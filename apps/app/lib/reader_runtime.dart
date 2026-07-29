import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pipeline/pipeline.dart';
import 'package:reader/reader.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'asset_bundle_transport.dart';
import 'media_load_token.dart';

const readerTopControlsKey = ValueKey<String>('reader-top-controls');
const readerBottomControlsKey = ValueKey<String>('reader-bottom-controls');
const readerPageSliderKey = ValueKey<String>('reader-page-slider');
const readerPauseKey = ValueKey<String>('reader-pause');
const readerSpeedKey = ValueKey<String>('reader-speed');
const readerRotateKey = ValueKey<String>('reader-rotate');
const readerFavoriteKey = ValueKey<String>('reader-favorite');
const readerDownloadKey = ValueKey<String>('reader-download');
Key readerSpeedOptionKey(double speed) =>
    ValueKey<String>('reader-speed-option:$speed');

typedef ReaderArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);
typedef ReaderPageBytesLoader = Future<Uint8List> Function(
  MediaLoadToken token,
);

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
  });

  final ChapterManifest chapter;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final int Function() demandRevision;
  final ReaderPageBytesLoader loadBytes;
  final ReaderPlaybackController playback;
}

typedef ReaderArtifactPageBuilder = Widget? Function(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
  ReaderPageRuntime runtime,
);
typedef ReaderAppBarTitleBuilder = Widget Function(
  BuildContext context,
  ChapterManifest chapter,
  int currentIndex,
);
typedef ReaderAppBarActionsBuilder = List<Widget> Function(
  BuildContext context,
  ReaderController controller,
);
typedef ReaderProgressWriter = FutureOr<void> Function(
  ReadingProgress progress,
);

final class ReaderRuntimeScreen extends StatefulWidget {
  const ReaderRuntimeScreen({
    required this.chapter,
    this.artifactPageBuilder,
    this.mediaBytesLoader,
    this.artifactCache,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.appBarTitleBuilder,
    this.appBarActionsBuilder,
    this.initialProgress,
    this.onProgressChanged,
    this.initialFavorite = false,
    this.onFavoriteChanged,
    this.onDownloadRequested,
    this.screenKey,
    super.key,
  });

  final ChapterManifest chapter;
  final ReaderArtifactPageBuilder? artifactPageBuilder;
  final ReaderArtifactBytesLoader? mediaBytesLoader;
  final ArtifactCacheStore? artifactCache;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final ReaderAppBarTitleBuilder? appBarTitleBuilder;
  final ReaderAppBarActionsBuilder? appBarActionsBuilder;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
  final bool initialFavorite;
  final FutureOr<void> Function(bool favorite)? onFavoriteChanged;
  final FutureOr<void> Function()? onDownloadRequested;
  final Key? screenKey;

  @override
  State<ReaderRuntimeScreen> createState() => _ReaderRuntimeScreenState();
}

final class _ReaderRuntimeScreenState extends State<ReaderRuntimeScreen> {
  static int _sessionSequence = 0;

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
  late final DownloadRegistry _downloads;
  PromotedArtifactCacheHandoff? _artifactCacheHandoff;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  ReaderController? _reader;
  DecodeTarget? _target;
  int? _lastProgressPage;
  ReaderMode? _lastProgressMode;
  late final ReaderPlaybackController _playback;
  late bool _favorite;
  bool _controlsVisible = false;
  bool _downloading = false;
  bool _downloaded = false;

  @override
  void initState() {
    super.initState();
    _playback = ReaderPlaybackController();
    _favorite = widget.initialFavorite;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _sessionId = 'reader-${++_sessionSequence}';
    _clock = SystemClock();
    _memoryTrace = MemoryTraceSink();
    _trace = MultiTraceSink(<TraceSink>[
      _memoryTrace,
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
      onSessionCreated: _observeDownloadSession,
    );
    _coordinator = LiveCoordinator(
      registry: _downloads,
      transportFor: _transportFor,
      clock: _clock,
      traceSink: _trace,
    );
  }

  @override
  void didUpdateWidget(covariant ReaderRuntimeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFavorite != widget.initialFavorite) {
      _favorite = widget.initialFavorite;
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
    final direction = previous?.direction ??
        (initialProgress?.readerMode == ReaderMode.continuous
            ? ReadingDirection.vertical
            : widget.chapter.readingDirection);
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
    final writer = widget.onProgressChanged;
    if (reader == null || writer == null) {
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
      final ready = Completer<DownloadSnapshot>();
      late final DownloadSnapshotListener listener;
      listener = (snapshot) {
        if (ready.isCompleted) {
          return;
        }
        switch (snapshot.state) {
          case DownloadState.promoted:
            ready.complete(snapshot);
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
      };
      session.addSnapshotListener(listener);
      try {
        await Future.any<DownloadSnapshot>(<Future<DownloadSnapshot>>[
          ready.future,
          token.whenCancelled.then<DownloadSnapshot>((_) {
            token.throwIfCancelled();
            throw StateError('unreachable cancellation path');
          }),
        ]);
      } finally {
        session.removeSnapshotListener(listener);
      }
    }
    token.throwIfCancelled();
    final bytes = await _workspace.readArtifact(session.artifact);
    token.throwIfCancelled();
    return bytes;
  }

  @override
  void dispose() {
    final reader = _reader;
    if (reader != null) {
      reader.removeListener(_handleReaderProgress);
      _binding?.detach(reader.sessionId);
      reader.dispose();
    }
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

  Widget _topControls(
    BuildContext context,
    ReaderController reader,
  ) {
    final titleBuilder = widget.appBarTitleBuilder;
    return SafeArea(
      key: readerTopControlsKey,
      bottom: false,
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: SizedBox(
              height: kToolbarHeight,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: titleBuilder == null
                        ? Text(
                            widget.chapter.chapter.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : titleBuilder(
                            context,
                            widget.chapter,
                            reader.currentIndex,
                          ),
                  ),
                  ...?widget.appBarActionsBuilder?.call(context, reader),
                  PopupMenuButton<ReadingDirection>(
                    tooltip: '阅读方向',
                    initialValue: reader.direction,
                    onSelected: reader.setDirection,
                    itemBuilder: (context) =>
                        const <PopupMenuEntry<ReadingDirection>>[
                      PopupMenuItem(
                        value: ReadingDirection.ltr,
                        child: Text('LTR'),
                      ),
                      PopupMenuItem(
                        value: ReadingDirection.rtl,
                        child: Text('RTL'),
                      ),
                      PopupMenuItem(
                        value: ReadingDirection.vertical,
                        child: Text('纵向'),
                      ),
                    ],
                    icon: const Icon(Icons.swap_horiz),
                  ),
                ],
              ),
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
                      Text('${reader.currentIndex + 1}'),
                      Expanded(
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
                      Text('$pages'),
                    ],
                  ),
                  ValueListenableBuilder<ReaderPlaybackState>(
                    valueListenable: _playback,
                    builder: (context, playback, _) => Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        IconButton(
                          key: readerPauseKey,
                          tooltip: playback.paused ? '继续播放' : '暂停动画',
                          onPressed: _togglePlaybackPaused,
                          icon: Icon(
                            playback.paused ? Icons.play_arrow : Icons.pause,
                          ),
                        ),
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
