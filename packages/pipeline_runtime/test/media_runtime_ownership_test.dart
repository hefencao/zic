import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  test('factory clones retain the composition-owned artifact cache manager', () {
    final manager = ArtifactCacheManager(backend: _Backend());
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      artifactCacheManager: manager,
    );

    expect(
      identical(
        factory.artifactCacheManager,
        factory.withLoaderSources(factory.loaderSources).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.artifactCacheManager,
        factory.withArtifactCacheManager(manager).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.artifactCacheManager,
        factory.withBytesLoader(null).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.pageDownloadLane,
        factory.withLoaderSources(factory.loaderSources).pageDownloadLane,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.decodePrefixHints,
        factory.withBytesLoader(null).decodePrefixHints,
      ),
      isTrue,
    );
  });

  test('Reader reentry reuses the authoritative resource session', () async {
    final runtime = _Runtime();
    final trace = MemoryTraceSink();
    final base = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    );
    final uri = Uri.parse('content://local/page-0.webp');
    final chapter = _chapter(uri: uri);
    final firstFactory = base.withLoaderSources(
      <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'local-r1',
          loadBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
        ),
      },
    );
    final first = firstFactory.acquire(
      chapter: chapter,
      sessionId: 'retained-reader-1',
      traceSink: trace,
    );
    first.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    first.accept(
      ReaderObs(
        sessionId: 'retained-reader-1',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: chapter.pages.single.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    firstFactory.release(first);
    final retainedEvent = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.readerSessionRetained,
    );
    expect(retainedEvent.payload['decodeSessions'], 0);
    expect(retainedEvent.payload['uploadSessions'], 0);

    final secondFactory = base.withLoaderSources(
      <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'local-r1',
          loadBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
        ),
      },
    );
    final second = secondFactory.acquire(
      chapter: chapter,
      sessionId: 'retained-reader-2',
      traceSink: trace,
    );

    expect(identical(first, second), isTrue);
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.readerSessionCreated,
      ),
      hasLength(1),
    );
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.readerSessionRetained,
      ),
      hasLength(1),
    );
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.readerSessionReused,
      ),
      hasLength(1),
    );

    secondFactory.release(second);
    await base.disposeRetainedSessions();
    expect(runtime.closed, isTrue);
  });

  test(
      'presentation pageStream cannot precreate an exact physical session before verified acquire',
      () async {
    final cache = ArtifactCacheManager(backend: _Backend());
    final net = NetLane(maxActive: 2);
    final transferRuntime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: null,
      net: net,
    );
    final newUri = Uri.parse('https://example.invalid/new.webp');
    final oldUri = Uri.parse('https://example.invalid/old.webp');
    final chapter = _chapter(uri: newUri);
    final newId = readerPageDownloadId(chapter, chapter.pages.single);
    final oldId = DownloadId(
      content: newId.content,
      sourceRevision: 'old-r0',
      canonicalUri: oldUri,
    );
    cache.linkEquivalent(first: oldId, second: newId);

    final physical = transferRuntime.registry.get(oldId);
    await physical.restore();
    final writer = physical.acquireWriter();
    await physical.bindResponse(
      validators: const Validators(),
      totalLength: 128 * 1024,
    );
    await physical.append(writer, 0, List<int>.filled(4096, 1));
    await physical.pause(writer);

    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
    ).withTransferRuntime(transferRuntime).withLoaderSources(
      <Uri, LoaderTransportSource>{
        newUri: LoaderTransportSource(
          revision: 'new-r1',
          loadBytes: () async => Uint8List(128 * 1024),
        ),
      },
    );
    final reader = factory.create(
      chapter: chapter,
      sessionId: 'late-bound-page-stream',
    );

    final stream = reader.pageStream(chapter.pages.single);
    expect(transferRuntime.registry.findExact(newId), isNull,
        reason: 'presentation projection must not acquire physical ownership');
    expect(stream.identity, newId);
    expect(stream.committedLength, 0);

    reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    reader.accept(
      ReaderObs(
        sessionId: 'late-bound-reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: chapter.pages.single.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(transferRuntime.registry.resolvePhysicalId(newId), oldId);
    expect(transferRuntime.registry.find(newId), same(physical));
    expect(transferRuntime.registry.findExact(newId), isNull);
    expect(stream.committedLength, 4096,
        reason: 'logical stream must project the resolved physical partial');
    expect(transferRuntime.registry.sessions, hasLength(1));

    await reader.dispose();
    await transferRuntime.dispose();
  });

  test('shared physical trace sink emits each demand once across Readers', () async {
    final sharedTrace = MemoryTraceSink();
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
    );
    final chapter = _chapter();
    final first = factory.create(
      chapter: chapter,
      sessionId: 'trace-reader-a',
      traceSink: sharedTrace,
    );
    final second = factory.create(
      chapter: chapter,
      sessionId: 'trace-reader-b',
      traceSink: sharedTrace,
    );
    final target = DecodeTarget(physicalWidth: 320, physicalHeight: 480);
    first.attach(target);
    second.attach(target);

    ReaderObs observation(String sessionId) => ReaderObs(
          sessionId: sessionId,
          currentIndex: 0,
          stableIndex: 0,
          interaction: Interaction.idle,
          logicalPosition: 0,
          velocity: 0,
          currentCoverage: Coverage(
            pageIndex: 0,
            assetKey: chapter.pages.single.assetKey,
            fraction: 1,
          ),
          direction: ReadingDirection.ltr,
          timestamp: DateTime.utc(2026),
          monotonicMicros: 1,
        );

    first.accept(observation('trace-reader-a'));
    second.accept(observation('trace-reader-b'));
    await Future<void>.delayed(Duration.zero);

    int physicalDemandCount(String scopeId) => sharedTrace.events.where((event) {
          if (event.kind != TraceEventKind.demandApplied) return false;
          return event.payload['lane'] == 'download' &&
              event.payload['scopeId'] == scopeId;
        }).length;

    expect(physicalDemandCount('reader:trace-reader-a'), 1);
    expect(physicalDemandCount('reader:trace-reader-b'), 1);

    await first.dispose();
    await second.dispose();
    await factory.disposeTransferRuntimes();
  });

  test('current output prewarms the exact aligned decoded raster', () async {
    final runtime = _Runtime();
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _chapter(width: 4096, height: 3072),
      sessionId: 'exact-output-prewarm-test',
    );
    final target = DecodeTarget(
      physicalWidth: 1075,
      physicalHeight: 803,
    );
    session.attach(target);
    final page = session.chapter.pages.single;
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: page.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(
      await runtime.firstPrewarm.future,
      <int>[1056, 792],
    );
    expect(runtime.prewarmCalls, 1);

    await session.dispose();
  });

  test('animated next prewarms output lease without opening upload demand', () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _galleryChapter(pageCount: 4),
      sessionId: 'decode-only-next-output-prewarm-test',
      traceSink: trace,
    );
    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.androidTexture,
      ),
    );
    final current = session.chapter.pages[0];
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: current.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(runtime.prewarmCalls, 2);
    final prewarms = trace.events
        .where((event) => event.kind == TraceEventKind.pageOutputPrewarmed)
        .toList(growable: false);
    expect(prewarms, hasLength(2));
    expect(
      prewarms.map((event) => event.payload['role']),
      containsAll(<String>['current', 'next']),
    );
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.uploadDemand),
      hasLength(1),
      reason: 'next output lease prewarm must not create frame upload work',
    );

    await session.dispose();
  });

  test('current detached prewarm bypasses an already queued Flutter frame', () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(
      renderer: RendererKind.androidTexture,
      scheduler: scheduler,
    );
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _galleryChapter(pageCount: 1),
      sessionId: 'current-prewarm-frame-priority-test',
    );
    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.androidTexture,
      ),
    );
    final page = session.chapter.pages.single;
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: page.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(runtime.prewarmCalls, 1);
    expect(scheduler.pendingCallbackCount, 0);

    await session.dispose();
  });

  test('transition gallery prewarm waits for one idle handoff', () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(
      renderer: RendererKind.androidTexture,
      scheduler: scheduler,
    );
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _galleryChapter(pageCount: 4),
      sessionId: 'deferred-gallery-prewarm-budget-test',
    );

    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.androidTexture,
      ),
    );
    final current = session.chapter.pages[0];
    final transition = session.chapter.pages[2];
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.dragging,
        logicalPosition: 0.5,
        velocity: 1,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: current.assetKey,
          fraction: 0.5,
        ),
        targetCoverage: Coverage(
          pageIndex: 2,
          assetKey: transition.assetKey,
          fraction: 0.5,
        ),
        visibleCoverages: <Coverage>[
          Coverage(
            pageIndex: 0,
            assetKey: current.assetKey,
            fraction: 0.5,
          ),
          Coverage(
            pageIndex: 2,
            assetKey: transition.assetKey,
            fraction: 0.5,
          ),
        ],
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    // Current is the only output allowed to cross the queued-frame boundary
    // immediately. Transition and decode-only next leases queue behind it,
    // with transition winning the first idle slot. Neither creates frame
    // upload work or shares one idle turn with another platform create.
    expect(runtime.prewarmCalls, 1);
    expect(scheduler.pendingCallbackCount, 1);
    expect(
      scheduler.requestedFrames,
      0,
      reason: 'idle prewarm must not request a competing Flutter frame',
    );

    scheduler.flushAfterFrame();
    expect(runtime.prewarmCalls, 2);
    expect(scheduler.pendingCallbackCount, 1);

    scheduler.flushAfterFrame();
    expect(runtime.prewarmCalls, 3);
    expect(scheduler.pendingCallbackCount, 0);

    await session.dispose();
  });

  test('horizontal role window prewarms an unknown page kind', () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _chapter(contentKindHint: ContentKindHint.unknown),
      sessionId: 'unknown-kind-gallery-prewarm-test',
      traceSink: trace,
    );
    final page = session.chapter.pages.single;
    // Simulate PageView creating the host-owned projection before the role
    // plan reaches the Reader session. Prewarm telemetry must still expose
    // the transition even though the stream itself already exists.
    session.pageOutput(page);
    session.attach(
      DecodeTarget(
        physicalWidth: 320,
        physicalHeight: 480,
        renderer: RendererKind.androidTexture,
      ),
    );
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: page.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    final prewarms = trace.events.where(
      (event) => event.kind == TraceEventKind.pageOutputPrewarmed,
    );
    expect(
      prewarms,
      hasLength(1),
      reason: 'role-bounded prewarm must not wait for media classification',
    );
    expect(prewarms.single.payload['created'], isFalse);

    await session.dispose();
  });

  test('known non-WebP pages do not allocate detached native outputs', () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
    ).create(
      chapter: _chapter(
        uri: Uri.parse('asset:///page-0.jpg'),
        contentKindHint: ContentKindHint.jpeg,
      ),
      sessionId: 'non-webp-gallery-prewarm-test',
      traceSink: trace,
    );
    final page = session.chapter.pages.single;
    session.attach(
      DecodeTarget(
        physicalWidth: 320,
        physicalHeight: 480,
        renderer: RendererKind.androidTexture,
      ),
    );
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.idle,
        logicalPosition: 0,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: page.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.pageOutputPrewarmed,
      ),
      isEmpty,
    );

    await session.dispose();
  });

  test('Reader session owns and closes one atomic media runtime', () async {
    final runtime = _Runtime();
    final factory = _Factory(runtime);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: factory,
    ).create(
      chapter: _chapter(),
      sessionId: 'atomic-media-test',
    );

    expect(factory.created, 1);
    expect(session.renderer, RendererKind.flutterImage);

    await session.dispose();

    expect(runtime.closed, isTrue);
  });
}

