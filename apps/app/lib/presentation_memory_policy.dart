import 'package:flutter/painting.dart';
import 'package:local_media_ui/local_media_ui.dart';

/// Process presentation-memory envelope shared by managed Reader rasters and
/// Flutter's generic ImageCache entries.
///
/// Reader static rasters are admitted into [pipelinePresentationRasterCache],
/// which owns their keepAlive/LRU metadata and shrinks the generic ImageCache
/// remainder by the exact admitted weight. Raster bytes are never duplicated:
/// the same ImageStreamCompleter moves from generic keepAlive ownership to the
/// managed raster plane. Pipeline FrameBudgeter remains the independent native
/// decode/upload budget.
const int zicFlutterImageCacheMaximumBytes =
    pipelinePresentationRasterMaximumBytes;
const int zicFlutterImageCacheMaximumEntries =
    pipelinePresentationRasterMaximumEntries;

void applyZicFlutterImageCachePolicy(ImageCache cache) {
  cache.maximumSize = zicFlutterImageCacheMaximumEntries;
  cache.maximumSizeBytes = zicFlutterImageCacheMaximumBytes;
}

void configureZicFlutterImageCache() {
  applyZicFlutterImageCachePolicy(PaintingBinding.instance.imageCache);
}
