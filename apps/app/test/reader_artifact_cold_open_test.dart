import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transport/transport.dart';
import 'package:zic/media_load_token.dart';
import 'package:zic/reader_runtime.dart';

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

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderRuntimeScreen(
            chapter: chapter,
            artifactCache: store,
            loaderSources: <Uri, LoaderTransportSource>{
              id.canonicalUri: LoaderTransportSource(
                revision: 'origin-r1',
                loadBytes: () async {
                  originLoads++;
                  throw StateError('promoted artifact unexpectedly missed');
                },
              ),
            },
            artifactPageBuilder: (
              context,
              asset,
              reportFirstFrame,
              runtime,
            ) => _ArtifactBytesPage(
              runtime: runtime,
              reportFirstFrame: reportFirstFrame,
            ),
          ),
        ),
      );

      for (var frame = 0;
          frame < 80 && find.byKey(_readyKey).evaluate().isEmpty;
          frame++) {
        await tester.pump();
      }

      expect(find.byKey(_readyKey), findsOneWidget);
      expect(store.reads, 1);
      expect(originLoads, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
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

final class _ArtifactStore implements ArtifactCacheStore {
  _ArtifactStore(this.values);

  final Map<DownloadId, Uint8List> values;
  int reads = 0;

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
