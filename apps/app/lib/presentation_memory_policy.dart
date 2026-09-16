import 'package:flutter/painting.dart';

/// Actual decoded-raster cache owned by Flutter presentation paths such as
/// FileImage/ResizeImage/MemoryImage.
///
/// This is deliberately separate from Pipeline FrameBudgeter: FrameBudgeter
/// owns native decoded/upload residency, while ImageCache owns Flutter image
/// completers and their decoded rasters. It is also not a page-eligibility
/// estimate; staged Pipeline demand decides which fallback page may decode.
const int zicFlutterImageCacheMaximumBytes = 100 * 1024 * 1024;
const int zicFlutterImageCacheMaximumEntries = 1000;

void applyZicFlutterImageCachePolicy(ImageCache cache) {
  cache.maximumSize = zicFlutterImageCacheMaximumEntries;
  cache.maximumSizeBytes = zicFlutterImageCacheMaximumBytes;
}

void configureZicFlutterImageCache() {
  applyZicFlutterImageCachePolicy(PaintingBinding.instance.imageCache);
}
