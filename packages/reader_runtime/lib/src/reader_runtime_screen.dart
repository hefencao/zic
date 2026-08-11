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

import 'reader_session_settings.dart';
import 'reader_settings_fields.dart';

const readerTopControlsKey = ValueKey<String>('reader-top-controls');
const readerBottomControlsKey = ValueKey<String>('reader-bottom-controls');
const readerPageSliderKey = ValueKey<String>('reader-page-slider');
const readerPauseKey = ValueKey<String>('reader-pause');
const readerSpeedKey = ValueKey<String>('reader-speed');
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
const readerExistingProgressKey = ValueKey<String>('reader-existing-progress');
const readerNetworkProgressKey = ValueKey<String>('reader-network-progress');
Key readerSpeedOptionKey(double speed) =>
    ValueKey<String>('reader-speed-option:$speed');

typedef ReaderArtifactBytesLoader = PipelineArtifactBytesLoader;
typedef ReaderPageBytesLoader = Future<Uint8List> Function(
  MediaLoadToken token,
);
typedef ReaderPageDimensionsReporter = void Function(int width, int height);

@immutable
final class ReaderPlaybackState {
  const ReaderPlaybackState({
    this.paused = false,
    this.speed = 1,
  })  : assert(speed >= 0.25),
        assert(speed <= 4);

  final bool paused;
  final double speed;

  ReaderPlaybackState copyWith({bool? paused, double? speed}) =>
      ReaderPlaybackState(
        paused: paused ?? this.paused,
        speed: speed ?? this.speed,
      );
}

final class ReaderPlaybackController
    extends ValueNotifier<ReaderPlaybackState> {
  ReaderPlaybackController() : super(const ReaderPlaybackState());

  void togglePaused() => value = value.copyWith(paused: !value.paused);

  void setSpeed(double speed) {
    if (value.speed == speed) {
      return;
    }
    value = value.copyWith(speed: speed);
  }
}

