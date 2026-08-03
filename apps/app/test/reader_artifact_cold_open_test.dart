import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transport/transport.dart';
import 'package:zic/media_load_token.dart';
import 'package:zic/reader_runtime.dart';
import 'package:zic/webp_demo.dart' show defaultLocalMediaPipelineFactory;

const _readyKey = ValueKey<String>('cold-reader-artifact-ready');

void main() {
  testWidgets(
    'cold Reader consumes promoted bytes before replacement session staging',
    (tester) async {
      final chapter = _chapter();
      final id = readerPageDownloadId(chapter, chapter.pages.single);
      final store = _ArtifactStore(<DownloadId, Uint8List>{
        id: Uint8List.fromList(<int>[1, 2, 3, 4]),
      });
      var originLoads = 0;

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PipelineReaderSessionHost(
              chapter: chapter,
              factory: defaultLocalMediaPipelineFactory
                  .withArtifactCacheManager(
                    ArtifactCacheManager(backend: store),
                  )
                  .withLoaderSources(<Uri, LoaderTransportSource>{
                  id.canonicalUri: LoaderTransportSource(
                    revision: 'origin-r1',
                    loadBytes: () async {
                      originLoads++;
                      throw StateError(
                        'promoted artifact unexpectedly missed',
                      );
                    },
                  ),
                }),
              builder: (context, pipeline) => ReaderRuntimeScreen(
                chapter: chapter,
                pipeline: pipeline,
                artifactPageBuilder: (
                  context,
                  asset,
                  reportFirstFrame,
                  runtime,
                ) =>
                    _ArtifactBytesPage(
                  runtime: runtime,
                  reportFirstFrame: reportFirstFrame,
                ),
              ),
            ),
          ),
        );

        final elapsed = Stopwatch()..start();
        while (elapsed.elapsed < const Duration(seconds: 5) &&
            find.byKey(_readyKey).evaluate().isEmpty) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
        }

        expect(find.byKey(_readyKey), findsOneWidget);
        expect(store.reads, 1);
        expect(originLoads, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
    },
  );
}

ChapterManifest _chapter() => ChapterManifest(
      sourceId: 'source',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Chapter',
        sequence: 0,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter',
          index: 0,
          uri: Uri.parse('memory://cold-reader-page'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );

final class _ArtifactBytesPage extends StatefulWidget {
  const _ArtifactBytesPage({
    required this.runtime,
    required this.reportFirstFrame,
  });

  final ReaderPageRuntime runtime;
  final VoidCallback reportFirstFrame;

  @override
  State<_ArtifactBytesPage> createState() => _ArtifactBytesPageState();
}

final class _ArtifactBytesPageState extends State<_ArtifactBytesPage> {
  late final MediaLoadToken _token;
  late final Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _token = MediaLoadToken();
    _bytes = widget.runtime.loadBytes(_token);
  }

  @override
  void dispose() {
    _token.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ColoredBox(color: Colors.black);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.reportFirstFrame();
          }
        });
        return Text(
          '${snapshot.requireData.lengthInBytes}',
          key: _readyKey,
        );
      },
    );
  }
}

final class _ArtifactStore implements ArtifactCacheBackend {
  _ArtifactStore(this.values);

  final Map<DownloadId, Uint8List> values;
  int reads = 0;


  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    reads++;
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = endExclusive ?? bytes.lengthInBytes;
        yield Uint8List.sublistView(bytes, start, end);
      },
      readAll: () async => bytes,
    );
  }

  @override
  Future<Uint8List?> readArtifact(DownloadId id) async {
    reads++;
    return values[id];
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }
}
