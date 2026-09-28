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
  final DecodeWaterlineStage stage;
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
/// Current bootstrap is authoritative: until current reaches min(3, its role
/// maximum), neighbor decode targets are effectively zero, matching
/// VibeVenera's shallow FrameDepthTable. If current is waiting for source, an
/// actually visible drag `transition` may still acquire its independent first
/// frame; speculative next/next2/previous work does not run around a stalled
/// current. After bootstrap, deeper refills follow
/// `n2, m2, p2, c5, n3, c7, n4, m3, n5`.
/// The role maxima remain c/n/m/p = 7/5/3/2; last remains keep-only.
final class StagedDecodeRefillPolicy {
  const StagedDecodeRefillPolicy();

  DecodeRefillDecision? next({
    required Map<DecodeId, DecodeDemand> demands,
    required DecodeDepthLookup depthOf,
    DecodeTerminalLookup terminalOf = _neverTerminal,
    DecodeEligibilityLookup eligibleOf = _alwaysEligible,
    DecodeSatisfiedLookup satisfiedOf = _neverSatisfied,
  }) {
    DecodeId? currentId;
    for (final entry in demands.entries) {
      if (entry.value.role == PageRole.current) currentId = entry.key;
    }

    bool outranks(
      MapEntry<DecodeId, DecodeDemand> candidate,
      MapEntry<DecodeId, DecodeDemand> current,
    ) {
      final priority =
          candidate.value.priority.compareTo(current.value.priority);
      if (priority != 0) return priority > 0;
      return candidate.key.key.compareTo(current.key.key) < 0;
    }

    DecodeRefillDecision? transitionFirstFrame() {
      // A short vertical current can expose both neighboring pages at once.
      // transition is a viewport role, not a singleton target slot. If one
      // visible transition is waiting on source/presentation, another ready
      // transition must still be able to acquire its first frame.
      MapEntry<DecodeId, DecodeDemand>? best;
      for (final entry in demands.entries) {
        if (entry.value.role != PageRole.transition) continue;
        final id = entry.key;
        if (!eligibleOf(id) ||
            terminalOf(id) ||
            satisfiedOf(id) ||
            depthOf(id) >= 1) {
          continue;
        }
        if (best == null || outranks(entry, best)) best = entry;
      }
      if (best == null) return null;
      return DecodeRefillDecision(
        id: best.key,
        role: best.value.role,
        stage: DecodeWaterlineStage.transitionFirstFrame,
        depth: depthOf(best.key),
        threshold: 0,
        targetWatermark: 1,
      );
    }

    final current = currentId;
    if (current != null &&
        !terminalOf(current) &&
        !satisfiedOf(current)) {
      final demand = demands[current]!;
      final bootstrapTarget = demand.targetWatermark.clamp(0, 3).toInt();
      final depth = depthOf(current);
      if (bootstrapTarget > 0 && depth < bootstrapTarget) {
        if (eligibleOf(current)) {
          return DecodeRefillDecision(
            id: current,
            role: demand.role,
            stage: bootstrapTarget == 1
                ? DecodeWaterlineStage.oneFrame
                : DecodeWaterlineStage.currentBootstrap,
            depth: depth,
            threshold: bootstrapTarget == 1 ? 0 : 2,
            targetWatermark: bootstrapTarget,
          );
        }
        // A real viewport transition may make progress while current waits on
        // source ingress. Other neighbors remain download-only until current
        // bootstrap can resume.
        return transitionFirstFrame();
      }
    }

    MapEntry<DecodeId, DecodeDemand>? oneFrame;
    for (final entry in demands.entries) {
      if (entry.value.targetWatermark != 1 ||
          !eligibleOf(entry.key) ||
          terminalOf(entry.key) ||
          satisfiedOf(entry.key) ||
          depthOf(entry.key) >= 1) {
        continue;
      }
      if (oneFrame == null || outranks(entry, oneFrame)) {
        oneFrame = entry;
      }
    }
    final oneFrameDecision = oneFrame == null
        ? null
        : DecodeRefillDecision(
            id: oneFrame.key,
            role: oneFrame.value.role,
            stage: DecodeWaterlineStage.oneFrame,
            depth: depthOf(oneFrame.key),
            threshold: 0,
            targetWatermark: 1,
          );

    final byRole = <PageRole, DecodeId>{};
    for (final entry in demands.entries) {
      byRole[entry.value.role] = entry.key;
    }

    // Preserve the historical logical-next choice for deeper staged animation
    // waterlines. The multi-transition list above only fixes first-frame
    // eligibility; it does not redefine the later one-role-at-a-time schedule.
    final transition = byRole[PageRole.transition];
    final transitionFirstFrameDecision = transitionFirstFrame();
    final logical = <_WaterlineRole, DecodeId?>{
      _WaterlineRole.current: byRole[PageRole.current],
      _WaterlineRole.next: transition ?? byRole[PageRole.next],
      _WaterlineRole.next2: byRole[PageRole.next2] ??
          (transition == null ? null : byRole[PageRole.next]),
      _WaterlineRole.previous: byRole[PageRole.previous],
    };

    const steps = <_RefillStep>[
      _RefillStep(
        _WaterlineRole.current,
        2,
        DecodeWaterlineStage.currentBootstrap,
      ),
      _RefillStep(_WaterlineRole.next, 1, DecodeWaterlineStage.nextShallow),
      _RefillStep(_WaterlineRole.next2, 1, DecodeWaterlineStage.next2Shallow),
      _RefillStep(
        _WaterlineRole.previous,
        1,
        DecodeWaterlineStage.previousShallow,
      ),
      _RefillStep(_WaterlineRole.current, 4, DecodeWaterlineStage.currentMid),
      _RefillStep(_WaterlineRole.next, 2, DecodeWaterlineStage.nextMid),
      _RefillStep(_WaterlineRole.current, 6, DecodeWaterlineStage.currentDeep),
      _RefillStep(_WaterlineRole.next, 3, DecodeWaterlineStage.nextDeep),
      _RefillStep(_WaterlineRole.next2, 2, DecodeWaterlineStage.next2Deep),
      _RefillStep(_WaterlineRole.next, 4, DecodeWaterlineStage.nextMax),
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
  final DecodeWaterlineStage stage;
}

bool _neverTerminal(DecodeId _) => false;
bool _alwaysEligible(DecodeId _) => true;
bool _neverSatisfied(DecodeId _) => false;
