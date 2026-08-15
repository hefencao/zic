import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';

import 'cache_identity.dart';
import 'comic_source.dart';
import 'source_catalog.dart';

String _canonicalFilterState(SourceSearchFilterState state) {
  final output = StringBuffer();

  void writeValue(Object? value) {
    if (value == null) {
      output.write('n;');
      return;
    }
    if (value is bool) {
      output.write(value ? 'b1;' : 'b0;');
      return;
    }
    if (value is int) {
      output
        ..write('i')
        ..write(value)
        ..write(';');
      return;
    }
    if (value is String) {
      output
        ..write('s')
        ..write(value.length)
        ..write(':')
        ..write(value)
        ..write(';');
      return;
    }
    if (value is Map<Object?, Object?>) {
      final keys = value.keys.cast<String>().toList()..sort();
      output
        ..write('m')
        ..write(keys.length)
        ..write('{');
      for (final key in keys) {
        writeValue(key);
        writeValue(value[key]);
      }
      output.write('}');
      return;
    }
    if (value is List<Object?>) {
      output
        ..write('l')
        ..write(value.length)
        ..write('[');
      for (final item in value) {
        writeValue(item);
      }
      output.write(']');
      return;
    }
    throw ArgumentError.value(
      value,
      'filterState',
      'Unsupported search-filter state value.',
    );
  }

  writeValue(state);
  return output.toString();
}

