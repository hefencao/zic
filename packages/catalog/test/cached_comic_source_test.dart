import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';

void main() {
  test('catalog metadata and images share one cache manager', () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    await Future.wait(<Future<Object>>[
      source.loadComic('comic'),
      source.loadComic('comic'),
    ]);
    await source.loadChapter('chapter');
    await source.loadChapter('chapter');
    await source.browse(query: ' query ');
    await source.browse(query: 'query');
    await source.loadImage(
      Uri.parse('https://example.invalid/cover'),
      comicId: 'comic',
    );
    await source.loadImage(
      Uri.parse('https://example.invalid/cover'),
      comicId: 'comic',
    );

    expect(raw.comicLoads, 1);
    expect(raw.chapterLoads, 1);
    expect(raw.browseLoads, 1);
    expect(raw.lastQuery, 'query');
    expect(raw.resourceLoads, 1);
    expect(cache.stats.forKind(ResourceCacheKind.imageBytes).entries, 1);
    expect(cache.stats.forKind(ResourceCacheKind.comicDetails).entries, 1);
    expect(cache.stats.forKind(ResourceCacheKind.chapterMetadata).entries, 1);
    expect(cache.stats.forKind(ResourceCacheKind.searchResults).entries, 1);
  });

  test('comic invalidation clears related detail chapter and artwork only',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final cover = Uri.parse('https://example.invalid/cover');

    await source.loadComic('comic');
    await source.loadChapter('chapter');
    await source.loadImage(cover, comicId: 'comic');
    await source.browse(query: 'query');
    source.invalidateComic('comic');

    await source.loadComic('comic');
    await source.loadChapter('chapter');
    await source.loadImage(cover, comicId: 'comic');
    await source.browse(query: 'query');

    expect(raw.comicLoads, 2);
    expect(raw.chapterLoads, 2);
    expect(raw.resourceLoads, 2);
    expect(raw.browseLoads, 1);
  });

  test('generic comic images share namespace invalidation', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    var loads = 0;

    Future<Uint8List> load() async {
      loads++;
      return Uint8List.fromList(<int>[4, 5, 6]);
    }

    await loadCachedComicImage(
      cache: cache,
      sourceId: 'fixture',
      comicId: 'comic',
      imageIdentity: 'local-cover',
      loader: load,
    );
    await loadCachedComicImage(
      cache: cache,
      sourceId: 'fixture',
      comicId: 'comic',
      imageIdentity: 'local-cover',
      loader: load,
    );
    expect(loads, 1);

    invalidateComicResourceCache(
      cache,
      sourceId: 'fixture',
      comicId: 'comic',
    );
    await loadCachedComicImage(
      cache: cache,
      sourceId: 'fixture',
      comicId: 'comic',
      imageIdentity: 'local-cover',
      loader: load,
    );
    expect(loads, 2);
  });

  test('image revision separates changed cover bytes', () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final cover = Uri.parse('https://example.invalid/revisioned-cover');

    await source.loadImage(cover, comicId: 'comic', revision: 'r1');
    await source.loadImage(cover, comicId: 'comic', revision: 'r1');
    await source.loadImage(cover, comicId: 'comic', revision: 'r2');

    expect(raw.resourceLoads, 2);
    expect(cache.stats.forKind(ResourceCacheKind.imageBytes).entries, 2);
  });

  test('chapter metadata schema revision bypasses stale locator entries',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final stale = await raw.loadChapter('chapter');
    raw.chapterLoads = 0;

    await cache.getOrLoad<ChapterManifest>(
      key: const ResourceCacheKey(
        kind: ResourceCacheKind.chapterMetadata,
        identity: 'fixture\u0000chapter',
        namespace: 'source:fixture',
      ),
      loader: () async => stale,
      weightOf: (_) => 1,
    );

    final loaded = await source.loadChapter('chapter');

    expect(loaded.pages.single.uri, stale.pages.single.uri);
    expect(raw.chapterLoads, 1);
    expect(cache.stats.forKind(ResourceCacheKind.chapterMetadata).entries, 2);
  });

  test('chapter refresh capability bypasses the current response', () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    await source.loadChapter('chapter');
    await source.refreshChapter('chapter');

    expect(raw.chapterLoads, 2);
    expect(cache.stats.forKind(ResourceCacheKind.chapterMetadata).entries, 1);
  });

  test('raw page resources bypass response cache for pipeline ownership',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final uri = Uri.parse('https://example.invalid/page');

    await source.loadResource(uri);
    await source.loadResource(uri);

    expect(raw.resourceLoads, 2);
    expect(cache.stats.entries, 0);
  });
}

final class _CountingSource implements BrowsableComicSource {
  var comicLoads = 0;
  var chapterLoads = 0;
  var browseLoads = 0;
  var resourceLoads = 0;
  String? lastQuery;

  @override
  String get sourceId => 'fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async {
    browseLoads++;
    lastQuery = query;
    return SourceBrowsePage(
      items: const <SourceComicSummary>[],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    comicLoads++;
    return ComicManifest(
      comic: Comic(
        comicId: comicId,
        sourceId: sourceId,
        title: 'Comic',
        authors: const <String>[],
        readingDirection: ReadingDirection.ltr,
      ),
      chapters: const <Chapter>[
        Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'Chapter',
          sequence: 1,
          pageCount: 1,
          sourceRevision: 'r1',
        ),
      ],
    );
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    chapterLoads++;
    return ChapterManifest(
      sourceId: sourceId,
      comicId: 'comic',
      chapter: Chapter(
        chapterId: chapterId,
        comicId: 'comic',
        title: 'Chapter',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page',
          chapterId: chapterId,
          index: 0,
          uri: Uri.parse('https://example.invalid/page'),
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    resourceLoads++;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}
