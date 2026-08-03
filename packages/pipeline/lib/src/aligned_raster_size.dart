import 'dart:math' as math;

/// One canonical aspect-preserving physical raster calculation.
///
/// Downsampled dimensions are aligned to [alignment] pixels as a pair. The
/// search only considers candidates near the maximum fitting area, then picks
/// the smallest source-aspect error and the largest area on ties. The result is
/// always aligned as a pair and never exceeds either the source or viewport.
/// Tiny rasters below one alignment quantum retain their exact contain size.
final class AlignedRasterSize {
  const AlignedRasterSize({
    required this.width,
    required this.height,
  });

  factory AlignedRasterSize.fit({
    required int sourceWidth,
    required int sourceHeight,
    required int maxWidth,
    required int maxHeight,
    int alignment = 8,
  }) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      throw ArgumentError('source dimensions must be positive');
    }
    if (maxWidth <= 0 || maxHeight <= 0) {
      throw ArgumentError('maximum dimensions must be positive');
    }
    if (alignment <= 0) {
      throw ArgumentError.value(alignment, 'alignment', 'must be positive');
    }
    final boundedWidth = math.min(sourceWidth, maxWidth);
    final boundedHeight = math.min(sourceHeight, maxHeight);
    if (boundedWidth < alignment || boundedHeight < alignment) {
      final scale = math.min(
        1.0,
        math.min(maxWidth / sourceWidth, maxHeight / sourceHeight),
      );
      return AlignedRasterSize(
        width: math.max(1, (sourceWidth * scale).floor()),
        height: math.max(1, (sourceHeight * scale).floor()),
      );
    }
    final widthBound = _alignDown(
      math.min(sourceWidth, maxWidth),
      alignment,
    );
    final heightBound = _alignDown(
      math.min(sourceHeight, maxHeight),
      alignment,
    );
    final widthLimited = widthBound * sourceHeight <=
        heightBound * sourceWidth;
    final idealWidth = widthLimited
        ? widthBound
        : math.max(
            alignment,
            sourceWidth * heightBound ~/ sourceHeight,
          );
    final idealHeight = widthLimited
        ? math.max(
            alignment,
            sourceHeight * widthBound ~/ sourceWidth,
          )
        : heightBound;
    final largestWidth = _alignDown(
      math.min(widthBound, idealWidth),
      alignment,
    );
    final largestHeight = _alignDown(
      math.min(heightBound, idealHeight),
      alignment,
    );
    final minimumArea = largestWidth * largestHeight * 85 ~/ 100;

    _RasterCandidate? best;
    void consider(int width, int height) {
      if (width < alignment ||
          height < alignment ||
          width > widthBound ||
          height > heightBound ||
          width * height < minimumArea) {
        return;
      }
      final candidate = _RasterCandidate(
        width: width,
        height: height,
        aspectError: (width * sourceHeight - height * sourceWidth).abs(),
      );
      final current = best;
      if (current == null || candidate.isBetterThan(current)) {
        best = candidate;
      }
    }

    for (var width = largestWidth;
        width >= alignment && width * largestHeight >= minimumArea;
        width -= alignment) {
      final height = _alignRatioClosest(
        sourceHeight * width,
        sourceWidth,
        heightBound,
        alignment,
      );
      consider(width, height);
    }
    for (var height = largestHeight;
        height >= alignment && largestWidth * height >= minimumArea;
        height -= alignment) {
      final width = _alignRatioClosest(
        sourceWidth * height,
        sourceHeight,
        widthBound,
        alignment,
      );
      consider(width, height);
    }

    final selected = best;
    if (selected == null) {
      throw StateError('no aligned raster fits the requested bounds');
    }
    return AlignedRasterSize(
      width: selected.width,
      height: selected.height,
    );
  }

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlignedRasterSize &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'AlignedRasterSize(${width}x$height)';
}

final class _RasterCandidate {
  const _RasterCandidate({
    required this.width,
    required this.height,
    required this.aspectError,
  });

  final int width;
  final int height;
  final int aspectError;

  int get area => width * height;

  bool isBetterThan(_RasterCandidate other) {
    final relativeError = aspectError * other.height;
    final otherRelativeError = other.aspectError * height;
    return relativeError < otherRelativeError ||
        (relativeError == otherRelativeError && area > other.area);
  }
}

int _alignRatioClosest(
  int numerator,
  int denominator,
  int limit,
  int alignment,
) {
  final floor = numerator ~/ denominator;
  final ceil = (numerator + denominator - 1) ~/ denominator;
  final down = _alignDown(floor, alignment);
  final up = math.min(
    limit,
    ((math.max(1, ceil) + alignment - 1) ~/ alignment) * alignment,
  );
  if (down < alignment) {
    return up;
  }
  final downError = (numerator - down * denominator).abs();
  final upError = (numerator - up * denominator).abs();
  return downError <= upError ? down : up;
}

int _alignDown(int value, int alignment) {
  final aligned = value ~/ alignment * alignment;
  return aligned >= alignment ? aligned : alignment;
}
