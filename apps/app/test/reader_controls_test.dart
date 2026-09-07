import 'dart:async';

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:zic/reader_runtime.dart';
import 'package:zic/webp_demo.dart' show defaultLocalMediaPipelineFactory;

const _screenKey = ValueKey<String>('reader-controls-screen');

ChapterManifest _chapter({
  bool animated = false,
  ReadingDirection direction = ReadingDirection.ltr,
}) {
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
        contentKindHint:
            animated ? ContentKindHint.webp : ContentKindHint.png,
        animatedHint: animated,
      ),
    ),
    readingDirection: direction,
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

Widget _pipelineReader({
  required ChapterManifest chapter,
  required ReaderRuntimeScreen Function(PipelineReaderSession pipeline) build,
}) =>
    PipelineReaderSessionHost(
      chapter: chapter,
      factory: defaultLocalMediaPipelineFactory,
      builder: (context, pipeline) => build(pipeline),
    );

const _readerRetentionSettleStep = Duration(milliseconds: 500);
const _readerRetentionSettleSteps = 300;

Future<void> _disposePipelineReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Retained reader sessions expire after two idle minutes. Drive fake time
  // in bounded steps until the expiry timer fires and disposes the session;
  // interleaved pumps also keep yielding to the real event loop so the
  // pipeline's file-I/O futures can settle. This synchronizes on actual
  // teardown work instead of one fixed pump duration.
  for (var i = 0; i < _readerRetentionSettleSteps; i++) {
    await tester.pump(_readerRetentionSettleStep);
  }
}

