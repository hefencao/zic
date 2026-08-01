import 'package:domain/domain.dart';
import 'package:test/test.dart';

import '../lib/src/vertical_reader_geometry.dart';

void main() {
  final pages = List<PageAsset>.generate(
    3,
    (index) => PageAsset(
      pageId: 'page-$index',
      chapterId: 'chapter',
      index: index,
      uri: Uri.parse('asset:///page-$index.png'),
      width: 1000,
      height: index == 1 ? 2400 : 1600,
    ),
  );

  test('stitch removes exactly one owned gap before the next page', () {
    final withGap = ReaderVerticalGeometry(
      pages: pages,
      ratios: const <String, double>{},
      viewportWidth: 400,
      viewportHeight: 800,
      stitch: false,
      rotationQuarterTurns: 0,
    );
    final stitched = ReaderVerticalGeometry(
      pages: pages,
      ratios: const <String, double>{},
      viewportWidth: 400,
      viewportHeight: 800,
      stitch: true,
      rotationQuarterTurns: 0,
    );

    expect(
      withGap.boundsAt(1).start - stitched.boundsAt(1).start,
      readerVerticalPageGap,
    );
    expect(stitched.extentAt(1), 960);
  });

  test('geometry changes preserve page identity and local pixel offset', () {
    final initialRatios = <String, double>{
      for (final page in pages) page.assetKey: 1.6,
    };
    final initial = ReaderVerticalGeometry(
      pages: pages,
      ratios: initialRatios,
      viewportWidth: 400,
      viewportHeight: 800,
      stitch: true,
      rotationQuarterTurns: 0,
    );
    final top = initial.boundsAt(1).start + 137;
    final anchor = initial.anchorForTop(top);

    final measured = ReaderVerticalGeometry(
      pages: pages,
      ratios: <String, double>{
        ...initialRatios,
        pages.first.assetKey: 2.4,
      },
      viewportWidth: 400,
      viewportHeight: 800,
      stitch: true,
      rotationQuarterTurns: 0,
    );
    final restored = measured.restoreTop(anchor);

    expect(anchor.index, 1);
    expect(anchor.offset, 137);
    expect(restored, measured.boundsAt(1).start + 137);
    expect(restored - top, closeTo(320, 1e-9));
  });


  test('stitched boundaries share one physical-pixel grid', () {
    final geometry = ReaderVerticalGeometry(
      pages: pages,
      ratios: <String, double>{
        pages[0].assetKey: 1.3333333333,
        pages[1].assetKey: 2.123456789,
        pages[2].assetKey: 1.777777777,
      },
      viewportWidth: 411.428571,
      viewportHeight: 890,
      stitch: true,
      rotationQuarterTurns: 0,
      devicePixelRatio: 2.75,
    );

    for (var index = 0; index < pages.length; index++) {
      final bounds = geometry.boundsAt(index);
      expect(
        bounds.start * geometry.devicePixelRatio,
        closeTo((bounds.start * geometry.devicePixelRatio).round(), 1e-9),
      );
      expect(
        bounds.end * geometry.devicePixelRatio,
        closeTo((bounds.end * geometry.devicePixelRatio).round(), 1e-9),
      );
      if (index + 1 < pages.length) {
        expect(bounds.end, geometry.boundsAt(index + 1).start);
      }
    }
  });

  test('unknown extents do not depend on current page state', () {
    final unknownPages = List<PageAsset>.generate(
      2,
      (index) => PageAsset(
        pageId: 'unknown-$index',
        chapterId: 'chapter',
        index: index,
        uri: Uri.parse('asset:///unknown-$index.png'),
      ),
    );
    final geometry = ReaderVerticalGeometry(
      pages: unknownPages,
      ratios: const <String, double>{},
      viewportWidth: 400,
      viewportHeight: 900,
      stitch: false,
      rotationQuarterTurns: 0,
    );

    expect(geometry.extentAt(0), 900);
    expect(geometry.extentAt(1), 900);
  });
}
