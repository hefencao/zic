import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/src/animated_decode_target_governor.dart';
import 'package:sessions/sessions.dart';

void main() {
  test('severe current animation degrades once to half raster', () {
    final governor = AnimatedDecodeTargetGovernor();
    final base = DecodeTarget(
      physicalWidth: 1080,
      physicalHeight: 2336,
      renderer: RendererKind.androidTexture,
    );
    governor.attach(base);

    AnimatedDecodeTargetChange? change;
    for (var index = 0; index < 3; index++) {
      change = governor.observe(
        timing: _timing(nativeMicros: 150000),
        frameDurationMicros: 50000,
        animated: true,
      );
    }

    expect(change, isNotNull);
    expect(change!.toTier, AnimatedDecodeRasterTier.severe);
    expect(change.target.physicalWidth, 544);
    expect(change.target.physicalHeight, 1168);
    expect(governor.degraded, isTrue);
  });


  test('moderate tier escalates to severe when lower raster stays too slow', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());

    for (var index = 0; index < 3; index++) {
      governor.observe(
        timing: _timing(nativeMicros: 85000),
        frameDurationMicros: 50000,
        animated: true,
      );
    }
    expect(governor.tier, AnimatedDecodeRasterTier.moderate);

    AnimatedDecodeTargetChange? change;
    for (var index = 0; index < 3; index++) {
      change = governor.observe(
        timing: _timing(nativeMicros: 105000),
        frameDurationMicros: 50000,
        animated: true,
      );
    }

    expect(change, isNotNull);
    expect(change!.fromTier, AnimatedDecodeRasterTier.moderate);
    expect(change.toTier, AnimatedDecodeRasterTier.severe);
    expect(change.reason, 'cadence-still-slow');
    expect(change.target.physicalWidth, 544);
    expect(change.target.physicalHeight, 1168);
  });

  test('moderate escalation requires consecutive slow lower-raster frames', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());

    for (var index = 0; index < 3; index++) {
      governor.observe(
        timing: _timing(nativeMicros: 85000),
        frameDurationMicros: 50000,
        animated: true,
      );
    }
    expect(governor.tier, AnimatedDecodeRasterTier.moderate);

    for (var index = 0; index < 2; index++) {
      expect(
        governor.observe(
          timing: _timing(nativeMicros: 105000),
          frameDurationMicros: 50000,
          animated: true,
        ),
        isNull,
      );
    }
    governor.observe(
      timing: _timing(nativeMicros: 70000),
      frameDurationMicros: 50000,
      animated: true,
    );
    for (var index = 0; index < 2; index++) {
      expect(
        governor.observe(
          timing: _timing(nativeMicros: 105000),
          frameDurationMicros: 50000,
          animated: true,
        ),
        isNull,
      );
    }
    expect(governor.tier, AnimatedDecodeRasterTier.moderate);
  });

  test('degraded tier persists across animated and unresolved page boundaries', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());
    _degradeSevere(governor);

    expect(governor.onPageBoundary(knownStatic: false), isNull);
    expect(governor.tier, AnimatedDecodeRasterTier.severe);
    expect(governor.onPageBoundary(knownStatic: false), isNull);
    expect(governor.tier, AnimatedDecodeRasterTier.severe);
  });

  test('sustained fast degraded decode restores only at later page boundary', () {
    final governor = AnimatedDecodeTargetGovernor();
    final base = _baseTarget();
    governor.attach(base);
    _degradeSevere(governor);

    for (var index = 0;
        index < AnimatedDecodeTargetGovernor.recoveryFramesRequired;
        index++) {
      expect(
        governor.observe(
          timing: _timing(nativeMicros: 19000),
          frameDurationMicros: 50000,
          animated: true,
        ),
        isNull,
      );
    }
    expect(governor.recoveryEligible, isTrue);
    expect(governor.effectiveTarget, isNot(base));

    final restore = governor.onPageBoundary(knownStatic: false);
    expect(restore, isNotNull);
    expect(restore!.reason, 'sustained-recovery-page-boundary');
    expect(restore.toTier, AnimatedDecodeRasterTier.full);
    expect(restore.target, base);
  });

  test('one slow degraded frame revokes recovery before page boundary', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());
    _degradeSevere(governor);

    for (var index = 0;
        index < AnimatedDecodeTargetGovernor.recoveryFramesRequired;
        index++) {
      governor.observe(
        timing: _timing(nativeMicros: 19000),
        frameDurationMicros: 50000,
        animated: true,
      );
    }
    expect(governor.recoveryEligible, isTrue);

    governor.observe(
      timing: _timing(nativeMicros: 81000),
      frameDurationMicros: 50000,
      animated: true,
    );
    expect(governor.recoveryEligible, isFalse);
    expect(governor.onPageBoundary(knownStatic: false), isNull);
    expect(governor.degraded, isTrue);
  });

  test('known static current restores full raster without recovery evidence', () {
    final governor = AnimatedDecodeTargetGovernor();
    final base = _baseTarget();
    governor.attach(base);
    _degradeSevere(governor);

    final restore = governor.onPageBoundary(knownStatic: true);
    expect(restore, isNotNull);
    expect(restore!.reason, 'current-static');
    expect(restore.target, base);
  });

  test('external target changes preserve active performance tier', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());
    _degradeSevere(governor);

    final effective = governor.updateBaseTarget(
      DecodeTarget(
        physicalWidth: 1200,
        physicalHeight: 2400,
        renderer: RendererKind.androidTexture,
      ),
    );
    expect(effective.physicalWidth, 600);
    expect(effective.physicalHeight, 1200);
    expect(governor.tier, AnimatedDecodeRasterTier.severe);
  });

  test('healthy full raster and non-current samples never degrade', () {
    final governor = AnimatedDecodeTargetGovernor();
    governor.attach(_baseTarget());
    for (var index = 0; index < 10; index++) {
      expect(
        governor.observe(
          timing: _timing(nativeMicros: 41000),
          frameDurationMicros: 50000,
          animated: true,
        ),
        isNull,
      );
    }
    for (var index = 0; index < 10; index++) {
      expect(
        governor.observe(
          timing: _timing(
            nativeMicros: 170000,
            role: PageRole.next,
          ),
          frameDurationMicros: 50000,
          animated: true,
        ),
        isNull,
      );
    }
    expect(governor.tier, AnimatedDecodeRasterTier.full);
  });
}

