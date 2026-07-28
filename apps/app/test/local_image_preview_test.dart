import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/webp_demo.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );


Uint8List _tinyWebp() => base64Decode(
      'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAAAAAAAAgBB'
      'Tk1GKAAAAAAAAAAAAAEAAAEAADwAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/'
      'AQBBTk1GKAAAAAAAAAAAAAEAAAEAAFoAAABWUDhMDwAAAC8BQAAAB9D/iP4H'
      'IqL/AQA=',
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

  testWidgets('disposing a local image player cancels artifact loading', (
    tester,
  ) async {
    final started = Completer<void>();
    MediaLoadToken? token;
    final image = PickedImage(
      file: XFile('/virtual/chapter/pending.png'),
      format: LocalImageFormat.png,
      displayName: 'pending.png',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          tokenBytesLoader: (_, value) async {
            token = value;
            started.complete();
            await value.whenCancelled;
            value.throwIfCancelled();
            return Uint8List(0);
          },
        ),
      ),
    );
    await started.future;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(token, isNotNull);
    expect(token!.isCancelled, isTrue);
  });

  testWidgets('folder WebP forwards Reader identity and trace context', (
    tester,
  ) async {
    final identity = DownloadId(
      content: const ContentId(
        sourceId: 'local-folder',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page-0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('content://provider/document/page-0'),
    );
    final clock = _FakeClock();
    final trace = MemoryTraceSink();
    final image = PickedImage(
      file: XFile(identity.canonicalUri.toString()),
      sourceId: identity.canonicalUri.toString(),
      format: LocalImageFormat.webp,
      displayName: 'page-0.webp',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LocalImagePlayer(
          image: image,
          tokenBytesLoader: (_, __) async => _tinyWebp(),
          downloadIdentity: identity,
          traceClock: clock,
          traceSink: trace,
          traceSessionId: 'reader-folder-test',
          demandRevision: () => 7,
        ),
      ),
    );
    for (var frame = 0;
        frame < 30 && find.byType(NativeWebpPlayer).evaluate().isEmpty;
        frame++) {
      await tester.pump();
    }

    final player = tester.widget<NativeWebpPlayer>(
      find.byType(NativeWebpPlayer),
    );
    expect(player.downloadIdentity, same(identity));
    expect(player.traceClock, same(clock));
    expect(player.traceSink, same(trace));
    expect(player.traceSessionId, 'reader-folder-test');
    expect(player.demandRevision!(), 7);
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


final class _FakeClock implements MonoClock {
  int _micros = 0;

  @override
  int nowMicros() => _micros++;
}
