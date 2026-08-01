import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';

void main() {
  testWidgets('page media owns the only loading indicator', (tester) async {
    final bytes = Completer<Uint8List>();
    final image = PickedImage(
      file: XFile('pending.png'),
      format: LocalImageFormat.png,
      displayName: 'pending.png',
      sourceId: 'memory:pending.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 360,
          child: LocalImagePlayer(
            image: image,
            bytesLoader: (_) => bytes.future,
          ),
        ),
      ),
    );

    final indicator = find.byKey(imagePageLoadingIndicatorKey);
    expect(indicator, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.getCenter(indicator),
      tester.getCenter(find.byType(LocalImagePlayer)),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    bytes.complete(Uint8List(0));
    await tester.pump();
  });
}
