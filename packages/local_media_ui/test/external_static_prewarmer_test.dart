import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

void main() {
  testWidgets(
    'static raster that already fits physical bounds keeps the prewarmed provider key',
    (tester) async {
      final provider = MemoryImage(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2.53125),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 426.6666666666667,
              height: 414.81481481481484,
              child: MediaRasterImage(
                image: provider,
                dimensions: const Size(720, 700),
                fit: BoxFit.fitWidth,
              ),
            ),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect(
        identical(image.image, provider),
        isTrue,
        reason:
            'a source already inside the physical viewport must reuse the exact provider warmed by detached ImageCache prefetch',
      );
    },
  );

  test('generation-stable file capability keeps one ImageProvider cache key',
      () async {
    const cacheIdentity = ('external-static-test', 1);
    final first = encodedResourceImageProvider(
      const FileEncodedResourceSource(
        path: '/proc/self/fd/101',
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final second = encodedResourceImageProvider(
      const FileEncodedResourceSource(
        path: '/proc/self/fd/202',
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final firstKey = await first.obtainKey(ImageConfiguration.empty);
    final secondKey = await second.obtainKey(ImageConfiguration.empty);
    expect(firstKey, secondKey);
  });

  testWidgets('prewarmed file identity resolves synchronously for mounted image',
      (tester) async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final directory = Directory(
      'build/external-static-prewarm-${DateTime.now().microsecondsSinceEpoch}',
    );
    await tester.runAsync(() => directory.create(recursive: true));
    addTearDown(() async {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/one.png');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    await tester.runAsync(() => file.writeAsBytes(bytes, flush: true));

    const cacheIdentity = ('prewarmed-mounted-image', 1);
    final asset = PageAsset(
      pageId: 'one',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.file(file.path),
      width: 1,
      height: 1,
      contentKindHint: ContentKindHint.png,
    );
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'one',
      ),
      sourceRevision: 'r1',
      canonicalUri: asset.uri,
      pageIndexHint: 0,
    );
    final identity = DecodeId(
      download: download,
      physicalWidth: 100,
      physicalHeight: 100,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    Future<PipelineEncodedPresentationFileLease?> open(
      MediaLoadToken _,
    ) async =>
        PipelineEncodedPresentationFileLease(
          path: file.path,
          length: bytes.length,
          cacheIdentity: cacheIdentity,
          width: 1,
          height: 1,
          release: () async {},
        );

    await tester.runAsync(() => prewarmPipelineExternalStaticPresentation(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: MediaLoadToken(),
            openEncodedPresentationFile: open,
            loadBytes: (_) async => bytes,
            maxPhysicalWidth: 100,
            maxPhysicalHeight: 100,
          ),
        ));

    final provider = encodedResourceImageProvider(
      FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: bytes.length,
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final frame = Completer<bool>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronouslyLoaded) {
        image.dispose();
        stream.removeListener(listener);
        if (!frame.isCompleted) frame.complete(synchronouslyLoaded);
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        if (!frame.isCompleted) frame.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    expect(await frame.future, isTrue);
  });

  testWidgets(
      'memory prewarm remains synchronous after backing switches to file',
      (tester) async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final directory = Directory(
      'build/external-static-memory-file-${DateTime.now().microsecondsSinceEpoch}',
    );
    await tester.runAsync(() => directory.create(recursive: true));
    addTearDown(() async {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final file = File('${directory.path}/one.png');
    await tester.runAsync(() => file.writeAsBytes(bytes, flush: true));
    final cacheIdentity = Object();
    final asset = PageAsset(
      pageId: 'memory-then-file',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.parse('venera-resource:memory-then-file'),
      width: 1,
      height: 1,
      contentKindHint: ContentKindHint.png,
    );
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'memory-then-file',
      ),
      sourceRevision: 'r1',
      canonicalUri: asset.uri,
      pageIndexHint: 0,
    );
    final identity = DecodeId(
      download: download,
      physicalWidth: 100,
      physicalHeight: 100,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );

    await tester.runAsync(() => prewarmPipelineExternalStaticPresentation(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: MediaLoadToken(),
            openEncodedPresentationFile: (_) async => null,
            loadBytes: (_) async => bytes,
            maxPhysicalWidth: 100,
            maxPhysicalHeight: 100,
          ),
        ));

    final provider = encodedResourceImageProvider(
      FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: bytes.length,
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final frame = Completer<bool>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronouslyLoaded) {
        image.dispose();
        stream.removeListener(listener);
        if (!frame.isCompleted) frame.complete(synchronouslyLoaded);
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        if (!frame.isCompleted) frame.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    expect(await frame.future, isTrue);
  });

  testWidgets('prewarm declines a source that needs layout-specific resize',
      (tester) async {
    final token = MediaLoadToken();
    final asset = PageAsset(
      pageId: 'large',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.parse('https://example.test/large.png'),
      width: 1200,
      height: 1800,
      contentKindHint: ContentKindHint.png,
    );
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'large',
      ),
      sourceRevision: 'r1',
      canonicalUri: asset.uri,
      pageIndexHint: 0,
    );
    final identity = DecodeId(
      download: download,
      physicalWidth: 800,
      physicalHeight: 1200,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    var releases = 0;

    await expectLater(
      prewarmPipelineExternalStaticPresentation(
        PipelineExternalPresentationWarmRequest(
          asset: asset,
          identity: identity,
          cacheIdentity: const ('large-presentation', 1),
          token: token,
          openEncodedPresentationFile: (_) async =>
              PipelineEncodedPresentationFileLease(
            path: '/unused/large.png',
            length: 1,
            cacheIdentity: const ('large', 1),
            width: 1200,
            height: 1800,
            release: () async => releases++,
          ),
          loadBytes: (_) async => Uint8List(0),
          maxPhysicalWidth: 800,
          maxPhysicalHeight: 1200,
        ),
      ),
      throwsUnsupportedError,
    );
    expect(releases, 1);
  });
}
