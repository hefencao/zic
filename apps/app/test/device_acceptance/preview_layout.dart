import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/debug_trace_export.dart';

import 'preview_layout_fixture.dart';

// Explicit device entry: original details/artwork widgets with in-memory PNGs.
// No user library, preferences, artifact index or network is opened.
final _captureKey = GlobalKey();
final _cases = <Map<String, Object?>>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final configurations = <_Case>[
    const _Case('narrow', Size(240, 640),
      <Size>[Size(48, 240), Size(48, 240), Size(48, 240), Size(48, 240)]),
    const _Case('ordinary-local-reorder', Size(400, 900),
      <Size>[Size(48, 240), Size(80, 100), Size(240, 48), Size(48, 240),
        Size(100, 100), Size(48, 240), Size(48, 240)]),
    const _Case('wide-short-sparse', Size(800, 400),
      <Size>[Size(48, 240), Size(48, 240), Size(48, 240), Size(48, 240)]),
    const _Case('wide-short-cap-set', Size(800, 400),
      <Size>[Size(48, 240), Size(80, 100), Size(100, 100)]),
    const _Case('extreme-mixed', Size(800, 400),
      <Size>[Size(480, 24), Size(24, 480), Size(24, 480)]),
    const _Case('wide-short-single', Size(800, 400), <Size>[Size(48, 240)]),
    for (var maximum = 1; maximum <= 8; maximum++)
      _Case('user-maximum-$maximum', const Size(400, 900),
        const <Size>[Size(48, 240), Size(48, 240), Size(48, 240), Size(48, 240)],
        maximum: maximum),
  ];
  var passed = false;
  String? failure;
  try {
    for (final configuration in configurations) {
      await _runCase(configuration);
    }
    passed = true;
  } on Object catch (error, stack) {
    failure = '$error\n$stack';
    debugPrint('preview-layout-failed $failure');
  } finally {
    final result = <String, Object?>{
      'passed': passed, 'failure': failure, 'cases': _cases,
      'boundary': 'Actual Android details/artwork raster and layout in controlled '
          'logical windows; in-memory PNGs, no real-origin/crop/network/Reader claim.',
    };
    await exportDebugTraceFile(
      suggestedName: 'zic-preview-layout-${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(result))),
      relativeDirectory: 'Debug',
    );
    runApp(MaterialApp(home: Scaffold(body: Center(
      child: Text(passed ? '预览排版验收通过' : '预览排版验收失败')))));
    debugPrint('preview-layout-complete passed=$passed cases=${_cases.length}');
  }
}

