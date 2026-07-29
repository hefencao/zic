import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bridge/bridge.dart';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pipeline/pipeline.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';
import 'package:texture_bridge/texture_bridge.dart';
import 'package:transport/transport.dart';

import 'local_image_folder.dart';
import 'media_load_token.dart';
import 'reader_runtime.dart';

export 'local_image_folder.dart';
export 'media_load_token.dart' show MediaLoadToken;

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
@Deprecated('Use ImageFolderPicker')
typedef WebpFolderPicker = ImageFolderPicker;
typedef LocalWebpSelector = Future<XFile?> Function();
typedef WebpBytesLoader = Future<Uint8List> Function(WebpLoadToken token);
typedef LocalImageBytesLoader = Future<Uint8List> Function(PickedImage image);
typedef LocalImageTokenBytesLoader = Future<Uint8List> Function(
  PickedImage image,
  MediaLoadToken token,
);
typedef LocalImageDecodeProbe = Future<void> Function(Uint8List bytes);

@Deprecated('Use MediaLoadToken')
typedef WebpLoadToken = MediaLoadToken;

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

@Deprecated('Use PickedImageFolder')
final class PickedWebpFolder extends PickedImageFolder {
  factory PickedWebpFolder({
    required String directoryPath,
    required List<PickedWebp> files,
    String? displayName,
  }) {
    final explicit = displayName?.trim() ?? '';
    return PickedWebpFolder._(
      directoryPath: directoryPath,
      displayName: explicit.isEmpty
          ? imageDirectoryDisplayName(directoryPath)
          : explicit,
      files: List<PickedImage>.unmodifiable(
        files.map(
          (picked) => PickedImage(
            file: picked.file,
            format: LocalImageFormat.webp,
            displayName: picked.displayName,
          ),
        ),
      ),
    );
  }

  const PickedWebpFolder._({
    required String directoryPath,
    required String displayName,
    required List<PickedImage> files,
  }) : super._(
          directoryPath: directoryPath,
          displayName: displayName,
          files: files,
          scannedFiles: files.length,
          unreadableFiles: 0,
        );
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
const imageFolderTitleKey = ValueKey<String>('webp-folder-title');
const imageFolderCurrentFileKey = ValueKey<String>('webp-folder-current-file');
const imageFolderPositionKey = ValueKey<String>('webp-folder-position');
const imageFolderPreviousKey = ValueKey<String>('webp-folder-previous');
const imageFolderNextKey = ValueKey<String>('webp-folder-next');
const imageFolderFileMenuKey = ValueKey<String>('webp-folder-file-menu');
@Deprecated('Use imageFolderScreenKey')
const webpFolderScreenKey = imageFolderScreenKey;
@Deprecated('Use imageFolderTitleKey')
const webpFolderTitleKey = imageFolderTitleKey;
@Deprecated('Use imageFolderCurrentFileKey')
const webpFolderCurrentFileKey = imageFolderCurrentFileKey;
@Deprecated('Use imageFolderPositionKey')
const webpFolderPositionKey = imageFolderPositionKey;
@Deprecated('Use imageFolderPreviousKey')
const webpFolderPreviousKey = imageFolderPreviousKey;
@Deprecated('Use imageFolderNextKey')
const webpFolderNextKey = imageFolderNextKey;
@Deprecated('Use imageFolderFileMenuKey')
const webpFolderFileMenuKey = imageFolderFileMenuKey;
const imageFolderPreviewStateKey =
    ValueKey<String>('image-folder-preview-state');
const imageFolderPreviewReadyKey =
    ValueKey<String>('image-folder-preview-ready');
const imageFolderPreviewLoadingKey =
    ValueKey<String>('image-folder-preview-loading');
const imageFolderPreviewErrorKey =
    ValueKey<String>('image-folder-preview-error');
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

@Deprecated('Use pickLocalImageFolder')
Future<PickedImageFolder?> pickLocalWebpFolder({
  LocalImageDirectoryContentsPicker? pickDirectoryContents,
  LocalImageDirectorySelector? selectDirectory,
  LocalImageDirectoryLoader? listFiles,
}) =>
    pickLocalImageFolder(
      pickDirectoryContents: pickDirectoryContents,
      selectDirectory: selectDirectory,
      listFiles: listFiles,
    );

@Deprecated('Use defaultImageFolderPicker')
Future<PickedImageFolder?> defaultWebpFolderPicker() =>
    defaultImageFolderPicker();

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

final class WebpCatalogScreen extends StatelessWidget {
  const WebpCatalogScreen({
    this.entriesLoader = loadWebpDemoEntries,
    super.key,
  });

