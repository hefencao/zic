part of '../local_media_ui.dart';

const _webpTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'Animated WebP',
    extensions: <String>['webp'],
    mimeTypes: <String>['image/webp'],
  ),
];

typedef WebpPicker = Future<PickedWebp?> Function();
typedef ImageFolderPicker = Future<PickedImageFolder?> Function();
typedef ImageFolderRefresher = Future<PickedImageFolder> Function(
  ImportedChapterRecord chapter,
);
typedef LocalWebpSelector = Future<XFile?> Function();
typedef WebpBytesLoader = Future<Uint8List> Function(MediaLoadToken token);
typedef LocalImageBytesLoader = Future<Uint8List> Function(PickedImage image);
typedef LocalImageTokenBytesLoader = Future<Uint8List> Function(
  PickedImage image,
  MediaLoadToken token,
);
typedef LocalImagePresentationFileLoader =
    Future<PipelineEncodedPresentationFileLease?> Function(MediaLoadToken token);
typedef LocalImageDecodeProbe = Future<void> Function(Uint8List bytes);


final class PickedImage {
  factory PickedImage({
    required XFile file,
    required LocalImageFormat format,
    String? displayName,
    String? sourceId,
    int? byteLength,
    LocalImageFileBytesLoader? readBytes,
  }) {
    if (byteLength != null && byteLength < 0) {
      throw ArgumentError.value(byteLength, 'byteLength', 'must be non-negative');
    }
    final explicit = displayName?.trim() ?? '';
    final explicitSource = sourceId?.trim() ?? '';
    final fallbackSource = file.path.trim().isEmpty
        ? 'memory:${explicit.isEmpty ? imageDisplayName(file) : explicit}'
        : file.path.trim();
    return PickedImage._(
      file: file,
      format: format,
      displayName: explicit.isEmpty ? imageDisplayName(file) : explicit,
      sourceId: explicitSource.isEmpty ? fallbackSource : explicitSource,
      byteLength: byteLength,
      bytesLoader: readBytes,
    );
  }

  const PickedImage._({
    required this.file,
    required this.format,
    required this.displayName,
    required this.sourceId,
    required this.byteLength,
    required LocalImageFileBytesLoader? bytesLoader,
  }) : _bytesLoader = bytesLoader;

  final XFile file;
  final LocalImageFormat format;
  final String displayName;
  final String sourceId;
  final int? byteLength;
  final LocalImageFileBytesLoader? _bytesLoader;

  Uri get sourceUri {
    final parsed = Uri.tryParse(sourceId);
    if (parsed != null &&
        parsed.hasScheme &&
        (sourceId.contains('://') || parsed.scheme == 'memory')) {
      return parsed;
    }
    return Uri.file(sourceId);
  }

  bool get hasCustomBytesLoader => _bytesLoader != null;

  Future<Uint8List> readAsBytes() =>
      _bytesLoader == null ? file.readAsBytes() : _bytesLoader();
}

class PickedImageFolder {
  factory PickedImageFolder({
    required String directoryPath,
    required List<PickedImage> files,
    String? displayName,
    int? scannedFiles,
    int unreadableFiles = 0,
  }) {
    if (files.isEmpty) {
      throw ArgumentError.value(
        files,
        'files',
        'must contain at least one image',
      );
    }
    final explicit = displayName?.trim() ?? '';
    return PickedImageFolder._(
      directoryPath: directoryPath,
      displayName: explicit.isEmpty
          ? imageDirectoryDisplayName(directoryPath)
          : explicit,
      files: List<PickedImage>.unmodifiable(files),
      scannedFiles: scannedFiles ?? files.length,
      unreadableFiles: unreadableFiles,
    );
  }

  const PickedImageFolder._({
    required this.directoryPath,
    required this.displayName,
    required this.files,
    required this.scannedFiles,
    required this.unreadableFiles,
  });

  final String directoryPath;
  final String displayName;
  final List<PickedImage> files;
  final int scannedFiles;
  final int unreadableFiles;
}

final class PickedWebp {
  factory PickedWebp({
    required XFile file,
    String? displayName,
  }) {
    final explicit = displayName?.trim() ?? '';
    return PickedWebp._(
      file: file,
      displayName: explicit.isEmpty ? webpDisplayName(file) : explicit,
    );
  }

  const PickedWebp._({
    required this.file,
    required this.displayName,
  });

  factory PickedWebp.fromFile(XFile file) => PickedWebp(file: file);

  final XFile file;
  final String displayName;
}

String imageDisplayName(XFile file) {
  final name = file.name.trim();
  if (name.isNotEmpty) {
    return name;
  }
  final path = file.path.trim();
  if (path.isNotEmpty) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final base = slash < 0 ? normalized : normalized.substring(slash + 1);
    if (base.isNotEmpty) {
      return base;
    }
  }
  return '本地图片';
}

String webpDisplayName(XFile file) => imageDisplayName(file);

