import 'package:pipeline/pipeline.dart';
import 'package:test/test.dart';

void main() {
  test('tiny sources stay intrinsic and are enlarged only by renderer', () {
    final display = DecodeTarget.fit(
      sourceWidth: 4,
      sourceHeight: 4,
      logicalWidth: 360,
      logicalHeight: 640,
      devicePixelRatio: 3,
    );
    final plan = RasterPlan.fit(
      sourceWidth: 4,
      sourceHeight: 4,
      display: display,
    );

    expect(plan.decodeWidth, 4);
    expect(plan.decodeHeight, 4);
    expect(plan.isDownsampled, isFalse);
    expect(plan.isRenderUpscaled, isTrue);
    expect(plan.prefersNearestNeighbor, isTrue);
  });

  test('large sources are downsampled to the aligned display target', () {
    final display = DecodeTarget.fit(
      sourceWidth: 2400,
      sourceHeight: 3600,
      logicalWidth: 393,
      logicalHeight: 852,
      devicePixelRatio: 2.75,
    );
    final plan = RasterPlan.fit(
      sourceWidth: 2400,
      sourceHeight: 3600,
      display: display,
    );

    expect(plan.decodeWidth, display.physicalWidth);
    expect(plan.decodeHeight, display.physicalHeight);
    expect(plan.isDownsampled, isTrue);
    expect(plan.prefersNearestNeighbor, isFalse);
  });
}
