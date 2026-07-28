import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
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
import 'webp_demo.dart';

const staticDemoScreenKey = ValueKey<String>('static-demo-screen');

final class StaticDemoScreen extends StatefulWidget {
  const StaticDemoScreen({super.key});

  @override
  State<StaticDemoScreen> createState() => _StaticDemoScreenState();
}

final class _StaticDemoScreenState extends State<StaticDemoScreen> {
  late final Future<ChapterManifest> _chapter;

  @override
  void initState() {
    super.initState();
    final source = LocalManifestSource(
      sourceId: 'local-demo',
      loader: rootBundle.loadString,
      comicManifestPaths: const <String, String>{
        'zic-demo': 'assets/demo/comic.json',
      },
      chapterManifestPaths: const <String, String>{
        'chapter-001': 'assets/demo/chapter_001.json',
      },
    );
    _chapter = source.loadChapter('chapter-001');
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: staticDemoScreenKey,
      child: FutureBuilder<ChapterManifest>(
        future: _chapter,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(title: const Text('100 页静态章节')),
              body: Center(child: Text('加载演示失败：${snapshot.error}')),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return _ReaderRuntime(chapter: snapshot.requireData);
        },
      ),
    );
  }
}

const mediaPipelineReaderScreenKey =
    ValueKey<String>('media-pipeline-reader-screen');
const readerMediaWebpPageKey = ValueKey<String>('reader-media-webp-page');

typedef ChapterManifestLoader = Future<ChapterManifest> Function();
typedef ReaderMediaBytesLoader = Future<Uint8List> Function(
  PageAsset asset,
  WebpLoadToken token,
);

final class MediaPipelineReaderScreen extends StatefulWidget {
  const MediaPipelineReaderScreen({
    this.chapterLoader,
    this.mediaBytesLoader,
    this.onPreviewStateChanged,
    super.key,
  });

  final ChapterManifestLoader? chapterLoader;
  final ReaderMediaBytesLoader? mediaBytesLoader;
  final WebpPreviewStateChanged? onPreviewStateChanged;

  @override
  State<MediaPipelineReaderScreen> createState() =>
      _MediaPipelineReaderScreenState();
}

final class _MediaPipelineReaderScreenState
    extends State<MediaPipelineReaderScreen> {
  late final Future<ChapterManifest> _chapter;

  @override
  void initState() {
    super.initState();
    final provided = widget.chapterLoader;
    if (provided != null) {
      _chapter = provided();
      return;
    }
    final source = LocalManifestSource(
      sourceId: 'local-demo',
      loader: rootBundle.loadString,
      comicManifestPaths: const <String, String>{
        'zic-demo': 'assets/demo/comic.json',
      },
      chapterManifestPaths: const <String, String>{
        'chapter-media-pipeline':
            'assets/demo/chapter_media_pipeline.json',
      },
    );
    _chapter = source.loadChapter('chapter-media-pipeline');
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: mediaPipelineReaderScreenKey,
      child: FutureBuilder<ChapterManifest>(
        future: _chapter,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(title: const Text('Reader Media Pipeline')),
              body: Center(child: Text('加载演示失败：${snapshot.error}')),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return _ReaderRuntime(
            chapter: snapshot.requireData,
            mediaPipeline: true,
            mediaBytesLoader: widget.mediaBytesLoader,
            onPreviewStateChanged: widget.onPreviewStateChanged,
          );
        },
      ),
    );
  }
}

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

Widget? _buildMediaReaderPage(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame, {
  required ChapterManifest chapter,
  required MonoClock clock,
  required TraceSink traceSink,
  required String sessionId,
  required int Function() demandRevision,
  required Future<Uint8List> Function(
    PageAsset asset,
    WebpLoadToken token,
  ) loadBytes,
  WebpPreviewStateChanged? onPreviewStateChanged,
}) {
  if (asset.contentKindHint != ContentKindHint.webp) {
    return null;
  }
  return ColoredBox(
    key: readerMediaWebpPageKey,
    color: Colors.black,
    child: NativeWebpPlayer(
      key: ValueKey<String>(asset.assetKey),
      title: asset.pageId,
      sourceUri: asset.uri,
      loadBytes: (token) => loadBytes(asset, token),
      showEngineControls: false,
      showStatus: false,
      initialEngine: WebpPlayerEngine.flutter,
      onFirstFrame: reportFirstFrame,
      traceClock: clock,
      traceSink: traceSink,
      traceSessionId: sessionId,
      demandRevision: demandRevision,
      downloadIdentity: readerPageDownloadId(chapter, asset),
      onPreviewStateChanged: onPreviewStateChanged,
    ),
  );
}

