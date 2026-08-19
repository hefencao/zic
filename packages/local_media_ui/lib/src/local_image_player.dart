part of '../local_media_ui.dart';

const mediaAspectViewportKey = ValueKey<String>('media-aspect-viewport');

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
    this.pageStream,
    this.pageOutput,
    this.onPlaybackCapabilityChanged,
    this.onDimensionsChanged,
    this.fit = BoxFit.contain,
    this.flutterAnimatedCodecFactory = instantiateFlutterAnimatedCodec,
    super.key,
  }) : assert(
          pageStream == null || pageOutput != null,
          'Pipeline page streams must be paired with their owned output',
        );

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
  final PipelinePageStream? pageStream;
  final PipelinePageOutputStream? pageOutput;
  final ValueChanged<bool>? onPlaybackCapabilityChanged;
  final ValueChanged<Size>? onDimensionsChanged;
  final BoxFit fit;
  final FlutterAnimatedCodecFactory flutterAnimatedCodecFactory;

  Uri get sourceUri => image.sourceUri;

  @override
  State<LocalImagePlayer> createState() => _LocalImagePlayerState();
}

final class _LocalImagePlayerState extends State<LocalImagePlayer> {
  late ImagePreviewState _state;
  late LocalImageFormat _detectedFormat;
  Uint8List? _bytes;
  ImageProvider<Object>? _imageProvider;
  int _generation = 0;
  int _scheduledStaticFrameGeneration = -1;
  late MediaLoadToken _loadToken;
  bool _reportedFirstFrame = false;
  PipelinePageStreamListener? _pageStreamingListener;
  PipelinePageOutputListener? _pageOutputListener;
  PipelinePageOutputSnapshot? _pageOutputSnapshot;
  PipelinePageSurface? _scheduledOutputSurface;
  bool _streamingPrefixSyncing = false;
  int _streamingPrefixRequestedLength = 0;
  int _streamingPrefixRequestedRevision = 0;
  int _streamingPrefixReadRevision = 0;
  bool _fallbackLoadStarted = false;
  bool _pipelineAuthoritativeStatic = false;
  bool _pipelineStaticLoadStarted = false;
  Size? _reportedDimensions;
  bool _reportedDimensionsAuthoritative = false;

  @override
  void initState() {
    super.initState();
    _detectedFormat = widget.image.format;
    _state = ImagePreviewState.loading(widget.image.format);
    _loadToken = MediaLoadToken();
    _scheduleObserverSnapshot();
    final streaming = widget.pageStream;
    if (streaming != null) {
      _attachPageStreaming(streaming);
      final output = widget.pageOutput;
      if (output != null) {
        _attachPageOutput(output);
      }
    } else {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant LocalImagePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.sourceId != widget.image.sourceId ||
        oldWidget.image.displayName != widget.image.displayName ||
        oldWidget.image.format != widget.image.format ||
        oldWidget.pageStream != widget.pageStream ||
        oldWidget.pageOutput != widget.pageOutput) {
      _generation++;
      _loadToken.cancel();
      _loadToken = MediaLoadToken();
      _reportedFirstFrame = false;
      _scheduledStaticFrameGeneration = -1;
      _bytes = null;
      _imageProvider = null;
      _reportedDimensions = null;
      _reportedDimensionsAuthoritative = false;
      _detectedFormat = widget.image.format;
      _state = ImagePreviewState.loading(widget.image.format);
      _notifyObserver(_state);
      _fallbackLoadStarted = false;
      _pipelineAuthoritativeStatic = false;
      _pipelineStaticLoadStarted = false;
      final oldStreaming = oldWidget.pageStream;
      final oldListener = _pageStreamingListener;
      if (oldStreaming != null && oldListener != null) {
        oldStreaming.removeListener(oldListener);
      }
      _pageStreamingListener = null;
      final oldOutput = oldWidget.pageOutput;
      final oldOutputListener = _pageOutputListener;
      if (oldOutput != null && oldOutputListener != null) {
        oldOutput.removeListener(oldOutputListener);
      }
      _pageOutputListener = null;
      _pageOutputSnapshot = null;
      _scheduledOutputSurface = null;
      _streamingPrefixSyncing = false;
      _streamingPrefixRequestedLength = 0;
      _streamingPrefixRequestedRevision = 0;
      _streamingPrefixReadRevision = 0;
      final streaming = widget.pageStream;
      if (streaming != null) {
        _attachPageStreaming(streaming);
        final output = widget.pageOutput;
        if (output != null) {
          _attachPageOutput(output);
        }
      } else {
        unawaited(_load());
      }
    }
  }

