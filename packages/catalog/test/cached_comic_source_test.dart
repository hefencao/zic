import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';

void main() {
  test('catalog metadata shares one cache manager', () async {
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
    expect(raw.comicLoads, 1);
    expect(raw.chapterLoads, 1);
    expect(raw.browseLoads, 1);
    expect(raw.lastQuery, 'query');
    expect(raw.resourceLoads, 0);
    expect(cache.stats.forKind(ResourceCacheKind.comicDetails).entries, 1);
    expect(cache.stats.forKind(ResourceCacheKind.chapterMetadata).entries, 1);
    expect(cache.stats.forKind(ResourceCacheKind.searchResults).entries, 1);
    expect(
      cache.stats.forKind(ResourceCacheKind.comicDetails).weight,
      greaterThan(256),
    );
    expect(
      cache.stats.forKind(ResourceCacheKind.chapterMetadata).weight,
      greaterThan(256),
    );
    expect(
      cache.stats.forKind(ResourceCacheKind.searchResults).weight,
      greaterThan(256),
    );
  });


  test('browse sections and pages use stable cache identities with refresh',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    final sections = await source.loadBrowseSections();
    await source.loadBrowseSections();
    final first = await source.browseSection('popular', offset: 0, limit: 24);
    expect(source.peekBrowsePage(sectionId: 'popular'), same(first));
    await source.browseSection('popular', offset: 0, limit: 24);
    await source.refreshBrowsePage(sectionId: 'popular', offset: 0, limit: 24);

    expect(sections.single.sectionId, 'popular');
    expect(raw.sectionLoads, 1);
    expect(raw.browseLoads, 2);
    expect(raw.lastSectionId, 'popular');
    final latest = source.peekLatestBrowseProjection();
    expect(latest, isNotNull);
    expect(latest!.sectionId, 'popular');
    expect(latest.offset, 0);
    expect(latest.limit, 24);
    expect(latest.page.items.single.sourceId, raw.sourceId);
  });

  test('default filter browse has a distinct cache mode from source sections',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    await source.browseSection('popular', offset: 0, limit: 24);
    await source.browseWithFilters(
      sectionId: 'popular',
      offset: 0,
      limit: 24,
      filterState: const <String, Object?>{},
    );

    expect(raw.sectionBrowseLoads, 1);
    expect(raw.filterBrowseLoads, 1);
    expect(
      source.peekBrowsePage(
        sectionId: 'popular',
        offset: 0,
        limit: 24,
        useFilters: true,
      ),
      isNotNull,
    );
    expect(
      source.peekLatestBrowseProjection()!.useFilters,
      isTrue,
    );
    expect(
      cache.stats.forKind(ResourceCacheKind.searchResults).entries,
      2,
    );
  });

  test('latest browse projection follows the target source request identity',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    await source.browseSection('popular', offset: 0, limit: 24);
    await source.browseSection('latest', offset: 24, limit: 12);

    final latest = source.peekLatestBrowseProjection();
    expect(latest, isNotNull);
    expect(latest!.sectionId, 'latest');
    expect(latest.offset, 24);
    expect(latest.limit, 12);
    expect(latest.page.offset, 24);
  });

  test('cached source preserves the optional comic web URI capability', () {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    expect(source, isA<ComicWebUriSource>());
    expect(
      source.resolveComicWebUri('comic'),
      Uri.parse('https://example.invalid/comic/comic'),
    );
  });

  test('cached source preserves canonical comic identity capability', () {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    expect(source, isA<CanonicalComicIdentitySource>());
    expect(
      source.canonicalComicIdentity('mutable-alias'),
      'https://example.invalid/comic/mutable-alias',
    );
  });

  test('cached source preserves the WebView request user agent', () {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final request = source.webViewRequest(
      Uri.parse('https://example.invalid/comic/comic'),
    );

    expect(source, isA<ComicWebViewRequestSource>());
    expect(request.url.path, '/comic/comic');
    expect(request.userAgent, 'fixture-browser-agent');
  });

  test('cached source preserves the source-owned version capability', () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    expect(source, isA<ComicVersionSource>());
    final versions = await (source as ComicVersionSource)
        .findComicVersions('comic');

    expect(source.supportsComicVersions, isTrue);
    expect(versions.single.comicId, 'version');
    expect(raw.versionLoads, 1);
  });

  test('comic metadata refresh preserves artwork and search caches',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final cover = Uri.parse('https://example.invalid/cover');

    Future<Uint8List> loadCover() async {
      raw.resourceLoads++;
      return Uint8List.fromList(<int>[9, 8, 7]);
    }

    await source.loadComic('comic');
    await source.loadChapter('chapter');
    await loadCachedComicImage(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      imageIdentity: cover.toString(),
      loader: loadCover,
    );
    await source.browse(query: 'query');
    source.invalidateComicMetadata('comic');

    await source.loadComic('comic');
    await source.loadChapter('chapter');
    await loadCachedComicImage(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      imageIdentity: cover.toString(),
      loader: loadCover,
    );
    await source.browse(query: 'query');

    expect(raw.comicLoads, 2);
    expect(raw.chapterLoads, 2);
    expect(raw.resourceLoads, 1);
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

    invalidateAllComicResources(
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
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    var loads = 0;
    final cover = Uri.parse('https://example.invalid/revisioned-cover');

    Future<Uint8List> load() async {
      loads++;
      return Uint8List.fromList(<int>[1, 2, 3]);
    }

    for (final revision in <String>['r1', 'r1', 'r2']) {
      await loadCachedComicImage(
        cache: cache,
        sourceId: 'fixture',
        comicId: 'comic',
        imageIdentity: cover.toString(),
        revision: revision,
        loader: load,
      );
    }

    expect(loads, 2);
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


  test('stable cache-key encoding is delimiter safe', () {
    final left = encodeStableCacheKey('fixture', <String>['a:b', 'c']);
    final right = encodeStableCacheKey('fixture', <String>['a', 'b:c']);

    expect(left, isNot(right));
    expect(left, encodeStableCacheKey('fixture', <String>['a:b', 'c']));
  });

  test('comic cover cache identity survives locator URL changes', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    var loads = 0;

    Future<Uint8List> load() async {
      loads++;
      return Uint8List.fromList(<int>[1, 2, 3]);
    }

    for (final uri in <Uri>[
      Uri.parse('https://cdn.invalid/cover-old.jpg?token=old'),
      Uri.parse('https://cdn.invalid/cover-new.jpg?token=new'),
    ]) {
      await loadCachedComicImage(
        cache: cache,
        sourceId: 'fixture',
        comicId: 'comic',
        imageIdentity: uri.toString(),
        loader: load,
      );
    }

    expect(loads, 1);
    expect(cache.stats.forKind(ResourceCacheKind.imageBytes).entries, 1);
  });
}

