import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/download_manager.dart';

ImportedLibraryEntry _versionedDownloadEntry({
  required String comicId,
  required String chapterId,
  required String title,
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:$comicId:$chapterId',
        displayName: title,
        sourceId: 'version-manager-source',
        comicId: comicId,
        comicTitle: '版本漫画 $comicId',
        chapterId: chapterId,
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://$comicId/$chapterId/1',
            pageId: '$comicId-$chapterId-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );

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
    expect(
      tester
          .widget<NavigationBar>(find.byKey(downloadManagerBottomNavKey))
          .labelBehavior,
      NavigationDestinationLabelBehavior.alwaysHide,
    );
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
      'download manager actions wait for the adopted durable service generation',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:action-durable-handoff',
        displayName: '切换中的删除任务',
        sourceId: 'action-handoff-source',
        comicId: 'action-handoff-comic',
        comicTitle: '切换中的漫画',
        chapterId: 'action-handoff-chapter',
        sourceRevision: 'action-handoff-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://action-handoff-1',
            pageId: 'action-handoff-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final bootstrapDelegate = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await bootstrapDelegate.download(entry);
    final bootstrap = _BlockingInspectManyDownloadService(
      bootstrapDelegate,
      Future<void>.value(),
    );
    final bootstrapQueue = WholeComicDownloadQueue(downloads: bootstrap);
    await bootstrapQueue.ready;
    final initial = await bootstrap.inspect(entry);

    final durableDelegate = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await durableDelegate.download(entry);
    final durable = _BlockingInspectManyDownloadService(
      durableDelegate,
      Future<void>.value(),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durable);
    await durableQueue.ready;

    final projectionChanges = ChangeNotifier();
    final projection = DownloadManagerProjection(
      entries: <ImportedLibraryEntry>[entry],
      snapshots: <ChapterDownloadSnapshot>[initial],
      wholeComicSnapshot: bootstrapQueue.snapshot,
    );
    final releaseServices = Completer<void>();
    var resolverCalls = 0;
    var commandDeleteCalls = 0;
    final commandActions = DownloadManagerCommandActions(
      downloadChapter: (_) => throw StateError('not used'),
      retryChapter: (_) => throw StateError('not used'),
      stopChapter: (_) => throw StateError('not used'),
      deleteChapterFiles: (entry) async {
        commandDeleteCalls++;
        await durableDelegate.delete(entry);
        return durableDelegate.inspect(entry);
      },
      pauseWholeComicJob: (_) async {},
      resumeWholeComicJob: (_) async {},
      cancelWholeComicJob: (_) async {},
      retryWholeComicJob: (_) async {},
      removeWholeComicJob: (_) async {},
      updateWholeComicPolicy: (_) async {},
    );

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
            resolverCalls++;
            await releaseServices.future;
            return DownloadManagerServices(
              downloads: durable,
              wholeComicDownloads: durableQueue,
            );
          },
          commandActions: commandActions,
        ),
      ),
    );
    await tester.pump();
    expect(resolverCalls, 1);

    await tester.tap(find.byKey(downloadManagerDeleteKey(initial.identity)));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(bootstrap.deleteCalls, 0);
    expect(durable.deleteCalls, 0);
    expect(commandDeleteCalls, 0);

    releaseServices.complete();
    for (var frame = 0; frame < 40 && commandDeleteCalls == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(bootstrap.deleteCalls, 0);
    expect(durable.deleteCalls, 0);
    expect(commandDeleteCalls, 1);
    expect(await durableDelegate.isDownloaded(entry), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    projectionChanges.dispose();
    unawaited(bootstrapQueue.close());
    unawaited(durableQueue.close());
    unawaited(bootstrap.close());
    unawaited(durable.close());
  });

  testWidgets(
      'download manager chapter fallback re-resolves after hydrate generation change',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:hydrate-generation',
        displayName: 'Hydrate generation chapter',
        sourceId: 'hydrate-generation-source',
        comicId: 'hydrate-generation-comic',
        comicTitle: 'Hydrate generation comic',
        chapterId: 'hydrate-generation-chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin',
            sourceId: 'memory://hydrate-generation/1',
            pageId: 'hydrate-generation-page-1',
            contentKindHint: ContentKindHint.unknown,
            byteLength: 4,
          ),
        ],
      ),
    );
    final firstDelegate = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await firstDelegate.download(entry);
    final firstDownloads = _BlockingInspectManyDownloadService(
      firstDelegate,
      Future<void>.value(),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    await firstQueue.ready;
    final initial = await firstDownloads.inspect(entry);

    final secondDelegate = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await secondDelegate.download(entry);
    final secondDownloads = _BlockingInspectManyDownloadService(
      secondDelegate,
      Future<void>.value(),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    await secondQueue.ready;

    var currentServices = DownloadManagerServices(
      downloads: firstDownloads,
      wholeComicDownloads: firstQueue,
    );
    final serviceChanges = ChangeNotifier();
    final hydrateStarted = Completer<void>();
    final releaseHydrate = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[entry],
          downloads: firstDownloads,
          wholeComicDownloads: firstQueue,
          initialSnapshots: <ChapterDownloadSnapshot>[initial],
          serviceChanges: serviceChanges,
          resolveServices: () async => currentServices,
          hydrateEntry: (value) async {
            if (!hydrateStarted.isCompleted) hydrateStarted.complete();
            await releaseHydrate.future;
            return value;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.byKey(downloadManagerDeleteKey(initial.identity)));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await hydrateStarted.future;

    currentServices = DownloadManagerServices(
      downloads: secondDownloads,
      wholeComicDownloads: secondQueue,
    );
    serviceChanges.notifyListeners();
    releaseHydrate.complete();

    for (var frame = 0;
        frame < 40 &&
            firstDownloads.deleteCalls == 0 &&
            secondDownloads.deleteCalls == 0;
        frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(firstDownloads.deleteCalls, 0);
    expect(secondDownloads.deleteCalls, 1);
    expect(await firstDelegate.isDownloaded(entry), isTrue);
    expect(await secondDelegate.isDownloaded(entry), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    serviceChanges.dispose();
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(firstDownloads.close());
    unawaited(secondDownloads.close());
  });

  testWidgets(
      'download manager re-resolves services after a later generation change',
      (tester) async {
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    await firstQueue.ready;

    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    await secondQueue.ready;
    await secondQueue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 4),
    );

    var currentServices = DownloadManagerServices(
      downloads: firstDownloads,
      wholeComicDownloads: firstQueue,
    );
    final serviceChanges = ChangeNotifier();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: const <ImportedLibraryEntry>[],
          downloads: firstDownloads,
          wholeComicDownloads: firstQueue,
          serviceChanges: serviceChanges,
          resolveServices: () async {
            resolverCalls++;
            return currentServices;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(resolverCalls, 1);

    currentServices = DownloadManagerServices(
      downloads: secondDownloads,
      wholeComicDownloads: secondQueue,
    );
    serviceChanges.notifyListeners();
    await tester.tap(find.byKey(downloadQueuePolicyKey));
    await tester.pumpAndSettle();

    expect(resolverCalls, 2);
    final concurrency = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(concurrency.selected, <int>{4});

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    serviceChanges.dispose();
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(firstDownloads.close());
    unawaited(secondDownloads.close());
  });

  testWidgets(
      'download manager policy fallback re-resolves after an open dialog',
      (tester) async {
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    await firstQueue.ready;
    await firstQueue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 1),
    );

    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    await secondQueue.ready;
    await secondQueue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 4),
    );

    var currentServices = DownloadManagerServices(
      downloads: firstDownloads,
      wholeComicDownloads: firstQueue,
    );
    final serviceChanges = ChangeNotifier();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: const <ImportedLibraryEntry>[],
          downloads: firstDownloads,
          wholeComicDownloads: firstQueue,
          serviceChanges: serviceChanges,
          resolveServices: () async {
            resolverCalls++;
            return currentServices;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(resolverCalls, 1);

    await tester.tap(find.byKey(downloadQueuePolicyKey));
    await tester.pumpAndSettle();
    expect(find.text('整本下载队列策略'), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
          .selected,
      <int>{1},
    );

    currentServices = DownloadManagerServices(
      downloads: secondDownloads,
      wholeComicDownloads: secondQueue,
    );
    serviceChanges.notifyListeners();

    await tester.tap(find.text('3'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(firstQueue.snapshot.policy.concurrency, 1);
    expect(secondQueue.snapshot.policy.concurrency, 3);
    expect(resolverCalls, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    serviceChanges.dispose();
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(firstDownloads.close());
    unawaited(secondDownloads.close());
  });

  testWidgets(
      'download manager catches a generation change during service resolution',
      (tester) async {
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    await firstQueue.ready;

    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    await secondQueue.ready;
    await secondQueue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 4),
    );

    var currentServices = DownloadManagerServices(
      downloads: firstDownloads,
      wholeComicDownloads: firstQueue,
    );
    final serviceChanges = ChangeNotifier();
    final releaseFirstResolution = Completer<void>();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: const <ImportedLibraryEntry>[],
          downloads: firstDownloads,
          wholeComicDownloads: firstQueue,
          serviceChanges: serviceChanges,
          resolveServices: () async {
            resolverCalls++;
            final resolvedAtStart = currentServices;
            if (resolverCalls == 1) {
              await releaseFirstResolution.future;
            }
            return resolvedAtStart;
          },
        ),
      ),
    );
    await tester.pump();
    expect(resolverCalls, 1);

    currentServices = DownloadManagerServices(
      downloads: secondDownloads,
      wholeComicDownloads: secondQueue,
    );
    serviceChanges.notifyListeners();
    releaseFirstResolution.complete();
    for (var frame = 0; frame < 40 && resolverCalls < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(resolverCalls, 2);
    await tester.tap(find.byKey(downloadQueuePolicyKey));
    await tester.pumpAndSettle();
    final concurrency = tester.widget<SegmentedButton<int>>(
      find.byType(SegmentedButton<int>),
    );
    expect(concurrency.selected, <int>{4});

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    serviceChanges.dispose();
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(firstDownloads.close());
    unawaited(secondDownloads.close());
  });

  testWidgets('live chapter revision event removes stale progress aliases',
      (tester) async {
    final entry = _versionedDownloadEntry(
      comicId: 'comic', chapterId: 'chapter', title: 'Revision row',
    );
    final delegate = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    final service = _EventDownloadService(delegate);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;
    ChapterDownloadSnapshot snapshot(String revision, {bool complete = true}) =>
        ChapterDownloadSnapshot(
          sourceId: entry.chapter.sourceId, comicId: 'comic',
          comicTitle: 'Comic', chapterId: 'chapter',
          sourceRevision: revision, title: 'Revision row',
          completedPages: complete ? 1 : 0, totalPages: 1,
          receivedBytes: complete ? 4 : 0,
          phase: complete ? ChapterDownloadPhase.complete : ChapterDownloadPhase.idle,
          started: true,
        );
    final projection = DownloadManagerProjection(
      entries: <ImportedLibraryEntry>[entry],
      snapshots: <ChapterDownloadSnapshot>[snapshot('r0'), snapshot('r1')],
      wholeComicSnapshot: queue.snapshot,
    );
    await tester.pumpWidget(MaterialApp(
      home: DownloadManagerScreen(
        entries: projection.entries, downloads: service,
        wholeComicDownloads: queue, readProjection: () => projection,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Revision row'), findsOneWidget);
    service.events.add(snapshot('r2', complete: false));
    await tester.pumpAndSettle();
    expect(find.text('Revision row'), findsNothing,
        reason: 'old completed revisions must not resurrect a cleared row');
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.events.close());
    unawaited(service.close());
  });

  testWidgets('manual tab rebinds live downloads without another user action',
      (tester) async {
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:live-handoff', displayName: '实时接管章节',
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapterId: 'chapter', sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.bin', sourceId: 'memory://live-handoff',
            pageId: 'page', contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final first = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final second = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: first);
    final secondQueue = WholeComicDownloadQueue(downloads: second);
    await Future.wait(<Future<void>>[firstQueue.ready, secondQueue.ready]);
    final changes = ChangeNotifier();
    var services = DownloadManagerServices(
      downloads: first, wholeComicDownloads: firstQueue,
    );
    var resolutions = 0;
    await tester.pumpWidget(MaterialApp(
      home: DownloadManagerScreen(
        entries: <ImportedLibraryEntry>[entry],
        downloads: first, wholeComicDownloads: firstQueue,
        serviceChanges: changes,
        resolveServices: () async {
          resolutions++;
          return services;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(resolutions, 1);
    services = DownloadManagerServices(
      downloads: second, wholeComicDownloads: secondQueue,
    );
    changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(resolutions, 2);
    await second.download(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('1/1 页 · 4 B'), findsOneWidget);
    await first.download(entry);
    await tester.pumpAndSettle();
    expect(find.textContaining('1/1 页 · 4 B'), findsOneWidget);
    expect(find.textContaining('1/1 页 · 1 B'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(first.close());
    unawaited(second.close());
  });

  testWidgets(
      'download manager stops resolving when disposed during service handoff',
      (tester) async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    await queue.ready;
    final releaseResolution = Completer<void>();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: const <ImportedLibraryEntry>[],
          downloads: downloads,
          wholeComicDownloads: queue,
          resolveServices: () async {
            resolverCalls++;
            await releaseResolution.future;
            return DownloadManagerServices(
              downloads: downloads,
              wholeComicDownloads: queue,
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(resolverCalls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    releaseResolution.complete();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));

    expect(resolverCalls, 1);
    unawaited(queue.close());
    unawaited(downloads.close());
  });

  testWidgets(
      'download manager cache maintenance follows the latest service generation',
      (tester) async {
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    await firstQueue.ready;
    final firstArtifacts = _CountingArtifactCacheMaintenance();
    final firstCache = ResourceCacheCoordinator(artifacts: firstArtifacts);

    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    await secondQueue.ready;
    final secondArtifacts = _CountingArtifactCacheMaintenance();
    final secondCache = ResourceCacheCoordinator(artifacts: secondArtifacts);

    var currentServices = DownloadManagerServices(
      downloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      cacheCoordinator: firstCache,
    );
    final serviceChanges = ChangeNotifier();
    var resolverCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: const <ImportedLibraryEntry>[],
          downloads: firstDownloads,
          wholeComicDownloads: firstQueue,
          cacheCoordinator: firstCache,
          serviceChanges: serviceChanges,
          resolveServices: () async {
            resolverCalls++;
            return currentServices;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(resolverCalls, 1);

    currentServices = DownloadManagerServices(
      downloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      cacheCoordinator: secondCache,
    );
    serviceChanges.notifyListeners();
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pumpAndSettle();

    expect(resolverCalls, 2);
    expect(firstArtifacts.inspectCalls, 0);
    expect(secondArtifacts.inspectCalls, greaterThan(0));

    await tester.tap(find.byKey(downloadCacheTrimKey));
    await tester.pumpAndSettle();
    expect(firstArtifacts.trimCalls, 0);
    expect(secondArtifacts.trimCalls, 1);

    await tester.tap(find.byTooltip('清除可回收缓存'));
    await tester.pump();
    await tester.tap(find.byKey(downloadCacheClearKey));
    await tester.pumpAndSettle();

    expect(firstArtifacts.clearCalls, 0);
    expect(secondArtifacts.clearCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    serviceChanges.dispose();
    unawaited(firstCache.close());
    unawaited(secondCache.close());
    unawaited(firstQueue.close());
    unawaited(secondQueue.close());
    unawaited(firstDownloads.close());
    unawaited(secondDownloads.close());
  });

  testWidgets(
      'download manager adopts durable projection and revalidates through owner',
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
    expect(refreshCalls, 1);

    await tester.tap(find.byKey(downloadManagerRefreshKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(resolverCalls, 1);
    expect(refreshCalls, 2);
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
    'canonical tab lazily hydrates missing physical projection after first paint',
    (tester) async {
      final old = _versionedDownloadEntry(
        comicId: 'cold-canonical-old',
        chapterId: 'same-ch',
        title: '冷启动旧版缓存',
      );
      final newest = _versionedDownloadEntry(
        comicId: 'cold-canonical-new',
        chapterId: 'same-ch',
        title: '冷启动新版缓存',
      );
      final service = MemoryChapterDownloadService(
        pageLoader: (_, __) async => Uint8List(4),
      );
      service.seedPages(
        old,
        <Uint8List?>[Uint8List(4)],
        pinnedPages: 0,
        phase: ChapterDownloadPhase.idle,
      );
      service.seedPages(
        newest,
        <Uint8List?>[Uint8List(4)],
        pinnedPages: 0,
        phase: ChapterDownloadPhase.idle,
      );
      final snapshots = await service.inspectMany(
        <ImportedLibraryEntry>[old, newest],
      );
      final queue = WholeComicDownloadQueue(downloads: service);
      await queue.ready;
      final canonical = CanonicalChapterCacheSnapshot(
        familyId: const VersionFamilyId('cold-family'),
        canonicalChapterId: const CanonicalChapterId('cold-chapter'),
        readyPages: 1,
        partialPages: 0,
        receivedBytes: 4,
        manualReferencedPages: 0,
        memberChapterIdentities: snapshots.map((snapshot) => snapshot.identity),
      );
      final projectionChanges = ChangeNotifier();
      var projection = DownloadManagerProjection(
        entries: <ImportedLibraryEntry>[old, newest],
        snapshots: snapshots,
        wholeComicSnapshot: queue.snapshot,
      );
      var fullRefreshCalls = 0;
      var cacheRefreshCalls = 0;
      final releaseRefresh = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: DownloadManagerScreen(
            entries: projection.entries,
            downloads: service,
            wholeComicDownloads: queue,
            initialSnapshots: projection.snapshots,
            projectionChanges: projectionChanges,
            readProjection: () => projection,
            refreshProjection: () async {
              fullRefreshCalls++;
            },
            refreshCacheProjection: () async {
              cacheRefreshCalls++;
              await releaseRefresh.future;
              projection = DownloadManagerProjection(
                entries: projection.entries,
                snapshots: projection.snapshots,
                wholeComicSnapshot: projection.wholeComicSnapshot,
                cacheProjection: ChapterCacheManagementProjection(
                  canonical: <CanonicalChapterCacheSnapshot>[canonical],
                  exact: const <ExactChapterCacheSnapshot>[],
                ),
              );
              projectionChanges.notifyListeners();
            },
          ),
        ),
      );
      await tester.pump();

      expect(fullRefreshCalls, 1);
      expect(cacheRefreshCalls, 0);
      await tester.tap(find.byKey(downloadManagerTabCacheKey));
      await tester.pump();
      expect(find.text('正在读取 Canonical 缓存…'), findsOneWidget);
      for (final snapshot in snapshots) {
        expect(
          find.byKey(downloadManagerAutoCacheTaskKey(snapshot.identity)),
          findsNothing,
        );
      }

      expect(fullRefreshCalls, 1);
      expect(cacheRefreshCalls, 1);
      releaseRefresh.complete();
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(downloadManagerCanonicalCacheTaskKey(canonical.identity)),
        findsOneWidget,
      );
      expect(find.text('正在读取 Canonical 缓存…'), findsNothing);
      final canonicalSliver = tester.widget<SliverList>(find.byType(SliverList));
      expect(
        canonicalSliver.delegate,
        isA<SliverChildBuilderDelegate>(),
        reason:
            'Canonical cache rows must stay lazy instead of allocating every historical tile during tab switch',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      projectionChanges.dispose();
      unawaited(queue.close());
      unawaited(service.close());
    },
  );

  testWidgets('opening manager reconciles changes missed while route was absent',
      (tester) async {
    final entry = _versionedDownloadEntry(
      comicId: 'missed-comic', chapterId: 'missed-chapter', title: '离页期间完成',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(4),
    );
    await service.download(entry);
    final completed = await service.inspect(entry);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;
    var projection = DownloadManagerProjection(
      entries: <ImportedLibraryEntry>[entry],
      snapshots: <ChapterDownloadSnapshot>[ChapterDownloadSnapshot.idle(entry)],
      wholeComicSnapshot: queue.snapshot,
    );
    final releaseRefresh = Completer<void>();
    var refreshCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: DownloadManagerScreen(
        entries: projection.entries, downloads: service,
        wholeComicDownloads: queue, initialSnapshots: projection.snapshots,
        readProjection: () => projection,
        refreshProjection: () async {
          refreshCalls++;
          await releaseRefresh.future;
          projection = DownloadManagerProjection(
            entries: <ImportedLibraryEntry>[entry],
            snapshots: <ChapterDownloadSnapshot>[completed],
            wholeComicSnapshot: queue.snapshot,
          );
        },
      ),
    ));
    await tester.pump();
    expect(find.byKey(downloadManagerScreenKey), findsOneWidget);
    expect(find.text('离页期间完成'), findsNothing);
    final callsBeforeRelease = refreshCalls;
    releaseRefresh.complete();
    await tester.pumpAndSettle();
    expect(callsBeforeRelease, 1,
        reason: 'route must reconcile after painting without requiring a tap');
    expect(find.text('离页期间完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets(
    'download manager auto-refreshes durable auto-cache projection changes',
    (tester) async {
      final entry = ImportedLibraryEntry(
        chapter: ImportedChapterRecord(
          directoryId: 'fixture:auto-cache-auto-refresh',
          displayName: '自动缓存刷新章节',
          sourceId: 'auto-cache-refresh-source',
          comicId: 'auto-cache-refresh-comic',
          comicTitle: '自动缓存刷新漫画',
          chapterId: 'auto-cache-refresh-chapter',
          sourceRevision: 'r1',
          pages: const <ImportedPageRecord>[
            ImportedPageRecord(
              displayName: '1.webp',
              sourceId: 'memory://auto-cache-refresh-1',
              pageId: 'auto-cache-refresh-page-1',
              contentKindHint: ContentKindHint.webp,
              byteLength: 4,
            ),
          ],
        ),
      );
      final delegate = MemoryChapterDownloadService(
        pageLoader: (_, _) async => Uint8List(4),
      );
      final idle = ChapterDownloadSnapshot.idle(entry);
      final service = _ManagementProjectionDownloadService(
        delegate,
        ChapterDownloadManagementProjection(
          orphanedEntries: const <ImportedLibraryEntry>[],
          snapshots: <ChapterDownloadSnapshot>[idle],
        ),
      );
      final queue = WholeComicDownloadQueue(downloads: service);
      await queue.ready;

      await tester.pumpWidget(
        MaterialApp(
          home: DownloadManagerScreen(
            entries: <ImportedLibraryEntry>[entry],
            downloads: service,
            wholeComicDownloads: queue,
            initialSnapshots: <ChapterDownloadSnapshot>[idle],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      await tester.tap(find.byKey(downloadManagerTabCacheKey));
      await tester.pump();
      expect(find.byKey(downloadManagerAutoCacheTaskKey(idle.identity)), findsNothing);

      final cached = ChapterDownloadSnapshot(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        comicTitle: entry.chapter.comicTitle,
        chapterId: entry.chapter.chapterId,
        sourceRevision: entry.chapter.sourceRevision,
        title: entry.chapter.displayName,
        completedPages: 1,
        totalPages: 1,
        receivedBytes: 4,
        pinnedPages: 0,
        exactCompletedPages: 0,
        totalBytes: 4,
        phase: ChapterDownloadPhase.idle,
      );
      service.projection = ChapterDownloadManagementProjection(
        orphanedEntries: const <ImportedLibraryEntry>[],
        snapshots: <ChapterDownloadSnapshot>[cached],
      );
      // A continuous event stream must not postpone refresh indefinitely.
      for (var i = 0; i < 4; i++) {
        service.notifyManagementChanged();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump();

      expect(
        find.byKey(downloadManagerAutoCacheTaskKey(cached.identity)),
        findsOneWidget,
      );
      expect(service.managementInspections, greaterThanOrEqualTo(2));

      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(queue.close());
      unawaited(service.close());
    },
  );

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


  testWidgets(
      'download manager keeps an explicitly downloaded predecessor when successor was never started',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'old',
      chapterId: 'shared-chapter',
      title: '旧版手动章节',
    );
    final newest = _versionedDownloadEntry(
      comicId: 'new',
      chapterId: 'shared-chapter',
      title: '新版未下载章节',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    await service.download(old);
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old, newest]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old, newest],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          versionBaselines: _downloadVersionBaselines(
            const <ComicVersionRelation>[
                        ComicVersionRelation(
                          sourceId: 'version-manager-source',
                          predecessorComicId: 'old',
                          successorComicId: 'new',
                        ),
                      ],
            snapshots,
          ),
        ),
      ),
    );
    await tester.pump();

    final oldSnapshot = snapshots.firstWhere((s) => s.comicId == 'old');
    final newSnapshot = snapshots.firstWhere((s) => s.comicId == 'new');
    expect(find.byKey(downloadManagerTaskKey(oldSnapshot.identity)), findsOneWidget);
    expect(find.byKey(downloadManagerTaskKey(newSnapshot.identity)), findsNothing);
    expect(find.text('旧版手动章节'), findsOneWidget);
    expect(find.text('新版未下载章节'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets(
      'download manager consumes projected download head across mapped chapter ids',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'old',
      chapterId: 'old-ch',
      title: '旧版已下载',
    );
    final newest = _versionedDownloadEntry(
      comicId: 'new',
      chapterId: 'new-ch',
      title: '新版已下载',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    await service.download(old);
    await service.download(newest);
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old, newest]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old, newest],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          versionBaselines: _downloadVersionBaselines(
            const <ComicVersionRelation>[
                        ComicVersionRelation(
                          sourceId: 'version-manager-source',
                          predecessorComicId: 'old',
                          successorComicId: 'middle',
                          pageMappings: <ComicVersionPageMapping>[
                            ComicVersionPageMapping(
                              predecessorChapterId: 'old-ch',
                              successorChapterId: 'middle-ch',
                              predecessorPageCount: 1,
                              successorPageCount: 2,
                              successorOffset: 1,
                            ),
                          ],
                        ),
                        ComicVersionRelation(
                          sourceId: 'version-manager-source',
                          predecessorComicId: 'middle',
                          successorComicId: 'new',
                          pageMappings: <ComicVersionPageMapping>[
                            ComicVersionPageMapping(
                              predecessorChapterId: 'middle-ch',
                              successorChapterId: 'new-ch',
                              predecessorPageCount: 2,
                              successorPageCount: 3,
                              successorOffset: 1,
                            ),
                          ],
                        ),
                      ],
            snapshots,
          ),
        ),
      ),
    );
    await tester.pump();

    final oldSnapshot = snapshots.firstWhere((s) => s.comicId == 'old');
    final newSnapshot = snapshots.firstWhere((s) => s.comicId == 'new');
    expect(find.byKey(downloadManagerTaskKey(oldSnapshot.identity)), findsNothing);
    expect(find.byKey(downloadManagerTaskKey(newSnapshot.identity)), findsOneWidget);
    expect(find.text('旧版已下载'), findsNothing);
    expect(find.text('新版已下载'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets(
      'download manager does not merge same raw chapter id when explicit mapping points elsewhere',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'mapped-old',
      chapterId: 'shared-unmapped',
      title: '旧版未映射章节',
    );
    final newest = _versionedDownloadEntry(
      comicId: 'mapped-new',
      chapterId: 'shared-unmapped',
      title: '新版未映射章节',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    await service.download(old);
    await service.download(newest);
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old, newest]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old, newest],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          versionBaselines: _downloadVersionBaselines(
            const <ComicVersionRelation>[
                        ComicVersionRelation(
                          sourceId: 'version-manager-source',
                          predecessorComicId: 'mapped-old',
                          successorComicId: 'mapped-new',
                          pageMappings: <ComicVersionPageMapping>[
                            ComicVersionPageMapping(
                              predecessorChapterId: 'other-old-ch',
                              successorChapterId: 'other-new-ch',
                              predecessorPageCount: 1,
                              successorPageCount: 2,
                              successorOffset: 1,
                            ),
                          ],
                        ),
                      ],
            snapshots,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('旧版未映射章节'), findsOneWidget);
    expect(find.text('新版未映射章节'), findsOneWidget);
    for (final snapshot in snapshots) {
      expect(find.byKey(downloadManagerTaskKey(snapshot.identity)), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets('download manager keeps auto-cache rows exact across comic versions',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'cache-old',
      chapterId: 'same-ch',
      title: '旧版缓存',
    );
    final newest = _versionedDownloadEntry(
      comicId: 'cache-new',
      chapterId: 'same-ch',
      title: '新版缓存',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    service.seedPages(
      old,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );
    service.seedPages(
      newest,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old, newest]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old, newest],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          versionBaselines: _downloadVersionBaselines(
            const <ComicVersionRelation>[
                        ComicVersionRelation(
                          sourceId: 'version-manager-source',
                          predecessorComicId: 'cache-old',
                          successorComicId: 'cache-new',
                        ),
                      ],
            snapshots,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump();

    expect(find.text('旧版缓存'), findsOneWidget);
    expect(find.text('新版缓存'), findsOneWidget);
    for (final snapshot in snapshots) {
      expect(
        find.byKey(downloadManagerAutoCacheTaskKey(snapshot.identity)),
        findsOneWidget,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });


  testWidgets(
      'download manager renders one canonical cache row for version-family cache',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'canonical-old',
      chapterId: 'same-ch',
      title: '旧版缓存',
    );
    final newest = _versionedDownloadEntry(
      comicId: 'canonical-new',
      chapterId: 'same-ch',
      title: '新版缓存',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    service.seedPages(
      old,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );
    service.seedPages(
      newest,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old, newest]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;
    final canonical = CanonicalChapterCacheSnapshot(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('chapter'),
      readyPages: 1,
      partialPages: 0,
      receivedBytes: 4,
      manualReferencedPages: 0,
      memberChapterIdentities: snapshots.map((snapshot) => snapshot.identity),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old, newest],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          initialCacheProjection: ChapterCacheManagementProjection(
            canonical: <CanonicalChapterCacheSnapshot>[canonical],
            exact: const <ExactChapterCacheSnapshot>[],
          ),
          versionBaselines: _downloadVersionBaselines(
            const <ComicVersionRelation>[
              ComicVersionRelation(
                sourceId: 'version-manager-source',
                predecessorComicId: 'canonical-old',
                successorComicId: 'canonical-new',
              ),
            ],
            snapshots,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump();

    expect(
      find.byKey(downloadManagerCanonicalCacheTaskKey(canonical.identity)),
      findsOneWidget,
    );
    for (final snapshot in snapshots) {
      expect(
        find.byKey(downloadManagerAutoCacheTaskKey(snapshot.identity)),
        findsNothing,
      );
    }
    expect(find.textContaining('Canonical 缓存'), findsWidgets);
    expect(find.textContaining('2 个版本共享'), findsOneWidget);

    await tester.tap(find.byKey(downloadManagerConvertKey(canonical.identity)));
    await tester.pumpAndSettle();
    final oldAfter = await service.inspect(old);
    final newestAfter = await service.inspect(newest);
    expect(oldAfter.isManualDownload, isFalse);
    expect(newestAfter.isManualDownload, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });

  testWidgets(
      'canonical cache does not guess an older download target when latest member is absent',
      (tester) async {
    final old = _versionedDownloadEntry(
      comicId: 'canonical-old-only',
      chapterId: 'same-ch',
      title: '旧版缓存',
    );
    final service = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(4),
    );
    service.seedPages(
      old,
      <Uint8List?>[Uint8List(4)],
      pinnedPages: 0,
      phase: ChapterDownloadPhase.idle,
    );
    final snapshots = await service.inspectMany(<ImportedLibraryEntry>[old]);
    final queue = WholeComicDownloadQueue(downloads: service);
    await queue.ready;
    final canonical = CanonicalChapterCacheSnapshot(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('chapter'),
      readyPages: 1,
      partialPages: 0,
      receivedBytes: 4,
      manualReferencedPages: 0,
      memberChapterIdentities: snapshots.map((snapshot) => snapshot.identity),
    );
    final versionBaselines = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 'version-manager-source',
          predecessorComicId: 'canonical-old-only',
          successorComicId: 'canonical-new-missing',
        ),
      ],
      cacheReuseComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(
          sourceId: 'version-manager-source',
          comicId: 'canonical-old-only',
        ),
        ComicVersionIdentity(
          sourceId: 'version-manager-source',
          comicId: 'canonical-new-missing',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadManagerScreen(
          entries: <ImportedLibraryEntry>[old],
          downloads: service,
          wholeComicDownloads: queue,
          initialSnapshots: snapshots,
          initialCacheProjection: ChapterCacheManagementProjection(
            canonical: <CanonicalChapterCacheSnapshot>[canonical],
            exact: const <ExactChapterCacheSnapshot>[],
          ),
          versionBaselines: versionBaselines,
        ),
      ),
    );
    await tester.tap(find.byKey(downloadManagerTabCacheKey));
    await tester.pump();

    expect(
      find.byKey(downloadManagerCanonicalCacheTaskKey(canonical.identity)),
      findsOneWidget,
    );
    expect(
      find.byKey(downloadManagerConvertKey(canonical.identity)),
      findsNothing,
    );
    expect((await service.inspect(old)).isManualDownload, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(queue.close());
    unawaited(service.close());
  });


}

ComicVersionBaselineProjection _downloadVersionBaselines(
  Iterable<ComicVersionRelation> relations,
  Iterable<ChapterDownloadSnapshot> snapshots,
) =>
    resolveComicVersionBaselines(
      relations: relations,
      manualDownloadComics: <ComicVersionIdentity>[
        for (final snapshot in snapshots)
          if (snapshot.isManualDownload)
            ComicVersionIdentity(
              sourceId: snapshot.sourceId,
              comicId: snapshot.comicId,
            ),
      ],
    );

final class _CountingArtifactCacheMaintenance
    implements ArtifactCacheMaintenance {
  int inspectCalls = 0;
  int trimCalls = 0;
  int clearCalls = 0;

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async {
    inspectCalls++;
    return const ArtifactCacheUsage(bytes: 0, entries: 0);
  }

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    trimCalls++;
    return const ArtifactCacheReport(
      beforeBytes: 0,
      releasedBytes: 0,
      remainingBytes: 0,
      evictedEntries: 0,
      skippedBusy: 0,
    );
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    clearCalls++;
    return const ArtifactCacheReport(
      beforeBytes: 0,
      releasedBytes: 0,
      remainingBytes: 0,
      evictedEntries: 0,
      skippedBusy: 0,
    );
  }
}

final class _EventDownloadService extends _BlockingInspectManyDownloadService {
  _EventDownloadService(ChapterDownloadService delegate)
      : super(delegate, Future<void>.value());

  final StreamController<ChapterDownloadSnapshot> events =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);

  @override
  Stream<ChapterDownloadSnapshot> get changes => events.stream;
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
  void updateVersionBaselines(List<ComicVersionRelation> relations) =>
      _delegate.updateVersionBaselines(relations);

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) =>
      _delegate.updateCacheVersionRelations(relations);

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
  int deleteCalls = 0;

  @override
  Stream<ChapterDownloadSnapshot> get changes => _delegate.changes;

  @override
  Future<void> download(ImportedLibraryEntry entry) => _delegate.download(entry);

  @override
  Future<void> retry(ImportedLibraryEntry entry) => _delegate.retry(entry);

  @override
  Future<void> cancel(ImportedLibraryEntry entry) => _delegate.cancel(entry);

  @override
  Future<void> delete(ImportedLibraryEntry entry) {
    deleteCalls++;
    return _delegate.delete(entry);
  }

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


final class _ManagementProjectionDownloadService
    extends _BlockingInspectManyDownloadService
    implements
        ChapterDownloadManagementProjectionReader,
        ChapterDownloadManagementChangeSource {
  _ManagementProjectionDownloadService(
    ChapterDownloadService delegate,
    this.projection,
  ) : super(delegate, Future<void>.value());

  final StreamController<void> _managementChanges =
      StreamController<void>.broadcast(sync: true);
  ChapterDownloadManagementProjection projection;
  int managementInspections = 0;

  @override
  Stream<void> get managementProjectionChanges => _managementChanges.stream;

  @override
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    managementInspections++;
    return projection;
  }

  void notifyManagementChanged() {
    _managementChanges.add(null);
  }

  @override
  Future<void> close() async {
    if (!_managementChanges.isClosed) {
      await _managementChanges.close();
    }
    await super.close();
  }
}
