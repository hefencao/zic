import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('reader binding reconciles demand and viewport playback together', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
    );

    binding.accept(_obs(
      interaction: Interaction.dragging,
      current: 1,
      currentFraction: 0.4,
      target: 2,
      targetFraction: 0.6,
    ));

    expect(coordinator.downloads, isNotEmpty);
    expect(coordinator.decodes, hasLength(2));
    expect(coordinator.uploads, hasLength(2));
    expect(coordinator.viewport?.phase, ViewportPhase.dominant);
    expect(coordinator.viewport?.dominantPageIndex, 2);
    expect(coordinator.playbackIds.keys, containsAll(<int>[1, 2]));
    expect(coordinator.playbackSyncs, 1);
    expect(binding.revision, 1);
  });

  test('viewport playback binds upload identities, not decode-only warm pages', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _deferredChapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
      windowResolver: const RoleResolver(
        forwardEncodedPages: 2,
        backwardEncodedPages: 1,
        forwardDecodePages: 2,
        backwardDecodePages: 1,
        nearRadius: 0,
      ),
      policy: const HeuristicPolicy(decodeWarmPages: true),
    );

    binding.accept(_obs(
      interaction: Interaction.idle,
      current: 2,
      currentFraction: 1,
    ));

    expect(coordinator.decodes.length, greaterThan(coordinator.uploads.length));
    expect(coordinator.uploads, hasLength(1));
    expect(coordinator.playbackIds.keys, unorderedEquals(<int>[2]));
  });

  test('unchanged demand roles still update viewport playback', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
    );

    binding.accept(_obs(
      interaction: Interaction.dragging,
      current: 1,
      currentFraction: 0.7,
      target: 2,
      targetFraction: 0.3,
    ));
    final demandRevision = binding.revision;
    final playbackSyncs = coordinator.playbackSyncs;

    binding.accept(_obs(
      interaction: Interaction.dragging,
      current: 1,
      currentFraction: 0.5,
      target: 2,
      targetFraction: 0.5,
    ));

    expect(binding.revision, demandRevision,
        reason: 'the stable role window must not resubmit demands');
    expect(coordinator.playbackSyncs, playbackSyncs + 1,
        reason: 'viewport coverage is independent from demand reconciliation');
    expect(coordinator.viewport?.dominantPageIndex, 2);
  });

  test('reader binding uses explicit demand and playback contracts', () {
    final demand = _DemandOnly();
    final playback = _PlaybackOnly();
    final binding = ReaderBinding(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: demand,
      playback: playback,
    );

    binding.accept(_obs(
      interaction: Interaction.idle,
      current: 0,
      currentFraction: 1,
    ));

    expect(demand.reconciles, 1);
    expect(playback.syncs, 1);
    expect(playback.ids, isNotEmpty);
  });

  test('reader binding accepts a conservative deferred-resource window', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _deferredChapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
      windowResolver: const RoleResolver(
        forwardEncodedPages: 1,
        backwardEncodedPages: 0,
        nearRadius: 1,
      ),
      policyGuard: const PolicyGuard(maxDownloadDemands: 2),
    );

    binding.accept(_obs(
      interaction: Interaction.idle,
      current: 0,
      currentFraction: 1,
    ));

    expect(coordinator.downloads.length, lessThanOrEqualTo(2));
    expect(
      coordinator.downloads.keys.map((id) => id.content.pageId),
      containsAll(<String>['deferred-0', 'deferred-1']),
    );
  });

  test('continuous binding freezes viewport while scrolling', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
      discretePages: false,
    );

    binding.accept(_obs(
      interaction: Interaction.scrolling,
      current: 0,
      currentFraction: 0.8,
      target: 1,
      targetFraction: 0.2,
    ));

    expect(coordinator.viewport?.phase, ViewportPhase.continuous);
    expect(coordinator.viewport?.freezesPresentation, isTrue);
  });

  test('detaching a binding removes every outstanding demand', () {
    final coordinator = FakeCoordinator(clock: _Clock());
    final binding = ReaderBinding(
      chapter: _chapter(),
      decodeTarget: DecodeTarget(
        physicalWidth: 1080,
        physicalHeight: 1920,
      ),
      clock: _Clock(),
      coordinator: coordinator,
      playback: coordinator,
    );

    binding.accept(_obs(
      interaction: Interaction.idle,
      current: 1,
      currentFraction: 1,
    ));
    expect(coordinator.downloads, isNotEmpty);
    expect(coordinator.decodes, isNotEmpty);
    expect(coordinator.uploads, isNotEmpty);

    binding.detach('reader');

    expect(coordinator.downloads, isEmpty);
    expect(coordinator.decodes, isEmpty);
    expect(coordinator.uploads, isEmpty);
    expect(coordinator.keep, isEmpty);
    expect(
      () => binding.accept(_obs(
        interaction: Interaction.idle,
        current: 0,
        currentFraction: 1,
      )),
      throwsStateError,
    );
  });
}

ChapterManifest _deferredChapter() {
  final pages = List<PageAsset>.generate(
    6,
    (index) => PageAsset(
      pageId: 'deferred-$index',
      chapterId: 'chapter',
      index: index,
      uri: Uri.parse('venera-resource:page-$index'),
      contentKindHint: ContentKindHint.webp,
      animatedHint: true,
    ),
  );
  return ChapterManifest(
    sourceId: 'venera:fixture',
    comicId: 'comic',
    chapter: const Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'Chapter',
      sequence: 1,
      pageCount: 6,
      sourceRevision: 'r1',
    ),
    pages: pages,
    readingDirection: ReadingDirection.ltr,
  );
}

ChapterManifest _chapter() {
  final pages = List<PageAsset>.generate(
    3,
    (index) => PageAsset(
      pageId: 'page-$index',
      chapterId: 'chapter',
      index: index,
      uri: Uri.parse('https://example.test/page-$index.webp'),
      contentKindHint: ContentKindHint.webp,
      animatedHint: true,
    ),
  );
  return ChapterManifest(
    sourceId: 'source',
    comicId: 'comic',
    chapter: const Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'Chapter',
      sequence: 1,
      pageCount: 3,
      sourceRevision: 'r1',
    ),
    pages: pages,
    readingDirection: ReadingDirection.ltr,
  );
}

ReaderObs _obs({
  required Interaction interaction,
  required int current,
  required double currentFraction,
  int? target,
  double targetFraction = 0,
}) {
  return ReaderObs(
    sessionId: 'reader',
    currentIndex: current,
    stableIndex: current,
    interaction: interaction,
    logicalPosition: current.toDouble(),
    velocity: 0,
    currentCoverage: Coverage(
      pageIndex: current,
      assetKey: 'chapter/page-$current',
      fraction: currentFraction,
    ),
    targetCoverage: target == null
        ? null
        : Coverage(
            pageIndex: target,
            assetKey: 'chapter/page-$target',
            fraction: targetFraction,
          ),
    direction: ReadingDirection.ltr,
    timestamp: DateTime.utc(2026),
    monotonicMicros: 0,
  );
}

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 0;
}

final class _DemandOnly implements Coordinator {
  int reconciles = 0;

  @override
  void reconcile(String sessionId, PipelineDelta update) {
    reconciles++;
  }
}

final class _PlaybackOnly implements PlaybackCoordinator {
  int syncs = 0;
  Map<int, DecodeId> ids = const <int, DecodeId>{};

  @override
  void syncPlayback(ViewportState viewport, Map<int, DecodeId> ids) {
    syncs++;
    this.ids = Map<int, DecodeId>.unmodifiable(ids);
  }
}
