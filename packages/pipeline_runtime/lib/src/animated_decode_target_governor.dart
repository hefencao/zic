import 'dart:math' as math;

import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';

enum AnimatedDecodeRasterTier { full, moderate, severe }

final class AnimatedDecodeTargetChange {
  const AnimatedDecodeTargetChange({
    required this.target,
    required this.fromTier,
    required this.toTier,
    required this.reason,
  });

  final DecodeTarget target;
  final AnimatedDecodeRasterTier fromTier;
  final AnimatedDecodeRasterTier toTier;
  final String reason;
}

/// Session-local adaptive raster policy for current Animated WebP playback.
///
/// The policy observes only measured native decode throughput. It does not use
/// Android power mode, cpuset placement or CPU affinity as authority. Once a
/// current animation proves that the full raster cannot sustain its own frame
/// cadence, the selected lower raster remains active across nearby page
/// boundaries. Recovery requires sustained fast native decode and is applied
/// only at a later page boundary, never by rebuilding the decoder mid-frame.
final class AnimatedDecodeTargetGovernor {
  static const int slowFramesToDegrade = 3;
  static const int recoveryFramesRequired = 24;
  static const int minimumSlowBudgetMicros = 75000;

  DecodeTarget? _baseTarget;
  DecodeTarget? _effectiveTarget;
  AnimatedDecodeRasterTier _tier = AnimatedDecodeRasterTier.full;
  int _consecutiveSlowFrames = 0;
  int _consecutiveRecoveryFrames = 0;
  bool _recoveryEligible = false;

  AnimatedDecodeRasterTier get tier => _tier;
  bool get degraded => _tier != AnimatedDecodeRasterTier.full;
  bool get recoveryEligible => _recoveryEligible;
  DecodeTarget? get baseTarget => _baseTarget;
  DecodeTarget? get effectiveTarget => _effectiveTarget;

  DecodeTarget attach(DecodeTarget target) {
    _baseTarget = target;
    _effectiveTarget = target;
    _tier = AnimatedDecodeRasterTier.full;
    _consecutiveSlowFrames = 0;
    _consecutiveRecoveryFrames = 0;
    _recoveryEligible = false;
    return target;
  }

  /// Updates the caller-owned viewport/zoom target while preserving the
  /// measured performance tier. The returned target is the effective raster
  /// that should be applied to Pipeline demand.
  DecodeTarget updateBaseTarget(DecodeTarget target) {
    _baseTarget = target;
    _effectiveTarget = _scaledTarget(target, _tier);
    return _effectiveTarget!;
  }

