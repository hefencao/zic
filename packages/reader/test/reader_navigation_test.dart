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
      greaterThan(2),
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
          pageCount: 6,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          6,
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
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('localized:localized-3')),
      );
      final prior = builds['localized-3'];

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
          timestamp: DateTime.utc(2026, 8, 4),
          monotonicMicros: 1,
        ),
      );
      await tester.pump();

      expect(builds['localized-3'], prior);
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
              clock: FakeClock(),
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

final class FakeClock implements MonoClock {
  int _micros = 0;

  @override
  int nowMicros() => _micros++;
}
