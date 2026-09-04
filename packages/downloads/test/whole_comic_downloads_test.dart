import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';
import 'package:downloads/downloads.dart';

ImportedLibraryEntry _entry(
  int chapter, {
  int pageCount = 1,
  String comicId = 'queue-comic',
  String comicTitle = '队列漫画',
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:$comicId',
        displayName: '第 $chapter 话',
        sourceId: 'queue-source',
        comicId: comicId,
        comicTitle: comicTitle,
        chapterId: comicId == 'queue-comic'
            ? 'queue-chapter-$chapter'
            : '$comicId-chapter-$chapter',
        sourceRevision: 'queue-r$chapter',
        sequence: chapter,
        pages: <ImportedPageRecord>[
          for (var page = 1; page <= pageCount; page++)
            ImportedPageRecord(
              displayName: '$chapter-$page.bin',
              sourceId: 'memory://queue-$chapter-$page',
              pageId: 'queue-page-$chapter-$page',
              contentKindHint: ContentKindHint.unknown,
              byteLength: 1,
            ),
        ],
      ),
    );

final class _CountingQueueStore implements WholeComicQueueStore {
  Map<String, Object?>? value;
  var saveCount = 0;

  @override
  Future<Map<String, Object?>?> load() async => value;

  @override
  Future<void> save(Map<String, Object?> data) async {
    saveCount++;
    value = Map<String, Object?>.from(data);
  }

  @override
  Future<void> close() async {}
}

Future<WholeComicQueueJobSnapshot> _waitForJob(
  WholeComicDownloadQueue queue,
  bool Function(WholeComicQueueJobSnapshot job) predicate,
) async {
  final current = queue.snapshot.jobFor('queue-source', 'queue-comic');
  if (current != null && predicate(current)) {
    return current;
  }
  final completer = Completer<WholeComicQueueJobSnapshot>();
  late final StreamSubscription<WholeComicQueueSnapshot> subscription;
  subscription = queue.changes.listen((snapshot) {
    final job = snapshot.jobFor('queue-source', 'queue-comic');
    if (job != null && predicate(job) && !completer.isCompleted) {
      completer.complete(job);
    }
  });
  try {
    return await completer.future.timeout(const Duration(seconds: 2));
  } finally {
    await subscription.cancel();
  }
}

