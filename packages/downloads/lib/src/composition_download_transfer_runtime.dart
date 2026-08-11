import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'partial_download_handoff.dart';
import 'partial_download_store.dart';
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
  })  : clock = const SystemClock(),
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
      );
    }
    if (partialStore != null) {
      partialDownloadHandoff = PartialDownloadHandoff(
        store: partialStore,
        onError: (error, stackTrace) {},
        clock: clock,
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
      },
    );
    owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      prepareDownload: partialDownloadHandoff?.restoreInto,
      persistUnclaimed: partialDownloadHandoff == null
          ? null
          : (session) => partialDownloadHandoff!.drain(<DownloadSession>[session]),
      net: net,
    );
    if (cache != null) {
      void listener(DownloadId promoted) {
        if (_disposed) return;
        for (final equivalent in cache.directEquivalents(promoted)) {
          if (equivalent == promoted || registry.find(equivalent) == null) {
            continue;
          }
          owner.refreshForLocalArtifact(equivalent);
        }
      }
      artifactPromotionListener = listener;
      cache.addPromotionListener(listener);
    }
  }

  static int _sequence = 0;

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;
  final MonoClock clock;
  final _CompositionTransferTraceHub traceHub;
  final EphemeralCacheWorkspace workspace;
  PromotedArtifactCacheHandoff? artifactCacheHandoff;
  PartialDownloadHandoff? partialDownloadHandoff;
  late final DownloadRegistry registry;
  late final DownloadTransferOwner owner;
  ArtifactPromotionListener? artifactPromotionListener;
  bool _disposed = false;

  bool get disposed => _disposed;
  bool get hasConsumers => owner.consumers.isNotEmpty;

  DownloadTransferConsumer attachConsumer({
    required String scopeId,
    required TransferTransportPick transportFor,
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

  Future<void> persistPromoted(DownloadId id) async {
    final session = registry.find(id);
    if (session == null || session.state != DownloadState.promoted) return;
    await artifactCacheHandoff?.persist(session);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (hasConsumers) {
      throw StateError('cannot dispose composition transfer with active consumers');
    }
    _disposed = true;
    final promotionListener = artifactPromotionListener;
    artifactPromotionListener = null;
    if (promotionListener != null) {
      artifactCacheManager?.removePromotionListener(promotionListener);
    }
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
  }) {
    final key = _CompositionTransferRuntimeKey(
      artifactCacheManager: artifactCacheManager,
      partialDownloadStore: partialDownloadStore,
      net: net,
    );
    return _entries.putIfAbsent(
      key,
      () => CompositionDownloadTransferRuntime(
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        net: net,
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
  });

  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final NetLane net;

  @override
  bool operator ==(Object other) =>
      other is _CompositionTransferRuntimeKey &&
      identical(artifactCacheManager, other.artifactCacheManager) &&
      identical(partialDownloadStore, other.partialDownloadStore) &&
      identical(net, other.net);

  @override
  int get hashCode => Object.hash(
        identityHashCode(artifactCacheManager),
        identityHashCode(partialDownloadStore),
        identityHashCode(net),
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
