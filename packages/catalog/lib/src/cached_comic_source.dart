import 'dart:collection';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';

import 'comic_source.dart';
import 'source_catalog.dart';

/// Catalog decorator for reusable source-response caching.
///
/// Search pages, comic details, chapter metadata and source artwork share one
/// [ResourceCacheManager]. [loadResource] deliberately remains a raw
/// pass-through because Reader page bytes must enter pipeline/session/artifact
/// ownership instead of being prefetched by the catalog response cache.
final class CachedBrowsableComicSource
    implements BrowsableComicSource, ConfigurableComicSource {
  CachedBrowsableComicSource({
    required this.source,
    required this.cache,
  });

  final BrowsableComicSource source;
  final ResourceCacheManager cache;
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
        identity: '$sourceId\u0000$normalizedQuery\u0000$offset\u0000$limit',
        namespace: _sourceNamespace(sourceId),
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
  Future<ComicManifest> loadComic(String comicId) =>
      cache
          .getOrLoad<ComicManifest>(
            key: _comicKey(sourceId, comicId),
            loader: () => source.loadComic(comicId),
            weightOf: _comicWeight,
          )
          .then((manifest) {
        _rememberComic(manifest);
        return manifest;
      });

  @override
  Future<ChapterManifest> loadChapter(String chapterId) {
    final comicId = _chapterComicIds[chapterId];
    return cache
        .getOrLoad<ChapterManifest>(
          key: ResourceCacheKey(
            kind: ResourceCacheKind.chapterMetadata,
            identity: '$sourceId\u0000$chapterId',
            namespace: comicId == null
                ? _sourceNamespace(sourceId)
                : comicResourceCacheNamespace(sourceId, comicId),
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

  /// Cached source artwork entry used by cover and comparison presentation.
  Future<Uint8List> loadImage(
    Uri uri, {
    String? comicId,
    String revision = '',
  }) =>
      loadCachedComicImage(
        cache: cache,
        sourceId: sourceId,
        comicId: comicId,
        imageIdentity: uri.toString(),
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
        comicId: comicId,
        imageIdentity: uri.toString(),
        revision: revision,
        loader: () => source.loadResource(uri),
      );

  void invalidateComic(String comicId) {
    final cached = cache.peek<ComicManifest>(_comicKey(sourceId, comicId));
    if (cached != null) {
      _rememberComic(cached);
    }
    final chapterIds = _chapterComicIds.entries
        .where((entry) => entry.value == comicId)
        .map((entry) => entry.key)
        .toList(growable: false);
    cache.invalidateNamespace(comicResourceCacheNamespace(sourceId, comicId));
    for (final chapterId in chapterIds) {
      cache.invalidateWhere(
        (key) =>
            key.kind == ResourceCacheKind.chapterMetadata &&
            key.identity == '$sourceId\u0000$chapterId',
      );
      _chapterComicIds.remove(chapterId);
    }
  }

  void invalidateSearch() => cache.invalidateWhere(
        (key) =>
            key.kind == ResourceCacheKind.searchResults &&
            key.namespace == _sourceNamespace(sourceId),
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

Future<Uint8List> loadCachedComicImage({
  required ResourceCacheManager cache,
  required String sourceId,
  required String imageIdentity,
  required Future<Uint8List> Function() loader,
  String? comicId,
  String revision = '',
}) =>
    cache.getOrLoad<Uint8List>(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.imageBytes,
        identity: '$sourceId\u0000$imageIdentity',
        namespace: comicId == null
            ? _sourceNamespace(sourceId)
            : comicResourceCacheNamespace(sourceId, comicId),
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
  String revision = '',
}) =>
    cache.getOrLoadEncodedImage(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.imageBytes,
        identity: '$sourceId\u0000$imageIdentity',
        namespace: comicId == null
            ? _sourceNamespace(sourceId)
            : comicResourceCacheNamespace(sourceId, comicId),
        revision: revision,
      ),
      loader: loader,
    );

void invalidateComicResourceCache(
  ResourceCacheManager cache, {
  required String sourceId,
  required String comicId,
}) =>
    cache.invalidateNamespace(
      comicResourceCacheNamespace(sourceId, comicId),
    );

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

int _browseWeight(SourceBrowsePage page) =>
    128 + page.items.fold<int>(0, (sum, item) => sum + _summaryWeight(item));

int _summaryWeight(SourceComicSummary item) =>
    96 +
    item.title.length * 2 +
    item.authors.fold<int>(0, (sum, author) => sum + author.length * 2) +
    (item.description?.length ?? 0) * 2 +
    (item.coverUri?.toString().length ?? 0) * 2;

int _comicWeight(ComicManifest manifest) =>
    256 +
    manifest.comic.title.length * 2 +
    manifest.comic.authors
        .fold<int>(0, (sum, author) => sum + author.length * 2) +
    (manifest.comic.description?.length ?? 0) * 2 +
    manifest.chapters.length * 160;

int _chapterWeight(ChapterManifest manifest) =>
    192 + manifest.pages.length * 192;

ResourceCacheKey _comicKey(String sourceId, String comicId) =>
    ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: '$sourceId\u0000$comicId',
      namespace: comicResourceCacheNamespace(sourceId, comicId),
    );

String _sourceNamespace(String sourceId) => 'source:$sourceId';

String comicResourceCacheNamespace(String sourceId, String comicId) =>
    'comic:$sourceId\u0000$comicId';

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
