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

const _webpTypes = <XTypeGroup>[
  XTypeGroup(
    label: 'Animated WebP',
    extensions: <String>['webp'],
    mimeTypes: <String>['image/webp'],
  ),
];

typedef WebpPicker = Future<XFile?> Function();

Future<XFile?> pickLocalWebp() => openFile(acceptedTypeGroups: _webpTypes);

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

  factory WebpPlayerScreen.file(XFile file) {
    return WebpPlayerScreen._(
      title: file.name,
      sourceUri: file.path.isEmpty
          ? Uri(scheme: 'memory', path: file.name)
          : Uri.file(file.path),
      loadBytes: file.readAsBytes,
    );
  }

  final String title;
  final Uri sourceUri;
  final Future<Uint8List> Function() loadBytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
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
    super.key,
  });

  final String title;
  final Uri sourceUri;
  final Future<Uint8List> Function() loadBytes;

  @override
  State<NativeWebpPlayer> createState() => _NativeWebpPlayerState();
}

final class _NativeWebpPlayerState extends State<NativeWebpPlayer> {
  _PlayerEngine _engine = _PlayerEngine.native;
  Uint8List? _encoded;
  _CanvasSize? _sourceCanvas;
  DecodeTarget? _target;
  DecodeTarget? _scheduledTarget;
  ui.Image? _image;
  EncodedSource? _source;
  CursorBinding? _cursor;
  _PreparedNativeFrame? _pending;
  Timer? _timer;
  Stopwatch? _frameClock;
  Stopwatch? _timerClock;
  Duration _pendingDelay = Duration.zero;
  Object? _nativeError;
  String _status = '加载中';
  int _frameIndex = -1;
  int _cycle = 0;
  bool _paused = false;
  bool _preparing = false;
  bool _completionPending = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
      setState(() {
        _encoded = bytes;
        _sourceCanvas = _readWebpCanvas(bytes);
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
      setState(() {
        _nativeError = error;
        _engine = _PlayerEngine.flutter;
        _status = '读取失败';
      });
    }
  }

