import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';

void main() {
  testWidgets('one viewport preserves source aspect for every media renderer',
      (tester) async {
    const childKey = ValueKey<String>('media-child');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: MediaAspectViewport(
              dimensions: const Size(400, 100),
              fit: BoxFit.contain,
              builder: (innerFit) => const ColoredBox(
                key: childKey,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(childKey)), const Size(200, 50));
    expect(find.byKey(mediaAspectViewportKey), findsOneWidget);
  });

  testWidgets('unknown intrinsic size keeps requested fit instead of filling',
      (tester) async {
    const fitKey = ValueKey<String>('unresolved-media-fit');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 200,
          child: MediaAspectViewport(
            dimensions: null,
            fit: BoxFit.contain,
            builder: (innerFit) => FittedBox(
              key: fitKey,
              fit: innerFit,
              child: const SizedBox(width: 400, height: 100),
            ),
          ),
        ),
      ),
    );

    expect(tester.widget<FittedBox>(find.byKey(fitKey)).fit, BoxFit.contain);
  });
}
