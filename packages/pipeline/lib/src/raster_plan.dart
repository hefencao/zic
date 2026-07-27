import 'dart:math' as math;

import 'decode_target.dart';

/// Separates the physical display target from the encoded-image decode size.
///
/// Large sources are downsampled to [display]. Small sources remain at their
/// intrinsic dimensions and are enlarged only by the renderer. This avoids
/// asking animated codecs to upscale partial subframes before composition.
final class RasterPlan {
  const RasterPlan._({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.decodeWidth,
    required this.decodeHeight,
    required this.display,
  });

  factory RasterPlan.fit({
    required int sourceWidth,
    required int sourceHeight,
    required DecodeTarget display,
  }) {
    if (sourceWidth <= 0) {
      throw ArgumentError.value(sourceWidth, 'sourceWidth', 'must be positive');
    }
    if (sourceHeight <= 0) {
      throw ArgumentError.value(sourceHeight, 'sourceHeight', 'must be positive');
    }

    final needsDownsample =
        display.physicalWidth < sourceWidth ||
        display.physicalHeight < sourceHeight;
    return RasterPlan._(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      decodeWidth: needsDownsample ? display.physicalWidth : sourceWidth,
      decodeHeight: needsDownsample ? display.physicalHeight : sourceHeight,
      display: display,
    );
  }

  final int sourceWidth;
  final int sourceHeight;
  final int decodeWidth;
  final int decodeHeight;
  final DecodeTarget display;

  bool get isDownsampled =>
      decodeWidth < sourceWidth || decodeHeight < sourceHeight;

  bool get isRenderUpscaled =>
      display.physicalWidth > decodeWidth ||
      display.physicalHeight > decodeHeight;

  double get renderScale => math.min(
        display.physicalWidth / decodeWidth,
        display.physicalHeight / decodeHeight,
      );

  /// Tiny deterministic fixtures and pixel-art-like images should be enlarged
  /// with nearest-neighbour filtering. Normal comic pages retain smooth
  /// filtering even if the viewport is slightly larger than the source.
  bool get prefersNearestNeighbor =>
      isRenderUpscaled &&
      math.max(sourceWidth, sourceHeight) <= 64 &&
      renderScale >= 2;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RasterPlan &&
          sourceWidth == other.sourceWidth &&
          sourceHeight == other.sourceHeight &&
          decodeWidth == other.decodeWidth &&
          decodeHeight == other.decodeHeight &&
          display == other.display;

  @override
  int get hashCode => Object.hash(
        sourceWidth,
        sourceHeight,
        decodeWidth,
        decodeHeight,
        display,
      );

  @override
  String toString() => 'RasterPlan('
      'source=${sourceWidth}x$sourceHeight, '
      'decode=${decodeWidth}x$decodeHeight, '
      'display=${display.physicalWidth}x${display.physicalHeight})';
}