Future<void> _runCase(_Case configuration) async {
  final images = await previewFixtureImages(configuration.dimensions);
  runApp(MaterialApp(home: Scaffold(body: Center(child: FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(width: configuration.view.width, height: configuration.view.height,
      child: RepaintBoundary(key: _captureKey,
        child: KeyedSubtree(key: ValueKey(configuration.name),
          child: previewLayoutFixture(dimensions: configuration.dimensions,
            images: images, maximum: configuration.maximum,
            logicalView: configuration.view)))),
  )))));
  await _frames(10);
  final scroll = (_element((element) => element.widget is Scrollable &&
    (element.widget as Scrollable).axisDirection == AxisDirection.down)!
      as StatefulElement).state as ScrollableState;
  for (var attempt = 0; attempt < 12 && _item(0) == null; attempt++) {
    scroll.position.jumpTo(math.min(scroll.position.maxScrollExtent,
      scroll.position.pixels + configuration.view.height * .6));
    await _frames(3);
  }
  _require(_item(0) != null, 'preview did not mount');
  final folded = _visibleRows(configuration.view);
  _require(folded.length == 1, 'folded preview is not one row');
  final firstRow = folded.single;
  final tallest = firstRow.reduce((a, b) => a.rect.height > b.rect.height ? a : b);
  await Scrollable.ensureVisible(_item(tallest.index)!, alignment: 0);
  await _frames(10);

  Uint8List? png;
  var markers = false;
  for (var attempt = 0; attempt < 40; attempt++) {
    final capture = _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await capture.toImage(pixelRatio: 1);
    try {
      final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      markers = _markersVisible(configuration, _visibleRows(configuration.view).single,
        pixels, image.width, image.height);
      if (markers) {
        _checkMarkerNegativeControl(configuration,
          _visibleRows(configuration.view).single, pixels, image.width, image.height);
        final encoded = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        png = encoded.buffer.asUint8List(encoded.offsetInBytes, encoded.lengthInBytes);
        break;
      }
    } finally {
      image.dispose();
    }
    await _frames(2);
  }
  _require(markers, 'complete PNG first/last markers are not visible');

  final expand = _element((element) =>
    element.widget.key == details.comicDetailsPreviewExpandKey)!.widget as IconButton;
  _require(expand.onPressed != null, 'preview expansion unavailable');
  expand.onPressed!();
  await _frames(10);
  final pagerElement = _element((element) => element.widget is PageView)!;
  final pager = pagerElement.widget as PageView;
  final pageCount = pager.childrenDelegate.estimatedChildCount!;
  final pagerHeight = (pagerElement.findRenderObject()! as RenderBox).size.height;
  _require(pagerHeight + (pageCount > 1 ? 28 : 0) <= configuration.view.height * .9 + .001,
    'expanded image area exceeds screen height');
  final expanded = _visibleRows(configuration.view).first;
  _require(_sameSizes(firstRow, expanded), 'folded/expanded first row changed');
  final allRows = <List<_Tile>>[];
  for (var page = 0; page < pageCount; page++) {
    pager.controller!.jumpToPage(page);
    await _frames(5);
    allRows.addAll(_visibleRows(configuration.view));
  }
  _verifyRows(configuration, allRows);
  final indices = allRows.expand((row) => row.map((tile) => tile.index)).toList();
  _require(indices.toSet().length == configuration.dimensions.length &&
    indices.length == configuration.dimensions.length, 'page identity lost or duplicated');
  if (configuration.name == 'ordinary-local-reorder') {
    _require(indices.join(',') == '0,2,1,3,4,5,6', 'source local reorder changed');
  }
  pager.controller!.jumpToPage(0);
  await _frames(5);
  (_element((element) => element.widget.key == details.comicDetailsPreviewExpandKey)!
    .widget as IconButton).onPressed!();
  await _frames(5);
  _require(_sameSizes(firstRow, _visibleRows(configuration.view).single),
    'collapse changed first-row geometry');
  _cases.add(<String, Object?>{
    'name': configuration.name, 'status': 'passed',
    'logicalView': <double>[configuration.view.width, configuration.view.height],
    'maximum': configuration.maximum, 'pages': pageCount,
    'expandedAreaHeight': pagerHeight + (pageCount > 1 ? 28 : 0),
    'rows': allRows.map((row) => row.map((tile) => <String, Object?>{
      'index': tile.index, 'width': tile.rect.width, 'height': tile.rect.height,
    }).toList()).toList(),
    'fullPNGFirstAndLastMarkersVisible': markers, 'foldExpandCollapseSameFirstRow': true,
    'markerOracleRejectsBackgroundAtEitherEnd': true,
    'foldedRasterPNG': base64Encode(png!),
  });
  debugPrint('preview-layout-case passed=${configuration.name} pages=$pageCount');
}

void _verifyRows(_Case configuration, List<List<_Tile>> rows) {
  final completeAreas = <double>[];
  final sparseAreas = <double>[];
  for (final row in rows) {
    final landscape = row.any((tile) {
      final image = configuration.dimensions[tile.index];
      return image.width > image.height;
    });
    final limit = math.min(configuration.maximum, landscape ? 2 : 3);
    _require(row.length <= limit, 'per-row count exceeds declared limit');
    final area = row.first.rect.width * row.first.rect.height;
    for (final tile in row) {
      _require((tile.rect.width * tile.rect.height - area).abs() < .01,
        'row areas differ');
      _require(tile.rect.height <= configuration.view.height * .9 + .001,
        'single tile exceeds height bound');
    }
    if (row.length == limit || rows.length == 1) {
      final width = row.fold<double>(0, (sum, tile) => sum + tile.rect.width) +
        8 * (row.length - 1);
      _require((width - configuration.view.width).abs() < .01, 'complete row lost width');
    }
    if (row.length == limit) {
      completeAreas.add(area);
    } else {
      sparseAreas.add(area);
    }
  }
  if (completeAreas.isNotEmpty) {
    final reference = completeAreas.reduce(math.min);
    _require(sparseAreas.every((area) => area <= reference * 2.4 + .01),
      'sparse final area exceeds reference');
  }
}

