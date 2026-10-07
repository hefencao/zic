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

final _testStaticPresentation =
    PipelineStaticPresentation(pipelinePresentationRasterCache);

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
                staticPresentation: _testStaticPresentation,
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
      () => _testStaticPresentation.prewarm(
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
      () => _testStaticPresentation.prewarm(
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
        () => _testStaticPresentation.prewarm(
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
    bool? mountedSynchronouslyLoaded;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2.5),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 432,
            height: 934.4,
            child: MediaRasterImage(
              staticPresentation: _testStaticPresentation,
              image: provider,
              dimensions: const Size(1080, 3600),
              fit: BoxFit.fitWidth,
              presentationIdentity: cacheIdentity,
              frameBuilder: (context, child, frame, synchronouslyLoaded) {
                if (frame != null || synchronouslyLoaded) {
                  mountedSynchronouslyLoaded = synchronouslyLoaded;
                }
                return child;
              },
            ),
          ),
        ),
      ),
    );
    for (var attempt = 0;
        attempt < 20 && mountedSynchronouslyLoaded == null;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(
      mountedSynchronouslyLoaded,
      isTrue,
      reason:
          'fit-width mounted presentation must attach synchronously to the exact raster already admitted by detached prewarm',
    );
    expect(
      pipelinePresentationRasterCache.inspectPresentationRasters().entries,
      1,
      reason:
          'mounted attach must reuse the detached managed entry rather than replace it with a second key',
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
    expect(releases, 1);
    },
  );
  testWidgets('cancelled file prewarm pins an in-flight decoder for its consumer',
      (tester) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('zic-file-prewarm-lifetime-'),
    );
    final file = File('${directory!.path}/page.png');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    await tester.runAsync(() => file.writeAsBytes(bytes));
    addTearDown(() async {
      pipelinePresentationRasterCache.clearPresentationRasters();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    const cacheIdentity = ('cancelled-file-prewarm', 1);
    final asset = PageAsset(
      pageId: 'page',
      chapterId: 'chapter',
      index: 0,
      uri: Uri.file(file.path),
      width: 1,
      height: 1,
      contentKindHint: ContentKindHint.png,
    );
    final identity = DecodeId(
      download: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: asset.uri,
      ),
      physicalWidth: 100,
      physicalHeight: 100,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    var releases = 0;
    var releasesWhileReading = -1;
    Object? cancellation;
    Object? presentationError;
    var frames = 0;
    await tester.runAsync(() {
      final opened = Completer<void>();
      final continueRead = Completer<void>();
      final token = MediaLoadToken();
      return IOOverrides.runZoned(() async {
        final warm = _testStaticPresentation.prewarm(
          PipelineExternalPresentationWarmRequest(
            asset: asset,
            identity: identity,
            cacheIdentity: cacheIdentity,
            token: token,
            openEncodedPresentationFile: (_) async =>
                PipelineEncodedPresentationFileLease(
              path: file.path,
              length: bytes.length,
              width: 1,
              height: 1,
              cacheIdentity: cacheIdentity,
              release: () async {
                releases++;
                await file.delete();
              },
            ),
            loadBytes: (_) async => throw StateError('must keep the file route'),
            maxPhysicalWidth: 100,
            maxPhysicalHeight: 100,
            fit: PipelineExternalPresentationFit.contain,
          ),
        ).then<void>((_) {}, onError: (Object error, StackTrace _) {
          cancellation = error;
        });
        await opened.future.timeout(const Duration(seconds: 5));
        token.cancel();
        await Future<void>.delayed(Duration.zero);
        releasesWhileReading = releases;
        // A mounted deadline consumer can join the already-admitted pending
        // completer even after the detached warm request is cancelled.
        final provider = _testStaticPresentation.residentProvider(cacheIdentity)!;
        final stream = provider.resolve(ImageConfiguration.empty);
        final presented = Completer<void>();
        late final ImageStreamListener listener;
        listener = ImageStreamListener((image, _) {
          frames++;
          image.dispose();
          stream.removeListener(listener);
          presented.complete();
        }, onError: (Object error, StackTrace? _) {
          presentationError = error;
          stream.removeListener(listener);
          presented.complete();
        });
        stream.addListener(listener);
        continueRead.complete();
        await warm;
        await presented.future.timeout(const Duration(seconds: 5));
      }, createFile: (path) {
        return path == file.path
            ? _PendingReadFile(file, opened, continueRead.future)
            : throw StateError('unexpected file route: $path');
      });
    });

    expect(releasesWhileReading, 0,
        reason: 'cancelling a listener does not cancel the engine file read');
    expect(cancellation, isA<Failure>());
    expect(presentationError, isNull);
    expect(frames, 1);
    expect(releases, 1);
  });
}

final class _PendingReadFile implements File {
  _PendingReadFile(this.file, this.opened, this.continueRead);

  final File file;
  final Completer<void> opened;
  final Future<void> continueRead;

  @override
  String get path => file.path;

  @override
  Future<int> length() async {
    if (!opened.isCompleted) opened.complete();
    await continueRead;
    return file.length();
  }

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
