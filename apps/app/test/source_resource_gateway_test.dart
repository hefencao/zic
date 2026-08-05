import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:zic/source_resource_gateway.dart';

void main() {
  test('gateway binds source access atomically and unbinds on close', () async {
    final source = _Source();
    final downloads = _RecordingDownloads();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );

    gateway.bindTo(downloads);
    final access = downloads.access;
    expect(access, isNotNull);
    expect(
      await access!.loadBytes!(
        source.sourceId,
        Uri.parse('venera-resource:durable'),
      ),
      <int>[1, 2, 3],
    );
    expect(source.loads, 1);

    gateway.close();
    expect(downloads.access, isNull);
  });

  test('artwork cache coalesces one source request-plan resolution', () async {
    final locator = Uri.parse('mihon:resource:cover');
    final source = _ResolvedSource(
      resolvedUri: locator,
      bytes: Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
    );
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);

    final first = await gateway.loadArtworkBytes(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: locator,
    );
    final second = await gateway.loadArtworkBytes(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: locator,
    );

    expect(first, <int>[0xff, 0xd8, 0xff, 0xd9]);
    expect(second, first);
    expect(source.resolveCalls, 1);
    expect(source.loads, 1);
  });

  test('custom source artwork locator coalesces one runtime fallback',
      () async {
    final source = _ImageSource();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);
    final locator = Uri.parse('mihon:resource:opaque-cover');

    final results = await Future.wait<EncodedResourceSource>(
      <Future<EncodedResourceSource>>[
        gateway.loadArtworkSource(
          cache: cache,
          sourceId: source.sourceId,
          comicId: 'comic',
          uri: locator,
        ),
        gateway.loadArtworkSource(
          cache: cache,
          sourceId: source.sourceId,
          comicId: 'comic',
          uri: locator,
        ),
      ],
    );

    expect(source.loads, 1);
    expect(results, hasLength(2));
    expect(results.every((value) => value.lengthInBytes == 4), isTrue);
  });

  test('warm artwork cache does not resolve the source', () async {
    final source = _ImageSource();
    final cache = ResourceCacheManager();
    final firstGateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    addTearDown(firstGateway.close);
    addTearDown(cache.close);
    final locator = Uri.parse('mihon:resource:warm-cover');

    await firstGateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: locator,
    );

    var resolverCalls = 0;
    final secondGateway = ComicSourceResourceGateway(
      sourceForId: (_) {
        resolverCalls++;
        return null;
      },
    );
    addTearDown(secondGateway.close);

    final cached = await secondGateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: locator,
    );

    expect(cached.origin, EncodedResourceOrigin.memory);
    expect(resolverCalls, 0);
    expect(source.loads, 1);
  });

  test('obsolete artwork cache keys are not consulted', () async {
    final source = _ImageSource(canonicalPrefix: 'canonical:');
    final cache = ResourceCacheManager();
    final oldUrlKey = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: '${source.sourceId}\u0000mihon:resource:canonical-cover',
      namespace: 'comic:${source.sourceId}\u0000comic',
      revision: 'artwork-v2',
    );
    await cache.getOrLoadEncodedImage(
      key: oldUrlKey,
      loader: () async => Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
    );
    final oldCanonicalKey = ComicResourceCacheIdentity(
      sourceId: source.sourceId,
      comicId: 'canonical:comic',
    );
    await cache.getOrLoadEncodedImage(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.imageBytes,
        identity: oldCanonicalKey.response('cover'),
        namespace: oldCanonicalKey.namespace,
        revision: 'artwork-v2',
      ),
      loader: () async => Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
    );
    addTearDown(cache.close);

    var resolverCalls = 0;
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) {
        resolverCalls++;
        return sourceId == source.sourceId ? source : null;
      },
    );
    addTearDown(gateway.close);

    final loaded = await gateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: Uri.parse('mihon:resource:canonical-cover'),
    );

    expect(loaded.origin, EncodedResourceOrigin.memory);
    expect(resolverCalls, 1);
    expect(source.loads, 1);
  });

  test('durable raw artwork hit bypasses source resolution', () async {
    final root = await Directory.systemTemp.createTemp('zic-cover-cache-');
    addTearDown(() => root.delete(recursive: true));
    final source = _ImageSource();
    final firstCache = createAppResourceCache(storageRoot: root.path);
    final firstGateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );

    await firstGateway.loadArtworkSource(
      cache: firstCache.responses,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: Uri.parse('mihon:resource:durable-cover'),
    );
    firstGateway.close();
    await firstCache.close();

    final reopenedCache = createAppResourceCache(storageRoot: root.path);
    addTearDown(reopenedCache.close);
    var resolverCalls = 0;
    final reopenedGateway = ComicSourceResourceGateway(
      sourceForId: (_) {
        resolverCalls++;
        return null;
      },
    );
    addTearDown(reopenedGateway.close);

    final cached = await reopenedGateway.loadArtworkSource(
      cache: reopenedCache.responses,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: Uri.parse('mihon:resource:durable-cover'),
    );

    expect(cached.origin, EncodedResourceOrigin.durableCacheFile);
    expect(resolverCalls, 0);
    expect(source.loads, 1);
  });

  test('invalid artwork responses are not persisted as cover cache hits',
      () async {
    final locator = Uri.parse('mihon:resource:invalid-cover');
    final source = _ResolvedSource(
      resolvedUri: locator,
      bytes: Uint8List.fromList(<int>[0x3c, 0x68, 0x74, 0x6d, 0x6c, 0x3e]),
    );
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);

    await expectLater(
      gateway.loadArtworkSource(
        cache: cache,
        sourceId: source.sourceId,
        comicId: 'comic',
        uri: locator,
      ),
      throwsFormatException,
    );
    await expectLater(
      gateway.loadArtworkSource(
        cache: cache,
        sourceId: source.sourceId,
        comicId: 'comic',
        uri: locator,
      ),
      throwsFormatException,
    );
    expect(source.resolveCalls, 1);
    expect(source.loads, 2);
  });

  test('gateway rejects legacy Venera tokens before source dispatch', () async {
    final source = _Source();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (_) => source,
    );
    addTearDown(gateway.close);

    expect(
      () => gateway.loadBytes(
        source.sourceId,
        Uri.parse('venera-resource://7'),
      ),
      throwsStateError,
    );
    expect(source.loads, 0);
  });
}

