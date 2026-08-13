import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  ChapterManifest chapter() => ChapterManifest(
        sourceId: 'source',
        comicId: 'comic',
        chapter: const Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'chapter',
          sequence: 1,
          pageCount: 30,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          30,
          (index) => PageAsset(
            pageId: 'p$index',
            chapterId: 'chapter',
            index: index,
            uri: Uri.parse('https://example.test/$index.webp'),
            contentKindHint: ContentKindHint.webp,
          ),
        ),
        readingDirection: ReadingDirection.ltr,
      );

  ReaderObs observation(int current) => ReaderObs(
        sessionId: 'reader',
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
        timestamp: DateTime.utc(2026, 8, 12),
        monotonicMicros: current + 1,
      );

  const resolver = RoleResolver(
    forwardEncodedPages: 7,
    backwardEncodedPages: 3,
    forwardDecodePages: 2,
    backwardDecodePages: 1,
    nearRadius: 0,
  );

  test('animation keeps all logical 3/7 downloads and assigns frame flow credits', () {
    final manifest = chapter();
    final obs = observation(12);
    final window = resolver.resolve(manifest, obs);
    final flow = const AnimatedPrefetchPolicy().plan(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 0,
    );

    expect(window.roles, hasLength(11));
    expect(flow.targetFramesByIndex, hasLength(11));
    expect(flow.targetFramesFor(12), 0); // current is unlimited
    expect(flow.targetFramesFor(13), 5);
    expect(flow.targetFramesFor(14), 3);
    expect(flow.targetFramesFor(11), 2);
    expect(flow.targetFramesFor(9), 1);
    expect(flow.targetFramesFor(15), 1);
    expect(flow.targetFramesFor(19), 1);
  });

  test('waterlines raise far frame credits without changing 3/7 membership', () {
    final manifest = chapter();
    final obs = observation(12);
    final window = resolver.resolve(manifest, obs);
    const policy = AnimatedPrefetchPolicy();

    final stage1 = policy.plan(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 1,
    );
    expect(stage1.targetFramesFor(15), 2);
    expect(stage1.targetFramesFor(16), 2);
    expect(stage1.targetFramesFor(9), 1);

    final stage2 = policy.plan(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 2,
    );
    expect(stage2.targetFramesFor(10), 2);
    expect(stage2.targetFramesFor(9), 2);

    final stage3 = policy.plan(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 3,
    );
    expect(stage3.targetFramesFor(17), 2);
    expect(stage3.targetFramesFor(18), 2);

    final stage4 = policy.plan(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 4,
    );
    expect(stage4.targetFramesFor(19), 2);
    expect(stage4.targetFramesByIndex, hasLength(11));
  });

  test('static classification restores unlimited 3/7 flow', () {
    final manifest = chapter();
    PipelineDelta? latest;
    final controller = PipelineController(
      chapter: manifest,
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
      clock: _TestClock(),
      windowResolver: resolver,
      policy: const HeuristicPolicy(decodeWarmPages: true),
      guard: const PolicyGuard(maxDownloadDemands: 11),
      onUpdate: (update) => latest = update,
    );

    controller.accept(observation(12));
    expect(latest!.plan.downloads, hasLength(11));
    expect(
      latest!.plan.downloads.values.where((demand) => demand.flowTargetFrames > 0),
      isNotEmpty,
    );
    final firstRevision = controller.revision;
    expect(
      controller.observeDecodeWaterline(
        planRevision: firstRevision,
        stage: 'c>4',
      ),
      isTrue,
    );
    expect(latest!.plan.downloads, hasLength(11));

    controller.accept(observation(13));
    expect(latest!.plan.downloads, hasLength(11));
    expect(controller.classifyPage(pageIndex: 13, animated: false), isTrue);
    expect(latest!.plan.downloads, hasLength(11));
    expect(
      latest!.plan.downloads.values.every((demand) => demand.flowTargetFrames == 0),
      isTrue,
    );

    expect(
      controller.observeDecodeWaterline(
        planRevision: firstRevision,
        stage: 'n>3',
      ),
      isFalse,
    );
  });
  test('runtime WebP cost activates bounded flow for opaque plugin URIs', () {
    final manifest = ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 30,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        30,
        (index) => PageAsset(
          pageId: 'p$index',
          chapterId: 'chapter',
          index: index,
          uri: Uri.parse('venera-resource:opaque-$index'),
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );
    PipelineDelta? latest;
    final controller = PipelineController(
      chapter: manifest,
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
      clock: _TestClock(),
      windowResolver: resolver,
      policy: const HeuristicPolicy(decodeWarmPages: true),
      guard: const PolicyGuard(maxDownloadDemands: 11),
      onUpdate: (update) => latest = update,
    );

    controller.accept(observation(12));
    expect(
      latest!.plan.downloads.values.every((demand) => demand.flowTargetFrames == 0),
      isTrue,
    );

    expect(
      controller.observeWebpTransportCost(pageIndex: 12, webp: true),
      isTrue,
    );
    expect(
      latest!.plan.downloads.values.where((demand) => demand.flowTargetFrames > 0),
      isNotEmpty,
    );

    // Decoder truth remains authoritative: a static classification restores
    // unlimited flow for this current WebP page/window.
    expect(controller.classifyPage(pageIndex: 12, animated: false), isTrue);
    expect(
      latest!.plan.downloads.values.every((demand) => demand.flowTargetFrames == 0),
      isTrue,
    );
  });

}

final class _TestClock implements MonoClock {
  @override
  int nowMicros() => 1;
}
