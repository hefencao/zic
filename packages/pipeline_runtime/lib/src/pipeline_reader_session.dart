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

typedef PipelineArtifactBytesLoader =
    Future<Uint8List> Function(PageAsset asset, MediaLoadToken token);

/// Immutable cache authority for the exact encoded body returned to one
/// presentation load. Error recovery must return this same authority rather
/// than asking the page for whichever generation happens to be newest later.
final class PipelinePresentationArtifactAuthority {
  const PipelinePresentationArtifactAuthority({
    required this.storageId,
    required this.generation,
  });

  final DownloadId storageId;
  final int generation;
}

/// Exact encoded bytes plus the artifact authority that produced them.
final class PipelinePresentationBytes {
  const PipelinePresentationBytes({required this.bytes, this.authority});

  final Uint8List bytes;
  final PipelinePresentationArtifactAuthority? authority;
}

/// Immutable encoded-body file/descriptor lease for presentation codecs that
/// can consume a path directly. The lease is physical-generation scoped and
/// must remain alive until the ImageProvider/codec no longer needs the path.
final class PipelineEncodedPresentationFileLease {
  const PipelineEncodedPresentationFileLease({
    required this.path,
    required this.length,
    required this.cacheIdentity,
    required this.release,
    this.width,
    this.height,
    this.authority,
  });

  final String path;
  final int length;
  final Object cacheIdentity;
  final int? width;
  final int? height;
  final PipelinePresentationArtifactAuthority? authority;
  final Future<void> Function() release;
}

/// Presentation geometry needed to derive the exact Flutter raster-cache key.
///
/// This is a presentation fact, not a scheduling policy. Pipeline still owns
/// which page receives an external-presentation grant; the presentation
/// adapter only uses this value to build the same raster identity whether it
/// is mounted or detached.
enum PipelineExternalPresentationFit { contain, fitWidth }

/// One coordinator-authorized external static presentation warm request.
///
/// The executor may decode only the supplied exact page capability. It does
/// not choose page eligibility, create transfer demand, or own encoded-byte
/// persistence. Successful completion means the presentation composition has
/// a first static raster resident in its existing cache.
final class PipelineExternalPresentationWarmRequest {
  const PipelineExternalPresentationWarmRequest({
    required this.asset,
    required this.identity,
    required this.cacheIdentity,
    required this.token,
    required this.openEncodedPresentationFile,
    required this.loadBytes,
    required this.maxPhysicalWidth,
    required this.maxPhysicalHeight,
    required this.fit,
  });

  final PageAsset asset;
  final DecodeId identity;

  /// Opaque identity for this immutable external-presentation generation.
  ///
  /// Presentation adapters must use it independently from whether the bytes
  /// are currently exposed from resident memory or a durable file lease.
  final Object cacheIdentity;
  final MediaLoadToken token;
  final Future<PipelineEncodedPresentationFileLease?> Function(
    MediaLoadToken token,
  )
  openEncodedPresentationFile;
  final Future<Uint8List> Function(MediaLoadToken token) loadBytes;
  final int maxPhysicalWidth;
  final int maxPhysicalHeight;
  final PipelineExternalPresentationFit fit;
}

typedef PipelineExternalPresentationPrewarmer =
    Future<void> Function(PipelineExternalPresentationWarmRequest request);

typedef PipelinePresentationCacheInvalidationListener =
    void Function(Object presentationIdentity);

enum PipelinePresentationCacheClaim { speculative, deadline, protected }

/// Composition-owned residency authority for volatile Reader presentation
/// rasters. Pipeline owns demand/generation state; this cache authority owns
/// reusable raster lifetime and emits exact invalidation when residency ends.
abstract interface class PipelinePresentationCacheAuthority {
  void addInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  );

  void removeInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  );

  void updatePresentationClaim(
    Object presentationIdentity,
    PipelinePresentationCacheClaim claim,
  );

  void releasePresentationClaim(Object presentationIdentity);

  /// Whether this residency owner currently permits a new raster admission for
  /// [presentationIdentity]. A budget eviction may temporarily deny another
  /// speculative warm for the same immutable generation until its claim is
  /// promoted to deadline/protected.
  bool allowsPresentationWarm(Object presentationIdentity);

  void invalidatePresentationIdentity(Object presentationIdentity);
}

final class _MediaLoadTaskControl implements TaskControl {
  _MediaLoadTaskControl(this.token);

  final MediaLoadToken token;

  @override
  bool get cancelled => token.isCancelled;

  @override
  Future<void> get whenCancelled => token.whenCancelled;

  // Direct presentation reads do not own scheduler ranking. Keep this below
  // the network task ranks while still exposing the complete cancellation
  // signal to controlled transports.
  @override
  int get priority => -1;
}

final class _DirectNextChunk {
  const _DirectNextChunk(this.available);

  final bool available;
}

final class _DirectCancelled {
  const _DirectCancelled();
}

const Duration _readerSessionRetentionDuration = Duration(minutes: 2);
const int _maxRetainedReaderSessions = 2;

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

