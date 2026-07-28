import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

File _nativeFixture(String name) {
  final candidates = <File>[
    File('native/media_core/testdata/$name'),
    File('../../native/media_core/testdata/$name'),
  ];
  return candidates.firstWhere(
    (file) => file.existsSync(),
    orElse: () => throw StateError('Missing native fixture: $name'),
  );
}

Future<WebpPreviewState> _pumpUntilPhase(
  WidgetTester tester,
  WebpPreviewPhase phase, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    final markers = find.byKey(webpPreviewStateKey).evaluate();
    if (markers.isEmpty) {
      continue;
    }
    final marker = tester.widget<WebpPreviewStateRegion>(
      find.byKey(webpPreviewStateKey),
    );
    if (marker.state.phase == phase) {
      return marker.state;
    }
  }
  throw TestFailure('Preview never reached ${phase.name}');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  testWidgets('valid local WebP reaches an explicit ready state', (
    tester,
  ) async {
    final bytes = _nativeFixture('finite_loop.webp').readAsBytesSync();
    await tester.pumpWidget(
      MaterialApp(
        home: WebpPlayerScreen.bytes(
          displayName: 'valid-local.webp',
          bytes: bytes,
        ),
      ),
    );

    final state = await _pumpUntilPhase(tester, WebpPreviewPhase.ready);

    expect(state.info, isNotNull);
    expect(find.byKey(webpPreviewReadyKey), findsOneWidget);
    expect(find.byKey(webpPreviewErrorKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('malformed local WebP reaches a controlled invalid state', (
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
      MaterialApp(
        home: WebpPlayerScreen.bytes(
          displayName: 'broken.webp',
          bytes: bytes,
        ),
      ),
    );

    final state = await _pumpUntilPhase(tester, WebpPreviewPhase.invalid);

    expect(state.error, isA<FormatException>());
    expect(find.byKey(webpPreviewErrorKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('WebP opens on the deterministic Flutter codec by default', (
    tester,
  ) async {
    final bytes = _nativeFixture('finite_loop.webp').readAsBytesSync();
    await tester.pumpWidget(
      MaterialApp(
        home: WebpPlayerScreen.bytes(
          displayName: 'safe-default.webp',
          bytes: bytes,
        ),
      ),
    );
    await _pumpUntilPhase(tester, WebpPreviewPhase.ready);
    await _pumpUntilFound(tester, find.byKey(webpFlutterPreviewKey));

    final control = tester.widget<SegmentedButton<WebpPlayerEngine>>(
      find.byKey(webpEngineControlKey),
    );
    expect(control.selected, <WebpPlayerEngine>{WebpPlayerEngine.flutter});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('native pipeline requires explicit confirmation', (
    tester,
  ) async {
    final bytes = _nativeFixture('finite_loop.webp').readAsBytesSync();
    await tester.pumpWidget(
      MaterialApp(
        home: WebpPlayerScreen.bytes(
          displayName: 'native-confirmation.webp',
          bytes: bytes,
        ),
      ),
    );
    await _pumpUntilPhase(tester, WebpPreviewPhase.ready);

    await tester.tap(find.byKey(webpNativeEngineOptionKey));
    await tester.pump();

    expect(find.byKey(webpNativeConfirmDialogKey), findsOneWidget);
    await tester.tap(find.byKey(webpNativeCancelKey));
    await tester.pump();

    final control = tester.widget<SegmentedButton<WebpPlayerEngine>>(
      find.byKey(webpEngineControlKey),
    );
    expect(control.selected, <WebpPlayerEngine>{WebpPlayerEngine.flutter});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

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
    await _pumpUntilPhase(tester, WebpPreviewPhase.ready);
    await _pumpUntilFound(tester, find.byKey(webpFlutterPreviewKey));

    final image = tester.widget<Image>(find.byKey(webpFlutterPreviewKey));
    expect(image.image, isNot(isA<ResizeImage>()));
    expect(image.filterQuality, FilterQuality.none);
    expect(image.isAntiAlias, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