  void _scheduleTarget(DecodeTarget target) {
    if (_target == target || _scheduledTarget == target) {
      return;
    }
    _scheduledTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledTarget != target) {
        return;
      }
      _scheduledTarget = null;
      if (_target == target) {
        return;
      }
      setState(() {
        _target = target;
        _status = _engine == _PlayerEngine.native
            ? '重建 native target'
            : 'Flutter codec · ${target.physicalWidth}×${target.physicalHeight}';
      });
      if (_encoded != null && _engine == _PlayerEngine.native) {
        unawaited(_startNative(++_generation));
      }
    });
  }

  Future<void> _startNative(int generation) async {
    final bytes = _encoded;
    final target = _target;
    if (bytes == null || target == null || _engine != _PlayerEngine.native) {
      return;
    }
    _resetNative(disposeImage: true);
    _nativeError = null;
    _frameIndex = -1;
    _cycle = 0;

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
      final append = source.append(epoch: epoch, offset: 0, bytes: bytes);
      if (append != SourceStatus.ok) {
        source.dispose();
        throw StateError('native source append failed: ${append.name}');
      }
      final seal = source.seal(epoch);
      if (seal != SourceStatus.ok) {
        source.dispose();
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
        physicalWidth: target.physicalWidth,
        physicalHeight: target.physicalHeight,
        pixelFormat: PixelFormat.rgba8888,
        renderer: RendererKind.flutterImage,
      );
      final cursor = const NativeCursorFactory().create(
        id: id,
        source: source,
        epoch: epoch,
      );
      _source = source;
      _cursor = cursor;
      if (mounted && generation == _generation) {
        setState(() {
          _status = 'native · ${target.physicalWidth}×${target.physicalHeight}';
        });
      }
      final first = await _decodePrepared(generation);
      if (first == null) {
        if (mounted && generation == _generation) {
          setState(() => _status = '播放完成');
        }
        return;
      }
      _presentPrepared(first, generation);
    } catch (error) {
      _resetNative(disposeImage: true);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _nativeError = error;
        _engine = _PlayerEngine.flutter;
        _status = 'native 不可用，已回退 Flutter codec';
      });
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
          final rgba = frame.copyBytes();
          _premultiplyRgbaInPlace(rgba);
          final duration = frame.duration > Duration.zero
              ? frame.duration
              : const Duration(milliseconds: 100);
          final index = frame.index;
          final cycle = binding.loop?.cycle ?? 0;
          late final ui.Image image;
          try {
            image = await _decodeRgba(rgba, frame.width, frame.height);
          } finally {
            frame.dispose();
          }
          return _PreparedNativeFrame(
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

  void _presentPrepared(_PreparedNativeFrame prepared, int generation) {
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

    final previous = _image;
    setState(() {
      _image = prepared.image;
      _frameIndex = prepared.index;
      _cycle = prepared.cycle;
      _status = 'native · frame ${prepared.index} · cycle ${prepared.cycle}';
    });
    previous?.dispose();

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
        _presentPrepared(next, generation);
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
    if (disposeImage) {
      _image?.dispose();
      _image = null;
    }
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
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<_PlayerEngine>(
            segments: const <ButtonSegment<_PlayerEngine>>[
              ButtonSegment(
                value: _PlayerEngine.native,
                icon: Icon(Icons.memory),
                label: Text('Native pipeline'),
              ),
              ButtonSegment(
                value: _PlayerEngine.flutter,
                icon: Icon(Icons.image),
                label: Text('Flutter codec'),
              ),
            ],
            selected: <_PlayerEngine>{_engine},
            onSelectionChanged: (selection) => _setEngine(selection.single),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final source = _sourceCanvas;
                DecodeTarget? target;
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
                  _scheduleTarget(target);
                }
                return SizedBox.expand(
                  child: switch (_engine) {
                    _PlayerEngine.native => _image == null
                        ? const Center(child: CircularProgressIndicator())
                        : RawImage(
                            image: _image,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                          ),
                    _PlayerEngine.flutter => encoded == null || target == null
                        ? const Center(child: CircularProgressIndicator())
                        : Image.memory(
                            encoded,
                            key: ValueKey<String>(
                              'flutter-${target.physicalWidth}x'
                              '${target.physicalHeight}-${widget.sourceUri}',
                            ),
                            cacheWidth: target.physicalWidth,
                            cacheHeight: target.physicalHeight,
                            width: double.infinity,
                            height: double.infinity,
                            gaplessPlayback: true,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            isAntiAlias: true,
                            errorBuilder: (context, error, stackTrace) => Center(
                              child: Text(
                                'Flutter codec 无法解码：$error',
                                style: const TextStyle(color: Colors.white),
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
                          'target=${_target!.physicalWidth}×'
                          '${_target!.physicalHeight} px',
                        ),
                      if (_engine == _PlayerEngine.native)
                        Text('frame=$_frameIndex · cycle=$_cycle'),
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
                  onPressed:
                      _engine == _PlayerEngine.native ? _togglePause : null,
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _PreparedNativeFrame {
  _PreparedNativeFrame({
    required this.image,
    required this.duration,
    required this.index,
    required this.cycle,
  });

  final ui.Image image;
  final Duration duration;
  final int index;
  final int cycle;

  void dispose() => image.dispose();
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

final class _CanvasSize {
  const _CanvasSize(this.width, this.height);

  final int width;
  final int height;
}

_CanvasSize _readWebpCanvas(Uint8List bytes) {
  if (bytes.length < 30 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    return const _CanvasSize(512, 512);
  }
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final tag = ascii.decode(
      bytes.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final length = data.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    if (tag == 'VP8X' && dataOffset + 10 <= bytes.length) {
      final width = 1 +
          bytes[dataOffset + 4] +
          (bytes[dataOffset + 5] << 8) +
          (bytes[dataOffset + 6] << 16);
      final height = 1 +
          bytes[dataOffset + 7] +
          (bytes[dataOffset + 8] << 8) +
          (bytes[dataOffset + 9] << 16);
      return _CanvasSize(width, height);
    }
    offset = dataOffset + length + (length.isOdd ? 1 : 0);
  }
  return const _CanvasSize(512, 512);
}

