import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_downloads.dart';
import 'package:zic/download_manager.dart';
import 'package:zic/whole_comic_downloads.dart';

void main() {
  test('memory chapter download owns bytes before reporting completion', () async {
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

  test('memory download publishes progress and delete returns to idle', () async {
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

  test('memory download cancellation keeps partial progress and retry completes',
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
    final service = MemoryChapterDownloadService(
      pageLoader: (_, index) async {
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

    await service.retry(entry);
    final complete = await service.inspect(entry);
    expect(complete.phase, ChapterDownloadPhase.complete);
    expect(complete.completedPages, 2);
    expect(complete.receivedBytes, 5);
  });

  testWidgets('download manager exposes completed task and durable delete',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:manager-comic',
        displayName: '下载管理章节',
        sourceId: 'manager-source',
        comicId: 'manager-comic',
        comicTitle: '下载管理漫画',
        chapterId: 'manager-chapter',
        sourceRevision: 'manager-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://manager-1',
            pageId: 'manager-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    addTearDown(service.close);
    await service.download(entry);
    final queue = WholeComicDownloadQueue(downloads: service);
    addTearDown(queue.close);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[entry],
          downloads: service,
          wholeComicDownloads: queue,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final identity = chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );
    expect(find.byKey(downloadManagerTaskKey(identity)), findsOneWidget);
    expect(find.text('下载管理章节'), findsOneWidget);
    expect(find.textContaining('下载管理漫画'), findsOneWidget);
    expect(find.textContaining('1/1 页'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(find.byKey(downloadManagerDeleteKey(identity)));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump();
    expect(await service.isDownloaded(entry), isFalse);
  });

  testWidgets('download manager pauses and resumes a whole-comic queue job',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:whole-manager',
        displayName: '队列章节',
        sourceId: 'whole-manager-source',
        comicId: 'whole-manager-comic',
        comicTitle: '整本队列漫画',
        chapterId: 'whole-manager-chapter',
        sourceRevision: 'whole-manager-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://whole-manager-1',
            pageId: 'whole-manager-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    addTearDown(service.close);
    final environment = MutableWholeComicQueueEnvironment(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: false,
        charging: true,
      ),
    );
    addTearDown(environment.close);
    final queue = WholeComicDownloadQueue(
      downloads: service,
      environment: environment,
    );
    addTearDown(queue.close);
    await queue.ready;
    await queue.updatePolicy(
      const WholeComicQueuePolicy(
        network: WholeComicNetworkPolicy.unmetered,
      ),
    );
    await queue.enqueue(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      chapters: <ImportedLibraryEntry>[entry],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[entry],
          downloads: service,
          wholeComicDownloads: queue,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final jobId = comicLibraryIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
    );
    expect(find.byKey(wholeComicQueueJobKey(jobId)), findsOneWidget);
    expect(find.textContaining('等待策略条件'), findsOneWidget);
    expect(find.byKey(downloadQueuePolicyKey), findsOneWidget);

    await tester.tap(find.byKey(wholeComicQueuePauseKey(jobId)));
    await tester.pump();
    expect(find.byKey(wholeComicQueueResumeKey(jobId)), findsOneWidget);

    await tester.tap(find.byKey(wholeComicQueueResumeKey(jobId)));
    await tester.pump();
    expect(find.textContaining('等待策略条件'), findsOneWidget);
  });
}
