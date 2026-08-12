import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  ChapterManifest chapter({int pageBytes = 2 * 1024 * 1024}) => ChapterManifest(
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
            byteLength: pageBytes,
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

  test('animated admission narrows network but preserves logical 3/7 window', () {
    final manifest = chapter();
    final obs = observation(12);
    final window = resolver.resolve(manifest, obs);
    final admission = const AnimatedPrefetchPolicy().admit(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 0,
    );

    expect(window.roles, hasLength(11));
    expect(window.roleOf(9), isNot(PageRole.detached));
    expect(window.roleOf(19), isNot(PageRole.detached));
    expect(admission.admittedIndexes, <int>{10, 11, 12, 13, 14, 15, 16});
    expect(admission.admittedIndexes, hasLength(7));
  });

  test('waterlines progressively open outer network pages to 3/7 maximum', () {
    final manifest = chapter();
    final obs = observation(12);
    final window = resolver.resolve(manifest, obs);
    const policy = AnimatedPrefetchPolicy();

    expect(
      policy.admit(
        chapter: manifest,
        observation: obs,
        window: window,
        active: true,
        expansionStage: 1,
      ).admittedIndexes,
      contains(17),
    );
    expect(
      policy.admit(
        chapter: manifest,
        observation: obs,
        window: window,
        active: true,
        expansionStage: 2,
      ).admittedIndexes,
      containsAll(<int>[9, 17]),
    );
    expect(
      policy.admit(
        chapter: manifest,
        observation: obs,
        window: window,
        active: true,
        expansionStage: 3,
      ).admittedIndexes,
      containsAll(<int>[9, 17, 18]),
    );
    final full = policy.admit(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 4,
    );
    expect(full.admittedIndexes, hasLength(11));
    expect(full.admittedIndexes, containsAll(<int>[9, 17, 18, 19]));
  });

  test('byte budget does not remove eligible 2/4 or waterline pages', () {
    final manifest = chapter(pageBytes: 10 * 1024 * 1024);
    final obs = observation(12);
    final window = resolver.resolve(manifest, obs);
    final admission = const AnimatedPrefetchPolicy(
      maxSpeculativeBytes: 50 * 1024 * 1024,
    ).admit(
      chapter: manifest,
      observation: obs,
      window: window,
      active: true,
      expansionStage: 4,
    );

    expect(admission.minimumExceedsBudget, isTrue);
    expect(admission.estimatedSpeculativeBytes, 100 * 1024 * 1024);
    expect(admission.admittedIndexes, hasLength(11));
    expect(admission.admittedIndexes, containsAll(<int>[9, 17, 18, 19]));
    expect(admission.estimatedBytesFor(13), 10 * 1024 * 1024);
  });

  test('controller resets staged expansion on jump and restores static 3/7', () {
    final manifest = chapter();
    PipelineDelta? latest;
    final controller = PipelineController(
      chapter: manifest,
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
      clock: _TestClock(),
      windowResolver: resolver,
      policy: const HeuristicPolicy(
        decodeWarmPages: true,
        animatedPrefetchPolicy: AnimatedPrefetchPolicy(
          maxSpeculativeBytes: 50 * 1024 * 1024,
        ),
      ),
      guard: const PolicyGuard(maxDownloadDemands: 11),
      onUpdate: (update) => latest = update,
    );

    controller.accept(observation(12));
    expect(latest!.plan.downloads, hasLength(7));
    final firstRevision = controller.revision;
    expect(
      controller.observeDecodeWaterline(
        planRevision: firstRevision,
        stage: 'c>4',
      ),
      isTrue,
    );
    expect(latest!.plan.downloads, hasLength(8));

    controller.accept(observation(13));
    expect(latest!.plan.downloads, hasLength(7));
    expect(controller.classifyPage(pageIndex: 13, animated: false), isTrue);
    expect(latest!.plan.downloads, hasLength(11));

    // Stale refill evidence from the previous plan cannot reopen animation
    // prefetch after the jump/classification revision has moved on.
    expect(
      controller.observeDecodeWaterline(
        planRevision: firstRevision,
        stage: 'n>3',
      ),
      isFalse,
    );
  });
}

final class _TestClock implements MonoClock {
  @override
  int nowMicros() => 1;
}
