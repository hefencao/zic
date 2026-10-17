part of 'translation_overlay.dart';

const _crossingBubbleOutsideFraction = .2;

// Typography belongs to this immutable page, never to later page arrivals.
double? _pageBodyFontRatio(ComicTranslationArtifact artifact) {
  if (artifact.imageWidth <= 0 || artifact.imageHeight <= 0) return null;
  final language = artifact.sourceLanguage.split(RegExp('[-_]')).first.toLowerCase();
  final squareGlyphs = {'ja', 'ko', 'zh'}.contains(language);
  final samples = <({double ratio, double weight})>[];
  for (final region in artifact.regions) {
    final characters = region.sourceText.replaceAll(RegExp(r'\s'), '').runes.length;
    if (region.kind == ComicTextKind.soundEffect || characters < 4) continue;
    final points = region.sourceMaskPolygons.isEmpty
        ? region.polygon : region.sourceMaskPolygons.expand((polygon) => polygon);
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final point in points) {
      if (!point.x.isFinite || !point.y.isFinite) continue;
      left = math.min(left, point.x);
      right = math.max(right, point.x);
      top = math.min(top, point.y);
      bottom = math.max(bottom, point.y);
    }
    if (right <= left || bottom <= top) continue;
    final width = (right - left) * artifact.imageWidth;
    final height = (bottom - top) * artifact.imageHeight;
    final vertical = region.orientation == ComicTextOrientation.vertical;
    final size = comicTextSourceFontSize(
      crossExtent: vertical ? width : height,
      mainExtent: vertical ? height : width,
      decodedCharacters: characters, bodyContext: true, squareGlyphs: squareGlyphs,
    );
    samples.add((ratio: size / artifact.imageWidth, weight: characters.clamp(1, 12).toDouble()));
  }
  samples.sort((a, b) => a.ratio.compareTo(b.ratio));
  final total = samples.fold(0.0, (sum, sample) => sum + sample.weight);
  var cumulative = 0.0;
  for (final sample in samples) {
    cumulative += sample.weight;
    if (cumulative >= total / 2) return sample.ratio;
  }
  return null;
}

