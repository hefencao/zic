import 'dart:async';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_store.dart';
import 'partial_download_store.dart';
import 'resident_replay_reader_pool.dart';

typedef PartialDownloadHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);
typedef PartialEquivalentCandidates = Iterable<DownloadId> Function(
  DownloadId id,
);

/// Bridges an authoritative hot DownloadSession prefix to the chapter-owned
/// durable partial store. Physical transfer progress may checkpoint here, and
/// true hot-session retirement drains here as a final barrier. Reader route
/// detach/reentry never owns either decision: the physical session remains the
/// hot writer while this owner snapshots only committed bytes.
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
  final ResidentReplayReaderPool _residentReplayReaders =
      ResidentReplayReaderPool();
  final Map<DownloadSession, Future<bool>> _stores =
      <DownloadSession, Future<bool>>{};
  final Expando<_ExactDurableRestoreProof> _exactDurableRestoreProofs =
      Expando<_ExactDurableRestoreProof>('exact-durable-restore');
  final Expando<int> _durablePartialLengths =
      Expando<int>('durable-partial-length');

  int durablePartialLength(DownloadSession session) =>
      _durablePartialLengths[session] ?? 0;

  Future<void> close() => _residentReplayReaders.close();

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
    final restoreStartedAtMicros = clock?.nowMicros();
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

    // The recoverable owner probe is filesystem work too. Route it through the
    // same composition read scheduler as durable prefix/range reads so two
    // parallel local preparations cannot bypass actual foreground local-read
    // pressure with unscheduled stat/sidecar work. Keep the lease narrow: later canonical
    // lookup and prefix proof get their own ranked quanta instead of one long
    // foreground lease that would push every successor preparation into the
    // current frame's native decode window.
    final ownedProbeStartedAtMicros = clock?.nowMicros();
    await _withReadLease(
      session,
      () => session.restore(
        verifyPromotedChecksum: false,
        preferOwnedPartialCheckpoint: true,
        ownedCheckpointProbeOnly: true,
        control: control,
      ),
      control: control,
    );
    _recordRestoreStage(
      session,
      stage: 'owned-checkpoint-probe',
      startedAtMicros: ownedProbeStartedAtMicros,
      restoreStartedAtMicros: restoreStartedAtMicros,
      extra: <String, Object?>{
        'state': session.state.name,
        'committedLength': session.committedLength,
      },
    );
    control?.throwIfCancelled();
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength > 0) {
      return;
    }

    _PartialRestoreCandidate? durableCandidate;
    PartialDownloadEntry? physicalPartial;
    if (!session.physicalId.isExactFallback && cache != null) {
      final requiresBoundReplay = cache.supportsPhysicalArtifactBoundReplay;
      final physicalOpenStartedAtMicros = clock?.nowMicros();
      var physical = requiresBoundReplay
          ? await cache.openPhysicalArtifactForBoundReplay(session.physicalId)
          : await cache.openPhysicalArtifact(session.physicalId);
      _recordRestoreStage(
        session,
        stage: 'physical-artifact-open',
        startedAtMicros: physicalOpenStartedAtMicros,
        restoreStartedAtMicros: restoreStartedAtMicros,
        extra: <String, Object?>{
          'hit': physical != null,
          'boundReplayLookup': requiresBoundReplay,
          if (physical != null) 'accessMode': physical.accessMode,
          if (physical != null) 'bytes': physical.length,
        },
      );
      var recoveredHistoricalBinding = false;
      if (physical == null) {
        final historicalBindStartedAtMicros = clock?.nowMicros();
        recoveredHistoricalBinding =
            await cache.bindPhysicalArtifactFromCandidates(
          physicalId: session.physicalId,
          candidates: <DownloadId>[
            session.id,
            ...?equivalentCandidates?.call(session.id),
          ],
        );
        _recordRestoreStage(
          session,
          stage: 'physical-artifact-historical-bind',
          startedAtMicros: historicalBindStartedAtMicros,
          restoreStartedAtMicros: restoreStartedAtMicros,
          extra: <String, Object?>{'bound': recoveredHistoricalBinding},
        );
        control?.throwIfCancelled();
        if (recoveredHistoricalBinding) {
          final reboundOpenStartedAtMicros = clock?.nowMicros();
          physical = requiresBoundReplay
              ? await cache.openPhysicalArtifactForBoundReplay(session.physicalId)
              : await cache.openPhysicalArtifact(session.physicalId);
          _recordRestoreStage(
            session,
            stage: 'physical-artifact-reopen-after-bind',
            startedAtMicros: reboundOpenStartedAtMicros,
            restoreStartedAtMicros: restoreStartedAtMicros,
            extra: <String, Object?>{
              'hit': physical != null,
              'boundReplayLookup': requiresBoundReplay,
              if (physical != null) 'accessMode': physical.accessMode,
              if (physical != null) 'bytes': physical.length,
            },
          );
        }
      }
      control?.throwIfCancelled();
      if (physical != null) {
        final readyBindStartedAtMicros = clock?.nowMicros();
        final boundReady = await _tryBindResidentReadyAuthority(
            session,
            _physicalArtifactEntry(physical),
            candidatesChecked: 0,
            control: control,
            requireBoundReader: requiresBoundReplay,
          );
        _recordRestoreStage(
          session,
          stage: 'physical-ready-bind',
          startedAtMicros: readyBindStartedAtMicros,
          restoreStartedAtMicros: restoreStartedAtMicros,
          extra: <String, Object?>{
            'bound': boundReady,
            'accessMode': physical.accessMode,
          },
        );
        if (boundReady) return;
        if (requiresBoundReplay) {
          // The optimized lookup deliberately deferred provider validation to
          // the retained descriptor open. If that operation cannot establish
          // a bound reader, run the historical fully-preflighted path once so
          // stale-replica cleanup and generic range fallback stay unchanged.
          final fallbackOpenStartedAtMicros = clock?.nowMicros();
          physical = await cache.openPhysicalArtifact(session.physicalId);
          _recordRestoreStage(
            session,
            stage: 'physical-artifact-fallback-open',
            startedAtMicros: fallbackOpenStartedAtMicros,
            restoreStartedAtMicros: restoreStartedAtMicros,
            extra: <String, Object?>{
              'hit': physical != null,
              if (physical != null) 'accessMode': physical.accessMode,
              if (physical != null) 'bytes': physical.length,
            },
          );
          if (physical != null &&
              await _tryBindResidentReadyAuthority(
                session,
                _physicalArtifactEntry(physical),
                candidatesChecked: 0,
                control: control,
              )) {
            return;
          }
        }
      }
    }
    // The probe above already falls through to generic restore when any
    // deterministic final/partial body exists but lacks a valid owned
    // checkpoint. Reaching here therefore proves there is no session-local
    // body to recover; do not materialize an empty writable staging artifact
    // before consulting canonical durable authorities.
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
    if (candidate == null) {
      // Historical URI reuse is intentionally weaker than verified
      // equivalence, but once the cache-trust policy admits one sealed READY
      // carrier it is still an immutable local authority. Bind that authority
      // directly instead of falling through to ArtifactCacheTransport, where
      // DownloadJob would consume the whole body merely to promote a
      // body-empty resident session and presentation would then reopen the
      // same immutable bytes a second time.
      //
      // Keep this after exact/partial/verified-equivalent restore so an older
      // URI can never displace stronger current-generation evidence. The
      // transport path remains the correctness fallback when a resident range
      // authority cannot be established here.
      final historical = cache == null
          ? null
          : await cache.lookupHistoricalCarrier(
              session.id,
              control: control,
            );
      control?.throwIfCancelled();
      if (historical != null &&
          historical.lookup.durable &&
          await _tryBindResidentReadyAuthority(
            session,
            _physicalArtifactEntry(historical.lookup.entry),
            candidatesChecked: 0,
            control: control,
            historicalCarrier: true,
          )) {
        cache!.noteHistoricalCarrierServed(
          session.id,
          storageId: historical.lookup.storageId,
          generation: historical.lookup.generation,
        );
        return;
      }
      return;
    }
    if (candidate.entry.length <= 0) return;
    final entry = candidate.entry;

    if (candidate.equivalent &&
        entry.exactDurableFinal &&
        await _tryBindResidentReadyAuthority(
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
      if (entry.openBoundRangeReader != null) {
        try {
          boundReader = (await _openReadyBoundReader(
            session,
            entry,
            control: control,
          ))
              .reader;
        } on Object {
          // Descriptor reuse is an optimization. The stateless exact-range
          // authority below remains the correctness fallback.
          boundReader = null;
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
          residentReplayCacheKey: _residentReplayCacheKey(session, entry),
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
        sealedChecksum: entry.sealedChecksum,
        sealedChecksumAlgorithm: entry.sealedChecksumAlgorithm,
        exactDurableFinal: true,
      );

  ResidentReplayGenerationKey? _residentReplayCacheKey(
    DownloadSession session,
    PartialDownloadEntry entry,
  ) {
    if (!entry.exactDurableFinal || entry.length <= 0) return null;
    final checksum = entry.sealedChecksum?.trim().toLowerCase();
    final algorithm = entry.sealedChecksumAlgorithm?.trim().toLowerCase();
    if (checksum == null || checksum.isEmpty ||
        algorithm == null || algorithm.isEmpty) {
      return null;
    }
    return ResidentReplayGenerationKey(
      physicalMediaKey: session.physicalId.key,
      length: entry.length,
      checksumAlgorithm: algorithm,
      checksum: checksum,
    );
  }

  Future<({
    PartialDownloadBoundRangeReader? reader,
    bool poolHit,
    int schedulerWaitMicros,
    int providerOpenMicros,
    int schedulerActiveAtRequest,
    int schedulerForegroundAtRequest,
    int schedulerBackgroundAtRequest,
    int schedulerPendingAtRequest,
  })> _openReadyBoundReader(
    DownloadSession session,
    PartialDownloadEntry entry, {
    TaskControl? control,
  }) async {
    final openBoundReader = entry.openBoundRangeReader;
    if (openBoundReader == null) {
      return (
        reader: null,
        poolHit: false,
        schedulerWaitMicros: 0,
        providerOpenMicros: 0,
        schedulerActiveAtRequest: 0,
        schedulerForegroundAtRequest: 0,
        schedulerBackgroundAtRequest: 0,
        schedulerPendingAtRequest: 0,
      );
    }
    var schedulerWaitMicros = 0;
    var providerOpenMicros = 0;
    var schedulerActiveAtRequest = 0;
    var schedulerForegroundAtRequest = 0;
    var schedulerBackgroundAtRequest = 0;
    var schedulerPendingAtRequest = 0;
    Future<PartialDownloadBoundRangeReader?> openProvider() async {
      ArtifactCacheReadLease? lease;
      try {
        final scheduler = readScheduler;
        if (scheduler != null) {
          schedulerActiveAtRequest = scheduler.activeCount;
          schedulerForegroundAtRequest = scheduler.activeForegroundCount;
          schedulerBackgroundAtRequest = scheduler.activeBackgroundCount;
          schedulerPendingAtRequest = scheduler.pendingCount;
          final waitStarted = clock?.nowMicros();
          lease = await scheduler.acquire(
            priority: () => session.effectivePriority,
            control: control,
          );
          final acquired = clock?.nowMicros();
          if (waitStarted != null && acquired != null) {
            schedulerWaitMicros =
                (acquired - waitStarted).clamp(0, 1 << 62).toInt();
          }
        }
        final providerStarted = clock?.nowMicros();
        final reader = await openBoundReader();
        final providerFinished = clock?.nowMicros();
        if (providerStarted != null && providerFinished != null) {
          providerOpenMicros =
              (providerFinished - providerStarted).clamp(0, 1 << 62).toInt();
        }
        return reader;
      } finally {
        lease?.release();
      }
    }

    final replayKey = _residentReplayCacheKey(session, entry);
    if (replayKey != null) {
      final lease = await _residentReplayReaders.acquire(
        replayKey,
        openProvider,
      );
      return (
        reader: lease?.reader,
        poolHit: lease?.reused ?? false,
        schedulerWaitMicros: schedulerWaitMicros,
        providerOpenMicros: providerOpenMicros,
        schedulerActiveAtRequest: schedulerActiveAtRequest,
        schedulerForegroundAtRequest: schedulerForegroundAtRequest,
        schedulerBackgroundAtRequest: schedulerBackgroundAtRequest,
        schedulerPendingAtRequest: schedulerPendingAtRequest,
      );
    }
    return (
      reader: await openProvider(),
      poolHit: false,
      schedulerWaitMicros: schedulerWaitMicros,
      providerOpenMicros: providerOpenMicros,
      schedulerActiveAtRequest: schedulerActiveAtRequest,
      schedulerForegroundAtRequest: schedulerForegroundAtRequest,
      schedulerBackgroundAtRequest: schedulerBackgroundAtRequest,
      schedulerPendingAtRequest: schedulerPendingAtRequest,
    );
  }

  Future<bool> _tryBindResidentReadyAuthority(
    DownloadSession session,
    PartialDownloadEntry entry, {
    required int candidatesChecked,
    TaskControl? control,
    bool requireBoundReader = false,
    bool historicalCarrier = false,
  }) async {
    final startedAtMicros = clock?.nowMicros();
    final totalLength = entry.totalLength ?? entry.length;
    if (!entry.exactDurableFinal ||
        entry.length <= 0 ||
        totalLength != entry.length) {
      return false;
    }

    PartialDownloadBoundRangeReader? boundReader;
    final boundReaderOpenStartedAtMicros = clock?.nowMicros();
    var poolHit = false;
    var schedulerWaitMicros = 0;
    var boundReaderProviderOpenMicros = 0;
    var schedulerActiveAtRequest = 0;
    var schedulerForegroundAtRequest = 0;
    var schedulerBackgroundAtRequest = 0;
    var schedulerPendingAtRequest = 0;
    if (entry.openBoundRangeReader != null) {
      try {
        final opened = await _openReadyBoundReader(
          session,
          entry,
          control: control,
        );
        boundReader = opened.reader;
        poolHit = opened.poolHit;
        schedulerWaitMicros = opened.schedulerWaitMicros;
        boundReaderProviderOpenMicros = opened.providerOpenMicros;
        schedulerActiveAtRequest = opened.schedulerActiveAtRequest;
        schedulerForegroundAtRequest = opened.schedulerForegroundAtRequest;
        schedulerBackgroundAtRequest = opened.schedulerBackgroundAtRequest;
        schedulerPendingAtRequest = opened.schedulerPendingAtRequest;
      } on Object {
        // Retained descriptor reuse is an optimization. The verified durable
        // range authority below remains the correctness fallback.
        boundReader = null;
      }
    }
    _recordRestoreStage(
      session,
      stage: 'ready-bound-reader-open',
      startedAtMicros: boundReaderOpenStartedAtMicros,
      restoreStartedAtMicros: startedAtMicros,
      extra: <String, Object?>{
        'bound': boundReader != null,
        if (boundReader != null) 'accessMode': boundReader.accessMode,
        'residentReaderPoolHit': poolHit,
        'schedulerWaitMicros': schedulerWaitMicros,
        'boundReaderProviderOpenMicros': boundReaderProviderOpenMicros,
        'schedulerActiveAtRequest': schedulerActiveAtRequest,
        'schedulerForegroundAtRequest': schedulerForegroundAtRequest,
        'schedulerBackgroundAtRequest': schedulerBackgroundAtRequest,
        'schedulerPendingAtRequest': schedulerPendingAtRequest,
      },
    );
    control?.throwIfCancelled();
    if (requireBoundReader && boundReader == null) return false;

    final prefixReadStartedAtMicros = clock?.nowMicros();
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
    _recordRestoreStage(
      session,
      stage: 'ready-metadata-prefix-read',
      startedAtMicros: prefixReadStartedAtMicros,
      restoreStartedAtMicros: startedAtMicros,
      extra: <String, Object?>{'bytes': prefix.length},
    );
    control?.throwIfCancelled();

    final openRange = entry.openRange;
    final reader = boundReader;
    if (reader == null && openRange == null) return false;
    final bindPublishStartedAtMicros = clock?.nowMicros();
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
        residentReplayCacheKey: _residentReplayCacheKey(session, entry),
      );
      boundReader = null; // DownloadSession now owns the retained reader lease.
      _recordRestoreStage(
        session,
        stage: 'ready-resident-bind-publish',
        startedAtMicros: bindPublishStartedAtMicros,
        restoreStartedAtMicros: startedAtMicros,
        extra: <String, Object?>{
          'metadataPrefixBytes': prefix.length,
          'residentReaderPoolHit': poolHit,
        },
      );
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
      action: historicalCarrier
          ? 'bound-historical-ready-authority'
          : 'bound-ready-authority',
      bytes: entry.length,
      startedAtMicros: startedAtMicros,
      equivalent: !historicalCarrier,
      equivalentCandidatesChecked: candidatesChecked,
    );
    return true;
  }

  Future<T> _withReadLease<T>(
    DownloadSession session,
    Future<T> Function() operation, {
    TaskControl? control,
  }) async {
    ArtifactCacheReadLease? lease;
    final scheduler = readScheduler;
    if (scheduler != null) {
      lease = await scheduler.acquire(
        priority: () => session.effectivePriority,
        control: control,
      );
    }
    try {
      return await operation();
    } finally {
      lease?.release();
    }
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
    if (session.hasBorrowedPartialBacking) {
      final checkpointLength = await session.checkpointPartialCache();
      if (checkpointLength <= 0) {
        await session.settleCacheMutations();
        return true;
      }
      _durablePartialLengths[session] = checkpointLength;
      _record(
        session,
        action: 'retained-adopted',
        bytes: checkpointLength,
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
          // Mutable transfer checkpoints prefer App-private Direct staging.
          // Final/manual placement remains a separate promoted-artifact step.
          preferDirectStaging: true,
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
      _durablePartialLengths[session] = length;
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

  void _recordRestoreStage(
    DownloadSession session, {
    required String stage,
    required int? startedAtMicros,
    required int? restoreStartedAtMicros,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    final sourceClock = clock;
    if (sourceClock == null || startedAtMicros == null) return;
    final now = sourceClock.nowMicros();
    traceSink.record(traceEvent(
      clock: sourceClock,
      sessionId: sessionId,
      kind: TraceEventKind.artifactSource,
      identityHash: session.id.key,
      payload: <String, Object?>{
        'source': 'session-partial-handoff',
        'consumer': 'durable-partial',
        'action': 'restore-stage',
        'stage': stage,
        'stageMicros': (now - startedAtMicros).clamp(0, 1 << 62).toInt(),
        if (restoreStartedAtMicros != null)
          'restoreElapsedMicros':
              (now - restoreStartedAtMicros).clamp(0, 1 << 62).toInt(),
        ...extra,
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
