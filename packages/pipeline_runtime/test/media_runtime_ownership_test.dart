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
  testWidgets(
      'Reader session host rejects page carrier mutation without key replacement',
      (tester) async {
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
    );
    const hostKey = ValueKey<String>('reader-host');

    Widget host(ChapterManifest chapter) => Directionality(
          textDirection: TextDirection.ltr,
          child: PipelineReaderSessionHost(
            key: hostKey,
            chapter: chapter,
            factory: factory,
            builder: (_, _) => const SizedBox(),
          ),
        );

    await tester.pumpWidget(
      host(_chapter(uri: Uri.parse('https://old.example/page.webp'))),
    );
    await tester.pumpWidget(
      host(_chapter(uri: Uri.parse('https://new.example/page.webp'))),
    );

    expect(
      tester.takeException(),
      isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('chapter identity is immutable'),
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await factory.disposeRetainedSessions();
    },
  );

  test(
    'factory clones retain composition-owned cache and presentation executor',
    () {
    final manager = ArtifactCacheManager(backend: _Backend());
      Future<void> prewarmer(
        PipelineExternalPresentationWarmRequest request,
      ) async {}
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      artifactCacheManager: manager,
      externalPresentationPrewarmer: prewarmer,
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
    expect(
      identical(
        factory.externalPresentationPrewarmer,
          factory
              .withLoaderSources(factory.loaderSources)
            .externalPresentationPrewarmer,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.externalPresentationPrewarmer,
        factory.withTransferRuntime(null).externalPresentationPrewarmer,
      ),
      isTrue,
    );
    },
  );

  test(
    'Reader current does not pre-arm composition local-read pressure',
    () async {
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      artifactCacheManager: ArtifactCacheManager(backend: _Backend()),
      artifactReadScheduler: scheduler,
    ).create(
      chapter: _chapter(),
      sessionId: 'no-presentation-pressure-coupling-test',
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

    session.accept(_currentObservation(session.chapter));

    expect(
      scheduler.foregroundPressure,
      isFalse,
        reason:
            'current/output lifecycle must not manufacture local-read pressure; '
          'only an actual foreground read may do so',
    );
    },
  );

  test(
    'local source bucket remains the stable profile limit before first output',
      () async {
    final trace = MemoryTraceSink();
    final uri = Uri.parse('asset:///local-startup.webp');
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'local-startup-r1',
          loadBytes: () async => Uint8List.fromList(<int>[
                  0x52,
                  0x49,
                  0x46,
                  0x46,
                  0x04,
                  0x00,
                  0x00,
                  0x00,
                  0x57,
                  0x45,
                  0x42,
                  0x50,
          ]),
        ),
      },
    ).create(
      chapter: _chapter(uri: uri),
      sessionId: 'stable-local-bucket-test',
      traceSink: trace,
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(_currentObservation(session.chapter));

    TraceEvent? started;
    for (var attempt = 0; attempt < 100 && started == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      for (final event in trace.events) {
        if (event.kind == TraceEventKind.downloadStarted) {
          started = event;
          break;
        }
      }
    }
    expect(started, isNotNull);
    expect(
      started!.payload['bucketLimit'],
      ReaderPipelineProfile.stable.localSourceConcurrency,
        reason:
            'presentation readiness must not rewrite NetLane source capacity',
      );
    },
    );

  test('Reader reentry reuses the authoritative resource session', () async {
    final runtime = _Runtime();
    final trace = MemoryTraceSink();
    final base = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    );
    final uri = Uri.parse('content://local/page-0.webp');
    final chapter = _chapter(uri: uri);
    final firstFactory = base.withLoaderSources(<Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'local-r1',
          loadBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
        ),
    });
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
    expect(retainedEvent.payload['ingressProjections'], 0);
    expect(retainedEvent.payload['streamingSources'], 0);

    final secondFactory = base.withLoaderSources(<Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'local-r1',
          loadBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
        ),
    });
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

  test('Reader retention waits for an admitted decode before retiring media',
      () async {
    final sources = _RetainedDecodeSourceFactory();
    final cursors = _RetainedDecodeCursorFactory();
    final runtime = _Runtime(sources: sources, cursors: cursors);
    final trace = MemoryTraceSink();
    final uri = Uri.parse('asset:///retained-active-decode.webp');
    final chapter = _chapter(uri: uri);
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).withLoaderSources(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'retained-active-r1',
        loadBytes: () async =>
            Uint8List.fromList('RIFF....WEBPpayload'.codeUnits),
      ),
    });
    addTearDown(() async {
      if (!cursors.cursor.finish.isCompleted) cursors.cursor.finish.complete();
      await factory.disposeRetainedSessions();
      await factory.disposeTransferRuntimes();
    });
    final session = factory.acquire(
      chapter: chapter,
      sessionId: 'retained-active-decode',
      traceSink: trace,
    );
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(ReaderObs(
      sessionId: 'retained-active-decode',
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
    ));
    await cursors.cursor.started.future;

    factory.release(session);
    expect(cursors.cursor.disposed, isFalse,
        reason: 'cancel does not retire a cursor still executing native work');
    expect(sources.created.last.disposed, isFalse);
    cursors.cursor.finish.complete();
    await cursors.cursor.retired.future.timeout(const Duration(seconds: 2));
    expect(cursors.cursor.disposed, isTrue);
    expect(sources.created.last.disposed, isTrue);
    expect(trace.events.where((event) =>
        event.kind == TraceEventKind.taskFailed), isEmpty);
  });

  test(
    'retained-session drain releases idle consumers but not active Readers',
      () async {
    final cache = ArtifactCacheManager(backend: _Backend());
    final net = NetLane(maxActive: 2);
    final transferRuntime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: null,
      net: net,
    );
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: net,
    ).withTransferRuntime(transferRuntime);
    final reader = factory.acquire(
      chapter: _chapter(),
      sessionId: 'exclusive-storage-reader',
    );

    expect(transferRuntime.hasConsumers, isTrue);
    await factory.disposeRetainedSessions();
    expect(
      transferRuntime.hasConsumers,
      isTrue,
      reason: 'an actively leased Reader must survive idle-retention drain',
    );

    factory.release(reader);
    expect(transferRuntime.hasConsumers, isTrue);
    await factory.disposeRetainedSessions();
    expect(
      transferRuntime.hasConsumers,
      isFalse,
      reason: 'an idle retained Reader must not block exclusive storage work',
    );

    await transferRuntime.dispose();
    },
  );

  test('changed page carrier cannot reuse a retained Reader session', () async {
    final base = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
    );
    final oldUri = Uri.parse('https://old.example/page.webp');
    final newUri = Uri.parse('https://new.example/page.webp');
    final firstFactory = base.withLoaderSources(<Uri, LoaderTransportSource>{
        oldUri: LoaderTransportSource(
          revision: 'r1:0',
          loadBytes: () async => Uint8List(0),
        ),
    });
    final first = firstFactory.acquire(
      chapter: _chapter(uri: oldUri),
      sessionId: 'old-carrier',
    );
    firstFactory.release(first);

    final secondFactory = base.withLoaderSources(<Uri, LoaderTransportSource>{
        newUri: LoaderTransportSource(
          revision: 'r1:0',
          loadBytes: () async => Uint8List(0),
        ),
    });
    final second = secondFactory.acquire(
      chapter: _chapter(uri: newUri),
      sessionId: 'new-carrier',
    );

    expect(second, isNot(same(first)));
    expect(second.chapter.pages.single.uri, newUri);

    secondFactory.release(second);
    await base.disposeRetainedSessions();
  });

  test(
    'changed page metadata cannot reuse a retained Reader session',
    () async {
    final uri = Uri.parse('https://stable.example/page.webp');
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'r1:0',
          loadBytes: () async => Uint8List(0),
        ),
      },
    );
    final first = factory.acquire(
      chapter: _chapter(uri: uri, byteLength: 100),
      sessionId: 'old-metadata',
    );
    factory.release(first);

    final second = factory.acquire(
      chapter: _chapter(uri: uri, byteLength: 200),
      sessionId: 'new-metadata',
    );

    expect(second, isNot(same(first)));
    expect(second.chapter.pages.single.byteLength, 200);

    factory.release(second);
    await factory.disposeRetainedSessions();
    },
  );

  test(
    'retention keeps the two most recent media-empty Reader sessions',
    () async {
    final base = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
    );
    final chapterA = _chapterIdentity(
      comicId: 'comic-a',
      chapterId: 'chapter-a',
      uri: Uri.parse('asset:///a.webp'),
    );
    final chapterB = _chapterIdentity(
      comicId: 'comic-b',
      chapterId: 'chapter-b',
      uri: Uri.parse('asset:///b.webp'),
    );

    final firstA = base.acquire(
      chapter: chapterA,
      sessionId: 'retention-a-1',
    );
    base.release(firstA);
    final firstB = base.acquire(
      chapter: chapterB,
      sessionId: 'retention-b-1',
    );
    base.release(firstB);

    final secondA = base.acquire(
      chapter: chapterA,
      sessionId: 'retention-a-2',
    );
    expect(secondA, same(firstA));
    base.release(secondA);
    final secondB = base.acquire(
      chapter: chapterB,
      sessionId: 'retention-b-2',
    );
    expect(secondB, same(firstB));
    base.release(secondB);

    await base.disposeRetainedSessions();
    },
  );

  test('a third retained Reader evicts only the oldest idle session', () async {
    final base = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
    );
    ChapterManifest chapter(String suffix) => _chapterIdentity(
          comicId: 'comic-$suffix',
          chapterId: 'chapter-$suffix',
          uri: Uri.parse('asset:///$suffix.webp'),
        );
    final a = base.acquire(chapter: chapter('a'), sessionId: 'lru-a-1');
    base.release(a);
    final b = base.acquire(chapter: chapter('b'), sessionId: 'lru-b-1');
    base.release(b);
    final c = base.acquire(chapter: chapter('c'), sessionId: 'lru-c-1');
    base.release(c);

    final bAgain = base.acquire(chapter: chapter('b'), sessionId: 'lru-b-2');
    expect(bAgain, same(b));
    base.release(bAgain);
    final aAgain = base.acquire(chapter: chapter('a'), sessionId: 'lru-a-2');
    expect(aAgain, isNot(same(a)));
    base.release(aAgain);

    await base.disposeRetainedSessions();
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

      final factory =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
              )
              .withTransferRuntime(transferRuntime)
              .withLoaderSources(<Uri, LoaderTransportSource>{
        newUri: LoaderTransportSource(
          revision: 'new-r1',
          loadBytes: () async => Uint8List(128 * 1024),
        ),
              });
    final reader = factory.create(
      chapter: chapter,
      sessionId: 'late-bound-page-stream',
    );

    final stream = reader.pageStream(chapter.pages.single);
      expect(
        transferRuntime.registry.findExact(newId),
        isNull,
        reason: 'presentation projection must not acquire physical ownership',
      );
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
      expect(
        stream.committedLength,
        4096,
        reason: 'logical stream must project the resolved physical partial',
      );
    expect(transferRuntime.registry.sessions, hasLength(1));

    await reader.dispose();
    await transferRuntime.dispose();
    },
  );

  test(
    'shared physical trace sink emits each demand once across Readers',
    () async {
    final sharedTrace = MemoryTraceSink();
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: const _FreshFactory(),
      pageDownloadLane: NetLane(maxActive: 5),
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

      int physicalDemandCount(String scopeId) =>
          sharedTrace.events.where((event) {
          if (event.kind != TraceEventKind.demandApplied) return false;
          return event.payload['lane'] == 'download' &&
              event.payload['scopeId'] == scopeId;
        }).length;

    expect(physicalDemandCount('reader:trace-reader-a'), 1);
    expect(physicalDemandCount('reader:trace-reader-b'), 1);

    await first.dispose();
    await second.dispose();
    await factory.disposeTransferRuntimes();
    },
  );

  test('current output prewarms the exact aligned decoded raster', () async {
    final runtime = _Runtime();
    final session =
        PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(
      chapter: _chapter(width: 4096, height: 3072),
      sessionId: 'exact-output-prewarm-test',
    );
    final target = DecodeTarget(physicalWidth: 1075, physicalHeight: 803);
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

    expect(await runtime.firstPrewarm.future, <int>[1056, 792]);
    expect(runtime.prewarmCalls, 1);

    await session.dispose();
  });

  test('vertical native current prebinds detached output before host mount', () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(
      chapter: _galleryChapter(pageCount: 3),
      sessionId: 'vertical-detached-output-prebind-test',
      traceSink: trace,
    );
    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.androidTexture,
      ),
      externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
    );
    final current = session.chapter.pages[0];
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.scrolling,
        logicalPosition: 0,
        velocity: 1,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: current.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    final prewarms = trace.events
        .where((event) => event.kind == TraceEventKind.pageOutputPrewarmed)
        .toList(growable: false);
    expect(prewarms, isNotEmpty);
    expect(prewarms.first.payload['pageIndex'], 0);
    expect(prewarms.first.payload['role'], 'current');
    expect(prewarms.first.payload['created'], isTrue);
    expect(runtime.prewarmCalls, 1);

    await session.dispose();
  });

  test('vertical visible transition prewarms with current before idle', () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(
      renderer: RendererKind.androidTexture,
      scheduler: scheduler,
    );
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(
      chapter: _galleryChapter(pageCount: 3),
      sessionId: 'vertical-visible-transition-prewarm-test',
    );
    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.androidTexture,
      ),
    );
    final current = session.chapter.pages[0];
    final adjacent = session.chapter.pages[1];
    session.accept(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.scrubbing,
        logicalPosition: 0.5,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: current.assetKey,
          fraction: 0.5,
        ),
        targetCoverage: Coverage(
          pageIndex: 1,
          assetKey: adjacent.assetKey,
          fraction: 0.5,
        ),
        visibleCoverages: <Coverage>[
          Coverage(pageIndex: 0, assetKey: current.assetKey, fraction: 0.5),
          Coverage(pageIndex: 1, assetKey: adjacent.assetKey, fraction: 0.5),
        ],
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(
      runtime.prewarmCalls,
      2,
      reason:
          'both physically visible vertical pages share the first-frame deadline; '
          'only hidden output prewarm may wait for the idle handoff',
    );

    await session.dispose();
  });

  test('animated paged next prewarms output without idle upload', () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
    final session =
        PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(
      chapter: _galleryChapter(pageCount: 4),
      sessionId: 'paged-next-first-frame-preupload-test',
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
    final initialUploadDemands = trace.events
        .where((event) => event.kind == TraceEventKind.uploadDemand)
        .toList(growable: false);
    expect(initialUploadDemands, hasLength(1));
    expect(initialUploadDemands.single.payload['priority'], 1000);
    expect(
      initialUploadDemands.any((event) => event.payload['priority'] == 820),
      isFalse,
      reason: 'idle paged next must stay decode-only',
    );

    final next = session.chapter.pages[1];
    final nextOutput = session.pageOutput(next);
    expect(nextOutput.snapshot.state, PipelinePageOutputState.preparing);
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
        monotonicMicros: 2,
      ),
    );
    final repeatedPrewarms = trace.events
        .where((event) => event.kind == TraceEventKind.pageOutputPrewarmed)
        .toList(growable: false);
    expect(repeatedPrewarms, hasLength(2));
    expect(runtime.prewarmCalls, 2);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.uploadDemand),
      hasLength(1),
      reason: 'an unchanged idle plan must not create paged-next upload demand',
    );

    await session.dispose();
  });

  test(
    'current detached prewarm bypasses an already queued Flutter frame',
    () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(
      renderer: RendererKind.androidTexture,
      scheduler: scheduler,
    );
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
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
    },
  );

  test('Reader observation reconcile yields to an already queued frame',
      () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(scheduler: scheduler);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(
      chapter: _galleryChapter(pageCount: 2),
      sessionId: 'observation-after-frame-test',
    );
    session.attach(
      DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
        renderer: RendererKind.flutterImage,
      ),
    );
    final page = session.chapter.pages.first;

    session.enqueueObservation(
      ReaderObs(
        sessionId: 'reader',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.scrolling,
        logicalPosition: 0,
        velocity: 1200,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: page.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );

    expect(session.revision, 0);
    expect(scheduler.pendingCallbackCount, 1);

    scheduler.flushAfterFrame();
    expect(session.revision, greaterThan(0));

    await session.dispose();
  });

  test('transition gallery prewarm waits for one idle handoff', () async {
    final scheduler = _ControlledFrameScheduler(scheduled: true);
    final runtime = _Runtime(
      renderer: RendererKind.androidTexture,
      scheduler: scheduler,
    );
    final session =
        PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
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
          Coverage(pageIndex: 0, assetKey: current.assetKey, fraction: 0.5),
          Coverage(pageIndex: 2, assetKey: transition.assetKey, fraction: 0.5),
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
    final session =
        PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
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

  test('exact fallback image prefix becomes runtime static evidence', () async {
    final trace = MemoryTraceSink();
    final uri = Uri.parse('asset:///opaque-static-page');
    final session =
        PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'opaque-static-r1',
          loadBytes: () async => Uint8List.fromList(const <int>[
                0x89,
                0x50,
                0x4e,
                0x47,
                0x0d,
                0x0a,
                0x1a,
                0x0a,
                0x00,
                0x00,
                0x00,
                0x0d,
                0x49,
                0x48,
                0x44,
                0x52,
                0x00,
                0x00,
                0x02,
                0xd0,
                0x00,
                0x00,
                0x02,
                0xbc,
          ]),
        ),
      },
    ).create(
          chapter: _chapter(uri: uri, contentKindHint: ContentKindHint.unknown),
      sessionId: 'fallback-static-classification-test',
      traceSink: trace,
    );
    addTearDown(session.dispose);
    final dimensions = <PipelinePageDimensions>[];
    session.pageDimensions.addListener(dimensions.add);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(_currentObservation(session.chapter));

    TraceEvent? classified;
    for (
      var attempt = 0;
        attempt < 100 && (classified == null || dimensions.isEmpty);
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      for (final event in trace.events) {
        if (event.kind == TraceEventKind.mediaClassified &&
            event.payload['pageIndex'] == 0 &&
            event.payload['animated'] == false &&
            event.payload['basis'] == 'encoded-prefix') {
          classified = event;
          break;
        }
      }
    }

    expect(
      classified,
      isNotNull,
      reason:
          'an exact JPEG/PNG/etc prefix classified as fallback must become Pipeline static evidence instead of waiting until transition',
    );
    expect(dimensions, isNotEmpty);
    expect(dimensions.last.width, 720);
    expect(dimensions.last.height, 700);
    expect(dimensions.last.basis, PipelinePageDimensionBasis.sourceCanvas);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.pageDimensionsResolved &&
            event.payload['source'] == 'physical-ingress-source-canvas',
      ),
      isNotEmpty,
      reason:
          'generation-local encoded metadata must reach Reader geometry before presentation-file or page-host work',
    );
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.policyDecision &&
            event.payload['runtimeStaticPages'] == 1 &&
            event.payload['runtimeExternalStaticPages'] == 1,
      ),
      isNotEmpty,
    );
  });

  test(
    'slider release presents downloaded static neighbor without another observation',
    () async {
    final currentBytes = Completer<Uint8List>();
    final nextBytes = Completer<Uint8List>();
    final pages = List<PageAsset>.generate(
      2,
      (index) => PageAsset(
        pageId: 'static-$index',
        chapterId: 'chapter',
        index: index,
        uri: Uri.parse('https://example.test/opaque-static-$index'),
        width: 1080,
        height: 3600,
        contentKindHint: ContentKindHint.jpeg,
      ),
    );
    final trace = MemoryTraceSink();
    final warmed = <PageAsset>[];
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      loaderSources: <Uri, LoaderTransportSource>{
        for (final page in pages)
          page.uri: LoaderTransportSource(
            revision: 'r1',
            loadBytes: () => page.index == 0 ? currentBytes.future : nextBytes.future,
          ),
      },
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request.asset);
      },
    ).create(
      chapter: ChapterManifest(
        sourceId: 'source',
        comicId: 'comic',
        chapter: Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'chapter',
          sequence: 1,
          pageCount: 2,
          sourceRevision: 'r1',
        ),
        pages: pages,
        readingDirection: ReadingDirection.vertical,
      ),
      sessionId: 'slider-static-source-wait-test',
      traceSink: trace,
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    ReaderObs observation(Interaction interaction) => ReaderObs(
          sessionId: 'reader',
          currentIndex: 0,
          stableIndex: 0,
          interaction: interaction,
          logicalPosition: 0.5,
          velocity: 0,
          currentCoverage: Coverage(pageIndex: 0, assetKey: pages[0].assetKey, fraction: 1),
          direction: ReadingDirection.vertical,
          timestamp: DateTime.utc(2026),
          monotonicMicros: interaction == Interaction.scrubbing ? 1 : 2,
        );
    session.accept(observation(Interaction.scrubbing));
    session.accept(observation(Interaction.idle));
    final jpeg = Uint8List.fromList(
      const <int>[0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1],
    );
    nextBytes.complete(jpeg);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('downloaded static page never received its existing first-frame grant after slider release');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(warmed.single.pageId, 'static-1');
    expect(session.pageOutput(pages[1]).externalPresentationReady, isTrue);
    expect(currentBytes.isCompleted, isFalse);
    currentBytes.complete(jpeg);
  });

  test(
    'external static prewarmer satisfies first frame without a page host',
      () async {
    final trace = MemoryTraceSink();
    final uri = Uri.parse('asset:///opaque-detached-static-page');
    final warmed = <PipelineExternalPresentationWarmRequest>[];
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request);
      },
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'opaque-detached-static-r1',
          loadBytes: () async => Uint8List.fromList(const <int>[
                  0xff,
                  0xd8,
                  0xff,
                  0xe0,
                  0x00,
                  0x10,
                  0x4a,
                  0x46,
                  0x49,
                  0x46,
                  0x00,
                  0x01,
          ]),
        ),
      },
    ).create(
      chapter: _chapter(
        uri: uri,
        contentKindHint: ContentKindHint.unknown,
      ),
      sessionId: 'fallback-detached-prewarm-test',
      traceSink: trace,
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(_currentObservation(session.chapter));

    TraceEvent? prepared;
    for (var attempt = 0; attempt < 200 && prepared == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      for (final event in trace.events) {
        if (event.kind == TraceEventKind.readerObservation &&
            event.payload['stage'] == 'external-presentation-first-frame' &&
            event.payload['owner'] == 'detached-image-cache') {
          prepared = event;
          break;
        }
      }
    }

    expect(warmed, hasLength(1));
    expect(prepared, isNotNull);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.readerObservation &&
            event.payload['stage'] == 'external-presentation-requested' &&
            event.payload['consumer'] == 'detached-image-cache',
      ),
      isNotEmpty,
      reason:
          'the staged coordinator grant must be consumable before any Reader page widget mounts',
    );

    final output = session.pageOutput(session.chapter.pages.single);
    expect(output.externalPresentationRequested, isFalse);
    expect(
      output.externalPresentationReady,
      isTrue,
      reason:
          'a later page host must observe the already-prepared presentation cache state',
    );
    expect(warmed.single.fit, PipelineExternalPresentationFit.contain);
    final firstCacheIdentity = warmed.single.cacheIdentity;

    session.updateExternalPresentationFit(
      PipelineExternalPresentationFit.fitWidth,
    );
    final fitDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.length < 2) {
      if (DateTime.now().isAfter(fitDeadline)) {
        fail('presentation-fit change never re-granted detached warm');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(warmed.last.fit, PipelineExternalPresentationFit.fitWidth);
    expect(
      identical(firstCacheIdentity, warmed.last.cacheIdentity),
      isFalse,
      reason:
          'presentation geometry is part of the Flutter raster generation even when DecodeId/source identity is unchanged',
    );
    },
  );

  test(
    'external static cache identity survives an ordinary demand gap',
      () async {
    final pages = List<PageAsset>.generate(
      12,
      (index) => PageAsset(
        pageId: 'static-$index',
        chapterId: 'chapter',
        index: index,
        uri: Uri.parse('asset:///static-$index.jpg'),
        width: 1080,
        height: 3600,
        contentKindHint: ContentKindHint.jpeg,
      ),
    );
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 12,
        sourceRevision: 'r1',
      ),
      pages: pages,
      readingDirection: ReadingDirection.vertical,
    );
    final warmed = <PipelineExternalPresentationWarmRequest>[];
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request);
      },
      loaderSources: <Uri, LoaderTransportSource>{
        for (final page in pages)
          page.uri: LoaderTransportSource(
            revision: 'static-demand-gap-r1',
            loadBytes: () async => Uint8List.fromList(const <int>[
                0xff,
                0xd8,
                0xff,
                0xe0,
                0x00,
                0x10,
                0x4a,
                0x46,
                0x49,
                0x46,
                0x00,
                0x01,
            ]),
          ),
      },
      ).create(chapter: chapter, sessionId: 'external-static-demand-gap-test');
    addTearDown(session.dispose);
    session.attach(
      DecodeTarget(physicalWidth: 1080, physicalHeight: 2336),
      externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
    );

    ReaderObs observationAt(int index, int micros) => ReaderObs(
          sessionId: 'reader',
          currentIndex: index,
          stableIndex: index,
          interaction: Interaction.idle,
          logicalPosition: index.toDouble(),
          velocity: 0,
          currentCoverage: Coverage(
            pageIndex: index,
            assetKey: pages[index].assetKey,
            fraction: 1,
          ),
          direction: ReadingDirection.vertical,
          timestamp: DateTime.utc(2026),
          monotonicMicros: micros,
        );

    session.accept(observationAt(0, 1));
    final firstDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.where((request) => request.asset.index == 0).isEmpty) {
      if (DateTime.now().isAfter(firstDeadline)) {
        fail('initial page never reached detached presentation warm');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final first = warmed.firstWhere((request) => request.asset.index == 0);

    // Moving farther than the encoded/continuity window removes page 0's
    // DecodeDemand. That is a scheduling gap only, not a new source or
    // presentation generation.
    session.accept(observationAt(10, 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    session.accept(observationAt(0, 3));

    final secondDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.where((request) => request.asset.index == 0).length < 2) {
      if (DateTime.now().isAfter(secondDeadline)) {
        fail('returning page never revalidated detached presentation warm');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
      final pageZeroWarms = warmed
          .where((request) => request.asset.index == 0)
          .toList();
    expect(pageZeroWarms, hasLength(2));
    expect(
      identical(first.cacheIdentity, pageZeroWarms.last.cacheIdentity),
      isTrue,
      reason:
          'ordinary demand-window churn must revalidate the same Flutter ImageCache generation instead of forcing a second raster key',
    );
    },
  );

  test(
    'raster eviction actively invalidates far warm before deadline promotion',
    () async {
      final pages = List<PageAsset>.generate(
        12,
        (index) => PageAsset(
          pageId: 'managed-static-$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('asset:///managed-static-$index.jpg'),
          width: 1080,
          height: 3600,
          contentKindHint: ContentKindHint.jpeg,
        ),
      );
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'comic',
        chapter: const Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'chapter',
          sequence: 1,
          pageCount: 12,
          sourceRevision: 'r1',
        ),
        pages: pages,
        readingDirection: ReadingDirection.vertical,
      );
      final trace = MemoryTraceSink();
      final warmed = <PipelineExternalPresentationWarmRequest>[];
      final cacheAuthority = _FakePresentationCacheAuthority();
      final session =
          PipelineReaderSessionFactory(
            mediaRuntimeFactory: _Factory(_Runtime()),
            pageDownloadLane: NetLane(maxActive: 5),
            externalPresentationPrewarmer: (request) async {
              request.token.throwIfCancelled();
              warmed.add(request);
            },
            presentationCacheAuthority: cacheAuthority,
            loaderSources: <Uri, LoaderTransportSource>{
              for (final page in pages)
                page.uri: LoaderTransportSource(
                  revision: 'managed-static-r1',
                  loadBytes: () async => Uint8List.fromList(const <int>[
                    0xff,
                    0xd8,
                    0xff,
                    0xe0,
                    0x00,
                    0x10,
                    0x4a,
                    0x46,
                    0x49,
                    0x46,
                    0x00,
                    0x01,
                  ]),
                ),
            },
          ).create(
            chapter: chapter,
            sessionId: 'managed-raster-eviction-test',
            traceSink: trace,
          );
      addTearDown(session.dispose);
      session.attach(
        DecodeTarget(physicalWidth: 1080, physicalHeight: 2336),
        externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
      );

      ReaderObs observationAt(int index, int micros) => ReaderObs(
        sessionId: 'reader',
        currentIndex: index,
        stableIndex: index,
        interaction: Interaction.idle,
        logicalPosition: index.toDouble(),
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: index,
          assetKey: pages[index].assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026),
        monotonicMicros: micros,
      );

      session.accept(observationAt(0, 1));
      final firstDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (warmed.where((request) => request.asset.index == 6).isEmpty ||
          warmed.where((request) => request.asset.index == 7).isEmpty) {
        if (DateTime.now().isAfter(firstDeadline)) {
          fail('outer far pages never reached managed presentation warm');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final first = warmed.firstWhere((request) => request.asset.index == 7);
      expect(
        cacheAuthority.claims[first.cacheIdentity],
        PipelinePresentationCacheClaim.speculative,
        reason: 'the outer far warm must be reclaimable cache slack',
      );

      final mountedFar = session.pageOutput(pages[7]);
      final otherMountedFar = session.pageOutput(pages[6]);
      void farListener(PipelinePageOutputSnapshot _) {}
      mountedFar.addListener(farListener);
      otherMountedFar.addListener(farListener);
      addTearDown(() {
        mountedFar.removeListener(farListener);
        otherMountedFar.removeListener(farListener);
      });
      cacheAuthority.evictForBudget(first.cacheIdentity);
      cacheAuthority.evictForBudget(
        warmed.firstWhere((request) => request.asset.index == 6).cacheIdentity,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mountedFar.externalPresentationRequested, isFalse,
          reason: 'a mounted offscreen host cannot bypass cache admission denial');
      expect(otherMountedFar.externalPresentationRequested, isFalse);
      expect(
        warmed.where((request) => request.asset.index == 7),
        hasLength(1),
        reason:
            'active far eviction must revoke residency without immediately recreating the same far raster',
      );
      expect(
        trace.events.any(
          (event) =>
              event.kind == TraceEventKind.policyDecision &&
              event.payload['stage'] ==
                  'presentation-raster-cache-invalidated' &&
              event.payload['role'] == 'far' &&
              event.payload['presentationWarmAllowed'] == false,
        ),
        isTrue,
      );

      session.accept(observationAt(5, 2));
      final secondDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (warmed.where((request) => request.asset.index == 7).length < 2) {
        if (DateTime.now().isAfter(secondDeadline)) {
          fail('near-deadline role did not refill actively-invalidated raster');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final pageSeven = warmed
          .where((request) => request.asset.index == 7)
          .toList();
      expect(pageSeven, hasLength(2));
      expect(
        identical(first.cacheIdentity, pageSeven.last.cacheIdentity),
        isTrue,
        reason:
            'raster eviction changes residency, not presentation generation; deadline refill must reuse the exact source/fit key',
      );
      expect(
        cacheAuthority.claims[first.cacheIdentity],
        PipelinePresentationCacheClaim.deadline,
        reason:
            'role promotion must proactively upgrade the managed residency claim instead of polling Flutter ImageCache',
      );
    },
  );

  test(
    'retained Reader reentry keeps external static cache generation',
      () async {
    final uri = Uri.parse('asset:///retained-external-static.jpg');
    final warmed = <PipelineExternalPresentationWarmRequest>[];
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request);
      },
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'retained-static-r1',
          loadBytes: () async => Uint8List.fromList(const <int>[
                  0xff,
                  0xd8,
                  0xff,
                  0xe0,
                  0x00,
                  0x10,
                  0x4a,
                  0x46,
                  0x49,
                  0x46,
                  0x00,
                  0x01,
          ]),
        ),
      },
    ).create(
            chapter: _chapter(uri: uri, contentKindHint: ContentKindHint.jpeg),
      sessionId: 'retained-external-static-test',
    );
    addTearDown(session.dispose);
    final target = DecodeTarget(physicalWidth: 1080, physicalHeight: 2336);
    session.attach(
      target,
      externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
    );
    session.accept(_currentObservation(session.chapter));

    final firstDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.isEmpty) {
      if (DateTime.now().isAfter(firstDeadline)) {
        fail('initial external-static warm did not complete');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final firstIdentity = warmed.single.cacheIdentity;

    session.retainReaderSession();
    session.resumeRetainedReaderSession(retainedMicros: 1000);
    session.attach(
      target,
      externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
    );
    session.accept(_currentObservation(session.chapter));

    final secondDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.length < 2) {
      if (DateTime.now().isAfter(secondDeadline)) {
          fail(
            'retained Reader reentry did not revalidate external static warm',
          );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      identical(firstIdentity, warmed[1].cacheIdentity),
      isTrue,
      reason:
          'route retention must not manufacture a new Flutter ImageCache generation when source, raster target and fit are unchanged',
    );

    session.retainReaderSession();
    session.resumeRetainedReaderSession(retainedMicros: 1000);
    session.attach(
      target,
      externalPresentationFit: PipelineExternalPresentationFit.contain,
    );
    session.accept(_currentObservation(session.chapter));
    final fitDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (warmed.length < 3) {
      if (DateTime.now().isAfter(fitDeadline)) {
        fail('fit-changed Reader reentry did not warm external static');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      identical(warmed[1].cacheIdentity, warmed[2].cacheIdentity),
      isFalse,
        reason:
            'a real presentation-fit change must rotate the cache generation',
      );
    },
    );

  test(
    'offscreen mounted static host still uses detached presentation warm',
      () async {
    final firstUri = Uri.parse('asset:///mounted-static-current');
    final secondUri = Uri.parse('asset:///mounted-static-next');
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 2,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: firstUri,
          contentKindHint: ContentKindHint.unknown,
        ),
        PageAsset(
          pageId: 'page-1',
          chapterId: 'chapter',
          index: 1,
          uri: secondUri,
          contentKindHint: ContentKindHint.unknown,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final warmed = <int>[];
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request.asset.index);
      },
      loaderSources: <Uri, LoaderTransportSource>{
        for (final uri in <Uri>[firstUri, secondUri])
          uri: LoaderTransportSource(
            revision: 'mounted-static-r1',
            loadBytes: () async => Uint8List.fromList(const <int>[
                0xff,
                0xd8,
                0xff,
                0xe0,
                0x00,
                0x10,
                0x4a,
                0x46,
                0x49,
                0x46,
                0x00,
                0x01,
            ]),
          ),
      },
      ).create(chapter: chapter, sessionId: 'mounted-offscreen-static-test');
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

    final output = session.pageOutput(chapter.pages[1]);
    void listener(PipelinePageOutputSnapshot _) {}
    output.addListener(listener);
    addTearDown(() => output.removeListener(listener));
    session.accept(_currentObservation(chapter));

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!warmed.contains(1)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('offscreen next static page never reached detached prewarm');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      output.externalPresentationRequested,
      isFalse,
      reason:
          'an offscreen retained page host must not become the speculative presentation executor',
    );
    final readyDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (!output.externalPresentationReady) {
      if (DateTime.now().isAfter(readyDeadline)) {
        fail('offscreen mounted host never observed completed detached warm');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      output.externalPresentationReady,
      isTrue,
      reason:
          'completed detached work must be consumable before the page enters the viewport',
    );
    },
  );

  test(
    'detached prewarm failure cannot revoke a newly mounted consumer',
      () async {
    final uri = Uri.parse('asset:///opaque-prewarm-handoff-page');
    final releasePrewarm = Completer<void>();
    final prewarmStarted = Completer<void>();
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      externalPresentationPrewarmer: (request) async {
        if (!prewarmStarted.isCompleted) prewarmStarted.complete();
        await releasePrewarm.future;
        throw UnsupportedError('detached warm miss');
      },
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'opaque-prewarm-handoff-r1',
          loadBytes: () async => Uint8List.fromList(const <int>[
                  0xff,
                  0xd8,
                  0xff,
                  0xe0,
                  0x00,
                  0x10,
                  0x4a,
                  0x46,
                  0x49,
                  0x46,
                  0x00,
                  0x01,
          ]),
        ),
      },
    ).create(
      chapter: _chapter(
        uri: uri,
        contentKindHint: ContentKindHint.unknown,
      ),
      sessionId: 'fallback-prewarm-handoff-test',
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(_currentObservation(session.chapter));

    await prewarmStarted.future.timeout(const Duration(seconds: 2));
    final page = session.chapter.pages.single;
    final output = session.pageOutput(page);
    void listener(PipelinePageOutputSnapshot _) {}
    output.addListener(listener);
    addTearDown(() => output.removeListener(listener));

    expect(output.externalPresentationRequested, isTrue);
    releasePrewarm.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      output.externalPresentationRequested,
      isTrue,
      reason:
          'a detached optimization miss must hand the existing exact grant to the mounted consumer',
    );

    final grant = output.externalPresentationGrant;
    expect(grant, isNotNull);
    output.reportExternalPresentationFrameReady(grant!);
    expect(output.externalPresentationRequested, isFalse);
    expect(output.externalPresentationReady, isTrue);
    },
  );

  test(
    'stale first-frame acknowledgement cannot satisfy same-identity regrant',
    () async {
      final uri = Uri.parse('asset:///stale-presentation-ack-page');
      final authority = _FakePresentationCacheAuthority();
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: _Factory(_Runtime()),
        pageDownloadLane: NetLane(maxActive: 5),
        presentationCacheAuthority: authority,
        externalPresentationPrewarmer: (_) async {
          throw UnsupportedError('force mounted presentation');
        },
        loaderSources: <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'stale-presentation-ack-r1',
            loadBytes: () async => Uint8List.fromList(const <int>[
              0xff,
              0xd8,
              0xff,
              0xe0,
              0x00,
              0x10,
              0x4a,
              0x46,
              0x49,
              0x46,
              0x00,
              0x01,
            ]),
          ),
        },
      ).create(
        chapter: _chapter(
          uri: uri,
          contentKindHint: ContentKindHint.unknown,
        ),
        sessionId: 'stale-presentation-ack-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

      final page = session.chapter.pages.single;
      final output = session.pageOutput(page);
      void listener(PipelinePageOutputSnapshot _) {}
      output.addListener(listener);
      addTearDown(() => output.removeListener(listener));
      session.accept(_currentObservation(session.chapter));

      final firstDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (!output.externalPresentationRequested) {
        if (DateTime.now().isAfter(firstDeadline)) {
          fail('initial mounted presentation grant was not requested');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final first = output.externalPresentationGrant!;
      expect(first.requested, isTrue);

      authority.invalidatePresentationIdentity(first.cacheIdentity);

      final regrantDeadline = DateTime.now().add(const Duration(seconds: 2));
      while (!(output.externalPresentationGrant?.requested ?? false) ||
          identical(
            output.externalPresentationGrant?.acknowledgementToken,
            first.acknowledgementToken,
          )) {
        if (DateTime.now().isAfter(regrantDeadline)) {
          fail('same-identity presentation was not regranted');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final regrant = output.externalPresentationGrant!;
      expect(identical(regrant.cacheIdentity, first.cacheIdentity), isTrue);
      expect(
        identical(regrant.acknowledgementToken, first.acknowledgementToken),
        isFalse,
      );

      output.reportExternalPresentationFrameReady(first);
      expect(output.externalPresentationRequested, isTrue);
      expect(output.externalPresentationReady, isFalse);

      output.reportExternalPresentationFrameReady(regrant);
      expect(output.externalPresentationRequested, isFalse);
      expect(output.externalPresentationReady, isTrue);
    },
  );

  test(
    'non-media fallback prefix never becomes runtime static evidence',
    () async {
    final trace = MemoryTraceSink();
    final uri = Uri.parse('asset:///opaque-non-media-page');
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 5),
      loaderSources: <Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'opaque-non-media-r1',
                loadBytes: () async =>
                    Uint8List.fromList('Could not connect to mysql!'.codeUnits),
        ),
      },
    ).create(
      chapter: _chapter(
        uri: uri,
        contentKindHint: ContentKindHint.unknown,
      ),
      sessionId: 'fallback-non-media-classification-test',
      traceSink: trace,
    );
    addTearDown(session.dispose);
    session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
    session.accept(_currentObservation(session.chapter));

    TraceEvent? fallbackCommit;
      for (
        var attempt = 0;
        attempt < 100 && fallbackCommit == null;
        attempt++
      ) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      for (final event in trace.events) {
        if (event.kind == TraceEventKind.bytesCommitted &&
            event.payload['kind'] == 'fallback') {
          fallbackCommit = event;
          break;
        }
      }
    }
    expect(fallbackCommit, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.mediaClassified &&
            event.payload['basis'] == 'encoded-prefix',
      ),
      isEmpty,
      reason:
          'fallback is a transport category, not proof that arbitrary HTML/error bytes are a static image',
    );
    },
  );

  test(
    'known non-WebP pages do not allocate detached native outputs',
    () async {
    final trace = MemoryTraceSink();
    final runtime = _Runtime(renderer: RendererKind.androidTexture);
      final session =
          PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(runtime),
      pageDownloadLane: NetLane(maxActive: 5),
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
    },
  );

  test(
    'static non-WebP suffixes reject unresolved native WebP prewarm',
      () async {
    for (final suffix in <String>['jpe', 'heic']) {
      final trace = MemoryTraceSink();
      final runtime = _Runtime(renderer: RendererKind.androidTexture);
        final session =
            PipelineReaderSessionFactory(
        mediaRuntimeFactory: _Factory(runtime),
        pageDownloadLane: NetLane(maxActive: 5),
      ).create(
        chapter: _chapter(
          uri: Uri.parse('asset:///page-0.$suffix'),
          contentKindHint: ContentKindHint.unknown,
        ),
        sessionId: 'non-webp-suffix-prewarm-$suffix',
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
          sessionId: 'reader-$suffix',
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
        reason: '.$suffix is already positive non-WebP container evidence',
      );
      await session.dispose();
    }
    },
  );

  test('Reader session dispose releases presentation cache listener and claims',
      () async {
    final pages = List<PageAsset>.generate(
      3,
      (index) => PageAsset(
        pageId: 'dispose-static-$index',
        chapterId: 'dispose-static-chapter',
        index: index,
        uri: Uri.parse('asset:///dispose-static-$index.png'),
        width: 1,
        height: 1,
        contentKindHint: ContentKindHint.png,
      ),
    );
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'dispose-static-comic',
      chapter: const Chapter(
        chapterId: 'dispose-static-chapter',
        comicId: 'dispose-static-comic',
        title: 'dispose static',
        sequence: 1,
        pageCount: 3,
        sourceRevision: 'r1',
      ),
      pages: pages,
      readingDirection: ReadingDirection.vertical,
    );
    final authority = _FakePresentationCacheAuthority();
    final warmed = <PipelineExternalPresentationWarmRequest>[];
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      pageDownloadLane: NetLane(maxActive: 3),
      presentationCacheAuthority: authority,
      externalPresentationPrewarmer: (request) async {
        request.token.throwIfCancelled();
        warmed.add(request);
      },
      loaderSources: <Uri, LoaderTransportSource>{
        for (final page in pages)
          page.uri: LoaderTransportSource(
            revision: 'dispose-static-r1',
            loadBytes: () async => Uint8List.fromList(
              const <int>[
                0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
              ],
            ),
          ),
      },
    ).create(
      chapter: chapter,
      sessionId: 'presentation-dispose-test',
    );
    session.attach(
      DecodeTarget(physicalWidth: 320, physicalHeight: 480),
      externalPresentationFit: PipelineExternalPresentationFit.fitWidth,
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
          assetKey: pages.first.assetKey,
          fraction: 1,
        ),
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026),
        monotonicMicros: 1,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (authority.claims.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('presentation cache claim was never established');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(authority.listenerCount, 1);

    await session.dispose();

    expect(authority.listenerCount, 0);
    expect(authority.claims, isEmpty);
  });

  test('Reader session owns and closes one atomic media runtime', () async {
    final runtime = _Runtime();
    final factory = _Factory(runtime);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: factory,
      pageDownloadLane: NetLane(maxActive: 5),
    ).create(chapter: _chapter(), sessionId: 'atomic-media-test');

    expect(factory.created, 1);
    expect(session.renderer, RendererKind.flutterImage);

    await session.dispose();

    expect(runtime.closed, isTrue);
  });
}