  void _attachPageStreaming(PipelinePageStream stream) {
    void listener(PipelinePageStreamSnapshot snapshot) {
      if (!mounted) return;
      final sourceCanvasWidth = snapshot.sourceCanvasWidth;
      final sourceCanvasHeight = snapshot.sourceCanvasHeight;
      if (sourceCanvasWidth != null &&
          sourceCanvasHeight != null &&
          sourceCanvasWidth > 0 &&
          sourceCanvasHeight > 0) {
        // Reader geometry and media presentation must consume the same encoded
        // source-aspect authority. The decoded raster may be a rounded native
        // scale target and is only a pixel carrier, not a second aspect owner.
        _reportDimensions(
          sourceCanvasWidth,
          sourceCanvasHeight,
          authoritative: true,
        );
      }
      final kind = snapshot.kind;
      final encodedStatic =
          snapshot.authoritativeStatic &&
              kind == PipelinePageContentKind.webp;
      if (encodedStatic) {
        _activatePipelineStaticPresentation();
        return;
      }
      if (kind == PipelinePageContentKind.webp) {
        if (_detectedFormat != LocalImageFormat.webp) {
          setState(() => _detectedFormat = LocalImageFormat.webp);
        }
        _requestStreamingWebpPrefix(stream, snapshot);
        return;
      }
      if (!_fallbackLoadStarted &&
          (snapshot.state == PipelinePageTransferState.promoted ||
              snapshot.state == PipelinePageTransferState.sealed)) {
        _fallbackLoadStarted = true;
        unawaited(_load());
      }
      if (snapshot.state == PipelinePageTransferState.failed) {
        _publish(
          ImagePreviewState.invalid(
            _detectedFormat,
            snapshot.failure ?? StateError('pipeline page transfer failed'),
          ),
        );
      }
    }
    _pageStreamingListener = listener;
    stream.addListener(listener);
  }

  void _requestStreamingWebpPrefix(
    PipelinePageStream stream,
    PipelinePageStreamSnapshot snapshot,
  ) {
    final requested = math.min(snapshot.committedLength, 256 * 1024);
    if (requested > _streamingPrefixRequestedLength) {
      _streamingPrefixRequestedLength = requested;
    }
    _streamingPrefixRequestedRevision++;
    if (_streamingPrefixSyncing ||
        _streamingPrefixRequestedLength < 20 ||
        _streamingPrefixRequestedRevision <= _streamingPrefixReadRevision) {
      return;
    }
    unawaited(_drainStreamingWebpPrefix(stream));
  }

