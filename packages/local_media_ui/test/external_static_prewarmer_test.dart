import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

void main() {
  setUp(() {
    pipelinePresentationRasterCache.clearPresentationRasters();
  });
  tearDown(() {
    pipelinePresentationRasterCache.clearPresentationRasters();
  });
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

  test(
    'generation-stable file capability keeps one ImageProvider cache key',
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
    },
  );

  testWidgets('prewarmed file identity resolves synchronously for mounted image', (
    tester,
  ) async {
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
    ) async => PipelineEncodedPresentationFileLease(
          path: file.path,
          length: bytes.length,
          cacheIdentity: cacheIdentity,
          width: 1,
          height: 1,
          release: () async {},
        );

    await tester.runAsync(
      () => prewarmPipelineExternalStaticPresentation(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: MediaLoadToken(),
            openEncodedPresentationFile: open,
            loadBytes: (_) async => bytes,
            maxPhysicalWidth: 100,
            maxPhysicalHeight: 100,
            fit: PipelineExternalPresentationFit.contain,
          ),
      ),
    );

    final provider = encodedResourceImageProvider(
      FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: bytes.length,
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final managed = pipelinePresentationRasterCache.providerFor(
      provider: provider,
      presentationIdentity: cacheIdentity,
    );
    final stream = managed.resolve(ImageConfiguration.empty);
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

  testWidgets('memory prewarm remains synchronous after backing switches to file', (
    tester,
  ) async {
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

    await tester.runAsync(
      () => prewarmPipelineExternalStaticPresentation(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: MediaLoadToken(),
            openEncodedPresentationFile: (_) async => null,
            loadBytes: (_) async => bytes,
            maxPhysicalWidth: 100,
            maxPhysicalHeight: 100,
            fit: PipelineExternalPresentationFit.contain,
          ),
      ),
    );

    final provider = encodedResourceImageProvider(
      FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: bytes.length,
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    final managed = pipelinePresentationRasterCache.providerFor(
      provider: provider,
      presentationIdentity: cacheIdentity,
    );
    final stream = managed.resolve(ImageConfiguration.empty);
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
      'fit-width long page prewarm matches the mounted presentation cache key',
      (tester) async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final directory = Directory(
      'build/external-static-fit-width-${DateTime.now().microsecondsSinceEpoch}',
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
    final file = File('${directory.path}/long.png');
    await tester.runAsync(() => file.writeAsBytes(bytes, flush: true));

    const cacheIdentity = ('long-fit-width-presentation', 1);
    final asset = PageAsset(
      pageId: 'long',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.file(file.path),
      width: 1080,
      height: 3600,
      contentKindHint: ContentKindHint.png,
    );
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'long',
      ),
      sourceRevision: 'r1',
      canonicalUri: asset.uri,
      pageIndexHint: 0,
    );
    final identity = DecodeId(
      download: download,
      physicalWidth: 1080,
      physicalHeight: 2336,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    var releases = 0;

      await tester.runAsync(
        () => prewarmPipelineExternalStaticPresentation(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: MediaLoadToken(),
            openEncodedPresentationFile: (_) async =>
                PipelineEncodedPresentationFileLease(
              path: file.path,
              length: bytes.length,
              cacheIdentity: cacheIdentity,
              width: 1080,
              height: 3600,
              release: () async => releases++,
            ),
            loadBytes: (_) async => bytes,
            maxPhysicalWidth: 1080,
            maxPhysicalHeight: 2336,
            fit: PipelineExternalPresentationFit.fitWidth,
          ),
        ),
      );

    final provider = encodedResourceImageProvider(
      FileEncodedResourceSource(
        path: file.path,
        lengthInBytes: bytes.length,
        cacheIdentity: cacheIdentity,
        origin: EncodedResourceOrigin.durableCacheFile,
      ),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2.5),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 432,
            height: 934.4,
            child: MediaRasterImage(
              image: provider,
              dimensions: const Size(1080, 3600),
              fit: BoxFit.fitWidth,
                presentationIdentity: cacheIdentity,
            ),
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
      final managed = pipelinePresentationRasterCache.providerFor(
        provider: provider,
        presentationIdentity: cacheIdentity,
      );
    expect(
        await image.image.obtainKey(ImageConfiguration.empty),
        await managed.obtainKey(ImageConfiguration.empty),
      reason:
            'fit-width presentation is width-bound; mounted and detached paths must resolve the same managed raster key',
    );
      final stream = managed.resolve(ImageConfiguration.empty);
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
    expect(releases, 1);
    },
  );
}
