import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:telemetry/telemetry.dart';

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
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();

      expect(controller.currentIndex, 0);
      expect(lifecycle.created['page-0'], 1);
      expect(lifecycle.created['page-1'], 1);
      expect(lifecycle.disposed['page-0'] ?? 0, 0);
      expect(lifecycle.disposed['page-1'] ?? 0, 0);

      await gesture.moveBy(const Offset(-220, 0));
      await tester.pump();

      expect(controller.currentIndex, 1);
      expect(lifecycle.created['page-0'], 1);
      expect(lifecycle.created['page-1'], 1);
      expect(lifecycle.disposed['page-0'] ?? 0, 0);
      expect(lifecycle.disposed['page-1'] ?? 0, 0);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(lifecycle.created['page-1'], 1);
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
              event.kind == TraceEventKind.pageHostDisposed &&
              (event.identityHash == chapter.pages[0].assetKey ||
                  event.identityHash == chapter.pages[1].assetKey),
        ),
        isEmpty,
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

    final viewer = find.descendant(
      of: rotation,
      matching: find.byType(InteractiveViewer),
    );
    await tester.tap(viewer);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(viewer);
    await tester.pump(const Duration(milliseconds: 50));
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
      tester
          .widget<InteractiveViewer>(resetViewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      1,
    );
    // Drain the reader's own delayed single-tap window before disposal.
    await tester.pump(const Duration(milliseconds: 400));
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
