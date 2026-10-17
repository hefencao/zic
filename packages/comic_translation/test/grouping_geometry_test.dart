import 'dart:collection';

import 'package:comic_translation/src/grouping.dart';
import 'package:comic_translation/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dense masks are read once per grouping and released between passes', () {
    const bubble = [NormalizedPoint(.1, .05), NormalizedPoint(.8, .05),
      NormalizedPoint(.8, .42), NormalizedPoint(.1, .42)];
    final masks = <_CountingList<NormalizedPoint>>[];
    final regions = List.generate(3, (index) {
      final top = .1 + index * .09;
      final polygon = [NormalizedPoint(.2, top), NormalizedPoint(.7, top),
        NormalizedPoint(.7, top + .08), NormalizedPoint(.2, top + .08)];
      final mask = _CountingList(List.generate(1024, (i) => polygon[i % 4]));
      masks.add(mask);
      return ComicTextRegion(value: index, id: 'r$index', text: '안녕하세요',
        polygon: polygon, sourceMaskPolygons: [mask],
        orientation: ComicTextOrientation.horizontal, backgroundArgb: 0xffffffff,
        bubbleGroupId: 0, bubblePolygon: bubble);
    });
    const grouping = ComicTextGrouping(imageWidth: 1000, imageHeight: 2000,
      sourceLanguage: 'ko');
    for (var pass = 1; pass <= 2; pass++) {
      final groups = grouping.resolve(regions);
      expect(groups, hasLength(1));
      expect(groups.single.bands.map((band) => band.regions.single.id), ['r0', 'r1', 'r2']);
      for (final mask in masks) {
        expect(mask.reads, mask.length * pass,
          reason: 'pair/container comparisons reuse geometry only within this pass');
      }
    }
  });
}

class _CountingList<T> extends ListBase<T> {
  _CountingList(this.values);
  final List<T> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => values.length = value;
  @override
  T operator [](int index) { reads++; return values[index]; }
  @override
  void operator []=(int index, T value) => values[index] = value;
}
