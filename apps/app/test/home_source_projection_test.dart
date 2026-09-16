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
    final initialExternal = _Source(sourceId: 'mihon:initial');
    final replacementExternal = _Source(sourceId: 'mihon:replacement');
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
    expect(projection.sourceForId('mihon:initial'), isNotNull);

    final candidate = projection.composeForServices(
      replacementCache,
      externalSources: <BrowsableComicSource>[replacementExternal],
    );
    expect(
      candidate.map((source) => source.sourceId),
      <String>['fixture:builtin', 'mihon:replacement'],
    );
    expect(projection.sourceForId('mihon:initial'), isNotNull);
    expect(projection.sourceForId('mihon:replacement'), isNull);

    projection.adoptServiceProjection(candidate, cache: replacementCache);

    expect(projection.sourceForId('mihon:initial'), isNull);
    expect(projection.sourceForId('mihon:replacement'), isNotNull);
  });

  test('external projection persists canonical ids before conditional reload',
      () async {
    final cache = ResourceCacheCoordinator();
    addTearDown(cache.close);
    final builtIn = _Source(sourceId: 'fixture:builtin');
    final external = _Source(
      sourceId: 'mihon:test',
      canonicalPrefix: 'canonical:',
    );
    var saved = <SavedComicRecord>[
      SavedComicRecord(
        sourceId: 'mihon:test',
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
      <String>['fixture:builtin', 'mihon:test'],
    ]);
    expect(readyCalls, 1);
    expect(upsertCalls, 1);
    expect(reloadCalls, 1);
    expect(presentationRefreshes, 1);
    expect(saved.single.canonicalComicId, 'canonical:raw-comic');
    expect(projection.sourceForId('mihon:test'), isNotNull);

    await projection.refreshExternalSources(<BrowsableComicSource>[external]);

    expect(readyCalls, 2);
    expect(upsertCalls, 1);
    expect(reloadCalls, 1);
    expect(presentationRefreshes, 2);
  });
}

final class _Source
    implements BrowsableComicSource, CanonicalComicIdentitySource {
  const _Source({required this.sourceId, this.canonicalPrefix = ''});

  @override
  final String sourceId;
  final String canonicalPrefix;

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
