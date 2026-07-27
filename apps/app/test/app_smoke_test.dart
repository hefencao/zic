import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/main.dart';
import 'package:zic/webp_demo.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 40,
  Duration step = const Duration(milliseconds: 25),
}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  testWidgets('home exposes static, bundled WebP, and local import entries', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    await tester.pump();

    expect(find.text('100 页静态章节'), findsOneWidget);
    expect(find.text('内置动图 WebP'), findsOneWidget);
    expect(find.text('导入本地 WebP'), findsOneWidget);
  });

  testWidgets('static demo opens from home', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.text('100 页静态章节'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 100'), findsOneWidget);
  });

  testWidgets('bundled Animated WebP catalog is reachable', (tester) async {
    await tester.pumpWidget(const App());
    await tester.tap(find.text('内置动图 WebP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('无限循环 · 基础帧'), findsOneWidget);
    expect(find.text('有限循环 · 2 次'), findsOneWidget);
    expect(find.text('局部帧 · Alpha Blend'), findsOneWidget);
  });

  testWidgets('local WebP picker opens a preview route', (tester) async {
    final data = await rootBundle.load(
      'assets/demo/animated/finite_loop.webp',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await tester.pumpWidget(
      App(
        picker: () async => PickedWebp(
          file: XFile.fromData(
            bytes,
            mimeType: 'image/webp',
          ),
          displayName: 'local.webp',
        ),
      ),
    );
    await tester.tap(find.text('导入本地 WebP'));
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(webpPreviewScreenKey),
    );

    final title = tester.widget<Text>(
      find.byKey(webpPreviewTitleKey),
    );
    expect(title.data, 'local.webp');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('malformed local WebP shows a controlled preview error', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(<int>[
      0x52,
      0x49,
      0x46,
      0x46,
      0,
      0,
      0,
      0,
      0x57,
      0x45,
      0x42,
      0x50,
    ]);
    await tester.pumpWidget(
      App(
        picker: () async => PickedWebp(
          file: XFile.fromData(
            bytes,
            mimeType: 'image/webp',
          ),
          displayName: 'broken.webp',
        ),
      ),
    );
    await tester.tap(find.text('导入本地 WebP'));
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(webpPreviewScreenKey),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(webpPreviewErrorKey),
    );

    final title = tester.widget<Text>(
      find.byKey(webpPreviewTitleKey),
    );
    expect(title.data, 'broken.webp');
    final error = tester.widget<Text>(
      find.byKey(webpPreviewErrorKey),
    );
    expect(error.data, contains('WebP 文件无效'));
    expect(find.text('加载失败'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
