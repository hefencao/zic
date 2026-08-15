import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'asset_bundle_transport.dart';
import 'media_load_token.dart';
import 'pipeline_media_runtime.dart';
import 'pipeline_page_stream.dart';
import 'pipeline_transfer_progress.dart';
import 'reader_pipeline_profile.dart';

part 'pipeline_page_output.dart';

typedef PipelineArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);

final class PipelinePageDimensions {
  const PipelinePageDimensions({required this.width, required this.height});

  final int width;
  final int height;
}

const Duration _readerSessionRetentionDuration = Duration(minutes: 2);
const int _maxRetainedReaderSessions = 1;

final class _RetainedReaderSession {
  _RetainedReaderSession({
    required this.key,
    required this.session,
    required this.retainedAtMicros,
    required this.expiry,
  });

  final String key;
  final PipelineReaderSession session;
  final int retainedAtMicros;
  final Timer expiry;
}

final class _PipelineReaderSessionRetentionPool {
  bool get hasLeased => _leased.isNotEmpty;

  final Map<String, _RetainedReaderSession> _idle =
      <String, _RetainedReaderSession>{};
  final Map<PipelineReaderSession, String> _leased =
      <PipelineReaderSession, String>{};

  PipelineReaderSession acquire({
    required String key,
    required PipelineReaderSession Function() create,
  }) {
    final retained = _idle.remove(key);
    if (retained != null) {
      retained.expiry.cancel();
      final session = retained.session;
      if (!session.isDisposed) {
        _leased[session] = key;
        session.resumeRetainedReaderSession(
          retainedMicros:
              session.clock.nowMicros() - retained.retainedAtMicros,
        );
        return session;
      }
    }
    final session = create();
    _leased[session] = key;
    return session;
  }

  void release(PipelineReaderSession session) {
    final key = _leased.remove(session);
    if (key == null || session.isDisposed) {
      unawaited(session.dispose());
      return;
    }
    session.retainReaderSession();
    final prior = _idle.remove(key);
    if (prior != null && !identical(prior.session, session)) {
      prior.expiry.cancel();
      unawaited(prior.session.dispose());
    }
    late final Timer expiry;
    final retainedAtMicros = session.clock.nowMicros();
    expiry = Timer(_readerSessionRetentionDuration, () {
      final current = _idle[key];
      if (current == null || !identical(current.expiry, expiry)) {
        return;
      }
      _idle.remove(key);
      unawaited(current.session.dispose());
    });
    _idle[key] = _RetainedReaderSession(
      key: key,
      session: session,
      retainedAtMicros: retainedAtMicros,
      expiry: expiry,
    );
    _trim();
  }

  Future<void> disposeAll() async {
    final sessions = _idle.values.map((entry) => entry.session).toSet();
    for (final retained in _idle.values) {
      retained.expiry.cancel();
    }
    _idle.clear();
    for (final session in sessions) {
      await session.dispose();
    }
  }

  void _trim() {
    while (_idle.length > _maxRetainedReaderSessions) {
      final oldest = _idle.values.reduce(
        (left, right) =>
            left.retainedAtMicros <= right.retainedAtMicros ? left : right,
      );
      _idle.remove(oldest.key);
      oldest.expiry.cancel();
      unawaited(oldest.session.dispose());
    }
  }
}


final class PipelineReaderSessionFactory {
  PipelineReaderSessionFactory({
    required this.mediaRuntimeFactory,
    this.artifactCacheManager,
    this.partialDownloadStore,
    ArtifactCacheReadScheduler? artifactReadScheduler,
    NetLane? pageDownloadLane,
    WebpDecodePrefixHints? decodePrefixHints,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.bytesLoader,
    this.userAgentProvider,
    _PipelineReaderSessionRetentionPool? retentionPool,
    CompositionDownloadTransferRuntimePool? transferRuntimePool,
    this.transferRuntime,
  })  : _retentionPool =
            retentionPool ?? _PipelineReaderSessionRetentionPool(),
        _transferRuntimePool = transferRuntimePool ??
            CompositionDownloadTransferRuntimePool(),
        artifactReadScheduler =
            artifactReadScheduler ?? ArtifactCacheReadScheduler(),
        pageDownloadLane =
            pageDownloadLane ??
            NetLane(
              maxActive: ReaderPipelineProfile.stable.networkConcurrency,
              reservedHighPrioritySlots: 1,
              highPriorityThreshold: 1000,
              preemptionThreshold: 40,
              preemptionCandidateGrace: const Duration(milliseconds: 100),
            ),
        decodePrefixHints = decodePrefixHints ?? WebpDecodePrefixHints();

  final PipelineMediaRuntimeFactory mediaRuntimeFactory;
  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final _PipelineReaderSessionRetentionPool _retentionPool;
  final CompositionDownloadTransferRuntimePool _transferRuntimePool;
  final CompositionDownloadTransferRuntime? transferRuntime;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  final NetLane pageDownloadLane;
  final WebpDecodePrefixHints decodePrefixHints;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final PipelineArtifactBytesLoader? bytesLoader;
  final String Function()? userAgentProvider;

  /// Returns a factory that keeps composition-owned cache/byte loaders while
  /// adding page-local transport sources.
  PipelineReaderSessionFactory withLoaderSources(
    Map<Uri, LoaderTransportSource> sources,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: <Uri, LoaderTransportSource>{
          ...loaderSources,
          ...sources,
        },
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: transferRuntime,
      );

  PipelineReaderSessionFactory withArtifactCacheManager(
    ArtifactCacheManager? manager,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: manager,
        partialDownloadStore: partialDownloadStore,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: transferRuntime,
      );

  PipelineReaderSessionFactory withPartialDownloadStore(
    PartialDownloadStore? store,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: store,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: transferRuntime,
      );

  PipelineReaderSessionFactory withUserAgentProvider(
    String Function()? provider,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: provider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: transferRuntime,
      );

  PipelineReaderSessionFactory withBytesLoader(
    PipelineArtifactBytesLoader? loader,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        partialDownloadStore: partialDownloadStore,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: loader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: transferRuntime,
      );

  /// Returns a factory whose Reader consumers attach to the supplied
  /// composition-level physical transfer runtime. The runtime is owned by the
  /// application composition, not by any Reader session.
  PipelineReaderSessionFactory withTransferRuntime(
    CompositionDownloadTransferRuntime? runtime,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager:
            runtime == null ? artifactCacheManager : runtime.artifactCacheManager,
        partialDownloadStore:
            runtime == null ? partialDownloadStore : runtime.partialDownloadStore,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: runtime?.net ?? pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
        transferRuntimePool: _transferRuntimePool,
        transferRuntime: runtime,
      );