const webpCatalogScreenKey = ValueKey<String>('webp-catalog-screen');
const webpPreviewScreenKey = ValueKey<String>('webp-preview-screen');
const webpPreviewTitleKey = ValueKey<String>('webp-preview-title');
const webpPreviewStateKey = ValueKey<String>('webp-preview-state');
const webpPreviewLoadingKey = ValueKey<String>('webp-preview-loading');
const webpPreviewReadyKey = ValueKey<String>('webp-preview-ready');
const webpPreviewErrorKey = ValueKey<String>('webp-preview-error');
const webpEngineControlKey = ValueKey<String>('webp-engine-control');
const webpNativeEngineOptionKey = ValueKey<String>('webp-engine-native-option');
const webpFlutterEngineOptionKey =
    ValueKey<String>('webp-engine-flutter-option');
const webpNativeConfirmDialogKey =
    ValueKey<String>('webp-native-confirm-dialog');
const webpNativeConfirmKey = ValueKey<String>('webp-native-confirm');
const webpNativeCancelKey = ValueKey<String>('webp-native-cancel');
const webpFlutterPreviewKey = ValueKey<String>('webp-flutter-preview');
const webpNativeTextureViewportKey =
    ValueKey<String>('webp-native-texture-viewport');
const imageFolderScreenKey = ValueKey<String>('webp-folder-screen');
const imageFolderPreviewStateKey =
    ValueKey<String>('image-folder-preview-state');
const imageFolderPreviewReadyKey =
    ValueKey<String>('image-folder-preview-ready');
const imageFolderPreviewLoadingKey =
    ValueKey<String>('image-folder-preview-loading');
const imagePageLoadingIndicatorKey =
    ValueKey<String>('image-page-loading-indicator');
const imageFolderPreviewErrorKey =
    ValueKey<String>('image-folder-preview-error');
const imageFolderPreviewRetryKey =
    ValueKey<String>('image-folder-preview-retry');
const imageFolderFlutterPreviewKey =
    ValueKey<String>('image-folder-flutter-preview');

Key webpCatalogEntryKey(String id) => ValueKey<String>('webp-catalog:$id');

Future<PickedWebp?> pickLocalWebp({LocalWebpSelector? selectFile}) async {
  final file =
      await (selectFile ?? () => openFile(acceptedTypeGroups: _webpTypes))();
  return file == null ? null : PickedWebp.fromFile(file);
}

Future<PickedWebp?> defaultWebpPicker() => pickLocalWebp();

Future<PickedImageFolder?> pickLocalImageFolder({
  LocalImageDirectoryContentsPicker? pickDirectoryContents,
  LocalImageDirectorySelector? selectDirectory,
  LocalImageDirectoryLoader? listFiles,
}) async {
  final useScopedPicker = pickDirectoryContents != null ||
      (selectDirectory == null &&
          listFiles == null &&
          prefersScopedLocalImageDirectoryPicker);
  if (useScopedPicker) {
    final picker = pickDirectoryContents ?? pickScopedLocalImageDirectory;
    final selection = await picker();
    if (selection == null) {
      return null;
    }
    return _pickedImageFolderFromScan(
      directoryId: selection.directoryId,
      displayName: selection.displayName,
      scan: selection.scan,
    );
  }

  final directoryPath = await (selectDirectory ?? selectLocalImageDirectory)();
  if (directoryPath == null) {
    return null;
  }
  final normalizedDirectory = directoryPath.trim();
  if (normalizedDirectory.isEmpty) {
    throw const FormatException('文件夹路径不能为空');
  }
  final scan = await (listFiles ?? listLocalImageDirectory)(normalizedDirectory);
  return _pickedImageFolderFromScan(
    directoryId: normalizedDirectory,
    displayName: imageDirectoryDisplayName(normalizedDirectory),
    scan: scan,
    relativeRoot: normalizedDirectory,
  );
}

PickedImageFolder _pickedImageFolderFromScan({
  required String directoryId,
  required String displayName,
  required LocalImageDirectoryScan scan,
  String? relativeRoot,
}) {
  if (scan.images.isEmpty) {
    throw FormatException(
      '所选文件夹中没有可识别的图片（已按文件头检查 '
      '${scan.scannedFiles} 个文件；'
      '${scan.headerRecognizedFiles} 个文件头识别；'
      '${scan.metadataRecognizedFiles} 个元数据候选；'
      '${scan.unrecognizedFiles} 个文件签名不匹配；'
      '${scan.unreadableFiles} 个文件不可读取）',
    );
  }
  final files = scan.images
      .map(
        (image) => PickedImage(
          file: image.file,
          format: image.format,
          displayName: image.displayName ??
              (relativeRoot == null
                  ? imageDisplayName(image.file)
                  : _relativeImageName(relativeRoot, image.file.path)),
          sourceId: image.sourceId,
          byteLength: image.byteLength,
          readBytes: image.readBytes,
        ),
      )
      .toList(growable: false);
  return PickedImageFolder(
    directoryPath: directoryId,
    displayName: displayName,
    files: files,
    scannedFiles: scan.scannedFiles,
    unreadableFiles: scan.unreadableFiles,
  );
}

