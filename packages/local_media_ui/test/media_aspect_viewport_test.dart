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

    expect(tester.getRect(find.byKey(childKey)).size, const Size(200, 50));
    final fitted = tester.widget<FittedBox>(find.descendant(
      of: find.byKey(mediaAspectViewportKey),
      matching: find.byType(FittedBox),
    ));
    expect(fitted.alignment, Alignment.center);
    expect(find.byKey(mediaAspectViewportKey), findsOneWidget);
  });

  testWidgets(
      'continuous fitWidth preserves source aspect across a transient parent extent',
      (tester) async {
    const childKey = ValueKey<String>('continuous-media-child');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: MediaAspectViewport(
              dimensions: const Size(100, 400),
              fit: BoxFit.fitWidth,
              builder: (_) => const ColoredBox(
                key: childKey,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );

    final fitted = tester.widget<FittedBox>(find.descendant(
      of: find.byKey(mediaAspectViewportKey),
      matching: find.byType(FittedBox),
    ));
    expect(fitted.fit, BoxFit.fitWidth);
    expect(fitted.alignment, Alignment.topCenter);
    expect(
      tester.getRect(find.byKey(mediaAspectViewportKey)).size,
      const Size(200, 200),
    );
    // The fitted source box remains 1:4 even though the parent is temporarily
    // square. FittedBox may paint it wider/taller, but it never rewrites the
    // source box to the parent's 1:1 aspect.
    final sourceBox = fitted.child! as SizedBox;
    expect(sourceBox.width, 100);
    expect(sourceBox.height, 400);
  });

  testWidgets(
      'continuous fitWidth closes only nearest-physical-pixel rounding residual',
      (tester) async {
    const childKey = ValueKey<String>('rounded-media-child');
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2.5),
          child: Center(
            child: SizedBox(
              width: 200,
              height: 406.4,
              child: MediaAspectViewport(
                dimensions: const Size(960, 1950),
                fit: BoxFit.fitWidth,
                builder: (_) => const SizedBox.expand(key: childKey),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(mediaAspectViewportKey),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    expect(
      tester.getRect(find.byKey(mediaAspectViewportKey)).size,
      const Size(200, 406.4),
    );
    expect(tester.getRect(find.byKey(childKey)).size, const Size(200, 406.4));
  });

  test('physical pixel snap correction rounds paint offset only', () {
    expect(
      physicalPixelSnapCorrection(
        globalLogicalOffset: 10.1,
        devicePixelRatio: 2.5,
      ),
      closeTo(-0.1, 1e-9),
    );
    expect(
      physicalPixelSnapCorrection(
        globalLogicalOffset: 10.3,
        devicePixelRatio: 2.5,
      ),
      closeTo(0.1, 1e-9),
    );
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
