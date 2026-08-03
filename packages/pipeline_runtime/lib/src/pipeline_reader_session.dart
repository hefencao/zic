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

final class PipelineReaderSessionFactory {
  PipelineReaderSessionFactory({
    required this.mediaRuntimeFactory,
    this.artifactCache,
    ArtifactCacheReadScheduler? artifactReadScheduler,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.bytesLoader,
  }) : artifactReadScheduler =
            artifactReadScheduler ?? ArtifactCacheReadScheduler();

  final PipelineMediaRuntimeFactory mediaRuntimeFactory;
  final ArtifactCacheStore? artifactCache;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final PipelineArtifactBytesLoader? bytesLoader;

  /// Returns a factory that keeps composition-owned cache/byte loaders while
  /// adding page-local transport sources.
  ///
  /// Presentation packages can contribute local source handles without
  /// importing download/cache implementation types.
  PipelineReaderSessionFactory withLoaderSources(
    Map<Uri, LoaderTransportSource> sources,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCache: artifactCache,
        artifactReadScheduler: artifactReadScheduler,
        loaderSources: <Uri, LoaderTransportSource>{
          ...loaderSources,
          ...sources,
        },
        bytesLoader: bytesLoader,
      );

  PipelineReaderSessionFactory withArtifactCache(
    ArtifactCacheStore? cache,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCache: cache,
        artifactReadScheduler: artifactReadScheduler,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
      );

