import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_download_commands.dart';
import 'package:zic/download_command_lifetimes.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('Stop during source preparation cannot start a late chapter or queue', () async {
    for (final wholeComic in [false, true]) {
      final preparation = Completer<void>();
      final lifetimes = DownloadCommandLifetimes();
      var sourceRefreshes = 0;
      var pageLoads = 0;
      final downloads = MemoryChapterDownloadService(pageLoader: (_, _) async {
        pageLoads++;
        return Uint8List(1);
      });
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(library: MemoryImportedLibraryStore(),
        chapterDownloads: downloads, wholeComicDownloads: queue,
        sources: const [], ownsLibrary: true, ownsChapterDownloads: true,
        ownsWholeComicDownloads: true);
      await session.ready;
      final commands = HomeDownloadCommands(session: session,
        commandLifetimes: lifetimes,
        ensureDurableServices: () => preparation.future,
        ensurePlatformEnvironment: () async {},
        requiresSourceLocatorRefresh: (_) => true,
        refreshRemoteEntry: (entry, {required forceSourceRefresh}) async {
          sourceRefreshes++;
          return entry;
        }, refreshStaleChapter: (_) async => null);
      final entry = _entry();
      final Future<Object?> command = wholeComic
          ? commands.downloadComicEntries(comicLibraryIdentity(entry.chapter.sourceId,
              entry.chapter.comicId), [entry])
          : commands.downloadChapter(entry);
      expect(lifetimes.activeCount, 1,
          reason: 'foreground-service lifetime starts before durable/source waits');
      final failed = expectLater(command, throwsA(isA<Failure>()
        .having((failure) => failure.code, 'code', ErrorCode.cancelled)));
      var exited = false;
      final drain = lifetimes.cancelAll().then((_) => exited = true);
      await Future<void>.delayed(Duration.zero);
      expect(exited, false);
      preparation.complete();
      await Future.wait([failed, drain]);
      expect(sourceRefreshes, 0);
      expect(pageLoads, 0);
      expect(queue.snapshot.jobs, isEmpty);
      expect(lifetimes.activeCount, 0);
      await session.close();
      session.dispose();
      lifetimes.dispose();
    }
  });

  test('download commands follow the session service generation', () async {
    final firstLibrary = MemoryImportedLibraryStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List.fromList(<int>[1]),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {},
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async => null,
    );
    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List.fromList(<int>[2, 3, 4]),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    await session.ready;
    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );

    final snapshot = await commands.downloadChapter(_entry());

    expect(snapshot.isComplete, isTrue);
    expect(snapshot.receivedBytes, 3);
    expect((await secondDownloads.inspect(_entry())).isComplete, isTrue);
    await expectLater(
      firstDownloads.inspect(_entry()),
      throwsA(isA<StateError>()),
    );
  });

  test('metadata-only delete does not open durable download services', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List.fromList(<int>[1]),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    var durableAdoptions = 0;
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {
        durableAdoptions++;
      },
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async => null,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final entry = await session.upsertChapter(_entry().chapter);
    await commands.deleteChapter(entry);

    expect(durableAdoptions, 0);
    expect(
      await library.get(entry.chapter.sourceId, entry.chapter.chapterId),
      isNull,
    );
  });

  test('file deletion is durable and archive-only deletion keeps metadata',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List.fromList(<int>[1, 2]),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    var durableAdoptions = 0;
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {
        durableAdoptions++;
      },
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async => null,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final entry = await session.upsertChapter(_entry().chapter);
    downloads.seedPages(
      entry,
      <Uint8List?>[Uint8List.fromList(<int>[1, 2])],
      phase: ChapterDownloadPhase.complete,
    );

    await commands.deleteChapterFiles(entry);

    expect(durableAdoptions, 1);
    expect(
      await library.get(entry.chapter.sourceId, entry.chapter.chapterId),
      isNotNull,
    );
    expect((await downloads.inspect(entry)).isComplete, isFalse);

    downloads.seedPages(
      entry,
      <Uint8List?>[Uint8List.fromList(<int>[3, 4])],
      phase: ChapterDownloadPhase.complete,
    );
    await commands.deleteChapter(entry, deleteFiles: true);

    expect(durableAdoptions, 2);
    expect(
      await library.get(entry.chapter.sourceId, entry.chapter.chapterId),
      isNull,
    );
    expect((await downloads.inspect(entry)).isComplete, isFalse);
  });

  test('manager retry refreshes stale source locator before service mutation',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (entry, _) async {
        if (entry.chapter.sourceRevision != 'r2') {
          throw StateError('stale locator reached download service');
        }
        return Uint8List.fromList(<int>[7, 6, 5]);
      },
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    var sourceRefreshes = 0;
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {},
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (chapter) => chapter.sourceRevision == 'r1',
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async {
        sourceRefreshes++;
        expect(forceSourceRefresh, isTrue);
        return _entry(revision: 'r2');
      },
      refreshStaleChapter: (_) async => null,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final snapshot = await commands.retryChapter(_entry());

    expect(sourceRefreshes, 1);
    expect(snapshot.sourceRevision, 'r2');
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.receivedBytes, 3);
  });

  test('stale-token recovery retries only with refreshed chapter authority',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (entry, _) async {
        if (entry.chapter.sourceRevision == 'r1') {
          throw StateError('token expired');
        }
        return Uint8List.fromList(<int>[9, 8]);
      },
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    var staleRefreshes = 0;
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {},
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async {
        staleRefreshes++;
        return _entry(revision: 'r2');
      },
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final snapshot = await commands.downloadChapter(_entry());

    expect(staleRefreshes, 1);
    expect(snapshot.sourceRevision, 'r2');
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.receivedBytes, 2);
  });

  test('terminal source-plan replay refreshes chapter authority once', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (entry, _) async {
        if (entry.chapter.sourceRevision == 'r1') {
          throw const Failure(
            code: ErrorCode.source,
            message: 'source resource plan replay unavailable',
            details: <String, Object?>{
              'sourceResourcePlanReplayEligible': true,
              'sourceResourcePlanReplayAttempted': true,
              'sourceResourcePlanReplayUnavailable': true,
            },
          );
        }
        return Uint8List.fromList(<int>[6, 5, 4]);
      },
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    var staleRefreshes = 0;
    final commands = HomeDownloadCommands(
      session: session,
      ensureDurableServices: () async {},
      ensurePlatformEnvironment: () async {},
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) async => entry,
      refreshStaleChapter: (_) async {
        staleRefreshes++;
        return _entry(revision: 'r2');
      },
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final snapshot = await commands.downloadChapter(_entry());

    expect(staleRefreshes, 1);
    expect(snapshot.sourceRevision, 'r2');
    expect(snapshot.isComplete, isTrue);
    expect(snapshot.receivedBytes, 3);
  });
}

ImportedLibraryEntry _entry({String revision = 'r1'}) {
  const sourceId = 'fixture-source';
  const comicId = 'fixture-comic';
  const chapterId = 'fixture-chapter';
  final comic = Comic(
    comicId: comicId,
    sourceId: sourceId,
    title: 'Fixture comic',
    authors: const <String>[],
    readingDirection: ReadingDirection.ltr,
  );
  final chapter = Chapter(
    chapterId: chapterId,
    comicId: comicId,
    title: 'Fixture chapter',
    sequence: 1,
    pageCount: 1,
    sourceRevision: revision,
  );
  final manifest = ChapterManifest(
    sourceId: sourceId,
    comicId: comicId,
    chapter: chapter,
    readingDirection: ReadingDirection.ltr,
    pages: <PageAsset>[
      PageAsset(
        pageId: 'fixture-page',
        chapterId: chapterId,
        index: 0,
        uri: Uri.parse('https://example.invalid/page.webp'),
        contentKindHint: ContentKindHint.webp,
      ),
    ],
  );
  return ImportedLibraryEntry(
    chapter: ImportedChapterRecord.remote(comic: comic, manifest: manifest),
  );
}