  Future<void> _drainStreamingWebpPrefix(
    PipelinePageStream stream,
  ) async {
    if (_streamingPrefixSyncing) {
      return;
    }
    _streamingPrefixSyncing = true;
    try {
      while (mounted && widget.pageStream == stream) {
        final requested = _streamingPrefixRequestedLength;
        final requestedRevision = _streamingPrefixRequestedRevision;
        if (requested < 20 ||
            requestedRevision <= _streamingPrefixReadRevision) {
          return;
        }
        try {
          final prefix = await stream.readPrefix(requested);
          if (!mounted || widget.pageStream != stream) {
            return;
          }
          _streamingPrefixReadRevision = requestedRevision;
          final info = parseWebpPrefixInfo(prefix);
          if (info != null) {
            _reportDimensions(info.width, info.height);
          }
          if (webpPrefixDeclaresAnimation(prefix)) {
            widget.onPlaybackCapabilityChanged?.call(true);
          }
        } on Object {
          // Wait for the next source lifecycle revision before retrying.
          _streamingPrefixReadRevision = requestedRevision;
        }
      }
    } finally {
      _streamingPrefixSyncing = false;
      if (mounted &&
          widget.pageStream == stream &&
          _streamingPrefixRequestedRevision >
              _streamingPrefixReadRevision) {
        unawaited(_drainStreamingWebpPrefix(stream));
      }
    }
  }

  void _attachPageOutput(PipelinePageOutputStream output) {
    void listener(PipelinePageOutputSnapshot snapshot) {
      if (!mounted) return;
      if (_pipelineAuthoritativeStatic) {
        // Decoder truth has moved this page to the encoded static-image path.
        // Any late native texture completion is stale presentation work and
        // must not replace the Flutter ImageProvider surface.
        return;
      }
      final prior = _pageOutputSnapshot;
      final visualChanged = prior == null ||
          prior.state != snapshot.state ||
          !identical(prior.surface, snapshot.surface) ||
          prior.frameIndex != snapshot.frameIndex ||
          prior.replacing != snapshot.replacing ||
          !identical(prior.failure, snapshot.failure);
      if (visualChanged) {
        if (_pageOutputSnapshot == null) {
          _pageOutputSnapshot = snapshot;
        } else {
          setState(() => _pageOutputSnapshot = snapshot);
        }
      } else {
        _pageOutputSnapshot = snapshot;
      }
      if (snapshot.hasSurface) {
        final surface = snapshot.surface!;
        _reportDimensions(
          surface.width,
          surface.height,
          authoritative: false,
        );
        if (snapshot.animation.complete) {
          widget.onPlaybackCapabilityChanged?.call(snapshot.isAnimated);
        }
        _schedulePipelineOutputFirstFrame(surface);
        return;
      }
      _scheduledOutputSurface = null;
      if (snapshot.state == PipelinePageOutputState.failed) {
        _publish(
          ImagePreviewState.invalid(
            LocalImageFormat.webp,
            snapshot.failure ?? StateError('pipeline page output failed'),
          ),
        );
      }
    }
    _pageOutputListener = listener;
    output.addListener(listener);
  }

  void _activatePipelineStaticPresentation() {
    if (!_pipelineAuthoritativeStatic) {
      setState(() {
        _pipelineAuthoritativeStatic = true;
        _pageOutputSnapshot = null;
        _scheduledOutputSurface = null;
      });
      widget.onPlaybackCapabilityChanged?.call(false);
    }
    if (_pipelineStaticLoadStarted) {
      return;
    }
    final loader = widget.tokenBytesLoader;
    if (loader == null) {
      return;
    }
    _pipelineStaticLoadStarted = true;
    unawaited(_loadPipelineStaticEncoded(loader));
  }

