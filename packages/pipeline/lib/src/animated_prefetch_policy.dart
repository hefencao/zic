import 'package:domain/domain.dart';

import 'role_window.dart';

const int defaultAnimatedWebpPrefetchBudgetBytes = 50 * 1024 * 1024;

/// Network-admission policy for pages whose current media is known, hinted, or
/// conservatively suspected to be animated WebP.
///
/// This policy never changes [RoleWindow]. The stable Reader logical/retention
/// envelope remains previous 3 / next 7; this class selects only the subset
/// that is allowed to create network download demand. The mandatory network
/// floor is previous 2 / next 4. Waterline evidence may progressively admit
/// the four outer positions, subject to the speculative byte budget.
final class AnimatedPrefetchPolicy {
  const AnimatedPrefetchPolicy({
    this.minimumForwardPages = 4,
    this.minimumBackwardPages = 2,
    this.maximumForwardPages = 7,
    this.maximumBackwardPages = 3,
    this.maxSpeculativeBytes = defaultAnimatedWebpPrefetchBudgetBytes,
    this.unknownPageEstimateBytes = 12 * 1024 * 1024,
  });

  final int minimumForwardPages;
  final int minimumBackwardPages;
  final int maximumForwardPages;
  final int maximumBackwardPages;

  /// Budget for speculative encoded bytes excluding the current page.
  ///
  /// The previous2/next4 floor is a hard count lower bound. If that floor is
  /// already larger than the byte budget, it remains admitted and the result
  /// reports [AnimatedPrefetchAdmission.minimumExceedsBudget]; no outer page
  /// will be admitted until the estimate fits again.
  final int maxSpeculativeBytes;

  /// Conservative cost for sources that do not expose a page byte length.
  final int unknownPageEstimateBytes;

  /// Maps completed decode-waterline evidence to the monotonic outer-window
  /// expansion stage. These stages mirror the existing staged c/n refill
  /// sequence without moving network policy into the sessions package.
  int expansionStageForWaterline(String waterline) => switch (waterline) {
        'c>4' => 1,
        'n>2' => 2,
        'c>6' => 3,
        'n>3' => 4,
        _ => 0,
      };

  AnimatedPrefetchAdmission admit({
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required bool active,
    required int expansionStage,
  }) {
    if (!active) {
      return AnimatedPrefetchAdmission(
        active: false,
        admittedIndexes: window.roles.keys.toSet(),
        expansionStage: 4,
        estimatedSpeculativeBytes: 0,
        minimumExceedsBudget: false,
      );
    }

    final current = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    final admitted = <int>{current};

    void admitIfLogical(int index) {
      if (index < 0 || index >= chapter.pages.length) return;
      if (window.roleOf(index) == PageRole.detached) return;
      admitted.add(index);
    }

    // Hard lower envelope: previous2 / next4. It is count-authoritative even
    // when the estimated encoded byte cost already exceeds the configured
    // budget.
    for (var offset = 1; offset <= minimumForwardPages; offset++) {
      admitIfLogical(current + offset);
    }
    for (var offset = 1; offset <= minimumBackwardPages; offset++) {
      admitIfLogical(current - offset);
    }

    // Visible transition pages are foreground facts, not speculation. Keep
    // them network-admitted even if a non-standard viewport puts one outside
    // the ordinary lower envelope.
    for (final coverage in observation.visibleCoverages) {
      if (coverage.fraction > 0) admitIfLogical(coverage.pageIndex);
    }
    final target = observation.targetCoverage;
    if (target != null && target.fraction > 0) {
      admitIfLogical(target.pageIndex);
    }

    var estimated = _estimateSpeculativeBytes(
      chapter: chapter,
      indexes: admitted,
      currentIndex: current,
    );
    final minimumExceedsBudget = maxSpeculativeBytes > 0 &&
        estimated > maxSpeculativeBytes;

    // The upper-envelope openings are monotonic and intentionally asymmetric:
    // next5 first, then previous3, then next6 and next7. This preserves the
    // static-oriented logical 3/7 window while expensive animation downloads
    // only expand when deeper current/neighbor waterlines prove headroom.
    final candidates = <({int stage, int index})>[
      (stage: 1, index: current + 5),
      (stage: 2, index: current - 3),
      (stage: 3, index: current + 6),
      (stage: 4, index: current + 7),
    ];
    for (final candidate in candidates) {
      if (candidate.stage > expansionStage) continue;
      final index = candidate.index;
      if (index < 0 || index >= chapter.pages.length) continue;
      if (window.roleOf(index) == PageRole.detached || admitted.contains(index)) {
        continue;
      }
      final offset = index - current;
      if (offset > maximumForwardPages || -offset > maximumBackwardPages) {
        continue;
      }
      final cost = _estimatedPageBytes(chapter.pages[index]);
      if (maxSpeculativeBytes > 0 && estimated + cost > maxSpeculativeBytes) {
        continue;
      }
      admitted.add(index);
      estimated += cost;
    }

    return AnimatedPrefetchAdmission(
      active: true,
      admittedIndexes: admitted,
      expansionStage: expansionStage.clamp(0, 4).toInt(),
      estimatedSpeculativeBytes: estimated,
      minimumExceedsBudget: minimumExceedsBudget,
    );
  }

  int _estimateSpeculativeBytes({
    required ChapterManifest chapter,
    required Set<int> indexes,
    required int currentIndex,
  }) {
    var total = 0;
    for (final index in indexes) {
      if (index == currentIndex || index < 0 || index >= chapter.pages.length) {
        continue;
      }
      total += _estimatedPageBytes(chapter.pages[index]);
    }
    return total;
  }

  int _estimatedPageBytes(PageAsset page) {
    final known = page.byteLength;
    if (known != null && known > 0) return known;
    return unknownPageEstimateBytes;
  }
}

final class AnimatedPrefetchAdmission {
  AnimatedPrefetchAdmission({
    required this.active,
    required Set<int> admittedIndexes,
    required this.expansionStage,
    required this.estimatedSpeculativeBytes,
    required this.minimumExceedsBudget,
  }) : admittedIndexes = Set<int>.unmodifiable(admittedIndexes);

  final bool active;
  final Set<int> admittedIndexes;
  final int expansionStage;
  final int estimatedSpeculativeBytes;
  final bool minimumExceedsBudget;

  bool allows(int pageIndex) => admittedIndexes.contains(pageIndex);
}
