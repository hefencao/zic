import 'package:domain/domain.dart';
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
    var notifications = 0;
    final controller = ReaderController(
      sessionId: 's1',
      chapter: chapter,
      onObservation: observations.add,
      clock: _Clock(),
    )..addListener(() => notifications++);

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
    expect(notifications, 0);

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
    expect(notifications, 1);
    controller.dispose();
  });
}
