import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

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
        animatedHint: true,
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
    expect(
      plan.decodes.values.singleWhere(
        (value) => value.role == PageRole.current,
      ).targetWatermark,
      7,
    );
  });

  test('slider scrub keeps only foreground-current resource demand', () {
    final obs = ReaderObs(
      sessionId: 'scrub',
      currentIndex: 4,
      stableIndex: 4,
      interaction: Interaction.scrubbing,
      logicalPosition: 4,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 4,
        assetKey: 'chapter/p4',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 8, 11),
      monotonicMicros: 2,
    );
    final window = const RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
    ).resolve(chapter, obs, previousCurrentIndex: 2);
    final plan = const HeuristicPolicy().createPlan(
      revision: 2,
      chapter: chapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
    );

    expect(window.roles, <int, PageRole>{4: PageRole.current});
    expect(window.retainedIndex, isNull);
    expect(plan.downloads, hasLength(1));
    expect(plan.decodes, hasLength(1));
    expect(plan.uploads, hasLength(1));
    expect(plan.downloads.values.single.priority, 1000);
    expect(plan.decodes.values.single.priority, 1000);
    expect(plan.uploads.values.single.priority, 1000);
  });

  test('source streaming profile keeps far pages download-only', () {
    final longChapter = ChapterManifest(
      sourceId: 'venera:fixture',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
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
          uri: Uri.parse('venera-resource:page-$index'),
          animatedHint: true,
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );
    final obs = ReaderObs(
      sessionId: 's1',
      currentIndex: 8,
      stableIndex: 8,
      interaction: Interaction.idle,
      logicalPosition: 8,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 8,
        assetKey: 'chapter/p8',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 7, 31),
      monotonicMicros: 1,
    );
    final window = const RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    ).resolve(longChapter, obs);
    final plan = const HeuristicPolicy(decodeWarmPages: true).createPlan(
      revision: 1,
      chapter: longChapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
    );

    expect(plan.downloads, hasLength(11));
    expect(plan.decodes, hasLength(4));
    expect(window.roleOf(10), PageRole.next2);
    expect(window.roleOf(11), PageRole.far);
    expect(
      plan.decodes.keys.map((id) => id.download.content.pageId),
      containsAll(<String>['p7', 'p8', 'p9', 'p10']),
    );
    expect(
      plan.decodes.keys.map((id) => id.download.content.pageId),
      isNot(contains('p11')),
    );
    final downloadPriorities = <String, int>{
      for (final entry in plan.downloads.entries)
        entry.key.content.pageId: entry.value.priority,
    };
    expect(downloadPriorities['p8'], 1000);
    expect(downloadPriorities['p9'], 820);
    expect(downloadPriorities['p10'], 800);
    expect(downloadPriorities['p7'], 780);
    expect(downloadPriorities['p11'], 760);
    expect(downloadPriorities['p12'], 740);
    expect(downloadPriorities['p13'], 720);
    expect(downloadPriorities['p14'], 700);
    expect(downloadPriorities['p15'], 680);
    expect(downloadPriorities['p6'], 660);
    expect(downloadPriorities['p5'], 640);
    expect(downloadPriorities.values.toSet(), hasLength(11));
  });


  test('previous current stays in previous window while its output is retained', () {
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _FakeClock(),
      windowResolver: const RoleResolver(
        forwardEncodedPages: 2,
        backwardEncodedPages: 1,
        forwardDecodePages: 2,
        backwardDecodePages: 1,
        nearRadius: 0,
      ),
      policy: const HeuristicPolicy(decodeWarmPages: true),
      onUpdate: updates.add,
    );

    controller.accept(observation());
    final moved = ReaderObs(
      sessionId: 's1',
      currentIndex: 3,
      stableIndex: 3,
      interaction: Interaction.idle,
      logicalPosition: 3,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 3,
        assetKey: 'chapter/p3',
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 7, 26),
      monotonicMicros: 2,
    );
    controller.accept(moved);
    controller.accept(moved);

    final latest = updates.last;
    expect(latest.window.roleOf(2), PageRole.previous);
    expect(latest.window.retainedIndex, 2,
        reason: 'output retention must not replace the relative previous role');
    expect(latest.window.roleOf(1), PageRole.detached,
        reason: 'the single backward slot belongs to the adjacent previous page');
    expect(
      latest.plan.uploads.values.where((value) => value.role == PageRole.last),
      hasLength(1),
    );
    expect(
      latest.plan.decodes.values.where((value) => value.role == PageRole.previous),
      hasLength(1),
    );
    expect(
      latest.plan.downloads.values.where((value) => value.role == PageRole.previous),
      hasLength(1),
    );
    expect(
      latest.plan.downloads.values
          .singleWhere((value) => value.role == PageRole.previous)
          .priority,
      780,
    );
    expect(updates, hasLength(2),
        reason: 'last ownership must persist across unchanged observations');
  });

  test('far previous current retains output without redundant download', () {
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _FakeClock(),
      windowResolver: const RoleResolver(
        forwardEncodedPages: 2,
        backwardEncodedPages: 1,
        forwardDecodePages: 2,
        backwardDecodePages: 1,
        nearRadius: 0,
      ),
      policy: const HeuristicPolicy(decodeWarmPages: true),
      onUpdate: updates.add,
    );

    controller.accept(observation());
    controller.accept(
      ReaderObs(
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
      ),
    );

    final latest = updates.last;
    expect(latest.window.retainedIndex, 2);
    expect(latest.window.roleOf(2), PageRole.detached,
        reason: 'retention must not pull a far old current back into the window');
    expect(
      latest.plan.downloads.keys
          .map((id) => id.content.pageId),
      isNot(contains('p2')),
      reason: 'a far retained output must not create redundant network demand',
    );
    expect(
      latest.plan.decodes.keys
          .map((id) => id.download.content.pageId),
      isNot(contains('p2')),
      reason: 'a far retained output must not create redundant decode demand',
    );
    expect(
      latest.plan.uploads.entries.singleWhere(
        (entry) => entry.key.download.content.pageId == 'p2',
      ).value.role,
      PageRole.last,
      reason: 'the already-presented output is retained independently',
    );
  });

  test('decode target update preserves download demand ownership', () {
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _FakeClock(),
      onUpdate: updates.add,
    );

    final obs = observation();
    controller.accept(obs);
    final before = controller.currentPlan;
    final beforeDownloads = before.downloads.keys.toSet();

    controller.updateDecodeTarget(
      DecodeTarget(
        physicalWidth: 720,
        physicalHeight: 1280,
      ),
    );
    controller.accept(obs);

    expect(updates, hasLength(2));
    final retarget = updates.last;
    expect(retarget.diff.downloads.isEmpty, isTrue,
        reason: 'viewport raster changes must not withdraw physical downloads');
    expect(retarget.plan.downloads.keys.toSet(), beforeDownloads);
    expect(retarget.diff.decodes.added, isNotEmpty);
    expect(retarget.diff.decodes.removed, isNotEmpty);
    expect(retarget.diff.uploads.added, isNotEmpty);
    expect(retarget.diff.uploads.removed, isNotEmpty);
    expect(
      retarget.plan.decodes.keys.every(
        (id) => id.physicalWidth == 720 && id.physicalHeight == 1280,
      ),
      isTrue,
    );
  });

  test('pipeline does not resubmit an unchanged role window', () {
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: chapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _FakeClock(),
      onUpdate: updates.add,
    );

    controller.accept(observation());
    controller.accept(observation());

    expect(controller.revision, 1);
    expect(updates, hasLength(1));
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


final class _FakeClock implements MonoClock {
  @override
  int nowMicros() => 1;
  test('vertical overlap becomes transition before midpoint', () {
    final vertical = ReaderObs(
      sessionId: 'vertical',
      currentIndex: 2,
      stableIndex: 2,
      interaction: Interaction.scrolling,
      logicalPosition: 2.8,
      velocity: -0.2,
      currentCoverage: Coverage(
        pageIndex: 2,
        assetKey: 'chapter/p2',
        fraction: 0.92,
      ),
      targetCoverage: Coverage(
        pageIndex: 1,
        assetKey: 'chapter/p1',
        fraction: 0.08,
      ),
      direction: ReadingDirection.vertical,
      timestamp: DateTime.utc(2026, 8, 4),
      monotonicMicros: 2,
    );
    final window = const RoleResolver().resolve(chapter, vertical);

    expect(window.roleOf(2), PageRole.current);
    expect(window.roleOf(1), PageRole.transition);
  });

  test('static neighbor outputs fill the byte budget and remain evictable', () {
    final staticChapter = ChapterManifest(
      sourceId: 'local',
      comicId: 'static-comic',
      chapter: const Chapter(
        chapterId: 'static-chapter',
        comicId: 'static-comic',
        title: 'Static',
        sequence: 1,
        pageCount: 12,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        12,
        (index) => PageAsset(
          pageId: 's$index',
          chapterId: 'static-chapter',
          index: index,
          uri: Uri.parse('asset:///s$index.png'),
          contentKindHint: ContentKindHint.png,
          animatedHint: false,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final obs = ReaderObs(
      sessionId: 'static',
      currentIndex: 5,
      stableIndex: 5,
      interaction: Interaction.idle,
      logicalPosition: 5,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 5,
        assetKey: 'static-chapter/s5',
        fraction: 1,
      ),
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
    ).resolve(staticChapter, obs);
    final plan = const HeuristicPolicy(
      decodeWarmPages: true,
      staticOutputBudgetBytes: 20 * 1024 * 1024,
    ).createPlan(
      revision: 1,
      chapter: staticChapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1000,
        physicalHeight: 1000,
      ),
    );

    // 4 MiB per output, so the speculative budget admits five static pages.
    expect(plan.uploads, hasLength(5));
    expect(plan.decodes, hasLength(5));
    expect(
      plan.uploads.values.where(
        (demand) => demand.reason.startsWith('heuristic:static-warm'),
      ),
      isNotEmpty,
    );
    expect(
      plan.uploads.values.where((demand) => demand.role == PageRole.far),
      isNotEmpty,
    );
  });

  test(
    'vertical active scroll keeps next2 decode warm but defers its hidden static upload',
    () {
      final staticChapter = ChapterManifest(
        sourceId: 'local',
        comicId: 'vertical-active-static-comic',
        chapter: const Chapter(
          chapterId: 'vertical-active-static-chapter',
          comicId: 'vertical-active-static-comic',
          title: 'Vertical Active Static',
          sequence: 1,
          pageCount: 12,
          sourceRevision: 'r1',
        ),
        pages: List<PageAsset>.generate(
          12,
          (index) => PageAsset(
            pageId: 'va$index',
            chapterId: 'vertical-active-static-chapter',
            index: index,
            uri: Uri.parse('asset:///va$index.png'),
            contentKindHint: ContentKindHint.png,
            animatedHint: false,
          ),
        ),
        readingDirection: ReadingDirection.vertical,
      );

      ReaderObs verticalObservation(Interaction interaction) => ReaderObs(
            sessionId: 'vertical-active-static',
            currentIndex: 5,
            stableIndex: 5,
            interaction: interaction,
            logicalPosition: 5.2,
            velocity: interaction == Interaction.idle ? 0 : 2.5,
            currentCoverage: Coverage(
              pageIndex: 5,
              assetKey: staticChapter.pages[5].assetKey,
              fraction: 0.8,
            ),
            visibleCoverages: <Coverage>[
              Coverage(
                pageIndex: 5,
                assetKey: staticChapter.pages[5].assetKey,
                fraction: 0.8,
              ),
              Coverage(
                pageIndex: 6,
                assetKey: staticChapter.pages[6].assetKey,
                fraction: 0.2,
              ),
            ],
            direction: ReadingDirection.vertical,
            timestamp: DateTime.utc(2026, 8, 14),
            monotonicMicros: 1,
          );

      final active = verticalObservation(Interaction.scrolling);
      final resolver = const RoleResolver(
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
        forwardDecodePages: 2,
        backwardDecodePages: 1,
        nearRadius: 0,
      );
      final policy = const HeuristicPolicy(
        decodeWarmPages: true,
        staticOutputBudgetBytes: 32 * 1024 * 1024,
      );
      final target = DecodeTarget(physicalWidth: 1000, physicalHeight: 1000);
      final activePlan = policy.createPlan(
        revision: 1,
        chapter: staticChapter,
        observation: active,
        window: resolver.resolve(staticChapter, active),
        decodeTarget: target,
      );

      expect(
        activePlan.decodes.values.where((demand) => demand.role == PageRole.next2),
        isNotEmpty,
        reason: 'active vertical scrolling must keep next2 decode warm',
      );
      expect(
        activePlan.uploads.values.where((demand) => demand.role == PageRole.next2),
        isEmpty,
        reason:
            'a hidden next2 static texture must not blit while vertical presentation is active',
      );
      expect(
        activePlan.uploads.values.where((demand) => demand.role == PageRole.next),
        isNotEmpty,
        reason: 'the immediate next page remains warm',
      );

      final idle = verticalObservation(Interaction.idle);
      final idlePlan = policy.createPlan(
        revision: 2,
        chapter: staticChapter,
        observation: idle,
        window: resolver.resolve(staticChapter, idle),
        decodeTarget: target,
      );
      expect(
        idlePlan.uploads.values.where((demand) => demand.role == PageRole.next2),
        isNotEmpty,
        reason: 'next2 texture warming resumes once the vertical viewport is idle',
      );
    },
  );

  test('runtime static WebP evidence enables one-frame chapter warming', () {
    final webpChapter = ChapterManifest(
      sourceId: 'venera:fixture',
      comicId: 'webp-static-comic',
      chapter: const Chapter(
        chapterId: 'webp-static-chapter',
        comicId: 'webp-static-comic',
        title: 'Static WebP',
        sequence: 1,
        pageCount: 8,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        8,
        (index) => PageAsset(
          pageId: 'w$index',
          chapterId: 'webp-static-chapter',
          index: index,
          uri: Uri.parse('venera-resource://page/$index.webp'),
          contentKindHint: ContentKindHint.webp,
          // Source metadata can only say that WebP may animate.
          animatedHint: true,
        ),
      ),
      readingDirection: ReadingDirection.vertical,
    );
    final obs = ReaderObs(
      sessionId: 'runtime-static',
      currentIndex: 3,
      stableIndex: 3,
      interaction: Interaction.idle,
      logicalPosition: 3,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 3,
        assetKey: 'webp-static-chapter/w3',
        fraction: 1,
      ),
      direction: ReadingDirection.vertical,
      timestamp: DateTime.utc(2026, 8, 4),
      monotonicMicros: 1,
    );
    final updates = <PipelineDelta>[];
    final controller = PipelineController(
      chapter: webpChapter,
      decodeTarget: DecodeTarget(
        physicalWidth: 1000,
        physicalHeight: 1000,
      ),
      clock: _TestClock(),
      policy: const HeuristicPolicy(
        decodeWarmPages: true,
        staticOutputBudgetBytes: 24 * 1024 * 1024,
      ),
      onUpdate: updates.add,
    );

    controller.accept(obs);
    expect(controller.currentPlan.uploads, hasLength(1));

    expect(controller.classifyPage(pageIndex: 3, animated: false), isTrue);
    expect(controller.classifyPage(pageIndex: 4, animated: false), isTrue);

    expect(updates, isNotEmpty);
    expect(
      controller.currentPlan.uploads.values.where(
        (demand) => demand.reason.startsWith('heuristic:static-'),
      ).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('static evidence does not widen stable decode window into far pages', () {
    final longChapter = ChapterManifest(
      sourceId: 'venera:fixture',
      comicId: 'static-comic',
      chapter: const Chapter(
        chapterId: 'static-chapter',
        comicId: 'static-comic',
        title: 'Static Chapter',
        sequence: 1,
        pageCount: 20,
        sourceRevision: 'r1',
      ),
      pages: List<PageAsset>.generate(
        20,
        (index) => PageAsset(
          pageId: 's$index',
          chapterId: 'static-chapter',
          index: index,
          uri: Uri.parse('venera-resource:static-$index'),
          animatedHint: false,
        ),
      ),
      readingDirection: ReadingDirection.ltr,
    );
    final obs = ReaderObs(
      sessionId: 'static-window',
      currentIndex: 8,
      stableIndex: 8,
      interaction: Interaction.idle,
      logicalPosition: 8,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 8,
        assetKey: longChapter.pages[8].assetKey,
        fraction: 1,
      ),
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026, 8, 9),
      monotonicMicros: 1,
    );
    final window = const RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    ).resolve(longChapter, obs);
    final plan = const HeuristicPolicy(decodeWarmPages: true).createPlan(
      revision: 1,
      chapter: longChapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(physicalWidth: 1080, physicalHeight: 1920),
    );

    expect(plan.downloads, hasLength(11));
    expect(plan.decodes, hasLength(4));
    expect(plan.uploads, hasLength(4));
    expect(
      plan.decodes.keys.map((id) => id.download.content.pageId),
      containsAll(<String>['s7', 's8', 's9', 's10']),
    );
    expect(
      plan.decodes.keys.map((id) => id.download.content.pageId),
      isNot(contains('s11')),
    );
  });

  test('runtime animated evidence disables unresolved static inference', () {
    final overrides = <int, bool>{0: false, 1: false, 2: true};
    final obs = observation();
    final window = const RoleResolver().resolve(chapter, obs);
    final plan = const HeuristicPolicy(
      decodeWarmPages: true,
      staticOutputBudgetBytes: 64 * 1024 * 1024,
    ).createPlan(
      revision: 1,
      chapter: chapter,
      observation: obs,
      window: window,
      decodeTarget: DecodeTarget(
        physicalWidth: 1000,
        physicalHeight: 1000,
      ),
      runtimeAnimatedPages: overrides,
      assumeUnresolvedStatic: false,
    );

    final staticWarm = plan.uploads.entries.where(
      (entry) => entry.value.reason.startsWith('heuristic:static-warm'),
    ).toList(growable: false);
    expect(staticWarm, hasLength(1));
    expect(
      staticWarm.map((entry) => entry.key.download.content.pageId),
      contains('p1'),
    );
    expect(
      staticWarm.map((entry) => entry.key.download.content.pageId),
      isNot(contains('p3')),
    );
  });

}


final class _TestClock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}