ChapterManifest _galleryChapter({int pageCount = 3}) {
  final pages = List<PageAsset>.generate(
    pageCount,
    (index) => PageAsset(
      pageId: 'page-$index',
      chapterId: 'chapter',
      index: index,
      uri: Uri.parse('asset:///page-$index.webp'),
      width: 4096,
      height: 3072,
      contentKindHint: ContentKindHint.webp,
    ),
  );
  return ChapterManifest(
    sourceId: 'source',
    comicId: 'comic',
    chapter: Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'chapter',
      sequence: 1,
      pageCount: pageCount,
      sourceRevision: 'r1',
    ),
    pages: pages,
    readingDirection: ReadingDirection.ltr,
  );
}

ChapterManifest _chapter({
  int? width,
  int? height,
  Uri? uri,
  ContentKindHint contentKindHint = ContentKindHint.webp,
}) => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: uri ?? Uri.parse('asset:///page-0.webp'),
          width: width,
          height: height,
          contentKindHint: contentKindHint,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _FreshFactory implements PipelineMediaRuntimeFactory {
  const _FreshFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      _Runtime();
}

final class _Factory implements PipelineMediaRuntimeFactory {
  _Factory(this.runtime);

  final _Runtime runtime;
  int created = 0;

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) {
    created++;
    return runtime;
  }
}

