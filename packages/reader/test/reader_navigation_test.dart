import 'dart:async';

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
  for (final replaceController in <bool>[false, true]) {
    testWidgets(
      'vertical history entry keeps its center through late short-page ratios '
      '(replace controller: $replaceController)',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final base = _chapter(pageCount: 20);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = FakeClock();
        ReaderController controllerAt(int index) {
          final controller = ReaderController(
            sessionId: 'reader-history-entry-$index',
            chapter: chapter,
            initialPage: index,
            onObservation: observations.add,
            clock: clock,
          );
          addTearDown(controller.dispose);
          return controller;
        }
        final ratios = ValueNotifier<Map<String, double>>(
          const <String, double>{},
        );
        addTearDown(ratios.dispose);
        Widget view(ReaderController controller) => MaterialApp(
              home: ReaderView(
                controller: controller,
                clock: clock,
                verticalStitch: true,
                pageAspectRatiosListenable: ratios,
                pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                  key: ValueKey<String>('history-entry:${asset.pageId}'),
                  color: Colors.black,
                ),
              ),
            );
        if (replaceController) {
          await tester.pumpWidget(view(controllerAt(0)));
          await tester.pumpAndSettle();
        }
        final controller = controllerAt(2);
        await tester.pumpWidget(view(controller));
        await tester.pumpAndSettle();
        expect(controller.currentIndex, 2);
        expect(controller.requestedIndex, isNull);

        // Entry was already acknowledged against provisional viewport-sized
        // pages. Later source dimensions must preserve the requested center,
        // rather than treating that absolute entry as an ordinary top anchor.
        for (final ratio in <double>[0.75, 0.65]) {
          await tester.pump(const Duration(seconds: 1));
          ratios.value = <String, double>{
            for (final page in chapter.pages) page.assetKey: ratio,
          };
          await tester.pumpAndSettle();
          expect(controller.currentIndex, 2);
          expect(controller.requestedIndex, isNull);
          expect(observations.last.logicalPosition, closeTo(2.5, 0.001));
          expect(observations.last.velocity, closeTo(0, 0.001));
          expect(observations.last.interaction, Interaction.idle);
        }

        await tester.timedDrag(
          find.byKey(const ValueKey<String>('reader-vertical-list')),
          const Offset(0, -500),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        final movedIndex = controller.currentIndex;
        expect(movedIndex, greaterThan(2));
        final movedPage = find.byKey(ValueKey<String>(
          'history-entry:${chapter.pages[movedIndex].pageId}',
        ));
        final movedTop = tester.getTopLeft(movedPage).dy;
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages.first.assetKey: 0.5,
        };
        await tester.pumpAndSettle();
        expect(controller.currentIndex, movedIndex);
        expect(tester.getTopLeft(movedPage).dy, closeTo(movedTop, 0.5),
            reason: 'real content motion retires the entry center anchor');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final warmRatios in <bool>[false, true]) {
    testWidgets(
      'vertical entry does not manufacture idle velocity '
      '(warm ratios: $warmRatios)',
      (tester) async {
        final base = _chapter(pageCount: 8);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = FakeClock();
        final controller = ReaderController(
          sessionId: 'reader-idle-entry-velocity',
          chapter: chapter,
          initialPage: 3,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: clock,
            verticalStitch: true,
            pageAspectRatios: <String, double>{
              if (warmRatios)
                for (final page in chapter.pages) page.assetKey: 2.0,
            },
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ));
        await tester.pumpAndSettle();
        expect(controller.currentIndex, 3);
        final idle = observations.where(
          (observation) => observation.interaction == Interaction.idle,
        );
        expect(idle, isNotEmpty);
        expect(idle.map((observation) => observation.velocity),
            everyElement(closeTo(0, 1e-9)),
            reason: 'integer entry identity becoming a physical center '
                'coordinate is not content motion');

        observations.clear();
        await tester.drag(
          find.byKey(const ValueKey<String>('reader-vertical-list')),
          const Offset(0, -220),
        );
        await tester.pumpAndSettle();
        expect(observations.any((observation) =>
            observation.interaction == Interaction.dragging &&
            observation.velocity.abs() > 0.01), isTrue,
            reason: 'actual content motion still publishes measured velocity');
        expect(observations.last.interaction, Interaction.idle);
        expect(observations.last.velocity, closeTo(0, 1e-9));
      },
    );
  }

  testWidgets(
    'continuous single tap does not publish drag motion before tap resolves',
    (tester) async {
      final base = _chapter(pageCount: 4);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-single-tap-no-drag',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              onSingleTap: (_) => taps++,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      observations.clear();

      await tester.tap(
        find.byKey(const ValueKey<String>('reader-vertical-list')),
      );
      await tester.pump(const Duration(milliseconds: 320));

      expect(taps, 1);
      expect(
        observations.where(
          (item) =>
              item.interaction == Interaction.dragging ||
              item.interaction == Interaction.scrolling,
        ),
        isEmpty,
        reason:
            'tap/long-press disambiguation must not become Pipeline motion',
      );
    },
  );

  testWidgets(
    'continuous page command finishes with a stable planning observation',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-command-planning-window',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      observations.clear();

      controller.requestPage(2, animated: true);
      await tester.pumpAndSettle();

      expect(controller.currentIndex, 2);
      expect(observations, isNotEmpty);
      expect(
        observations.last.interaction,
        Interaction.idle,
        reason:
            'completed page commands must restore the normal near-page window',
      );
    },
  );

  testWidgets(
    'interrupted continuous animation does not overwrite active drag state',
    (tester) async {
      final base = _chapter(pageCount: 8);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-animation-drag-interrupt',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list =
          find.byKey(const ValueKey<String>('reader-vertical-list'));
      observations.clear();

      controller.requestViewportStep(0.9, animated: true);
      await tester.pump(const Duration(milliseconds: 24));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 24));

      expect(
        observations.any((item) => item.interaction == Interaction.dragging),
        isTrue,
        reason: 'pointer-owned motion must become the interaction authority',
      );

      await tester.pump(const Duration(milliseconds: 220));
      expect(
        observations.last.interaction,
        Interaction.dragging,
        reason:
            'the interrupted command Future may finish while the pointer is '
            'still down, but its completion must not publish idle',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'real drag retires an unfinished absolute page command',
    (tester) async {
      final base = _chapter(pageCount: 8);
      final controller = ReaderController(
        sessionId: 'reader-absolute-drag-interrupt',
        chapter: ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        ),
        onObservation: (_) {},
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          pageBuilder: (context, asset, reportFirstFrame) =>
              const ColoredBox(color: Colors.black),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
      controller.requestPage(6, animated: true);
      await tester.pump(const Duration(milliseconds: 24));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 24));
      final position = tester.state<ScrollableState>(scrollable).position;
      final draggedPixels = position.pixels;
      expect(controller.requestedIndex, isNull);

      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      expect(position.pixels, closeTo(draggedPixels, 0.01));
      expect(controller.lastObservation?.interaction, Interaction.dragging);
      expect(controller.currentIndex, lessThan(6));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continuous viewport command scrolls by a fraction of the visible screen',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-viewport-step',
        chapter: chapter,
        onObservation: observations.add,
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list =
          find.byKey(const ValueKey<String>('reader-vertical-list'));
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      final viewport = position.viewportDimension;
      observations.clear();

      controller.requestViewportStep(0.5, animated: true);
      await tester.pumpAndSettle();

      expect(position.pixels, closeTo(before + viewport * 0.5, 0.5));
      expect(controller.requestedViewportFraction, isNull);
      expect(observations, isNotEmpty);
      expect(
        observations.where(
          (item) =>
              item.interaction == Interaction.jumping ||
              item.interaction == Interaction.settling,
        ),
        isEmpty,
        reason:
            'viewport commands are execution details; Pipeline demand must '
            'follow real ScrollMetrics rather than synthetic jump states',
      );
      expect(observations.last.interaction, Interaction.idle);
    },
  );

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
    'chapter reentry reaches the requested boundary after cached ratios arrive',
    (tester) async {
      final base = _chapter(pageCount: 49);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final clock = FakeClock();
      final ratios = ValueNotifier<Map<String, double>>(<String, double>{
        for (final page in chapter.pages) page.assetKey: 1,
      });
      addTearDown(ratios.dispose);
      ReaderController controllerAt(int index) {
        final controller = ReaderController(
          sessionId: 'reader-chapter-entry-$index',
          chapter: chapter,
          initialPage: index,
          onObservation: (_) {},
          clock: clock,
        );
        addTearDown(controller.dispose);
        return controller;
      }
      Widget view(ReaderController controller) => MaterialApp(
            home: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          );

      final history = controllerAt(12);
      await tester.pumpWidget(view(history));
      await tester.pump();
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey<String>('reader-vertical-list')),
        matching: find.byType(Scrollable),
      );
      expect(history.currentIndex, 12);

      // Cached dimensions arrive after this frame's old extents have been
      // applied, before the replacement controller's initial sync. The old
      // viewport must not become the landing anchor of the new entry command.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ratios.value = <String, double>{
          for (final page in chapter.pages)
            page.assetKey: page.index == 48 ? 0.25 : 2,
        };
      });
      final previousEntry = controllerAt(48);
      await tester.pumpWidget(view(previousEntry));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump();
      }
      final end = tester.state<ScrollableState>(scrollable).position;
      expect(previousEntry.currentIndex, 48);
      expect(end.pixels, closeTo(end.maxScrollExtent, 0.01));

      final nextEntry = controllerAt(0);
      await tester.pumpWidget(view(nextEntry));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      final start = tester.state<ScrollableState>(scrollable).position;
      expect(nextEntry.currentIndex, 0);
      expect(start.pixels, closeTo(start.minScrollExtent, 0.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
      'paged chapter-boundary traversal is gated only by cross-chapter UI setting',
      (tester) async {
    final chapter = _chapter(pageCount: 2);
    final controller = ReaderController(
      sessionId: 'reader-chapter-boundary-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final crossChapter = ValueNotifier<bool>(false);
    addTearDown(crossChapter.dispose);
    final requested = <ReaderChapterBoundary>[];

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: crossChapter,
          builder: (context, enabled, _) => ReaderView(
            controller: controller,
            clock: FakeClock(),
            crossChapterReading: enabled,
            canReadNextChapter: true,
            onChapterBoundaryRequested: requested.add,
            pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
              key: ValueKey<String>('boundary:${asset.pageId}'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
    controller.requestPage(1);
    await tester.pump();
    await tester.drag(find.byType(PageView), const Offset(-360, 0));
    await tester.pump();
    expect(requested, isEmpty);

    crossChapter.value = true;
    await tester.pump();
    await tester.drag(find.byType(PageView), const Offset(-360, 0));
    await tester.pump();
    expect(requested, <ReaderChapterBoundary>[ReaderChapterBoundary.next]);
  });

  testWidgets(
      'continuous boundary shows loading feedback while next chapter is prepared',
      (tester) async {
    final base = _chapter(pageCount: 1);
    final chapter = ChapterManifest(
      sourceId: base.sourceId,
      comicId: base.comicId,
      chapter: base.chapter,
      pages: base.pages,
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-vertical-boundary-feedback-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <ReaderChapterBoundary>[];
    final completion = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: ReaderView(
            controller: controller,
            clock: FakeClock(),
            crossChapterReading: true,
            canReadNextChapter: true,
            onChapterBoundaryRequested: (boundary) {
              requested.add(boundary);
              return completion.future;
            },
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();

    final list =
        find.byKey(const ValueKey<String>('reader-vertical-list'));
    await tester.drag(list, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(requested, isEmpty);
    final scrollableFinder = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final scrollableBefore =
        tester.state<ScrollableState>(scrollableFinder);
    final pixelsBefore = scrollableBefore.position.pixels;

    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('松手加载下一章'), findsOneWidget);
    expect(requested, isEmpty);
    final scrollableWhileArmed =
        tester.state<ScrollableState>(scrollableFinder);
    expect(scrollableWhileArmed, same(scrollableBefore));
    expect(scrollableWhileArmed.position.pixels, closeTo(pixelsBefore, 0.01));

    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(requested, <ReaderChapterBoundary>[ReaderChapterBoundary.next]);
    expect(tester.takeException(), isNull);
    expect(find.text('正在加载下一章…'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey<String>('reader-chapter-boundary-next'),
      ),
      findsOneWidget,
    );

    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('正在加载下一章…'), findsNothing);
    final scrollableAfter =
        tester.state<ScrollableState>(scrollableFinder);
    expect(scrollableAfter, same(scrollableBefore));
    expect(scrollableAfter.position.pixels, closeTo(pixelsBefore, 0.01));
  });

  testWidgets('continuous start boundary keeps scrollable identity', (
    tester,
  ) async {
    final base = _chapter(pageCount: 2);
    final chapter = ChapterManifest(
      sourceId: base.sourceId,
      comicId: base.comicId,
      chapter: base.chapter,
      pages: base.pages,
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-vertical-previous-boundary-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <ReaderChapterBoundary>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: ReaderView(
            controller: controller,
            clock: FakeClock(),
            crossChapterReading: true,
            canReadPreviousChapter: true,
            onChapterBoundaryRequested: requested.add,
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();

    final list =
        find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollableFinder = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    final scrollableBefore =
        tester.state<ScrollableState>(scrollableFinder);
    expect(scrollableBefore.position.pixels, closeTo(0, 0.01));

    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    await tester.pump();

    expect(find.text('松手加载上一章'), findsOneWidget);
    final scrollableWhileArmed =
        tester.state<ScrollableState>(scrollableFinder);
    expect(scrollableWhileArmed, same(scrollableBefore));
    expect(scrollableWhileArmed.position.pixels, closeTo(0, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      requested,
      <ReaderChapterBoundary>[ReaderChapterBoundary.previous],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'continuous end boundary uses scroll geometry when final page is short',
      (tester) async {
    final base = _chapter(pageCount: 2);
    final chapter = ChapterManifest(
      sourceId: base.sourceId,
      comicId: base.comicId,
      chapter: base.chapter,
      pages: base.pages,
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-short-final-page-boundary-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <ReaderChapterBoundary>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: ReaderView(
            controller: controller,
            clock: FakeClock(),
            verticalStitch: true,
            pageAspectRatios: <String, double>{
              chapter.pages[0].assetKey: 2.0,
              chapter.pages[1].assetKey: 0.1,
            },
            crossChapterReading: true,
            canReadNextChapter: true,
            onChapterBoundaryRequested: requested.add,
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(scrollable);
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(requested, isEmpty);
    expect(
      controller.currentIndex,
      1,
      reason:
          'max extent is the final-page navigation boundary even when the '
          'viewport center still lies inside a taller previous page',
    );

    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await tester.pump();
    expect(find.text('松手加载下一章'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(requested, <ReaderChapterBoundary>[ReaderChapterBoundary.next]);
  });

  testWidgets(
    'continuous max extent reports the final page for short-page chapters',
    (tester) async {
      final base = _chapter(pageCount: 8);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-short-pages-final-current-test',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              verticalStitch: true,
              pageAspectRatios: <String, double>{
                for (final page in chapter.pages) page.assetKey: 0.25,
              },
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final list =
          find.byKey(const ValueKey<String>('reader-vertical-list'));
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.maxScrollExtent, greaterThan(0));

      state.position.jumpTo(state.position.maxScrollExtent);
      await tester.pumpAndSettle();

      expect(
        controller.currentIndex,
        chapter.pages.length - 1,
        reason:
            'the clamped end position is the final-page navigation boundary, '
            'even though the viewport center lies several short pages earlier',
      );
    },
  );

  testWidgets('idle chapter tail remains the tail when the viewport changes',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chapter = _chapter(pageCount: 8);
    final controller = ReaderController(
      sessionId: 'reader-tail-viewport-resize',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    controller.setDirection(ReadingDirection.vertical);
    addTearDown(controller.dispose);
    final ratios = ValueNotifier<Map<String, double>>(<String, double>{
      for (final page in chapter.pages) page.assetKey: 0.25,
    });
    addTearDown(ratios.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ReaderView(
        controller: controller,
        clock: FakeClock(),
        verticalStitch: true,
        pageAspectRatiosListenable: ratios,
        pageBuilder: (context, asset, reportFirstFrame) =>
            const ColoredBox(color: Colors.black),
      ),
    ));
    await tester.pumpAndSettle();
    controller.requestPage(7, forcePosition: true, alignment: 1);
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    tester.view.physicalSize = const Size(400, 500);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    expect(controller.lastObservation?.velocity, 0);
    for (final size in <Size>[
      const Size(400, 700),
      const Size(500, 700),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(controller.currentIndex, 7);
      expect(controller.lastObservation?.velocity, 0);
    }
    ratios.value = <String, double>{
      for (final page in chapter.pages) page.assetKey: 0.5,
    };
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    expect(controller.lastObservation?.velocity, 0);
  });

  testWidgets('real chapter tail includes the scroll view system insets',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chapter = _chapter(pageCount: 8);
    final controller = ReaderController(
      sessionId: 'reader-tail-system-insets',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    controller.setDirection(ReadingDirection.vertical);
    addTearDown(controller.dispose);
    final ratios = ValueNotifier<Map<String, double>>(<String, double>{
      for (final page in chapter.pages) page.assetKey: 0.25,
    });
    addTearDown(ratios.dispose);
    final insets = ValueNotifier<EdgeInsets>(
      const EdgeInsets.only(top: 36, bottom: 20),
    );
    addTearDown(insets.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => ValueListenableBuilder<EdgeInsets>(
        valueListenable: insets,
        builder: (context, padding, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: padding),
          child: child!,
        ),
      ),
      home: ReaderView(
        controller: controller,
        clock: FakeClock(),
        verticalStitch: true,
        pageAspectRatiosListenable: ratios,
        pageBuilder: (context, asset, reportFirstFrame) =>
            const ColoredBox(color: Colors.black),
      ),
    ));
    await tester.pumpAndSettle();
    controller.requestPage(7, forcePosition: true, alignment: 1);
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    ratios.value = <String, double>{
      for (final page in chapter.pages) page.assetKey: 0.5,
    };
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    tester.view.physicalSize = const Size(400, 500);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    expect(controller.lastObservation?.velocity, 0);
    insets.value = const EdgeInsets.only(top: 36, bottom: 40);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
    expect(controller.lastObservation?.velocity, 0);
    insets.value = const EdgeInsets.only(top: 36);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(controller.currentIndex, 7);
  });

  for (final initialPixels in <double>[0, 150]) {
    testWidgets('viewport resize preserves the non-tail anchor at $initialPixels',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chapter = _chapter(pageCount: 8);
      final controller = ReaderController(
        sessionId: 'reader-non-tail-viewport-resize',
        chapter: chapter,
        onObservation: (_) {},
        clock: FakeClock(),
      );
      controller.setDirection(ReadingDirection.vertical);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          verticalStitch: true,
          pageAspectRatios: <String, double>{
            for (final page in chapter.pages) page.assetKey: 0.25,
          },
          pageBuilder: (context, asset, reportFirstFrame) =>
              const ColoredBox(color: Colors.black),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(initialPixels);
      await tester.pumpAndSettle();
      expect(position.pixels, lessThan(position.maxScrollExtent));
      tester.view.physicalSize = const Size(400, 500);
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(initialPixels, 0.5));
      expect(position.pixels, lessThan(position.maxScrollExtent));
      expect(controller.lastObservation?.velocity, 0);
    });
  }

  testWidgets('a fitting chapter stays at the head when late dimensions grow',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final chapter = _chapter(pageCount: 1);
    final controller = ReaderController(
      sessionId: 'reader-fitting-chapter-dimension-growth',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    controller.setDirection(ReadingDirection.vertical);
    addTearDown(controller.dispose);
    final ratios = ValueNotifier<Map<String, double>>(<String, double>{
      chapter.pages.single.assetKey: 0.25,
    });
    addTearDown(ratios.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ReaderView(
        controller: controller,
        clock: FakeClock(),
        verticalStitch: true,
        pageAspectRatiosListenable: ratios,
        pageBuilder: (context, asset, reportFirstFrame) =>
            const ColoredBox(color: Colors.black),
      ),
    ));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, 0);
    ratios.value = <String, double>{chapter.pages.single.assetKey: 2};
    await tester.pumpAndSettle();
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, 0);
    expect(controller.currentIndex, 0);
    expect(controller.lastObservation?.velocity, 0);
  });

  testWidgets('viewport-fitting chapter chooses boundary from pull direction',
      (tester) async {
    final base = _chapter(pageCount: 1);
    final chapter = ChapterManifest(
      sourceId: base.sourceId,
      comicId: base.comicId,
      chapter: base.chapter,
      pages: base.pages,
      readingDirection: ReadingDirection.vertical,
    );
    final controller = ReaderController(
      sessionId: 'reader-fitting-chapter-boundary',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <ReaderChapterBoundary>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          verticalStitch: true,
          crossChapterReading: true,
          canReadPreviousChapter: true,
          canReadNextChapter: true,
          onChapterBoundaryRequested: requested.add,
          pageAspectRatios: <String, double>{
            chapter.pages.single.assetKey: 0.25,
          },
          pageBuilder: (context, asset, reportFirstFrame) =>
              const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = tester.state<ScrollableState>(find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    ));
    expect(scrollable.position.maxScrollExtent, 0);

    final down = await tester.startGesture(tester.getCenter(list));
    await down.moveBy(const Offset(0, 80));
    await tester.pump();
    await down.up();
    await tester.pumpAndSettle();
    expect(requested, <ReaderChapterBoundary>[ReaderChapterBoundary.previous]);

    final up = await tester.startGesture(tester.getCenter(list));
    await up.moveBy(const Offset(0, -80));
    await tester.pump();
    await up.up();
    await tester.pumpAndSettle();
    expect(requested, <ReaderChapterBoundary>[
      ReaderChapterBoundary.previous,
      ReaderChapterBoundary.next,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-page RTL maps forward boundary gesture to next chapter',
      (tester) async {
    final base = _chapter(pageCount: 1);
    final chapter = ChapterManifest(
      sourceId: base.sourceId,
      comicId: base.comicId,
      chapter: base.chapter,
      pages: base.pages,
      readingDirection: ReadingDirection.rtl,
    );
    final controller = ReaderController(
      sessionId: 'reader-single-rtl-boundary-test',
      chapter: chapter,
      onObservation: (_) {},
      clock: FakeClock(),
    );
    addTearDown(controller.dispose);
    final requested = <ReaderChapterBoundary>[];

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: FakeClock(),
          crossChapterReading: true,
          canReadPreviousChapter: true,
          canReadNextChapter: true,
          onChapterBoundaryRequested: requested.add,
          pageBuilder: (context, asset, reportFirstFrame) =>
              const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(360, 0));
    await tester.pump();
    expect(requested, <ReaderChapterBoundary>[ReaderChapterBoundary.next]);
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
            height: 1000,
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
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: ReaderView(
                controller: controller,
                clock: clock,
                pageBuilder: (context, asset, reportFirstFrame) =>
                    const Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final list = find.byKey(
        const ValueKey<String>('reader-vertical-list'),
      );
      await tester.drag(list, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 250));

      final pageFinders = <({int index, Finder finder})>[];
      for (var index = 0; index < chapter.pages.length; index++) {
        final finder = find.byKey(
          ValueKey<String>('reader-vertical-page:$index'),
          skipOffstage: false,
        );
        if (finder.evaluate().isNotEmpty) {
          pageFinders.add((index: index, finder: finder));
        }
      }
      expect(pageFinders.length, greaterThan(1));

      final listRect = tester.getRect(list);
      var visibleCount = 0;
      var offscreenCount = 0;
      for (final entry in pageFinders) {
        final tickerMode = find.descendant(
          of: entry.finder,
          matching: find.byType(TickerMode, skipOffstage: false),
        );
        expect(
          tickerMode,
          findsOneWidget,
          reason: 'every composed vertical page must have a ticker gate',
        );
        final rect = tester.getRect(entry.finder);
        final geometryVisible =
            rect.bottom > listRect.top && rect.top < listRect.bottom;
        final enabled = tester.widget<TickerMode>(tickerMode).enabled;
        if (geometryVisible) {
          visibleCount++;
          expect(
            enabled,
            isTrue,
            reason:
                'geometry-visible page ' + entry.index.toString() + ' must be allowed to tick',
          );
        } else {
          offscreenCount++;
          expect(
            enabled,
            isFalse,
            reason:
                'composed offscreen page ' + entry.index.toString() + ' must stay ticker-muted',
          );
        }
      }

      expect(visibleCount, greaterThan(0));
      expect(
        offscreenCount,
        greaterThan(0),
        reason:
            'the cacheExtent scenario must keep at least one offscreen page composed',
      );
    },
  );

  testWidgets(
    'vertical scene-motion diagnostics follow cadence opt-in',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'scene-probe-comic',
        chapter: const Chapter(
          chapterId: 'scene-probe-chapter',
          comicId: 'scene-probe-comic',
          title: 'scene probe',
          sequence: 0,
          pageCount: 12,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          12,
          (index) => PageAsset(
            pageId: 'scene-probe-$index',
            chapterId: 'scene-probe-chapter',
            index: index,
            uri: Uri.parse('asset:///scene-probe-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final trace = MemoryTraceSink();
      final controller = ReaderController(
        sessionId: 'reader-scene-probe-test',
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
            traceSink: trace,
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();

      await tester.drag(
        find.byKey(const ValueKey<String>('reader-vertical-list')),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();

      const diagnosticsEnabled = bool.fromEnvironment(
        'ZIC_READER_FRAME_CADENCE_DIAGNOSTICS',
      );
      final sceneMotionEvents = trace.events.where(
        (event) =>
            event.kind == TraceEventKind.verticalSceneMotionSummary ||
            event.kind == TraceEventKind.verticalSceneMotionOutlier,
      );
      if (diagnosticsEnabled) {
        expect(
          sceneMotionEvents,
          isNotEmpty,
          reason:
              'the explicit cadence diagnostics build must retain scene-motion sampling for investigations',
        );
      } else {
        expect(
          sceneMotionEvents,
          isEmpty,
          reason:
              'scene-motion matrix sampling is diagnostic-only and must stay disabled in normal builds',
        );
      }
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
    'live vertical ratios rebuild only when ListView geometry changes',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-local-layout-comic',
        chapter: const Chapter(
          chapterId: 'vertical-local-layout-chapter',
          comicId: 'vertical-local-layout-comic',
          title: 'vertical local layout',
          sequence: 0,
          pageCount: 6,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          6,
          (index) => PageAsset(
            pageId: 'vertical-local-layout-$index',
            chapterId: 'vertical-local-layout-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-local-layout-$index.png'),
            width: 1000,
            height: 1000,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final controller = ReaderController(
        sessionId: 'reader-vertical-local-layout-test',
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
            child: ReaderView(
              controller: controller,
              clock: FakeClock(),
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('vertical-local-layout:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final reader = find.byType(ReaderView);
      final outerLayout = find.descendant(
        of: reader,
        matching: find.byType(LayoutBuilder),
      );
      final list = find.byKey(
        const ValueKey<String>('reader-vertical-list'),
      );
      expect(outerLayout, findsOneWidget);
      expect(list, findsOneWidget);

      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -18));
      await tester.pump();

      final outerBefore = tester.widget<LayoutBuilder>(outerLayout);
      final listBefore = tester.widget<ListView>(list);

      ratios.value = <String, double>{
        chapter.pages.first.assetKey: 3.0,
      };
      await tester.pump();

      expect(
        identical(tester.widget<LayoutBuilder>(outerLayout), outerBefore),
        isTrue,
        reason:
            'a pending-only ratio fact must not dirty the whole ReaderView',
      );
      expect(
        identical(tester.widget<ListView>(list), listBefore),
        isTrue,
        reason:
            'a pending-only ratio fact must not rebuild vertical layout',
      );

      final listAfterPending = tester.widget<ListView>(list);
      ratios.value = <String, double>{
        chapter.pages.first.assetKey: 3.0,
        chapter.pages.last.assetKey: 3.0,
      };
      await tester.pump();

      expect(
        identical(tester.widget<LayoutBuilder>(outerLayout), outerBefore),
        isTrue,
        reason:
            'decode-ahead geometry must not dirty the ReaderView root',
      );
      expect(
        identical(tester.widget<ListView>(list), listAfterPending),
        isFalse,
        reason:
            'a real future extent change must rebuild the vertical layout subtree',
      );

      await gesture.up();
      await tester.pumpAndSettle();
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
    'vertical scrub adopts visible ratios before pointer up',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-scrub-ratio-comic',
        chapter: const Chapter(
          chapterId: 'vertical-scrub-ratio-chapter',
          comicId: 'vertical-scrub-ratio-comic',
          title: 'vertical scrub ratio',
          sequence: 0,
          pageCount: 4,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          4,
          (index) => PageAsset(
            pageId: 'vertical-scrub-ratio-$index',
            chapterId: 'vertical-scrub-ratio-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-scrub-ratio-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-vertical-scrub-ratio-test',
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
                key: ValueKey<String>('vertical-scrub-ratio:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.beginPageScrub();
      controller.scrubToPage(1);
      await tester.pump();
      await tester.pump();

      expect(controller.pageScrubbing, isTrue);
      expect(controller.currentIndex, 1);
      expect(observations.last.interaction, Interaction.scrubbing);
      expect(
        observations.last.visibleCoverages.map((entry) => entry.pageIndex),
        <int>[1],
        reason:
            'unknown ratios intentionally begin as one-viewport provisional extents',
      );

      observations.clear();
      ratios.value = <String, double>{
        chapter.pages[1].assetKey: 0.25,
      };
      await tester.pump();
      await tester.pump();

      expect(controller.pageScrubbing, isTrue,
          reason: 'the test has not delivered pointer-up/endPageScrub');
      expect(controller.currentIndex, 1,
          reason: 'ratio adoption must preserve the slider-selected page');
      expect(observations, isNotEmpty);
      expect(observations.last.interaction, Interaction.scrubbing);
      expect(
        observations.last.visibleCoverages.map((entry) => entry.pageIndex),
        contains(2),
        reason:
            'a short measured current page must expose and schedule the next physically visible page while the slider remains held',
      );

      controller.endPageScrub(1);
      await tester.pump();
    },
  );


  testWidgets(
    'vertical scrub keeps selected center through deferred prefix ratios',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-scrub-prefix-comic',
        chapter: const Chapter(
          chapterId: 'vertical-scrub-prefix-chapter',
          comicId: 'vertical-scrub-prefix-comic',
          title: 'vertical scrub prefix',
          sequence: 0,
          pageCount: 5,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          5,
          (index) => PageAsset(
            pageId: 'vertical-scrub-prefix-$index',
            chapterId: 'vertical-scrub-prefix-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-scrub-prefix-$index.png'),
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final controller = ReaderController(
        sessionId: 'reader-vertical-scrub-prefix-test',
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
                key: ValueKey<String>('vertical-scrub-prefix:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.beginPageScrub();
      controller.scrubToPage(2);
      await tester.pump();
      await tester.pump();
      expect(controller.currentIndex, 2);

      observations.clear();
      ratios.value = <String, double>{
        chapter.pages[1].assetKey: 0.25,
        chapter.pages[2].assetKey: 0.25,
      };
      // The selected page shrinks first. That exposes page 1, whose ratio was
      // already known in the same update even though it was outside the old
      // provisional viewport. Drain the held-scrub geometry convergence.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(controller.pageScrubbing, isTrue);
      expect(controller.currentIndex, 2);
      expect(observations.last.interaction, Interaction.scrubbing);
      expect(
        observations.last.visibleCoverages.map((entry) => entry.pageIndex),
        containsAll(<int>[1, 2, 3]),
      );
      final held = observations.lastWhere(
        (item) =>
            item.interaction == Interaction.scrubbing &&
            item.currentIndex == 2,
      );
      expect(
        held.logicalPosition,
        closeTo(2.5, 0.001),
        reason:
            'the final held-scrub observation must publish the corrected '
            'physical center after deferred prefix-ratio convergence',
      );
      expect(
        held.velocity,
        closeTo(0, 0.001),
        reason:
            'absolute slider jumps must not teach continuous travel direction',
      );

      controller.endPageScrub(2);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(controller.pageScrubbing, isFalse);
      expect(
        controller.currentIndex,
        2,
        reason:
            'pointer-up must not switch from the slider-selected page center '
            'to an idle top-of-viewport geometry anchor',
      );
      final released = observations.lastWhere(
        (item) =>
            item.interaction == Interaction.idle &&
            item.currentIndex == 2,
      );
      expect(released.logicalPosition, closeTo(held.logicalPosition, 0.001));
      expect(
        released.velocity,
        closeTo(0, 0.001),
        reason:
            'pointer-up after deferred ratio convergence must not manufacture '
            'travel from a stale pre-correction observation',
      );
    },
  );


  for (final releaseBeforeLayout in <bool>[false, true]) {
    testWidgets(
      'released vertical scrub keeps its center through late ratios '
      '(pending layout: $releaseBeforeLayout)',
      (tester) async {
        final chapter = ChapterManifest(
          sourceId: 'source',
          comicId: 'vertical-released-scrub-comic',
          chapter: const Chapter(
            chapterId: 'vertical-released-scrub-chapter',
            comicId: 'vertical-released-scrub-comic',
            title: 'vertical released scrub',
            sequence: 0,
            pageCount: 8,
            sourceRevision: 'r1',
          ),
          pages: List<PageAsset>.generate(
            8,
            (index) => PageAsset(
              pageId: 'vertical-released-scrub-$index',
              chapterId: 'vertical-released-scrub-chapter',
              index: index,
              uri: Uri.parse('asset:///vertical-released-scrub-$index.png'),
            ),
          ),
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = FakeClock();
        final controller = ReaderController(
          sessionId: 'reader-vertical-released-scrub-test',
          chapter: chapter,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        final ratios = ValueNotifier<Map<String, double>>(
          const <String, double>{},
        );
        addTearDown(ratios.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderView(
              controller: controller,
              clock: clock,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                key: ValueKey<String>('released-scrub:${asset.pageId}'),
                color: Colors.black,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        controller.beginPageScrub();
        controller.scrubToPage(3);
        if (!releaseBeforeLayout) {
          await tester.pump();
          await tester.pump();
        }
        controller.endPageScrub(3);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(controller.pageScrubbing, isFalse);
        expect(observations.last.interaction, Interaction.idle);
        expect(controller.currentIndex, 3);

        await tester.pump(const Duration(seconds: 2));
        ratios.value = <String, double>{chapter.pages[3].assetKey: 0.25};
        await tester.pump();
        await tester.pump();
        expect(controller.currentIndex, 3,
            reason: 'the first measurement can arrive after pointer-up');
        expect(observations.last.logicalPosition, closeTo(3.5, 0.001));
        expect(observations.last.velocity, closeTo(0, 0.001));
        expect(observations.last.interaction, Interaction.idle);

        await tester.pump(const Duration(seconds: 1));
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages[2].assetKey: 0.25,
          chapter.pages[4].assetKey: 0.25,
        };
        await tester.pump();
        await tester.pump();
        expect(controller.currentIndex, 3);
        expect(observations.last.logicalPosition, closeTo(3.5, 0.001));
        expect(observations.last.velocity, closeTo(0, 0.001));

        await tester.drag(find.byType(ReaderView), const Offset(0, -500));
        await tester.pumpAndSettle();
        final movedIndex = controller.currentIndex;
        expect(movedIndex, greaterThan(3));
        final movedTop = tester.getTopLeft(
          find.byKey(ValueKey<String>(
            'released-scrub:${chapter.pages[movedIndex].pageId}',
          )),
        ).dy;
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages[1].assetKey: 0.25,
        };
        await tester.pump();
        await tester.pump();
        expect(controller.currentIndex, movedIndex,
            reason: 'content dragging retires the absolute scrub anchor');
        expect(
          tester.getTopLeft(find.byKey(ValueKey<String>(
            'released-scrub:${chapter.pages[movedIndex].pageId}',
          ))).dy,
          closeTo(movedTop, 0.5),
        );
      },
    );
  }


  testWidgets(
    'vertical scrub release preserves physical logical position and zero phase velocity',
    (tester) async {
      final chapter = ChapterManifest(
        sourceId: 'source',
        comicId: 'vertical-scrub-logical-comic',
        chapter: const Chapter(
          chapterId: 'vertical-scrub-logical-chapter',
          comicId: 'vertical-scrub-logical-comic',
          title: 'vertical scrub logical',
          sequence: 0,
          pageCount: 4,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          4,
          (index) => PageAsset(
            pageId: 'vertical-scrub-logical-$index',
            chapterId: 'vertical-scrub-logical-chapter',
            index: index,
            uri: Uri.parse('asset:///vertical-scrub-logical-$index.png'),
            width: 400,
            height: 400,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-vertical-scrub-logical-test',
        chapter: chapter,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              pageAspectRatios: <String, double>{
                for (final page in chapter.pages) page.assetKey: 1,
              },
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.beginPageScrub();
      controller.scrubToPage(1);
      await tester.pump();
      await tester.pump();

      final held = observations.lastWhere(
        (item) =>
            item.interaction == Interaction.scrubbing &&
            item.currentIndex == 1,
      );
      expect(
        held.logicalPosition,
        closeTo(1.5, 0.001),
        reason:
            'slider selection owns current identity, but logical position must '
            'remain the physical viewport-center coordinate',
      );

      observations.clear();
      controller.endPageScrub(1);
      await tester.pump();
      await tester.pump();

      final released = observations.lastWhere(
        (item) =>
            item.interaction == Interaction.idle &&
            item.currentIndex == 1,
      );
      expect(released.logicalPosition, closeTo(held.logicalPosition, 0.001));
      expect(
        released.velocity,
        closeTo(0, 0.001),
        reason:
            'ending scrub without physical motion must not manufacture travel '
            'direction from a navigation-phase coordinate change',
      );
    },
  );


  testWidgets(
    'vertical scrub release before final layout exits preview without another scroll',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-scrub-pending-release',
        chapter: chapter,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderView(
            controller: controller,
            clock: clock,
            pageAspectRatios: <String, double>{
              for (final page in chapter.pages) page.assetKey: 1,
            },
            pageBuilder: (context, asset, reportFirstFrame) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      observations.clear();

      // The final jump is already physical, but its post-frame observation has
      // not updated currentIndex. Pointer-up therefore requests the same offset
      // again; that no-op jump cannot supply a ScrollEnd notification.
      controller.beginPageScrub();
      controller.scrubToPage(3);
      expect(controller.currentIndex, 0);
      expect(controller.requestedIndex, 3);
      controller.endPageScrub(3);
      await tester.pump();
      await tester.pump();

      expect(controller.pageScrubbing, isFalse);
      expect(controller.currentIndex, 3);
      expect(observations.last.interaction, Interaction.idle);
      expect(observations.last.logicalPosition, closeTo(3.5, 0.001));
      expect(observations.last.velocity, closeTo(0, 0.001));
      expect(controller.requestedIndex, isNull);

      // Pointer-up may also flush a different final target. Its jump must not
      // turn absolute slider travel into a learned content-scroll velocity.
      observations.clear();
      controller.beginPageScrub();
      controller.scrubToPage(2);
      controller.endPageScrub(4);
      await tester.pump();
      await tester.pump();
      expect(controller.currentIndex, 4);
      expect(observations.last.interaction, Interaction.idle);
      expect(observations.last.logicalPosition, closeTo(4.5, 0.001));
      expect(observations.last.velocity, closeTo(0, 0.001));
      expect(
        observations
            .where((item) => item.currentIndex == 4 &&
                item.interaction == Interaction.idle)
            .map((item) => item.velocity),
        everyElement(closeTo(0, 0.001)),
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
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();

      expect(controller.lastObservation?.interaction, Interaction.dragging);

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
    'post-frame prefix adoption observes only geometry applied to scroll metrics',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-post-frame-prefix',
        chapter: chapter,
        initialPage: 3,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages.first.assetKey: 3.0,
      };
      await tester.pump();
      // Reversal schedules the already-known prefix adoption at frame end.
      // A later observation callback in that same frame still has old pixels.
      await gesture.moveBy(const Offset(0, 30));
      final before = observations.last.logicalPosition;
      final page = find.byKey(
        const ValueKey<String>('reader-vertical-page:3'),
        skipOffstage: false,
      );
      final topBefore = tester.getTopLeft(page).dy;
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      ScrollUpdateNotification(
        metrics: scrollable.position,
        context: tester.element(list),
        scrollDelta: 0,
      ).dispatch(tester.element(list));
      observations.clear();
      await tester.pump();
      await tester.pump();
      expect(observations, isNotEmpty);
      expect(
        observations.map((observation) => observation.logicalPosition),
        everyElement(closeTo(before, 0.001)),
        reason: 'new prefix extents at old pixels must never be published '
            'as a transient page jump or reverse velocity',
      );
      expect(tester.getTopLeft(page).dy, closeTo(topBefore + 30, 0.001));
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  for (final head in <bool>[true, false]) {
    testWidgets(
      'vertical ${head ? 'head' : 'tail'} navigation keeps physical motion continuous',
      (tester) async {
        final base = _chapter(pageCount: 8);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = _ControlledClock();
        final controller = ReaderController(
          sessionId: 'reader-endpoint-motion-${head ? 'head' : 'tail'}',
          chapter: chapter,
          initialPage: 4,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ReaderView(
                controller: controller,
                clock: clock,
                verticalStitch: true,
                pageAspectRatios: <String, double>{
                  for (final page in chapter.pages) page.assetKey: 0.25,
                },
                pageBuilder: (context, asset, reportFirstFrame) =>
                    const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        );
        final position = scrollable.position;
        position.jumpTo(head
            ? position.minScrollExtent + 30
            : position.maxScrollExtent - 30);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 16000;
        await gesture.moveBy(Offset(0, head ? 24 : -24));
        final priorPixels = position.pixels;
        expect(priorPixels, greaterThan(position.minScrollExtent));
        expect(priorPixels, lessThan(position.maxScrollExtent));
        clock.micros = 32000;
        await gesture.moveBy(Offset(0, head ? 48 : -48));
        final endpointPixels = position.pixels;
        expect(endpointPixels,
            head ? position.minScrollExtent : position.maxScrollExtent);
        final endpoint = observations.last;
        expect(endpoint.interaction, Interaction.dragging);
        expect(endpoint.currentIndex, head ? 0 : 7);
        expect(endpoint.logicalPosition, head ? 0 : 7);
        expect(endpoint.velocity,
            closeTo((endpointPixels - priorPixels) / 100 / 0.016, 0.001),
            reason: 'semantic first/last page identity is not physical displacement');

        clock.micros = 48000;
        await gesture.moveBy(Offset(0, head ? -12 : 12));
        expect(observations.last.velocity,
            closeTo((position.pixels - endpointPixels) / 100 / 0.016, 0.001),
            reason: 'leaving the endpoint must use the same physical baseline');
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'pointer drag promotion preserves the real content sampling interval',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = _ControlledClock();
      final controller = ReaderController(
        sessionId: 'reader-pointer-promotion-motion-clock',
        chapter: chapter,
        initialPage: 3,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatios: <String, double>{
                for (final page in chapter.pages) page.assetKey: 1.5,
              },
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      final before = observations.last;
      clock.micros = 16000;
      await gesture.moveBy(const Offset(0, 100));
      final motion = observations.last;
      expect(motion.interaction, Interaction.dragging);
      final expected = (motion.logicalPosition - before.logicalPosition) / 0.016;
      expect(expected, lessThan(0));
      expect(motion.velocity, closeTo(expected, 0.001),
        reason: 'raw pointer phase promotion and the ScrollUpdate from the '
            'same input must not become two physical movement samples');
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  for (final delta in <double>[-8, 8]) {
    testWidgets(
      'drag velocity uses input timestamps across bunched delivery ($delta)',
      (tester) async {
        final base = _chapter(pageCount: 6);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = _ControlledClock();
        final controller = ReaderController(
          sessionId: 'reader-bunched-input-motion-clock',
          chapter: chapter,
          initialPage: 3,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        final ratios = ValueNotifier<Map<String, double>>(
          <String, double>{
            for (final page in chapter.pages) page.assetKey: 1.5,
          },
        );
        addTearDown(ratios.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ReaderView(
                controller: controller,
                clock: clock,
                verticalStitch: true,
                pageAspectRatiosListenable: ratios,
                pageBuilder: (context, asset, reportFirstFrame) =>
                    const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
        final gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 16000;
        await gesture.moveBy(Offset(0, delta * 12.5),
          timeStamp: const Duration(microseconds: 1016000));
        await tester.pump();
        var prior = observations.last.logicalPosition;

        // One input waits longer in delivery; the following input catches up.
        // Their source timestamps remain16ms apart in their own time domain.
        clock.micros = 45000;
        await gesture.moveBy(Offset(0, delta),
          timeStamp: const Duration(microseconds: 1032000));
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - prior) / 0.016, 0.001),
            reason: 'delivery latency must not change measured input speed');
        prior = observations.last.logicalPosition;
        final velocity = observations.last.velocity;
        clock.micros = 45500;
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages.last.assetKey: 3.0,
        };
        await tester.pump();
        expect(observations.last.logicalPosition, closeTo(prior, 0.001));
        expect(observations.last.velocity, closeTo(velocity, 0.001));
        clock.micros = 46000;
        await gesture.moveBy(Offset(0, delta),
          timeStamp: const Duration(microseconds: 1048000));
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - prior) / 0.016, 0.001),
            reason: 'bunched callbacks must not compress16ms input to1ms');
        prior = observations.last.logicalPosition;
        final priorVelocity = observations.last.velocity;
        // A backdated source event can rewind the physical viewport shortly
        // after the latest real input. Coverage must stay current, but elapsed
        // source time is invalid for another motion derivative.
        clock.micros = 49000;
        await gesture.moveBy(Offset(0, -delta),
          timeStamp: const Duration(microseconds: 1047600));
        expect(observations.last.logicalPosition,
            delta > 0 ? greaterThan(prior) : lessThan(prior),
            reason: 'physical coverage must still observe the rewind');
        expect(observations.last.velocity, closeTo(priorVelocity, 0.001),
            reason: 'a source timestamp rewind must not manufacture a3ms '
                'opposite-direction derivative');
        clock.micros = 64000;
        await gesture.moveBy(Offset(0, delta * 2),
          timeStamp: const Duration(microseconds: 1064000));
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - prior) / 0.016, 0.001),
            reason: 'the next valid input must keep the last increasing '
                'source position and timestamp baseline');
        await gesture.up();
        await tester.pumpAndSettle();
        final idlePosition = observations.last.logicalPosition;
        expect(observations.last.interaction, Interaction.idle);
        clock.micros = 80000;
        final nextGesture =
            await tester.startGesture(tester.getCenter(list));
        await nextGesture.moveBy(Offset(0, delta * 12.5),
          timeStamp: const Duration(microseconds: 2016000));
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - idlePosition) / 0.016,
                0.001),
            reason: 'a new gesture has no preceding source input sample; '
                'idle must retire the old input timestamp');
        await nextGesture.up();
        await tester.pumpAndSettle();
        clock.micros = 250000;
        await tester.fling(list, Offset(0, delta * 25), 1000);
        final beforeInterruption = observations.last.logicalPosition;
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.isScrollingNotifier.value, isTrue,
            reason: 'the next gesture interrupts before the first ballistic tick');
        clock.micros = 266000;
        final interruptingGesture =
            await tester.startGesture(tester.getCenter(list));
        await interruptingGesture.moveBy(Offset(0, delta * 12.5),
          timeStamp: const Duration(microseconds: 3016000));
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - beforeInterruption) /
                0.016, 0.001),
            reason: 'a new scroll activity must retire the old source timestamp '
                'even when idle observation has not run');
        await interruptingGesture.up();
        await tester.pumpAndSettle();
      },
    );
  }

  for (final delta in <double>[-100, 100]) {
    testWidgets(
      'idle prefix correction preserves the next drag and read-only timing '
      '(delta: $delta)',
      (tester) async {
        final base = _chapter(pageCount: 8);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = _ControlledClock();
        final timings = _TestFrameTimingSource();
        final controller = ReaderController(
          sessionId: 'reader-idle-prefix-motion-handoff',
          chapter: chapter,
          initialPage: 3,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        final ratios = ValueNotifier<Map<String, double>>(<String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        });
        addTearDown(ratios.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Center(child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              frameTimingSource: timings,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          )),
        ));
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
        final page = find.byKey(
          const ValueKey<String>('reader-vertical-page:3'),
          skipOffstage: false,
        );
        var gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 16000;
        await gesture.moveBy(const Offset(0, -100));
        await tester.pump();
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages[0].assetKey: .75,
          chapter.pages[1].assetKey: .75,
        };
        expect(observations.last.interaction, Interaction.dragging);
        clock.micros = 32000;
        await gesture.up();
        expect(observations.last.interaction, Interaction.idle);
        await tester.pump();
        // Idle has prepared the changed prefix; its layout applies next frame.
        // Reading timing context must not freeze the target before new input.
        final top = tester.getTopLeft(page).dy;
        final position = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        ).position;
        final pixels = position.pixels;
        timings.emit(const <ReaderFrameTimingSample>[
          ReaderFrameTimingSample(
            buildMicros: 22000,
            rasterMicros: 3000,
            totalSpanMicros: 26000,
            vsyncOverheadMicros: 400,
            vsyncStartMicros: 100000,
            frameIntervalMicros: 16667,
          ),
        ]);
        gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 48000;
        await gesture.moveBy(Offset(0, delta),
          timeStamp: const Duration(microseconds: 1016000));
        final movement = position.pixels - pixels;
        expect(movement.abs(), greaterThan(0));
        final prior = observations.last.logicalPosition;
        await tester.pump();
        expect(tester.getTopLeft(page).dy, closeTo(top - movement, .001),
            reason: 'prefix compensation and intervening physical motion '
                'must apply atomically through repeated layout passes');
        final appliedPixels = position.pixels;
        await tester.pump();
        expect(position.pixels, closeTo(appliedPixels, .001));
        clock.micros = 64000;
        await gesture.moveBy(Offset(0, delta * .08),
          timeStamp: const Duration(microseconds: 1032000));
        expect(position.pixels, closeTo(appliedPixels - delta * .08, .001),
            reason: 'the applied correction must not swallow later motion');
        expect(observations.last.velocity,
            closeTo((observations.last.logicalPosition - prior) / .016, .001));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final delta in <double>[-40, 40]) {
    testWidgets(
      'visible ratio handoff rebases motion without consuming its input interval '
      '(delta: $delta)',
      (tester) async {
        final base = _chapter(pageCount: 8);
        final chapter = ChapterManifest(
          sourceId: base.sourceId,
          comicId: base.comicId,
          chapter: base.chapter,
          pages: base.pages,
          readingDirection: ReadingDirection.vertical,
        );
        final observations = <ReaderObs>[];
        final clock = _ControlledClock();
        final controller = ReaderController(
          sessionId: 'reader-visible-ratio-motion-handoff',
          chapter: chapter,
          initialPage: 3,
          onObservation: observations.add,
          clock: clock,
        );
        addTearDown(controller.dispose);
        final ratios = ValueNotifier<Map<String, double>>(<String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        });
        addTearDown(ratios.dispose);
        await tester.pumpWidget(MaterialApp(
          home: Center(child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          )),
        ));
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
        final page = find.byKey(
          const ValueKey<String>('reader-vertical-page:3'),
          skipOffstage: false,
        );
        var gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 16000;
        await gesture.moveBy(const Offset(0, 100));
        await tester.pump();
        ratios.value = <String, double>{
          ...ratios.value,
          chapter.pages[0].assetKey: .75,
          chapter.pages[3].assetKey: .75,
        };
        expect(tester.getSize(page).height, 600);
        clock.micros = 32000;
        await gesture.up();
        await tester.pump();
        // The idle commit changes a visible extent as well as the prefix.
        // The next gesture starts before that revision applies.
        gesture = await tester.startGesture(tester.getCenter(list));
        clock.micros = 48000;
        await gesture.moveBy(Offset(0, delta),
          timeStamp: const Duration(microseconds: 1016000));
        await tester.pump();
        final height = tester.getSize(page).height;
        expect(height, 300);
        final top = tester.getTopLeft(page).dy;
        clock.micros = 80000;
        await tester.pump();
        clock.micros = 81000;
        await gesture.moveBy(Offset(0, delta * .2),
          timeStamp: const Duration(microseconds: 1032000));
        expect(observations.last.velocity,
            closeTo(-delta * .2 / height / .016, .001),
            reason: 'different logical center coordinates across a geometry '
                'revision are not real displacement; layout must retain '
                'the16ms source input interval');
        await tester.pump();
        expect(tester.getTopLeft(page).dy, closeTo(top + delta * .2, .001));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'active prefix layout refresh preserves the content motion sampling interval',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = _ControlledClock();
      final controller = ReaderController(
        sessionId: 'reader-prefix-motion-clock',
        chapter: chapter,
        initialPage: 3,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      clock.micros = 16000;
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      clock.micros = 32000;
      await gesture.moveBy(const Offset(0, 8));
      final lastMotion = observations.last.logicalPosition;
      final lastVelocity = observations.last.velocity;
      expect(observations.last.velocity, lessThan(0));

      // A header arrives between two input samples, shortly before the next
      // input. Applying its prefix correction does not move the visible page.
      clock.micros = 47500;
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages.first.assetKey: 3.0,
      };
      await tester.pump();
      expect(observations.last.logicalPosition, closeTo(lastMotion, 0.001));
      expect(observations.last.velocity, closeTo(lastVelocity, 0.001));
      clock.micros = 48000;
      await gesture.moveBy(const Offset(0, 8));
      final motion = observations.last;
      final expected = (motion.logicalPosition - lastMotion) / 0.016;
      expect(motion.velocity, closeTo(expected, 0.001),
        reason: 'the geometry callback is not a new content input sample; '
            'it must not shorten the16ms motion interval to500us');
      expect(motion.velocity, lessThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'direct drag retires a queued ballistic motion sampling request',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = _ControlledClock();
      final controller = ReaderController(
        sessionId: 'reader-superseded-ballistic-motion-clock',
        chapter: chapter,
        initialPage: 3,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      clock.micros = 16000;
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      // An earlier non-drag scroll notification requested a coalesced sample.
      // A new direct drag samples the current physical position before that
      // callback runs, so the earlier sampling request has been consumed.
      clock.micros = 31500;
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      ScrollUpdateNotification(
        metrics: scrollable.position,
        context: tester.element(list),
        scrollDelta: 0,
      ).dispatch(tester.element(list));
      clock.micros = 32000;
      await gesture.moveBy(const Offset(0, 8));
      final lastMotion = observations.last.logicalPosition;
      final lastVelocity = observations.last.velocity;
      expect(observations.last.velocity, lessThan(0));

      // A header arrives between two input samples, shortly before the next
      // input. Applying its prefix correction does not move the visible page.
      clock.micros = 47500;
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages.first.assetKey: 3.0,
      };
      await tester.pump();
      expect(observations.last.logicalPosition, closeTo(lastMotion, 0.001));
      expect(observations.last.velocity, closeTo(lastVelocity, 0.001));
      clock.micros = 48000;
      await gesture.moveBy(const Offset(0, 8));
      final motion = observations.last;
      final expected = (motion.logicalPosition - lastMotion) / 0.016;
      expect(motion.velocity, closeTo(expected, 0.001),
        reason: 'the geometry callback is not a new content input sample; '
            'it must not shorten the16ms motion interval to500us');
      expect(motion.velocity, lessThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'ballistic motion still samples velocity through coalesced layout observations',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final observations = <ReaderObs>[];
      final clock = _ControlledClock();
      final controller = ReaderController(
        sessionId: 'reader-ballistic-motion-clock',
        chapter: chapter,
        initialPage: 3,
        onObservation: observations.add,
        clock: clock,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      clock.micros = 250000;
      await tester.fling(list, const Offset(0, -200), 1000);
      clock.micros += 16000;
      await tester.pump(const Duration(milliseconds: 16));
      var prior = observations.last;
      for (var frame = 0; frame < 4; frame++) {
        clock.micros += 16000;
        if (frame == 1) {
          ratios.value = <String, double>{
            ...ratios.value,
            chapter.pages.last.assetKey: 3.0,
          };
        }
        await tester.pump(const Duration(milliseconds: 16));
        final motion = observations.last;
        expect(motion.interaction, Interaction.scrolling);
        final seconds =
            (motion.monotonicMicros - prior.monotonicMicros) / 1000000.0;
        expect(seconds, greaterThan(0));
        final expected =
            (motion.logicalPosition - prior.logicalPosition) / seconds;
        expect(expected, greaterThan(0));
        expect(motion.velocity, closeTo(expected, 0.001),
          reason: 'coalescing must retain a real ballistic sampling request '
              'when geometry also schedules an observation');
        prior = motion;
      }
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'multiple active prefix measurements share the physically applied anchor',
    (tester) async {
      final base = _chapter(pageCount: 6);
      final chapter = ChapterManifest(
        sourceId: base.sourceId,
        comicId: base.comicId,
        chapter: base.chapter,
        pages: base.pages,
        readingDirection: ReadingDirection.vertical,
      );
      final clock = FakeClock();
      final controller = ReaderController(
        sessionId: 'reader-multiple-prefix-measurements',
        chapter: chapter,
        initialPage: 3,
        onObservation: (_) {},
        clock: clock,
      );
      addTearDown(controller.dispose);
      final ratios = ValueNotifier<Map<String, double>>(
        <String, double>{
          for (final page in chapter.pages) page.assetKey: 1.5,
        },
      );
      addTearDown(ratios.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ReaderView(
              controller: controller,
              clock: clock,
              verticalStitch: true,
              pageAspectRatiosListenable: ratios,
              pageBuilder: (context, asset, reportFirstFrame) =>
                  const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      final page = find.byKey(
        const ValueKey<String>('reader-vertical-page:3'),
        skipOffstage: false,
      );
      final topBefore = tester.getTopLeft(page).dy;
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages[0].assetKey: 3.0,
      };
      ratios.value = <String, double>{
        ...ratios.value,
        chapter.pages[1].assetKey: 3.0,
      };
      await tester.pump();
      expect(
        tester.getTopLeft(page).dy,
        closeTo(topBefore, 0.001),
        reason: 'back-to-back header facts must accumulate prefix correction '
            'against the geometry belonging to the current physical pixels',
      );
      expect(controller.currentIndex, 3);
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

final class _ControlledClock implements MonoClock {
  int micros = 0;

  @override
  int nowMicros() => micros;
}
