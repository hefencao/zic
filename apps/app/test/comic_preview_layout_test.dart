import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/comic_details.dart' as details;

import 'device_acceptance/preview_layout_fixture.dart';

void main() {
  testWidgets('wide short preview keeps full row width within screen height',
      (tester) async {
    await _mount(tester, const Size(800, 400), const <Size>[Size(48, 240)]);
    final item = find.byKey(details.comicDetailsPreviewItemKey(0));
    final size = tester.getSize(item);
    expect(size.width, closeTo(800, .001));
    expect(size.height, lessThanOrEqualTo(360));
  });

  testWidgets('bounded mixed row keeps equal areas and full width', (tester) async {
    await _mount(tester, const Size(800, 400),
      const <Size>[Size(48, 240), Size(240, 48)]);
    final sizes = _sizes(tester, 2);
    _expectFullEqualAreaRow(sizes, 800, 360);
    expect(sizes.first.height, lessThan(sizes.first.width / .45));
    expect(sizes.last.width / sizes.last.height, closeTo(2.2, .001));
    await _expand(tester);
    expect(_sizes(tester, 2), sizes);
    expect(tester.getSize(find.byType(PageView)).height, lessThanOrEqualTo(360));
  });

  testWidgets('height bound can retire a provisional capped tile', (tester) async {
    await _mount(tester, const Size(800, 400),
      const <Size>[Size(48, 240), Size(80, 100), Size(100, 100)]);
    final sizes = _sizes(tester, 3);
    _expectFullEqualAreaRow(sizes, 800, 360);
    expect(sizes[1].width / sizes[1].height, closeTo(.8, .001));
    expect(sizes[2].width / sizes[2].height, closeTo(1, .001));
  });

  testWidgets('height-limited pagination preserves sparse final area and first row',
      (tester) async {
    await _mount(tester, const Size(800, 400),
      const <Size>[Size(48, 240), Size(48, 240), Size(48, 240), Size(48, 240)]);
    final folded = _sizes(tester, 3);
    _expectFullEqualAreaRow(folded, 800, 360);
    await _expand(tester);
    expect(_sizes(tester, 3), folded);
    final pager = find.byType(PageView);
    expect(tester.getSize(pager).height + 28, lessThanOrEqualTo(360));
    await tester.drag(pager, const Offset(-700, 0));
    await tester.pumpAndSettle();
    final sparse = tester.getSize(find.byKey(details.comicDetailsPreviewItemKey(3)));
    expect(sparse.height, lessThanOrEqualTo(360));
    expect(sparse.width * sparse.height,
      lessThanOrEqualTo(folded.first.width * folded.first.height * 2.4 + .001));
    expect(sparse.width, lessThan(800));
  });

  testWidgets('smaller user maximum and ordinary aspect geometry remain intact',
      (tester) async {
    await _mount(tester, const Size(320, 800),
      const <Size>[Size(48, 240), Size(48, 240), Size(48, 240)], maximum: 2);
    final sizes = _sizes(tester, 2);
    _expectFullEqualAreaRow(sizes, 320, 720);
    for (final size in sizes) {
      expect(size.width / size.height, closeTo(.45, .001));
    }
    expect(find.byKey(details.comicDetailsPreviewItemKey(2)), findsNothing);
  });
}

Future<void> _mount(WidgetTester tester, Size view, List<Size> dimensions,
    {int maximum = 4}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = view;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final images = await tester.runAsync(() => previewFixtureImages(dimensions));
  await tester.pumpWidget(previewLayoutFixture(
    dimensions: dimensions, images: images!, maximum: maximum));
  await tester.pump();
  final item = find.byKey(details.comicDetailsPreviewItemKey(0));
  for (var attempt = 0; attempt < 10 && item.evaluate().isEmpty; attempt++) {
    await tester.drag(find.byKey(details.remoteComicDetailsScreenKey),
      const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(item, findsOneWidget);
  expect(tester.takeException(), isNull);
}

List<Size> _sizes(WidgetTester tester, int count) => <Size>[
  for (var index = 0; index < count; index++)
    tester.getSize(find.byKey(details.comicDetailsPreviewItemKey(index))),
];

void _expectFullEqualAreaRow(List<Size> sizes, double width, double maximumHeight) {
  expect(sizes.fold<double>(0, (sum, size) => sum + size.width) +
    8 * (sizes.length - 1), closeTo(width, .001));
  final area = sizes.first.width * sizes.first.height;
  for (final size in sizes) {
    expect(size.width * size.height, closeTo(area, .001));
    expect(size.height, lessThanOrEqualTo(maximumHeight));
  }
}

Future<void> _expand(WidgetTester tester) async {
  final expand = find.byKey(details.comicDetailsPreviewExpandKey);
  await tester.ensureVisible(expand);
  await tester.pumpAndSettle();
  await tester.tap(expand);
  await tester.pumpAndSettle();
}
