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
import 'package:storage/storage.dart';
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
    ArtifactCacheReadScheduler? artifactReadScheduler,
    NetLane? pageDownloadLane,
    WebpDecodePrefixHints? decodePrefixHints,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.bytesLoader,
    this.userAgentProvider,
    _PipelineReaderSessionRetentionPool? retentionPool,
  })  : _retentionPool =
            retentionPool ?? _PipelineReaderSessionRetentionPool(),
        artifactReadScheduler =
            artifactReadScheduler ?? ArtifactCacheReadScheduler(),
        pageDownloadLane =
            pageDownloadLane ??
            NetLane(
              maxActive: ReaderPipelineProfile.stable.networkConcurrency,
              reservedHighPrioritySlots: 1,
              highPriorityThreshold: 1000,
              preemptionThreshold: 40,
            ),
        decodePrefixHints = decodePrefixHints ?? WebpDecodePrefixHints();

  final PipelineMediaRuntimeFactory mediaRuntimeFactory;
  final ArtifactCacheManager? artifactCacheManager;
  final _PipelineReaderSessionRetentionPool _retentionPool;
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
      );

  PipelineReaderSessionFactory withArtifactCacheManager(
    ArtifactCacheManager? manager,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: manager,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
      );

  PipelineReaderSessionFactory withUserAgentProvider(
    String Function()? provider,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: provider,
        retentionPool: _retentionPool,
      );

  PipelineReaderSessionFactory withBytesLoader(
    PipelineArtifactBytesLoader? loader,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCacheManager: artifactCacheManager,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: loader,
        userAgentProvider: userAgentProvider,
        retentionPool: _retentionPool,
      );

  PipelineReaderSession create({
    required ChapterManifest chapter,
    required String sessionId,
    TraceSink? traceSink,
  }) =>
      PipelineReaderSession(
        chapter: chapter,
        mediaRuntimeFactory: mediaRuntimeFactory,
        sessionId: sessionId,
        artifactCacheManager: artifactCacheManager,
        artifactReadScheduler: artifactReadScheduler,
        pageDownloadLane: pageDownloadLane,
        decodePrefixHints: decodePrefixHints,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        userAgentProvider: userAgentProvider,
        traceSink: traceSink,
      );

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

  Future<void> disposeRetainedSessions() => _retentionPool.disposeAll();

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
      identityHashCode(artifactReadScheduler),
      identityHashCode(pageDownloadLane),
      identityHashCode(decodePrefixHints),
      identityHashCode(bytesLoader),
      identityHashCode(traceSink),
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
/// projections. Download scheduling, request transport, artifact promotion,
/// decode/upload lanes and transfer progress remain behind this boundary.
final class PipelineReaderSession {
  PipelineReaderSession({
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
  })  : artifactReadScheduler = artifactReadScheduler,
        _artifactCacheManager = artifactCacheManager,
        _bytesLoader = bytesLoader,
        clock = SystemClock(),
        _memoryTrace = MemoryTraceSink(),
        _profile = readerPipelineProfileFor(chapter),
        _workspace = EphemeralCacheWorkspace.readerSession(sessionId),
        _assetTransport = AssetBundleTransport(rootBundle),
        _ioTransport = IoTransport(
          http: HttpTransport(userAgentProvider: userAgentProvider),
        ),
        _loaderTransport = LoaderTransport(loaderSources),
        transferProgress = PipelineTransferProgressPublisher() {
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
      _artifactCacheHandoff = PromotedArtifactCacheHandoff(
        cache: artifactCacheManager,
        onError: (error, stackTrace) {},
        clock: clock,
        traceSink: trace,
        sessionId: sessionId,
      );
    }
    _downloads = DownloadRegistry(
      layout: _workspace.layout,
      clock: clock,
      traceSink: trace,
      sources: _streamingSources,
      onSessionCreated: _observeDownloadSession,
    );
    _decodes = DecodeRegistry(
      downloads: _downloads,
      cursors: _media.cursors,
      clock: clock,
      prefixHints: decodePrefixHints,
      onAnimationResolved: _handleAnimationResolved,
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
      clock: clock,
      traceSink: trace,
      retry: _profile.retry,
      decodes: _decodes,
      uploads: _uploads,
      budgets: _frameBudgets,
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
  final ReaderPipelineProfile _profile;
  late final PipelineMediaRuntime _media;
  final PipelineArtifactBytesLoader? _bytesLoader;
  final EphemeralCacheWorkspace _workspace;
  final AssetBundleTransport _assetTransport;
  final IoTransport _ioTransport;
  final LoaderTransport _loaderTransport;
  final ArtifactCacheManager? _artifactCacheManager;
  ArtifactCacheTransport? _artifactCacheTransport;
  late final SourcePool _streamingSources;
  late final DownloadRegistry _downloads;
  late final DecodeRegistry _decodes;
  late final UploadRegistry _uploads;
  late final FrameBudgeter _frameBudgets;
  PromotedArtifactCacheHandoff? _artifactCacheHandoff;
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
  final ArtifactCacheReadScheduler artifactReadScheduler;
  ArtifactCachePressureLease? _startupArtifactPressure;
  DownloadId? _startupArtifactPressureDownload;
  DownloadId? _startupCurrentDownload;
  bool _disposed = false;
  bool _retainedForReaderReentry = false;

  bool get isDisposed => _disposed;
  int get revision => _binding?.revision ?? 0;
  RendererKind get renderer => _media.renderer;

  void attach(DecodeTarget target) {
    _requireOpen();
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
    transferProgress.select(currentDownload);
    _holdStartupArtifactPressureFor(currentDownload);
    binding.accept(observation);
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
      () => PipelinePageStream.fromSession(_downloads.get(id)),
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

    final session = _downloads.get(id);
    if ((session.state != DownloadState.promoted ||
            session.residentCacheBacked) &&
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
            sessionState: session.state.name,
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

    if (session.state != DownloadState.promoted) {
      await _waitForPromotion(session, token);
    }
    token.throwIfCancelled();
    if (session.residentCacheBacked &&
        _isDirectImmutableLocalUri(asset.uri)) {
      return _readDirectImmutableSource(asset, id, token);
    }
    final artifactReadStarted = clock.nowMicros();
    final cacheRead = cache == null
        ? null
        : await cache.readSessionArtifact(
            id: id,
            length: session.artifact.committedLength,
            loader: () => _workspace.readArtifact(session.artifact),
          );
    final Uint8List bytes;
    if (cacheRead != null) {
      bytes = cacheRead.bytes;
    } else {
      bytes = await _workspace.readArtifact(session.artifact);
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
    MediaLoadToken token,
  ) async {
    final started = clock.nowMicros();
    final session = _downloads.get(id);
    final response = await _baseTransportFor(asset.uri).open(
      asset.uri,
      validators: session.validators,
    );
    if (session.validators.canResume &&
        !session.validators.matches(response.validators)) {
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

  void _observeDownloadSession(DownloadSession session) {
    _artifactCacheHandoff?.observe(session);
    transferProgress.observe(session);
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
    final download = _downloads.get(id.download).snapshot;
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
    final download = _downloads.get(id.download).snapshot;
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
    _disposed = true;
    final disposeStartedAtMicros = clock.nowMicros();
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionDisposeStarted,
        revision: revision,
        payload: <String, Object?>{
          'downloadSessions': _downloads.sessions.length,
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
    _uploads.removeListener(_handleUploadSnapshot);
    _artifactCacheHandoff?.detach();
    final coordinatorDisposeStartedAtMicros = clock.nowMicros();
    await _coordinator.dispose();
    final coordinatorDisposeMicros =
        clock.nowMicros() - coordinatorDisposeStartedAtMicros;
    final handoffDrainStartedAtMicros = clock.nowMicros();
    await _artifactCacheHandoff?.drain(_downloads.sessions);
    final handoffDrainMicros = clock.nowMicros() - handoffDrainStartedAtMicros;
    _uploads.dispose();
    _decodes.dispose();
    final mediaCloseStartedAtMicros = clock.nowMicros();
    await _media.close();
    final mediaCloseMicros = clock.nowMicros() - mediaCloseStartedAtMicros;
    final downloadsDisposeStartedAtMicros = clock.nowMicros();
    await _downloads.dispose();
    final downloadsDisposeMicros =
        clock.nowMicros() - downloadsDisposeStartedAtMicros;
    _streamingSources.dispose();
    _ioTransport.close(force: true);
    final workspaceDisposeStartedAtMicros = clock.nowMicros();
    await _workspace.dispose();
    final workspaceDisposeMicros =
        clock.nowMicros() - workspaceDisposeStartedAtMicros;
    _pageStreams.clear();
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionDisposed,
        payload: <String, Object?>{
          'disposeMicros': clock.nowMicros() - disposeStartedAtMicros,
          'coordinatorDisposeMicros': coordinatorDisposeMicros,
          'handoffDrainMicros': handoffDrainMicros,
          'mediaCloseMicros': mediaCloseMicros,
          'downloadsDisposeMicros': downloadsDisposeMicros,
          'workspaceDisposeMicros': workspaceDisposeMicros,
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