Future<PickedImageFolder?> defaultImageFolderPicker() => pickLocalImageFolder();

Future<PickedImageFolder> refreshPickedImageFolder(
  ImportedChapterRecord chapter, {
  LocalImageDirectoryRefresher? refreshDirectory,
}) async {
  final selection = await (refreshDirectory ?? refreshLocalImageDirectory)(
    chapter.directoryId,
  );
  return _pickedImageFolderFromScan(
    directoryId: selection.directoryId,
    displayName: selection.displayName,
    scan: selection.scan,
    relativeRoot: selection.directoryId.startsWith('content://')
        ? null
        : selection.directoryId,
  );
}

Future<PickedImageFolder> defaultImageFolderRefresher(
  ImportedChapterRecord chapter,
) =>
    refreshPickedImageFolder(chapter);

String imageDirectoryDisplayName(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    return '本地图片文件夹';
  }
  final withoutTrailing = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = withoutTrailing.lastIndexOf('/');
  final name =
      slash < 0 ? withoutTrailing : withoutTrailing.substring(slash + 1);
  return name.isEmpty ? '本地图片文件夹' : name;
}

String webpDirectoryDisplayName(String path) => imageDirectoryDisplayName(path);

String _relativeImageName(String directoryPath, String filePath) {
  final root = directoryPath.replaceAll('\\', '/');
  final path = filePath.replaceAll('\\', '/');
  final prefix = root.endsWith('/') ? root : '$root/';
  if (path.toLowerCase().startsWith(prefix.toLowerCase()) &&
      path.length > prefix.length) {
    return path.substring(prefix.length);
  }
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

enum WebpPreviewPhase { loading, ready, invalid }

typedef WebpPreviewStateChanged = void Function(WebpPreviewState state);

@immutable
final class WebpPreviewState {
  const WebpPreviewState._({required this.phase, this.info, this.error});

  const WebpPreviewState.loading() : this._(phase: WebpPreviewPhase.loading);

  const WebpPreviewState.ready(WebpInfo info)
      : this._(phase: WebpPreviewPhase.ready, info: info);

  const WebpPreviewState.invalid(Object error)
      : this._(phase: WebpPreviewPhase.invalid, error: error);

  final WebpPreviewPhase phase;
  final WebpInfo? info;
  final Object? error;
}

final class WebpPreviewStateRegion extends StatelessWidget {
  const WebpPreviewStateRegion({
    required this.state,
    required this.child,
    super.key,
  });

  final WebpPreviewState state;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

enum ImagePreviewPhase { loading, ready, invalid }

typedef ImagePreviewStateChanged = void Function(ImagePreviewState state);

@immutable
final class ImagePreviewState {
  const ImagePreviewState._({
    required this.phase,
    required this.format,
    this.error,
  });

  const ImagePreviewState.loading(LocalImageFormat format)
      : this._(phase: ImagePreviewPhase.loading, format: format);

  const ImagePreviewState.ready(LocalImageFormat format)
      : this._(phase: ImagePreviewPhase.ready, format: format);

  const ImagePreviewState.invalid(LocalImageFormat format, Object error)
      : this._(
          phase: ImagePreviewPhase.invalid,
          format: format,
          error: error,
        );

  final ImagePreviewPhase phase;
  final LocalImageFormat format;
  final Object? error;
}

final class ImagePreviewStateRegion extends StatelessWidget {
  const ImagePreviewStateRegion({
    required this.state,
    required this.child,
    super.key,
  });

  final ImagePreviewState state;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

final class WebpDemoEntry {
  const WebpDemoEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.asset,
    required this.byteLength,
    required this.frameCount,
    required this.loopCount,
  });

  final String id;
  final String title;
  final String description;
  final String asset;
  final int byteLength;
  final int frameCount;
  final int loopCount;
}

Future<List<WebpDemoEntry>> loadWebpDemoEntries() async {
  final source = await rootBundle.loadString('assets/demo/animated/index.json');
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?> || decoded['items'] is! List<Object?>) {
    throw const FormatException('invalid Animated WebP demo index');
  }
  final entries = <WebpDemoEntry>[];
  for (final value in decoded['items']! as List<Object?>) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('invalid Animated WebP demo entry');
    }
    entries.add(
      WebpDemoEntry(
        id: value['id']! as String,
        title: value['title']! as String,
        description: value['description']! as String,
        asset: value['asset']! as String,
        byteLength: value['byteLength']! as int,
        frameCount: value['frameCount']! as int,
        loopCount: value['loopCount']! as int,
      ),
    );
  }
  return List<WebpDemoEntry>.unmodifiable(entries);
}

