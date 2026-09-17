import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_download_commands.dart';
import 'package:zic/home_library_session.dart';

void main() {
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