ReaderObs _currentObservation(ChapterManifest chapter) => ReaderObs(
      sessionId: 'reader',
      currentIndex: 0,
      stableIndex: 0,
      interaction: Interaction.idle,
      logicalPosition: 0,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 0,
        assetKey: chapter.pages.first.assetKey,
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026),
      monotonicMicros: 1,
    );

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

ChapterManifest _chapterIdentity({
  required String comicId,
  required String chapterId,
  required Uri uri,
}) => ChapterManifest(
      sourceId: 'source',
      comicId: comicId,
      chapter: Chapter(
        chapterId: chapterId,
        comicId: comicId,
        title: chapterId,
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: '$chapterId-page-0',
          chapterId: chapterId,
          index: 0,
          uri: uri,
          contentKindHint: ContentKindHint.webp,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

ChapterManifest _chapter({
  int? width,
  int? height,
  int? byteLength,
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
          byteLength: byteLength,
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
  }) => _Runtime();
}

final class _FakePresentationCacheAuthority
    implements PipelinePresentationCacheAuthority {
  final Set<PipelinePresentationCacheInvalidationListener> _listeners =
      <PipelinePresentationCacheInvalidationListener>{};
  final Map<Object, PipelinePresentationCacheClaim> claims =
      <Object, PipelinePresentationCacheClaim>{};
  final Set<Object> speculativeAdmissionDenied = <Object>{};

  int get listenerCount => _listeners.length;

  @override
  void addInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  ) {
    _listeners.add(listener);
  }

  @override
  void removeInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  ) {
    _listeners.remove(listener);
  }

  @override
  void updatePresentationClaim(
    Object presentationIdentity,
    PipelinePresentationCacheClaim claim,
  ) {
    claims[presentationIdentity] = claim;
    if (claim != PipelinePresentationCacheClaim.speculative) {
      speculativeAdmissionDenied.remove(presentationIdentity);
    }
  }

  @override
  void releasePresentationClaim(Object presentationIdentity) {
    claims.remove(presentationIdentity);
  }

  @override
  bool allowsPresentationWarm(Object presentationIdentity) {
    if (!speculativeAdmissionDenied.contains(presentationIdentity)) return true;
    final claim = claims[presentationIdentity];
    return claim == PipelinePresentationCacheClaim.deadline ||
        claim == PipelinePresentationCacheClaim.protected;
  }

  void evictForBudget(Object presentationIdentity) {
    if (claims[presentationIdentity] ==
        PipelinePresentationCacheClaim.speculative) {
      speculativeAdmissionDenied.add(presentationIdentity);
    }
    for (final listener in _listeners.toList(growable: false)) {
      listener(presentationIdentity);
    }
  }

  @override
  void invalidatePresentationIdentity(Object presentationIdentity) {
    claims.remove(presentationIdentity);
    speculativeAdmissionDenied.remove(presentationIdentity);
    for (final listener in _listeners.toList(growable: false)) {
      listener(presentationIdentity);
    }
  }
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

