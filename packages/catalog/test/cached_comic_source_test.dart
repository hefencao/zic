import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';

void main() {
  test('cached source preserves resource transport generation identity', () {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final first = CachedBrowsableComicSource(source: raw, cache: cache);
    final second = CachedBrowsableComicSource(source: raw, cache: cache);

    expect(first.resourceTransportGenerationIdentity, same(raw));
    expect(
      second.resourceTransportGenerationIdentity,
      same(first.resourceTransportGenerationIdentity),
    );
  });

  test('cached source preserves controlled resource refresh capability', () async {
    final raw = _RefreshableCountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final uri = Uri.parse('venera-resource:stale-page');

    expect(source, isA<RefreshableComicResourceSource>());
    expect(source, isA<ControlledRefreshableComicResourceSource>());

    await source.refreshResourceControlled(uri);

    expect(raw.refreshes, 1);
    expect(raw.lastRefreshedUri, uri);
  });

  test('cached source preserves controlled metadata and version ownership',
      () async {
    final raw = _ControlledMetadataCountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    final control = _TestTaskControl(priority: 100);

    await source.loadComicControlled('comic-controlled', control: control);
    expect(raw.lastComicControl, same(control));

    await source.loadChapterControlled('chapter-controlled', control: control);
    expect(raw.lastChapterControl, same(control));

    await source.findComicVersionsControlled(
      'comic-controlled',
      control: control,
    );
    expect(raw.lastVersionControl, same(control));
  });

  test('cached source preserves resource-operation timeout capability', () {
    final raw = _BoundedCountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    expect(
      source.resourceOperationTimeout,
      const Duration(seconds: 23),
    );
  });

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

  test('comic detail preview and comments use independent cached responses',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    final preview = await source.loadComicPreview('comic');
    expect(await source.loadComicPreview('comic'), same(preview));
    final comments = await source.loadComicComments(
      'comic',
      page: 1,
    );
    expect(
      await source.loadComicComments('comic', page: 1),
      same(comments),
    );
    expect(raw.previewLoads, 1);
    expect(raw.commentLoads, 1);
    expect(source.peekComicPreview('comic'), same(preview));
    expect(source.peekComicComments('comic', page: 1), same(comments));

    await source.refreshComicPreview('comic');
    await source.refreshComicComments('comic', page: 1);

    expect(raw.previewLoads, 2);
    expect(raw.commentLoads, 2);
    expect(
      cache.stats.forKind(ResourceCacheKind.comicDetails).entries,
      2,
    );
  });

  test('forced embedded detail refresh replaces stale side-page projections',
      () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    raw.embeddedPreview = _previewPage('embedded-old');
    raw.embeddedComments = _commentPage('embedded-old');
    await source.refreshComic('comic');
    expect(source.peekComicPreview('comic')!.items.single.label, 'embedded-old');
    expect(
      source.peekComicComments('comic', page: 1)!.items.single.content,
      'embedded-old',
    );

    raw.embeddedPreview = _previewPage('embedded-new');
    raw.embeddedComments = _commentPage('embedded-new');
    await source.refreshComic('comic');

    expect(source.peekComicPreview('comic')!.items.single.label, 'embedded-new');
    expect(
      source.peekComicComments('comic', page: 1)!.items.single.content,
      'embedded-new',
    );
  });

  test('independent side refresh bypasses embedded first pages', () async {
    final raw = _CountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);

    raw.embeddedPreview = _previewPage('embedded');
    raw.embeddedComments = _commentPage('embedded');
    await source.loadComic('comic');

    await source.refreshComicPreview('comic');
    await source.refreshComicComments('comic', page: 1);

    expect(
      source.peekComicPreview('comic')!.items.single.uri,
      Uri.parse('https://example.invalid/preview/1'),
    );
    expect(
      source.peekComicComments('comic', page: 1)!.items.single.content,
      'Comment 1',
    );
    expect(raw.previewLoads, 1);
    expect(raw.commentLoads, 1);
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

  test('canonical aliases retain request-scoped comic manifests and artwork',
      () async {
    final raw = _CanonicalAliasCountingSource();
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final source = CachedBrowsableComicSource(source: raw, cache: cache);
    const native = '/album/123';
    const opaque = 'mihon:manga:original';
    final identity = ComicResourceCacheIdentity.fromSource(source, native);
    expect(
      ComicResourceCacheIdentity.fromSource(source, opaque).namespace,
      identity.namespace,
    );

    final nativeManifest = await source.loadComic(native);
    expect(source.peekComic(opaque), isNull);
    final opaqueManifests = await Future.wait(<Future<ComicManifest>>[
      source.loadComic(opaque),
      source.loadComic(opaque),
    ]);
    final opaqueManifest = opaqueManifests.first;
    expect(opaqueManifests.last, same(opaqueManifest));
    expect(nativeManifest.comic.comicId, native);
    expect(nativeManifest.chapters.single.comicId, native);
    expect(opaqueManifest.comic.comicId, opaque);
    expect(opaqueManifest.chapters.single.comicId, opaque);
    expect(source.peekComic(native), same(nativeManifest));
    expect(source.peekComic(opaque), same(opaqueManifest));
    expect(raw.comicLoads, 2);

    await source.refreshComic(native);
    expect(source.peekComic(opaque), same(opaqueManifest));
    expect(await source.loadComic(opaque), same(opaqueManifest));
    expect(raw.comicLoads, 3);

    Future<Uint8List> loadCover() async {
      raw.resourceLoads++;
      return Uint8List.fromList(<int>[9, 8, 7]);
    }

    Future<Uint8List> cover(String comicId) => loadCachedComicImage(
          cache: cache,
          sourceId: source.sourceId,
          comicId: source.canonicalComicIdentity(comicId),
          imageIdentity: 'cover',
          loader: loadCover,
        );
    final bytes = await cover(native);
    expect(await cover(opaque), same(bytes));
    await source.browse(query: 'query');
    source.invalidateComicMetadata(opaque);
    expect(source.peekComic(native), isNull);
    expect(source.peekComic(opaque), isNull);
    final reloaded = await Future.wait(<Future<ComicManifest>>[
      source.loadComic(native),
      source.loadComic(opaque),
    ]);
    expect(reloaded.first.comic.comicId, native);
    expect(reloaded.last.comic.comicId, opaque);
    expect(raw.comicLoads, 5);
    expect(await cover(native), same(bytes));
    expect(await cover(opaque), same(bytes));
    await source.browse(query: 'query');
    expect(raw.resourceLoads, 1);
    expect(raw.browseLoads, 1);
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

ComicPreviewPage _previewPage(String label) => ComicPreviewPage(
      items: <ComicPreviewAsset>[
        ComicPreviewAsset(
          uri: Uri.parse('https://example.invalid/$label'),
          label: label,
        ),
      ],
    );

ComicCommentPage _commentPage(String content) => ComicCommentPage(
      page: 1,
      maxPage: 1,
      items: <ComicComment>[
        ComicComment(userName: 'Reader', content: content),
      ],
    );


final class _RefreshableCountingSource extends _CountingSource
    implements
        RefreshableComicResourceSource,
        ControlledRefreshableComicResourceSource {
  var refreshes = 0;
  Uri? lastRefreshedUri;

  @override
  Future<void> refreshResource(Uri uri) => refreshResourceControlled(uri);

  @override
  Future<void> refreshResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    refreshes++;
    lastRefreshedUri = uri;
  }
}

final class _ControlledMetadataCountingSource extends _CountingSource
    implements ControlledComicSource, ControlledComicVersionSource {
  TaskControl? lastComicControl;
  TaskControl? lastChapterControl;
  TaskControl? lastVersionControl;

  @override
  Future<ComicManifest> loadComicControlled(
    String comicId, {
    TaskControl? control,
  }) {
    lastComicControl = control;
    return super.loadComic(comicId);
  }

  @override
  Future<ChapterManifest> loadChapterControlled(
    String chapterId, {
    TaskControl? control,
  }) {
    lastChapterControl = control;
    return super.loadChapter(chapterId);
  }

  @override
  Future<List<SourceComicVersion>> findComicVersionsControlled(
    String comicId, {
    TaskControl? control,
  }) {
    lastVersionControl = control;
    return super.findComicVersions(comicId);
  }
}

final class _TestTaskControl implements TaskControl {
  _TestTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  final int priority;

  @override
  Future<void> get whenCancelled => _cancelled.future;
}

final class _BoundedCountingSource extends _CountingSource
    implements BoundedComicResourceSource {
  @override
  Duration get resourceOperationTimeout => const Duration(seconds: 23);
}

final class _CanonicalAliasCountingSource extends _CountingSource {
  @override
  String get sourceId => 'mihon:fixture';

  @override
  String canonicalComicIdentity(String comicId) =>
      'https://example.invalid/album/123';

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
      chapters: <Chapter>[
        Chapter(
          chapterId: '$comicId/chapter',
          comicId: comicId,
          title: 'Chapter',
          sequence: 1,
          pageCount: 1,
          sourceRevision: 'r1',
        ),
      ],
    );
  }
}

