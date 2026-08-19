import 'package:domain/domain.dart';

import 'animated_prefetch_policy.dart';
import 'decode_target.dart';
import 'demand.dart';
import 'role_window.dart';

final class HeuristicPolicy {
  const HeuristicPolicy({
    this.decodeWarmPages = false,
    this.staticOutputBudgetBytes = 96 * 1024 * 1024,
    this.animatedPrefetchPolicy = const AnimatedPrefetchPolicy(),
  });

  final bool decodeWarmPages;
  final AnimatedPrefetchPolicy animatedPrefetchPolicy;

  /// Budget available to speculative static-page outputs. The session-level
  /// [FrameBudgeter] remains authoritative and may trim lower-priority outputs
  /// when actual decoded dimensions exceed this estimate.
  final int staticOutputBudgetBytes;

  DemandPlan createPlan({
    required int revision,
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required DecodeTarget decodeTarget,
    Map<int, bool> runtimeAnimatedPages = const <int, bool>{},
    Set<int> runtimeLocalStaticPages = const <int>{},
    bool assumeUnresolvedStatic = false,
    AnimatedPrefetchFlow? downloadFlow,
    int readDirection = 1,
  }) {
    final downloads = <DownloadId, DownloadDemand>{};
    final decodes = <DecodeId, DecodeDemand>{};
    final uploads = <DecodeId, UploadDemand>{};
    final keep = <ResourceId>{};
    final visibleIndexes = observation.visibleCoverages
        .where((coverage) => coverage.fraction > 0)
        .map((coverage) => coverage.pageIndex)
        .toSet();
    visibleIndexes.add(observation.currentIndex);
    final staticWarmPages = _staticWarmPages(
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: decodeTarget,
      runtimeAnimatedPages: runtimeAnimatedPages,
      assumeUnresolvedStatic: assumeUnresolvedStatic,
      readDirection: readDirection,
    );

    for (final entry in window.roles.entries) {
      final page = chapter.pages[entry.key];
      final role = entry.value;
      final content = ContentId(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapter.chapterId,
        pageId: page.pageId,
      );
      final download = DownloadId(
        content: content,
        sourceRevision: chapter.chapter.sourceRevision,
        canonicalUri: page.uri,
      );
      final decode = DecodeId(
        download: download,
        physicalWidth: decodeTarget.physicalWidth,
        physicalHeight: decodeTarget.physicalHeight,
        pixelFormat: decodeTarget.pixelFormat,
        renderer: decodeTarget.renderer,
      );

      final downloadPriority = _downloadPriority(
        role,
        pageIndex: entry.key,
        currentIndex: observation.currentIndex,
        readDirection: readDirection,
      );
      if (downloadPriority > 0) {
        downloads[download] = DownloadDemand(
          role: role,
          priority: downloadPriority,
          reason: 'heuristic:${role.name}',
          expirationRevision: revision + 1,
          flowTargetFrames: downloadFlow?.targetFramesFor(entry.key) ?? 0,
        );
        keep.add(ResourceId.download(download));
      }

      final staticWarm = staticWarmPages.contains(entry.key);
      final visibleStatic = staticWarm && visibleIndexes.contains(entry.key);
      final decodeWatermark = staticWarm ? 1 : _decodeWatermark(role);
      if (decodeWatermark > 0) {
        decodes[decode] = DecodeDemand(
          role: role,
          priority: staticWarm
              ? _staticWarmPriority(
                  role,
                  visible: visibleStatic,
                  pageIndex: entry.key,
                  currentIndex: observation.currentIndex,
                  readDirection: readDirection,
                )
              : _decodePriority(role),
          targetWatermark: decodeWatermark,
          reason: staticWarm
              ? visibleStatic
                  ? 'heuristic:static-visible:${role.name}'
                  : 'heuristic:static-warm:${role.name}'
              : 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
        keep.add(ResourceId.decode(decode));
      }

      final primaryUpload = role == PageRole.current ||
          role == PageRole.transition;
      final localStaticReady =
          runtimeLocalStaticPages.contains(entry.key) &&
              runtimeAnimatedPages[entry.key] == false;
      final deferHiddenVerticalStaticUpload =
          observation.direction == ReadingDirection.vertical &&
              staticWarm &&
              !primaryUpload &&
              !visibleStatic &&
              !localStaticReady &&
              _verticalPresentationActive(observation.interaction);
      if ((primaryUpload || staticWarm) && !deferHiddenVerticalStaticUpload) {
        uploads[decode] = UploadDemand(
          role: role,
          priority: primaryUpload
              ? switch (role) {
                  PageRole.current => 1000,
                  PageRole.transition => 900,
                  PageRole.last => 850,
                  _ => 0,
                }
              : _staticWarmPriority(
                  role,
                  visible: visibleStatic,
                  pageIndex: entry.key,
                  currentIndex: observation.currentIndex,
                  readDirection: readDirection,
                ),
          reason: staticWarm && !primaryUpload
              ? visibleStatic
                  ? 'heuristic:static-visible:${role.name}'
                  : 'heuristic:static-warm:${role.name}'
              : 'heuristic:${role.name}',
          expirationRevision: revision + 1,
          // A decoded static page backed by immutable local/durable bytes may
          // prepare its external texture before it reaches the viewport. Keep
          // that already-prepared output inside the existing bounded static
          // budget so a fast transition cannot fall back to a black/loading
          // surface while the platform blit catches up.
          retainOutput: visibleStatic || localStaticReady,
        );
      }
    }

    final retainedIndex = window.retainedIndex;
    if (retainedIndex != null &&
        retainedIndex >= 0 &&
        retainedIndex < chapter.pages.length &&
        retainedIndex != observation.currentIndex) {
      final page = chapter.pages[retainedIndex];
      final content = ContentId(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapter.chapterId,
        pageId: page.pageId,
      );
      final download = DownloadId(
        content: content,
        sourceRevision: chapter.chapter.sourceRevision,
        canonicalUri: page.uri,
      );
      final decode = DecodeId(
        download: download,
        physicalWidth: decodeTarget.physicalWidth,
        physicalHeight: decodeTarget.physicalHeight,
        pixelFormat: decodeTarget.pixelFormat,
        renderer: decodeTarget.renderer,
      );
      // Retaining the previous current output is independent from its
      // relative network/decode role. If it is still inside the 7/3 window,
      // the regular loop above keeps downloading/decoding it as previous or
      // next. This upload-only overlay freezes the already-presented output.
      uploads[decode] = UploadDemand(
        role: PageRole.last,
        priority: 850,
        reason: 'heuristic:last-output-retained',
        expirationRevision: revision + 1,
      );
    }

    return DemandPlan(
      revision: revision,
      downloads: downloads,
      decodes: decodes,
      uploads: uploads,
      keep: keep,
    );
  }

  bool _verticalPresentationActive(Interaction interaction) => switch (interaction) {
        Interaction.dragging ||
        Interaction.scrolling ||
        Interaction.settling => true,
        Interaction.idle ||
        Interaction.scrubbing ||
        Interaction.jumping => false,
      };

  Set<int> _staticWarmPages({
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required DecodeTarget decodeTarget,
    required Map<int, bool> runtimeAnimatedPages,
    required bool assumeUnresolvedStatic,
    required int readDirection,
  }) {
    final visibleIndexes = observation.visibleCoverages
        .where((coverage) => coverage.fraction > 0)
        .map((coverage) => coverage.pageIndex)
        .toSet();
    visibleIndexes.add(observation.currentIndex);

    bool isStaticCandidate(MapEntry<int, PageRole> entry) {
      final runtimeAnimated = runtimeAnimatedPages[entry.key];
      if (runtimeAnimated != null) return !runtimeAnimated;
      return assumeUnresolvedStatic || !chapter.pages[entry.key].animatedHint;
    }

    bool isStableDecodeRole(PageRole role) => switch (role) {
          PageRole.current ||
          PageRole.transition ||
          PageRole.next ||
          PageRole.next2 ||
          PageRole.previous => true,
          PageRole.last ||
          PageRole.near ||
          PageRole.far ||
          PageRole.detached => false,
        };

    // Static single-frame knowledge may lower the cost of a page that is
    // already inside the stable +2/-1 decode window, but it must not enlarge
    // that window. The old policy let every likely-static page in the 7/3
    // encoded window create decode + upload work; device traces showed 6-7
    // speculative warm decodes/uploads competing with current execution.
    // Actually visible vertical pages remain authoritative even if they fall
    // outside the relative decode window (for example several very short
    // stitched pages in one viewport).
    final candidates = window.roles.entries
        .where(isStaticCandidate)
        .where(
          (entry) =>
              visibleIndexes.contains(entry.key) ||
              isStableDecodeRole(entry.value),
        )
        .toList(growable: false);

    final selected = <int>{};
    // Visibility is not speculative and therefore does not consume the
    // speculative output budget. FrameBudget remains the authoritative owner
    // if actual output dimensions later exceed memory limits.
    for (final entry in candidates) {
      if (visibleIndexes.contains(entry.key)) selected.add(entry.key);
    }

    if (staticOutputBudgetBytes <= 0) return selected;
    final speculative = candidates
        .where((entry) => !visibleIndexes.contains(entry.key))
        .toList(growable: false);
    speculative.sort((a, b) {
      final aPriority = _staticPriority(
        a.value,
        pageIndex: a.key,
        currentIndex: observation.currentIndex,
        readDirection: readDirection,
      );
      final bPriority = _staticPriority(
        b.value,
        pageIndex: b.key,
        currentIndex: observation.currentIndex,
        readDirection: readDirection,
      );
      final priorityOrder = bPriority.compareTo(aPriority);
      if (priorityOrder != 0) return priorityOrder;
      return (a.key - observation.currentIndex)
          .abs()
          .compareTo((b.key - observation.currentIndex).abs());
    });
    var remaining = staticOutputBudgetBytes;
    for (final entry in speculative) {
      final estimate = _estimatedStaticOutputBytes(
        chapter.pages[entry.key],
        decodeTarget,
        vertical: observation.direction == ReadingDirection.vertical,
      );
      if (selected.isNotEmpty && estimate > remaining) continue;
      selected.add(entry.key);
      remaining = (remaining - estimate)
          .clamp(0, staticOutputBudgetBytes)
          .toInt();
    }
    return selected;
  }

  int _estimatedStaticOutputBytes(
    PageAsset page,
    DecodeTarget decodeTarget, {
    required bool vertical,
  }) {
    final sourceWidth = page.width;
    final sourceHeight = page.height;
    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      return decodeTarget.physicalWidth *
          decodeTarget.physicalHeight *
          4;
    }
    final widthScale = decodeTarget.physicalWidth / sourceWidth;
    final heightScale = decodeTarget.physicalHeight / sourceHeight;
    final scale = vertical
        ? widthScale.clamp(0.0, 1.0)
        : widthScale < heightScale
            ? widthScale.clamp(0.0, 1.0)
            : heightScale.clamp(0.0, 1.0);
    final projectedWidth = (sourceWidth * scale)
        .round()
        .clamp(1, 1 << 20)
        .toInt();
    final projectedHeight = (sourceHeight * scale)
        .round()
        .clamp(1, 1 << 20)
        .toInt();
    return projectedWidth * projectedHeight * 4;
  }

