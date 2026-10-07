import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/home_source_projection.dart';

void main() {
  test('source projection owns cache wrapping and service adoption', () async {
    final cache = ResourceCacheCoordinator();
    final replacementCache = ResourceCacheCoordinator();
    addTearDown(cache.close);
    addTearDown(replacementCache.close);
    final builtIn = _Source(sourceId: 'fixture:builtin');
    final initialExternal = _Source(sourceId: 'plugin:initial');
    final replacementExternal = _Source(sourceId: 'plugin:replacement');
    final projection = HomeSourceProjection(
      suppliedSources: null,
      defaultSources: () => <BrowsableComicSource>[builtIn],
      cache: cache,
      externalSources: <BrowsableComicSource>[initialExternal],
      publishSources: (_) async {},
      ensureLibraryReady: () async {},
      savedComics: () => const <SavedComicRecord>[],
      upsertSavedComic: (_) async {},
      reloadLibrary: () async {},
      requestPresentationRefresh: () {},
    );

    expect(
      projection.sources,
      everyElement(isA<CachedBrowsableComicSource>()),
    );
    expect(projection.sourceForId('fixture:builtin'), isNotNull);
    expect(projection.sourceForId('plugin:initial'), isNotNull);
    expect(projection.externalSourceIds, <String>{'plugin:initial'});

    final candidate = projection.composeForServices(
      replacementCache,
      externalSources: <BrowsableComicSource>[replacementExternal],
    );
    expect(
      candidate.map((source) => source.sourceId),
      <String>['fixture:builtin', 'plugin:replacement'],
    );
    expect(projection.sourceForId('plugin:initial'), isNotNull);
    expect(projection.sourceForId('plugin:replacement'), isNull);

    projection.adoptServiceProjection(
      candidate,
      cache: replacementCache,
      externalSources: <BrowsableComicSource>[replacementExternal],
    );

    expect(projection.sourceForId('plugin:initial'), isNull);
    expect(projection.sourceForId('plugin:replacement'), isNotNull);
    expect(projection.externalSourceIds, <String>{'plugin:replacement'});
  });

  test('external decoration reuse preserves source and cache generation boundaries',
      () async {
    final cache = ResourceCacheCoordinator();
    final replacementCache = ResourceCacheCoordinator();
    addTearDown(cache.close);
    addTearDown(replacementCache.close);
    var producerGeneration = Object();
    final active = _Source(
      sourceId: 'plugin:active',
      readTransportGeneration: () => producerGeneration,
    );
    final other = _Source(sourceId: 'plugin:other');
    final projection = HomeSourceProjection(
      suppliedSources: null,
      defaultSources: () => const <BrowsableComicSource>[],
      cache: cache,
      externalSources: <BrowsableComicSource>[active],
      publishSources: (_) async {},
      ensureLibraryReady: () async {},
      savedComics: () => const <SavedComicRecord>[],
      upsertSavedComic: (_) async {},
      reloadLibrary: () async {},
      requestPresentationRefresh: () {},
    );
    final original = projection.sourceForId(active.sourceId);
    await projection.refreshExternalSources(<BrowsableComicSource>[active, other]);
    expect(projection.sourceForId(active.sourceId), same(original));
    await projection.refreshExternalSources(<BrowsableComicSource>[active]);
    expect(projection.sourceForId(active.sourceId), same(original));

    producerGeneration = Object();
    expect(
      (original as ComicResourceTransportGenerationSource)
          .resourceTransportGenerationIdentity,
      same(producerGeneration),
    );
    await projection.refreshExternalSources(<BrowsableComicSource>[active]);
    final mutated = projection.sourceForId(active.sourceId);
    expect(mutated, isNot(same(original)));
    await projection.refreshExternalSources(<BrowsableComicSource>[active, other]);
    expect(projection.sourceForId(active.sourceId), same(mutated));

    final replacement = _Source(sourceId: active.sourceId);
    await projection.refreshExternalSources(<BrowsableComicSource>[replacement]);
    final replaced = projection.sourceForId(active.sourceId);
    expect(replaced, isNot(same(mutated)));
    final candidate = projection.composeForServices(
      replacementCache,
      externalSources: <BrowsableComicSource>[replacement],
    );
    expect(candidate.single, isNot(same(replaced)));
    expect(
      (candidate.single as CachedBrowsableComicSource).cache,
      same(replacementCache.responses),
    );
    projection.adoptServiceProjection(
      candidate,
      cache: replacementCache,
      externalSources: <BrowsableComicSource>[replacement],
    );
    await projection.refreshExternalSources(<BrowsableComicSource>[replacement]);
    expect(projection.sourceForId(active.sourceId), same(candidate.single));
  });

  test('external projection persists canonical ids before conditional reload',
      () async {
    final cache = ResourceCacheCoordinator();
    addTearDown(cache.close);
    final builtIn = _Source(sourceId: 'fixture:builtin');
    final external = _Source(
      sourceId: 'plugin:test',
      canonicalPrefix: 'canonical:',
    );
    var saved = <SavedComicRecord>[
      SavedComicRecord(
        sourceId: 'plugin:test',
        comicId: 'raw-comic',
        title: 'Fixture comic',
        chapters: const <SavedChapterRecord>[],
      ),
    ];
    final published = <List<String>>[];
    var readyCalls = 0;
    var upsertCalls = 0;
    var reloadCalls = 0;
    var presentationRefreshes = 0;
    final projection = HomeSourceProjection(
      suppliedSources: null,
      defaultSources: () => <BrowsableComicSource>[builtIn],
      cache: cache,
      publishSources: (sources) async {
        published.add(
          sources.map((source) => source.sourceId).toList(growable: false),
        );
      },
      ensureLibraryReady: () async {
        readyCalls++;
      },
      savedComics: () => saved,
      upsertSavedComic: (comic) async {
        upsertCalls++;
        saved = <SavedComicRecord>[comic];
      },
      reloadLibrary: () async {
        reloadCalls++;
      },
      requestPresentationRefresh: () {
        presentationRefreshes++;
      },
    );

    await projection.refreshExternalSources(<BrowsableComicSource>[external]);

    expect(published, <List<String>>[
      <String>['fixture:builtin', 'plugin:test'],
    ]);
    expect(readyCalls, 1);
    expect(upsertCalls, 1);
    expect(reloadCalls, 1);
    expect(presentationRefreshes, 1);
    expect(saved.single.canonicalComicId, 'canonical:raw-comic');
    expect(projection.sourceForId('plugin:test'), isNotNull);

    await projection.refreshExternalSources(<BrowsableComicSource>[external]);

    expect(readyCalls, 2);
    expect(upsertCalls, 1);
    expect(reloadCalls, 1);
    expect(presentationRefreshes, 2);
    expect(
      projection.sources
          .where((source) => source.sourceId == 'plugin:test')
          .length,
      1,
    );
  });
}

final class _Source
    implements
        BrowsableComicSource,
        CanonicalComicIdentitySource,
        ComicResourceTransportGenerationSource {
  const _Source({
    required this.sourceId,
    this.canonicalPrefix = '',
    this.readTransportGeneration,
  });

  @override
  final String sourceId;
  final String canonicalPrefix;
  final Object Function()? readTransportGeneration;

  @override
  Object get resourceTransportGenerationIdentity =>
      readTransportGeneration?.call() ?? this;

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: sourceId,
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  String canonicalComicIdentity(String comicId) =>
      canonicalPrefix.isEmpty ? comicId : '$canonicalPrefix$comicId';

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      throw UnimplementedError();

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> loadResource(Uri uri) => throw UnimplementedError();
}
