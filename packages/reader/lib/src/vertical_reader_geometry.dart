import 'dart:math' as math;

import 'package:domain/domain.dart';

const double readerVerticalPageGap = 8;

final class ReaderVerticalAnchor {
  const ReaderVerticalAnchor({required this.index, required this.offset});

  final int index;
  final double offset;
}

/// Immutable continuous-reader layout snapshot.
///
/// Page extents and prefix starts are computed once. Scroll observations,
/// commands and lazy child layout then use O(1) extent/bounds lookup and a
/// binary search instead of rebuilding the same prefix sum on every call.
final class ReaderVerticalGeometry {
  ReaderVerticalGeometry({
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

  late final List<double> _extents = List<double>.generate(
    pages.length,
    (index) => _computeExtent(index, ratios),
    growable: false,
  );
  late final List<double> _starts = _buildStarts();

  List<double> _buildStarts() {
    final starts = List<double>.filled(pages.length, 0, growable: false);
    var offset = 0.0;
    for (var index = 0; index < pages.length; index++) {
      starts[index] = offset;
      offset += _extents[index] + (index + 1 < pages.length ? gap : 0);
    }
    return starts;
  }

  double _computeExtent(int index, Map<String, double> ratioSource) {
    if (viewportWidth <= 0 || viewportHeight <= 0) return 1;
    final asset = pages[index];
    var ratio = ratioSource[asset.assetKey];
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

  double extentAt(int index) => _extents[index];

  ({double start, double end}) boundsAt(int index) => (
        start: _starts[index],
        end: _starts[index] + _extents[index],
      );

  double centeredOffsetFor(int index) {
    final bounds = boundsAt(index);
    return (bounds.start + bounds.end) / 2 - viewportHeight / 2;
  }

  ReaderVerticalAnchor anchorForTop(double top) {
    if (pages.isEmpty) {
      return const ReaderVerticalAnchor(index: 0, offset: 0);
    }
    final index = _indexAt(top);
    return ReaderVerticalAnchor(
      index: index,
      offset: (top - _starts[index]).clamp(
        0.0,
        math.max(0.0, _extents[index] - 1),
      ),
    );
  }

  double restoreTop(ReaderVerticalAnchor anchor) {
    if (pages.isEmpty) return 0;
    final index = anchor.index.clamp(0, pages.length - 1).toInt();
    final extent = math.max(1.0, _extents[index]);
    return _starts[index] +
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
    var index = _indexAt(viewportStart);
    while (index < pages.length) {
      final start = _starts[index];
      final end = start + _extents[index];
      if (start >= viewportEnd) break;
      final overlap = math.max(
        0.0,
        math.min(end, viewportEnd) - math.max(start, viewportStart),
      );
      if (overlap > 0) {
        result.add((
          index: index,
          fraction: (overlap / viewportDimension).clamp(0.0, 1.0),
        ));
      }
      index++;
    }
    return result;
  }

  ({int index, double logicalPosition}) positionAt({
    required double pixels,
    required double viewportDimension,
  }) {
    if (pages.isEmpty) return (index: 0, logicalPosition: 0);
    final center = pixels + viewportDimension / 2;
    final index = _indexAt(center);
    final fraction = ((center - _starts[index]) / math.max(1.0, _extents[index]))
        .clamp(0.0, 0.999)
        .toDouble();
    return (index: index, logicalPosition: index + fraction);
  }

  int _indexAt(double offset) {
    if (pages.isEmpty || offset <= 0) return 0;
    var low = 0;
    var high = pages.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_starts[mid] <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    var index = math.max(0, low - 1);
    if (index + 1 < pages.length &&
        offset > _starts[index] + _extents[index]) {
      index++;
    }
    return index;
  }
}