DecodeTarget _baseTarget() => DecodeTarget(
      physicalWidth: 1080,
      physicalHeight: 2336,
      renderer: RendererKind.androidTexture,
    );

void _degradeSevere(AnimatedDecodeTargetGovernor governor) {
  for (var index = 0; index < 3; index++) {
    governor.observe(
      timing: _timing(nativeMicros: 150000),
      frameDurationMicros: 50000,
      animated: true,
    );
  }
  expect(governor.tier, AnimatedDecodeRasterTier.severe);
}

DecodedFrameTiming _timing({
  required int nativeMicros,
  PageRole role = PageRole.current,
}) =>
    DecodedFrameTiming(
      frameIndex: 1,
      cycle: 0,
      role: role,
      decodeStartedAtMicros: 0,
      decodedAtMicros: nativeMicros,
      laneQueueMicros: 0,
      sourceWaitMicros: 0,
      cursorCreateMicros: 0,
      workerReadyMicros: 0,
      workerQueueMicros: 0,
      workerRoundTripMicros: nativeMicros,
      dispatchMicros: 0,
      nativeDecodeMicros: nativeMicros,
      nativeMetadataMicros: 0,
      decodeMicros: nativeMicros,
      workerIndex: 0,
      workerPlacementStatus: 0,
      sourceLength: 1,
      sourceSealed: true,
    );
