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
import 'package:texture_bridge/texture_bridge.dart';

const _webpTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'Animated WebP',
    extensions: <String>['webp'],
    mimeTypes: <String>['image/webp'],
  ),
];

typedef WebpPicker = Future<PickedWebp?> Function();
typedef LocalWebpSelector = Future<XFile?> Function();

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

const webpPreviewScreenKey = ValueKey<String>('webp-preview-screen');
const webpPreviewTitleKey = ValueKey<String>('webp-preview-title');
const webpPreviewStateKey = ValueKey<String>('webp-preview-state');
const webpPreviewLoadingKey = ValueKey<String>('webp-preview-loading');
const webpPreviewReadyKey = ValueKey<String>('webp-preview-ready');
const webpPreviewErrorKey = ValueKey<String>('webp-preview-error');
const webpEngineControlKey = ValueKey<String>('webp-engine-control');
const webpFlutterEngineOptionKey =
    ValueKey<String>('webp-engine-flutter-option');
const webpFlutterPreviewKey = ValueKey<String>('webp-flutter-preview');

Future<PickedWebp?> pickLocalWebp({LocalWebpSelector? selectFile}) async {
  final file = await (selectFile ??
      () => openFile(acceptedTypeGroups: _webpTypes))();
  return file == null ? null : PickedWebp.fromFile(file);
}

Future<PickedWebp?> defaultWebpPicker() => pickLocalWebp();

enum WebpPreviewPhase { loading, ready, invalid }

@immutable
final class WebpPreviewState {
  const WebpPreviewState._({required this.phase, this.info, this.error});

  const WebpPreviewState.loading()
      : this._(phase: WebpPreviewPhase.loading);

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
  const WebpCatalogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('内置动图 WebP')),
      body: FutureBuilder<List<WebpDemoEntry>>(
        future: loadWebpDemoEntries(),
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

  factory WebpPlayerScreen.picked(PickedWebp picked) =>
      WebpPlayerScreen.file(
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

enum _PlayerEngine { native, flutter }

final class NativeWebpPlayer extends StatefulWidget {
  const NativeWebpPlayer({
    required this.title,
    required this.sourceUri,
    required this.loadBytes,
    this.showEngineControls = true,
    this.showStatus = true,
    this.onFirstFrame,
    super.key,
  });

  final String title;
  final Uri sourceUri;
  final Future<Uint8List> Function() loadBytes;
  final bool showEngineControls;
  final bool showStatus;
  final VoidCallback? onFirstFrame;

  @override
  State<NativeWebpPlayer> createState() => _NativeWebpPlayerState();
}

final class _NativeWebpPlayerState extends State<NativeWebpPlayer> {
  static const _textureUploadBudget = Duration(microseconds: 16667);

  _PlayerEngine _engine = _PlayerEngine.native;
  Uint8List? _encoded;
  WebpInfo? _sourceCanvas;
  DecodeTarget? _target;
  DecodeTarget? _scheduledTarget;
  RasterPlan? _raster;
  RasterPlan? _scheduledRaster;
  ui.Image? _image;
  late final AndroidTexturePresenter _texturePresenter;
  AndroidTextureLease? _texture;
  int? _textureId;
  TexturePresentTelemetry? _lastTexturePresent;
  TextureFallbackTelemetry? _lastTextureFallback;
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
    _texturePresenter = AndroidTexturePresenter(
      telemetrySink: _recordTextureTelemetry,
    );
    unawaited(_load());
  }

  void _recordTextureTelemetry(TextureTelemetry event) {
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
      if (target != null && _engine == _PlayerEngine.native) {
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
        _engine = _PlayerEngine.flutter;
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
        _status = _engine == _PlayerEngine.native
            ? decodeChanged
                ? '重建 native decode target'
                : 'native display target 已更新'
            : 'Flutter codec · ${raster.decodeWidth}×${raster.decodeHeight}';
      });
      if (decodeChanged &&
          _encoded != null &&
          _engine == _PlayerEngine.native) {
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
        _engine != _PlayerEngine.native) {
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
        download: DownloadId(
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
      _resetNative(disposeImage: true);
      setState(() {
        _nativeError = error;
        _engine = _PlayerEngine.flutter;
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
      final step = await binding.frames.decodeNext();
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
            return _PreparedTextureFrame(
              frame: NativeTextureFrameOwner(frame),
              duration: duration,
              index: index,
              cycle: cycle,
            );
          }
          final rgba = frame.copyBytes();
          _premultiplyRgbaInPlace(rgba);
          late final ui.Image image;
          try {
            image = await _decodeRgba(rgba, frame.width, frame.height);
          } finally {
            frame.dispose();
          }
          return _PreparedImageFrame(
            image: image,
            duration: duration,
            index: index,
            cycle: cycle,
          );
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
      final oldImage = _image;
      _image = null;
      oldImage?.dispose();
      setState(() {
        _nativeError = error;
        _engine = _PlayerEngine.flutter;
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
    final oldImage = _image;
    _image = null;
    oldImage?.dispose();
    setState(() {
      _nativeError = error;
      _engine = _PlayerEngine.flutter;
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
          _presentPrepared(next, generation).catchError((Object error, StackTrace stackTrace) {
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

  void _setEngine(_PlayerEngine engine) {
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
      _status = engine == _PlayerEngine.native
          ? '启动 native'
          : target == null
              ? 'Flutter codec'
              : 'Flutter codec · '
                  '${target.physicalWidth}×${target.physicalHeight}';
    });
    if (engine == _PlayerEngine.native) {
      unawaited(_startNative(generation));
    }
  }

  void _togglePause() {
    if (_engine != _PlayerEngine.native) {
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
              child: SegmentedButton<_PlayerEngine>(
                key: webpEngineControlKey,
                segments: const <ButtonSegment<_PlayerEngine>>[
                  ButtonSegment(
                    value: _PlayerEngine.native,
                    icon: Icon(Icons.memory),
                    label: Text('Native pipeline'),
                  ),
                  ButtonSegment(
                    value: _PlayerEngine.flutter,
                    icon: Icon(Icons.image),
                    label: Text(
                      'Flutter codec',
                      key: webpFlutterEngineOptionKey,
                    ),
                  ),
                ],
                selected: <_PlayerEngine>{_engine},
                onSelectionChanged: (selection) =>
                    _setEngine(selection.single),
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
                      devicePixelRatio:
                          MediaQuery.of(context).devicePixelRatio,
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
                  final quality = nearest
                      ? FilterQuality.none
                      : FilterQuality.medium;
                  return SizedBox.expand(
                    key: _previewState.phase == WebpPreviewPhase.ready
                        ? webpPreviewReadyKey
                        : webpPreviewLoadingKey,
                    child: switch (_engine) {
                      _PlayerEngine.native => _textureId != null
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
                      _PlayerEngine.flutter =>
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
                          if (_engine == _PlayerEngine.native)
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
                      onPressed: _engine == _PlayerEngine.native
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
  });

  final Duration duration;
  final int index;
  final int cycle;

  void dispose();
}

final class _PreparedImageFrame extends _PreparedNativeFrame {
  _PreparedImageFrame({
    required ui.Image image,
    required super.duration,
    required super.index,
    required super.cycle,
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

