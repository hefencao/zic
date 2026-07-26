import 'package:test/test.dart';
import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';

void main() {
  final chapter = ChapterManifest(
    sourceId: 'local',
    comicId: 'comic',
    chapter: const Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'Chapter',
      sequence: 1,
      pageCount: 6,
      sourceRevision: 'r1',
    ),
    pages: List<PageAsset>.generate(
      6,
      (index) => PageAsset(
        pageId: 'p$index',
        chapterId: 'chapter',
        index: index,
        uri: Uri.parse('assets/p$index.png'),
      ),
    ),
    readingDirection: ReadingDirection.ltr,
  );

  ReaderObs observation({double targetFraction = 0}) {
    return ReaderObs(
      sessionId: 's1',
      currentIndex: 2,
      stableIndex: 2,
      interaction: Interaction.dragging,
      logicalPosition: 2 + targetFraction,
      velocity: 1,
      currentCoverage: Coverage(
        pageIndex: 2,
        assetKey: 'chapter/p2',
        fraction: 1 - targetFraction,
      ),
      targetCoverage: targetFraction == 0
          ? null
          : Coverage(
              pageIndex: 3,
              assetKey: 'chapter/p3',
              fraction: targetFraction,
            ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 7, 26),
      monotonicMicros: 1,
    );
  }

  test('target becomes transition before page change', () {
    final window = const RoleResolver().resolve(
      chapter,
      observation(targetFraction: 0.2),
    );

    expect(window.roleOf(2), PageRole.current);
    expect(window.roleOf(3), PageRole.transition);
    expect(window.roleOf(1), PageRole.previous);
  });

  test('heuristic guarantees current download decode and upload', () {
    final obs = observation(targetFraction: 0.2);
    final window = const RoleResolver().resolve(chapter, obs);
    final plan = const HeuristicPolicy().createPlan(
      revision: 1,
      chapter: chapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
    );

    expect(
      plan.downloads.values.where((value) => value.role == PageRole.current),
      hasLength(1),
    );
    expect(
      plan.decodes.values.where((value) => value.role == PageRole.current),
      hasLength(1),
    );
    expect(
      plan.uploads.values.where((value) => value.role == PageRole.current),
      hasLength(1),
    );
    expect(
      plan.decodes.values.where((value) => value.role == PageRole.transition),
      hasLength(1),
    );
  });

  test('demand diff detaches resources that leave the window', () {
    final firstWindow = const RoleResolver().resolve(chapter, observation());
    final policy = const HeuristicPolicy();
    final target = DecodeTarget(physicalWidth: 1080, physicalHeight: 1920);
    final first = policy.createPlan(
      revision: 1,
      chapter: chapter,
      observation: observation(),
      window: firstWindow,
      decodeTarget: target,
    );
    final moved = ReaderObs(
      sessionId: 's1',
      currentIndex: 5,
      stableIndex: 5,
      interaction: Interaction.idle,
      logicalPosition: 5,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 5,
        assetKey: 'chapter/p5',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 7, 26),
      monotonicMicros: 2,
    );
    final second = policy.createPlan(
      revision: 2,
      chapter: chapter,
      observation: moved,
      window: const RoleResolver().resolve(chapter, moved),
      decodeTarget: target,
    );

    expect(DemandDiff.between(first, second).downloads.removed, isNotEmpty);
  });
}