final class _Runtime implements PipelineMediaRuntime, PipelineOutputPrewarmer {
  _Runtime({
    RendererKind renderer = RendererKind.flutterImage,
    PipelineFrameScheduler? scheduler,
    SourceFactory? sources,
    CursorFactory? cursors,
  })  : _renderer = renderer,
        _scheduler = scheduler ?? const _TestFrameScheduler(),
        _sources = sources ?? _SourceFactory(),
        _cursors = cursors ?? const _CursorFactory();

  final RendererKind _renderer;
  final PipelineFrameScheduler _scheduler;
  final SourceFactory _sources;
  final CursorFactory _cursors;
  bool closed = false;
  int prewarmCalls = 0;
  final Completer<List<int>> firstPrewarm = Completer<List<int>>();

  @override
  SourceFactory get sources => _sources;

  @override
  CursorFactory get cursors => _cursors;

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
  bool disposed = false;

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
  void dispose() => disposed = true;
}

final class _RetainedDecodeSourceFactory implements SourceFactory {
  final List<_Source> created = <_Source>[];

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    final source = _Source(epoch)..kind = SourceKind.webp;
    created.add(source);
    return source;
  }
}

final class _RetainedDecodeCursorFactory implements CursorFactory {
  final cursor = _RetainedDecodeCursor();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    cursor.epoch = epoch;
    return CursorBinding(frames: cursor);
  }
}

final class _RetainedDecodeCursor implements FrameCursor {
  final started = Completer<void>();
  final finish = Completer<void>();
  final retired = Completer<void>();
  bool disposed = false;
  @override
  int epoch = 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (!started.isCompleted) started.complete();
    await finish.future;
    if (disposed) throw StateError('cursor disposed before native return');
    return const CursorStep.end();
  }

  @override
  void dispose() {
    disposed = true;
    if (!retired.isCompleted) retired.complete();
  }
}

final class _CursorFactory implements CursorFactory {
  const _CursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => throw UnsupportedError('not used');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({required DecodeId id, required FrameRef frame}) =>
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
  }) => SizedBox(key: key, width: 1, height: 1);
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
