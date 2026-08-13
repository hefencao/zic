import 'package:domain/domain.dart';

import 'role_window.dart';

/// Animated WebP prefetch-flow policy inside the stable Reader 3/7 window.
///
/// The policy never removes a logical/network demand from [RoleWindow]. Every
/// page in the stable previous3/next7 envelope stays eligible so fast browsing
/// can promote it without recreating identity or partial state. Instead, the
/// policy assigns a frame-equivalent transport credit to speculative animated
/// pages. DownloadJob enforces that credit by backpressuring the already-open
/// response body; a later waterline/current promotion raises the same task's
/// credit and resumes the same response.
///
/// A target of zero means unlimited flow. Static media also receives zero so
/// the historical 3/7 full prefetch behavior is preserved.
final class AnimatedPrefetchPolicy {
  const AnimatedPrefetchPolicy();

  /// Existing staged decode-waterline evidence remains the only expansion
  /// signal. dev.249 changes what expands: outer pages already have demand;
  /// these stages raise their retained response-body frame credit.
  int expansionStageForWaterline(String waterline) => switch (waterline) {
        'c>4' => 1,
        'n>2' => 2,
        'c>6' => 3,
        'n>3' => 4,
        _ => 0,
      };

  AnimatedPrefetchFlow plan({
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required bool active,
    required int expansionStage,
    int readDirection = 1,
  }) {
    final current = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    final targets = <int, int>{};
    for (final entry in window.roles.entries) {
      final index = entry.key;
      if (!active) {
        targets[index] = 0;
        continue;
      }
      final role = entry.value;
      if (index == current ||
          role == PageRole.current ||
          role == PageRole.transition ||
          _visible(observation, index)) {
        targets[index] = 0;
        continue;
      }
      targets[index] = _targetFrames(
        readDistance: (index - current) * (readDirection < 0 ? -1 : 1),
        expansionStage: expansionStage,
      );
    }
    return AnimatedPrefetchFlow(
      active: active,
      expansionStage: expansionStage.clamp(0, 4).toInt(),
      targetFramesByIndex: targets,
    );
  }

  int _targetFrames({
    required int readDistance,
    required int expansionStage,
  }) {
    // Near neighbors mirror the existing holder maxima that matter for a fast
    // page change. They are shallow enough to avoid pulling full 154+ frame
    // WebPs while giving the next page useful playback immediately.
    if (readDistance == 1) return 5;
    if (readDistance == 2) return 3;
    if (readDistance == -1) return 2;

    // All remaining positions in the stable 3/7 envelope start with one
    // complete animation frame. Existing c/n staged-waterline evidence raises
    // selected outer bands to two frames without changing their window
    // membership or opening/closing the transport task itself.
    if ((readDistance == 3 || readDistance == 4) && expansionStage >= 1) return 2;
    if ((readDistance == -2 || readDistance == -3) && expansionStage >= 2) return 2;
    if ((readDistance == 5 || readDistance == 6) && expansionStage >= 3) return 2;
    if (readDistance == 7 && expansionStage >= 4) return 2;
    return 1;
  }

  bool _visible(ReaderObs observation, int index) {
    if (observation.visibleCoverages.any(
      (coverage) => coverage.pageIndex == index && coverage.fraction > 0,
    )) {
      return true;
    }
    final target = observation.targetCoverage;
    return target != null && target.pageIndex == index && target.fraction > 0;
  }
}

final class AnimatedPrefetchFlow {
  AnimatedPrefetchFlow({
    required this.active,
    required this.expansionStage,
    required Map<int, int> targetFramesByIndex,
  }) : targetFramesByIndex = Map<int, int>.unmodifiable(targetFramesByIndex);

  final bool active;
  final int expansionStage;

  /// Zero means unlimited. Positive values are complete animated WebP frame
  /// credits enforced on the transport body without ending the physical task.
  final Map<int, int> targetFramesByIndex;

  int targetFramesFor(int pageIndex) => targetFramesByIndex[pageIndex] ?? 0;
}