void main() {
  test('empty durable queue does not persist default state on restore', () async {
    final store = _CountingQueueStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final queue = WholeComicDownloadQueue(
      downloads: downloads,
      store: store,
    );
    addTearDown(queue.close);

    await queue.ready;
    expect(store.saveCount, 0);

    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
    );
    expect(store.saveCount, greaterThan(0));
  });

  test('whole-comic queue enforces configured chapter concurrency', () async {
    var active = 0;
    var maxActive = 0;
    final release = Completer<void>();
    final twoStarted = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        active++;
        if (active > maxActive) {
          maxActive = active;
        }
        if (active == 2 && !twoStarted.isCompleted) {
          twoStarted.complete();
        }
        await release.future;
        active--;
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final queue = WholeComicDownloadQueue(downloads: downloads);
    addTearDown(queue.close);
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
    await queue.ready;
    await queue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 2),
    );

    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1), _entry(2), _entry(3)],
    );
    await twoStarted.future.timeout(const Duration(seconds: 2));
    expect(maxActive, 2);

    release.complete();
    final complete = await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(complete.completedChapters, 3);
  });

  test('whole-comic snapshot projects live page progress', () async {
    final secondPageStarted = Completer<void>();
    final releaseSecondPage = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, pageIndex) async {
        if (pageIndex == 1) {
          secondPageStarted.complete();
          await releaseSecondPage.future;
        }
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final queue = WholeComicDownloadQueue(downloads: downloads);
    addTearDown(queue.close);
    addTearDown(() {
      if (!releaseSecondPage.isCompleted) releaseSecondPage.complete();
    });
    await queue.ready;
    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1, pageCount: 2)],
    );

    await secondPageStarted.future.timeout(const Duration(seconds: 2));
    final progress = await _waitForJob(
      queue,
      (job) => job.completedPageUnits == 1,
    );
    expect(progress.completedChapters, 0);
    expect(progress.completedPages, 1);
    expect(progress.totalPages, 2);
    expect(progress.fraction, 0.5);

    releaseSecondPage.complete();
    final complete = await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(complete.completedPageUnits, 2);
    expect(complete.fraction, 1);
  });

  test('whole-comic queue waits for policy and resumes on environment change',
      () async {
    var loads = 0;
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        loads++;
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final environment = MutableWholeComicQueueEnvironment(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: false,
        charging: true,
      ),
    );
    addTearDown(environment.close);
    final queue = WholeComicDownloadQueue(
      downloads: downloads,
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
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
    );

    await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.waitingForPolicy,
    );
    expect(loads, 0);

    environment.update(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: true,
        charging: true,
      ),
    );
    await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(loads, 1);
  });

  test('policy loss suspends an active chapter and resumes it later', () async {
    final firstLoadStarted = Completer<void>();
    final releaseFirstLoad = Completer<void>();
    var loads = 0;
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        loads++;
        if (loads == 1) {
          firstLoadStarted.complete();
          await releaseFirstLoad.future;
        }
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final environment = MutableWholeComicQueueEnvironment(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: true,
        charging: true,
      ),
    );
    addTearDown(environment.close);
    final queue = WholeComicDownloadQueue(
      downloads: downloads,
      environment: environment,
    );
    addTearDown(queue.close);
    addTearDown(() {
      if (!releaseFirstLoad.isCompleted) {
        releaseFirstLoad.complete();
      }
    });
    await queue.ready;
    await queue.updatePolicy(
      const WholeComicQueuePolicy(
        network: WholeComicNetworkPolicy.unmetered,
      ),
    );
    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
    );
    await firstLoadStarted.future.timeout(const Duration(seconds: 2));

    environment.update(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: false,
        charging: true,
      ),
    );
    await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.waitingForPolicy,
    );
    releaseFirstLoad.complete();
    await Future<void>.delayed(Duration.zero);
    expect(
      queue.snapshot.jobFor('queue-source', 'queue-comic')?.phase,
      WholeComicQueuePhase.waitingForPolicy,
    );

    environment.update(
      const WholeComicQueueEnvironment(
        networkAvailable: true,
        unmetered: true,
        charging: true,
      ),
    );
    final complete = await _waitForJob(
      queue,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(complete.completedChapters, 1);
    expect(loads, 2);
  });

  test('paused whole-comic job survives queue recreation', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    var loads = 0;
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        loads++;
        if (!started.isCompleted) {
          started.complete();
        }
        await gate.future;
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final store = MemoryWholeComicQueueStore();
    final first = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(first.close);
    addTearDown(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    await first.ready;
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1), _entry(2)],
    );
    await started.future.timeout(const Duration(seconds: 2));
    final pause = first.pause(comicLibraryIdentity('queue-source', 'queue-comic'));
    gate.complete();
    await pause;
    final beforeClose = first.snapshot.jobFor('queue-source', 'queue-comic');
    expect(beforeClose?.phase, WholeComicQueuePhase.paused);
    expect(loads, 1);
    await first.close();

    final reopened = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(reopened.close);
    await reopened.ready;
    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored, isNotNull);
    expect(restored!.phase, WholeComicQueuePhase.paused);
    expect(restored.completedChapters, beforeClose!.completedChapters);
    await Future<void>.delayed(Duration.zero);
    expect(
      loads,
      1,
      reason: 'a restored paused job must not start another chapter',
    );
  });

  test('whole-comic queue persists placement parameters across restarts and enforces them', () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final store = MemoryWholeComicQueueStore();
    final first = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(first.close);
    await first.ready;
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
      placementDirectory: '自定义目录',
      placementMode: DownloadPlacementMode.overwrite,
      observedOwnerKey: 'old-source\u0000old-comic',
    );

    await _waitForJob(first, (job) => job.phase == WholeComicQueuePhase.complete);
    final placement = await downloads.getDownloadPlacement(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
    );
    expect(placement?.relativeDirectory, '自定义目录');
    expect(placement?.mode, DownloadPlacementMode.overwrite);
    expect(placement?.observedOwnerKey, 'old-source\u0000old-comic');
    await first.close();

    // Verify stored JSON has placement fields
    final storedJson = await store.load();
    expect(storedJson, isNotNull);
    final jobs = storedJson!['jobs'] as List<Object?>;
    final jobMap = jobs.first as Map<String, Object?>;
    expect(jobMap['placementDirectory'], '自定义目录');
    expect(jobMap['placementMode'], 'overwrite');
    expect(jobMap['observedOwnerKey'], 'old-source\u0000old-comic');

    // Reopen queue and verify placement survives
    final reopened = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(reopened.close);
    await reopened.ready;
    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored, isNotNull);
    expect(restored!.phase, WholeComicQueuePhase.complete);
  });

  test('enqueue with overwrite and observedOwnerKey displaces prior version comic job', () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final store = MemoryWholeComicQueueStore();
    final queue = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(queue.close);
    await queue.ready;

    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'old-comic',
      comicTitle: '旧版漫画',
      chapters: <ImportedLibraryEntry>[
        _entry(1, comicId: 'old-comic', comicTitle: '旧版漫画'),
      ],
    );
    expect(queue.snapshot.jobFor('queue-source', 'old-comic'), isNotNull);

    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'new-comic',
      comicTitle: '新版漫画',
      chapters: <ImportedLibraryEntry>[
        _entry(1, comicId: 'new-comic', comicTitle: '新版漫画'),
      ],
      placementDirectory: '漫画目录',
      placementMode: DownloadPlacementMode.overwrite,
      observedOwnerKey: 'queue-source\u0000old-comic',
    );

    expect(queue.snapshot.jobFor('queue-source', 'old-comic'), isNull);
    expect(queue.snapshot.jobFor('queue-source', 'new-comic'), isNotNull);
  });

  test('storage root change reconciles a completed job against the new authority',
      () async {
    final secondRunStarted = Completer<void>();
    final releaseSecondRun = Completer<void>();
    var loads = 0;
    final entry = _entry(1);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        loads++;
        if (loads == 2) {
          secondRunStarted.complete();
          await releaseSecondRun.future;
        }
        return Uint8List(1);
      },
    );
    final store = MemoryWholeComicQueueStore();
    final first = WholeComicDownloadQueue(
      downloads: downloads,
      store: store,
      storageRootId: 'root-a',
    );
    addTearDown(() async {
      if (!releaseSecondRun.isCompleted) releaseSecondRun.complete();
      await first.close();
      await downloads.close();
    });
    await first.ready;
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[entry],
    );
    await _waitForJob(first, (job) => job.phase == WholeComicQueuePhase.complete);
    await first.close();
    await downloads.delete(entry);

    final reopened = WholeComicDownloadQueue(
      downloads: downloads,
      store: store,
      storageRootId: 'root-b',
    );
    addTearDown(reopened.close);
    await reopened.ready;
    await secondRunStarted.future.timeout(const Duration(seconds: 2));

    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored, isNotNull);
    expect(restored!.phase, WholeComicQueuePhase.running);
    expect(restored.completedChapters, 0);
    expect(restored.completedPages, 0);
    expect((await store.load())?['storageRootId'], 'root-b');

    releaseSecondRun.complete();
    await _waitForJob(
      reopened,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(loads, 2);
  });

  test('queue close stays bounded when an active chapter does not exit',
      () async {
    final runStarted = Completer<void>();
    final releaseRun = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        runStarted.complete();
        await releaseRun.future;
        return Uint8List(1);
      },
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    addTearDown(() async {
      if (!releaseRun.isCompleted) releaseRun.complete();
      await queue.close();
      await downloads.close();
    });
    await queue.ready;
    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
    );
    await runStarted.future.timeout(const Duration(seconds: 2));

    final stopwatch = Stopwatch()..start();
    await runZoned(
      queue.close,
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) =>
            parent.createTimer(
          zone,
          duration == const Duration(seconds: 10)
              ? const Duration(milliseconds: 10)
              : duration,
          callback,
        ),
      ),
    );
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    releaseRun.complete();
    await downloads.close();
  });

  test('placement conflicts persist as typed user action and require re-enqueue',
      () async {
    var conflict = true;
    var loads = 0;
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async {
        loads++;
        if (conflict) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'download placement directory conflict',
            details: <String, Object?>{
              'directory': '队列漫画',
              'existingOwner': 'old-source\u0000old-comic',
              'requestOwner': 'queue-source\u0000queue-comic',
            },
          );
        }
        return Uint8List(1);
      },
    );
    addTearDown(downloads.close);
    final store = MemoryWholeComicQueueStore();
    final first = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(first.close);
    await first.ready;
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
      placementDirectory: '队列漫画',
      placementMode: DownloadPlacementMode.incremental,
      observedOwnerKey: 'old-source\u0000old-comic',
    );

    final blocked = await _waitForJob(
      first,
      (job) => job.phase == WholeComicQueuePhase.requiresUserAction,
    );
    expect(blocked.requiresUserAction, isTrue);
    expect(blocked.canRetry, isFalse);
    expect(
      blocked.userAction?.kind,
      WholeComicQueueUserActionKind.resolveDownloadPlacement,
    );
    expect(blocked.userAction?.directory, '队列漫画');
    expect(blocked.userAction?.existingOwnerKey, 'old-source\u0000old-comic');
    expect(blocked.userAction?.requestOwnerKey, 'queue-source\u0000queue-comic');
    expect(blocked.userAction?.chapterId, 'queue-chapter-1');
    await first.close();

    final reopened = WholeComicDownloadQueue(
      downloads: downloads,
      store: store,
    );
    addTearDown(reopened.close);
    await reopened.ready;
    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored?.phase, WholeComicQueuePhase.requiresUserAction);
    expect(restored?.userAction?.directory, '队列漫画');
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1, reason: 'restore must not retry without a new decision');

    conflict = false;
    await reopened.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
      placementDirectory: '队列漫画 (queue-source)',
      placementMode: DownloadPlacementMode.createNew,
    );
    final complete = await _waitForJob(
      reopened,
      (job) => job.phase == WholeComicQueuePhase.complete,
    );
    expect(complete.userAction, isNull);
    expect(loads, 2);
    final stored = await store.load();
    final storedJobs = stored!['jobs'] as List<Object?>;
    final storedJob = storedJobs.single as Map<String, Object?>;
    expect(storedJob['placementDirectory'], '队列漫画 (queue-source)');
    expect(storedJob['placementMode'], 'createNew');
    expect(storedJob['observedOwnerKey'], isNull);
  });

  test('new placement directory defaults to createNew instead of inheriting mode',
      () async {
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    addTearDown(downloads.close);
    final store = MemoryWholeComicQueueStore();
    final queue = WholeComicDownloadQueue(downloads: downloads, store: store);
    addTearDown(queue.close);
    await queue.ready;
    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
      placementDirectory: '旧目录',
      placementMode: DownloadPlacementMode.overwrite,
    );
    await _waitForJob(queue, (job) => job.phase == WholeComicQueuePhase.complete);
    await queue.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1)],
      placementDirectory: '新目录',
    );
    final stored = await store.load();
    final storedJobs = stored!['jobs'] as List<Object?>;
    final storedJob = storedJobs.single as Map<String, Object?>;
    expect(storedJob['placementDirectory'], '新目录');
    expect(storedJob['placementMode'], 'createNew');
  });
}