final class _TestFrameScheduler implements PipelineFrameScheduler {
  const _TestFrameScheduler();

  @override
  bool get inPersistentCallbacks => false;

  @override
  bool get isIdle => true;

  @override
  bool get hasScheduledFrame => false;

  @override
  void afterFrame(void Function() callback) => scheduleMicrotask(callback);

  @override
  void scheduleIdle(void Function() callback) => scheduleMicrotask(callback);

  @override
  void requestFrame() {}
}

final class _ControlledFrameScheduler implements PipelineFrameScheduler {
  _ControlledFrameScheduler({this.scheduled = false});

  bool scheduled;
  final List<void Function()> _callbacks = <void Function()>[];

  int requestedFrames = 0;

  int get pendingCallbackCount => _callbacks.length;

  @override
  bool get inPersistentCallbacks => false;

  @override
  bool get isIdle => !scheduled;

  @override
  bool get hasScheduledFrame => scheduled;

  @override
  void afterFrame(void Function() callback) {
    _callbacks.add(callback);
  }

  @override
  void scheduleIdle(void Function() callback) {
    _callbacks.add(callback);
  }

  @override
  void requestFrame() {
    requestedFrames++;
    scheduled = true;
  }

  void flushAfterFrame() {
    scheduled = false;
    final callbacks = _callbacks.toList(growable: false);
    _callbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }
}

