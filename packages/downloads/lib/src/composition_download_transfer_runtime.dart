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
    this.maxIdlePartialSessions = 32,
    this.maxIdlePartialBytes = 256 * 1024 * 1024,
  })  : localReadScheduler =
            localReadScheduler ?? ArtifactCacheReadScheduler(),
        clock = const SystemClock(),
        traceHub = _CompositionTransferTraceHub(),
        workspace = EphemeralCacheWorkspace.readerSession(
          'composition-transfer-${++_sequence}',
        ) {
    final cache = artifactCacheManager;
    final partialStore = partialDownloadStore;
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
        requiredExactTargets: (session) =>
            owner.requiredExactDurableTargets(session.id),
      );
    }
    if (partialStore != null) {
      partialDownloadHandoff = PartialDownloadHandoff(
        store: partialStore,
        equivalentCandidates: cache?.directEquivalents,
        onError: (error, stackTrace) {},
        clock: clock,
        readScheduler: localReadScheduler,
        traceSink: traceHub,
        sessionId: 'composition-transfer-owner',
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
      net: net,
      resolveTransferId: _resolveTransferIdForAcquire,
    );
    _physicalTransferRetention = PhysicalTransferRetention(
      registry: registry,
      owner: owner,
      clock: clock,
      traceSink: traceHub,
      artifactHandoff: artifactCacheHandoff,
      partialHandoff: partialDownloadHandoff,
      maxIdlePartialSessions: maxIdlePartialSessions,
      maxIdlePartialBytes: maxIdlePartialBytes,
    );
  }

  static int _sequence = 0;

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler localReadScheduler;
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

  DownloadId _resolveTransferIdForAcquire(DownloadId exactId) {
    final resolved = registry.resolvePhysicalId(exactId);
    if (resolved != exactId) return resolved;
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

  Future<void> settlePhysicalRetention() async {
    await _physicalTransferRetention?.settle();
  }

  Future<void> persistPromoted(DownloadId id) async {
    final session = registry.find(id);
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
    await handoff.persist(session, exactId: id);
    final expectedLength = session.committedLength;
    if (expectedLength > 0 &&
        !await cache.containsBackendExact(
          id: id,
          expectedLength: expectedLength,
        )) {
      throw StateError(
        'required exact durable artifact was not materialized for ${id.key}',
      );
    }
  }

  Future<void> checkpointPartials({
    String reason = 'process-lifecycle-checkpoint',
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
  }) {
    final key = _CompositionTransferRuntimeKey(
      artifactCacheManager: artifactCacheManager,
      partialDownloadStore: partialDownloadStore,
      net: net,
      localReadScheduler: localReadScheduler,
    );
    return _entries.putIfAbsent(
      key,
      () => CompositionDownloadTransferRuntime(
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        net: net,
        localReadScheduler: localReadScheduler,
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
  });

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final ArtifactCacheReadScheduler? localReadScheduler;

  @override
  bool operator ==(Object other) =>
      other is _CompositionTransferRuntimeKey &&
      identical(artifactCacheManager, other.artifactCacheManager) &&
      identical(partialDownloadStore, other.partialDownloadStore) &&
      identical(net, other.net) &&
      identical(localReadScheduler, other.localReadScheduler);

  @override
  int get hashCode => Object.hash(
        identityHashCode(artifactCacheManager),
        identityHashCode(partialDownloadStore),
        identityHashCode(net),
        identityHashCode(localReadScheduler),
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
