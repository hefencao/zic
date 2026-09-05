import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';

import 'download_ingress_projection.dart';
import 'download_session.dart';

final class _IngressProjectionEntry {
  _IngressProjectionEntry({
    required this.session,
    required this.projection,
    this.control,
  }) : completer = Completer<void>();

  DownloadSession session;
  final DownloadIngressProjection projection;
  final _IngressAttachmentControl? control;
  final Completer<void> completer;
  Future<void>? attachment;
  bool active = true;

  int get priority => control?.priority ?? session.effectivePriority;
}

/// Reader-local registry for native ingress projections.
///
/// Physical [DownloadSession] state can outlive any Reader. A Reader joining an
/// already-active/promoted transfer therefore must not synchronously attach a
/// fresh native ingress: replaying an existing committed prefix is asynchronous
/// consumer work. [get] always returns the Reader-local projection immediately
/// and starts a synchronized late join in the background when necessary.
///
/// This keeps physical transfer ownership independent from demand reconciliation
/// and ensures decode/upload can be reconciled even while the local source is
/// still catching up. For nonresident WebP hot partials the projection may publish a decoder-usable
/// prefix before full catch-up; its source listener then becomes the wake edge
/// while the same native source continues suffix replay toward the authoritative
/// committed boundary.
final class DownloadIngressProjectionRegistry {
  DownloadIngressProjectionRegistry({
    required this.sources,
    required this.scopePrefix,
    this.residentReplaySource,
    this.residentReplaySourceWithControl,
  });

  final SourcePool sources;
  final String scopePrefix;
  final DownloadResidentReplaySource? residentReplaySource;
  final DownloadResidentReplaySourceWithControl?
      residentReplaySourceWithControl;
  final Map<DownloadId, _IngressProjectionEntry> _entries =
      <DownloadId, _IngressProjectionEntry>{};
  final List<_IngressProjectionEntry> _pendingReplays =
      <_IngressProjectionEntry>[];
  final Set<_IngressProjectionEntry> _activeReplays =
      <_IngressProjectionEntry>{};
  bool _isMemoryPressured = false;

  Iterable<DownloadIngressProjection> get projections =>
      _entries.values.map((entry) => entry.projection);

  void observeMemoryPressure(bool isPressured) {
    if (_isMemoryPressured == isPressured) return;
    _isMemoryPressured = isPressured;
    _pumpReplays();
  }

  DownloadIngressProjection attach(DownloadSession session) {
    final existing = _entries[session.id];
    if (existing != null && identical(existing.session, session)) {
      existing.control?.updatePriority(session.effectivePriority);
      _pumpReplays();
      return existing.projection;
    }
    if (existing != null) {
      // A new physical DownloadSession with the same DownloadId is a new
      // physical object generation. dev.279 only preserves the Reader encoded
      // generation under the sealed immutable exception below.
      final snapshot = existing.projection.snapshot;
      if (existing.attachment == null &&
          !_pendingReplays.contains(existing) &&
          snapshot.sealed &&
          snapshot.sourceReady &&
          snapshot.failure == null) {
        // The physical transfer object changed, but this Reader already owns a
        // complete immutable encoded generation for the same exact DownloadId.
        // Retiring that source would turn a hot Reader re-entry into disk replay
        // + decode/upload regeneration even though the encoded bytes did not
        // change. Physical generation and encoded-source generation are not the
        // same concept once the Reader-local source is sealed.
        existing.session.detachIngressProjection(existing.projection.scopeId);
        existing.session = session;
        existing.attachment = null;
        return existing.projection;
      }
      _pendingReplays.remove(existing);
      _activeReplays.remove(existing);
      existing.active = false;
      existing.control?.cancel();
      if (!existing.completer.isCompleted) {
        existing.completer.complete();
      }
      existing.session.detachIngressProjection(existing.projection.scopeId);
      existing.projection.detach();
      _entries.remove(session.id);
      // An incomplete/failed Reader-local source is still physical-generation
      // bound. A replacement physical session must receive a fresh ingress and
      // revision timeline rather than inheriting a mutable prefix.
      sources.remove(session.id);
    }

    final projection = DownloadIngressProjection(
      scopeId: '$scopePrefix:physical:${session.sessionId}',
      ingress: sources.get(session.id),
    );
    final attachmentControl = session.committedLength == 0
        ? null
        : _IngressAttachmentControl(priority: session.effectivePriority);
    final entry = _IngressProjectionEntry(
      session: session,
      projection: projection,
      control: attachmentControl,
    );
    // Publish the local projection before starting a late replay. DecodeSession
    // may safely enter waitingSource against this empty projection while the
    // physical prefix is copied; the eventual rebuild notification wakes it.
    _entries[session.id] = entry;

    if (session.committedLength == 0) {
      try {
        session.attachIngressProjection(projection);
        entry.completer.complete();
      } on Object {
        _entries.remove(session.id);
        projection.detach();
        rethrow;
      }
      return projection;
    }

    _pendingReplays.add(entry);
    _pumpReplays();
    return projection;
  }

  DownloadIngressProjection get(DownloadSession session) => attach(session);