  AnimatedDecodeTargetChange? observe({
    required DecodedFrameTiming timing,
    required int frameDurationMicros,
    required bool animated,
  }) {
    final base = _baseTarget;
    if (base == null ||
        !animated ||
        timing.role != PageRole.current ||
        timing.nativeDecodeMicros <= 0 ||
        frameDurationMicros <= 0) {
      if (timing.role == PageRole.current && !degraded) {
        _consecutiveSlowFrames = 0;
      }
      return null;
    }

    final cadenceBudget = frameDurationMicros * 3 ~/ 2;
    final slowBudget = math.max(minimumSlowBudgetMicros, cadenceBudget);

    if (degraded) {
      if (_tier == AnimatedDecodeRasterTier.moderate) {
        if (timing.nativeDecodeMicros > slowBudget) {
          _consecutiveSlowFrames++;
          if (_consecutiveSlowFrames >= slowFramesToDegrade) {
            final priorTier = _tier;
            final nextTier = AnimatedDecodeRasterTier.severe;
            final next = _scaledTarget(base, nextTier);
            _tier = nextTier;
            _effectiveTarget = next;
            _consecutiveSlowFrames = 0;
            _consecutiveRecoveryFrames = 0;
            _recoveryEligible = false;
            return AnimatedDecodeTargetChange(
              target: next,
              fromTier: priorTier,
              toTier: nextTier,
              reason: 'cadence-still-slow',
            );
          }
        } else {
          _consecutiveSlowFrames = 0;
        }
      } else {
        _consecutiveSlowFrames = 0;
      }

      // A lower raster is only considered evidence of full-raster recovery
      // when it is substantially faster than the source cadence. This avoids
      // promoting on a merely-less-bad decode that would fall behind again at
      // full resolution.
      final recoveryFast =
          timing.nativeDecodeMicros * 5 <= frameDurationMicros * 3;
      if (recoveryFast) {
        _consecutiveRecoveryFrames++;
        if (_consecutiveRecoveryFrames >= recoveryFramesRequired) {
          _recoveryEligible = true;
        }
      } else {
        _consecutiveRecoveryFrames = 0;
        _recoveryEligible = false;
      }
      return null;
    }

    if (timing.nativeDecodeMicros <= slowBudget) {
      _consecutiveSlowFrames = 0;
      return null;
    }

    _consecutiveSlowFrames++;
    if (_consecutiveSlowFrames < slowFramesToDegrade) return null;

    final severe = timing.nativeDecodeMicros * 2 >= frameDurationMicros * 5;
    final nextTier = severe
        ? AnimatedDecodeRasterTier.severe
        : AnimatedDecodeRasterTier.moderate;
    final priorTier = _tier;
    final next = _scaledTarget(base, nextTier);
    _consecutiveSlowFrames = 0;
    if (next == _effectiveTarget) return null;
    _tier = nextTier;
    _effectiveTarget = next;
    _consecutiveRecoveryFrames = 0;
    _recoveryEligible = false;
    return AnimatedDecodeTargetChange(
      target: next,
      fromTier: priorTier,
      toTier: nextTier,
      reason: severe ? 'cadence-severe' : 'cadence-moderate',
    );
  }

  /// Called only when the Reader current page changes. Degraded raster is
  /// retained across animated or not-yet-classified pages. Sustained recovery
  /// evidence may restore full raster here without interrupting an animation.
  AnimatedDecodeTargetChange? onPageBoundary({required bool knownStatic}) {
    if (!degraded) {
      _consecutiveSlowFrames = 0;
      return null;
    }
    if (!knownStatic && !_recoveryEligible) {
      return null;
    }
    return _restoreFull(
      knownStatic ? 'current-static' : 'sustained-recovery-page-boundary',
    );
  }

  /// A page can be unknown when it first becomes current. If later codec
  /// evidence proves it static, restoring full raster is safe because there is
  /// no animation playback clock to disrupt.
  AnimatedDecodeTargetChange? onCurrentClassifiedStatic() {
    if (!degraded) return null;
    return _restoreFull('current-classified-static');
  }

  AnimatedDecodeTargetChange? _restoreFull(String reason) {
    final base = _baseTarget;
    if (base == null || !degraded) return null;
    final priorTier = _tier;
    _tier = AnimatedDecodeRasterTier.full;
    _effectiveTarget = base;
    _consecutiveSlowFrames = 0;
    _consecutiveRecoveryFrames = 0;
    _recoveryEligible = false;
    return AnimatedDecodeTargetChange(
      target: base,
      fromTier: priorTier,
      toTier: AnimatedDecodeRasterTier.full,
      reason: reason,
    );
  }

  DecodeTarget _scaledTarget(
    DecodeTarget base,
    AnimatedDecodeRasterTier tier,
  ) {
    final (numerator, denominator) = switch (tier) {
      AnimatedDecodeRasterTier.full => (1, 1),
      AnimatedDecodeRasterTier.moderate => (2, 3),
      AnimatedDecodeRasterTier.severe => (1, 2),
    };
    if (numerator == denominator) return base;
    return DecodeTarget(
      physicalWidth: base.physicalWidth * numerator ~/ denominator,
      physicalHeight: base.physicalHeight * numerator ~/ denominator,
      pixelFormat: base.pixelFormat,
      renderer: base.renderer,
      alignment: base.alignment,
    );
  }
}