final class _Source implements BrowsableComicSource {
  int loads = 0;

  @override
  String get sourceId => 'venera:test';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Venera fixture',
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

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
  Future<Uint8List> loadResource(Uri uri) async {
    loads += 1;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }
}

final class _RecordingDownloads
    implements ChapterDownloadService, ConfigurableChapterResourceAccess {
  ChapterResourceAccess? access;

  @override
  void setChapterResourceAccess(ChapterResourceAccess? value) {
    access = value;
  }

  @override
  Stream<ChapterDownloadSnapshot> get changes => const Stream.empty();

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {}

  @override
  Future<void> download(ImportedLibraryEntry entry) async {}

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) =>
      throw UnimplementedError();

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async =>
      const <ChapterDownloadSnapshot>[];

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async => false;

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) =>
      throw UnimplementedError();

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {}
}

final class _ResolvedSource
    implements BrowsableComicSource, ResolvableComicResourceSource {
  _ResolvedSource({required this.resolvedUri, required this.bytes});

  final Uri resolvedUri;
  final Uint8List bytes;
  int resolveCalls = 0;
  int loads = 0;

  @override
  String get sourceId => 'venera:resolved';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Resolved fixture',
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  Future<ComicResourceRequest> resolveResource(Uri uri) async {
    resolveCalls += 1;
    return ComicResourceRequest(
      uri: resolvedUri,
      requiresRuntimeTransform: true,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loads += 1;
    return Uint8List.fromList(bytes);
  }

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
}

final class _ImageSource
    implements BrowsableComicSource, CanonicalComicIdentitySource {
  _ImageSource({this.canonicalPrefix = ''});

  final String canonicalPrefix;
  int loads = 0;

  @override
  String get sourceId => 'mihon:test';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Mihon image fixture',
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  String canonicalComicIdentity(String comicId) =>
      canonicalPrefix.isEmpty ? comicId : '$canonicalPrefix$comicId';

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loads += 1;
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
  }

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
}
