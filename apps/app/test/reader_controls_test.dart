import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:zic/reader_runtime.dart';

const _screenKey = ValueKey<String>('reader-controls-screen');

ChapterManifest _chapter() {
  return ChapterManifest(
    sourceId: 'reader-controls-source',
    comicId: 'reader-controls-comic',
    chapter: const Chapter(
      chapterId: 'reader-controls-chapter',
      comicId: 'reader-controls-comic',
      title: '控制栏测试章节',
      sequence: 1,
      pageCount: 3,
      sourceRevision: 'reader-controls-r1',
    ),
    pages: List<PageAsset>.generate(
      3,
      (index) => PageAsset(
        pageId: 'reader-controls-page-$index',
        chapterId: 'reader-controls-chapter',
        index: index,
        uri: Uri.parse(
          'assets/demo/pages/${(index + 1).toString().padLeft(3, '0')}.png',
        ),
        contentKindHint: ContentKindHint.png,
      ),
    ),
    readingDirection: ReadingDirection.ltr,
  );
}

IgnorePointer _controlsPointer(WidgetTester tester, Finder controls) {
  final pointer = find.ancestor(
    of: controls,
    matching: find.byType(IgnorePointer),
  );
  return tester.widget<IgnorePointer>(pointer.first);
}

const _frameStep = Duration(milliseconds: 20);

Future<void> _pumpUntilControls(
  WidgetTester tester,
  Finder top,
  Finder bottom, {
  required bool ignoring,
  int maxFrames = 40,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(_frameStep);
    if (_controlsPointer(tester, top).ignoring == ignoring &&
        _controlsPointer(tester, bottom).ignoring == ignoring) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for reader controls ignoring=$ignoring');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 40,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(_frameStep);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  testWidgets('reader starts immersive and exposes complete bottom controls',
      (tester) async {
    bool? favorite;
    var downloadRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderRuntimeScreen(
          chapter: _chapter(),
          screenKey: _screenKey,
          initialFavorite: false,
          onFavoriteChanged: (value) async => favorite = value,
          onDownloadRequested: () async => downloadRequested = true,
          artifactPageBuilder: (
            context,
            asset,
            reportFirstFrame,
            runtime,
          ) => ColoredBox(
            key: ValueKey<String>('reader-control-page:${asset.index}'),
            color: Colors.black,
          ),
        ),
      ),
    );
    await tester.pump();

    final top = find.byKey(readerTopControlsKey);
    final bottom = find.byKey(readerBottomControlsKey);
    expect(top, findsOneWidget);
    expect(bottom, findsOneWidget);
    expect(_controlsPointer(tester, top).ignoring, isTrue);
    expect(_controlsPointer(tester, bottom).ignoring, isTrue);

    await tester.tap(find.byType(ReaderView));
    await _pumpUntilControls(
      tester,
      top,
      bottom,
      ignoring: false,
    );
    expect(_controlsPointer(tester, top).ignoring, isFalse);
    expect(_controlsPointer(tester, bottom).ignoring, isFalse);
    expect(find.byKey(readerPageSliderKey), findsOneWidget);
    expect(find.byKey(readerPauseKey), findsOneWidget);
    expect(find.byKey(readerSpeedKey), findsOneWidget);
    expect(find.byKey(readerRotateKey), findsOneWidget);
    expect(find.byKey(readerFavoriteKey), findsOneWidget);
    expect(find.byKey(readerDownloadKey), findsOneWidget);

    await _pumpUntilFound(tester, find.byKey(readerPauseKey).hitTestable());
    await tester.tap(find.byKey(readerPauseKey).hitTestable());
    final playIcon = find.descendant(
      of: find.byKey(readerPauseKey),
      matching: find.byIcon(Icons.play_arrow),
    );
    await _pumpUntilFound(tester, playIcon);
    expect(playIcon, findsOneWidget);

    await tester.tap(find.byKey(readerSpeedKey));
    await _pumpUntilFound(tester, find.text('2×'));
    await tester.tap(find.text('2×').last);
    await _pumpUntilFound(tester, find.byKey(readerSpeedKey));
    expect(find.text('2×'), findsOneWidget);

    await tester.tap(find.byKey(readerRotateKey));
    await tester.pump();
    expect(
      tester
          .widget<RotatedBox>(
            find.byKey(
              const ValueKey<String>('reader-page-rotation:0'),
            ),
          )
          .quarterTurns,
      1,
    );

    await tester.tap(find.byKey(readerFavoriteKey));
    await tester.pump();
    expect(favorite, isTrue);

    await tester.tap(find.byKey(readerDownloadKey));
    await tester.pump();
    expect(downloadRequested, isTrue);
    expect(find.byTooltip('本章已缓存'), findsOneWidget);

    final slider = tester.getRect(find.byKey(readerPageSliderKey));
    await tester.tapAt(Offset(slider.right - 2, slider.center.dy));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey<String>('reader-page-rotation:2'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(ReaderView));
    await _pumpUntilControls(
      tester,
      top,
      bottom,
      ignoring: true,
    );
    expect(_controlsPointer(tester, bottom).ignoring, isTrue);
  });
}
