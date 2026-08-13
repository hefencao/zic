import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:test/test.dart';

void main() {
  final chapter = ChapterManifest(
    sourceId: 'local',
    comicId: 'direction-comic',
    chapter: const Chapter(
      chapterId: 'direction-chapter',
      comicId: 'direction-comic',
      title: 'Direction',
      sequence: 1,
      pageCount: 120,
      sourceRevision: 'r1',
    ),
    pages: List<PageAsset>.generate(
      120,
      (index) => PageAsset(
        pageId: 'p$index',
        chapterId: 'direction-chapter',
        index: index,
        uri: Uri.parse('assets/p$index.webp'),
        animatedHint: true,
      ),
    ),
    readingDirection: ReadingDirection.ltr,
  );
  const resolver = RoleResolver(
    forwardEncodedPages: 7,
    backwardEncodedPages: 3,
    forwardDecodePages: 2,
    backwardDecodePages: 1,
    nearRadius: 0,
  );

  ReaderObs observation(int index, int micros) => ReaderObs(
        sessionId: 'direction-reader',
        currentIndex: index,
        stableIndex: index,
        interaction: Interaction.idle,
        logicalPosition: index.toDouble(),
        velocity: 0,
        currentCoverage: Coverage(
          pageIndex: index,
          assetKey: 'direction-chapter/p$index',
          fraction: 1,
        ),
        direction: ReadingDirection.ltr,
        timestamp: DateTime.utc(2026, 8, 13),
        monotonicMicros: micros,
      );

  test('one-page reverse is a revisit, not a 3/7 working-set reversal', () {
    final predictor = BrowsingDirectionPredictor(initialDirection: 1);
    final before = resolver.resolve(
      chapter,
      observation(99, 1),
      readDirection: predictor.direction,
    );

    expect(predictor.record(delta: -1), 1);
    final afterOneReverse = resolver.resolve(
      chapter,
      observation(98, 2),
      previousCurrentIndex: 99,
      readDirection: predictor.direction,
    );

    final beforeSet = before.roles.keys.toSet();
    final afterSet = afterOneReverse.roles.keys.toSet();
    expect(beforeSet.difference(afterSet), <int>{106});
    expect(afterSet.difference(beforeSet), <int>{95});
    expect(afterOneReverse.roleOf(99), PageRole.next);
    expect(afterOneReverse.roleOf(97), PageRole.previous);
  });

  test('two committed reverse page moves confirm one shared read direction', () {
    final predictor = BrowsingDirectionPredictor(initialDirection: 1);
    expect(predictor.record(delta: -1), 1);
    expect(predictor.record(delta: -1), -1);

    final obs = observation(97, 3);
    final window = resolver.resolve(
      chapter,
      obs,
      previousCurrentIndex: 98,
      readDirection: predictor.direction,
    );
    final flow = const AnimatedPrefetchPolicy().plan(
      chapter: chapter,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 0,
      readDirection: predictor.direction,
    );
    final plan = const HeuristicPolicy(decodeWarmPages: true).createPlan(
      revision: 1,
      chapter: chapter,
      observation: obs,
      window: window,
      decodeTarget: const DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      downloadFlow: flow,
      readDirection: predictor.direction,
    );

    expect(window.roleOf(96), PageRole.next);
    expect(window.roleOf(95), PageRole.next2);
    expect(window.roleOf(98), PageRole.previous);
    expect(flow.targetFramesFor(96), 5);
    expect(flow.targetFramesFor(95), 3);
    expect(flow.targetFramesFor(98), 2);

    final priorities = <String, int>{
      for (final entry in plan.downloads.entries)
        entry.key.content.pageId: entry.value.priority,
    };
    expect(priorities['p96'], 820);
    expect(priorities['p95'], 800);
    expect(priorities['p98'], 780);
  });

  test('jump or scrub evidence clears a pending reversal candidate', () {
    final predictor = BrowsingDirectionPredictor(initialDirection: 1);
    expect(predictor.record(delta: -1), 1);
    expect(predictor.candidateCount, 1);

    expect(predictor.record(delta: -8, directional: false), 1);
    expect(predictor.candidateCount, 0);
    expect(predictor.record(delta: -1), 1);
    expect(predictor.direction, 1);
  });
}
