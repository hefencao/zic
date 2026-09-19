import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  testWidgets(
    'mounted external static reloads when Pipeline presentation generation changes',
    (tester) async {
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final uri = Uri.parse('asset:///generation-static.png');
      final chapter = _chapter(uri);
      final session = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _RuntimeFactory(),
        pageDownloadLane: NetLane(maxActive: 2),
        loaderSources: <Uri, LoaderTransportSource>{
          uri: LoaderTransportSource(
            revision: 'generation-static-r1',
            loadBytes: () async => bytes,
          ),
        },
      ).create(
        chapter: chapter,
        sessionId: 'external-generation-widget-test',
      );
      addTearDown(session.dispose);
      session.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));

      final asset = chapter.pages.single;
      final output = session.pageOutput(asset);
      final stream = session.pageStream(asset);
      var loads = 0;
      final image = PickedImage(
        file: XFile('generation-static.png'),
        format: LocalImageFormat.png,
        displayName: 'generation-static.png',
        sourceId: uri.toString(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 240,
            height: 360,
            child: LocalImagePlayer(
              image: image,
              tokenBytesLoader: (_, token) async {
                token.throwIfCancelled();
                loads++;
                return Uint8List.fromList(bytes);
              },
              onFirstFrame: () =>
                  session.reportPresentationFrameReady(asset),
              pageStream: stream,
              pageOutput: output,
            ),
          ),
        ),
      );
      session.accept(_observation(chapter));

      await _pumpUntil(tester, () => loads >= 1);
      final firstIdentity = output.externalPresentationCacheIdentity;
      expect(firstIdentity, isNotNull);

      session.updateDecodeTarget(
        DecodeTarget(physicalWidth: 640, physicalHeight: 960),
      );
      session.accept(_observation(chapter));

      await _pumpUntil(tester, () => loads >= 2);
      expect(
        identical(firstIdentity, output.externalPresentationCacheIdentity),
        isFalse,
        reason:
            'the same mounted page output must expose a new exact presentation generation after DecodeId rebind',
      );
      expect(
        loads,
        2,
        reason:
            'widget lifetime must not suppress the new Pipeline presentation grant',
      );
    },
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate,
) async {
  for (var attempt = 0; attempt < 200 && !predicate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(predicate(), isTrue);
}

ChapterManifest _chapter(Uri uri) => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: uri,
          width: 1,
          height: 1,
          contentKindHint: ContentKindHint.unknown,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

ReaderObs _observation(ChapterManifest chapter) => ReaderObs(
      sessionId: 'external-generation-widget-test',
      currentIndex: 0,
      stableIndex: 0,
      interaction: Interaction.idle,
      logicalPosition: 0,
      velocity: 0,
      currentCoverage: Coverage(
        pageIndex: 0,
        assetKey: chapter.pages.single.assetKey,
        fraction: 1,
      ),
      direction: chapter.readingDirection,
      timestamp: DateTime.utc(2026),
      monotonicMicros: 1,
    );

final class _RuntimeFactory implements PipelineMediaRuntimeFactory {
  const _RuntimeFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      const _Runtime();
}

final class _Runtime implements PipelineMediaRuntime {
  const _Runtime();

  @override
  SourceFactory get sources => const _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  PipelineFrameScheduler get frameScheduler => const _FrameScheduler();

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  Future<void> close() async {}
}

final class _SourceFactory implements SourceFactory {
  const _SourceFactory();

  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _Source(epoch);
}

final class _Source implements EncodedSource {
  _Source(this.epoch);

  @override
  int epoch;
  @override
  int length = 0;
  @override
  bool sealed = false;
  @override
  SourceKind kind = SourceKind.unknown;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    length += bytes.length;
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    length = 0;
    sealed = false;
    kind = SourceKind.unknown;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _CursorFactory implements CursorFactory {
  const _CursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      throw UnsupportedError('fallback static does not use a native cursor');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) =>
      throw UnsupportedError('fallback static does not use native upload');

  @override
  void release(DecodeId id) {}
}

final class _Projector implements PipelineOutputProjector {
  const _Projector();

  @override
  PipelinePageSurface project(OutputFrame frame) =>
      throw UnsupportedError('fallback static does not use native output');
}

final class _FrameScheduler implements PipelineFrameScheduler {
  const _FrameScheduler();

  @override
  bool get inPersistentCallbacks => false;

  @override
  bool get isIdle => true;

  @override
  bool get hasScheduledFrame => false;

  @override
  void afterFrame(void Function() callback) => scheduleMicrotask(callback);

  @override
  void scheduleIdle(void Function() callback) => scheduleMicrotask(callback);

  @override
  void requestFrame() {}
}
