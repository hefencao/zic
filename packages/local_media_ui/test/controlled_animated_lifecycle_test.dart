import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:reader_runtime/reader_runtime.dart';

void main() {
  testWidgets(
    'GIF ready transition keeps one codec and pause resume cannot reenter frame fetch',
    (tester) async {
      final playback = ReaderPlaybackController();
      addTearDown(playback.dispose);
      final codec = _BlockingCodec();
      var codecCreates = 0;
      final bytes = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
      );
      final image = PickedImage(
        file: XFile('controlled.gif'),
        format: LocalImageFormat.gif,
        displayName: 'controlled.gif',
        sourceId: 'memory:controlled.gif',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 120,
            height: 120,
            child: LocalImagePlayer(
              image: image,
              playback: playback,
              bytesLoader: (_) async => bytes,
              flutterAnimatedCodecFactory: (
                _,
                {int? targetWidth, int? targetHeight}
              ) async {
                codecCreates++;
                return codec;
              },
            ),
          ),
        ),
      );

      for (var turn = 0; turn < 20 && codec.calls == 0; turn++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(codec.calls, 1);

      playback.togglePaused();
      playback.togglePaused();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        codec.calls,
        1,
        reason:
            'resume while getNextFrame is pending must not start a second '
            'request on the same codec',
      );
      expect(codec.maxConcurrent, 1);

      codec.completeNext(await _image());
      await tester.pump();
      await tester.pump();

      expect(
        codecCreates,
        1,
        reason:
            'loading -> ready changes presentation state, not media subtree '
            'identity; the codec must not be recreated for the first frame',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      codec.dispose();
    },
  );
}

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 1, 1),
    ui.Paint()..color = const ui.Color(0xffffffff),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  picture.dispose();
  return image;
}

final class _BlockingCodec implements FlutterAnimatedCodec {
  final List<Completer<FlutterAnimatedFrame>> _pending =
      <Completer<FlutterAnimatedFrame>>[];
  int calls = 0;
  int concurrent = 0;
  int maxConcurrent = 0;
  bool disposed = false;

  @override
  int get frameCount => 2;

  @override
  int get repetitionCount => -1;

  @override
  Future<FlutterAnimatedFrame> getNextFrame() {
    calls++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    final completer = Completer<FlutterAnimatedFrame>();
    _pending.add(completer);
    return completer.future.whenComplete(() {
      concurrent--;
    });
  }

  void completeNext(ui.Image image) {
    final completer = _pending.removeAt(0);
    completer.complete(
      FlutterAnimatedFrame(
        image: image,
        duration: const Duration(milliseconds: 100),
      ),
    );
  }

  @override
  void dispose() {
    disposed = true;
  }
}
