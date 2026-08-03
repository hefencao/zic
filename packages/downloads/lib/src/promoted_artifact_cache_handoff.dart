import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';

import 'artifact_cache_manager.dart';

typedef ArtifactCacheHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Commits only fully promoted session artifacts to the persistent cache tier.
///
/// This observer does not create demand, start downloads or choose retention.
/// It follows DownloadSession state, copies a final artifact after promotion,
/// and drains pending commits before the owning ephemeral workspace is removed.
final class PromotedArtifactCacheHandoff {
  PromotedArtifactCacheHandoff({
    required this.cache,
    this.onError,
    this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'artifact-cache-handoff',
  });

  final ArtifactCacheManager cache;
  final ArtifactCacheHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;
  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadId, Future<void>> _commits =
      <DownloadId, Future<void>>{};

  void observe(DownloadSession session) {
    if (_listeners.containsKey(session)) {
      return;
    }
    void listener(DownloadSnapshot snapshot) {
      if (snapshot.state == DownloadState.promoted) {
        _submit(session);
      }
    }

    _listeners[session] = listener;
    session.addSnapshotListener(listener);
    if (session.state == DownloadState.promoted) {
      _submit(session);
    }
  }

  Future<void> drain(Iterable<DownloadSession> sessions) async {
    final current = sessions.toList(growable: false);
    for (var attempt = 0; attempt < 2; attempt++) {
      for (final session in current) {
        if (session.state == DownloadState.promoted) {
          _submit(session);
        }
      }
      for (final commit in _commits.values.toList(growable: false)) {
        await commit;
      }
    }
  }

  void detach() {
    for (final entry in _listeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _listeners.clear();
  }

  void _submit(DownloadSession session) {
    final id = session.id;
    if (_commits.containsKey(id)) {
      return;
    }
    late final Future<void> tracked;
    tracked = _commit(session).catchError(
      (Object error, StackTrace stackTrace) {
        if (identical(_commits[id], tracked)) {
          _commits.remove(id);
        }
        try {
          onError?.call(error, stackTrace);
        } on Object {
          // Error reporting must not create another failed cache Future.
        }
      },
    );
    _commits[id] = tracked;
    unawaited(tracked);
  }

  Future<void> _commit(DownloadSession session) async {
    if (session.state != DownloadState.promoted) {
      return;
    }
    final startedAtMicros = clock?.nowMicros();
    final expectedLength = session.artifact.committedLength;
    if (await cache.containsBackend(
      id: session.id,
      expectedLength: expectedLength,
    )) {
      _recordCommit(
        session,
        action: 'skip-existing',
        bytes: expectedLength,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks()) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    await cache.storePromotedArtifact(
      id: session.id,
      bytes: bytes,
    );
    _recordCommit(
      session,
      action: 'stored',
      bytes: bytes.lengthInBytes,
      startedAtMicros: startedAtMicros,
    );
  }

  void _recordCommit(
    DownloadSession session, {
    required String action,
    required int bytes,
    required int? startedAtMicros,
  }) {
    final sourceClock = clock;
    if (sourceClock == null) return;
    traceSink.record(
      traceEvent(
        clock: sourceClock,
        sessionId: sessionId,
        kind: TraceEventKind.artifactSource,
        identityHash: session.id.key,
        payload: <String, Object?>{
          'source': 'session-artifact-handoff',
          'consumer': 'persistent-cache',
          'action': action,
          'bytes': bytes,
          if (startedAtMicros != null)
            'handoffMicros': (sourceClock.nowMicros() - startedAtMicros)
                .clamp(0, 1 << 62)
                .toInt(),
        },
      ),
    );
  }
}