  int _staticWarmPriority(
    PageRole role, {
    required bool visible,
    required int pageIndex,
    required int currentIndex,
    required int readDirection,
  }) {
    final base = _staticPriority(
      role,
      pageIndex: pageIndex,
      currentIndex: currentIndex,
      readDirection: readDirection,
    );
    // A non-current page that is already on screen must beat speculative
    // next/previous output preparation without pretending to be current or a
    // drag transition.
    return visible && role != PageRole.current && role != PageRole.transition
        ? (base < 880 ? 880 : base)
        : base;
  }

  int _staticPriority(
    PageRole role, {
    required int pageIndex,
    required int currentIndex,
    required int readDirection,
  }) =>
      switch (role) {
        PageRole.current => 1000,
        PageRole.transition => 900,
        PageRole.last => 850,
        PageRole.next => 820,
        PageRole.next2 => 800,
        PageRole.previous => 780,
        PageRole.near || PageRole.far => _distanceDownloadPriority(
            pageIndex: pageIndex,
            currentIndex: currentIndex,
            readDirection: readDirection,
          ),
        PageRole.detached => 0,
      };

  int _downloadPriority(
    PageRole role, {
    required int pageIndex,
    required int currentIndex,
    required int readDirection,
  }) {
    return switch (role) {
      PageRole.current => 1000,
      PageRole.last => 0,
      PageRole.transition => 900,
      PageRole.next => 820,
      PageRole.next2 => 800,
      PageRole.previous => 780,
      PageRole.near || PageRole.far => _distanceDownloadPriority(
          pageIndex: pageIndex,
          currentIndex: currentIndex,
          readDirection: readDirection,
        ),
      PageRole.detached => 0,
    };
  }

