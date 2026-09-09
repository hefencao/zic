import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'partial_download_handoff.dart';
import 'partial_download_store.dart';
import 'physical_transfer_retention.dart';
import 'promoted_artifact_cache_handoff.dart';
import 'version_page_authority.dart';

/// Composition-level owner for physical image transfer state.
///
/// Reader sessions, prefetch and explicit download commands attach consumers;
/// none of those consumers owns the physical [DownloadRegistry], writer,
/// retry state or hot partial. Durable immutable artifacts remain owned by
/// [ArtifactCacheManager], and cold partials remain owned by
/// [PartialDownloadStore].
final class CompositionDownloadTransferRuntime {
  CompositionDownloadTransferRuntime({
    required this.artifactCacheManager,
    required this.partialDownloadStore,
    required this.net,
    ArtifactCacheReadScheduler? localReadScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
    EphemeralCacheWorkspace? transferWorkspace,
    this.readStallTimeout = DownloadJob.defaultReadStallTimeout,
    this.maxIdlePromotedSessions = 8,
    this.maxIdlePartialSessions = 32,
    this.maxIdlePartialBytes = 256 * 1024 * 1024,
    VersionPageAuthority? versionPageAuthority,
  })  : versionPageAuthority = versionPageAuthority ?? VersionPageAuthority(),
        localReadScheduler =
            localReadScheduler ?? ArtifactCacheReadScheduler(),
        speculativeEncodedReadBudget =
            speculativeEncodedReadBudget ?? SpeculativeEncodedReadBudget(),
        clock = const SystemClock(),
        traceHub = _CompositionTransferTraceHub(),
        workspace = transferWorkspace ??
            EphemeralCacheWorkspace.readerSession(
              'composition-transfer-${++_sequence}',
            ) {
    final cache = artifactCacheManager;
    final partialStore = partialDownloadStore;
    if (partialStore != null) {
      partialDownloadHandoff = PartialDownloadHandoff(
        store: partialStore,
        equivalentCandidates: cache?.directEquivalents,
        persistTarget: this.versionPageAuthority.resolve,
        onError: (error, stackTrace) {},
        clock: clock,
        readScheduler: localReadScheduler,
        traceSink: traceHub,
        sessionId: 'composition-transfer-owner',
      );
    }
    if (cache != null) {
      artifactCacheHandoff = PromotedArtifactCacheHandoff(
        cache: cache,
        onError: (error, stackTrace) {},
        clock: clock,
        traceSink: traceHub,
        sessionId: 'composition-transfer-owner',
        residentReplaySource: (session, endExclusive) => owner.openResidentReplay(
          session.id,
          endExclusive: endExclusive,
        ),
        defaultTarget: (session) => this.versionPageAuthority.resolve(session.id),
        requiredExactTargets: (session) => owner
            .requiredExactDurableTargets(session.id)
            .map(this.versionPageAuthority.resolve)
            .toSet(),
        exactDurableRestoreProof: partialDownloadHandoff?.provesExactDurableBody,
      );
    }
    registry = DownloadRegistry(
      layout: workspace.layout,
      clock: clock,
      traceSink: traceHub,
      onSessionCreated: (session) {
        artifactCacheHandoff?.observe(session);
        _physicalTransferRetention?.observe(session);
      },
    );
    owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      prepareDownload: partialDownloadHandoff?.restoreInto,
      prepareDownloadWithControl: partialDownloadHandoff == null
          ? null
          : (session, {required control}) =>
              partialDownloadHandoff!.restoreInto(
                session,
                control: control,
              ),
      net: net,
      resolveTransferId: _resolveTransferIdForAcquire,
      speculativeEncodedReadBudget: this.speculativeEncodedReadBudget,
      readStallTimeout: readStallTimeout,
    );
    _physicalTransferRetention = PhysicalTransferRetention(
      registry: registry,
      owner: owner,
      clock: clock,
      traceSink: traceHub,
      artifactHandoff: artifactCacheHandoff,
      partialHandoff: partialDownloadHandoff,
      maxIdlePromotedSessions: maxIdlePromotedSessions,
      maxIdlePartialSessions: maxIdlePartialSessions,
      maxIdlePartialBytes: maxIdlePartialBytes,
    );
  }

  static int _sequence = 0;

  final ArtifactCacheManager? artifactCacheManager;
  final VersionPageAuthority versionPageAuthority;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler localReadScheduler;
  final SpeculativeEncodedReadBudget speculativeEncodedReadBudget;
  final Duration readStallTimeout;
  final int maxIdlePromotedSessions;
  final int maxIdlePartialSessions;
  final int maxIdlePartialBytes;
  final MonoClock clock;
  final _CompositionTransferTraceHub traceHub;
  final EphemeralCacheWorkspace workspace;
  PromotedArtifactCacheHandoff? artifactCacheHandoff;
  PartialDownloadHandoff? partialDownloadHandoff;
  PhysicalTransferRetention? _physicalTransferRetention;
  late final DownloadRegistry registry;
  late final DownloadTransferOwner owner;
  bool _disposed = false;

  bool get disposed => _disposed;
  bool get hasConsumers => owner.consumers.isNotEmpty;

  DownloadId canonicalOwnerFor(DownloadId id) => versionPageAuthority.resolve(id);

  DownloadId _resolveTransferIdForAcquire(DownloadId exactId) {
    final canonicalId = versionPageAuthority.resolve(exactId);
    final resolvedCanonical = registry.resolvePhysicalId(canonicalId);
    if (resolvedCanonical != canonicalId) return resolvedCanonical;
    final resolvedExact = registry.resolvePhysicalId(exactId);
    if (resolvedExact != exactId) return resolvedExact;

    if (canonicalId != exactId) {
      final canonicalSession = registry.findExact(canonicalId);
      if (canonicalSession != null) {
        registry.aliasPhysical(id: exactId, target: canonicalId);
        _recordAcquireAlias(
          exactId,
          action: 'joined-canonical-owner',
          candidate: canonicalId,
          session: canonicalSession,
        );
        return canonicalId;
      }
      final exactSession = registry.findExact(exactId);
      if (exactSession != null && _canJoinEquivalentSession(exactSession)) {
        // A relation can be discovered after an older physical carrier already
        // exists. Keep the active carrier stable, but bind the newer canonical
        // logical owner to it so future claims converge before persistence.
        registry.aliasPhysical(id: canonicalId, target: exactId);
        _recordAcquireAlias(
          canonicalId,
          action: 'canonical-owner-adopted-existing-carrier',
          candidate: exactId,
          session: exactSession,
        );
        return exactId;
      }
      if (exactSession == null) {
        return canonicalId;
      }
      return exactId;
    }

    if (registry.findExact(exactId) != null) return exactId;
    final cache = artifactCacheManager;
    if (cache == null) return exactId;

    final candidates = <DownloadId, DownloadSession>{};
    for (final equivalent in cache.directEquivalents(exactId)) {
      final physicalId = registry.resolvePhysicalId(equivalent);
      final session = registry.find(physicalId);
      if (session == null || !_canJoinEquivalentSession(session)) continue;
      candidates[physicalId] = session;
    }
    if (candidates.isEmpty) return exactId;
    final ordered = candidates.entries.toList(growable: false)
      ..sort(_compareEquivalentPhysicalCandidates);
    final selected = ordered.first;
    registry.aliasPhysical(id: exactId, target: selected.key);
    _recordAcquireAlias(
      exactId,
      action: 'joined-existing-physical',
      candidate: selected.key,
      session: selected.value,
      candidateOwners: ordered.length,
    );
    return selected.key;
  }

  void _recordAcquireAlias(
    DownloadId exactId, {
    required String action,
    required DownloadId candidate,
    DownloadSession? session,
    int candidateOwners = 1,
  }) {
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: exactId.key,
          payload: <String, Object?>{
            'stage': 'verified-transfer-acquire-alias',
            'action': action,
            'physicalToken': workspace.layout.tokenFor(candidate),
            if (session != null) 'physicalState': session.state.name,
            if (session != null)
              'physicalCommittedLength': session.committedLength,
            'candidateOwners': candidateOwners,
            'selection': candidateOwners > 1
                ? 'preferred-existing-owner'
                : 'unique-existing-owner',
            'phase': 'acquire-before-physical-session',
          },
        ),
      );
    } on Object {
      // Identity diagnostics must never alter physical acquisition.
    }
  }

  int _compareEquivalentPhysicalCandidates(
    MapEntry<DownloadId, DownloadSession> left,
    MapEntry<DownloadId, DownloadSession> right,
  ) {
    final authority = _physicalReuseAuthority(right.value)
        .compareTo(_physicalReuseAuthority(left.value));
    if (authority != 0) return authority;
    final committed = right.value.committedLength
        .compareTo(left.value.committedLength);
    if (committed != 0) return committed;
    final demand = right.value.demandCount.compareTo(left.value.demandCount);
    if (demand != 0) return demand;
    final priority = right.value.effectivePriority
        .compareTo(left.value.effectivePriority);
    if (priority != 0) return priority;
    return left.key.key.compareTo(right.key.key);
  }

  int _physicalReuseAuthority(DownloadSession session) {
    if (session.state == DownloadState.promoted) return 4;
    if (session.hasWriter ||
        session.activeRun ||
        session.state == DownloadState.receiving) {
      return 3;
    }
    if (session.demanded || session.state == DownloadState.queued) return 2;
    if (session.committedLength > 0) return 1;
    return 0;
  }

  bool _canJoinEquivalentSession(DownloadSession session) {
    if (session.state == DownloadState.disposed) return false;
    if (session.residentBodyBacked &&
        session.residentBodyAuthority !=
            ByteResponseBodyAuthority.artifactCache) {
      // A source-resident body has no physical encoded copy to replay through
      // another version safely. Keep it exact until durable cache authority
      // exists; hot/session artifacts can share immediately.
      return false;
    }
    return session.demanded ||
        session.activeRun ||
        session.hasWriter ||
        session.committedLength > 0 ||
        session.state == DownloadState.promoted;
  }

  /// Whether [id] currently resolves to physical encoded state that a newly
  /// verified equivalent identity may safely join at acquire time.
  ///
  /// Keep this query on the transfer runtime so version-reuse preparation and
  /// `_resolveTransferIdForAcquire` share the same resident-body authority
  /// rules instead of duplicating session-state heuristics in the App layer.
  bool hasReusableEquivalentPhysicalState(DownloadId id) {
    final session = registry.find(id);
    return session != null && _canJoinEquivalentSession(session);
  }

  DownloadTransferConsumer attachConsumer({
    required String scopeId,
    required TransferTransportPick transportFor,
    TransferRetainedTransportPick? retainedTransportFor,
    required TraceSink consumerTraceSink,
    TraceSink? localPhysicalTraceSink,
    TraceSink? sharedPhysicalTraceSink,
    RetryPolicy retry = const RetryPolicy(),
    String Function(DownloadId id)? downloadBucketFor,
    int Function(DownloadId id)? downloadBucketLimitFor,
  }) {
    if (_disposed) {
      throw StateError('composition transfer runtime is disposed');
    }
    if (localPhysicalTraceSink != null) {
      traceHub.attach(localPhysicalTraceSink);
    }
    if (sharedPhysicalTraceSink != null) {
      traceHub.attach(sharedPhysicalTraceSink);
    }
    return owner.attachConsumer(
      scopeId: scopeId,
      transportFor: transportFor,
      retainedTransportFor: retainedTransportFor,
      traceSink: consumerTraceSink,
      retry: retry,
      downloadBucketFor: downloadBucketFor,
      downloadBucketLimitFor: downloadBucketLimitFor,
    );
  }

  void detachPhysicalTrace({
    TraceSink? localPhysicalTraceSink,
    TraceSink? sharedPhysicalTraceSink,
  }) {
    if (localPhysicalTraceSink != null) {
      traceHub.detach(localPhysicalTraceSink);
    }
    if (sharedPhysicalTraceSink != null) {
      traceHub.detach(sharedPhysicalTraceSink);
    }
  }

  Future<Uint8List> readArtifact(Artifact artifact) =>
      workspace.readArtifact(artifact);

  /// Invalidates the exact byte authority rejected by presentation and
  /// reopens the same demanded physical transfer as a fresh epoch. The
  /// rejected storage identity/generation comes from the actual cache read; a
  /// late failure from an older generation must never delete a newer artifact.
  Future<bool> recoverPresentationArtifact(
    DownloadId id, {
    required String reason,
    bool userInitiated = false,
    DownloadId? rejectedStorageId,
    int? rejectedGeneration,
  }) async {
    if (_disposed) return false;
    final cache = artifactCacheManager;
    final rejectedAuthorityKnown =
        rejectedStorageId != null && rejectedGeneration != null;
    if (cache != null &&
        rejectedAuthorityKnown &&
        cache.generationFor(rejectedStorageId) != rejectedGeneration) {
      _recordPresentationRecoveryTrace(
        id: id,
        storageId: rejectedStorageId,
        reason: reason,
        action: 'stale-generation-reload',
      );
      return true;
    }

    var storageId = rejectedStorageId;
    var generation = rejectedGeneration;
    if (cache != null && storageId == null) {
      final lookup = await cache.lookup(id);
      storageId = lookup?.storageId ?? id;
      generation = lookup?.generation ?? cache.generationFor(storageId);
    }
    storageId ??= id;
    int? freshSourceRecoveryGroup;

    return owner.recoverPresentationArtifact(
      id,
      invalidateArtifact: () async {
        var invalidated = true;
        if (cache != null) {
          final expectedGeneration = generation;
          if (expectedGeneration == null) {
            await cache.invalidate(storageId!);
          } else {
            invalidated = await cache.invalidateIfGeneration(
              storageId!,
              expectedGeneration: expectedGeneration,
            );
          }
        }
        if (invalidated && cache != null) {
          freshSourceRecoveryGroup = cache.beginFreshSourceRecovery(<DownloadId>{
            id,
            registry.resolvePhysicalId(id),
          });
        }
        _recordPresentationRecoveryTrace(
          id: id,
          storageId: storageId!,
          reason: reason,
          action: invalidated
              ? (userInitiated ? 'manual-retry' : 'automatic-retry')
              : 'stale-generation-reload',
        );
        return invalidated;
      },
      afterPhysicalReset: () async {
        final group = freshSourceRecoveryGroup;
        if (group != null) cache?.armFreshSourceRecovery(group);
      },
    );
  }

  void _recordPresentationRecoveryTrace({
    required DownloadId id,
    required DownloadId storageId,
    required String reason,
    required String action,
  }) {
    try {
      traceHub.record(
        traceEvent(
          clock: clock,
          sessionId: 'composition-transfer-owner',
          kind: TraceEventKind.artifactSource,
          identityHash: id.key,
          payload: <String, Object?>{
            'stage': 'presentation-artifact-recovery',
            'action': action,
            'reason': reason,
            if (storageId != id) 'storageIdentityHash': storageId.key,
          },
        ),
      );
    } on Object {
      // Recovery diagnostics must never alter cache/session authority.
    }
  }

  /// Returns the composition-owned resident-body replay service for one
  /// consumer. Storage/source backend selection stays here; consumers supply
  /// only a dynamic priority projection for the shared local-read scheduler.
  DownloadResidentReplaySource residentReplaySource({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, endExclusive) => _openResidentReplay(
            session,
            0,
            endExclusive,
            priority: () => priorityFor(session.id),
          );

  DownloadResidentReplaySourceWithControl residentReplaySourceWithControl({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, endExclusive, {required control}) => _openResidentReplay(
            session,
            0,
            endExclusive,
            priority: () => priorityFor(session.id),
            control: control,
          );

  DownloadResidentReplayRangeSource residentReplayRangeSource({
    required int Function(DownloadId id) priorityFor,
  }) =>
      (session, start, endExclusive) => _openResidentReplay(
            session,
            start,
            endExclusive,
            priority: () => priorityFor(session.id),
          );

  DownloadResidentReplayRangeSourceWithControl
      residentReplayRangeSourceWithControl({
    required int Function(DownloadId id) priorityFor,
  }) =>
          (session, start, endExclusive, {required control}) =>
              _openResidentReplay(
                session,
                start,
                endExclusive,
                priority: () => priorityFor(session.id),
                control: control,
              );

  Future<Stream<List<int>>> _openResidentReplay(
    DownloadSession session,
    int start,
    int endExclusive, {
    required int Function() priority,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    int replayPriority() {
      final controlled = control?.priority;
      if (controlled != null) return controlled;
      final physical = session.effectivePriority;
      return physical > 0 ? physical : priority();
    }
    if (_disposed) {
      throw StateError('composition transfer runtime is disposed');
    }
    if (!identical(registry.find(session.id), session)) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'resident replay requires the current physical session',
      );
    }
    if (start < 0 ||
        endExclusive <= start ||
        endExclusive > session.committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'invalid resident replay range $start..$endExclusive/'
            '${session.committedLength}',
      );
    }

    final boundReplay = session.residentReplayRangeChunks;
    if (boundReplay != null) {
      return _scheduledResidentReplay(
        _boundedResidentReplay(
          boundReplay,
          start,
          endExclusive,
          control: control,
        ),
        priority: replayPriority,
        control: control,
        allowBackgroundDuringForegroundPressure:
            session.residentReplayAccessMode != 'saf',
      );
    }

    final cache = artifactCacheManager;
    if (cache != null) {
      final lookup = await cache.lookup(session.id, control: control);
      control?.throwIfCancelled();
      if (lookup != null) {
        final expectedTotal = session.totalLength;
        if ((expectedTotal == null || lookup.entry.length == expectedTotal) &&
            lookup.entry.length >= endExclusive) {
          return _scheduledResidentReplay(
            lookup.entry.open(
              start: start,
              endExclusive: endExclusive,
            ),
            priority: replayPriority,
            control: control,
            allowBackgroundDuringForegroundPressure:
                lookup.entry.accessMode != 'saf',
          );
        }
      }
    }

    final scheme = session.id.canonicalUri.scheme.toLowerCase();
    if (scheme != 'file' && scheme != 'content' && scheme != 'asset') {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident encoded-byte replay authority is unavailable for '
            '${session.id.key}',
      );
    }
    final chunks = await owner.openResidentReplay(
      session.id,
      start: start,
      endExclusive: endExclusive,
      control: control,
    );
    return _scheduledResidentReplay(
      chunks,
      priority: replayPriority,
      control: control,
    );
  }

  Stream<List<int>> _boundedResidentReplay(
    DownloadResidentReplayRangeChunks openRange,
    int start,
    int endExclusive, {
    TaskControl? control,
  }) async* {
    const quantumBytes = 256 * 1024;
    var offset = start;
    while (offset < endExclusive) {
      control?.throwIfCancelled();
      final remaining = endExclusive - offset;
      final end = offset +
          (remaining < quantumBytes ? remaining : quantumBytes);
      final chunks = await openRange(offset, end);
      control?.throwIfCancelled();
      var emitted = 0;
      await for (final chunk in chunks) {
        control?.throwIfCancelled();
        if (chunk.isEmpty) continue;
        emitted += chunk.length;
        yield chunk;
      }
      if (emitted != end - offset) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay quantum was short: $emitted/${end - offset}',
        );
      }
      offset = end;
    }
  }

  Stream<List<int>> _scheduledResidentReplay(
    Stream<List<int>> chunks, {
    required int Function() priority,
    TaskControl? control,
    bool allowBackgroundDuringForegroundPressure = true,
  }) async* {
    final iterator = StreamIterator<List<int>>(chunks);
    try {
      final budgetAccount = control == null
          ? null
          : speculativeEncodedReadBudget.accountFor(control, control: control);
      while (true) {
        await budgetAccount?.waitForRead(control: control);
        final lease = await localReadScheduler.acquire(
          priority: priority,
          control: control,
          allowBackgroundDuringForegroundPressure:
              allowBackgroundDuringForegroundPressure,
        );
        final bool hasChunk;
        try {
          hasChunk = await _moveNextResidentReplayChunk(iterator, control);
        } finally {
          lease.release();
        }
        if (!hasChunk) break;
        control?.throwIfCancelled();
        final chunk = iterator.current;
        if (chunk.isNotEmpty) {
          budgetAccount?.recordRead(chunk.length);
          yield chunk;
        }
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<bool> _moveNextResidentReplayChunk(
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
            message: 'resident replay was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> settlePhysicalRetention() async {
    await _physicalTransferRetention?.settle();
  }

  /// Retires an idle transfer session after a durable owner has applied its
  /// logical delete. This deliberately disposes only the in-memory physical
  /// owner; persistent bytes are deleted (or retained for another binding) by
  /// [ArtifactCacheBackend]. Calling the registry's evict primitive here would
  /// blindly delete a shared staging final after the durable owner had kept it.
  Future<void> retirePhysicalAfterDelete(DownloadId id) async {
    final session = registry.find(id);
    if (session == null || session.demanded || !session.canEvict) return;
    final retired = registry.takeIdlePhysical(id);
    if (retired != null) {
      _physicalTransferRetention?.forget(retired);
      await retired.dispose();
    }
  }

  Future<void> persistPromoted(DownloadId id) async {
    final canonicalId = versionPageAuthority.resolve(id);
    final session = registry.find(id) ?? registry.find(canonicalId);
    if (session == null || session.state != DownloadState.promoted) return;
    final handoff = artifactCacheHandoff;
    final cache = artifactCacheManager;
    if (handoff == null || cache == null) return;
    if (id != session.id && !registry.isPhysicalAlias(id, session.id)) {
      throw StateError(
        'exact durable materialization requires an acquire-time verified '
        'physical alias',
      );
    }
    await handoff.persist(session, exactId: canonicalId);
    final expectedLength = session.committedLength;
    if (expectedLength > 0 &&
        !await cache.containsBackendExact(
          id: canonicalId,
          expectedLength: expectedLength,
        )) {
      throw StateError(
        'required canonical durable artifact was not materialized for ${canonicalId.key}',
      );
    }
  }

  Future<void> checkpointPartials({
    String reason = 'runtime-safety-checkpoint',
  }) async {
    final handoff = partialDownloadHandoff;
    if (handoff == null || _disposed) return;
    final candidates = registry.sessions
        .where((session) =>
            session.state != DownloadState.promoted &&
            session.state != DownloadState.disposed &&
            !session.residentBodyBacked &&
            session.artifact.committedLength > 0)
        .toList(growable: false)
      ..sort((left, right) {
        final priority =
            right.effectivePriority.compareTo(left.effectivePriority);
        if (priority != 0) return priority;
        return right.artifact.committedLength
            .compareTo(left.artifact.committedLength);
      });
    for (final session in candidates) {
      await handoff.persist(session, reason: reason);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (hasConsumers) {
      throw StateError('cannot dispose composition transfer with active consumers');
    }
    _disposed = true;
    await _physicalTransferRetention?.dispose();
    await owner.dispose();
    await artifactCacheHandoff?.drain(registry.sessions);
    artifactCacheHandoff?.detach();
    await partialDownloadHandoff?.drain(registry.sessions);
    await registry.dispose();
    await workspace.dispose();
  }
}

final class CompositionDownloadTransferRuntimePool {
  final Map<_CompositionTransferRuntimeKey, CompositionDownloadTransferRuntime>
      _entries = <_CompositionTransferRuntimeKey, CompositionDownloadTransferRuntime>{};

  CompositionDownloadTransferRuntime get({
    required ArtifactCacheManager? artifactCacheManager,
    required PartialDownloadStore? partialDownloadStore,
    required NetLane net,
    ArtifactCacheReadScheduler? localReadScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
  }) {
    final key = _CompositionTransferRuntimeKey(
      artifactCacheManager: artifactCacheManager,
      partialDownloadStore: partialDownloadStore,
      net: net,
      localReadScheduler: localReadScheduler,
      speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    );
    return _entries.putIfAbsent(
      key,
      () => CompositionDownloadTransferRuntime(
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        net: net,
        localReadScheduler: localReadScheduler,
        speculativeEncodedReadBudget: speculativeEncodedReadBudget,
      ),
    );
  }

  bool get hasConsumers => _entries.values.any((runtime) => runtime.hasConsumers);

  Future<void> disposeIdle() async {
    final idleKeys = <_CompositionTransferRuntimeKey>[
      for (final entry in _entries.entries)
        if (!entry.value.hasConsumers) entry.key,
    ];
    for (final key in idleKeys) {
      final runtime = _entries.remove(key);
      if (runtime != null) {
        await runtime.dispose();
      }
    }
  }

  Future<void> disposeAll() async {
    if (hasConsumers) {
      throw StateError('cannot dispose physical transfers with active consumers');
    }
    final runtimes = _entries.values.toList(growable: false);
    _entries.clear();
    for (final runtime in runtimes) {
      await runtime.dispose();
    }
  }
}

final class _CompositionTransferRuntimeKey {
  const _CompositionTransferRuntimeKey({
    required this.artifactCacheManager,
    required this.partialDownloadStore,
    required this.net,
    required this.localReadScheduler,
    required this.speculativeEncodedReadBudget,
  });

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler? localReadScheduler;
  final SpeculativeEncodedReadBudget? speculativeEncodedReadBudget;

  @override
  bool operator ==(Object other) =>
      other is _CompositionTransferRuntimeKey &&
      identical(artifactCacheManager, other.artifactCacheManager) &&
      identical(partialDownloadStore, other.partialDownloadStore) &&
      identical(net, other.net) &&
      identical(localReadScheduler, other.localReadScheduler) &&
      identical(speculativeEncodedReadBudget, other.speculativeEncodedReadBudget);

  @override
  int get hashCode => Object.hash(
        identityHashCode(artifactCacheManager),
        identityHashCode(partialDownloadStore),
        identityHashCode(net),
        identityHashCode(localReadScheduler),
        identityHashCode(speculativeEncodedReadBudget),
      );
}

final class _CompositionTransferTraceHub implements TraceSink {
  final Map<TraceSink, int> _sinks = <TraceSink, int>{};

  void attach(TraceSink sink) {
    _sinks.update(sink, (count) => count + 1, ifAbsent: () => 1);
  }

  void detach(TraceSink sink) {
    final count = _sinks[sink];
    if (count == null) return;
    if (count <= 1) {
      _sinks.remove(sink);
      return;
    }
    _sinks[sink] = count - 1;
  }

  @override
  void record(TraceEvent event) {
    for (final sink in _sinks.keys.toList(growable: false)) {
      try {
        sink.record(event);
      } on Object {
        // A consumer diagnostics sink cannot break physical transfer ownership.
      }
    }
  }
}
