import 'package:domain/domain.dart';

import 'decode_target.dart';
import 'demand.dart';
import 'role_window.dart';

final class HeuristicPolicy {
  const HeuristicPolicy({
    this.decodeWarmPages = false,
    this.staticOutputBudgetBytes = 96 * 1024 * 1024,
  });

  final bool decodeWarmPages;

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
    bool assumeUnresolvedStatic = false,
  }) {
    final downloads = <DownloadId, DownloadDemand>{};
    final decodes = <DecodeId, DecodeDemand>{};
    final uploads = <DecodeId, UploadDemand>{};
    final keep = <ResourceId>{};
    final staticWarmPages = _staticWarmPages(
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: decodeTarget,
      runtimeAnimatedPages: runtimeAnimatedPages,
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
      );
      if (downloadPriority > 0) {
        downloads[download] = DownloadDemand(
          role: role,
          priority: downloadPriority,
          reason: 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
        keep.add(ResourceId.download(download));
      }

      final staticWarm = staticWarmPages.contains(entry.key);
      final decodeWatermark = role == PageRole.last
          ? 0
          : staticWarm
              ? 1
              : _decodeWatermark(role);
      if (decodeWatermark > 0) {
        decodes[decode] = DecodeDemand(
          role: role,
          priority: staticWarm
              ? _staticPriority(
                  role,
                  pageIndex: entry.key,
                  currentIndex: observation.currentIndex,
                )
              : _decodePriority(role),
          targetWatermark: decodeWatermark,
          reason: staticWarm
              ? 'heuristic:static-warm:${role.name}'
              : 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
        keep.add(ResourceId.decode(decode));
      }

      final primaryUpload = role == PageRole.current ||
          role == PageRole.transition ||
          role == PageRole.last;
      if (primaryUpload || staticWarm) {
        uploads[decode] = UploadDemand(
          role: role,
          priority: primaryUpload
              ? switch (role) {
                  PageRole.current => 1000,
                  PageRole.transition => 900,
                  PageRole.last => 850,
                  _ => 0,
                }
              : _staticPriority(
                  role,
                  pageIndex: entry.key,
                  currentIndex: observation.currentIndex,
                ),
          reason: staticWarm && !primaryUpload
              ? 'heuristic:static-warm:${role.name}'
              : 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
      }
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
    required ReaderObs observation,
    required RoleWindow window,
    required DecodeTarget decodeTarget,
    required Map<int, bool> runtimeAnimatedPages,
    required bool assumeUnresolvedStatic,
  }) {
    if (staticOutputBudgetBytes <= 0) return const <int>{};
    final candidates = window.roles.entries.where((entry) {
      final runtimeAnimated = runtimeAnimatedPages[entry.key];
      if (runtimeAnimated != null) return !runtimeAnimated;
      return assumeUnresolvedStatic || !chapter.pages[entry.key].animatedHint;
    }).toList();
    candidates.sort((a, b) {
      final aPriority = _staticPriority(
        a.value,
        pageIndex: a.key,
        currentIndex: observation.currentIndex,
      );
      final bPriority = _staticPriority(
        b.value,
        pageIndex: b.key,
        currentIndex: observation.currentIndex,
      );
      final priorityOrder = bPriority.compareTo(aPriority);
      if (priorityOrder != 0) return priorityOrder;
      return (a.key - observation.currentIndex)
          .abs()
          .compareTo((b.key - observation.currentIndex).abs());
    });
    final selected = <int>{};
    var remaining = staticOutputBudgetBytes;
    for (final entry in candidates) {
      final estimate = _estimatedStaticOutputBytes(
        chapter.pages[entry.key],
        decodeTarget,
        vertical: observation.direction == ReadingDirection.vertical,
      );
      if (selected.isNotEmpty && estimate > remaining) {
        continue;
      }
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

  int _staticPriority(
    PageRole role, {
    required int pageIndex,
    required int currentIndex,
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
          ),
        PageRole.detached => 0,
      };

  int _downloadPriority(
    PageRole role, {
    required int pageIndex,
    required int currentIndex,
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
        ),
      PageRole.detached => 0,
    };
  }

  int _distanceDownloadPriority({
    required int pageIndex,
    required int currentIndex,
  }) {
    final distance = (pageIndex - currentIndex).abs();
    if (pageIndex > currentIndex) {
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
