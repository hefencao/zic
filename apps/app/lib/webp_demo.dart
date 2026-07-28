import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bridge/bridge.dart';
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:texture_bridge/texture_bridge.dart';

import 'local_webp_folder.dart';

const _webpTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'Animated WebP',
    extensions: <String>['webp'],
    mimeTypes: <String>['image/webp'],
  ),
];

typedef WebpPicker = Future<PickedWebp?> Function();
typedef WebpFolderPicker = Future<PickedWebpFolder?> Function();
typedef LocalWebpSelector = Future<XFile?> Function();

final class PickedWebpFolder {
  factory PickedWebpFolder({
    required String directoryPath,
    required List<PickedWebp> files,
    String? displayName,
  }) {
    if (files.isEmpty) {
      throw ArgumentError.value(
          files, 'files', 'must contain at least one WebP');
    }
    final explicit = displayName?.trim() ?? '';
    return PickedWebpFolder._(
      directoryPath: directoryPath,
      displayName:
          explicit.isEmpty ? webpDirectoryDisplayName(directoryPath) : explicit,
      files: List<PickedWebp>.unmodifiable(files),
    );
  }

  const PickedWebpFolder._({
    required this.directoryPath,
    required this.displayName,
    required this.files,
  });

  final String directoryPath;
  final String displayName;
  final List<PickedWebp> files;
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

String webpDisplayName(XFile file) {
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
  return '本地 WebP';
}

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
const webpFolderScreenKey = ValueKey<String>('webp-folder-screen');
const webpFolderTitleKey = ValueKey<String>('webp-folder-title');
const webpFolderCurrentFileKey = ValueKey<String>('webp-folder-current-file');
const webpFolderPositionKey = ValueKey<String>('webp-folder-position');
const webpFolderPreviousKey = ValueKey<String>('webp-folder-previous');
const webpFolderNextKey = ValueKey<String>('webp-folder-next');
const webpFolderFileMenuKey = ValueKey<String>('webp-folder-file-menu');

Key webpCatalogEntryKey(String id) => ValueKey<String>('webp-catalog:$id');

Future<PickedWebp?> pickLocalWebp({LocalWebpSelector? selectFile}) async {
  final file =
      await (selectFile ?? () => openFile(acceptedTypeGroups: _webpTypes))();
  return file == null ? null : PickedWebp.fromFile(file);
}

Future<PickedWebp?> defaultWebpPicker() => pickLocalWebp();

Future<PickedWebpFolder?> pickLocalWebpFolder({
  LocalWebpDirectorySelector? selectDirectory,
  LocalWebpDirectoryLoader? listFiles,
}) async {
  final directoryPath = await (selectDirectory ?? selectLocalWebpDirectory)();
  if (directoryPath == null) {
    return null;
  }
  final normalizedDirectory = directoryPath.trim();
  if (normalizedDirectory.isEmpty) {
    throw const FormatException('文件夹路径不能为空');
  }
  final selected = await (listFiles ?? listLocalWebpDirectory)(
    normalizedDirectory,
  );
  if (selected.isEmpty) {
    throw const FormatException('所选文件夹中没有 WebP 文件');
  }
  final files = selected
      .map(
        (file) => PickedWebp(
          file: file,
          displayName: _relativeWebpName(normalizedDirectory, file.path),
        ),
      )
      .toList(growable: false);
  return PickedWebpFolder(
    directoryPath: normalizedDirectory,
    files: files,
  );
}

Future<PickedWebpFolder?> defaultWebpFolderPicker() => pickLocalWebpFolder();

String webpDirectoryDisplayName(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    return '本地 WebP 文件夹';
  }
  final withoutTrailing = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = withoutTrailing.lastIndexOf('/');
  final name =
      slash < 0 ? withoutTrailing : withoutTrailing.substring(slash + 1);
  return name.isEmpty ? '本地 WebP 文件夹' : name;
}

