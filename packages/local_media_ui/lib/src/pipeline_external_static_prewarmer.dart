part of '../local_media_ui.dart';

/// Decodes one coordinator-authorized external static page into Flutter's
/// existing ImageCache without creating a hidden page/widget tree.
///
/// This executor deliberately accepts only the case where the source raster
/// already fits inside the Pipeline physical viewport. In that case the later
/// visible [MediaRasterImage] resolves the exact same base ImageProvider key,
/// so the cache hit is mechanically guaranteed. Larger sources may require a
/// layout-specific ResizeImage key (fit-width vs contain); without that typed
/// presentation geometry this optimization declines the request instead of
/// warming a second, unusable raster.
Future<void> prewarmPipelineExternalStaticPresentation(
  PipelineExternalPresentationWarmRequest request,
) async {
  request.token.throwIfCancelled();
  PipelineEncodedPresentationFileLease? lease;
  ImageProvider<Object>? provider;
  int? sourceWidth;
  int? sourceHeight;
  try {
    lease = await request.openEncodedPresentationFile(request.token);
    request.token.throwIfCancelled();
    if (lease != null) {
      sourceWidth = lease.width;
      sourceHeight = lease.height;
      provider = encodedResourceImageProvider(
        FileEncodedResourceSource(
          path: lease.path,
          lengthInBytes: lease.length,
          origin: EncodedResourceOrigin.durableCacheFile,
          cacheIdentity: request.cacheIdentity,
        ),
      );
    } else {
      final bytes = await request.loadBytes(request.token);
      request.token.throwIfCancelled();
      final format = detectLocalImageFormat(bytes, fileLength: bytes.lengthInBytes);
      if (format == null || format.isWebp || format == LocalImageFormat.gif) {
        throw StateError(
          'external static prewarm received non-static encoded content',
        );
      }
      final dimensions = _staticImageDimensions(bytes, format);
      if (dimensions == null) {
        throw UnsupportedError(
          'external static prewarm requires intrinsic dimensions',
        );
      }
      sourceWidth = dimensions.width;
      sourceHeight = dimensions.height;
      provider = encodedResourceImageProvider(
        MemoryEncodedResourceSource(
          bytes,
          cacheIdentity: request.cacheIdentity,
        ),
      );
    }

    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      throw UnsupportedError(
        'external static prewarm requires intrinsic dimensions',
      );
    }
    if (sourceWidth > request.maxPhysicalWidth ||
        sourceHeight > request.maxPhysicalHeight) {
      throw UnsupportedError(
        'external static prewarm needs layout-specific resize identity: '
        '${sourceWidth}x$sourceHeight > '
        '${request.maxPhysicalWidth}x${request.maxPhysicalHeight}',
      );
    }

    await _resolveFirstStaticImageFrame(provider, request.token);
  } finally {
    final currentLease = lease;
    if (currentLease != null) {
      await currentLease.release();
    }
  }
}

Future<void> _resolveFirstStaticImageFrame(
  ImageProvider<Object> provider,
  MediaLoadToken token,
) async {
  token.throwIfCancelled();
  final stream = provider.resolve(ImageConfiguration.empty);
  final completed = Completer<void>();
  late final ImageStreamListener listener;
  var listening = false;

  void detach() {
    if (!listening) return;
    listening = false;
    stream.removeListener(listener);
  }

  listener = ImageStreamListener(
    (image, _) {
      image.dispose();
      detach();
      if (!completed.isCompleted) completed.complete();
    },
    onError: (Object error, StackTrace? stackTrace) {
      detach();
      if (!completed.isCompleted) {
        completed.completeError(error, stackTrace);
      }
    },
  );
  listening = true;
  stream.addListener(listener);
  try {
    await Future.any<void>(<Future<void>>[
      completed.future,
      token.whenCancelled.then<void>((_) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'external static presentation prewarm was cancelled',
        );
      }),
    ]);
    token.throwIfCancelled();
  } finally {
    detach();
  }
}
