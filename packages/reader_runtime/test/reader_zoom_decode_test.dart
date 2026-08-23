import 'package:flutter_test/flutter_test.dart';
import 'package:pipeline/pipeline.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  final DecodeTarget base =
      DecodeTarget(physicalWidth: 1080, physicalHeight: 1920);

  test('zoom decode boost is disabled or sub-threshold safe', () {
    // use outer [base]
    expect(
      boostedDecodeTargetForZoom(base, scale: 2, enabled: false,
        viewportLogicalWidth: 360, viewportLogicalHeight: 640,
        devicePixelRatio: 3),
      isNull,
    );
    expect(
      boostedDecodeTargetForZoom(base, scale: 1.0, enabled: true,
        viewportLogicalWidth: 360, viewportLogicalHeight: 640,
        devicePixelRatio: 3),
      isNull,
    );
  });

  test('zoom decode boost scales the visible region up to the stage', () {
    final boosted = boostedDecodeTargetForZoom(
      base,
      scale: 2,
      enabled: true,
      viewportLogicalWidth: 360,
      viewportLogicalHeight: 640,
      devicePixelRatio: 3,
    );
    expect(boosted, isNotNull);
    expect(boosted!.physicalWidth, greaterThan(1080));
    expect(boosted.physicalHeight, greaterThan(1920));
    // The whole point: the visible region gains real pixels.
    expect(
      boosted.physicalWidth / 1080,
      closeTo(2, 0.35),
    );
    expect(
      boosted.physicalHeight / 1920,
      closeTo(2, 0.35),
    );
  });

  test('zoom decode boost never exceeds the source canvas', () {
    final boosted = boostedDecodeTargetForZoom(
      base,
      scale: 4,
      enabled: true,
      viewportLogicalWidth: 360,
      viewportLogicalHeight: 640,
      devicePixelRatio: 3,
      maxSourceWidth: 2400,
      maxSourceHeight: 3200,
    );
    expect(boosted, isNotNull);
    expect(boosted!.physicalWidth, lessThanOrEqualTo(2416));
    expect(boosted.physicalHeight, lessThanOrEqualTo(3208));
  });
}
