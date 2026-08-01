import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_load_token.dart';
import 'reader_runtime.dart';
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
          final chapter = snapshot.requireData;
          return PipelineReaderSessionHost(
            chapter: chapter,
            factory: defaultLocalMediaPipelineFactory,
            builder: (context, pipeline) => ReaderRuntimeScreen(
              chapter: chapter,
              pipeline: pipeline,
            ),
          );
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
  MediaLoadToken token,
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
          final chapter = snapshot.requireData;
          return PipelineReaderSessionHost(
            chapter: chapter,
            factory: defaultLocalMediaPipelineFactory.withBytesLoader(
              widget.mediaBytesLoader,
            ),
            builder: (context, pipeline) => ReaderRuntimeScreen(
              chapter: chapter,
              pipeline: pipeline,
              artifactPageBuilder: (
                context,
                asset,
                reportFirstFrame,
                runtime,
              ) =>
                  _buildMediaReaderPage(
                context,
                asset,
                reportFirstFrame,
                runtime,
                onPreviewStateChanged: widget.onPreviewStateChanged,
              ),
            ),
          );
        },
      ),
    );
  }
}

Widget? _buildMediaReaderPage(
  BuildContext context,
  PageAsset asset,
  VoidCallback reportFirstFrame,
  ReaderPageRuntime runtime, {
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
      loadBytes: (token) => runtime.loadBytes(token),
      showEngineControls: false,
      showStatus: false,
      initialEngine: WebpPlayerEngine.native,
      pageStream: runtime.pageStream,
      onPlaybackCapabilityChanged: runtime.reportPlaybackCapability,
      onFirstFrame: reportFirstFrame,
      traceClock: runtime.clock,
      traceSink: runtime.traceSink,
      traceSessionId: runtime.sessionId,
      demandRevision: runtime.demandRevision,
      downloadIdentity: runtime.pageStream.identity,
      onPreviewStateChanged: onPreviewStateChanged,
      playback: runtime.playback,
    ),
  );
}
