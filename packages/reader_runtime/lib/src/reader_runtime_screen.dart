import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader/reader.dart';
import 'package:telemetry/telemetry.dart';

import 'flutter_reader_frame_timing_source.dart';
import 'flutter_reader_platform_frame_cadence.dart';
import 'reader_playback_controls.dart';
import 'reader_session_settings.dart';
import 'reader_zoom_decode.dart';
import 'reader_settings_fields.dart';
import 'reader_transfer_progress_indicator.dart';

SnackBar _copyableReaderErrorSnackBar(String message) => SnackBar(
      content: Text(message),
      action: SnackBarAction(
        label: '复制',
        onPressed: () => unawaited(
          Clipboard.setData(ClipboardData(text: message)),
        ),
      ),
    );

const readerTopControlsKey = ValueKey<String>('reader-top-controls');
const readerBottomControlsKey = ValueKey<String>('reader-bottom-controls');
const readerForceReloadKey = ValueKey<String>('reader-force-reload');
const readerPageSliderKey = ValueKey<String>('reader-page-slider');
const readerRotateKey = ValueKey<String>('reader-rotate');
const readerFavoriteKey = ValueKey<String>('reader-favorite');
const readerDownloadKey = ValueKey<String>('reader-download');
const readerComicSettingsKey = ValueKey<String>('reader-comic-settings');
const readerChapterTitleKey = ValueKey<String>('reader-chapter-title');
const readerPageSubtitleKey = ValueKey<String>('reader-page-subtitle');
const readerComicSettingsEnabledKey =
    ValueKey<String>('reader-comic-settings-enabled');
const readerAdaptiveSettingsKey = ValueKey<String>('reader-adaptive-settings');
const readerVerticalStitchKey = ValueKey<String>('reader-vertical-stitch');
const readerVerticalLongPressZoomKey =
    ValueKey<String>('reader-vertical-long-press-zoom');
const readerExistingProgressKey = ValueKey<String>('reader-existing-progress');
const readerNetworkProgressKey = ValueKey<String>('reader-network-progress');
typedef ReaderArtifactBytesLoader = PipelineArtifactBytesLoader;
typedef ReaderPageBytesLoader = Future<Uint8List> Function(
  MediaLoadToken token,
);
typedef ReaderPageDimensionsReporter = void Function(int width, int height);

final class ReaderPageRuntime {
  const ReaderPageRuntime({
    required this.chapter,
    required this.clock,
    required this.traceSink,
    required this.sessionId,
    required this.demandRevision,
    required this.loadBytes,
    required this.openEncodedPresentationFile,
    required this.recoverPresentationFailure,
    required this.retryPresentation,
    required this.playback,
    required this.pageStream,
    required this.pageOutput,
    required this.reportPlaybackCapability,
    required this.reportDimensions,
    required this.mediaFit,
  });

  final ChapterManifest chapter;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final int Function() demandRevision;
  final ReaderPageBytesLoader loadBytes;
  final Future<PipelineEncodedPresentationFileLease?> Function(MediaLoadToken token)
      openEncodedPresentationFile;
  final Future<bool> Function(Object error) recoverPresentationFailure;
  final Future<bool> Function() retryPresentation;
  final ReaderPlaybackController playback;
  final PipelinePageStream pageStream;
  final PipelinePageOutputStream pageOutput;
  final ValueChanged<bool> reportPlaybackCapability;
  final ReaderPageDimensionsReporter reportDimensions;
  final BoxFit mediaFit;
}

typedef ReaderArtifactPageBuilder = Widget? Function(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
  ReaderPageRuntime runtime,
);
typedef ReaderPageSubtitleBuilder = String Function(PageAsset asset);
typedef ReaderProgressWriter = FutureOr<void> Function(
  ReadingProgress progress,
);
typedef ReaderProgressFlush = FutureOr<void> Function();
typedef ReaderSessionSettingsWriter = FutureOr<void> Function(
  ReaderSessionSettings settings,
);

final class ReaderRuntimeScreen extends StatefulWidget {
  const ReaderRuntimeScreen({
    required this.chapter,
    required this.pipeline,
    this.adaptiveMetadata,
    this.artifactPageBuilder,
    this.pageSubtitleBuilder,
    this.initialProgress,
    this.onProgressChanged,
    this.onProgressFlush,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    this.initiallyImmersive = true,
    this.initialSettings = const ReaderSessionSettings(),
    this.onSettingsChanged,
    this.screenKey,
    super.key,
  });

  final ChapterManifest chapter;
  final PipelineReaderSession pipeline;
  final AdaptiveReaderMetadata? adaptiveMetadata;
  final ReaderArtifactPageBuilder? artifactPageBuilder;
  final ReaderPageSubtitleBuilder? pageSubtitleBuilder;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final ReaderProgressFlush? onProgressFlush;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final bool initiallyImmersive;
  final ReaderSessionSettings initialSettings;
  final ReaderSessionSettingsWriter? onSettingsChanged;
  final Key? screenKey;

  @override
  State<ReaderRuntimeScreen> createState() => _ReaderRuntimeScreenState();
}

