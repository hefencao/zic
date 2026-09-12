import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
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

    // A chapter-owned exact READY body may bypass an empty deterministic
    // session artifact only after the Artifact owner itself proves that no
    // local partial/final body exists. This preserves the historical authority
    // order when both representations exist. The fast path additionally
    // requires a retained range reader, whose open includes the exact-length
    // physical proof; any miss/failure falls back to the complete restore path.
    _PartialRestoreCandidate? exactCandidate;
    var exactCandidateChecked = false;
    if (!await session.artifact.hasRestorableBody()) {
      control?.throwIfCancelled();
      exactCandidateChecked = true;
      exactCandidate = await _restoreExactCandidate(
        session.id,
        control: control,
      );
      final exactEntry = exactCandidate?.entry;
      if (exactEntry != null &&
          exactEntry.exactDurableFinal &&
          await _tryBindExactReadyWithoutSessionRestore(
            session,
            exactEntry,
            control: control,
          )) {
        return;
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
    final candidate = exactCandidate ??
        await _restoreCandidate(
          session.id,
          skipExact: exactCandidateChecked,
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
    bool skipExact = false,
    TaskControl? control,
  }) async {
    if (!skipExact) {
      final exact = await _restoreExactCandidate(id, control: control);
      if (exact != null) return exact;
    }
    final candidates = equivalentCandidates;
    if (candidates == null) return null;
    final metadataStore = store is PartialDownloadMetadataStore
        ? store as PartialDownloadMetadataStore
        : null;
    if (metadataStore != null) {
      return _restoreEquivalentCandidateByMetadata(
        id,
        candidates,
        metadataStore,
        control: control,
      );
    }
    return _restoreEquivalentCandidateLegacy(
      id,
      candidates(id),
      control: control,
    );
  }

  Future<_PartialRestoreCandidate?> _restoreEquivalentCandidateByMetadata(
    DownloadId id,
    PartialEquivalentCandidates candidates,
    PartialDownloadMetadataStore metadataStore, {
    TaskControl? control,
  }) async {
    final candidateIds = <DownloadId>[];
    final ranked = <_RankedPartialCandidate>[];
    var checked = 0;
    var order = 0;
    for (final equivalent in candidates(id)) {
      control?.throwIfCancelled();
      if (equivalent == id) continue;
      candidateIds.add(equivalent);
      checked++;
      final metadata = await _awaitCancellable(
        metadataStore.inspectPartialDownloadMetadata(equivalent),
        control,
      );
      if (metadata == null || metadata.length <= 0) {
        order++;
        continue;
      }
      if (metadata.exactDurableFinal) {
        final entry = await _awaitCancellable(
          store.openPartialDownload(equivalent),
          control,
        );
        if (entry == null || entry.length <= 0) {
          order++;
          continue;
        }
        if (entry.exactDurableFinal) {
          return _PartialRestoreCandidate(
            entry: entry,
            equivalent: true,
            candidatesChecked: checked,
          );
        }
        ranked.add(_RankedPartialCandidate(
          id: equivalent,
          metadataLength: entry.length,
          order: order,
          openedEntry: entry,
        ));
        order++;
        continue;
      }
      ranked.add(_RankedPartialCandidate(
        id: equivalent,
        metadataLength: metadata.length,
        order: order,
      ));
      order++;
    }
    ranked.sort((a, b) {
      final length = b.metadataLength.compareTo(a.metadataLength);
      return length != 0 ? length : a.order.compareTo(b.order);
    });
    for (final candidate in ranked) {
      control?.throwIfCancelled();
      final entry = candidate.openedEntry ??
          await _awaitCancellable(
            store.openPartialDownload(candidate.id),
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
      if (entry.length != candidate.metadataLength) {
        // The metadata snapshot changed while candidates were ranked. Fall
        // back to the historical physical-open scan so longest-prefix
        // selection remains authoritative under concurrent mutation.
        return _restoreEquivalentCandidateLegacy(
          id,
          candidateIds,
          control: control,
        );
      }
      return _PartialRestoreCandidate(
        entry: entry,
        equivalent: true,
        candidatesChecked: checked,
      );
    }
    return null;
  }

  Future<_PartialRestoreCandidate?> _restoreEquivalentCandidateLegacy(
    DownloadId id,
    Iterable<DownloadId> candidates, {
    TaskControl? control,
  }) async {
    PartialDownloadEntry? selected;
    var checked = 0;
    for (final equivalent in candidates) {
      control?.throwIfCancelled();
      if (equivalent == id) continue;
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
    required this.order,
    this.openedEntry,
  });

  final DownloadId id;
  final int metadataLength;
  final int order;
  final PartialDownloadEntry? openedEntry;
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
