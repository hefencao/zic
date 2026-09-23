import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:reader/reader.dart';

class _FakeClock implements MonoClock {
  const _FakeClock();

  @override
  int nowMicros() => DateTime.now().microsecondsSinceEpoch;
}

ChapterManifest _verticalChapter(int pageCount) => ChapterManifest(
      sourceId: 'zoom-source',
      comicId: 'zoom-comic',
      chapter: Chapter(
        chapterId: 'zoom-chapter',
        comicId: 'zoom-comic',
        title: 'zoom',
        sequence: 0,
        pageCount: pageCount,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        pageCount,
        (index) => PageAsset(
          pageId: 'zoom-page-$index',
          chapterId: 'zoom-chapter',
          index: index,
          uri: Uri.parse('asset:///zoom-$index.png'),
          width: 1000,
          height: 1000,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );

double _stripScale(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .ancestor(
          of: find.byKey(const ValueKey<String>('reader-vertical-list')),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform.getMaxScaleOnAxis();
}

Matrix4 _stripMatrix(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .ancestor(
          of: find.byKey(const ValueKey<String>('reader-vertical-list')),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform;
}

ChapterManifest _pagedChapter(
  int pageCount, {
  double width = 1000,
  double height = 1000,
  bool includeDimensions = true,
}) =>
    ChapterManifest(
      sourceId: 'zoom-source',
      comicId: 'zoom-comic',
      chapter: Chapter(
        chapterId: 'zoom-chapter-paged',
        comicId: 'zoom-comic',
        title: 'zoom-paged',
        sequence: 0,
        pageCount: pageCount,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        pageCount,
        (index) => PageAsset(
          pageId: 'zoom-page-$index',
          chapterId: 'zoom-chapter-paged',
          index: index,
          uri: Uri.parse('asset:///zoom-$index.png'),
          width: includeDimensions ? width.toInt() : null,
          height: includeDimensions ? height.toInt() : null,
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );

Matrix4 _pagedTransform(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(
    find.byType(InteractiveViewer),
  );
  return viewer.transformationController!.value;
}

void main() {
  testWidgets('continuous strip double-tap zooms every page together', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-zoom',
      chapter: _verticalChapter(4),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    final scales = <double>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              zoomStageFirst: 2.5,
              zoomStageSecond: 4.0,
              onZoomScaleChanged: scales.add,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('content-${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final page = find.byKey(const ValueKey<String>('reader-vertical-page:0'));
    expect(_stripScale(tester), 1);

    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(_stripScale(tester), 2.5);
    expect(scales.last, 2.5);

    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 4.0);

    // At second stage with center anchoring the tapped page slides off the
    // viewport; double-tap an explicit on-screen point instead.
    await tester.tapAt(const Offset(350, 350));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(350, 350));
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1);
    expect(scales.last, 1);
  });

  testWidgets('continuous strip scrolling stays enabled while zoomed', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-zoom-scroll',
      chapter: _verticalChapter(6),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                color: Colors.black,
                child: Text(asset.pageId),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final page = find.byKey(const ValueKey<String>('reader-vertical-page:0'));
    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_stripScale(tester), greaterThan(1));

    // The zoom is a viewport-space layer: dragging still scrolls the strip
    // and advances the current page under the magnifier. Pointer travel is
    // inverse-transformed for the list, so fling further than one page.
    await tester.drag(find.byType(ReaderView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(controller.currentIndex, 1);
  });

  testWidgets('continuous long-press lens defaults off and opts in', (
    tester,
  ) async {
    Future<ReaderController> pumpStrip({required bool enabled}) async {
      final controller = ReaderController(
        sessionId: 'strip-lens-${enabled ? 'on' : 'off'}',
        chapter: _verticalChapter(3),
        onObservation: (_) {},
        clock: _FakeClock(),
        initialPage: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: ReaderView(
                controller: controller,
                clock: _FakeClock(),
                zoomStageFirst: 2.5,
                zoomStageSecond: 2.5,
                longPressZoomEnabled: enabled,
                longPressZoomScale: 2.5,
                pageBuilder: (context, asset, reportFirstFrame) =>
                    ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return controller;
    }

    var controller = await pumpStrip(enabled: false);
    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripScale(tester), 1);
    await gesture.up();
    await tester.pumpAndSettle();

    controller = await pumpStrip(enabled: true);
    addTearDown(controller.dispose);
    final lens = await tester.startGesture(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripScale(tester), greaterThan(2));

    await lens.moveBy(const Offset(-60, -60));
    await tester.pump();
    expect(_stripScale(tester), greaterThan(2));
    // Continuous mode keeps the strip zoom after release; there is no auto
    // restore. Double-tap cycles back to 1x.
    await lens.up();
    await tester.pumpAndSettle();
    expect(_stripScale(tester), greaterThan(2));

    // The lens panned the strip, so tap an explicit on-screen position.
    await tester.tapAt(const Offset(200, 100));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1);
  });

  Future<ReaderController> pumpPaged(
    WidgetTester tester, {
    bool restoreOnRelease = true,
    ReaderLongPressMoveMode moveMode = ReaderLongPressMoveMode.drag,
    double panRatio = 1.0,
    bool limitToViewport = true,
    double longPressScale = 4.0,
  }) async {
    final controller = ReaderController(
      sessionId: 'paged-lens',
      chapter: _pagedChapter(3),
      onObservation: (_) {},
      clock: const _FakeClock(),
      initialPage: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: const _FakeClock(),
              zoomStageFirst: 2.0,
              zoomStageSecond: 4.0,
              longPressZoomEnabled: true,
              longPressZoomScale: longPressScale,
              longPressZoomRestoreOnRelease: restoreOnRelease,
              longPressZoomMoveMode: moveMode,
              longPressZoomPanRatio: panRatio,
              longPressZoomLimitToViewport: limitToViewport,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('long-press scale is independent from double-tap stages', (
    tester,
  ) async {
    final controller = await pumpPaged(tester, longPressScale: 2.75);
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), closeTo(2.75, 0.001));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('paged long-press drag follows the zoomed resolution once', (
    tester,
  ) async {
    final controller = await pumpPaged(tester);
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);
    // Lens entry at (200, 200) with scale 4: translation (-600, -600).
    expect(_pagedTransform(tester).storage[12], -600);
    expect(_pagedTransform(tester).storage[13], -600);

    await gesture.moveBy(const Offset(8, 4));
    await tester.pump();
    await gesture.moveBy(const Offset(12, 6));
    await tester.pump();
    // Cumulative finger travel (20, 10) is applied to the entry translation
    // exactly once: (-580, -590). Compounding per-update would drift.
    expect(_pagedTransform(tester).storage[12], closeTo(-580, 0.01));
    expect(_pagedTransform(tester).storage[13], closeTo(-590, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('paged long-press drag ratio scales finger travel', (
    tester,
  ) async {
    final controller = await pumpPaged(tester, panRatio: 0.5);
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(8, 4));
    await tester.pump();
    await gesture.moveBy(const Offset(12, 6));
    await tester.pump();
    // Cumulative (20, 10) * 0.5 applied to entry (-600, -600).
    expect(_pagedTransform(tester).storage[12], closeTo(-590, 0.01));
    expect(_pagedTransform(tester).storage[13], closeTo(-595, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('paged long-press focus keeps content under the finger', (
    tester,
  ) async {
    final controller = await pumpPaged(
      tester,
      moveMode: ReaderLongPressMoveMode.focus,
    );
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(20, 10));
    await tester.pump();
    // Finger now at (220, 210); focus keeps t = p * (1 - s).
    expect(_pagedTransform(tester).storage[12], closeTo(-660, 0.01));
    expect(_pagedTransform(tester).storage[13], closeTo(-630, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('paged long-press zoom persists when restore is disabled', (
    tester,
  ) async {
    final controller = await pumpPaged(tester, restoreOnRelease: false);
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);
  });

  testWidgets('paged long-press drag can leave viewport bounds when allowed', (
    tester,
  ) async {
    final controller = await pumpPaged(tester, limitToViewport: false);
    addTearDown(controller.dispose);

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    // Entry clamp keeps the pivot reachable; a large free drag then moves
    // past the cover-clamp boundary (translation beyond -1200..0 range).
    await gesture.moveBy(const Offset(-800, 0));
    await tester.pump();
    expect(_pagedTransform(tester).storage[12], lessThan(-1200));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('strip long-press lens keeps whole-strip transform on release', (
    tester,
  ) async {
    Future<ReaderController> pumpStrip({
      ReaderLongPressMoveMode moveMode = ReaderLongPressMoveMode.drag,
      double panRatio = 1.0,
    }) async {
      final controller = ReaderController(
        sessionId: 'strip-lens-persist-$moveMode-$panRatio',
        chapter: _verticalChapter(3),
        onObservation: (_) {},
        clock: _FakeClock(),
        initialPage: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: ReaderView(
                controller: controller,
                clock: _FakeClock(),
                zoomStageFirst: 2.5,
                zoomStageSecond: 4.0,
                longPressZoomEnabled: true,
                longPressZoomScale: 2.5,
                longPressZoomMoveMode: moveMode,
                longPressZoomPanRatio: panRatio,
                pageBuilder: (context, asset, reportFirstFrame) =>
                    ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return controller;
    }

    final controller = await pumpStrip();
    addTearDown(controller.dispose);
    final lens = await tester.startGesture(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripScale(tester), greaterThan(2));
    await lens.moveBy(const Offset(-40, -20));
    await tester.pump();
    await lens.up();
    await tester.pumpAndSettle();
    // Continuous mode keeps the strip-level zoom after release so every page
    // stays magnified together; scrolling stays enabled while zoomed.
    expect(_stripScale(tester), greaterThan(2));

    // Drag mode with ratio 0.5: cumulative travel (-80, -40) maps to
    // base + (-40, -20).
    final dragController = await pumpStrip(
      panRatio: 0.5,
      moveMode: ReaderLongPressMoveMode.drag,
    );
    addTearDown(dragController.dispose);
    final drag = await tester.startGesture(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 600));
    final baseX = _stripMatrix(tester).storage[12];
    final baseY = _stripMatrix(tester).storage[13];
    await drag.moveBy(const Offset(-40, -20));
    await tester.pump();
    await drag.moveBy(const Offset(-40, -20));
    await tester.pump();
    expect(_stripMatrix(tester).storage[12], closeTo(baseX - 40, 0.01));
    // Vertical stays with native scrolling: translation.y keeps its entry.
    expect(_stripMatrix(tester).storage[13], closeTo(baseY, 0.01));
    // Release keeps the strip zoom (no auto restore in continuous mode).
    await drag.up();
    await tester.pumpAndSettle();
    expect(_stripScale(tester), greaterThan(2));

    // Focus mode: horizontal translation tracks p * (1 - s) under the
    // finger; the vertical axis stays with native scrolling and keeps its
    // entry offset.
    final focusController = await pumpStrip(
      moveMode: ReaderLongPressMoveMode.focus,
    );
    addTearDown(focusController.dispose);
    final focus = await tester.startGesture(const Offset(200, 300));
    await tester.pump(const Duration(milliseconds: 600));
    await focus.moveBy(const Offset(20, 10));
    await tester.pump();
    final scale = _stripScale(tester);
    final matrix = _stripMatrix(tester);
    expect(matrix.storage[12], closeTo(220 * (1 - scale), 0.5));
    expect(matrix.storage[13], closeTo(-450, 0.5));
    await focus.up();
    await tester.pumpAndSettle();
  });

  Future<ReaderController> pumpPagedWithOrigin(
    WidgetTester tester,
    ReaderDoubleTapZoomOrigin origin,
    {
      double width = 1000,
      double height = 1000,
    }
  ) async {
    final controller = ReaderController(
      sessionId: 'paged-origin-$origin',
      chapter: _pagedChapter(2, width: width, height: height),
      onObservation: (_) {},
      clock: const _FakeClock(),
      initialPage: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // A distinct key per segment forces a fresh ReaderView state so
          // stage cycling does not leak between origin cases.
          key: ValueKey<String>('origin-${origin.name}'),
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: const _FakeClock(),
              zoomStageFirst: 2.0,
              zoomStageSecond: 4.0,
              doubleTapZoomOrigin: origin,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('paged double-tap zoom origin modes anchor differently', (
    tester,
  ) async {
    // Stage one is 2x on a square page inside a 400x400 viewport.
    var controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.center,
    );
    addTearDown(controller.dispose);
    await tester.tapAt(const Offset(300, 150));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(300, 150));
    await tester.pumpAndSettle();
    var transform = _pagedTransform(tester);
    expect(transform.getMaxScaleOnAxis(), 2);
    // Center ignores the tap point entirely.
    expect(transform.storage[12], closeTo(-200, 0.01));
    expect(transform.storage[13], closeTo(-200, 0.01));

    controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.focus,
    );
    addTearDown(controller.dispose);
    await tester.tapAt(const Offset(300, 150));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(300, 150));
    await tester.pumpAndSettle();
    transform = _pagedTransform(tester);
    // Focus keeps the tapped content point under the finger.
    expect(transform.storage[12], closeTo(-300, 0.01));
    expect(transform.storage[13], closeTo(-150, 0.01));

    controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.snap,
    );
    addTearDown(controller.dispose);
    await tester.tapAt(const Offset(300, 150));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(300, 150));
    await tester.pumpAndSettle();
    transform = _pagedTransform(tester);
    // Tap on the right half snaps the image right edge to the viewport
    // right; tap on the upper half snaps the top edge to the top.
    expect(transform.storage[12], closeTo(-400, 0.01));
    expect(transform.storage[13], closeTo(0, 0.01));
  });

  testWidgets('paged second stage uses the current scale for its bounds', (
    tester,
  ) async {
    final controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.focus,
    );
    addTearDown(controller.dispose);

    Future<void> doubleTapAt(Offset position) async {
      await tester.tapAt(position);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(position);
      await tester.pumpAndSettle();
    }

    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).storage[12], closeTo(-200, 0.01));

    // Move the first-stage image to its right boundary before entering the
    // second stage. The center content point is x=300 at 2x, so at 4x it
    // must land at x=200 with translation -1000, not be reinterpreted from
    // the stage-one offset as if the current scale were 1x.
    await tester.drag(find.byType(InteractiveViewer), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-400, 0.01));

    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);
    expect(_pagedTransform(tester).storage[12], closeTo(-1000, 0.01));

    // The second-stage pan still honors the viewport boundary rather than
    // allowing the scaled page to disappear beyond either edge.
    await tester.drag(find.byType(InteractiveViewer), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-1200, 0.01));
  });

  testWidgets('paged boundary constraint follows the letterboxed image rect', (
    tester,
  ) async {
    // A 1:2 portrait image contain-fit in a 400x400 box leaves 100px side
    // bars; horizontal dragging must stop at the image edges, not the box.
    final controller = ReaderController(
      sessionId: 'paged-lens-letterbox',
      chapter: _pagedChapter(1, width: 500, height: 1000),
      onObservation: (_) {},
      clock: const _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: const _FakeClock(),
              zoomStageFirst: 2.0,
              zoomStageSecond: 4.0,
              longPressZoomEnabled: true,
              longPressZoomScale: 4.0,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    // Lens enters at scale 4 around the press point; the image spans
    // x [100, 300] unscaled so the valid x range is [-800, -400].
    expect(_pagedTransform(tester).storage[12], closeTo(-600, 0.01));
    expect(_pagedTransform(tester).storage[13], closeTo(-600, 0.01));

    // Cumulative travel (+400, 0): the box clamp alone would allow -200,
    // which pushes the whole image off the right edge. The image-rect clamp
    // stops at the right-flush bound.
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    expect(_pagedTransform(tester).storage[12], closeTo(-400, 0.01));

    // Vertical travel is unconstrained within the tall-image bounds.
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(_pagedTransform(tester).storage[13], closeTo(-700, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('paged second-stage drag stays inside the image rect', (
    tester,
  ) async {
    final controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.center,
      width: 500,
      height: 1000,
    );
    addTearDown(controller.dispose);

    Future<void> doubleTapAt(Offset position) async {
      await tester.tapAt(position);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(position);
      await tester.pumpAndSettle();
    }

    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 2);
    expect(_pagedTransform(tester).storage[12], closeTo(-200, 0.01));

    // At the first stage the portrait image is exactly viewport-wide, so
    // both horizontal edges coincide at the centered translation.
    await tester.drag(find.byType(InteractiveViewer), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-200, 0.01));

    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);

    // The portrait image occupies x=[100,300] at 1x, so at 4x the viewport
    // coverage range is [-800,-400], not the page-box range [-1200,0].
    await tester.drag(find.byType(InteractiveViewer), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-400, 0.01));

    await tester.drag(find.byType(InteractiveViewer), const Offset(-3000, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-800, 0.01));
  });

  testWidgets('paged second-stage fling keeps the image-rect boundary', (
    tester,
  ) async {
    final controller = await pumpPagedWithOrigin(
      tester,
      ReaderDoubleTapZoomOrigin.center,
      width: 500,
      height: 1000,
    );
    addTearDown(controller.dispose);

    Future<void> doubleTapAt(Offset position) async {
      await tester.tapAt(position);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(position);
      await tester.pumpAndSettle();
    }

    await doubleTapAt(const Offset(200, 200));
    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);

    // The page-box boundary would let the fling settle at 0. The portrait
    // image's right-flush bound at 4x is -400 and must survive inertia.
    await tester.fling(
      find.byType(InteractiveViewer),
      const Offset(200, 0),
      5000,
    );
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-400, 0.01));
  });

  testWidgets('paged boundary adopts a late decoded image aspect ratio', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'paged-late-aspect',
      chapter: _pagedChapter(
        1,
        includeDimensions: false,
      ),
      onObservation: (_) {},
      clock: const _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);

    final ratios = ValueNotifier<Map<String, double>>(
      const <String, double>{},
    );
    addTearDown(ratios.dispose);
    var pageBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: const _FakeClock(),
              pageAspectRatiosListenable: ratios,
              zoomStageFirst: 2.0,
              zoomStageSecond: 4.0,
              pageBuilder: (context, asset, reportFirstFrame) {
                pageBuilds++;
                return const ColoredBox(color: Colors.black);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    Future<void> doubleTapAt(Offset position) async {
      await tester.tapAt(position);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(position);
      await tester.pumpAndSettle();
    }

    await doubleTapAt(const Offset(200, 200));
    await doubleTapAt(const Offset(200, 200));
    expect(_pagedTransform(tester).getMaxScaleOnAxis(), 4);

    // The horizontal page initially has no source aspect, so its old fallback
    // treats the page box as the image. Feed the portrait ratio (height /
    // width) discovered after the first decoded frame and verify the next pan
    // uses x=[-800,-400].
    final buildsBeforeRatio = pageBuilds;
    ratios.value = <String, double>{
      controller.chapter.pages.single.assetKey: 2.0,
    };
    await tester.pump();
    expect(
      pageBuilds,
      buildsBeforeRatio,
      reason: 'paged ratio metadata must not rebuild page presentation',
    );
    expect(
      tester
          .widget<ReaderView>(find.byType(ReaderView))
          .pageAspectRatiosListenable
          ?.value[controller.chapter.pages.single.assetKey],
      2.0,
    );
    expect(_pagedTransform(tester).storage[12], closeTo(-600, 0.01));
    await tester.drag(find.byType(InteractiveViewer), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(_pagedTransform(tester).storage[12], closeTo(-400, 0.01));
  });

  testWidgets('strip pinch keeps its scale and offset on release', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-pinch-persist',
      chapter: _verticalChapter(3),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              zoomStageFirst: 2.5,
              zoomStageSecond: 4.0,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // A light two-finger spread ends below the old 1.15 snap-back threshold;
    // the resulting scale must persist instead of resetting to 1x.
    final first = await tester.startGesture(const Offset(180, 200));
    final second = await tester.startGesture(const Offset(220, 200));
    await tester.pump();
    await first.moveBy(const Offset(-2, 0));
    await second.moveBy(const Offset(2, 0));
    await tester.pump();
    final scaleBeforeRelease = _stripScale(tester);
    expect(scaleBeforeRelease, greaterThan(1.0));
    expect(scaleBeforeRelease, lessThan(1.15));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(_stripScale(tester), closeTo(scaleBeforeRelease, 0.001));
  });

  testWidgets('zoomed strip pans horizontally until fixed lock', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-hpan',
      chapter: _verticalChapter(3),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              longPressZoomEnabled: true,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final page = find.byKey(const ValueKey<String>('reader-vertical-page:0'));
    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1.5);

    // Before fixed-crop mode, a single-finger horizontal swipe moves the
    // whole strip and preserves its vertical entry offset.
    final beforeSwipe = _stripMatrix(tester).storage[12];
    final swipe = await tester.startGesture(const Offset(200, 200));
    await swipe.moveBy(const Offset(-60, 0));
    await tester.pump();
    await swipe.up();
    await tester.pumpAndSettle();
    expect(_stripMatrix(tester).storage[12], closeTo(beforeSwipe - 60, 0.01));

    // A later long press on the zoomed strip must not jump the scale: it
    // drags horizontally only and the offset locks again on release.
    final scaleBeforeLens = _stripScale(tester);
    final entryX = _stripMatrix(tester).storage[12];
    // Vertical finger movement stays with scrolling: translation.y is kept
    final lens = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_stripScale(tester), scaleBeforeLens);
    await lens.moveBy(const Offset(-25, 30));
    await tester.pump();
    expect(_stripMatrix(tester).storage[12], closeTo(entryX - 25, 0.01));
    // Vertical finger movement stays with scrolling: translation.y is kept
    // at its double-tap entry value (center origin, 1.5x => -100).
    expect(_stripMatrix(tester).storage[13], closeTo(-100, 0.01));
    await lens.up();
    await tester.pumpAndSettle();
    expect(_stripScale(tester), scaleBeforeLens);
    expect(_stripMatrix(tester).storage[12], closeTo(entryX - 25, 0.01));
  });

  testWidgets('strip zoom freezes deferred ratio commits until 1x', (
    tester,
  ) async {
    // Pages without manifest dimensions start on provisional extents; the
    // runtime delivers measured ratios afterwards. While the strip stays
    // zoomed those commits must NOT resize content under the magnifier.
    final controller = ReaderController(
      sessionId: 'strip-ratio-defer',
      chapter: ChapterManifest(
        sourceId: 'zoom-source',
        comicId: 'zoom-comic',
        chapter: Chapter(
          chapterId: 'zoom-chapter',
          comicId: 'zoom-comic',
          title: 'zoom',
          sequence: 0,
          pageCount: 3,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          3,
          (index) => PageAsset(
            pageId: 'zoom-page-$index',
            chapterId: 'zoom-chapter',
            index: index,
            uri: Uri.parse('asset:///zoom-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      ),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);

    var ratios = const <String, double>{};
    Future<void> repump() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: ReaderView(
                controller: controller,
                clock: _FakeClock(),
                longPressZoomEnabled: true,
                pageAspectRatios: ratios,
                pageBuilder: (context, asset, reportFirstFrame) =>
                    ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await repump();
    double pageHeight() => tester
        .getSize(find.byKey(const ValueKey<String>('reader-vertical-page:0')))
        .height;
    expect(pageHeight(), 600); // provisional unknown-ratio extent

    final page = find.byKey(const ValueKey<String>('reader-vertical-page:0'));
    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1.5);

    // Measured ratios arrive while zoomed: extents stay frozen.
    ratios = <String, double>{
      for (var i = 0; i < 3; i++) 'zoom-chapter/zoom-page-$i': 1.0,
    };
    await repump();
    expect(_stripScale(tester), 1.5);
    expect(pageHeight(), 600, reason: 'zoomed strip must not resize');

    // Returning to 1x releases the deferred commits.
    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(page, warnIfMissed: false);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(page, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1.0);
    expect(pageHeight(), 400);
  });

  testWidgets('double-tap second press held fixes horizontal offset', (
    tester,
  ) async {
    var controlToggles = 0;
    final controller = ReaderController(
      sessionId: 'strip-dt-hold',
      chapter: _verticalChapter(4),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              zoomStageFirst: 2.5,
              zoomStageSecond: 4.0,
              onTap: () => controlToggles++,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Enter the first zoom stage, then press a second time inside the
    // double-tap window and HOLD it past the long-press threshold.
    await tester.tapAt(const Offset(200, 200));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 2.5);

    final first = await tester.startGesture(const Offset(200, 200));
    await first.up();
    await tester.pump(kDoubleTapMinTime);
    final second = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 600));

    // The held second tap fixes the CURRENT stage; it must not advance to the
    // second stage, and the pending single-tap must never toggle controls.
    expect(controlToggles, 0);
    expect(_stripScale(tester), 2.5);
    expect(_stripMatrix(tester).storage[12], closeTo(-300, 0.01));
    expect(_stripMatrix(tester).storage[13], closeTo(-300, 0.01));

    // Fixed-crop mode disables horizontal dragging; vertical movement also
    // stays out of the strip transform while the hold owns the pointer.
    await second.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(_stripMatrix(tester).storage[12], closeTo(-300, 0.01));
    await second.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(_stripMatrix(tester).storage[13], closeTo(-300, 0.01));

    // Release locks both scale and offset; controls were never toggled.
    await second.up();
    await tester.pumpAndSettle();
    expect(controlToggles, 0);
    expect(_stripScale(tester), 2.5);
    expect(_stripMatrix(tester).storage[12], closeTo(-300, 0.01));

    // A subsequent ordinary double-tap exits the fixed-crop lock without
    // changing the current zoom stage.
    await tester.tapAt(const Offset(200, 200));
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 2.5);

    // Horizontal panning is available again after unlocking.
    final unlockedX = _stripMatrix(tester).storage[12];
    final unlockedSwipe = await tester.startGesture(const Offset(200, 200));
    await unlockedSwipe.moveBy(const Offset(-30, 0));
    await tester.pump();
    await unlockedSwipe.up();
    await tester.pumpAndSettle();
    expect(_stripMatrix(tester).storage[12], closeTo(unlockedX - 30, 0.01));

    // Scrolling resumes after the hold releases.
    await tester.drag(find.byType(ReaderView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(controller.currentIndex, greaterThanOrEqualTo(1));
  });

  testWidgets('rapid double-tap sequences advance monotonically', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-rapid-dt',
      chapter: _verticalChapter(4),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              zoomStageFirst: 2.5,
              zoomStageSecond: 4.0,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> doubleTap() async {
      await tester.tapAt(const Offset(200, 100));
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(const Offset(200, 100));
    }

    await doubleTap();
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 2.5);

    // Fire the next double-tap while its animation is still running, then a
    // third one mid-flight: the target-based reference must step straight to
    // the exit instead of falling back to the smaller stage.
    await doubleTap();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_stripScale(tester), greaterThan(2.5));
    expect(_stripScale(tester), lessThan(4.0));
    await doubleTap();
    await tester.pumpAndSettle();
    expect(_stripScale(tester), 1.0);
  });

  testWidgets('second-stage zoom keeps the focal content anchored', (
    tester,
  ) async {
    final controller = ReaderController(
      sessionId: 'strip-stage2-offset',
      chapter: _verticalChapter(3),
      onObservation: (_) {},
      clock: _FakeClock(),
      initialPage: 0,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: _FakeClock(),
              zoomStageFirst: 2.5,
              zoomStageSecond: 4.0,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> doubleTap() async {
      await tester.tapAt(const Offset(200, 200));
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(const Offset(200, 200));
      await tester.pumpAndSettle();
    }

    await doubleTap();
    expect(_stripScale(tester), 2.5);
    expect(_stripMatrix(tester).storage[12], closeTo(-300, 0.01));

    // Entering the second stage from the first stage's offset must divide by
    // the current scale when keeping the viewport-center content fixed:
    // t' = f - s' * ((f - o) / s) = 200 - 4 * ((200 + 300) / 2.5) = -600.
    // Reusing the stage-1 offset as if s were 1 lands out of bounds (-1200).
    await doubleTap();
    expect(_stripScale(tester), 4.0);
    expect(_stripMatrix(tester).storage[12], closeTo(-600, 0.01));
    expect(_stripMatrix(tester).storage[13], closeTo(-600, 0.01));
  });
}