void main() {
  testWidgets('reader starts immersive and exposes complete bottom controls',
      (tester) async {
    bool? favorite;
    var downloadRequested = false;
    final chapter = _chapter(animated: true);
    await tester.pumpWidget(
      MaterialApp(
        home: _pipelineReader(
          chapter: chapter,
          build: (pipeline) => ReaderRuntimeScreen(
            chapter: chapter,
            pipeline: pipeline,
            screenKey: _screenKey,
            initialFavorite: false,
            onFavoriteChanged: (value) async => favorite = value,
            onDownloadRequested: () async => downloadRequested = true,
            artifactPageBuilder: (
              context,
              asset,
              reportFirstFrame,
              runtime,
            ) =>
                ColoredBox(
              key: ValueKey<String>('reader-control-page:${asset.index}'),
              color: Colors.black,
            ),
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

    await tester.tap(find.byKey(readerSpeedKey).hitTestable());
    final speed2x = find.byKey(readerSpeedOptionKey(2)).hitTestable();
    await _pumpUntilFound(tester, speed2x);
    await tester.tap(speed2x);
    await _pumpUntilFound(tester, find.byKey(readerSpeedKey).hitTestable());
    expect(find.text('2×'), findsOneWidget);

    await _pumpUntilFound(tester, find.byKey(readerRotateKey).hitTestable());
    await tester.tap(find.byKey(readerRotateKey).hitTestable());
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

    final sliderFinder = find.byKey(readerPageSliderKey);
    final slider = tester.getRect(sliderFinder);
    final gesture = await tester.startGesture(
      Offset(slider.left + 24, slider.center.dy),
    );
    await gesture.moveTo(Offset(slider.right - 24, slider.center.dy));
    await tester.pump();
    // Slider dragging is live Reader navigation. The viewport follows the
    // thumb before release; Pipeline marks these observations as scrubbing so
    // only foreground-current demand moves with the gesture.
    expect(tester.widget<Slider>(sliderFinder).value, greaterThan(1));
    expect(
      find.byKey(const ValueKey<String>('reader-page-rotation:2')),
      findsOneWidget,
    );
    await gesture.up();
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
    await _disposePipelineReader(tester);
  });

  testWidgets('reader waits for the final progress checkpoint before pop',
      (tester) async {
    final firstWrite = Completer<void>();
    final durableFlush = Completer<void>();
    final writes = <ReadingProgress>[];
    var flushes = 0;
    final chapter = _chapter();
    const launchKey = ValueKey<String>('reader-progress-launch');

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: launchKey,
                onPressed: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _pipelineReader(
                        chapter: chapter,
                        build: (pipeline) => ReaderRuntimeScreen(
                          chapter: chapter,
                          pipeline: pipeline,
                          initiallyImmersive: false,
                          screenKey: const ValueKey<String>(
                            'reader-progress-screen',
                          ),
                          onProgressChanged: (progress) {
                            writes.add(progress);
                            return firstWrite.future;
                          },
                          onProgressFlush: () {
                            flushes++;
                            return durableFlush.future;
                          },
                          artifactPageBuilder: (
                            context,
                            asset,
                            reportFirstFrame,
                            runtime,
                          ) =>
                              ColoredBox(
                            key: ValueKey<String>(
                              'reader-progress-page:${asset.index}',
                            ),
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Launch Reader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(launchKey));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('reader-progress-screen')),
    );
    final slider = tester.widget<Slider>(find.byKey(readerPageSliderKey));
    slider.onChanged!(2);
    slider.onChangeEnd!(2);
    await tester.pump();
    expect(writes, isNotEmpty);

    final pop = tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('reader-progress-screen')),
      findsOneWidget,
    );

    firstWrite.complete();
    await tester.pump();
    expect(flushes, 1);
    expect(
      find.byKey(const ValueKey<String>('reader-progress-screen')),
      findsOneWidget,
    );

    durableFlush.complete();
    await pop;
    await tester.pumpAndSettle();
    expect(find.byKey(launchKey), findsOneWidget);
    expect(writes.last.pageIndex, 2);
    await _disposePipelineReader(tester);
  });

  testWidgets('static images hide playback-only controls', (tester) async {
    final chapter = _chapter();
    await tester.pumpWidget(
      MaterialApp(
        home: _pipelineReader(
          chapter: chapter,
          build: (pipeline) => ReaderRuntimeScreen(
            chapter: chapter,
            pipeline: pipeline,
            screenKey: const ValueKey<String>(
              'reader-static-controls-screen',
            ),
            artifactPageBuilder: (
              context,
              asset,
              reportFirstFrame,
              runtime,
            ) =>
                ColoredBox(
              key: ValueKey<String>('reader-static-page:${asset.index}'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final top = find.byKey(readerTopControlsKey);
    final bottom = find.byKey(readerBottomControlsKey);
    await tester.tap(find.byType(ReaderView));
    await _pumpUntilControls(tester, top, bottom, ignoring: false);

    expect(find.byKey(readerPauseKey), findsNothing);
    expect(find.byKey(readerSpeedKey), findsNothing);
    expect(find.byKey(readerRotateKey), findsOneWidget);
    expect(find.byKey(readerFavoriteKey), findsOneWidget);
    expect(find.byKey(readerDownloadKey), findsNothing);
    await _disposePipelineReader(tester);
  });

  testWidgets('top controls omit duplicate navigation and layout actions',
      (tester) async {
    final chapter = _chapter();
    await tester.pumpWidget(
      MaterialApp(
        home: _pipelineReader(
          chapter: chapter,
          build: (pipeline) => ReaderRuntimeScreen(
            chapter: chapter,
            pipeline: pipeline,
            initiallyImmersive: false,
            onSettingsChanged: (_) {},
            artifactPageBuilder: (
              context,
              asset,
              reportFirstFrame,
              runtime,
            ) =>
                ColoredBox(
              key: ValueKey<String>('reader-top-page:${asset.index}'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final top = find.byKey(readerTopControlsKey);
    expect(find.byKey(readerChapterTitleKey), findsOneWidget);
    expect(
      find.descendant(of: top, matching: find.byIcon(Icons.chevron_left)),
      findsNothing,
    );
    expect(
      find.descendant(of: top, matching: find.byIcon(Icons.chevron_right)),
      findsNothing,
    );
    expect(
      find.descendant(of: top, matching: find.byIcon(Icons.swap_horiz)),
      findsNothing,
    );
    expect(find.byKey(readerComicSettingsKey), findsOneWidget);
    expect(find.byKey(readerPageSliderKey), findsOneWidget);
    await _disposePipelineReader(tester);
  });

  testWidgets('RTL reader mirrors slider direction and index labels',
      (tester) async {
    final chapter = _chapter(direction: ReadingDirection.rtl);
    await tester.pumpWidget(
      MaterialApp(
        home: _pipelineReader(
          chapter: chapter,
          build: (pipeline) => ReaderRuntimeScreen(
            chapter: chapter,
            pipeline: pipeline,
            initiallyImmersive: false,
            initialSettings: const ReaderSessionSettings(
              comicSpecificEnabled: true,
              directionOverride: ReadingDirection.rtl,
            ),
            artifactPageBuilder: (
              context,
              asset,
              reportFirstFrame,
              runtime,
            ) =>
                ColoredBox(
              key: ValueKey<String>('reader-rtl-page:${asset.index}'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final sliderFinder = find.byKey(readerPageSliderKey);
    expect(sliderFinder, findsOneWidget);
    expect(
      Directionality.of(tester.element(sliderFinder)),
      TextDirection.rtl,
    );
    final slider = tester.getRect(sliderFinder);
    await tester.tapAt(Offset(slider.left + 2, slider.center.dy));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('reader-rtl-page:2')),
      findsOneWidget,
    );
    await _disposePipelineReader(tester);
  });

  // Adaptive classification belongs to reader_runtime and is covered by
  // packages/reader_runtime/test/adaptive_reader_classifier_test.dart.
}
