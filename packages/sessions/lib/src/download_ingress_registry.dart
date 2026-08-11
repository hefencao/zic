import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';

import 'download_ingress_projection.dart';
import 'download_session.dart';

typedef ResidentIngressReplaySource = Future<Stream<List<int>>> Function(
  DownloadSession session,
  int endExclusive,
);

final class _IngressProjectionEntry {
  _IngressProjectionEntry({
    required this.session,
    required this.projection,
  });

  final DownloadSession session;
  final DownloadIngressProjection projection;
  Future<void>? attachment;
  bool active = true;
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
/// still catching up. The projection's source listener becomes the wake edge
/// when the replay reaches an authoritative committed boundary.
final class DownloadIngressProjectionRegistry {
  DownloadIngressProjectionRegistry({
    required this.sources,
    required this.scopePrefix,
    this.residentReplaySource,
  });

  final SourcePool sources;
  final String scopePrefix;
  final ResidentIngressReplaySource? residentReplaySource;
  final Map<DownloadId, _IngressProjectionEntry> _entries =
      <DownloadId, _IngressProjectionEntry>{};

  Iterable<DownloadIngressProjection> get projections =>
      _entries.values.map((entry) => entry.projection);

  DownloadIngressProjection attach(DownloadSession session) {
    final existing = _entries[session.id];
    if (existing != null) return existing.projection;

    final projection = DownloadIngressProjection(
      scopeId: '$scopePrefix:${session.id.key}',
      ingress: sources.get(session.id),
    );
    final entry = _IngressProjectionEntry(
      session: session,
      projection: projection,
    );
    // Publish the local projection before starting a late replay. DecodeSession
    // may safely enter waitingSource against this empty projection while the
    // physical prefix is copied; the eventual rebuild notification wakes it.
    _entries[session.id] = entry;

    if (session.committedLength == 0) {
      try {
        session.attachIngressProjection(projection);
      } on Object {
        _entries.remove(session.id);
        projection.detach();
        rethrow;
      }
      return projection;
    }

    final attachment = session.attachSynchronizedIngressProjection(
      projection,
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
      }).catchError((Object error, StackTrace stackTrace) {
        if (!entry.active || !identical(_entries[session.id], entry)) {
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
      }),
    );
    return projection;
  }

  DownloadIngressProjection get(DownloadSession session) =>
      _entries[session.id]?.projection ?? attach(session);

  DownloadIngressProjection? find(DownloadId id) => _entries[id]?.projection;

  Future<void> settled(DownloadId id) =>
      _entries[id]?.attachment ?? Future<void>.value();

  void detach(DownloadSession session) {
    final entry = _entries.remove(session.id);
    if (entry == null) return;
    entry.active = false;
    session.detachIngressProjection(entry.projection.scopeId);
    entry.projection.detach();
  }

  /// Releases only Reader-local projection ownership.
  ///
  /// It intentionally does not enumerate or dispose the composition physical
  /// DownloadRegistry. Any in-flight late-join future self-cleans its physical
  /// fan-out when it observes [active] becoming false.
  void dispose() {
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    for (final entry in entries) {
      entry.active = false;
      entry.session.detachIngressProjection(entry.projection.scopeId);
      entry.projection.detach();
    }
  }
}
