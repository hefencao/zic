import 'package:pipeline/pipeline.dart';

/// Computes the zoomed decode target for the visible region.
///
/// Zooming multiplies how many source pixels one viewport pixel consumes, so
/// the demanded pages should be decoded at `viewport * scale` resolution
/// instead of upscaled from the 1x raster. The result is bounded by the
/// current page's intrinsic canvas when known ("仅解码可视区域"的近似：只提升
/// 当前被 demand 的可见页，且不超过源分辨率). Returns null when the caller
/// must keep the existing target.
DecodeTarget? boostedDecodeTargetForZoom(
  DecodeTarget base, {
  required double scale,
  required bool enabled,
  required int viewportLogicalWidth,
  required int viewportLogicalHeight,
  required double devicePixelRatio,
  int? maxSourceWidth,
  int? maxSourceHeight,
}) {
  if (!enabled) return null;
  if (!scale.isFinite || scale <= 1.05) return null;
  final effective = scale.clamp(1.0, 8.0).toDouble();
  var logicalWidth = viewportLogicalWidth * effective;
  var logicalHeight = viewportLogicalHeight * effective;
  if (maxSourceWidth != null && maxSourceWidth > 0) {
    final deviceWidth = maxSourceWidth / devicePixelRatio;
    if (deviceWidth.isFinite && deviceWidth > 0 && logicalWidth > deviceWidth) {
      logicalHeight *= deviceWidth / logicalWidth;
      logicalWidth = deviceWidth;
    }
  }
  if (maxSourceHeight != null && maxSourceHeight > 0) {
    final deviceHeight = maxSourceHeight / devicePixelRatio;
    if (deviceHeight.isFinite &&
        deviceHeight > 0 &&
        logicalHeight > deviceHeight) {
      logicalWidth *= deviceHeight / logicalHeight;
      logicalHeight = deviceHeight;
    }
  }
  if (logicalWidth <= base.physicalWidth / devicePixelRatio &&
      logicalHeight <= base.physicalHeight / devicePixelRatio) {
    return null;
  }
  // Zoomed decoding intentionally exceeds the 1x 4-megapixel default cap:
  // the user asked for extra real pixels in the visible region, and the
  // session FrameBudgeter still owns global memory safety.
  return DecodeTarget.viewport(
    logicalWidth: logicalWidth,
    logicalHeight: logicalHeight,
    devicePixelRatio: devicePixelRatio,
    pixelFormat: base.pixelFormat,
    renderer: base.renderer,
    maxPhysicalSide: 6000,
    maxPhysicalPixels: 12 * 1024 * 1024,
  );
}
