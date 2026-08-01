import 'package:pipeline/pipeline.dart';
import 'package:test/test.dart';

void main() {
  test('fits wide and tall sources with one aligned aspect decision', () {
    final wide = AlignedRasterSize.fit(
      sourceWidth: 4000,
      sourceHeight: 1000,
      maxWidth: 1000,
      maxHeight: 1000,
    );
    final tall = AlignedRasterSize.fit(
      sourceWidth: 1000,
      sourceHeight: 4000,
      maxWidth: 1000,
      maxHeight: 1000,
    );

    expect(wide.width % 8, 0);
    expect(wide.height % 8, 0);
    expect(tall.width % 8, 0);
    expect(tall.height % 8, 0);
    expect((wide.width / wide.height - 4).abs(), lessThan(0.01));
    expect((tall.width / tall.height - 0.25).abs(), lessThan(0.01));
  });

  test('aligns a fitting source without exceeding its dimensions', () {
    expect(
      AlignedRasterSize.fit(
        sourceWidth: 321,
        sourceHeight: 643,
        maxWidth: 1080,
        maxHeight: 1920,
      ),
      const AlignedRasterSize(width: 320, height: 640),
    );

    expect(
      AlignedRasterSize.fit(
        sourceWidth: 101,
        sourceHeight: 99,
        maxWidth: 1080,
        maxHeight: 1920,
      ),
      const AlignedRasterSize(width: 96, height: 96),
    );
  });
}