bool _markersVisible(_Case configuration, List<_Tile> tiles, ByteData pixels,
    int width, int height) {
  for (final tile in tiles) {
    final source = configuration.dimensions[tile.index];
    final destination = applyBoxFit(BoxFit.contain, source, tile.rect.size).destination;
    final rect = Alignment.center.inscribe(destination, tile.rect);
    for (final top in <bool>[true, false]) {
      final x = rect.center.dx.floor();
      final inset = 1.5 * rect.height / source.height;
      final y = (top ? rect.top + inset : rect.bottom - inset).floor();
      if (x < 0 || x >= width || y < 0 || y >= height) return false;
      final offset = 4 * (y * width + x);
      for (var channel = 0; channel < 3; channel++) {
        final value = pixels.getUint8(offset + channel);
        if (top ? value < 220 : value > 8) return false;
      }
    }
  }
  return true;
}

void _checkMarkerNegativeControl(_Case configuration, List<_Tile> tiles,
    ByteData pixels, int width, int height) {
  final tile = tiles.first;
  final source = configuration.dimensions[tile.index];
  final destination = applyBoxFit(BoxFit.contain, source, tile.rect.size).destination;
  final rect = Alignment.center.inscribe(destination, tile.rect);
  for (final top in <bool>[true, false]) {
    final inset = 1.5 * rect.height / source.height;
    final y = (top ? rect.top + inset : rect.bottom - inset).floor();
    final offset = 4 * (y * width + rect.center.dx.floor());
    final original = List<int>.generate(3, (channel) => pixels.getUint8(offset + channel));
    for (var channel = 0; channel < 3; channel++) {
      pixels.setUint8(offset + channel, 19);
    }
    final rejected = !_markersVisible(configuration, tiles, pixels, width, height);
    for (var channel = 0; channel < 3; channel++) {
      pixels.setUint8(offset + channel, original[channel]);
    }
    _require(rejected, 'marker oracle accepted background at an image end');
  }
}

List<List<_Tile>> _visibleRows(Size view) {
  final grouped = <Element, List<_Tile>>{};
  final capture = _captureKey.currentContext!.findRenderObject()! as RenderBox;
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('comic-details-preview-item:')) {
      final index = int.parse(key.value.substring('comic-details-preview-item:'.length));
      final box = element.findRenderObject()! as RenderBox;
      final rect = box.localToGlobal(Offset.zero, ancestor: capture) & box.size;
      if (rect.center.dx >= 0 && rect.center.dx < view.width) {
        Element? row;
        element.visitAncestorElements((ancestor) {
          if (ancestor.widget is Row) { row = ancestor; return false; }
          return true;
        });
        grouped.putIfAbsent(row!, () => <_Tile>[]).add(_Tile(index, rect));
      }
    }
    element.visitChildren(visit);
  }
  visit(_captureKey.currentContext! as Element);
  return grouped.values.toList();
}

bool _sameSizes(List<_Tile> a, List<_Tile> b) => a.length == b.length &&
  List<bool>.generate(a.length, (index) => a[index].index == b[index].index &&
    (a[index].rect.width - b[index].rect.width).abs() < .001 &&
    (a[index].rect.height - b[index].rect.height).abs() < .001).every((value) => value);

Element? _item(int index) => _element((element) =>
    element.widget.key == details.comicDetailsPreviewItemKey(index));

Element? _element(bool Function(Element element) matches) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (matches(element)) { found = element; return; }
    element.visitChildren(visit);
  }
  visit(_captureKey.currentContext! as Element);
  return found;
}

Future<void> _frames(int count) async {
  for (var index = 0; index < count; index++) {
    await WidgetsBinding.instance.endOfFrame;
  }
}

void _require(bool passed, String reason) {
  if (!passed) throw StateError(reason);
}

final class _Tile {
  const _Tile(this.index, this.rect);
  final int index;
  final Rect rect;
}

final class _Case {
  const _Case(this.name, this.view, this.dimensions, {this.maximum = 4});
  final String name;
  final Size view;
  final List<Size> dimensions;
  final int maximum;
}