class _CountingSource implements
        BrowsableComicSource,
        ComicWebUriSource,
        CanonicalComicIdentitySource,
        ComicWebViewRequestSource,
        ComicVersionSource,
        ComicPreviewSource,
        ComicCommentSource,
        SectionedBrowsableComicSource,
        FilterableBrowsableComicSource {
  var comicLoads = 0;
  var chapterLoads = 0;
  var browseLoads = 0;
  var resourceLoads = 0;
  var versionLoads = 0;
  var previewLoads = 0;
  var commentLoads = 0;
  ComicPreviewPage? embeddedPreview;
  ComicCommentPage? embeddedComments;
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
      items: <SourceComicSummary>[
        SourceComicSummary(
          sourceId: sourceId,
          comicId: 'comic',
          title: 'Comic',
          authors: const <String>[],
          coverUri: Uri.parse('https://example.invalid/cover.jpg'),
        ),
      ],
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
      preview: embeddedPreview,
      comments: embeddedComments,
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
  bool get supportsComicPreview => true;

  @override
  Future<ComicPreviewPage> loadComicPreview(
    String comicId, {
    String? nextToken,
  }) async {
    previewLoads++;
    return ComicPreviewPage(
      items: <ComicPreviewAsset>[
        ComicPreviewAsset(
          uri: Uri.parse('https://example.invalid/preview/$previewLoads'),
          width: 100,
          height: 200,
        ),
      ],
      nextToken: nextToken == null ? 'next' : null,
    );
  }

  @override
  bool get supportsComicComments => true;

  @override
  Future<ComicCommentPage> loadComicComments(
    String comicId, {
    String? subId,
    required int page,
    String? replyTo,
  }) async {
    commentLoads++;
    return ComicCommentPage(
      page: page,
      maxPage: page,
      items: <ComicComment>[
        ComicComment(
          id: 'comment-$commentLoads',
          userName: 'Reader',
          content: 'Comment $commentLoads',
        ),
      ],
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