final class _ReaderRuntime extends StatefulWidget {
  const _ReaderRuntime({
    required this.chapter,
    this.pageBuilder,
    this.mediaPipeline = false,
    this.mediaBytesLoader,
    this.onPreviewStateChanged,
  });

  final ChapterManifest chapter;
  final ReaderPageBuilder? pageBuilder;
  final bool mediaPipeline;
  final ReaderMediaBytesLoader? mediaBytesLoader;
  final WebpPreviewStateChanged? onPreviewStateChanged;

  @override
  State<_ReaderRuntime> createState() => _ReaderRuntimeState();
}

final class _ReaderRuntimeState extends State<_ReaderRuntime> {
  static int _sessionSequence = 0;

  late final String _sessionId;
  late final MonoClock _clock;
  late final MemoryTraceSink _memoryTrace;
  late final TraceSink _trace;
  late final Directory _cacheRoot;
  late final AssetBundleTransport _assetTransport;
  late final IoTransport _ioTransport;
  late final DownloadRegistry _downloads;
  late final LiveCoordinator _coordinator;
  ReaderBinding? _binding;
  ReaderController? _reader;
  DecodeTarget? _target;

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
    _cacheRoot = Directory.systemTemp.createTempSync('zic-reader-media-');
    _assetTransport = AssetBundleTransport(rootBundle);
    _ioTransport = IoTransport();
    _downloads = DownloadRegistry(
      layout: CacheLayout(_cacheRoot.path),
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
    final currentIndex = previous?.currentIndex ?? 0;
    final direction = previous?.direction ?? widget.chapter.readingDirection;
    if (previous != null) {
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
    _binding = binding;
    _target = target;
    _reader = reader;
  }

  Transport _transportFor(Uri uri) {
    if (uri.scheme.isEmpty || uri.scheme == 'asset') {
      return _assetTransport;
    }
    return _ioTransport;
  }

  Future<Uint8List> _loadMediaBytes(
    PageAsset asset,
    WebpLoadToken token,
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
    return File(session.artifact.finalPath).readAsBytes();
  }

  @override
  void dispose() {
    final reader = _reader;
    if (reader != null) {
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
    if (await _cacheRoot.exists()) {
      await _cacheRoot.delete(recursive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPageBuilder? pageBuilder;
    if (widget.mediaPipeline) {
      pageBuilder = (context, asset, reportFirstFrame) =>
          _buildMediaReaderPage(
        context,
        asset,
        reportFirstFrame,
        chapter: widget.chapter,
        clock: _clock,
        traceSink: _trace,
        sessionId: _reader!.sessionId,
        demandRevision: () => _binding?.revision ?? 0,
        loadBytes: widget.mediaBytesLoader ?? _loadMediaBytes,
        onPreviewStateChanged: widget.onPreviewStateChanged,
      );
    } else {
      pageBuilder = widget.pageBuilder;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chapter.chapter.title),
        actions: <Widget>[
          PopupMenuButton<ReadingDirection>(
            tooltip: '阅读方向',
            initialValue: _reader!.direction,
            onSelected: _reader!.setDirection,
            itemBuilder: (context) => const <PopupMenuEntry<ReadingDirection>>[
              PopupMenuItem(value: ReadingDirection.ltr, child: Text('LTR')),
              PopupMenuItem(value: ReadingDirection.rtl, child: Text('RTL')),
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
        controller: _reader!,
        clock: _clock,
        traceSink: _trace,
        pageBuilder: pageBuilder,
      ),
    );
  }
}
