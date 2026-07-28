import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
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

typedef ReaderArtifactBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  MediaLoadToken token,
);
typedef ReaderPageBytesLoader = Future<Uint8List> Function(
  MediaLoadToken token,
);
final class ReaderPageRuntime {
  const ReaderPageRuntime({
    required this.chapter,
    required this.clock,
    required this.traceSink,
    required this.sessionId,
    required this.demandRevision,
    required this.loadBytes,
  });

  final ChapterManifest chapter;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final int Function() demandRevision;
  final ReaderPageBytesLoader loadBytes;
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

DownloadId readerPageDownloadId(
  ChapterManifest chapter,
  PageAsset asset,
) {
  if (asset.chapterId != chapter.chapter.chapterId) {
    throw ArgumentError.value(
      asset.chapterId,
      'asset.chapterId',
      'must match ${chapter.chapter.chapterId}',
    );
  }
  return DownloadId(
    content: ContentId(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: asset.chapterId,
      pageId: asset.pageId,
    ),
    sourceRevision: chapter.chapter.sourceRevision,
    canonicalUri: asset.uri,
  );
}

final class ReaderRuntimeScreen extends StatefulWidget {
  const ReaderRuntimeScreen({
    required this.chapter,
    this.artifactPageBuilder,
    this.mediaBytesLoader,
    this.loaderSources = const <Uri, LoaderTransportSource>{},
    this.appBarTitleBuilder,
    this.appBarActionsBuilder,
    this.initialProgress,
    this.onProgressChanged,
    this.screenKey,
    super.key,
  });

  final ChapterManifest chapter;
  final ReaderArtifactPageBuilder? artifactPageBuilder;
  final ReaderArtifactBytesLoader? mediaBytesLoader;
  final Map<Uri, LoaderTransportSource> loaderSources;
  final ReaderAppBarTitleBuilder? appBarTitleBuilder;
  final ReaderAppBarActionsBuilder? appBarActionsBuilder;
  final ReadingProgress? initialProgress;
  final ReaderProgressWriter? onProgressChanged;
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
  late final DownloadRegistry _downloads;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  ReaderController? _reader;
  DecodeTarget? _target;
  int? _lastProgressPage;
  ReaderMode? _lastProgressMode;

  @override
  void initState() {
    super.initState();
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
    _downloads = DownloadRegistry(
      layout: _workspace.layout,
      clock: _clock,
      traceSink: _trace,
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
    if (!_sameChapterSession(oldWidget.chapter, widget.chapter) ||
        !_sameLoaderSources(
          oldWidget.loaderSources,
          widget.loaderSources,
        )) {
      throw StateError(
        'ReaderRuntimeScreen chapter and loader source identities are '
        'immutable for a mounted session; replace the widget key to open '
        'another chapter or source revision',
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

  Transport _transportFor(Uri uri) {
    if (_loaderTransport.contains(uri)) {
      return _loaderTransport;
    }
    if (uri.scheme.isEmpty || uri.scheme == 'asset') {
      return _assetTransport;
    }
    return _ioTransport;
  }

  Future<Uint8List> _loadMediaBytes(
    PageAsset asset,
    MediaLoadToken token,
  ) async {
    token.throwIfCancelled();
    final id = readerPageDownloadId(widget.chapter, asset);
    final session = _downloads.get(id);
    if (session.state != DownloadState.promoted) {
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
    unawaited(
      _disposeRuntime().catchError((Object error, StackTrace stackTrace) {
        debugPrint('reader runtime dispose failed: $error');
      }),
    );
    super.dispose();
  }

  Future<void> _disposeRuntime() async {
    await _coordinator.dispose();
    await _downloads.dispose();
    _ioTransport.close(force: true);
    await _workspace.dispose();
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
              ),
            );
    return AnimatedBuilder(
      animation: reader,
      builder: (context, _) {
        final titleBuilder = widget.appBarTitleBuilder;
        return Scaffold(
          key: widget.screenKey,
          appBar: AppBar(
            title: titleBuilder == null
                ? Text(widget.chapter.chapter.title)
                : titleBuilder(
                    context,
                    widget.chapter,
                    reader.currentIndex,
                  ),
            actions: <Widget>[
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
          body: ReaderView(
            controller: reader,
            clock: _clock,
            traceSink: _trace,
            pageBuilder: pageBuilder,
          ),
        );
      },
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