  DownloadIngressProjection? find(DownloadId id) => _entries[id]?.projection;

  Future<void> settled(DownloadId id) {
    final entry = _entries[id];
    if (entry == null) return Future<void>.value();
    if (entry.attachment == null && _pendingReplays.contains(entry)) {
      _pendingReplays.remove(entry);
      _startReplay(entry);
    }
    return entry.completer.future;
  }

  void updatePriority(DownloadSession session) {
    final entry = _entries[session.id];
    if (entry != null && identical(entry.session, session)) {
      entry.control?.updatePriority(session.effectivePriority);
      _pumpReplays();
    }
  }

  void detach(DownloadSession session) {
    final entry = _entries[session.id];
    if (entry == null || !identical(entry.session, session)) return;
    _entries.remove(session.id);
    _pendingReplays.remove(entry);
    _activeReplays.remove(entry);
    entry.active = false;
    entry.control?.cancel();
    if (!entry.completer.isCompleted) {
      entry.completer.complete();
    }
    session.detachIngressProjection(entry.projection.scopeId);
    entry.projection.detach();
    _pumpReplays();
  }

  /// Releases only Reader-local projection ownership.
  ///
  /// It intentionally does not enumerate or dispose the composition physical
  /// DownloadRegistry. Any in-flight late-join future self-cleans its physical
  /// fan-out when it observes [active] becoming false.
  void dispose() {
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    _pendingReplays.clear();
    _activeReplays.clear();
    for (final entry in entries) {
      entry.active = false;
      entry.control?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete();
      }
      entry.session.detachIngressProjection(entry.projection.scopeId);
      entry.projection.detach();
    }
  }

  void _pumpReplays() {
    if (_pendingReplays.isEmpty) return;

    _pendingReplays.sort((a, b) => b.priority.compareTo(a.priority));

    final activeForeground =
        _activeReplays.where((e) => e.priority >= 1000).length;
    final activeBackground = _activeReplays.length - activeForeground;

    final toStart = <_IngressProjectionEntry>[];
    for (final entry in _pendingReplays) {
      if (!entry.active) continue;
      final priority = entry.priority;
      if (priority >= 1000) {
        toStart.add(entry);
      } else if (priority >= 780) {
        if (activeForeground == 0 && (activeBackground + toStart.length) < 1) {
          toStart.add(entry);
        }
      } else {
        if (!_isMemoryPressured &&
            activeForeground == 0 &&
            (activeBackground + toStart.length) < 1) {
          toStart.add(entry);
        }
      }
    }

    for (final entry in toStart) {
      _pendingReplays.remove(entry);
      _startReplay(entry);
    }
  }

  void _startReplay(_IngressProjectionEntry entry) {
    if (!entry.active) return;
    _activeReplays.add(entry);

    final session = entry.session;
    final projection = entry.projection;
    final attachmentControl = entry.control;

    final attachment = session.attachSynchronizedIngressProjection(
      projection,
      control: attachmentControl,
      residentReplayChunks: session.residentBodyBacked
          ? (endExclusive) {
              final replay = residentReplaySource;
              if (replay == null) {
                throw const Failure(
                  code: ErrorCode.invalidState,
                  message: 'resident-cache Reader replay source is unavailable',
                );
              }
              return replay(session, endExclusive);
            }
          : null,
      controlledResidentReplayChunks:
          session.residentBodyBacked &&
                  residentReplaySourceWithControl != null
              ? (endExclusive, {required control}) {
                  return residentReplaySourceWithControl!(
                    session,
                    endExclusive,
                    control: control,
                  );
                }
              : null,
    );
    entry.attachment = attachment;
    unawaited(
      attachment.then<void>((_) {
        // Reader teardown can race the asynchronous replay. If this entry is no
        // longer authoritative, remove any physical fan-out that the replay may
        // just have installed rather than resurrecting a dead Reader consumer.
        if (!entry.active || !identical(_entries[session.id], entry)) {
          session.detachIngressProjection(projection.scopeId);
        }
        if (!entry.completer.isCompleted) {
          entry.completer.complete();
        }
      }).catchError((Object error, StackTrace stackTrace) {
        if (!entry.active || !identical(_entries[session.id], entry)) {
          if (!entry.completer.isCompleted) {
            entry.completer.complete();
          }
          return;
        }
        final failure = error is Failure
            ? error
            : Failure(
                code: ErrorCode.source,
                message: 'Reader ingress projection attachment failed',
                cause: error,
              );
        projection.fail(failure);
        if (!entry.completer.isCompleted) {
          entry.completer.complete();
        }
      }).whenComplete(() {
        _activeReplays.remove(entry);
        _pumpReplays();
      }),
    );
  }
}

final class _IngressAttachmentControl implements TaskControl {
  _IngressAttachmentControl({int priority = 0}) : _priority = priority;

  int _priority;

  @override
  int get priority => _priority;

  void updatePriority(int priority) {
    _priority = priority;
  }

  final Completer<void> _cancelledSignal = Completer<void>();

  @override
  bool get cancelled => _cancelledSignal.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }
}
