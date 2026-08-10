import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';

import 'partial_download_store.dart';

typedef PartialDownloadHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Bridges a truly evicted hot DownloadSession to the chapter-owned durable
/// partial store. Ordinary Reader detach/reentry must never use this handoff:
/// the retained PipelineReaderSession remains the hot owner.
final class PartialDownloadHandoff {
  PartialDownloadHandoff({
    required this.store,
    this.onError,
    this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'partial-download-handoff',
  });

  final PartialDownloadStore store;
  final PartialDownloadHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;

  Future<void> restoreInto(DownloadSession session) async {
    if (session.committedLength > 0) return;
    await session.restore(verifyPromotedChecksum: false);
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength > 0) {
      return;
    }
    final entry = await store.openPartialDownload(session.id);
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
    _record(session, action: 'restored', bytes: offset, startedAtMicros: startedAtMicros);
  }

  /// Stores each unfinished authoritative prefix exactly once when the hot
  /// session is really being destroyed. This is not a per-route checkpoint or
  /// a second live writer.
  Future<void> drain(Iterable<DownloadSession> sessions) async {
    for (final session in sessions) {
      if (session.state == DownloadState.promoted || session.residentCacheBacked) {
        continue;
      }
      final length = session.artifact.committedLength;
      if (length <= 0) continue;
      final startedAtMicros = clock?.nowMicros();
      try {
        await store.storePartialDownload(
          id: session.id,
          entry: PartialDownloadEntry(
            length: length,
            validators: session.validators,
            totalLength: session.totalLength,
            open: ({required int start}) => session.artifact.readChunks(
              start: start,
              endExclusive: length,
            ),
          ),
        );
        _record(session, action: 'stored', bytes: length, startedAtMicros: startedAtMicros);
      } on Object catch (error, stackTrace) {
        try { onError?.call(error, stackTrace); } on Object {}
      }
    }
  }

  void _record(DownloadSession session, {required String action, required int bytes, required int? startedAtMicros}) {
    final sourceClock = clock;
    if (sourceClock == null) return;
    traceSink.record(traceEvent(
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
          'handoffMicros': (sourceClock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
      },
    ));
  }
}
