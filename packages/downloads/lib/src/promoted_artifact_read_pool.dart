import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';

import 'artifact_cache_store.dart';

/// Coalesces exact reads of already-promoted artifacts during one Reader run.
///
/// A cold Reader session still creates and promotes its own DownloadSession so
/// pipeline/session ownership is unchanged. The page consumer and the
/// read-through transport may, however, share the same immutable cache read so
/// first-frame decode does not wait for the bytes to be copied into and read
/// back out of the ephemeral session artifact.
///
/// Completed reads are released as soon as the new session reaches a terminal
/// state. The pool does not retain encoded pages beyond that handoff and does
/// not choose which pages are demanded.
final class PromotedArtifactReadPool {
  PromotedArtifactReadPool({required this.cache});

  final ArtifactCacheStore cache;
  final Map<DownloadId, Future<Uint8List?>> _reads =
      <DownloadId, Future<Uint8List?>>{};
  final Map<DownloadId, Completer<Uint8List?>> _joiners =
      <DownloadId, Completer<Uint8List?>>{};
  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Set<DownloadId> _terminal = <DownloadId>{};
  bool _closed = false;

  int get retainedReadCount => _reads.length;

  Future<Uint8List?> read(DownloadId id) {
    _requireOpen();
    _terminal.remove(id);
    final existing = _reads[id];
    if (existing != null) {
      return existing;
    }

    final completer = Completer<Uint8List?>();
    final tracked = completer.future;
    _reads[id] = tracked;
    Future<Uint8List?>.sync(() => cache.readArtifact(id)).then<void>(
      completer.complete,
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_reads[id], tracked)) {
          _reads.remove(id);
        }
        completer.completeError(error, stackTrace);
      },
    );
    final joiner = _joiners.remove(id);
    if (joiner != null && !joiner.isCompleted) {
      joiner.complete(tracked);
    }
    return tracked;
  }

  /// Joins a read only after the authoritative session enters active work.
  ///
  /// Calling this method never accesses cache storage and therefore does not
  /// turn PageView construction into an independent download/cache demand.
  Future<Uint8List?> join(DownloadId id) {
    _requireOpen();
    if (cache is ArtifactCacheStreamStore) {
      return Future<Uint8List?>.value();
    }
    final existing = _reads[id];
    if (existing != null) {
      return existing;
    }
    if (_terminal.contains(id)) {
      return Future<Uint8List?>.value();
    }
    return _joiners.putIfAbsent(id, Completer<Uint8List?>.new).future;
  }

  /// Releases a shared read when the replacement Reader session no longer
  /// needs cache-to-session handoff coordination.
  void release(DownloadId id) {
    _reads.remove(id);
    final joiner = _joiners.remove(id);
    if (joiner != null && !joiner.isCompleted) {
      joiner.complete(null);
    }
  }

  void observe(DownloadSession session) {
    _requireOpen();
    if (_listeners.containsKey(session)) {
      return;
    }

    void listener(DownloadSnapshot snapshot) {
      switch (snapshot.state) {
        case DownloadState.promoted:
        case DownloadState.failed:
        case DownloadState.disposed:
          _terminal.add(session.id);
          release(session.id);
          return;
        case DownloadState.idle:
        case DownloadState.queued:
        case DownloadState.receiving:
        case DownloadState.sealed:
          _terminal.remove(session.id);
          break;
      }

      // beginRun() is the earliest authoritative ownership signal. Priming on
      // activeRun lets a page join the persistent artifact while the session
      // is still restoring its ephemeral workspace, instead of blocking first
      // frame on file-system setup. queued/receiving remain explicit signals
      // for alternative coordinators that do not expose the run transition.
      if (snapshot.activeRun ||
          snapshot.state == DownloadState.queued ||
          snapshot.state == DownloadState.receiving) {
        _prime(session.id);
      }
    }

    _listeners[session] = listener;
    session.addSnapshotListener(listener);
  }

  void _prime(DownloadId id) {
    if (cache is ArtifactCacheStreamStore) {
      return;
    }
    final pending = read(id);
    // The session transport or page consumer will normally await the same
    // Future. This listener only prevents an unhandled asynchronous error if
    // the session is cancelled before either consumer attaches.
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final entry in _listeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _listeners.clear();
    for (final joiner in _joiners.values) {
      if (!joiner.isCompleted) {
        joiner.complete(null);
      }
    }
    _joiners.clear();
    _reads.clear();
    _terminal.clear();
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('promoted artifact read pool is closed');
    }
  }
}
