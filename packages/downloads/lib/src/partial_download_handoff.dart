import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_store.dart';
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
    this.physicalArtifactCache,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'partial-download-handoff',
  });

  final PartialDownloadStore store;
  final PartialDownloadHandoffError? onError;
  final PartialEquivalentCandidates? equivalentCandidates;
  final MonoClock? clock;
  final ArtifactCacheReadScheduler? readScheduler;
  final ArtifactCacheManager? physicalArtifactCache;
  final TraceSink traceSink;
  final String sessionId;
  final Map<DownloadSession, Future<bool>> _stores =
      <DownloadSession, Future<bool>>{};
  final Expando<_ExactDurableRestoreProof> _exactDurableRestoreProofs =
      Expando<_ExactDurableRestoreProof>('exact-durable-restore');

  bool provesExactDurableBody(
    DownloadSession session,
    DownloadId targetId,
    int length,
  ) {
    final proof = _exactDurableRestoreProofs[session];
    return proof != null &&
        proof.id == targetId &&
        proof.epoch == session.epoch &&
        proof.length == length &&
        session.id == targetId;
  }

  Future<void> restoreInto(
    DownloadSession session, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    _exactDurableRestoreProofs[session] = null;
    if (session.committedLength > 0) return;
    final cache = physicalArtifactCache;
    if (cache != null && cache.requiresFreshSource(session.id)) {
      _record(
        session,
        action: 'fresh-source-skip-durable-restore',
        bytes: 0,
        startedAtMicros: clock?.nowMicros(),
      );
      return;
    }

    // A recoverable session-local artifact remains the first physical owner.
    // Only when it proves empty do exact and direct verified durable candidates
    // compete. This path is compatibility for historical/non-canonical state;
    // canonical physical READY/partial ownership is still checked first below.
    _PartialRestoreCandidate? durableCandidate;
    PartialDownloadEntry? physicalPartial;
    if (!await session.artifact.hasRestorableBody()) {
      control?.throwIfCancelled();
      if (!session.physicalId.isExactFallback && cache != null) {
        var physical = await cache.openPhysicalArtifact(session.physicalId);
        var recoveredHistoricalBinding = false;
        if (physical == null) {
          recoveredHistoricalBinding =
              await cache.bindPhysicalArtifactFromCandidates(
            physicalId: session.physicalId,
            candidates: <DownloadId>[
              session.id,
              ...?equivalentCandidates?.call(session.id),
            ],
          );
          control?.throwIfCancelled();
          if (recoveredHistoricalBinding) {
            physical = await cache.openPhysicalArtifact(session.physicalId);
          }
        }
        control?.throwIfCancelled();
        if (physical != null &&
            await _tryBindEquivalentReadyAuthority(
              session,
              _physicalArtifactEntry(physical),
              candidatesChecked: 0,
              control: control,
            )) {
          return;
        }
      }
      if (!session.physicalId.isExactFallback) {
        final physicalStore = store;
        if (physicalStore is PhysicalPartialDownloadStore) {
          physicalPartial =
              await (physicalStore as PhysicalPartialDownloadStore)
                  .openPhysicalPartialDownload(
            physicalId: session.physicalId,
            requestId: session.id,
          );
          control?.throwIfCancelled();
        }
      }
      if (physicalPartial == null) {
        durableCandidate = await _restoreCandidate(
          session.id,
          control: control,
        );
        final durableEntry = durableCandidate?.entry;
        if (durableEntry != null && durableEntry.exactDurableFinal) {
          final bound = durableCandidate!.equivalent
              ? await _tryBindEquivalentReadyAuthority(
                  session,
                  durableEntry,
                  candidatesChecked: durableCandidate.candidatesChecked,
                  control: control,
                )
              : await _tryBindExactReadyWithoutSessionRestore(
                  session,
                  durableEntry,
                  control: control,
                );
          if (bound) return;
        }
      }
    }

    await session.restore(
      verifyPromotedChecksum: false,
      control: control,
    );
    control?.throwIfCancelled();
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength > 0) {
      return;
    }
    final physicalEntry = physicalPartial;
    if (physicalEntry != null && physicalEntry.length > 0) {
      final adoptInto = physicalEntry.adoptInto;
      if (adoptInto != null) {
        final startedAtMicros = clock?.nowMicros();
        final adopted = await adoptInto(session, control: control);
        control?.throwIfCancelled();
        if (adopted) {
          _record(
            session,
            action: 'adopted-physical',
            bytes: session.committedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
      }
      final startedAtMicros = clock?.nowMicros();
      await session.bindResponse(
        validators: physicalEntry.validators,
        totalLength: physicalEntry.totalLength,
      );
      control?.throwIfCancelled();
      final writer = session.acquireWriter();
      var offset = 0;
      try {
        offset = await _restoreEntry(
          session,
          writer,
          physicalEntry,
          priority: () => session.effectivePriority,
          control: control,
        );
        if (offset != physicalEntry.length) {
          throw StateError(
            'physical durable partial length changed while restoring '
            '${session.physicalId.key}: $offset/${physicalEntry.length}',
          );
        }
        control?.throwIfCancelled();
        await session.pause(writer);
        control?.throwIfCancelled();
      } on Object catch (error, stackTrace) {
        if (session.hasWriter) {
          try {
            await session.fail(writer, error);
          } on Object {
            // Preserve the restore failure.
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      _record(
        session,
        action: 'restored-physical',
        bytes: offset,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final candidate = durableCandidate ??
        await _restoreCandidate(
          session.id,
          control: control,
        );
    if (candidate == null || candidate.entry.length <= 0) return;
    final entry = candidate.entry;

    if (candidate.equivalent &&
        entry.exactDurableFinal &&
        await _tryBindEquivalentReadyAuthority(
          session,
          entry,
          candidatesChecked: candidate.candidatesChecked,
          control: control,
        )) {
      return;
    }

    if (!candidate.equivalent && entry.exactDurableFinal) {
      final totalLength = entry.totalLength ?? entry.length;
      if (totalLength != entry.length) {
        throw StateError(
          'exact durable final length mismatch for ${session.id.key}: '
          '${entry.length}/$totalLength',
        );
      }
      final startedAtMicros = clock?.nowMicros();
      PartialDownloadBoundRangeReader? boundReader;
      final openBoundReader = entry.openBoundRangeReader;
      if (openBoundReader != null) {
        ArtifactCacheReadLease? lease;
        try {
          final scheduler = readScheduler;
          if (scheduler != null) {
            lease = await scheduler.acquire(
              priority: () => session.effectivePriority,
              control: control,
            );
          }
          boundReader = await openBoundReader();
        } on Object {
          // Descriptor reuse is an optimization. The stateless exact-range
          // authority below remains the correctness fallback.
          boundReader = null;
        } finally {
          lease?.release();
        }
      }
      final prefix = await _readEntryPrefix(
        entry,
        boundReader: boundReader,
        priority: () => session.effectivePriority,
        control: control,
      );
      control?.throwIfCancelled();
      final proof = _ExactDurableRestoreProof(
        id: session.id,
        epoch: session.epoch,
        length: entry.length,
      );
      // Promotion observers run synchronously from DownloadSession's snapshot
      // publication. Install the exact durable proof before binding/promoting so
      // PromotedArtifactCacheHandoff cannot race ahead into a redundant backend
      // preflight of the same body.
      _exactDurableRestoreProofs[session] = proof;
      try {
        final openRange = entry.openRange;
        final reader = boundReader;
        session.bindResidentImmutableAuthority(
          validators: entry.validators,
          totalLength: totalLength,
          validatorRequestUri: session.id.canonicalUri,
          bodyAuthority: ByteResponseBodyAuthority.artifactCache,
          metadataPrefix: prefix,
          residentReplayRangeChunks: reader != null
              ? (start, endExclusive) async =>
                    _openBoundRange(reader, start, endExclusive)
              : openRange == null
                  ? null
                  : (start, endExclusive) async => openRange(
                        start: start,
                        endExclusive: endExclusive,
                      ),
          residentReplayRangeClose: reader?.close,
          residentReplayAccessMode: reader?.accessMode ?? entry.accessMode,
        );
        boundReader = null; // DownloadSession now owns reader lifecycle.
      } on Object {
        final reader = boundReader;
        boundReader = null;
        if (reader != null) {
          try {
            await reader.close();
          } on Object {
            // Preserve the bind failure.
          }
        }
        if (identical(_exactDurableRestoreProofs[session], proof)) {
          _exactDurableRestoreProofs[session] = null;
        }
        rethrow;
      }
      _record(
        session,
        action: 'bound-ready-authority',
        bytes: entry.length,
        startedAtMicros: startedAtMicros,
      );
      return;
    }

    final adoptInto = entry.adoptInto;
    if (!candidate.equivalent && adoptInto != null) {
      final startedAtMicros = clock?.nowMicros();
      final adopted = await adoptInto(session, control: control);
      control?.throwIfCancelled();
      if (adopted) {
        _record(
          session,
          action: 'adopted',
          bytes: session.committedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }
    }

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
    if (!candidate.equivalent && entry.exactDurableFinal) {
      _exactDurableRestoreProofs[session] = _ExactDurableRestoreProof(
        id: session.id,
        epoch: session.epoch,
        length: offset,
      );
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


  Stream<List<int>> _openBoundRange(
    PartialDownloadBoundRangeReader reader,
    int start,
    int endExclusive,
  ) async* {
    final bytes = await reader.readRange(start, endExclusive);
    if (bytes.isNotEmpty) yield bytes;
  }

  PartialDownloadEntry _physicalArtifactEntry(ArtifactCacheStreamEntry entry) =>
      PartialDownloadEntry(
        length: entry.length,
        validators: const Validators(),
        totalLength: entry.length,
        open: ({required int start}) => entry.open(start: start),
        openRange: ({required int start, required int endExclusive}) =>
            entry.open(start: start, endExclusive: endExclusive),
        openBoundRangeReader: entry.openBoundRangeReader == null
            ? null
            : () async {
                final reader = await entry.openBoundRangeReader!();
                if (reader == null) return null;
                return (
                  accessMode: reader.accessMode,
                  readRange: reader.readRange,
                  close: reader.close,
                );
              },
        accessMode: entry.accessMode,
        exactDurableFinal: true,
      );

  Future<bool> _tryBindEquivalentReadyAuthority(
    DownloadSession session,
    PartialDownloadEntry entry, {
    required int candidatesChecked,
    TaskControl? control,
  }) async {
    final startedAtMicros = clock?.nowMicros();
    final totalLength = entry.totalLength ?? entry.length;
    if (!entry.exactDurableFinal ||
        entry.length <= 0 ||
        totalLength != entry.length) {
      return false;
    }

    PartialDownloadBoundRangeReader? boundReader;
    final openBoundReader = entry.openBoundRangeReader;
    if (openBoundReader != null) {
      ArtifactCacheReadLease? lease;
      try {
        final scheduler = readScheduler;
        if (scheduler != null) {
          lease = await scheduler.acquire(
            priority: () => session.effectivePriority,
            control: control,
          );
        }
        boundReader = await openBoundReader();
      } on Object {
        // Retained descriptor reuse is an optimization. The verified durable
        // range authority below remains a correctness fallback.
        boundReader = null;
      } finally {
        lease?.release();
      }
    }
    control?.throwIfCancelled();

    final List<int> prefix;
    try {
      prefix = await _readEntryPrefix(
        entry,
        boundReader: boundReader,
        priority: () => session.effectivePriority,
        control: control,
      );
    } on Object {
      final reader = boundReader;
      boundReader = null;
      if (reader != null) {
        try {
          await reader.close();
        } on Object {
          // Preserve the metadata/read failure and use the historical copy
          // fallback below.
        }
      }
      return false;
    }
    control?.throwIfCancelled();

    final openRange = entry.openRange;
    final reader = boundReader;
    if (reader == null && openRange == null) {
      return false;
    }
    try {
      session.bindResidentImmutableAuthority(
        // Equivalent source revisions may not share resume validators even
        // when their bytes are source-verified equivalent.
        validators: const Validators(),
        totalLength: totalLength,
        bodyAuthority: ByteResponseBodyAuthority.artifactCache,
        metadataPrefix: prefix,
        residentReplayRangeChunks: reader != null
            ? (start, endExclusive) async =>
                _openBoundRange(reader, start, endExclusive)
            : (start, endExclusive) async => openRange!(
                  start: start,
                  endExclusive: endExclusive,
                ),
        residentReplayRangeClose: reader?.close,
        residentReplayAccessMode: reader?.accessMode ?? entry.accessMode,
      );
      boundReader = null; // DownloadSession now owns the retained reader.
    } on Object {
      final reader = boundReader;
      boundReader = null;
      if (reader != null) {
        try {
          await reader.close();
        } on Object {
          // Preserve the bind failure.
        }
      }
      rethrow;
    }
    _record(
      session,
      action: 'bound-ready-authority',
      bytes: entry.length,
      startedAtMicros: startedAtMicros,
      equivalent: true,
      equivalentCandidatesChecked: candidatesChecked,
    );
    return true;
  }

  Future<bool> _tryBindExactReadyWithoutSessionRestore(
    DownloadSession session,
    PartialDownloadEntry entry, {
    TaskControl? control,
  }) async {
    final startedAtMicros = clock?.nowMicros();
    final totalLength = entry.totalLength ?? entry.length;
    if (entry.length <= 0 || totalLength != entry.length) return false;
    final openBoundReader = entry.openBoundRangeReader;
    if (openBoundReader == null) return false;

    PartialDownloadBoundRangeReader? boundReader;
    ArtifactCacheReadLease? lease;
    try {
      final scheduler = readScheduler;
      if (scheduler != null) {
        lease = await scheduler.acquire(
          priority: () => session.effectivePriority,
          control: control,
        );
      }
      boundReader = await openBoundReader();
    } on Object {
      boundReader = null;
    } finally {
      lease?.release();
    }
    control?.throwIfCancelled();
    final reader = boundReader;
    if (reader == null) return false;

    final List<int> prefix;
    try {
      prefix = await _readEntryPrefix(
        entry,
        boundReader: reader,
        priority: () => session.effectivePriority,
        control: control,
      );
    } on Object {
      try {
        await reader.close();
      } on Object {
        // Prefix metadata is required for the fast path. If it cannot be
        // proven, fall back to the ordinary restore path instead of binding a
        // promoted body whose content kind would remain permanently unknown.
      }
      return false;
    }

    final proof = _ExactDurableRestoreProof(
      id: session.id,
      epoch: session.epoch,
      length: entry.length,
    );
    _exactDurableRestoreProofs[session] = proof;
    try {
      session.bindResidentImmutableAuthority(
        validators: entry.validators,
        totalLength: totalLength,
        validatorRequestUri: session.id.canonicalUri,
        bodyAuthority: ByteResponseBodyAuthority.artifactCache,
        metadataPrefix: prefix,
        residentReplayRangeChunks: (start, endExclusive) async =>
            _openBoundRange(reader, start, endExclusive),
        residentReplayRangeClose: reader.close,
        residentReplayAccessMode: reader.accessMode,
      );
      boundReader = null;
    } on Object {
      _exactDurableRestoreProofs[session] = null;
      try {
        await reader.close();
      } on Object {
        // Preserve the bind failure.
      }
      rethrow;
    }
    _record(
      session,
      action: 'bound-ready-authority',
      bytes: entry.length,
      startedAtMicros: startedAtMicros,
    );
    return true;
  }

  Future<List<int>> _readEntryPrefix(
    PartialDownloadEntry entry, {
    PartialDownloadBoundRangeReader? boundReader,
    required int Function() priority,
    TaskControl? control,
    int maxBytes = 64,
  }) async {
    final exactPrefix = entry.openRange;
    final prefixEnd = maxBytes < entry.length ? maxBytes : entry.length;
    final iterator = StreamIterator<List<int>>(
      boundReader != null
          ? _openBoundRange(boundReader, 0, prefixEnd)
          : exactPrefix == null
              ? entry.open(start: 0)
              : exactPrefix(
                  start: 0,
                  endExclusive: prefixEnd,
                ),
    );
    final prefix = <int>[];
    try {
      while (prefix.length < maxBytes) {
        ArtifactCacheReadLease? lease;
        final bool available;
        try {
          if (readScheduler != null) {
            lease = await readScheduler!.acquire(
              priority: priority,
              control: control,
            );
          }
          available = await _moveNextCancellable(iterator, control);
        } finally {
          lease?.release();
        }
        if (!available) break;
        control?.throwIfCancelled();
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        final remaining = maxBytes - prefix.length;
        prefix.addAll(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
      }
    } finally {
      await iterator.cancel();
    }
    return prefix;
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
    var iteratorCleanupDetached = false;
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
          final moveNext = iterator.moveNext();
          final bool available;
          if (control == null) {
            available = await moveNext;
          } else {
            control.throwIfCancelled();
            try {
              available = await Future.any<bool>(<Future<bool>>[
                moveNext,
                control.whenCancelled.then<bool>((_) {
                  throw const Failure(
                    code: ErrorCode.cancelled,
                    message: 'partial download restore was cancelled',
                  );
                }),
              ]);
            } on Object catch (error, stackTrace) {
              if (control.cancelled) {
                // The consumer/session side of a preempted restore can retire
                // immediately, but the physical source read may still be
                // inside an uncancellable platform/file Future. Keep that
                // exact read quantum charged to ArtifactCacheReadScheduler
                // until it really settles, while transferring StreamIterator
                // cleanup to the detached drain. This frees the bounded local
                // preparation slot without pretending the underlying I/O has
                // already finished.
                final drainingLease = lease;
                lease = null;
                iteratorCleanupDetached = true;
                unawaited(
                  _drainCancelledRestoreRead(
                    session,
                    iterator,
                    moveNext,
                    drainingLease,
                    offset: offset,
                  ),
                );
                Error.throwWithStackTrace(error, stackTrace);
              }
              rethrow;
            }
          }
          if (!available) break;
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
      if (!iteratorCleanupDetached) {
        try {
          await iterator.cancel();
        } on Object catch (error, stackTrace) {
          if (primaryError == null) {
            Error.throwWithStackTrace(error, stackTrace);
          }
        }
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    return offset;
  }

  Future<void> _drainCancelledRestoreRead(
    DownloadSession session,
    StreamIterator<List<int>> iterator,
    Future<bool> moveNext,
    ArtifactCacheReadLease? lease, {
    required int offset,
  }) async {
    final startedAtMicros = clock?.nowMicros();
    try {
      _record(
        session,
        action: 'cancelled-read-draining',
        bytes: offset,
        startedAtMicros: startedAtMicros,
      );
    } on Object {
      // Diagnostics cannot own detached physical-I/O retirement.
    }
    try {
      Future<void>? cancel;
      try {
        cancel = iterator.cancel();
      } on Object {
        // A synchronous cleanup failure cannot resurrect a cancelled restore.
      }
      try {
        await moveNext;
      } on Object {
        // The restore cancellation already owns the consumer-visible result.
        // A late source error is only part of retiring this read quantum.
      }
      if (cancel != null) {
        try {
          await cancel;
        } on Object {
          // Likewise, async cleanup failure remains detached from the owner.
        }
      }
    } finally {
      lease?.release();
      try {
        _record(
          session,
          action: 'cancelled-read-drain-complete',
          bytes: offset,
          startedAtMicros: startedAtMicros,
        );
      } on Object {
        // Diagnostics cannot own detached physical-I/O retirement.
      }
    }
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
    final candidates = equivalentCandidates;
    if (candidates == null) {
      return _restoreExactCandidate(id, control: control);
    }
    final metadataStore = store is PartialDownloadMetadataStore
        ? store as PartialDownloadMetadataStore
        : null;
    if (metadataStore != null) {
      return _restoreCandidateByMetadata(
        id,
        candidates,
        metadataStore,
        control: control,
      );
    }
    return _restoreCandidateLegacy(
      id,
      candidates(id),
      control: control,
    );
  }

  Future<_PartialRestoreCandidate?> _restoreCandidateByMetadata(
    DownloadId id,
    PartialEquivalentCandidates candidates,
    PartialDownloadMetadataStore metadataStore, {
    TaskControl? control,
  }) async {
    final equivalentIds = <DownloadId>[];
    final seen = <DownloadId>{id};
    for (final equivalent in candidates(id)) {
      if (seen.add(equivalent)) equivalentIds.add(equivalent);
    }
    var checked = 0;
    var order = 0;
    final ranked = <_RankedPartialCandidate>[];

    final exactMetadata = await _awaitCancellable(
      metadataStore.inspectPartialDownloadMetadata(id),
      control,
    );
    if (exactMetadata != null && exactMetadata.length > 0) {
      if (exactMetadata.exactDurableFinal) {
        final entry = await _awaitCancellable(
          store.openPartialDownload(id),
          control,
        );
        if (entry != null && entry.length > 0) {
          if (entry.length != exactMetadata.length ||
              !entry.exactDurableFinal) {
            return _restoreCandidateLegacy(
              id,
              equivalentIds,
              control: control,
            );
          }
          return _PartialRestoreCandidate(
            entry: entry,
            equivalent: false,
            candidatesChecked: checked,
          );
        }
      } else {
        ranked.add(
          _RankedPartialCandidate(
            id: id,
            metadataLength: exactMetadata.length,
            equivalent: false,
            order: order++,
          ),
        );
      }
    }

    for (final equivalent in equivalentIds) {
      control?.throwIfCancelled();
      checked++;
      final metadata = await _awaitCancellable(
        metadataStore.inspectPartialDownloadMetadata(equivalent),
        control,
      );
      if (metadata == null || metadata.length <= 0) continue;
      if (metadata.exactDurableFinal) {
        // Exact is already known not to be READY, so one physically verified
        // READY equivalent outranks every incomplete partial without scanning
        // the remainder of a potentially wide direct-candidate set.
        final entry = await _awaitCancellable(
          store.openPartialDownload(equivalent),
          control,
        );
        if (entry == null || entry.length <= 0) continue;
        if (entry.length != metadata.length || !entry.exactDurableFinal) {
          return _restoreCandidateLegacy(
            id,
            equivalentIds,
            control: control,
          );
        }
        return _PartialRestoreCandidate(
          entry: entry,
          equivalent: true,
          candidatesChecked: checked,
        );
      }
      ranked.add(
        _RankedPartialCandidate(
          id: equivalent,
          metadataLength: metadata.length,
          equivalent: true,
          order: order++,
        ),
      );
    }

    ranked.sort((a, b) {
      final length = b.metadataLength.compareTo(a.metadataLength);
      if (length != 0) return length;
      if (a.equivalent != b.equivalent) return a.equivalent ? 1 : -1;
      return a.order.compareTo(b.order);
    });
    for (final candidate in ranked) {
      control?.throwIfCancelled();
      final entry = await _awaitCancellable(
        store.openPartialDownload(candidate.id),
        control,
      );
      if (entry == null || entry.length <= 0) continue;
      if (entry.length != candidate.metadataLength || entry.exactDurableFinal) {
        // Metadata is only a ranking hint. If the physical open disagrees,
        // rescan exact + direct equivalents using physical state as authority.
        return _restoreCandidateLegacy(
          id,
          equivalentIds,
          control: control,
        );
      }
      return _PartialRestoreCandidate(
        entry: entry,
        equivalent: candidate.equivalent,
        candidatesChecked: checked,
      );
    }
    return null;
  }

  Future<_PartialRestoreCandidate?> _restoreCandidateLegacy(
    DownloadId id,
    Iterable<DownloadId> candidates, {
    TaskControl? control,
  }) async {
    _PartialRestoreCandidate? selected;
    final exact = await _awaitCancellable(
      store.openPartialDownload(id),
      control,
    );
    if (exact != null && exact.length > 0) {
      if (exact.exactDurableFinal) {
        return _PartialRestoreCandidate(
          entry: exact,
          equivalent: false,
          candidatesChecked: 0,
        );
      }
      selected = _PartialRestoreCandidate(
        entry: exact,
        equivalent: false,
        candidatesChecked: 0,
      );
    }

    final seen = <DownloadId>{id};
    var checked = 0;
    for (final equivalent in candidates) {
      control?.throwIfCancelled();
      if (!seen.add(equivalent)) continue;
      checked++;
      final entry = await _awaitCancellable(
        store.openPartialDownload(equivalent),
        control,
      );
      if (entry == null || entry.length <= 0) continue;
      if (entry.exactDurableFinal) {
        return _PartialRestoreCandidate(
          entry: entry,
          equivalent: true,
          candidatesChecked: checked,
        );
      }
      if (selected == null || entry.length > selected.entry.length) {
        selected = _PartialRestoreCandidate(
          entry: entry,
          equivalent: true,
          candidatesChecked: checked,
        );
      }
    }
    if (selected == null) return null;
    return _PartialRestoreCandidate(
      entry: selected.entry,
      equivalent: selected.equivalent,
      candidatesChecked: checked,
    );
  }

  Future<_PartialRestoreCandidate?> _restoreExactCandidate(
    DownloadId id, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final exact = await _awaitCancellable(
      store.openPartialDownload(id),
      control,
    );
    if (exact == null || exact.length <= 0) return null;
    return _PartialRestoreCandidate(
      entry: exact,
      equivalent: false,
      candidatesChecked: 0,
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
    if (session.hasBorrowedDurableSpool) {
      await session.settleCacheMutations();
      _record(
        session,
        action: 'retained-adopted',
        bytes: session.committedLength,
        startedAtMicros: clock?.nowMicros(),
        reason: reason,
      );
      return true;
    }
    final length = session.artifact.committedLength;
    if (length <= 0) return true;
    final startedAtMicros = clock?.nowMicros();
    final targetId = session.id;
    try {
      final physicalStore = store;
      final storedPhysically = !session.physicalId.isExactFallback &&
          physicalStore is PhysicalPartialDownloadStore;
      if (storedPhysically) {
        await (physicalStore as PhysicalPartialDownloadStore)
            .storePhysicalPartialDownload(
          physicalId: session.physicalId,
          providerHint: targetId,
          entry: PartialDownloadEntry(
            length: length,
            // Validators are provider-scoped. A canonical physical prefix may
            // outlive this exact provider request, so only body length is
            // shared until a later exact request re-establishes continuity.
            validators: const Validators(),
            totalLength: session.totalLength,
            open: ({required int start}) => session.artifact.readChunks(
              start: start,
              endExclusive: length,
            ),
          ),
        );
      } else {
        await store.storePartialDownload(
          id: targetId,
          entry: PartialDownloadEntry(
            length: length,
            validators: session.resumeValidatorsFor(targetId.canonicalUri),
            totalLength: session.totalLength,
            open: ({required int start}) => session.artifact.readChunks(
              start: start,
              endExclusive: length,
            ),
          ),
        );
      }
      _record(
        session,
        action: storedPhysically ? 'stored-physical' : 'stored',
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

final class _ExactDurableRestoreProof {
  const _ExactDurableRestoreProof({
    required this.id,
    required this.epoch,
    required this.length,
  });

  final DownloadId id;
  final SourceEpoch epoch;
  final int length;
}

final class _RankedPartialCandidate {
  const _RankedPartialCandidate({
    required this.id,
    required this.metadataLength,
    required this.equivalent,
    required this.order,
  });

  final DownloadId id;
  final int metadataLength;
  final bool equivalent;
  final int order;
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