  Future<void> _loadPipelineStaticEncoded(
    LocalImageTokenBytesLoader loader,
  ) async {
    final generation = _generation;
    final token = _loadToken;
    try {
      final bytes = await loader(widget.image, token);
      token.throwIfCancelled();
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          !_pipelineAuthoritativeStatic) {
        return;
      }
      final detected = detectLocalImageFormat(bytes, fileLength: bytes.length);
      if (detected == null) {
        throw const FormatException('Pipeline static image bytes are invalid');
      }
      final provider = MemoryImage(bytes);
      setState(() {
        _detectedFormat = detected;
        _imageProvider = provider;
      });
      widget.traceSink.record(
        traceEvent(
          clock: widget.traceClock ?? const SystemClock(),
          sessionId: widget.traceSessionId,
          kind: TraceEventKind.staticEncodedPresentation,
          identityHash: widget.downloadIdentity?.key,
          revision: widget.demandRevision?.call(),
          payload: <String, Object?>{
            'format': detected.name,
            'bytes': bytes.lengthInBytes,
            'route': 'pipeline-compressed-bytes-flutter-codec',
          },
        ),
      );
    } on Object catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _publish(ImagePreviewState.invalid(_detectedFormat, error));
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
        final provider = localImageDirectFileProvider(widget.image);
        if (provider == null) {
          throw StateError('local file provider is unavailable');
        }
        if (!mounted || generation != _generation || token != _loadToken) {
          return;
        }
        setState(() => _imageProvider = provider);
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
      widget.onPlaybackCapabilityChanged?.call(
        detected == LocalImageFormat.gif,
      );
      setState(() {
        _detectedFormat = detected;
        _bytes = bytes;
        _imageProvider = provider;
      });
      if (provider != null) {
        final dimensions = _staticImageDimensions(bytes, detected);
        if (dimensions != null) {
          _reportDimensions(dimensions.width, dimensions.height);
        }
      }
      if (provider != null && decodeProbe != null) {
        _publish(ImagePreviewState.ready(detected));
      }
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token != _loadToken ||
          token.isCancelled) {
        return;
      }
      _publish(ImagePreviewState.invalid(_detectedFormat, error));
    }
  }

  @override
  void dispose() {
    final streaming = widget.pageStream;
    final listener = _pageStreamingListener;
    if (streaming != null && listener != null) {
      streaming.removeListener(listener);
    }
    final output = widget.pageOutput;
    final outputListener = _pageOutputListener;
    if (output != null && outputListener != null) {
      output.removeListener(outputListener);
    }

    _generation++;
    _loadToken.cancel();
    super.dispose();
  }

  void _reportDimensions(
    int width,
    int height, {
    bool authoritative = true,
  }) {
    if (width <= 0 || height <= 0) {
      return;
    }
    if (!authoritative && _reportedDimensionsAuthoritative) {
      return;
    }
    final dimensions = Size(width.toDouble(), height.toDouble());
    final changed = _reportedDimensions != dimensions;
    final authoritativeChanged =
        authoritative && !_reportedDimensionsAuthoritative;
    if (!changed && !authoritativeChanged) {
      return;
    }
    void commit() {
      _reportedDimensions = dimensions;
      _reportedDimensionsAuthoritative =
          _reportedDimensionsAuthoritative || authoritative;
    }
    if (mounted) {
      if (_reportedDimensions == null) {
        commit();
      } else {
        setState(commit);
      }
    } else {
      commit();
    }
    // Surface/output dimensions describe the decoded presentation raster, not
    // the source canvas. Keep them local for rendering, but only source/header
    // metadata may escape through the geometry callback. An authoritative
    // upgrade is reported even when it has the same numeric size as a prior
    // provisional raster.
    if (!authoritative) {
      return;
    }
    try {
      widget.onDimensionsChanged?.call(dimensions);
    } on Object catch (error) {
      debugPrint('image dimensions observer failed: $error');
    }
  }

  void _scheduleStaticFramePresented(
    int generation,
    LocalImageFormat format,
  ) {
    if (_state.phase == ImagePreviewPhase.ready ||
        _scheduledStaticFrameGeneration == generation) {
      return;
    }
    _scheduledStaticFrameGeneration = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || _imageProvider == null) {
        return;
      }
      _publish(ImagePreviewState.ready(format));
      _reportFirstFrame();
    });
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
        _publish(ImagePreviewState.invalid(_detectedFormat, error));
      }
    });
  }

  void _onWebpState(WebpPreviewState state) {
    switch (state.phase) {
      case WebpPreviewPhase.loading:
        break;
      case WebpPreviewPhase.ready:
        final info = state.info;
        if (info != null) {
          _reportDimensions(info.width, info.height);
        }
        // Container validation is not presentation readiness. The outer local
        // image state becomes ready only after the Flutter/native renderer
        // reports an actually presented first frame.
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

  void _schedulePipelineOutputFirstFrame(PipelinePageSurface surface) {
    if (_reportedFirstFrame || identical(_scheduledOutputSurface, surface)) {
      return;
    }
    _scheduledOutputSurface = surface;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _reportedFirstFrame ||
          !identical(_pageOutputSnapshot?.surface, surface)) {
        return;
      }
      _scheduledOutputSurface = null;
      _onWebpFirstFrame();
    });
  }

  void _onWebpFirstFrame() {
    _publish(ImagePreviewState.ready(LocalImageFormat.webp));
    _reportFirstFrame();
  }

  void _onControlledReady() {
    _publish(ImagePreviewState.ready(_detectedFormat));
    _reportFirstFrame();
  }

  void _onControlledError(Object error) {
    _publish(ImagePreviewState.invalid(_detectedFormat, error));
  }

  Widget _loadingIndicator() => const Center(
        child: CircularProgressIndicator(
          key: imagePageLoadingIndicatorKey,
        ),
      );

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
    } else if (_pipelineAuthoritativeStatic) {
      if (imageProvider == null) {
        content = _loadingIndicator();
      } else {
        content = MediaRasterImage(
          image: imageProvider,
          dimensions: _reportedDimensions,
          fit: widget.fit,
          imageKey: imageFolderFlutterPreviewKey,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (frame != null || wasSynchronouslyLoaded) {
              _scheduleStaticFramePresented(
                _generation,
                _detectedFormat,
              );
            }
            return child;
          },
          errorBuilder: (context, error, stackTrace) {
            _scheduleError(error);
            return const SizedBox.shrink();
          },
        );
      }
    } else if (_detectedFormat.isWebp) {
      final output = widget.pageOutput;
      if (output != null) {
        final surface = _pageOutputSnapshot?.surface;
        content = surface == null
            ? _loadingIndicator()
            : MediaAspectViewport(
                dimensions: _reportedDimensions,
                fit: widget.fit,
                builder: (innerFit) => surface.build(
                  key: webpNativeTextureViewportKey,
                  fit: innerFit,
                  filterQuality: widget.fit == BoxFit.fitWidth
                      ? FilterQuality.low
                      : FilterQuality.medium,
                ),
              );
      } else if (bytes == null) {
        content = _loadingIndicator();
      } else {
        content = MediaAspectViewport(
          dimensions: _reportedDimensions,
          fit: widget.fit,
          builder: (innerFit) => NativeWebpPlayer(
            title: widget.image.displayName,
            sourceUri: widget.sourceUri,
            loadBytes: (_) => Future<Uint8List>.value(bytes),
            showEngineControls: false,
            showStatus: false,
            initialEngine: WebpPlayerEngine.flutter,
            onPreviewStateChanged: _onWebpState,
            onFirstFrame: _onWebpFirstFrame,
            downloadIdentity: widget.downloadIdentity,
            traceClock: widget.traceClock,
            traceSink: widget.traceSink,
            traceSessionId: widget.traceSessionId,
            demandRevision: widget.demandRevision,
            playback: widget.playback,
            onPlaybackCapabilityChanged: widget.onPlaybackCapabilityChanged,
            fit: innerFit,
            flutterAnimatedCodecFactory: widget.flutterAnimatedCodecFactory,
          ),
        );
      }
    } else if (widget.playback != null &&
        _detectedFormat == LocalImageFormat.gif) {
      if (bytes == null) {
        content = _loadingIndicator();
      } else {
        content = MediaAspectViewport(
          dimensions: _reportedDimensions,
          fit: widget.fit,
          builder: (innerFit) => _ControlledAnimatedImage(
            bytes: bytes,
            playback: widget.playback!,
            onReady: _onControlledReady,
            onError: _onControlledError,
            codecFactory: widget.flutterAnimatedCodecFactory,
            fit: innerFit,
            downloadIdentity: widget.downloadIdentity,
            traceClock: widget.traceClock,
            traceSink: widget.traceSink,
            traceSessionId: widget.traceSessionId,
            demandRevision: widget.demandRevision,
          ),
        );
      }
    } else if (imageProvider == null) {
      content = _loadingIndicator();
    } else {
      content = MediaRasterImage(
        image: imageProvider,
        dimensions: _reportedDimensions,
        fit: widget.fit,
        imageKey: imageFolderFlutterPreviewKey,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame != null || wasSynchronouslyLoaded) {
            _scheduleStaticFramePresented(
              _generation,
              _detectedFormat,
            );
          }
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          _scheduleError(error);
          return const SizedBox.shrink();
        },
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