final class ReaderPageRuntime {
  const ReaderPageRuntime({
    required this.chapter,
    required this.clock,
    required this.traceSink,
    required this.sessionId,
    required this.demandRevision,
    required this.loadBytes,
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
  late final ValueNotifier<Map<String, double>> _pageAspectRatios;
  final Map<String, double> _pendingPageAspectRatios = <String, double>{};
  bool _pageAspectRatioUpdateScheduled = false;
  late bool _favorite;
  late bool _controlsVisible;
  bool _downloading = false;
  bool _downloaded = false;
  late ReaderSessionSettings _settings;
  late final AdaptiveReaderClassifier _adaptiveClassifier;
  AdaptiveReaderProfile? _adaptiveProfile;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageAspectRatios =
        ValueNotifier<Map<String, double>>(const <String, double>{});
    _playback = ReaderPlaybackController()
      ..addListener(_syncPipelinePlayback);
    _syncPipelinePlayback();
    _settings = widget.initialSettings;
    _adaptiveClassifier = AdaptiveReaderClassifier(
      widget.chapter,
      metadata: widget.adaptiveMetadata,
    );
    _adaptiveProfile = _initialAdaptiveProfile(_settings);
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
    final previous = _reader;
    final initialProgress = _matchingInitialProgress();
    final currentIndex = previous?.currentIndex ??
        (initialProgress?.pageIndex ?? 0)
            .clamp(0, widget.chapter.pages.length - 1)
            .toInt();
    final direction = previous?.direction ?? _resolveInitialDirection(
      initialProgress,
    );
    if (previous != null) {
      previous.removeListener(_handleReaderProgress);
      _pipeline.detach(previous.sessionId);
      previous.dispose();
    }

    _pipeline.attach(target);
    final reader = ReaderController(
      sessionId: _pipeline.sessionId,
      chapter: widget.chapter,
      initialPage: currentIndex,
      onObservation: _pipeline.accept,
      clock: _pipeline.clock,
      traceSink: _pipeline.trace,
    );
    reader.setDirection(direction);
    reader.addListener(_handleReaderProgress);
    _target = target;
    _reader = reader;
    _lastProgressPage = reader.currentIndex;
    _lastProgressMode = _readerMode(reader.direction);
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
    _persistSettings();
    if (mounted) setState(() {});
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
        await Future<void>.sync(() => writer(progress));
      } on Object catch (error) {
        debugPrint('reader progress write failed: $error');
      }
    }
  }

  Future<bool> _flushProgressBeforePop() async {
    await _checkpointReaderProgress(force: true);
    while (_pendingProgress != null || _progressDrain != null) {
      await _checkpointReaderProgress();
    }
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_checkpointReaderProgress(force: true));
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

  bool _currentPageSupportsPlayback(ReaderController reader) {
    final asset = widget.chapter.pages[reader.currentIndex];
    return _playbackCapabilities[asset.assetKey] ?? asset.animatedHint;
  }

  void _reportPlaybackCapability(PageAsset asset, bool supported) {
    if (_playbackCapabilities[asset.assetKey] == supported) return;
    _playbackCapabilities[asset.assetKey] = supported;
    final reader = _reader;
    if (supported) {
      _applyAdaptiveProfile(_adaptiveClassifier.observeAnimated(asset));
    }
    if (mounted &&
        reader != null &&
        widget.chapter.pages[reader.currentIndex].assetKey == asset.assetKey) {
      setState(() {});
    }
  }

  void _reportPageDimensions(PageAsset asset, int width, int height) {
    if (width <= 0 || height <= 0) return;
    _applyAdaptiveProfile(
      _adaptiveClassifier.observeDimensions(asset, width, height),
    );
    final ratio = height / width;
    final sourceWidth = asset.width;
    final sourceHeight = asset.height;
    if (sourceWidth != null &&
        sourceHeight != null &&
        sourceWidth > 0 &&
        sourceHeight > 0) {
      final intrinsicRatio = sourceHeight / sourceWidth;
      final relativeDifference =
          (intrinsicRatio - ratio).abs() / intrinsicRatio;
      if (relativeDifference < 0.01) {
        return;
      }
    }
    final prior = _pendingPageAspectRatios[asset.assetKey] ??
        _pageAspectRatios.value[asset.assetKey];
    if (prior != null && (prior - ratio).abs() < 0.001) return;
    _pendingPageAspectRatios[asset.assetKey] = ratio;
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

  void _syncPipelinePlayback() {
    final state = _playback.value;
    _pipeline.setPlayback(paused: state.paused, speed: state.speed);
  }

  @override
  void dispose() {
    unawaited(_checkpointReaderProgress(force: true));
    WidgetsBinding.instance.removeObserver(this);
    final reader = _reader;
    if (reader != null) {
      reader.removeListener(_handleReaderProgress);
      _pipeline.detach(reader.sessionId);
      reader.dispose();
    }
    _playback.removeListener(_syncPipelinePlayback);
    _playback.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
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
        SnackBar(content: Text('收藏状态保存失败：$error')),
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
          SnackBar(content: Text('缓存本章失败：$error')),
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
    final writer = widget.onSettingsChanged;
    if (writer != null) {
      try {
        await Future<void>.sync(() => writer(_settings));
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存本漫画阅读设置失败：$error')),
          );
        }
      }
    }
  }

  Widget _topControls(
    BuildContext context,
    ReaderController reader,
  ) {
    final subtitle = widget.pageSubtitleBuilder?.call(
      widget.chapter.pages[reader.currentIndex],
    );
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
                            if (subtitle != null && subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                key: readerPageSubtitleKey,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
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
                ValueListenableBuilder<PipelineTransferProgress>(
                  valueListenable: _pipeline.transferProgress.notifier,
                  builder: (context, progress, _) {
                    if (!progress.active) return const SizedBox(height: 3);
                    final committed = progress.committedFraction;
                    final existing = progress.existingFraction;
                    if (committed == null) {
                      final receiving = progress.phase ==
                          PipelineTransferPhase.receiving;
                      return Semantics(
                        label: receiving ? '正在接收页面数据' : '正在连接页面资源',
                        value: receiving
                            ? '${progress.receivedBytes} bytes'
                            : null,
                        child: LinearProgressIndicator(
                          key: readerNetworkProgressKey,
                          minHeight: 3,
                          color: receiving
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                      );
                    }
                    return SizedBox(
                      height: 3,
                      child: Stack(
                        fit: StackFit.expand,
                        alignment: Alignment.centerLeft,
                        children: <Widget>[
                          FractionallySizedBox(
                            key: readerNetworkProgressKey,
                            widthFactor: committed,
                            alignment: Alignment.centerLeft,
                            child: ColoredBox(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          if (existing != null && existing > 0)
                            FractionallySizedBox(
                              key: readerExistingProgressKey,
                              widthFactor: existing,
                              alignment: Alignment.centerLeft,
                              child: ColoredBox(
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomControls(
    BuildContext context,
    ReaderController reader,
  ) {
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
                  Row(
                    children: <Widget>[
                      Text(
                        reader.direction == ReadingDirection.rtl
                            ? '$pages'
                            : '${reader.currentIndex + 1}',
                      ),
                      Expanded(
                        child: Directionality(
                          textDirection: reader.direction == ReadingDirection.rtl
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          child: Slider(
                            key: readerPageSliderKey,
                            value: (reader.requestedIndex ?? reader.currentIndex)
                                .clamp(0, math.max(1, pages - 1))
                                .toDouble(),
                            min: 0,
                            max: math.max(1, pages - 1).toDouble(),
                            divisions: pages > 1 ? pages - 1 : null,
                            onChanged: pages <= 1
                                ? null
                                : (value) => reader.requestPage(value.round()),
                          ),
                        ),
                      ),
                      Text(
                        reader.direction == ReadingDirection.rtl
                            ? '${reader.currentIndex + 1}'
                            : '$pages',
                      ),
                    ],
                  ),
                  ValueListenableBuilder<ReaderPlaybackState>(
                    valueListenable: _playback,
                    builder: (context, playback, _) => Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        if (_currentPageSupportsPlayback(reader))
                          IconButton(
                            key: readerPauseKey,
                            tooltip: playback.paused ? '继续播放' : '暂停动画',
                            onPressed: _togglePlaybackPaused,
                            icon: Icon(
                              playback.paused ? Icons.play_arrow : Icons.pause,
                            ),
                          ),
                        if (_currentPageSupportsPlayback(reader))
                          TextButton(
                            key: readerSpeedKey,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => unawaited(_choosePlaybackSpeed()),
                            child: Text(_playbackSpeedLabel(playback.speed)),
                          ),
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
                            _favorite
                                ? Icons.bookmark
                                : Icons.bookmark_border,
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
        : (context, asset, reportFirstFrame) => artifactBuilder(
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
    return WillPopScope(
      onWillPop: _flushProgressBeforePop,
      child: Scaffold(
        key: widget.screenKey,
        backgroundColor: Colors.black,
        body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ValueListenableBuilder<Map<String, double>>(
            valueListenable: _pageAspectRatios,
            builder: (context, pageAspectRatios, _) => ReaderView(
              controller: reader,
              clock: _pipeline.clock,
              traceSink: _pipeline.trace,
              pageBuilder: pageBuilder,
              demandRevision: () => _pipeline.revision,
              onTap: _toggleControls,
              verticalStitch: _settings.effectiveVerticalStitch,
              pageAspectRatios: pageAspectRatios,
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
                    child: _bottomControls(context, reader),
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
