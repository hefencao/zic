import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
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
    final originalBytes = Uint8List.fromList(<int>[2, 4, 6, 8]);
    final firstWrite = first.storePromotedArtifact(
      id: id,
      bytes: originalBytes,
    );
    await expectLater(
      first.storePromotedArtifact(
        id: id,
        bytes: Uint8List.fromList(<int>[2, 4, 6, 9]),
      ),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    await firstWrite;
    expect(await _readBackendArtifact(first, id), originalBytes);
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

  test('storePromotedArtifact replaces interrupted partial session', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-partial-promoted-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);

    final id = _readerArtifactId('interrupted-partial-page');
    final partialBytes = Uint8List.fromList(<int>[1, 2]);
    await service.artifactStore.storePartialDownload(
      id: id,
      entry: PartialDownloadEntry(
        length: partialBytes.lengthInBytes,
        validators: const Validators(etag: '"partial-v1"'),
        totalLength: 10,
        open: ({required int start}) async* {
          yield Uint8List.sublistView(partialBytes, start);
        },
      ),
    );
    final beforeStore = await service.openPartialDownload(id);
    expect(beforeStore, isNotNull);
    expect(beforeStore!.length, 2);
    expect(await service.openArtifactStream(id), isNull);

    final fullBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    await service.storePromotedArtifact(id: id, bytes: fullBytes);

    expect(await _readBackendArtifact(service, id), fullBytes);
    final promotedStream = await service.openArtifactStream(id);
    expect(promotedStream, isNotNull);
    expect(promotedStream!.length, 5);
  });

  test(
    'compact home entries project progress from incrementally verified records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-compact-download-progress-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = await PersistentChapterDownloadService.open(
        directory.path,
      );
      addTearDown(service.close);
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'compact-source',
          comicId: 'compact-comic',
          chapterId: 'compact-chapter',
          pageId: 'page-1',
        ),
        sourceRevision: 'compact-r1',
        canonicalUri: Uri.parse('https://example.test/page-1.webp'),
      );
      await service.storePromotedArtifact(
        id: id,
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final compact = ImportedLibraryEntry(
        chapter: ImportedChapterRecord(
          directoryId: 'compact-directory',
          displayName: '紧凑章节',
          sourceId: 'compact-source',
          comicId: 'compact-comic',
          chapterId: 'compact-chapter',
          sourceRevision: 'compact-r1',
          pages: const <ImportedPageRecord>[
            ImportedPageRecord(
              displayName: 'page-1',
              sourceId: 'zic-home-snapshot-page:0',
              contentKindHint: ContentKindHint.unknown,
            ),
            ImportedPageRecord(
              displayName: 'page-2',
              sourceId: 'zic-home-snapshot-page:1',
              contentKindHint: ContentKindHint.unknown,
            ),
            ImportedPageRecord(
              displayName: 'page-3',
              sourceId: 'zic-home-snapshot-page:2',
              contentKindHint: ContentKindHint.unknown,
            ),
          ],
        ),
      );

      final snapshot = (await service.inspectMany(<ImportedLibraryEntry>[
        compact,
      ])).single;
      expect(snapshot.completedPages, 1);
      expect(snapshot.totalPages, 3);
      expect(snapshot.receivedBytes, 4);
    },
  );

  test(
    'persistent partial artifact survives Reader service reopen without promotion',
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

      final reopened = await PersistentChapterDownloadService.open(
        directory.path,
      );
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
    },
  );

  test(
    'cold partial misses do not materialize durable DownloadSessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-reader-partial-miss-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final service = await PersistentChapterDownloadService.open(
        directory.path,
      );
      addTearDown(service.close);

      for (var index = 0; index < 12; index++) {
        final id = _readerArtifactId('missing-partial-$index');
        expect(await service.openPartialDownload(id), isNull);
      }
      expect(service.materializedSessionCount, 0);
    },
  );

  test(
    'SAF partial store rejects an explicitly foreign existing owner',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-saf-partial-owner-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = <String, Uint8List>{};
      final saf = _MemorySafIo(storage);
      final service = await PersistentChapterDownloadService.open(
        directory.path,
        safTreeIo: saf,
        safTreeUri: 'content://tree/saf-partial-owner',
      );
      addTearDown(service.close);

      final id = _readerArtifactId('saf-partial-owner');
      final foreign = _readerArtifactId('saf-partial-foreign');
      final relativePath =
          'partial/${service.artifactStore.layoutFor(id).tokenFor(id)}.part';
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      storage[relativePath] = Uint8List.fromList(bytes);
      storage['$relativePath.meta'] = Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'downloadKey': foreign.key,
            'download': foreign.toJson(),
          }),
        ),
      );

      await expectLater(
        service.storePartialDownload(
          id: id,
          entry: PartialDownloadEntry(
            length: bytes.length,
            validators: const Validators(etag: 'saf-partial'),
            totalLength: 20,
            open: ({required int start}) async* {
              yield Uint8List.sublistView(bytes, start);
            },
          ),
        ),
        throwsA(
          isA<Failure>().having(
            (error) => error.code,
            'code',
            ErrorCode.artifactCorruption,
          ),
        ),
      );
      expect(storage[relativePath], orderedEquals(bytes));
    },
  );

  test(
    'SAF partial persistence yields to foreground local-read pressure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-saf-partial-foreground-yield-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = <String, Uint8List>{};
      final saf = _MemorySafIo(storage);
      final reads = ArtifactCacheReadScheduler(
        maxActive: 2,
        maxBackgroundWhileForeground: 1,
      );
      final writes = StorageWriteScheduler(localReadScheduler: reads);
      final service = await PersistentChapterDownloadService.open(
        directory.path,
        localReadScheduler: reads,
        storageWriteScheduler: writes,
        safTreeIo: saf,
        safTreeUri: 'content://tree/saf-partial-foreground-yield',
      );
      addTearDown(service.close);
      final id = _readerArtifactId('saf-partial-foreground-yield');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (index) => index & 0xff),
      );
      final pressure = reads.holdForegroundPressure();
      addTearDown(pressure.release);

      var completed = false;
      final storing = service
          .storePartialDownload(
            id: id,
            entry: PartialDownloadEntry(
              length: bytes.lengthInBytes,
              validators: const Validators(etag: 'saf-yield'),
              totalLength: bytes.lengthInBytes * 2,
              open: ({required int start}) async* {
                yield Uint8List.sublistView(
                  bytes,
                  start,
                  bytes.lengthInBytes ~/ 2,
                );
                yield Uint8List.sublistView(bytes, bytes.lengthInBytes ~/ 2);
              },
            ),
          )
          .whenComplete(() => completed = true);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      expect(
        storage.keys.where((path) => path.contains('.zic-tmp-')),
        isEmpty,
        reason:
            'background SAF persistence must not acquire a write quantum '
            'while Reader foreground pressure is held',
      );

      pressure.release();
      await storing.timeout(const Duration(seconds: 1));
      final relativePath =
          'partial/${service.artifactStore.layoutFor(id).tokenFor(id)}.part';
      expect(storage[relativePath], orderedEquals(bytes));
    },
  );

  test(
    'SAF partial stays stream-backed and never exposes POSIX adoption',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-saf-partial-stream-fallback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = <String, Uint8List>{};
      final service = await PersistentChapterDownloadService.open(
        directory.path,
        safTreeIo: _MemorySafIo(storage),
        safTreeUri: 'content://tree/saf-partial-stream-fallback',
      );
      addTearDown(service.close);
      final id = _readerArtifactId('saf-partial-stream-fallback');
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);

      await service.storePartialDownload(
        id: id,
        entry: PartialDownloadEntry(
          length: bytes.lengthInBytes,
          validators: const Validators(etag: 'saf-stream-v1'),
          totalLength: 12,
          open: ({required int start}) =>
              Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
        ),
      );
      final partial = await service.openPartialDownload(id);

      expect(partial, isNotNull);
      expect(partial!.adoptInto, isNull);
      final restored = <int>[];
      await for (final chunk in partial.open(start: 0)) {
        restored.addAll(chunk);
      }
      expect(restored, bytes);
    },
  );

  test('foreign partial metadata drops only the logical binding', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-partial-foreign-binding-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(directory.path);
    addTearDown(service.close);
    final id = _readerArtifactId('foreign-partial-target');
    final foreign = _readerArtifactId('foreign-partial-owner');
    final path = '${directory.path}/offline_chapters/partial.bin';
    final bytes = Uint8List.fromList(<int>[5, 6, 7, 8]);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bytes);
    await File('$path.meta').writeAsString(
      jsonEncode(<String, Object?>{
        'downloadKey': foreign.key,
        'download': foreign.toJson(),
      }),
    );
    await service.artifactStore.index.put(
      CacheRec(
        id: id,
        state: CacheState.partial,
        path: path,
        bytes: bytes.length,
        checksum: '',
        createdUs: 1,
        touchedUs: 1,
        storageRootId: '${directory.path}/offline_chapters',
      ),
    );

    expect(await service.openPartialDownload(id), isNull);
    expect(await File(path).readAsBytes(), bytes);
    expect(await File('$path.meta').exists(), isTrue);
    expect(await service.artifactStore.index.get(id.key), isNull);
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
          event.identityHash ==
              TraceEvent(
                monotonicMicros: 0,
                sessionId: 'test',
                kind: TraceEventKind.artifactSource,
                identityHash: freshId.key,
              ).identityHash,
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
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
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
            controller.add(<int>[
              0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
            ]);
            await release.future;
            controller.add(<int>[
              0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
            ]);
            await controller.close();
          });
          return ByteResponse(
            bytes: controller.stream,
            statusCode: HttpStatus.ok,
            rangeStart: 0,
            totalLength: 16,
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
          snapshot.receivedBytes == 8) {
        partial.complete(snapshot);
      }
    });
    addTearDown(subscription.cancel);

    final run = service.download(entry);
    final live = await partial.future.timeout(const Duration(seconds: 2));
    expect(live.totalBytes, 16);
    expect(live.fraction, closeTo(0.5, 0.001));

    release.complete();
    await run;
    expect(events.last.phase, ChapterDownloadPhase.complete);
    expect(events.last.receivedBytes, 16);
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
            byteLength: 16,
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

  test('memory delete cannot be undone by a late page loader completion', () async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:delete-race',
        displayName: '删除竞态',
        sourceId: 'delete-race-source',
        comicId: 'delete-race-comic',
        comicTitle: '删除竞态测试',
        chapterId: 'delete-race-chapter',
        sourceRevision: 'delete-race-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://delete-race-1',
            pageId: 'delete-race-page-1',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        entered.complete();
        await release.future;
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );
    addTearDown(service.close);

    final run = service.download(entry);
    await entered.future;
    await service.delete(entry);
    release.complete();
    await run;

    final snapshot = await service.inspect(entry);
    expect(snapshot.phase, ChapterDownloadPhase.idle);
    expect(snapshot.completedPages, 0);
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

  test('CompositeArtifactBytes delegates transparently between local and SAF',
      () async {
    final temp = await Directory.systemTemp.createTemp('composite-bytes-test');
    addTearDown(() => temp.delete(recursive: true));
    final localFile = File('${temp.path}/sample.bin');
    await localFile.writeAsBytes(<int>[1, 2, 3, 4]);

    final safStorage = <String, Uint8List>{
      'final/p1.bin': Uint8List.fromList(<int>[10, 20, 30]),
    };
    final safIo = _MemorySafIo(safStorage);
    final composite = CompositeArtifactBytes(
      saf: SafArtifactBytes(safIo),
    );

    expect(await composite.exists(localFile.path), isTrue);
    expect(await composite.length(localFile.path), 4);
    final localChunks = await composite
        .readChunks(localFile.path, start: 1, endExclusive: 3)
        .toList();
    expect(localChunks.single, <int>[2, 3]);

    final safPath = encodeSafRecordPath(
      treeUri: 'content://saf-test-tree',
      relativePath: 'final/p1.bin',
    );
    expect(await composite.exists(safPath), isTrue);
    expect(await composite.length(safPath), 3);
    final safChunks = await composite
        .readChunks(safPath, start: 0, endExclusive: 2)
        .toList();
    expect(safChunks.single, <int>[10, 20]);

    await composite.delete(safPath);
    expect(await composite.exists(safPath), isFalse);
    expect(safStorage.containsKey('final/p1.bin'), isFalse);

    await composite.delete(localFile.path);
    expect(await composite.exists(localFile.path), isFalse);
  });

  test('local artifact bytes never follows a symbolic link', () async {
    if (Platform.isWindows) return;
    final temp = await Directory.systemTemp.createTemp('local-bytes-link-test');
    addTearDown(() => temp.delete(recursive: true));
    final outside = File('${temp.path}/outside.bin');
    await outside.writeAsBytes(const <int>[1, 2, 3]);
    final link = Link('${temp.path}/cache.bin');
    await link.create(outside.path);
    final bytes = const LocalArtifactBytes();

    expect(await bytes.exists(link.path), isFalse);
    expect(await bytes.length(link.path), 0);
    expect(await bytes.readChunks(link.path, start: 0).toList(), isEmpty);
    await bytes.delete(link.path);
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(await outside.exists(), isTrue);
  });

  test('sniffImageExtension detects known image headers correctly', () async {
    final temp = await Directory.systemTemp.createTemp('sniff-ext-test');
    addTearDown(() => temp.delete(recursive: true));

    final jpgFile = File('${temp.path}/t.jpg');
    await jpgFile.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xe0, 0x00]);
    expect(await sniffImageExtension(jpgFile), 'jpg');

    final pngFile = File('${temp.path}/t.png');
    await pngFile.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(await sniffImageExtension(pngFile), 'png');

    final webpFile = File('${temp.path}/t.webp');
    await webpFile.writeAsBytes(<int>[
      0x52, 0x49, 0x46, 0x46,
      0x00, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
    ]);
    expect(await sniffImageExtension(webpFile), 'webp');

    final gifFile = File('${temp.path}/t.gif');
    await gifFile.writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    expect(await sniffImageExtension(gifFile), 'gif');

    final bmpFile = File('${temp.path}/t.bmp');
    await bmpFile.writeAsBytes(<int>[0x42, 0x4d, 1, 2, 3, 4]);
    expect(await sniffImageExtension(bmpFile), 'bmp');

    final tiffFile = File('${temp.path}/t.tiff');
    await tiffFile.writeAsBytes(<int>[0x49, 0x49, 0x2a, 0x00, 1, 2]);
    expect(await sniffImageExtension(tiffFile), 'tiff');

    final icoFile = File('${temp.path}/t.ico');
    await icoFile.writeAsBytes(<int>[0x00, 0x00, 0x01, 0x00, 1, 2]);
    expect(await sniffImageExtension(icoFile), 'ico');

    final avifFile = File('${temp.path}/t.avif');
    await avifFile.writeAsBytes(<int>[
      0, 0, 0, 24, ...'ftyp'.codeUnits, ...'avif'.codeUnits,
      0, 0, 0, 0, ...'mif1'.codeUnits,
    ]);
    expect(await sniffImageExtension(avifFile), 'avif');

    final heifFile = File('${temp.path}/t.heif');
    await heifFile.writeAsBytes(<int>[
      0, 0, 0, 24, ...'ftyp'.codeUnits, ...'heic'.codeUnits,
      0, 0, 0, 0, ...'mif1'.codeUnits,
    ]);
    expect(await sniffImageExtension(heifFile), 'heif');

    final genericFtyp = File('${temp.path}/video.bin');
    await genericFtyp.writeAsBytes(<int>[
      0, 0, 0, 24, ...'ftyp'.codeUnits, ...'mp42'.codeUnits,
      0, 0, 0, 0, ...'isom'.codeUnits,
    ]);
    expect(await sniffImageExtension(genericFtyp), 'bin');

    final binFile = File('${temp.path}/t.bin');
    await binFile.writeAsBytes(<int>[1, 2, 3, 4]);
    expect(await sniffImageExtension(binFile), 'bin');
  });

  test('scanExistingPages rejects non-image payloads with image extensions',
      () async {
    final root = await Directory.systemTemp.createTemp('scan-magic-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final comicDir = Directory('${service.artifactStore.layout.root}/校验漫画');
    await comicDir.create(recursive: true);
    await File('${comicDir.path}/001.jpg').writeAsString(
      '<html>not an image</html>',
    );
    await File('${comicDir.path}/002.jpg').writeAsBytes(<int>[
      0xff,
      0xd8,
      0xff,
      0xe0,
      0x00,
    ]);

    final pages = await service.artifactStore.scanExistingPages(
      comicTitle: '校验漫画',
      chapterTitle: '单话',
      isSingleChapter: true,
    );
    expect(pages.keys, contains(2));
    expect(pages.keys, isNot(contains(1)));
  });

  test('PersistentChapterDownloadService discovers orphaned entries not in known set', () async {
    final temp = await Directory.systemTemp.createTemp('orphaned-test');
    addTearDown(() => temp.delete(recursive: true));

    final service = await PersistentChapterDownloadService.open(temp.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async => Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
          0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
        ]),
      ),
    );

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:test:comic',
        displayName: '测试章节',
        sourceId: 'mihon:test',
        comicId: 'comic-1',
        chapterId: 'ch-1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          const ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'mihon:resource:page-1',
            pageId: 'page-1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 3,
          ),
        ],
      ),
    );

    // Download an entry
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);

    // If knownEntries contains entry, discoverOrphanedEntries returns empty
    final none = await service.discoverOrphanedEntries(<ImportedLibraryEntry>[entry]);
    expect(none, isEmpty);

    // If knownEntries is empty, discoverOrphanedEntries returns the entry
    final orphaned = await service.discoverOrphanedEntries(const <ImportedLibraryEntry>[]);
    expect(orphaned.length, 1);
    expect(orphaned.first.chapter.chapterId, entry.chapter.chapterId);
    expect(orphaned.first.chapter.comicId, entry.chapter.comicId);
    expect(orphaned.first.chapter.sourceId, entry.chapter.sourceId);

    final management = await service.inspectDownloadManagement(
      const <ImportedLibraryEntry>[],
    );
    expect(management.orphanedEntries, hasLength(1));
    expect(management.snapshots, hasLength(1));
    expect(management.snapshots.single.isComplete, isTrue);

    final knownManagement = await service.inspectDownloadManagement(
      <ImportedLibraryEntry>[entry],
    );
    expect(knownManagement.orphanedEntries, isEmpty);
    expect(knownManagement.snapshots.single.title, entry.chapter.displayName);
  });

  test('Structured download writes flat single-chapter and auto-migrates on multi-chapter transition', () async {
    final temp = await Directory.systemTemp.createTemp('structured-download-test');
    addTearDown(() => temp.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final memorySaf = _MemorySafIo(memoryStorage);
    final service = await PersistentChapterDownloadService.open(
      temp.path,
      safTreeIo: memorySaf,
      safTreeUri: 'content://com.android.externalstorage.documents/tree/1234',
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async => Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      ),
    );

    final entry1 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:test:comic-one',
        displayName: '第 1 话',
        sourceId: 'mihon:test',
        comicId: 'comic-one',
        comicTitle: '航海王',
        chapterId: 'ch-01',
        sourceRevision: 'r1',
        sequence: 1,
        pages: <ImportedPageRecord>[
          const ImportedPageRecord(
            displayName: '001.png',
            sourceId: 'mihon:resource:page-1',
            pageId: 'page-1',
            contentKindHint: ContentKindHint.png,
            byteLength: 8,
          ),
        ],
      ),
    );

    // 1. Download single chapter: should be flat directly under comic folder
    await service.download(entry1);
    expect(await service.isDownloaded(entry1), isTrue);

    final singleChapterPaths = memoryStorage.keys.toList();
    expect(singleChapterPaths, contains('航海王/001.png'));
    expect(singleChapterPaths, contains('航海王/.zic.json'));
    expect(singleChapterPaths, isNot(contains('航海王/第 1 话/001.png')));

    // 2. Download second chapter: should auto-migrate ch-01 to subfolder and save ch-02 to subfolder
    final entry2 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:test:comic-one',
        displayName: '第 2 话',
        sourceId: 'mihon:test',
        comicId: 'comic-one',
        comicTitle: '航海王',
        chapterId: 'ch-02',
        sourceRevision: 'r1',
        sequence: 2,
        pages: <ImportedPageRecord>[
          const ImportedPageRecord(
            displayName: '001.png',
            sourceId: 'mihon:resource:page-2',
            pageId: 'page-2',
            contentKindHint: ContentKindHint.png,
            byteLength: 8,
          ),
        ],
      ),
    );

    await service.download(entry2);
    expect(await service.isDownloaded(entry1), isTrue);
    expect(await service.isDownloaded(entry2), isTrue);

    final multiChapterPaths = memoryStorage.keys.toList();
    expect(multiChapterPaths, contains('航海王/第 1 话/001.png'));
    expect(multiChapterPaths, contains('航海王/第 2 话/001.png'));
    expect(multiChapterPaths, isNot(contains('航海王/001.png')));

    // 3. Delete chapters: cleans up entries
    await service.delete(entry1);
    expect(await service.isDownloaded(entry1), isFalse);
    expect(await service.isDownloaded(entry2), isTrue);

    await service.delete(entry2);
    expect(await service.isDownloaded(entry2), isFalse);
  });

  test('structured migration rejects a same-length changed indexed source', () async {
    final temp = await Directory.systemTemp.createTemp(
      'zic-structured-migration-corruption-',
    );
    addTearDown(() => temp.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final service = await PersistentChapterDownloadService.open(
      temp.path,
      safTreeIo: _MemorySafIo(memoryStorage),
      safTreeUri: 'content://tree/structured-migration-corruption',
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async => Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ]),
      ),
    );

    ImportedLibraryEntry entry(String chapterId, int sequence, String pageId) =>
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'mihon:test:structured-corruption',
            displayName: '第 $sequence 话',
            sourceId: 'mihon:test',
            comicId: 'structured-corruption',
            comicTitle: '损坏迁移测试',
            chapterId: chapterId,
            sourceRevision: 'r1',
            sequence: sequence,
            pages: <ImportedPageRecord>[
              ImportedPageRecord(
                displayName: '001.png',
                sourceId: 'mihon:resource:$pageId',
                pageId: pageId,
                contentKindHint: ContentKindHint.png,
                byteLength: 8,
              ),
            ],
          ),
        );

    final first = entry('ch-01', 1, 'page-1');
    await service.download(first);
    final sourcePath = '损坏迁移测试/001.png';
    expect(memoryStorage[sourcePath], isNotNull);
    memoryStorage[sourcePath] = Uint8List.fromList(<int>[
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    ]);

    final second = entry('ch-02', 2, 'page-2');
    await expectLater(
      service.download(second),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(memoryStorage[sourcePath], hasLength(8));
    expect(memoryStorage.keys, isNot(contains('损坏迁移测试/第 1 话/001.png')));
  });

  test('unindexed files require an explicit overwrite and are never adopted by retry', () async {
    final root = await Directory.systemTemp.createTemp('zic-incremental-download');
    addTearDown(() => root.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final memorySaf = _MemorySafIo(memoryStorage);

    final webpBytes1 = Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4]);
    final webpBytes2 = Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 9, 10, 11, 12]);

    // Pre-populate page 1 on disk/SAF (e.g. 001.webp with valid webp header)
    memoryStorage['[武器屋]海賊（ワンピース）/001.webp'] = webpBytes1;

    final service = await PersistentChapterDownloadService.open(
      root.path,
      safTreeIo: memorySaf,
      safTreeUri: 'content://tree/downloads',
    );
    addTearDown(service.close);
    var networkCalls = 0;
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (sourceId, uri) async {
          networkCalls++;
          return webpBytes2;
        },
      ),
    );

    // Chapter now has 2 pages: page 1 (already on disk) and page 2 (missing)
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:ehentai:gallery-1',
        displayName: '单话',
        sourceId: 'mihon:ehentai',
        comicId: 'gallery-1',
        comicTitle: '[武器屋]海賊（ワンピース）',
        chapterId: 'ch-1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'mihon:ehentai:p1',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 16,
          ),
          ImportedPageRecord(
            displayName: '002.webp',
            sourceId: 'mihon:ehentai:p2',
            pageId: 'p2',
            contentKindHint: ContentKindHint.webp,
            byteLength: 16,
          ),
        ],
      ),
    );

    await expectLater(
      service.download(entry),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );
    expect(memoryStorage['[武器屋]海賊（ワンピース）/001.webp'], webpBytes1);
    // Ordinary download classifies only from incrementally persisted records.
    // It may finish another page in the bounded transfer window before the
    // conflicting target commit fails, but it must not enumerate the folder.
    expect(networkCalls, 2);
    expect(memorySaf.listCalls, 0);

    await service.claimComicDirectory(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      directoryName: '[武器屋]海賊（ワンピース）',
      mode: DownloadPlacementMode.overwrite,
    );
    await service.retry(entry);
    expect(await service.isDownloaded(entry), isTrue);
    expect(networkCalls, 2);
    expect(memorySaf.listCalls, 0);
    expect(memoryStorage['[武器屋]海賊（ワンピース）/001.webp'], webpBytes2);
    expect(memoryStorage['[武器屋]海賊（ワンピース）/002.webp'], webpBytes2);
  });

  test('retry consumes incremental checksum records without listing existing files', () async {
    final root = await Directory.systemTemp.createTemp('zic-scan-cache-');
    addTearDown(() => root.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final memorySaf = _MemorySafIo(memoryStorage);
    final webp1 = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00, //
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final webp2 = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00, //
      0x57, 0x45, 0x42, 0x50, 9, 10, 11, 12,
    ]);
    final traceEvents = <TraceEvent>[];
    var networkCalls = 0;
    final service = await PersistentChapterDownloadService.open(
      root.path,
      safTreeIo: memorySaf,
      safTreeUri: 'content://tree/downloads',
      traceSink: CallbackTraceSink(traceEvents.add),
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (sourceId, uri) async {
        networkCalls++;
        return uri.toString().endsWith('p1') ? webp1 : webp2;
      }),
    );

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:ehentai:scan-cache',
        displayName: '单话',
        sourceId: 'mihon:ehentai',
        comicId: 'gallery-1',
        comicTitle: '[武器屋]海賊（ワンピース）',
        chapterId: 'ch-1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'mihon:ehentai:p1',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 16,
          ),
          ImportedPageRecord(
            displayName: '002.webp',
            sourceId: 'mihon:ehentai:p2',
            pageId: 'p2',
            contentKindHint: ContentKindHint.webp,
            byteLength: 16,
          ),
        ],
      ),
    );

    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);
    expect(networkCalls, 2);
    expect(memorySaf.listCalls, 0);
    final pageReadsAfterFirstDownload = memorySaf.readPaths
        .where((path) => path.endsWith('.webp'))
        .length;
    expect(
      traceEvents.where(
        (event) => event.payload['stage'] == 'chapter-run-scanned',
      ),
      isEmpty,
    );

    await service.retry(entry);
    expect(networkCalls, 2);
    expect(memorySaf.listCalls, 0);
    expect(
      memorySaf.readPaths
          .where((path) => path.endsWith('.webp'))
          .length,
      pageReadsAfterFirstDownload,
    );
    expect(await service.isDownloaded(entry), isTrue);
  });

  test('retry revalidates a structured exact file deleted outside the app',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-retry-external-delete-');
    addTearDown(() => root.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final memorySaf = _MemorySafIo(memoryStorage);
    final webp = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    var networkCalls = 0;
    var service = await PersistentChapterDownloadService.open(
      root.path,
      safTreeIo: memorySaf,
      safTreeUri: 'content://tree/downloads',
    );
    addTearDown(() async {
      try {
        await service.close();
      } on StateError {
        // The test may have already closed the previous service instance.
      }
    });
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return webp;
      }),
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:retry-external-delete',
        displayName: '单话',
        sourceId: 'mihon:test',
        comicId: 'retry-external-delete',
        comicTitle: '外部删除重试',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'mihon:test:retry-page',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 16,
          ),
        ],
      ),
    );

    await service.download(entry);
    expect(networkCalls, 1);
    final exportedPath = memoryStorage.keys.singleWhere(
      (path) => path.endsWith('/001.webp'),
    );
    await service.close();
    memoryStorage.remove(exportedPath);
    service = await PersistentChapterDownloadService.open(
      root.path,
      safTreeIo: memorySaf,
      safTreeUri: 'content://tree/downloads',
    );
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return webp;
      }),
    );

    await service.retry(entry);

    expect(networkCalls, 2,
        reason: 'retry must not trust a structured index after external deletion');
    expect(memoryStorage[exportedPath], webp);
    expect(await service.isDownloaded(entry), isTrue);
  });

  test('chapter stall window resets on sub-quantum network progress', () async {
    final root = await Directory.systemTemp.createTemp('zic-stall-progress-');
    addTearDown(() => root.delete(recursive: true));

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46,
      0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x20,
    ]);
    final chunks = <List<int>>[
      webpBytes.sublist(0, 4),
      webpBytes.sublist(4, 8),
      webpBytes.sublist(8, 12),
      webpBytes.sublist(12, 16),
    ];
    final service = await PersistentChapterDownloadService.open(
      root.path,
      pageStallTimeout: const Duration(milliseconds: 250),
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        openResponse: (sourceId, uri, {range, validators}) async {
          Stream<List<int>> body() async* {
            for (final chunk in chunks) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              yield chunk;
            }
          }

          return ByteResponse(
            bytes: body(),
            statusCode: HttpStatus.ok,
            rangeStart: 0,
            totalLength: webpBytes.length,
          );
        },
        loadBytes: (sourceId, uri) async => webpBytes,
      ),
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'stall-progress',
        displayName: '持续慢流',
        sourceId: 'mihon:test',
        comicId: 'stall-progress-comic',
        comicTitle: '持续慢流测试',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'mihon:test:stall-progress-page',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );

    await service.download(entry);

    final snapshot = await service.inspect(entry);
    expect(snapshot.phase, ChapterDownloadPhase.complete);
    expect(snapshot.receivedBytes, webpBytes.length);
  });

  test('chapter command lets the physical owner retry a stalled body',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-stall-reclaim-');
    addTearDown(() => root.delete(recursive: true));

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00, //
      0x57, 0x45, 0x42, 0x50, 5, 6, 7, 8,
    ]);
    var openCalls = 0;
    final traceEvents = <TraceEvent>[];

    final service = await PersistentChapterDownloadService.open(
      root.path,
      pageStallTimeout: const Duration(milliseconds: 400),
      traceSink: CallbackTraceSink(traceEvents.add),
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        openResponse: (sourceId, uri, {range, validators}) async {
          openCalls++;
          if (openCalls == 1) {
            // First physical run goes silent forever: no bytes, no error, no
            // terminal session state (a backgrounded plugin runtime).
            final controller = StreamController<List<int>>();
            return ByteResponse(
              bytes: controller.stream,
              statusCode: 200,
              rangeStart: 0,
              totalLength: webpBytes.length,
            );
          }
          return ByteResponse(
            bytes: Stream.value(webpBytes),
            statusCode: 200,
            rangeStart: 0,
            totalLength: webpBytes.length,
          );
        },
        loadBytes: (sourceId, uri) async => webpBytes,
      ),
    );

    final uri = Uri.parse('mihon:ehentai:stall-page');
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:ehentai:stall',
        displayName: '停摆章节',
        sourceId: 'mihon:ehentai',
        comicId: 'stall-comic',
        comicTitle: '停摆回收测试',
        chapterId: 'stall-ch',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uri.toString(),
            pageId: 'stall-page',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    // Body stall → DownloadJob attempt cleanup → provider retry → completes.
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);
    expect(openCalls, greaterThanOrEqualTo(2));

    // The stall trail must land in the injected sink.
    final stages = traceEvents
        .map((event) => event.payload['stage'] as String?)
        .toSet();
    expect(stages, contains('chapter-run-start'));
    expect(stages, isNot(contains('page-promotion-stall-reclaim')));
    expect(stages, isNot(contains('page-promotion-reclaim-rewait')));
    expect(stages, contains('chapter-run-complete'));
    expect(stages, isNot(contains('page-promotion-stall-gave-up')));
    // The owner reacted to the stuck attempt through the same sink.
    final kinds = traceEvents.map((event) => event.kind).toSet();
    expect(kinds, contains(TraceEventKind.retryScheduled));
  });

  test('chapter page waiter yields to a self-bounded long transport open',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-self-bounded-open-');
    addTearDown(() => root.delete(recursive: true));

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 5, 6, 7, 8,
    ]);
    var openCalls = 0;
    final traceEvents = <TraceEvent>[];
    final service = await PersistentChapterDownloadService.open(
      root.path,
      pageStallTimeout: const Duration(milliseconds: 100),
      traceSink: CallbackTraceSink(traceEvents.add),
    );
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        openResponse: (sourceId, uri, {range, validators}) async {
          openCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          return ByteResponse(
            bytes: Stream<List<int>>.value(webpBytes),
            statusCode: HttpStatus.ok,
            rangeStart: 0,
            totalLength: webpBytes.length,
          );
        },
        selfBoundsOpen: (sourceId, uri) => true,
      ),
    );

    final uri = Uri.parse('venera-resource:self-bounded-page');
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:self-bounded',
        displayName: '长 request-plan 章节',
        sourceId: 'venera:self-bounded',
        comicId: 'self-bounded-comic',
        comicTitle: '长 request-plan 测试',
        chapterId: 'self-bounded-ch',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uri.toString(),
            pageId: 'self-bounded-page',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    await service.download(entry);

    expect(await service.isDownloaded(entry), isTrue);
    expect(openCalls, 1);
    final stages = traceEvents
        .map((event) => event.payload['stage'] as String?)
        .toSet();
    expect(stages, isNot(contains('page-promotion-stall-reclaim')));
    expect(stages, isNot(contains('page-promotion-stall-gave-up')));
  });

  test('same revision pageId never substitutes for a different exact URI',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-alias-preference-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final bytesOldRevision = Uint8List.fromList(List<int>.filled(100, 1));
    final bytesEntryRevision = Uint8List.fromList(List<int>.filled(50, 2));
    final content = const ContentId(
      sourceId: 'mihon:ehentai',
      comicId: 'alias-comic',
      chapterId: 'alias-ch',
      pageId: 'p1',
    );
    // The current revision re-resolved the page to a different URI. Neither
    // the same pageId nor being in the current revision proves exact identity.
    final superseded = DownloadId(
      content: content,
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/alias/a.webp'),
    );
    final entryRevision = DownloadId(
      content: content,
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/alias/b.webp'),
    );
    await service.storePromotedArtifact(id: entryRevision, bytes: bytesEntryRevision);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await service.storePromotedArtifact(id: superseded, bytes: bytesOldRevision);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:ehentai:alias',
        displayName: '别名章节',
        sourceId: 'mihon:ehentai',
        comicId: 'alias-comic',
        comicTitle: '别名确定性测试',
        chapterId: 'alias-ch',
        sourceRevision: 'r2',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/alias/a.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: bytesOldRevision.length,
          ),
        ],
      ),
    );

    final snapshot = await service.inspect(entry);
    expect(await service.readyPageIndices(entry), isEmpty);
    expect(snapshot.completedPages, 0);
    expect(snapshot.exactCompletedPages, 0);
    expect(snapshot.reusablePages, 0);
    expect(snapshot.receivedBytes, 0);
    expect(snapshot.isComplete, isFalse);
  });

  test('invalid comic manifests block destructive directory reuse', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-invalid-comic-manifest-',
    );
    addTearDown(() async => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final entry = _entryForArtifact(_readerArtifactId('invalid-manifest'), byteLength: 1);
    final comicDirectory = Directory('${service.artifactStore.layout.root}/缓存漫画');
    await comicDirectory.create(recursive: true);
    final manifest = File(
      '${comicDirectory.path}/$comicManifestFileName',
    );
    await manifest.writeAsString('{not-json');

    await expectLater(
      service.artifactStore.resolveStructuredComicDirectory(entry),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(await manifest.readAsString(), '{not-json');
  });

  test('adopting a same-length changed file requires matching content proof',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-adopt-integrity-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final path = '${root.path}/page.bin';
    final expected = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final changed = Uint8List.fromList(<int>[1, 2, 3, 5]);
    await File(path).writeAsBytes(changed);
    final checksum = (Crc32()..add(expected)).hex;
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:test-src',
        comicId: 'comic-integrity',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.bin'),
    );

    await expectLater(
      service.artifactStore.adoptExistingPageRecord(
        id: id,
        path: path,
        bytes: expected.length,
        checksum: checksum,
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(await service.artifactStore.openArtifactStream(id), isNull);
  });

  test('shared cache bindings charge and release physical bytes once', () async {
    final root = await Directory.systemTemp.createTemp('zic-shared-cache-capacity-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final first = DownloadId(
      content: const ContentId(
        sourceId: 'source', comicId: 'v1', chapterId: 'ch', pageId: 'p'),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v1.webp'),
    );
    final second = DownloadId(
      content: const ContentId(
        sourceId: 'source', comicId: 'v2', chapterId: 'ch', pageId: 'p'),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/v2.webp'),
    );
    await service.storePromotedArtifact(id: first, bytes: bytes);
    final source = await service.artifactStore.index.get(first.key);
    expect(source, isNotNull);
    await service.artifactStore.index.put(
      CacheRec(
        id: second,
        state: CacheState.ready,
        path: source!.path,
        bytes: source.bytes,
        checksum: source.checksum,
        createdUs: source.createdUs,
        touchedUs: source.touchedUs + 1,
        pinned: false,
        checksumAlgorithm: source.checksumAlgorithm,
        artifactId: source.effectiveArtifactId,
        storageRootId: source.storageRootId,
      ),
    );

    final usage = await service.inspectArtifacts();
    expect(usage.entries, 2);
    expect(usage.bytes, bytes.lengthInBytes);

    final cleared = await service.clearArtifacts();
    expect(cleared.releasedBytes, bytes.lengthInBytes);
    expect(cleared.evictedEntries, 1,
        reason: 'one physical artifact was released after both bindings left');
    expect(cleared.remainingBytes, 0);
    expect(await service.artifactStore.index.get(first.key), isNull);
    expect(await service.artifactStore.index.get(second.key), isNull);
  });

  test('cross-version shared physical file is preserved when one version is deleted', () async {
    final tempDir = await Directory.systemTemp.createTemp('zic_delete_safety_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final memoryStorage = <String, Uint8List>{};
    final safIo = _MemorySafIo(memoryStorage);

    final composition = await PersistentDownloadComposition.open(
      tempDir.path,
      safTreeIo: safIo,
      safTreeUri: 'content://tree/downloads',
    );
    addTearDown(composition.close);
    final store = composition.artifactStore;

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final checksum = (Crc32()..add(webpBytes)).hex;
    final sharedPath = 'saf:content%3A%2F%2Ftree%2Fdownloads?path=test_comic%2F001.webp';
    memoryStorage['test_comic/001.webp'] = webpBytes;

    final idV1 = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:ehentai',
        comicId: 'v1',
        chapterId: 'ch1',
        pageId: '0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v1/0.webp'),
    );
    final idV2 = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:ehentai',
        comicId: 'v2',
        chapterId: 'ch1',
        pageId: '0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v2/0.webp'),
    );

    await store.adoptExistingPageRecord(
      id: idV1,
      path: sharedPath,
      bytes: webpBytes.length,
      checksum: checksum,
    );
    await store.adoptExistingPageRecord(
      id: idV2,
      path: sharedPath,
      bytes: webpBytes.length,
      checksum: checksum,
    );

    // Evict v1: physical file in memoryStorage must be preserved because v2 still references it
    await store.evict(idV1);
    expect(memoryStorage['test_comic/001.webp'], isNotNull);
    expect(await store.openArtifactStream(idV2), isNotNull);
    expect(await store.openArtifactStream(idV1), isNull);

    // Evict v2: no other records reference the file, so physical file is now deleted
    await store.evict(idV2);
    expect(memoryStorage['test_comic/001.webp'], isNull);
  });

  test('evicting one bound session does not delete a shared physical artifact',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-shared-session-eviction-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final store = service.artifactStore;
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final first = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:ehentai',
        comicId: 'shared-session-v1',
        chapterId: 'ch1',
        pageId: '0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/shared/v1.webp'),
    );
    final second = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:ehentai',
        comicId: 'shared-session-v2',
        chapterId: 'ch1',
        pageId: '0',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/shared/v2.webp'),
    );

    await store.storePromotedArtifact(id: first, bytes: bytes);
    final firstRecord = await store.index.get(first.key);
    expect(firstRecord, isNotNull);
    await store.adoptExistingPageRecord(
      id: second,
      path: firstRecord!.path,
      bytes: firstRecord.bytes,
      checksum: firstRecord.checksum,
      artifactId: firstRecord.artifactId,
      storageRootId: firstRecord.storageRootId,
    );

    await store.evict(first);

    expect(await store.openArtifactStream(second), isNotNull);
    expect(await File(firstRecord.path).readAsBytes(), bytes);
  });

  test('structured writer isolates versions and rejects forced path collision',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-structured-version-conflict-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final store = service.artifactStore;
    final firstBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 1, 1, 1, 1,
    ]);
    final secondBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 2, 2, 2, 2,
    ]);

    ImportedLibraryEntry entry(String comicId, Uri uri) =>
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'mihon:ehentai:$comicId',
            displayName: '画廊',
            sourceId: 'mihon:ehentai',
            comicId: comicId,
            comicTitle: '同名多版本',
            chapterId: '$comicId-chapter',
            sourceRevision: '$comicId-r1',
            pages: <ImportedPageRecord>[
              ImportedPageRecord(
                displayName: '001.webp',
                sourceId: uri.toString(),
                pageId: '$comicId-page',
                contentKindHint: ContentKindHint.webp,
                byteLength: firstBytes.length,
              ),
            ],
          ),
        );

    DownloadId id(String comicId, Uri uri) => DownloadId(
          content: ContentId(
            sourceId: 'mihon:ehentai',
            comicId: comicId,
            chapterId: '$comicId-chapter',
            pageId: '$comicId-page',
          ),
          sourceRevision: '$comicId-r1',
          canonicalUri: uri,
        );

    final firstUri = Uri.parse('https://example.test/old/001.webp');
    final secondUri = Uri.parse('https://example.test/new/001.webp');
    final firstEntry = entry('old-gallery', firstUri);
    final secondEntry = entry('new-gallery', secondUri);
    final firstId = id('old-gallery', firstUri);
    final secondId = id('new-gallery', secondUri);
    final firstDirectory =
        await store.resolveStructuredComicDirectory(firstEntry);
    final secondDirectory =
        await store.resolveStructuredComicDirectory(secondEntry);
    expect(firstDirectory, '同名多版本');
    expect(secondDirectory, isNot(firstDirectory));
    await store.storePromotedArtifact(id: firstId, bytes: firstBytes);
    await store.storePromotedArtifact(id: secondId, bytes: secondBytes);

    await store.mirrorPromotedToSafIfConfigured(
      firstId,
      entry: firstEntry,
      pageIndex: 1,
      isSingleChapter: true,
      comicDirectoryName: firstDirectory,
    );
    await expectLater(
      store.mirrorPromotedToSafIfConfigured(
        secondId,
        entry: secondEntry,
        pageIndex: 1,
        isSingleChapter: true,
        comicDirectoryName: firstDirectory,
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );

    final exported = File(
      '${store.layout.root}/$firstDirectory/001.webp',
    );
    expect(await exported.readAsBytes(), firstBytes);
    await store.writeComicFolderManifest(
      firstEntry,
      comicDirectoryName: firstDirectory,
    );
    await expectLater(
      store.verifyStructuredDestinationOwner(
        secondEntry,
        comicDirectoryName: firstDirectory,
      ),
      throwsA(isA<Failure>()),
    );
    final manifest = ComicFolderManifest.decode(
      await File(
        '${store.layout.root}/$firstDirectory/$comicManifestFileName',
      ).readAsString(),
    );
    expect(manifest?.comicId, 'old-gallery');

    await store.mirrorPromotedToSafIfConfigured(
      secondId,
      entry: secondEntry,
      pageIndex: 1,
      isSingleChapter: true,
      comicDirectoryName: secondDirectory,
    );
    await store.writeComicFolderManifest(
      secondEntry,
      comicDirectoryName: secondDirectory,
    );
    expect(
      await File(
        '${store.layout.root}/$secondDirectory/001.webp',
      ).readAsBytes(),
      secondBytes,
    );
  });

  test('delete cleanly clears chapter even if download session has active writer', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-delete-busy-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final uri = Uri.parse('https://example.test/delete-busy.webp');
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'test:comic',
        displayName: '第一话',
        sourceId: 'test',
        comicId: 'comic',
        comicTitle: '漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uri.toString(),
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 100,
          ),
        ],
      ),
    );

    // Simulate session having active writer
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'test',
        comicId: 'comic',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final session = service.transferRuntime.registry.get(id);
    await session.restore();
    session.acquireWriter();
    expect(session.hasWriter, isTrue);

    // Calling delete must gracefully reset the writer and successfully delete
    await service.delete(entry);
    expect(await service.isDownloaded(entry), isFalse);
    expect(session.hasWriter, isFalse);
  });

  test('POSIX evict deletes SQLite index record cleanly', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-posix-evict-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final uri = Uri.parse('https://example.test/posix-evict.webp');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'posix-source',
        comicId: 'comic-1',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    await service.artifactStore.storePromotedArtifact(id: id, bytes: webpBytes);
    final recBefore = await service.artifactStore.indexedRecords();
    expect(recBefore.containsKey(id.key), isTrue);

    await service.artifactStore.evict(id);
    final recAfter = await service.artifactStore.indexedRecords();
    expect(recAfter.containsKey(id.key), isFalse);
  });

  test('evict does not delete a binding from another storage root', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-evict-root-');
    final otherRoot = await Directory.systemTemp.createTemp('zic-test-evict-other-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await otherRoot.exists()) await otherRoot.delete(recursive: true);
    });
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final id = _readerArtifactId('historical-root-binding');
    final path = '${otherRoot.path}/final/historical.bin';
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bytes);
    await service.artifactStore.index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: path,
        bytes: bytes.length,
        checksum: (Crc32()..add(bytes)).hex,
        createdUs: 1,
        touchedUs: 1,
        storageRootId: otherRoot.path,
      ),
    );

    await service.artifactStore.evict(id);

    expect(await File(path).readAsBytes(), bytes);
    expect(await service.artifactStore.index.get(id.key), isNotNull);
  });

  test('probeExistingDownloads matches plugin family across sourceId variants', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-probe-plugin-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final uri = Uri.parse('https://example.test/probe-plugin.webp');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:eu.kanade.tachiyomi.extension.zh.ehentai',
        comicId: 'gallery-1',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    await service.artifactStore.storePromotedArtifact(id: id, bytes: webpBytes);

    // Query with different exact sourceId but matching pluginId 'mihon'
    final report = await service.probeExistingDownloads(
      const DownloadExistenceQuery(
        sourceId: 'mihon:eu.kanade.tachiyomi.extension.all.ehentai',
        pluginId: 'mihon',
        comicId: 'gallery-1',
      ),
    );
    expect(report.indexedReadyPages, 1);
  });

  test('claimComicDirectory directs download to pre-claimed structured directory', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-claim-dir-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    final uri = Uri.parse('https://example.test/claim-page.webp');
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:claim-comic',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-claim',
        comicTitle: '通用漫画标题',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uri.toString(),
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    // Explicitly pre-claim custom destination (as chosen in conflict dialog)
    await service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-claim',
      directoryName: '通用漫画标题 (自定义隔离目录)',
    );

    await service.download(entry);
    final targetFile = File(
      '${service.artifactStore.layout.root}/通用漫画标题 (自定义隔离目录)/001.webp',
    );
    expect(await targetFile.exists(), isTrue);
  });

  test('removed placement does not leave an in-process directory reservation',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-placement-refresh-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    await service.claimComicDirectory(
      sourceId: 'mihon:source-a',
      comicId: 'comic-a',
      directoryName: '可复用目录',
    );
    await service.artifactStore.index.removePlacement(
      sourceId: 'mihon:source-a',
      comicId: 'comic-a',
    );

    await service.claimComicDirectory(
      sourceId: 'mihon:source-b',
      comicId: 'comic-b',
      directoryName: '可复用目录',
    );
    expect(
      (await service.getDownloadPlacement(
        sourceId: 'mihon:source-b',
        comicId: 'comic-b',
      ))?.relativeDirectory,
      '可复用目录',
    );
  });

  test('pre-claimed source-specific directory survives service reopen', () async {
    final root = await Directory.systemTemp.createTemp('zic-source-placement-');
    addTearDown(() => root.delete(recursive: true));
    final sourceRoot = '${root.path}/mihon-downloads';
    const sourceId = 'mihon:test-src';
    const comicId = 'comic-source-root';
    const directoryName = '漫画重试标题 (mihon source)';

    Future<PersistentChapterDownloadService> openService() =>
        PersistentChapterDownloadService.open(
          root.path,
          layoutResolver: (id) => id.content.sourceId == sourceId
              ? CacheLayout(sourceRoot)
              : null,
        );

    var service = await openService();
    await service.claimComicDirectory(
      sourceId: sourceId,
      comicId: comicId,
      directoryName: directoryName,
    );
    await service.close();

    service = await openService();
    addTearDown(service.close);
    final placement = await service.getDownloadPlacement(
      sourceId: sourceId,
      comicId: comicId,
    );
    expect(placement?.relativeDirectory, directoryName);
    expect(placement?.storageRootId, sourceRoot);
  });

  test('persisted placement reserves an empty directory after restart', () async {
    final root = await Directory.systemTemp.createTemp('zic-placement-reservation-');
    addTearDown(() => root.delete(recursive: true));
    var service = await PersistentChapterDownloadService.open(root.path);
    await service.claimComicDirectory(
      sourceId: 'mihon:source-a',
      comicId: 'comic-a',
      directoryName: '空目录保留',
    );
    await service.close();

    service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    await expectLater(
      service.claimComicDirectory(
        sourceId: 'mihon:source-b',
        comicId: 'comic-b',
        directoryName: '空目录保留',
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );
  });

  test('deleted comic folder without records yields clean base directory on new download', () async {
    final root = await Directory.systemTemp.createTemp('zic-placement-clean-');
    addTearDown(() => root.delete(recursive: true));
    var service = await PersistentChapterDownloadService.open(root.path);
    await service.artifactStore.index.putPlacement(
      DownloadPlacement(
        placementId: 'venera:ehentai\u0000comic-v1',
        sourceId: 'venera:ehentai',
        comicId: 'comic-v1',
        comicTitle: 'Ani Collections',
        mode: DownloadPlacementMode.createNew,
        relativeDirectory: 'Ani Collections (venera_ehentai-fff908ad)',
        storageRootId: 'default',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await service.close();

    service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:comic-v2',
        displayName: '第一话',
        sourceId: 'venera:ehentai',
        comicId: 'comic-v2',
        comicTitle: 'Ani Collections',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/p1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 100,
          ),
        ],
      ),
    );

    final resolvedDir = await service.artifactStore.resolveStructuredComicDirectory(entry);
    expect(resolvedDir, equals('Ani Collections'));
  });

  test('legacy indexed records recover placement without scanning files on retry', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-retry-dir-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    var service = await PersistentChapterDownloadService.open(root.path);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    final uri = Uri.parse('https://example.test/page1.webp');
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-v2',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-v2',
        comicTitle: '漫画重试标题',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uri.toString(),
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    // Initial claim to isolated directory (e.g. from conflict resolution)
    await service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-v2',
      directoryName: '漫画重试标题 (mihon 2)',
    );    await service.download(entry);
    await service.artifactStore.index.removePlacement(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
    );
    await service.close();

    // Reopen service (simulating app restart)
    service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final resolvedDir = await service.artifactStore.resolveStructuredComicDirectory(entry);
    expect(resolvedDir, '漫画重试标题 (mihon 2)');
    final placement = await service.getDownloadPlacement(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
    );
    expect(placement?.mode, DownloadPlacementMode.incremental);
  });

  test('cross-version verified equivalence reuses downloaded pages and computes progress', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-cross-ver-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    var networkCalls = 0;
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return webpBytes;
      }),
    );

    // Version A: gallery 1001 with image key 7d8a9b1c
    final uriA = Uri.parse('https://e-hentai.org/s/7d8a9b1c/1001-1');
    final entryA = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:1001',
        displayName: '第一话',
        sourceId: 'mihon:ehentai',
        comicId: '1001',
        comicTitle: '多版本测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uriA.toString(),
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );
    await service.download(entryA);
    expect(networkCalls, 1);

    // Version B: gallery 2002 with SAME image key 7d8a9b1c
    final uriB = Uri.parse('https://e-hentai.org/s/7d8a9b1c/2002-1');
    final entryB = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:2002',
        displayName: '第一话',
        sourceId: 'mihon:ehentai',
        comicId: '2002',
        comicTitle: '多版本测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: uriB.toString(),
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    // Snapshot should recognize Version B's page as already available via verified equivalence
    final snapshotB = await service.inspect(entryB);
    expect(await service.readyPageIndices(entryB), <int>{0});
    expect(snapshotB.completedPages, 1);
    expect(snapshotB.exactCompletedPages, 0);
    expect(snapshotB.reusablePages, 1);
    expect(snapshotB.receivedBytes, webpBytes.length);
    expect(snapshotB.isComplete, isFalse);

    // Downloading Version B should adopt the equivalent artifact with ZERO new network calls
    await service.download(entryB);
    expect(networkCalls, 1);
    expect(await service.isDownloaded(entryB), isTrue);
  });

  test('DownloadPlacement overwrite mode allows overwriting structured directory with updated manifest', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-placement-overwrite-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    // Initial download for Comic 1
    final entry1 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:c1',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'c1',
        comicTitle: '覆盖测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/c1/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );
    await service.download(entry1);

    // Now Comic 2 claims the same directory with DownloadPlacementMode.overwrite
    final entry2 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:c2',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'c2',
        comicTitle: '覆盖测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/c2/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );
    await service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'c2',
      comicTitle: '覆盖测试漫画',
      directoryName: '覆盖测试漫画',
      mode: DownloadPlacementMode.overwrite,
      observedOwnerKey: 'mihon:test-src\u0000c1',
    );
    // Download should succeed under overwrite placement without failure
    await service.download(entry2);
    expect(await service.isDownloaded(entry2), isTrue);
  });

  test('DownloadPlacement unauthorized collision throws Failure with policy code instead of artifactCorruption', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-placement-collision-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    // Initial download for Comic 1 into '冲突漫画'
    final entry1 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:c1',
        displayName: '第一话',
        sourceId: 'mihon:src-a',
        comicId: 'c1',
        comicTitle: '冲突漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );
    await service.download(entry1);

    // Comic 2 forced into Comic 1's directory without overwrite permission
    final entry2 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:c2',
        displayName: '第一话',
        sourceId: 'mihon:src-b',
        comicId: 'c2',
        comicTitle: '冲突漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/2.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    expect(
      () => service.artifactStore.verifyStructuredDestinationOwner(
        entry2,
        comicDirectoryName: '冲突漫画',
      ),
      throwsA(
        isA<Failure>().having((f) => f.code, 'code', ErrorCode.policy),
      ),
    );
  });

  test('multi-version shared downloads: deleting old version preserves shared files, deleting new version deletes only exclusive files', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-multiversion-delete-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    // Version A: 10 pages (hex hashes '00000000000000000000000000000001' .. '00000000000000000000000000000010')
    final entryA = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-a',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-a',
        comicTitle: '版本A',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          10,
          (i) {
            final hex = (i + 1).toRadixString(16).padLeft(32, '0');
            return ImportedPageRecord(
              displayName: '${(i + 1).toString().padLeft(3, '0')}.webp',
              sourceId: 'https://example.com/a/$hex.webp',
              pageId: 'p_${i + 1}',
              contentKindHint: ContentKindHint.webp,
              byteLength: webpBytes.length,
            );
          },
        ),
      ),
    );

    // Version B: 30 pages (pages 1..20 exclusive hashes, pages 21..30 match Version A hashes)
    final entryB = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-b',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-b',
        comicTitle: '版本B',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          30,
          (i) {
            final pageNum = i + 1;
            final hex = pageNum > 20
                ? (pageNum - 20).toRadixString(16).padLeft(32, '0')
                : (pageNum + 100).toRadixString(16).padLeft(32, '0');
            return ImportedPageRecord(
              displayName: '${pageNum.toString().padLeft(3, '0')}.webp',
              sourceId: 'https://example.com/b/$hex.webp',
              pageId: 'p_$pageNum',
              contentKindHint: ContentKindHint.webp,
              byteLength: webpBytes.length,
            );
          },
        ),
      ),
    );

    // 1. Download Version A
    await service.download(entryA);
    expect(await service.isDownloaded(entryA), isTrue);

    // 2. Download Version B (should adopt 10 pages from Version A)
    await service.download(entryB);
    expect(await service.isDownloaded(entryB), isTrue);

    // Check all 30 pages of Version B are readable
    final manifestB = entryB.chapter.toManifest();
    for (final p in manifestB.pages) {
      final id = DownloadId(
        content: ContentId(
          sourceId: 'mihon:test-src',
          comicId: 'comic-b',
          chapterId: 'ch1',
          pageId: p.pageId,
        ),
        sourceRevision: 'r1',
        canonicalUri: p.uri,
      );
      final stream = await service.artifactStore.openArtifactStream(id);
      expect(stream, isNotNull, reason: 'Version B page ${p.pageId} should be readable');
    }

    // 3. Test deleting Version A: Version B must remain 100% complete and intact
    await service.delete(entryA);
    expect(await service.isDownloaded(entryA), isFalse);
    expect(await service.isDownloaded(entryB), isTrue);

    for (final p in manifestB.pages) {
      final id = DownloadId(
        content: ContentId(
          sourceId: 'mihon:test-src',
          comicId: 'comic-b',
          chapterId: 'ch1',
          pageId: p.pageId,
        ),
        sourceRevision: 'r1',
        canonicalUri: p.uri,
      );
      final stream = await service.artifactStore.openArtifactStream(id);
      expect(stream, isNotNull, reason: 'Version B page ${p.pageId} must survive Version A deletion');
    }
  });

  test('multi-version shared downloads: deleting new version deletes exclusive files and preserves old version', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-multiversion-del-b-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => webpBytes),
    );

    // Version A: 10 pages (hex hashes '00000000000000000000000000000001' .. '00000000000000000000000000000010')
    final entryA = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-a',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-a',
        comicTitle: '版本A',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          10,
          (i) {
            final hex = (i + 1).toRadixString(16).padLeft(32, '0');
            return ImportedPageRecord(
              displayName: '${(i + 1).toString().padLeft(3, '0')}.webp',
              sourceId: 'https://example.com/a/$hex.webp',
              pageId: 'p_${i + 1}',
              contentKindHint: ContentKindHint.webp,
              byteLength: webpBytes.length,
            );
          },
        ),
      ),
    );

    // Version B: 30 pages (pages 1..20 exclusive hashes, pages 21..30 match Version A hashes)
    final entryB = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-b',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-b',
        comicTitle: '版本B',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          30,
          (i) {
            final pageNum = i + 1;
            final hex = pageNum > 20
                ? (pageNum - 20).toRadixString(16).padLeft(32, '0')
                : (pageNum + 100).toRadixString(16).padLeft(32, '0');
            return ImportedPageRecord(
              displayName: '${pageNum.toString().padLeft(3, '0')}.webp',
              sourceId: 'https://example.com/b/$hex.webp',
              pageId: 'p_$pageNum',
              contentKindHint: ContentKindHint.webp,
              byteLength: webpBytes.length,
            );
          },
        ),
      ),
    );

    // 1. Download both versions
    await service.download(entryA);
    await service.download(entryB);

    // 2. Delete Version B
    await service.delete(entryB);
    expect(await service.isDownloaded(entryB), isFalse);
    expect(await service.isDownloaded(entryA), isTrue);

    // 3. Verify Version A is 100% complete and readable
    final manifestA = entryA.chapter.toManifest();
    for (final p in manifestA.pages) {
      final id = DownloadId(
        content: ContentId(
          sourceId: 'mihon:test-src',
          comicId: 'comic-a',
          chapterId: 'ch1',
          pageId: p.pageId,
        ),
        sourceRevision: 'r1',
        canonicalUri: p.uri,
      );
      final stream = await service.artifactStore.openArtifactStream(id);
      expect(stream, isNotNull, reason: 'Version A page ${p.pageId} must survive Version B deletion');
    }
  });

  test('overwrite claim replaces the displaced durable placement owner', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-overwrite-placement-');
    addTearDown(() => root.delete(recursive: true));
    var service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    const oldSourceId = 'mihon:old-source';
    const oldComicId = 'old-comic';
    const newSourceId = 'mihon:new-source';
    const newComicId = 'new-comic';
    const directoryName = '测试漫画';
    final oldOwner = '$oldSourceId\u0000$oldComicId';

    await service.claimComicDirectory(
      sourceId: oldSourceId,
      comicId: oldComicId,
      comicTitle: directoryName,
      directoryName: directoryName,
      mode: DownloadPlacementMode.createNew,
    );
    await service.claimComicDirectory(
      sourceId: newSourceId,
      comicId: newComicId,
      comicTitle: directoryName,
      directoryName: directoryName,
      mode: DownloadPlacementMode.overwrite,
      observedOwnerKey: oldOwner,
    );

    expect(
      await service.getDownloadPlacement(
        sourceId: oldSourceId,
        comicId: oldComicId,
      ),
      isNull,
    );
    expect(
      await service.getDownloadPlacement(
        sourceId: newSourceId,
        comicId: newComicId,
      ),
      isNotNull,
    );

    await service.close();
    service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    expect(
      await service.getDownloadPlacement(
        sourceId: oldSourceId,
        comicId: oldComicId,
      ),
      isNull,
    );
    expect(
      await service.getDownloadPlacement(
        sourceId: newSourceId,
        comicId: newComicId,
      ),
      isNotNull,
    );
  });

  test('overwrite mode refuses to replace a target still bound to another owner',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-test-overwrite-shared-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final oldBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 1, 1, 1,
    ]);
    final newBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x16, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 2, 2, 2, 2, 2, 2,
    ]);
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:old-source',
        comicId: 'old-comic',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final otherId = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:other-source',
        comicId: 'other-comic',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/other.webp'),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:new-source',
        comicId: 'new-comic',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/new.webp'),
    );
    final target = File('${root.path}/offline_chapters/共享漫画/001.webp');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(oldBytes);
    final oldChecksum = (Crc32()..add(oldBytes)).hex;
    final newChecksum = (Crc32()..add(newBytes)).hex;
    await service.artifactStore.index.put(
      CacheRec(
        id: oldId,
        state: CacheState.ready,
        path: target.path,
        bytes: oldBytes.length,
        checksum: oldChecksum,
        checksumAlgorithm: 'crc32',
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'old-artifact',
        storageRootId: root.path,
      ),
    );
    await service.artifactStore.index.put(
      CacheRec(
        id: otherId,
        state: CacheState.ready,
        path: target.path,
        bytes: oldBytes.length,
        checksum: (Crc32()..add(<int>[9, 9, 9, 9])).hex,
        checksumAlgorithm: 'crc32',
        createdUs: 2,
        touchedUs: 2,
        artifactId: 'other-artifact',
        storageRootId: root.path,
      ),
    );
    final staging = File('${root.path}/staging/new.bin');
    await staging.parent.create(recursive: true);
    await staging.writeAsBytes(newBytes);
    await service.artifactStore.adoptExistingPageRecord(
      id: newId,
      path: staging.path,
      bytes: newBytes.length,
      checksum: newChecksum,
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:new-comic',
        displayName: '第一话',
        sourceId: 'mihon:new-source',
        comicId: 'new-comic',
        comicTitle: '共享漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/new.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    await service.claimComicDirectory(
      sourceId: 'mihon:new-source',
      comicId: 'new-comic',
      comicTitle: '共享漫画',
      directoryName: '共享漫画',
      mode: DownloadPlacementMode.overwrite,
      observedOwnerKey: 'mihon:old-source\u0000old-comic',
    );

    await expectLater(
      service.artifactStore.mirrorPromotedToSafIfConfigured(
        newId,
        entry: entry,
        pageIndex: 1,
        isSingleChapter: true,
        comicDirectoryName: '共享漫画',
      ),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.policy,
      )),
    );
    expect(await target.readAsBytes(), oldBytes);
    expect(await service.artifactStore.index.get(otherId.key), isNotNull);
  });

  test('overwrite mode does not blindly adopt non-matching files from disk and overwrites cleanly', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-overwrite-content-');
    addTearDown(() => root.delete(recursive: true));
    final oldBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 1, 1, 1,
    ]);
    final newBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x16, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 2, 2, 2, 2, 2, 2,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async => newBytes),
    );

    // Create old file in structured destination
    final comicDir = Directory('${service.artifactStore.layout.root}/测试漫画');
    await comicDir.create(recursive: true);
    final oldFile = File('${comicDir.path}/001.webp');
    await oldFile.writeAsBytes(oldBytes);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-overwrite',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-overwrite',
        comicTitle: '测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: newBytes.length,
          ),
        ],
      ),
    );

    // Claim directory with overwrite mode
    await service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-overwrite',
      comicTitle: '测试漫画',
      directoryName: '测试漫画',
      mode: DownloadPlacementMode.overwrite,
      observedOwnerKey: 'old-src\u0000old-comic',
    );

    // Download should overwrite old file and not blindly adopt old bytes
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);

    final downloadedBytes = await oldFile.readAsBytes();
    expect(downloadedBytes, equals(newBytes));
  });

  test('createNew mode materializes adopted sibling pages into its own target directory', () async {
    final root = await Directory.systemTemp.createTemp('zic-test-createnew-materialize-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 9, 9, 9, 9,
    ]);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    var networkCalls = 0;
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return webpBytes;
      }),
    );

    final entryV1 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:v1',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-v1',
        comicTitle: '漫画V1',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/shared_0123456789abcdef0123456789abcdef.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    final entryV2 = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:v2',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-v2',
        comicTitle: '漫画V2',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.com/shared_0123456789abcdef0123456789abcdef.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );

    service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-v1',
      comicTitle: '漫画V1',
      directoryName: '漫画V1',
      mode: DownloadPlacementMode.createNew,
    );
    service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-v2',
      comicTitle: '漫画V2',
      directoryName: '漫画V2',
      mode: DownloadPlacementMode.createNew,
    );

    await service.download(entryV1);
    await service.download(entryV2);
    expect(networkCalls, 1);

    // Verify V2 file physically exists in 漫画V2 directory
    final v2File = File('${service.artifactStore.layout.root}/漫画V2/001.webp');
    expect(await v2File.exists(), isTrue);
    expect(
      await File('${service.artifactStore.layout.root}/漫画V2/000.webp').exists(),
      isFalse,
    );
    expect(await v2File.readAsBytes(), webpBytes);

    // Delete V1 and ensure V2 is still 100% readable and independent
    await service.delete(entryV1);
    expect(await service.isDownloaded(entryV2), isTrue);
    expect(await v2File.exists(), isTrue);
  });

  test('SAF sibling materialization removes partial target when close fails',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-test-saf-materialize-close-',
    );
    addTearDown(() => root.delete(recursive: true));
    final safStorage = <String, Uint8List>{};
    final safIo = _MemorySafIo(safStorage);
    final service = await PersistentChapterDownloadService.open(
      root.path,
      safTreeIo: safIo,
      safTreeUri: 'content://tree/downloads',
    );
    addTearDown(service.close);
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 7, 7, 7, 7,
    ]);
    final source = File('${root.path}/sibling.webp');
    await source.writeAsBytes(bytes);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'mihon:test-src',
        comicId: 'comic-v1',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/shared.webp'),
    );
    final sibling = await service.artifactStore.adoptExistingPageRecord(
      id: id,
      path: source.path,
      bytes: bytes.lengthInBytes,
      checksum: (Crc32()..add(bytes)).hex,
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:comic-v2',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-v2',
        comicTitle: '漫画V2',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/shared.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    service.claimComicDirectory(
      sourceId: 'mihon:test-src',
      comicId: 'comic-v2',
      comicTitle: '漫画V2',
      directoryName: '漫画V2',
      mode: DownloadPlacementMode.createNew,
    );

    safIo.failNextClose = true;
    await expectLater(
      service.artifactStore.materializeSiblingToDestinationIfSeparate(
        siblingRecord: sibling,
        entry: entry,
        pageNumber: 1,
        isSingleChapter: true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(safStorage.containsKey('漫画V2/001.webp'), isFalse);
  });

  test('download placement alone never pins a later Reader cache page', () async {
    final root = await Directory.systemTemp.createTemp('zic-auto-pin-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:auto-pin',
        displayName: '第一话',
        sourceId: 'mihon:test-src',
        comicId: 'comic-auto-pin',
        comicTitle: '自动转下载漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/page1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 32,
          ),
        ],
      ),
    );

    // Pre-claim download placement for this comic
    service.claimComicDirectory(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      directoryName: '自动转下载漫画',
    );

    final id = DownloadId(
      content: ContentId(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
        pageId: entry.chapter.pages.first.pageId!,
      ),
      sourceRevision: entry.chapter.sourceRevision,
      canonicalUri: Uri.parse('https://example.test/page1.webp'),
    );

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
      0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
      0x00, 0x07, 0x08, 0x85, 0x88, 0x88, 0x08, 0x00,
    ]);
    await service.storePromotedArtifact(id: id, bytes: webpBytes);

    var rec = await service.artifactStore.index.get(id.key);
    expect(rec, isNotNull);
    expect(rec!.pinned, isFalse,
        reason: 'placement chooses an export destination, not retention intent');

    var snapshot = await service.inspect(entry);
    expect(snapshot.pinnedPages, 0);
    expect(snapshot.isManualDownload, isFalse);
    expect(snapshot.hasAutoCache, isTrue);

    final cleared = await service.clearArtifacts();
    expect(cleared.releasedBytes, webpBytes.lengthInBytes,
        reason: 'placement alone must not protect Reader cache from clear');
    expect(await service.artifactStore.index.get(id.key), isNull);

    // Recreate the same Reader cache so the explicit command can demonstrate
    // the only production transition that adds durable retention.
    await service.storePromotedArtifact(id: id, bytes: webpBytes);

    // The explicit download command converts this exact cached binding into
    // an offline retained page without needing placement to act as a pin.
    await service.download(entry);
    rec = await service.artifactStore.index.get(id.key);
    expect(rec, isNotNull);
    expect(rec!.pinned, isTrue);
    snapshot = await service.inspect(entry);
    expect(snapshot.pinnedPages, 1);
    expect(snapshot.isComplete, isTrue);
  });

  test('explicit download pins only the current exact revision', () async {
    final root = await Directory.systemTemp.createTemp('zic-exact-pin-scope-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    const sourceId = 'mihon:test-src';
    const comicId = 'pin-scope-comic';
    const chapterId = 'ch1';
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
      0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
      0x00, 0x07, 0x08, 0x85, 0x88, 0x88, 0x08, 0x00,
    ]);
    await service.claimComicDirectory(
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: 'Pin Scope',
      directoryName: 'Pin Scope',
    );
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        pageId: 'old-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final currentId = DownloadId(
      content: const ContentId(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        pageId: 'current-page',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/current.webp'),
    );
    await service.storePromotedArtifact(id: oldId, bytes: bytes);
    await service.storePromotedArtifact(id: currentId, bytes: bytes);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
    expect((await service.artifactStore.index.get(currentId.key))!.pinned, isFalse);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'mihon:pin-scope',
        displayName: '第一话',
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: 'Pin Scope',
        chapterId: chapterId,
        sourceRevision: 'r2',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/current.webp',
            pageId: 'current-page',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );

    await service.download(entry);

    expect((await service.artifactStore.index.get(currentId.key))!.pinned, isTrue);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse,
        reason: 'chapter id and placement do not confer current download intent');
  });

  test('same pageId from another revision never proves target page reuse', () async {
    final root = await Directory.systemTemp.createTemp('zic-pageid-revision-proof-');
    addTearDown(() => root.delete(recursive: true));
    final oldBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 1, 1, 1, 1,
    ]);
    final newBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 2, 2, 2, 2,
    ]);
    var networkCalls = 0;
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return newBytes;
      }),
    );

    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'venera:test',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'same-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('venera-resource:old-revision-page'),
    );
    await service.storePromotedArtifact(id: oldId, bytes: oldBytes);

    final target = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:test:comic',
        displayName: '第一话',
        sourceId: 'venera:test',
        comicId: 'comic',
        comicTitle: 'Revision Identity',
        chapterId: 'chapter',
        sourceRevision: 'r2',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'venera-resource:new-revision-page',
            pageId: 'same-page',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );

    await service.download(target);
    expect(networkCalls, 1);
    expect(await service.readPage(target, 0), newBytes);
  });

  test('version page proof is invalid when predecessor revision changed', () async {
    final root = await Directory.systemTemp.createTemp('zic-version-proof-revision-');
    addTearDown(() => root.delete(recursive: true));
    final oldBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 3, 3, 3, 3,
    ]);
    final newBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 4, 4, 4, 4,
    ]);
    var networkCalls = 0;
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(loadBytes: (_, __) async {
        networkCalls++;
        return networkCalls == 1 ? oldBytes : newBytes;
      }),
    );

    final oldEntry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:old',
        displayName: '第一话',
        sourceId: 'venera:test',
        comicId: 'old',
        comicTitle: 'Old',
        chapterId: 'chapter',
        sourceRevision: 'old-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'venera-resource:old-page',
            pageId: 'old-page',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );
    final newEntry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:new',
        displayName: '第一话',
        sourceId: 'venera:test',
        comicId: 'new',
        comicTitle: 'New',
        chapterId: 'chapter',
        sourceRevision: 'new-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'venera-resource:new-page',
            pageId: 'new-page',
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    );

    await service.download(oldEntry);
    expect(networkCalls, 1);
    service.updateVersionBaselines(const <ComicVersionRelation>[
      ComicVersionRelation(
        sourceId: 'venera:test',
        predecessorComicId: 'old',
        successorComicId: 'new',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'chapter',
            successorChapterId: 'chapter',
            predecessorPageCount: 1,
            successorPageCount: 1,
            successorOffset: 0,
            predecessorSourceRevision: 'old-r0',
            successorSourceRevision: 'new-r1',
            verifiedPredecessorPageIndexes: <int>[0],
          ),
        ],
      ),
    ]);

    await service.download(newEntry);
    expect(networkCalls, 2,
        reason: 'a proof for old-r0 must not adopt the old-r1 artifact');
    expect(await service.readPage(newEntry, 0), newBytes);
  });

  test('cross-version download with offset adopts predecessor pages in chronological order', () async {
    final root = await Directory.systemTemp.createTemp('zic-offset-adopt-test-');
    addTearDown(() => root.delete(recursive: true));
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    var networkCalls = 0;
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    service.setChapterResourceAccess(
      ChapterResourceAccess(
        loadBytes: (_, __) async {
          networkCalls++;
          return webpBytes;
        },
      ),
    );

    // Version Old: 3 pages (opaque URIs as in Venera/E-Hentai)
    final entryOld = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:old',
        displayName: '第一话',
        sourceId: 'venera:ehentai',
        comicId: 'comic-old',
        comicTitle: '漫画 旧版',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          3,
          (i) => ImportedPageRecord(
            displayName: '${(i + 1).toString().padLeft(3, '0')}.webp',
            sourceId: 'venera-resource:old_token_$i',
            pageId: 'p_${i + 1}',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ),
      ),
    );

    // Version New: 5 pages (pages 0,1 are new, pages 2,3,4 match old pages 0,1,2 with offset 2)
    final entryNew = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'venera:new',
        displayName: '第一话',
        sourceId: 'venera:ehentai',
        comicId: 'comic-new',
        comicTitle: '漫画 新版',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: List.generate(
          5,
          (i) => ImportedPageRecord(
            displayName: '${(i + 1).toString().padLeft(3, '0')}.webp',
            sourceId: 'venera-resource:new_token_$i',
            pageId: 'p_${i + 1}',
            contentKindHint: ContentKindHint.webp,
            byteLength: webpBytes.length,
          ),
        ),
      ),
    );

    service.updateVersionBaselines(<ComicVersionRelation>[
      const ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'comic-old',
        successorComicId: 'comic-new',
        predecessorTitle: '漫画 旧版',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'ch1',
            successorChapterId: 'ch1',
            successorOffset: 2,
            predecessorPageCount: 3,
            successorPageCount: 5,
            predecessorSourceRevision: 'r1',
            successorSourceRevision: 'r1',
            verifiedPredecessorPageIndexes: <int>[0, 1, 2],
          ),
        ],
      ),
    ]);

    // Download old version first: 3 pages -> 3 network calls
    await service.download(entryOld);
    expect(await service.isDownloaded(entryOld), isTrue);
    expect(networkCalls, 3);

    final reusableBeforeDownload = await service.inspect(entryNew);
    expect(await service.readyPageIndices(entryNew), <int>{2, 3, 4});
    expect(reusableBeforeDownload.completedPages, 3);
    expect(reusableBeforeDownload.exactCompletedPages, 0);
    expect(reusableBeforeDownload.reusablePages, 3);
    expect(reusableBeforeDownload.isComplete, isFalse);

    // Download new version: only 2 new pages should hit network, 3 adopted!
    await service.download(entryNew);
    expect(await service.isDownloaded(entryNew), isTrue);
    expect(networkCalls, 5); // 3 (old) + 2 (new) = 5 calls total!

    // Verify all 5 pages of new version are readable
    for (var i = 0; i < 5; i++) {
      final page = await service.readPage(entryNew, i);
      expect(page, isNotEmpty);
    }
  });

  test('unpinned auto-cached chapter snapshot remains idle and hasAutoCache true', () async {
    final root = await Directory.systemTemp.createTemp('zic-autocache-idle-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'lib:ch1',
        displayName: '第一话',
        sourceId: 'src1',
        comicId: 'comic1',
        comicTitle: '漫画1',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.webp,
            byteLength: 100,
          ),
          ImportedPageRecord(
            displayName: '002.webp',
            sourceId: 'https://example.test/2.webp',
            pageId: 'p2',
            contentKindHint: ContentKindHint.webp,
            byteLength: 100,
          ),
        ],
      ),
    );

    final p1Id = DownloadId(
      content: const ContentId(
        sourceId: 'src1',
        comicId: 'comic1',
        chapterId: 'ch1',
        pageId: 'p1',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/1.webp'),
    );
    final p2Id = DownloadId(
      content: const ContentId(
        sourceId: 'src1',
        comicId: 'comic1',
        chapterId: 'ch1',
        pageId: 'p2',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/2.webp'),
    );

    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);

    await service.storePromotedArtifact(id: p1Id, bytes: webpBytes);
    await service.storePromotedArtifact(id: p2Id, bytes: webpBytes);

    final snapshot = await service.inspect(entry);
    expect(snapshot.completedPages, 2);
    expect(snapshot.totalPages, 2);
    expect(snapshot.pinnedPages, 0);
    expect(snapshot.autoCachedPages, 2);
    expect(snapshot.phase, ChapterDownloadPhase.idle);
    expect(snapshot.isManualDownload, isFalse);
    expect(snapshot.hasAutoCache, isTrue);

    // After initiating explicit manual download, it transitions to complete and manual
    await service.download(entry);
    final manualSnapshot = await service.inspect(entry);
    expect(manualSnapshot.phase, ChapterDownloadPhase.complete);
    expect(manualSnapshot.isManualDownload, isTrue);
    expect(manualSnapshot.hasAutoCache, isFalse);
  });

  test('structured materialization sniffs image bytes when hint is unknown',
      () async {
    final root = await Directory.systemTemp.createTemp('unknown-image-sniff-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final webpBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'lib:unknown-image',
        displayName: '第一话',
        sourceId: 'venera:ehentai',
        comicId: 'unknown-image-comic',
        comicTitle: '未知格式漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.bin',
            sourceId: 'https://example.test/unknown-image',
            pageId: 'p1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: webpBytes.length,
          ),
        ],
      ),
    );
    final id = DownloadId(
      content: ContentId(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
        pageId: 'p1',
      ),
      sourceRevision: entry.chapter.sourceRevision,
      canonicalUri: Uri.parse('https://example.test/unknown-image'),
    );
    await service.storePromotedArtifact(id: id, bytes: webpBytes);
    await service.artifactStore.mirrorPromotedToSafIfConfigured(
      id,
      entry: entry,
      pageIndex: 1,
      isSingleChapter: true,
    );

    final record = await service.artifactStore.index.get(id.key);
    expect(record, isNotNull);
    expect(record!.path, endsWith('/未知格式漫画/001.webp'));
    expect(await File(record.path).readAsBytes(), webpBytes);
  });

  test('mirrorPromotedToSafIfConfigured rejects non-image .bin payload for structured download', () async {
    final root = await Directory.systemTemp.createTemp('bin-reject-test-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'lib:ch1',
        displayName: '第一话',
        sourceId: 'venera:ehentai',
        comicId: 'comic1',
        comicTitle: '测试漫画',
        chapterId: 'ch1',
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '001.webp',
            sourceId: 'https://example.test/1.webp',
            pageId: 'p1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 20,
          ),
        ],
      ),
    );

    final id = DownloadId(
      content: ContentId(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
        pageId: 'p1',
      ),
      sourceRevision: entry.chapter.sourceRevision,
      canonicalUri: Uri.parse('https://example.test/1.webp'),
    );

    await service.artifactStore.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03, 0x04]),
    );
    await service.transferRuntime.persistPromoted(id);

    await expectLater(
      service.artifactStore.mirrorPromotedToSafIfConfigured(
        id,
        entry: entry,
        pageIndex: 1,
        isSingleChapter: true,
      ),
      throwsA(isA<Failure>().having((f) => f.code, 'code', ErrorCode.artifactCorruption)),
    );
    final rec = await service.artifactStore.index.get(id.key);
    expect(rec != null && await File(rec.path).exists(), isFalse);
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

