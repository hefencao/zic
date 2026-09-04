import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_read_scheduler.dart';
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
    this.readScheduler,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'partial-download-handoff',
  });

  final PartialDownloadStore store;
  final PartialDownloadHandoffError? onError;
  final PartialEquivalentCandidates? equivalentCandidates;
  final MonoClock? clock;
  final ArtifactCacheReadScheduler? readScheduler;
  final TraceSink traceSink;
  final String sessionId;
  final Map<DownloadSession, Future<bool>> _stores =
      <DownloadSession, Future<bool>>{};

  Future<void> restoreInto(
    DownloadSession session, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (session.committedLength > 0) return;
    await session.restore(verifyPromotedChecksum: false);
    control?.throwIfCancelled();
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength > 0) {
      return;
    }
    final candidate = await _restoreCandidate(
      session.id,
      control: control,
    );
    if (candidate == null || candidate.entry.length <= 0) return;
    final entry = candidate.entry;

    final startedAtMicros = clock?.nowMicros();
    await session.bindResponse(
      validators: candidate.equivalent
          ? const Validators()
          : entry.validators,
      totalLength: entry.totalLength,
    );
    control?.throwIfCancelled();
    final writer = session.acquireWriter();
    var offset = 0;
    try {
      offset = await _restoreEntry(
        session,
        writer,
        entry,
        priority: () => session.effectivePriority,
        control: control,
      );
      if (offset != entry.length) {
        throw StateError(
          'durable partial length changed while restoring ${session.id.key}: '
          '$offset/${entry.length}',
        );
      }
      control?.throwIfCancelled();
      await session.pause(writer);
      control?.throwIfCancelled();
    } on Object catch (error, stackTrace) {
      // pause() retires the writer in its finally block even when its flush or
      // cache synchronization fails. Do not invoke fail() with a stale lease
      // in that case, and never let cleanup replace the original restore
      // error (especially a late cancellation after a successful pause).
      if (session.hasWriter) {
        try {
          await session.fail(writer, error);
        } on Object {
          // Preserve the restore/pause error. The session's terminal path has
          // already retired the writer; the next owner attempt can restore
          // the durable prefix.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    _record(
      session,
      action: candidate.equivalent ? 'restored-equivalent' : 'restored',
      bytes: offset,
      startedAtMicros: startedAtMicros,
      equivalent: candidate.equivalent,
      equivalentCandidatesChecked: candidate.candidatesChecked,
    );
  }


  Future<int> _restoreEntry(
    DownloadSession session,
    WriterLease writer,
    PartialDownloadEntry entry, {
    required int Function() priority,
    TaskControl? control,
  }) async {
    final scheduler = readScheduler;
    final iterator = StreamIterator<List<int>>(entry.open(start: 0));
    var offset = 0;
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      while (true) {
        ArtifactCacheReadLease? lease;
        try {
          if (scheduler != null) {
            lease = await scheduler.acquire(
              priority: priority,
              control: control,
            );
          }
          if (!await _moveNextCancellable(iterator, control)) break;
          final chunk = iterator.current;
          if (chunk.isEmpty) continue;
          control?.throwIfCancelled();
          await session.append(writer, offset, chunk);
          offset += chunk.length;
          control?.throwIfCancelled();
        } finally {
          lease?.release();
        }
      }
    } on Object catch (error, stackTrace) {
      primaryError = error;
      primaryStack = stackTrace;
    } finally {
      try {
        await iterator.cancel();
      } on Object catch (error, stackTrace) {
        if (primaryError == null) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    return offset;
  }

  Future<bool> _moveNextCancellable(
    StreamIterator<List<int>> iterator,
    TaskControl? control,
  ) async {
    if (control == null) return iterator.moveNext();
    control.throwIfCancelled();
    try {
      return await Future.any<bool>(<Future<bool>>[
        iterator.moveNext(),
        control.whenCancelled.then<bool>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'partial download restore was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }


  Future<_PartialRestoreCandidate?> _restoreCandidate(
    DownloadId id, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final exact = await _awaitCancellable(
      store.openPartialDownload(id),
      control,
    );
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
      control?.throwIfCancelled();
      if (equivalent == id) continue;
      checked++;
      final entry = await _awaitCancellable(
        store.openPartialDownload(equivalent),
        control,
      );
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

  static Future<T> _awaitCancellable<T>(
    Future<T> operation,
    TaskControl? control,
  ) async {
    if (control == null) return operation;
    control.throwIfCancelled();
    try {
      return await Future.any<T>(<Future<T>>[
        operation,
        control.whenCancelled.then<T>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'partial download restore was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Persists one unfinished authoritative prefix before its hot physical
  /// session is actually retired.
  ///
  /// The caller owns the retirement policy. This class only owns the durable
  /// partial representation and coalesces concurrent writes for the same hot
  /// session.
  Future<bool> persist(
    DownloadSession session, {
    String reason = 'physical-retirement',
  }) {
    final running = _stores[session];
    if (running != null) return running;
    late final Future<bool> tracked;
    tracked = _persist(session, reason: reason).whenComplete(() {
      if (identical(_stores[session], tracked)) _stores.remove(session);
    });
    _stores[session] = tracked;
    return tracked;
  }

  Future<bool> _persist(
    DownloadSession session, {
    required String reason,
  }) async {
    if (session.state == DownloadState.promoted || session.residentBodyBacked) {
      return true;
    }
    final length = session.artifact.committedLength;
    if (length <= 0) return true;
    final startedAtMicros = clock?.nowMicros();
    try {
      await store.storePartialDownload(
        id: session.id,
        entry: PartialDownloadEntry(
          length: length,
          validators: session.resumeValidatorsFor(session.id.canonicalUri),
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
        reason: reason,
      );
      return true;
    } on Object catch (error, stackTrace) {
      try {
        onError?.call(error, stackTrace);
      } on Object {}
      return false;
    }
  }

  /// Stores every unfinished authoritative prefix when the entire physical
  /// runtime is shutting down. Ordinary Reader detach/reentry never calls
  /// this path.
  Future<void> drain(Iterable<DownloadSession> sessions) async {
    for (final session in sessions) {
      await persist(session, reason: 'runtime-dispose');
    }
  }

  void _record(
    DownloadSession session, {
    required String action,
    required int bytes,
    required int? startedAtMicros,
    bool equivalent = false,
    int equivalentCandidatesChecked = 0,
    String? reason,
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
        if (reason != null) 'reason': reason,
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
