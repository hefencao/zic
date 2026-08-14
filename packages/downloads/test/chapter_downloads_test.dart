import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('chapter resource access rejects an empty binding', () {
    expect(ChapterResourceAccess.new, throwsArgumentError);
  });

  test('chapter command contract does not own the cache capability', () async {
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(0),
    );
    final ManagedChapterDownloadService command = service;
    addTearDown(command.close);

    final coordinator = ResourceCacheCoordinator(artifacts: service);
    addTearDown(coordinator.close);
    final usage = await coordinator.inspect();

    expect(command, isA<ChapterDownloadService>());
    expect(usage.artifacts, isNotNull);
    expect(usage.artifacts!.entries, 0);
  });

  test('memory chapter download owns bytes before reporting completion',
      () async {
    final bytes = Uint8List.fromList(<int>[7, 8, 9]);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:memory-comic',
        displayName: '第 1 话',
        sourceId: 'memory-source',
        comicId: 'memory-comic',
        comicTitle: '内存下载测试',
        chapterId: 'memory-chapter',
        sourceRevision: 'memory-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://page-1',
            pageId: 'memory-page-1',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => bytes,
    );
    addTearDown(service.close);

    expect(await service.isDownloaded(entry), isFalse);
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);
    expect(await service.readPage(entry, 0), bytes);
  });

  test('memory artifact store retains exact promoted reader pages', () async {
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(0),
    );
    addTearDown(service.close);
    final id = _readerArtifactId('memory-cache-page');
    final bytes = Uint8List.fromList(<int>[4, 5, 6]);

    expect(await _readBackendArtifact(service, id), isNull);
    await service.storePromotedArtifact(id: id, bytes: bytes);
    expect(await _readBackendArtifact(service, id), bytes);

    final report = await service.clearArtifacts();
    expect(report.evictedEntries, 1);
    expect(await _readBackendArtifact(service, id), isNull);
  });

  test('persistent service opens without eagerly restoring indexed pages',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-artifact-restore-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _readerArtifactId('lazy-cache-page');
    final first = await PersistentChapterDownloadService.open(directory.path);
    await first.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[2, 4, 6, 8]),
    );
    await first.close();

    final reopened =
        await PersistentChapterDownloadService.open(directory.path);
    addTearDown(reopened.close);

    expect(reopened.materializedSessionCount, 0);
    final entry = _entryForArtifact(id, byteLength: 4);
    final projected = (await reopened.inspectMany(<ImportedLibraryEntry>[
      entry,
    ])).single;
    expect(projected.completedPages, 1);
    expect(projected.receivedBytes, 4);
    expect(reopened.materializedSessionCount, 0);

    expect(await _readBackendArtifact(reopened, id), <int>[2, 4, 6, 8]);
    final stream = await reopened.openArtifactStream(id);
    expect(stream, isNotNull);
    expect(
      await stream!.open(start: 1, endExclusive: 3).expand((chunk) => chunk).toList(),
      <int>[4, 6],
    );
    expect(reopened.materializedSessionCount, 0);
  });

  test('persistent partial artifact survives Reader service reopen without promotion',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-partial-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _readerArtifactId('persistent-partial-page');
    final bytes = Uint8List.fromList(
      List<int>.generate(384, (index) => index & 0xff),
    );

    final first = await PersistentChapterDownloadService.open(directory.path);
    await first.storePartialDownload(
      id: id,
      entry: PartialDownloadEntry(
        length: bytes.lengthInBytes,
        validators: const Validators(etag: '"partial-v1"'),
        totalLength: 2048,
        open: ({required int start}) async* {
          yield Uint8List.sublistView(bytes, start);
        },
      ),
    );
    expect(await first.openArtifactStream(id), isNull);
    final beforeClose = await first.openPartialDownload(id);
    expect(beforeClose, isNotNull);
    expect(beforeClose!.length, bytes.lengthInBytes);
    await first.close();

    final reopened =
        await PersistentChapterDownloadService.open(directory.path);
    addTearDown(reopened.close);
    expect(await reopened.openArtifactStream(id), isNull);
    expect(reopened.materializedSessionCount, 0);
    final partial = await reopened.openPartialDownload(id);
    expect(partial, isNotNull);
    expect(partial!.length, bytes.lengthInBytes);
    expect(partial.validators.etag, '"partial-v1"');
    expect(partial.totalLength, 2048);
    expect(reopened.materializedSessionCount, 0);
    expect(
      await partial.open(start: 0).expand((chunk) => chunk).toList(),
      bytes,
    );
    expect(reopened.materializedSessionCount, 0);
  });

  test('cold partial misses do not materialize durable DownloadSessions',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-partial-miss-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);

    for (var index = 0; index < 12; index++) {
      final id = _readerArtifactId('missing-partial-$index');
      expect(await service.openPartialDownload(id), isNull);
    }
    expect(service.materializedSessionCount, 0);
  });

  test('persistent artifact store survives Reader service reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-artifact-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _readerArtifactId('persistent-cache-page');
    final bytes = Uint8List.fromList(<int>[11, 12, 13, 14]);

    final first = await PersistentChapterDownloadService.open(directory.path);
    await first.storePromotedArtifact(id: id, bytes: bytes);
    expect(await _readBackendArtifact(first, id), bytes);
    await first.close();

    final reopened =
        await PersistentChapterDownloadService.open(directory.path);
    addTearDown(reopened.close);
    expect(await _readBackendArtifact(reopened, id), bytes);
  });

  test('persistent composition owns runtime independently of chapter command',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-download-composition-owner-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final composition = await PersistentDownloadComposition.open(directory.path);

    await composition.chapterDownloads.close();

    expect(composition.transferRuntime.disposed, isFalse);
    expect((await composition.artifactStore.inspectArtifacts()).entries, 0);

    await composition.close();
    expect(composition.transferRuntime.disposed, isTrue);
  });

  test('chapter command joins an existing composition physical transfer',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-shared-chapter-transfer-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('https://example.test/shared-page.webp');
    final bytes = Uint8List.fromList('RIFF....WEBPshared'.codeUnits);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:shared-comic',
        displayName: '共享传输章节',
        sourceId: 'fixture-source',
        comicId: 'shared-comic',
        comicTitle: '共享传输测试',
        chapterId: 'shared-chapter',
        sourceRevision: 'shared-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: uri.toString(),
            pageId: 'shared-page',
            contentKindHint: ContentKindHint.webp,
            byteLength: bytes.lengthInBytes,
          ),
        ],
      ),
    );
    final service = await PersistentChapterDownloadService.open(directory.path);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'fixture-source',
        comicId: 'shared-comic',
        chapterId: 'shared-chapter',
        pageId: 'shared-page',
      ),
      sourceRevision: 'shared-r1',
      canonicalUri: uri,
    );
    final readerTransport = _SharedGateTransport(bytes);
    final reader = service.transferRuntime.attachConsumer(
      scopeId: 'reader-like-shared',
      transportFor: (_) => readerTransport,
      consumerTraceSink: const NoopTraceSink(),
    );
    var readerDisposed = false;
    var serviceClosed = false;
    addTearDown(() async {
      if (!readerTransport.release.isCompleted) {
        readerTransport.release.complete();
      }
      if (!readerDisposed) {
        await reader.dispose();
      }
      if (!serviceClosed) {
        await service.close();
      }
    });

    reader.replaceDemands(
      'reader-like-shared',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(priority: 1000, reason: 'reader-current'),
      },
    );
    await readerTransport.opened.future;
    final chapterRun = service.download(entry);
    await _waitUntil(() => service.transferRuntime.owner.claimCount(id) == 2);

    expect(service.transferRuntime.registry.sessions, hasLength(1));
    expect(readerTransport.opens, 1);
    expect(service.transferRuntime.owner.claimCount(id), 2);

    readerTransport.release.complete();
    await Future.wait<void>(<Future<void>>[reader.idle(), chapterRun]);

    expect(readerTransport.opens, 1);
    expect(service.transferRuntime.registry.sessions, hasLength(1));
    expect(await service.readPage(entry, 0), bytes);
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.complete);

    await reader.dispose();
    readerDisposed = true;
    await service.close();
    serviceClosed = true;
  });

  test('verified equivalent chapter joins existing physical transfer before acquire',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-equivalent-chapter-transfer-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final oldUri = Uri.parse('https://example.test/version-a.webp');
    final newUri = Uri.parse('https://example.test/version-b.webp');
    final bytes = Uint8List.fromList('RIFF....WEBPequivalent'.codeUnits);
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'fixture-source',
        comicId: 'version-a-comic',
        chapterId: 'version-a-chapter',
        pageId: 'version-a-page',
      ),
      sourceRevision: 'version-a-r1',
      canonicalUri: oldUri,
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:version-b-comic',
        displayName: '等价版本章节',
        sourceId: 'fixture-source',
        comicId: 'version-b-comic',
        comicTitle: '等价传输测试',
        chapterId: 'version-b-chapter',
        sourceRevision: 'version-b-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: newUri.toString(),
            pageId: 'version-b-page',
            contentKindHint: ContentKindHint.webp,
            byteLength: bytes.lengthInBytes,
          ),
        ],
      ),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'fixture-source',
        comicId: 'version-b-comic',
        chapterId: 'version-b-chapter',
        pageId: 'version-b-page',
      ),
      sourceRevision: 'version-b-r1',
      canonicalUri: newUri,
    );
    final service = await PersistentChapterDownloadService.open(directory.path);
    final oldTransport = _SharedGateTransport(bytes);
    final physicalTrace = MemoryTraceSink();
    final reader = service.transferRuntime.attachConsumer(
      scopeId: 'reader-like-version-a',
      transportFor: (_) => oldTransport,
      consumerTraceSink: const NoopTraceSink(),
      localPhysicalTraceSink: physicalTrace,
    );
    var readerDisposed = false;
    var serviceClosed = false;
    addTearDown(() async {
      if (!oldTransport.release.isCompleted) oldTransport.release.complete();
      if (!readerDisposed) await reader.dispose();
      if (!serviceClosed) await service.close();
    });
    service.artifactCacheManager.linkEquivalent(first: oldId, second: newId);

    reader.replaceDemands(
      'reader-like-version-a',
      1,
      <DownloadId, TransferDemand>{
        oldId: const TransferDemand(priority: 1000, reason: 'reader-current'),
      },
    );
    await oldTransport.opened.future;
    final chapterRun = service.download(entry);
    await _waitUntil(
      () => service.transferRuntime.owner.claimCount(newId) == 2,
    );

    expect(service.transferRuntime.registry.sessions, hasLength(1));
    expect(
      identical(
        service.transferRuntime.registry.get(oldId),
        service.transferRuntime.registry.get(newId),
      ),
      isTrue,
    );
    expect(oldTransport.opens, 1);
    expect(
      physicalTrace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] == 'verified-transfer-acquire-alias' &&
            event.payload['action'] == 'joined-existing-physical',
      ),
      isNotEmpty,
    );

    oldTransport.release.complete();
    await Future.wait<void>(<Future<void>>[reader.idle(), chapterRun]);

    expect(oldTransport.opens, 1);
    expect(
      physicalTrace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] ==
                'verified-equivalent-promotion-takeover',
      ),
      isEmpty,
    );
    expect(await service.artifactStore.openArtifactStream(newId), isNotNull);
    expect(await service.artifactStore.openArtifactStream(oldId), isNull);
    expect(
      physicalTrace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.identityHash == newId.key &&
            event.payload['action'] == 'stored-required-exact-alias' &&
            event.payload['physicalIdentityHash'] == oldId.key,
      ),
      isNotEmpty,
    );
    expect(await service.readPage(entry, 0), bytes);
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.complete);

    await reader.dispose();
    readerDisposed = true;
    await service.close();
    serviceClosed = true;
  });

  test('verified equivalence never merges two already-created physical sessions',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-no-late-session-merge-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);
    final first = _readerArtifactId('existing-equivalent-a');
    final second = _readerArtifactId('existing-equivalent-b');
    service.transferRuntime.registry.get(first);
    service.transferRuntime.registry.get(second);
    service.artifactCacheManager.linkEquivalent(first: first, second: second);

    final consumer = service.transferRuntime.attachConsumer(
      scopeId: 'existing-session-proof',
      transportFor: (_) => _ImmediateTransport(<int>[1, 2, 3, 4]),
      consumerTraceSink: const NoopTraceSink(),
    );
    addTearDown(consumer.dispose);
    consumer.replaceDemands(
      'existing-session-proof',
      1,
      <DownloadId, TransferDemand>{
        second: const TransferDemand(priority: 1, reason: 'proof'),
      },
    );

    expect(service.transferRuntime.registry.sessions, hasLength(2));
    expect(
      identical(
        service.transferRuntime.registry.get(first),
        service.transferRuntime.registry.get(second),
      ),
      isFalse,
    );
  });

  test('fresh verified identity reuses preferred existing physical owner',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-preferred-existing-owner-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);
    final promotedId = _readerArtifactId('preferred-promoted');
    final failedId = _readerArtifactId('alternate-failed');
    final freshId = _readerArtifactId('fresh-equivalent');
    final bytes = Uint8List.fromList('RIFF....WEBPpreferred'.codeUnits);

    final promoted = service.transferRuntime.registry.get(promotedId);
    await promoted.restore();
    await promoted.bindResponse(
      validators: const Validators(etag: 'preferred'),
      totalLength: bytes.lengthInBytes,
    );
    final promotedWriter = promoted.acquireWriter();
    await promoted.append(promotedWriter, 0, bytes);
    await promoted.seal(promotedWriter, expectedLength: bytes.lengthInBytes);
    await promoted.promote();

    final failed = service.transferRuntime.registry.get(failedId);
    await failed.restore();
    await failed.bindResponse(
      validators: const Validators(etag: 'failed'),
      totalLength: bytes.lengthInBytes,
    );
    final failedWriter = failed.acquireWriter();
    await failed.append(failedWriter, 0, bytes.sublist(0, 8));
    await failed.fail(
      failedWriter,
      const Failure(code: ErrorCode.cancelled, message: 'fixture preemption'),
    );

    service.artifactCacheManager.linkEquivalent(
      first: freshId,
      second: promotedId,
    );
    service.artifactCacheManager.linkEquivalent(
      first: freshId,
      second: failedId,
    );
    final trace = MemoryTraceSink();
    final consumer = service.transferRuntime.attachConsumer(
      scopeId: 'preferred-existing-owner',
      transportFor: (_) => _ImmediateTransport(bytes),
      consumerTraceSink: const NoopTraceSink(),
      localPhysicalTraceSink: trace,
    );
    addTearDown(consumer.dispose);

    consumer.replaceDemands(
      'preferred-existing-owner',
      1,
      <DownloadId, TransferDemand>{
        freshId: const TransferDemand(priority: 1000, reason: 'reader-current'),
      },
    );

    expect(service.transferRuntime.registry.sessions, hasLength(2));
    expect(
      identical(service.transferRuntime.registry.get(freshId), promoted),
      isTrue,
    );
    final alias = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'verified-transfer-acquire-alias' &&
          event.identityHash == freshId.key,
    );
    expect(alias.payload['action'], 'joined-existing-physical');
    expect(alias.payload['candidateOwners'], 2);
    expect(alias.payload['selection'], 'preferred-existing-owner');
    expect(alias.payload['physicalState'], DownloadState.promoted.name);
  });

  test('chapter cancellation removes only its composition transfer claim',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-shared-chapter-cancel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('https://example.test/shared-cancel.webp');
    final bytes = Uint8List.fromList('RIFF....WEBPcancel'.codeUnits);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:cancel-shared',
        displayName: '共享取消章节',
        sourceId: 'fixture-source',
        comicId: 'cancel-shared-comic',
        comicTitle: '共享取消测试',
        chapterId: 'cancel-shared-chapter',
        sourceRevision: 'cancel-shared-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: uri.toString(),
            pageId: 'cancel-shared-page',
            contentKindHint: ContentKindHint.webp,
            byteLength: bytes.lengthInBytes,
          ),
        ],
      ),
    );
    final service = await PersistentChapterDownloadService.open(directory.path);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'fixture-source',
        comicId: 'cancel-shared-comic',
        chapterId: 'cancel-shared-chapter',
        pageId: 'cancel-shared-page',
      ),
      sourceRevision: 'cancel-shared-r1',
      canonicalUri: uri,
    );
    final readerTransport = _SharedGateTransport(bytes);
    final reader = service.transferRuntime.attachConsumer(
      scopeId: 'reader-like-cancel',
      transportFor: (_) => readerTransport,
      consumerTraceSink: const NoopTraceSink(),
    );
    var readerDisposed = false;
    var serviceClosed = false;
    addTearDown(() async {
      if (!readerTransport.release.isCompleted) {
        readerTransport.release.complete();
      }
      if (!readerDisposed) {
        await reader.dispose();
      }
      if (!serviceClosed) {
        await service.close();
      }
    });

    reader.replaceDemands(
      'reader-like-cancel',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(priority: 1000, reason: 'reader-current'),
      },
    );
    await readerTransport.opened.future;
    final chapterRun = service.download(entry);
    await _waitUntil(() => service.transferRuntime.owner.claimCount(id) == 2);

    await service.cancel(entry);
    await chapterRun;
    expect(service.transferRuntime.owner.claimCount(id), 1);
    expect(service.transferRuntime.registry.get(id).demandCount, 1);
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.cancelled);

    readerTransport.release.complete();
    await reader.idle();
    expect(service.transferRuntime.registry.get(id).state, DownloadState.promoted);
    expect(readerTransport.opens, 1);

    await reader.dispose();
    readerDisposed = true;
    await service.close();
    serviceClosed = true;
  });

  test('persistent chapter download survives reopen and serves page bytes',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-chapter-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    await source.writeAsBytes(bytes, flush: true);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:comic',
        displayName: '第 1 话',
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        comicTitle: '离线下载测试',
        chapterId: 'fixture-chapter',
        sourceRevision: 'fixture-r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: source.uri.toString(),
            pageId: 'fixture-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: bytes.length,
          ),
        ],
      ),
    );

    final first = await PersistentChapterDownloadService.open(directory.path);
    expect(await first.isDownloaded(entry), isFalse);
    await first.download(entry);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        chapterId: 'fixture-chapter',
        pageId: 'fixture-page-1',
      ),
      sourceRevision: 'fixture-r1',
      canonicalUri: source.uri,
    );
    final physical = first.transferRuntime.registry.get(id);
    expect(physical.residentBodyBacked, isTrue);
    expect(physical.residentBodyAuthority, ByteResponseBodyAuthority.source);
    expect(physical.residentSource, 'reopenable-immutable-source');
    expect(physical.artifact.committedLength, 0);
    expect(await first.artifactStore.openArtifactStream(id), isNotNull);
    expect(await first.isDownloaded(entry), isTrue);
    expect(await first.readPage(entry, 0), bytes);
    await first.close();

    final reopened =
        await PersistentChapterDownloadService.open(directory.path);
    addTearDown(reopened.close);
    expect(await reopened.isDownloaded(entry), isTrue);
    expect(await reopened.readPage(entry, 0), bytes);
  });

  test('persistent plugin download resolves opaque source resources', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-plugin-chapter-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3]);
    final requested = <Uri>[];
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:test:comic',
        displayName: '第 1 话',
        sourceId: 'mihon:test',
        comicId: 'comic',
        comicTitle: '插件下载测试',
        chapterId: 'chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: 'mihon:resource:opaque-page',
            pageId: 'page-1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async {
          expect(sourceId, 'mihon:test');
          requested.add(uri);
          return bytes;
        },
      ),
    );

    await service.download(entry);

    expect(requested, <Uri>[Uri.parse('mihon:resource:opaque-page')]);
    expect(await service.readPage(entry, 0), bytes);
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.complete);
  });

  test('persistent plugin download publishes streamed byte progress in order',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-plugin-stream-progress-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:fixture:comic',
        displayName: '流式章节',
        sourceId: 'venera:fixture',
        comicId: 'comic',
        comicTitle: '流式进度测试',
        chapterId: 'chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.webp',
            sourceId: 'venera-resource:stream-page',
            pageId: 'page-1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    final release = Completer<void>();
    final controller = StreamController<List<int>>();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      if (!controller.isClosed) await controller.close();
    });
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);
    var completeByteFallbackCalled = false;
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async {
          completeByteFallbackCalled = true;
          return Uint8List(0);
        },
        openResponse: (sourceId, uri, {range, validators}) async {
          scheduleMicrotask(() async {
            controller.add(<int>[1, 2, 3]);
            await release.future;
            controller.add(<int>[4, 5, 6]);
            await controller.close();
          });
          return ByteResponse(
            bytes: controller.stream,
            statusCode: HttpStatus.ok,
            rangeStart: 0,
            totalLength: 6,
            validators: const Validators(etag: '"stream"'),
            rangeSupported: true,
          );
        },
      ),
    );
    final events = <ChapterDownloadSnapshot>[];
    final partial = Completer<ChapterDownloadSnapshot>();
    final subscription = service.changes.listen((snapshot) {
      events.add(snapshot);
      if (!partial.isCompleted &&
          snapshot.phase == ChapterDownloadPhase.downloading &&
          snapshot.receivedBytes == 3) {
        partial.complete(snapshot);
      }
    });
    addTearDown(subscription.cancel);

    final run = service.download(entry);
    final live = await partial.future.timeout(const Duration(seconds: 2));
    expect(live.totalBytes, 6);
    expect(live.fraction, closeTo(0.5, 0.001));

    release.complete();
    await run;
    expect(events.last.phase, ChapterDownloadPhase.complete);
    expect(events.last.receivedBytes, 6);
    expect(events.last.fraction, 1);
    expect(completeByteFallbackCalled, isFalse);
  });

  test('memory download publishes progress and delete returns to idle',
      () async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:progress-comic',
        displayName: '第 2 话',
        sourceId: 'progress-source',
        comicId: 'progress-comic',
        comicTitle: '进度测试',
        chapterId: 'progress-chapter',
        sourceRevision: 'progress-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://progress-1',
            pageId: 'progress-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 3,
          ),
          ImportedPageRecord(
            displayName: '2.bin',
            sourceId: 'memory://progress-2',
            pageId: 'progress-page-2',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 2,
          ),
        ],
      ),
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, index) async => Uint8List(index == 0 ? 3 : 2),
    );
    addTearDown(service.close);
    final events = <ChapterDownloadSnapshot>[];
    final subscription = service.changes.listen(events.add);
    addTearDown(subscription.cancel);

    await service.download(entry);
    final complete = await service.inspect(entry);
    expect(complete.phase, ChapterDownloadPhase.complete);
    expect(complete.completedPages, 2);
    expect(complete.receivedBytes, 5);
    expect(events.first.phase, ChapterDownloadPhase.downloading);
    expect(events.last.phase, ChapterDownloadPhase.complete);

    await service.delete(entry);
    final idle = await service.inspect(entry);
    expect(idle.phase, ChapterDownloadPhase.idle);
    expect(await service.isDownloaded(entry), isFalse);
  });

  test(
      'memory download cancellation keeps partial progress and retry completes',
      () async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:cancel-comic',
        displayName: '第 3 话',
        sourceId: 'cancel-source',
        comicId: 'cancel-comic',
        comicTitle: '取消与重试测试',
        chapterId: 'cancel-chapter',
        sourceRevision: 'cancel-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://cancel-1',
            pageId: 'cancel-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 3,
          ),
          ImportedPageRecord(
            displayName: '2.bin',
            sourceId: 'memory://cancel-2',
            pageId: 'cancel-page-2',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 2,
          ),
        ],
      ),
    );
    final secondPageGate = Completer<void>();
    final partialReached = Completer<void>();
    final loadedPages = <int>[];
    final service = MemoryChapterDownloadService(
      pageLoader: (_, index) async {
        loadedPages.add(index);
        if (index == 1 && !secondPageGate.isCompleted) {
          await secondPageGate.future;
        }
        return Uint8List(index == 0 ? 3 : 2);
      },
    );
    addTearDown(service.close);
    addTearDown(() {
      if (!secondPageGate.isCompleted) {
        secondPageGate.complete();
      }
    });
    final subscription = service.changes.listen((snapshot) {
      if (snapshot.phase == ChapterDownloadPhase.downloading &&
          snapshot.completedPages == 1 &&
          !partialReached.isCompleted) {
        partialReached.complete();
      }
    });
    addTearDown(subscription.cancel);

    final run = service.download(entry);
    await partialReached.future;
    final cancel = service.cancel(entry);
    secondPageGate.complete();
    await cancel;
    await run;

    final cancelled = await service.inspect(entry);
    expect(cancelled.phase, ChapterDownloadPhase.cancelled);
    expect(cancelled.completedPages, 1);
    expect(cancelled.receivedBytes, 3);
    expect(await service.isDownloaded(entry), isFalse);
    final partialUsage = await service.inspectArtifacts();
    expect(partialUsage.entries, 1);
    expect(partialUsage.bytes, 3);

    await service.retry(entry);
    final complete = await service.inspect(entry);
    expect(complete.phase, ChapterDownloadPhase.complete);
    expect(complete.completedPages, 2);
    expect(complete.receivedBytes, 5);
    expect(loadedPages.where((index) => index == 0).length, 1);
    expect(loadedPages.where((index) => index == 1).length, 2);
  });
}


