import 'package:pipeline/pipeline.dart';
import 'package:test/test.dart';

void main() {
  test('fit uses physical viewport and preserves source aspect approximately', () {
    final target = DecodeTarget.fit(
      sourceWidth: 1920,
      sourceHeight: 1080,
      logicalWidth: 360,
      logicalHeight: 640,
      devicePixelRatio: 3,
    );

    expect(target.physicalWidth, 1080);
    expect(target.physicalHeight % 8, 0);
    expect(target.physicalHeight, lessThanOrEqualTo(1920));
    expect(
      target.physicalWidth / target.physicalHeight,
      closeTo(1920 / 1080, 0.02),
    );
  });

  test('fit aligns dimensions and never exceeds viewport bounds', () {
    final target = DecodeTarget.fit(
      sourceWidth: 1000,
      sourceHeight: 2000,
      logicalWidth: 393,
      logicalHeight: 852,
      devicePixelRatio: 2.75,
    );

    expect(target.physicalWidth % 8, 0);
    expect(target.physicalHeight % 8, 0);
    expect(target.physicalWidth, lessThanOrEqualTo((393 * 2.75).floor()));
    expect(target.physicalHeight, lessThanOrEqualTo((852 * 2.75).floor()));
  });

  test('viewport target applies the physical pixel budget', () {
    final target = DecodeTarget.viewport(
      logicalWidth: 1440,
      logicalHeight: 3200,
      devicePixelRatio: 2,
    );

    expect(target.physicalWidth % 8, 0);
    expect(target.physicalHeight % 8, 0);
    expect(target.physicalPixels, lessThanOrEqualTo(4 * 1024 * 1024));
  });
}