  PipelineReaderSession create({
    required ChapterManifest chapter,
    required String sessionId,
    TraceSink? traceSink,
  }) {
    final externalTransferRuntime = this.transferRuntime;
    if (externalTransferRuntime != null) {
      if (!identical(
            artifactCacheManager,
            externalTransferRuntime.artifactCacheManager,
          ) ||
          !identical(
            partialDownloadStore,
            externalTransferRuntime.partialDownloadStore,
          ) ||
          !identical(pageDownloadLane, externalTransferRuntime.net)) {
        throw StateError(
          'Reader transfer runtime must share the factory artifact cache, '
          'partial store and NetLane authorities',
        );
      }
    }
    final transferRuntime = externalTransferRuntime ??
        _transferRuntimePool.get(
          artifactCacheManager: artifactCacheManager,
          partialDownloadStore: partialDownloadStore,
          net: pageDownloadLane,
          localReadScheduler: artifactReadScheduler,
        );
    final localReadScheduler = transferRuntime.localReadScheduler;
    return PipelineReaderSession._(
      chapter: chapter,
      mediaRuntimeFactory: mediaRuntimeFactory,
      sessionId: sessionId,
      artifactCacheManager: artifactCacheManager,
      artifactReadScheduler: localReadScheduler,
      pageDownloadLane: pageDownloadLane,
      decodePrefixHints: decodePrefixHints,
      loaderSources: loaderSources,
      bytesLoader: bytesLoader,
      userAgentProvider: userAgentProvider,
      traceSink: traceSink,
      transferRuntime: transferRuntime,
    );
  }

  PipelineReaderSession acquire({
    required ChapterManifest chapter,
    required String sessionId,
    TraceSink? traceSink,
  }) =>
      _retentionPool.acquire(
        key: _retentionKey(chapter, traceSink),
        create: () => create(
          chapter: chapter,
          sessionId: sessionId,
          traceSink: traceSink,
        ),
      );

  void release(PipelineReaderSession session) {
    _retentionPool.release(session);
  }

  Future<void> disposeRetainedSessions() async {
    await _retentionPool.disposeAll();
    // `create()` callers are not represented in the retention pool. Dispose
    // only runtimes that prove they have no live transfer consumers.
    await _transferRuntimePool.disposeIdle();
  }

  /// Explicit composition shutdown for tests/app teardown after every active
  /// Reader/command consumer has detached from the physical transfer owner.
  Future<void> disposeTransferRuntimes() async {
    if (_transferRuntimePool.hasConsumers) {
      throw StateError('cannot dispose physical transfers with active consumers');
    }
    await _transferRuntimePool.disposeAll();
  }

  String _retentionKey(ChapterManifest chapter, TraceSink? traceSink) {
    final orderedSources = loaderSources.entries.toList(growable: false)
      ..sort(
        (left, right) =>
            left.key.toString().compareTo(right.key.toString()),
      );
    final loaderFingerprint = Object.hashAll(
      orderedSources.map(
        (entry) => Object.hash(
          entry.key.toString(),
          entry.value.revision,
          entry.value.loadBytes != null,
          entry.value.openResponse != null,
        ),
      ),
    );
    final configuration = Object.hash(
      identityHashCode(mediaRuntimeFactory),
      identityHashCode(artifactCacheManager),
      identityHashCode(partialDownloadStore),
      identityHashCode(artifactReadScheduler),
      identityHashCode(pageDownloadLane),
      identityHashCode(decodePrefixHints),
      identityHashCode(bytesLoader),
      identityHashCode(traceSink),
      identityHashCode(transferRuntime),
      loaderFingerprint,
    );
    return '${chapter.sourceId}\u0000${chapter.comicId}\u0000'
        '${chapter.chapter.chapterId}\u0000'
        '${chapter.chapter.sourceRevision}\u0000$configuration';
  }
}

