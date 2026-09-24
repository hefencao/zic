part of '../local_media_ui.dart';

/// Decodes one coordinator-authorized external static page into Flutter's
/// existing ImageCache without creating a hidden page/widget tree.
///
/// Mounted and detached presentation must derive the effective ImageProvider
/// through the same raster policy. Pipeline supplies the typed presentation
/// fit while this composition layer owns the Flutter cache/ResizeImage key.
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
      final format = detectLocalImageFormat(
        bytes,
        fileLength: bytes.lengthInBytes,
      );
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
    provider = _mediaRasterProviderForPresentation(
      image: provider,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      maxPhysicalWidth: request.maxPhysicalWidth,
      maxPhysicalHeight: request.maxPhysicalHeight,
      fit: request.fit,
    );
    provider = pipelinePresentationRasterCache.providerFor(
      provider: provider,
      presentationIdentity: request.cacheIdentity,
    );

    await _resolveFirstStaticImageFrame(provider, request.token);
  } finally {
    final currentLease = lease;
    if (currentLease != null) {
      await currentLease.release();
    }
  }
}

ImageProvider<Object> _mediaRasterProviderForPresentation({
  required ImageProvider<Object> image,
  required int sourceWidth,
  required int sourceHeight,
  required int maxPhysicalWidth,
  required int maxPhysicalHeight,
  required PipelineExternalPresentationFit fit,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) return image;
  if (maxPhysicalWidth <= 0 || maxPhysicalHeight <= 0) return image;

  // fitWidth owns width only. The page host's physical height is derived from
  // source aspect and may be much taller than the viewport; constraining it to
  // viewport height would manufacture a different ResizeImage key and make
  // detached warming unusable for long vertical pages.
  final effectiveMaxHeight = fit == PipelineExternalPresentationFit.fitWidth
      ? sourceHeight
      : maxPhysicalHeight;
  if (sourceWidth <= maxPhysicalWidth && sourceHeight <= effectiveMaxHeight) {
    return image;
  }
  final raster = AlignedRasterSize.fit(
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    maxWidth: maxPhysicalWidth,
    maxHeight: effectiveMaxHeight,
  );
  return ResizeImage.resizeIfNeeded(
    raster.width < sourceWidth ? raster.width : null,
    raster.height < sourceHeight ? raster.height : null,
    image,
  );
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