String _relativeWebpName(String directoryPath, String filePath) {
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

final class WebpFolderScreen extends StatefulWidget {
  const WebpFolderScreen({required this.folder, super.key});

  final PickedWebpFolder folder;

  @override
  State<WebpFolderScreen> createState() => _WebpFolderScreenState();
}

final class _WebpFolderScreenState extends State<WebpFolderScreen> {
  int _index = 0;

  PickedWebp get _current => widget.folder.files[_index];

  @override
  void didUpdateWidget(covariant WebpFolderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.folder.files.length) {
      _index = widget.folder.files.length - 1;
    }
  }

  void _select(int index) {
    if (index == _index || index < 0 || index >= widget.folder.files.length) {
      return;
    }
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final count = widget.folder.files.length;
    return Scaffold(
      key: webpFolderScreenKey,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.folder.displayName, key: webpFolderTitleKey),
            Text(
              current.displayName,
              key: webpFolderCurrentFileKey,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: <Widget>[
          PopupMenuButton<int>(
            key: webpFolderFileMenuKey,
            tooltip: '选择 WebP',
            initialValue: _index,
            onSelected: _select,
            itemBuilder: (context) => <PopupMenuEntry<int>>[
              for (var index = 0; index < count; index++)
                PopupMenuItem<int>(
                  value: index,
                  child: Text(widget.folder.files[index].displayName),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: NativeWebpPlayer(
              key: ValueKey<String>(
                'folder-webp:${current.file.path}:$_index',
              ),
              title: current.displayName,
              sourceUri: current.file.path.isEmpty
                  ? Uri(scheme: 'memory', path: current.displayName)
                  : Uri.file(current.file.path),
              loadBytes: current.file.readAsBytes,
              showEngineControls: false,
              initialEngine: WebpPlayerEngine.flutter,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: <Widget>[
                  IconButton.filledTonal(
                    key: webpFolderPreviousKey,
                    tooltip: '上一个 WebP',
                    onPressed: _index == 0 ? null : () => _select(_index - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      '${_index + 1} / $count',
                      key: webpFolderPositionKey,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton.filledTonal(
                    key: webpFolderNextKey,
                    tooltip: '下一个 WebP',
                    onPressed:
                        _index + 1 >= count ? null : () => _select(_index + 1),
                    icon: const Icon(Icons.chevron_right),
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
      loadBytes: () async {
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
      loadBytes: file.readAsBytes,
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
        loadBytes: () async => bytes,
      );

  final String title;
  final Uri sourceUri;
  final Future<Uint8List> Function() loadBytes;

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
    super.key,
  });

  final String title;
  final Uri sourceUri;
  final Future<Uint8List> Function() loadBytes;
  final bool showEngineControls;
  final bool showStatus;
  final VoidCallback? onFirstFrame;
  final TraceSink traceSink;
  final MonoClock? traceClock;
  final String traceSessionId;
  final int Function()? demandRevision;
  final DownloadId? downloadIdentity;
  final WebpPlayerEngine initialEngine;

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
  bool _preparing = false;
  bool _completionPending = false;
  int _generation = 0;
  bool _reportedFirstFrame = false;

  @override
  void initState() {
    super.initState();
    _engine = widget.initialEngine;
    _traceClock = widget.traceClock ?? SystemClock();
    _texturePresenter = AndroidTexturePresenter(
      telemetrySink: _recordTextureTelemetry,
    );
    unawaited(_load());
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
    _resetNative(disposeImage: true);
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final bytes = await widget.loadBytes();
      if (!mounted || generation != _generation) {
        return;
      }
      final canvas = parseWebpInfo(bytes);
      setState(() {
        _encoded = bytes;
        _sourceCanvas = canvas;
        _loadError = null;
        _previewState = WebpPreviewState.ready(canvas);
        _status = '已读取 ${bytes.length} B，等待 viewport';
      });
      final target = _target;
      if (target != null && _engine == WebpPlayerEngine.native) {
        await _startNative(++_generation);
      }
    } catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      _resetNative(disposeImage: true);
      setState(() {
        _encoded = null;
        _sourceCanvas = null;
        _loadError = error;
        _previewState = WebpPreviewState.invalid(error);
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
      if (!mounted || generation != _generation) {
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
      if (!mounted || generation != _generation) {
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
    try {
      final next = await _decodePrepared(generation);
      if (!mounted || generation != _generation) {
        next?.dispose();
        return;
      }
      final remaining = FramePacing.remaining(
        frameDuration: currentDuration,
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
      if (!mounted || generation != _generation) {
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
      _paused = false;
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
    if (_engine != WebpPlayerEngine.native) {
      return;
    }
    final pausing = !_paused;
    setState(() => _paused = pausing);
    if (pausing) {
      _frameClock?.stop();
      final timerClock = _timerClock;
      if (_timer != null && timerClock != null) {
        final remaining = _pendingDelay - timerClock.elapsed;
        _pendingDelay = remaining;
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
    } else if (!_preparing && _status == '播放完成') {
      return;
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
                          ? Texture(
                              textureId: _textureId!,
                              filterQuality: quality,
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
                            : Image.memory(
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
                                  if (frame != null || wasSynchronouslyLoaded) {
                                    _reportFirstFrame();
                                  }
                                  return child;
                                },
                                fit: BoxFit.contain,
                                filterQuality: quality,
                                isAntiAlias: !nearest,
                                errorBuilder: (context, error, stackTrace) =>
                                    Center(
                                  child: Text(
                                    'Flutter codec 无法解码：$error',
                                    style: const TextStyle(
                                      color: Colors.white,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
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