/// Catalog decorator for reusable source-response caching.
///
/// Search pages, comic details and chapter metadata share one
/// [ResourceCacheManager]. Artwork is deliberately not loaded here: App
/// composition routes external artwork through ComicSourceResourceGateway,
/// while [loadResource] remains the raw source-owned compatibility capability
/// consumed only behind that gateway/streaming transport boundary.
final class CachedBrowsableComicSource
    implements
        BrowsableComicSource,
        ConfigurableComicSource,
        AuthenticatableComicSource,
        ComicWebUriSource,
        CanonicalComicIdentitySource,
        ComicWebViewRequestSource,
        ComicVersionSource,
        ComicPreviewSource,
        ComicCommentSource,
        SectionedBrowsableComicSource,
        FilterableBrowsableComicSource,
        CachedSourceBrowseProjection,
        RefreshableChapterComicSource,
        ResolvableComicResourceSource,
        ControlledResolvableComicResourceSource,
        RetryableComicResourceSource,
        ControlledRetryableComicResourceSource,
        ControlledComicResourceSource {
  CachedBrowsableComicSource({
    required this.source,
    required this.cache,
  });

  final BrowsableComicSource source;
  final ResourceCacheManager cache;
  static const String _chapterMetadataSchemaRevision =
      'chapter-metadata-v3-source-contract-refresh';
  static const int _maxChapterIdentityIndex = 512;
  final LinkedHashMap<String, String> _chapterComicIds =
      LinkedHashMap<String, String>();
  CachedSourceBrowseSnapshot? _latestBrowseProjection;

  @override
  String get sourceId => source.sourceId;

  @override
  ComicSourceDescriptor get descriptor => source.descriptor;

  ResourceCacheKey _browseKey({
    required String normalizedQuery,
    required int offset,
    required int limit,
    String? sectionId,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  }) =>
      ResourceCacheKey(
        kind: ResourceCacheKind.searchResults,
        identity: encodeStableCacheKey(
          'search-results',
          <String>[
            sourceId,
            sectionId ?? '',
            normalizedQuery,
            '$offset',
            '$limit',
            useFilters ? 'filters' : 'section',
            _canonicalFilterState(filterState),
          ],
        ),
        namespace: sourceResourceCacheNamespace(sourceId),
      );

  Future<SourceBrowsePage> _loadBrowsePage({
    required String normalizedQuery,
    required int offset,
    required int limit,
    String? sectionId,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
    bool forceRefresh = false,
  }) {
    final sectioned = source is SectionedBrowsableComicSource
        ? source as SectionedBrowsableComicSource
        : null;
    final result = cache.getOrLoad<SourceBrowsePage>(
      key: _browseKey(
        normalizedQuery: normalizedQuery,
        offset: offset,
        limit: limit,
        sectionId: sectionId,
        filterState: filterState,
        useFilters: useFilters,
      ),
      loader: () {
        final filterable = source is FilterableBrowsableComicSource
            ? source as FilterableBrowsableComicSource
            : null;
        if (filterable != null && useFilters) {
          return filterable.browseWithFilters(
            sectionId: sectionId,
            query: normalizedQuery,
            offset: offset,
            limit: limit,
            filterState: filterState,
          );
        }
        return sectionId != null && sectioned != null
          ? sectioned.browseSection(
              sectionId,
              query: normalizedQuery,
              offset: offset,
              limit: limit,
            )
          : source.browse(
              query: normalizedQuery,
              offset: offset,
              limit: limit,
            );
      },
      weightOf: _browseWeight,
      forceRefresh: forceRefresh,
    );
    return result.then((page) {
      _latestBrowseProjection = CachedSourceBrowseSnapshot(
        page: page,
        sectionId: sectionId,
        query: normalizedQuery,
        offset: offset,
        limit: limit,
        filterState: filterState,
        useFilters: useFilters,
      );
      return page;
    });
  }

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      _loadBrowsePage(
        normalizedQuery: query.trim(),
        offset: offset,
        limit: limit,
      );

  @override
  Future<List<SourceBrowseSection>> loadBrowseSections() {
    final sectioned = source is SectionedBrowsableComicSource
        ? source as SectionedBrowsableComicSource
        : null;
    if (sectioned == null) {
      return Future<List<SourceBrowseSection>>.value(
        const <SourceBrowseSection>[],
      );
    }
    return cache.getOrLoad<List<SourceBrowseSection>>(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.searchResults,
        identity: encodeStableCacheKey(
          'browse-sections',
          <String>[sourceId],
        ),
        namespace: sourceResourceCacheNamespace(sourceId),
      ),
      loader: sectioned.loadBrowseSections,
      weightOf: _browseSectionsWeight,
    );
  }

  @override
  Future<List<SourceSearchFilterNode>> loadSearchFilters() {
    final filterable = source is FilterableBrowsableComicSource
        ? source as FilterableBrowsableComicSource
        : null;
    if (filterable == null) {
      return Future<List<SourceSearchFilterNode>>.value(
        const <SourceSearchFilterNode>[],
      );
    }
    return filterable.loadSearchFilters();
  }

  @override
  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
  }) =>
      _loadBrowsePage(
        normalizedQuery: query.trim(),
        offset: offset,
        limit: limit,
        sectionId: sectionId,
        filterState: filterState,
        useFilters: true,
      );

  @override
  Future<SourceBrowsePage> browseSection(
    String sectionId, {
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      _loadBrowsePage(
        normalizedQuery: query.trim(),
        offset: offset,
        limit: limit,
        sectionId: sectionId,
      );

  @override
  CachedSourceBrowseSnapshot? peekLatestBrowseProjection() =>
      _latestBrowseProjection;

  @override
  SourceBrowsePage? peekBrowsePage({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  }) {
    final normalizedQuery = query.trim();
    final page = cache.peek<SourceBrowsePage>(
      _browseKey(
        normalizedQuery: normalizedQuery,
        offset: offset,
        limit: limit,
        sectionId: sectionId,
        filterState: filterState,
        useFilters: useFilters,
      ),
    );
    if (page != null) {
      _latestBrowseProjection = CachedSourceBrowseSnapshot(
        page: page,
        sectionId: sectionId,
        query: normalizedQuery,
        offset: offset,
        limit: limit,
        filterState: filterState,
        useFilters: useFilters,
      );
    }
    return page;
  }

  @override
  Future<SourceBrowsePage> refreshBrowsePage({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
    bool useFilters = false,
  }) =>
      _loadBrowsePage(
        normalizedQuery: query.trim(),
        offset: offset,
        limit: limit,
        sectionId: sectionId,
        filterState: filterState,
        useFilters: useFilters,
        forceRefresh: true,
      );

  @override
  Uri? resolveComicWebUri(String comicId) {
    final Object candidate = source;
    if (candidate is! ComicWebUriSource) return descriptor.website;
    final webSource = candidate;
    return webSource.resolveComicWebUri(comicId);
  }

  @override
  String canonicalComicIdentity(String comicId) {
    final Object candidate = source;
    if (candidate is! CanonicalComicIdentitySource) return comicId;
    final identitySource = candidate;
    return identitySource.canonicalComicIdentity(comicId);
  }

  @override
  ComicWebViewRequest webViewRequest(Uri url) {
    final Object candidate = source;
    if (candidate is! ComicWebViewRequestSource) {
      return ComicWebViewRequest(url: url);
    }
    final requestSource = candidate;
    return requestSource.webViewRequest(url);
  }

  @override
  bool get supportsComicVersions {
    final Object candidate = source;
    if (candidate is! ComicVersionSource) return false;
    final versionSource = candidate;
    return versionSource.supportsComicVersions;
  }

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) {
    final Object candidate = source;
    if (candidate is! ComicVersionSource) {
      return Future<List<SourceComicVersion>>.value(
        const <SourceComicVersion>[],
      );
    }
    final versionSource = candidate;
    if (!versionSource.supportsComicVersions) {
      return Future<List<SourceComicVersion>>.value(
        const <SourceComicVersion>[],
      );
    }
    return versionSource.findComicVersions(comicId);
  }

  @override
  bool get supportsComicPreview {
    final Object candidate = source;
    if (candidate is! ComicPreviewSource) return false;
    final previewSource = candidate;
    return previewSource.supportsComicPreview;
  }

  @override
  Future<ComicPreviewPage> loadComicPreview(
    String comicId, {
    String? nextToken,
  }) {
    final Object candidate = source;
    if (candidate is! ComicPreviewSource) {
      return Future<ComicPreviewPage>.value(
        ComicPreviewPage(items: const <ComicPreviewAsset>[]),
      );
    }
    final previewSource = candidate;
    if (!previewSource.supportsComicPreview) {
      return Future<ComicPreviewPage>.value(
        ComicPreviewPage(items: const <ComicPreviewAsset>[]),
      );
    }
    return previewSource.loadComicPreview(
      comicId,
      nextToken: nextToken,
    );
  }

  @override
  bool get supportsComicComments {
    final Object candidate = source;
    if (candidate is! ComicCommentSource) return false;
    final commentSource = candidate;
    return commentSource.supportsComicComments;
  }

  @override
  Future<ComicCommentPage> loadComicComments(
    String comicId, {
    String? subId,
    required int page,
    String? replyTo,
  }) {
    final Object candidate = source;
    if (candidate is! ComicCommentSource) {
      return Future<ComicCommentPage>.value(
        ComicCommentPage(
          page: page,
          items: const <ComicComment>[],
          maxPage: page,
        ),
      );
    }
    final commentSource = candidate;
    if (!commentSource.supportsComicComments) {
      return Future<ComicCommentPage>.value(
        ComicCommentPage(
          page: page,
          items: const <ComicComment>[],
          maxPage: page,
        ),
      );
    }
    return commentSource.loadComicComments(
      comicId,
      subId: subId,
      page: page,
      replyTo: replyTo,
    );
  }

  @override
  Future<ComicManifest> loadComic(String comicId) {
    final identity = _comicIdentity(comicId);
    return cache
        .getOrLoad<ComicManifest>(
          key: _comicKey(identity),
          loader: () => source.loadComic(comicId),
          weightOf: _comicWeight,
        )
        .then((manifest) {
      _rememberComic(manifest);
      return manifest;
    });
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) {
    final comicId = _chapterComicIds[chapterId];
    return cache
        .getOrLoad<ChapterManifest>(
          key: ResourceCacheKey(
            kind: ResourceCacheKind.chapterMetadata,
            identity: encodeStableCacheKey(
              'chapter-metadata',
              <String>[sourceId, chapterId],
            ),
            namespace: comicId == null
                ? sourceResourceCacheNamespace(sourceId)
                : _comicIdentity(comicId).namespace,
            revision: _chapterMetadataSchemaRevision,
          ),
          loader: () => source.loadChapter(chapterId),
          weightOf: _chapterWeight,
        )
        .then((manifest) {
      _rememberChapter(chapterId, manifest.comicId);
      return manifest;
    });
  }

  /// Raw page/resource transport entry used by Reader and download sessions.
  @override
  Future<Uint8List> loadResource(Uri uri) => source.loadResource(uri);

  @override
  Future<Uint8List> loadResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) {
    final controlled = source is ControlledComicResourceSource
        ? source as ControlledComicResourceSource
        : null;
    return controlled?.loadResourceControlled(uri, control: control) ??
        source.loadResource(uri);
  }

  @override
  Future<ComicResourceRequest> resolveResource(Uri uri) =>
      resolveResourceControlled(uri);

  @override
  Future<ComicResourceRequest> resolveResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) {
    final controlled = source is ControlledResolvableComicResourceSource
        ? source as ControlledResolvableComicResourceSource
        : null;
    if (controlled != null) {
      return controlled.resolveResourceControlled(uri, control: control);
    }
    final resolvable = source is ResolvableComicResourceSource
        ? source as ResolvableComicResourceSource
        : null;
    if (resolvable == null) {
      final direct = uri.scheme == 'http' || uri.scheme == 'https';
      return Future<ComicResourceRequest>.value(
        ComicResourceRequest(
          uri: uri,
          requiresRuntimeTransform: !direct,
        ),
      );
    }
    return resolvable.resolveResource(uri);
  }

  @override
  Future<ComicResourceRequest?> retryResource(Uri uri) =>
      retryResourceControlled(uri);

  @override
  Future<ComicResourceRequest?> retryResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) {
    final controlled = source is ControlledRetryableComicResourceSource
        ? source as ControlledRetryableComicResourceSource
        : null;
    if (controlled != null) {
      return controlled.retryResourceControlled(uri, control: control);
    }
    final retryable = source is RetryableComicResourceSource
        ? source as RetryableComicResourceSource
        : null;
    if (retryable == null) {
      return Future<ComicResourceRequest?>.value(null);
    }
    return retryable.retryResource(uri);
  }

  /// Invalidates one chapter metadata response without touching page artifacts.
  ///
  /// This is used when an adapter-level locator contract changes or a persisted
  /// chapter is known to contain generation-scoped resource identities. Page
  /// bytes remain owned by Reader/download sessions and are deliberately not
  /// removed here.
  @override
  Future<ChapterManifest> refreshChapter(String chapterId) {
    cache.invalidateWhere(
      (key) =>
          key.kind == ResourceCacheKind.chapterMetadata &&
          key.identity == encodeStableCacheKey(
            'chapter-metadata',
            <String>[sourceId, chapterId],
          ),
    );
    _chapterComicIds.remove(chapterId);
    return loadChapter(chapterId);
  }

  @override
  Future<List<ComicSourceSetting>> loadSettings() {
    final configurable = source is ConfigurableComicSource
        ? source as ConfigurableComicSource
        : null;
    if (configurable == null) {
      return Future<List<ComicSourceSetting>>.value(
        const <ComicSourceSetting>[],
      );
    }
    return configurable.loadSettings();
  }

  @override
  Future<void> updateSetting(String key, Object value) {
    final configurable = source is ConfigurableComicSource
        ? source as ConfigurableComicSource
        : null;
    if (configurable == null) {
      throw UnsupportedError('comic source does not expose settings');
    }
    return configurable.updateSetting(key, value);
  }

  AuthenticatableComicSource get _accountSource {
    final account = source is AuthenticatableComicSource
        ? source as AuthenticatableComicSource
        : null;
    if (account == null) {
      throw UnsupportedError('comic source does not expose account login');
    }
    return account;
  }

  @override
  Future<ComicSourceAccount> loadAccount() => _accountSource.loadAccount();

  @override
  Future<void> loginWithCredentials(String account, String password) =>
      _accountSource.loginWithCredentials(account, password);

  @override
  Future<void> loginWithCookies(Map<String, String> cookies) =>
      _accountSource.loginWithCookies(cookies);

  @override
  Future<void> confirmWebLogin({
    String? currentUrl,
    String? title,
    Map<String, String> cookies = const <String, String>{},
    Map<String, String> localStorage = const <String, String>{},
  }) =>
      _accountSource.confirmWebLogin(
        currentUrl: currentUrl,
        title: title,
        cookies: cookies,
        localStorage: localStorage,
      );

  @override
  Future<void> logout() => _accountSource.logout();


  void invalidateComicMetadata(String comicId) {
    final identity = _comicIdentity(comicId);
    final cached = cache.peek<ComicManifest>(_comicKey(identity));
    if (cached != null) {
      _rememberComic(cached);
    }
    final chapterIds = _chapterComicIds.entries
        .where((entry) => entry.value == comicId)
        .map((entry) => entry.key)
        .toList(growable: false);
    final namespaces = <String>{
      identity.namespace,
      if (identity.comicId != comicId)
        ComicResourceCacheIdentity(
          sourceId: sourceId,
          comicId: comicId,
        ).namespace,
    };
    cache.invalidateWhere(
      (key) =>
          namespaces.contains(key.namespace) &&
          key.kind != ResourceCacheKind.imageBytes,
    );
    for (final chapterId in chapterIds) {
      cache.invalidateWhere(
        (key) =>
            key.kind == ResourceCacheKind.chapterMetadata &&
            key.identity == encodeStableCacheKey(
              'chapter-metadata',
              <String>[sourceId, chapterId],
            ),
      );
      _chapterComicIds.remove(chapterId);
    }
  }

  void invalidateSearch() => cache.invalidateWhere(
        (key) =>
            key.kind == ResourceCacheKind.searchResults &&
            key.namespace == sourceResourceCacheNamespace(sourceId),
      );

  ComicResourceCacheIdentity _comicIdentity(String comicId) =>
      ComicResourceCacheIdentity(
        sourceId: sourceId,
        comicId: canonicalComicIdentity(comicId),
      );

  void _rememberComic(ComicManifest manifest) {
    for (final chapter in manifest.chapters) {
      _rememberChapter(chapter.chapterId, manifest.comic.comicId);
    }
  }

  void _rememberChapter(String chapterId, String comicId) {
    _chapterComicIds.remove(chapterId);
    _chapterComicIds[chapterId] = comicId;
    while (_chapterComicIds.length > _maxChapterIdentityIndex) {
      _chapterComicIds.remove(_chapterComicIds.keys.first);
    }
  }
}

