import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/services.dart';
import 'package:media/media.dart' show NativeSourceFactory, SourcePool;
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'asset_bundle_transport.dart';
import 'media_load_token.dart';
import 'pipeline_page_stream.dart';
import 'pipeline_transfer_progress.dart';

typedef PipelineArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);

final class PipelineReaderSessionFactory {
  const PipelineReaderSessionFactory({
    this.artifactCache,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.bytesLoader,
  });

  final ArtifactCacheStore? artifactCache;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final PipelineArtifactBytesLoader? bytesLoader;

  PipelineReaderSession create({
    required ChapterManifest chapter,
    required String sessionId,
    TraceSink? traceSink,
  }) =>
      PipelineReaderSession(
        chapter: chapter,
        sessionId: sessionId,
        artifactCache: artifactCache,
        loaderSources: loaderSources,
        bytesLoader: bytesLoader,
        traceSink: traceSink,
      );
}

/// Owns the complete resource side of one Reader session.
///
/// Reader reports viewport observations and consumes [PipelinePageStream]
/// projections. Download scheduling, request transport, artifact promotion,
/// decode/upload lanes and transfer progress remain behind this boundary.
final class PipelineReaderSession {
  PipelineReaderSession({
    required this.chapter,
    required this.sessionId,
    ArtifactCacheStore? artifactCache,
    Map<Uri, LoaderTransportSource> loaderSources =
        const <Uri, LoaderTransportSource>{},
    PipelineArtifactBytesLoader? bytesLoader,
    TraceSink? traceSink,
  })  : _bytesLoader = bytesLoader,
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
      factory: const NativeSourceFactory(),
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
    _coordinator = LiveCoordinator(
      registry: _downloads,
      transportFor: _transportFor,
      clock: clock,
      traceSink: trace,
      retry: _profile.retry,
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
  final PipelineArtifactBytesLoader? _bytesLoader;
  final EphemeralCacheWorkspace _workspace;
  final AssetBundleTransport _assetTransport;
  final IoTransport _ioTransport;
  final LoaderTransport _loaderTransport;
  ArtifactCacheTransport? _artifactCacheTransport;
  PromotedArtifactReadPool? _artifactReads;
  late final SourcePool _streamingSources;
  late final DownloadRegistry _downloads;
  PromotedArtifactCacheHandoff? _artifactCacheHandoff;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  final Map<String, PipelinePageStream> _pageStreams =
      <String, PipelinePageStream>{};
  final PipelineTransferProgressPublisher transferProgress;
  bool _disposed = false;

  int get revision => _binding?.revision ?? 0;

  void attach(DecodeTarget target) {
    _requireOpen();
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
  }

  void detach(String readerSessionId) {
    _binding?.detach(readerSessionId);
    _binding = null;
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
            trace.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.artifactSource,
                identityHash: id.key,
                revision: revision,
                payload: <String, Object?>{
                  'source': 'artifact-cache',
                  'consumer': 'pipeline-presentation',
                  'bytes': cached.lengthInBytes,
                  'joinMicros': clock.nowMicros() - readStarted,
                  'sessionState': session.state.name,
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
    final bytes = await _workspace.readArtifact(session.artifact);
    token.throwIfCancelled();
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _binding = null;
    transferProgress.dispose();
    await _coordinator.dispose();
    await _artifactCacheHandoff?.drain(_downloads.sessions);
    _artifactCacheHandoff?.detach();
    _artifactReads?.close();
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