  final Future<List<WebpDemoEntry>> Function() entriesLoader;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: webpCatalogScreenKey,
      appBar: AppBar(title: const Text('内置动图 WebP')),
      body: FutureBuilder<List<WebpDemoEntry>>(
        future: entriesLoader(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('加载动图清单失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: snapshot.requireData.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final entry = snapshot.requireData[index];
              return Card(
                key: webpCatalogEntryKey(entry.id),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: SizedBox.square(
                    dimension: 64,
                    child: Image.asset(entry.asset, fit: BoxFit.cover),
                  ),
                  title: Text(entry.title),
                  subtitle: Text(
                    '${entry.description}\n'
                    '${entry.frameCount} 帧 · '
                    '${entry.loopCount == 0 ? '无限循环' : '${entry.loopCount} 次播放'} · '
                    '${entry.byteLength} B',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WebpPlayerScreen.asset(entry: entry),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

final class LocalImagePlayer extends StatefulWidget {
  const LocalImagePlayer({
    required this.image,
    this.bytesLoader,
    this.tokenBytesLoader,
    this.decodeProbe,
    this.onPreviewStateChanged,
    this.onFirstFrame,
    this.downloadIdentity,
    this.traceClock,
    this.traceSink = const NoopTraceSink(),
    this.traceSessionId = 'local-image-preview',
    this.demandRevision,
    this.playback,
    super.key,
  });

  final PickedImage image;
  final LocalImageBytesLoader? bytesLoader;
  final LocalImageTokenBytesLoader? tokenBytesLoader;
  final LocalImageDecodeProbe? decodeProbe;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final VoidCallback? onFirstFrame;
  final DownloadId? downloadIdentity;
  final MonoClock? traceClock;
  final TraceSink traceSink;
  final String traceSessionId;
  final int Function()? demandRevision;
  final ReaderPlaybackController? playback;

  Uri get sourceUri => image.sourceUri;

  @override
  State<LocalImagePlayer> createState() => _LocalImagePlayerState();
}

final class _LocalImagePlayerState extends State<LocalImagePlayer> {
  late ImagePreviewState _state;
  Uint8List? _bytes;
  ImageProvider<Object>? _imageProvider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  int _generation = 0;
  late MediaLoadToken _loadToken;
  bool _reportedFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _state = ImagePreviewState.loading(widget.image.format);
    _loadToken = MediaLoadToken();
    _scheduleObserverSnapshot();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LocalImagePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.sourceId != widget.image.sourceId ||
        oldWidget.image.displayName != widget.image.displayName ||
        oldWidget.image.format != widget.image.format) {
      _generation++;
      _loadToken.cancel();
      _loadToken = MediaLoadToken();
      _reportedFirstFrame = false;
      _detachImageStream();
      _bytes = null;
      _imageProvider = null;
      _state = ImagePreviewState.loading(widget.image.format);
      _notifyObserver(_state);
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final token = _loadToken;
    try {
      final tokenLoader = widget.tokenBytesLoader;
      final loader = widget.bytesLoader;
      final directPath = tokenLoader == null &&
              loader == null &&
              widget.decodeProbe == null &&
              !widget.image.format.isWebp &&
              !(widget.playback != null &&
                  widget.image.format == LocalImageFormat.gif)
          ? localImageFilePath(widget.image.sourceId)
          : null;
      if (directPath != null) {
        final provider = encodedResourceImageProvider(
          FileEncodedResourceSource(
            path: directPath,
            lengthInBytes: widget.image.byteLength,
          ),
        );
        if (!mounted || generation != _generation || token != _loadToken) {
          return;
        }
        setState(() => _imageProvider = provider);
        _listenForImage(provider, generation, widget.image.format);
        return;
      }
      final bytes = tokenLoader != null
          ? await tokenLoader(widget.image, token)
          : loader == null
              ? await widget.image.readAsBytes()
              : await loader(widget.image);
      token.throwIfCancelled();
      if (!mounted || generation != _generation || token != _loadToken) {
        return;
      }
      final detected = detectLocalImageFormat(bytes, fileLength: bytes.length);
      if (detected == null) {
        throw const FormatException('文件头不是可识别的图片格式');
      }
      if (detected != widget.image.format) {
        throw FormatException(
          '图片格式在扫描后发生变化：'
          '${widget.image.format.label} → ${detected.label}',
        );
      }
      final provider = detected.isWebp ? null : MemoryImage(bytes);
      final decodeProbe = widget.decodeProbe;
      if (provider != null && decodeProbe != null) {
        await decodeProbe(bytes);
        token.throwIfCancelled();
        if (!mounted ||
            generation != _generation ||
            token != _loadToken ||
            token.isCancelled) {
          return;
        }
      }
      setState(() {
        _bytes = bytes;
        _imageProvider = provider;
      });
      if (provider != null) {
        if (decodeProbe != null) {
          _publish(ImagePreviewState.ready(detected));
        } else {
          _listenForImage(provider, generation, detected);
        }
      }
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _publish(ImagePreviewState.invalid(widget.image.format, error));
    }
  }

  @override
  void dispose() {
    _generation++;
    _loadToken.cancel();
    _detachImageStream();
    super.dispose();
  }

  void _listenForImage(
    ImageProvider<Object> provider,
    int generation,
    LocalImageFormat format,
  ) {
    _detachImageStream();
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) {
        if (!mounted || generation != _generation) {
          return;
        }
        _publish(ImagePreviewState.ready(format));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            _detachImageStream();
          }
        });
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted || generation != _generation) {
          return;
        }
        _publish(ImagePreviewState.invalid(format, error));
        _detachImageStream();
      },
    );
    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  void _detachImageStream() {
    final stream = _imageStream;
    final listener = _imageStreamListener;
    _imageStream = null;
    _imageStreamListener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  void _scheduleObserverSnapshot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _notifyObserver(_state);
      }
    });
  }

  void _notifyObserver(ImagePreviewState state) {
    try {
      widget.onPreviewStateChanged?.call(state);
    } on Object catch (error) {
      debugPrint('image preview state observer failed: $error');
    }
  }

  void _publish(ImagePreviewState state) {
    if (!mounted ||
        (_state.phase == state.phase &&
            _state.format == state.format &&
            _state.error == state.error)) {
      return;
    }
    setState(() => _state = state);
    _notifyObserver(state);
    if (state.phase == ImagePreviewPhase.ready &&
        state.format != LocalImageFormat.webp) {
      _reportFirstFrame();
    }
  }

  void _reportFirstFrame() {
    if (_reportedFirstFrame) {
      return;
    }
    _reportedFirstFrame = true;
    try {
      widget.onFirstFrame?.call();
    } on Object catch (error) {
      debugPrint('image first-frame observer failed: $error');
    }
  }

  void _scheduleError(Object error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _publish(ImagePreviewState.invalid(widget.image.format, error));
      }
    });
  }

  void _onWebpState(WebpPreviewState state) {
    switch (state.phase) {
      case WebpPreviewPhase.loading:
        break;
      case WebpPreviewPhase.ready:
        _publish(ImagePreviewState.ready(LocalImageFormat.webp));
        break;
      case WebpPreviewPhase.invalid:
        _publish(
          ImagePreviewState.invalid(
            LocalImageFormat.webp,
            state.error ?? const FormatException('WebP 文件无效'),
          ),
        );
        break;
    }
  }

  void _onControlledReady() {
    _publish(ImagePreviewState.ready(widget.image.format));
    _reportFirstFrame();
  }

  void _onControlledError(Object error) {
    _publish(ImagePreviewState.invalid(widget.image.format, error));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final imageProvider = _imageProvider;
    final Widget content;
    if (_state.phase == ImagePreviewPhase.invalid) {
      content = Center(
        child: SelectionArea(
          child: Text(
            '图片无法打开：${_state.error}',
            key: imageFolderPreviewErrorKey,
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (bytes == null && imageProvider == null) {
      content = const Center(
        child: CircularProgressIndicator(),
      );
    } else if (widget.image.format.isWebp) {
      content = NativeWebpPlayer(
        title: widget.image.displayName,
        sourceUri: widget.sourceUri,
        loadBytes: (_) async => bytes,
        showEngineControls: false,
        showStatus: false,
        initialEngine: WebpPlayerEngine.flutter,
        onPreviewStateChanged: _onWebpState,
        onFirstFrame: _reportFirstFrame,
        downloadIdentity: widget.downloadIdentity,
        traceClock: widget.traceClock,
        traceSink: widget.traceSink,
        traceSessionId: widget.traceSessionId,
        demandRevision: widget.demandRevision,
        playback: widget.playback,
      );
    } else if (widget.playback != null &&
        widget.image.format == LocalImageFormat.gif) {
      content = _ControlledAnimatedImage(
        bytes: bytes,
        playback: widget.playback!,
        onReady: _onControlledReady,
        onError: _onControlledError,
        downloadIdentity: widget.downloadIdentity,
        traceClock: widget.traceClock,
        traceSink: widget.traceSink,
        traceSessionId: widget.traceSessionId,
        demandRevision: widget.demandRevision,
      );
    } else {
      content = Center(
        child: Image(
          image: imageProvider!,
          key: imageFolderFlutterPreviewKey,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stackTrace) {
            _scheduleError(error);
            return const SizedBox.shrink();
          },
        ),
      );
    }
    final keyed = switch (_state.phase) {
      ImagePreviewPhase.loading => KeyedSubtree(
          key: imageFolderPreviewLoadingKey,
          child: content,
        ),
      ImagePreviewPhase.ready => KeyedSubtree(
          key: imageFolderPreviewReadyKey,
          child: content,
        ),
      ImagePreviewPhase.invalid => content,
    };
    return ImagePreviewStateRegion(
      key: imageFolderPreviewStateKey,
      state: _state,
      child: keyed,
    );
  }
}

final class _ControlledAnimatedImage extends StatefulWidget {
  const _ControlledAnimatedImage({
    required this.bytes,
    required this.playback,
    required this.onReady,
    required this.onError,
    this.targetWidth,
    this.targetHeight,
    this.downloadIdentity,
    this.traceClock,
    this.traceSink = const NoopTraceSink(),
    this.traceSessionId = 'flutter-animated-image',
    this.demandRevision,
    super.key,
  });

  final Uint8List bytes;
  final ReaderPlaybackController playback;
  final int? targetWidth;
  final int? targetHeight;
  final DownloadId? downloadIdentity;
  final MonoClock? traceClock;
  final TraceSink traceSink;
  final String traceSessionId;
  final int Function()? demandRevision;
  final VoidCallback onReady;
  final ValueChanged<Object> onError;

  @override
  State<_ControlledAnimatedImage> createState() =>
      _ControlledAnimatedImageState();
}

final class _ControlledAnimatedImageState
    extends State<_ControlledAnimatedImage> {
  ui.Codec? _codec;
  ui.Image? _image;
  Timer? _timer;
  Duration _remaining = Duration.zero;
  Duration _sourceDuration = Duration.zero;
  Stopwatch? _timerClock;
  int _framesPresented = 0;
  late double _playbackSpeed;
  late bool _paused;
  late final MonoClock _traceClock;
  int? _workRevision;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final playback = widget.playback.value;
    _playbackSpeed = playback.speed;
    _paused = playback.paused;
    _traceClock = widget.traceClock ?? SystemClock();
    widget.playback.addListener(_handlePlaybackChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _ControlledAnimatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_handlePlaybackChanged);
      final playback = widget.playback.value;
      _playbackSpeed = playback.speed;
      _paused = playback.paused;
      widget.playback.addListener(_handlePlaybackChanged);
    }
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.targetWidth != widget.targetWidth ||
        oldWidget.targetHeight != widget.targetHeight) {
      unawaited(
        _reload(
          preservePresentedFrame: identical(oldWidget.bytes, widget.bytes),
        ),
      );
    }
  }

  Future<void> _reload({required bool preservePresentedFrame}) async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _timerClock = null;
    final oldCodec = _codec;
    _codec = null;
    oldCodec?.dispose();
    if (!preservePresentedFrame) {
      final oldImage = _image;
      if (mounted) {
        setState(() => _image = null);
      } else {
        _image = null;
      }
      if (oldImage != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => oldImage.dispose());
      }
    }
    _framesPresented = 0;
    await _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final workRevision = widget.demandRevision?.call();
    _workRevision = workRevision;
    _recordTrace(
      TraceEventKind.decodeStarted,
      revision: workRevision,
      payload: <String, Object?>{
        'engine': 'flutter-codec',
        'stage': 'instantiate',
        if (widget.targetWidth != null) 'targetWidth': widget.targetWidth,
        if (widget.targetHeight != null) 'targetHeight': widget.targetHeight,
      },
    );
    try {
      final codec = await ui.instantiateImageCodec(
        widget.bytes,
        targetWidth: widget.targetWidth,
        targetHeight: widget.targetHeight,
        allowUpscaling: false,
      );
      if (!mounted || generation != _generation) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _presentNext(generation, workRevision);
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        widget.onError(error);
      }
    }
  }

  Future<void> _presentNext(int generation, [int? workRevision]) async {
    final codec = _codec;
    if (codec == null || !mounted || generation != _generation) {
      return;
    }
    final totalPresentations = codec.repetitionCount < 0
        ? null
        : codec.frameCount * (codec.repetitionCount + 1);
    if (totalPresentations != null && _framesPresented >= totalPresentations) {
      return;
    }
    try {
      final frame = await codec.getNextFrame();
      if (!mounted || generation != _generation) {
        frame.image.dispose();
        return;
      }
      final revision = workRevision ?? _workRevision;
      _recordTrace(
        TraceEventKind.frameDecoded,
        revision: revision,
        image: frame.image,
        payload: <String, Object?>{
          'engine': 'flutter-codec',
          'frameIndex': _framesPresented,
          'frameDurationMicros': frame.duration.inMicroseconds,
        },
      );
      final previous = _image;
      _sourceDuration = frame.duration <= Duration.zero
          ? const Duration(milliseconds: 100)
          : frame.duration;
      _remaining = _scaledDuration(_sourceDuration);
      setState(() => _image = frame.image);
      _framesPresented++;
      final presentedFrameIndex = _framesPresented - 1;
      final presentedIdentity = _traceIdentity(frame.image);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation) {
          return;
        }
        _recordTrace(
          TraceEventKind.framePresented,
          revision: revision,
          identityHash: presentedIdentity,
          payload: <String, Object?>{
            'engine': 'flutter-codec',
            'frameIndex': presentedFrameIndex,
          },
        );
        if (presentedFrameIndex == 0) {
          widget.onReady();
        }
      });
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
      if (codec.frameCount > 1 && !_paused) {
        _schedule(generation, _remaining);
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        widget.onError(error);
      }
    }
  }

  String? _traceIdentity(ui.Image? image) {
    final download = widget.downloadIdentity;
    if (download == null) {
      return null;
    }
    final width = image?.width ?? widget.targetWidth ?? 1;
    final height = image?.height ?? widget.targetHeight ?? 1;
    return DecodeId(
      download: download,
      physicalWidth: width,
      physicalHeight: height,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    ).key;
  }

  void _recordTrace(
    TraceEventKind kind, {
    int? revision,
    ui.Image? image,
    String? identityHash,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    final identity = identityHash ?? _traceIdentity(image);
    if (identity == null) {
      return;
    }
    widget.traceSink.record(
      traceEvent(
        clock: _traceClock,
        sessionId: widget.traceSessionId,
        kind: kind,
        identityHash: identity,
        revision: revision,
        payload: payload,
      ),
    );
  }

  Duration _scaledDuration(Duration source) {
    final micros = math.max(
      1000,
      (source.inMicroseconds / _playbackSpeed).round(),
    ).toInt();
    return Duration(microseconds: micros);
  }

  void _schedule(int generation, Duration delay) {
    _timer?.cancel();
    _remaining = delay;
    _timerClock = Stopwatch()..start();
    _timer = Timer(delay, () {
      _timer = null;
      _timerClock = null;
      unawaited(_presentNext(generation, _workRevision));
    });
  }

  void _handlePlaybackChanged() {
    final codec = _codec;
    if (!mounted || codec == null || codec.frameCount <= 1) {
      return;
    }
    final playback = widget.playback.value;
    final oldSpeed = _playbackSpeed;
    final wasPaused = _paused;
    var remaining = _remaining;
    final clock = _timerClock;
    final hadTimer = _timer != null;
    if (hadTimer && clock != null) {
      final next = remaining - clock.elapsed;
      remaining = next.isNegative ? Duration.zero : next;
    }
    if (oldSpeed != playback.speed) {
      remaining = Duration(
        microseconds: math.max(
          0,
          (remaining.inMicroseconds * oldSpeed / playback.speed).round(),
        ).toInt(),
      );
    }
    _timer?.cancel();
    _timer = null;
    _timerClock = null;
    _playbackSpeed = playback.speed;
    _paused = playback.paused;
    _remaining = remaining;
    if (!_paused && (hadTimer || wasPaused)) {
      _schedule(_generation, _remaining);
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.playback.removeListener(_handlePlaybackChanged);
    _timer?.cancel();
    _codec?.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return RawImage(
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}

ImportedChapterRecord imageFolderChapterRecord(
  PickedImageFolder folder, {
  ReadingDirection readingDirection = ReadingDirection.ltr,
  DateTime? importedAt,
}) {
  return ImportedChapterRecord.folder(
    directoryId: folder.directoryPath,
    displayName: folder.displayName,
    readingDirection: readingDirection,
    importedAt: importedAt,
    pages: folder.files
        .map(
          (image) => ImportedPageRecord(
            displayName: image.displayName,
            sourceId: image.sourceId,
            contentKindHint: _contentKindHint(image.format),
            mediaFormat: image.format.name,
            byteLength: image.byteLength,
            animatedHint: image.format == LocalImageFormat.webp ||
                image.format == LocalImageFormat.gif,
          ),
        )
        .toList(growable: false),
  );
}

ContentKindHint _contentKindHint(LocalImageFormat format) => switch (format) {
      LocalImageFormat.jpeg => ContentKindHint.jpeg,
      LocalImageFormat.png => ContentKindHint.png,
      LocalImageFormat.gif => ContentKindHint.gif,
      LocalImageFormat.webp => ContentKindHint.webp,
      LocalImageFormat.avif => ContentKindHint.avif,
      LocalImageFormat.bmp ||
      LocalImageFormat.tiff ||
      LocalImageFormat.ico ||
      LocalImageFormat.heif => ContentKindHint.fallback,
    };

final class ImageFolderScreen extends StatelessWidget {
  const ImageFolderScreen({
    required this.folder,
    this.bytesLoader,
    this.onPreviewStateChanged,
    this.initialProgress,
    this.onProgressChanged,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    super.key,
  });

  final PickedImageFolder folder;
  final LocalImageBytesLoader? bytesLoader;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;

  @override
  Widget build(BuildContext context) {
    final record = imageFolderChapterRecord(folder);
    return ImportedImageChapterScreen(
      record: record,
      byteLoaders: <String, LocalImageFileBytesLoader>{
        for (final image in folder.files)
          image.sourceId: () => bytesLoader == null
              ? image.readAsBytes()
              : bytesLoader!(image),
      },
      onPreviewStateChanged: onPreviewStateChanged,
      initialProgress: initialProgress,
      onProgressChanged: onProgressChanged,
      initialFavorite: initialFavorite,
      onFavoriteChanged: onFavoriteChanged,
      onDownloadRequested: onDownloadRequested,
    );
  }
}

final class ImportedImageChapterScreen extends StatelessWidget {
  const ImportedImageChapterScreen({
    required this.record,
    this.byteLoaders = const <String, LocalImageFileBytesLoader>{},
    this.onPreviewStateChanged,
    this.initialProgress,
    this.onProgressChanged,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    this.artifactCache,
    super.key,
  });

  final ImportedChapterRecord record;
  final Map<String, LocalImageFileBytesLoader> byteLoaders;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final ArtifactCacheStore? artifactCache;

  @override
  Widget build(BuildContext context) {
    final chapter = record.toManifest();
    final sources = <Uri, LoaderTransportSource>{};
    for (var index = 0; index < record.pages.length; index++) {
      final page = record.pages[index];
      final uri = chapter.pages[index].uri;
      final loader = byteLoaders[page.sourceId];
      if (loader != null || !_isRemoteMediaUri(uri)) {
        sources[uri] = LoaderTransportSource(
          revision: '${record.sourceRevision}:$index',
          loadBytes: loader ?? () => readLocalImageSource(page.sourceId),
        );
      }
    }

    return ReaderRuntimeScreen(
      key: ValueKey<Object>(
        (record.chapterId, record.sourceRevision, byteLoaders.length),
      ),
      screenKey: imageFolderScreenKey,
      chapter: chapter,
      loaderSources: sources,
      artifactCache: artifactCache,
      initialProgress: initialProgress,
      onProgressChanged: onProgressChanged,
      initialFavorite: initialFavorite,
      onFavoriteChanged: onFavoriteChanged,
      onDownloadRequested: onDownloadRequested,
      appBarTitleBuilder: (context, chapter, currentIndex) {
        final current = record.pages[currentIndex];
        final format = _importedPageFormat(current);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(record.displayName, key: imageFolderTitleKey),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${current.displayName} · ${format.label}',
                    key: imageFolderCurrentFileKey,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${currentIndex + 1} / ${record.pages.length}',
                  key: imageFolderPositionKey,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        );
      },
      appBarActionsBuilder: (context, reader) => <Widget>[
        IconButton(
          key: imageFolderPreviousKey,
          tooltip: '上一张图片',
          onPressed: reader.currentIndex == 0
              ? null
              : () => reader.requestPage(reader.currentIndex - 1),
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          key: imageFolderNextKey,
          tooltip: '下一张图片',
          onPressed: reader.currentIndex + 1 >= record.pages.length
              ? null
              : () => reader.requestPage(reader.currentIndex + 1),
          icon: const Icon(Icons.chevron_right),
        ),
        PopupMenuButton<int>(
          key: imageFolderFileMenuKey,
          tooltip: '选择图片',
          initialValue: reader.currentIndex,
          onSelected: reader.requestPage,
          itemBuilder: (context) => <PopupMenuEntry<int>>[
            for (var index = 0; index < record.pages.length; index++)
              PopupMenuItem<int>(
                value: index,
                child: Text(
                  '${record.pages[index].displayName} · '
                  '${_importedPageFormat(record.pages[index]).label}',
                ),
              ),
          ],
        ),
      ],
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
            tokenBytesLoader: (_, token) => runtime.loadBytes(token),
            onPreviewStateChanged: onPreviewStateChanged,
            onFirstFrame: reportFirstFrame,
            downloadIdentity: readerPageDownloadId(runtime.chapter, asset),
            traceClock: runtime.clock,
            traceSink: runtime.traceSink,
            traceSessionId: runtime.sessionId,
            demandRevision: runtime.demandRevision,
            playback: runtime.playback,
          ),
        );
      },
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

@Deprecated('Use ImageFolderScreen')
final class WebpFolderScreen extends StatelessWidget {
  const WebpFolderScreen({
    required this.folder,
    this.bytesLoader,
    this.onPreviewStateChanged,
    this.initialProgress,
    this.onProgressChanged,
    super.key,
  });

  final PickedImageFolder folder;
  final LocalImageBytesLoader? bytesLoader;
  final ImagePreviewStateChanged? onPreviewStateChanged;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;

  @override
  Widget build(BuildContext context) => ImageFolderScreen(
        folder: folder,
        bytesLoader: bytesLoader,
        onPreviewStateChanged: onPreviewStateChanged,
        initialProgress: initialProgress,
        onProgressChanged: onProgressChanged,
      );
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

enum WebpPlayerEngine { native, flutter }

final class NativeWebpPlayer extends StatefulWidget {
  const NativeWebpPlayer({
    required this.title,
    required this.sourceUri,
    required this.loadBytes,
    this.showEngineControls = true,
    this.showStatus = true,
    this.onFirstFrame,
    this.traceSink = const NoopTraceSink(),
    this.traceClock,
    this.traceSessionId = 'webp-preview',
    this.demandRevision,
    this.downloadIdentity,
    this.initialEngine = WebpPlayerEngine.flutter,
    this.onPreviewStateChanged,
    this.playback,
    super.key,
  });

  final String title;
  final Uri sourceUri;
  final WebpBytesLoader loadBytes;
  final bool showEngineControls;
  final bool showStatus;
  final VoidCallback? onFirstFrame;
  final TraceSink traceSink;
  final MonoClock? traceClock;
  final String traceSessionId;
  final int Function()? demandRevision;
  final DownloadId? downloadIdentity;
  final WebpPlayerEngine initialEngine;
  final WebpPreviewStateChanged? onPreviewStateChanged;
  final ReaderPlaybackController? playback;

  @override
  State<NativeWebpPlayer> createState() => _NativeWebpPlayerState();
}

final class _NativeWebpPlayerState extends State<NativeWebpPlayer> {
  static const _textureUploadBudget = Duration(microseconds: 16667);

  late WebpPlayerEngine _engine;
  Uint8List? _encoded;
  WebpInfo? _sourceCanvas;
  DecodeTarget? _target;
  DecodeTarget? _scheduledTarget;
  RasterPlan? _raster;
  RasterPlan? _scheduledRaster;
  ui.Image? _image;
  late final AndroidTexturePresenter _texturePresenter;
  late final MonoClock _traceClock;
  AndroidTextureLease? _texture;
  int? _textureId;
  TexturePresentTelemetry? _lastTexturePresent;
  TextureFallbackTelemetry? _lastTextureFallback;
  DecodeId? _decodeId;
  int? _nativeEpoch;
  EncodedSource? _source;
  CursorBinding? _cursor;
  _PreparedNativeFrame? _pending;
  Timer? _timer;
  Stopwatch? _frameClock;
  Stopwatch? _timerClock;
  Duration _pendingDelay = Duration.zero;
  Object? _nativeError;
  Object? _loadError;
  WebpPreviewState _previewState = const WebpPreviewState.loading();
  String _status = '加载中';
  int _frameIndex = -1;
  int _cycle = 0;
  bool _paused = false;
  double _playbackSpeed = 1;
  bool _preparing = false;
  bool _completionPending = false;
  int _generation = 0;
  bool _reportedFirstFrame = false;
  late final WebpLoadToken _loadToken;

  @override
  void initState() {
    super.initState();
    _loadToken = WebpLoadToken();
    _engine = widget.initialEngine;
    _playbackSpeed = widget.playback?.value.speed ?? 1;
    _paused = widget.playback?.value.paused ?? false;
    widget.playback?.addListener(_handleExternalPlayback);
    _traceClock = widget.traceClock ?? SystemClock();
    _texturePresenter = AndroidTexturePresenter(
      telemetrySink: _recordTextureTelemetry,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _notifyPreviewObserver(_previewState);
      }
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant NativeWebpPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback?.removeListener(_handleExternalPlayback);
      widget.playback?.addListener(_handleExternalPlayback);
      _playbackSpeed = widget.playback?.value.speed ?? 1;
      _setPaused(widget.playback?.value.paused ?? false, notify: false);
    }
  }

  Duration _scaledPlaybackDuration(Duration source) {
    final micros = math.max(
      1000,
      (source.inMicroseconds / _playbackSpeed).round(),
    ).toInt();
    return Duration(microseconds: micros);
  }

  void _handleExternalPlayback() {
    final state = widget.playback?.value;
    if (state == null) {
      return;
    }
    final oldSpeed = _playbackSpeed;
    _playbackSpeed = state.speed;
    final pacingPending =
        _timer != null || _pending != null || _completionPending;
    if (oldSpeed != _playbackSpeed && pacingPending) {
      final elapsed = _timerClock?.elapsed ?? Duration.zero;
      final remaining = _pendingDelay - elapsed;
      final safeRemaining = remaining.isNegative ? Duration.zero : remaining;
      _pendingDelay = Duration(
        microseconds: math.max(
          0,
          (safeRemaining.inMicroseconds * oldSpeed / _playbackSpeed).round(),
        ).toInt(),
      );
      _timer?.cancel();
      _timer = null;
      _timerClock = null;
      if (!state.paused) {
        if (_pending != null) {
          _schedulePending(_generation);
        } else if (_completionPending) {
          _scheduleCompletion(_generation);
        }
      }
    }
    _setPaused(state.paused);
  }

  void _recordTextureTelemetry(TextureTelemetry event) {
    final context = event.context;
    switch (event) {
      case TexturePresentTelemetry():
        _recordTrace(
          TraceEventKind.frameUploaded,
          sessionId: context.sessionId,
          identityHash: context.decodeIdentity,
          revision: context.demandRevision,
          epoch: context.epoch,
          payload: <String, Object?>{
            'frame': event.frameIndex,
            'queueMicros': event.queueMicros,
            'uploadMicros': event.uploadMicros,
            'deadlineMissMicros': event.deadlineMissMicros,
            'frameBytes': event.frameBytes,
            'textureBytes': event.textureBytes,
            'inFlightBytes': event.inFlightBytes,
            'renderer': RendererKind.androidTexture.name,
          },
        );
      case TextureFallbackTelemetry():
        _recordTrace(
          TraceEventKind.taskFailed,
          sessionId: context.sessionId,
          identityHash: context.decodeIdentity,
          revision: context.demandRevision,
          epoch: context.epoch,
          payload: <String, Object?>{
            'lane': 'texture',
            'reason': event.reason,
          },
        );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      switch (event) {
        case TexturePresentTelemetry():
          _lastTexturePresent = event;
          _lastTextureFallback = null;
        case TextureFallbackTelemetry():
          _lastTextureFallback = event;
      }
    });
  }

  void _recordTrace(
    TraceEventKind kind, {
    String? sessionId,
    String? identityHash,
    int? revision,
    int? epoch,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      traceEvent(
        clock: _traceClock,
        sessionId: sessionId ?? widget.traceSessionId,
        kind: kind,
        identityHash: identityHash ?? _decodeId?.key,
        revision: revision ?? widget.demandRevision?.call(),
        epoch: epoch ?? _nativeEpoch,
        payload: payload,
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    widget.playback?.removeListener(_handleExternalPlayback);
    _loadToken.cancel();
    _resetNative(disposeImage: true);
    super.dispose();
  }

  void _notifyPreviewObserver(WebpPreviewState state) {
    try {
      widget.onPreviewStateChanged?.call(state);
    } on Object catch (error) {
      debugPrint('preview state observer failed: $error');
    }
  }

  void _publishPreviewState(WebpPreviewState state) {
    _previewState = state;
    _notifyPreviewObserver(state);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final token = _loadToken;
    try {
      final bytes = await widget.loadBytes(token);
      token.throwIfCancelled();
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      final canvas = parseWebpInfo(bytes);
      setState(() {
        _encoded = bytes;
        _sourceCanvas = canvas;
        _loadError = null;
        _publishPreviewState(WebpPreviewState.ready(canvas));
        _status = '已读取 ${bytes.length} B，等待 viewport';
      });
      final target = _target;
      if (target != null && _engine == WebpPlayerEngine.native) {
        await _startNative(++_generation);
      }
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _resetNative(disposeImage: true);
      setState(() {
        _encoded = null;
        _sourceCanvas = null;
        _loadError = error;
        _publishPreviewState(WebpPreviewState.invalid(error));
        _nativeError = null;
        _engine = WebpPlayerEngine.flutter;
        _status = '加载失败';
      });
    }
  }

  void _scheduleTarget(DecodeTarget target, RasterPlan raster) {
    if ((_target == target && _raster == raster) ||
        (_scheduledTarget == target && _scheduledRaster == raster)) {
      return;
    }
    _scheduledTarget = target;
    _scheduledRaster = raster;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _scheduledTarget != target ||
          _scheduledRaster != raster) {
        return;
      }
      _scheduledTarget = null;
      _scheduledRaster = null;
      final decodeChanged = _raster?.decodeWidth != raster.decodeWidth ||
          _raster?.decodeHeight != raster.decodeHeight;
      setState(() {
        _target = target;
        _raster = raster;
        _status = _engine == WebpPlayerEngine.native
            ? decodeChanged
                ? '重建 native decode target'
                : 'native display target 已更新'
            : 'Flutter codec · ${raster.decodeWidth}×${raster.decodeHeight}';
      });
      if (decodeChanged &&
          _encoded != null &&
          _engine == WebpPlayerEngine.native) {
        unawaited(_startNative(++_generation));
      }
    });
  }

  Future<void> _startNative(int generation) async {
    final token = _loadToken;
    final bytes = _encoded;
    final target = _target;
    final raster = _raster;
    if (!mounted ||
        generation != _generation ||
        bytes == null ||
        target == null ||
        raster == null ||
        _engine != WebpPlayerEngine.native) {
      return;
    }
    _resetNative(disposeImage: true);
    _lastTexturePresent = null;
    _lastTextureFallback = null;
    _nativeError = null;
    _frameIndex = -1;
    _cycle = 0;

    EncodedSource? pendingSource;
    CursorBinding? pendingCursor;
    AndroidTextureLease? pendingTexture;
    try {
      final version = NativeVersion.load();
      if (!version.usesPinnedWebp) {
        throw StateError(
          'native runtime 未链接锁定的 libwebp 1.6.0 '
          '(decoder=0x${version.webpDecoderVersion.toRadixString(16)}, '
          'demux=0x${version.webpDemuxVersion.toRadixString(16)})',
        );
      }
      final epoch = generation;
      final source = const NativeSourceFactory().create(
        epoch: epoch,
        maxBytes: bytes.length,
      );
      pendingSource = source;
      final append = source.append(epoch: epoch, offset: 0, bytes: bytes);
      if (append != SourceStatus.ok) {
        throw StateError('native source append failed: ${append.name}');
      }
      final seal = source.seal(epoch);
      if (seal != SourceStatus.ok) {
        throw StateError('native source seal failed: ${seal.name}');
      }
      final id = DecodeId(
        download: widget.downloadIdentity ??
            DownloadId(
              content: ContentId(
                sourceId: 'demo',
                comicId: 'animated-webp',
                chapterId: 'preview',
                pageId: widget.title,
              ),
              sourceRevision: 'local-v1',
              canonicalUri: widget.sourceUri,
            ),
        physicalWidth: raster.decodeWidth,
        physicalHeight: raster.decodeHeight,
        pixelFormat: PixelFormat.rgba8888,
        renderer: AndroidTexturePresenter.isSupported
            ? RendererKind.androidTexture
            : RendererKind.flutterImage,
      );
      final cursor = const NativeCursorFactory().create(
        id: id,
        source: source,
        epoch: epoch,
      );
      pendingCursor = cursor;
      if (AndroidTexturePresenter.isSupported) {
        pendingTexture = await _texturePresenter.create(
          width: raster.decodeWidth,
          height: raster.decodeHeight,
        );
      }
      token.throwIfCancelled();
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }

      _source = source;
      _cursor = cursor;
      _decodeId = id;
      _nativeEpoch = epoch;
      _texture = pendingTexture;
      _textureId = pendingTexture?.textureId;
      pendingSource = null;
      pendingCursor = null;
      pendingTexture = null;
      setState(() {
        _status = _texture == null
            ? 'native image · ${raster.decodeWidth}×${raster.decodeHeight}'
            : 'native texture · ${raster.decodeWidth}×${raster.decodeHeight}';
      });
      final first = await _decodePrepared(generation);
      if (first == null) {
        if (mounted && generation == _generation) {
          setState(() => _status = '播放完成');
        }
        return;
      }
      await _presentPrepared(first, generation);
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _recordTrace(
        TraceEventKind.taskFailed,
        identityHash: _decodeId?.key ?? widget.sourceUri.toString(),
        revision: widget.demandRevision?.call(),
        epoch: _nativeEpoch ?? generation,
        payload: <String, Object?>{
          'lane': 'native-start',
          'reason': error.toString(),
          'fallback': RendererKind.flutterImage.name,
        },
      );
      _resetNative(disposeImage: true);
      setState(() {
        _nativeError = error;
        _engine = WebpPlayerEngine.flutter;
        _status = 'native 不可用，已回退 Flutter codec';
      });
    } finally {
      pendingCursor?.frames.dispose();
      pendingSource?.dispose();
      final texture = pendingTexture;
      if (texture != null) {
        try {
          await texture.release();
        } catch (_) {
          // The untransferred texture is already unreachable; best-effort release.
        }
      }
    }
  }

  Future<_PreparedNativeFrame?> _decodePrepared(int generation) async {
    final binding = _cursor;
    if (binding == null) {
      return null;
    }
    while (mounted && generation == _generation) {
      final decodeClock = Stopwatch()..start();
      final step = await binding.frames.decodeNext();
      final decodeMicros = decodeClock.elapsedMicroseconds;
      if (!mounted || generation != _generation) {
        step.frame?.dispose();
        return null;
      }
      switch (step.kind) {
        case CursorStepKind.frame:
          final frame = step.frame;
          if (frame is! PixelFrame) {
            frame?.dispose();
            throw StateError('native cursor returned a non-pixel frame');
          }
          final duration = frame.duration > Duration.zero
              ? frame.duration
              : const Duration(milliseconds: 100);
          final index = frame.index;
          final cycle = binding.loop?.cycle ?? 0;
          if (_texture != null) {
            if (frame is! NativeFrame) {
              frame.dispose();
              throw StateError('Android texture requires a native frame owner');
            }
            final prepared = _PreparedTextureFrame(
              frame: NativeTextureFrameOwner(frame),
              duration: duration,
              index: index,
              cycle: cycle,
              frameBytes: frame.byteLength,
              decodeMicros: decodeMicros,
              prepareMicros: 0,
            );
            _recordDecoded(prepared, RendererKind.androidTexture);
            return prepared;
          }
          final frameBytes = frame.byteLength;
          final prepareClock = Stopwatch()..start();
          final rgba = frame.copyBytes();
          _premultiplyRgbaInPlace(rgba);
          late final ui.Image image;
          try {
            image = await _decodeRgba(rgba, frame.width, frame.height);
          } finally {
            frame.dispose();
          }
          final prepared = _PreparedImageFrame(
            image: image,
            duration: duration,
            index: index,
            cycle: cycle,
            frameBytes: frameBytes,
            decodeMicros: decodeMicros,
            prepareMicros: prepareClock.elapsedMicroseconds,
          );
          _recordDecoded(prepared, RendererKind.flutterImage);
          return prepared;
        case CursorStepKind.needMoreData:
          throw StateError('sealed WebP unexpectedly needs more data');
        case CursorStepKind.end:
          final loop = binding.loop;
          if (loop != null && loop.rewind()) {
            continue;
          }
          return null;
      }
    }
    return null;
  }

  void _recordDecoded(
    _PreparedNativeFrame prepared,
    RendererKind renderer,
  ) {
    _recordTrace(
      TraceEventKind.frameDecoded,
      payload: <String, Object?>{
        'frame': prepared.index,
        'cycle': prepared.cycle,
        'frameBytes': prepared.frameBytes,
        'decodeMicros': prepared.decodeMicros,
        'prepareMicros': prepared.prepareMicros,
        'renderer': renderer.name,
      },
    );
  }

  Future<void> _presentPrepared(
    _PreparedNativeFrame prepared,
    int generation,
  ) async {
    if (!mounted || generation != _generation || _paused) {
      if (!mounted || generation != _generation) {
        prepared.dispose();
      } else {
        _pending?.dispose();
        _pending = prepared;
        _pendingDelay = Duration.zero;
      }
      return;
    }
    _timer?.cancel();
    _timer = null;
    _timerClock = null;
    _pending = null;
    _pendingDelay = Duration.zero;

    switch (prepared) {
      case _PreparedTextureFrame():
        final texture = _texture;
        final frame = prepared.takeFrame();
        if (texture == null || frame == null) {
          frame?.dispose();
          throw StateError('native texture ownership was lost before present');
        }
        try {
          await texture.present(
            frame,
            deadlineAfterMicros: _textureUploadBudget.inMicroseconds,
            context: TextureTelemetryContext(
              sessionId: widget.traceSessionId,
              decodeIdentity: _decodeId?.key,
              demandRevision: widget.demandRevision?.call(),
              epoch: _nativeEpoch,
            ),
          );
        } finally {
          frame.dispose();
        }
        if (!mounted || generation != _generation) {
          return;
        }
        final previous = _image;
        setState(() {
          _image = null;
          _textureId = texture.textureId;
          _frameIndex = prepared.index;
          _cycle = prepared.cycle;
          _status = 'native texture · frame ${prepared.index} · '
              'cycle ${prepared.cycle}';
        });
        previous?.dispose();
        _reportFirstFrame();
      case _PreparedImageFrame():
        final image = prepared.takeImage();
        if (image == null) {
          throw StateError('native image ownership was lost before present');
        }
        final previous = _image;
        setState(() {
          _image = image;
          _textureId = null;
          _frameIndex = prepared.index;
          _cycle = prepared.cycle;
          _status = 'native image · frame ${prepared.index} · '
              'cycle ${prepared.cycle}';
        });
        previous?.dispose();
        _reportFirstFrame();
    }

    _recordTrace(
      TraceEventKind.framePresented,
      payload: <String, Object?>{
        'frame': prepared.index,
        'cycle': prepared.cycle,
        'frameBytes': prepared.frameBytes,
        'decodeMicros': prepared.decodeMicros,
        'prepareMicros': prepared.prepareMicros,
        'renderer': prepared is _PreparedTextureFrame
            ? RendererKind.androidTexture.name
            : RendererKind.flutterImage.name,
      },
    );

    final clock = Stopwatch()..start();
    _frameClock = clock;
    _preparing = true;
    unawaited(_prepareFollowing(generation, prepared.duration, clock));
  }

  Future<void> _prepareFollowing(
    int generation,
    Duration currentDuration,
    Stopwatch clock,
  ) async {
    final token = _loadToken;
    try {
      final next = await _decodePrepared(generation);
      token.throwIfCancelled();
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        next?.dispose();
        return;
      }
      final remaining = FramePacing.remaining(
        frameDuration: _scaledPlaybackDuration(currentDuration),
        preparationElapsed: clock.elapsed,
      );
      if (next == null) {
        _completionPending = true;
        _pendingDelay = remaining;
        _scheduleCompletion(generation);
        return;
      }
      _pending?.dispose();
      _pending = next;
      _pendingDelay = remaining;
      if (!_paused) {
        _schedulePending(generation);
      }
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _recordTrace(
        TraceEventKind.taskFailed,
        payload: <String, Object?>{
          'lane': 'decode',
          'reason': error.toString(),
          'fallback': RendererKind.flutterImage.name,
        },
      );
      final oldImage = _image;
      _image = null;
      oldImage?.dispose();
      setState(() {
        _nativeError = error;
        _engine = WebpPlayerEngine.flutter;
        _status = 'native 解码失败，已回退 Flutter codec';
      });
      _resetNative(disposeImage: false);
    } finally {
      if (generation == _generation) {
        _preparing = false;
      }
    }
  }

  void _fallbackFromNative(Object error, int generation) {
    if (!mounted || generation != _generation) {
      return;
    }
    if (_lastTextureFallback == null) {
      _recordTrace(
        TraceEventKind.taskFailed,
        payload: <String, Object?>{
          'lane': 'present',
          'reason': error.toString(),
          'fallback': RendererKind.flutterImage.name,
        },
      );
    }
    final oldImage = _image;
    _image = null;
    oldImage?.dispose();
    setState(() {
      _nativeError = error;
      _engine = WebpPlayerEngine.flutter;
      _status = 'native present 失败，已回退 Flutter codec';
    });
    _resetNative(disposeImage: false);
  }

  void _schedulePending(int generation) {
    final pending = _pending;
    if (pending == null || _paused || generation != _generation) {
      return;
    }
    _timer?.cancel();
    final clock = Stopwatch()..start();
    _timerClock = clock;
    _timer = Timer(_pendingDelay, () {
      _timer = null;
      _timerClock = null;
      final next = _pending;
      _pending = null;
      _pendingDelay = Duration.zero;
      if (next != null) {
        unawaited(
          _presentPrepared(next, generation)
              .catchError((Object error, StackTrace stackTrace) {
            _fallbackFromNative(error, generation);
          }),
        );
      }
    });
  }

  void _scheduleCompletion(int generation) {
    if (_paused || generation != _generation) {
      return;
    }
    _timer?.cancel();
    final clock = Stopwatch()..start();
    _timerClock = clock;
    _timer = Timer(_pendingDelay, () {
      _timer = null;
      _timerClock = null;
      _pendingDelay = Duration.zero;
      _completionPending = false;
      if (mounted && generation == _generation) {
        setState(() => _status = '播放完成');
      }
    });
  }

  void _resetNative({required bool disposeImage}) {
    _timer?.cancel();
    _timer = null;
    _timerClock = null;
    _frameClock = null;
    _preparing = false;
    _completionPending = false;
    _pendingDelay = Duration.zero;
    _pending?.dispose();
    _pending = null;
    _cursor?.frames.dispose();
    _cursor = null;
    _source?.dispose();
    _source = null;
    _decodeId = null;
    _nativeEpoch = null;
    final texture = _texture;
    _texture = null;
    _textureId = null;
    _lastTexturePresent = null;
    if (texture != null) {
      unawaited(texture.release().catchError((Object _) {}));
    }
    if (disposeImage) {
      _image?.dispose();
      _image = null;
    }
  }

  void _reportFirstFrame() {
    if (_reportedFirstFrame) {
      return;
    }
    _reportedFirstFrame = true;
    widget.onFirstFrame?.call();
  }

  Future<void> _requestEngine(Set<WebpPlayerEngine> selection) async {
    final engine = selection.single;
    if (engine != WebpPlayerEngine.native) {
      _setEngine(engine);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: webpNativeConfirmDialogKey,
        title: const Text('启用实验 native 管线？'),
        content: const Text(
          '普通预览默认使用 Flutter codec。native texture 仅用于显式诊断，'
          '可能因设备、ABI 或本地库状态回退。',
        ),
        actions: <Widget>[
          TextButton(
            key: webpNativeCancelKey,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: webpNativeConfirmKey,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续实验'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }
    _setEngine(WebpPlayerEngine.native);
  }

  void _setEngine(WebpPlayerEngine engine) {
    if (engine == _engine) {
      return;
    }
    final generation = ++_generation;
    _resetNative(disposeImage: true);
    setState(() {
      _engine = engine;
      _paused = widget.playback?.value.paused ?? false;
      _lastTexturePresent = null;
      _lastTextureFallback = null;
      _nativeError = null;
      final target = _target;
      _status = engine == WebpPlayerEngine.native
          ? '启动 native'
          : target == null
              ? 'Flutter codec'
              : 'Flutter codec · '
                  '${target.physicalWidth}×${target.physicalHeight}';
    });
    if (engine == WebpPlayerEngine.native) {
      unawaited(_startNative(generation));
    }
  }

  void _togglePause() {
    final playback = widget.playback;
    if (playback != null) {
      playback.togglePaused();
      return;
    }
    if (_engine == WebpPlayerEngine.native) {
      _setPaused(!_paused);
    }
  }

  void _setPaused(bool pausing, {bool notify = true}) {
    if (_paused == pausing) {
      return;
    }
    if (notify && mounted) {
      setState(() => _paused = pausing);
    } else {
      _paused = pausing;
    }
    if (pausing) {
      _frameClock?.stop();
      final timerClock = _timerClock;
      if (_timer != null && timerClock != null) {
        final remaining = _pendingDelay - timerClock.elapsed;
        _pendingDelay = remaining.isNegative ? Duration.zero : remaining;
      }
      _timer?.cancel();
      _timer = null;
      _timerClock = null;
      return;
    }

    _frameClock?.start();
    if (_pending != null) {
      _schedulePending(_generation);
    } else if (_completionPending) {
      _scheduleCompletion(_generation);
    }
  }

  @override
  Widget build(BuildContext context) {
    final encoded = _encoded;
    return WebpPreviewStateRegion(
      key: webpPreviewStateKey,
      state: _previewState,
      child: Column(
        children: <Widget>[
          if (widget.showEngineControls)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SegmentedButton<WebpPlayerEngine>(
                key: webpEngineControlKey,
                segments: const <ButtonSegment<WebpPlayerEngine>>[
                  ButtonSegment(
                    value: WebpPlayerEngine.native,
                    icon: Icon(Icons.memory),
                    label: Text(
                      'Native（实验）',
                      key: webpNativeEngineOptionKey,
                    ),
                  ),
                  ButtonSegment(
                    value: WebpPlayerEngine.flutter,
                    icon: Icon(Icons.image),
                    label: Text(
                      'Flutter codec',
                      key: webpFlutterEngineOptionKey,
                    ),
                  ),
                ],
                selected: <WebpPlayerEngine>{_engine},
                onSelectionChanged: _requestEngine,
              ),
            ),
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final source = _sourceCanvas;
                  DecodeTarget? target;
                  RasterPlan? raster;
                  if (source != null &&
                      constraints.maxWidth.isFinite &&
                      constraints.maxHeight.isFinite &&
                      constraints.maxWidth > 0 &&
                      constraints.maxHeight > 0) {
                    target = DecodeTarget.fit(
                      sourceWidth: source.width,
                      sourceHeight: source.height,
                      logicalWidth: constraints.maxWidth,
                      logicalHeight: constraints.maxHeight,
                      devicePixelRatio: MediaQuery.of(context).devicePixelRatio,
                    );
                    raster = RasterPlan.fit(
                      sourceWidth: source.width,
                      sourceHeight: source.height,
                      display: target,
                    );
                    _scheduleTarget(target, raster);
                  }
                  final loadError = _loadError;
                  if (loadError != null && encoded == null) {
                    return Center(
                      key: webpPreviewErrorKey,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'WebP 文件无效：$loadError',
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  final nearest = raster?.prefersNearestNeighbor ?? false;
                  final quality =
                      nearest ? FilterQuality.none : FilterQuality.medium;
                  return SizedBox.expand(
                    key: _previewState.phase == WebpPreviewPhase.ready
                        ? webpPreviewReadyKey
                        : webpPreviewLoadingKey,
                    child: switch (_engine) {
                      WebpPlayerEngine.native => _textureId != null
                          ? NativeTextureViewport(
                              textureId: _textureId!,
                              sourceWidth: source?.width ??
                                  raster?.sourceWidth ??
                                  1,
                              sourceHeight: source?.height ??
                                  raster?.sourceHeight ??
                                  1,
                              filterQuality: quality,
                              viewportKey: webpNativeTextureViewportKey,
                            )
                          : _image == null
                              ? const Center(
                                  child: CircularProgressIndicator(),
                                )
                              : RawImage(
                                  image: _image,
                                  fit: BoxFit.contain,
                                  filterQuality: quality,
                                  isAntiAlias: !nearest,
                                ),
                      WebpPlayerEngine.flutter =>
                        encoded == null || target == null || raster == null
                            ? const Center(
                                child: CircularProgressIndicator(),
                              )
                            : widget.playback == null
                                ? Image.memory(
                                    encoded,
                                    key: webpFlutterPreviewKey,
                                    cacheWidth: raster.isDownsampled
                                        ? raster.decodeWidth
                                        : null,
                                    cacheHeight: raster.isDownsampled
                                        ? raster.decodeHeight
                                        : null,
                                    width: double.infinity,
                                    height: double.infinity,
                                    gaplessPlayback: true,
                                    frameBuilder: (
                                      context,
                                      child,
                                      frame,
                                      wasSynchronouslyLoaded,
                                    ) {
                                      if (frame != null ||
                                          wasSynchronouslyLoaded) {
                                        _reportFirstFrame();
                                      }
                                      return child;
                                    },
                                    fit: BoxFit.contain,
                                    filterQuality: quality,
                                    isAntiAlias: !nearest,
                                    errorBuilder: (
                                      context,
                                      error,
                                      stackTrace,
                                    ) => Center(
                                      child: Text(
                                        'Flutter codec 无法解码：$error',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  )
                                : _ControlledAnimatedImage(
                                    key: webpFlutterPreviewKey,
                                    bytes: encoded,
                                    playback: widget.playback!,
                                    targetWidth: raster.isDownsampled
                                        ? raster.decodeWidth
                                        : null,
                                    targetHeight: raster.isDownsampled
                                        ? raster.decodeHeight
                                        : null,
                                    onReady: _reportFirstFrame,
                                    onError: (error) {
                                      if (mounted) {
                                        setState(() {
                                          _nativeError = error;
                                          _status =
                                              'Flutter codec 无法解码：$error';
                                        });
                                      }
                                    },
                                    downloadIdentity: widget.downloadIdentity,
                                    traceClock: widget.traceClock,
                                    traceSink: widget.traceSink,
                                    traceSessionId: widget.traceSessionId,
                                    demandRevision: widget.demandRevision,
                                  ),
                    },
                  );
                },
              ),
            ),
          ),
          if (widget.showStatus)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(_status),
                          if (_target != null)
                            Text(
                              'display=${_target!.physicalWidth}×'
                              '${_target!.physicalHeight} px',
                            ),
                          if (_raster != null)
                            Text(
                              'decode=${_raster!.decodeWidth}×'
                              '${_raster!.decodeHeight} px',
                            ),
                          if (_engine == WebpPlayerEngine.native)
                            Text('frame=$_frameIndex · cycle=$_cycle'),
                          if (_lastTexturePresent case final sample?)
                            Text(
                              'texture queue=${sample.queueMicros} µs · '
                              'upload=${sample.uploadMicros} µs · '
                              'deadline miss=${sample.deadlineMissMicros} µs · '
                              'memory frame=${sample.frameBytes} B · '
                              'texture=${sample.textureBytes} B · '
                              'in-flight=${sample.inFlightBytes} B',
                            ),
                          if (_lastTextureFallback case final fallback?)
                            Text(
                              'texture fallback: ${fallback.reason}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (_nativeError != null)
                            Text(
                              'native: $_nativeError',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: _paused ? '继续' : '暂停',
                      onPressed: _engine == WebpPlayerEngine.native
                          ? _togglePause
                          : null,
                      icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

sealed class _PreparedNativeFrame {
  _PreparedNativeFrame({
    required this.duration,
    required this.index,
    required this.cycle,
    required this.frameBytes,
    required this.decodeMicros,
    required this.prepareMicros,
  });

  final Duration duration;
  final int index;
  final int cycle;
  final int frameBytes;
  final int decodeMicros;
  final int prepareMicros;

  void dispose();
}

final class _PreparedImageFrame extends _PreparedNativeFrame {
  _PreparedImageFrame({
    required ui.Image image,
    required super.duration,
    required super.index,
    required super.cycle,
    required super.frameBytes,
    required super.decodeMicros,
    required super.prepareMicros,
  }) : _image = image;

  ui.Image? _image;

  ui.Image? takeImage() {
    final image = _image;
    _image = null;
    return image;
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

final class _PreparedTextureFrame extends _PreparedNativeFrame {
  _PreparedTextureFrame({
    required TextureFrameOwner frame,
    required super.duration,
    required super.index,
    required super.cycle,
    required super.frameBytes,
    required super.decodeMicros,
    required super.prepareMicros,
  }) : _frame = frame;

  TextureFrameOwner? _frame;

  TextureFrameOwner? takeFrame() {
    final frame = _frame;
    _frame = null;
    return frame;
  }

  @override
  void dispose() {
    _frame?.dispose();
    _frame = null;
  }
}

Future<ui.Image> _decodeRgba(Uint8List bytes, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
    rowBytes: width * 4,
  );
  return completer.future;
}

void _premultiplyRgbaInPlace(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    final alpha = bytes[i + 3];
    if (alpha == 255) {
      continue;
    }
    bytes[i] = (bytes[i] * alpha + 127) ~/ 255;
    bytes[i + 1] = (bytes[i + 1] * alpha + 127) ~/ 255;
    bytes[i + 2] = (bytes[i + 2] * alpha + 127) ~/ 255;
  }
}