final class _Runtime
    implements PipelineMediaRuntime, PipelineOutputPrewarmer {
  _Runtime({
    RendererKind renderer = RendererKind.flutterImage,
    PipelineFrameScheduler? scheduler,
  })  : _renderer = renderer,
        _scheduler = scheduler ?? const _TestFrameScheduler();

  final RendererKind _renderer;
  final PipelineFrameScheduler _scheduler;
  bool closed = false;
  int prewarmCalls = 0;
  final Completer<List<int>> firstPrewarm = Completer<List<int>>();

  @override
  SourceFactory get sources => _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  PipelineFrameScheduler get frameScheduler => _scheduler;

  @override
  RendererKind get renderer => _renderer;

  @override
  Future<void> prewarmOutput({required int width, required int height}) async {
    prewarmCalls++;
    if (!firstPrewarm.isCompleted) {
      firstPrewarm.complete(<int>[width, height]);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _SourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _Source(epoch);
}

final class _Source implements EncodedSource {
  _Source(this.epoch);

  @override
  int epoch;
  @override
  int length = 0;
  @override
  bool sealed = false;
  @override
  SourceKind kind = SourceKind.unknown;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    length += bytes.length;
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    length = 0;
    sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _CursorFactory implements CursorFactory {
  const _CursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      throw UnsupportedError('not used');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) =>
      throw UnsupportedError('not used');

  @override
  void release(DecodeId id) {}
}

final class _Projector implements PipelineOutputProjector {
  const _Projector();

  @override
  PipelinePageSurface project(OutputFrame frame) => const _Surface();
}

final class _Surface implements PipelinePageSurface {
  const _Surface();

  @override
  int get width => 1;

  @override
  int get height => 1;

  @override
  Object get presentationIdentity => this;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      SizedBox(key: key, width: 1, height: 1);
}

final class _Backend implements ArtifactCacheBackend {
  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      null;


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}
