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
      final controller = ReaderController(
        sessionId: 'reader-midpoint-test',
        chapter: chapter,
        onObservation: (_) {},
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
      await tester.pumpAndSettle();
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
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
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
    // Drain the reader's own delayed single-tap window before disposal.
    await tester.pump(const Duration(milliseconds: 400));
  });


  testWidgets('vertical mode uses proportional continuous pages and stitch gap',
      (tester) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'vertical-comic',
      chapter: const Chapter(
        chapterId: 'vertical-chapter',
        comicId: 'vertical-comic',
        title: 'vertical',
        sequence: 0,
        pageCount: 3,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        3,
        (index) => PageAsset(
          pageId: 'vertical-$index',
          chapterId: 'vertical-chapter',
          index: index,
          uri: Uri.parse('asset:///vertical-$index.png'),
          width: 1000,
          height: index == 1 ? 2400 : 1600,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-vertical-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    Future<void> pump({required bool stitch}) => tester.pumpWidget(
          MaterialApp(
            home: ReaderView(
              controller: controller,
              clock: FakeClock(),
              verticalStitch: stitch,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>(asset.pageId),
                color: Colors.black,
              ),
            ),
          ),
        );

    await pump(stitch: false);
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    final firstPageHeight = tester
        .getSize(
          find.byKey(const ValueKey<String>('reader-vertical-page:0')),
        )
        .height;
    controller.requestPage(1);
    final secondPage =
        find.byKey(const ValueKey<String>('reader-vertical-page:1'));
    await _pumpUntilFound(tester, secondPage);
    final gap =
        find.byKey(const ValueKey<String>('reader-vertical-gap:0'));
    final gapElements = gap.evaluate().toList(growable: false);
    expect(gapElements, hasLength(1));
    if (gapElements.length == 1) {
      final gapWidget = gapElements.first.widget as SizedBox;
      expect(gapWidget.height, 8);
    }
    expect(
      tester
          .getSize(secondPage)
          .height,
      greaterThan(firstPageHeight),
    );
    expect(controller.requestedIndex, isNull);

    controller.requestPage(0);
    await tester.pump();
    await tester.pump();
    await pump(stitch: true);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('reader-vertical-gap:0')),
      findsNothing,
      reason: 'stitched pages must not build a separator render object',
    );

    controller.requestPage(2);
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('reader-vertical-page:2')),
    );
    expect(controller.requestedIndex, isNull);
  });

  testWidgets('vertical restore starts near the saved page without mounting prefix',
      (tester) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'restore-comic',
      chapter: const Chapter(
        chapterId: 'restore-chapter',
        comicId: 'restore-comic',
        title: 'restore',
        sequence: 0,
        pageCount: 120,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        120,
        (index) => PageAsset(
          pageId: 'restore-$index',
          chapterId: 'restore-chapter',
          index: index,
          uri: Uri.parse('asset:///restore-$index.png'),
          width: 1000,
          height: 1600,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final trace = MemoryTraceSink();
    final controller = ReaderController(
      sessionId: 'reader-restore-test',
      chapter: chapter,
      initialPage: 87,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          traceSink: trace,
          verticalStitch: true,
          pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
            color: Colors.black,
            child: Text(asset.pageId),
          ),
        ),
      ),
    );
    await tester.pump();

    final mounted = trace.events
        .where((event) => event.kind == TraceEventKind.pageHostMounted)
        .map((event) => event.payload['pageIndex'])
        .whereType<int>()
        .toList(growable: false);
    expect(mounted, isNotEmpty);
    expect(mounted, everyElement(greaterThan(70)));
    expect(
      find.byKey(const ValueKey<String>('reader-vertical-page:87')),
      findsOneWidget,
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
      reason: 'the active unknown-size page must center loading in viewport',
    );

    final loader = find.byKey(
      const ValueKey<String>('reader-loading-indicator'),
    );
    expect(loader, findsOneWidget);
    expect(
      tester.getCenter(loader),
      tester.getCenter(find.byType(ReaderView)),
      reason: 'loading belongs to the viewport, not an estimated page box',
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

  testWidgets('vertical geometry updates preserve the visible scroll anchor',
      (tester) async {
    final chapter = ChapterManifest(
      sourceId: 'source',
      comicId: 'anchor-comic',
      chapter: const Chapter(
        chapterId: 'anchor-chapter',
        comicId: 'anchor-comic',
        title: 'anchor',
        sequence: 0,
        pageCount: 3,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        3,
        (index) => PageAsset(
          pageId: 'anchor-$index',
          chapterId: 'anchor-chapter',
          index: index,
          uri: Uri.parse('asset:///anchor-$index.png'),
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-anchor-test',
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
              verticalStitch: true,
              pageAspectRatios: ratios,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                color: Colors.black,
                child: Text(asset.pageId),
              ),
            ),
          ),
        );

    final initial = <String, double>{
      for (final page in chapter.pages) page.assetKey: 1.6,
    };
    await pump(initial);
    await tester.pump();
    final list = find.byKey(
      const ValueKey<String>('reader-vertical-list'),
    );
    await tester.drag(list, const Offset(0, -240));
    await tester.pump();
    final before = tester.widget<ListView>(list).controller!.offset;

    await pump(<String, double>{
      ...initial,
      chapter.pages.first.assetKey: 2.4,
    });
    await tester.pump();
    await tester.pump();
    final after = tester.widget<ListView>(list).controller!.offset;

    expect(after, greaterThan(before));
    expect(
      after,
      greaterThan(600),
      reason: 'measured geometry must not jump back to page zero center',
    );
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
