import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bridge/bridge.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:media/media.dart' show SourcePool;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:pipeline/pipeline.dart';
import 'package:reader/reader.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'asset_bundle_transport.dart';
import 'media_load_token.dart';
import 'reader_session_settings.dart';

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

typedef ReaderArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);
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

@immutable
final class ReaderTransferProgress {
  const ReaderTransferProgress({
    this.active = false,
    this.existingBytes = 0,
    this.committedBytes = 0,
    this.totalBytes,
  });

  final bool active;
  final int existingBytes;
  final int committedBytes;
  final int? totalBytes;

  double? get existingFraction {
    final total = totalBytes;
    return total == null || total <= 0
        ? null
        : (existingBytes / total).clamp(0.0, 1.0).toDouble();
  }

  double? get committedFraction {
    final total = totalBytes;
    return total == null || total <= 0
        ? null
        : (committedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderTransferProgress &&
          active == other.active &&
          existingBytes == other.existingBytes &&
          committedBytes == other.committedBytes &&
          totalBytes == other.totalBytes;

  @override
  int get hashCode => Object.hash(
        active,
        existingBytes,
        committedBytes,
        totalBytes,
      );
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
    required this.downloadSession,
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
  final DownloadSession downloadSession;
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
    this.artifactPageBuilder,
    this.mediaBytesLoader,
    this.artifactCache,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.pageSubtitleBuilder,
    this.initialProgress,
    this.onProgressChanged,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    this.initiallyImmersive = true,
    this.initialSettings = const ReaderSessionSettings(),
    this.onSettingsChanged,
    this.traceSink,
    this.screenKey,
    super.key,
  });

  final ChapterManifest chapter;
  final ReaderArtifactPageBuilder? artifactPageBuilder;
  final ReaderArtifactBytesLoader? mediaBytesLoader;
  final ArtifactCacheStore? artifactCache;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final ReaderPageSubtitleBuilder? pageSubtitleBuilder;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final bool initiallyImmersive;
  final ReaderSessionSettings initialSettings;
  final ReaderSessionSettingsWriter? onSettingsChanged;
  final TraceSink? traceSink;
  final Key? screenKey;

  @override
  State<ReaderRuntimeScreen> createState() => _ReaderRuntimeScreenState();
}

final class _ReaderRuntimeScreenState extends State<ReaderRuntimeScreen> {
  static int _sessionSequence = 0;

  bool get _usesDeferredPluginResources => widget.chapter.pages.any(
        (asset) => asset.uri.scheme == 'venera-resource',
      );

  late final String _sessionId;
  late final MonoClock _clock;
  late final MemoryTraceSink _memoryTrace;
  late final TraceSink _trace;
  late final EphemeralCacheWorkspace _workspace;
  late final AssetBundleTransport _assetTransport;
  late final IoTransport _ioTransport;
  late final LoaderTransport _loaderTransport;
  ArtifactCacheTransport? _artifactCacheTransport;
  PromotedArtifactReadPool? _artifactReads;
  late final SourcePool _streamingSources;
  late final DownloadRegistry _downloads;
  PromotedArtifactCacheHandoff? _artifactCacheHandoff;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  ReaderController? _reader;
  DecodeTarget? _target;
  int? _lastProgressPage;
  ReaderMode? _lastProgressMode;
  late final ReaderPlaybackController _playback;
  late final ValueNotifier<ReaderTransferProgress> _transferProgress;
  ReaderTransferProgress? _pendingTransferProgress;
  bool _transferProgressScheduled = false;
  bool _transferProgressDisposed = false;
  final Map<String, DownloadSession> _pageSessions = <String, DownloadSession>{};
  final Map<DownloadSession, DownloadSnapshotListener> _sessionProgressListeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadSession, int> _sessionExistingBytes = <DownloadSession, int>{};
  final Set<DownloadSession> _sessionTransferStarted = <DownloadSession>{};
  final Map<String, bool> _playbackCapabilities = <String, bool>{};
  Map<String, double> _pageAspectRatios = const <String, double>{};
  final Map<String, double> _pendingPageAspectRatios = <String, double>{};
  bool _pageAspectRatioUpdateScheduled = false;
  late bool _favorite;
  late bool _controlsVisible;
  bool _downloading = false;
  bool _downloaded = false;
  late ReaderSessionSettings _settings;
  AdaptiveReaderProfile? _adaptiveProfile;

