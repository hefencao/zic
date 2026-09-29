part of '../local_media_ui.dart';

final class ImageFolderScreen extends StatelessWidget {
  const ImageFolderScreen({
    required this.folder,
    this.bytesLoader,
    this.onPreviewStateChanged,
    this.initialProgress,
    this.onProgressChanged,
    this.onProgressFlush,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    required this.pipelineFactory,
    this.initialReaderSettings = const ReaderSessionSettings(),
    this.onReaderSettingsChanged,
    super.key,
  });

  final PickedImageFolder folder;
  final LocalImageBytesLoader? bytesLoader;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final ReaderProgressFlush? onProgressFlush;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final PipelineReaderSessionFactory pipelineFactory;
  final ReaderSessionSettings initialReaderSettings;
  final ReaderSessionSettingsWriter? onReaderSettingsChanged;

  @override
  Widget build(BuildContext context) {
    final record = imageFolderChapterRecord(folder);
    return ImportedImageChapterScreen(
      record: record,
      byteLoaders: <String, LocalImageFileBytesLoader>{
        for (final image in folder.files)
          if (image.sourceUri.scheme != 'content' &&
              (bytesLoader != null ||
                  image.hasCustomBytesLoader ||
                  image.sourceUri.scheme == 'memory'))
            image.sourceId: () => bytesLoader == null
                ? image.readAsBytes()
                : bytesLoader!(image),
      },
      onPreviewStateChanged: onPreviewStateChanged,
      initialProgress: initialProgress,
      onProgressChanged: onProgressChanged,
      onProgressFlush: onProgressFlush,
      initialFavorite: initialFavorite,
      onFavoriteChanged: onFavoriteChanged,
      onDownloadRequested: onDownloadRequested,
      pipelineFactory: pipelineFactory,
      initialReaderSettings: initialReaderSettings,
      onReaderSettingsChanged: onReaderSettingsChanged,
    );
  }
}


final class _ImportedChapterPipelineKey {
  _ImportedChapterPipelineKey(ImportedChapterRecord record)
      : chapterId = record.chapterId,
        sourceRevision = record.sourceRevision,
        pages = List<(String, String, int?, ContentKindHint, bool)>.unmodifiable(
          record.pages.map(
            (page) => (
              page.stablePageId,
              page.sourceId,
              page.byteLength,
              page.contentKindHint,
              page.animatedHint,
            ),
          ),
        );

