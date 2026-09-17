import 'package:catalog/catalog.dart';
import 'package:resource_cache/resource_cache.dart';

typedef HomeSourceProjectionPublisher = Future<void> Function(
  List<BrowsableComicSource> sources,
);
typedef HomeSourceSavedComicsProvider = List<SavedComicRecord> Function();
typedef HomeSourceSavedComicUpsert = Future<void> Function(
  SavedComicRecord comic,
);

/// Composition-owned source projection for Home, details and Reader lookup.
///
/// External plugin lifecycle is owned separately by the Home external-source
/// lifecycle owner.
/// This owner keeps the resolver-visible source list, applies the shared
/// response-cache decorator, publishes source changes to HomeLibrarySession and
/// persists source-confirmed canonical comic ids before requesting any library
/// reload. It has no Widget/navigation ownership.
final class HomeSourceProjection {
  factory HomeSourceProjection({
    required List<BrowsableComicSource>? suppliedSources,
    required List<BrowsableComicSource> Function() defaultSources,
    required ResourceCacheCoordinator cache,
    Iterable<BrowsableComicSource> externalSources =
        const <BrowsableComicSource>[],
    required HomeSourceProjectionPublisher publishSources,
    required Future<void> Function() ensureLibraryReady,
    required HomeSourceSavedComicsProvider savedComics,
    required HomeSourceSavedComicUpsert upsertSavedComic,
    required Future<void> Function() reloadLibrary,
    required void Function() requestPresentationRefresh,
  }) {
    final initialExternalSources = externalSources.toList(growable: false);
    final projection = HomeSourceProjection._(
      suppliedSources,
      defaultSources,
      cache,
      publishSources,
      ensureLibraryReady,
      savedComics,
      upsertSavedComic,
      reloadLibrary,
      requestPresentationRefresh,
    );
    projection._sources = projection._compose(
      cache,
      externalSources: initialExternalSources,
    );
    projection._externalSourceIds = initialExternalSources
        .map((source) => source.sourceId)
        .toSet();
    return projection;
  }

  HomeSourceProjection._(
    this._suppliedSources,
    this._defaultSources,
    this._cache,
    this._publishSources,
    this._ensureLibraryReady,
    this._savedComics,
    this._upsertSavedComic,
    this._reloadLibrary,
    this._requestPresentationRefresh,
  );

  final List<BrowsableComicSource>? _suppliedSources;
  final List<BrowsableComicSource> Function() _defaultSources;
  ResourceCacheCoordinator _cache;
  final HomeSourceProjectionPublisher _publishSources;
  final Future<void> Function() _ensureLibraryReady;
  final HomeSourceSavedComicsProvider _savedComics;
  final HomeSourceSavedComicUpsert _upsertSavedComic;
  final Future<void> Function() _reloadLibrary;
  final void Function() _requestPresentationRefresh;
  late List<BrowsableComicSource> _sources;
  Set<String> _externalSourceIds = <String>{};

  List<BrowsableComicSource> get sources => _sources;

  BrowsableComicSource? sourceForId(String sourceId) {
    for (final source in _sources) {
      if (source.sourceId == sourceId) return source;
    }
    return null;
  }

  List<BrowsableComicSource> composeForServices(
    ResourceCacheCoordinator cache, {
    Iterable<BrowsableComicSource> externalSources =
        const <BrowsableComicSource>[],
  }) =>
      _compose(cache, externalSources: externalSources);

  void adoptServiceProjection(
    List<BrowsableComicSource> sources, {
    required ResourceCacheCoordinator cache,
    required Iterable<BrowsableComicSource> externalSources,
  }) {
    _cache = cache;
    _sources = List<BrowsableComicSource>.unmodifiable(sources);
    _externalSourceIds = externalSources
        .map((source) => source.sourceId)
        .toSet();
  }

  Future<void> refreshExternalSources(
    Iterable<BrowsableComicSource> externalSources,
  ) async {
    final external = externalSources.toList(growable: false);
    final nextExternalSourceIds = external
        .map((source) => source.sourceId)
        .toSet();
    final replacedSourceIds = <String>{
      ..._externalSourceIds,
      ...nextExternalSourceIds,
    };
    final builtIn = _sources
        .where((source) => !replacedSourceIds.contains(source.sourceId))
        .toList(growable: true);
    _sources = _wrapSources(
      <BrowsableComicSource>[...builtIn, ...external],
      _cache,
    );
    _externalSourceIds = nextExternalSourceIds;
    await _publishSources(_sources);
    final canonicalIdsPersisted = await _persistKnownCanonicalComicIds();
    if (canonicalIdsPersisted) {
      await _reloadLibrary();
    }
    _requestPresentationRefresh();
  }

  List<BrowsableComicSource> _compose(
    ResourceCacheCoordinator cache, {
    Iterable<BrowsableComicSource> externalSources =
        const <BrowsableComicSource>[],
  }) {
    final rawSources = _suppliedSources ??
        <BrowsableComicSource>[
          ..._defaultSources(),
          ...externalSources,
        ];
    return _wrapSources(rawSources, cache);
  }

  List<BrowsableComicSource> _wrapSources(
    Iterable<BrowsableComicSource> sources,
    ResourceCacheCoordinator cache,
  ) =>
      List<BrowsableComicSource>.unmodifiable(
        sources.map(
          (source) => source is CachedBrowsableComicSource
              ? source
              : CachedBrowsableComicSource(
                  source: source,
                  cache: cache.responses,
                ),
        ),
      );

  String? _sourceCanonicalComicId(String sourceId, String comicId) {
    final source = sourceForId(sourceId);
    if (source is! CanonicalComicIdentitySource) return null;
    return (source as CanonicalComicIdentitySource)
        .canonicalComicIdentity(comicId);
  }

  Future<bool> _persistKnownCanonicalComicIds() async {
    await _ensureLibraryReady();
    var changed = false;
    for (final saved in _savedComics()) {
      final sourceCanonical = _sourceCanonicalComicId(
        saved.sourceId,
        saved.comicId,
      );
      if (sourceCanonical == null) continue;
      final canonical =
          sourceCanonical == saved.comicId ? null : sourceCanonical;
      if (canonical == saved.canonicalComicId) continue;
      await _upsertSavedComic(
        saved.copyWith(
          canonicalComicId: canonical,
          clearCanonicalComicId: canonical == null,
        ),
      );
      changed = true;
    }
    return changed;
  }
}
