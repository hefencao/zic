import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';

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
            onRecoverPresentationFailure: (_, __) async {
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
            onRecoverPresentationFailure: (_, __) async => false,
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

  testWidgets('manual retry receives the original presentation error',
      (tester) async {
    var fresh = false;
    Object? retryError;
    final image = PickedImage(
      file: XFile('manual-retry-error.png'),
      format: LocalImageFormat.png,
      displayName: 'manual-retry-error.png',
      sourceId: 'memory:manual-retry-error.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 240,
          height: 360,
          child: LocalImagePlayer(
            image: image,
            bytesLoader: (_) async => fresh
                ? base64Decode(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                  )
                : Uint8List.fromList('<html>bad media</html>'.codeUnits),
            onRecoverPresentationFailure: (_, __) async => false,
            onRetryWithError: (error) async {
              retryError = error;
              fresh = true;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
    await tester.tap(find.byKey(imageFolderPreviewRetryKey));
    await tester.pumpAndSettle();

    expect(retryError, isNotNull);
    expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
  });

  testWidgets('cancelled presentation file load releases late lease',
      (tester) async {
    final leaseResult = Completer<PipelineEncodedPresentationFileLease?>();
    var releases = 0;
    final image = PickedImage(
      file: XFile('late-lease.png'),
      format: LocalImageFormat.png,
      displayName: 'late-lease.png',
      sourceId: 'memory:late-lease.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          presentationFileLoader: (_) => leaseResult.future,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.runAsync(() async {
      leaseResult.complete(
        PipelineEncodedPresentationFileLease(
          path: '/unused/late-lease.png',
          length: 1,
          cacheIdentity: const ('late-lease', 1),
          width: 1,
          height: 1,
          release: () async {
            releases++;
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(releases, 1);
  });

  testWidgets('presentation recovery receives the exact read authority',
      (tester) async {
    final authority = PipelinePresentationArtifactAuthority(
      storageId: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.invalid/page.png'),
      ),
      generation: 7,
    );
    PipelinePresentationArtifactAuthority? rejected;
    final image = PickedImage(
      file: XFile('authority.png'),
      format: LocalImageFormat.png,
      displayName: 'authority.png',
      sourceId: 'memory:authority.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          presentationBytesLoader: (_, __) async => PipelinePresentationBytes(
            bytes: Uint8List.fromList('<html>bad authority</html>'.codeUnits),
            authority: authority,
          ),
          onRecoverPresentationFailure: (_, readAuthority) async {
            rejected = readAuthority;
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(identical(rejected, authority), isTrue);
    expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
  });

  testWidgets('stale automatic recovery cannot restart replacement image',
      (tester) async {
    final recovery = Completer<bool>();
    var recoveryCalls = 0;
    var bLoads = 0;
    final imageA = PickedImage(
      file: XFile('generation-a.png'),
      format: LocalImageFormat.png,
      displayName: 'generation-a.png',
      sourceId: 'memory:generation-a.png',
    );
    final imageB = PickedImage(
      file: XFile('generation-b.png'),
      format: LocalImageFormat.png,
      displayName: 'generation-b.png',
      sourceId: 'memory:generation-b.png',
    );
    final valid = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    Widget player(PickedImage image, Future<Uint8List> Function(PickedImage) load) {
      return MaterialApp(
        home: LocalImagePlayer(
          image: image,
          bytesLoader: load,
          onRecoverPresentationFailure: (_, __) async {
            recoveryCalls++;
            return recovery.future;
          },
        ),
      );
    }

    await tester.pumpWidget(
      player(
        imageA,
        (_) async => Uint8List.fromList('<html>bad A</html>'.codeUnits),
      ),
    );
    for (var turn = 0; turn < 20 && recoveryCalls == 0; turn++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(recoveryCalls, 1);

    await tester.pumpWidget(
      player(
        imageB,
        (_) async {
          bLoads++;
          return valid;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(bLoads, 1);

    recovery.complete(true);
    await tester.pumpAndSettle();

    expect(
      bLoads,
      1,
      reason:
          'recovery from the replaced A generation must not restart current B',
    );
  });

  testWidgets(
      'stale presented decode failure cannot invalidate replacement image',
      (tester) async {
    final valid = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final corrupt = Uint8List.fromList(valid.sublist(0, 33));
    final recovery = Completer<bool>();
    var recoveryCalls = 0;
    final imageA = PickedImage(
      file: XFile('presented-a.png'),
      format: LocalImageFormat.png,
      displayName: 'presented-a.png',
      sourceId: 'memory:presented-a.png',
    );
    final imageB = PickedImage(
      file: XFile('presented-b.png'),
      format: LocalImageFormat.png,
      displayName: 'presented-b.png',
      sourceId: 'memory:presented-b.png',
    );

    Widget player(PickedImage image, Uint8List bytes) => MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: image,
              bytesLoader: (_) async => bytes,
              onRecoverPresentationFailure: (_, __) {
                recoveryCalls++;
                return recovery.future;
              },
            ),
          ),
        );

    await tester.pumpWidget(player(imageA, corrupt));
    for (var turn = 0; turn < 40 && recoveryCalls == 0; turn++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(recoveryCalls, 1);

    await tester.pumpWidget(player(imageB, valid));
    await tester.pumpAndSettle();
    expect(find.byKey(imageFolderPreviewErrorKey), findsNothing);
    expect(find.byKey(imageFolderFlutterPreviewKey), findsOneWidget);

    recovery.complete(false);
    await tester.pumpAndSettle();
    expect(
      find.byKey(imageFolderPreviewErrorKey),
      findsNothing,
      reason:
          'A decode/recovery completion is scoped to A presentation attempt '
          'and cannot publish failure into the already-ready B attempt',
    );
    expect(find.byKey(imageFolderFlutterPreviewKey), findsOneWidget);
  });

}
