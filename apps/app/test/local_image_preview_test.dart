import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/reader_runtime.dart';
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

  testWidgets('Flutter animated codec exposes cold first-frame phases', (
    tester,
  ) async {
    final identity = DownloadId(
      content: const ContentId(
        sourceId: 'remote',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page-0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.invalid/page-0.webp'),
    );
    final trace = MemoryTraceSink();
    final playback = ReaderPlaybackController();
    addTearDown(playback.dispose);
    final fixture = await rootBundle.load(
      'assets/demo/animated/finite_loop.webp',
    );
    final fixtureBytes = fixture.buffer.asUint8List(
      fixture.offsetInBytes,
      fixture.lengthInBytes,
    );
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
          tokenBytesLoader: (_, __) async => fixtureBytes,
          downloadIdentity: identity,
          traceClock: _FakeClock(),
          traceSink: trace,
          traceSessionId: 'reader-cold-codec-test',
          demandRevision: () => 11,
          playback: playback,
        ),
      ),
    );

    await _pumpUntilPhase(tester, ImagePreviewPhase.ready);
    for (var frame = 0;
        frame < 40 &&
            !trace.events.any(
              (event) => event.kind == TraceEventKind.framePresented,
            );
        frame++) {
      await tester.pump();
    }

    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.framePresented,
      ),
      isNotEmpty,
    );
    final decodeStarted = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.decodeStarted,
    );
    final decoded = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.frameDecoded,
    );
    final presented = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.framePresented,
    );
    expect(decodeStarted.identityHash, startsWith(identity.key));
    expect(decoded.identityHash, startsWith(identity.key));
    expect(presented.identityHash, startsWith(identity.key));
    expect(decodeStarted.revision, 11);
    expect(decoded.revision, 11);
    expect(presented.revision, 11);
    expect(decodeStarted.payload['engine'], 'flutter-codec');
  });

  testWidgets('Flutter target rebuild keeps the presented frame visible', (
    tester,
  ) async {
    final playback = ReaderPlaybackController();
    addTearDown(playback.dispose);
    final fixture = await rootBundle.load(
      'assets/demo/animated/finite_loop.webp',
    );
    final fixtureBytes = fixture.buffer.asUint8List(
      fixture.offsetInBytes,
      fixture.lengthInBytes,
    );
    var width = 320.0;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return Center(
              child: SizedBox(
                width: width,
                height: 320,
                child: NativeWebpPlayer(
                  title: 'gapless.webp',
                  sourceUri: Uri.parse('memory://gapless.webp'),
                  loadBytes: (_) async => fixtureBytes,
                  showEngineControls: false,
                  showStatus: false,
                  playback: playback,
                ),
              ),
            );
          },
        ),
      ),
    );

    for (var frame = 0;
        frame < 60 && find.byType(RawImage).evaluate().isEmpty;
        frame++) {
      await tester.pump();
    }
    expect(find.byType(RawImage), findsOneWidget);

    updateHost(() => width = 180);
    await tester.pump();
    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('plain local image uses a file provider without byte loading',
      (tester) async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-local-image-file-provider-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File('${directory.path}/cover.png');
    await file.writeAsBytes(_tinyPng(), flush: true);
    var byteLoads = 0;
    final image = PickedImage(
      file: XFile(file.path),
      format: LocalImageFormat.png,
      displayName: 'cover.png',
      byteLength: await file.length(),
      readBytes: () async {
        byteLoads++;
        throw StateError('direct file image must not materialize bytes');
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: LocalImagePlayer(image: image)),
    );
    final state = await _pumpUntilPhase(tester, ImagePreviewPhase.ready);

    expect(state.format, LocalImageFormat.png);
    expect(byteLoads, 0);
    final imageWidget = tester.widget<Image>(
      find.byKey(imageFolderFlutterPreviewKey),
    );
    expect(imageWidget.image, isA<FileImage>());
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