  final String chapterId;
  final String sourceRevision;
  final List<(String, String, int?, ContentKindHint, bool)> pages;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ImportedChapterPipelineKey ||
        chapterId != other.chapterId ||
        sourceRevision != other.sourceRevision ||
        pages.length != other.pages.length) {
      return false;
    }
    for (var index = 0; index < pages.length; index++) {
      if (pages[index] != other.pages[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        chapterId,
        sourceRevision,
        Object.hashAll(pages),
      );
}

typedef ImportedPagePresentationRecovery = Future<bool> Function(
  PageAsset asset,
  Object error, {
  required bool userInitiated,
});

final class LocalImageResponseSource {
  const LocalImageResponseSource({
    required this.openControlledResponse,
    this.selfBoundedOpen = false,
  });

  final ControlledTransportResponseLoader openControlledResponse;
  final bool selfBoundedOpen;
}

Transport importedImageChapterLoaderTransport({
  required ImportedChapterRecord record,
  required Map<String, LocalImageFileBytesLoader> byteLoaders,
  required Map<String, LocalImageResponseSource> responseSources,
}) {
  final chapter = record.toManifest();
  final sources = _importedImageChapterLoaderSources(
    record: record,
    chapter: chapter,
    byteLoaders: byteLoaders,
    responseSources: responseSources,
  );
  return LoaderTransport(sources);
}

Map<Uri, LoaderTransportSource> _importedImageChapterLoaderSources({
  required ImportedChapterRecord record,
  required ChapterManifest chapter,
  required Map<String, LocalImageFileBytesLoader> byteLoaders,
  required Map<String, LocalImageResponseSource> responseSources,
}) {
  final sources = <Uri, LoaderTransportSource>{};
  for (var index = 0; index < record.pages.length; index++) {
    final page = record.pages[index];
    final uri = chapter.pages[index].uri;
    final loader = byteLoaders[page.sourceId];
    final responseSource = responseSources[page.sourceId];
    if (loader != null && responseSource != null) {
      throw StateError(
        'page source composition must choose local bytes or origin response, not both',
      );
    }
    sources[uri] = LoaderTransportSource(
      revision: '${record.sourceRevision}:$index',
      loadBytes: loader,
      openControlledResponse: responseSource?.openControlledResponse,
      selfBoundedOpen: responseSource?.selfBoundedOpen ?? false,
      openResponse: responseSource == null && loader == null
          ? ({ByteRange? range, Validators? validators}) =>
              _openLocalMediaResponse(
                page.sourceId,
                range: range,
                validators: validators,
              )
          : null,
    );
  }
  return sources;
}

PipelineReaderSessionFactory importedImageChapterPipelineFactory({
  required ImportedChapterRecord record,
  required Map<String, LocalImageFileBytesLoader> byteLoaders,
  required Map<String, LocalImageResponseSource> responseSources,
  required PipelineReaderSessionFactory pipelineFactory,
}) {
  final chapter = record.toManifest();
  final sources = _importedImageChapterLoaderSources(
    record: record,
    chapter: chapter,
    byteLoaders: byteLoaders,
    responseSources: responseSources,
  );
  return pipelineFactory.withLoaderSources(sources);
}

final class ImportedImageChapterScreen extends StatelessWidget {
  const ImportedImageChapterScreen({
    required this.record,
    this.adaptiveMetadata,
    this.byteLoaders = const <String, LocalImageFileBytesLoader>{},
    this.responseSources = const <String, LocalImageResponseSource>{},
    this.onPreviewStateChanged,
    this.initialProgress,
    this.onProgressChanged,
    this.onProgressFlush,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    this.onFirstPresentationFrame,
    this.onPagePresentationRecovery,
    required this.pipelineFactory,
    this.initiallyImmersive = true,
    this.initialReaderSettings = const ReaderSessionSettings(),
    this.onReaderSettingsChanged,
    this.onReaderModeSettingsChanged,
    this.onOpenGlobalReadingSettings,
    this.onOpenSourceWebView,
    this.onOpenExternalBrowser,
    this.canReadPreviousChapter = false,
    this.canReadNextChapter = false,
    this.onChapterBoundaryRequested,
    this.traceSink,
    super.key,
  });

  final ImportedChapterRecord record;
  final AdaptiveReaderMetadata? adaptiveMetadata;
  final Map<String, LocalImageFileBytesLoader> byteLoaders;
  final Map<String, LocalImageResponseSource> responseSources;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final ReaderProgressFlush? onProgressFlush;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final VoidCallback? onFirstPresentationFrame;
  final ImportedPagePresentationRecovery? onPagePresentationRecovery;
  final PipelineReaderSessionFactory pipelineFactory;
  final bool initiallyImmersive;
  final ReaderSessionSettings initialReaderSettings;
  final ReaderSessionSettingsWriter? onReaderSettingsChanged;
  final ReaderModeSettingsWriter? onReaderModeSettingsChanged;
  final ReaderGlobalSettingsOpener? onOpenGlobalReadingSettings;
  final ReaderExternalAction? onOpenSourceWebView;
  final ReaderExternalAction? onOpenExternalBrowser;
  final bool canReadPreviousChapter;
  final bool canReadNextChapter;
  final ReaderChapterBoundaryCallback? onChapterBoundaryRequested;
  final TraceSink? traceSink;

  @override
  Widget build(BuildContext context) {
    final chapter = record.toManifest();
    final configuredFactory = importedImageChapterPipelineFactory(
      record: record,
      byteLoaders: byteLoaders,
      responseSources: responseSources,
      pipelineFactory: pipelineFactory,
    );

    return PipelineReaderSessionHost(
      key: ValueKey<_ImportedChapterPipelineKey>(
        _ImportedChapterPipelineKey(record),
      ),
      chapter: chapter,
      factory: configuredFactory,
      traceSink: traceSink,
      builder: (context, pipeline) => ReaderRuntimeScreen(
        pipeline: pipeline,
        screenKey: imageFolderScreenKey,
        chapter: chapter,
        adaptiveMetadata: adaptiveMetadata ??
            AdaptiveReaderMetadata(
              sourceKey: record.sourceId,
              comicId: record.comicId,
              title: record.comicTitle,
              authors: record.comicAuthors,
              tags: record.comicTags,
              sourceUrl: record.pages.first.uri.toString(),
            ),
        initialProgress: initialProgress,
        onProgressChanged: onProgressChanged,
        onProgressFlush: onProgressFlush,
        initialFavorite: initialFavorite,
        onFavoriteChanged: onFavoriteChanged,
        onDownloadRequested: onDownloadRequested,
        onFirstPresentationFrame: onFirstPresentationFrame,
        initiallyImmersive: initiallyImmersive,
        initialSettings: initialReaderSettings,
        onSettingsChanged: onReaderSettingsChanged,
        onModeSettingsChanged: onReaderModeSettingsChanged,
        onOpenGlobalReadingSettings: onOpenGlobalReadingSettings,
        onOpenSourceWebView: onOpenSourceWebView,
        onOpenExternalBrowser: onOpenExternalBrowser,
        canReadPreviousChapter: canReadPreviousChapter,
        canReadNextChapter: canReadNextChapter,
        onChapterBoundaryRequested: onChapterBoundaryRequested,
        pageSubtitleBuilder: (asset) {
          final current = record.pages[asset.index];
          return '${current.displayName} · ${_importedPageFormat(current).label}';
        },
        artifactPageBuilder: (
          context,
          asset,
          reportFirstFrame,
          runtime,
        ) {
          final page = record.pages[asset.index];
          final format = _importedPageFormat(page);
          final image = PickedImage(
            file: XFile(page.sourceId),
            format: format,
            displayName: page.displayName,
            sourceId: page.sourceId,
            byteLength: page.byteLength,
            readBytes: byteLoaders[page.sourceId] ??
                (_isRemoteMediaUri(page.uri)
                    ? () => Future<Uint8List>.error(
                          StateError(
                            'remote page bytes are owned by the Reader artifact',
                          ),
                        )
                    : () => readLocalImageSource(page.sourceId)),
          );
          return ColoredBox(
            color: Colors.black,
            child: LocalImagePlayer(
              key: ValueKey<String>(
                'folder-image:${page.sourceId}:${format.name}:${asset.index}',
              ),
              image: image,
              presentationBytesLoader: (_, token) =>
                  runtime.loadPresentationBytes(token),
              presentationFileLoader: runtime.openEncodedPresentationFile,
              onRecoverPresentationFailure: onPagePresentationRecovery == null
                  ? runtime.recoverPresentationFailure
                  : (error, authority) async {
                      if (await onPagePresentationRecovery!(
                        asset,
                        error,
                        userInitiated: false,
                      )) {
                        return true;
                      }
                      return runtime.recoverPresentationFailure(
                        error,
                        authority,
                      );
                    },
              onRetry: onPagePresentationRecovery == null
                  ? runtime.retryPresentation
                  : null,
              onRetryWithError: onPagePresentationRecovery == null
                  ? null
                  : (error) async {
                      if (error != null &&
                          await onPagePresentationRecovery!(
                            asset,
                            error,
                            userInitiated: true,
                          )) {
                        return true;
                      }
                      return runtime.retryPresentation();
                    },
              onPreviewStateChanged: onPreviewStateChanged,
              onFirstFrame: reportFirstFrame,
              downloadIdentity: runtime.pageStream.identity,
              traceClock: runtime.clock,
              traceSink: runtime.traceSink,
              traceSessionId: runtime.sessionId,
              demandRevision: runtime.demandRevision,
              playback: runtime.playback,
              pageStream: runtime.pageStream,
              pageOutput: runtime.pageOutput,
              onPlaybackCapabilityChanged: runtime.reportPlaybackCapability,
              onDimensionsChanged: (size) => runtime.reportDimensions(
                size.width.round(),
                size.height.round(),
              ),
              fit: runtime.mediaFit,
            ),
          );
        },
      ),
    );
  }
}


bool _isRemoteMediaUri(Uri uri) =>
    uri.scheme == 'http' || uri.scheme == 'https';

LocalImageFormat _importedPageFormat(ImportedPageRecord page) {
  final stored = localImageFormatByName(page.mediaFormat ?? '');
  if (stored != null) {
    return stored;
  }
  return switch (page.contentKindHint) {
    ContentKindHint.jpeg => LocalImageFormat.jpeg,
    ContentKindHint.png => LocalImageFormat.png,
    ContentKindHint.gif => LocalImageFormat.gif,
    ContentKindHint.webp => LocalImageFormat.webp,
    ContentKindHint.avif => LocalImageFormat.avif,
    ContentKindHint.unknown || ContentKindHint.fallback =>
      _formatFromSourceName(page.sourceId),
  };
}

LocalImageFormat _formatFromSourceName(String sourceId) {
  final path = (Uri.tryParse(sourceId)?.path ?? sourceId).toLowerCase();
  if (path.endsWith('.webp')) {
    return LocalImageFormat.webp;
  }
  if (path.endsWith('.gif')) {
    return LocalImageFormat.gif;
  }
  if (path.endsWith('.png')) {
    return LocalImageFormat.png;
  }
  if (path.endsWith('.avif')) {
    return LocalImageFormat.avif;
  }
  if (path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.jpe')) {
    return LocalImageFormat.jpeg;
  }
  if (path.endsWith('.bmp') || path.endsWith('.dib')) {
    return LocalImageFormat.bmp;
  }
  if (path.endsWith('.tif') || path.endsWith('.tiff')) {
    return LocalImageFormat.tiff;
  }
  if (path.endsWith('.ico')) {
    return LocalImageFormat.ico;
  }
  if (path.endsWith('.heif') ||
      path.endsWith('.heic') ||
      path.endsWith('.hif')) {
    return LocalImageFormat.heif;
  }
  return LocalImageFormat.jpeg;
}

final class WebpPlayerScreen extends StatelessWidget {
  const WebpPlayerScreen._({
    required this.title,
    required this.loadBytes,
    required this.sourceUri,
  });

  factory WebpPlayerScreen.asset({required WebpDemoEntry entry}) {
    return WebpPlayerScreen._(
      title: entry.title,
      sourceUri: Uri.parse(entry.asset),
      loadBytes: (_) async {
        final data = await rootBundle.load(entry.asset);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      },
    );
  }

  factory WebpPlayerScreen.file(
    XFile file, {
    String? displayName,
  }) {
    final explicit = displayName?.trim() ?? '';
    final title = explicit.isEmpty ? webpDisplayName(file) : explicit;
    return WebpPlayerScreen._(
      title: title,
      sourceUri: file.path.isEmpty
          ? Uri(scheme: 'memory', path: title)
          : Uri.file(file.path),
      loadBytes: (_) => file.readAsBytes(),
    );
  }

  factory WebpPlayerScreen.picked(PickedWebp picked) => WebpPlayerScreen.file(
        picked.file,
        displayName: picked.displayName,
      );

  factory WebpPlayerScreen.bytes({
    required String displayName,
    required Uint8List bytes,
    Uri? sourceUri,
  }) =>
      WebpPlayerScreen._(
        title: displayName,
        sourceUri: sourceUri ?? Uri(scheme: 'memory', path: displayName),
        loadBytes: (_) async => bytes,
      );

  final String title;
  final Uri sourceUri;
  final WebpBytesLoader loadBytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: webpPreviewScreenKey,
      appBar: AppBar(
        title: Text(
          title,
          key: webpPreviewTitleKey,
        ),
      ),
      body: NativeWebpPlayer(
        title: title,
        sourceUri: sourceUri,
        loadBytes: loadBytes,
      ),
    );
  }
}



Future<ByteResponse> _openLocalMediaResponse(
  String sourceId, {
  ByteRange? range,
  Validators? validators,
}) async {
  range?.validate();
  final response = await openLocalImageSource(
    sourceId,
    start: range?.start ?? 0,
    endExclusive: range?.end == null ? null : range!.end! + 1,
    expectedRevision: validators?.etag,
  );
  final partial = response.partial;
  return ByteResponse(
    bytes: response.bytes,
    statusCode: partial ? 206 : 200,
    rangeStart: response.rangeStart,
    totalLength: response.totalLength,
    validators: Validators(etag: response.revision),
    rangeSupported: response.rangeSupported,
    disposition: ByteResponseDisposition.durableImmutable,
    onDiscard: response.close,
  );
}
