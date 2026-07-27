import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/main.dart';

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
        picker: () async => XFile.fromData(
          bytes,
          name: 'local.webp',
          mimeType: 'image/webp',
        ),
      ),
    );
    await tester.tap(find.text('导入本地 WebP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('local.webp'), findsOneWidget);
  });
}
