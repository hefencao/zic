import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';
import 'package:downloads/downloads.dart';

ImportedLibraryEntry _entry(int chapter) => ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture:queue-comic',
        displayName: '第 $chapter 话',
        sourceId: 'queue-source',
        comicId: 'queue-comic',
        comicTitle: '队列漫画',
        chapterId: 'queue-chapter-$chapter',
        sourceRevision: 'queue-r$chapter',
        sequence: chapter,
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '$chapter.bin',
            sourceId: 'memory://queue-$chapter',
            pageId: 'queue-page-$chapter',
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
}