ImportedLibraryEntry _entryForArtifact(
  DownloadId id, {
  required int byteLength,
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:${id.content.comicId}',
        displayName: '缓存章节',
        sourceId: id.content.sourceId,
        comicId: id.content.comicId,
        comicTitle: '缓存漫画',
        chapterId: id.content.chapterId,
        sourceRevision: id.sourceRevision,
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '${id.content.pageId}.bin',
            sourceId: id.canonicalUri.toString(),
            pageId: id.content.pageId,
            contentKindHint: ContentKindHint.unknown,
            byteLength: byteLength,
          ),
        ],
      ),
    );


Future<Uint8List?> _readBackendArtifact(
  ArtifactCacheBackend backend,
  DownloadId id,
) async {
  final entry = await backend.openArtifactStream(id);
  if (entry == null) return null;
  if (entry.readAll != null) return entry.readAll!();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in entry.open(start: 0)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _ImmediateTransport implements Transport {
  _ImmediateTransport(List<int> bytes) : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.value(bytes),
        statusCode: 200,
        rangeStart: 0,
        totalLength: bytes.lengthInBytes,
        validators: const Validators(etag: 'immediate'),
        rangeSupported: false,
      );
}

final class _SharedGateTransport implements ControlledTransport {
  _SharedGateTransport(this.bytes);

  final Uint8List bytes;
  final Completer<void> opened = Completer<void>();
  final Completer<void> release = Completer<void>();
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    opens++;
    if (!opened.isCompleted) opened.complete();
    await release.future;
    if (control?.cancelled ?? false) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'shared transfer cancelled',
      );
    }
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.lengthInBytes,
      validators: const Validators(etag: 'shared-transfer'),
      rangeSupported: false,
    );
  }
}

DownloadId _readerArtifactId(String pageId) => DownloadId(
      content: ContentId(
        sourceId: 'reader-cache-source',
        comicId: 'reader-cache-comic',
        chapterId: 'reader-cache-chapter',
        pageId: pageId,
      ),
      sourceRevision: 'reader-cache-r1',
      canonicalUri: Uri.parse('https://example.invalid/$pageId.bin'),
    );