final class MediaRasterImage extends StatelessWidget {
  const MediaRasterImage({
    required this.image,
    required this.dimensions,
    required this.fit,
    this.imageKey,
    this.frameBuilder,
    this.errorBuilder,
    super.key,
  });

  final ImageProvider<Object> image;
  final Size? dimensions;
  final BoxFit fit;
  final Key? imageKey;
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    final source = dimensions;
    return LayoutBuilder(
      builder: (context, constraints) {
        ImageProvider<Object> provider = image;
        if (source != null &&
            source.width > 0 &&
            source.height > 0 &&
            constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final raster = AlignedRasterSize.fit(
            sourceWidth: source.width.round(),
            sourceHeight: source.height.round(),
            maxWidth: math.max(8, (constraints.maxWidth * ratio).floor()),
            maxHeight: math.max(8, (constraints.maxHeight * ratio).floor()),
          );
          provider = ResizeImage.resizeIfNeeded(
            raster.width < source.width ? raster.width : null,
            raster.height < source.height ? raster.height : null,
            image,
          );
        }
        return MediaAspectViewport(
          dimensions: source,
          fit: fit,
          builder: (innerFit) => Image(
            image: provider,
            key: imageKey,
            width: double.infinity,
            height: double.infinity,
            fit: innerFit,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
            frameBuilder: frameBuilder,
            errorBuilder: errorBuilder,
          ),
        );
      },
    );
  }
}

