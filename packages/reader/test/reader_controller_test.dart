import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/reader.dart';
import 'package:telemetry/telemetry.dart';

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 7;
}

void main() {
  test('controller forwards observations without rebuilding on every scroll', () {
    final chapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 2,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'p0',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('assets/p0.png'),
        ),
        PageAsset(
          pageId: 'p1',
          chapterId: 'chapter',
          index: 1,
          uri: Uri.parse('assets/p1.png'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final observations = <ReaderObs>[];
    var commandNotifications = 0;
    var currentNotifications = 0;
    final controller = ReaderController(
      sessionId: 's1',
      chapter: chapter,
      onObservation: observations.add,
      clock: _Clock(),
    )..addListener(() => commandNotifications++);
    controller.currentIndexListenable.addListener(() => currentNotifications++);

    controller.report(
      ReaderObs(
        sessionId: 's1',
        currentIndex: 0,
        stableIndex: 0,
        interaction: Interaction.dragging,
        logicalPosition: 0.2,
        velocity: 1,
        currentCoverage: Coverage(
          pageIndex: 0,
          assetKey: 'chapter/p0',
          fraction: 0.8,
        ),
        targetCoverage: Coverage(
          pageIndex: 1,
          assetKey: 'chapter/p1',
          fraction: 0.2,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026, 7, 26),
        monotonicMicros: 1,
      ),
    );
    expect(observations, hasLength(1));
    expect(commandNotifications, 0);
    expect(currentNotifications, 0);

    controller.report(
      ReaderObs(
        sessionId: 's1',
        currentIndex: 1,
        stableIndex: 1,
        interaction: Interaction.settling,
        logicalPosition: 1,
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: 1,
          assetKey: 'chapter/p1',
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026, 7, 26),
        monotonicMicros: 2,
      ),
    );
    expect(commandNotifications, 0,
        reason: 'current projection must not wake command consumers');
    expect(currentNotifications, 1);
    expect(controller.currentIndexListenable.value, 1);
    controller.dispose();
  });

  test('pipeline observation failure cannot roll back visible navigation', () {
    final chapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 2,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'p0',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('assets/p0.png'),
        ),
        PageAsset(
          pageId: 'p1',
          chapterId: 'chapter',
          index: 1,
          uri: Uri.parse('assets/p1.png'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final reportedErrors = <FlutterErrorDetails>[];
    final priorErrorHandler = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    addTearDown(() => FlutterError.onError = priorErrorHandler);
    var commandNotifications = 0;
    var currentNotifications = 0;
    final controller = ReaderController(
      sessionId: 'navigation-isolation',
      chapter: chapter,
      onObservation: (_) => throw StateError('pipeline failed'),
      clock: _Clock(),
    )..addListener(() => commandNotifications++);
    controller.currentIndexListenable.addListener(() => currentNotifications++);
    addTearDown(controller.dispose);

    final observation = ReaderObs(
      sessionId: 'navigation-isolation',
      currentIndex: 1,
      stableIndex: 1,
      interaction: Interaction.settling,
      logicalPosition: 1,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 1,
        assetKey: 'chapter/p1',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 8, 11),
      monotonicMicros: 3,
    );

    expect(() => controller.report(observation), returnsNormally);
    expect(controller.currentIndex, 1);
    expect(controller.stableIndex, 1);
    expect(controller.lastObservation, same(observation));
    expect(commandNotifications, 0);
    expect(currentNotifications, 1,
        reason: 'visible navigation publishes before pipeline consumption');
    expect(reportedErrors, hasLength(1));
    expect(reportedErrors.single.exception, isA<StateError>());
  });

  testWidgets('custom media page reports first frame exactly once', (
    tester,
  ) async {
    final chapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'p0',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('assets/p0.webp'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
    final trace = MemoryTraceSink();
    final controller = ReaderController(
      sessionId: 'media-session',
      chapter: chapter,
      onObservation: (_) {},
      clock: _Clock(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ReaderView(
          controller: controller,
          clock: _Clock(),
          traceSink: trace,
          demandRevision: () => 11,
          pageBuilder: (context, asset, reportFirstFrame) {
            reportFirstFrame();
            reportFirstFrame();
            return const SizedBox(
              key: ValueKey<String>('custom-media-page'),
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('custom-media-page')),
      findsOneWidget,
    );
    final firstFrames = trace.events
        .where((event) => event.kind == TraceEventKind.firstFrameReady)
        .toList();
    expect(firstFrames, hasLength(1));
    expect(firstFrames.single.identityHash, chapter.pages.single.assetKey);
    expect(firstFrames.single.revision, 11);
    expect(
      firstFrames.single.payload['mountToFirstFrameMicros'],
      greaterThanOrEqualTo(0),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
}