  PipelineReaderSessionFactory withBytesLoader(
    PipelineArtifactBytesLoader? loader,
  ) =>
      PipelineReaderSessionFactory(
        mediaRuntimeFactory: mediaRuntimeFactory,
        artifactCache: artifactCache,
        artifactReadScheduler: artifactReadScheduler,
        loaderSources: loaderSources,
        bytesLoader: loader,
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
        artifactCache: artifactCache,
        artifactReadScheduler: artifactReadScheduler,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        traceSink: traceSink,
      );
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
    ArtifactCacheStore? artifactCache,
    required ArtifactCacheReadScheduler artifactReadScheduler,
    Map<Uri, LoaderTransportSource> loaderSources =
        const <Uri, LoaderTransportSource>{},
    PipelineArtifactBytesLoader? bytesLoader,
    TraceSink? traceSink,
  })  : artifactReadScheduler = artifactReadScheduler,
        _bytesLoader = bytesLoader,
        clock = SystemClock(),
        _memoryTrace = MemoryTraceSink(),
        _profile = readerPipelineProfileFor(chapter),
        _workspace = EphemeralCacheWorkspace.readerSession(sessionId),
        _assetTransport = AssetBundleTransport(rootBundle),
        _ioTransport = IoTransport(),
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
    if (artifactCache != null) {
      final reads = PromotedArtifactReadPool(cache: artifactCache);
      _artifactReads = reads;
      _artifactCacheTransport = ArtifactCacheTransport(
        cache: artifactCache,
        identities: identities,
        fallbackFor: _baseTransportFor,
        readPool: reads,
        readScheduler: artifactReadScheduler,
        demandPriority: _artifactReadPriority,
        clock: clock,
        traceSink: trace,
        sessionId: sessionId,
        demandRevision: () => revision,
      );
      _artifactCacheHandoff = PromotedArtifactCacheHandoff(
        cache: artifactCache,
        onError: (error, stackTrace) {},
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
      net: NetLane(maxActive: _profile.networkConcurrency),
      decode: DecodeLane(maxActive: _profile.decodeConcurrency),
      upload: UploadLane(maxActive: _profile.uploadConcurrency),
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
  ArtifactCacheTransport? _artifactCacheTransport;
  PromotedArtifactReadPool? _artifactReads;
  late final SourcePool _streamingSources;
  late final DownloadRegistry _downloads;
  late final DecodeRegistry _decodes;
  late final UploadRegistry _uploads;
  late final FrameBudgeter _frameBudgets;
  PromotedArtifactCacheHandoff? _artifactCacheHandoff;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  final Map<String, PipelinePageStream> _pageStreams =
      <String, PipelinePageStream>{};
  final Map<String, PipelinePageOutputStream> _pageOutputs =
      <String, PipelinePageOutputStream>{};
  Timer? _playbackTicker;
  bool _playbackPaused = false;
  final PipelineTransferProgressPublisher transferProgress;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  bool _disposed = false;

  int get revision => _binding?.revision ?? 0;
  RendererKind get renderer => _media.renderer;

  void attach(DecodeTarget target) {
    _requireOpen();
    if (target.renderer != renderer) {
      throw ArgumentError.value(
        target.renderer,
        'target.renderer',
        'must match the atomically injected Pipeline media renderer '
            '${renderer.name}',
      );
    }
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
    final binding = _binding;
    if (binding == null) {
      throw StateError('pipeline Reader session is not attached');
    }
    final pageIndex = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    transferProgress.select(
      readerPageDownloadId(chapter, chapter.pages[pageIndex]),
    );
    binding.accept(observation);
    artifactReadScheduler.refresh();
    _syncPageOutputs();
    _ensurePlaybackTicker();
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
    artifactReadScheduler.refresh();
    transferProgress.clear();
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
    final session = _downloads.get(id);
    if (session.state != DownloadState.promoted) {
      final reads = _artifactReads;
      if (reads != null) {
        final readStarted = clock.nowMicros();
        try {
          final cached = await reads.join(id);
          token.throwIfCancelled();
          if (cached != null) {
            final joinMicros = clock.nowMicros() - readStarted;
            trace.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.artifactSource,
                identityHash: id.key,
                revision: revision,
                payload: <String, Object?>{
                  'source': 'artifact-cache',
                  'sourceClass': 'persistent-artifact',
                  'consumer': 'pipeline-presentation',
                  'bytes': cached.lengthInBytes,
                  'joinMicros': joinMicros,
                  'sessionState': session.state.name,
                },
              ),
            );
            trace.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.sourceRead,
                identityHash: id.key,
                revision: revision,
                payload: <String, Object?>{
                  'source': 'artifact-cache',
                  'sourceClass': 'persistent-artifact',
                  'uriScheme': asset.uri.scheme.isEmpty
                      ? 'file'
                      : asset.uri.scheme,
                  'bytes': cached.lengthInBytes,
                  'chunks': 1,
                  'minChunkBytes': cached.lengthInBytes,
                  'maxChunkBytes': cached.lengthInBytes,
                  'firstChunkMicros': joinMicros < 0 ? 0 : joinMicros,
                  'streamMicros': joinMicros < 0 ? 0 : joinMicros,
                  'readMicros': joinMicros < 0 ? 0 : joinMicros,
                  'completed': true,
                  'consumer': 'pipeline-presentation',
                },
              ),
            );
            return cached;
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
                'lane': 'artifact-cache-read',
                'consumer': 'pipeline-presentation',
                'reason': error.toString(),
                'joinMicros': clock.nowMicros() - readStarted,
                'fallback': 'session',
              },
            ),
          );
        }
      }
      await _waitForPromotion(session, token);
    }
    token.throwIfCancelled();
    final artifactReadStarted = clock.nowMicros();
    final bytes = await _workspace.readArtifact(session.artifact);
    token.throwIfCancelled();
    final artifactReadMicros = clock.nowMicros() - artifactReadStarted;
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.sourceRead,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'source': 'session-artifact',
          'sourceClass': _readerSourceClass(asset.uri),
          'uriScheme': asset.uri.scheme.isEmpty ? 'file' : asset.uri.scheme,
          'bytes': bytes.lengthInBytes,
          'chunks': 1,
          'minChunkBytes': bytes.lengthInBytes,
          'maxChunkBytes': bytes.lengthInBytes,
          'firstChunkMicros': artifactReadMicros < 0 ? 0 : artifactReadMicros,
          'streamMicros': artifactReadMicros < 0 ? 0 : artifactReadMicros,
          'readMicros': artifactReadMicros < 0 ? 0 : artifactReadMicros,
          'completed': true,
          'consumer': 'pipeline-presentation',
        },
      ),
    );
    return bytes;
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
    _artifactReads?.observe(session);
    _artifactCacheHandoff?.observe(session);
    transferProgress.observe(session);
  }

  void _handleUploadSnapshot(DecodeId id, UploadSnapshot snapshot) {
    _pageOutputs[id.download.key]?._accept(id, snapshot);
    // Pipeline reconciliation can create the upload session after the viewport
    // observation was applied. Re-project the existing viewport so a late
    // transition session is frozen and a late current session is resumed before
    // its first presentation deadline is armed.
    _binding?.resyncPlayback();
    if (snapshot.state == UploadState.ready) {
      _ensurePlaybackTicker();
    }
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
    final hasRunnablePlayback =
        ids != null && _uploads.hasRunnablePlayback(ids);
    if (_playbackPaused || !hasRunnablePlayback || _disposed) {
      _playbackTicker?.cancel();
      _playbackTicker = null;
      return;
    }
    _playbackTicker ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _advanceDueFrames(),
    );
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
    _ensurePlaybackTicker();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playbackTicker?.cancel();
    _playbackTicker = null;
    final binding = _binding;
    _binding = null;
    binding?.detach(sessionId);
    for (final output in _pageOutputs.values) {
      output._dispose();
    }
    _pageOutputs.clear();
    transferProgress.dispose();
    _uploads.removeListener(_handleUploadSnapshot);
    await _coordinator.dispose();
    await _artifactCacheHandoff?.drain(_downloads.sessions);
    _artifactCacheHandoff?.detach();
    _artifactReads?.close();
    _uploads.dispose();
    _decodes.dispose();
    await _media.close();
    await _downloads.dispose();
    _streamingSources.dispose();
    _ioTransport.close(force: true);
    await _workspace.dispose();
    _pageStreams.clear();
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
