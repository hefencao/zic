import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

void main() {
  testWidgets('tiny partial-frame WebP is not upscaled by Flutter codec', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WebpPlayerScreen.asset(
          entry: const WebpDemoEntry(
            id: 'partial-blend',
            title: '局部帧',
            description: 'test',
            asset: 'assets/demo/animated/partial_blend.webp',
            byteLength: 188,
            frameCount: 2,
            loopCount: 0,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Flutter codec'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isNot(isA<ResizeImage>()));
    expect(image.filterQuality, FilterQuality.none);
    expect(image.isAntiAlias, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