typedef MediaAspectChildBuilder = Widget Function(BoxFit innerFit);

Alignment mediaAlignmentFor(BoxFit fit) =>
    fit == BoxFit.fitWidth ? Alignment.topCenter : Alignment.center;

final class MediaAspectViewport extends StatelessWidget {
  const MediaAspectViewport({
    required this.dimensions,
    required this.fit,
    required this.builder,
  });

  final Size? dimensions;
  final BoxFit fit;
  final MediaAspectChildBuilder builder;

  @override
  Widget build(BuildContext context) {
    final source = dimensions;
    if (source == null || source.width <= 0 || source.height <= 0) {
      return SizedBox.expand(child: builder(fit));
    }
    // Presentation must never inherit a transient aspect error from the
    // parent sliver. Continuous Reader owns page extent/navigation geometry,
    // while media owns source-aspect preservation. In fitWidth mode the page
    // top stays fixed and any temporary extent mismatch is clipped/blanked at
    // the trailing edge instead of stretching the texture until layout idles.
    return SizedBox.expand(
      key: mediaAspectViewportKey,
      child: FittedBox(
        fit: fit,
        alignment: mediaAlignmentFor(fit),
        clipBehavior: fit == BoxFit.fitWidth ? Clip.none : Clip.hardEdge,
        child: SizedBox(
          width: source.width,
          height: source.height,
          child: builder(BoxFit.fill),
        ),
      ),
    );
  }
}

