import 'dart:async';
import 'dart:convert';
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

  testWidgets('presentation failure self-heals once before showing an error',
      (tester) async {
    var loads = 0;
    var recoveries = 0;
    final image = PickedImage(
      file: XFile('recover.png'),
      format: LocalImageFormat.png,
      displayName: 'recover.png',
      sourceId: 'memory:recover.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 360,
          child: LocalImagePlayer(
            image: image,
            bytesLoader: (_) async {
              loads++;
              if (loads == 1) {
                return Uint8List.fromList('<html>old cache</html>'.codeUnits);
              }
              return base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              );
            },
            onRecoverPresentationFailure: (_) async {
              recoveries++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(recoveries, 1);
    expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
  });

  testWidgets('failed automatic recovery exposes a manual retry action',
      (tester) async {
    var loads = 0;
    var retries = 0;
    var fresh = false;
    final image = PickedImage(
      file: XFile('manual-retry.png'),
      format: LocalImageFormat.png,
      displayName: 'manual-retry.png',
      sourceId: 'memory:manual-retry.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 360,
          child: LocalImagePlayer(
            image: image,
            bytesLoader: (_) async {
              loads++;
              if (!fresh) {
                return Uint8List.fromList('<html>old cache</html>'.codeUnits);
              }
              return base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              );
            },
            onRecoverPresentationFailure: (_) async => false,
            onRetry: () async {
              retries++;
              fresh = true;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
    expect(find.byKey(imageFolderPreviewCopyErrorKey), findsOneWidget);
    expect(find.byKey(imageFolderPreviewRetryKey), findsOneWidget);

    await tester.tap(find.byKey(imageFolderPreviewRetryKey));
    await tester.pumpAndSettle();

    expect(retries, 1);
    expect(loads, 2);
    expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
  });

}