const int _cacheObjectOverhead = 64;
const int _cacheCollectionOverhead = 24;

int _browseSectionsWeight(List<SourceBrowseSection> sections) =>
    64 +
    sections.fold<int>(
      0,
      (total, section) =>
          total + 32 + section.sectionId.length * 2 + section.label.length * 2,
    );

int _browseWeight(SourceBrowsePage page) =>
    _cacheObjectOverhead +
    _cacheCollectionWeight<SourceComicSummary>(
      page.items,
      _sourceComicSummaryWeight,
    );

int _comicWeight(ComicManifest manifest) =>
    _cacheObjectOverhead +
    _comicValueWeight(manifest.comic) +
    _cacheCollectionWeight<Chapter>(manifest.chapters, _chapterValueWeight) +
    _previewWeight(manifest.preview) +
    _commentPageWeight(manifest.comments);

int _chapterWeight(ChapterManifest manifest) =>
    _cacheObjectOverhead +
    _textWeight(manifest.sourceId) +
    _textWeight(manifest.comicId) +
    _chapterValueWeight(manifest.chapter) +
    _cacheCollectionWeight<PageAsset>(manifest.pages, _pageAssetWeight);

int _sourceComicSummaryWeight(SourceComicSummary summary) =>
    _cacheObjectOverhead +
    _textWeight(summary.sourceId) +
    _textWeight(summary.comicId) +
    _textWeight(summary.title) +
    _cacheCollectionWeight<String>(summary.authors, _textWeight) +
    _cacheCollectionWeight<String>(summary.tags, _textWeight) +
    _uriWeight(summary.coverUri) +
    _textWeight(summary.description);