extension _ComicTranslationGeometry on _ComicTranslationPainter {
  _TranslationBlockGeometry? _blockGeometry(
    _TranslationLayoutBlock block,
    Rect imageRect,
  ) {
    final regionBounds = block.regions
        .map((region) => _displayBounds(region.inkBounds, imageRect))
        .toList(growable: false);
    final sourceBounds = regionBounds
        .reduce((value, next) => value.expandToInclude(next));
    final sourceCenter = _sourceCenter(block, imageRect, sourceBounds);
    final bubble = _blockBubble(block, imageRect);
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    final sourceOutsideBubble = bubble == null ? 0.0
        : _sourceOutsideBubbleFraction(regionBounds, bubble.path);
    final domain = bubble?.path ?? (Path()..addRect(
      _openBubbleBounds(sourceBounds, sourceFontSize, imageRect)));
    final layoutBounds = _blockLayoutBounds(block, imageRect, domain);
    // Test the original contour before reserving neighboring groups' space.
    // Lettering already crossing that contour must not be pulled inside a
    // narrow inscribed rectangle. Its source-anchored layout still uses the
    // same reserved cell, so it cannot expand over the adjacent dialogue.
    var bubblePath = bubble == null ||
        sourceOutsideBubble >= _crossingBubbleOutsideFraction ? null : Path.combine(
      PathOperation.intersect, bubble.path, Path()..addRect(layoutBounds));
    var bounds = bubblePath == null
        ? _openBubbleBounds(sourceBounds, sourceFontSize, layoutBounds)
        : _safeBubbleBounds(
            bubble!.polygons,
            sourceBounds,
            sourceCenter,
            sourceFontSize,
            layoutBounds,
          ).intersect(imageRect);
    bool tooSmall(Rect value) => value.width < math.max(3, sourceBounds.width) ||
        value.height < math.max(3, sourceBounds.height);
    if (bubblePath != null && tooSmall(bounds)) {
      // A valid contour may become narrower when reserving another group's
      // space. Fit its text inside that cell; only reject an intrinsically
      // unusable contour, never let this fallback escape a valid bubble.
      final original = layoutBounds == imageRect ? bounds : _safeBubbleBounds(
        bubble!.polygons, sourceBounds, sourceCenter, sourceFontSize, imageRect,
      ).intersect(imageRect);
      if (tooSmall(original) || bounds.width < 3 || bounds.height < 3) {
        final outer = _bounds(bubble!.polygons.expand((polygon) => polygon));
        _TranslationLog.warning(
          'Translation.Layout',
          'bubble inner rejected block=${block.key} '
              'outer/source='
              '${(outer.width / sourceBounds.width).toStringAsFixed(2)}x'
              '${(outer.height / sourceBounds.height).toStringAsFixed(2)} '
              'inner/source='
              '${(bounds.width / sourceBounds.width).toStringAsFixed(2)}x'
              '${(bounds.height / sourceBounds.height).toStringAsFixed(2)} '
              'source=${block.regions.map((region) =>
                  region.region.sourceText).join('|')}',
        );
        bubblePath = null;
        bounds = _openBubbleBounds(sourceBounds, sourceFontSize, layoutBounds);
      }
    }
    if (bounds.width < 3 || bounds.height < 3) return null;
    return _TranslationBlockGeometry(
      regionBounds,
      bounds,
      bubblePath,
      sourceOutsideBubble,
    );
  }

  double _sourceOutsideBubbleFraction(List<Rect> regions, Path bubble) {
    var totalArea = 0.0;
    var outsideArea = 0.0;
    for (final bounds in regions) {
      final area = bounds.width * bounds.height;
      if (area <= 0) continue;
      var outside = 0;
      // A bounded interior grid tolerates noisy OCR corners. Weight actual
      // source rectangles, not the empty space between separate OCR lines.
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          if (!bubble.contains(Offset(bounds.left + bounds.width * (x + .5) / 5,
              bounds.top + bounds.height * (y + .5) / 5))) outside++;
        }
      }
      totalArea += area;
      outsideArea += area * outside / 25;
    }
    return totalArea == 0 ? 0 : outsideArea / totalArea;
  }

  Rect _blockLayoutBounds(_TranslationLayoutBlock block, Rect imageRect, Path domain) {
    final source = layoutCache.sourceBounds[block.key]!;
    final domainBounds = domain.getBounds();
    var left = 0.0;
    var top = 0.0;
    var right = 1.0;
    var bottom = 1.0;
    for (final entry in layoutCache.sourceBounds.entries) {
      if (entry.key == block.key) continue;
      final other = entry.value;
      final otherBounds = _displayBounds(other, imageRect);
      if (!domainBounds.overlaps(otherBounds)) continue;
      final core = Rect.fromCenter(center: otherBounds.center,
        width: otherBounds.width * .6, height: otherBounds.height * .6);
      if (![core.center, core.topCenter, core.centerRight,
          core.bottomCenter, core.centerLeft].any(domain.contains)) {
        continue;
      }
      final gapX = math.max(source.left, other.left) - math.min(source.right, other.right);
      final gapY = math.max(source.top, other.top) - math.min(source.bottom, other.bottom);
      // Reserve space from original ink, including groups kept untranslated.
      // A shared native contour does not make separate groups share a layout
      // area. Use the same separating axis/mid-gap for both sides, preserving
      // each source rectangle and staying independent of font or ready order.
      if (gapX < 0 && gapY < 0) continue;
      if (gapX * imageRect.width >= gapY * imageRect.height) {
        if (source.right <= other.left) {
          right = math.min(right, (source.right + other.left) / 2);
        } else {
          left = math.max(left, (other.right + source.left) / 2);
        }
      } else if (source.bottom <= other.top) {
        bottom = math.min(bottom, (source.bottom + other.top) / 2);
      } else {
        top = math.max(top, (other.bottom + source.top) / 2);
      }
    }
    return _displayBounds(Rect.fromLTRB(left, top, right, bottom), imageRect);
  }

  double _dominantFontSize(
    List<({double size, double weight})> samples,
    {double clusterRatio = 1.32,}
  ) {
    samples.sort((a, b) => a.size.compareTo(b.size));
    if (samples.length == 1) return samples.single.size;
    var bestStart = 0;
    var bestEnd = 1;
    var bestScore = -1.0;
    for (var start = 0; start < samples.length; start++) {
      var end = start + 1;
      while (end < samples.length &&
          samples[end].size <= samples[start].size * clusterRatio) {
        end++;
      }
      final clusterWeight = samples
          .sublist(start, end)
          .fold(0.0, (sum, sample) => sum + sample.weight);
      final medianSize = samples[(start + end - 1) ~/ 2].size;
      final relativeSize = medianSize / math.max(1e-6, samples.last.size);
      final score = clusterWeight * math.pow(relativeSize, .28);
      if (score > bestScore) {
        bestStart = start;
        bestEnd = end;
        bestScore = score;
      }
    }
    final cluster = samples.sublist(bestStart, bestEnd);
    final total = cluster.fold(0.0, (sum, sample) => sum + sample.weight);
    var cumulative = 0.0;
    for (final sample in cluster) {
      cumulative += sample.weight;
      if (cumulative >= total / 2) return sample.size;
    }
    return cluster.last.size;
  }


  double _sourceFontSize(
    _TranslationLayoutBlock block,
    List<Rect> regionBounds,
  ) {
    final bodyBlock = _isBodyBlock(block);
    final sourceLanguage = artifact.sourceLanguage
        .split(RegExp('[-_]')).first.toLowerCase();
    final squareGlyphs = {'ja', 'ko', 'zh'}.contains(sourceLanguage);
    final samples = List.generate(block.regions.length, (index) {
      final decodedCharacters = math.max(
        1,
        _characters(block.regions[index].region.sourceText),
      );
      final bounds = regionBounds[index];
      final crossExtent = block.orientation == ComicTextOrientation.vertical
          ? bounds.width
          : bounds.height;
      final mainExtent = block.orientation == ComicTextOrientation.vertical
          ? bounds.height
          : bounds.width;
      final region = block.regions[index].region;
      final bodyContext =
          region.bubbleGroupId != null ||
          region.bubblePolygon != null ||
          region.bubbleCandidatePolygon != null ||
          bodyBlock;
      // A small recognizer may decode only one glyph from a multi-glyph OCR
      // line. Ink aspect still preserves its approximate character count and
      // prevents mainExtent / 1 from inflating the source font estimate.
      final size = comicTextSourceFontSize(
        crossExtent: crossExtent,
        mainExtent: mainExtent,
        decodedCharacters: decodedCharacters,
        bodyContext: bodyContext,
        squareGlyphs: squareGlyphs,
      );
      return (
        size: math.max(1.0, size).toDouble(),
        weight: decodedCharacters.toDouble(),
      );
    });
    return _dominantFontSize(samples);
  }

  double _preferredFontSize(_TranslationLayoutBlock block, List<Rect> regionBounds,
      {bool useBodyReference = true}) {
    final local = _sourceFontSize(block, regionBounds);
    final reference = useBodyReference && _isBodyBlock(block) ? bodyFontRatio : null;
    // A rendering preference must never feed bubble bounds or group membership.
    return (reference == null ? local
        : math.max(local, reference * _layoutImageRect!.width)) * fontScale;
  }

  bool _isBodyBlock(_TranslationLayoutBlock block) {
    if (block.regions.any((region) =>
        region.region.kind == ComicTextKind.soundEffect)) {
      return false;
    }
    final characters = block.regions.fold(0, (count, region) =>
        count + _characters(region.region.sourceText));
    return characters >= 4 || block.regions.any((region) =>
        region.region.bubbleGroupId != null ||
        region.region.bubblePolygon != null ||
        region.region.bubbleCandidatePolygon != null);
  }


  List<_TranslationLayoutOption> _layoutOptions(
    _TranslationLayoutBlock block,
    Rect bounds,
    List<Rect> regionBounds,
    Rect imageRect,
    bool insideBubble,
  ) {
    final sourceBounds = regionBounds
        .reduce((value, next) => value.expandToInclude(next));
    final sourceCenter = _sourceCenter(block, imageRect, sourceBounds);
    final sourceFontSize = _sourceFontSize(block, regionBounds);
    final initialWidth = math.min(
      bounds.width,
      sourceBounds.width + math.max(6, sourceFontSize * .7),
    );
    final initialHeight = math.min(
      bounds.height,
      sourceBounds.height + math.max(6, sourceFontSize * .7),
    );
    final text = _laneText(block.bands);
    final breakHints = _breakHints(block.bands, text);
    final sourceBandCharacters = block.bands.map((band) => band.fold(
      0,
      (count, region) => count + _characters(region.region.sourceText),
    )).toList();
    final targetBandCharacters = block.bands.map((band) =>
        _characters(_bandText(band))).toList();
    final factors = insideBubble
        ? const [0.0, .22, .45, .68, .85, 1.0]
        : const [0.0];
    final diagonal = math.max(
      1.0,
      math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height),
    );
    return factors.map((factor) {
      final width = initialWidth + (bounds.width - initialWidth) * factor;
      final height = initialHeight + (bounds.height - initialHeight) * factor;
      final laneBounds = _rectAroundAnchor(
        sourceCenter,
        width,
        height,
        bounds,
      );
      final positionPenalty = (laneBounds.center - sourceCenter).distance;
      return _TranslationLayoutOption(
        [_TranslationTextLane(
          block.regions,
          text,
          laneBounds,
          breakHints,
          sourceBandCharacters,
          targetBandCharacters,
        )],
        positionPenalty / diagonal,
      );
    }).toList();
  }

  Rect _rectAroundAnchor(
    Offset anchor,
    double width,
    double height,
    Rect container,
  ) {
    final safeWidth = width.clamp(0.0, container.width).toDouble();
    final safeHeight = height.clamp(0.0, container.height).toDouble();
    final halfWidth = safeWidth / 2;
    final halfHeight = safeHeight / 2;
    final minCenterX = container.left + halfWidth;
    final minCenterY = container.top + halfHeight;
    // Clamp travel from one origin. At factor=1, calculating left+half and
    // right-half independently can invert the equal bounds by one ULP.
    final centerTravelX = container.width - safeWidth;
    final centerTravelY = container.height - safeHeight;
    final center = Offset(
      minCenterX +
          (anchor.dx - minCenterX).clamp(0.0, centerTravelX).toDouble(),
      minCenterY +
          (anchor.dy - minCenterY).clamp(0.0, centerTravelY).toDouble(),
    );
    return Rect.fromCenter(
      center: center,
      width: safeWidth,
      height: safeHeight,
    );
  }


  Offset _sourceCenter(
    _TranslationLayoutBlock block,
    Rect imageRect,
    Rect sourceBounds,
  ) {
    var totalWeight = 0.0;
    var x = 0.0;
    var y = 0.0;
    for (final layout in block.regions) {
      final bounds = _displayBounds(layout.inkBounds, imageRect);
      // Area-weighted text centres keep equal columns centred while making a
      // tiny ruby/annotation box unable to drag the whole translation away.
      final weight = math.max(1.0, bounds.width * bounds.height);
      totalWeight += weight;
      x += bounds.center.dx * weight;
      y += bounds.center.dy * weight;
    }
    if (totalWeight <= 0) return sourceBounds.center;
    return Offset(
      (x / totalWeight).clamp(sourceBounds.left, sourceBounds.right).toDouble(),
      (y / totalWeight).clamp(sourceBounds.top, sourceBounds.bottom).toDouble(),
    );
  }

  Rect _openBubbleBounds(
    Rect sourceBounds,
    double sourceFontSize,
    Rect imageRect,
  ) => sourceBounds
      .inflate(math.max(3, sourceFontSize * 0.7))
      .intersect(imageRect);

  Rect _safeBubbleBounds(
    List<List<Offset>> bubblePolygons,
    Rect sourceBounds,
    Offset sourceCenter,
    double sourceFontSize,
    Rect layoutBounds,
  ) => comicBubbleInnerBounds(
    polygons: bubblePolygons,
    sourceBounds: sourceBounds,
    sourceCenter: sourceCenter,
    sourceFontSize: sourceFontSize,
    layoutBounds: layoutBounds,
  );
  Color _regionBackground(ComicTranslatedRegion region) =>
      region.backgroundArgb == null
          ? background.withValues(alpha: 1)
          : Color(region.backgroundArgb!);

  Color _regionForeground(ComicTranslatedRegion region) =>
      region.foregroundArgb == null
          ? foreground
          : Color(region.foregroundArgb!);

  ({Path path, List<List<Offset>> polygons})? _blockBubble(
    _TranslationLayoutBlock block,
    Rect imageRect,
  ) {
    final confirmed = block.bubblePolygons
        .map((polygon) => _displayPolygon(polygon, imageRect))
        .toList();
    final inkBounds = block.regions
        .map((region) => _displayBounds(region.inkBounds, imageRect))
        .toList();
    final candidates = block.bubbleCandidatePolygons
        .map((polygon) => _displayPolygon(polygon, imageRect))
        .toList();
    final decision = exploreComicBubbleBoundary(
      inkBounds: inkBounds,
      confirmedPolygons: confirmed,
      candidatePolygons: candidates,
    );
    final polygons = decision.polygons;
    if (polygons == null) return null;
    Path union(List<List<Offset>> polygons) {
      var path = Path()..addPolygon(polygons.first, true);
      for (final polygon in polygons.skip(1)) {
        path = Path.combine(
          PathOperation.union,
          path,
          Path()..addPolygon(polygon, true),
        );
      }
      return path;
    }
    return (path: union(polygons), polygons: polygons);
  }

  Locale? get _targetLocale => _languageLocale(artifact.targetLanguage);

  Locale? _languageLocale(String language) {
    if (language == 'auto') return null;
    final parts = language.split(RegExp('[-_]'));
    return Locale.fromSubtags(
      languageCode: parts.first,
      countryCode: parts.elementAtOrNull(1),
    );
  }

  List<_TranslationLayoutBlock> _layoutBlocks() {
    final cached = _blocks;
    if (cached != null) return cached;
    final valid = artifact.regions.where((region) =>
        region.polygon.length >= 3 &&
        region.polygon.every(
          (point) => point.x.isFinite && point.y.isFinite,
        )).toList();
    final layouts = {
      for (final region in valid)
        region.ocrRegionId: _TranslationLayoutRegion(
          region,
          _normalizedBounds(region),
          _normalizedInkBounds(region),
        ),
    };
    final grouping = ComicTextGrouping(
      imageWidth: artifact.imageWidth,
      imageHeight: artifact.imageHeight,
      sourceLanguage: artifact.sourceLanguage,
    );
    final groups = grouping.resolve(valid.map((region) => ComicTextRegion(
      value: region,
      id: region.ocrRegionId,
      text: region.sourceText,
      polygon: region.polygon,
      sourceMaskPolygons: region.sourceMaskPolygons,
      orientation: region.orientation,
      backgroundArgb: region.backgroundArgb,
      bubbleGroupId: region.bubbleGroupId,
      bubblePolygon: region.bubblePolygon,
    )).toList());
    for (final group in groups) {
      layoutCache.sourceBounds['layout:${group.key}'] = group.regions
          .map((region) => layouts[region.id]!.inkBounds)
          .reduce((value, next) => value.expandToInclude(next));
    }
    final blocks = groups.map((group) {
      final values = group.regions
          .where((region) =>
              _visibleTranslation(region.value.translatedText).isNotEmpty)
          .map((region) => layouts[region.id]!)
          .toList();
      final bands = group.bands.map((band) => band.regions
          .where((region) =>
              _visibleTranslation(region.value.translatedText).isNotEmpty)
          .map((region) => layouts[region.id]!)
          .toList()).where((band) => band.isNotEmpty).toList();
      if (values.isEmpty) return null;
      return _TranslationLayoutBlock(
        key: 'layout:${group.key}',
        regions: values,
        orientation: _blockOrientation(values, group.orientation),
        bands: bands,
        bubblePolygons: group.regions
            .map((region) => region.value.bubblePolygon)
            .whereType<List<NormalizedPoint>>()
            .where((polygon) => polygon.length >= 3 && polygon.every(
                (point) => point.x.isFinite && point.y.isFinite))
            .toList(),
        // Candidate contours are page-level evidence. Grouping is already
        // complete here, so an open block may inspect a candidate recovered
        // beside another member instead of being limited by native g-/group.
        bubbleCandidatePolygons: artifact.regions
            .map((region) => region.bubbleCandidatePolygon)
            .whereType<List<NormalizedPoint>>()
            .where((polygon) => polygon.length >= 3 && polygon.every(
                (point) => point.x.isFinite && point.y.isFinite))
            .toList(),
      );
    }).whereType<_TranslationLayoutBlock>().toList();
    blocks.sort((a, b) {
      double order(_TranslationLayoutBlock block) {
        final top = block.regions
            .map((region) => region.inkBounds.top)
            .reduce(math.min);
        final left = block.regions
            .map((region) => region.inkBounds.left)
            .reduce(math.min);
        return top * artifact.imageWidth + left;
      }
      return order(a).compareTo(order(b));
    });
    return _blocks = blocks;
  }

  ComicTextOrientation _blockOrientation(
    List<_TranslationLayoutRegion> regions,
    ComicTextOrientation fallback,
  ) {
    var vertical = 0;
    var horizontal = 0;
    final hasBody = regions.any((region) =>
        _characters(region.region.sourceText) > 1);
    for (final region in regions) {
      final characters = _characters(region.region.sourceText);
      if (hasBody && characters == 1) continue;
      final bounds = region.inkBounds;
      final width = bounds.width * artifact.imageWidth;
      final height = bounds.height * artifact.imageHeight;
      final orientation = height >= width * 1.15
          ? ComicTextOrientation.vertical
          : width >= height * 1.15
              ? ComicTextOrientation.horizontal
              : region.region.orientation;
      if (orientation == ComicTextOrientation.vertical) {
        vertical += characters;
      } else {
        horizontal += characters;
      }
    }
    if (vertical == horizontal) return fallback;
    return vertical > horizontal
        ? ComicTextOrientation.vertical
        : ComicTextOrientation.horizontal;
  }


  Rect _normalizedBounds(ComicTranslatedRegion region) => _bounds(
    region.polygon.map((point) => Offset(point.x, point.y)),
  );

  Rect _normalizedInkBounds(ComicTranslatedRegion region) {
    final points = region.sourceMaskPolygons
        .expand((polygon) => polygon)
        .where((point) => point.x.isFinite && point.y.isFinite)
        .map((point) => Offset(point.x, point.y))
        .toList();
    return points.isEmpty ? _normalizedBounds(region) : _bounds(points);
  }


  List<Offset> _displayPolygon(
    List<NormalizedPoint> polygon,
    Rect imageRect,
  ) => polygon.map((point) => Offset(
    imageRect.left + point.x * imageRect.width,
    imageRect.top + point.y * imageRect.height,
  )).toList();

  Rect _displayBounds(Rect bounds, Rect imageRect) => Rect.fromLTRB(
    imageRect.left + bounds.left * imageRect.width,
    imageRect.top + bounds.top * imageRect.height,
    imageRect.left + bounds.right * imageRect.width,
    imageRect.top + bounds.bottom * imageRect.height,
  );

  Rect _bounds(Iterable<Offset> points) {
    final iterator = points.iterator;
    iterator.moveNext();
    var left = iterator.current.dx;
    var top = iterator.current.dy;
    var right = left;
    var bottom = top;
    while (iterator.moveNext()) {
      final point = iterator.current;
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

}
