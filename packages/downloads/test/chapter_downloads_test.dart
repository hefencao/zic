import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('chapter resource access rejects an empty binding', () {
    expect(ChapterResourceAccess.new, throwsArgumentError);
  });

  test('managed chapter service is a cache-maintenance capability', () async {
    final ManagedChapterDownloadService service =
        MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(0),
    );
    addTearDown(service.close);

    final coordinator = ResourceCacheCoordinator(artifacts: service);
    addTearDown(coordinator.close);
    final usage = await coordinator.inspect();

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

  test('persistent chapter download survives reopen and serves page bytes',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-chapter-download-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
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
