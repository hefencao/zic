part of '../local_media_ui.dart';

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
    this.onPlaybackCapabilityChanged,
    this.fit = BoxFit.contain,
    this.flutterAnimatedCodecFactory = instantiateFlutterAnimatedCodec,
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
  final ValueChanged<bool>? onPlaybackCapabilityChanged;
  final BoxFit fit;
  final FlutterAnimatedCodecFactory flutterAnimatedCodecFactory;

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
      widget.onPlaybackCapabilityChanged?.call(
        webpPrefixDeclaresAnimation(bytes),
      );
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
          if (index > 0 || (binding.loop?.animation.frameCount ?? 0) > 1) {
            widget.onPlaybackCapabilityChanged?.call(true);
          }
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
            if (loop.animation.frameCount > 1) {
              widget.onPlaybackCapabilityChanged?.call(true);
            }
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
                              fit: widget.fit,
                              viewportKey: webpNativeTextureViewportKey,
                            )
                          : _image == null
                              ? const Center(
                                  child: CircularProgressIndicator(),
                                )
                              : RawImage(
                                  image: _image,
                                  fit: widget.fit,
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
                                    fit: widget.fit,
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
                                    codecFactory:
                                        widget.flutterAnimatedCodecFactory,
                                    fit: widget.fit,
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
