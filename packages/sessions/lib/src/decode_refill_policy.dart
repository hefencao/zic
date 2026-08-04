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
///   c  n  m  p  l
///   3  1  1  1  keep
///   5  2  1  1  keep
///   7  3  2  2  keep
///   7  5  3  2  keep
///
/// During a drag, `transition` is the logical n. It therefore receives every
/// n stage instead of a separate one-off transition watermark. `last` never
/// refills; its existing upload output is frozen and retained.
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
    final logical = <_WaterlineRole, DecodeId?>{
      _WaterlineRole.current: byRole[PageRole.current],
      _WaterlineRole.next: transition ?? byRole[PageRole.next],
      _WaterlineRole.next2: byRole[PageRole.next2] ??
          (transition == null ? null : byRole[PageRole.next]),
      _WaterlineRole.previous: byRole[PageRole.previous],
    };

    const steps = <_RefillStep>[
      _RefillStep(_WaterlineRole.current, 3, 'c>3'),
      _RefillStep(_WaterlineRole.next, 1, 'n>1'),
      _RefillStep(_WaterlineRole.next2, 1, 'm>1'),
      _RefillStep(_WaterlineRole.previous, 1, 'p>1'),
      _RefillStep(_WaterlineRole.current, 5, 'c>5'),
      _RefillStep(_WaterlineRole.next, 2, 'n>2'),
      _RefillStep(_WaterlineRole.current, 7, 'c>7'),
      _RefillStep(_WaterlineRole.next, 3, 'n>3'),
      _RefillStep(_WaterlineRole.next2, 2, 'm>2'),
      _RefillStep(_WaterlineRole.previous, 2, 'p>2'),
      _RefillStep(_WaterlineRole.next, 5, 'n>5'),
      _RefillStep(_WaterlineRole.next2, 3, 'm>3'),
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
