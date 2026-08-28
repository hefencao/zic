import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/download_manager.dart';

void main() {
  testWidgets('download manager paints before durable bulk refresh completes',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:route-first-download-manager',
        displayName: '首帧章节',
        sourceId: 'route-first-source',
        comicId: 'route-first-comic',
        comicTitle: '首帧漫画',
        chapterId: 'route-first-chapter',
        sourceRevision: 'route-first-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://route-first-1',
            pageId: 'route-first-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final delegate = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    await delegate.download(entry);
    final initial = await delegate.inspect(entry);
    final releaseRefresh = Completer<void>();
    final service = _BlockingInspectManyDownloadService(
      delegate,
      releaseRefresh.future,
    );
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[entry],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: <ChapterDownloadSnapshot>[initial],
        ),
      ),
    );

    // The first frame is already the download route even though the
    // post-frame durable refresh is intentionally blocked.
    expect(find.byKey(downloadManagerScreenKey), findsOneWidget);
    expect(find.text('首帧章节'), findsOneWidget);
    expect(service.inspectManyStarted, isTrue);
    expect(releaseRefresh.isCompleted, isFalse);

    releaseRefresh.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
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
    await service.download(entry);
    final queue = WholeComicDownloadQueue(downloads: service);
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
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

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
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await service.isDownloaded(entry), isFalse);
    final task = find.byKey(downloadManagerTaskKey(identity));
    for (var frame = 0; frame < 40 && task.evaluate().isNotEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(task, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
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
    final environment = MutableWholeComicQueueEnvironment(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: false,
        charging: true,
      ),
    );
    final queue = WholeComicDownloadQueue(
      downloads: service,
      environment: environment,
    );
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
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    final jobId = comicLibraryIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
    );
    expect(find.byKey(wholeComicQueueJobKey(jobId)), findsOneWidget);
    expect(find.textContaining('等待策略条件'), findsOneWidget);
    expect(find.byKey(downloadQueuePolicyKey), findsOneWidget);

    await tester.tap(find.byKey(wholeComicQueuePauseKey(jobId)));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(wholeComicQueueResumeKey(jobId)), findsOneWidget);

    await tester.tap(find.byKey(wholeComicQueueResumeKey(jobId)));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.textContaining('等待策略条件'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(environment.close());
    unawaited(service.close());
  });
}

final class _BlockingInspectManyDownloadService
    implements ChapterDownloadService {
  _BlockingInspectManyDownloadService(this._delegate, this._release);

  final ChapterDownloadService _delegate;
  final Future<void> _release;
  bool inspectManyStarted = false;

  @override
  Stream<ChapterDownloadSnapshot> get changes => _delegate.changes;

  @override
  Future<void> download(ImportedLibraryEntry entry) => _delegate.download(entry);

  @override
  Future<void> retry(ImportedLibraryEntry entry) => _delegate.retry(entry);

  @override
  Future<void> cancel(ImportedLibraryEntry entry) => _delegate.cancel(entry);

  @override
  Future<void> delete(ImportedLibraryEntry entry) => _delegate.delete(entry);

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) =>
      _delegate.inspect(entry);

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    inspectManyStarted = true;
    await _release;
    return _delegate.inspectMany(entries);
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) =>
      _delegate.isDownloaded(entry);

  @override
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
  }) =>
      _delegate.inspectComicConflicts(
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
      );

  @override
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) =>
      _delegate.discoverOrphanedEntries(knownEntries);

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) =>
      _delegate.readPage(entry, pageIndex);

  @override
  Future<void> close() => _delegate.close();
}