final class _MemorySafIo implements SafTreeIo {
  _MemorySafIo(this.storage);

  final Map<String, Uint8List> storage;
  final Map<int, ({String path, int pos})> _handles =
      <int, ({String path, int pos})>{};
  int _nextHandle = 1;
  int listCalls = 0;
  final List<String> readPaths = <String>[];
  bool failNextClose = false;

  @override
  Future<int?> open(String relativePath, {SafWriteMode? mode}) async {
    if (!storage.containsKey(relativePath)) {
      if (mode == SafWriteMode.writeTruncate || mode == SafWriteMode.writeAppend) {
        storage[relativePath] = Uint8List(0);
      } else {
        return null;
      }
    }
    final handle = _nextHandle++;
    final initialPos = mode == SafWriteMode.writeAppend
        ? storage[relativePath]!.lengthInBytes
        : 0;
    _handles[handle] = (path: relativePath, pos: initialPos);
    return handle;
  }

  @override
  Future<Uint8List> read(int handle, int length) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid handle');
    readPaths.add(state.path);
    final bytes = storage[state.path]!;
    final start = state.pos;
    final end = (start + length).clamp(0, bytes.lengthInBytes);
    _handles[handle] = (path: state.path, pos: end);
    return Uint8List.fromList(bytes.sublist(start, end));
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid handle');
    final existing = storage[state.path] ?? Uint8List(0);
    final builder = BytesBuilder(copy: false);
    builder.add(existing.sublist(0, state.pos));
    builder.add(bytes);
    storage[state.path] = builder.takeBytes();
    _handles[handle] = (path: state.path, pos: state.pos + bytes.lengthInBytes);
  }

  @override
  Future<int?> length(int handle) async {
    final state = _handles[handle];
    if (state == null) return null;
    return storage[state.path]?.lengthInBytes ?? 0;
  }

  @override
  Future<void> seek(int handle, int position) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid handle');
    _handles[handle] = (path: state.path, pos: position);
  }

  @override
  Future<void> close(int handle) async {
    _handles.remove(handle);
    if (failNextClose) {
      failNextClose = false;
      throw StateError('simulated SAF close failure');
    }
  }

  @override
  Future<bool> delete(String relativePath) async =>
      storage.remove(relativePath) != null;

  @override
  Future<bool> rename(String relativePath, String newRelativePath) async {
    if (storage.containsKey(newRelativePath) ||
        !storage.containsKey(relativePath)) {
      return false;
    }
    storage[newRelativePath] = storage.remove(relativePath)!;
    return true;
  }

  @override
  Future<bool> exists(String relativePath) async =>
      storage.containsKey(relativePath);

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    listCalls++;
    final prefix = relativePath.isEmpty ? '' : '$relativePath/';
    final result = <SafTreeFile>[];
    final seen = <String>{};
    for (final path in storage.keys) {
      if (prefix.isEmpty) {
        final segments = path.split('/');
        if (segments.length > 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(name: segments.first, isDirectory: true, length: 0),
          );
        }
      } else if (path.startsWith(prefix)) {
        final sub = path.substring(prefix.length);
        final segments = sub.split('/');
        if (segments.length == 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(
              name: segments.first,
              isDirectory: false,
              length: storage[path]?.lengthInBytes ?? 0,
            ),
          );
        } else if (segments.length > 1 && seen.add(segments.first)) {
          result.add(
            SafTreeFile(name: segments.first, isDirectory: true, length: 0),
          );
        }
      }
    }
    return result;
  }
}
