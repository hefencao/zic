import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';

typedef DecodeDepthLookup = int Function(DecodeId id);
typedef DecodeTerminalLookup = bool Function(DecodeId id);

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
  }) {
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

    for (final step in steps) {
      final id = logical[step.role];
      if (id == null || terminalOf(id)) {
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
      return DecodeRefillDecision(
        id: id,
        role: demand.role,
        stage: step.stage,
        depth: depth,
        threshold: step.threshold,
        targetWatermark: (step.threshold + 1).clamp(1, maximum).toInt(),
      );
    }
    return null;
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
