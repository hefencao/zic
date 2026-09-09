import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('home session owns durable projection outside DemoHome state', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.loading, isFalse);
    expect(session.error, isNull);
    expect(session.entries, isEmpty);
    expect(session.savedComics, isEmpty);
    expect(session.activeSourceId, isNull);

    var notifications = 0;
    session.addListener(() => notifications++);
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);

    session.replacePreference(preference);

    expect(session.preferences[preference.identity]?.liked, isTrue);
    expect(notifications, 1);
  });

  test('version relations publish page reuse candidates without Reader entry',
      () async {
    final root = await Directory.systemTemp.createTemp('version-owner-home-');
    final composition = await PersistentDownloadComposition.open(root.path);
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'old-comic',
      chapterId: 'old-chapter',
      revision: 'old-r1',
      pageCount: 2,
    );
    final newManifest = _versionManifest(
      comicId: 'new-comic',
      chapterId: 'new-chapter',
      revision: 'new-r1',
      pageCount: 3,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('old-comic'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('new-comic'),
        manifest: newManifest,
      ),
    );
    await library.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: 'version-source',
        predecessorComicId: 'old-comic',
        successorComicId: 'new-comic',
        pageMappings: const <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-chapter',
            successorChapterId: 'new-chapter',
            predecessorPageCount: 2,
            successorPageCount: 3,
            successorOffset: 1,
            predecessorSourceRevision: 'old-r1',
            successorSourceRevision: 'new-r1',
            verifiedPredecessorPageIndexes: <int>[0, 1],
          ),
        ],
      ),
    );
    final queue = WholeComicDownloadQueue(downloads: composition.chapterDownloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: composition.chapterDownloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: false,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await composition.close();
      await root.delete(recursive: true);
    });

    await session.ready;
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages[0]);
    final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    expect(composition.transferRuntime.versionCandidatesFor(oldId), contains(newId));
    expect(composition.transferRuntime.versionCandidatesFor(newId), contains(oldId));

    await session.removeChapter('version-source', 'new-chapter');
    expect(composition.transferRuntime.versionCandidatesFor(oldId), isEmpty);
  });

  test('batch hydration publishes reuse candidates without growing Home entries',
      () async {
    final root = await Directory.systemTemp.createTemp('version-owner-hydrate-');
    final composition = await PersistentDownloadComposition.open(root.path);
    final library = MemoryImportedLibraryStore();
    final queue = WholeComicDownloadQueue(downloads: composition.chapterDownloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: composition.chapterDownloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: false,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await composition.close();
      await root.delete(recursive: true);
    });
    await session.ready;
    expect(session.entries, isEmpty);

    final oldManifest = _versionManifest(
      comicId: 'old-comic',
      chapterId: 'old-chapter',
      revision: 'old-r1',
      pageCount: 2,
    );
    final newManifest = _versionManifest(
      comicId: 'new-comic',
      chapterId: 'new-chapter',
      revision: 'new-r1',
      pageCount: 3,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('old-comic'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('new-comic'),
        manifest: newManifest,
      ),
    );
    await session.upsertVersionRelation(
      const ComicVersionRelation(
        sourceId: 'version-source',
        predecessorComicId: 'old-comic',
        successorComicId: 'new-comic',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-chapter',
            successorChapterId: 'new-chapter',
            predecessorPageCount: 2,
            successorPageCount: 3,
            successorOffset: 1,
            predecessorSourceRevision: 'old-r1',
            successorSourceRevision: 'new-r1',
            verifiedPredecessorPageIndexes: <int>[0, 1],
          ),
        ],
      ),
    );
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages[0]);
    final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    expect(composition.transferRuntime.versionCandidatesFor(oldId), isEmpty);

    final hydrated = await session.hydrateChapterBatch(
      const <ImportedLibraryChapterKey>[
        ImportedLibraryChapterKey(
          sourceId: 'version-source',
          chapterId: 'old-chapter',
        ),
        ImportedLibraryChapterKey(
          sourceId: 'version-source',
          chapterId: 'new-chapter',
        ),
      ],
    );
    expect(hydrated, hasLength(2));
    expect(session.entries, isEmpty);
    expect(composition.transferRuntime.versionCandidatesFor(oldId), contains(newId));
    expect(composition.transferRuntime.versionCandidatesFor(newId), contains(oldId));
  });

  test('derived version page mappings do not broadcast Home projection',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final discoveredAt = DateTime.utc(2026, 9, 7);
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'old-gallery',
        successorComicId: 'new-gallery',
        predecessorTitle: 'Old',
        discoveredAt: discoveredAt,
      ),
    );

    var notifications = 0;
    session.addListener(() => notifications++);
    await session.upsertVersionRelationDerivedState(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'old-gallery',
        successorComicId: 'new-gallery',
        predecessorTitle: 'Old',
        discoveredAt: discoveredAt,
        pageMappings: const <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-chapter',
            successorChapterId: 'new-chapter',
            predecessorPageCount: 424,
            successorPageCount: 425,
            successorOffset: 1,
          ),
        ],
      ),
    );

    expect(notifications, 0);
    expect(session.versionRelations.single.pageMappings, hasLength(1));
    final persisted = await library.listComicVersionSuccessors(
      'venera:ehentai',
      'old-gallery',
    );
    expect(persisted.single.pageMappings, hasLength(1));
  });

  test('download projection changes do not rebuild the library projection',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    await queue.ready;
    await Future<void>.delayed(Duration.zero);

    var libraryNotifications = 0;
    var downloadNotifications = 0;
    session.addListener(() => libraryNotifications++);
    session.downloadProjectionChanges.addListener(
      () => downloadNotifications++,
    );
    session.acceptDownloadSnapshot(
      const ChapterDownloadSnapshot(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        comicTitle: 'Fixture',
        chapterId: 'fixture-chapter',
        sourceRevision: 'r1',
        title: 'Chapter 1',
        completedPages: 0,
        totalPages: 1,
        receivedBytes: 0,
        phase: ChapterDownloadPhase.idle,
      ),
    );

    expect(libraryNotifications, 0);
    expect(downloadNotifications, 1);
    expect(session.downloadSnapshots, hasLength(1));
  });

  test('startup can project missing preferences without durable writes',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final comic = SavedComicRecord(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      title: 'Fixture',
    );
    await delegate.upsertSavedComic(comic);
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
      persistMissingPreferences: false,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.preferences[comic.identity], isNotNull);
    expect(library.comicPreferenceWrites, 0);
  });

  test('chapter writes and final progress update the mounted Home projection',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;

    final chapter = ImportedChapterRecord(
      directoryId: 'remote:fixture',
      displayName: 'Chapter',
      sourceId: 'fixture-source',
      comicId: 'raw-current',
      comicTitle: 'Fixture',
      chapterId: 'chapter-1',
      sourceRevision: 'r1',
      importedAt: DateTime.utc(2026, 8, 8),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.jpg',
          sourceId: 'https://example.test/1.jpg',
          contentKindHint: ContentKindHint.jpeg,
          mediaFormat: 'jpeg',
          byteLength: 100,
        ),
      ],
    );

    final entry = await session.upsertChapter(chapter);
    expect(entry.chapter.chapterId, 'chapter-1');
    expect(session.entries, hasLength(1));

    session.replaceProgress(
      ReadingProgress(
        sourceId: 'fixture-source',
        comicId: 'raw-stale-alias',
        chapterId: 'chapter-1',
        pageIndex: 0,
        subPageOffset: 0.5,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 8, 8, 1),
      ),
    );
    expect(session.entries.single.progress?.comicId, 'raw-current');
    expect(session.entries.single.progress?.subPageOffset, 0.5);
    session.replaceReadState(
      ChapterReadState(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        isRead: true,
        updatedAt: DateTime.utc(2026, 8, 8, 1),
      ),
    );
    expect(session.readStates, hasLength(1));

    final saved = SavedComicRecord(
      sourceId: 'fixture-source',
      comicId: 'raw-current',
      title: 'Fixture',
    );
    await session.upsertSavedComic(saved);
    expect(session.savedComics.single.identity, saved.identity);
    await session.removeSavedComic(saved.sourceId, saved.comicId);
    expect(session.savedComics, isEmpty);

    await session.removeChapter(chapter.sourceId, chapter.chapterId);
    expect(session.entries, isEmpty);
    expect(session.readStates, isEmpty);
  });

  test('confirmed version relations are a write-through Home projection',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    await library.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'old-gallery',
        successorComicId: 'new-gallery',
        discoveredAt: DateTime.utc(2026, 8, 11),
        pageMappings: const <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-chapter',
            successorChapterId: 'new-chapter',
            predecessorPageCount: 370,
            successorPageCount: 371,
            successorOffset: 1,
          ),
        ],
      ),
    );
    await library.close();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    expect(session.versionRelations, hasLength(1));
    expect(session.versionRelations.single.predecessorComicId, 'old-gallery');
    expect(session.versionRelations.single.pageMappings, hasLength(1));

    // Shelf/download heads are materialized facts, not aliases for the newest
    // discovered source version.
    session.replacePreference(
      ComicPreference.defaults(
        sourceId: 'venera:ehentai',
        comicId: 'new-gallery',
        sourceKind: ComicSourceKind.remote,
      ),
    );
    session.acceptDownloadSnapshot(
      const ChapterDownloadSnapshot(
        sourceId: 'venera:ehentai',
        comicId: 'old-gallery',
        comicTitle: 'Fixture',
        chapterId: 'old-chapter',
        sourceRevision: 'r1',
        title: 'Old',
        completedPages: 1,
        totalPages: 1,
        receivedBytes: 1,
        pinnedPages: 1,
        phase: ChapterDownloadPhase.complete,
        started: true,
      ),
    );
    expect(
      session.versionBaselines.latestKnownHeadFor(
        'venera:ehentai',
        'old-gallery',
      ),
      'new-gallery',
    );
    expect(
      session.versionBaselines.shelfHeadFor('venera:ehentai', 'old-gallery'),
      'new-gallery',
    );
    expect(
      session.versionBaselines.downloadHeadFor('venera:ehentai', 'old-gallery'),
      'old-gallery',
    );

    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'new-gallery',
        successorComicId: 'newest-gallery',
        discoveredAt: DateTime.utc(2026, 8, 11, 1),
      ),
    );
    expect(session.versionRelations, hasLength(2));
    expect(
      session.versionBaselines.latestKnownHeadFor(
        'venera:ehentai',
        'old-gallery',
      ),
      'newest-gallery',
    );
    expect(
      session.versionBaselines.shelfHeadFor('venera:ehentai', 'old-gallery'),
      'new-gallery',
    );
    expect(
      session.versionBaselines.downloadHeadFor('venera:ehentai', 'old-gallery'),
      'old-gallery',
    );
    session.acceptDownloadSnapshot(
      const ChapterDownloadSnapshot(
        sourceId: 'venera:ehentai',
        comicId: 'newest-gallery',
        comicTitle: 'Fixture',
        chapterId: 'newest-chapter',
        sourceRevision: 'r1',
        title: 'Newest',
        completedPages: 1,
        totalPages: 1,
        receivedBytes: 1,
        pinnedPages: 1,
        phase: ChapterDownloadPhase.complete,
        started: true,
      ),
    );
    expect(
      session.versionBaselines.downloadHeadFor('venera:ehentai', 'old-gallery'),
      'newest-gallery',
    );
    final durable = await library.listAllComicVersionRelations();
    expect(durable, hasLength(2));
  });

  test('stale reload snapshot cannot overwrite a write-through chapter',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final categories = Completer<List<LibraryCategory>>();
    final library = _GatedLibraryStore(delegate, categories.future);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final primaryFrame = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: () => primaryFrame.future,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    // _reload has already captured its empty primary snapshot when it waits for
    // this frame barrier. A newly materialized chapter must become the newer
    // mounted projection and survive the rest of that old reload.
    await Future<void>.delayed(Duration.zero);
    final chapter = ImportedChapterRecord(
      directoryId: 'remote:race',
      displayName: 'Race Chapter',
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      comicTitle: 'Fixture',
      chapterId: 'chapter-race',
      sourceRevision: 'r1',
      importedAt: DateTime.utc(2026, 8, 8),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.jpg',
          sourceId: 'https://example.test/race.jpg',
          contentKindHint: ContentKindHint.jpeg,
          mediaFormat: 'jpeg',
          byteLength: 100,
        ),
      ],
    );
    await session.upsertChapter(chapter);
    expect(session.entries.single.chapter.chapterId, 'chapter-race');

    primaryFrame.complete();
    categories.complete(const <LibraryCategory>[]);
    await session.ready;

    expect(session.entries, hasLength(1));
    expect(session.entries.single.chapter.chapterId, 'chapter-race');
  });

  test('publishes cover-bearing primary library before enrichment finishes',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    await delegate.upsertSavedComic(
      SavedComicRecord(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        title: 'Fixture Comic',
        coverSourceId: 'https://example.test/cover.webp',
      ),
    );
    final categories = Completer<List<LibraryCategory>>();
    final library = _GatedLibraryStore(delegate, categories.future);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final primaryFrame = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: () => primaryFrame.future,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    var readyCompleted = false;
    unawaited(session.ready.then((_) => readyCompleted = true));
    for (var attempt = 0;
        attempt < 20 && session.savedComics.isEmpty;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(session.savedComics, hasLength(1));
    expect(session.savedComics.single.coverSourceId, isNotNull);
    expect(session.loading, isTrue);
    expect(readyCompleted, isFalse);

    categories.complete(const <LibraryCategory>[]);
    primaryFrame.complete();
    await session.ready;
    expect(session.loading, isFalse);
  });

  test('explicit Home projection flush drains the latest queued snapshot',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-session-exit-flush-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      libraryRevision: 42,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      snapshotStore: snapshotStore,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);
    session.replacePreference(preference);

    await session.flushSnapshotWrites();

    final persisted = await snapshotStore.read();
    expect(persisted?.libraryRevision, 42);
    expect(
      persisted?.preferences.singleWhere(
        (candidate) => candidate.identity == preference.identity,
      ).liked,
      isTrue,
    );
  });

  test('explicit checkpoint rewrites snapshot after durable revision advances',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-session-exit-checkpoint-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    final library = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      libraryRevision: 42,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      snapshotStore: snapshotStore,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    await session.flushSnapshotWrites();
    expect((await snapshotStore.read())?.libraryRevision, 42);

    // Models a Reader progress writer committing after the last ordinary Home
    // mutation: Home data is unchanged, but the durable revision advanced.
    library.libraryRevision = 43;
    await session.checkpointSnapshot();

    expect((await snapshotStore.read())?.libraryRevision, 43);
  });

  test('shows the previous Home snapshot before reconciling SQLite data',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-session-snapshot-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    final oldChapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/old',
      displayName: 'Old chapter',
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'old.jpg',
          sourceId: '${directory.path}/old/old.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final currentChapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/current',
      displayName: 'Current chapter',
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'current.jpg',
          sourceId: '${directory.path}/current/current.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    await snapshotStore.write(
      HomeProjectionSnapshot(
        entries: <ImportedLibraryEntry>[
          ImportedLibraryEntry(chapter: oldChapter),
        ],
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
      ),
    );

    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    await delegate.upsertChapter(currentChapter);
    final openGate = Completer<void>();
    final categories = Completer<List<LibraryCategory>>();
    final library = _GatedLibraryStore(
      delegate,
      categories.future,
      openGate: openGate.future,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final primaryFrame = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      snapshotStore: snapshotStore,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: () => primaryFrame.future,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    for (var attempt = 0;
        attempt < 100 && session.entries.isEmpty;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(session.entries.single.chapter.displayName, 'Old chapter');

    openGate.complete();
    categories.complete(const <LibraryCategory>[]);
    primaryFrame.complete();
    await session.ready;
    expect(session.entries.single.chapter.displayName, 'Current chapter');

    HomeProjectionSnapshot? persisted;
    for (var attempt = 0; attempt < 100; attempt++) {
      persisted = await snapshotStore.read();
      if (persisted?.entries.single.chapter.displayName == 'Current chapter') {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(persisted?.entries.single.chapter.displayName, 'Current chapter');
  });

  test('reuses a snapshot when the durable projection revision is unchanged',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-session-revision-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Cached chapter',
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: '${directory.path}/chapter/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    await snapshotStore.write(
      HomeProjectionSnapshot(
        entries: <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
        libraryRevision: 7,
      ),
    );
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    await delegate.upsertChapter(chapter);
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      libraryRevision: 7,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      snapshotStore: snapshotStore,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.entries.single.chapter.displayName, 'Cached chapter');
    expect(library.listCalls, 0);
    expect(session.loading, isFalse);
  });

  test('bootstrap does not reconcile a snapshot against empty memory storage',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-bootstrap-snapshot-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Bootstrap chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'file:///bootstrap/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    await snapshotStore.write(
      HomeProjectionSnapshot(
        entries: <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
        chapterDownloads: <HomeChapterDownloadSummary>[
          HomeChapterDownloadSummary(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            comicTitle: chapter.comicTitle,
            chapterId: chapter.chapterId,
            sourceRevision: chapter.sourceRevision,
            title: chapter.displayName,
            completedPages: 1,
            totalPages: 1,
            receivedBytes: 4,
            pinnedPages: 1,
            exactCompletedPages: 1,
            totalBytes: 4,
            phase: 'complete',
            started: true,
          ),
        ],
      ),
    );
    final memory = MemoryImportedLibraryStore();
    await memory.open();
    final library = _GatedLibraryStore(
      memory,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      snapshotStore: snapshotStore,
      persistSnapshot: false,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.entries.single.chapter.displayName, 'Bootstrap chapter');
    expect(session.downloadSnapshots, hasLength(1));
    expect(
      session.downloadSnapshots.values.single.phase,
      ChapterDownloadPhase.complete,
    );
    expect(library.listCalls, 0);
  });

  test('durable service handoff keeps the matching snapshot projection',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-service-handoff-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Handoff chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'file:///handoff/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final snapshotStore = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );
    await snapshotStore.write(
      HomeProjectionSnapshot(
        entries: <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
        chapterDownloads: <HomeChapterDownloadSummary>[
          HomeChapterDownloadSummary(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            comicTitle: chapter.comicTitle,
            chapterId: chapter.chapterId,
            sourceRevision: chapter.sourceRevision,
            title: chapter.displayName,
            completedPages: 1,
            totalPages: 1,
            receivedBytes: 4,
            pinnedPages: 1,
            exactCompletedPages: 1,
            totalBytes: 4,
            phase: 'complete',
            started: true,
          ),
        ],
        libraryRevision: 7,
      ),
    );

    final bootstrapLibrary = MemoryImportedLibraryStore();
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(
      downloads: bootstrapDownloads,
    );
    final durableDelegate = MemoryImportedLibraryStore();
    final durableLibrary = _GatedLibraryStore(
      durableDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      libraryRevision: 7,
    );
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    final primaryFrame = Completer<void>();
    final presentationFrame = Completer<void>();
    var frameWaitCalls = 0;
    Future<void> waitForFrame() {
      frameWaitCalls++;
      return frameWaitCalls == 1
          ? primaryFrame.future
          : presentationFrame.future;
    }
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      snapshotStore: snapshotStore,
      persistSnapshot: false,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: waitForFrame,
    );
    addTearDown(() async {
      if (!primaryFrame.isCompleted) {
        primaryFrame.complete();
      }
      if (!presentationFrame.isCompleted) {
        presentationFrame.complete();
      }
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
      await durableLibrary.close();
    });

    await session.ready;
    expect(
      session.downloadSnapshots.values.single.phase,
      ChapterDownloadPhase.complete,
    );

    await session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: true,
    );

    expect(session.entries.single.chapter.displayName, 'Handoff chapter');
    expect(
      session.downloadSnapshots.values.single.phase,
      ChapterDownloadPhase.complete,
    );
    expect(durableLibrary.listCalls, 0);
    expect(session.loading, isFalse);

    for (var attempt = 0; attempt < 20 && frameWaitCalls < 1; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(frameWaitCalls, 1);

    primaryFrame.complete();
    for (var attempt = 0; attempt < 20 && frameWaitCalls < 2; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(frameWaitCalls, 2);
    expect(
      session.downloadSnapshots.values.single.phase,
      ChapterDownloadPhase.complete,
      reason: 'download reconciliation must not preempt the successor Home frame',
    );

    presentationFrame.complete();
    for (var attempt = 0;
        attempt < 20 &&
            session.downloadSnapshots.values.single.phase !=
                ChapterDownloadPhase.idle;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      session.downloadSnapshots.values.single.phase,
      ChapterDownloadPhase.idle,
    );

    HomeProjectionSnapshot? persisted;
    for (var attempt = 0; attempt < 100; attempt++) {
      persisted = await snapshotStore.read();
      if (persisted?.chapterDownloads.isEmpty == true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(persisted?.chapterDownloads, isEmpty);
  });


  test('chapter batch hydration uses one targeted store lookup', () async {
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
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
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;
    final first = ImportedChapterRecord.folder(
      directoryId: '/batch/one',
      displayName: 'one',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///batch/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final second = ImportedChapterRecord.folder(
      directoryId: '/batch/two',
      displayName: 'two',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///batch/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await delegate.upsertChapter(first);
    await delegate.upsertChapter(second);

    final hydrated = await session.hydrateChapterBatch(
      <ImportedLibraryChapterKey>[
        ImportedLibraryChapterKey(
          sourceId: first.sourceId,
          chapterId: first.chapterId,
        ),
        ImportedLibraryChapterKey(
          sourceId: second.sourceId,
          chapterId: second.chapterId,
        ),
        ImportedLibraryChapterKey(
          sourceId: first.sourceId,
          chapterId: first.chapterId,
        ),
      ],
    );

    expect(hydrated, hasLength(2));
    expect(library.getManyCalls, 1);
    expect(library.getCalls, 0);
  });
}


Comic _versionComic(String comicId) => Comic(
      comicId: comicId,
      sourceId: 'version-source',
      title: comicId,
      authors: const <String>[],
      readingDirection: ReadingDirection.ltr,
    );

ChapterManifest _versionManifest({
  required String comicId,
  required String chapterId,
  required String revision,
  required int pageCount,
}) {
  final chapter = Chapter(
    chapterId: chapterId,
    comicId: comicId,
    title: chapterId,
    sequence: 1,
    pageCount: pageCount,
    sourceRevision: revision,
  );
  return ChapterManifest(
    sourceId: 'version-source',
    comicId: comicId,
    chapter: chapter,
    readingDirection: ReadingDirection.ltr,
    pages: <PageAsset>[
      for (var index = 0; index < pageCount; index++)
        PageAsset(
          pageId: '$chapterId-page-$index',
          chapterId: chapterId,
          index: index,
          uri: Uri.parse('https://example.test/$comicId/$index.webp'),
          contentKindHint: ContentKindHint.webp,
        ),
    ],
  );
}

final class _GatedLibraryStore
    implements
        ImportedLibraryStore,
        ImportedLibraryBatchLookup,
        ImportedLibraryRevisionStore {
  _GatedLibraryStore(
    this.delegate,
    this.categories, {
    this.openGate,
    this.libraryRevision,
  });

  final ImportedLibraryStore delegate;
  final Future<List<LibraryCategory>> categories;
  final Future<void>? openGate;
  int? libraryRevision;
  var comicPreferenceWrites = 0;
  var sourcePreferenceWrites = 0;
  var listCalls = 0;
  var getCalls = 0;
  var getManyCalls = 0;

  @override
  Future<int?> get libraryProjectionRevision async => libraryRevision;

  @override
  Future<void> open() async {
    await openGate;
    await delegate.open();
  }
  @override
  Future<List<ImportedLibraryEntry>> list() {
    listCalls++;
    return delegate.list();
  }
  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) {
    getCalls++;
    return delegate.get(sourceId, chapterId);
  }
  @override
  Future<List<ImportedLibraryEntry>> getMany(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) {
    getManyCalls++;
    return (delegate as ImportedLibraryBatchLookup).getMany(chapters);
  }
  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) =>
      delegate.upsertChapter(chapter);
  @override
  Future<void> saveProgress(ReadingProgress progress) =>
      delegate.saveProgress(progress);
  @override
  Future<void> removeChapter(String sourceId, String chapterId) =>
      delegate.removeChapter(sourceId, chapterId);
  @override
  Future<List<SavedComicRecord>> listSavedComics() =>
      delegate.listSavedComics();
  @override
  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId) =>
      delegate.getSavedComic(sourceId, comicId);
  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) =>
      delegate.upsertSavedComic(comic);
  @override
  Future<void> removeSavedComic(String sourceId, String comicId) =>
      delegate.removeSavedComic(sourceId, comicId);
  @override
  Future<List<LibraryCategory>> listCategories() => categories;
  @override
  Future<void> upsertCategory(LibraryCategory category) =>
      delegate.upsertCategory(category);
  @override
  Future<void> removeCategory(String categoryId) =>
      delegate.removeCategory(categoryId);
  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      delegate.listComicPreferences();
  @override
  Future<ComicPreference?> getComicPreference(String sourceId, String comicId) =>
      delegate.getComicPreference(sourceId, comicId);
  @override
  Future<void> saveComicPreference(ComicPreference preference) =>
      Future<void>(() {
        comicPreferenceWrites++;
        return delegate.saveComicPreference(preference);
      });
  @override
  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  ) =>
      delegate.listChapterReadStates(sourceId, comicId);
  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      delegate.listAllChapterReadStates();
  @override
  Future<void> saveChapterReadState(ChapterReadState state) =>
      delegate.saveChapterReadState(state);
  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      delegate.listSourcePreferences();
  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) =>
      Future<void>(() {
        sourcePreferenceWrites++;
        return delegate.saveSourcePreference(preference);
      });
  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) =>
      delegate.listMigrationIssues(includeAcknowledged: includeAcknowledged);
  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) =>
      delegate.acknowledgeMigrationIssues(
        issueIds,
        acknowledgedAt: acknowledgedAt,
      );
  @override
  Future<void> close() => delegate.close();
}
