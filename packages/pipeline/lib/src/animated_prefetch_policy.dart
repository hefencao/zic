import 'package:domain/domain.dart';

import 'role_window.dart';

const int defaultAnimatedWebpPrefetchBudgetBytes = 50 * 1024 * 1024;

/// Network-admission policy for pages whose current media is known, hinted, or
/// conservatively suspected to be animated WebP.
///
/// This policy never changes [RoleWindow]. The stable Reader logical/retention
/// envelope remains previous 3 / next 7; this class selects the subset that
/// is eligible for network prefetch demand. The mandatory eligibility floor is
/// previous 2 / next 4. Waterline evidence progressively admits the four outer
/// positions. The speculative byte budget is carried with those demands and
/// enforced by NetLane as an execution budget, so eligible pages may queue
/// without all becoming active transports at once.
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

  /// Budget for concurrently active speculative encoded work, excluding
  /// foreground current/visible-transition execution. Pipeline attaches this
  /// value and the per-page estimate to download demand; NetLane enforces it.
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
        estimatedPageBytes: const <int, int>{},
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
    final estimatedPageBytes = <int, int>{
      for (final index in admitted)
        if (index != current) index: _estimatedPageBytes(chapter.pages[index]),
      current: _estimatedPageBytes(chapter.pages[current]),
    };

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
      admitted.add(index);
      estimatedPageBytes[index] = cost;
      estimated += cost;
    }

    return AnimatedPrefetchAdmission(
      active: true,
      admittedIndexes: admitted,
      expansionStage: expansionStage.clamp(0, 4).toInt(),
      estimatedSpeculativeBytes: estimated,
      minimumExceedsBudget: minimumExceedsBudget,
      estimatedPageBytes: estimatedPageBytes,
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
    required Map<int, int> estimatedPageBytes,
  })  : admittedIndexes = Set<int>.unmodifiable(admittedIndexes),
        estimatedPageBytes = Map<int, int>.unmodifiable(estimatedPageBytes);

  final bool active;

  /// Pages eligible for prefetch demand. This is intentionally distinct from
  /// the set of transfers currently active in NetLane.
  final Set<int> admittedIndexes;
  final int expansionStage;
  final int estimatedSpeculativeBytes;
  final bool minimumExceedsBudget;
  final Map<int, int> estimatedPageBytes;

  bool allows(int pageIndex) => admittedIndexes.contains(pageIndex);

  int estimatedBytesFor(int pageIndex) => estimatedPageBytes[pageIndex] ?? 0;
}