  @override
  void initState() {
    super.initState();
    _playback = ReaderPlaybackController();
    _settings = widget.initialSettings;
    _adaptiveProfile = _settings.effectiveAdaptiveEnabled
        ? classifyAdaptiveReaderLayout(widget.chapter)
        : null;
    _transferProgress = ValueNotifier<ReaderTransferProgress>(
      const ReaderTransferProgress(),
    );
    _favorite = widget.initialFavorite;
    _controlsVisible = !widget.initiallyImmersive;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        widget.initiallyImmersive
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      ),
    );
    _sessionId = 'reader-${++_sessionSequence}';
    _clock = SystemClock();
    _memoryTrace = MemoryTraceSink();
    _trace = MultiTraceSink(<TraceSink>[
      _memoryTrace,
      if (widget.traceSink != null) widget.traceSink!,
      CallbackTraceSink((event) => debugPrint(event.toJsonLine())),
    ]);
    _workspace = EphemeralCacheWorkspace.readerSession(_sessionId);
    _assetTransport = AssetBundleTransport(rootBundle);
    _ioTransport = IoTransport();
    _loaderTransport = LoaderTransport(widget.loaderSources);
    final identities = widget.chapter.pages.map(
      (asset) => MapEntry<Uri, DownloadId>(
        asset.uri,
        readerPageDownloadId(widget.chapter, asset),
      ),
    ).toList(growable: false);
    final sourceBudgets = <DownloadId, int>{
      for (final asset in widget.chapter.pages)
        readerPageDownloadId(widget.chapter, asset): math.max(
          asset.byteLength ?? 0,
          256 * 1024 * 1024,
        ),
    };
    _streamingSources = SourcePool(
      factory: const NativeSourceFactory(),
      budgetFor: (id) => sourceBudgets[id] ?? 256 * 1024 * 1024,
    );
    final cache = widget.artifactCache;
    if (cache != null) {
      final reads = PromotedArtifactReadPool(cache: cache);
      _artifactReads = reads;
      _artifactCacheTransport = ArtifactCacheTransport(
        cache: cache,
        identities: identities,
        fallbackFor: _baseTransportFor,
        readPool: reads,
        clock: _clock,
        traceSink: _trace,
        sessionId: _sessionId,
        demandRevision: () => _binding?.revision ?? 0,
      );
      _artifactCacheHandoff = PromotedArtifactCacheHandoff(
        cache: cache,
        onError: (error, stackTrace) {
          debugPrint('reader artifact cache handoff failed: $error');
        },
      );
    }
    _downloads = DownloadRegistry(
      layout: _workspace.layout,
      clock: _clock,
      traceSink: _trace,
      sources: _streamingSources,
      onSessionCreated: _observeDownloadSession,
    );
    _coordinator = LiveCoordinator(
      registry: _downloads,
      transportFor: _transportFor,
      clock: _clock,
      traceSink: _trace,
      retry: _usesDeferredPluginResources
          ? const RetryPolicy(maxAttempts: 1)
          : const RetryPolicy(),
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
      _adaptiveProfile = _settings.effectiveAdaptiveEnabled
          ? classifyAdaptiveReaderLayout(widget.chapter)
          : null;
    }
    if (!_sameChapterSession(oldWidget.chapter, widget.chapter) ||
        !identical(oldWidget.artifactCache, widget.artifactCache) ||
        !_sameLoaderSources(
          oldWidget.loaderSources,
          widget.loaderSources,
        )) {
      throw StateError(
        'ReaderRuntimeScreen chapter, artifact cache and loader source '
        'identities are immutable for a mounted session; replace the widget '
        'key to open another chapter or source revision',
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
      _binding?.detach(previous.sessionId);
      previous.dispose();
    }

    final binding = ReaderBinding(
      chapter: widget.chapter,
      decodeTarget: target,
      clock: _clock,
      traceSink: _trace,
      coordinator: _coordinator,
      playback: _coordinator,
      windowResolver: _usesDeferredPluginResources
          ? const RoleResolver(
              forwardEncodedPages: 1,
              backwardEncodedPages: 0,
              nearRadius: 1,
            )
          : const RoleResolver(),
      policyGuard: _usesDeferredPluginResources
          ? const PolicyGuard(maxDownloadDemands: 2)
          : const PolicyGuard(),
    );
    final reader = ReaderController(
      sessionId: _sessionId,
      chapter: widget.chapter,
      initialPage: currentIndex,
      onObservation: binding.accept,
      clock: _clock,
      traceSink: _trace,
    );
    reader.setDirection(direction);
    reader.addListener(_handleReaderProgress);
    _binding = binding;
    _target = target;
    _reader = reader;
    _lastProgressPage = reader.currentIndex;
    _lastProgressMode = _readerMode(reader.direction);
    _syncCurrentTransferProgress();
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
    final reader = _reader;
    if (reader == null) {
      return;
    }
    _syncCurrentTransferProgress();
    final writer = widget.onProgressChanged;
    if (writer == null) {
      return;
    }
    final mode = _readerMode(reader.direction);
    if (_lastProgressPage == reader.currentIndex && _lastProgressMode == mode) {
      return;
    }
    _lastProgressPage = reader.currentIndex;
    _lastProgressMode = mode;
    final progress = ReadingProgress(
      sourceId: widget.chapter.sourceId,
      comicId: widget.chapter.comicId,
      chapterId: widget.chapter.chapter.chapterId,
      pageIndex: reader.currentIndex,
      subPageOffset: 0,
      readerMode: mode,
      updatedAt: DateTime.now().toUtc(),
    );
    Future<void>.sync(() => writer(progress)).catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('reader progress write failed: $error');
      },
    );
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

  Transport _baseTransportFor(Uri uri) {
    if (_loaderTransport.contains(uri)) {
      return _loaderTransport;
    }
    if (uri.scheme.isEmpty || uri.scheme == 'asset') {
      return _assetTransport;
    }
    return _ioTransport;
  }

  Transport _transportFor(Uri uri) =>
      _artifactCacheTransport ?? _baseTransportFor(uri);

  void _observeDownloadSession(DownloadSession session) {
    _artifactReads?.observe(session);
    _artifactCacheHandoff?.observe(session);
    _pageSessions[session.id.key] = session;
    _sessionExistingBytes[session] = session.committedLength;
    void listener(DownloadSnapshot snapshot) {
      if (!_sessionTransferStarted.contains(session)) {
        if (snapshot.state == DownloadState.receiving || snapshot.activeRun) {
          _sessionTransferStarted.add(session);
        } else {
          _sessionExistingBytes[session] = math.max(
            _sessionExistingBytes[session] ?? 0,
            snapshot.committedLength,
          );
        }
      }
      _syncCurrentTransferProgress();
    }
    _sessionProgressListeners[session] = listener;
    session.addSnapshotListener(listener);
  }

  void _syncCurrentTransferProgress() {
    final reader = _reader;
    if (reader == null || widget.chapter.pages.isEmpty) {
      _publishTransferProgress(const ReaderTransferProgress());
      return;
    }
    final asset = widget.chapter.pages[reader.currentIndex];
    final id = readerPageDownloadId(widget.chapter, asset);
    final session = _pageSessions[id.key] ?? _downloads.find(id);
    if (session == null) {
      _publishTransferProgress(const ReaderTransferProgress());
      return;
    }
    final snapshot = session.snapshot;
    final existing = math.min(
      _sessionExistingBytes[session] ?? snapshot.committedLength,
      snapshot.committedLength,
    );
    final active = snapshot.state == DownloadState.receiving ||
        snapshot.state == DownloadState.queued ||
        snapshot.activeRun ||
        (snapshot.committedLength > 0 &&
            snapshot.state != DownloadState.promoted &&
            snapshot.state != DownloadState.failed &&
            snapshot.state != DownloadState.disposed);
    _publishTransferProgress(
      ReaderTransferProgress(
        active: active,
        existingBytes: existing,
        committedBytes: snapshot.committedLength,
        totalBytes: snapshot.totalLength,
      ),
    );
  }

  void _reportPageDimensions(PageAsset asset, int width, int height) {
    if (width <= 0 || height <= 0) {
      return;
    }
    final ratio = (height / width).clamp(0.05, 64.0).toDouble();
    final current = _pendingPageAspectRatios[asset.assetKey] ??
        _pageAspectRatios[asset.assetKey];
    if (current != null && (current - ratio).abs() < 0.001) {
      return;
    }
    _pendingPageAspectRatios[asset.assetKey] = ratio;
    if (_pageAspectRatioUpdateScheduled) {
      return;
    }
    _pageAspectRatioUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageAspectRatioUpdateScheduled = false;
      if (!mounted || _pendingPageAspectRatios.isEmpty) {
        _pendingPageAspectRatios.clear();
        return;
      }
      final updates = Map<String, double>.from(_pendingPageAspectRatios);
      _pendingPageAspectRatios.clear();
      setState(() {
        _pageAspectRatios = <String, double>{
          ..._pageAspectRatios,
          ...updates,
        };
      });
    });
  }

  void _publishTransferProgress(ReaderTransferProgress next) {
    if (_transferProgressDisposed) return;
    if (!_transferProgressScheduled && _transferProgress.value == next) return;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      _pendingTransferProgress = null;
      if (_transferProgress.value != next) {
        _transferProgress.value = next;
      }
      return;
    }
    _pendingTransferProgress = next;
    if (_transferProgressScheduled) return;
    _transferProgressScheduled = true;
    scheduler.addPostFrameCallback((_) {
      _transferProgressScheduled = false;
      if (_transferProgressDisposed || !mounted) {
        _pendingTransferProgress = null;
        return;
      }
      final pending = _pendingTransferProgress;
      _pendingTransferProgress = null;
      if (pending != null && _transferProgress.value != pending) {
        _transferProgress.value = pending;
      }
    });
  }

  bool _currentPageSupportsPlayback(ReaderController reader) {
    final asset = widget.chapter.pages[reader.currentIndex];
    return _playbackCapabilities[asset.assetKey] ?? asset.animatedHint;
  }

  void _reportPlaybackCapability(PageAsset asset, bool supported) {
    if (_playbackCapabilities[asset.assetKey] == supported) return;
    _playbackCapabilities[asset.assetKey] = supported;
    final reader = _reader;
    if (mounted && reader != null &&
        widget.chapter.pages[reader.currentIndex].assetKey == asset.assetKey) {
      setState(() {});
    }
  }

  Future<Uint8List> _loadMediaBytes(
    PageAsset asset,
    MediaLoadToken token,
  ) async {
    token.throwIfCancelled();
    final id = readerPageDownloadId(widget.chapter, asset);
    final session = _downloads.get(id);
    if (session.state != DownloadState.promoted) {
      final reads = _artifactReads;
      if (reads != null) {
        final readStarted = _clock.nowMicros();
        final readRevision = _binding?.revision ?? 0;
        try {
          final cached = await reads.join(id);
          token.throwIfCancelled();
          if (cached != null) {
            _trace.record(
              traceEvent(
                clock: _clock,
                sessionId: _sessionId,
                kind: TraceEventKind.artifactSource,
                identityHash: id.key,
                revision: readRevision,
                payload: <String, Object?>{
                  'source': 'artifact-cache',
                  'consumer': 'reader-direct',
                  'bytes': cached.lengthInBytes,
                  'joinMicros': _clock.nowMicros() - readStarted,
                  'sessionState': session.state.name,
                },
              ),
            );
            return cached;
          }
        } on Object catch (error) {
          token.throwIfCancelled();
          _trace.record(
            traceEvent(
              clock: _clock,
              sessionId: _sessionId,
              kind: TraceEventKind.taskFailed,
              identityHash: id.key,
              revision: readRevision,
              payload: <String, Object?>{
                'lane': 'artifact-cache-read',
                'consumer': 'reader-direct',
                'reason': error.toString(),
                'joinMicros': _clock.nowMicros() - readStarted,
                'fallback': 'session',
              },
            ),
          );
        }
      }
      await _waitForMediaPromotion(session, token);
    }
    token.throwIfCancelled();
    final bytes = await _workspace.readArtifact(session.artifact);
    token.throwIfCancelled();
    return bytes;
  }

  Future<void> _waitForMediaPromotion(
    DownloadSession session,
    MediaLoadToken token,
  ) async {
    token.throwIfCancelled();
    final ready = Completer<void>();

    void accept(DownloadSnapshot snapshot) {
      if (ready.isCompleted) {
        return;
      }
      switch (snapshot.state) {
        case DownloadState.promoted:
          ready.complete();
          break;
        case DownloadState.failed:
          ready.completeError(
            snapshot.failure ??
                const Failure(
                  code: ErrorCode.network,
                  message: 'reader media download failed',
                ),
          );
          break;
        case DownloadState.disposed:
          ready.completeError(
            const Failure(
              code: ErrorCode.cancelled,
              message: 'reader media download was disposed',
            ),
          );
          break;
        case DownloadState.idle:
        case DownloadState.queued:
        case DownloadState.receiving:
        case DownloadState.sealed:
          break;
      }
    }

    // DownloadSession fires the current snapshot on attachment. The explicit
    // snapshot checks on both sides of registration also document and close
    // the transition window for alternative session implementations.
    accept(session.snapshot);
    if (ready.isCompleted) {
      await ready.future;
      return;
    }
    session.addSnapshotListener(accept, fireImmediately: false);
    try {
      accept(session.snapshot);
      await Future.any<void>(<Future<void>>[
        ready.future,
        token.whenCancelled.then<void>((_) => token.throwIfCancelled()),
      ]);
    } finally {
      session.removeSnapshotListener(accept);
    }
  }

  @override
  void dispose() {
    final reader = _reader;
    if (reader != null) {
      reader.removeListener(_handleReaderProgress);
      _binding?.detach(reader.sessionId);
      reader.dispose();
    }
    for (final entry in _sessionProgressListeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _sessionProgressListeners.clear();
    _transferProgressDisposed = true;
    _pendingTransferProgress = null;
    _transferProgress.dispose();
    _playback.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(
      _disposeRuntime().catchError((Object error, StackTrace stackTrace) {
        debugPrint('reader runtime dispose failed: $error');
      }),
    );
    super.dispose();
  }

  Future<void> _disposeRuntime() async {
    await _coordinator.dispose();
    await _artifactCacheHandoff?.drain(_downloads.sessions);
    _artifactCacheHandoff?.detach();
    _artifactReads?.close();
    await _downloads.dispose();
    _streamingSources.dispose();
    _ioTransport.close(force: true);
    await _workspace.dispose();
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
      if (external != null) {
        await Future<void>.sync(external);
      } else {
        for (final asset in widget.chapter.pages) {
          final id = readerPageDownloadId(widget.chapter, asset);
          final session = _downloads.get(id);
          if (session.state == DownloadState.promoted) {
            continue;
          }
          if (session.activeRun) {
            await _waitForPromotion(session);
            continue;
          }
          try {
            await DownloadJob(
              transport: _transportFor(asset.uri),
              session: session,
            ).run();
          } on Failure catch (error) {
            if (error.code != ErrorCode.sessionBusy) {
              rethrow;
            }
            await _waitForPromotion(session);
          }
        }
      }
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

  Future<void> _waitForPromotion(DownloadSession session) {
    final completer = Completer<void>();
    late final DownloadSnapshotListener listener;
    listener = (snapshot) {
      if (completer.isCompleted) {
        return;
      }
      switch (snapshot.state) {
        case DownloadState.promoted:
          completer.complete();
          break;
        case DownloadState.failed:
          completer.completeError(
            snapshot.failure ??
                const Failure(
                  code: ErrorCode.network,
                  message: 'chapter cache failed',
                ),
          );
          break;
        case DownloadState.disposed:
          completer.completeError(
            const Failure(
              code: ErrorCode.cancelled,
              message: 'chapter cache was disposed',
            ),
          );
          break;
        case DownloadState.idle:
        case DownloadState.queued:
        case DownloadState.receiving:
        case DownloadState.sealed:
          break;
      }
    };
    session.addSnapshotListener(listener);
    return completer.future.whenComplete(
      () => session.removeSnapshotListener(listener),
    );
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
      'source-hint' => '来源方向',
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
                    SwitchListTile(
                      key: readerVerticalStitchKey,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('纵向拼接'),
                      subtitle: const Text(
                        '纵向模式中移除页面间距，按页面比例连续滚动。',
                      ),
                      value: draft.verticalStitch,
                      onChanged: (value) => setSheetState(
                        () => draft = draft.copyWith(verticalStitch: value),
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
      _adaptiveProfile = _settings.effectiveAdaptiveEnabled
          ? classifyAdaptiveReaderLayout(widget.chapter)
          : null;
    });
    _reader?.setDirection(_resolveInitialDirection(_matchingInitialProgress()));
    final writer = widget.onSettingsChanged;
    if (writer != null) {
      try {
        await Future<void>.sync(() => writer(saved));
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
                ValueListenableBuilder<ReaderTransferProgress>(
                  valueListenable: _transferProgress,
                  builder: (context, progress, _) {
                    if (!progress.active) return const SizedBox(height: 3);
                    final committed = progress.committedFraction;
                    final existing = progress.existingFraction;
                    if (committed == null) {
                      return const LinearProgressIndicator(
                        key: readerNetworkProgressKey,
                        minHeight: 3,
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
                            value: reader.currentIndex.toDouble(),
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
                clock: _clock,
                traceSink: _trace,
                sessionId: reader.sessionId,
                demandRevision: () => _binding?.revision ?? 0,
                loadBytes: (token) =>
                    (widget.mediaBytesLoader ?? _loadMediaBytes)(asset, token),
                playback: _playback,
                downloadSession: _downloads.get(
                  readerPageDownloadId(widget.chapter, asset),
                ),
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
    return AnimatedBuilder(
      animation: reader,
      builder: (context, _) => Scaffold(
        key: widget.screenKey,
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ReaderView(
              controller: reader,
              clock: _clock,
              traceSink: _trace,
              pageBuilder: pageBuilder,
              demandRevision: () => _binding?.revision ?? 0,
              onTap: _toggleControls,
              verticalStitch: _settings.effectiveVerticalStitch,
              pageAspectRatios: _pageAspectRatios,
            ),
            AnimatedOpacity(
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
            AnimatedOpacity(
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

bool _sameLoaderSources(
  Map<Uri, LoaderTransportSource> left,
  Map<Uri, LoaderTransportSource> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    final candidate = right[entry.key];
    if (candidate == null || candidate.revision != entry.value.revision) {
      return false;
    }
  }
  return true;
}
