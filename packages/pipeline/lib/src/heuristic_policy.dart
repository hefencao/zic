import 'package:domain/domain.dart';

import 'animated_prefetch_policy.dart';
import 'decode_target.dart';
import 'demand.dart';
import 'interaction_policy.dart';
import 'page_media_evidence.dart';
import 'role_window.dart';

final class HeuristicPolicy {
  const HeuristicPolicy({
    this.decodeWarmPages = false,
    this.animatedPrefetchPolicy = const AnimatedPrefetchPolicy(),
  });

  final bool decodeWarmPages;
  final AnimatedPrefetchPolicy animatedPrefetchPolicy;

  DemandPlan createPlan({
    required int revision,
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required DecodeTarget decodeTarget,
    Map<int, bool> runtimeAnimatedPages = const <int, bool>{},
    Set<int> runtimeLocalStaticPages = const <int>{},
    Set<int> runtimeExternalStaticPages = const <int>{},
    Set<int> runtimeWebpCostPages = const <int>{},
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
      window: window,
      runtimeAnimatedPages: runtimeAnimatedPages,
      runtimeWebpCostPages: runtimeWebpCostPages,
      assumeUnresolvedStatic: assumeUnresolvedStatic,
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
        pageIndexHint: entry.key,
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
      final pagedTargetPreupload =
          observation.direction != ReadingDirection.vertical &&
              observation.targetCoverage?.pageIndex == entry.key &&
              (role == PageRole.next || role == PageRole.previous) &&
              decodeWatermark > 0 &&
              isPresentationMotionInteraction(observation.interaction);
      final localStaticReady =
          runtimeLocalStaticPages.contains(entry.key) &&
              runtimeAnimatedPages[entry.key] == false;
      final externalStatic =
          runtimeExternalStaticPages.contains(entry.key) &&
              runtimeAnimatedPages[entry.key] == false;
      final deadlineStaticPreupload =
          role == PageRole.next ||
          role == PageRole.next2 ||
          role == PageRole.previous;
      final deferHiddenVerticalNativeStaticUpload =
          observation.direction == ReadingDirection.vertical &&
              staticWarm &&
              !primaryUpload &&
              !visibleStatic &&
              !deadlineStaticPreupload &&
              !localStaticReady &&
              !externalStatic &&
              isPresentationMotionInteraction(observation.interaction);
      if ((primaryUpload || staticWarm || pagedTargetPreupload) &&
          !deferHiddenVerticalNativeStaticUpload) {
        uploads[decode] = UploadDemand(
          role: role,
          priority: primaryUpload
              ? switch (role) {
                  PageRole.current => 1000,
                  PageRole.transition => 900,
                  PageRole.last => 850,
                  _ => 0,
                }
              : pagedTargetPreupload && !staticWarm
                  ? 820
                  : _staticWarmPriority(
                      role,
                      visible: visibleStatic,
                      pageIndex: entry.key,
                      currentIndex: observation.currentIndex,
                      readDirection: readDirection,
                    ),
          reason: pagedTargetPreupload && !staticWarm
              ? role == PageRole.previous
                  ? 'heuristic:paged-previous-preupload'
                  : 'heuristic:paged-next-preupload'
              : staticWarm && !primaryUpload
                  ? visibleStatic
                      ? 'heuristic:static-visible:${role.name}'
                      : 'heuristic:static-warm:${role.name}'
                  : 'heuristic:${role.name}',
          expirationRevision: revision + 1,
          // A decoded static page in the existing next/next2/previous
          // deadline window may prepare its one output before viewport entry.
          // Keep that already-prepared output under FrameBudgeter so continuous
          // vertical motion cannot turn decode-ahead into visible upload-ahead
          // debt. Local/durable static keeps the same retention proof. No new
          // page-count or estimated-output-byte admission budget is created.
          retainOutput:
              visibleStatic || localStaticReady || deadlineStaticPreupload,
          viewportVisible: primaryUpload || visibleStatic,
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
        pageIndexHint: retainedIndex,
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
        viewportVisible: visibleIndexes.contains(retainedIndex),
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

  Set<int> _staticWarmPages({
    required ChapterManifest chapter,
    required RoleWindow window,
    required Map<int, bool> runtimeAnimatedPages,
    required Set<int> runtimeWebpCostPages,
    required bool assumeUnresolvedStatic,
  }) {
    bool isStaticCandidate(MapEntry<int, PageRole> entry) {
      final runtimeAnimated = runtimeAnimatedPages[entry.key];
      if (runtimeAnimated != null) return !runtimeAnimated;
      final page = chapter.pages[entry.key];
      // An exact runtime WebP sniff is page-local evidence and must wait for
      // that page's decoder classification. The existing two-page
      // authoritative-static chapter inference may admit other unresolved
      // pages, including WebP hints whose exact body has not been sniffed yet.
      if (runtimeWebpCostPages.contains(entry.key)) return false;
      if (assumeUnresolvedStatic) return true;
      return hasStaticContentEvidence(page);
    }

    // A static page needs one frame, but it does not need another page-count
    // or estimated-byte admission policy. RoleWindow owns the 3/7 logical
    // envelope, StagedDecodeRefillPolicy releases one-frame work in priority
    // order, and SpeculativeEncodedReadBudget owns actual speculative encoded
    // I/O. Native decoded/output residency remains FrameBudgeter-owned; external
    // Flutter fallback rasters remain PipelinePresentationRasterCache-owned by
    // App composition. No
    // estimated static-output admission budget is duplicated in Pipeline.
    return window.roles.entries
        .where(isStaticCandidate)
        .map((entry) => entry.key)
        .toSet();
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