int _comicValueWeight(Comic comic) =>
    _cacheObjectOverhead +
    _textWeight(comic.comicId) +
    _textWeight(comic.sourceId) +
    _textWeight(comic.title) +
    _cacheCollectionWeight<String>(comic.authors, _textWeight) +
    _cacheCollectionWeight<String>(comic.tags, _textWeight) +
    _uriWeight(comic.coverUri) +
    _textWeight(comic.description) +
    _textWeight(comic.sourceSubId);

int _previewWeight(ComicPreviewPage? page) => page == null
    ? 0
    : _cacheCollectionWeight<ComicPreviewAsset>(
        page.items,
        (asset) =>
            _cacheObjectOverhead +
            _uriWeight(asset.uri) +
            _textWeight(asset.label),
      ) +
        _textWeight(page.nextToken);

int _commentPageWeight(ComicCommentPage? page) => page == null
    ? 0
    : _cacheCollectionWeight<ComicComment>(
        page.items,
        (comment) =>
            _cacheObjectOverhead +
            _textWeight(comment.id) +
            _textWeight(comment.userName) +
            _uriWeight(comment.avatarUri) +
            _textWeight(comment.content) +
            _textWeight(comment.time),
      );

int _chapterValueWeight(Chapter chapter) =>
    _cacheObjectOverhead +
    _textWeight(chapter.chapterId) +
    _textWeight(chapter.comicId) +
    _textWeight(chapter.title) +
    _textWeight(chapter.sourceRevision);

