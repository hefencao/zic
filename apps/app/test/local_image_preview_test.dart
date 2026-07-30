import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
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

Uint8List _largeCanvasWebp() {
  final bytes = Uint8List.fromList(_tinyWebp());
  // VP8X stores canvas dimensions minus one as 24-bit little-endian values.
  // Keep the tiny encoded frames but advertise a 2048×2048 canvas so viewport
  // changes produce distinct downsample targets without invoking a real codec.
  const encodedExtent = 2048 - 1;
  bytes[24] = encodedExtent & 0xff;
  bytes[25] = (encodedExtent >> 8) & 0xff;
  bytes[26] = (encodedExtent >> 16) & 0xff;
  bytes[27] = encodedExtent & 0xff;
  bytes[28] = (encodedExtent >> 8) & 0xff;
  bytes[29] = (encodedExtent >> 16) & 0xff;
  return bytes;
}

Future<ui.Image> _testFrameImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(2, 2);
  } finally {
    picture.dispose();
  }
}

final class _TestFlutterAnimatedCodec implements FlutterAnimatedCodec {
  _TestFlutterAnimatedCodec({this.beforeFrame});

  final Future<void>? beforeFrame;
  bool _disposed = false;
  bool _delayed = false;

  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<FlutterAnimatedFrame> getNextFrame() async {
    if (!_delayed) {
      _delayed = true;
      final gate = beforeFrame;
      if (gate != null) {
        await gate;
      }
    }
    if (_disposed) {
      throw StateError('test codec is disposed');
    }
    return FlutterAnimatedFrame(
      image: await _testFrameImage(),
      duration: const Duration(milliseconds: 100),
    );
  }

  @override
  void dispose() => _disposed = true;
}

Future<void> _yieldCodecWork() async {
  // Image codecs complete on engine/IO threads rather than the fake timer
  // queue. A short real-event-loop yield is bounded by the caller deadline;
  // it is not used as an assertion about decode duration.
  await Future<void>.delayed(const Duration(milliseconds: 2));
}

Future<ImagePreviewState> _pumpUntilPhase(
  WidgetTester tester,
  ImagePreviewPhase phase, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final elapsed = Stopwatch()..start();
  ImagePreviewState? last;
  while (elapsed.elapsed < timeout) {
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
    await tester.runAsync(_yieldCodecWork);
  }
  throw TestFailure(
    'Timed out waiting for image phase $phase; last=${last?.phase}',
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(_yieldCodecWork);
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    await tester.pump();
    if (condition()) {
      return;
    }
    await tester.runAsync(_yieldCodecWork);
  }
  throw TestFailure('Timed out waiting for asynchronous image condition');
}

