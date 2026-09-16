import 'package:zic/presentation_memory_policy.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter presentation raster cache has an explicit zic budget', () {
    final cache = ImageCache()
      ..maximumSize = 7
      ..maximumSizeBytes = 8 * 1024 * 1024;

    applyZicFlutterImageCachePolicy(cache);

    expect(cache.maximumSize, zicFlutterImageCacheMaximumEntries);
    expect(cache.maximumSizeBytes, zicFlutterImageCacheMaximumBytes);
    expect(zicFlutterImageCacheMaximumEntries, 1000);
    expect(zicFlutterImageCacheMaximumBytes, 100 * 1024 * 1024);
  });
}
