import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('single reverse move does not flip browsing direction', () {
    final predictor = BrowsingDirectionPredictor();
    predictor.reset(direction: 1, nowMicros: 0);

    expect(
      predictor.record(delta: -1, nowMicros: 500000),
      1,
    );
    expect(
      predictor.record(delta: 1, nowMicros: 900000),
      1,
    );
  });

  test('two consecutive reverse moves confirm browsing direction', () {
    final predictor = BrowsingDirectionPredictor();
    predictor.reset(direction: 1, nowMicros: 0);

    expect(predictor.record(delta: -1, nowMicros: 500000), 1);
    expect(predictor.record(delta: -1, nowMicros: 1000000), -1);
  });

  test('scrub and large jump do not teach browsing direction', () {
    final predictor = BrowsingDirectionPredictor(initialDirection: -1);
    predictor.reset(direction: -1, nowMicros: 0);

    expect(
      predictor.record(
        delta: 8,
        nowMicros: 500000,
        directional: false,
      ),
      -1,
    );
    expect(
      predictor.record(delta: 8, nowMicros: 1000000),
      -1,
    );
  });

  test('3/7 role window is oriented by predicted browsing direction', () {
    final chapter = _chapter();
    final obs = _observation(10, 1000000);
    const resolver = RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    );

    final forward = resolver.resolve(chapter, obs, readDirection: 1);
    expect(forward.roleOf(11), PageRole.next);
    expect(forward.roleOf(12), PageRole.next2);
    expect(forward.roleOf(9), PageRole.previous);
    expect(forward.roleOf(17), PageRole.far);
    expect(forward.roleOf(7), PageRole.far);
    expect(forward.roleOf(6), PageRole.detached);

    final reverse = resolver.resolve(chapter, obs, readDirection: -1);
    expect(reverse.roleOf(9), PageRole.next);
    expect(reverse.roleOf(8), PageRole.next2);
    expect(reverse.roleOf(11), PageRole.previous);
    expect(reverse.roleOf(3), PageRole.far);
    expect(reverse.roleOf(13), PageRole.far);
    expect(reverse.roleOf(14), PageRole.detached);
  });

  test('controller keeps old 3/7 orientation for one-page reversal then flips',
      () {
    final updates = <PipelineDelta>[];
    final trace = MemoryTraceSink();
    final controller = PipelineController(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
      clock: const _Clock(),
      traceSink: trace,
      windowResolver: const RoleResolver(
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
        forwardDecodePages: 2,
        backwardDecodePages: 1,
        nearRadius: 0,
      ),
      onUpdate: updates.add,
    );

    controller.accept(_observation(10, 1000000));
    expect(updates.last.window.roleOf(11), PageRole.next);

    controller.accept(_observation(9, 1500000));
    expect(updates.last.window.roleOf(10), PageRole.next);
    expect(updates.last.window.roleOf(8), PageRole.previous);

    controller.accept(_observation(8, 2000000));
    expect(updates.last.window.roleOf(7), PageRole.next);
    expect(updates.last.window.roleOf(6), PageRole.next2);
    expect(updates.last.window.roleOf(9), PageRole.previous);

    final directions = trace.events
        .where((event) => event.kind == TraceEventKind.policyDecision)
        .map((event) => event.payload['readDirection'])
        .toList(growable: false);
    expect(directions, containsAllInOrder(<Object?>[1, 1, -1]));
  });

  test('animated flow credit uses browsing-relative distance', () {
    final chapter = _chapter();
    final obs = _observation(10, 1000000);
    final window = const RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    ).resolve(chapter, obs, readDirection: -1);
    final flow = const AnimatedPrefetchPolicy().plan(
      chapter: chapter,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 0,
      readDirection: -1,
    );

    expect(flow.targetFramesFor(9), 5);
    expect(flow.targetFramesFor(8), 3);
    expect(flow.targetFramesFor(11), 2);
    expect(flow.targetFramesFor(7), 1);
  });
}

ChapterManifest _chapter() => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 24,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        24,
        (index) => PageAsset(
          pageId: 'p$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('https://example.test/$index.webp'),
          animatedHint: true,
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );

ReaderObs _observation(int current, int micros) => ReaderObs(
      sessionId: 'direction-test',
      currentIndex: current,
      stableIndex: current,
      interaction: Interaction.idle,
      logicalPosition: current.toDouble(),
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: current,
        assetKey: 'chapter/p$current',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 8, 13),
      monotonicMicros: micros,
    );

final class _Clock implements MonoClock {
  const _Clock();

  @override
  int nowMicros() => 1;
}
