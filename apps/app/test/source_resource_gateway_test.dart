import 'dart:async';
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
      <int>[0xff, 0xd8, 0xff, 0xd9],
    );
    expect(source.loads, 1);

    gateway.close();
    expect(downloads.access, isNull);
  });

  test('unbind tolerates a download service already closed by replacement',
      () async {
    final source = _Source();
    final downloads = _RecordingDownloads();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    addTearDown(gateway.close);

    gateway.bindTo(downloads);
    expect(downloads.access, isNotNull);
    await downloads.close();

    expect(() => gateway.unbindFrom(downloads), returnsNormally);
    expect(() => gateway.unbindFrom(downloads), returnsNormally,
        reason: 'local binding retirement must remain idempotent');
  });

  test('gateway forwards only proven source-open bounds to chapter access',
      () async {
    final locator = Uri.parse('venera-resource:bounded');
    final source = _ResolvedSource(
      resolvedUri: Uri.parse('https://example.invalid/bounded.webp'),
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      resourceOperationTimeout: const Duration(seconds: 55),
    );
    final downloads = _RecordingDownloads();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
      directTransport: _SelfBoundedDirectTransport(),
    );
    addTearDown(gateway.close);

    gateway.bindTo(downloads);
    final bound = downloads.access?.selfBoundsOpen;
    expect(bound, isNotNull);
    expect(bound!(source.sourceId, locator), isTrue);
    expect(
      bound(source.sourceId, Uri.parse('venera-resource://7')),
      isFalse,
    );
  });

  test('page open waits for deferred source only on origin fallback', () async {
    final locator = Uri.parse('venera:resource:deferred-page');
    final source = _ResolvedSource(
      resolvedUri: Uri.parse('https://example.invalid/deferred.webp'),
      bytes: Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
      resourceOperationTimeout: const Duration(seconds: 55),
    );
    final published = Completer<void>();
    _ResolvedSource? liveSource;
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) =>
          sourceId == source.sourceId ? liveSource : null,
      waitForSource: (_) => published.future,
      directTransport: _SelfBoundedDirectTransport(),
    );
    addTearDown(gateway.close);

    final loader = gateway.pageControlledResponseLoaderFor(
      source.sourceId,
      locator,
    );
    expect(gateway.pageOpenSelfBoundedFor(source.sourceId, locator), isFalse);

    final control = _OpenPhaseControl();
    final pending = loader(control: control);
    await Future<void>.delayed(Duration.zero);
    expect(control.reportedSelfBounded, isFalse);

    liveSource = source;
    published.complete();
    final response = await pending;
    expect(control.reportedSelfBounded, isTrue);
    await response.discard();
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

  test('artwork cache miss waits for deferred source publication', () async {
    final source = _ImageSource();
    final sourcePublished = Completer<void>();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
      waitForSource: (_) => sourcePublished.future,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);

    final pending = gateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: Uri.parse('mihon:resource:deferred-cover'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(source.loads, 0);

    sourcePublished.complete();
    final result = await pending;
    expect(result.lengthInBytes, 4);
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

  test('preview crops share one encoded cache entry', () async {
    final source = _ImageSource();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    final cache = ResourceCacheManager();
    addTearDown(gateway.close);
    addTearDown(cache.close);
    final firstUri = Uri.parse(
      'mihon:resource:preview-base@x=0-200&y=0-200',
    );
    final secondUri = Uri.parse(
      'mihon:resource:preview-base@x=200-400&y=200-400',
    );

    await gateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: firstUri,
      resourceRole: 'preview',
    );
    await gateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'comic',
      uri: secondUri,
      resourceRole: 'preview',
    );

    expect(source.loads, 1);
    expect(source.loadedUris, <Uri>[Uri.parse('mihon:resource:preview-base')]);
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

  test('canonical artwork identity survives mutable raw comic aliases', () async {
    final source = _ImageSource(canonicalPrefix: 'canonical:');
    final cache = ResourceCacheManager();
    final locator = Uri.parse('mihon:resource:canonical-cover');
    final firstGateway = ComicSourceResourceGateway(
      sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
    );
    addTearDown(firstGateway.close);
    addTearDown(cache.close);

    await firstGateway.loadArtworkSource(
      cache: cache,
      sourceId: source.sourceId,
      comicId: 'mutable-browse-snapshot',
      cacheComicId: 'canonical:comic',
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
      comicId: 'mutable-detail-snapshot',
      cacheComicId: 'canonical:comic',
      uri: locator,
    );

    expect(cached.origin, EncodedResourceOrigin.memory);
    expect(resolverCalls, 0);
    expect(source.loads, 1);
  });

  test('durable artwork identity bypasses source resolution', () async {
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
      comicId: 'mutable-browse-snapshot',
      cacheComicId: 'canonical:comic',
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
      comicId: 'mutable-detail-snapshot',
      cacheComicId: 'canonical:comic',
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

    final invalidRuntimeBody = isA<Failure>()
        .having((error) => error.code, 'code', ErrorCode.source)
        .having(
          (error) => error.details['runtimeBodyImageSignatureRejected'],
          'runtime signature rejection',
          isTrue,
        );
    await expectLater(
      gateway.loadArtworkSource(
        cache: cache,
        sourceId: source.sourceId,
        comicId: 'comic',
        uri: locator,
      ),
      throwsA(invalidRuntimeBody),
    );
    await expectLater(
      gateway.loadArtworkSource(
        cache: cache,
        sourceId: source.sourceId,
        comicId: 'comic',
        uri: locator,
      ),
      throwsA(invalidRuntimeBody),
    );
    expect(source.resolveCalls, 2);
    expect(source.loads, 2);
  });

  test('gateway rejects legacy Venera tokens before source dispatch', () async {
    final source = _Source();
    final gateway = ComicSourceResourceGateway(
      sourceForId: (_) => source,
    );
    addTearDown(gateway.close);

    expect(
      () => gateway.loadPageBytes(
        source.sourceId,
        Uri.parse('venera-resource://7'),
      ),
      throwsStateError,
    );
    expect(source.loads, 0);
  });

  test(
    'observed Reader page streaming feeds strong identity to version evidence',
    () async {
      final locator = Uri.parse('venera-resource:reader-page');
      final resolved = Uri.parse(
        'https://cdn.invalid/0123456789abcdef0123456789abcdef.webp',
      );
      final source = _ResolvedSource(
        resolvedUri: resolved,
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        requiresRuntimeTransform: false,
      );
      final gateway = ComicSourceResourceGateway(
        sourceForId: (sourceId) => sourceId == source.sourceId ? source : null,
        directTransport: _SelfBoundedDirectTransport(),
      );
      addTearDown(gateway.close);
      final page = PageAsset(
        pageId: 'page-0',
        chapterId: 'chapter',
        index: 0,
        uri: locator,
      );
      final manifest = ChapterManifest(
        sourceId: source.sourceId,
        comicId: 'comic',
        chapter: const Chapter(
          chapterId: 'chapter',
          comicId: 'comic',
          title: 'chapter',
          sequence: 0,
          pageCount: 1,
          sourceRevision: 'r1',
        ),
        pages: <PageAsset>[page],
        readingDirection: ReadingDirection.ltr,
      );
      ChapterManifest? observedManifest;
      PageAsset? observedPage;
      String? observedIdentity;
      gateway.setVerifiedPageReuseObserver((manifest, page, identity) {
        observedManifest = manifest;
        observedPage = page;
        observedIdentity = identity;
      });

      final loader = gateway.observedPageControlledResponseLoaderFor(
        manifest,
        page,
      );
      final response = await loader();

      expect(observedManifest, same(manifest));
      expect(observedPage, same(page));
      expect(observedIdentity, 'hash:0123456789abcdef0123456789abcdef');
      await response.discard();
    },
  );

  test('page loader creation does not require a published source', () async {
    final gateway = ComicSourceResourceGateway(
      sourceForId: (_) => null,
    );
    addTearDown(gateway.close);

    final loader = gateway.pageControlledResponseLoaderFor(
      'venera:missing',
      Uri.parse('venera-resource:page-1'),
    );
    await expectLater(loader(), throwsStateError);
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
    return Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);
  }
}

final class _RecordingDownloads
    implements ChapterDownloadService, ConfigurableChapterResourceAccess {

  @override
  Future<DownloadExistenceReport> probeExistingDownloads(
    DownloadExistenceQuery query,
  ) async =>
      const DownloadExistenceReport(
        liveRunIdentities: <String>[],
        liveRunStarted: false,
        indexedReadyPages: 0,
        urlMatchedPages: 0,
      );

  @override
  Future<ChapterFileStateReport> inspectChapterFileState(
    ImportedLibraryEntry entry,
  ) async =>
      const ChapterFileStateReport(
        manifestPages: 1,
        indexReadyPages: 0,
        diskPages: 0,
        diskBytes: 0,
      );

  @override
  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) async {}

  @override
  void updateVersionBaselines(List<ComicVersionRelation> relations) {}

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {}

  @override
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async =>
      null;

  ChapterResourceAccess? access;
  bool _closed = false;

  @override
  void setChapterResourceAccess(ChapterResourceAccess? value) {
    if (_closed) throw StateError('recording downloads is closed');
    access = value;
  }

  @override
  Stream<ChapterDownloadSnapshot> get changes => const Stream.empty();

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {}

  @override
  Future<void> close() async {
    _closed = true;
  }

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
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async =>
      const <ImportedLibraryEntry>[];

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async => false;

  @override
  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry) async => const <int>{};

  @override
  Future<bool> hasReadyPage(ImportedLibraryEntry entry, int pageIndex) async => false;

  @override
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async =>
      ComicConflictReport(
        candidates: const <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName: comicTitle,
      );

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) =>
      throw UnimplementedError();

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {}
}

final class _ResolvedSource
    implements
        BrowsableComicSource,
        ResolvableComicResourceSource,
        BoundedComicResourceSource {
  _ResolvedSource({
    required this.resolvedUri,
    required this.bytes,
    this.resourceOperationTimeout,
    this.requiresRuntimeTransform = true,
  });

  final Uri resolvedUri;
  final Uint8List bytes;
  final bool requiresRuntimeTransform;
  @override
  final Duration? resourceOperationTimeout;
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
      requiresRuntimeTransform: requiresRuntimeTransform,
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
  final List<Uri> loadedUris = <Uri>[];

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
    loadedUris.add(uri);
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

final class _OpenPhaseControl implements OpenPhaseReportingTaskControl {
  final Completer<void> _cancelled = Completer<void>();
  bool reportedSelfBounded = false;

  @override
  bool get cancelled => false;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  int get priority => 1000;

  @override
  void markOpenSelfBounded() {
    reportedSelfBounded = true;
  }
}

final class _SelfBoundedDirectTransport
    implements SelfBoundedSourceResourceDirectTransport {
  @override
  Future<ByteResponse> open(
    ComicResourceRequest request, {
    TaskControl? control,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: 3,
      );

  @override
  void close() {}
}