bool _sameRetainedReaderChapter(ChapterManifest left, ChapterManifest right) {
  if (left.sourceId != right.sourceId ||
      left.comicId != right.comicId ||
      left.chapter.chapterId != right.chapter.chapterId ||
      left.chapter.sourceRevision != right.chapter.sourceRevision ||
      left.readingDirection != right.readingDirection ||
      left.pages.length != right.pages.length) {
    return false;
  }
  for (var index = 0; index < left.pages.length; index++) {
    final a = left.pages[index];
    final b = right.pages[index];
    if (a.pageId != b.pageId ||
        a.index != b.index ||
        a.uri != b.uri ||
        a.width != b.width ||
        a.height != b.height ||
        a.byteLength != b.byteLength ||
        a.contentKindHint != b.contentKindHint ||
        a.animatedHint != b.animatedHint ||
        a.checksum != b.checksum ||
        a.checksumAlgorithm != b.checksumAlgorithm) {
      return false;
    }
  }
  return true;
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
    required bool Function(PipelineReaderSession session) canReuse,
    required PipelineReaderSession Function() create,
  }) {
    final retained = _idle.remove(key);
    if (retained != null) {
      retained.expiry.cancel();
      final session = retained.session;
      if (!session.isDisposed && canReuse(session)) {
        _leased[session] = key;
        session.resumeRetainedReaderSession(
          retainedMicros: session.clock.nowMicros() - retained.retainedAtMicros,
        );
        return session;
      }
      if (!session.isDisposed) {
        unawaited(session.dispose());
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
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
    required this.pageDownloadLane,
    WebpDecodePrefixHints? decodePrefixHints,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.bytesLoader,
    this.userAgentProvider,
    this.externalPresentationPrewarmer,
    this.presentationCacheAuthority,
    _PipelineReaderSessionRetentionPool? retentionPool,
    CompositionDownloadTransferRuntimePool? transferRuntimePool,
    this.transferRuntime,
  }) : _retentionPool = retentionPool ?? _PipelineReaderSessionRetentionPool(),
       _transferRuntimePool =
           transferRuntimePool ?? CompositionDownloadTransferRuntimePool(),
       artifactReadScheduler =
           artifactReadScheduler ?? ArtifactCacheReadScheduler(),
       speculativeEncodedReadBudget =
           speculativeEncodedReadBudget ?? SpeculativeEncodedReadBudget(),
       decodePrefixHints = decodePrefixHints ?? WebpDecodePrefixHints();

  final PipelineMediaRuntimeFactory mediaRuntimeFactory;
  final ArtifactCacheManager? artifactCacheManager;
  final PartialDownloadStore? partialDownloadStore;
  final _PipelineReaderSessionRetentionPool _retentionPool;
  final CompositionDownloadTransferRuntimePool _transferRuntimePool;
  final CompositionDownloadTransferRuntime? transferRuntime;
  final ArtifactCacheReadScheduler artifactReadScheduler;
  final SpeculativeEncodedReadBudget speculativeEncodedReadBudget;
  final NetLane pageDownloadLane;
  final WebpDecodePrefixHints decodePrefixHints;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final PipelineArtifactBytesLoader? bytesLoader;
  final String Function()? userAgentProvider;
  final PipelineExternalPresentationPrewarmer? externalPresentationPrewarmer;
  final PipelinePresentationCacheAuthority? presentationCacheAuthority;

  /// Returns a factory that keeps composition-owned cache/byte loaders while
  /// adding page-local transport sources.
  PipelineReaderSessionFactory withLoaderSources(
    Map<Uri, LoaderTransportSource> sources,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: artifactCacheManager,
    partialDownloadStore: partialDownloadStore,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    pageDownloadLane: pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: <Uri, LoaderTransportSource>{...loaderSources, ...sources},
    bytesLoader: bytesLoader,
    userAgentProvider: userAgentProvider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
    retentionPool: _retentionPool,
    transferRuntimePool: _transferRuntimePool,
    transferRuntime: transferRuntime,
  );

  PipelineReaderSessionFactory withArtifactCacheManager(
    ArtifactCacheManager? manager,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: manager,
    partialDownloadStore: partialDownloadStore,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    pageDownloadLane: pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: loaderSources,
    bytesLoader: bytesLoader,
    userAgentProvider: userAgentProvider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
    retentionPool: _retentionPool,
    transferRuntimePool: _transferRuntimePool,
    transferRuntime: transferRuntime,
  );

  PipelineReaderSessionFactory withPartialDownloadStore(
    PartialDownloadStore? store,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: artifactCacheManager,
    partialDownloadStore: store,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    pageDownloadLane: pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: loaderSources,
    bytesLoader: bytesLoader,
    userAgentProvider: userAgentProvider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
    retentionPool: _retentionPool,
    transferRuntimePool: _transferRuntimePool,
    transferRuntime: transferRuntime,
  );

  PipelineReaderSessionFactory withUserAgentProvider(
    String Function()? provider,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: artifactCacheManager,
    partialDownloadStore: partialDownloadStore,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    pageDownloadLane: pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: loaderSources,
    bytesLoader: bytesLoader,
    userAgentProvider: provider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
    retentionPool: _retentionPool,
    transferRuntimePool: _transferRuntimePool,
    transferRuntime: transferRuntime,
  );

  PipelineReaderSessionFactory withBytesLoader(
    PipelineArtifactBytesLoader? loader,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: artifactCacheManager,
    partialDownloadStore: partialDownloadStore,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    pageDownloadLane: pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: loaderSources,
    bytesLoader: loader,
    userAgentProvider: userAgentProvider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
    retentionPool: _retentionPool,
    transferRuntimePool: _transferRuntimePool,
    transferRuntime: transferRuntime,
  );

  /// Returns a factory whose Reader consumers attach to the supplied
  /// composition-level physical transfer runtime. The runtime is owned by the
  /// application composition, not by any Reader session.
  PipelineReaderSessionFactory withTransferRuntime(
    CompositionDownloadTransferRuntime? runtime,
  ) => PipelineReaderSessionFactory(
    mediaRuntimeFactory: mediaRuntimeFactory,
    artifactCacheManager: runtime == null
        ? artifactCacheManager
        : runtime.artifactCacheManager,
    partialDownloadStore: runtime == null
        ? partialDownloadStore
        : runtime.partialDownloadStore,
    artifactReadScheduler: artifactReadScheduler,
    speculativeEncodedReadBudget:
        runtime?.speculativeEncodedReadBudget ?? speculativeEncodedReadBudget,
    pageDownloadLane: runtime?.net ?? pageDownloadLane,
    decodePrefixHints: decodePrefixHints,
    loaderSources: loaderSources,
    bytesLoader: bytesLoader,
    userAgentProvider: userAgentProvider,
    externalPresentationPrewarmer: externalPresentationPrewarmer,
    presentationCacheAuthority: presentationCacheAuthority,
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
          !identical(pageDownloadLane, externalTransferRuntime.net) ||
          !identical(
            speculativeEncodedReadBudget,
            externalTransferRuntime.speculativeEncodedReadBudget,
          )) {
        throw StateError(
          'Reader transfer runtime must share the factory artifact cache, '
          'partial store and NetLane authorities',
        );
      }
    }
    final transferRuntime =
        externalTransferRuntime ??
        _transferRuntimePool.get(
          artifactCacheManager: artifactCacheManager,
          partialDownloadStore: partialDownloadStore,
          net: pageDownloadLane,
          localReadScheduler: artifactReadScheduler,
          speculativeEncodedReadBudget: speculativeEncodedReadBudget,
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
      externalPresentationPrewarmer: externalPresentationPrewarmer,
      presentationCacheAuthority: presentationCacheAuthority,
      traceSink: traceSink,
      transferRuntime: transferRuntime,
    );
  }

  PipelineReaderSession acquire({
    required ChapterManifest chapter,
    required String sessionId,
    TraceSink? traceSink,
  }) => _retentionPool.acquire(
    key: _retentionKey(chapter, traceSink),
    canReuse: (session) => _sameRetainedReaderChapter(session.chapter, chapter),
    create: () =>
        create(chapter: chapter, sessionId: sessionId, traceSink: traceSink),
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
        (left, right) => left.key.toString().compareTo(right.key.toString()),
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
      identityHashCode(speculativeEncodedReadBudget),
      identityHashCode(pageDownloadLane),
      identityHashCode(decodePrefixHints),
      identityHashCode(bytesLoader),
      identityHashCode(externalPresentationPrewarmer),
      identityHashCode(presentationCacheAuthority),
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
    PipelineExternalPresentationPrewarmer? externalPresentationPrewarmer,
    PipelinePresentationCacheAuthority? presentationCacheAuthority,
    TraceSink? traceSink,
    required CompositionDownloadTransferRuntime transferRuntime,
  }) : artifactReadScheduler = artifactReadScheduler,
       _artifactCacheManager = artifactCacheManager,
       _transferRuntime = transferRuntime,
       _sharedTraceSink = traceSink,
       _bytesLoader = bytesLoader,
       _externalPresentationPrewarmer = externalPresentationPrewarmer,
       _presentationCacheAuthority = presentationCacheAuthority,
       clock = SystemClock(),
       _profile = readerPipelineProfileFor(chapter),
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
    _residentReplaySourceWithControl = _transferRuntime
        .residentReplaySourceWithControl(priorityFor: _artifactReadPriority);
    _residentReplayRangeSource = _transferRuntime.residentReplayRangeSource(
      priorityFor: _artifactReadPriority,
    );
    _residentReplayRangeSourceWithControl = _transferRuntime
        .residentReplayRangeSourceWithControl(
          priorityFor: _artifactReadPriority,
        );
    _artifactReplayRangeSourceWithControl = _transferRuntime
        .artifactReplayRangeSourceWithControl(
          priorityFor: _artifactReadPriority,
        );
    _ingresses = DownloadIngressProjectionRegistry(
      sources: _streamingSources,
      scopePrefix: 'reader:$sessionId',
      residentReplaySource: _residentReplaySource,
      residentReplaySourceWithControl: _residentReplaySourceWithControl,
      residentReplayRangeSource: _residentReplayRangeSource,
      residentReplayRangeSourceWithControl:
          _residentReplayRangeSourceWithControl,
      artifactReplayRangeSourceWithControl:
          _artifactReplayRangeSourceWithControl,
      prefixHints: decodePrefixHints,
      traceSink: trace,
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
      downloadBucketLimitFor: _profile.downloadBucketLimit,
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
      downloadSessionFor: _transferRuntime.sessionFor,
      findDownloadSession: _transferRuntime.findSession,
      onDownloadObserved: _observeDownloadSession,
      onSourceKindObserved: _handleSourceKindObserved,
      onExternalPresentationRequested: _handleExternalPresentationRequested,
      externalPresentationAvailable: _externalPresentationAvailable,
      maxSpeculativeExternalPresentationPending:
          _profile.speculativeExternalPresentationConcurrency,
      net: pageDownloadLane,
      downloadBucketFor: _profile.downloadBucket,
      downloadBucketLimitFor: _profile.downloadBucketLimit,
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
    _presentationCacheAuthority?.addInvalidationListener(
      _handlePresentationCacheInvalidated,
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
  final PipelineExternalPresentationPrewarmer? _externalPresentationPrewarmer;
  final PipelinePresentationCacheAuthority? _presentationCacheAuthority;
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
  late final DownloadResidentReplaySourceWithControl
  _residentReplaySourceWithControl;
  late final DownloadResidentReplayRangeSource _residentReplayRangeSource;
  late final DownloadResidentReplayRangeSourceWithControl
  _residentReplayRangeSourceWithControl;
  late final DownloadArtifactReplayRangeSourceWithControl
  _artifactReplayRangeSourceWithControl;
  late final DecodeRegistry _decodes;
  late final UploadRegistry _uploads;
  late final FrameBudgeter _frameBudgets;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  String? _readerSessionId;
  PipelineExternalPresentationFit _externalPresentationFit =
      PipelineExternalPresentationFit.contain;
  final Map<String, PipelinePageStream> _pageStreams =
      <String, PipelinePageStream>{};
  final Map<String, PipelinePageOutputStream> _pageOutputs =
      <String, PipelinePageOutputStream>{};
  final Set<DownloadId> _automaticPresentationRecoveries = <DownloadId>{};
  final Set<DownloadId> _automaticPresentationRasterRecoveries =
      <DownloadId>{};
  final Set<DecodeId> _animatedOutputs = <DecodeId>{};
  final Set<DecodeId> _externalPresentationRequests = <DecodeId>{};
  final Set<DecodeId> _externalPresentationReady = <DecodeId>{};
  final Set<DecodeId> _externalPresentationPrewarmFailures = <DecodeId>{};
  final Map<DecodeId, MediaLoadToken> _externalPresentationPrewarmTokens =
      <DecodeId, MediaLoadToken>{};
  final Map<DecodeId, Object> _externalPresentationCacheIdentities =
      <DecodeId, Object>{};
  final Set<DecodeId> _externalPresentationVisibleFrames = <DecodeId>{};
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
  late final PipelineTransferProgressPublisher transferProgress;
  final _PipelinePageDimensionsPublisher _pageDimensions;
  final Map<String, int> _pageIndexByPageId;
  PipelinePageDimensionsFeed get pageDimensions => _pageDimensions;
  final ArtifactCacheReadScheduler artifactReadScheduler;
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

  void attach(
    DecodeTarget target, {
    PipelineExternalPresentationFit externalPresentationFit =
        PipelineExternalPresentationFit.contain,
  }) {
    _requireOpen();
    if (_externalPresentationFit != externalPresentationFit) {
      // A retained Reader may reuse the same DecodeId dimensions while its
      // presentation mode changes (for example contain -> stitched fitWidth).
      // Presentation-fit changes are a real raster-generation boundary.
      // Retire the managed raster generation itself before forgetting the
      // Pipeline identity map so cache and scheduling state cannot diverge.
      for (final identity in _externalPresentationCacheIdentities.values.toList(
        growable: false,
      )) {
        _presentationCacheAuthority?.invalidatePresentationIdentity(identity);
      }
      _externalPresentationCacheIdentities.clear();
    }
    _externalPresentationFit = externalPresentationFit;
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

  /// Updates only the external static presentation geometry.
  ///
  /// Decode/source identity is intentionally unchanged. The previous Flutter
  /// presentation-cache proof is geometry-specific, so it is rotated and the
  /// coordinator re-grants first-frame work through the existing staged policy.
  void updateExternalPresentationFit(PipelineExternalPresentationFit fit) {
    _requireOpen();
    final binding = _binding;
    if (binding == null) {
      throw StateError('pipeline Reader session is not attached');
    }
    if (_externalPresentationFit == fit) return;
    _externalPresentationFit = fit;
    final identities = _coordinator.decodeDemands.keys.toList(growable: false);
    for (final identity in identities) {
      final pageIndex = _pageIndexByPageId[identity.download.content.pageId];
      if (pageIndex == null ||
          !binding.pipeline.isRuntimeExternalStaticPage(pageIndex)) {
        continue;
      }
      _externalPresentationPrewarmTokens.remove(identity)?.cancel();
      _rotateExternalPresentationCacheIdentityFor(identity);
      _externalPresentationRequests.remove(identity);
      _externalPresentationReady.remove(identity);
      _externalPresentationPrewarmFailures.remove(identity);
      _externalPresentationVisibleFrames.remove(identity);
      _coordinator.invalidateExternalPresentation(sessionId, identity);
      _coordinator.updateExternalPresentationAvailability(
        sessionId,
        identity,
        available: _externalPresentationAvailable(identity),
      );
    }
    _syncPageOutputs();
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
    final scheduler = _media.frameScheduler;
    final frameQueued =
        scheduler.inPersistentCallbacks || scheduler.hasScheduledFrame;
    if (frameQueued) {
      // A Reader scroll/page-boundary observation is control work produced by
      // presentation motion. If Flutter already owes the user a frame, run the
      // latest-wins reconcile only after that visual frame has been delivered;
      // an ordinary Timer can otherwise win the event-loop race and consume
      // several milliseconds of UI-isolate control work before beginFrame.
      // This changes only the execution seam, not policy or demand order.
      scheduler.afterFrame(() => _drainObservation(generation));
      return;
    }
    // With no frame pending, do not manufacture one merely to update resource
    // control state. Yield one ordinary event turn, preserving the historical
    // prompt idle/non-visual path.
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
    return target.fraction >= _profile.windowResolver.transitionThreshold
        ? 2
        : 1;
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
    if (target.fraction >= defaultDominantCoverageThreshold ||
        current.fraction >= defaultDominantCoverageThreshold) {
      return 1; // dominant
    }
    if (current.fraction >= defaultTransitionCoverageThreshold &&
        target.fraction >= defaultTransitionCoverageThreshold) {
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

  int _controlInteraction(Interaction interaction) {
    if (isPresentationMotionInteraction(interaction)) return 1;
    return switch (interaction) {
      Interaction.idle => 2,
      Interaction.scrubbing => 3,
      Interaction.jumping => 4,
      Interaction.dragging || Interaction.scrolling || Interaction.settling =>
        throw StateError('presentation-motion interaction escaped grouping'),
    };
  }

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
            direction: observation.direction,
          );
        }
      }
    }
    final revisionBefore = binding.pipeline.revision;
    final playbackChanged = binding.accept(observation);
    final planChanged = binding.pipeline.revision != revisionBefore;
    _lastControlCurrentDownload = currentDownload;
    _lastControlDecodeTarget = target;
    if (!planChanged && !controlIdentityChanged) {
      // Playback ownership can cross overlap->dominant without changing a
      // demand role or DecodeId. In that case PlaybackGate may have just
      // resumed a timer that was armed while the adjacent WebP was hidden.
      // Rebuild the single Reader wake here; waiting for another demand or
      // PageView observation makes the newly-current animation appear frozen
      // until the user swipes again.
      if (playbackChanged) {
        _ensurePlaybackTicker();
      }
      return;
    }
    _syncPageStreams();
    transferProgress.select(_downloads.find(currentDownload));
    artifactReadScheduler.refresh();
    // The first accepted plan is already authoritative for detached gallery
    // prewarm, even though the retained observation is written only after the
    // full control transaction returns. Pass it explicitly so a ready
    // current/next/transition output cannot wait for the PageView host to
    // mount.
    _syncPageOutputs(observation: observation);
    _syncTransferProgressPresentationSatisfaction(currentDownload);
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
    final sourceWidth =
        asset.width ?? download?.sourceCanvasWidth ?? decoded?.decodedWidth;
    final sourceHeight =
        asset.height ?? download?.sourceCanvasHeight ?? decoded?.decodedHeight;
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
    ReadingDirection? direction,
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
    if (_shouldDeferOutputPrewarm(id, direction: direction)) {
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

  bool _shouldDeferOutputPrewarm(
    DecodeId id, {
    ReadingDirection? direction,
  }) {
    final scheduler = _media.frameScheduler;
    final frameBusy =
        scheduler.inPersistentCallbacks || scheduler.hasScheduledFrame;
    if (!frameBusy) return false;

    final role = _pagedOutputPrewarmRole(id);
    final uploadDemand = _binding?.pipeline.currentPlan.uploads[id];
    final verticalViewportVisible =
        (direction ?? _lastAcceptedControlObservation?.direction) ==
            ReadingDirection.vertical &&
        uploadDemand?.viewportVisible == true;
    final output = _pageOutputs[id.download.key];
    final detached =
        output == null ||
        output._listeners.isEmpty ||
        !output.snapshot.hasSurface;

    // Every physically visible page in continuous vertical mode has the same
    // first-frame presentation deadline. `current` remains navigation/progress
    // semantics; it must not make another on-screen transition wait for an
    // idle platform-create handoff. Horizontal PageView targets keep the
    // historical defer-until-idle behavior because their transition lease is
    // not necessarily part of the currently painted viewport.
    if (role == PageRole.current || verticalViewportVisible) return !detached;
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
      if (prewarmer == null || _binding == null) {
        _deferredOutputPrewarms.clear();
        return;
      }

      DecodeId? selectedId;
      ({int width, int height})? selectedSize;
      var selectedPriority = -1;
      for (final entry in _deferredOutputPrewarms.entries.toList(
        growable: false,
      )) {
        final role = _pagedOutputPrewarmRole(entry.key);
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
    _ensurePlaybackTicker();
  }

  void detach(String readerSessionId) {
    _invalidateObservationQueue();
    _binding?.detach(readerSessionId);
    _binding = null;
    _readerSessionId = null;
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
    for (final token in _externalPresentationPrewarmTokens.values) {
      token.cancel();
    }
    _externalPresentationPrewarmTokens.clear();
    // Reader-route retention ends widget/output/decode lifetimes, but the
    // composition-owned PipelinePresentationRasterCache may still retain exact
    // fallback rasters under its own claim/budget authority. Keep only their
    // lightweight presentation-generation identities so re-entry can reuse
    // the same managed provider keys instead of manufacturing a new generation
    // solely because the route disappeared.
    _externalPresentationRequests.clear();
    _externalPresentationReady.clear();
    _externalPresentationPrewarmFailures.clear();
    _externalPresentationVisibleFrames.clear();
    _releasePresentationCacheClaims();
    final binding = _binding;
    final readerSessionId = _readerSessionId;
    _binding = null;
    _readerSessionId = null;
    binding?.detach(readerSessionId ?? sessionId);
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
    _deferredOutputPrewarms.clear();

    // Reader re-entry retention exists to preserve expensive transfer/source
    // authority, not decoded presentation state. A NativeCursor owns an Arc to
    // its encoded ByteSource plus a full RGBA canvas; keeping one detached
    // decode frame per old viewport therefore pins both the compressed page
    // body and native raster working set even after the physical transfer
    // registry retires that page. Retire uploads first so their frame claims
    // are released, then retire every decode/cursor. Re-entry recreates this
    // cheap Reader-local media layer from the retained DownloadSession bytes.
    final retainedDecodedBytes = _decodes.totalBytes;
    final retainedOutputBytes = _uploads.totalBytes;
    final retainedUploadSessions = _uploads.sessions.toList(growable: false);
    for (final upload in retainedUploadSessions) {
      _uploads.evict(upload.id);
    }
    final retainedDecodeSessions = _decodes.sessions.toList(growable: false);
    for (final decode in retainedDecodeSessions) {
      _decodes.evict(decode.id);
    }
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerSessionRetained,
        payload: <String, Object?>{
          'downloadSessions': _downloads.sessions.length,
          'decodeSessions': _decodes.sessions.length,
          'uploadSessions': _uploads.sessions.length,
          'ingressProjections': _ingresses.projections.length,
          'streamingSources': _streamingSources.ids.length,
          'releasedDecodeSessions': retainedDecodeSessions.length,
          'releasedUploadSessions': retainedUploadSessions.length,
          'releasedDecodedBytes': retainedDecodedBytes,
          'releasedOutputBytes': retainedOutputBytes,
        },
      ),
    );
  }

  void _releasePresentationCacheClaims() {
    final authority = _presentationCacheAuthority;
    if (authority == null) return;
    for (final identity in _externalPresentationCacheIdentities.values) {
      authority.releasePresentationClaim(identity);
    }
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
    final output = _pageOutputs.putIfAbsent(id.key, () => _newPageOutput(id));
    final outputIdentity = _activePagedOutputIdentity(id);
    output._bind(
      outputIdentity,
      retainedStaticIdentity: outputIdentity == null
          ? _staticPresentationContinuityIdentity(id)
          : null,
    );
    output._setExternalPresentationCacheIdentity(
      outputIdentity == null
          ? null
          : _externalPresentationCacheIdentityFor(outputIdentity),
    );
    output._setExternalPresentationRequested(
      outputIdentity != null &&
          _externalPresentationRequests.contains(outputIdentity) &&
          _coordinator.externalPresentationPendingFor(outputIdentity),
    );
    output._setExternalPresentationReady(
      outputIdentity != null &&
          _externalPresentationReadyForOutput(outputIdentity),
    );
    return output;
  }

  /// Reports an actually presented first frame for an external/fallback
  /// renderer. Native Pipeline surfaces ignore this because their readiness is
  /// already owned by UploadRegistry/PresentClaim. A detached managed-raster
  /// warm may already have satisfied the staged watermark; the visible frame still
  /// gets traced, but it does not manufacture a second coordinator completion.
  void reportPresentationFrameReady(PageAsset asset) {
    if (_disposed) return;
    final download = readerPageDownloadId(chapter, asset);
    DecodeId? identity;
    for (final candidate in _coordinator.decodeDemands.keys) {
      if (candidate.download == download) {
        identity = candidate;
        break;
      }
    }
    if (identity == null) return;
    final firstVisible = _externalPresentationVisibleFrames.add(identity);
    if (firstVisible) {
      _syncTransferProgressPresentationSatisfaction(download);
      _transferRuntime.notifyPresentationSatisfied(download);
    }
    final pending =
        _externalPresentationRequests.contains(identity) &&
        _coordinator.externalPresentationPendingFor(identity);
    if (pending) {
      _externalPresentationRequests.remove(identity);
      _externalPresentationReady.add(identity);
      _externalPresentationPrewarmTokens.remove(identity)?.cancel();
      final output = _pageOutputs[download.key];
      output?._setExternalPresentationRequested(false);
      output?._setExternalPresentationReady(true);
      if (_coordinator.completeExternalPresentation(sessionId, identity)) {
        _recordExternalPresentationFirstFrame(
          identity,
          owner: 'mounted-presentation',
          preparedOnly: false,
        );
      }
      return;
    }
    if (firstVisible && _externalPresentationReady.contains(identity)) {
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.readerObservation,
          identityHash: identity.key,
          revision: revision,
          payload: const <String, Object?>{
            'stage': 'external-presentation-visible-first-frame',
            'owner': 'mounted-presentation',
            'prepared': true,
          },
        ),
      );
    }
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
      onExternalPresentationConsumerChanged:
          _handleExternalPresentationConsumerChanged,
    );
    if (detachedPrewarm) {
      output._enableDetachedPrewarm();
    }
    return output;
  }

  PageRole? _pagedOutputPrewarmRole(
    DecodeId id, {
    ReadingDirection? direction,
  }) {
    final plan = _binding?.pipeline.currentPlan;
    final uploadRole = plan?.uploads[id]?.role;
    if (uploadRole == PageRole.current ||
        uploadRole == PageRole.transition ||
        uploadRole == PageRole.next ||
        uploadRole == PageRole.next2 ||
        uploadRole == PageRole.previous) {
      return uploadRole;
    }
    // Horizontal animated-next intentionally has DecodeDemand but no
    // UploadDemand. It may still pre-create only an empty platform lease so
    // the first visible upload does not also pay SurfaceProducer creation.
    // Continuous vertical presentation does not gain that extra decode-only
    // lease: it prebinds only roles that already own real UploadDemand, so the
    // fix below cannot widen animated work or the 2/1 static deadline window.
    final effectiveDirection =
        direction ?? _lastAcceptedControlObservation?.direction;
    if (effectiveDirection == ReadingDirection.vertical) return null;
    final decodeRole = plan?.decodes[id]?.role;
    return decodeRole == PageRole.next ? PageRole.next : null;
  }

  void _maybePrewarmPagedOutput(DecodeId id, {ReaderObs? observation}) {
    final acceptedObservation = observation ?? _lastAcceptedControlObservation;
    if (acceptedObservation == null ||
        _media.renderer != RendererKind.androidTexture) {
      return;
    }
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    if (pageIndex == null) return;
    final role = _pagedOutputPrewarmRole(
      id,
      direction: acceptedObservation.direction,
    );
    if (role == null) {
      // Continuous vertical presentation prebinds only the existing static
      // UploadDemand deadline window. Horizontal gallery keeps its historical
      // decode-only animated-next lease optimization. The outer encoded/far
      // window remains presentation-inert in both modes.
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
        direction: acceptedObservation.direction,
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
          role: role,
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
    final shouldTrace =
        existing == null ||
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
        role: role,
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
    if (hasWebpUriSuffix(asset.uri)) return true;
    return !hasKnownNonWebpImageSuffix(asset.uri);
  }

  bool _mayUseEncodedPresentationFile(
    PageAsset asset,
    ContentKind? contentKind,
  ) {
    switch (contentKind) {
      case ContentKind.webp:
      case ContentKind.gif:
        return false;
      case ContentKind.fallback:
        return true;
      case ContentKind.unknown:
      case null:
        break;
    }
    switch (asset.contentKindHint) {
      case ContentKindHint.webp:
      case ContentKindHint.gif:
        return false;
      case ContentKindHint.jpeg:
      case ContentKindHint.png:
      case ContentKindHint.avif:
      case ContentKindHint.fallback:
        return true;
      case ContentKindHint.unknown:
        break;
    }
    final path = asset.uri.path.toLowerCase();
    return !path.endsWith('.webp') && !path.endsWith('.gif');
  }

  Future<PipelineEncodedPresentationFileLease?> openEncodedPresentationFile(
    PageAsset asset,
    MediaLoadToken token,
  ) async {
    if (_bytesLoader != null) return null;
    token.throwIfCancelled();
    final cache = _artifactCacheManager;
    if (cache == null) return null;
    final id = readerPageDownloadId(chapter, asset);
    final session = _downloads.find(id);
    if (!_mayUseEncodedPresentationFile(asset, session?.contentKind)) {
      return null;
    }
    final started = clock.nowMicros();
    ArtifactCachePresentationFileRead? read;
    final retainedHistoricalPresentation = cache.requiresFreshSource(id);
    try {
      final control = _MediaLoadTaskControl(token);
      read = retainedHistoricalPresentation
          ? await cache.openRetainedHistoricalPresentationFile(
              id,
              control: control,
            )
          : await cache.openPresentationFile(id, control: control);
      if (token.isCancelled) {
        await read?.release();
        token.throwIfCancelled();
      }
      if (read == null) return null;
      final width = asset.width ?? read.width;
      final height = asset.height ?? read.height;
      if (width == null || height == null || width <= 0 || height <= 0) {
        await read.release();
        _recordPresentationFileLeaseFallback(
          asset: asset,
          id: id,
          reason: 'intrinsic-dimensions-unavailable',
          readMicros: clock.nowMicros() - started,
        );
        return null;
      }
      final authority = PipelinePresentationArtifactAuthority(
        storageId: read.storageId,
        generation: read.generation,
      );
      _publishPageSourceDimensions(
        id: id,
        asset: asset,
        width: width,
        height: height,
        source: 'presentation-file-lease',
      );
      _recordPresentationFileLease(
        asset: asset,
        id: id,
        length: read.length,
        readMicros: clock.nowMicros() - started,
        storageId: read.storageId,
        generation: read.generation,
        width: width,
        height: height,
        retainedHistoricalPresentation: retainedHistoricalPresentation,
      );
      return PipelineEncodedPresentationFileLease(
        path: read.path,
        length: read.length,
        cacheIdentity: read.cacheIdentity,
        width: width,
        height: height,
        authority: authority,
        release: read.release,
      );
    } on Object catch (error) {
      if (token.isCancelled) {
        await read?.release();
        token.throwIfCancelled();
      }
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.taskFailed,
          identityHash: id.key,
          revision: revision,
          payload: <String, Object?>{
            'lane': 'artifact-cache-presentation-file',
            'consumer': 'pipeline-presentation',
            'reason': error.toString(),
            'readMicros': clock.nowMicros() - started,
            'fallback': 'encoded-bytes',
          },
        ),
      );
      return null;
    }
  }

  Future<Uint8List> loadBytes(PageAsset asset, MediaLoadToken token) async =>
      (await loadPresentationBytes(asset, token)).bytes;

  Future<PipelinePresentationBytes> loadPresentationBytes(
    PageAsset asset,
    MediaLoadToken token,
  ) async {
    final override = _bytesLoader;
    final id = readerPageDownloadId(chapter, asset);
    if (override != null) {
      return PipelinePresentationBytes(bytes: await override(asset, token));
    }
    token.throwIfCancelled();
    final cache = _artifactCacheManager;
    if (cache != null && cache.requiresFreshSource(id)) {
      final readStarted = clock.nowMicros();
      final retained = await cache.readRetainedHistoricalPresentation(
        id,
        control: _MediaLoadTaskControl(token),
      );
      token.throwIfCancelled();
      if (retained != null) {
        final authority = PipelinePresentationArtifactAuthority(
          storageId: retained.storageId,
          generation: retained.generation,
        );
        _recordPresentationCacheRead(
          asset: asset,
          id: id,
          bytes: retained.bytes,
          source: 'retained-historical-presentation',
          readMode: retained.memoryHit ? 'memory-hit' : 'read-all',
          readMicros: clock.nowMicros() - readStarted,
          memoryHit: retained.memoryHit,
          joined: retained.joined,
          integrityBasis: retained.integrityBasis.name,
        );
        return PipelinePresentationBytes(
          bytes: retained.bytes,
          authority: authority,
        );
      }
    }
    final hotRead = cache?.lookupMemoryWithAuthority(id);
    if (hotRead != null) {
      final hotBytes = hotRead.bytes;
      final authority = PipelinePresentationArtifactAuthority(
        storageId: hotRead.storageId,
        generation: hotRead.generation,
      );
      _recordPresentationCacheRead(
        asset: asset,
        id: id,
        bytes: hotBytes,
        source: 'artifact-byte-cache',
        readMode: 'memory-hit',
        readMicros: 0,
        memoryHit: true,
        joined: false,
        integrityBasis: ArtifactReadIntegrityBasis.memoryResident.name,
      );
      return PipelinePresentationBytes(bytes: hotBytes, authority: authority);
    }

    final session = _downloads.find(id);
    if ((session == null ||
            session.state != DownloadState.promoted ||
            session.residentBodyBacked) &&
        cache != null) {
      final readStarted = clock.nowMicros();
      try {
        final cached = await cache.readForeground(
          id,
          control: _MediaLoadTaskControl(token),
        );
        token.throwIfCancelled();
        if (cached != null) {
          final authority = PipelinePresentationArtifactAuthority(
            storageId: cached.storageId,
            generation: cached.generation,
          );
          final readMicros = clock.nowMicros() - readStarted;
          _recordPresentationCacheRead(
            asset: asset,
            id: id,
            bytes: cached.bytes,
            source: cached.memoryHit ? 'artifact-byte-cache' : 'artifact-cache',
            readMode: cached.memoryHit
                ? 'memory-hit'
                : cached.joined
                ? 'joined-read-all'
                : 'read-all',
            readMicros: readMicros,
            memoryHit: cached.memoryHit,
            joined: cached.joined,
            integrityBasis: cached.integrityBasis.name,
            sessionState: session?.state.name,
          );
          return PipelinePresentationBytes(
            bytes: cached.bytes,
            authority: authority,
          );
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
      return PipelinePresentationBytes(
        bytes: await _readDirectImmutableSource(asset, id, session, token),
      );
    }
    if (session.state != DownloadState.promoted) {
      await _waitForPromotion(session, token);
    }
    token.throwIfCancelled();
    if (session.residentBodyBacked) {
      // A promoted resident-body session intentionally owns no duplicate
      // writable Artifact body. This is the durable/historical-cache fast
      // path used after provider URI churn: the immutable bytes stay behind
      // the composition-owned resident replay capability while
      // session.artifact remains empty by design.
      //
      // Presentation must therefore replay that resident authority directly.
      // Falling through to readSessionArtifact(session.artifact) turns a
      // healthy promoted cache hit into "artifact cache entry is empty" and
      // incorrectly requires a user retry/source reload.
      return PipelinePresentationBytes(
        bytes: await _readResidentPresentationBody(asset, id, session, token),
      );
    }
    final artifactReadStarted = clock.nowMicros();
    final cacheRead = cache == null
        ? null
        : await cache.readSessionArtifact(
            id: id,
            length: session.artifact.committedLength,
            loader: () => _transferRuntime.readArtifact(session.artifact),
            control: _MediaLoadTaskControl(token),
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
      integrityBasis:
          cacheRead?.integrityBasis.name ??
          ArtifactReadIntegrityBasis.sessionArtifact.name,
    );
    return PipelinePresentationBytes(bytes: bytes);
  }

  Future<Uint8List> _readResidentPresentationBody(
    PageAsset asset,
    DownloadId id,
    DownloadSession session,
    MediaLoadToken token,
  ) async {
    final expectedLength = session.committedLength;
    if (expectedLength <= 0) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident presentation authority has no committed body',
      );
    }
    final started = clock.nowMicros();
    final control = _MediaLoadTaskControl(token);
    final chunks = await _residentReplaySourceWithControl(
      session,
      expectedLength,
      control: control,
    );
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in chunks) {
      token.throwIfCancelled();
      if (chunk.isEmpty) continue;
      received += chunk.length;
      if (received > expectedLength) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'resident presentation replay exceeded '
              '$expectedLength for ${id.key}',
        );
      }
      builder.add(chunk);
    }
    token.throwIfCancelled();
    final bytes = builder.takeBytes();
    if (bytes.lengthInBytes != expectedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message:
            'resident presentation replay was short: '
            '${bytes.lengthInBytes}/$expectedLength for ${id.key}',
      );
    }
    _recordPresentationCacheRead(
      asset: asset,
      id: id,
      bytes: bytes,
      source: 'resident-body',
      readMode: 'resident-replay',
      readMicros: clock.nowMicros() - started,
      memoryHit: false,
      joined: false,
      // The resident replay capability may be backed by a durable cache
      // stream or an immutable source. Its owner currently exposes bytes and
      // lifetime, not a unified integrity-proof enum, so do not mislabel it
      // as a writable session Artifact read.
      integrityBasis: ArtifactReadIntegrityBasis.unspecified.name,
      sessionState: session.state.name,
    );
    return bytes;
  }

  /// Presentation reports semantic decode/format rejection back to the
  /// composition owner. A failure of an already-resident managed raster has
  /// no artifact authority and therefore retires only the volatile
  /// presentation generation. A failure carrying exact artifact authority may
  /// invalidate that durable generation. Each automatic tier is bounded once
  /// per page/Reader session; explicit user retry may request fresh bytes.
  Future<bool> recoverPresentationFailure(
    PageAsset asset,
    Object error, {
    bool userInitiated = false,
    PipelinePresentationArtifactAuthority? rejectedAuthority,
  }) async {
    _requireOpen();
    final id = readerPageDownloadId(chapter, asset);
    final authority = rejectedAuthority;
    if (!userInitiated) {
      if (authority == null) {
        if (!_automaticPresentationRasterRecoveries.add(id)) return false;
        final recovered = _recoverExternalPresentationRasterGeneration(
          id,
          error,
        );
        if (!recovered) {
          _automaticPresentationRasterRecoveries.remove(id);
        }
        return recovered;
      }
      if (!_automaticPresentationRecoveries.add(id)) return false;
    }
    final recovered = await _transferRuntime.recoverPresentationArtifact(
      id,
      reason: error.runtimeType.toString(),
      userInitiated: userInitiated,
      rejectedStorageId: authority?.storageId,
      rejectedGeneration: authority?.generation,
    );
    if (recovered) {
      _rotateExternalPresentationCacheIdentity(id);
      _downloadTransfer.refreshScheduling();
    }
    return recovered;
  }

  Future<bool> forceReloadPresentation(PageAsset asset) async {
    _requireOpen();
    final id = readerPageDownloadId(chapter, asset);
    final recovered = await _transferRuntime.recoverPresentationArtifact(
      id,
      reason: 'manual-force-reload',
      userInitiated: true,
    );
    if (recovered) {
      _automaticPresentationRecoveries.remove(id);
      _automaticPresentationRasterRecoveries.remove(id);
      _rotateExternalPresentationCacheIdentity(id);
      _downloadTransfer.refreshScheduling();
    }
    return recovered;
  }

  Future<bool> retryPresentation(PageAsset asset) =>
      forceReloadPresentation(asset);

  Future<Uint8List> _readDirectImmutableSource(
    PageAsset asset,
    DownloadId id,
    DownloadSession session,
    MediaLoadToken token,
  ) async {
    final started = clock.nowMicros();
    final cache = _artifactCacheManager;
    final cacheGeneration = cache?.generationFor(id);
    final resumeValidators = session.resumeValidatorsFor(asset.uri);
    final control = _MediaLoadTaskControl(token);
    final response = await _openDirectImmutableSourceResponse(
      asset.uri,
      validators: resumeValidators.canResume ? resumeValidators : null,
      control: control,
    );
    if (resumeValidators.canResume &&
        !resumeValidators.matches(response.validators)) {
      await response.discard(control: control);
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'direct immutable image source revision changed',
      );
    }
    final builder = BytesBuilder(copy: false);
    final iterator = StreamIterator<List<int>>(response.bytes);
    try {
      while (await _moveNextDirectImmutableSource(iterator, control)) {
        final chunk = iterator.current;
        token.throwIfCancelled();
        if (chunk.isNotEmpty) builder.add(chunk);
      }
    } finally {
      try {
        await iterator.cancel();
      } finally {
        await response.discard(control: control);
      }
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
        message:
            'direct immutable image source length changed: '
            '${bytes.lengthInBytes}/$expected',
      );
    }
    // Keep the validated immutable body in the presentation memory tier so
    // rapid keep-alive eviction/remount cycles during fast continuous
    // scrolling do not repeat the same source read. Promotion still owns the
    // durable artifact; a later promotion remember() supersedes this entry.
    // A read that began before invalidation must not repopulate the memory
    // tier after that invalidation, and a cancelled presentation must not
    // retain bytes after its consumer has withdrawn.
    control.throwIfCancelled();
    cache?.remember(id: id, bytes: bytes, generation: cacheGeneration);
    final presentationBytes = cache?.lookupMemory(id) ?? bytes;
    _recordPresentationCacheRead(
      asset: asset,
      id: id,
      bytes: bytes,
      source: 'direct-source',
      readMode: 'direct-read-all',
      readMicros: clock.nowMicros() - started,
      memoryHit: false,
      joined: false,
      integrityBasis: ArtifactReadIntegrityBasis.directImmutableSource.name,
      sessionState: session.state.name,
    );
    return presentationBytes;
  }

  Future<ByteResponse> _openDirectImmutableSourceResponse(
    Uri uri, {
    required Validators? validators,
    required TaskControl control,
  }) async {
    final transport = _baseTransportFor(uri);
    final controlled = transport is ControlledTransport ? transport : null;
    control.throwIfCancelled();
    final pending = controlled == null
        ? Future<ByteResponse>.sync(
            () => transport.open(uri, validators: validators),
          )
        : Future<ByteResponse>.sync(
            () => controlled.openControlled(
              uri,
              validators: validators,
              control: control,
            ),
          );
    try {
      return await Future.any<ByteResponse>(<Future<ByteResponse>>[
        pending,
        control.whenCancelled.then<ByteResponse>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'direct immutable source read was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) {
        // An uncontrolled loader may finish after the presentation request has
        // already been cancelled. Do not leave its late response subscribed;
        // controlled transports use the same discard boundary for symmetry.
        unawaited(
          pending.then<void>(
            (response) => response.discard(control: control),
            onError: (Object _, StackTrace __) {},
          ),
        );
        control.throwIfCancelled();
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<bool> _moveNextDirectImmutableSource(
    StreamIterator<List<int>> iterator,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    final result = await Future.any<Object>(<Future<Object>>[
      _moveNextDirectImmutableSourceWithWatchdog(
        iterator,
      ).then<Object>(_DirectNextChunk.new),
      control.whenCancelled.then<Object>((_) => const _DirectCancelled()),
    ]);
    if (result is _DirectCancelled) {
      await iterator.cancel();
      control.throwIfCancelled();
    }
    return (result as _DirectNextChunk).available;
  }

  Future<bool> _moveNextDirectImmutableSourceWithWatchdog(
    StreamIterator<List<int>> iterator,
  ) {
    final timeout = DownloadJob.defaultReadStallTimeout;
    if (timeout <= Duration.zero) return iterator.moveNext();
    final watchdog = Completer<Never>();
    final timer = Timer(timeout, () {
      if (!watchdog.isCompleted) {
        watchdog.completeError(
          const Failure(
            code: ErrorCode.network,
            message:
                'direct immutable source body read stalled: no bytes within the read stall window',
          ),
        );
      }
    });
    return Future.any<bool>(<Future<bool>>[
      Future<bool>.sync(iterator.moveNext),
      watchdog.future,
    ]).then<bool>(
      (available) {
        timer.cancel();
        return available;
      },
      onError: (Object error, StackTrace stackTrace) async {
        timer.cancel();
        if (watchdog.isCompleted) {
          await iterator.cancel();
        }
        throw Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  bool _isDirectImmutableLocalUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'file' || scheme == 'content' || scheme == 'asset';
  }

  void _recordPresentationFileLease({
    required PageAsset asset,
    required DownloadId id,
    required int length,
    required int readMicros,
    required DownloadId storageId,
    required int generation,
    required int width,
    required int height,
    required bool retainedHistoricalPresentation,
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
          'source': 'artifact-cache',
          'sourceClass': 'persistent-artifact',
          'uriScheme': asset.uri.scheme.isEmpty ? 'file' : asset.uri.scheme,
          'bytes': length,
          'readMicros': safeMicros,
          'artifactReadMode': 'presentation-file-lease',
          'retainedHistoricalPresentation': retainedHistoricalPresentation,
          'artifactIntegrityBasis':
              ArtifactReadIntegrityBasis.sealedMetadataLength.name,
          'artifactWholeChecksumVerifiedThisRead': false,
          'artifactMaterializeMicros': 0,
          'encodedWholeBodyMaterializedInDart': false,
          'presentationWidth': width,
          'presentationHeight': height,
          'artifactGeneration': generation,
          if (storageId != id) 'storageIdentityHash': storageId.key,
          'hotCacheEntries': _artifactCacheManager?.memoryEntryCount ?? 0,
          'hotCacheBytes': _artifactCacheManager?.memoryBytes ?? 0,
          'completed': true,
          'consumer': 'pipeline-presentation',
        },
      ),
    );
  }

  void _recordPresentationFileLeaseFallback({
    required PageAsset asset,
    required DownloadId id,
    required String reason,
    required int readMicros,
  }) {
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerObservation,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'stage': 'presentation-file-lease-fallback',
          'reason': reason,
          'uriScheme': asset.uri.scheme.isEmpty ? 'file' : asset.uri.scheme,
          'readMicros': readMicros < 0 ? 0 : readMicros,
          'fallback': 'encoded-bytes',
        },
      ),
    );
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
    required String integrityBasis,
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
          'sourceClass':
              source == 'session-artifact' || source == 'direct-source'
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
          'artifactIntegrityBasis': integrityBasis,
          'artifactWholeChecksumVerifiedThisRead':
              integrityBasis == ArtifactReadIntegrityBasis.crc32Verified.name,
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
    if (_outputPrewarmSnapshotListeners.containsKey(session)) return;
    late final DownloadSnapshotListener listener;
    listener = (snapshot) {
      _handleDownloadSnapshotForOutputPrewarm(snapshot);
    };
    _outputPrewarmSnapshotListeners[session] = listener;
    session.addSnapshotListener(listener);
  }

  void _handleDownloadSnapshotForOutputPrewarm(DownloadSnapshot snapshot) {
    if (_disposed || _retainedForReaderReentry || !snapshot.hasSourceCanvas) {
      return;
    }
    final sourcePageIndex = _pageIndexByPageId[snapshot.id.content.pageId];
    if (sourcePageIndex != null) {
      final asset = chapter.pages[sourcePageIndex];
      _publishPageSourceDimensions(
        id: snapshot.id,
        asset: asset,
        width: asset.width ?? snapshot.sourceCanvasWidth!,
        height: asset.height ?? snapshot.sourceCanvasHeight!,
        source: asset.width != null && asset.height != null
            ? 'manifest-source-canvas'
            : 'physical-ingress-source-canvas',
      );
    }
    if (_media.renderer != RendererKind.androidTexture) return;
    final observation = _lastAcceptedControlObservation;
    if (observation == null ||
        observation.direction == ReadingDirection.vertical) {
      return;
    }
    final id = _activeDecodeIdentity(snapshot.id);
    if (id == null || _outputPrewarmSizes.containsKey(id)) return;
    if (_pagedOutputPrewarmRole(id) == null) return;
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
      direction: observation.direction,
    );
  }

  void _handleSourceKindObserved(DownloadId id, ContentKind kind) {
    scheduleMicrotask(() {
      if (_disposed) return;
      final pageIndex = _pageIndexByPageId[id.content.pageId];
      if (pageIndex == null) return;
      final binding = _binding;
      if (binding == null) return;
      final download = _downloads.find(id);
      var staticClassificationChanged = false;
      EncodedImageKind? encodedKind;
      if (kind == ContentKind.fallback && download != null) {
        encodedKind = sniffEncodedImageKind(download.readSourceMetadataPrefix());
        if (_isStaticFallbackImageKind(encodedKind)) {
          final asset = chapter.pages[pageIndex];
          final localPresentationReady =
              _isDirectImmutableLocalUri(asset.uri) ||
              download.residentBodyBacked;
          staticClassificationChanged = binding.classifyPage(
            pageIndex: pageIndex,
            animated: false,
            localPresentationReady: localPresentationReady,
            externalPresentationRequired: true,
          );
          if (staticClassificationChanged) {
            trace.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.mediaClassified,
                identityHash: id.key,
                revision: revision,
                payload: <String, Object?>{
                  'pageIndex': pageIndex,
                  'animated': false,
                  'localPresentationReady': localPresentationReady,
                  'basis': 'encoded-prefix',
                  'encodedKind': encodedKind!.name,
                },
              ),
            );
          }
        }
      }
      final transportCostChanged = binding.observeWebpTransportCost(
        pageIndex: pageIndex,
        webp: kind == ContentKind.webp,
      );
      if (transportCostChanged) {
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
      }
      if (!staticClassificationChanged && !transportCostChanged) return;
      artifactReadScheduler.refresh();
      if (staticClassificationChanged) {
        _syncPageOutputs();
      }
    });
  }

  bool _isStaticFallbackImageKind(EncodedImageKind? kind) => switch (kind) {
    EncodedImageKind.jpeg ||
    EncodedImageKind.png ||
    EncodedImageKind.bmp ||
    EncodedImageKind.tiff ||
    EncodedImageKind.ico ||
    EncodedImageKind.avif ||
    EncodedImageKind.heif => true,
    EncodedImageKind.webp || EncodedImageKind.gif || null => false,
  };

  bool _hasMountedExternalPresentationConsumer(DecodeId id) {
    final output = _pageOutputs[id.download.key];
    return output != null &&
        output._identity == id &&
        output._listeners.isNotEmpty;
  }

  bool _canDetachedExternalPresentationPrewarm(DecodeId id) {
    if (_externalPresentationPrewarmer == null ||
        _externalPresentationPrewarmFailures.contains(id)) {
      return false;
    }
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    final binding = _binding;
    if (pageIndex == null ||
        binding == null ||
        !binding.pipeline.isRuntimeExternalStaticPage(pageIndex)) {
      return false;
    }
    final authority = _presentationCacheAuthority;
    if (authority == null) return true;
    return authority.allowsPresentationWarm(
      _externalPresentationCacheIdentityFor(id),
    );
  }

  bool _externalPresentationAvailable(DecodeId id) =>
      _hasMountedExternalPresentationConsumer(id) ||
      _canDetachedExternalPresentationPrewarm(id);

  Object _externalPresentationCacheIdentityFor(DecodeId id) {
    final existing = _externalPresentationCacheIdentities[id];
    if (existing != null) return existing;
    final identity = Object();
    _externalPresentationCacheIdentities[id] = identity;
    _syncExternalPresentationCacheClaimFor(id, identity);
    return identity;
  }

  PipelinePresentationCacheClaim? _externalPresentationCacheClaimFor(
    DecodeId id,
  ) {
    final demand = _coordinator.decodeDemands[id];
    if (demand == null) return null;
    final upload = _coordinator.uploadDemands[id];
    if (upload?.viewportVisible == true ||
        demand.role == PageRole.current ||
        demand.role == PageRole.transition) {
      return PipelinePresentationCacheClaim.protected;
    }
    return switch (demand.role) {
      PageRole.next ||
      PageRole.next2 ||
      PageRole.previous ||
      PageRole.near ||
      PageRole.last => PipelinePresentationCacheClaim.deadline,
      PageRole.far ||
      PageRole.detached => PipelinePresentationCacheClaim.speculative,
      PageRole.current ||
      PageRole.transition => PipelinePresentationCacheClaim.protected,
    };
  }

  void _syncExternalPresentationCacheClaimFor(
    DecodeId id,
    Object presentationIdentity,
  ) {
    final authority = _presentationCacheAuthority;
    if (authority == null) return;
    final claim = _externalPresentationCacheClaimFor(id);
    if (claim == null) {
      authority.releasePresentationClaim(presentationIdentity);
      return;
    }
    authority.updatePresentationClaim(presentationIdentity, claim);
  }

  void _syncExternalPresentationCacheClaims() {
    for (final entry in _externalPresentationCacheIdentities.entries) {
      _syncExternalPresentationCacheClaimFor(entry.key, entry.value);
    }
  }

  void _rotateExternalPresentationCacheIdentityFor(DecodeId id) {
    final previous = _externalPresentationCacheIdentities[id];
    if (previous != null) {
      _presentationCacheAuthority?.invalidatePresentationIdentity(previous);
    }
    if (previous == null ||
        identical(_externalPresentationCacheIdentities[id], previous)) {
      final next = Object();
      _externalPresentationCacheIdentities[id] = next;
      _syncExternalPresentationCacheClaimFor(id, next);
    }
  }

  bool _recoverExternalPresentationRasterGeneration(
    DownloadId download,
    Object error,
  ) {
    final authority = _presentationCacheAuthority;
    if (authority == null) return false;
    final identities = <DecodeId>{
      ..._externalPresentationCacheIdentities.keys.where(
        (identity) => identity.download == download,
      ),
      ..._coordinator.decodeDemands.keys.where(
        (identity) => identity.download == download,
      ),
    };
    var recovered = false;
    for (final identity in identities) {
      if (!_coordinator.decodeDemands.containsKey(identity)) continue;
      final previous = _externalPresentationCacheIdentities[identity];
      if (previous == null) continue;

      // A resident-raster fault is not evidence that encoded bytes are bad.
      // Publish the replacement generation before evicting the rejected
      // raster so its synchronous invalidation callback cannot reinterpret
      // this explicit fault as an ordinary same-generation budget eviction.
      final replacement = Object();
      _externalPresentationCacheIdentities[identity] = replacement;
      _syncExternalPresentationCacheClaimFor(identity, replacement);
      authority.invalidatePresentationIdentity(previous);

      _externalPresentationPrewarmTokens.remove(identity)?.cancel();
      _externalPresentationRequests.remove(identity);
      _externalPresentationReady.remove(identity);
      _externalPresentationPrewarmFailures.remove(identity);
      _externalPresentationVisibleFrames.remove(identity);

      final output = _pageOutputs[download.key];
      if (output != null && output._identity == identity) {
        output._setExternalPresentationCacheIdentity(replacement);
        output._setExternalPresentationRequested(false);
        output._setExternalPresentationReady(false);
      }
      _coordinator.invalidateExternalPresentation(sessionId, identity);
      _coordinator.updateExternalPresentationAvailability(
        sessionId,
        identity,
        available: _externalPresentationAvailable(identity),
      );
      recovered = true;
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.policyDecision,
          identityHash: identity.key,
          revision: revision,
          payload: <String, Object?>{
            'stage': 'presentation-raster-generation-recovery',
            'action': 'automatic-redecode',
            'errorType': error.runtimeType.toString(),
            'durableArtifactInvalidated': false,
          },
        ),
      );
    }
    if (recovered && _lastControlCurrentDownload == download) {
      _syncTransferProgressPresentationSatisfaction(download);
    }
    return recovered;
  }

  void _handlePresentationCacheInvalidated(Object presentationIdentity) {
    if (_disposed) return;
    DecodeId? invalidated;
    for (final entry in _externalPresentationCacheIdentities.entries) {
      if (identical(entry.value, presentationIdentity)) {
        invalidated = entry.key;
        break;
      }
    }
    if (invalidated == null) return;
    final currentIdentity = _externalPresentationCacheIdentities[invalidated];
    if (!identical(currentIdentity, presentationIdentity)) return;

    _externalPresentationPrewarmTokens.remove(invalidated)?.cancel();
    _externalPresentationRequests.remove(invalidated);
    _externalPresentationReady.remove(invalidated);
    _externalPresentationPrewarmFailures.remove(invalidated);
    _externalPresentationVisibleFrames.remove(invalidated);
    // Residency loss is not a presentation-generation change. Keep the
    // exact source/DecodeId/fit identity stable so a later staged warm can
    // refill the same managed cache entry without manufacturing a new raster
    // key. Only source/recovery/fit changes rotate the identity.

    final demand = _coordinator.decodeDemands[invalidated];
    final presentationWarmAllowed =
        _presentationCacheAuthority?.allowsPresentationWarm(
          presentationIdentity,
        ) ??
        true;
    // Residency/admission backpressure belongs to the cache authority that
    // performed the eviction. Pipeline only invalidates its satisfaction proof;
    // it must not maintain a second "evicted while far" tombstone. A budget
    // victim stays asleep while the owner denies speculative admission and is
    // woken naturally when claim promotion clears that denial.
    _coordinator.invalidateExternalPresentation(
      sessionId,
      invalidated,
      wakeIdentity: presentationWarmAllowed,
    );

    final output = _pageOutputs[invalidated.download.key];
    if (output != null && output._identity == invalidated) {
      output._setExternalPresentationCacheIdentity(
        _externalPresentationCacheIdentityFor(invalidated),
      );
      output._setExternalPresentationRequested(false);
      output._setExternalPresentationReady(false);
    }
    if (_lastControlCurrentDownload == invalidated.download) {
      _syncTransferProgressPresentationSatisfaction(invalidated.download);
    }
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.policyDecision,
        identityHash: invalidated.key,
        revision: revision,
        payload: <String, Object?>{
          'stage': 'presentation-raster-cache-invalidated',
          'role': demand?.role.name,
          'presentationWarmAllowed': presentationWarmAllowed,
        },
      ),
    );
  }

  void _rotateExternalPresentationCacheIdentity(DownloadId download) {
    final identities = <DecodeId>{
      ..._externalPresentationCacheIdentities.keys.where(
        (identity) => identity.download == download,
      ),
      ..._coordinator.decodeDemands.keys.where(
        (identity) => identity.download == download,
      ),
    };
    for (final identity in identities) {
      _externalPresentationPrewarmTokens.remove(identity)?.cancel();
      _rotateExternalPresentationCacheIdentityFor(identity);
      _externalPresentationReady.remove(identity);
      _externalPresentationPrewarmFailures.remove(identity);
      _externalPresentationVisibleFrames.remove(identity);
    }
    final output = _pageOutputs[download.key];
    final outputIdentity = output?._identity;
    if (output != null && outputIdentity != null) {
      output._setExternalPresentationCacheIdentity(
        _externalPresentationCacheIdentityFor(outputIdentity),
      );
      output._setExternalPresentationReady(false);
    }
    if (_lastControlCurrentDownload == download) {
      _syncTransferProgressPresentationSatisfaction(download);
    }
  }

  bool _externalPresentationIsForeground(DecodeId id) {
    final demand = _coordinator.uploadDemands[id];
    if (demand == null) return false;
    return demand.viewportVisible ||
        demand.role == PageRole.current ||
        demand.role == PageRole.transition;
  }

  bool _preferDetachedExternalPresentation(DecodeId id) =>
      _canDetachedExternalPresentationPrewarm(id) &&
      !_externalPresentationIsForeground(id);

  bool _externalPresentationReadyForOutput(DecodeId id) {
    if (!_externalPresentationReady.contains(id) ||
        !_coordinator.externalPresentationSatisfiedFor(id)) {
      return false;
    }
    // The staged first-frame work has already completed in the composition's
    // unified presentation-raster owner. Do not make an already-mounted
    // offscreen page wait until it becomes visible before attaching to that
    // exact prepared cache entry.
    // UploadDemand still bounds the presentation lifetime; this only exposes
    // completed readiness and never creates a new grant or decode operation.
    return _coordinator.uploadDemands.containsKey(id);
  }

  void _handleExternalPresentationConsumerChanged(
    DecodeId? id,
    bool available,
  ) {
    if (_disposed || id == null) return;
    if (available) {
      _coordinator.updateExternalPresentationAvailability(
        sessionId,
        id,
        available: true,
      );
      final output = _pageOutputs[id.download.key];
      final pending =
          _externalPresentationRequests.contains(id) &&
          _coordinator.externalPresentationPendingFor(id);
      final preferDetached = pending && _preferDetachedExternalPresentation(id);
      if (pending && !preferDetached && output?._listeners.isNotEmpty == true) {
        _externalPresentationPrewarmTokens.remove(id)?.cancel();
      }
      output?._setExternalPresentationRequested(pending && !preferDetached);
      output?._setExternalPresentationReady(
        _externalPresentationReadyForOutput(id),
      );
      if (preferDetached) {
        _startExternalPresentationPrewarm(id, revision);
      }
      return;
    }

    // A detached static prewarmer is itself a real presentation consumer. A
    // PageView/Sliver host leaving the tree therefore must not revoke its grant.
    // Without that capability, preserve the historical listener-lifetime rule.
    if (_canDetachedExternalPresentationPrewarm(id)) {
      if (_externalPresentationRequests.contains(id) &&
          _coordinator.externalPresentationPendingFor(id)) {
        _startExternalPresentationPrewarm(id, revision);
      }
      return;
    }
    _externalPresentationRequests.remove(id);
    final output = _pageOutputs[id.download.key];
    output?._setExternalPresentationRequested(false);
    output?._setExternalPresentationReady(false);
    _coordinator.updateExternalPresentationAvailability(
      sessionId,
      id,
      available: false,
    );
  }

  void _handleExternalPresentationRequested(DecodeId id, int demandRevision) {
    scheduleMicrotask(() {
      if (_disposed ||
          !_coordinator.externalPresentationPendingFor(id) ||
          !_coordinator.decodeDemands.containsKey(id)) {
        return;
      }
      _externalPresentationRequests.add(id);
      final mounted = _hasMountedExternalPresentationConsumer(id);
      final detached = _canDetachedExternalPresentationPrewarm(id);
      final preferDetached = detached && !_externalPresentationIsForeground(id);
      final mountedOwnsRequest = mounted && !preferDetached;
      _pageOutputs[id.download.key]?._setExternalPresentationRequested(
        mountedOwnsRequest,
      );
      trace.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.readerObservation,
          identityHash: id.key,
          revision: demandRevision,
          payload: <String, Object?>{
            'stage': 'external-presentation-requested',
            'consumer': preferDetached || (!mounted && detached)
                ? 'detached-image-cache'
                : mountedOwnsRequest
                ? 'mounted-presentation'
                : 'none',
          },
        ),
      );
      if (preferDetached || (!mounted && detached)) {
        _startExternalPresentationPrewarm(id, demandRevision);
      }
    });
  }

  void _startExternalPresentationPrewarm(DecodeId id, int demandRevision) {
    final prewarmer = _externalPresentationPrewarmer;
    final binding = _binding;
    if (prewarmer == null ||
        binding == null ||
        _externalPresentationPrewarmTokens.containsKey(id) ||
        !_canDetachedExternalPresentationPrewarm(id) ||
        !_coordinator.externalPresentationPendingFor(id)) {
      return;
    }
    final pageIndex = _pageIndexByPageId[id.download.content.pageId];
    if (pageIndex == null) return;
    final asset = chapter.pages[pageIndex];
    final token = MediaLoadToken();
    final target = binding.pipeline.decodeTarget;
    _externalPresentationPrewarmTokens[id] = token;
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerObservation,
        identityHash: id.key,
        revision: demandRevision,
        payload: const <String, Object?>{
          'stage': 'external-presentation-prewarm-started',
          'owner': 'detached-image-cache',
        },
      ),
    );
    unawaited(() async {
      try {
        await prewarmer(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: id,
            cacheIdentity: _externalPresentationCacheIdentityFor(id),
            token: token,
            openEncodedPresentationFile: (loadToken) =>
                openEncodedPresentationFile(asset, loadToken),
            loadBytes: (loadToken) => loadBytes(asset, loadToken),
            maxPhysicalWidth: target.physicalWidth,
            maxPhysicalHeight: target.physicalHeight,
            fit: _externalPresentationFit,
          ),
        );
        token.throwIfCancelled();
        if (_disposed ||
            !identical(_externalPresentationPrewarmTokens[id], token) ||
            !_coordinator.externalPresentationPendingFor(id) ||
            !_coordinator.decodeDemands.containsKey(id)) {
          return;
        }
        _externalPresentationRequests.remove(id);
        _externalPresentationReady.add(id);
        _externalPresentationPrewarmFailures.remove(id);
        final output = _pageOutputs[id.download.key];
        output?._setExternalPresentationRequested(false);
        output?._setExternalPresentationReady(
          _externalPresentationReadyForOutput(id),
        );
        if (_coordinator.completeExternalPresentation(sessionId, id)) {
          // completeExternalPresentation changes the satisfied query used by the
          // ready projection, so refresh once after the coordinator commit.
          output?._setExternalPresentationReady(
            _externalPresentationReadyForOutput(id),
          );
          _recordExternalPresentationFirstFrame(
            id,
            owner: 'detached-image-cache',
            preparedOnly: true,
            demandRevision: demandRevision,
          );
        }
      } on Object catch (error) {
        if (token.isCancelled || _disposed) return;
        if (!identical(_externalPresentationPrewarmTokens[id], token)) return;
        _externalPresentationPrewarmFailures.add(id);
        final mounted = _hasMountedExternalPresentationConsumer(id);
        if (mounted) {
          // The visible adapter may have attached while detached warming was
          // in flight. A detached optimization miss must not revoke the exact
          // staged grant from that real consumer; let its normal load/report
          // path finish the same coordinator request.
          _pageOutputs[id.download.key]?._setExternalPresentationRequested(
            _externalPresentationRequests.contains(id) &&
                _coordinator.externalPresentationPendingFor(id),
          );
          _coordinator.updateExternalPresentationAvailability(
            sessionId,
            id,
            available: true,
          );
        } else {
          _externalPresentationRequests.remove(id);
          _pageOutputs[id.download.key]?._setExternalPresentationRequested(
            false,
          );
          _coordinator.updateExternalPresentationAvailability(
            sessionId,
            id,
            available: false,
          );
        }
        trace.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.readerObservation,
            identityHash: id.key,
            revision: demandRevision,
            payload: <String, Object?>{
              'stage': 'external-presentation-prewarm-failed',
              'owner': 'detached-image-cache',
              'errorType': error.runtimeType.toString(),
              'error': error.toString(),
            },
          ),
        );
      } finally {
        if (identical(_externalPresentationPrewarmTokens[id], token)) {
          _externalPresentationPrewarmTokens.remove(id);
        }
      }
    }());
  }

  void _recordExternalPresentationFirstFrame(
    DecodeId id, {
    required String owner,
    required bool preparedOnly,
    int? demandRevision,
  }) {
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.readerObservation,
        identityHash: id.key,
        revision: demandRevision ?? revision,
        payload: <String, Object?>{
          'stage': 'external-presentation-first-frame',
          'owner': owner,
          'preparedOnly': preparedOnly,
        },
      ),
    );
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
    final prewarmRole = _pagedOutputPrewarmRole(id);
    final prewarmer = _media is PipelineOutputPrewarmer
        ? _media as PipelineOutputPrewarmer
        : null;
    if (prewarmer != null &&
        observation != null &&
        observation.direction != ReadingDirection.vertical &&
        _media.renderer == RendererKind.androidTexture &&
        prewarmRole != null) {
      // The native decoder has already resolved the exact aligned canvas for
      // this page. Start the matching SurfaceProducer prewarm before the
      // upload lane asks for its lease; the old viewport-sized guess cannot be
      // reused for a smaller or differently-shaped source.
      _requestOutputPrewarm(
        prewarmer,
        id: id,
        width: decodedWidth,
        height: decodedHeight,
        direction: observation.direction,
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

  void _publishPageSourceDimensions({
    required DownloadId id,
    required PageAsset asset,
    required int width,
    required int height,
    required String source,
  }) {
    if (_disposed || width <= 0 || height <= 0) return;
    final pageIndex = _pageIndexByPageId[id.content.pageId];
    if (pageIndex == null) return;
    final changed = _pageDimensions.publish(
      PipelinePageDimensions(
        pageIndex: pageIndex,
        assetKey: asset.assetKey,
        width: width,
        height: height,
        basis: PipelinePageDimensionBasis.sourceCanvas,
      ),
    );
    if (!changed) return;
    trace.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.pageDimensionsResolved,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'pageIndex': pageIndex,
          'width': width,
          'height': height,
          'basis': PipelinePageDimensionBasis.sourceCanvas.name,
          'source': source,
        },
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
      final changed =
          _binding?.classifyPage(
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

  void _syncTransferProgressPresentationSatisfaction(
    DownloadId currentDownload,
  ) {
    if (_lastControlCurrentDownload != currentDownload) {
      transferProgress.setPresentationSatisfied(false);
      return;
    }
    final identity = _activeDecodeIdentity(currentDownload);
    final visibleExactIdentity =
        identity != null &&
        _externalPresentationVisibleFrames.contains(identity);
    final retainedStalePresentation =
        _artifactCacheManager?.hasRetainedHistoricalPresentation(
          currentDownload,
        ) ??
        false;
    transferProgress.setPresentationSatisfied(
      visibleExactIdentity || retainedStalePresentation,
    );
  }

  DecodeId? _activePagedOutputIdentity(DownloadId download) {
    final upload = _activeUploadIdentity(download);
    if (upload != null) {
      return upload;
    }
    final decode = _activeDecodeIdentity(download);
    if (decode != null && _pagedOutputPrewarmRole(decode) == PageRole.next) {
      return decode;
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
    _externalPresentationRequests.removeWhere(
      (id) => !_coordinator.externalPresentationPendingFor(id),
    );
    _externalPresentationReady.removeWhere(
      (id) => !_coordinator.externalPresentationSatisfiedFor(id),
    );
    _externalPresentationPrewarmFailures.removeWhere(
      (id) => !_coordinator.decodeDemands.containsKey(id),
    );
    _externalPresentationVisibleFrames.removeWhere(
      (id) => !_coordinator.decodeDemands.containsKey(id),
    );
    // Demand-role changes update only cache residency strength. The cache
    // authority owns whether a raster is reclaimable; Pipeline never polls the
    // Flutter ImageCache to infer this fact.
    _syncExternalPresentationCacheClaims();
    // Keep the Flutter presentation cache identity across ordinary demand
    // gaps. Decode/upload demand is only a scheduling window; it is not a
    // presentation-generation boundary. Retaining this tiny per-DecodeId key
    // lets the managed presentation cache keep/refill the same exact entry
    // instead of manufacturing a new provider generation. Source/presentation
    // recovery and fit changes rotate the identity
    // explicitly at their real generation boundaries; session dispose owns
    // final map retirement.
    for (final entry in _externalPresentationPrewarmTokens.entries.toList(
      growable: false,
    )) {
      if (!_coordinator.decodeDemands.containsKey(entry.key) ||
          !_coordinator.externalPresentationPendingFor(entry.key)) {
        entry.value.cancel();
        _externalPresentationPrewarmTokens.remove(entry.key);
      }
    }
    final emptyOutputs = <String>[];
    for (final entry in _pageOutputs.entries) {
      final output = entry.value;
      final outputIdentity = _activePagedOutputIdentity(output.download);
      output._bind(
        outputIdentity,
        retainedStaticIdentity: outputIdentity == null
            ? _staticPresentationContinuityIdentity(output.download)
            : null,
      );
      output._setExternalPresentationCacheIdentity(
        outputIdentity == null
            ? null
            : _externalPresentationCacheIdentityFor(outputIdentity),
      );
      final externalPending =
          outputIdentity != null &&
          _externalPresentationRequests.contains(outputIdentity) &&
          _coordinator.externalPresentationPendingFor(outputIdentity);
      final preferDetached =
          outputIdentity != null &&
          externalPending &&
          _preferDetachedExternalPresentation(outputIdentity);
      if (outputIdentity != null &&
          externalPending &&
          !preferDetached &&
          output._listeners.isNotEmpty) {
        _externalPresentationPrewarmTokens.remove(outputIdentity)?.cancel();
      }
      output._setExternalPresentationRequested(
        externalPending && output._listeners.isNotEmpty && !preferDetached,
      );
      output._setExternalPresentationReady(
        outputIdentity != null &&
            _externalPresentationReadyForOutput(outputIdentity),
      );
      if (outputIdentity != null && preferDetached) {
        _startExternalPresentationPrewarm(outputIdentity, revision);
      }
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
    final plan = _binding?.pipeline.currentPlan;
    // A prewarm marker is only a short-lived request guard. Once the role
    // plan no longer admits that DecodeId as a page that can enter the
    // gallery, let a later re-entry request a fresh unpresented lease. The
    // native pool still deduplicates an in-flight/idle lease, so this does not
    // allocate duplicate SurfaceProducers while the old request is settling.
    if (_outputPrewarmSizes.isNotEmpty) {
      _outputPrewarmSizes.removeWhere(
        (id, _) => _pagedOutputPrewarmRole(id) == null,
      );
    }
    if (_deferredOutputPrewarms.isNotEmpty) {
      _deferredOutputPrewarms.removeWhere(
        (id, _) => _pagedOutputPrewarmRole(id) == null,
      );
    }
    if (acceptedObservation == null ||
        _media.renderer != RendererKind.androidTexture ||
        plan == null) {
      return;
    }
    // Create the detached projection as soon as the role plan is committed,
    // rather than waiting for the first UploadSnapshot callback. Vertical
    // continuous presentation prebinds only roles that already own real
    // UploadDemand; horizontal gallery additionally keeps its historical
    // decode-only animated-next lease optimization.
    final prewarmIds = <DecodeId>{};
    for (final id in plan.uploads.keys) {
      if (_pagedOutputPrewarmRole(
            id,
            direction: acceptedObservation.direction,
          ) !=
          null) {
        prewarmIds.add(id);
      }
    }
    if (acceptedObservation.direction != ReadingDirection.vertical) {
      for (final entry in plan.decodes.entries) {
        if (entry.value.role == PageRole.next) {
          prewarmIds.add(entry.key);
        }
      }
    }
    for (final id in prewarmIds) {
      _maybePrewarmPagedOutput(id, observation: acceptedObservation);
    }
  }

  void _ensurePlaybackTicker() {
    final ids = _binding?.pipeline.currentPlan.uploads.keys;
    final deadline = ids == null
        ? null
        : _uploads.earliestPlaybackDeadlineMicros(ids);
    if (_uploads.playbackPaused ||
        deadline == null ||
        _disposed ||
        _retainedForReaderReentry) {
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
    if (_disposed || _uploads.playbackPaused || _retainedForReaderReentry) {
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
    final binding = _binding;
    final readerSessionId = _readerSessionId;
    _binding = null;
    _readerSessionId = null;
    binding?.detach(readerSessionId ?? sessionId);
    artifactReadScheduler.refresh();
    for (final token in _externalPresentationPrewarmTokens.values) {
      token.cancel();
    }
    _externalPresentationPrewarmTokens.clear();
    _releasePresentationCacheClaims();
    _presentationCacheAuthority?.removeInvalidationListener(
      _handlePresentationCacheInvalidated,
    );
    _externalPresentationCacheIdentities.clear();
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