final class _ReaderRuntimeScreenState extends State<ReaderRuntimeScreen>
    with WidgetsBindingObserver {
  PipelineReaderSession get _pipeline => widget.pipeline;
  ReaderController? _reader;
  DecodeTarget? _target;
  int? _lastProgressPage;
  ReaderMode? _lastProgressMode;
  ReadingProgress? _pendingProgress;
  Future<void>? _progressDrain;
  late final ReaderPlaybackController _playback;
  final Map<String, bool> _playbackCapabilities = <String, bool>{};
  final Map<String, int> _presentationReloadRevisions = <String, int>{};
  late final ValueNotifier<int> _playbackCapabilityRevision;
  late final ValueNotifier<Map<String, double>> _pageAspectRatios;
  final Map<String, double> _pendingPageAspectRatios = <String, double>{};
  final Map<String, PipelinePageDimensionBasis> _pageAspectBases =
      <String, PipelinePageDimensionBasis>{};
  bool _pageAspectRatioUpdateScheduled = false;
  late bool _favorite;
  late bool _controlsVisible;
  bool _downloading = false;
  bool _downloaded = false;
  late ReaderSessionSettings _settings;
  late final AdaptiveReaderClassifier _adaptiveClassifier;
  AdaptiveReaderProfile? _adaptiveProfile;
  FlutterReaderPlatformFrameCadenceProbe? _platformFrameCadenceProbe;
  DecodeTarget? _appliedZoomDecodeTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageAspectRatios =
        ValueNotifier<Map<String, double>>(const <String, double>{});
    _playbackCapabilityRevision = ValueNotifier<int>(0);
    _playback = ReaderPlaybackController()
      ..addListener(_syncPipelinePlayback);
    _syncPipelinePlayback();
    _settings = widget.initialSettings;
    _adaptiveClassifier = AdaptiveReaderClassifier(
      widget.chapter,
      metadata: widget.adaptiveMetadata,
    );
    _adaptiveProfile = _initialAdaptiveProfile(_settings);
    _pipeline.pageDimensions.addListener(_handlePipelinePageDimensions);
    final initialProfile = _adaptiveProfile;
    if (initialProfile != null &&
        initialProfile != _settings.adaptiveProfile) {
      _settings = _settings.copyWith(adaptiveProfile: initialProfile);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _persistSettings();
      });
    }
    _favorite = widget.initialFavorite;
    _controlsVisible = !widget.initiallyImmersive;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        widget.initiallyImmersive
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ReaderRuntimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFavorite != widget.initialFavorite) {
      _favorite = widget.initialFavorite;
    }
    if (oldWidget.initialSettings != widget.initialSettings) {
      _settings = widget.initialSettings;
      _adaptiveProfile = _initialAdaptiveProfile(_settings);
    }
    if (oldWidget.adaptiveMetadata?.fingerprint !=
        widget.adaptiveMetadata?.fingerprint) {
      throw StateError(
        'ReaderRuntimeScreen adaptive metadata is immutable for a mounted '
        'session; replace the widget key when comic metadata changes',
      );
    }
    if (!_sameChapterSession(oldWidget.chapter, widget.chapter)) {
      throw StateError(
        'ReaderRuntimeScreen chapter identity is immutable for a mounted '
        'session; replace the widget key to open another chapter or source '
        'revision',
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    final target = DecodeTarget.viewport(
      logicalWidth: media.size.width,
      logicalHeight: media.size.height,
      devicePixelRatio: media.devicePixelRatio,
      renderer: _pipeline.renderer,
    );
    if (_target == target) {
      return;
    }
    final reader = _reader;
    if (reader != null) {
      // Decode target belongs to the pipeline/media projection, not Reader
      // navigation. System-UI/MediaQuery changes must not destroy current or
      // pending page commands. Update only decode-target configuration and
      // replay the latest viewport fact through the enqueue boundary.
      _pipeline.updateDecodeTarget(target);
      _target = target;
      final observation = reader.lastObservation;
      if (observation != null) {
        _pipeline.enqueueObservation(observation);
      }
      return;
    }

    final initialProgress = _matchingInitialProgress();
    final currentIndex = (initialProgress?.pageIndex ?? 0)
        .clamp(0, widget.chapter.pages.length - 1)
        .toInt();
    final direction = _resolveInitialDirection(initialProgress);
    _pipeline.attach(target);
    final created = ReaderController(
      sessionId: _pipeline.sessionId,
      chapter: widget.chapter,
      initialPage: currentIndex,
      onObservation: _pipeline.enqueueObservation,
      clock: _pipeline.clock,
      traceSink: _pipeline.trace,
    );
    created.setDirection(direction);
    created.currentIndexListenable.addListener(_handleReaderProgress);
    _target = target;
    _reader = created;
    _syncPlatformFrameCadenceProbe();
    _lastProgressPage = created.currentIndex;
    _lastProgressMode = _readerMode(created.direction);
  }

  ReadingDirection _resolveInitialDirection(ReadingProgress? progress) {
    final base = progress?.readerMode == ReaderMode.continuous
        ? ReadingDirection.vertical
        : widget.chapter.readingDirection;
    if (_settings.comicSpecificEnabled &&
        _settings.directionOverride != null) {
      return _settings.directionOverride!;
    }
    final adaptive = _adaptiveProfile;
    if (_settings.effectiveAdaptiveEnabled &&
        adaptive != null &&
        adaptive.confidence >= 0.6) {
      return adaptive.direction;
    }
    return base;
  }

  AdaptiveReaderProfile? _initialAdaptiveProfile(
    ReaderSessionSettings settings,
  ) {
    if (!settings.effectiveAdaptiveEnabled) return null;
    final stored = settings.adaptiveProfile;
    if (stored != null &&
        stored.isCurrent &&
        stored.metadataFingerprint == _adaptiveClassifier.metadataFingerprint &&
        stored.confidence >= AdaptiveReaderProfile.applyConfidence) {
      return stored;
    }
    return _adaptiveClassifier.classifyManifest();
  }

  void _applyAdaptiveProfile(AdaptiveReaderProfile? candidate) {
    if (candidate == null ||
        candidate.confidence < AdaptiveReaderProfile.applyConfidence ||
        !_settings.effectiveAdaptiveEnabled ||
        (_settings.comicSpecificEnabled &&
            _settings.directionOverride != null)) {
      return;
    }
    final current = _adaptiveProfile;
    if (current != null) {
      if (current.animated && !candidate.animated) return;
      if (!candidate.animated && current.isCurrent && current.isTerminal) {
        return;
      }
      if (current == candidate) return;
    }
    _adaptiveProfile = candidate;
    _settings = _settings.copyWith(adaptiveProfile: candidate);
    _reader?.setDirection(candidate.direction);
    _syncPlatformFrameCadenceProbe();
    _persistSettings();
  }

  void _persistSettings() {
    final writer = widget.onSettingsChanged;
    if (writer == null) return;
    Future<void>.sync(() => writer(_settings)).catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('reader settings write failed: $error');
      },
    );
  }

  ReadingProgress? _matchingInitialProgress() {
    final progress = widget.initialProgress;
    if (progress == null ||
        progress.sourceId != widget.chapter.sourceId ||
        progress.comicId != widget.chapter.comicId ||
        progress.chapterId != widget.chapter.chapter.chapterId) {
      return null;
    }
    return progress;
  }

  void _handleReaderProgress() {
    unawaited(_checkpointReaderProgress());
  }

  ReadingProgress? _currentReaderProgress({bool force = false}) {
    final reader = _reader;
    final writer = widget.onProgressChanged;
    if (reader == null || writer == null) return null;
    final mode = _readerMode(reader.direction);
    if (!force &&
        _lastProgressPage == reader.currentIndex &&
        _lastProgressMode == mode) {
      return null;
    }
    _lastProgressPage = reader.currentIndex;
    _lastProgressMode = mode;
    return ReadingProgress(
      sourceId: widget.chapter.sourceId,
      comicId: widget.chapter.comicId,
      chapterId: widget.chapter.chapter.chapterId,
      pageIndex: reader.currentIndex,
      subPageOffset: 0,
      readerMode: mode,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _checkpointReaderProgress({bool force = false}) {
    final progress = _currentReaderProgress(force: force);
    if (progress != null) _pendingProgress = progress;
    final active = _progressDrain;
    if (active != null) return active;
    if (_pendingProgress == null || widget.onProgressChanged == null) {
      return Future<void>.value();
    }
    late final Future<void> drain;
    drain = _drainReaderProgress().whenComplete(() {
      if (!identical(_progressDrain, drain)) return;
      _progressDrain = null;
      if (_pendingProgress != null) {
        unawaited(_checkpointReaderProgress());
      }
    });
    _progressDrain = drain;
    return drain;
  }

  Future<void> _drainReaderProgress() async {
    final writer = widget.onProgressChanged;
    if (writer == null) {
      _pendingProgress = null;
      return;
    }
    while (_pendingProgress != null) {
      final progress = _pendingProgress!;
      _pendingProgress = null;
      try {
        final dispatchStartedAt = _pipeline.clock.nowMicros();
        final write = Future<void>.sync(() => writer(progress));
        final dispatchMicros =
            _pipeline.clock.nowMicros() - dispatchStartedAt;
        if (dispatchMicros >= 5000) {
          _pipeline.trace.record(
            traceEvent(
              clock: _pipeline.clock,
              sessionId: _pipeline.sessionId,
              kind: TraceEventKind.readerObservation,
              revision: _pipeline.revision,
              payload: <String, Object?>{
                'stage': 'progress-checkpoint-dispatch',
                'pageIndex': progress.pageIndex,
                'durationMicros': dispatchMicros,
              },
            ),
          );
        }
        await write;
      } on Object catch (error) {
        debugPrint('reader progress write failed: $error');
      }
    }
  }

  Future<void> _checkpointAndFlushReaderProgress() async {
    await _checkpointReaderProgress(force: true);
    while (_pendingProgress != null || _progressDrain != null) {
      await _checkpointReaderProgress();
    }
    final flush = widget.onProgressFlush;
    if (flush != null) {
      await Future<void>.sync(flush);
    }
  }

  Future<bool> _flushProgressBeforePop() async {
    try {
      await _checkpointAndFlushReaderProgress();
    } on Object catch (error) {
      debugPrint('reader progress flush failed: $error');
    }
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
        _checkpointAndFlushReaderProgress().catchError(
          (Object error, StackTrace _) {
            debugPrint('reader lifecycle progress flush failed: $error');
          },
        ),
      );
    }
  }

  ReaderMode _readerMode(ReadingDirection direction) =>
      direction == ReadingDirection.vertical
          ? ReaderMode.continuous
          : ReaderMode.paged;

  String _playbackSpeedLabel(double speed) {
    final tenths = speed * 10;
    final digits = speed == speed.roundToDouble()
        ? 0
        : tenths == tenths.roundToDouble()
            ? 1
            : 2;
    return '${speed.toStringAsFixed(digits)}×';
  }

  Future<void> _choosePlaybackSpeed() async {
    final selected = await showDialog<double>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('播放速度'),
        children: <Widget>[
          for (final speed in const <double>[0.5, 0.75, 1, 1.5, 2])
            SimpleDialogOption(
              key: readerSpeedOptionKey(speed),
              onPressed: () => Navigator.pop(context, speed),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 28,
                    child: speed == _playback.value.speed
                        ? const Icon(Icons.check, size: 20)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_playbackSpeedLabel(speed)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null && mounted) {
      _playback.setSpeed(selected);
    }
  }

  bool _currentPageSupportsPlayback(ReaderController reader) =>
      _playbackCapabilities[widget.chapter.pages[reader.currentIndex].assetKey] == true;

  void _reportPlaybackCapability(PageAsset asset, bool supported) {
    if (!mounted) return;
    if (_playbackCapabilities[asset.assetKey] == supported) return;
    _playbackCapabilities[asset.assetKey] = supported;
    final reader = _reader;
    if (reader != null &&
        widget.chapter.pages[reader.currentIndex].assetKey == asset.assetKey) {
      _playbackCapabilityRevision.value++;
    }
    if (supported) {
      _applyAdaptiveProfile(_adaptiveClassifier.observeAnimated(asset));
    }
  }

  void _handlePipelinePageDimensions(PipelinePageDimensions dimensions) {
    if (!mounted) return;
    final pageIndex = dimensions.pageIndex;
    if (pageIndex < 0 || pageIndex >= widget.chapter.pages.length) return;
    final asset = widget.chapter.pages[pageIndex];
    if (asset.assetKey != dimensions.assetKey) return;
    _reportPageDimensions(
      asset,
      dimensions.width,
      dimensions.height,
      basis: dimensions.basis,
    );
  }

  void _reportPageDimensions(
    PageAsset asset,
    int width,
    int height, {
    PipelinePageDimensionBasis basis = PipelinePageDimensionBasis.sourceCanvas,
  }) {
    if (width <= 0 || height <= 0) return;
    final assetKey = asset.assetKey;
    final priorBasis = _pageAspectBases[assetKey];
    if (priorBasis == PipelinePageDimensionBasis.sourceCanvas &&
        basis == PipelinePageDimensionBasis.decodedRaster) {
      return;
    }

    final sourceWidth = asset.width;
    final sourceHeight = asset.height;
    final hasIntrinsicSource = sourceWidth != null &&
        sourceHeight != null &&
        sourceWidth > 0 &&
        sourceHeight > 0;
    if (basis == PipelinePageDimensionBasis.decodedRaster &&
        hasIntrinsicSource) {
      return;
    }

    _applyAdaptiveProfile(
      _adaptiveClassifier.observeDimensions(asset, width, height),
    );
    final ratio = height / width;
    if (basis == PipelinePageDimensionBasis.sourceCanvas) {
      _pageAspectBases[assetKey] = basis;
    } else {
      _pageAspectBases.putIfAbsent(assetKey, () => basis);
    }

    if (hasIntrinsicSource && basis == PipelinePageDimensionBasis.sourceCanvas) {
      final intrinsicRatio = sourceHeight / sourceWidth;
      final relativeDifference =
          (intrinsicRatio - ratio).abs() / intrinsicRatio;
      if (relativeDifference < 0.01) {
        return;
      }
    }
    final prior = _pendingPageAspectRatios[assetKey] ??
        _pageAspectRatios.value[assetKey];
    if (prior != null && (prior - ratio).abs() < 0.001) return;
    _pendingPageAspectRatios[assetKey] = ratio;
    if (_pageAspectRatioUpdateScheduled) return;
    _pageAspectRatioUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageAspectRatioUpdateScheduled = false;
      if (!mounted || _pendingPageAspectRatios.isEmpty) return;
      final updated = <String, double>{
        ..._pageAspectRatios.value,
        ..._pendingPageAspectRatios,
      };
      _pendingPageAspectRatios.clear();
      _pageAspectRatios.value = Map<String, double>.unmodifiable(updated);
    });
  }

  void _syncPlatformFrameCadenceProbe() {
    final reader = _reader;
    final vertical = reader?.direction == ReadingDirection.vertical;
    if (vertical && reader != null) {
      if (_platformFrameCadenceProbe != null) return;
      final probe = FlutterReaderPlatformFrameCadenceProbe(
        clock: _pipeline.clock,
        traceSink: _pipeline.trace,
        sessionId: reader.sessionId,
        revision: () => _pipeline.revision,
      );
      _platformFrameCadenceProbe = probe;
      unawaited(probe.start());
      return;
    }
    final probe = _platformFrameCadenceProbe;
    _platformFrameCadenceProbe = null;
    if (probe != null) {
      unawaited(probe.stop());
    }
  }

  bool _effectiveLongPressZoom(ReaderController reader) =>
      reader.direction == ReadingDirection.vertical
          ? _settings.effectiveLongPressZoomVertical
          : _settings.effectiveLongPressZoomPaged;

  Size get _mediaQuerySize => MediaQueryData.fromView(View.of(context)).size;
  double get _mediaQueryDevicePixelRatio =>
      MediaQueryData.fromView(View.of(context)).devicePixelRatio;

  void _handleZoomScaleChanged(double scale) {
    final reader = _reader;
    final base = _target;
    if (reader == null || base == null || !mounted) return;
    final asset = widget.chapter.pages[reader.currentIndex];
    final boosted = boostedDecodeTargetForZoom(
      base,
      scale: scale,
      enabled: _settings.zoomDecodeBoost && !_playback.value.paused,
      viewportLogicalWidth: _mediaQuerySize.width.round(),
      viewportLogicalHeight: _mediaQuerySize.height.round(),
      devicePixelRatio: _mediaQueryDevicePixelRatio,
      maxSourceWidth: asset.width,
      maxSourceHeight: asset.height,
    );
    final next = boosted ?? base;
    if (next == base && _appliedZoomDecodeTarget == null) return;
    if (next == _appliedZoomDecodeTarget) return;
    _pipeline.updateDecodeTarget(next);
    _target = next;
    _appliedZoomDecodeTarget = next == base ? null : next;
  }

  void _syncPipelinePlayback() {
    final state = _playback.value;
    _pipeline.setPlayback(paused: state.paused, speed: state.speed);
  }

  @override
  void dispose() {
    final platformFrameCadenceProbe = _platformFrameCadenceProbe;
    _platformFrameCadenceProbe = null;
    if (platformFrameCadenceProbe != null) {
      unawaited(platformFrameCadenceProbe.stop());
    }
    unawaited(_checkpointReaderProgress(force: true));
    _pipeline.pageDimensions.removeListener(_handlePipelinePageDimensions);
    WidgetsBinding.instance.removeObserver(this);
    _playbackCapabilityRevision.dispose();
    final reader = _reader;
    if (reader != null) {
      reader.currentIndexListenable.removeListener(_handleReaderProgress);
      _pipeline.detach(reader.sessionId);
      reader.dispose();
    }
    _playback.removeListener(_syncPipelinePlayback);
    _playback.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _toggleControls() {
    final visible = !_controlsVisible;
    setState(() => _controlsVisible = visible);
    _pipeline.trace.record(
      traceEvent(
        clock: _pipeline.clock,
        sessionId: _pipeline.sessionId,
        kind: TraceEventKind.readerObservation,
        revision: _pipeline.revision,
        payload: <String, Object?>{
          'stage': 'reader-controls-visibility',
          'visible': visible,
          'pageCount': widget.chapter.pages.length,
        },
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        _controlsVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
  }

  void _togglePlaybackPaused() {
    _playback.togglePaused();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _forceReloadCurrentPage(ReaderController reader) async {
    final asset = widget.chapter.pages[reader.currentIndex];
    try {
      final reloaded = await _pipeline.forceReloadPresentation(asset);
      if (!mounted) return;
      if (!reloaded) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前页未能开始强制重新加载')),
        );
        return;
      }
      setState(() {
        _presentationReloadRevisions[asset.assetKey] =
            (_presentationReloadRevisions[asset.assetKey] ?? 0) + 1;
        _playbackCapabilities.remove(asset.assetKey);
      });
      _playbackCapabilityRevision.value++;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已强制重新加载当前页')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        _copyableReaderErrorSnackBar('强制重新加载失败：$error'),
      );
    }
  }

  Future<void> _toggleFavorite() async {
    final callback = widget.onFavoriteChanged;
    if (callback == null) {
      return;
    }
    final next = !_favorite;
    setState(() => _favorite = next);
    try {
      await Future<void>.sync(() => callback(next));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _favorite = !next);
      ScaffoldMessenger.of(context).showSnackBar(
        _copyableReaderErrorSnackBar('收藏状态保存失败：$error'),
      );
    }
  }

  Future<void> _downloadChapter() async {
    if (_downloading || _downloaded) {
      return;
    }
    setState(() => _downloading = true);
    try {
      final external = widget.onDownloadRequested;
      if (external == null) {
        throw StateError(
          'chapter download command must be supplied by pipeline composition',
        );
      }
      await Future<void>.sync(external);
      if (!mounted) {
        return;
      }
      setState(() => _downloaded = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本章已缓存')),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _copyableReaderErrorSnackBar('缓存本章失败：$error'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
      }
    }
  }

  String _directionLabel(ReadingDirection? direction) => switch (direction) {
        ReadingDirection.ltr => 'LTR',
        ReadingDirection.rtl => 'RTL',
        ReadingDirection.vertical => '纵向',
        null => '跟随来源/进度',
      };

  String _adaptiveProfileLabel(ReaderSessionSettings settings) {
    final profile = _adaptiveProfile;
    if (!settings.globalAdaptiveEnabled) return '全局自适应未启用';
    if (!settings.comicAdaptiveEnabled) return '本漫画已停用自适应';
    if (profile == null) return '暂无高置信度结果';
    final confidence = (profile.confidence * 100).round();
    final kind = profile.animated
        ? '动画分页'
        : _directionLabel(profile.direction);
    final basis = switch (profile.basis) {
      'animated-pages' => '动画页提示',
      'page-geometry' => '页面比例',
      'decoded-animation' => '实际动画页',
      'runtime-animation' => '实际动画页',
      _ => profile.basis,
    };
    return '$kind · $confidence% · $basis';
  }

  Future<void> _editComicSettings() async {
    var draft = _settings;
    final saved = await showModalBottomSheet<ReaderSessionSettings>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                16 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '本漫画阅读设置',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SwitchListTile(
                    key: readerComicSettingsEnabledKey,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用本漫画设置'),
                    subtitle: const Text(
                      '方向与拼接覆盖全局默认；关闭后仍可单独停用自适应。',
                    ),
                    value: draft.comicSpecificEnabled,
                    onChanged: (value) => setSheetState(
                      () => draft = draft.copyWith(
                        comicSpecificEnabled: value,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: readerAdaptiveSettingsKey,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用自适应设置'),
                    subtitle: Text(_adaptiveProfileLabel(draft)),
                    value: draft.comicAdaptiveEnabled,
                    onChanged: draft.globalAdaptiveEnabled
                        ? (value) => setSheetState(
                              () => draft = draft.copyWith(
                                comicAdaptiveEnabled: value,
                              ),
                            )
                        : null,
                  ),
                  if (draft.comicSpecificEnabled) ...<Widget>[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: draft.directionOverride?.name ?? 'follow',
                      decoration: const InputDecoration(
                        labelText: '阅读方向',
                        border: OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        const DropdownMenuItem(
                          value: 'follow',
                          child: Text('跟随来源/进度或自适应'),
                        ),
                        for (final direction in ReadingDirection.values)
                          DropdownMenuItem(
                            value: direction.name,
                            child: Text(_directionLabel(direction)),
                          ),
                      ],
                      onChanged: (value) => setSheetState(
                        () => draft = draft.copyWith(
                          directionOverride: value == null || value == 'follow'
                              ? null
                              : ReadingDirection.values.byName(value),
                        ),
                      ),
                    ),
                    readerVerticalStitchOverrideField(
                      key: readerVerticalStitchKey,
                      value: draft.verticalStitchOverride,
                      onChanged: (value) => setSheetState(
                        () => draft = draft.copyWith(
                          verticalStitchOverride: value,
                        ),
                      ),
                    ),
                    readerVerticalLongPressZoomField(
                      key: readerVerticalLongPressZoomKey,
                      value: draft.verticalLongPressZoomOverride,
                      onChanged: (value) => setSheetState(
                        () => draft = draft.copyWith(
                          verticalLongPressZoomOverride: value,
                        ),
                      ),
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('翻转阅读顺序'),
                      subtitle: const Text('由旧到新正序阅读（末页作为第一话）'),
                      value: draft.effectiveInvertPageOrder,
                      onChanged: (value) => setSheetState(
                        () => draft = draft.copyWith(
                          invertPageOrderOverride: value,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(
                          context,
                          ReaderSessionSettings(
                            fallbackVerticalStitch:
                                draft.fallbackVerticalStitch,
                            globalAdaptiveEnabled:
                                draft.globalAdaptiveEnabled,
                          ),
                        ),
                        child: const Text('清除本漫画设置'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, draft),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() {
      _settings = saved;
      _adaptiveProfile = _initialAdaptiveProfile(_settings);
      if (_adaptiveProfile != _settings.adaptiveProfile) {
        _settings = _settings.copyWith(adaptiveProfile: _adaptiveProfile);
      }
    });
    _reader?.setDirection(_resolveInitialDirection(_matchingInitialProgress()));
    _syncPlatformFrameCadenceProbe();
    final writer = widget.onSettingsChanged;
    if (writer != null) {
      try {
        await Future<void>.sync(() => writer(_settings));
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            _copyableReaderErrorSnackBar('保存本漫画阅读设置失败：$error'),
          );
        }
      }
    }
  }

  Widget _topControls(
    BuildContext context,
    ReaderController reader,
  ) {
    if (!_controlsVisible) {
      return const SizedBox.shrink(key: readerTopControlsKey);
    }
    return SafeArea(
      key: readerTopControlsKey,
      bottom: false,
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  height: kToolbarHeight,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              widget.chapter.chapter.title,
                              key: readerChapterTitleKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            ValueListenableBuilder<int>(
                              valueListenable: reader.currentIndexListenable,
                              builder: (context, currentIndex, _) {
                                final subtitle = widget.pageSubtitleBuilder?.call(
                                  widget.chapter.pages[currentIndex],
                                );
                                if (subtitle == null || subtitle.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Text(
                                  subtitle,
                                  key: readerPageSubtitleKey,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.white70),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: readerForceReloadKey,
                        tooltip: '强制重新加载当前页',
                        onPressed: () =>
                            unawaited(_forceReloadCurrentPage(reader)),
                        icon: const Icon(Icons.refresh),
                      ),
                      if (widget.onSettingsChanged != null)
                        IconButton(
                          key: readerComicSettingsKey,
                          tooltip: '本漫画阅读设置',
                          onPressed: () => unawaited(_editComicSettings()),
                          icon: const Icon(Icons.tune),
                        ),
                    ],
                  ),
                ),
                ReaderTransferProgressFeedIndicator(
                  feed: _pipeline.transferProgress.feed,
                  networkKey: readerNetworkProgressKey,
                  partialKey: readerExistingProgressKey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _animationControls(ReaderController reader) =>
      ReaderAnimationControlsVisibility(
        currentIndex: reader.currentIndexListenable,
        capabilityRevision: _playbackCapabilityRevision,
        isVisible: () => _controlsVisible && _currentPageSupportsPlayback(reader),
        child: ReaderAnimationControls(
          playback: _playback,
          onTogglePaused: _togglePlaybackPaused,
          onChooseSpeed: () => unawaited(_choosePlaybackSpeed()),
          speedLabel: _playbackSpeedLabel,
        ),
      );

  Widget _bottomControls(
    BuildContext context,
    ReaderController reader,
  ) {
    if (!_controlsVisible) {
      return const SizedBox.shrink(key: readerBottomControlsKey);
    }
    final pages = widget.chapter.pages.length;
    return SafeArea(
      key: readerBottomControlsKey,
      top: false,
      child: Material(
        color: Colors.black.withValues(alpha: 0.78),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ValueListenableBuilder<int>(
                    valueListenable: reader.currentIndexListenable,
                    builder: (context, currentIndex, _) => _ReaderPageScrubber(
                      pages: pages,
                      direction: reader.direction,
                      currentIndex: currentIndex,
                      requestedIndex: reader.requestedIndex,
                      onScrubStarted: reader.beginPageScrub,
                      onScrubbed: reader.scrubToPage,
                      onScrubEnded: reader.endPageScrub,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      IconButton(
                        key: readerRotateKey,
                        tooltip: '顺时针旋转',
                        onPressed: reader.rotateClockwise,
                        icon: const Icon(Icons.rotate_right),
                      ),
                      IconButton(
                        key: readerFavoriteKey,
                        tooltip: _favorite ? '取消收藏' : '收藏',
                        onPressed: widget.onFavoriteChanged == null
                            ? null
                            : _toggleFavorite,
                        icon: Icon(
                          _favorite ? Icons.bookmark : Icons.bookmark_border,
                        ),
                      ),
                      if (widget.onDownloadRequested != null)
                        IconButton(
                          key: readerDownloadKey,
                          tooltip: _downloaded ? '本章已缓存' : '缓存本章',
                          onPressed: _downloading || _downloaded
                              ? null
                              : _downloadChapter,
                          icon: _downloading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _downloaded
                                      ? Icons.download_done
                                      : Icons.download_outlined,
                                ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reader = _reader!;
    final artifactBuilder = widget.artifactPageBuilder;
    final ReaderPageBuilder? pageBuilder = artifactBuilder == null
        ? null
        : (context, asset, reportFirstFrame) {
            final child = artifactBuilder(
              context,
              asset,
              reportFirstFrame,
              ReaderPageRuntime(
                chapter: widget.chapter,
                clock: _pipeline.clock,
                traceSink: _pipeline.trace,
                sessionId: reader.sessionId,
                demandRevision: () => _pipeline.revision,
                loadBytes: (token) =>
                    _pipeline.loadBytes(asset, token),
                openEncodedPresentationFile: (token) =>
                    _pipeline.openEncodedPresentationFile(asset, token),
                recoverPresentationFailure: (error) =>
                    _pipeline.recoverPresentationFailure(asset, error),
                retryPresentation: () =>
                    _pipeline.retryPresentation(asset),
                playback: _playback,
                pageStream: _pipeline.pageStream(asset),
                pageOutput: _pipeline.pageOutput(asset),
                reportPlaybackCapability: (supported) =>
                    _reportPlaybackCapability(asset, supported),
                reportDimensions: (width, height) =>
                    _reportPageDimensions(asset, width, height),
                mediaFit: reader.direction == ReadingDirection.vertical &&
                        _settings.effectiveVerticalStitch
                    ? BoxFit.fitWidth
                    : BoxFit.contain,
              ),
            );
            if (child == null) return null;
            final reloadRevision =
                _presentationReloadRevisions[asset.assetKey] ?? 0;
            return KeyedSubtree(
              key: ValueKey<String>(
                'reader-page-presentation:${asset.assetKey}:$reloadRevision',
              ),
              child: child,
            );
          };
    return WillPopScope(
      onWillPop: _flushProgressBeforePop,
      child: Scaffold(
        key: widget.screenKey,
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ReaderView(
              controller: reader,
              clock: _pipeline.clock,
              traceSink: _pipeline.trace,
              frameTimingSource: const FlutterReaderFrameTimingSource(),
              pageBuilder: pageBuilder,
              pagePresentationRevisions:
                  Map<String, int>.unmodifiable(_presentationReloadRevisions),
              demandRevision: () => _pipeline.revision,
              onTap: _toggleControls,
              verticalStitch: _settings.effectiveVerticalStitch,
              pageAspectRatiosListenable: _pageAspectRatios,
              zoomStageFirst: _settings.zoomStageFirst,
              zoomStageSecond: _settings.zoomStageSecond,
              longPressZoomEnabled: _effectiveLongPressZoom(reader),
              longPressZoomRestoreOnRelease:
                  _settings.longPressZoomRestoreOnRelease,
              longPressZoomMoveMode: _settings.longPressZoomMoveMode,
              longPressZoomPanRatio: _settings.longPressZoomPanRatio,
              longPressZoomLimitToViewport:
                  _settings.longPressZoomLimitToViewport,
              doubleTapZoomOrigin: _settings.doubleTapZoomOrigin,
              onZoomScaleChanged: _handleZoomScaleChanged,
            ),
            AnimatedBuilder(
              animation: reader,
              builder: (context, _) => AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: ExcludeSemantics(
                    excluding: !_controlsVisible,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _topControls(context, reader),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: reader,
              builder: (context, _) => AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: ExcludeSemantics(
                    excluding: !_controlsVisible,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _animationControls(reader),
                          _bottomControls(context, reader),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reader page scrub control.
///
/// The thumb and Reader navigation move together while dragging so page number
/// and viewport remain live. The pipeline distinguishes the resulting
/// `Interaction.scrubbing` observations and keeps only foreground-current
/// demand until the gesture ends, avoiding a full prefetch-window replan for
/// every intermediate index.
final class _ReaderPageScrubber extends StatefulWidget {
  const _ReaderPageScrubber({
    required this.pages,
    required this.direction,
    required this.currentIndex,
    required this.requestedIndex,
    required this.onScrubStarted,
    required this.onScrubbed,
    required this.onScrubEnded,
  });

  final int pages;
  final ReadingDirection direction;
  final int currentIndex;
  final int? requestedIndex;
  final VoidCallback onScrubStarted;
  final ValueChanged<int> onScrubbed;
  final ValueChanged<int> onScrubEnded;

  @override
  State<_ReaderPageScrubber> createState() => _ReaderPageScrubberState();
}

final class _ReaderPageScrubberState extends State<_ReaderPageScrubber> {
  int? _previewIndex;

  int get _displayIndex =>
      _previewIndex ?? widget.requestedIndex ?? widget.currentIndex;

  void _start(double value) {
    widget.onScrubStarted();
    _preview(value);
  }

  void _preview(double value) {
    final index = value.round().clamp(0, widget.pages - 1).toInt();
    if (_previewIndex == index) return;
    setState(() => _previewIndex = index);
    widget.onScrubbed(index);
  }

  void _commit(double value) {
    final index = value.round().clamp(0, widget.pages - 1).toInt();
    widget.onScrubEnded(index);
    if (!mounted) return;
    setState(() => _previewIndex = null);
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.pages;
    final displayIndex = _displayIndex
        .clamp(0, math.max(0, pages - 1))
        .toInt();
    final currentLabel = '${displayIndex + 1}';
    return Row(
      children: <Widget>[
        Text(
          widget.direction == ReadingDirection.rtl ? '$pages' : currentLabel,
        ),
        Expanded(
          child: Directionality(
            textDirection: widget.direction == ReadingDirection.rtl
                ? TextDirection.rtl
                : TextDirection.ltr,
            child: Slider(
              key: readerPageSliderKey,
              value: displayIndex.toDouble(),
              min: 0,
              max: math.max(1, pages - 1).toDouble(),
              // Page selection remains integer-quantized in [_preview]. A
              // hundreds-page chapter must not ask RenderSlider/semantics to
              // materialize one division per page on every current-page update.
              divisions: null,
              onChangeStart: pages <= 1 ? null : _start,
              onChanged: pages <= 1 ? null : _preview,
              onChangeEnd: pages <= 1 ? null : _commit,
            ),
          ),
        ),
        Text(
          widget.direction == ReadingDirection.rtl ? currentLabel : '$pages',
        ),
      ],
    );
  }
}

bool _sameChapterSession(ChapterManifest left, ChapterManifest right) {
  if (left.sourceId != right.sourceId ||
      left.comicId != right.comicId ||
      left.chapter.chapterId != right.chapter.chapterId ||
      left.chapter.sourceRevision != right.chapter.sourceRevision ||
      left.readingDirection != right.readingDirection ||
      left.pages.length != right.pages.length) {
    return false;
  }
  for (var index = 0; index < left.pages.length; index++) {
    final a = left.pages[index];
    final b = right.pages[index];
    if (a.pageId != b.pageId ||
        a.index != b.index ||
        a.uri != b.uri ||
        a.byteLength != b.byteLength ||
        a.contentKindHint != b.contentKindHint ||
        a.animatedHint != b.animatedHint) {
      return false;
    }
  }
  return true;
}
