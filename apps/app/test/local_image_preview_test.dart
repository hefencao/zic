import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/webp_demo.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

Future<ImagePreviewState> _pumpUntilPhase(
  WidgetTester tester,
  ImagePreviewPhase phase,
) async {
  ImagePreviewState? last;
  for (var frame = 0; frame < 120; frame++) {
    await tester.pump();
    final regions = find.byKey(imageFolderPreviewStateKey).evaluate();
    if (regions.length == 1) {
      final region = tester.widget<ImagePreviewStateRegion>(
        find.byKey(imageFolderPreviewStateKey),
      );
      last = region.state;
      if (last.phase == phase) {
        return last;
      }
    }
  }
  throw TestFailure(
    'Timed out waiting for image phase $phase; last=${last?.phase}',
  );
}

void main() {
  testWidgets('image observer receives the current loading snapshot', (
    tester,
  ) async {
    final bytes = Completer<Uint8List>();
    final states = <ImagePreviewState>[];
    final image = PickedImage(
      file: XFile('/virtual/chapter/pending'),
      format: LocalImageFormat.png,
      displayName: 'pending',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          bytesLoader: (_) => bytes.future,
          onPreviewStateChanged: states.add,
        ),
      ),
    );
    await tester.pump();

    expect(states, isNotEmpty);
    expect(states.last.phase, ImagePreviewPhase.loading);

    await tester.pumpWidget(const SizedBox.shrink());
    bytes.complete(_tinyPng());
    await tester.pump();
  });

  testWidgets('extensionless PNG reaches the generic ready state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-001'),
      format: LocalImageFormat.png,
      displayName: 'page-001',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          bytesLoader: (_) async => _tinyPng(),
          decodeProbe: (_) async {},
        ),
      ),
    );

    final state = await _pumpUntilPhase(tester, ImagePreviewPhase.ready);

    expect(state.format, LocalImageFormat.png);
    expect(find.byKey(imageFolderFlutterPreviewKey), findsOneWidget);
    expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
  });

  testWidgets('codec probe failure reaches a controlled invalid state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-001.png'),
      format: LocalImageFormat.png,
      displayName: 'page-001.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          bytesLoader: (_) async => _tinyPng(),
          decodeProbe: (_) async => throw const FormatException('decode failed'),
        ),
      ),
    );

    final state = await _pumpUntilPhase(tester, ImagePreviewPhase.invalid);

    expect(state.format, LocalImageFormat.png);
    expect(state.error, isA<FormatException>());
    expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
  });

  testWidgets('changed file header reaches a controlled invalid state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-002.png'),
      format: LocalImageFormat.png,
      displayName: 'page-002.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          bytesLoader: (_) async => Uint8List.fromList('not an image'.codeUnits),
        ),
      ),
    );

    final state = await _pumpUntilPhase(tester, ImagePreviewPhase.invalid);

    expect(state.format, LocalImageFormat.png);
    expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
  });
}