({int width, int height})? _staticImageDimensions(
  Uint8List bytes,
  LocalImageFormat format,
) {
  final data = ByteData.sublistView(bytes);
  int u16le(int offset) => data.getUint16(offset, Endian.little);
  int u32le(int offset) => data.getUint32(offset, Endian.little);
  int i32le(int offset) => data.getInt32(offset, Endian.little);
  int u32be(int offset) => data.getUint32(offset, Endian.big);

  try {
    switch (format) {
      case LocalImageFormat.png:
        if (bytes.length >= 24) {
          return (width: u32be(16), height: u32be(20));
        }
        break;
      case LocalImageFormat.gif:
        if (bytes.length >= 10) {
          return (width: u16le(6), height: u16le(8));
        }
        break;
      case LocalImageFormat.bmp:
        if (bytes.length >= 26) {
          return (width: u32le(18), height: i32le(22).abs());
        }
        break;
      case LocalImageFormat.ico:
        if (bytes.length >= 8) {
          return (
            width: bytes[6] == 0 ? 256 : bytes[6],
            height: bytes[7] == 0 ? 256 : bytes[7],
          );
        }
        break;
      case LocalImageFormat.jpeg:
        var offset = 2;
        while (offset + 8 < bytes.length) {
          if (bytes[offset] != 0xff) {
            offset++;
            continue;
          }
          final marker = bytes[offset + 1];
          offset += 2;
          if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) {
            continue;
          }
          if (offset + 2 > bytes.length) break;
          final segmentLength = data.getUint16(offset, Endian.big);
          if (segmentLength < 2 || offset + segmentLength > bytes.length) break;
          final isStartOfFrame = marker >= 0xc0 &&
              marker <= 0xcf &&
              marker != 0xc4 &&
              marker != 0xc8 &&
              marker != 0xcc;
          if (isStartOfFrame && segmentLength >= 7) {
            return (
              width: data.getUint16(offset + 5, Endian.big),
              height: data.getUint16(offset + 3, Endian.big),
            );
          }
          offset += segmentLength;
        }
        break;
      case LocalImageFormat.webp:
      case LocalImageFormat.avif:
      case LocalImageFormat.heif:
      case LocalImageFormat.tiff:
        break;
    }
  } on RangeError {
    return null;
  }
  return null;
}

final class _ControlledAnimatedImage extends StatefulWidget {
  const _ControlledAnimatedImage({
    required this.bytes,
    required this.playback,
    required this.onReady,
    required this.onError,
    required this.codecFactory,
    this.fit = BoxFit.contain,
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
  final BoxFit fit;
  final int? targetWidth;
  final int? targetHeight;
  final DownloadId? downloadIdentity;
  final MonoClock? traceClock;
  final TraceSink traceSink;
  final String traceSessionId;
  final int Function()? demandRevision;
  final VoidCallback onReady;
  final ValueChanged<Object> onError;
  final FlutterAnimatedCodecFactory codecFactory;

  @override
  State<_ControlledAnimatedImage> createState() =>
      _ControlledAnimatedImageState();
}

final class _ControlledAnimatedImageState
    extends State<_ControlledAnimatedImage> {
  FlutterAnimatedCodec? _codec;
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
        oldWidget.targetHeight != widget.targetHeight ||
        oldWidget.codecFactory != widget.codecFactory) {
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
      final codec = await widget.codecFactory(
        widget.bytes,
        targetWidth: widget.targetWidth,
        targetHeight: widget.targetHeight,
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

      // Presentation readiness belongs to the frame that Flutter actually
      // completed, not merely to codec output. Awaiting endOfFrame also keeps
      // the old image alive until its replacement is visible and gives dispose
      // a generation boundary that prevents late callbacks from leaking into
      // the next widget test or Reader page.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _generation) {
        previous?.dispose();
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
      previous?.dispose();
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
      fit: widget.fit,
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
            // GIF is intrinsically animated. WebP is an unresolved animation
            // candidate until the decoder reports authoritative container
            // metadata; treating it as static here can suppress frame-zero
            // bootstrap before runtime classification has a chance to run.
            animatedHint: image.format == LocalImageFormat.gif ||
                image.format == LocalImageFormat.webp,
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
