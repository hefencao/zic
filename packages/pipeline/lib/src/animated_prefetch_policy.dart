import 'package:domain/domain.dart';

import 'role_window.dart';

/// Shared vocabulary for staged decode-waterline evidence.
///
/// These stages describe decode scheduling only. They must not control encoded
/// network admission or body-flow credit: a slow/blocked nearer decode must not
/// stall a farther page's transfer. Keeping the vocabulary typed still keeps
/// refill tracing and tests stable across package boundaries.
enum DecodeWaterlineStage {
  transitionFirstFrame('t>0'),
  oneFrame('one>0'),
  currentBootstrap('c>2'),
  nextShallow('n>1'),
  next2Shallow('m>1'),
  previousShallow('p>1'),
  currentMid('c>4'),
  nextMid('n>2'),
  currentDeep('c>6'),
  nextDeep('n>3'),
  next2Deep('m>2'),
  nextMax('n>4');

  const DecodeWaterlineStage(this.wireName);

  final String wireName;
}

/// Animated WebP prefetch-flow policy inside the stable Reader 3/7 window.
///
/// The policy never removes a logical/network demand from [RoleWindow]. Every
/// page in the stable previous3/next7 envelope stays eligible so fast browsing
/// can promote it without recreating identity or partial state. Instead, the
/// policy assigns a frame-equivalent transport credit to speculative animated
/// pages. DownloadJob enforces that credit by backpressuring the already-open
/// response body. Credit changes only when that page's own relative role
/// changes; another page's decode waterline never controls its transfer.
///
/// A target of zero means unlimited flow. Static media also receives zero so
/// the historical 3/7 full prefetch behavior is preserved.
final class AnimatedPrefetchPolicy {
  const AnimatedPrefetchPolicy();

  AnimatedPrefetchFlow plan({
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required bool active,
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
      );
    }
    return AnimatedPrefetchFlow(
      active: active,
      targetFramesByIndex: targets,
    );
  }

  int _targetFrames({required int readDistance}) {
    // Near neighbors mirror the existing holder maxima that matter for a fast
    // page change. They are shallow enough to avoid pulling full 154+ frame
    // WebPs while giving the next page useful playback immediately.
    if (readDistance == 1) return 5;
    if (readDistance == 2) return 3;
    if (readDistance == -1) return 2;

    // All remaining positions in the stable 3/7 envelope keep one
    // task-local frame credit until their own role is promoted closer to the
    // viewport. This credit never depends on another page's decode depth.
    // Cross-page encoded pressure is owned by the shared actual-read budget.
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
    required Map<int, int> targetFramesByIndex,
  }) : targetFramesByIndex = Map<int, int>.unmodifiable(targetFramesByIndex);

  final bool active;

  /// Zero means unlimited. Positive values are complete animated WebP frame
  /// credits enforced on the transport body without ending the physical task.
  final Map<int, int> targetFramesByIndex;

  int targetFramesFor(int pageIndex) => targetFramesByIndex[pageIndex] ?? 0;
}