/// Owns the complete resource side of one Reader session.
///
/// Reader reports viewport observations and consumes read-only
/// [PipelinePageStream] transfer plus [PipelinePageOutputStream] presentation
/// projections. Physical download scheduling/request transport are composition
/// services; Reader-local decode/upload and transfer projections remain behind
/// this session boundary.
final class PipelineReaderSession {
  PipelineReaderSession._({
    required this.chapter,
    required PipelineMediaRuntimeFactory mediaRuntimeFactory,
    required this.sessionId,
    ArtifactCacheManager? artifactCacheManager,
    required ArtifactCacheReadScheduler artifactReadScheduler,
    required NetLane pageDownloadLane,
    required WebpDecodePrefixHints decodePrefixHints,
    Map<Uri, LoaderTransportSource> loaderSources =
        const <Uri, LoaderTransportSource>{},
    PipelineArtifactBytesLoader? bytesLoader,
    String Function()? userAgentProvider,
    TraceSink? traceSink,
    required CompositionDownloadTransferRuntime transferRuntime,
  })  : artifactReadScheduler = artifactReadScheduler,
        _artifactCacheManager = artifactCacheManager,
        _transferRuntime = transferRuntime,
        _sharedTraceSink = traceSink,
        _bytesLoader = bytesLoader,
        clock = SystemClock(),
        _memoryTrace = MemoryTraceSink(),
        _profile = readerPipelineProfileFor(
          chapter,
          ),
        _assetTransport = AssetBundleTransport(rootBundle),
        _ioTransport = IoTransport(
          http: HttpTransport(userAgentProvider: userAgentProvider),
        ),
        _loaderTransport = LoaderTransport(loaderSources),
        transferProgress = PipelineTransferProgressPublisher(),
        _pageDimensions = ValueNotifier<Map<String, PipelinePageDimensions>>(
          const <String, PipelinePageDimensions>{},
        ) {
    trace = MultiTraceSink(<TraceSink>[
      _memoryTrace,
      if (traceSink != null) traceSink,
    ]);
    _media = mediaRuntimeFactory.create(
      sessionId: sessionId,
      clock: clock,
      traceSink: trace,
    );
    final identities = chapter.pages
        .map(
          (asset) => MapEntry<Uri, DownloadId>(
            asset.uri,
            readerPageDownloadId(chapter, asset),
          ),
        )
        .toList(growable: false);
    final sourceBudgets = <DownloadId, int>{
      for (final asset in chapter.pages)
        readerPageDownloadId(chapter, asset): math.max(
          asset.byteLength ?? 0,
          256 * 1024 * 1024,
        ),
    };
    _streamingSources = SourcePool(
      factory: _media.sources,
      budgetFor: (id) => sourceBudgets[id] ?? 256 * 1024 * 1024,
    );
    if (artifactCacheManager != null) {
      _artifactCacheTransport = ArtifactCacheTransport(
        cache: artifactCacheManager,
        identities: identities,
        fallbackFor: _baseTransportFor,
        readScheduler: artifactReadScheduler,
        demandPriority: _artifactReadPriority,
        clock: clock,
        traceSink: trace,
        sessionId: sessionId,
        demandRevision: () => revision,
      );
    }
    _ingresses = DownloadIngressProjectionRegistry(
      sources: _streamingSources,
      scopePrefix: 'reader:$sessionId',
      residentReplaySource: _openResidentReplaySource,
    );
    _downloads = _transferRuntime.registry;
    _downloadTransfer = _transferRuntime.attachConsumer(
      scopeId: 'reader:$sessionId',
      transportFor: _transportFor,
      retainedTransportFor: _retainedTransferTransportFor,
      consumerTraceSink: trace,
      localPhysicalTraceSink: _memoryTrace,
      sharedPhysicalTraceSink: _sharedTraceSink,
      retry: _profile.retry,
      downloadBucketFor: _profile.downloadBucket,
      downloadBucketLimitFor: _downloadBucketLimit,
    );
    _decodes = DecodeRegistry(
      downloads: _downloads,
      ingresses: _ingresses,
      cursors: _media.cursors,
      clock: clock,
      prefixHints: decodePrefixHints,
      onAnimationResolved: _handleAnimationResolved,
      onFrameDecoded: _handleFrameDecoded,
      traceSink: trace,
    );
    _uploads = UploadRegistry(
      decodes: _decodes,
      uploader: _media.uploader,
      clock: clock,
      traceSink: trace,
    )..addListener(_handleUploadSnapshot);
    _frameBudgets = FrameBudgeter(
      decodes: _decodes,
      uploads: _uploads,
      limits: const FrameBudget(
        decodedBytes: 256 * 1024 * 1024,
        outputBytes: 128 * 1024 * 1024,
        currentDecodedReserve: 64 * 1024 * 1024,
        currentOutputReserve: 32 * 1024 * 1024,
      ),
    );
    _coordinator = LiveCoordinator(
      registry: _downloads,
      transportFor: _transportFor,
      ingresses: _ingresses,
      clock: clock,
      traceSink: trace,
      retry: _profile.retry,
      decodes: _decodes,
      uploads: _uploads,
      budgets: _frameBudgets,
      downloadTransfer: _downloadTransfer,
      onDownloadObserved: _observeDownloadSession,
      onSourceKindObserved: _handleSourceKindObserved,
      onDecodeRefillObserved: _handleDecodeRefillObserved,
      net: pageDownloadLane,
      downloadBucketFor: _profile.downloadBucket,
      downloadBucketLimitFor: _downloadBucketLimit,
      // Match VibeVenera's current-page execution reservation. Download
      // priority alone cannot make first-frame latency stable if speculative
      // decode/upload work has already filled every execution slot. Current
      // work alone may use one temporary handoff slot while a lower-ranked
      // prefetch observes cancellation and unwinds; permits are released
      // only when the old task really exits.
      decode: DecodeLane(
        maxActive: _profile.decodeConcurrency,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 1000,
        preemptionThreshold: 40,
      ),
      upload: UploadLane(
        maxActive: _profile.uploadConcurrency,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 1000,
        preemptionThreshold: 40,
      ),
    );
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionCreated,
        payload: <String, Object?>{
          'pages': chapter.pages.length,
          'renderer': _media.renderer.name,
        },
      ),
    );
  }

  final ChapterManifest chapter;
  final String sessionId;
  final MonoClock clock;
  final MemoryTraceSink _memoryTrace;
  late final TraceSink trace;
  final TraceSink? _sharedTraceSink;
  final ReaderPipelineProfile _profile;
  late final PipelineMediaRuntime _media;
  final PipelineArtifactBytesLoader? _bytesLoader;
  final AssetBundleTransport _assetTransport;
  final IoTransport _ioTransport;
  final LoaderTransport _loaderTransport;
  final ArtifactCacheManager? _artifactCacheManager;
  ArtifactCacheTransport? _artifactCacheTransport;
  late final SourcePool _streamingSources;
  late final DownloadIngressProjectionRegistry _ingresses;
  final CompositionDownloadTransferRuntime _transferRuntime;
  late final DownloadRegistry _downloads;
  late final DownloadTransferConsumer _downloadTransfer;
  late final DecodeRegistry _decodes;
  late final UploadRegistry _uploads;
  late final FrameBudgeter _frameBudgets;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  String? _readerSessionId;
  final Map<String, PipelinePageStream> _pageStreams =
      <String, PipelinePageStream>{};
  final Map<String, PipelinePageOutputStream> _pageOutputs =
      <String, PipelinePageOutputStream>{};
  Timer? _playbackTicker;
  int? _playbackWakeAtMicros;
  bool _playbackPaused = false;
  final PipelineTransferProgressPublisher transferProgress;
  final ValueNotifier<Map<String, PipelinePageDimensions>> _pageDimensions;
  ValueListenable<Map<String, PipelinePageDimensions>> get pageDimensions =>
      _pageDimensions;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  ArtifactCachePressureLease? _startupArtifactPressure;
  DownloadId? _startupArtifactPressureDownload;
  DownloadId? _startupCurrentDownload;
  bool _disposed = false;
  bool _retainedForReaderReentry = false;
  ReaderObs? _pendingObservation;
  bool _observationDrainScheduled = false;
  int _observationGeneration = 0;

  bool get isDisposed => _disposed;
  int get revision => _binding?.revision ?? 0;
  RendererKind get renderer => _media.renderer;

  void attach(DecodeTarget target) {
    _requireOpen();
    _invalidateObservationQueue();
    _retainedForReaderReentry = false;
    if (target.renderer != renderer) {
      throw ArgumentError.value(
        target.renderer,
        'target.renderer',
        'must match the atomically injected Pipeline media renderer '
            '${renderer.name}',
      );
    }
    _readerSessionId = null;
    _binding = ReaderBinding(
      chapter: chapter,
      decodeTarget: target,
      clock: clock,
      traceSink: trace,
      coordinator: _coordinator,
      playback: _coordinator,
      windowResolver: _profile.windowResolver,
      policy: _profile.policy,
      policyGuard: _profile.guard,
    );
  }

  /// Changes only decode/upload raster identity for an attached Reader.
  /// Download demands remain diffed against the existing plan; this method must
  /// not detach the binding or touch Reader navigation state. Reconciliation is
  /// deferred until the next enqueued observation.
  void updateDecodeTarget(DecodeTarget target) {
    _requireOpen();
    if (target.renderer != renderer) {
      throw ArgumentError.value(
        target.renderer,
        'target.renderer',
        'must match the atomically injected Pipeline media renderer '
            '${renderer.name}',
      );
    }
    final binding = _binding;
    if (binding == null) {
      throw StateError('pipeline Reader session is not attached');
    }
    binding.updateDecodeTarget(target);
  }

  /// Enqueues the latest Reader viewport observation behind the UI/navigation
  /// callback boundary. ReaderView must never synchronously execute demand,
  /// transfer or decode reconciliation. Rapid scroll updates are latest-wins
  /// within one microtask turn; page identity/current transitions remain in the
  /// observation itself and are reconciled before the next frame.
  void enqueueObservation(ReaderObs observation) {
    if (_disposed || _retainedForReaderReentry) {
      return;
    }
    _pendingObservation = observation;
    _scheduleObservationDrain();
  }

  void _scheduleObservationDrain() {
    if (_observationDrainScheduled) return;
    _observationDrainScheduled = true;
    final generation = _observationGeneration;
    scheduleMicrotask(() => _drainObservation(generation));
  }

  void _drainObservation(int generation) {
    if (generation != _observationGeneration ||
        _disposed ||
        _retainedForReaderReentry) {
      _observationDrainScheduled = false;
      if (_pendingObservation != null &&
          !_disposed &&
          !_retainedForReaderReentry) {
        _scheduleObservationDrain();
      }
      return;
    }
    final observation = _pendingObservation;
    _pendingObservation = null;
    _observationDrainScheduled = false;
    if (observation == null) return;
    try {
      accept(observation);
    } on Object catch (error, stackTrace) {
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.taskFailed,
          revision: revision,
          payload: <String, Object?>{
            'stage': 'reader-observation-reconcile',
            'errorType': error.runtimeType.toString(),
            'error': error.toString(),
            'stackType': stackTrace.runtimeType.toString(),
          },
        ),
      );
    }
    if (_pendingObservation != null) {
      _scheduleObservationDrain();
    }
  }

  void _invalidateObservationQueue() {
    _observationGeneration++;
    _pendingObservation = null;
  }

  void accept(ReaderObs observation) {
    _requireOpen();
    _readerSessionId = observation.sessionId;
    final binding = _binding;
    if (binding == null) {
      throw StateError('pipeline Reader session is not attached');
    }
    final pageIndex = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    final currentAsset = chapter.pages[pageIndex];
    final currentDownload = readerPageDownloadId(chapter, currentAsset);
    final target = binding.pipeline.decodeTarget;
    final prewarmer = _media is PipelineOutputPrewarmer
        ? _media as PipelineOutputPrewarmer
        : null;
    if (prewarmer != null) {
      unawaited(
        _prewarmOutput(
          prewarmer,
          id: currentDownload,
          width: target.physicalWidth,
          height: target.physicalHeight,
        ),
      );
    }
    final currentOutput = _pageOutputs[currentDownload.key]?.snapshot;
    if (currentOutput?.hasSurface != true) {
      _startupCurrentDownload = currentDownload;
    } else if (_startupCurrentDownload == currentDownload) {
      _releaseStartupCurrentDownload();
    }
    _holdStartupArtifactPressureFor(currentDownload);
    binding.accept(observation);
    _syncPageStreams();
    transferProgress.select(_downloads.find(currentDownload));
    _syncStartupArtifactPressure();
    artifactReadScheduler.refresh();
    _syncPageOutputs();
    _ensurePlaybackTicker();
  }

  Future<void> _prewarmOutput(
    PipelineOutputPrewarmer prewarmer, {
    required DownloadId id,
    required int width,
    required int height,
  }) async {
    try {
      await prewarmer.prewarmOutput(width: width, height: height);
    } on Object catch (error) {
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.taskFailed,
          identityHash: id.key,
          payload: <String, Object?>{
            'lane': 'output-prewarm',
            'reason': error.toString(),
            'fallback': 'lazy-output-create',
            'width': width,
            'height': height,
          },
        ),
      );
    }
  }

  void setPlayback({required bool paused, required double speed}) {
    _requireOpen();
    if (!speed.isFinite || speed < 0.25 || speed > 4) {
      throw ArgumentError.value(
        speed,
        'speed',
        'must be finite and within 0.25..4',
      );
    }
    _uploads.setPlayback(paused: paused, speed: speed);
    _playbackPaused = paused;
    _ensurePlaybackTicker();
  }

  void detach(String readerSessionId) {
    _invalidateObservationQueue();
    _binding?.detach(readerSessionId);
    _binding = null;
    _readerSessionId = null;
    _releaseStartupArtifactPressure();
    _releaseStartupCurrentDownload();
    artifactReadScheduler.refresh();
    transferProgress.clear();
  }

  void retainReaderSession() {
    _requireOpen();
    if (_retainedForReaderReentry) {
      return;
    }
    _invalidateObservationQueue();
    _retainedForReaderReentry = true;
    _cancelPlaybackWake();
    final binding = _binding;
    final readerSessionId = _readerSessionId;
    _binding = null;
    _readerSessionId = null;
    binding?.detach(readerSessionId ?? sessionId);
    _releaseStartupArtifactPressure();
    _releaseStartupCurrentDownload();
    artifactReadScheduler.refresh();
    transferProgress.clear();
    for (final output in _pageOutputs.values) {
      output._dispose();
    }
    _pageOutputs.clear();
    for (final stream in _pageStreams.values) {
      stream.dispose();
    }
    _pageStreams.clear();
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionRetained,
        payload: <String, Object?>{
          'downloadSessions': _downloads.sessions.length,
          'decodeSessions': _decodes.sessions.length,
          'uploadSessions': _uploads.sessions.length,
        },
      ),
    );
  }

  void resumeRetainedReaderSession({required int retainedMicros}) {
    _requireOpen();
    _retainedForReaderReentry = false;
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionReused,
        payload: <String, Object?>{
          'retainedMicros': retainedMicros < 0 ? 0 : retainedMicros,
          'downloadSessions': _downloads.sessions.length,
          'decodeSessions': _decodes.sessions.length,
          'uploadSessions': _uploads.sessions.length,
        },
      ),
    );
  }

  PipelinePageStream pageStream(PageAsset asset) {
    _requireOpen();
    final id = readerPageDownloadId(chapter, asset);
    return _pageStreams.putIfAbsent(
      id.key,
      () => PipelinePageStream.forDownload(
        id,
        resolvePhysical: () => _downloads.find(id),
      )..refreshBinding(),
    );
  }

  PipelinePageOutputStream pageOutput(PageAsset asset) {
    _requireOpen();
    final id = readerPageDownloadId(chapter, asset);
    final output = _pageOutputs.putIfAbsent(
      id.key,
      () => PipelinePageOutputStream._(
        download: id,
        uploads: _uploads,
        decodes: _decodes,
        outputs: _media.outputs,
      ),
    );
    output._bind(_activeUploadIdentity(id));
    return output;
  }

  Future<Stream<List<int>>> _openResidentReplaySource(
    DownloadSession session,
    int endExclusive,
  ) async {
    if (endExclusive <= 0 || endExclusive > session.committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'invalid resident replay boundary $endExclusive/'
            '${session.committedLength}',
      );
    }

    final cache = _artifactCacheManager;
    if (cache != null) {
      final lookup = await cache.lookup(session.id);
      if (lookup != null) {
        final expectedTotal = session.totalLength;
        if ((expectedTotal == null || lookup.entry.length == expectedTotal) &&
            lookup.entry.length >= endExclusive) {
          return _scheduledResidentReplay(
            lookup.entry.open(
              start: 0,
              endExclusive: endExclusive,
            ),
            session.id,
          );
        }
      }
    }

    final uri = session.id.canonicalUri;
    if (_isDirectImmutableLocalUri(uri)) {
      final resumeValidators = session.resumeValidatorsFor(uri);
      final response = await _baseTransportFor(uri).open(
        uri,
        range: ByteRange(start: 0, end: endExclusive - 1),
        validators: resumeValidators.canResume ? resumeValidators : null,
      );
      final expectedTotal = session.totalLength;
      if (expectedTotal != null &&
          response.totalLength != null &&
          response.totalLength != expectedTotal) {
        await response.discard();
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident immutable source length changed: '
              '${response.totalLength}/$expectedTotal',
        );
      }
      if (resumeValidators.canResume &&
          !resumeValidators.matches(response.validators)) {
        await response.discard();
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident immutable source validators changed',
        );
      }
      return _boundedResidentReplay(
        response,
        endExclusive,
        session.id,
      );
    }

    throw Failure(
      code: ErrorCode.artifactCorruption,
      message: 'resident encoded-byte replay authority is unavailable for '
          '${session.id.key}',
    );
  }

  Stream<List<int>> _boundedResidentReplay(
    ByteResponse response,
    int endExclusive,
    DownloadId id,
  ) async* {
    var emitted = 0;
    final iterator = StreamIterator<List<int>>(response.bytes);
    try {
      while (emitted < endExclusive) {
        final lease = await artifactReadScheduler.acquire(
          priority: () => _artifactReadPriority(id),
        );
        final bool hasChunk;
        try {
          hasChunk = await iterator.moveNext();
        } finally {
          lease.release();
        }
        if (!hasChunk) break;
        final chunk = iterator.current;
        final remaining = endExclusive - emitted;
        if (chunk.length <= remaining) {
          emitted += chunk.length;
          if (chunk.isNotEmpty) yield chunk;
        } else {
          final prefix = chunk.sublist(0, remaining);
          emitted += prefix.length;
          if (prefix.isNotEmpty) yield prefix;
        }
      }
      if (emitted != endExclusive) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident immutable source replay was short: '
              '$emitted/$endExclusive',
        );
      }
    } finally {
      await iterator.cancel();
      await response.discard();
    }
  }

  Stream<List<int>> _scheduledResidentReplay(
    Stream<List<int>> chunks,
    DownloadId id,
  ) async* {
    final iterator = StreamIterator<List<int>>(chunks);
    try {
      while (true) {
        final lease = await artifactReadScheduler.acquire(
          priority: () => _artifactReadPriority(id),
        );
        final bool hasChunk;
        try {
          hasChunk = await iterator.moveNext();
        } finally {
          lease.release();
        }
        if (!hasChunk) break;
        final chunk = iterator.current;
        if (chunk.isNotEmpty) yield chunk;
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<Uint8List> loadBytes(
    PageAsset asset,
    MediaLoadToken token,
  ) async {
    final override = _bytesLoader;
    if (override != null) return override(asset, token);
    token.throwIfCancelled();
    final id = readerPageDownloadId(chapter, asset);
    final cache = _artifactCacheManager;
    final hotBytes = cache?.lookupMemory(id);
    if (hotBytes != null) {
      _recordPresentationCacheRead(
        asset: asset,
        id: id,
        bytes: hotBytes,
        source: 'artifact-byte-cache',
        readMode: 'memory-hit',
        readMicros: 0,
        memoryHit: true,
        joined: false,
      );
      return hotBytes;
    }

    final session = _downloads.find(id);
    if ((session == null ||
            session.state != DownloadState.promoted ||
            session.residentBodyBacked) &&
        cache != null) {
      final readStarted = clock.nowMicros();
      try {
        final cached = await cache.readForeground(id);
        token.throwIfCancelled();
        if (cached != null) {
          final readMicros = clock.nowMicros() - readStarted;
          _recordPresentationCacheRead(
            asset: asset,
            id: id,
            bytes: cached.bytes,
            source: cached.memoryHit
                ? 'artifact-byte-cache'
                : 'artifact-cache',
            readMode: cached.memoryHit
                ? 'memory-hit'
                : cached.joined
                    ? 'joined-read-all'
                    : 'read-all',
            readMicros: readMicros,
            memoryHit: cached.memoryHit,
            joined: cached.joined,
            sessionState: session?.state.name,
          );
          return cached.bytes;
        }
      } on Object catch (error) {
        token.throwIfCancelled();
        trace.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.taskFailed,
            identityHash: id.key,
            revision: revision,
            payload: <String, Object?>{
              'lane': 'artifact-cache-manager-read',
              'consumer': 'pipeline-presentation',
              'reason': error.toString(),
              'readMicros': clock.nowMicros() - readStarted,
              'fallback': 'session',
            },
          ),
        );
      }
    }

    if (session == null) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'presentation requested bytes before transfer acquisition',
      );
    }
    if (session.state != DownloadState.promoted) {
      await _waitForPromotion(session, token);
    }
    token.throwIfCancelled();
    if (session.residentBodyBacked &&
        _isDirectImmutableLocalUri(asset.uri)) {
      return _readDirectImmutableSource(asset, id, session, token);
    }
    final artifactReadStarted = clock.nowMicros();
    final cacheRead = cache == null
        ? null
        : await cache.readSessionArtifact(
            id: id,
            length: session.artifact.committedLength,
            loader: () => _transferRuntime.readArtifact(session.artifact),
          );
    final Uint8List bytes;
    if (cacheRead != null) {
      bytes = cacheRead.bytes;
    } else {
      bytes = await _transferRuntime.readArtifact(session.artifact);
    }
    token.throwIfCancelled();
    final artifactReadMicros = clock.nowMicros() - artifactReadStarted;
    _recordPresentationCacheRead(
      asset: asset,
      id: id,
      bytes: bytes,
      source: 'session-artifact',
      readMode: cacheRead == null
          ? 'session-read-all'
          : cacheRead.memoryHit
              ? 'memory-hit'
              : cacheRead.joined
                  ? 'joined-session-read-all'
                  : 'session-read-all',
      readMicros: artifactReadMicros,
      memoryHit: cacheRead?.memoryHit ?? false,
      joined: cacheRead?.joined ?? false,
    );
    return bytes;
  }

  Future<Uint8List> _readDirectImmutableSource(
    PageAsset asset,
    DownloadId id,
    DownloadSession session,
    MediaLoadToken token,
  ) async {
    final started = clock.nowMicros();
    final resumeValidators = session.resumeValidatorsFor(asset.uri);
    final response = await _baseTransportFor(asset.uri).open(
      asset.uri,
      validators: resumeValidators.canResume ? resumeValidators : null,
    );
    if (resumeValidators.canResume &&
        !resumeValidators.matches(response.validators)) {
      await response.discard();
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'direct immutable image source revision changed',
      );
    }
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.bytes) {
        token.throwIfCancelled();
        if (chunk.isNotEmpty) builder.add(chunk);
      }
    } finally {
      await response.discard();
    }
    token.throwIfCancelled();
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'direct immutable image source produced no bytes',
      );
    }
    final expected = session.totalLength ?? response.totalLength;
    if (expected != null && bytes.lengthInBytes != expected) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'direct immutable image source length changed: '
            '${bytes.lengthInBytes}/$expected',
      );
    }
    _recordPresentationCacheRead(
      asset: asset,
      id: id,
      bytes: bytes,
      source: 'direct-source',
      readMode: 'direct-read-all',
      readMicros: clock.nowMicros() - started,
      memoryHit: false,
      joined: false,
      sessionState: session.state.name,
    );
    return bytes;
  }

  bool _isDirectImmutableLocalUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'file' || scheme == 'content' || scheme == 'asset';
  }

  void _recordPresentationCacheRead({
    required PageAsset asset,
    required DownloadId id,
    required Uint8List bytes,
    required String source,
    required String readMode,
    required int readMicros,
    required bool memoryHit,
    required bool joined,
    String? sessionState,
  }) {
    final safeMicros = readMicros < 0 ? 0 : readMicros;
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.sourceRead,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'source': source,
          'sourceClass': source == 'session-artifact' ||
                  source == 'direct-source'
              ? _readerSourceClass(asset.uri)
              : 'persistent-artifact',
          'uriScheme': asset.uri.scheme.isEmpty ? 'file' : asset.uri.scheme,
          'bytes': bytes.lengthInBytes,
          'chunks': 1,
          'minChunkBytes': bytes.lengthInBytes,
          'maxChunkBytes': bytes.lengthInBytes,
          'firstChunkMicros': safeMicros,
          'streamMicros': safeMicros,
          'readMicros': safeMicros,
          'artifactReadMode': readMode,
          'memoryCacheHit': memoryHit,
          'memoryCacheJoined': joined,
          'artifactMaterializeMicros': safeMicros,
          'hotCacheEntries': _artifactCacheManager?.memoryEntryCount ?? 0,
          'hotCacheBytes': _artifactCacheManager?.memoryBytes ?? 0,
          if (sessionState != null) 'sessionState': sessionState,
          'completed': true,
          'consumer': 'pipeline-presentation',
        },
      ),
    );
  }

  Future<void> _waitForPromotion(
    DownloadSession session,
    MediaLoadToken token,
  ) async {
    token.throwIfCancelled();
    final ready = Completer<void>();
    void acceptSnapshot(DownloadSnapshot snapshot) {
      if (ready.isCompleted) return;
      switch (snapshot.state) {
        case DownloadState.promoted:
          ready.complete();
        case DownloadState.failed:
          ready.completeError(
            snapshot.failure ??
                const Failure(
                  code: ErrorCode.network,
                  message: 'pipeline media download failed',
                ),
          );
        case DownloadState.disposed:
          ready.completeError(
            const Failure(
              code: ErrorCode.cancelled,
              message: 'pipeline media session was disposed',
            ),
          );
        case DownloadState.idle:
        case DownloadState.queued:
        case DownloadState.receiving:
        case DownloadState.sealed:
          break;
      }
    }
    acceptSnapshot(session.snapshot);
    if (ready.isCompleted) return ready.future;
    session.addSnapshotListener(acceptSnapshot, fireImmediately: false);
    try {
      acceptSnapshot(session.snapshot);
      await Future.any<void>(<Future<void>>[
        ready.future,
        token.whenCancelled.then<void>((_) => token.throwIfCancelled()),
      ]);
    } finally {
      session.removeSnapshotListener(acceptSnapshot);
    }
  }

  Transport _baseTransportFor(Uri uri) {
    if (_loaderTransport.contains(uri)) return _loaderTransport;
    if (uri.scheme.isEmpty || uri.scheme == 'asset') return _assetTransport;
    return _ioTransport;
  }

  Transport _transportFor(Uri uri) =>
      _artifactCacheTransport ?? _baseTransportFor(uri);

  /// Returns only transports whose lifetime is independent of this Reader.
  /// LoaderTransport is immutable and owns no closeable socket/client; its
  /// source callbacks are composition-provided capabilities. The returned
  /// read-through transport may therefore be retained by one admitted physical
  /// task after this Reader consumer is disposed. Reader-owned IoTransport is
  /// intentionally excluded and remains protected by the dispose barrier.
  Transport? _retainedTransferTransportFor(Uri uri) =>
      _loaderTransport.contains(uri) ? _transportFor(uri) : null;

  void _observeDownloadSession(DownloadSession session) {
    _ingresses.attach(session);
  }

  void _handleSourceKindObserved(DownloadId id, ContentKind kind) {
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = chapter.pages.indexWhere(
        (page) => page.pageId == id.content.pageId,
      );
      if (pageIndex < 0) return;
      final changed = _binding?.observeWebpTransportCost(
            pageIndex: pageIndex,
            webp: kind == ContentKind.webp,
          ) ??
          false;
      if (!changed) return;
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.artifactSource,
          identityHash: id.key,
          revision: revision,
          payload: <String, Object?>{
            'stage': 'runtime-transport-cost',
            'action': kind == ContentKind.webp
                ? 'webp-observed'
                : 'webp-cleared',
            'pageIndex': pageIndex,
            'contentKind': kind.name,
          },
        ),
      );
      artifactReadScheduler.refresh();
    });
  }

  void _handleDecodeRefillObserved(
    DecodeRefillDecision decision,
    int demandRevision,
  ) {
    scheduleMicrotask(() {
      if (_disposed) return;
      _binding?.observeDecodeWaterline(
        planRevision: demandRevision,
        stage: decision.stage,
      );
    });
  }

  void _handleFrameDecoded(DecodeId id, DecodeSnapshot snapshot) {
    final width = snapshot.decodedWidth;
    final height = snapshot.decodedHeight;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = chapter.pages.indexWhere(
        (page) => page.pageId == id.download.content.pageId,
      );
      if (pageIndex < 0) return;
      final asset = chapter.pages[pageIndex];
      final prior = _pageDimensions.value[asset.assetKey];
      if (prior != null && prior.width == width && prior.height == height) {
        return;
      }
      _pageDimensions.value = Map<String, PipelinePageDimensions>.unmodifiable(
        <String, PipelinePageDimensions>{
          ..._pageDimensions.value,
          asset.assetKey: PipelinePageDimensions(
            width: width,
            height: height,
          ),
        },
      );
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.pageDimensionsResolved,
          identityHash: id.download.key,
          revision: revision,
          payload: <String, Object?>{
            'pageIndex': pageIndex,
            'width': width,
            'height': height,
            'source': 'decode-frame',
          },
        ),
      );
    });
  }

  void _handleAnimationResolved(DecodeId id, AnimationInfo animation) {
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = chapter.pages.indexWhere(
        (page) => page.pageId == id.download.content.pageId,
      );
      if (pageIndex < 0) return;
      final animated = animation.frameCount > 1;
      final changed = _binding?.classifyPage(
            pageIndex: pageIndex,
            animated: animated,
          ) ??
          false;
      if (!changed) return;
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.mediaClassified,
          identityHash: id.download.key,
          revision: revision,
          payload: <String, Object?>{
            'pageIndex': pageIndex,
            'animated': animated,
            'frameCount': animation.frameCount,
            'loopCount': animation.loopCount,
            'complete': animation.complete,
          },
        ),
      );
      artifactReadScheduler.refresh();
      _syncPageOutputs();
    });
  }

  void _handleUploadSnapshot(DecodeId id, UploadSnapshot snapshot) {
    _pageOutputs[id.download.key]?._accept(id, snapshot);
    // Pipeline reconciliation can create the upload session after the viewport
    // observation was applied. Re-project the existing viewport so a late
    // transition session is frozen and a late current session is resumed before
    // its first presentation deadline is armed.
    _binding?.resyncPlayback();
    _ensurePlaybackTicker();
    _maybeReleaseStartupCurrentDownload();
    _maybeReleaseStartupArtifactPressure();
  }

  void _holdStartupArtifactPressureFor(DownloadId current) {
    if (_artifactCacheTransport == null || _disposed) return;
    if (_startupArtifactPressureDownload == current &&
        _startupArtifactPressure != null) {
      return;
    }
    _releaseStartupArtifactPressure();
    _startupArtifactPressureDownload = current;
    _startupArtifactPressure = artifactReadScheduler.holdForegroundPressure();
  }

  void _syncStartupArtifactPressure() {
    if (_artifactCacheTransport == null || _disposed) {
      _releaseStartupArtifactPressure();
      return;
    }
    final uploads = _binding?.pipeline.currentPlan.uploads;
    DecodeId? current;
    if (uploads != null) {
      for (final entry in uploads.entries) {
        if (entry.value.role == PageRole.current) {
          current = entry.key;
          break;
        }
      }
    }
    if (current == null) {
      _releaseStartupArtifactPressure();
      return;
    }
    if (_startupOutputReady(current)) {
      _releaseStartupArtifactPressure();
      _releaseStartupCurrentDownload();
      return;
    }
    _holdStartupArtifactPressureFor(current.download);
  }

  void _maybeReleaseStartupCurrentDownload() {
    final held = _startupCurrentDownload;
    if (held == null) return;
    final uploads = _binding?.pipeline.currentPlan.uploads;
    if (uploads == null) {
      _releaseStartupCurrentDownload();
      return;
    }
    DecodeId? current;
    for (final entry in uploads.entries) {
      if (entry.value.role == PageRole.current) {
        current = entry.key;
        break;
      }
    }
    if (current == null || current.download != held) {
      _releaseStartupCurrentDownload();
      return;
    }
    if (_startupFirstOutputReady(current)) {
      _releaseStartupCurrentDownload();
    }
  }

  void _maybeReleaseStartupArtifactPressure() {
    final held = _startupArtifactPressureDownload;
    if (held == null) return;
    final uploads = _binding?.pipeline.currentPlan.uploads;
    if (uploads == null) {
      _releaseStartupArtifactPressure();
      return;
    }
    DecodeId? current;
    for (final entry in uploads.entries) {
      if (entry.value.role == PageRole.current) {
        current = entry.key;
        break;
      }
    }
    if (current == null || current.download != held) {
      _syncStartupArtifactPressure();
      return;
    }
    if (_startupOutputReady(current)) {
      _releaseStartupArtifactPressure();
      _releaseStartupCurrentDownload();
    }
  }

  bool _startupFirstOutputReady(DecodeId id) {
    final session = _downloads.find(id.download);
    if (session == null) return false;
    final download = session.snapshot;
    if (download.state == DownloadState.failed ||
        download.state == DownloadState.disposed) {
      return true;
    }
    final upload = _uploads.find(id)?.snapshot;
    if (upload == null) return false;
    return upload.state == UploadState.failed ||
        upload.state == UploadState.disposed ||
        (upload.state == UploadState.ready && upload.presentClaims > 0);
  }

  bool _startupOutputReady(DecodeId id) {
    final session = _downloads.find(id.download);
    if (session == null) return false;
    final download = session.snapshot;
    if (download.state == DownloadState.failed ||
        download.state == DownloadState.disposed) {
      return true;
    }
    final upload = _uploads.find(id)?.snapshot;
    if (upload == null) return false;
    if (upload.state == UploadState.failed ||
        upload.state == UploadState.disposed) {
      return true;
    }
    if (upload.state != UploadState.ready || upload.presentClaims <= 0) {
      return false;
    }
    final decode = _decodes.find(id)?.snapshot;
    if (decode == null) return true;
    final animation = decode.animation;
    final authoritativeStatic =
        animation.complete && animation.frameCount <= 1;
    return authoritativeStatic ||
        decode.state == DecodeState.ended ||
        decode.state == DecodeState.failed ||
        decode.state == DecodeState.disposed ||
        decode.depth > 4;
  }

  void _releaseStartupCurrentDownload() {
    if (_startupCurrentDownload == null) return;
    _startupCurrentDownload = null;
    _coordinator.refreshDownloadScheduling(sessionId);
  }

  void _releaseStartupArtifactPressure() {
    _startupArtifactPressure?.release();
    _startupArtifactPressure = null;
    _startupArtifactPressureDownload = null;
  }

  int _downloadBucketLimit(DownloadId id) {
    final stableLimit = _profile.downloadBucketLimit(id);
    final current = _startupCurrentDownload;
    if (stableLimit <= 1 || current == null) {
      return stableLimit;
    }
    final currentBucket = _profile.downloadBucket(current);
    return currentBucket == 'local' && _profile.downloadBucket(id) == 'local'
        ? 1
        : stableLimit;
  }

  int _artifactReadPriority(DownloadId id) =>
      _binding?.pipeline.currentPlan.downloads[id]?.priority ?? 0;

  DecodeId? _activeUploadIdentity(DownloadId download) {
    final uploads = _binding?.pipeline.currentPlan.uploads;
    if (uploads == null) {
      return null;
    }
    for (final id in uploads.keys) {
      if (id.download == download) {
        return id;
      }
    }
    return null;
  }

  void _syncPageStreams() {
    for (final stream in _pageStreams.values) {
      stream.refreshBinding();
    }
  }

  void _syncPageOutputs() {
    for (final output in _pageOutputs.values) {
      output._bind(_activeUploadIdentity(output.download));
    }
  }

  void _ensurePlaybackTicker() {
    final ids = _binding?.pipeline.currentPlan.uploads.keys;
    final deadline = ids == null
        ? null
        : _uploads.earliestPlaybackDeadlineMicros(ids);
    if (_playbackPaused || deadline == null || _disposed) {
      _cancelPlaybackWake();
      return;
    }
    if (_playbackTicker != null && _playbackWakeAtMicros == deadline) {
      return;
    }
    _playbackTicker?.cancel();
    _playbackWakeAtMicros = deadline;
    final remainingMicros = deadline - clock.nowMicros();
    _playbackTicker = Timer(
      Duration(microseconds: remainingMicros > 0 ? remainingMicros : 0),
      () {
        _playbackTicker = null;
        _playbackWakeAtMicros = null;
        _advanceDueFrames();
      },
    );
  }

  void _cancelPlaybackWake() {
    _playbackTicker?.cancel();
    _playbackTicker = null;
    _playbackWakeAtMicros = null;
  }

  void _advanceDueFrames() {
    if (_disposed || _playbackPaused) {
      _ensurePlaybackTicker();
      return;
    }
    final uploads = _binding?.pipeline.currentPlan.uploads.keys;
    if (uploads == null || uploads.isEmpty) {
      _ensurePlaybackTicker();
      return;
    }
    for (final id in uploads.toList(growable: false)) {
      _coordinator.advanceDueFrame(sessionId, id);
    }
    _maybeReleaseStartupCurrentDownload();
    _maybeReleaseStartupArtifactPressure();
    _ensurePlaybackTicker();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _invalidateObservationQueue();
    _disposed = true;
    final disposeStartedAtMicros = clock.nowMicros();
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionDisposeStarted,
        revision: revision,
        payload: <String, Object?>{
          'downloadSessions': _ingresses.projections.length,
          'physicalDownloadSessions': _downloads.sessions.length,
          'physicalTransferOwnerShared': true,
          'decodeSessions': _decodes.sessions.length,
          'uploadSessions': _uploads.sessions.length,
        },
      ),
    );
    _cancelPlaybackWake();
    _releaseStartupArtifactPressure();
    _startupCurrentDownload = null;
    final binding = _binding;
    final readerSessionId = _readerSessionId;
    _binding = null;
    _readerSessionId = null;
    binding?.detach(readerSessionId ?? sessionId);
    artifactReadScheduler.refresh();
    for (final output in _pageOutputs.values) {
      output._dispose();
    }
    _pageOutputs.clear();
    transferProgress.dispose();
    _pageDimensions.dispose();
    _uploads.removeListener(_handleUploadSnapshot);
    final coordinatorDisposeStartedAtMicros = clock.nowMicros();
    // The coordinator removes this Reader's transfer consumer and waits for any
    // active task that captured this Reader-owned transport to exit. Only after
    // this barrier is it safe to close _ioTransport.
    await _coordinator.dispose();
    final coordinatorDisposeMicros =
        clock.nowMicros() - coordinatorDisposeStartedAtMicros;
    _transferRuntime.detachPhysicalTrace(
      localPhysicalTraceSink: _memoryTrace,
      sharedPhysicalTraceSink: _sharedTraceSink,
    );
    _uploads.dispose();
    _decodes.dispose();
    _ingresses.dispose();
    _streamingSources.dispose();
    final mediaCloseStartedAtMicros = clock.nowMicros();
    await _media.close();
    final mediaCloseMicros = clock.nowMicros() - mediaCloseStartedAtMicros;
    _ioTransport.close(force: true);
    for (final stream in _pageStreams.values) {
      stream.dispose();
    }
    _pageStreams.clear();
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionDisposed,
        payload: <String, Object?>{
          'disposeMicros': clock.nowMicros() - disposeStartedAtMicros,
          'coordinatorDisposeMicros': coordinatorDisposeMicros,
          // Preserved diagnostic keys now explicitly mean no Reader-local
          // physical-owner teardown. The shared runtime drains/disposes only at
          // composition shutdown.
          'handoffDrainMicros': 0,
          'mediaCloseMicros': mediaCloseMicros,
          'downloadsDisposeMicros': 0,
          'workspaceDisposeMicros': 0,
          'physicalTransferOwnerShared': true,
        },
      ),
    );
  }

  void _requireOpen() {
    if (_disposed) throw StateError('pipeline Reader session is disposed');
  }
}

String _readerSourceClass(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'content') {
    return 'local-document';
  }
  if (scheme.isEmpty || scheme == 'file') {
    return 'local-file';
  }
  if (scheme == 'asset') {
    return 'asset';
  }
  if (scheme.startsWith('mihon') || scheme.startsWith('venera')) {
    return 'plugin-resource';
  }
  return 'remote';
}
