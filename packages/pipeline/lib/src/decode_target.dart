import 'dart:math' as math;

import 'package:domain/domain.dart';

import 'aligned_raster_size.dart';

/// Physical decode dimensions shared by policy, decoder and renderer identity.
///
/// Targets are aligned to [alignment] pixels and never exceed the supplied
/// physical viewport. [fit] preserves source aspect ratio within the viewport.
final class DecodeTarget {
  DecodeTarget({
    required int physicalWidth,
    required int physicalHeight,
    this.pixelFormat = PixelFormat.rgba8888,
    this.renderer = RendererKind.flutterImage,
    int alignment = 8,
  })  : alignment = _checkAlignment(alignment),
        physicalWidth = alignPhysicalDimension(
          physicalWidth,
          alignment: alignment,
        ),
        physicalHeight = alignPhysicalDimension(
          physicalHeight,
          alignment: alignment,
        );

  DecodeTarget._({
    required this.physicalWidth,
    required this.physicalHeight,
    required this.pixelFormat,
    required this.renderer,
    required this.alignment,
  });

  /// Builds a target from the logical viewport and its device pixel ratio.
  ///
  /// This is suitable when individual source dimensions are not yet known.
  factory DecodeTarget.viewport({
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
    PixelFormat pixelFormat = PixelFormat.rgba8888,
    RendererKind renderer = RendererKind.flutterImage,
    int alignment = 8,
    int maxPhysicalSide = 4096,
    int maxPhysicalPixels = 4 * 1024 * 1024,
  }) {
    final bounds = _physicalBounds(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
      alignment: alignment,
      maxPhysicalSide: maxPhysicalSide,
      maxPhysicalPixels: maxPhysicalPixels,
    );
    return DecodeTarget._(
      physicalWidth: bounds.width,
      physicalHeight: bounds.height,
      pixelFormat: pixelFormat,
      renderer: renderer,
      alignment: alignment,
    );
  }

  /// Fits a source canvas into the physical viewport without changing aspect.
  factory DecodeTarget.fit({
    required int sourceWidth,
    required int sourceHeight,
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
    PixelFormat pixelFormat = PixelFormat.rgba8888,
    RendererKind renderer = RendererKind.flutterImage,
    int alignment = 8,
    int maxPhysicalSide = 4096,
    int maxPhysicalPixels = 4 * 1024 * 1024,
  }) {
    if (sourceWidth <= 0) {
      throw ArgumentError.value(sourceWidth, 'sourceWidth', 'must be positive');
    }
    if (sourceHeight <= 0) {
      throw ArgumentError.value(sourceHeight, 'sourceHeight', 'must be positive');
    }
    final bounds = _physicalBounds(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
      alignment: alignment,
      maxPhysicalSide: maxPhysicalSide,
      maxPhysicalPixels: maxPhysicalPixels,
    );
    final raster = AlignedRasterSize.fit(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      maxWidth: bounds.width,
      maxHeight: bounds.height,
      alignment: alignment,
    );
    return DecodeTarget._(
      physicalWidth: raster.width,
      physicalHeight: raster.height,
      pixelFormat: pixelFormat,
      renderer: renderer,
      alignment: alignment,
    );
  }

  final int physicalWidth;
  final int physicalHeight;
  final PixelFormat pixelFormat;
  final RendererKind renderer;
  final int alignment;

  int get physicalPixels => physicalWidth * physicalHeight;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecodeTarget &&
          physicalWidth == other.physicalWidth &&
          physicalHeight == other.physicalHeight &&
          pixelFormat == other.pixelFormat &&
          renderer == other.renderer &&
          alignment == other.alignment;

  @override
  int get hashCode => Object.hash(
        physicalWidth,
        physicalHeight,
        pixelFormat,
        renderer,
        alignment,
      );

  @override
  String toString() => 'DecodeTarget('
      '${physicalWidth}x$physicalHeight, '
      '${pixelFormat.name}, ${renderer.name})';
}

final class _PhysicalBounds {
  const _PhysicalBounds(this.width, this.height);

  final int width;
  final int height;
}

_PhysicalBounds _physicalBounds({
  required double logicalWidth,
  required double logicalHeight,
  required double devicePixelRatio,
  required int alignment,
  required int maxPhysicalSide,
  required int maxPhysicalPixels,
}) {
  _checkFinitePositive(logicalWidth, 'logicalWidth');
  _checkFinitePositive(logicalHeight, 'logicalHeight');
  _checkFinitePositive(devicePixelRatio, 'devicePixelRatio');
  _checkAlignment(alignment);
  if (maxPhysicalSide < alignment) {
    throw ArgumentError.value(
      maxPhysicalSide,
      'maxPhysicalSide',
      'must be at least alignment',
    );
  }
  if (maxPhysicalPixels < alignment * alignment) {
    throw ArgumentError.value(
      maxPhysicalPixels,
      'maxPhysicalPixels',
      'is too small',
    );
  }

  var width = math.min(
    (logicalWidth * devicePixelRatio).floor(),
    maxPhysicalSide,
  ).toInt();
  var height = math.min(
    (logicalHeight * devicePixelRatio).floor(),
    maxPhysicalSide,
  ).toInt();
  if (width <= 0 || height <= 0) {
    throw ArgumentError('viewport resolves to an empty physical size');
  }
  final pixels = width * height;
  if (pixels > maxPhysicalPixels) {
    final scale = math.sqrt(maxPhysicalPixels / pixels);
    width = math.max(alignment, (width * scale).floor()).toInt();
    height = math.max(alignment, (height * scale).floor()).toInt();
  }
  return _PhysicalBounds(
    _alignDown(width, alignment),
    _alignDown(height, alignment),
  );
}


int _alignDown(int value, int alignment) {
  final aligned = (value ~/ alignment) * alignment;
  return aligned >= alignment ? aligned : alignment;
}

int _checkAlignment(int alignment) {
  if (alignment <= 0) {
    throw ArgumentError.value(alignment, 'alignment', 'must be positive');
  }
  return alignment;
}

void _checkFinitePositive(double value, String name) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, name, 'must be finite and positive');
  }
}