  int _distanceDownloadPriority({
    required int pageIndex,
    required int currentIndex,
    required int readDirection,
  }) {
    final offset = pageIndex - currentIndex;
    final distance = offset.abs();
    final readDistance = offset * (readDirection < 0 ? -1 : 1);
    if (readDistance > 0) {
      return (760 - (distance - 3).clamp(0, 10) * 20)
          .clamp(540, 760)
          .toInt();
    }
    return (660 - (distance - 2).clamp(0, 10) * 20)
        .clamp(520, 660)
        .toInt();
  }

  int _decodePriority(PageRole role) => switch (role) {
        PageRole.current => 1000,
        PageRole.transition => 900,
        PageRole.next => decodeWarmPages ? 720 : 0,
        PageRole.next2 => decodeWarmPages ? 700 : 0,
        PageRole.previous => decodeWarmPages ? 680 : 0,
        PageRole.last || PageRole.near || PageRole.far || PageRole.detached => 0,
      };

  int _decodeWatermark(PageRole role) => switch (role) {
        PageRole.current => 7,
        PageRole.transition => 5,
        PageRole.next => decodeWarmPages ? 5 : 0,
        PageRole.next2 => decodeWarmPages ? 3 : 0,
        PageRole.previous => decodeWarmPages ? 2 : 0,
        PageRole.last || PageRole.near || PageRole.far || PageRole.detached => 0,
      };
}