Future<void> _unmountAsyncImage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(_yieldCodecWork);
  await tester.pump();
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

    final playback = ReaderPlaybackController();
    addTearDown(playback.dispose);
    try {
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
            playback: playback,
            flutterAnimatedCodecFactory: (
              bytes, {
              targetWidth,
              targetHeight,
            }) async =>
                _TestFlutterAnimatedCodec(),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.byType(NativeWebpPlayer));

      final player = tester.widget<NativeWebpPlayer>(
        find.byType(NativeWebpPlayer),
      );
      expect(player.downloadIdentity, same(identity));
      expect(player.traceClock, same(clock));
      expect(player.traceSink, same(trace));
      expect(player.traceSessionId, 'reader-folder-test');
      expect(player.demandRevision!(), 7);
    } finally {
      await _unmountAsyncImage(tester);
    }
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
    final fixtureBytes = _tinyWebp();
    final image = PickedImage(
      file: XFile(identity.canonicalUri.toString()),
      sourceId: identity.canonicalUri.toString(),
      format: LocalImageFormat.webp,
      displayName: 'page-0.webp',
    );

    try {
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
            flutterAnimatedCodecFactory: (
              bytes, {
              targetWidth,
              targetHeight,
            }) async =>
                _TestFlutterAnimatedCodec(),
          ),
        ),
      );

      await _pumpUntilPhase(tester, ImagePreviewPhase.ready);
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
    } finally {
      await _unmountAsyncImage(tester);
    }
  });

  testWidgets('Flutter target rebuild keeps the presented frame visible', (
    tester,
  ) async {
    final playback = ReaderPlaybackController();
    addTearDown(playback.dispose);
    final fixtureBytes = _largeCanvasWebp();
    var width = 320.0;
    late StateSetter updateHost;
    var codecActivations = 0;
    final decodeTargets = <(int?, int?)>[];
    final replacementGate = Completer<void>();
    final FlutterAnimatedCodecFactory codecFactory = (
      bytes, {
      targetWidth,
      targetHeight,
    }) async {
      codecActivations++;
      decodeTargets.add((targetWidth, targetHeight));
      return _TestFlutterAnimatedCodec(
        beforeFrame: codecActivations >= 2 ? replacementGate.future : null,
      );
    };

    try {
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
                    flutterAnimatedCodecFactory: codecFactory,
                  ),
                ),
              );
            },
          ),
        ),
      );

      await _pumpUntilFound(tester, find.byType(RawImage));
      expect(find.byType(RawImage), findsOneWidget);

      updateHost(() => width = 180);
      await _pumpUntilCondition(tester, () => codecActivations >= 2);
      expect(decodeTargets.length, greaterThanOrEqualTo(2));
      expect(
        decodeTargets.any((target) => target != decodeTargets.first),
        isTrue,
      );

      // The old frame remains visible while the replacement codec is working.
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      replacementGate.complete();
      await tester.pump();
    } finally {
      if (!replacementGate.isCompleted) {
        replacementGate.complete();
      }
      await _unmountAsyncImage(tester);
    }
  });

  test('plain local image uses a file provider without byte loading', () {
    var byteLoads = 0;
    final image = PickedImage(
      file: XFile('/virtual/library/cover.png'),
      format: LocalImageFormat.png,
      displayName: 'cover.png',
      byteLength: _tinyPng().lengthInBytes,
      readBytes: () async {
        byteLoads++;
        throw StateError('direct file image must not materialize bytes');
      },
    );

    final provider = localImageDirectFileProvider(image);

    expect(provider, isA<FileImage>());
    expect((provider! as FileImage).file.path, '/virtual/library/cover.png');
    expect(byteLoads, 0);
  });

  testWidgets('extensionless PNG reaches the generic ready state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-001'),
      format: LocalImageFormat.png,
      displayName: 'page-001',
    );

    try {
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
    } finally {
      await _unmountAsyncImage(tester);
    }
  });

  testWidgets('codec probe failure reaches a controlled invalid state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-001.png'),
      format: LocalImageFormat.png,
      displayName: 'page-001.png',
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: LocalImagePlayer(
            image: image,
            bytesLoader: (_) async => _tinyPng(),
            decodeProbe: (_) async =>
                throw const FormatException('decode failed'),
          ),
        ),
      );

      final state = await _pumpUntilPhase(tester, ImagePreviewPhase.invalid);

      expect(state.format, LocalImageFormat.png);
      expect(state.error, isA<FormatException>());
      expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
    } finally {
      await _unmountAsyncImage(tester);
    }
  });

  testWidgets('changed file header reaches a controlled invalid state', (
    tester,
  ) async {
    final image = PickedImage(
      file: XFile('/virtual/chapter/page-002.png'),
      format: LocalImageFormat.png,
      displayName: 'page-002.png',
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: LocalImagePlayer(
            image: image,
            bytesLoader: (_) async =>
                Uint8List.fromList('not an image'.codeUnits),
          ),
        ),
      );

      final state = await _pumpUntilPhase(tester, ImagePreviewPhase.invalid);

      expect(state.format, LocalImageFormat.png);
      expect(find.byKey(imageFolderPreviewErrorKey), findsOneWidget);
    } finally {
      await _unmountAsyncImage(tester);
    }
  });
}


final class _FakeClock implements MonoClock {
  int _micros = 0;

  @override
  int nowMicros() => _micros++;
}
