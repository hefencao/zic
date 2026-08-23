import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'asset_bundle_transport.dart';
import 'media_load_token.dart';
import 'pipeline_frame_scheduler.dart';
import 'pipeline_media_runtime.dart';
import 'pipeline_page_stream.dart';
import 'pipeline_transfer_progress.dart';
import 'reader_pipeline_profile.dart';

part 'pipeline_page_dimensions.dart';
part 'pipeline_page_output.dart';

typedef PipelineArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);

const Duration _readerSessionRetentionDuration = Duration(minutes: 2);
const int _maxRetainedReaderSessions = 1;

Map<String, int> _indexChapterPages(ChapterManifest chapter) {
  final result = <String, int>{};
  for (final page in chapter.pages) {
    if (result.containsKey(page.pageId)) {
      throw StateError('duplicate Reader pageId: ${page.pageId}');
    }
    result[page.pageId] = page.index;
  }
  return Map<String, int>.unmodifiable(result);
}

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
        _profile = readerPipelineProfileFor(
          chapter,
          ),
        _assetTransport = AssetBundleTransport.root(),
        _ioTransport = IoTransport(
          http: HttpTransport(userAgentProvider: userAgentProvider),
        ),
        _loaderTransport = LoaderTransport(loaderSources),
        _pageDimensions = _PipelinePageDimensionsPublisher(),
        _pageIndexByPageId = _indexChapterPages(chapter) {
    trace = traceSink ?? const NoopTraceSink();
    _media = mediaRuntimeFactory.create(
      sessionId: sessionId,
      clock: clock,
      traceSink: trace,
    );
    transferProgress = PipelineTransferProgressPublisher(
      frameScheduler: _media.frameScheduler,
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
    _residentReplaySource = _transferRuntime.residentReplaySource(
      priorityFor: _artifactReadPriority,
    );
    _ingresses = DownloadIngressProjectionRegistry(
      sources: _streamingSources,
      scopePrefix: 'reader:$sessionId',
      residentReplaySource: _residentReplaySource,
    );
    _downloads = _transferRuntime.registry;
    _downloadTransfer = _transferRuntime.attachConsumer(
      scopeId: 'reader:$sessionId',
      transportFor: _transportFor,
      retainedTransportFor: _retainedTransferTransportFor,
      consumerTraceSink: trace,
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
  late final DownloadResidentReplaySource _residentReplaySource;
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
  final Set<DecodeId> _animatedOutputs = <DecodeId>{};
  // DownloadSession publishes source-canvas metadata as soon as the WebP
  // prefix is available. Keep one listener per physical session so the
  // matching output lease can be created before the first decoded frame is
  // handed to UploadSession. The listener is removed with the Reader session;
  // retaining a Reader keeps it because the physical session may continue to
  // receive bytes while the route is temporarily detached.
  final Map<DownloadSession, DownloadSnapshotListener>
      _outputPrewarmSnapshotListeners =
      <DownloadSession, DownloadSnapshotListener>{};
  // Platform texture leases are dimension-specific. Keep the exact raster
  // size requested for each decode identity so a viewport-sized prewarm is
  // never mistaken for a reusable output when the source is smaller or has a
  // different aspect ratio.
  final Map<DecodeId, ({int width, int height})> _outputPrewarmSizes =
      <DecodeId, ({int width, int height})>{};
  // A source-canvas callback can arrive while a visible PageView frame is
  // being laid out/painted. Keep that exact request latest-wins and start it
  // through the presentation adapter's idle boundary instead of posting
  // another platform texture create into the same UI-critical turn. Detached
  // current gallery outputs (no listener or no resident surface) still
  // prewarm immediately so the first visible frame cannot be blank; deferred
  // next/transition outputs are drained one platform create per idle task.
  final Map<DecodeId, ({int width, int height})> _deferredOutputPrewarms =
      <DecodeId, ({int width, int height})>{};
  bool _outputPrewarmIdleScheduled = false;
  Timer? _playbackTicker;
  int? _playbackWakeAtMicros;
  bool _playbackPaused = false;
  late final PipelineTransferProgressPublisher transferProgress;
  final _PipelinePageDimensionsPublisher _pageDimensions;
  final Map<String, int> _pageIndexByPageId;
  PipelinePageDimensionsFeed get pageDimensions => _pageDimensions;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  ArtifactCachePressureLease? _startupArtifactPressure;
  DownloadId? _startupArtifactPressureDownload;
  DownloadId? _startupCurrentDownload;
  bool _disposed = false;
  bool _retainedForReaderReentry = false;
  ReaderObs? _pendingObservation;
  ReaderObs? _lastAcceptedControlObservation;
  bool _observationDrainScheduled = false;
  bool _observationControlDirty = false;
  int _observationGeneration = 0;
  DownloadId? _lastControlCurrentDownload;
  DecodeTarget? _lastControlDecodeTarget;

  bool get isDisposed => _disposed;
  int get revision => _binding?.revision ?? 0;
  RendererKind get renderer => _media.renderer;

  void attach(DecodeTarget target) {
    _requireOpen();
    _invalidateObservationQueue();
    _lastAcceptedControlObservation = null;
    _lastControlCurrentDownload = null;
    _lastControlDecodeTarget = null;
    _observationControlDirty = false;
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
    _observationControlDirty = true;
  }

  /// Enqueues the latest Reader viewport observation behind the UI/navigation
  /// callback boundary. ReaderView must never synchronously execute demand,
  /// transfer or decode reconciliation. The drain uses an ordinary event turn,
  /// not the microtask queue: page-boundary control work must yield back to the
  /// engine/platform event loop after the current Flutter frame before it may
  /// consume the Dart UI isolate. Coverage fraction, velocity and
  /// logical-position changes that preserve the same discrete control state do
  /// not re-enter Pipeline in either paged or continuous mode; the target's
  /// transition visibility bucket remains an explicit horizontal boundary.
  /// A pending drain is still latest-wins, so a real current/target/visible or
  /// interaction-boundary change replaces stale work before reconciliation.
  void enqueueObservation(ReaderObs observation) {
    if (_disposed || _retainedForReaderReentry) {
      return;
    }
    _pendingObservation = observation;
    if (_observationDrainScheduled) {
      return;
    }
    if (!_observationControlDirty &&
        _sameControlObservation(_lastAcceptedControlObservation, observation)) {
      _pendingObservation = null;
      return;
    }
    _scheduleObservationDrain();
  }

  void _scheduleObservationDrain() {
    if (_observationDrainScheduled) return;
    _observationDrainScheduled = true;
    final generation = _observationGeneration;
    // scheduleMicrotask here starves platform/input/vsync events until the
    // whole plan/reconcile/lane-pump control transaction has completed. A
    // zero-delay Timer keeps the same latest-wins semantics while yielding one
    // ordinary event-loop turn after the frame that produced the observation.
    Timer.run(() => _drainObservation(generation));
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
    if (!_observationControlDirty &&
        _sameControlObservation(_lastAcceptedControlObservation, observation)) {
      return;
    }
    var accepted = false;
    try {
      accept(observation);
      accepted = true;
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
    if (accepted) {
      _lastAcceptedControlObservation = observation;
      _observationControlDirty = false;
    }
    if (_pendingObservation != null) {
      _scheduleObservationDrain();
    }
  }

  bool _sameControlObservation(ReaderObs? a, ReaderObs b) {
    if (a == null ||
        a.direction != b.direction ||
        a.currentIndex != b.currentIndex ||
        a.stableIndex != b.stableIndex ||
        a.targetCoverage?.pageIndex != b.targetCoverage?.pageIndex ||
        _targetVisibilityBucket(a) != _targetVisibilityBucket(b) ||
        _playbackPhaseBucket(a) != _playbackPhaseBucket(b) ||
        _playbackDominantIndex(a) != _playbackDominantIndex(b) ||
        _controlInteraction(a.interaction) !=
            _controlInteraction(b.interaction) ||
        a.visibleCoverages.length != b.visibleCoverages.length) {
      return false;
    }
    for (var index = 0; index < a.visibleCoverages.length; index++) {
      if (a.visibleCoverages[index].pageIndex !=
          b.visibleCoverages[index].pageIndex) {
        return false;
      }
    }
    return true;
  }

  int _targetVisibilityBucket(ReaderObs observation) {
    final target = observation.targetCoverage;
    if (target == null || target.fraction <= 0) return 0;
    // RoleResolver promotes a horizontal target to transition at 0.15. The
    // vertical resolver treats any positive target coverage as visible. Keep
    // this semantic bucket in the latest-wins gate so fractional PageView
    // updates do not rerun Pipeline policy while preserving the exact role
    // boundary that can change demand.
    if (observation.direction == ReadingDirection.vertical) return 1;
    return target.fraction >= 0.15 ? 2 : 1;
  }

  int _playbackPhaseBucket(ReaderObs observation) {
    if (observation.direction == ReadingDirection.vertical &&
        observation.interaction != Interaction.idle) {
      return 3; // continuous
    }
    final target = observation.targetCoverage;
    if (target == null || observation.interaction == Interaction.idle) {
      return 0; // idle
    }
    final current = observation.currentCoverage;
    if (target.fraction >= 0.5 || current.fraction >= 0.5) {
      return 1; // dominant
    }
    if (current.fraction >= 0.15 && target.fraction >= 0.15) {
      return 2; // overlap
    }
    return 1; // dominant fallback used by ViewportResolver
  }

  int _playbackDominantIndex(ReaderObs observation) {
    final phase = _playbackPhaseBucket(observation);
    if (phase == 2 || phase == 3) return -1;
    final target = observation.targetCoverage;
    if (target == null || observation.interaction == Interaction.idle) {
      return observation.currentCoverage.pageIndex;
    }
    return target.fraction > observation.currentCoverage.fraction
        ? target.pageIndex
        : observation.currentCoverage.pageIndex;
  }

  int _controlInteraction(Interaction interaction) => switch (interaction) {
        Interaction.dragging ||
        Interaction.scrolling ||
        Interaction.settling => 1,
        Interaction.idle => 2,
        Interaction.scrubbing => 3,
        Interaction.jumping => 4,
      };

  void _invalidateObservationQueue() {
    _observationGeneration++;
    _observationDrainScheduled = false;
    _pendingObservation = null;
    _lastAcceptedControlObservation = null;
    _observationControlDirty = false;
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
    final controlIdentityChanged =
        _lastControlCurrentDownload != currentDownload ||
        _lastControlDecodeTarget != target;
    if (controlIdentityChanged) {
      final prewarmer = _media is PipelineOutputPrewarmer
          ? _media as PipelineOutputPrewarmer
          : null;
      if (prewarmer != null) {
        final size = _anticipatedOutputSize(currentDownload, target);
        if (size != null) {
          _requestOutputPrewarm(
            prewarmer,
            id: DecodeId(
              download: currentDownload,
              physicalWidth: target.physicalWidth,
              physicalHeight: target.physicalHeight,
              pixelFormat: target.pixelFormat,
              renderer: target.renderer,
            ),
            width: size.width,
            height: size.height,
          );
        }
      }
      final currentOutput = _pageOutputs[currentDownload.key]?.snapshot;
      if (currentOutput?.hasSurface != true) {
        _startupCurrentDownload = currentDownload;
      } else if (_startupCurrentDownload == currentDownload) {
        _releaseStartupCurrentDownload();
      }
      _holdStartupArtifactPressureFor(currentDownload);
    }
    final revisionBefore = binding.pipeline.revision;
    binding.accept(observation);
    final planChanged = binding.pipeline.revision != revisionBefore;
    _lastControlCurrentDownload = currentDownload;
    _lastControlDecodeTarget = target;
    if (!planChanged && !controlIdentityChanged) {
      return;
    }
    _syncPageStreams();
    transferProgress.select(_downloads.find(currentDownload));
    _syncStartupArtifactPressure();
    artifactReadScheduler.refresh();
    // The first accepted plan is already authoritative for detached gallery
    // prewarm, even though the retained observation is written only after the
    // full control transaction returns. Pass it explicitly so a ready
    // current/next/transition output cannot wait for the PageView host to
    // mount.
    _syncPageOutputs(observation: observation);
    _ensurePlaybackTicker();
  }

  ({int width, int height})? _anticipatedOutputSize(
    DownloadId id,
    DecodeTarget target,
  ) {
    final pageIndex = _pageIndexByPageId[id.content.pageId];
    if (pageIndex == null) return null;
    final asset = chapter.pages[pageIndex];
    final download = _downloads.find(id)?.snapshot;
    final decodeId = _activeDecodeIdentity(id);
    final decoded = decodeId == null ? null : _decodes.find(decodeId)?.snapshot;
    // Prefer source-canvas facts because they own layout/aspect semantics.
    // Once a frame has already decoded, its aligned raster is an exact output
    // size fallback; omitting it leaves a narrow race where the first upload
    // creates a SurfaceProducer before the detached prewarm can start.
    final sourceWidth = asset.width ??
        download?.sourceCanvasWidth ??
        decoded?.decodedWidth;
    final sourceHeight = asset.height ??
        download?.sourceCanvasHeight ??
        decoded?.decodedHeight;
    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      return null;
    }
    final raster = AlignedRasterSize.fit(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      maxWidth: target.physicalWidth,
      maxHeight: target.physicalHeight,
      alignment: target.alignment,
    );
    return (width: raster.width, height: raster.height);
  }

  void _requestOutputPrewarm(
    PipelineOutputPrewarmer prewarmer, {
    required DecodeId id,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) return;
    // Once UploadSession has claimed a frame, its uploader owns the
    // authoritative texture lease. A deferred request that reaches this
    // boundary must not create a second SurfaceProducer while that upload (or
    // its ready resident frame) is still settling.
    final upload = _uploads.find(id)?.snapshot;
    if (upload?.state == UploadState.uploading ||
        (upload?.state == UploadState.ready && upload?.frameIndex != null)) {
      _deferredOutputPrewarms.remove(id);
      return;
    }
    final size = (width: width, height: height);
    if (_outputPrewarmSizes[id] == size ||
        _deferredOutputPrewarms[id] == size) {
      return;
    }
    if (_shouldDeferOutputPrewarm(id)) {
      _deferredOutputPrewarms[id] = size;
      _scheduleOutputPrewarmIdle();
      return;
    }
    _startOutputPrewarm(
      prewarmer,
      id: id,
      width: width,
      height: height,
      size: size,
    );
  }

  bool _shouldDeferOutputPrewarm(DecodeId id) {
    final scheduler = _media.frameScheduler;
    final frameBusy =
        scheduler.inPersistentCallbacks || scheduler.hasScheduledFrame;
    if (!frameBusy) return false;

    final role = _binding?.pipeline.currentPlan.uploads[id]?.role;
    final output = _pageOutputs[id.download.key];
    final detached = output == null ||
        output._listeners.isEmpty ||
        !output.snapshot.hasSurface;

    // Current has a first-frame deadline. If its host is not mounted yet, or
    // it has no resident surface to display, let the exact prewarm proceed in
    // this turn. A next/transition lease is invisible until PageView catches
    // up, so its platform create must yield to the frame already in flight.
    if (role == PageRole.current) return !detached;
    if (role == PageRole.next || role == PageRole.transition) return true;
    return !detached;
  }

  void _startOutputPrewarm(
    PipelineOutputPrewarmer prewarmer, {
    required DecodeId id,
    required int width,
    required int height,
    required ({int width, int height}) size,
  }) {
    _deferredOutputPrewarms.remove(id);
    _outputPrewarmSizes[id] = size;
    unawaited(
      _prewarmOutput(
        prewarmer,
        id: id.download,
        width: width,
        height: height,
        identity: id,
        size: size,
      ),
    );
  }

  void _scheduleOutputPrewarmIdle() {
    if (_outputPrewarmIdleScheduled) return;
    _outputPrewarmIdleScheduled = true;
    _media.frameScheduler.scheduleIdle(() {
      _outputPrewarmIdleScheduled = false;
      if (_disposed || _deferredOutputPrewarms.isEmpty) return;
      final prewarmer = _media is PipelineOutputPrewarmer
          ? _media as PipelineOutputPrewarmer
          : null;
      final uploads = _binding?.pipeline.currentPlan.uploads;
      if (prewarmer == null || uploads == null) {
        _deferredOutputPrewarms.clear();
        return;
      }

      DecodeId? selectedId;
      ({int width, int height})? selectedSize;
      var selectedPriority = -1;
      for (final entry in _deferredOutputPrewarms.entries.toList(
        growable: false,
      )) {
        final role = uploads[entry.key]?.role;
        final priority = switch (role) {
          PageRole.current => 3,
          PageRole.transition => 2,
          PageRole.next => 1,
          _ => 0,
        };
        if (priority == 0) {
          _deferredOutputPrewarms.remove(entry.key);
          continue;
        }
        if (priority > selectedPriority) {
          selectedId = entry.key;
          selectedSize = entry.value;
          selectedPriority = priority;
        }
      }
      final id = selectedId;
      final size = selectedSize;
      if (id == null || size == null) return;

      _deferredOutputPrewarms.remove(id);
      _startOutputPrewarm(
        prewarmer,
        id: id,
        width: size.width,
        height: size.height,
        size: size,
      );

      // Creating a SurfaceProducer crosses the Android main-thread boundary.
      // This callback is a Priority.idle handoff, so no create can run while
      // Flutter has animation/touch callbacks pending. Keep at most one such
      // create per idle task; another pending page gets a later idle slot
      // instead of sharing the first UI budget window.
      if (_deferredOutputPrewarms.isNotEmpty) {
        _scheduleOutputPrewarmIdle();
      }
    });
  }

  Future<void> _prewarmOutput(
    PipelineOutputPrewarmer prewarmer, {
    required DownloadId id,
    required int width,
    required int height,
    required DecodeId identity,
    required ({int width, int height}) size,
  }) async {
    try {
      await prewarmer.prewarmOutput(width: width, height: height);
    } on Object catch (error) {
      if (_outputPrewarmSizes[identity] == size) {
        _outputPrewarmSizes.remove(identity);
      }
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
    _outputPrewarmSizes.clear();
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
        residentReplaySource: _residentReplaySource,
      )..refreshBinding(),
    );
  }

  PipelinePageOutputStream pageOutput(PageAsset asset) {
    _requireOpen();
    final id = readerPageDownloadId(chapter, asset);
    final output = _pageOutputs.putIfAbsent(
      id.key,
      () => _newPageOutput(id),
    );
    final uploadIdentity = _activeUploadIdentity(id);
    output._bind(
      uploadIdentity,
      retainedStaticIdentity: uploadIdentity == null
          ? _staticPresentationContinuityIdentity(id)
          : null,
    );
    return output;
  }

  PipelinePageOutputStream _newPageOutput(
    DownloadId id, {
    bool detachedPrewarm = false,
  }) {
    final output = PipelinePageOutputStream._(
      download: id,
      uploads: _uploads,
      decodes: _decodes,
      outputs: _media.outputs,
      frameScheduler: _media.frameScheduler,
      onPlaybackWakeChanged: _ensurePlaybackTicker,
    );
    if (detachedPrewarm) {
      output._enableDetachedPrewarm();
    }
    return output;
  }

  void _maybePrewarmPagedOutput(
    DecodeId id, {
    ReaderObs? observation,
  }) {
    final acceptedObservation = observation ?? _lastAcceptedControlObservation;
    if (acceptedObservation == null ||
        acceptedObservation.direction == ReadingDirection.vertical ||
        _media.renderer != RendererKind.androidTexture) {
      return;
    }
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    if (pageIndex == null) return;
    final demand = _binding?.pipeline.currentPlan.uploads[id];
    if (demand == null ||
        (demand.role != PageRole.current &&
            demand.role != PageRole.next &&
            demand.role != PageRole.transition)) {
      // Only the current/transition/next output roles can become visible
      // before a PageView host catches up. Keep this guard before creating
      // any detached projection for the outer window.
      return;
    }
    final asset = chapter.pages[pageIndex];
    final download = _downloads.find(id.download);
    if (!_mayUseNativeWebpOutput(asset, download?.contentKind)) {
      return;
    }
    // The DownloadSession observer can fire while the first control
    // transaction is still being committed, before the accepted observation
    // is written back to [_lastAcceptedControlObservation]. If source-canvas
    // metadata was already available at that boundary, make the exact lease
    // request here as part of the role decision instead of waiting for another
    // snapshot that may never arrive.
    final prewarmer = _media is PipelineOutputPrewarmer
        ? _media as PipelineOutputPrewarmer
        : null;
    final target = _binding?.pipeline.decodeTarget;
    final size = target == null
        ? null
        : _anticipatedOutputSize(id.download, target);
    if (prewarmer != null && size != null) {
      _requestOutputPrewarm(
        prewarmer,
        id: id,
        width: size.width,
        height: size.height,
      );
    }
    // The role plan is already a bounded visibility decision. Creating the
    // projection here must not wait for WebP sniffing/classification (or even
    // for the first upload snapshot): an opaque-URI page may be mounted while
    // its kind is still unknown. _bind only records the exact DecodeId; it
    // does not create demand, decode bytes or a platform texture. When the
    // upload becomes ready, the stream can therefore present its first frame
    // before PageView attaches its listener. Known non-WebP pages stay on
    // their existing Flutter image/GIF path and never pay for an unused
    // native texture.
    final upload = _uploads.find(id)?.snapshot;
    final readyUpload = upload?.state == UploadState.ready;
    final existing = _pageOutputs[id.download.key];
    if (existing != null &&
        existing._identity == id &&
        existing.snapshot.hasSurface) {
      // The bounded first frame is already resident. Mark even a stream that
      // was created by an attached host as detached-prewarm capable so a later
      // PageView dispose can stop presenting invisible successors without
      // waiting for another plan/classification boundary.
      final shouldTrace = !existing._detachedPrewarmEnabled;
      existing._enableDetachedPrewarm();
      if (shouldTrace) {
        _recordPagedOutputPrewarm(
          id: id,
          pageIndex: pageIndex,
          role: demand.role,
          readyUpload: readyUpload,
          output: existing,
          created: false,
          prewarmWidth: size?.width,
          prewarmHeight: size?.height,
        );
      }
      return;
    }
    final created = existing == null;
    final shouldTrace = existing == null ||
        existing._identity != id ||
        !existing._detachedPrewarmEnabled;
    final output = _pageOutputs.putIfAbsent(
      id.download.key,
      () => _newPageOutput(id.download, detachedPrewarm: true),
    );
    output._enableDetachedPrewarm();
    output._bind(id);
    if (shouldTrace) {
      _recordPagedOutputPrewarm(
        id: id,
        pageIndex: pageIndex,
        role: demand.role,
        readyUpload: readyUpload,
        output: output,
        created: created,
        prewarmWidth: size?.width,
        prewarmHeight: size?.height,
      );
    }
  }

  void _recordPagedOutputPrewarm({
    required DecodeId id,
    required int pageIndex,
    required PageRole role,
    required bool readyUpload,
    required PipelinePageOutputStream output,
    required bool created,
    int? prewarmWidth,
    int? prewarmHeight,
  }) {
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.pageOutputPrewarmed,
        identityHash: id.download.key,
        revision: revision,
        payload: <String, Object?>{
          'pageIndex': pageIndex,
          'role': role.name,
          'readyUpload': readyUpload,
          'detached': output._listeners.isEmpty,
          'created': created,
          if (prewarmWidth != null) 'prewarmWidth': prewarmWidth,
          if (prewarmHeight != null) 'prewarmHeight': prewarmHeight,
        },
      ),
    );
  }

  bool _mayUseNativeWebpOutput(PageAsset asset, ContentKind? contentKind) {
    switch (asset.contentKindHint) {
      case ContentKindHint.webp:
        return true;
      case ContentKindHint.unknown:
        break;
      case ContentKindHint.jpeg:
      case ContentKindHint.png:
      case ContentKindHint.gif:
      case ContentKindHint.avif:
      case ContentKindHint.fallback:
        return false;
    }
    switch (contentKind) {
      case ContentKind.webp:
        return true;
      case ContentKind.gif:
      case ContentKind.fallback:
        return false;
      case ContentKind.unknown:
      case null:
        break;
    }
    final path = asset.uri.path.toLowerCase();
    if (path.endsWith('.webp')) return true;
    const nonWebpSuffixes = <String>[
      '.gif',
      '.jpg',
      '.jpeg',
      '.png',
      '.avif',
      '.bmp',
      '.dib',
      '.tif',
      '.tiff',
      '.ico',
      '.heif',
    ];
    return !nonWebpSuffixes.any(path.endsWith);
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
    if (_isDirectImmutableLocalUri(asset.uri)) {
      // An immutable local source owns final bytes before, during and after
      // its transfer. Presentation must not queue behind the transfer copy,
      // CRC and promotion just to read the same immutable body back; the
      // validated direct read below is the exact post-promotion authority.
      return _readDirectImmutableSource(asset, id, session, token);
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
    // Keep the validated immutable body in the presentation memory tier so
    // rapid keep-alive eviction/remount cycles during fast continuous
    // scrolling do not repeat the same source read. Promotion still owns the
    // durable artifact; a later promotion remember() supersedes this entry.
    _artifactCacheManager?.remember(id: id, bytes: bytes);
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
    if (_outputPrewarmSnapshotListeners.containsKey(session)) return;
    late final DownloadSnapshotListener listener;
    listener = (snapshot) {
      _handleDownloadSnapshotForOutputPrewarm(snapshot);
    };
    _outputPrewarmSnapshotListeners[session] = listener;
    session.addSnapshotListener(listener);
  }

  void _handleDownloadSnapshotForOutputPrewarm(DownloadSnapshot snapshot) {
    if (_disposed ||
        _retainedForReaderReentry ||
        !snapshot.hasSourceCanvas ||
        _media.renderer != RendererKind.androidTexture) {
      return;
    }
    final observation = _lastAcceptedControlObservation;
    if (observation == null || observation.direction == ReadingDirection.vertical) {
      return;
    }
    final id = _activeUploadIdentity(snapshot.id);
    if (id == null || _outputPrewarmSizes.containsKey(id)) return;
    final demand = _binding?.pipeline.currentPlan.uploads[id];
    if (demand == null ||
        (demand.role != PageRole.current &&
            demand.role != PageRole.next &&
            demand.role != PageRole.transition)) {
      return;
    }
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    if (pageIndex == null) return;
    final asset = chapter.pages[pageIndex];
    if (!_mayUseNativeWebpOutput(asset, snapshot.contentKind)) return;
    final target = _binding?.pipeline.decodeTarget;
    if (target == null) return;
    final raster = AlignedRasterSize.fit(
      sourceWidth: snapshot.sourceCanvasWidth!,
      sourceHeight: snapshot.sourceCanvasHeight!,
      maxWidth: target.physicalWidth,
      maxHeight: target.physicalHeight,
      alignment: target.alignment,
    );
    final prewarmer = _media is PipelineOutputPrewarmer
        ? _media as PipelineOutputPrewarmer
        : null;
    if (prewarmer == null) return;
    _requestOutputPrewarm(
      prewarmer,
      id: id,
      width: raster.width,
      height: raster.height,
    );
  }

  void _handleSourceKindObserved(DownloadId id, ContentKind kind) {
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = _pageIndexByPageId[id.content.pageId];
      if (pageIndex == null) return;
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
    final decodedWidth = snapshot.decodedWidth;
    final decodedHeight = snapshot.decodedHeight;
    if (decodedWidth == null ||
        decodedHeight == null ||
        decodedWidth <= 0 ||
        decodedHeight <= 0) {
      return;
    }
    final observation = _lastAcceptedControlObservation;
    final demand = _binding?.pipeline.currentPlan.uploads[id];
    final prewarmer = _media is PipelineOutputPrewarmer
        ? _media as PipelineOutputPrewarmer
        : null;
    if (prewarmer != null &&
        observation != null &&
        observation.direction != ReadingDirection.vertical &&
        _media.renderer == RendererKind.androidTexture &&
        demand != null &&
        (demand.role == PageRole.current ||
            demand.role == PageRole.next ||
            demand.role == PageRole.transition)) {
      // The native decoder has already resolved the exact aligned canvas for
      // this page. Start the matching SurfaceProducer prewarm before the
      // upload lane asks for its lease; the old viewport-sized guess cannot be
      // reused for a smaller or differently-shaped source.
      _requestOutputPrewarm(
        prewarmer,
        id: id,
        width: decodedWidth,
        height: decodedHeight,
      );
    }
    unawaited(
      _resolveAndPublishPageDimensions(
        id,
        decodedWidth: decodedWidth,
        decodedHeight: decodedHeight,
      ),
    );
  }

  Future<void> _resolveAndPublishPageDimensions(
    DecodeId id, {
    required int decodedWidth,
    required int decodedHeight,
  }) async {
    if (_disposed) return;
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    if (pageIndex == null) return;
    final asset = chapter.pages[pageIndex];

    var width = decodedWidth;
    var height = decodedHeight;
    var basis = PipelinePageDimensionBasis.decodedRaster;
    var source = 'decode-raster-fallback';

    final sourceWidth = asset.width;
    final sourceHeight = asset.height;
    if (sourceWidth != null &&
        sourceHeight != null &&
        sourceWidth > 0 &&
        sourceHeight > 0) {
      width = sourceWidth;
      height = sourceHeight;
      basis = PipelinePageDimensionBasis.sourceCanvas;
      source = 'manifest-source-canvas';
    } else {
      final download = _downloads.find(id.download);
      final snapshot = download?.snapshot;
      final prefixWidth = snapshot?.sourceCanvasWidth;
      final prefixHeight = snapshot?.sourceCanvasHeight;
      if (prefixWidth != null &&
          prefixHeight != null &&
          prefixWidth > 0 &&
          prefixHeight > 0) {
        width = prefixWidth;
        height = prefixHeight;
        basis = PipelinePageDimensionBasis.sourceCanvas;
        source = 'physical-ingress-source-canvas';
      }
    }
    if (_disposed) return;
    final changed = _pageDimensions.publish(
      PipelinePageDimensions(
        pageIndex: pageIndex,
        assetKey: asset.assetKey,
        width: width,
        height: height,
        basis: basis,
      ),
    );
    if (!changed) return;
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
          'basis': basis.name,
          'source': source,
          'decodedWidth': decodedWidth,
          'decodedHeight': decodedHeight,
        },
      ),
    );
  }

  void _handleAnimationResolved(DecodeId id, AnimationInfo animation) {
    if (animation.frameCount > 1) {
      _animatedOutputs.add(id);
    } else {
      _animatedOutputs.remove(id);
    }
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = _pageIndexByPageId[id.download.content.pageId];
      if (pageIndex == null) return;
      // Classification can arrive after the upload snapshot. Promote the
      // detached projection immediately so a ready first frame is resident
      // before PageView mounts, even when the classification result itself
      // does not change the current policy bucket.
      _maybePrewarmPagedOutput(id);
      final animated = animation.frameCount > 1;
      final asset = chapter.pages[pageIndex];
      final download = _downloads.find(id.download);
      final localPresentationReady = !animated &&
          (_isDirectImmutableLocalUri(asset.uri) ||
              download?.residentBodyBacked == true);
      final changed = _binding?.classifyPage(
            pageIndex: pageIndex,
            animated: animated,
            localPresentationReady: localPresentationReady,
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
            'localPresentationReady': localPresentationReady,
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
    if (snapshot.state == UploadState.uploading ||
        (snapshot.state == UploadState.ready && snapshot.frameIndex != null)) {
      // The deferred idle request is now superseded by the real uploader
      // lease. Remove it before output reconciliation can call
      // [_maybePrewarmPagedOutput] again for this same snapshot.
      _deferredOutputPrewarms.remove(id);
    }
    var output = _pageOutputs[id.download.key];
    // Once a current/adjacent output already owns a resident surface, every
    // animation upload can go straight to the output stream. Avoid repeating
    // role/geometry/classification lookups on this high-frequency callback;
    // the prewarm path is still entered for a missing/rebound/no-surface
    // output and for all low-frequency plan/classification boundaries.
    if (output == null ||
        output._identity != id ||
        (!output.snapshot.hasSurface && !output._detachedPrewarmEnabled)) {
      _maybePrewarmPagedOutput(id);
      // The prewarm path may create the stream for the first upload callback.
      // Re-read it before accepting the snapshot so that first ready frame is
      // presented immediately instead of waiting for the next animation tick.
      output = _pageOutputs[id.download.key];
    }
    output?._accept(id, snapshot);
    // Pipeline reconciliation can create the upload session after the viewport
    // observation was applied. Re-project the existing viewport while the
    // session is still preparing so a late transition is frozen.
    // The late current session is resumed before its first presentation
    // deadline is armed. Once animation metadata confirms a multi-frame output,
    // ready notifications are only presentation updates; replaying PlaybackGate
    // for every frame would make the animation compete with the Reader's UI
    // frame. Static and not-yet-classified outputs retain the original resync.
    final isReadyAnimatedFrame =
        snapshot.state == UploadState.ready &&
        snapshot.frameIndex != null &&
        _animatedOutputs.contains(id);
    if (!isReadyAnimatedFrame) {
      _binding?.resyncPlayback();
    }
    // An animated ready frame is followed by presentation, which arms the
    // session deadline and invokes the output stream's lightweight wake hook.
    // Do not scan every upload session from this pre-presentation callback; the
    // due-frame path and the post-present hook preserve multi-page ordering.
    if (!isReadyAnimatedFrame) {
      _ensurePlaybackTicker();
    }
    // Once an Animated WebP is classified, ready notifications are frame
    // presentation updates. The startup guards below scan the whole current
    // upload plan and normally become no-ops after the first frame; repeating
    // those scans for every animation frame needlessly runs on the UI isolate.
    // Keep them for the first/unknown frame and while either startup lease is
    // still held so release timing and pressure semantics remain unchanged.
    if (!isReadyAnimatedFrame ||
        _startupCurrentDownload != null ||
        _startupArtifactPressureDownload != null) {
      _maybeReleaseStartupCurrentDownload();
      _maybeReleaseStartupArtifactPressure();
    }
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

  DecodeId? _activeDecodeIdentity(DownloadId download) {
    final decodes = _binding?.pipeline.currentPlan.decodes;
    if (decodes == null) {
      return null;
    }
    for (final id in decodes.keys) {
      if (id.download == download) {
        return id;
      }
    }
    return null;
  }

  /// Presentation-only continuity for an already-presented static surface.
  ///
  /// Directional decode work remains previous1/next2. During a direction flip,
  /// however, a page at absolute distance two can leave that directional plan
  /// while still belonging to the union of the two possible directional
  /// windows. Clearing an already visible static surface at that point lets
  /// decode eligibility own UI lifetime and forces a later whole-page resident
  /// re-presentation.
  ///
  /// This helper never creates decode/upload work. It reconstructs only the
  /// current target identity so PipelinePageOutputStream can verify whether its
  /// existing authoritative static projection is still the same surface.
  DecodeId? _staticPresentationContinuityIdentity(DownloadId download) {
    final active = _activeDecodeIdentity(download);
    if (active != null) {
      return active;
    }
    final binding = _binding;
    final viewport = binding?.viewport;
    if (binding == null || viewport == null) {
      return null;
    }
    final pageIndex = _pageIndexByPageId[download.content.pageId];
    if (pageIndex == null ||
        (pageIndex - viewport.currentPageIndex).abs() > 2) {
      return null;
    }
    final target = binding.pipeline.decodeTarget;
    return DecodeId(
      download: download,
      physicalWidth: target.physicalWidth,
      physicalHeight: target.physicalHeight,
      pixelFormat: target.pixelFormat,
      renderer: target.renderer,
    );
  }

  void _syncPageStreams() {
    for (final stream in _pageStreams.values) {
      stream.refreshBinding();
    }
  }

  void _syncPageOutputs({ReaderObs? observation}) {
    final emptyOutputs = <String>[];
    for (final entry in _pageOutputs.entries) {
      final output = entry.value;
      final uploadIdentity = _activeUploadIdentity(output.download);
      output._bind(
        uploadIdentity,
        retainedStaticIdentity: uploadIdentity == null
            ? _staticPresentationContinuityIdentity(output.download)
            : null,
      );
      if (output._isEmptyDetachedStream) {
        emptyOutputs.add(entry.key);
      }
    }
    // Page hosts are recreated by PageView as pages leave/re-enter the
    // viewport. Once a stream has no listener, identity or resident claim,
    // retaining it in this map only adds work to every later plan sync.
    for (final key in emptyOutputs) {
      _pageOutputs.remove(key);
    }
    final acceptedObservation = observation ?? _lastAcceptedControlObservation;
    final uploads = _binding?.pipeline.currentPlan.uploads;
    // A prewarm marker is only a short-lived request guard. Once the role
    // plan no longer admits that DecodeId as a page that can enter the
    // gallery, let a later re-entry request a fresh unpresented lease. The
    // native pool still deduplicates an in-flight/idle lease, so this does not
    // allocate duplicate SurfaceProducers while the old request is settling.
    if (_outputPrewarmSizes.isNotEmpty) {
      _outputPrewarmSizes.removeWhere((id, _) {
        final role = uploads?[id]?.role;
        return role != PageRole.current &&
            role != PageRole.next &&
            role != PageRole.transition;
      });
    }
    if (_deferredOutputPrewarms.isNotEmpty) {
      _deferredOutputPrewarms.removeWhere((id, _) {
        final role = uploads?[id]?.role;
        return role != PageRole.current &&
            role != PageRole.next &&
            role != PageRole.transition;
      });
    }
    if (acceptedObservation == null ||
        acceptedObservation.direction == ReadingDirection.vertical ||
        _media.renderer != RendererKind.androidTexture ||
        uploads == null) {
      return;
    }
    // Create the detached projection as soon as the role plan is committed,
    // rather than waiting for the first UploadSnapshot callback. This closes
    // the race where a current or prefetched frame is already ready before the
    // PageView host mounts or begins its next drag.
    for (final entry in uploads.entries) {
      final role = entry.value.role;
      if (role == PageRole.current ||
          role == PageRole.next ||
          role == PageRole.transition) {
        final id = entry.key;
        _maybePrewarmPagedOutput(id, observation: acceptedObservation);
      }
    }
  }

  void _ensurePlaybackTicker() {
    final ids = _binding?.pipeline.currentPlan.uploads.keys;
    final deadline = ids == null
        ? null
        : _uploads.earliestPlaybackDeadlineMicros(ids);
    if (_playbackPaused || deadline == null || _disposed || _retainedForReaderReentry) {
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
    if (_disposed || _playbackPaused || _retainedForReaderReentry) {
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
    _outputPrewarmSizes.clear();
    _deferredOutputPrewarms.clear();
    _outputPrewarmIdleScheduled = false;
    for (final entry in _outputPrewarmSnapshotListeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _outputPrewarmSnapshotListeners.clear();
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
      sharedPhysicalTraceSink: _sharedTraceSink,
    );
    _uploads.dispose();
    _decodes.dispose();
    _animatedOutputs.clear();
    _outputPrewarmSizes.clear();
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
