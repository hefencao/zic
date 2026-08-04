import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media/media.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:telemetry/telemetry.dart';

void main() {
  test('factory clones retain the composition-owned artifact cache manager', () {
    final manager = ArtifactCacheManager(backend: _Backend());
    final factory = PipelineReaderSessionFactory(
      mediaRuntimeFactory: _Factory(_Runtime()),
      artifactCacheManager: manager,
    );

    expect(
      identical(
        factory.artifactCacheManager,
        factory.withLoaderSources(factory.loaderSources).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.artifactCacheManager,
        factory.withArtifactCacheManager(manager).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.artifactCacheManager,
        factory.withBytesLoader(null).artifactCacheManager,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.pageDownloadLane,
        factory.withLoaderSources(factory.loaderSources).pageDownloadLane,
      ),
      isTrue,
    );
    expect(
      identical(
        factory.decodePrefixHints,
        factory.withBytesLoader(null).decodePrefixHints,
      ),
      isTrue,
    );
  });

  test('Reader session owns and closes one atomic media runtime', () async {
    final runtime = _Runtime();
    final factory = _Factory(runtime);
    final session = PipelineReaderSessionFactory(
      mediaRuntimeFactory: factory,
    ).create(
      chapter: _chapter(),
      sessionId: 'atomic-media-test',
    );

    expect(factory.created, 1);
    expect(session.renderer, RendererKind.flutterImage);

    await session.dispose();

    expect(runtime.closed, isTrue);
  });
}

ChapterManifest _chapter() => ChapterManifest(
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
          uri: Uri.parse('asset:///page-0.webp'),
          contentKindHint: ContentKindHint.webp,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _Factory implements PipelineMediaRuntimeFactory {
  _Factory(this.runtime);

  final _Runtime runtime;
  int created = 0;

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) {
    created++;
    return runtime;
  }
}

final class _Runtime implements PipelineMediaRuntime {
  bool closed = false;

  @override
  SourceFactory get sources => _SourceFactory();

  @override
  CursorFactory get cursors => const _CursorFactory();

  @override
  FrameUploader get uploader => const _Uploader();

  @override
  PipelineOutputProjector get outputs => const _Projector();

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  Future<void> close() async {
    closed = true;
  }
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
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      SizedBox(key: key, width: 1, height: 1);
}

final class _Backend implements ArtifactCacheBackend {
  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async =>
      null;


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}
