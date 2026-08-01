import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
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

  test('artwork cache uses the shared request-plan transport', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests += 1;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 4
        ..add(<int>[0xff, 0xd8, 0xff, 0xd9]);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final source = _ResolvedSource(
      Uri.parse('http://${server.address.host}:${server.port}/cover.webp'),
    );
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);

    final locator = Uri.https('catalog.invalid', '/cover.webp');
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
    expect(source.loads, 0);
    expect(requests, 1);
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

  test('invalid artwork responses are not persisted as cover cache hits',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests += 1;
      request.response
        ..statusCode = HttpStatus.ok
        ..add(<int>[0x3c, 0x68, 0x74, 0x6d, 0x6c, 0x3e]);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final source = _ResolvedSource(
      Uri.parse('http://${server.address.host}:${server.port}/cover.jpg'),
    );
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);
    final locator = Uri.https('catalog.invalid', '/invalid-cover.jpg');

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
    expect(requests, 2);
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
  _ResolvedSource(this.resolvedUri);

  final Uri resolvedUri;
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
    return ComicResourceRequest(uri: resolvedUri);
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loads += 1;
    return Uint8List(0);
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

final class _ImageSource implements BrowsableComicSource {
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
