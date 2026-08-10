import 'dart:async';

import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_store.dart';

typedef PartialArtifactCacheHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Bridges incomplete Reader-session artifacts to the durable chapter-owned
/// DownloadSession store without making a partial look like a promoted cache
/// hit.
///
/// The handoff is intentionally lifecycle-scoped: the hot Reader artifact is
/// checkpointed when the route is retained and again before its ephemeral
/// workspace is destroyed. It is not a second per-chunk writer and it never
/// creates network demand.
final class PartialArtifactCacheHandoff {
  PartialArtifactCacheHandoff({
    required this.cache,
    this.onError,
    this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'partial-artifact-cache-handoff',
  });

  final ArtifactCacheManager cache;
  final PartialArtifactCacheHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;

  Future<void> restoreInto(DownloadSession session) async {
    if (!cache.supportsPartialArtifacts || session.committedLength > 0) return;
    await session.restore(verifyPromotedChecksum: false);
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength > 0) {
      return;
    }
    final entry = await cache.lookupPartial(session.id);
    if (entry == null || entry.length <= 0) return;

    final startedAtMicros = clock?.nowMicros();
    await session.bindResponse(
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
    final writer = session.acquireWriter();
    var offset = 0;
    try {
      await for (final chunk in entry.open(start: 0)) {
        if (chunk.isEmpty) continue;
        await session.append(writer, offset, chunk);
        offset += chunk.length;
      }
      if (offset != entry.length) {
        throw StateError(
          'durable partial length changed while restoring ${session.id.key}: '
          '$offset/${entry.length}',
        );
      }
    } on Object catch (error) {
      await session.fail(writer, error);
      rethrow;
    }
    await session.pause(writer);
    _record(
      session,
      action: 'restored',
      bytes: offset,
      startedAtMicros: startedAtMicros,
    );
  }

  /// Saves a stable prefix snapshot without stopping an active Reader writer.
  ///
  /// [Artifact.readChunks] flushes writes already committed at the snapshot
  /// boundary. The fixed endExclusive keeps later concurrent appends outside
  /// this checkpoint.
  Future<void> checkpoint(Iterable<DownloadSession> sessions) async {
    if (!cache.supportsPartialArtifacts) return;
    for (final session in sessions) {
      if (session.state == DownloadState.promoted || session.residentCacheBacked) {
        continue;
      }
      final length = session.artifact.committedLength;
      if (length <= 0) continue;
      final startedAtMicros = clock?.nowMicros();
      try {
        await cache.storePartialArtifact(
          id: session.id,
          entry: PartialArtifactCacheEntry(
            length: length,
            validators: session.validators,
            totalLength: session.totalLength,
            open: ({required int start}) => session.artifact.readChunks(
              start: start,
              endExclusive: length,
            ),
          ),
        );
        _record(
          session,
          action: 'stored',
          bytes: length,
          startedAtMicros: startedAtMicros,
        );
      } on Object catch (error, stackTrace) {
        try {
          onError?.call(error, stackTrace);
        } on Object {
          // Cache diagnostics must not fail Reader lifecycle.
        }
      }
    }
  }

  Future<void> drain(Iterable<DownloadSession> sessions) => checkpoint(sessions);

  void _record(
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
          'source': 'session-partial-handoff',
          'consumer': 'durable-partial',
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
