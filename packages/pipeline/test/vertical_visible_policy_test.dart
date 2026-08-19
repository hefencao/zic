import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('every vertically visible static page receives authoritative demand', () {
    final chapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
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
          uri: Uri.parse('asset:///p$index.png'),
          width: 1000,
          height: 1600,
          contentKindHint: ContentKindHint.png,
          animatedHint: false,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final observation = ReaderObs(
      sessionId: 'reader',
      currentIndex: 2,
      stableIndex: 2,
      interaction: Interaction.scrolling,
      logicalPosition: 2.2,
      velocity: -1,
      currentCoverage: Coverage(
        pageIndex: 2,
        assetKey: chapter.pages[2].assetKey,
        fraction: 0.6,
      ),
      targetCoverage: Coverage(
        pageIndex: 1,
        assetKey: chapter.pages[1].assetKey,
        fraction: 0.2,
      ),
      visibleCoverages: <Coverage>[
        Coverage(
          pageIndex: 1,
          assetKey: chapter.pages[1].assetKey,
          fraction: 0.2,
        ),
        Coverage(
          pageIndex: 2,
          assetKey: chapter.pages[2].assetKey,
          fraction: 0.6,
        ),
        Coverage(
          pageIndex: 3,
          assetKey: chapter.pages[3].assetKey,
          fraction: 0.2,
        ),
      ],
      direction: ReadingDirection.vertical,
      timestamp: DateTime.utc(2026, 8, 4),
      monotonicMicros: 1,
    );
    final window = const RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    ).resolve(chapter, observation);
    final plan = const HeuristicPolicy(
      decodeWarmPages: true,
      // Deliberately smaller than the three visible outputs. Visibility must
      // remain authoritative; the real FrameBudget trims only non-visible work.
      staticOutputBudgetBytes: 1,
    ).createPlan(
      revision: 1,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
    );

    expect(window.roleOf(1), PageRole.transition);
    expect(window.roleOf(3), PageRole.next);
    final visiblePage = plan.uploads.entries.singleWhere(
      (entry) => entry.key.download.content.pageId == 'p3',
    );
    expect(visiblePage.value.reason, 'heuristic:static-visible:next');
    expect(visiblePage.value.priority, greaterThanOrEqualTo(880));
    expect(visiblePage.value.retainOutput, isTrue);
    expect(plan.decodes[visiblePage.key]!.targetWatermark, 1);
  });
  test('far visible metadata does not create an empty scheduler revision', () {
    final chapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 20,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        20,
        (index) => PageAsset(
          pageId: 'p$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('asset:///p$index.png'),
          width: 1000,
          height: 1600,
          contentKindHint: ContentKindHint.png,
          animatedHint: false,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    ReaderObs observation({required bool includeFarVisible}) => ReaderObs(
          sessionId: 'reader',
          currentIndex: 8,
          stableIndex: 8,
          interaction: Interaction.scrolling,
          logicalPosition: 8.4,
          velocity: 1,
          currentCoverage: Coverage(
            pageIndex: 8,
            assetKey: chapter.pages[8].assetKey,
            fraction: 0.6,
          ),
          visibleCoverages: <Coverage>[
            Coverage(
              pageIndex: 8,
              assetKey: chapter.pages[8].assetKey,
              fraction: 0.6,
            ),
            if (includeFarVisible)
              Coverage(
                pageIndex: 19,
                assetKey: chapter.pages[19].assetKey,
                fraction: 0.1,
              ),
          ],
          direction: ReadingDirection.vertical,
          timestamp: DateTime.utc(2026, 8, 19),
          monotonicMicros: includeFarVisible ? 2 : 1,
        );
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      onUpdate: updates.add,
    );

    controller.accept(observation(includeFarVisible: false));
    final revision = controller.revision;
    final updateCount = updates.length;
    controller.accept(observation(includeFarVisible: true));

    expect(controller.revision, revision);
    expect(updates, hasLength(updateCount));
  });

}


final class _Clock implements MonoClock {
  @override
  int nowMicros() => 0;
}
