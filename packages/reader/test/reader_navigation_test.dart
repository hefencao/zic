import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:telemetry/telemetry.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 30,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}


void main() {
  testWidgets('controller page requests are consumed by ReaderView', (
    tester,
  ) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 0,
        pageCount: 3,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        3,
        (index) => PageAsset(
          pageId: 'page-$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('asset:///page-$index.png'),
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );
    final controller = ReaderController(
      sessionId: 'reader-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
            key: ValueKey<String>(asset.pageId),
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pump();

    controller.requestPage(2);
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('page-2')), findsOneWidget);
    expect(controller.requestedIndex, isNull);
  });


  testWidgets('presentation revision rebuilds only the changed page slot',
      (tester) async {
    final chapter = _chapter(pageCount: 3);
    final controller = ReaderController(
      sessionId: 'reader-presentation-revision-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final revisions = ValueNotifier<Map<String, int>>(
      const <String, int>{},
    );
    addTearDown(revisions.dispose);
    final builds = <String, int>{};

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<Map<String, int>>(
          valueListenable: revisions,
          builder: (context, value, _) => ReaderView(
            controller: controller,
            clock: FakeClock(),
            pagePresentationRevisions: value,
            pageBuilder: (context, asset, reportFirstFrame) {
              builds.update(
                asset.pageId,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              return ColoredBox(
                key: ValueKey<String>('presentation:${asset.pageId}'),
                color: Colors.black,
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final before = Map<String, int>.of(builds);
    expect(before['page-0'], isNotNull);

    revisions.value = <String, int>{chapter.pages[0].assetKey: 1};
    await tester.pump();

    expect(builds['page-0'], (before['page-0'] ?? 0) + 1);
    for (final entry in before.entries) {
      if (entry.key == 'page-0') continue;
      expect(
        builds[entry.key],
        entry.value,
        reason: 'unmodified page ${entry.key} must retain its cached slot',
      );
    }
  });


  testWidgets(
    'crossing the page midpoint preserves loaded page hosts',
    (tester) async {
      final chapter = _chapter(pageCount: 3);
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-midpoint-test',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      final lifecycle = _PageLifecycle();
      final trace = MemoryTraceSink();

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: FakeClock(),
            traceSink: trace,
            demandRevision: () => 7,
            pageBuilder: (context, asset, reportFirstFrame) =>
                _LifecyclePage(
              pageId: asset.pageId,
              lifecycle: lifecycle,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(lifecycle.created['page-0'], 1);

      final pageView = find.byType(PageView);
      final gesture = await tester.startGesture(tester.getCenter(pageView));
      final dragStep = Offset(-tester.getSize(pageView).width / 32, 0);
      await _moveGestureUntil(
        tester: tester,
        gesture: gesture,
        delta: dragStep,
        condition: () => lifecycle.created['page-1'] == 1,
        failure: 'target page host never entered the render tree',
      );

      expect(controller.currentIndex, 0);
      expect(lifecycle.created['page-0'], 1);
      expect(lifecycle.created['page-1'], 1);
      expect(lifecycle.disposed['page-0'] ?? 0, 0);
      expect(lifecycle.disposed['page-1'] ?? 0, 0);

      await _moveGestureUntil(
        tester: tester,
        gesture: gesture,
        delta: dragStep,
        condition: () => controller.currentIndex == 1,
        failure: 'gesture never crossed the page midpoint',
      );

      final midpointObservation = observations.last;
      expect(midpointObservation.currentIndex, 1);
      expect(midpointObservation.targetCoverage?.pageIndex, 0);
      expect(
        midpointObservation.currentCoverage.fraction,
        greaterThanOrEqualTo(0.5),
      );
      expect(midpointObservation.targetCoverage!.fraction, greaterThan(0));
      expect(
        midpointObservation.currentCoverage.fraction +
            midpointObservation.targetCoverage!.fraction,
        closeTo(1, 0.001),
        reason:
            'PageView midpoint ownership must not emit a targetless integer observation',
      );

      expect(controller.currentIndex, 1);
      expect(lifecycle.created['page-0'], 1);
      expect(lifecycle.created['page-1'], 1);
      expect(lifecycle.disposed['page-0'] ?? 0, 0);
      expect(lifecycle.disposed['page-1'] ?? 0, 0);
      expect(
        trace.events.where(
          (event) =>
              event.kind == TraceEventKind.pageHostDisposed &&
              (event.identityHash == chapter.pages[0].assetKey ||
                  event.identityHash == chapter.pages[1].assetKey),
        ),
        isEmpty,
        reason: 'crossing the role midpoint must not remount either loaded page',
      );
      expect(
        trace.events
            .where(
              (event) =>
                  event.kind == TraceEventKind.pageHostMounted ||
                  event.kind == TraceEventKind.pageHostDisposed,
            )
            .every((event) => event.payload['keepAlive'] is bool),
        isTrue,
      );

      await gesture.up();
      await tester.pump();
      expect(lifecycle.created['page-1'], 1);
      expect(lifecycle.disposed['page-1'] ?? 0, 0);
      expect(
        trace.events.where(
          (event) => event.kind == TraceEventKind.pageTransition,
        ),
        isNotEmpty,
      );
      expect(
        trace.events
            .where((event) => event.kind == TraceEventKind.pageTransition)
            .every((event) => event.revision == 7),
        isTrue,
      );
      expect(
        trace.events.where(
          (event) =>
              event.kind == TraceEventKind.pageHostMounted &&
              (event.identityHash == chapter.pages[0].assetKey ||
                  event.identityHash == chapter.pages[1].assetKey),
        ).length,
        2,
        reason: 'settling may evict the old page, but must not remount it',
      );
    },
  );

  testWidgets('ReaderView rotates pages and supports double-tap zoom',
      (tester) async {
    final chapter = _chapter(pageCount: 2);
    final controller = ReaderController(
      sessionId: 'reader-gesture-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
            color: Colors.black,
            child: Center(child: Text(asset.pageId)),
          ),
        ),
      ),
    );
    await tester.pump();

    final rotation = find.byKey(
      const ValueKey<String>('reader-page-rotation:0'),
    );
    expect(tester.widget<RotatedBox>(rotation).quarterTurns, 0);

    controller.rotateClockwise();
    await tester.pump();
    expect(tester.widget<RotatedBox>(rotation).quarterTurns, 1);

    var viewer = find.descendant(
      of: rotation,
      matching: find.byType(InteractiveViewer),
    );
    expect(
      viewer,
      findsNothing,
      reason: 'scale recognizers must not compete with PageView at scale 1',
    );
    final center = tester.getCenter(rotation);
    await tester.tapAt(center);
    await tester.tapAt(center);
    await tester.pump();
    viewer = find.descendant(
      of: rotation,
      matching: find.byType(InteractiveViewer),
    );
    expect(viewer, findsOneWidget);
    final interactive = tester.widget<InteractiveViewer>(viewer);
    expect(
      interactive.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );

    controller.requestPage(1);
    await tester.pump();
    controller.requestPage(0);
    await tester.pump();
    final resetViewer = find.descendant(
      of: rotation,
      matching: find.byType(InteractiveViewer),
    );
    expect(
      resetViewer,
      findsNothing,
      reason: 'returning to a page must reset it to swipe-through scale 1',
    );
  });


  testWidgets('vertical mode adopts measured media geometry without cropping',
      (tester) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'measured-comic',
      chapter: const Chapter(
        chapterId: 'measured-chapter',
        comicId: 'measured-comic',
        title: 'measured',
        sequence: 0,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'measured-page',
          chapterId: 'measured-chapter',
          index: 0,
          uri: Uri.parse('asset:///measured.png'),
        ),
      ],
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-measured-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    Future<void> pump(Map<String, double> ratios) => tester.pumpWidget(
          MaterialApp(
            home: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageAspectRatios: ratios,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                color: Colors.black,
                child: Text(asset.pageId),
              ),
            ),
          ),
        );

    await pump(const <String, double>{});
    await tester.pump();
    final finder = find.byKey(
      const ValueKey<String>('reader-vertical-page:0'),
    );
    final fallbackHeight = tester.getSize(finder).height;
    expect(
      fallbackHeight,
      greaterThanOrEqualTo(tester.getSize(find.byType(ReaderView)).height),
      reason: 'unknown geometry must keep the page presentation in view',
    );

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'Reader geometry must not create a second loading authority',
    );

    await pump(<String, double>{chapter.pages.single.assetKey: 2.4});
    await tester.pump();
    final measuredHeight = tester.getSize(finder).height;

    expect(measuredHeight, greaterThan(fallbackHeight));
    expect(
      measuredHeight,
      closeTo(tester.getSize(find.byType(ReaderView)).width * 2.4, 0.1),
    );
  });

  testWidgets('unknown vertical extents do not depend on current page',
      (tester) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'stable-placeholder-comic',
      chapter: const Chapter(
        chapterId: 'stable-placeholder-chapter',
        comicId: 'stable-placeholder-comic',
        title: 'stable placeholder',
        sequence: 0,
        pageCount: 2,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        2,
        (index) => PageAsset(
          pageId: 'stable-placeholder-$index',
          chapterId: 'stable-placeholder-chapter',
          index: index,
          uri: Uri.parse('asset:///stable-placeholder-$index.webp'),
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-stable-placeholder-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          pageBuilder: (context, asset, reportFirstFrame) =>
              Text(asset.pageId),
        ),
      ),
    );
    await tester.pump();
    final first = find.byKey(
      const ValueKey<String>('reader-vertical-page:0'),
    );
    final beforeFirst = tester.getSize(first).height;

    controller.report(
      ReaderObs(
        sessionId: controller.sessionId,
        currentIndex: 1,
        stableIndex: 1,
        currentCoverage: Coverage(
          pageIndex: 1,
          assetKey: chapter.pages[1].assetKey,
          fraction: 1,
        ),
        interaction: Interaction.idle,
        logicalPosition: 1,
        velocity: 0,
        direction: ReadingDirection.vertical,
        timestamp: DateTime.utc(2026, 8, 1),
        monotonicMicros: 1,
      ),
    );
    await tester.pump();

    expect(tester.getSize(first).height, beforeFirst);
  });

  test('rotation cycles and can reset', () {
    final controller = ReaderController(
      sessionId: 'reader-rotation-test',
      chapter: _chapter(pageCount: 1),
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    for (var index = 0; index < 5; index++) {
      controller.rotateClockwise();
    }
    expect(controller.rotationQuarterTurns, 1);
    controller.resetRotation();
    expect(controller.rotationQuarterTurns, 0);
  });

  test('page requests deduplicate and can cancel back to current', () {
    final chapter = _chapter(pageCount: 3);
    final controller = ReaderController(
      sessionId: 'reader-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    controller.requestPage(2);
    final revision = controller.navigationRevision;
    controller.requestPage(2);
    expect(controller.navigationRevision, revision);

    controller.requestPage(0);
    expect(controller.requestedIndex, isNull);
    expect(controller.navigationRevision, revision + 1);
  });

  test('page scrub updates navigation live and ends with a planning revision', () {
    final chapter = _chapter(pageCount: 4);
    final controller = ReaderController(
      sessionId: 'reader-scrub-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    controller.beginPageScrub();
    controller.scrubToPage(2);
    expect(controller.pageScrubbing, isTrue);
    expect(controller.requestedIndex, 2);
    final scrubRevision = controller.navigationRevision;

    controller.acknowledgePageRequest(scrubRevision);
    expect(controller.requestedIndex, isNull);
    controller.endPageScrub(2);
    expect(controller.pageScrubbing, isFalse);
    expect(controller.navigationRevision, scrubRevision + 1);
  });

  test('page scrub coalesces intermediate navigation and flushes final page', () async {
    final chapter = _chapter(pageCount: 5);
    final controller = ReaderController(
      sessionId: 'reader-scrub-coalesce-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <int?>[];
    controller.addListener(() => requested.add(controller.requestedIndex));

    controller.beginPageScrub();
    controller.scrubToPage(1);
    controller.scrubToPage(2);
    controller.scrubToPage(3);

    expect(requested, <int?>[1]);
    expect(controller.navigationRevision, 1);

    await Future<void>.delayed(const Duration(milliseconds: 65));
    expect(requested, <int?>[1, 3]);
    expect(controller.navigationRevision, 2);

    controller.endPageScrub(4);
    expect(controller.pageScrubbing, isFalse);
    expect(controller.requestedIndex, 4);
    expect(requested, <int?>[1, 3, 4]);
    expect(controller.navigationRevision, 3);
  });

  testWidgets(
    'frame interval anomalies stay individual with work jank',
    (tester) async {
      final chapter = _chapter(pageCount: 1);
      final trace = MemoryTraceSink();
      final source = _TestFrameTimingSource();
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-frame-summary-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: clock,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: clock,
            traceSink: trace,
            frameTimingSource: source,
          ),
        ),
      );
      await tester.pump();

      source.emit(const <ReaderFrameTimingSample>[
        ReaderFrameTimingSample(
          buildMicros: 3000,
          rasterMicros: 2500,
          totalSpanMicros: 6000,
          vsyncOverheadMicros: 300,
          vsyncStartMicros: 100000,
          frameIntervalMicros: 25000,
        ),
        ReaderFrameTimingSample(
          buildMicros: 3500,
          rasterMicros: 2600,
          totalSpanMicros: 6500,
          vsyncOverheadMicros: 350,
          vsyncStartMicros: 130000,
          frameIntervalMicros: 50000,
        ),
        ReaderFrameTimingSample(
          buildMicros: 22000,
          rasterMicros: 3000,
          totalSpanMicros: 26000,
          vsyncOverheadMicros: 400,
          vsyncStartMicros: 160000,
          frameIntervalMicros: 16667,
        ),
      ]);

      final timings = trace.events
          .where((event) => event.kind == TraceEventKind.readerFrameTiming)
          .toList(growable: false);
      expect(timings, hasLength(3));
      expect(timings[0].payload['frameIntervalMicros'], 25000);
      expect(timings[1].payload['frameIntervalMicros'], 50000);
      expect(timings[2].payload['buildMicros'], 22000);
      expect(
        timings.where((event) => event.payload['timingSummary'] == true),
        isEmpty,
      );
    },
  );

  testWidgets(
    'vertical composition gates loading tickers to geometry-visible pages',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'ticker-gate-comic',
        chapter: const Chapter(
          chapterId: 'ticker-gate-chapter',
          comicId: 'ticker-gate-comic',
          title: 'ticker gate',
          sequence: 0,
          pageCount: 48,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          48,
          (index) => PageAsset(
            pageId: 'ticker-$index',
            chapterId: 'ticker-gate-chapter',
            index: index,
            uri: Uri.parse('asset:///ticker-$index.png'),
            width: 1000,
            height: 100,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-ticker-gate-test',
        chapter: chapter,
        initialPage: 20,
        onObservation: (_) {},
        clock: clock,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: clock,
            pageBuilder: (context, asset, reportFirstFrame) => const Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final pageFinders = <({int index, Finder finder})>[];
      for (var index = 0; index < chapter.pages.length; index++) {
        final finder = find.byKey(
          ValueKey<String>('reader-vertical-page:$index'),
        );
        if (finder.evaluate().isNotEmpty) {
          pageFinders.add((index: index, finder: finder));
        }
      }
      expect(pageFinders.length, greaterThan(1));

      final tickerModes = <int, bool>{};
      for (final entry in pageFinders) {
        final tickerMode = find.descendant(
          of: entry.finder,
          matching: find.byType(TickerMode),
        );
        expect(
          tickerMode,
          findsOneWidget,
          reason: 'every composed vertical page must have a ticker gate',
        );
        tickerModes[entry.index] =
            tester.widget<TickerMode>(tickerMode).enabled;
      }

      expect(tickerModes.values, contains(true));
      expect(
        tickerModes.values,
        contains(false),
        reason:
            'cacheExtent/keepAlive pages outside the viewport must stay mounted but ticker-muted',
      );
      expect(tickerModes[controller.currentIndex], isTrue);
    },
  );

  testWidgets(
    'vertical idle keepAlive recenter does not release the whole old window in one frame',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'bounded-keepalive-comic',
        chapter: const Chapter(
          chapterId: 'bounded-keepalive-chapter',
          comicId: 'bounded-keepalive-comic',
          title: 'bounded keepalive',
          sequence: 0,
          pageCount: 48,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          48,
          (index) => PageAsset(
            pageId: 'bounded-$index',
            chapterId: 'bounded-keepalive-chapter',
            index: index,
            uri: Uri.parse('asset:///bounded-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-bounded-keepalive-test',
        chapter: chapter,
        initialPage: 20,
        onObservation: (_) {},
        clock: clock,
      );
      addTearDown(controller.dispose);
      final trace = MemoryTraceSink();

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: clock,
            traceSink: trace,
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();
      final list = find.byKey(
        const ValueKey<String>('reader-vertical-list'),
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      final mountedBeforeWarmupCollapse = trace.events
          .where((event) => event.kind == TraceEventKind.pageHostMounted)
          .length;
      expect(mountedBeforeWarmupCollapse, greaterThanOrEqualTo(8));

      state.position.jumpTo(state.position.pixels + 1);
      await tester.pumpAndSettle();
      final disposedBeforeJump = trace.events
          .where((event) => event.kind == TraceEventKind.pageHostDisposed)
          .length;

      state.position.jumpTo(state.position.maxScrollExtent * 0.85);
      var previousDisposed = disposedBeforeJump;
      final disposedPerFrame = <int>[];
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump();
        final disposed = trace.events
            .where((event) => event.kind == TraceEventKind.pageHostDisposed)
            .length;
        disposedPerFrame.add(disposed - previousDisposed);
        previousDisposed = disposed;
      }

      expect(controller.currentIndex, greaterThan(30));
      expect(
        disposedPerFrame.fold<int>(0, (max, value) => value > max ? value : max),
        lessThanOrEqualTo(3),
        reason:
            'idle keepAlive recenter must retire the old window over bounded frames',
      );
      expect(
        previousDisposed - disposedBeforeJump,
        greaterThanOrEqualTo(8),
        reason: 'the regression must exercise a real old-window retirement',
      );
    },
  );

  testWidgets(
    'vertical current changes rebuild only page shells whose state changed',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'localized-rebuild-comic',
        chapter: const Chapter(
          chapterId: 'localized-rebuild-chapter',
          comicId: 'localized-rebuild-comic',
          title: 'localized rebuild',
          sequence: 0,
          pageCount: 2,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          2,
          (index) => PageAsset(
            pageId: 'localized-$index',
            chapterId: 'localized-rebuild-chapter',
            index: index,
            uri: Uri.parse('asset:///localized-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-localized-rebuild-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      final builds = <String, int>{};

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: FakeClock(),
            pageBuilder: (context, asset, reportFirstFrame) {
              builds.update(
                asset.pageId,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              return ColoredBox(
                key: ValueKey<String>('localized:${asset.pageId}'),
                color: Colors.black,
              );
            },
          ),
        ),
      );
      await tester.pump();
      controller.requestPage(1);
      await tester.pump();
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('localized:localized-1')),
      );
      final currentPrior = builds['localized-0'];
      final nextPrior = builds['localized-1'];

      controller.report(
        ReaderObs(
          sessionId: controller.sessionId,
          currentIndex: 0,
          stableIndex: 0,
          currentCoverage: Coverage(
            pageIndex: 0,
            assetKey: chapter.pages[0].assetKey,
            fraction: 1,
          ),
          interaction: Interaction.idle,
          logicalPosition: 0,
          velocity: 0,
          direction: ReadingDirection.vertical,
          timestamp: DateTime.utc(2026, 8, 4),
          monotonicMicros: 1,
        ),
      );
      await tester.pump();

      expect(builds['localized-0'], currentPrior);
      expect(builds['localized-1'], nextPrior);
    },
  );

  testWidgets(
    'ratio updates reuse precomposed page shells instead of rebuilding content',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'composition-comic',
        chapter: const Chapter(
          chapterId: 'composition-chapter',
          comicId: 'composition-comic',
          title: 'composition',
          sequence: 0,
          pageCount: 4,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          4,
          (index) => PageAsset(
            pageId: 'composition-$index',
            chapterId: 'composition-chapter',
            index: index,
            uri: Uri.parse('asset:///composition-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-composition-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      final clock = FakeClock();
      final ratios = ValueNotifier<Map<String, double>>(
        const <String, double>{},
      );
      addTearDown(ratios.dispose);
      final builds = <String, int>{};

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Map<String, double>>(
            valueListenable: ratios,
            builder: (context, value, _) => ReaderView(
              controller: controller,
              clock: clock,
              pageAspectRatios: value,
              pageBuilder: (context, asset, reportFirstFrame) {
                builds.update(
                  asset.pageId,
                  (count) => count + 1,
                  ifAbsent: () => 1,
                );
                return ColoredBox(
                  key: ValueKey<String>('composition:${asset.pageId}'),
                  color: Colors.black,
                );
              },
            ),
          ),
        ),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('composition:composition-0')),
      );
      await tester.pump();
      final before = Map<String, int>.of(builds);

      ratios.value = <String, double>{
        chapter.pages.first.assetKey: 1.8,
      };
      await tester.pump();

      for (final entry in before.entries) {
        expect(builds[entry.key], entry.value);
      }
    },
  );


  testWidgets(
    'reverse vertical scroll prepares incoming measured prefix without visible reflow',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-reverse-prefix-comic',
        chapter: const Chapter(
          chapterId: 'vertical-reverse-prefix-chapter',
          comicId: 'vertical-reverse-prefix-comic',
          title: 'vertical reverse prefix',
          sequence: 0,
          pageCount: 4,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          4,
          (index) => PageAsset(
            pageId: 'vertical-reverse-$index',
            chapterId: 'vertical-reverse-prefix-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-reverse-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-vertical-reverse-prefix-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
        initialPage: 2,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          chapter.pages[2].assetKey: 1.5,
          chapter.pages[3].assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Map<String, double>>(
            valueListenable: ratios,
            builder: (context, value, _) => ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageAspectRatios: value,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('vertical-reverse:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final page1 = find.byKey(
        const ValueKey<String>('reader-vertical-page:1'),
        skipOffstage: false,
      );
      final initialHeight = tester.getSize(page1).height;
      final beforePage2Top = tester.getTopLeft(
        find.byKey(
          const ValueKey<String>('reader-vertical-page:2'),
          skipOffstage: false,
        ),
      ).dy;

      final gesture = await tester.startGesture(tester.getCenter(list));
      // Drag content down so the Reader travels toward lower page indexes.
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages[1].assetKey: 2.5,
      };
      await tester.pump();

      expect(
        tester.getSize(page1).height,
        greaterThan(initialHeight),
        reason:
            'an incoming lower-index page should use its measured extent before it enters the viewport',
      );
      final afterPage2Top = tester.getTopLeft(
        find.byKey(
          const ValueKey<String>('reader-vertical-page:2'),
          skipOffstage: false,
        ),
      ).dy;
      expect(
        afterPage2Top,
        closeTo(beforePage2Top + 120, 1.0),
        reason:
            'prefix growth must be absorbed by layout-time scroll correction instead of moving the current page',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );


  testWidgets(
    'idle measured ratio refresh republishes the real vertical visible set',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-idle-ratio-comic',
        chapter: const Chapter(
          chapterId: 'vertical-idle-ratio-chapter',
          comicId: 'vertical-idle-ratio-comic',
          title: 'vertical idle ratio',
          sequence: 0,
          pageCount: 3,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          3,
          (index) => PageAsset(
            pageId: 'vertical-idle-ratio-$index',
            chapterId: 'vertical-idle-ratio-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-idle-ratio-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-vertical-idle-ratio-test',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        const <String, double>{},
      );
      addTearDown(ratios.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('vertical-idle-ratio:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(observations.last.visibleCoverages.map((entry) => entry.pageIndex),
          <int>[0]);

      observations.clear();
      ratios.value = <String, double>{chapter.pages.first.assetKey: 0.25};
      await tester.pump();
      await tester.pump();

      expect(observations, isNotEmpty,
          reason:
              'a layout-only dimension change must publish new vertical visibility without waiting for a gesture');
      expect(
        observations.last.visibleCoverages.map((entry) => entry.pageIndex),
        contains(1),
        reason:
            'the lower page is physically visible after the first page shrinks and must receive demand immediately',
      );
    },
  );


  testWidgets(
    'vertical measured ratios stay frozen until active scrolling is idle',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-geometry-snapshot-comic',
        chapter: const Chapter(
          chapterId: 'vertical-geometry-snapshot-chapter',
          comicId: 'vertical-geometry-snapshot-comic',
          title: 'vertical geometry snapshot',
          sequence: 0,
          pageCount: 3,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          3,
          (index) => PageAsset(
            pageId: 'vertical-snapshot-$index',
            chapterId: 'vertical-geometry-snapshot-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-snapshot-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-vertical-geometry-snapshot-test',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
        initialPage: 1,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        const <String, double>{},
      );
      addTearDown(ratios.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Map<String, double>>(
            valueListenable: ratios,
            builder: (context, value, _) => ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageAspectRatios: value,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('vertical-snapshot:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final list = find.byKey(
        const ValueKey<String>('reader-vertical-list'),
      );
      final firstPage = find.byKey(
        const ValueKey<String>('reader-vertical-page:0'),
        skipOffstage: false,
      );
      final initialHeight = tester.getSize(firstPage).height;
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();

      ratios.value = <String, double>{
        chapter.pages.first.assetKey: 3.0,
      };
      await tester.pump();

      expect(
        tester.getSize(firstPage).height,
        initialHeight,
        reason:
            'async measured geometry must not mutate sliver extents mid-scroll',
      );
      observations.clear();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester.getSize(firstPage).height,
        greaterThan(initialHeight),
        reason: 'the latest measured geometry must commit once scrolling is idle',
      );
      expect(
        observations.where((observation) => observation.stableIndex == 0),
        isEmpty,
        reason:
            'idle geometry correction must not expose the new extents at the old pixels before anchor correction',
      );
      expect(
        controller.currentIndex,
        1,
        reason:
            'an async ratio commit above the viewport must preserve the visible page identity',
      );
    },
  );

  testWidgets(
    'vertical decode-ahead ratios prepare unseen future pages during active scrolling',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-ahead-ratio-comic',
        chapter: const Chapter(
          chapterId: 'vertical-ahead-ratio-chapter',
          comicId: 'vertical-ahead-ratio-comic',
          title: 'vertical ahead ratio',
          sequence: 0,
          pageCount: 6,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          6,
          (index) => PageAsset(
            pageId: 'vertical-ahead-$index',
            chapterId: 'vertical-ahead-ratio-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-ahead-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-vertical-ahead-ratio-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
        initialPage: 1,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        const <String, double>{},
      );
      addTearDown(ratios.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ValueListenableBuilder<Map<String, double>>(
              valueListenable: ratios,
              builder: (context, value, _) => ReaderView(
                controller: controller,
                clock: FakeClock(),
                pageAspectRatios: value,
                pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                  key: ValueKey<String>('vertical-ahead:${asset.pageId}'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('reader-vertical-page:5'),
          skipOffstage: false,
        ),
      );

      final list = find.byKey(
        const ValueKey<String>('reader-vertical-list'),
      );
      final priorPage = find.byKey(
        const ValueKey<String>('reader-vertical-page:0'),
        skipOffstage: false,
      );
      final futurePage = find.byKey(
        const ValueKey<String>('reader-vertical-page:5'),
        skipOffstage: false,
      );
      final priorHeight = tester.getSize(priorPage).height;
      final futureHeight = tester.getSize(futurePage).height;
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -18));
      await tester.pump();

      ratios.value = <String, double>{
        chapter.pages.first.assetKey: 3.0,
        chapter.pages.last.assetKey: 3.0,
      };
      await tester.pump();

      expect(
        tester.getSize(priorPage).height,
        priorHeight,
        reason: 'ratios before the visible prefix must remain frozen mid-scroll',
      );
      expect(
        tester.getSize(futurePage).height,
        greaterThan(futureHeight),
        reason:
            'decode-ahead ratios beyond the visible tail must become layout truth before the page enters the viewport',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getSize(priorPage).height, greaterThan(priorHeight));
    },
  );

  testWidgets(
    'vertical direction reversal adopts already-known incoming ratios before visibility',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-reverse-ratio-comic',
        chapter: const Chapter(
          chapterId: 'vertical-reverse-ratio-chapter',
          comicId: 'vertical-reverse-ratio-comic',
          title: 'vertical reverse ratio',
          sequence: 0,
          pageCount: 6,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          6,
          (index) => PageAsset(
            pageId: 'vertical-reverse-$index',
            chapterId: 'vertical-reverse-ratio-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-reverse-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-vertical-reverse-ratio-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
        initialPage: 2,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        const <String, double>{},
      );
      addTearDown(ratios.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ValueListenableBuilder<Map<String, double>>(
              valueListenable: ratios,
              builder: (context, value, _) => ReaderView(
                controller: controller,
                clock: FakeClock(),
                pageAspectRatios: value,
                pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                  key: ValueKey<String>('vertical-reverse:${asset.pageId}'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('reader-vertical-page:0'),
          skipOffstage: false,
        ),
      );

      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final priorPage = find.byKey(
        const ValueKey<String>('reader-vertical-page:0'),
        skipOffstage: false,
      );
      final initialHeight = tester.getSize(priorPage).height;
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();

      ratios.value = <String, double>{chapter.pages.first.assetKey: 3.0};
      await tester.pump();
      expect(
        tester.getSize(priorPage).height,
        initialHeight,
        reason: 'a ratio behind the active travel direction must remain frozen',
      );

      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSize(priorPage).height,
        greaterThan(initialHeight),
        reason:
            'once travel reverses, an already-known still-offscreen incoming page must install its real extent before visibility',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'vertical previous drag does not invent a hidden higher-index target',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-target-comic',
        chapter: const Chapter(
          chapterId: 'vertical-target-chapter',
          comicId: 'vertical-target-comic',
          title: 'vertical target',
          sequence: 0,
          pageCount: 5,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          5,
          (index) => PageAsset(
            pageId: 'vertical-target-$index',
            chapterId: 'vertical-target-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-target-$index.png'),
            width: 1000,
            height: 3000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-vertical-target-test',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
        initialPage: 2,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: FakeClock(),
            pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
              key: ValueKey<String>('vertical-target:${asset.pageId}'),
              color: Colors.black,
            ),
          ),
        ),
      );
      await tester.pump();

      observations.clear();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();

      final previousSamples = observations.where(
        (observation) =>
            observation.velocity < 0 &&
            observation.visibleCoverages.length == 1,
      );
      expect(previousSamples, isNotEmpty);
      expect(
        previousSamples.every((observation) => observation.targetCoverage == null),
        isTrue,
        reason:
            'vertical page-internal fraction must not be interpreted as a hidden PageView target in the opposite direction',
      );

      await gesture.up();
      await tester.pump();
    },
  );

  test('page request validates chapter bounds', () {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 0,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('asset:///page.png'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final controller = ReaderController(
      sessionId: 'reader-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    expect(() => controller.requestPage(1), throwsRangeError);
  });
}

Future<void> _moveGestureUntil({
  required WidgetTester tester,
  required TestGesture gesture,
  required Offset delta,
  required bool Function() condition,
  required String failure,
}) async {
  for (var step = 0; step < 40 && !condition(); step++) {
    await gesture.moveBy(delta);
    await tester.pump();
  }
  if (!condition()) {
    fail(failure);
  }
}

final class _PageLifecycle {
  final Map<String, int> created = <String, int>{};
  final Map<String, int> disposed = <String, int>{};
}

final class _LifecyclePage extends StatefulWidget {
  const _LifecyclePage({
    required this.pageId,
    required this.lifecycle,
  });

  final String pageId;
  final _PageLifecycle lifecycle;

  @override
  State<_LifecyclePage> createState() => _LifecyclePageState();
}

final class _LifecyclePageState extends State<_LifecyclePage> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.created.update(
      widget.pageId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  @override
  void dispose() {
    widget.lifecycle.disposed.update(
      widget.pageId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        key: ValueKey<String>('lifecycle:${widget.pageId}'),
        color: Colors.black,
      );
}

ChapterManifest _chapter({required int pageCount}) {
  return ChapterManifest(
    sourceId: 'source',
    comicId: 'comic',
    chapter: Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'chapter',
      sequence: 0,
      pageCount: pageCount,
      sourceRevision: 'r1',
    ),
    pages: List<PageAsset>.generate(
      pageCount,
      (index) => PageAsset(
        pageId: 'page-$index',
        chapterId: 'chapter',
        index: index,
        uri: Uri.parse('asset:///page-$index.png'),
      ),
    ),
    readingDirection: ReadingDirection.ltr,
  );
}

final class _TestFrameTimingSource implements ReaderFrameTimingSource {
  ReaderFrameTimingListener? _listener;

  @override
  ReaderFrameTimingSubscription subscribe(ReaderFrameTimingListener listener) {
    _listener = listener;
    return _TestFrameTimingSubscription(() {
      if (identical(_listener, listener)) _listener = null;
    });
  }

  void emit(List<ReaderFrameTimingSample> samples) => _listener?.call(samples);
}

final class _TestFrameTimingSubscription
    implements ReaderFrameTimingSubscription {
  _TestFrameTimingSubscription(this._cancel);

  final VoidCallback _cancel;
  bool _cancelled = false;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

final class FakeClock implements MonoClock {
  int _micros = 0;

  @override
  int nowMicros() => _micros++;
}
