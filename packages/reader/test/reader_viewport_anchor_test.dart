import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:telemetry/telemetry.dart';

void main() {
  for (final entry in <bool>[false, true]) {
    for (final change in <String>['viewport', 'DPR', 'viewport-and-DPR', 'stitch']) {
      testWidgets(
        '${entry ? 'interior entry' : 'released slider'} keeps its center '
        'in the first $change layout',
        (tester) async {
          tester.view.physicalSize = const Size(400, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final observations = <ReaderObs>[];
          final controller = ReaderController(
            sessionId: 'viewport-anchor-$entry-$change',
            chapter: _chapter(),
            initialPage: entry ? 20 : 0,
            onObservation: observations.add,
            clock: _Clock(),
          );
          addTearDown(controller.dispose);
          final motion = <ScrollUpdateNotification>[];
          Widget view({bool stitch = true}) => MaterialApp(
                home: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (notification) {
                    motion.add(notification);
                    return false;
                  },
                  child: ReaderView(
                    controller: controller,
                    clock: _Clock(),
                    verticalStitch: stitch,
                    pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
                      key: ValueKey<String>('viewport-anchor:${asset.pageId}'),
                      color: Colors.black,
                    ),
                  ),
                ),
              );
          await tester.pumpWidget(view());
          await tester.pumpAndSettle();
          if (!entry) {
            controller.beginPageScrub();
            controller.scrubToPage(20);
            await tester.pumpAndSettle();
            controller.endPageScrub(20);
            await tester.pumpAndSettle();
          }
          final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
          final selected = find.byKey(const ValueKey<String>('viewport-anchor:page-20'));
          expect(controller.currentIndex, 20);
          expect(controller.requestedIndex, isNull);
          expect(controller.pageScrubbing, isFalse);
          expect(tester.getCenter(selected).dy, closeTo(tester.getCenter(list).dy, 0.01));
          motion.clear();
          observations.clear();

          if (change.contains('viewport')) {
            tester.view.physicalSize = const Size(800, 400);
          }
          if (change.contains('DPR')) {
            tester.view.devicePixelRatio = 1.25;
          }
          if (change == 'stitch') {
            await tester.pumpWidget(view(stitch: false));
          } else {
            await tester.pump();
          }
          expect(
            tester.getCenter(selected).dy,
            closeTo(tester.getCenter(list).dy, 0.01),
            reason: 'absolute navigation must be corrected in the changed layout',
          );
          await tester.pumpAndSettle();
          expect(controller.currentIndex, 20);
          expect(observations, isNotEmpty);
          expect(observations.last.logicalPosition, closeTo(20.5, 0.001));
          expect(observations.last.velocity, 0);
          expect(observations.last.interaction, Interaction.idle);
          expect(motion, isEmpty,
              reason: 'layout correction must not impersonate content travel');
        },
      );
    }
  }

  for (final tail in <bool>[false, true]) {
    testWidgets('DPR replacement preserves the real ${tail ? 'tail' : 'head'}',
        (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 32);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      final controller = ReaderController(
        sessionId: 'viewport-DPR-boundary-$tail',
        chapter: _chapter(),
        onObservation: (_) {},
        clock: _Clock(),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: _Clock(),
          verticalStitch: true,
          pageBuilder: (context, asset, reportFirstFrame) =>
              const ColoredBox(color: Colors.black),
        ),
      ));
      await tester.pumpAndSettle();
      if (tail) {
        controller.requestPage(39, forcePosition: true, alignment: 1);
        await tester.pumpAndSettle();
      }
      final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
      final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
      tester.view.devicePixelRatio = 1.25;
      tester.view.physicalSize = const Size(800, 400);
      await tester.pump();
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels,
          closeTo(tail ? position.maxScrollExtent : position.minScrollExtent, 0.01));
      await tester.pumpAndSettle();
      expect(controller.currentIndex, tail ? 39 : 0);
      expect(controller.lastObservation?.velocity, 0);
    });
  }

  testWidgets('content motion retires the center before viewport correction',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReaderController(
      sessionId: 'viewport-after-content-motion',
      chapter: _chapter(),
      initialPage: 20,
      onObservation: (_) {},
      clock: _Clock(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ReaderView(
        controller: controller,
        clock: _Clock(),
        verticalStitch: true,
        pageBuilder: (context, asset, reportFirstFrame) => ColoredBox(
          key: ValueKey<String>('viewport-motion:${asset.pageId}'),
          color: Colors.black,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey<String>('reader-vertical-list'));
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(425);
    await tester.pumpAndSettle();
    final topPage = find.byKey(const ValueKey<String>('viewport-motion:page-4'));
    final top = tester.getTopLeft(topPage).dy;
    tester.view.physicalSize = const Size(600, 600);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(topPage).dy, closeTo(top, 0.01));
    expect(controller.currentIndex, isNot(20));
    expect(controller.lastObservation?.velocity, 0);
  });
}

ChapterManifest _chapter() => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 0,
        pageCount: 40,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        40,
        (index) => PageAsset(
          pageId: 'page-$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('asset:///page-$index.png'),
          width: 400,
          height: 100,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 0;
}
