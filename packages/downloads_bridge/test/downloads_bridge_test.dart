import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:test/test.dart';

void main() {
  test('JSON queue adapter restores policy and pending chapters', () async {
    final directory = await Directory.systemTemp.createTemp('zic-whole-queue-');
    addTearDown(() => directory.delete(recursive: true));
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    final path = '${directory.path}/queue.json';
    final first = await openPersistentWholeComicDownloadQueue(
      path: path,
      downloads: downloads,
      environment: environment,
    );
    await first.updatePolicy(
      const WholeComicQueuePolicy(
        concurrency: 3,
        network: WholeComicNetworkPolicy.unmetered,
      ),
    );
    await first.enqueue(
      sourceId: 'queue-source',
      comicId: 'queue-comic',
      comicTitle: '队列漫画',
      chapters: <ImportedLibraryEntry>[_entry(1), _entry(2)],
    );
    await _waitForPhase(first, WholeComicQueuePhase.waitingForPolicy);
    await first.close();

    final reopened = await openPersistentWholeComicDownloadQueue(
      path: path,
      downloads: downloads,
      environment: environment,
    );
    addTearDown(reopened.close);
    expect(reopened.snapshot.policy.concurrency, 3);
    expect(
      reopened.snapshot.policy.network,
      WholeComicNetworkPolicy.unmetered,
    );
    final restored = reopened.snapshot.jobFor('queue-source', 'queue-comic');
    expect(restored, isNotNull);
    expect(restored!.totalChapters, 2);
    expect(restored.phase, WholeComicQueuePhase.waitingForPolicy);
  });
}

Future<void> _waitForPhase(
  WholeComicDownloadQueue queue,
  WholeComicQueuePhase phase,
) async {
  if (queue.snapshot.jobs.any((job) => job.phase == phase)) {
    return;
  }
  await queue.changes.firstWhere(
    (snapshot) => snapshot.jobs.any((job) => job.phase == phase),
  );
}

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
