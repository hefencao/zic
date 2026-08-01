import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

void main() {
  test('app cache composition restores source and detail covers after restart',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-app-cache-');
    addTearDown(() => root.delete(recursive: true));
    final sourceCover = Uri.parse('https://example.invalid/source-cover.png');
    final detailCover = Uri.parse('https://example.invalid/comic-cover.png');

    final firstRaw = _CoverSource();
    final firstCache = createAppResourceCache(storageRoot: root.path);
    final first = CachedBrowsableComicSource(
      source: firstRaw,
      cache: firstCache.responses,
    );
    expect(
      await first.loadImage(sourceCover, revision: 'source-r1'),
      _CoverSource.sourceBytes,
    );
    expect(
      await first.loadImage(
        detailCover,
        comicId: 'comic-1',
        revision: 'comic-r1',
      ),
      _CoverSource.detailBytes,
    );
    expect(firstRaw.resourceLoads, 2);
    await firstCache.close();

    final reopenedRaw = _CoverSource(failResourceLoads: true);
    final reopenedCache = createAppResourceCache(storageRoot: root.path);
    addTearDown(reopenedCache.close);
    final reopened = CachedBrowsableComicSource(
      source: reopenedRaw,
      cache: reopenedCache.responses,
    );

    final sourceFile = await reopened.loadImageSource(
      sourceCover,
      revision: 'source-r1',
    );
    final detailFile = await reopened.loadImageSource(
      detailCover,
      comicId: 'comic-1',
      revision: 'comic-r1',
    );
    expect(sourceFile.origin, EncodedResourceOrigin.durableCacheFile);
    expect(detailFile.origin, EncodedResourceOrigin.durableCacheFile);
    expect(sourceFile, isA<FileEncodedResourceSource>());
    expect(detailFile, isA<FileEncodedResourceSource>());
    expect(reopenedRaw.resourceLoads, 0);
    expect(reopenedCache.responses.stats.persistentHits, 2);
  });
}

final class _CoverSource implements BrowsableComicSource {
  _CoverSource({this.failResourceLoads = false});

  static final Uint8List sourceBytes = Uint8List.fromList(<int>[1, 2, 3]);
  static final Uint8List detailBytes = Uint8List.fromList(<int>[4, 5, 6, 7]);

  final bool failResourceLoads;
  int resourceLoads = 0;

  @override
  String get sourceId => 'restart-fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Restart fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) async => ComicManifest(
        comic: Comic(
          comicId: comicId,
          sourceId: sourceId,
          title: 'Fixture',
          authors: const <String>[],
          readingDirection: ReadingDirection.ltr,
        ),
        chapters: const <Chapter>[],
      );

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnsupportedError('not used by this fixture');

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    resourceLoads++;
    if (failResourceLoads) {
      throw StateError('persistent cover cache missed after restart');
    }
    return Uint8List.fromList(
      uri.path.contains('source-cover') ? sourceBytes : detailBytes,
    );
  }
}
