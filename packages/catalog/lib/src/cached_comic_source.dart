import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';

import 'cache_identity.dart';
import 'comic_source.dart';
import 'source_catalog.dart';

/// Catalog decorator for reusable source-response caching.
///
/// Search pages, comic details, chapter metadata and source artwork share one
/// [ResourceCacheManager]. [loadResource] deliberately remains a raw
/// pass-through because Reader page bytes must enter pipeline/session/artifact
/// ownership instead of being prefetched by the catalog response cache.
final class CachedBrowsableComicSource
    implements
        BrowsableComicSource,
        ConfigurableComicSource,
        AuthenticatableComicSource,
        ComicWebUriSource,
        CanonicalComicIdentitySource,
        ComicWebViewRequestSource,
        RefreshableChapterComicSource,
        ResolvableComicResourceSource,
        RetryableComicResourceSource {
  CachedBrowsableComicSource({
    required this.source,
    required this.cache,
  });

  final BrowsableComicSource source;
  final ResourceCacheManager cache;
  static const String _chapterMetadataSchemaRevision =
      'chapter-metadata-v2-durable-plugin-locators';
  static const int _maxChapterIdentityIndex = 512;
  final LinkedHashMap<String, String> _chapterComicIds =
      LinkedHashMap<String, String>();

  @override
  String get sourceId => source.sourceId;

  @override
  ComicSourceDescriptor get descriptor => source.descriptor;

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) {
    final normalizedQuery = query.trim();
    return cache.getOrLoad<SourceBrowsePage>(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.searchResults,
        identity: encodeStableCacheKey(
          'search-results',
          <String>[sourceId, normalizedQuery, '$offset', '$limit'],
        ),
        namespace: sourceResourceCacheNamespace(sourceId),
      ),
      loader: () => source.browse(
        query: normalizedQuery,
        offset: offset,
        limit: limit,
      ),
      weightOf: _browseWeight,
    );
  }

  @override
  Uri resolveComicWebUri(String comicId) {
    final Object candidate = source;
    final ComicWebUriSource? webSource =
        candidate is ComicWebUriSource ? candidate : null;
    return webSource?.resolveComicWebUri(comicId) ?? descriptor.website;
  }

  @override
  String canonicalComicIdentity(String comicId) {
    final Object candidate = source;
    final CanonicalComicIdentitySource? identitySource =
        candidate is CanonicalComicIdentitySource ? candidate : null;
    return identitySource?.canonicalComicIdentity(comicId) ?? comicId;
  }

  @override
  ComicWebViewRequest webViewRequest(Uri url) {
    final Object candidate = source;
    final ComicWebViewRequestSource? requestSource =
        candidate is ComicWebViewRequestSource ? candidate : null;
    return requestSource?.webViewRequest(url) ?? ComicWebViewRequest(url: url);
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
  Future<ComicResourceRequest> resolveResource(Uri uri) {
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
  Future<ComicResourceRequest?> retryResource(Uri uri) {
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

  /// Cached source artwork entry used by cover and comparison presentation.
  Future<Uint8List> loadImage(
    Uri uri, {
    String? comicId,
    String revision = '',
  }) =>
      loadCachedComicImage(
        cache: cache,
        sourceId: sourceId,
        comicId: comicId == null ? null : _comicIdentity(comicId).comicId,
        legacyComicId: comicId,
        imageIdentity: uri.toString(),
        resourceRole: 'cover',
        revision: revision,
        loader: () => source.loadResource(uri),
      );

  /// File-backed artwork path when the durable response store supports it.
  ///
  /// The first network load may still arrive as bytes, but subsequent process
  /// starts can hand the immutable cache file directly to the image decoder.
  Future<EncodedResourceSource> loadImageSource(
    Uri uri, {
    String? comicId,
    String revision = '',
  }) =>
      loadCachedComicImageSource(
        cache: cache,
        sourceId: sourceId,
        comicId: comicId == null ? null : _comicIdentity(comicId).comicId,
        legacyComicId: comicId,
        imageIdentity: uri.toString(),
        resourceRole: 'cover',
        revision: revision,
        loader: () => source.loadResource(uri),
      );

  void invalidateComic(String comicId) {
    final identity = _comicIdentity(comicId);
    final cached = cache.peek<ComicManifest>(_comicKey(identity));
    if (cached != null) {
      _rememberComic(cached);
    }
    final chapterIds = _chapterComicIds.entries
        .where((entry) => entry.value == comicId)
        .map((entry) => entry.key)
        .toList(growable: false);
    cache.invalidateNamespace(identity.namespace);
    cache.invalidateNamespace(
      _legacyComicResourceCacheNamespace(sourceId, comicId),
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

int _browseWeight(SourceBrowsePage page) =>
    _cacheObjectOverhead +
    _cacheCollectionWeight<SourceComicSummary>(
      page.items,
      _sourceComicSummaryWeight,
    );

int _comicWeight(ComicManifest manifest) =>
    _cacheObjectOverhead +
    _comicValueWeight(manifest.comic) +
    _cacheCollectionWeight<Chapter>(manifest.chapters, _chapterValueWeight);

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
    _textWeight(comic.description);

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
  String? legacyComicId,
  String resourceRole = 'cover',
  String revision = '',
}) {
  final key = _imageKey(
    sourceId: sourceId,
    comicId: comicId,
    imageIdentity: imageIdentity,
    resourceRole: resourceRole,
    revision: revision,
  );
  final legacy = _legacyImageKey(
    sourceId: sourceId,
    comicId: legacyComicId ?? comicId,
    imageIdentity: imageIdentity,
    revision: revision,
  );
  return cache.getOrLoad<Uint8List>(
    key: key,
    loader: key == legacy
        ? loader
        : () async => await cache.readBytesIfPresent(legacy) ?? await loader(),
    weightOf: (bytes) => bytes.lengthInBytes,
  );
}

Future<EncodedResourceSource> loadCachedComicImageSource({
  required ResourceCacheManager cache,
  required String sourceId,
  required String imageIdentity,
  required Future<Uint8List> Function() loader,
  String? comicId,
  String? legacyComicId,
  String resourceRole = 'cover',
  String revision = '',
}) {
  final key = _imageKey(
    sourceId: sourceId,
    comicId: comicId,
    imageIdentity: imageIdentity,
    resourceRole: resourceRole,
    revision: revision,
  );
  final legacy = _legacyImageKey(
    sourceId: sourceId,
    comicId: legacyComicId ?? comicId,
    imageIdentity: imageIdentity,
    revision: revision,
  );
  return cache.getOrLoadEncodedImage(
    key: key,
    loader: key == legacy
        ? loader
        : () async => await cache.readBytesIfPresent(legacy) ?? await loader(),
  );
}

void invalidateComicResourceCache(
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
  cache.invalidateNamespace(
    _legacyComicResourceCacheNamespace(sourceId, comicId),
  );
}

Future<Uint8List> loadCachedSourceImage(
  BrowsableComicSource source,
  Uri uri, {
  String? comicId,
  String revision = '',
}) {
  if (source is CachedBrowsableComicSource) {
    return source.loadImage(
      uri,
      comicId: comicId,
      revision: revision,
    );
  }
  return source.loadResource(uri);
}

Future<EncodedResourceSource> loadCachedSourceImageSource(
  BrowsableComicSource source,
  Uri uri, {
  String? comicId,
  String revision = '',
}) {
  if (source is CachedBrowsableComicSource) {
    return source.loadImageSource(
      uri,
      comicId: comicId,
      revision: revision,
    );
  }
  return source
      .loadResource(uri)
      .then<EncodedResourceSource>(MemoryEncodedResourceSource.new);
}

void invalidateCachedComic(
  BrowsableComicSource source,
  String comicId,
) {
  if (source is CachedBrowsableComicSource) {
    source.invalidateComic(comicId);
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
    );

ResourceCacheKey _imageKey({
  required String sourceId,
  required String? comicId,
  required String imageIdentity,
  required String resourceRole,
  required String revision,
}) {
  if (comicId == null) {
    return _legacyImageKey(
      sourceId: sourceId,
      comicId: null,
      imageIdentity: imageIdentity,
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

ResourceCacheKey _legacyImageKey({
  required String sourceId,
  required String? comicId,
  required String imageIdentity,
  required String revision,
}) =>
    ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: '$sourceId\u0000$imageIdentity',
      namespace: comicId == null
          ? 'source:$sourceId'
          : _legacyComicResourceCacheNamespace(sourceId, comicId),
      revision: revision,
    );

String comicResourceCacheNamespace(String sourceId, String comicId) =>
    ComicResourceCacheIdentity(
      sourceId: sourceId,
      comicId: comicId,
    ).namespace;

String _legacyComicResourceCacheNamespace(String sourceId, String comicId) =>
    'comic:$sourceId\u0000$comicId';
