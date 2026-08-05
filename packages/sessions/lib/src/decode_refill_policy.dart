import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';

typedef DecodeDepthLookup = int Function(DecodeId id);
typedef DecodeTerminalLookup = bool Function(DecodeId id);
typedef DecodeEligibilityLookup = bool Function(DecodeId id);
typedef DecodeSatisfiedLookup = bool Function(DecodeId id);

/// One deterministic refill selected from the live page waterlines.
final class DecodeRefillDecision {
  const DecodeRefillDecision({
    required this.id,
    required this.role,
    required this.stage,
    required this.depth,
    required this.threshold,
    required this.targetWatermark,
  });

  final DecodeId id;
  final PageRole role;
  final String stage;
  final int depth;
  final int threshold;
  final int targetWatermark;
}

/// Staged current/neighbor decode-waterline policy.
///
/// The pipeline provides role maxima; this policy releases only the next
/// allowed refill from real holder depths. Thresholds are strict waterlines:
/// a depth at or below the threshold refills to the smallest value above it;
/// cursor batching may overshoot naturally.
///
/// A drag target in `transition` always retains an independent first-frame
/// bootstrap before current deepening. Deeper refills are then released in
/// this order: `c3, n2, m2, p2, c5, n3, c7, n4, m3, n5`.
/// The role maxima are therefore c/n/m/p = 7/5/3/2; last remains keep-only.
///
/// During a drag, `transition` is the logical n. Its first frame is independent
/// so page switching cannot wait for current to reach depth three; after that
/// it receives every n stage. `last` never refills; its existing upload output
/// is frozen and retained.
final class StagedDecodeRefillPolicy {
  const StagedDecodeRefillPolicy();

  DecodeRefillDecision? next({
    required Map<DecodeId, DecodeDemand> demands,
    required DecodeDepthLookup depthOf,
    DecodeTerminalLookup terminalOf = _neverTerminal,
    DecodeEligibilityLookup eligibleOf = _alwaysEligible,
    DecodeSatisfiedLookup satisfiedOf = _neverSatisfied,
  }) {
    final oneFrame = demands.entries
        .where(
          (entry) =>
              entry.value.targetWatermark == 1 &&
              eligibleOf(entry.key) &&
              !terminalOf(entry.key) &&
              !satisfiedOf(entry.key) &&
              depthOf(entry.key) < 1,
        )
        .toList(growable: false)
      ..sort((a, b) {
        final priority = b.value.priority.compareTo(a.value.priority);
        if (priority != 0) return priority;
        return a.key.key.compareTo(b.key.key);
      });
    final oneFrameDecision = oneFrame.isEmpty
        ? null
        : DecodeRefillDecision(
            id: oneFrame.first.key,
            role: oneFrame.first.value.role,
            stage: 'one>0',
            depth: depthOf(oneFrame.first.key),
            threshold: 0,
            targetWatermark: 1,
          );

    final byRole = <PageRole, DecodeId>{};
    for (final entry in demands.entries) {
      byRole[entry.value.role] = entry.key;
    }

    final transition = byRole[PageRole.transition];
    DecodeRefillDecision? transitionFirstFrameDecision;
    if (transition != null &&
        eligibleOf(transition) &&
        !terminalOf(transition) &&
        !satisfiedOf(transition) &&
        depthOf(transition) < 1) {
      final demand = demands[transition]!;
      transitionFirstFrameDecision = DecodeRefillDecision(
        id: transition,
        role: demand.role,
        stage: 't>0',
        depth: depthOf(transition),
        threshold: 0,
        targetWatermark: 1,
      );
    }
    final logical = <_WaterlineRole, DecodeId?>{
      _WaterlineRole.current: byRole[PageRole.current],
      _WaterlineRole.next: transition ?? byRole[PageRole.next],
      _WaterlineRole.next2: byRole[PageRole.next2] ??
          (transition == null ? null : byRole[PageRole.next]),
      _WaterlineRole.previous: byRole[PageRole.previous],
    };

    const steps = <_RefillStep>[
      _RefillStep(_WaterlineRole.current, 2, 'c>2'),
      _RefillStep(_WaterlineRole.next, 1, 'n>1'),
      _RefillStep(_WaterlineRole.next2, 1, 'm>1'),
      _RefillStep(_WaterlineRole.previous, 1, 'p>1'),
      _RefillStep(_WaterlineRole.current, 4, 'c>4'),
      _RefillStep(_WaterlineRole.next, 2, 'n>2'),
      _RefillStep(_WaterlineRole.current, 6, 'c>6'),
      _RefillStep(_WaterlineRole.next, 3, 'n>3'),
      _RefillStep(_WaterlineRole.next2, 2, 'm>2'),
      _RefillStep(_WaterlineRole.next, 4, 'n>4'),
    ];

    DecodeRefillDecision? stagedDecision;
    for (final step in steps) {
      final id = logical[step.role];
      if (id == null ||
          !eligibleOf(id) ||
          terminalOf(id) ||
          satisfiedOf(id)) {
        continue;
      }
      final demand = demands[id]!;
      final maximum = demand.targetWatermark;
      if (maximum <= step.threshold) {
        continue;
      }
      final depth = depthOf(id);
      if (depth > step.threshold) {
        continue;
      }
      stagedDecision = DecodeRefillDecision(
        id: id,
        role: demand.role,
        stage: step.stage,
        depth: depth,
        threshold: step.threshold,
        targetWatermark: (step.threshold + 1).clamp(1, maximum).toInt(),
      );
      break;
    }
    if (transitionFirstFrameDecision != null) {
      if (oneFrameDecision == null) return transitionFirstFrameDecision;
      final transitionPriority =
          demands[transitionFirstFrameDecision.id]!.priority;
      final oneFramePriority = demands[oneFrameDecision.id]!.priority;
      return oneFramePriority > transitionPriority
          ? oneFrameDecision
          : transitionFirstFrameDecision;
    }
    if (oneFrameDecision == null) return stagedDecision;
    if (stagedDecision == null) return oneFrameDecision;
    final oneFramePriority = demands[oneFrameDecision.id]!.priority;
    final stagedPriority = demands[stagedDecision.id]!.priority;
    return oneFramePriority > stagedPriority
        ? oneFrameDecision
        : stagedDecision;
  }
}

enum _WaterlineRole { current, next, next2, previous }

final class _RefillStep {
  const _RefillStep(this.role, this.threshold, this.stage);

  final _WaterlineRole role;
  final int threshold;
  final String stage;
}

bool _neverTerminal(DecodeId _) => false;
bool _alwaysEligible(DecodeId _) => true;
bool _neverSatisfied(DecodeId _) => false;
