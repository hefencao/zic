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
    final taskList = tester.widget<ListView>(find.byType(ListView));
    expect(taskList.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(service.inspectManyStarted, isTrue);
    expect(releaseRefresh.isCompleted, isFalse);

    releaseRefresh.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets(
      'download manager keeps persisted Home projection visible during handoff',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:persisted-first-entry',
        displayName: '持久任务首进可见',
        sourceId: 'persisted-first-entry-source',
        comicId: 'persisted-first-entry-comic',
        comicTitle: '持久任务漫画',
        chapterId: 'persisted-first-entry-chapter',
        sourceRevision: 'persisted-first-entry-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://persisted-first-entry-1',
            pageId: 'persisted-first-entry-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final bootstrap = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    final bootstrapQueue = WholeComicDownloadQueue(downloads: bootstrap);
    await bootstrapQueue.ready;
    final durable = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await durable.download(entry);
    final persistedSnapshot = await durable.inspect(entry);
    final releaseUnexpectedScan = Completer<void>();
    final durableView = _BlockingInspectManyDownloadService(
      durable,
      releaseUnexpectedScan.future,
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableView);
    await durableQueue.ready;
    final projectionChanges = ChangeNotifier();
    final projection = DownloadManagerProjection(
      entries: <ImportedLibraryEntry>[entry],
      snapshots: <ChapterDownloadSnapshot>[persistedSnapshot],
      wholeComicSnapshot: bootstrapQueue.snapshot,
    );
    final releaseServices = Completer<void>();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: projection.entries,
          downloads: bootstrap,
          wholeComicDownloads: bootstrapQueue,
          initialSnapshots: projection.snapshots,
          initialWholeComicSnapshot: projection.wholeComicSnapshot,
          projectionChanges: projectionChanges,
          readProjection: () => projection,
          refreshProjection: () async {},
          resolveServices: () async {
            resolverCalls += 1;
            await releaseServices.future;
            return DownloadManagerServices(
              downloads: durableView,
              wholeComicDownloads: durableQueue,
            );
          },
        ),
      ),
    );

    final task = find.byKey(downloadManagerTaskKey(persistedSnapshot.identity));
    expect(find.byKey(downloadManagerScreenKey), findsOneWidget);
    expect(find.text('持久任务首进可见'), findsOneWidget);
    expect(task, findsOneWidget);
    expect(resolverCalls, 1);
    expect(releaseServices.isCompleted, isFalse);
    expect(durableView.inspectManyStarted, isFalse);

    releaseServices.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('持久任务首进可见'), findsOneWidget);
    expect(task, findsOneWidget);
    expect(resolverCalls, 1);
    expect(durableView.inspectManyStarted, isFalse);

    if (!releaseUnexpectedScan.isCompleted) {
      releaseUnexpectedScan.complete();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    projectionChanges.dispose();
    unawaited(bootstrapQueue.close());
    unawaited(durableQueue.close());
    unawaited(bootstrap.close());
    unawaited(durableView.close());
  });

  testWidgets(
      'download manager adopts durable projection without reopening or route scan',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:first-open-service-adoption',
        displayName: '首次进入即可显示',
        sourceId: 'first-open-source',
        comicId: 'first-open-comic',
        comicTitle: '首次进入漫画',
        chapterId: 'first-open-chapter',
        sourceRevision: 'first-open-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://first-open-1',
            pageId: 'first-open-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final bootstrap = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    final bootstrapQueue = WholeComicDownloadQueue(downloads: bootstrap);
    await bootstrapQueue.ready;
    final durable = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await durable.download(entry);
    final durableSnapshot = await durable.inspect(entry);
    final releaseUnexpectedScan = Completer<void>();
    final durableView = _BlockingInspectManyDownloadService(
      durable,
      releaseUnexpectedScan.future,
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableView);
    await durableQueue.ready;
    final projectionChanges = ChangeNotifier();
    var projection = DownloadManagerProjection(
      entries: const <ImportedLibraryEntry>[],
      snapshots: const <ChapterDownloadSnapshot>[],
      wholeComicSnapshot: bootstrapQueue.snapshot,
    );
    final releaseServices = Completer<void>();
    var resolverCalls = 0;
    var refreshCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: projection.entries,
          downloads: bootstrap,
          wholeComicDownloads: bootstrapQueue,
          initialSnapshots: projection.snapshots,
          initialWholeComicSnapshot: projection.wholeComicSnapshot,
          projectionChanges: projectionChanges,
          readProjection: () => projection,
          refreshProjection: () async {
            refreshCalls += 1;
          },
          resolveServices: () async {
            resolverCalls += 1;
            await releaseServices.future;
            projection = DownloadManagerProjection(
              entries: <ImportedLibraryEntry>[entry],
              snapshots: <ChapterDownloadSnapshot>[durableSnapshot],
              wholeComicSnapshot: durableQueue.snapshot,
            );
            projectionChanges.notifyListeners();
            return DownloadManagerServices(
              downloads: durableView,
              wholeComicDownloads: durableQueue,
            );
          },
        ),
      ),
    );

    expect(find.byKey(downloadManagerScreenKey), findsOneWidget);
    expect(resolverCalls, 1);
    expect(find.text('首次进入即可显示'), findsNothing);

    releaseServices.complete();
    final task = find.byKey(
      downloadManagerTaskKey(
        chapterDownloadIdentity(
          entry.chapter.sourceId,
          entry.chapter.comicId,
          entry.chapter.chapterId,
          entry.chapter.sourceRevision,
        ),
      ),
    );
    for (var frame = 0; frame < 40 && task.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('首次进入即可显示'), findsOneWidget);
    expect(task, findsOneWidget);
    expect(durableView.inspectManyStarted, isFalse);

    await tester.tap(find.byKey(downloadManagerRefreshKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(resolverCalls, 1);
    expect(refreshCalls, 1);
    expect(durableView.inspectManyStarted, isFalse);

    if (!releaseUnexpectedScan.isCompleted) {
      releaseUnexpectedScan.complete();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    projectionChanges.dispose();
    unawaited(bootstrapQueue.close());
    unawaited(durableQueue.close());
    unawaited(bootstrap.close());
    unawaited(durableView.close());
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
      entry.chapter.comicId,
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

  testWidgets('download manager stops and retries a downloading chapter task',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:chapter-pause-resume',
        displayName: '停止重试章节',
        sourceId: 'pause-resume-source',
        comicId: 'pause-resume-comic',
        comicTitle: '停止重试漫画',
        chapterId: 'pause-resume-chapter',
        sourceRevision: 'pause-resume-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://pause-resume-1',
            pageId: 'pause-resume-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final blockLoader = Completer<void>();
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        await blockLoader.future;
        return Uint8List(4);
      },
    );
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    // Start download (will hang waiting for blockLoader)
    unawaited(service.download(entry));

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
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

    // Shows stop button when downloading
    expect(find.byKey(downloadManagerCancelKey(identity)), findsOneWidget);
    expect(find.textContaining('下载中'), findsOneWidget);

    // Tap stop button
    await tester.tap(find.byKey(downloadManagerCancelKey(identity)));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Shows retry button when stopped/cancelled
    expect(find.byKey(downloadManagerRetryKey(identity)), findsOneWidget);
    expect(find.textContaining('已停止'), findsOneWidget);

    // Unblock pageLoader and retry
    blockLoader.complete();
    await tester.tap(find.byKey(downloadManagerRetryKey(identity)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(await service.isDownloaded(entry), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets('download manager switches between manual tasks and page auto-cache tabs',
      (tester) async {
    final entryManual = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:manual-comic',
        displayName: '手动章节',
        sourceId: 'manual-source',
        comicId: 'manual-comic',
        comicTitle: '手动漫画',
        chapterId: 'manual-chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://manual-1',
            pageId: 'manual-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final entryCache = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:cache-comic',
        displayName: '缓存章节',
        sourceId: 'cache-source',
        comicId: 'cache-comic',
        comicTitle: '缓存漫画',
        chapterId: 'cache-chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://cache-1',
            pageId: 'cache-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    // Manual download for entryManual
    await service.download(entryManual);

    // Seed auto-cached page for entryCache
    service.seedPages(
      entryCache,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );

    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[entryManual, entryCache],
          downloads: service,
          wholeComicDownloads: queue,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Default tab: 手动下载任务
    expect(find.text('手动章节'), findsOneWidget);
    expect(find.text('缓存章节'), findsNothing);

    // Switch to 页面自动缓存 tab
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('手动章节'), findsNothing);
    expect(find.text('缓存章节'), findsOneWidget);
    final cacheSnapshot = await service.inspect(entryCache);
    expect(find.byKey(downloadManagerClearCacheKey(cacheSnapshot.identity)), findsOneWidget);

    // Switch back to 手动下载任务 tab
    await tester.tap(find.byKey(downloadManagerTabManualKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('手动章节'), findsOneWidget);
    expect(find.text('缓存章节'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets('download manager auto-cache tab allows clearing cache and manual download automatically adopts cache',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:convert-comic',
        displayName: '转下载章节',
        sourceId: 'convert-source',
        comicId: 'convert-comic',
        comicTitle: '转下载漫画',
        chapterId: 'convert-chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://convert-1',
            pageId: 'convert-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    service.seedPages(
      entry,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );

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
    await tester.pump(const Duration(milliseconds: 50));

    // Switch to 页面自动缓存 tab
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('转下载章节'), findsOneWidget);
    final cacheSnapshot = await service.inspect(entry);
    final deleteBtn = find.byKey(downloadManagerClearCacheKey(cacheSnapshot.identity));
    expect(deleteBtn, findsOneWidget);

    // Trigger explicit manual download on the service: it automatically pins/converts the cache
    await service.download(entry);
    expect(await service.isDownloaded(entry), isTrue);

    // Switch back to manual tab and verify it is complete in manual downloads
    await tester.tap(find.byKey(downloadManagerTabManualKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('转下载章节'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets('download manager handles incomplete download with subsequent auto-caching',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:hybrid-comic',
        displayName: '混合章节',
        sourceId: 'hybrid-source',
        comicId: 'hybrid-comic',
        comicTitle: '混合漫画',
        chapterId: 'hybrid-chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://hybrid-1',
            pageId: 'hybrid-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
          ImportedPageRecord(
            displayName: '2.bin',
            sourceId: 'memory://hybrid-2',
            pageId: 'hybrid-page-2',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    // Incomplete snapshot: 1 page pinned (manually downloaded), 1 page auto-cached (total 2 completed)
    service.seedPages(
      entry,
      <Uint8List?>[Uint8List(4), Uint8List(4)],
      pinnedPages: 1,
      phase: ChapterDownloadPhase.cancelled,
    );

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
    await tester.pump(const Duration(milliseconds: 50));

    // Visible in manual tab (because pinnedPages > 0 & cancelled phase)
    expect(find.text('混合章节'), findsOneWidget);
    expect(find.textContaining('1 页已固定下载 · 1 页自动缓存'), findsOneWidget);

    // Switch to auto-cache tab: manual download task must not leak into auto-cache tab
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('混合章节'), findsNothing);
    expect(find.text('暂无页面自动缓存'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets('download manager converts auto-cache to manual download via convert button',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:convert-btn-comic',
        displayName: '待转缓存章节',
        sourceId: 'convert-btn-src',
        comicId: 'convert-btn-comic',
        comicTitle: '待转缓存漫画',
        chapterId: 'convert-btn-ch',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://convert-btn-1',
            pageId: 'convert-btn-p1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    service.seedPages(
      entry,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );

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
    await tester.pump(const Duration(milliseconds: 50));

    // Switch to auto cache tab
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('待转缓存章节'), findsOneWidget);
    final cacheSnapshot = await service.inspect(entry);
    final convertBtn = find.byKey(downloadManagerConvertKey(cacheSnapshot.identity));
    expect(convertBtn, findsOneWidget);

    // Tap convert button
    await tester.tap(convertBtn);
    await tester.pump(const Duration(milliseconds: 50));

    // Automatically switches to manual tab and shows the converted chapter
    expect(find.byKey(downloadManagerTabManualKey), findsOneWidget);
    expect(find.text('待转缓存章节'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

}

final class _BlockingInspectManyDownloadService
    implements ChapterDownloadService {

  @override
  Future<DownloadExistenceReport> probeExistingDownloads(
    DownloadExistenceQuery query,
  ) =>
      _delegate.probeExistingDownloads(query);

  @override
  Future<ChapterFileStateReport> inspectChapterFileState(
    ImportedLibraryEntry entry,
  ) =>
      _delegate.inspectChapterFileState(entry);

  @override
  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) =>
      _delegate.claimComicDirectory(
        sourceId: sourceId,
        comicId: comicId,
        directoryName: directoryName,
        comicTitle: comicTitle,
        mode: mode,
        observedOwnerKey: observedOwnerKey,
        pageOrder: pageOrder,
      );

  @override
  void updateVersionRelations(List<ComicVersionRelation> relations) =>
      _delegate.updateVersionRelations(relations);

  @override
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) =>
      _delegate.getDownloadPlacement(
        sourceId: sourceId,
        comicId: comicId,
      );

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
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) =>
      _delegate.inspectComicConflicts(
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
        knownPredecessorComicIds: knownPredecessorComicIds,
        knownSuccessorComicIds: knownSuccessorComicIds,
      );

  @override
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) =>
      _delegate.discoverOrphanedEntries(knownEntries);

  @override
  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry) =>
      _delegate.readyPageIndices(entry);

  @override
  Future<bool> hasReadyPage(ImportedLibraryEntry entry, int pageIndex) =>
      _delegate.hasReadyPage(entry, pageIndex);

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) =>
      _delegate.readPage(entry, pageIndex);

  @override
  Future<void> close() => _delegate.close();
}
