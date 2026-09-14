import 'package:domain/domain.dart';

import 'coverage_thresholds.dart';

enum ViewportPhase { idle, dominant, overlap, continuous }

final class ViewportState {
  const ViewportState({
    required this.phase,
    required this.currentPageIndex,
    required this.dominantPageIndex,
    this.targetPageIndex,
  });

  final ViewportPhase phase;
  final int currentPageIndex;
  final int? targetPageIndex;
  final int? dominantPageIndex;

  bool get freezesPresentation =>
      phase == ViewportPhase.overlap || phase == ViewportPhase.continuous;
}

final class ViewportResolver {
  const ViewportResolver({
    this.dominantThreshold = defaultDominantCoverageThreshold,
    this.overlapThreshold = defaultTransitionCoverageThreshold,
  })  : assert(dominantThreshold > 0 && dominantThreshold <= 1),
        assert(overlapThreshold >= 0 && overlapThreshold < dominantThreshold);

  final double dominantThreshold;
  final double overlapThreshold;

  ViewportState resolve(
    ReaderObs observation, {
    bool discretePages = true,
  }) {
    final current = observation.currentCoverage;
    final target = observation.targetCoverage;

    if (!discretePages && observation.interaction != Interaction.idle) {
      return ViewportState(
        phase: ViewportPhase.continuous,
        currentPageIndex: current.pageIndex,
        targetPageIndex: target?.pageIndex,
        dominantPageIndex: null,
      );
    }

    if (target == null || observation.interaction == Interaction.idle) {
      return ViewportState(
        phase: ViewportPhase.idle,
        currentPageIndex: current.pageIndex,
        targetPageIndex: target?.pageIndex,
        dominantPageIndex: current.pageIndex,
      );
    }

    if (target.fraction >= dominantThreshold ||
        current.fraction >= dominantThreshold) {
      // PageView updates currentPageIndex at the 50% boundary. A strict target
      // comparison means the new stable page wins an exact tie, so playback
      // ownership changes once without a 40%..60% interval that freezes both.
      final dominant = target.fraction > current.fraction
          ? target.pageIndex
          : current.pageIndex;
      return ViewportState(
        phase: ViewportPhase.dominant,
        currentPageIndex: current.pageIndex,
        targetPageIndex: target.pageIndex,
        dominantPageIndex: dominant,
      );
    }

    if (current.fraction >= overlapThreshold &&
        target.fraction >= overlapThreshold) {
      return ViewportState(
        phase: ViewportPhase.overlap,
        currentPageIndex: current.pageIndex,
        targetPageIndex: target.pageIndex,
        dominantPageIndex: null,
      );
    }

    final dominant = target.fraction > current.fraction
        ? target.pageIndex
        : current.pageIndex;
    return ViewportState(
      phase: ViewportPhase.dominant,
      currentPageIndex: current.pageIndex,
      targetPageIndex: target.pageIndex,
      dominantPageIndex: dominant,
    );
  }
}