int _pageAssetWeight(PageAsset page) =>
    _cacheObjectOverhead +
    _textWeight(page.pageId) +
    _textWeight(page.chapterId) +
    _textWeight(page.uri.toString()) +
    _textWeight(page.checksum);

int _cacheCollectionWeight<T>(
  Iterable<T> values,
  int Function(T value) weightOf,
) {
  var weight = _cacheCollectionOverhead;
  for (final value in values) {
    weight += weightOf(value);
  }
  return weight;
}

int _uriWeight(Uri? uri) => uri == null ? 0 : _textWeight(uri.toString());

int _textWeight(String? value) =>
    value == null ? 0 : _cacheObjectOverhead + value.length * 2;

Future<Uint8List> loadCachedComicImage({
  required ResourceCacheManager cache,
  required String sourceId,
  required String imageIdentity,
  required Future<Uint8List> Function() loader,
  String? comicId,
  String resourceRole = 'cover',
  String revision = '',
}) => cache.getOrLoad<Uint8List>(
      key: _imageKey(
        sourceId: sourceId,
        comicId: comicId,
        imageIdentity: imageIdentity,
        resourceRole: resourceRole,
        revision: revision,
      ),
      loader: loader,
      weightOf: (bytes) => bytes.lengthInBytes,
    );

