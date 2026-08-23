import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

void main() {
  test(
    'presentation loadBytes reads immutable local sources before promotion',
    () async {
      const payload = <int>[7, 8, 9];
      var directOpens = 0;

      final uri = Uri.parse('file:///zic-presentation-direct/page-0.jpg');
      final chapter = _chapter(uri: uri);
      final id = readerPageDownloadId(chapter, chapter.pages.single);
      final factory = PipelineReaderSessionFactory(
        mediaRuntimeFactory: const _FreshFactory(),
        artifactCacheManager: ArtifactCacheManager(backend: const _Backend()),
      ).withLoaderSources(<Uri, LoaderTransportSource>{
        id.canonicalUri: LoaderTransportSource(
          revision: 'local-r1',
          openControlledResponse: ({range, validators, control}) async {
            // Only the physical transfer owns a TaskControl. The presentation
            // direct read opens without one.
            if (control != null) {
              return ByteResponse(
                bytes: _neverEndingBody(),
                statusCode: 200,
                rangeStart: 0,
                totalLength: payload.length,
                validators: const Validators(etag: '"local-r1-3"'),
              );
            }
            directOpens++;
            return ByteResponse(
              bytes: Stream<List<int>>.value(Uint8List.fromList(payload)),
              statusCode: 200,
              rangeStart: 0,
              totalLength: payload.length,
              validators: const Validators(etag: '"local-r1-3"'),
            );
          },
        ),
      });
      final reader = factory.create(
        chapter: chapter,
        sessionId: 'presentation-direct-reader',
      );

      try {
        reader.attach(DecodeTarget(physicalWidth: 320, physicalHeight: 480));
        reader.accept(_observation(reader.sessionId, chapter));

        final token = MediaLoadToken();
        final bytes = await reader
            .loadBytes(chapter.pages.single, token)
            .timeout(const Duration(seconds: 5));

        expect(bytes, Uint8List.fromList(payload));
        expect(directOpens, 1, reason: 'presentation must open its own '
            'immutable source read instead of waiting for the gated transfer');

        final warmBytes = await reader
            .loadBytes(chapter.pages.single, MediaLoadToken())
            .timeout(const Duration(seconds: 5));
        expect(warmBytes, Uint8List.fromList(payload));
        expect(directOpens, 1, reason: 'the validated direct read must feed '
            'the presentation memory tier for immediate remounts');
      } finally {
        // Detaching Reader demand cancels the gated physical attempt; the
        // never-ending body only ends through that cancellation.
        await reader.dispose().timeout(const Duration(seconds: 10));
        await factory
            .disposeRetainedSessions()
            .timeout(const Duration(seconds: 10));
        await factory
            .disposeTransferRuntimes()
            .timeout(const Duration(seconds: 10));
      }
    });
}

Stream<List<int>> _neverEndingBody() async* {
  // The gated transfer attempt never receives a byte; it exits only when its
  // consumer cancels the response subscription.
  await Completer<void>().future;
}

ReaderObs _observation(String sessionId, ChapterManifest chapter) => ReaderObs(
      sessionId: sessionId,
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
      direction: ReadingDirection.ltr,
      timestamp: DateTime.utc(2026),
      monotonicMicros: 1,
    );

ChapterManifest _chapter({required Uri uri}) => ChapterManifest(
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
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _Backend implements ArtifactCacheBackend {
  const _Backend();

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      null;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _FreshFactory implements PipelineMediaRuntimeFactory {
  const _FreshFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) =>
      _Runtime();
}

final class _Runtime implements PipelineMediaRuntime {
  @override
  SourceFactory get sources => _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  PipelineFrameScheduler get frameScheduler => const _TestFrameScheduler();

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  Future<void> close() async {}
}

final class _SourceFactory implements SourceFactory {
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
      throw UnsupportedError('not used');
}

final class _Uploader implements FrameUploader {
  const _Uploader();

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) =>
      throw UnsupportedError('not used');

  @override
  void release(DecodeId id) {}
}

final class _Projector implements PipelineOutputProjector {
  const _Projector();

  @override
  PipelinePageSurface project(OutputFrame frame) => const _Surface();
}

final class _Surface implements PipelinePageSurface {
  const _Surface();

  @override
  int get width => 1;

  @override
  int get height => 1;

  @override
  Object get presentationIdentity => this;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      SizedBox(key: key, width: 1, height: 1);
}

final class _TestFrameScheduler implements PipelineFrameScheduler {
  const _TestFrameScheduler();

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
