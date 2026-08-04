import 'dart:math' as math;

import 'package:domain/domain.dart';

const double readerVerticalPageGap = 8;

final class ReaderVerticalAnchor {
  const ReaderVerticalAnchor({required this.index, required this.offset});

  final int index;
  final double offset;
}

/// Pure continuous-reader geometry owned by the Reader presentation package.
///
/// Widget lifecycle code supplies viewport and measured page ratios; this
/// value object performs all extent, gap, anchor and logical-position math.
/// Tests can therefore validate geometry without depending on lazy ListView
/// children, animation frames or guessed scroll offsets.
final class ReaderVerticalGeometry {
  const ReaderVerticalGeometry({
    required this.pages,
    required this.ratios,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.stitch,
    required this.rotationQuarterTurns,
    this.devicePixelRatio = 1,
  });

  final List<PageAsset> pages;
  final Map<String, double> ratios;
  final double viewportWidth;
  final double viewportHeight;
  final bool stitch;
  final int rotationQuarterTurns;
  final double devicePixelRatio;

  double get gap => stitch ? 0 : readerVerticalPageGap;

  double extentAt(int index) {
    if (viewportWidth <= 0 || viewportHeight <= 0) return 1;
    final asset = pages[index];
    var ratio = ratios[asset.assetKey];
    var hasMeasuredRatio = ratio != null;
    final width = asset.width?.toDouble();
    final height = asset.height?.toDouble();
    if (ratio == null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      ratio = height / width;
      hasMeasuredRatio = true;
    }
    ratio ??= 1.5;
    if (rotationQuarterTurns.isOdd) {
      ratio = 1 / math.max(0.001, ratio);
    }
    var scaled = viewportWidth * ratio;
    if (!hasMeasuredRatio) {
      scaled = math.max(scaled, viewportHeight);
    }
    final upper = math.max(viewportHeight, viewportWidth * 64);
    final bounded = scaled.clamp(64.0, upper).toDouble();
    final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    return math.max(1, (bounded * dpr).round()) / dpr;
  }

  ({double start, double end}) boundsAt(int index) {
    var start = 0.0;
    for (var page = 0; page < index; page++) {
      start += extentAt(page) + gap;
    }
    return (start: start, end: start + extentAt(index));
  }

  double centeredOffsetFor(int index) {
    final bounds = boundsAt(index);
    return (bounds.start + bounds.end) / 2 - viewportHeight / 2;
  }

  ReaderVerticalAnchor anchorForTop(double top) {
    var pageStart = 0.0;
    for (var index = 0; index < pages.length; index++) {
      final extent = extentAt(index);
      final end = pageStart + extent;
      if (top <= end || index == pages.length - 1) {
        return ReaderVerticalAnchor(
          index: index,
          offset: (top - pageStart).clamp(
            0.0,
            math.max(0.0, extent - 1),
          ),
        );
      }
      pageStart = end + gap;
    }
    return const ReaderVerticalAnchor(index: 0, offset: 0);
  }

  double restoreTop(ReaderVerticalAnchor anchor) {
    final bounds = boundsAt(anchor.index);
    final extent = math.max(1.0, bounds.end - bounds.start);
    return bounds.start +
        anchor.offset.clamp(0.0, math.max(0.0, extent - 1));
  }

  List<({int index, double fraction})> visibleCoverages({
    required double pixels,
    required double viewportDimension,
  }) {
    if (pages.isEmpty || viewportDimension <= 0) {
      return const <({int index, double fraction})>[];
    }
    final viewportStart = pixels;
    final viewportEnd = pixels + viewportDimension;
    final result = <({int index, double fraction})>[];
    var offset = 0.0;
    for (var index = 0; index < pages.length; index++) {
      final extent = extentAt(index);
      final end = offset + extent;
      final overlap = math.max(
        0.0,
        math.min(end, viewportEnd) - math.max(offset, viewportStart),
      );
      if (overlap > 0) {
        result.add((
          index: index,
          fraction: (overlap / viewportDimension).clamp(0.0, 1.0),
        ));
      }
      if (offset > viewportEnd) break;
      offset = end + gap;
    }
    return result;
  }

  ({int index, double logicalPosition}) positionAt({
    required double pixels,
    required double viewportDimension,
  }) {
    final center = pixels + viewportDimension / 2;
    var offset = 0.0;
    for (var index = 0; index < pages.length; index++) {
      final extent = extentAt(index);
      final end = offset + extent;
      if (center <= end || index == pages.length - 1) {
        final fraction = ((center - offset) / math.max(1.0, extent))
            .clamp(0.0, 0.999)
            .toDouble();
        return (index: index, logicalPosition: index + fraction);
      }
      offset = end + gap;
    }
    return (
      index: math.max(0, pages.length - 1),
      logicalPosition: math.max(0, pages.length - 1).toDouble(),
    );
  }
}