Future<EncodedResourceSource> loadCachedComicImageSource({
  required ResourceCacheManager cache,
  required String sourceId,
  required String imageIdentity,
  required Future<Uint8List> Function() loader,
  String? comicId,
  String resourceRole = 'cover',
  String revision = '',
  bool awaitPersistence = true,
  bool forceRefresh = false,
  ResourceCacheRetention retention = ResourceCacheRetention.transient,
}) => cache.getOrLoadEncodedImage(
      key: _imageKey(
        sourceId: sourceId,
        comicId: comicId,
        imageIdentity: imageIdentity,
        resourceRole: resourceRole,
        revision: revision,
      ),
      awaitPersistence: awaitPersistence,
      forceRefresh: forceRefresh,
      retention: retention,
      loader: loader,
    );

/// Probes an artwork cache entry without invoking [loader].
///
/// Callers that can operate without a live source should use this before
/// resolving a plugin. This probes only the current stable key and never
/// invokes a source loader.
Future<EncodedResourceSource?> readCachedComicImageSource({
  required ResourceCacheManager cache,
  required String sourceId,
  required String imageIdentity,
  String? comicId,
  String resourceRole = 'cover',
  String revision = '',
  bool awaitPersistence = true,
  ResourceCacheRetention retention = ResourceCacheRetention.transient,
}) async {
  return cache.getEncodedImageIfPresent(
    _imageKey(
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: imageIdentity,
      resourceRole: resourceRole,
      revision: revision,
    ),
    awaitPersistence: awaitPersistence,
    retention: retention,
  );
}

void invalidateAllComicResources(
  ResourceCacheManager cache, {
  required String sourceId,
  required String comicId,
}) {
  cache.invalidateNamespace(
    ComicResourceCacheIdentity(
      sourceId: sourceId,
      comicId: comicId,
    ).namespace,
  );
}


void invalidateCachedComicMetadata(
  BrowsableComicSource source,
  String comicId,
) {
  if (source is CachedBrowsableComicSource) {
    source.invalidateComicMetadata(comicId);
  }
}

void invalidateCachedSearch(BrowsableComicSource source) {
  if (source is CachedBrowsableComicSource) {
    source.invalidateSearch();
  }
}

ResourceCacheKey _comicKey(ComicResourceCacheIdentity identity) =>
    ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: identity.response('details'),
      namespace: identity.namespace,
      // dev.160 corrects the Mihon 1.6 CatalogueSource host contract. Avoid
      // serving durable manifests produced by the previous shim, where chapter
      // discovery could collapse to an empty/invalid catalog. Other source
      // ecosystems keep their existing cache revision.
      revision: identity.sourceId.startsWith('mihon:')
          ? 'mihon-comic-details-v2-host-contract'
          : '',
    );

ResourceCacheKey _imageKey({
  required String sourceId,
  required String? comicId,
  required String imageIdentity,
  required String resourceRole,
  required String revision,
}) {
  if (comicId == null) {
    return ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: encodeStableCacheKey(
        'source-image',
        <String>[sourceId, imageIdentity, resourceRole],
      ),
      namespace: sourceResourceCacheNamespace(sourceId),
      revision: revision,
    );
  }
  final identity = ComicResourceCacheIdentity(
    sourceId: sourceId,
    comicId: comicId,
  );
  return ResourceCacheKey(
    kind: ResourceCacheKind.imageBytes,
    identity: identity.response(resourceRole),
    namespace: identity.namespace,
    revision: revision,
  );
}

String comicResourceCacheNamespace(String sourceId, String comicId) =>
    ComicResourceCacheIdentity(
      sourceId: sourceId,
      comicId: comicId,
    ).namespace;
