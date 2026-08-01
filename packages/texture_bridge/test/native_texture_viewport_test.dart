import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:texture_bridge/texture_bridge.dart';

void main() {
  testWidgets('external texture uses contain geometry for a wide source', (
    tester,
  ) async {
    const viewportKey = ValueKey<String>('native-texture-aspect-box');

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: NativeTextureViewport(
              textureId: 7,
              sourceWidth: 400,
              sourceHeight: 200,
              viewportKey: viewportKey,
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(viewportKey)), const Size(300, 150));
  });

  testWidgets('external texture uses contain geometry for a tall source', (
    tester,
  ) async {
    const viewportKey = ValueKey<String>('native-texture-aspect-box');

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: NativeTextureViewport(
              textureId: 8,
              sourceWidth: 100,
              sourceHeight: 200,
              viewportKey: viewportKey,
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(viewportKey)), const Size(150, 300));
  });

  testWidgets('external texture exposes width-fit presentation for stitch', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 300,
          height: 600,
          child: NativeTextureViewport(
            textureId: 9,
            sourceWidth: 100,
            sourceHeight: 200,
            fit: BoxFit.fitWidth,
          ),
        ),
      ),
    );

    final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fitted.fit, BoxFit.fitWidth);
    expect(fitted.alignment, Alignment.center);
  });


  testWidgets('authoritative stitched box fills without a second FittedBox', (
    tester,
  ) async {
    const viewportKey = ValueKey<String>('native-texture-fill-box');
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 300,
          height: 600,
          child: NativeTextureViewport(
            textureId: 10,
            sourceWidth: 104,
            sourceHeight: 208,
            fit: BoxFit.fill,
            viewportKey: viewportKey,
          ),
        ),
      ),
    );

    expect(find.byType(FittedBox), findsNothing);
    expect(tester.getSize(find.byKey(viewportKey)), const Size(300, 600));
  });

}