final class _CountingSource implements
        BrowsableComicSource,
        ComicWebUriSource,
        CanonicalComicIdentitySource,
        ComicWebViewRequestSource,
        ComicVersionSource,
        SectionedBrowsableComicSource,
        FilterableBrowsableComicSource {
  var comicLoads = 0;
  var chapterLoads = 0;
  var browseLoads = 0;
  var resourceLoads = 0;
  var versionLoads = 0;
  var sectionLoads = 0;
  var sectionBrowseLoads = 0;
  var filterBrowseLoads = 0;
  String? lastQuery;
  String? lastSectionId;

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
  Future<List<SourceBrowseSection>> loadBrowseSections() async {
    sectionLoads++;
    return const <SourceBrowseSection>[
      SourceBrowseSection(sectionId: 'popular', label: '热门'),
    ];
  }

  @override
  Future<List<SourceSearchFilterNode>> loadSearchFilters() async =>
      const <SourceSearchFilterNode>[
        SourceSearchFilterNode(
          filterId: 'status',
          kind: SourceSearchFilterKind.checkBox,
          label: '状态',
          value: false,
        ),
      ];

  @override
  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
  }) {
    filterBrowseLoads++;
    lastSectionId = sectionId;
    return browse(query: query, offset: offset, limit: limit);
  }

  @override
  Future<SourceBrowsePage> browseSection(
    String sectionId, {
    String query = '',
    int offset = 0,
    int limit = 24,
  }) {
    sectionBrowseLoads++;
    lastSectionId = sectionId;
    return browse(query: query, offset: offset, limit: limit);
  }

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
  Uri resolveComicWebUri(String comicId) =>
      Uri.parse('https://example.invalid/comic/$comicId');

  @override
  String canonicalComicIdentity(String comicId) =>
      resolveComicWebUri(comicId).toString();

  @override
  ComicWebViewRequest webViewRequest(Uri url) => ComicWebViewRequest(
        url: url,
        userAgent: 'fixture-browser-agent',
      );

  @override
  bool get supportsComicVersions => true;

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    versionLoads++;
    return const <SourceComicVersion>[
      SourceComicVersion(
        sourceId: 'fixture',
        comicId: 'version',
        title: 'Version',
        generation: 1,
      ),
    ];
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    resourceLoads++;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}
