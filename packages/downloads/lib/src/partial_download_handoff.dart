import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'partial_download_store.dart';

typedef PartialDownloadHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);
typedef PartialEquivalentCandidates = Iterable<DownloadId> Function(
  DownloadId id,
);

/// Bridges a truly evicted hot DownloadSession to the chapter-owned durable
/// partial store. Ordinary Reader detach/reentry must never use this handoff:
/// the retained PipelineReaderSession remains the hot owner.
final class PartialDownloadHandoff {
  PartialDownloadHandoff({
    required this.store,
    this.onError,
    this.equivalentCandidates,
    this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'partial-download-handoff',
  });

  final PartialDownloadStore store;
  final PartialDownloadHandoffError? onError;
  final PartialEquivalentCandidates? equivalentCandidates;
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
    final candidate = await _restoreCandidate(session.id);
    if (candidate == null || candidate.entry.length <= 0) return;
    final entry = candidate.entry;

    final startedAtMicros = clock?.nowMicros();
    await session.bindResponse(
      validators: candidate.equivalent
          ? const Validators()
          : entry.validators,
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
      action: candidate.equivalent ? 'restored-equivalent' : 'restored',
      bytes: offset,
      startedAtMicros: startedAtMicros,
      equivalent: candidate.equivalent,
      equivalentCandidatesChecked: candidate.candidatesChecked,
    );
  }


  Future<_PartialRestoreCandidate?> _restoreCandidate(DownloadId id) async {
    final exact = await store.openPartialDownload(id);
    if (exact != null && exact.length > 0) {
      return _PartialRestoreCandidate(
        entry: exact,
        equivalent: false,
        candidatesChecked: 0,
      );
    }
    final candidates = equivalentCandidates;
    if (candidates == null) return null;
    PartialDownloadEntry? selected;
    var checked = 0;
    for (final equivalent in candidates(id)) {
      if (equivalent == id) continue;
      checked++;
      final entry = await store.openPartialDownload(equivalent);
      if (entry == null || entry.length <= 0) continue;
      if (selected == null || entry.length > selected.length) {
        selected = entry;
      }
    }
    if (selected == null) return null;
    return _PartialRestoreCandidate(
      entry: selected,
      equivalent: true,
      candidatesChecked: checked,
    );
  }

  /// Stores each unfinished authoritative prefix exactly once when the hot
  /// session is really being destroyed. This is not a per-route checkpoint or
  /// a second live writer.
  Future<void> drain(Iterable<DownloadSession> sessions) async {
    for (final session in sessions) {
      if (session.state == DownloadState.promoted || session.residentBodyBacked) {
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

  void _record(
    DownloadSession session, {
    required String action,
    required int bytes,
    required int? startedAtMicros,
    bool equivalent = false,
    int equivalentCandidatesChecked = 0,
  }) {
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
        if (equivalent) 'verifiedEquivalentReuse': true,
        if (equivalent)
          'equivalentCandidatesChecked': equivalentCandidatesChecked,
        if (startedAtMicros != null)
          'handoffMicros': (sourceClock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
      },
    ));
  }
}

final class _PartialRestoreCandidate {
  const _PartialRestoreCandidate({
    required this.entry,
    required this.equivalent,
    required this.candidatesChecked,
  });

  final PartialDownloadEntry entry;
  final bool equivalent;
  final int candidatesChecked;
}
