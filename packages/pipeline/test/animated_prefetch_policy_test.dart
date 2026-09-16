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

  test('far flow credit is role-local and independent of nearer decode progress', () {
    final manifest = chapter();
    const policy = AnimatedPrefetchPolicy();

    final farObs = observation(12);
    final farFlow = policy.plan(
      chapter: manifest,
      observation: farObs,
      window: resolver.resolve(manifest, farObs),
      active: true,
    );
    expect(farFlow.targetFramesFor(15), 1);
    expect(farFlow.targetFramesFor(19), 1);
    expect(farFlow.targetFramesByIndex, hasLength(11));

    // The same page receives deeper transport credit only when its own role
    // moves closer to the viewport. No decode-waterline callback participates.
    final promotedObs = observation(14);
    final promotedFlow = policy.plan(
      chapter: manifest,
      observation: promotedObs,
      window: resolver.resolve(manifest, promotedObs),
      active: true,
    );
    expect(promotedFlow.targetFramesFor(15), 5);
    expect(promotedFlow.targetFramesFor(16), 3);
    expect(promotedFlow.targetFramesFor(17), 1);
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
    controller.accept(observation(13));
    expect(latest!.plan.downloads, hasLength(11));
    expect(controller.classifyPage(pageIndex: 13, animated: false), isTrue);
    expect(latest!.plan.downloads, hasLength(11));
    expect(
      latest!.plan.downloads.values.every((demand) => demand.flowTargetFrames == 0),
      isTrue,
    );

  });
  test('offscreen runtime WebP evidence changes the one-frame static plan', () {
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
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: manifest,
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
      clock: _TestClock(),
      windowResolver: resolver,
      policy: const HeuristicPolicy(decodeWarmPages: true),
      guard: const PolicyGuard(maxDownloadDemands: 11),
      onUpdate: updates.add,
    );

    controller.accept(observation(12));
    expect(controller.classifyPage(pageIndex: 12, animated: false), isTrue);
    expect(controller.classifyPage(pageIndex: 13, animated: false), isTrue);
    final revision = controller.revision;
    final updateCount = updates.length;

    // Runtime WebP sniff is page-local transport-cost evidence. Even with the
    // two-page unresolved-static escape hatch, that exact page must leave the
    // speculative static decode set until decoder classification resolves it.
    expect(
      controller.observeWebpTransportCost(pageIndex: 18, webp: true),
      isTrue,
    );
    expect(controller.revision, revision + 1);
    expect(updates, hasLength(updateCount + 1));

    // Authoritative static classification restores that page to the ordinary
    // one-frame static refill set and therefore produces the inverse semantic
    // plan change.
    expect(controller.classifyPage(pageIndex: 18, animated: false), isTrue);
    expect(controller.revision, revision + 2);
    expect(updates, hasLength(updateCount + 2));
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
