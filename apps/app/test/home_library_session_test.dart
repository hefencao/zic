import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('cold SQLite records preserve legacy canonical reuse and refresh locators',
      () async {
    final root = await Directory.systemTemp.createTemp('home-summary-reuse-');
    final composition = await PersistentDownloadComposition.open(root.path,
      transferNet: DownloadResourceCoordinator().networkLane);
    final library = SqliteImportedLibraryStore('${root.path}/library.sqlite');
    await library.open();
    final oldManifest = _versionManifest(comicId: 'old-comic',
      chapterId: 'old-chapter', revision: 'old-r1', pageCount: 2);
    final newManifest = _versionManifest(comicId: 'new-comic',
      chapterId: 'new-chapter', revision: 'new-r1', pageCount: 3);
    final oldRecord = ImportedChapterRecord.remote(
      comic: _versionComic('old-comic'), manifest: oldManifest);
    final newRecord = ImportedChapterRecord.remote(
      comic: _versionComic('new-comic'), manifest: newManifest);
    await library.upsertChapter(oldRecord);
    await library.upsertChapter(newRecord);
    await library.saveComicVersionRelation(const ComicVersionRelation(
      sourceId: 'version-source', predecessorComicId: 'old-comic',
      successorComicId: 'new-comic', pageMappings: [ComicVersionPageMapping(
        predecessorChapterId: 'old-chapter', successorChapterId: 'new-chapter',
        predecessorPageCount: 2, successorPageCount: 3, successorOffset: 1,
        predecessorSourceRevision: 'old-r1', successorSourceRevision: 'new-r1',
        verifiedPredecessorPageIndexes: [0, 1],
      )],
    ));
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages[0]);
    final body = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6jXcAAAAASUVORK5CYII=');
    await composition.artifactStore.storePromotedArtifact(id: oldId, bytes: body);
    final session = HomeLibrarySession(library: library,
      chapterDownloads: composition.chapterDownloads,
      wholeComicDownloads: WholeComicDownloadQueue(downloads: composition.chapterDownloads),
      sources: const <BrowsableComicSource>[], ownsLibrary: true,
      ownsChapterDownloads: false, ownsWholeComicDownloads: true);
    addTearDown(() async {
      await session.close(); session.dispose();
      await composition.close(); await root.delete(recursive: true);
    });
    await session.ready;
    expect(session.error, isNull);
    expect(session.entries.every((entry) => !entry.chapter.isSummary), isTrue);
    final current = await session.hydrateEntry(session.entries.singleWhere(
      (entry) => entry.chapter.chapterId == 'new-chapter'));
    await session.ensureCanonicalMediaForEntry(current);
    final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    final physical = composition.transferRuntime.physicalMediaIdFor(newId);
    expect(physical.isExactFallback, isFalse);
    expect(composition.transferRuntime.physicalMediaIdFor(oldId), physical);
    final cached = await composition.artifactCacheManager.openPhysicalArtifact(physical);
    expect(cached, isNotNull);
    final chunks = await cached!.open(start: 0).toList();
    expect(chunks.expand((chunk) => chunk), orderedEquals(body));
    final updated = newRecord.copyWith(pages: [
      newRecord.pages.first,
      const ImportedPageRecord(displayName: 'fresh.png', sourceId: 'memory:fresh.png',
        pageId: 'fresh', contentKindHint: ContentKindHint.png),
      newRecord.pages.last,
    ]);
    await library.upsertChapter(updated);
    await session.reload();
    final hydrated = await session.hydrateEntry(session.entries.singleWhere(
      (entry) => entry.chapter.chapterId == 'new-chapter'));
    expect(hydrated.chapter.sourceRevision, newRecord.sourceRevision);
    expect(hydrated.chapter.pages[1].sourceId, 'memory:fresh.png');
  });

  test('chapter-download relay publishes capability changes', () {
    final handoff = HomeServiceHandoff();
    addTearDown(handoff.dispose);
    var notifications = 0;
    handoff.addListener(() => notifications++);
    Future<String?> relay({String? directory, required bool migrateFiles}) async =>
        null;

    handoff.setChapterDownloadRelay(relay);
    expect(notifications, 1);
    handoff.setChapterDownloadRelay(relay);
    expect(notifications, 1);
    handoff.setChapterDownloadRelay(null);
    expect(notifications, 2);
  });

  test('download composition normalization has one explicit-first authority', () async {
    final root = await Directory.systemTemp.createTemp(
      'home-download-composition-authority-',
    );
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    addTearDown(() async {
      await composition.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    final chapterDownloads = composition.chapterDownloads;

    expect(chapterDownloads, isA<ChapterDownloadTransferRuntimeProvider>());
    expect(
      HomeLibrarySession.resolveDownloadComposition(chapterDownloads, null),
      same(chapterDownloads),
    );
    expect(
      HomeLibrarySession.resolveDownloadComposition(
        chapterDownloads,
        composition,
      ),
      same(composition),
    );
  });

  test('home session owns durable projection outside HomeShell state', () async {
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

  test('persisted reading progress preserves source update evidence', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library, chapterDownloads: downloads, wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[], ownsLibrary: true,
      ownsChapterDownloads: true, ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;
    final signal = DateTime.utc(2026, 8, 8);
    final chapter = ImportedChapterRecord(
      directoryId: 'progress-signal', displayName: 'Chapter',
      sourceId: 'fixture', comicId: 'comic', chapterId: 'chapter',
      sourceRevision: 'r1', pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'page', sourceId: 'memory:page.png', pageId: 'page',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await session.upsertChapter(chapter);
    await session.upsertSavedComic(SavedComicRecord(
      sourceId: 'fixture', comicId: 'comic', title: 'Comic',
      sourceUpdateAt: signal, unseenChapterIds: const <String>['chapter'],
    ));
    await session.persistProgress(ReadingProgress(
      sourceId: 'fixture', comicId: 'comic', chapterId: 'chapter',
      pageIndex: 0, subPageOffset: .5, readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 10, 3),
    ));
    expect(session.entries.single.progress!.subPageOffset, .5);
    expect((await library.get('fixture', 'chapter'))!.progress!.subPageOffset, .5);
    expect(session.savedComics.single.sourceUpdateAt, signal);
    final stored = (await library.getSavedComic('fixture', 'comic'))!;
    expect(stored.sourceUpdateAt, signal);
    expect(stored.unseenChapterIds, <String>{'chapter'});
  });

  test('service adoption does not wait for unrelated Home list reconciliation',
      () async {
    final bootstrap = MemoryImportedLibraryStore();
    final oldDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final oldQueue = WholeComicDownloadQueue(downloads: oldDownloads);
    final listGate = Completer<void>();
    final durable = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future.value(const <LibraryCategory>[]),
    )
      ..listReturnGate = listGate.future
      ..listStarted = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: bootstrap,
      chapterDownloads: oldDownloads,
      wholeComicDownloads: oldQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      if (!listGate.isCompleted) listGate.complete();
      await session.close();
      session.dispose();
      await queue.close();
      await downloads.close();
      await durable.close();
    });
    await session.ready;
    await durable.open();
    final chapter = ImportedChapterRecord(
      directoryId: 'selected',
      displayName: 'Selected',
      sourceId: 'fixture',
      comicId: 'comic',
      chapterId: 'chapter',
      sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'page',
          sourceId: 'file:///selected.png',
          pageId: 'page',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await durable.upsertChapter(chapter);
    var adopted = false;
    final adoption = session.adoptServices(
      library: durable,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    ).then((_) => adopted = true);
    await durable.listStarted!.future;
    await Future<void>.delayed(Duration.zero);
    expect(adopted, isTrue,
        reason: 'runtime capability binding must not join the Home list scan');
    expect(session.library, same(durable));
    expect(session.chapterDownloads, same(downloads));
    var reconciled = false;
    unawaited(session.ready.then((_) => reconciled = true));
    final selected = await session.hydrateEntry(
      ImportedLibraryEntry(chapter: chapter),
      awaitCanonicalPhysicalBackfill: false,
    );
    expect(selected.chapter.pages.single.sourceId, 'file:///selected.png');
    expect(durable.getCalls, 1);
    expect(reconciled, isFalse);
    listGate.complete();
    await adoption;
    await session.ready;
    expect(reconciled, isTrue);
  });

  test('failed authority read leaves old bindings intact and adoption retries',
      () async {
    final bootstrap = MemoryImportedLibraryStore();
    final oldDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final oldQueue = WholeComicDownloadQueue(downloads: oldDownloads);
    final durable = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future.value(const <LibraryCategory>[]),
    )..versionRelationReadError = StateError('authority unavailable');
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: bootstrap,
      chapterDownloads: oldDownloads,
      wholeComicDownloads: oldQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await queue.close();
      await downloads.close();
      await durable.close();
    });
    await session.ready;
    Future<void> adopt() => session.adoptServices(
      library: durable,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    await expectLater(adopt(), throwsStateError);
    expect(session.library, same(bootstrap));
    expect(session.chapterDownloads, same(oldDownloads));
    expect(await bootstrap.list(), isEmpty);
    expect(durable.listCalls, 0);
    durable.versionRelationReadError = null;
    await adopt();
    expect(session.library, same(durable));
    await session.ready;
  });

  test('close drains reconciliation installed by an admitted adoption', () async {
    final oldDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final oldQueue = WholeComicDownloadQueue(downloads: oldDownloads);
    final session = HomeLibrarySession(
      library: MemoryImportedLibraryStore(),
      chapterDownloads: oldDownloads,
      wholeComicDownloads: oldQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final authorityGate = Completer<void>();
    final listGate = Completer<void>();
    final durable = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future.value(const <LibraryCategory>[]),
    )
      ..versionRelationReadGate = authorityGate.future
      ..versionRelationReadStarted = Completer<void>()
      ..listReturnGate = listGate.future
      ..listStarted = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    addTearDown(() async {
      if (!authorityGate.isCompleted) authorityGate.complete();
      if (!listGate.isCompleted) listGate.complete();
      await session.close();
      session.dispose();
      await queue.close();
      await downloads.close();
      await durable.close();
    });
    await session.ready;
    final adoption = session.adoptServices(
      library: durable,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    await durable.versionRelationReadStarted!.future;
    var closed = false;
    final closing = session.close().then((_) => closed = true);
    authorityGate.complete();
    await adoption;
    await durable.listStarted!.future;
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse,
        reason: 'adoption completion is not projection-tail completion');
    listGate.complete();
    await closing;
    expect(closed, isTrue);
  });

  test('same-service adoption refreshes source projection identity', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final firstSource = MangaDexSource(translatedLanguage: 'en');
    final replacementSource = MangaDexSource(translatedLanguage: 'ja');
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: <BrowsableComicSource>[firstSource],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    await session.adoptServices(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: <BrowsableComicSource>[replacementSource],
      persistSnapshot: false,
    );

    expect(session.sources, hasLength(1));
    expect(session.sources.single, same(replacementSource));
  });

  test('library generation signal publishes only library authority changes',
      () async {
    final bootstrapLibrary = MemoryImportedLibraryStore();
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue =
        WholeComicDownloadQueue(downloads: bootstrapDownloads);
    final durableLibrary = MemoryImportedLibraryStore();
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
      await durableLibrary.close();
    });

    await session.ready;
    var notifications = 0;
    session.libraryGenerationChanges.addListener(() => notifications++);

    await session.adoptServices(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    expect(notifications, 0);

    await session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );

    expect(session.library, same(durableLibrary));
    expect(notifications, 1);
  });

  test('service adoption publishes the current whole-comic policy generation',
      () async {
    final bootstrapLibrary = MemoryImportedLibraryStore();
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(downloads: bootstrapDownloads);
    final durableLibrary = MemoryImportedLibraryStore();
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    await durableQueue.ready;
    await durableQueue.updatePolicy(
      const WholeComicQueuePolicy(concurrency: 3),
    );
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
      await durableLibrary.close();
    });

    await session.ready;
    final observedPolicies = <int>[];
    session.downloadProjectionChanges.addListener(() {
      observedPolicies.add(
        session.wholeComicQueueSnapshot.policy.concurrency,
      );
    });

    await session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    for (var attempt = 0;
        attempt < 20 && !observedPolicies.contains(3);
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(session.wholeComicQueueSnapshot.policy.concurrency, 3);
    expect(observedPolicies, contains(3));
  });

  test('dispose does not suppress later owned-resource close', () async {
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
    await session.ready;
    final manifest = _versionManifest(
      comicId: 'dispose-close-comic',
      chapterId: 'dispose-close-chapter',
      revision: 'dispose-close-r1',
      pageCount: 1,
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: _versionComic(manifest.comicId),
        manifest: manifest,
      ),
    );

    session.dispose();
    await session.close();

    await expectLater(library.list(), throwsA(isA<StateError>()));
    expect(() => downloads.download(entry), throwsA(isA<StateError>()));
    await expectLater(
      queue.enqueue(
        sourceId: manifest.sourceId,
        comicId: manifest.comicId,
        comicTitle: manifest.comicId,
        chapters: const <ImportedLibraryEntry>[],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('durable adoption carries separate composition into canonical owner',
      () async {
    final root = await Directory.systemTemp.createTemp('canonical-adoption-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final bootstrapLibrary = MemoryImportedLibraryStore();
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(downloads: bootstrapDownloads);
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final durableLibrary = MemoryImportedLibraryStore();
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
      await composition.close();
      await durableLibrary.close();
      await root.delete(recursive: true);
    });
    await durableLibrary.open();
    final oldManifest = _versionManifest(
      comicId: 'adopt-old',
      chapterId: 'adopt-old-chapter',
      revision: 'adopt-old-r1',
      pageCount: 2,
    );
    final newManifest = _versionManifest(
      comicId: 'adopt-new',
      chapterId: 'adopt-new-chapter',
      revision: 'adopt-new-r1',
      pageCount: 3,
    );
    await durableLibrary.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic(oldManifest.comicId),
        manifest: oldManifest,
      ),
    );
    await durableLibrary.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic(newManifest.comicId),
        manifest: newManifest,
      ),
    );
    await durableLibrary.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: oldManifest.sourceId,
        predecessorComicId: oldManifest.comicId,
        successorComicId: newManifest.comicId,
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: oldManifest.chapter.chapterId,
            successorChapterId: newManifest.chapter.chapterId,
            predecessorPageCount: oldManifest.pages.length,
            successorPageCount: newManifest.pages.length,
            successorOffset: 1,
            predecessorSourceRevision: oldManifest.chapter.sourceRevision,
            successorSourceRevision: newManifest.chapter.sourceRevision,
            verifiedIntervals: const <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 2,
                successorOffset: 1,
              ),
            ],
          ),
        ],
      ),
    );

    await session.ready;
    await session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      downloadComposition: composition,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    expect(session.downloadComposition, same(composition));
    await session.ready; // This assertion consumes the Home list projection.
    final current = session.entries.singleWhere(
      (entry) => entry.chapter.comicId == oldManifest.comicId,
    );
    await session.ensureCanonicalMediaForEntry(current);

    final projections = await composition.artifactStore
        .loadCanonicalMediaProjections();
    expect(projections, hasLength(2));
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages[0]);
    final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    final oldPhysical = composition.transferRuntime.physicalMediaIdFor(oldId);
    expect(oldPhysical.isExactFallback, isFalse);
    expect(composition.transferRuntime.physicalMediaIdFor(newId), oldPhysical);
  });

  test('persisted sparse canonical projection publishes physical owner on startup',
      () async {
    final root = await Directory.systemTemp.createTemp('canonical-projection-home-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'canonical-old',
      chapterId: 'canonical-old-chapter',
      revision: 'canonical-old-r1',
      pageCount: 2,
    );
    final newManifest = _versionManifest(
      comicId: 'canonical-new',
      chapterId: 'canonical-new-chapter',
      revision: 'canonical-new-r1',
      pageCount: 3,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('canonical-old'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('canonical-new'),
        manifest: newManifest,
      ),
    );
    await library.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: oldManifest.sourceId,
        predecessorComicId: oldManifest.comicId,
        successorComicId: newManifest.comicId,
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: oldManifest.chapter.chapterId,
            successorChapterId: newManifest.chapter.chapterId,
            predecessorPageCount: oldManifest.pages.length,
            successorPageCount: newManifest.pages.length,
            successorOffset: 1,
            predecessorSourceRevision: oldManifest.chapter.sourceRevision,
            successorSourceRevision: newManifest.chapter.sourceRevision,
            verifiedIntervals: const <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 1,
                successorOffset: 1,
              ),
            ],
          ),
        ],
      ),
    );
    const family = VersionFamilyId('canonical-family');
    const canonicalChapter = CanonicalChapterId('canonical-chapter');
    const segment = CanonicalMediaSegmentId('shared-segment');
    await composition.artifactStore.persistCanonicalMediaProjections(
      <VersionChapterCanonicalProjection>[
        VersionChapterCanonicalProjection(
          familyId: family,
          canonicalChapterId: canonicalChapter,
          sourceId: oldManifest.sourceId,
          comicId: oldManifest.comicId,
          chapterId: oldManifest.chapter.chapterId,
          sourceRevision: oldManifest.chapter.sourceRevision,
          pageCount: oldManifest.pages.length,
          intervals: const <CanonicalMediaBindingInterval>[
            CanonicalMediaBindingInterval(
              exactStart: 0,
              exactEndExclusive: 1,
              segmentId: segment,
              segmentStart: 0,
            ),
          ],
        ),
        VersionChapterCanonicalProjection(
          familyId: family,
          canonicalChapterId: canonicalChapter,
          sourceId: newManifest.sourceId,
          comicId: newManifest.comicId,
          chapterId: newManifest.chapter.chapterId,
          sourceRevision: newManifest.chapter.sourceRevision,
          pageCount: newManifest.pages.length,
          intervals: const <CanonicalMediaBindingInterval>[
            CanonicalMediaBindingInterval(
              exactStart: 1,
              exactEndExclusive: 2,
              segmentId: segment,
              segmentStart: 0,
            ),
          ],
        ),
      ],
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
    expect(composition.transferRuntime.canonicalMediaAuthorityCount, 2);
    expect(
      composition.transferRuntime.physicalMediaIdFor(oldId),
      composition.transferRuntime.physicalMediaIdFor(newId),
    );
    expect(
      composition.transferRuntime.sessionFor(newId),
      same(composition.transferRuntime.sessionFor(oldId)),
    );
    expect(
      composition.transferRuntime.registry.isPhysicalAlias(newId, oldId),
      isFalse,
    );
  });

  test(
    'cold canonical restore reads only the requested chapter manifest',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'canonical-compact-hydrate-',
      );
      final snapshotStore = HomeProjectionSnapshotStore.atPath(
        '${root.path}/home_snapshot.json',
      );
      final composition = await PersistentDownloadComposition.open(
        root.path,
        transferNet: DownloadResourceCoordinator().networkLane,
      );
      final library = MemoryImportedLibraryStore();
      await library.open();
      final oldManifest = _versionManifest(
        comicId: 'compact-old',
        chapterId: 'compact-old-chapter',
        revision: 'compact-old-r1',
        pageCount: 2,
      );
      final newManifest = _versionManifest(
        comicId: 'compact-new',
        chapterId: 'compact-new-chapter',
        revision: 'compact-new-r1',
        pageCount: 3,
      );
      final oldChapter = ImportedChapterRecord.remote(
        comic: _versionComic('compact-old'),
        manifest: oldManifest,
      );
      final newChapter = ImportedChapterRecord.remote(
        comic: _versionComic('compact-new'),
        manifest: newManifest,
      );
      await library.upsertChapter(oldChapter);
      await library.upsertChapter(newChapter);
      final relation = ComicVersionRelation(
        sourceId: oldManifest.sourceId,
        predecessorComicId: oldManifest.comicId,
        successorComicId: newManifest.comicId,
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: oldManifest.chapter.chapterId,
            successorChapterId: newManifest.chapter.chapterId,
            predecessorPageCount: oldManifest.pages.length,
            successorPageCount: newManifest.pages.length,
            successorOffset: 1,
            predecessorSourceRevision: oldManifest.chapter.sourceRevision,
            successorSourceRevision: newManifest.chapter.sourceRevision,
            verifiedIntervals: const <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 1,
                successorOffset: 1,
              ),
            ],
          ),
        ],
      );
      await library.saveComicVersionRelation(relation);
      await snapshotStore.write(
        HomeProjectionSnapshot(
          entries: <ImportedLibraryEntry>[
            ImportedLibraryEntry(chapter: oldChapter),
            ImportedLibraryEntry(chapter: newChapter),
          ],
          savedComics: const <SavedComicRecord>[],
          categories: const <LibraryCategory>[],
          preferences: const <ComicPreference>[],
          readStates: const <ChapterReadState>[],
          sourcePreferences: const <ComicSourcePreference>[],
          versionRelations: <ComicVersionRelation>[relation],
          libraryRevision: 7,
        ),
      );
      const family = VersionFamilyId('compact-family');
      const canonicalChapter = CanonicalChapterId('compact-chapter');
      const segment = CanonicalMediaSegmentId('compact-segment');
      final projection = VersionChapterCanonicalProjection(
          familyId: family,
          canonicalChapterId: canonicalChapter,
          sourceId: newManifest.sourceId,
          comicId: newManifest.comicId,
          chapterId: newManifest.chapter.chapterId,
          sourceRevision: newManifest.chapter.sourceRevision,
          pageCount: newManifest.pages.length,
          intervals: const <CanonicalMediaBindingInterval>[
            CanonicalMediaBindingInterval(
              exactStart: 1,
              exactEndExclusive: 2,
              segmentId: segment,
              segmentStart: 0,
            ),
          ],
        );
      await composition.artifactStore.persistCanonicalMediaProjection(projection);
      final oldId = readerPageDownloadId(oldManifest, oldManifest.pages.first);
      final body = Uint8List.fromList('RIFF....WEBPcanonical'.codeUnits);
      await composition.artifactStore.storePromotedArtifact(id: oldId, bytes: body);
      final canonical = PhysicalMediaId.canonical(
        projection.coordinateForPageIndex(1).stableKey);
      expect(await composition.artifactCacheManager.bindPhysicalArtifact(
        physicalId: canonical, sourceId: oldId), isTrue);
      final durable = _GatedLibraryStore(
        library,
        Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
        libraryRevision: 7,
      );
      final queue = WholeComicDownloadQueue(
        downloads: composition.chapterDownloads,
      );
      final session = HomeLibrarySession(
        library: durable,
        snapshotStore: snapshotStore,
        chapterDownloads: composition.chapterDownloads,
        downloadComposition: composition,
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
        if (await root.exists()) await root.delete(recursive: true);
      });

      await session.ready;
      final compact = session.entries.singleWhere(
        (entry) => entry.chapter.comicId == newManifest.comicId,
      );
      expect(
        compact.chapter.pages[1].sourceId,
        startsWith('zic-home-snapshot-page:'),
      );
      expect(
        session.versionAuthorityEntry(
          sourceId: compact.chapter.sourceId,
          comicId: compact.chapter.comicId,
          chapterId: compact.chapter.chapterId,
        ),
        isNull,
        reason: 'compact Home placeholders are not page authority',
      );
      final hydrated = await session.hydrateEntry(compact);
      expect(hydrated.chapter.pages[1].uri, newManifest.pages[1].uri);
      await session.ensureCanonicalMediaForEntry(hydrated);
      expect(durable.getCalls, 1);
      expect(durable.getManyCalls, 0,
          reason: 'canonical admission must not hydrate the version family');
      expect(session.versionAuthorityEntry(sourceId: oldManifest.sourceId,
        comicId: oldManifest.comicId, chapterId: oldManifest.chapter.chapterId), isNull);

      final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
      expect(
        composition.transferRuntime.physicalMediaIdFor(newId).isExactFallback,
        isFalse,
      );
      expect(composition.transferRuntime.physicalMediaIdFor(newId), canonical);
      final cached = await composition.artifactCacheManager.openPhysicalArtifact(canonical);
      expect(cached, isNotNull);
      expect((await cached!.open(start: 0).toList()).expand((chunk) => chunk),
        orderedEquals(body));
    },
  );

  test('verified relation allocates stable canonical media across proof revocation',
      () async {
    final root = await Directory.systemTemp.createTemp('canonical-ledger-home-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'ledger-old',
      chapterId: 'ledger-old-chapter',
      revision: 'ledger-old-r1',
      pageCount: 2,
    );
    final newManifest = _versionManifest(
      comicId: 'ledger-new',
      chapterId: 'ledger-new-chapter',
      revision: 'ledger-new-r1',
      pageCount: 3,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('ledger-old'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('ledger-new'),
        manifest: newManifest,
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

    ComicVersionRelation relation({required bool verified}) =>
        ComicVersionRelation(
          sourceId: oldManifest.sourceId,
          predecessorComicId: oldManifest.comicId,
          successorComicId: newManifest.comicId,
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: oldManifest.chapter.chapterId,
              successorChapterId: newManifest.chapter.chapterId,
              predecessorPageCount: oldManifest.pages.length,
              successorPageCount: newManifest.pages.length,
              successorOffset: 1,
              predecessorSourceRevision: oldManifest.chapter.sourceRevision,
              successorSourceRevision: newManifest.chapter.sourceRevision,
              verifiedIntervals: verified
                  ? const <VerifiedComicVersionPageInterval>[
                      VerifiedComicVersionPageInterval(
                        predecessorStart: 0,
                        predecessorEndExclusive: 1,
                        successorOffset: 1,
                      ),
                    ]
                  : const <VerifiedComicVersionPageInterval>[],
            ),
          ],
        );

    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages[0]);
    final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    expect(
      composition.transferRuntime.physicalMediaIdFor(oldId).isExactFallback,
      isTrue,
    );
    expect(
      composition.transferRuntime.physicalMediaIdFor(newId).isExactFallback,
      isTrue,
    );
    final historicalBytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    await composition.artifactStore.storePromotedArtifact(
      id: oldId,
      bytes: historicalBytes,
    );

    await session.upsertVersionRelation(relation(verified: true));
    final canonical = composition.transferRuntime.physicalMediaIdFor(oldId);
    expect(canonical.isExactFallback, isFalse);
    expect(composition.transferRuntime.physicalMediaIdFor(newId), canonical);
    final canonicalArtifact =
        await composition.artifactCacheManager.openPhysicalArtifact(canonical);
    expect(canonicalArtifact, isNotNull);
    expect(canonicalArtifact!.length, historicalBytes.length);
    expect(
      await composition.artifactStore.loadCanonicalMediaProjections(),
      hasLength(2),
    );

    await session.upsertVersionRelationDerivedState(relation(verified: false));
    expect(
      composition.transferRuntime.physicalMediaIdFor(oldId).isExactFallback,
      isTrue,
    );
    expect(
      composition.transferRuntime.physicalMediaIdFor(newId).isExactFallback,
      isTrue,
    );
    expect(
      await composition.artifactStore.loadCanonicalMediaProjections(),
      hasLength(2),
    );

    await session.upsertVersionRelationDerivedState(relation(verified: true));
    expect(composition.transferRuntime.physicalMediaIdFor(oldId), canonical);
    expect(composition.transferRuntime.physicalMediaIdFor(newId), canonical);
  });

  test('failed canonical persist does not advance the in-memory ledger',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'canonical-ledger-persist-failure-',
    );
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'failed-ledger-old',
      chapterId: 'failed-ledger-old-chapter',
      revision: 'failed-ledger-old-r1',
      pageCount: 1,
    );
    final newManifest = _versionManifest(
      comicId: 'failed-ledger-new',
      chapterId: 'failed-ledger-new-chapter',
      revision: 'failed-ledger-new-r1',
      pageCount: 1,
    );
    for (final manifest in <ChapterManifest>[oldManifest, newManifest]) {
      await library.upsertChapter(
        ImportedChapterRecord.remote(
          comic: _versionComic(manifest.comicId),
          manifest: manifest,
        ),
      );
    }
    final queue = WholeComicDownloadQueue(
      downloads: composition.chapterDownloads,
    );
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

    final conflict = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('conflicting-family'),
      canonicalChapterId: const CanonicalChapterId('conflicting-chapter'),
      sourceId: oldManifest.sourceId,
      comicId: oldManifest.comicId,
      chapterId: oldManifest.chapter.chapterId,
      sourceRevision: oldManifest.chapter.sourceRevision,
      pageCount: 1,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: CanonicalMediaSegmentId('conflicting-segment'),
          segmentStart: 0,
        ),
      ],
    );
    await composition.artifactStore.persistCanonicalMediaProjection(conflict);

    final relation = ComicVersionRelation(
      sourceId: oldManifest.sourceId,
      predecessorComicId: oldManifest.comicId,
      successorComicId: newManifest.comicId,
      pageMappings: <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: oldManifest.chapter.chapterId,
          successorChapterId: newManifest.chapter.chapterId,
          predecessorPageCount: 1,
          successorPageCount: 1,
          successorOffset: 0,
          predecessorSourceRevision: oldManifest.chapter.sourceRevision,
          successorSourceRevision: newManifest.chapter.sourceRevision,
          verifiedIntervals: const <VerifiedComicVersionPageInterval>[
            VerifiedComicVersionPageInterval(
              predecessorStart: 0,
              predecessorEndExclusive: 1,
              successorOffset: 0,
            ),
          ],
        ),
      ],
    );

    await session.upsertVersionRelationDerivedState(relation);
    final failedPersist =
        await composition.artifactStore.loadCanonicalMediaProjections();
    expect(failedPersist, hasLength(1));
    expect(failedPersist.single.exactKey, conflict.exactKey);
    expect(failedPersist.single.familyId, conflict.familyId);
    expect(
      failedPersist.single.coordinateForPageIndex(0),
      conflict.coordinateForPageIndex(0),
    );

    await (composition.artifactStore.index as PhysicalMediaProjectionIndex)
        .removePhysicalMediaProjection(conflict.exactKey);
    final oldEntry = session.entries.singleWhere(
      (entry) => entry.chapter.comicId == oldManifest.comicId,
    );
    await session.ensureCanonicalMediaForEntry(oldEntry);

    final recovered =
        await composition.artifactStore.loadCanonicalMediaProjections();
    expect(recovered, hasLength(2));
    expect(recovered.map((value) => value.familyId).toSet(), hasLength(1));
    expect(
      recovered.map((value) => value.exactKey).toSet(),
      <String>{
        canonicalMediaExactChapterKey(
          sourceId: oldManifest.sourceId,
          comicId: oldManifest.comicId,
          chapterId: oldManifest.chapter.chapterId,
          sourceRevision: oldManifest.chapter.sourceRevision,
        ),
        canonicalMediaExactChapterKey(
          sourceId: newManifest.sourceId,
          comicId: newManifest.comicId,
          chapterId: newManifest.chapter.chapterId,
          sourceRevision: newManifest.chapter.sourceRevision,
        ),
      },
    );
  });

  test('concurrent verified relations serialize one canonical media ledger',
      () async {
    final root = await Directory.systemTemp.createTemp('canonical-ledger-write-tail-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    await library.open();
    final a = _versionManifest(
      comicId: 'tail-a',
      chapterId: 'tail-a-chapter',
      revision: 'tail-a-r1',
      pageCount: 1,
    );
    final b = _versionManifest(
      comicId: 'tail-b',
      chapterId: 'tail-b-chapter',
      revision: 'tail-b-r1',
      pageCount: 1,
    );
    final c = _versionManifest(
      comicId: 'tail-c',
      chapterId: 'tail-c-chapter',
      revision: 'tail-c-r1',
      pageCount: 1,
    );
    for (final manifest in <ChapterManifest>[a, b, c]) {
      await library.upsertChapter(
        ImportedChapterRecord.remote(
          comic: _versionComic(manifest.comicId),
          manifest: manifest,
        ),
      );
    }
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

    ComicVersionRelation relation(ChapterManifest left, ChapterManifest right) =>
        ComicVersionRelation(
          sourceId: left.sourceId,
          predecessorComicId: left.comicId,
          successorComicId: right.comicId,
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: left.chapter.chapterId,
              successorChapterId: right.chapter.chapterId,
              predecessorPageCount: 1,
              successorPageCount: 1,
              successorOffset: 0,
              predecessorSourceRevision: left.chapter.sourceRevision,
              successorSourceRevision: right.chapter.sourceRevision,
              verifiedIntervals: const <VerifiedComicVersionPageInterval>[
                VerifiedComicVersionPageInterval(
                  predecessorStart: 0,
                  predecessorEndExclusive: 1,
                  successorOffset: 0,
                ),
              ],
            ),
          ],
        );

    await Future.wait(<Future<void>>[
      session.upsertVersionRelationDerivedState(relation(a, b)),
      session.upsertVersionRelationDerivedState(relation(b, c)),
    ]);

    final aId = readerPageDownloadId(a, a.pages.single);
    final bId = readerPageDownloadId(b, b.pages.single);
    final cId = readerPageDownloadId(c, c.pages.single);
    final physical = composition.transferRuntime.physicalMediaIdFor(aId);
    expect(physical.isExactFallback, isFalse);
    expect(composition.transferRuntime.physicalMediaIdFor(bId), physical);
    expect(composition.transferRuntime.physicalMediaIdFor(cId), physical);
    final projections = await composition.artifactStore.loadCanonicalMediaProjections();
    expect(projections, hasLength(3));
    expect(projections.map((value) => value.familyId).toSet(), hasLength(1));
  });

  test('version relations publish page reuse candidates without Reader entry',
      () async {
    final root = await Directory.systemTemp.createTemp('version-owner-home-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
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

  test('strong page identity publishes one canonical physical owner across versions',
      () async {
    final root = await Directory.systemTemp.createTemp('version-physical-home-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    await library.open();
    const sharedKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const addedKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final oldManifest = _versionManifestWithImageKeys(
      comicId: 'physical-old',
      chapterId: 'physical-old-chapter',
      revision: 'physical-old-r1',
      imageKeys: const <String>[sharedKey],
    );
    final newManifest = _versionManifestWithImageKeys(
      comicId: 'physical-new',
      chapterId: 'physical-new-chapter',
      revision: 'physical-new-r1',
      imageKeys: const <String>[addedKey, sharedKey],
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('physical-old'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('physical-new'),
        manifest: newManifest,
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

    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages.single);
    final newSharedId = readerPageDownloadId(newManifest, newManifest.pages[1]);
    final newAddedId = readerPageDownloadId(newManifest, newManifest.pages[0]);
    final oldPhysical = composition.transferRuntime.physicalMediaIdFor(oldId);
    final sharedPhysical =
        composition.transferRuntime.physicalMediaIdFor(newSharedId);
    final addedPhysical = composition.transferRuntime.physicalMediaIdFor(newAddedId);

    expect(oldPhysical.isExactFallback, isFalse);
    expect(sharedPhysical, oldPhysical);
    expect(addedPhysical, isNot(oldPhysical));
    final oldSession = composition.transferRuntime.sessionFor(oldId);
    final newSession = composition.transferRuntime.sessionFor(newSharedId);
    expect(newSession, same(oldSession));
    expect(oldSession.physicalId, oldPhysical);
    expect(composition.transferRuntime.registry.isPhysicalAlias(newSharedId, oldId),
        isFalse);
  });

  test('batch hydration publishes canonical media without growing Home entries',
      () async {
    final root = await Directory.systemTemp.createTemp('version-owner-hydrate-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
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
    final oldPhysical = composition.transferRuntime.physicalMediaIdFor(oldId);
    expect(oldPhysical.isExactFallback, isFalse);
    expect(composition.transferRuntime.physicalMediaIdFor(newId), oldPhysical);
    expect(
      composition.transferRuntime.sessionFor(newId),
      same(composition.transferRuntime.sessionFor(oldId)),
    );
    expect(composition.transferRuntime.versionCandidatesFor(oldId), isEmpty);
    expect(composition.transferRuntime.versionCandidatesFor(newId), isEmpty);
  });

  test('natural page evidence discovers a changed affine offset from observed identity',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'old-offset-evidence',
      chapterId: 'old-offset-chapter',
      revision: 'old-offset-r1',
      pageCount: 3,
    );
    final newManifest = _versionManifest(
      comicId: 'new-offset-evidence',
      chapterId: 'new-offset-chapter',
      revision: 'new-offset-r1',
      pageCount: 4,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('old-offset-evidence'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('new-offset-evidence'),
        manifest: newManifest,
      ),
    );
    await library.saveComicVersionRelation(
      const ComicVersionRelation(
        sourceId: 'version-source',
        predecessorComicId: 'old-offset-evidence',
        successorComicId: 'new-offset-evidence',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-offset-chapter',
            successorChapterId: 'new-offset-chapter',
            predecessorPageCount: 3,
            successorPageCount: 4,
            successorOffset: 0,
            predecessorSourceRevision: 'old-offset-r1',
            successorSourceRevision: 'new-offset-r1',
            verifiedPredecessorPageIndexes: <int>[0],
            verifiedIntervals: <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 1,
                successorOffset: 0,
              ),
            ],
          ),
        ],
      ),
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

    // Observe successor first. There is no matching predecessor evidence yet,
    // so the relation remains unchanged. Observing the predecessor later with
    // the same strong identity discovers the real +1 index shift directly.
    session.observeVerifiedPageReuseIdentity(
      newManifest,
      newManifest.pages[2],
      'media:shifted-page',
    );
    session.observeVerifiedPageReuseIdentity(
      oldManifest,
      oldManifest.pages[1],
      'media:shifted-page',
    );
    await session.flushVersionReuseEvidence();

    final mapping = session.versionRelations.single.pageMappings.single;
    expect(
      mapping.effectiveVerifiedIntervals
          .map((interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ))
          .toList(),
      <(int, int, int)>[(0, 1, 0), (1, 2, 1)],
    );
  });

  test('natural page evidence splits a mismatched verified interval without Home broadcast',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    final oldManifest = _versionManifest(
      comicId: 'old-evidence',
      chapterId: 'old-evidence-chapter',
      revision: 'old-evidence-r1',
      pageCount: 3,
    );
    final newManifest = _versionManifest(
      comicId: 'new-evidence',
      chapterId: 'new-evidence-chapter',
      revision: 'new-evidence-r1',
      pageCount: 3,
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('old-evidence'),
        manifest: oldManifest,
      ),
    );
    await library.upsertChapter(
      ImportedChapterRecord.remote(
        comic: _versionComic('new-evidence'),
        manifest: newManifest,
      ),
    );
    await library.saveComicVersionRelation(
      const ComicVersionRelation(
        sourceId: 'version-source',
        predecessorComicId: 'old-evidence',
        successorComicId: 'new-evidence',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'old-evidence-chapter',
            successorChapterId: 'new-evidence-chapter',
            predecessorPageCount: 3,
            successorPageCount: 3,
            successorOffset: 0,
            predecessorSourceRevision: 'old-evidence-r1',
            successorSourceRevision: 'new-evidence-r1',
            verifiedPredecessorPageIndexes: <int>[0, 2],
            verifiedIntervals: <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 3,
                successorOffset: 0,
              ),
            ],
          ),
        ],
      ),
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
    var notifications = 0;
    session.addListener(() => notifications++);

    session.observeVerifiedPageReuseIdentity(
      oldManifest,
      oldManifest.pages[1],
      'media:old-middle',
    );
    session.observeVerifiedPageReuseIdentity(
      newManifest,
      newManifest.pages[1],
      'media:new-middle',
    );
    await session.flushVersionReuseEvidence();

    expect(notifications, 0);
    final mapping = session.versionRelations.single.pageMappings.single;
    expect(
      mapping.effectiveVerifiedIntervals
          .map((interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ))
          .toList(),
      <(int, int, int)>[(0, 1, 0), (2, 3, 0)],
    );
    final persisted = await library.listComicVersionSuccessors(
      'version-source',
      'old-evidence',
    );
    expect(
      persisted.single.pageMappings.single.effectiveVerifiedIntervals,
      hasLength(2),
    );
  });

  test('unchanged version discovery preserves the existing runtime projection',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: WholeComicDownloadQueue(downloads: downloads),
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
    await session.upsertVersionRelation(ComicVersionRelation(
      sourceId: 's', predecessorComicId: 'old', successorComicId: 'new',
      predecessorTitle: 'Original', discoveredAt: discoveredAt,
      pageMappings: const <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'a', successorChapterId: 'b',
          predecessorPageCount: 3, successorPageCount: 3, successorOffset: 0,
        ),
      ],
    ));
    final baseline = session.versionBaselines;
    var notifications = 0;
    session.addListener(() => notifications++);
    await session.upsertVersionRelation(ComicVersionRelation(
      sourceId: 's', predecessorComicId: 'old', successorComicId: 'new',
      predecessorTitle: 'Original', discoveredAt: DateTime.utc(2026, 10, 10),
    ));
    expect(identical(session.versionBaselines, baseline), isTrue);
    expect(notifications, 0);
    expect(session.versionRelations.single.discoveredAt, discoveredAt);
    expect(session.versionRelations.single.pageMappings, hasLength(1));
    expect((await library.listComicVersionSuccessors('s', 'old'))
        .single.pageMappings, hasLength(1));
    await session.upsertVersionRelation(ComicVersionRelation(
      sourceId: 's', predecessorComicId: 'old', successorComicId: 'new',
      predecessorTitle: 'Updated', discoveredAt: discoveredAt,
    ));
    expect(notifications, 1);
    expect(session.versionRelations.single.predecessorTitle, 'Updated');
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

  test('SQLite chapter upsert retains the prepared manifest and durable progress',
      () async {
    final library = SqliteImportedLibraryStore.memory();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    final chapter = _preparedBoundaryChapter();
    final manifest = chapter.toManifest();
    await library.upsertChapter(chapter);
    final progress = ReadingProgress(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 1,
      subPageOffset: 0.35,
      readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 10, 1, 1),
    );
    await library.saveProgress(progress);

    final entry = await session.upsertChapter(chapter);
    expect(entry.chapter.toManifest(), same(manifest),
        reason: 'exact SQLite readback must not discard the prepared projection');
    expect(entry.progress?.toJson(), progress.toJson());
    expect(session.entries.single, same(entry));
    expect(session.versionAuthorityEntry(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
    )?.chapter.toManifest(), same(manifest));
    final durable = await library.get(chapter.sourceId, chapter.chapterId);
    expect(durable?.chapter.toJson(), chapter.toJson());
    expect(durable?.progress?.toJson(), progress.toJson());
  });

  test('chapter upsert adopts actual changed SQLite payload after preparation',
      () async {
    final delegate = SqliteImportedLibraryStore.memory();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    final chapter = _preparedBoundaryChapter();
    chapter.toManifest();
    final chapterChanges = <String, Object?>{
      'directoryId': 'changed-directory',
      'displayName': 'Changed chapter',
      'comicId': 'changed-comic',
      'sourceRevision': 'changed-revision',
      'comicTitle': 'Changed comic',
      'comicAuthors': <String>['Changed author'],
      'comicTags': <String>['Changed tag'],
      'comicDescription': null,
      'coverSourceId': null,
      'coverMediaFormat': null,
      'coverAnimatedHint': false,
      'sequence': 99,
      'readingDirection': ReadingDirection.rtl.name,
      'sourceUpdatedAt': null,
      'importedAt': DateTime.utc(2026, 10, 1).toIso8601String(),
      'pages': chapter.pages.reversed
          .map((page) => page.toJson()).toList(growable: false),
    };
    final pageChanges = <String, Object?>{
      'displayName': 'changed.jpg',
      'sourceId': 'mihon-page:changed-carrier',
      'pageId': 'changed-page-id',
      'contentKindHint': ContentKindHint.png.name,
      'mediaFormat': null,
      'byteLength': null,
      'checksum': null,
      'checksumAlgorithm': null,
      'animatedHint': false,
    };
    final changedPayloads = <String, Map<String, Object?>>{
      for (final change in chapterChanges.entries)
        change.key: <String, Object?>{...chapter.toJson(), change.key: change.value},
      for (final change in pageChanges.entries)
        'page.${change.key}': <String, Object?>{
          ...chapter.toJson(),
          'pages': <Map<String, Object?>>[
            <String, Object?>{...chapter.pages.first.toJson(), change.key: change.value},
            chapter.pages.last.toJson(),
          ],
        },
    };
    for (final change in changedPayloads.entries) {
      final started = Completer<void>();
      final release = Completer<void>();
      library.chapterWriteStarted = started;
      library.chapterWriteReturnGate = release.future;
      final write = session.upsertChapter(chapter);
      await started.future;
      final actual = ImportedChapterRecord.fromJson(change.value);
      await delegate.upsertChapter(actual);
      final progress = ReadingProgress(
        sourceId: actual.sourceId,
        comicId: actual.comicId,
        chapterId: actual.chapterId,
        pageIndex: 1,
        subPageOffset: 0.6,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 10, 1, 2),
      );
      await delegate.saveProgress(progress);
      release.complete();
      final entry = await write;
      expect(entry.chapter.toJson(), actual.toJson(), reason: change.key);
      expect(entry.chapter, isNot(same(chapter)), reason: change.key);
      expect(entry.progress?.toJson(), progress.toJson(), reason: change.key);
      expect(session.entries.single, same(entry), reason: change.key);
    }
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

  test(
      'category removal retries current cascade after in-flight adoption',
      () async {
    final category = LibraryCategory(
      categoryId: 'fixture-category',
      name: 'Fixture',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 9, 18),
    );
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      categoryIds: const <String>{'fixture-category'},
      updatedAt: DateTime.utc(2026, 9, 18),
    );

    final firstDelegate = MemoryImportedLibraryStore();
    await firstDelegate.open();
    await firstDelegate.upsertCategory(category);
    await firstDelegate.saveComicPreference(preference);
    final firstLibrary = _GatedLibraryStore(
      firstDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      readCategoriesFromDelegate: true,
    );
    final removeStarted = Completer<void>();
    final releaseRemove = Completer<void>();
    firstLibrary.categoryRemoveStarted = removeStarted;
    firstLibrary.categoryRemoveReturnGate = releaseRemove.future;
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    await session.ready;
    expect(session.categories.single.categoryId, category.categoryId);
    expect(
      session.preferences[preference.identity]?.categoryIds,
      contains(category.categoryId),
    );

    final secondLibrary = MemoryImportedLibraryStore();
    await secondLibrary.open();
    await secondLibrary.upsertCategory(category);
    await secondLibrary.saveComicPreference(preference);
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!releaseRemove.isCompleted) {
        releaseRemove.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final removeFuture = session.removeCategory(category.categoryId);
    await removeStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    releaseRemove.complete();
    await removeFuture;

    expect(session.categories, isEmpty);
    expect(
      session.preferences[preference.identity]?.categoryIds,
      isEmpty,
    );
    expect(await secondLibrary.listCategories(), isEmpty);
    expect(
      (await secondLibrary.getComicPreference(
        preference.sourceId,
        preference.comicId,
      ))
          ?.categoryIds,
      isEmpty,
    );
  });

  test('category removal publishes category and preference cascade once',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    final category = LibraryCategory(
      categoryId: 'fixture-category',
      name: 'Fixture',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 9, 18),
    );
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      categoryIds: const <String>{'fixture-category'},
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    await library.upsertCategory(category);
    await library.saveComicPreference(preference);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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

    var notifications = 0;
    session.addListener(() => notifications++);

    await session.removeCategory(category.categoryId);

    expect(notifications, 1);
    expect(session.categories, isEmpty);
    expect(
      session.preferences[preference.identity]?.categoryIds,
      isEmpty,
    );
  });

  test('reload cannot overwrite a concurrent category projection',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      readCategoriesFromDelegate: true,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final listStarted = Completer<void>();
    final releaseList = Completer<void>();
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
      if (!releaseList.isCompleted) {
        releaseList.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;

    library.categoryListCalls = 0;
    library.categoryListStarted = listStarted;
    library.categoryListReturnGate = releaseList.future;

    final reload = session.reload();
    await listStarted.future;

    final category = LibraryCategory(
      categoryId: 'concurrent-category',
      name: 'Concurrent',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 9, 18),
    );
    await session.upsertCategory(category);
    expect(
      session.categories.map((value) => value.categoryId),
      contains(category.categoryId),
    );

    releaseList.complete();
    await reload;

    expect(
      session.categories.map((value) => value.categoryId),
      contains(category.categoryId),
    );
    expect(
      (await delegate.listCategories()).map((value) => value.categoryId),
      contains(category.categoryId),
    );
  });

  test(
      'reload preserves concurrent source preference and active source',
      () async {
    const sourceA = _FixtureBrowsableSource('source-a');
    const sourceB = _FixtureBrowsableSource('source-b');
    final preferenceA = ComicSourcePreference.defaults(
      sourceId: sourceA.sourceId,
      sortOrder: 0,
    ).copyWith(updatedAt: DateTime.utc(2026, 9, 18));
    final preferenceB = ComicSourcePreference.defaults(
      sourceId: sourceB.sourceId,
      sortOrder: 1,
    ).copyWith(updatedAt: DateTime.utc(2026, 9, 18));

    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    await delegate.saveSourcePreference(preferenceA);
    await delegate.saveSourcePreference(preferenceB);
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final listStarted = Completer<void>();
    final releaseList = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[sourceA, sourceB],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      if (!releaseList.isCompleted) {
        releaseList.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;
    expect(session.activeSourceId, sourceA.sourceId);

    library.sourcePreferenceListCalls = 0;
    library.sourcePreferenceListStarted = listStarted;
    library.sourcePreferenceListReturnGate = releaseList.future;

    final reload = session.reload();
    await listStarted.future;

    await session.persistSourcePreference(
      preferenceA.copyWith(
        enabled: false,
        updatedAt: DateTime.utc(2026, 9, 18, 1),
      ),
    );
    expect(session.sourcePreferences[sourceA.sourceId]?.enabled, isFalse);
    expect(session.activeSourceId, sourceB.sourceId);

    releaseList.complete();
    await reload;

    expect(session.sourcePreferences[sourceA.sourceId]?.enabled, isFalse);
    expect(session.activeSourceId, sourceB.sourceId);
    expect(
      (await delegate.listSourcePreferences())
          .singleWhere((value) => value.sourceId == sourceA.sourceId)
          .enabled,
      isFalse,
    );
  });

  test(
      'reload default cannot overwrite a concurrent source preference',
      () async {
    const source = _FixtureBrowsableSource('default-race-source');
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final listStarted = Completer<void>();
    final releaseList = Completer<void>();
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
      if (!releaseList.isCompleted) {
        releaseList.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;
    await session.replaceSources(
      const <BrowsableComicSource>[source],
      reloadLibrary: false,
    );

    library.sourcePreferenceListCalls = 0;
    library.sourcePreferenceListStarted = listStarted;
    library.sourcePreferenceListReturnGate = releaseList.future;

    final reload = session.reload();
    await listStarted.future;

    final userPreference = ComicSourcePreference.defaults(
      sourceId: source.sourceId,
    ).copyWith(
      enabled: false,
      updatedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    await session.persistSourcePreference(userPreference);
    expect(session.sourcePreferences[source.sourceId]?.enabled, isFalse);

    releaseList.complete();
    await reload;

    expect(session.sourcePreferences[source.sourceId]?.enabled, isFalse);
    expect(
      (await delegate.listSourcePreferences())
          .singleWhere((value) => value.sourceId == source.sourceId)
          .enabled,
      isFalse,
    );
  });

  test('synthesized preferences keep baseline timestamps', () async {
    const source = _FixtureBrowsableSource('baseline-source');
    final library = MemoryImportedLibraryStore();
    await library.open();
    final saved = SavedComicRecord(
      sourceId: source.sourceId,
      comicId: 'baseline-comic',
      title: 'Baseline comic',
    );
    await library.upsertSavedComic(saved);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[source],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    final baseline = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    expect(session.sourcePreferences[source.sourceId]?.updatedAt, baseline);
    expect(session.preferences[saved.identity]?.updatedAt, baseline);
    expect(
      (await library.listSourcePreferences())
          .singleWhere((value) => value.sourceId == source.sourceId)
          .updatedAt,
      baseline,
    );
    expect(
      (await library.getComicPreference(saved.sourceId, saved.comicId))
          ?.updatedAt,
      baseline,
    );
  });

  test(
      'chapter write and readback retry current library after adoption',
      () async {
    final firstDelegate = MemoryImportedLibraryStore();
    final firstLibrary = _GatedLibraryStore(
      firstDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    firstLibrary.chapterWriteStarted = writeStarted;
    firstLibrary.chapterWriteReturnGate = releaseWrite.future;
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final chapter = ImportedChapterRecord(
      directoryId: 'remote:fixture',
      displayName: 'Chapter',
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      comicTitle: 'Fixture',
      chapterId: 'chapter-1',
      sourceRevision: 'r1',
      importedAt: DateTime.utc(2026, 9, 18),
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
    final writeFuture = session.upsertChapter(chapter);
    await writeStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    releaseWrite.complete();
    final entry = await writeFuture;

    expect(entry.chapter.chapterId, chapter.chapterId);
    expect(session.entries, hasLength(1));
    expect(session.entries.single.chapter.chapterId, chapter.chapterId);
    expect(
      await secondLibrary.get(chapter.sourceId, chapter.chapterId),
      isNotNull,
    );
  });

  test(
      'comic preference write retries current library after in-flight adoption',
      () async {
    final firstDelegate = MemoryImportedLibraryStore();
    final firstLibrary = _GatedLibraryStore(
      firstDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    firstLibrary.comicPreferenceWriteStarted = writeStarted;
    firstLibrary.comicPreferenceWriteReturnGate = releaseWrite.future;
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      liked: true,
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    final writeFuture = session.persistPreference(preference);
    await writeStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    releaseWrite.complete();
    await writeFuture;

    expect(session.preferences[preference.identity]?.liked, isTrue);
    expect(
      (await secondLibrary.getComicPreference(
        preference.sourceId,
        preference.comicId,
      ))
          ?.liked,
      isTrue,
    );
  });

  test('comic preference batch publishes once after durable writes', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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

    var notifications = 0;
    session.addListener(() => notifications++);
    final first = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'comic-a',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    final second = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'comic-b',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      updatedAt: DateTime.utc(2026, 9, 18, 0, 0, 1),
    );

    await session.persistPreferences(<ComicPreference>[first, second]);

    expect(notifications, 1);
    expect(session.preferences.keys, containsAll(<String>[first.identity, second.identity]));
    expect(await library.getComicPreference(first.sourceId, first.comicId), isNotNull);
    expect(
      await library.getComicPreference(second.sourceId, second.comicId),
      isNotNull,
    );
  });

  test(
      'version relation write retries current library after in-flight adoption',
      () async {
    final firstDelegate = MemoryImportedLibraryStore();
    final firstLibrary = _GatedLibraryStore(
      firstDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    firstLibrary.versionRelationWriteStarted = writeStarted;
    firstLibrary.versionRelationWriteReturnGate = releaseWrite.future;
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final relation = ComicVersionRelation(
      sourceId: 'fixture-source',
      predecessorComicId: 'old-comic',
      successorComicId: 'new-comic',
      predecessorTitle: 'Old comic',
      discoveredAt: DateTime.utc(2026, 9, 18),
    );
    final writeFuture = session.upsertVersionRelation(relation);
    await writeStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    releaseWrite.complete();
    await writeFuture;

    expect(session.library, same(secondLibrary));
    expect(session.versionRelations, hasLength(1));
    expect(session.versionRelations.single.successorComicId, 'new-comic');
    expect(
      await secondLibrary.listAllComicVersionRelations(),
      hasLength(1),
    );
    expect(
      (await secondLibrary.listAllComicVersionRelations())
          .single
          .successorComicId,
      'new-comic',
    );
  });

  test(
      'derived version relation write retries current library after adoption',
      () async {
    final firstDelegate = MemoryImportedLibraryStore();
    final firstLibrary = _GatedLibraryStore(
      firstDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    await session.ready;

    final base = ComicVersionRelation(
      sourceId: 'fixture-source',
      predecessorComicId: 'old-comic',
      successorComicId: 'new-comic',
      predecessorTitle: 'Old comic',
      discoveredAt: DateTime.utc(2026, 9, 18),
    );
    await session.upsertVersionRelation(base);

    final secondLibrary = MemoryImportedLibraryStore();
    await secondLibrary.open();
    await secondLibrary.saveComicVersionRelation(base);
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    firstLibrary.versionRelationWriteStarted = writeStarted;
    firstLibrary.versionRelationWriteReturnGate = releaseWrite.future;
    addTearDown(() async {
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final derived = ComicVersionRelation(
      sourceId: base.sourceId,
      predecessorComicId: base.predecessorComicId,
      successorComicId: base.successorComicId,
      predecessorTitle: base.predecessorTitle,
      discoveredAt: base.discoveredAt,
      pageMappings: const <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'old-chapter',
          successorChapterId: 'new-chapter',
          predecessorPageCount: 1,
          successorPageCount: 1,
          successorOffset: 0,
        ),
      ],
    );
    final writeFuture = session.upsertVersionRelationDerivedState(derived);
    await writeStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    releaseWrite.complete();
    await writeFuture;

    expect(session.versionRelations.single.pageMappings, hasLength(1));
    final persisted = await secondLibrary.listAllComicVersionRelations();
    expect(persisted, hasLength(1));
    expect(persisted.single.pageMappings, hasLength(1));
  });

  test('current version relation store failure still propagates', () async {
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    library.versionRelationWriteError = StateError('fixture relation write');

    await expectLater(
      session.upsertVersionRelation(
        ComicVersionRelation(
          sourceId: 'fixture-source',
          predecessorComicId: 'old-comic',
          successorComicId: 'new-comic',
          discoveredAt: DateTime.utc(2026, 9, 18),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(session.versionRelations, isEmpty);
    expect(await delegate.listAllComicVersionRelations(), isEmpty);
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

  test('pending snapshot preparation coalesces mutations and flushes the latest',
      () async {
    final directory = await Directory.systemTemp.createTemp('zic-snapshot-coalesce-');
    addTearDown(() => directory.delete(recursive: true));
    final store = HomeProjectionSnapshotStore.atPath('${directory.path}/snapshot.json');
    final library = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      libraryRevision: 42,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final session = HomeLibrarySession(
      library: library, snapshotStore: store,
      chapterDownloads: downloads,
      wholeComicDownloads: WholeComicDownloadQueue(downloads: downloads),
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true, ownsChapterDownloads: true, ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;
    await session.flushSnapshotWrites();
    final reads = library.libraryRevisionReads;
    final gate = Completer<void>();
    library.libraryRevisionReadGate = gate.future;
    for (var i = 0; i < 8; i++) {
      session.replacePreference(ComicPreference.defaults(
        sourceId: 's', comicId: 'comic-$i', sourceKind: ComicSourceKind.remote,
      ).copyWith(liked: true));
    }
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await session.flushSnapshotWrites();
    expect(library.libraryRevisionReads - reads, 1);
    final persisted = await store.read();
    expect(persisted!.preferences.where((p) => p.liked), hasLength(8));
    expect(persisted.libraryRevision, 42);
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

  test('close drains admitted Home snapshot writes before library shutdown',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-session-close-snapshot-drain-',
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
    addTearDown(session.dispose);

    await session.ready;
    await session.flushSnapshotWrites();
    final revisionReadsBefore = library.libraryRevisionReads;
    final revisionGate = Completer<void>();
    library.libraryRevisionReadGate = revisionGate.future;
    final preference = ComicPreference.defaults(
      sourceId: 'close-drain-source',
      comicId: 'close-drain-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);
    session.replacePreference(preference);

    for (var attempt = 0;
        attempt < 20 && library.libraryRevisionReads == revisionReadsBefore;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(library.libraryRevisionReads, greaterThan(revisionReadsBefore));

    var closeCompleted = false;
    final closing = session.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(closeCompleted, isFalse);
    expect(library.closeCalls, 0);

    final latePreference = ComicPreference.defaults(
      sourceId: 'close-drain-source',
      comicId: 'late-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);
    await expectLater(
      session.persistPreference(latePreference),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.reload(),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.adoptServices(
        library: library,
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        persistSnapshot: true,
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.replaceSources(
        const <BrowsableComicSource>[],
        reloadLibrary: false,
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.upsertVersionRelation(
        ComicVersionRelation(
          sourceId: 'close-drain-source',
          predecessorComicId: 'old-comic',
          successorComicId: 'new-comic',
          discoveredAt: DateTime.utc(2026, 9, 18),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    revisionGate.complete();
    await closing;
    expect(library.closeCalls, 1);

    final persisted = await snapshotStore.read();
    expect(
      persisted?.preferences.singleWhere(
        (candidate) => candidate.identity == preference.identity,
      ).liked,
      isTrue,
    );
  });

  test('close waits for an admitted stable library mutation', () async {
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    library.comicPreferenceWriteStarted = writeStarted;
    library.comicPreferenceWriteReturnGate = releaseWrite.future;
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
      if (!releaseWrite.isCompleted) {
        releaseWrite.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;

    final preference = ComicPreference.defaults(
      sourceId: 'close-admitted-source',
      comicId: 'close-admitted-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);
    final write = session.persistPreference(preference);
    await writeStarted.future;
    expect(
      (await delegate.getComicPreference(
        preference.sourceId,
        preference.comicId,
      ))
          ?.liked,
      isTrue,
    );

    var closeCompleted = false;
    final closing = session.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);
    expect(library.closeCalls, 0);

    releaseWrite.complete();
    await write;
    await closing;

    expect(library.closeCalls, 1);
    expect(session.preferences[preference.identity]?.liked, isTrue);
  });

  test('close waits for an admitted hydrate before library teardown',
      () async {
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    final releaseGet = Completer<void>();
    addTearDown(() async {
      if (!releaseGet.isCompleted) {
        releaseGet.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;

    final manifest = _versionManifest(
      comicId: 'close-hydrate-comic',
      chapterId: 'close-hydrate-chapter',
      revision: 'close-hydrate-r1',
      pageCount: 1,
    );
    final record = ImportedChapterRecord.remote(
      comic: _versionComic(manifest.comicId),
      manifest: manifest,
    );
    await delegate.upsertChapter(record);
    final getStarted = Completer<void>();
    library.getStarted = getStarted;
    library.getReturnGate = releaseGet.future;

    final hydration = session.hydrateEntry(
      ImportedLibraryEntry(chapter: record),
    );
    await getStarted.future;

    var closeCompleted = false;
    final closing = session.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(closeCompleted, isFalse);
    expect(library.closeCalls, 0);

    await expectLater(
      session.hydrateEntry(ImportedLibraryEntry(chapter: record)),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.hydrateChapterBatch(
        <ImportedLibraryChapterKey>[
          ImportedLibraryChapterKey(
            sourceId: record.sourceId,
            chapterId: record.chapterId,
          ),
        ],
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      session.ensureCanonicalMediaForEntry(
        ImportedLibraryEntry(chapter: record),
      ),
      throwsA(isA<StateError>()),
    );

    releaseGet.complete();
    await hydration;
    await closing;

    expect(closeCompleted, isTrue);
    expect(library.closeCalls, 1);
  });

  test('hydrate admissions remain concurrent before close', () async {
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
    final releaseGets = Completer<void>();
    addTearDown(() async {
      if (!releaseGets.isCompleted) {
        releaseGets.complete();
      }
      await session.close();
      session.dispose();
    });
    await session.ready;

    ImportedLibraryEntry entry(String suffix) {
      final manifest = _versionManifest(
        comicId: 'concurrent-hydrate-comic',
        chapterId: 'concurrent-hydrate-$suffix',
        revision: 'concurrent-hydrate-$suffix-r1',
        pageCount: 1,
      );
      return ImportedLibraryEntry(
        chapter: ImportedChapterRecord.remote(
          comic: _versionComic(manifest.comicId),
          manifest: manifest,
        ),
      );
    }

    final first = entry('a');
    final second = entry('b');
    await delegate.upsertChapter(first.chapter);
    await delegate.upsertChapter(second.chapter);
    final twoStarted = Completer<void>();
    library.twoGetsStarted = twoStarted;
    library.getReturnGate = releaseGets.future;

    final firstHydration = session.hydrateEntry(first);
    final secondHydration = session.hydrateEntry(second);

    await twoStarted.future.timeout(const Duration(seconds: 1));
    expect(library.getCalls, 2);

    releaseGets.complete();
    final hydrated = await Future.wait<ImportedLibraryEntry>(
      <Future<ImportedLibraryEntry>>[firstHydration, secondHydration],
    );
    expect(
      hydrated.map((entry) => entry.chapter.chapterId),
      containsAll(<String>[
        first.chapter.chapterId,
        second.chapter.chapterId,
      ]),
    );
  });

  test('close waits for constructor initialization admitted before teardown',
      () async {
    final openGate = Completer<void>();
    final delegate = MemoryImportedLibraryStore();
    final library = _GatedLibraryStore(
      delegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
      openGate: openGate.future,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
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
      if (!openGate.isCompleted) {
        openGate.complete();
      }
      await session.close();
      session.dispose();
    });

    var closeCompleted = false;
    final closing = session.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);
    expect(library.closeCalls, 0);

    openGate.complete();
    await closing;

    expect(library.openCalls, 1);
    expect(library.closeCalls, 1);
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

  for (final handoff in [false, true]) {
    test('metadata-only revision recovery preserves chapter scope handoff=$handoff',
        () async {
      final root = await Directory.systemTemp.createTemp('home-metadata-recovery-');
      final library = SqliteImportedLibraryStore('${root.path}/library.sqlite');
      await library.open();
      final chapters = [for (var index = 0; index < 3; index++)
        ImportedChapterRecord.remote(comic: _versionComic('metadata-$index'),
          manifest: _versionManifest(comicId: 'metadata-$index',
            chapterId: 'chapter-$index', revision: 'r1', pageCount: 120))];
      for (final chapter in chapters) {
        await library.upsertChapter(chapter);
      }
      final proof = (await library.libraryMetadataRevision)!;
      final chapter = chapters.first;
      final snapshotStore = HomeProjectionSnapshotStore.atPath('${root.path}/home.json');
      await snapshotStore.write(HomeProjectionSnapshot(
        entries: [for (final value in chapters) ImportedLibraryEntry(chapter: value)],
        savedComics: const [], categories: const [], preferences: const [],
        readStates: const [], sourcePreferences: const [], versionRelations: const [],
        libraryRevision: proof.revision, chapterRevision: proof.chapterRevision));
      final progress = ReadingProgress(sourceId: chapter.sourceId,
        comicId: chapter.comicId, chapterId: chapter.chapterId, pageIndex: 42,
        subPageOffset: .35, readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 10, 24));
      library.enqueueProgress(progress);
      final preference = ComicPreference.defaults(sourceId: chapter.sourceId,
        comicId: chapter.comicId).copyWith(inShelf: true,
          updatedAt: DateTime.utc(2026, 10, 24));
      await library.saveComicPreference(preference);
      final relation = ComicVersionRelation(sourceId: chapter.sourceId,
        predecessorComicId: chapter.comicId, successorComicId: chapters[1].comicId,
        predecessorTitle: 'Updated relation', discoveredAt: DateTime.utc(2026, 10, 24));
      await library.saveComicVersionRelation(relation);
      final messages = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = previousDebugPrint);
      final downloads = MemoryChapterDownloadService(pageLoader: (_, _) async => Uint8List(1));
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final bootstrap = MemoryImportedLibraryStore();
      final session = HomeLibrarySession(library: handoff ? bootstrap : library,
        snapshotStore: snapshotStore, persistSnapshot: !handoff,
        chapterDownloads: downloads, wholeComicDownloads: queue, sources: const [],
        ownsLibrary: false, ownsChapterDownloads: true, ownsWholeComicDownloads: true,
        persistMissingPreferences: false);
      addTearDown(() async {
        await session.close();
        session.dispose();
        await bootstrap.close();
        await library.close();
        await root.delete(recursive: true);
      });
      await session.ready;
      if (handoff) {
        await session.adoptServices(library: library, chapterDownloads: downloads,
          wholeComicDownloads: queue, sources: const [], persistSnapshot: true);
        await session.ready;
      }
      expect(session.error, isNull);
      expect(session.entries.every((entry) => entry.chapter.isSummary), isTrue);
      final selected = session.entries.singleWhere((entry) => entry.chapter.chapterId == chapter.chapterId);
      expect(selected.progress!.toJson(), progress.toJson());
      expect(session.preferences[preference.identity]!.inShelf, isTrue);
      expect(session.versionRelations.single.predecessorTitle, 'Updated relation');
      expect(messages.where((message) => message.contains('query-entries-start')), isEmpty);
      expect(messages.any((message) => message.contains('mode=metadata-only')), isTrue);
      final hydrated = await session.hydrateEntry(selected);
      expect(hydrated.chapter.toJson(), chapter.toJson());
      expect(session.versionAuthorityEntry(sourceId: chapters[1].sourceId,
        comicId: chapters[1].comicId, chapterId: chapters[1].chapterId), isNull);
      final retained = hydrated.chapter;
      await library.saveSourcePreference(ComicSourcePreference.defaults(
        sourceId: chapter.sourceId, sortOrder: 0).copyWith(enabled: false,
          updatedAt: DateTime.utc(2026, 10, 24)));
      await session.reload();
      expect(session.versionAuthorityEntry(sourceId: chapter.sourceId,
        comicId: chapter.comicId, chapterId: chapter.chapterId)!.chapter, same(retained),
        reason: 'metadata reconciliation must not withdraw hydrated authority');
      await session.flushSnapshotWrites();
      expect((await snapshotStore.read())!.chapterRevision, proof.chapterRevision);
      // Same revision/count is insufficient when actual request carriers change.
      final replacement = chapter.copyWith(pages: [
        const ImportedPageRecord(displayName: 'fresh.png', sourceId: 'memory:fresh.png',
          contentKindHint: ContentKindHint.png), ...chapter.pages.skip(1)]);
      await library.upsertChapter(replacement);
      messages.clear();
      await session.reload();
      expect(messages.any((message) => message.contains('query-entries-start')), isTrue);
      expect(session.entries.singleWhere((entry) => entry.identity == selected.identity)
        .chapter.pages.first.sourceId, 'memory:fresh.png');
      expect((await snapshotStore.read())!.chapterRevision, isNotNull);
    });
  }

  test('late snapshot revision cannot bless an older chapter proof', () async {
    final root = await Directory.systemTemp.createTemp('home-proof-provenance-');
    final library = SqliteImportedLibraryStore('${root.path}/library.sqlite');
    await library.open();
    final chapter = _preparedBoundaryChapter();
    await library.upsertChapter(chapter);
    final before = (await library.libraryMetadataRevision)!;
    final replacement = chapter.copyWith(pages: [
      const ImportedPageRecord(displayName: 'new.png', sourceId: 'memory:new.png',
        contentKindHint: ContentKindHint.png), ...chapter.pages.skip(1)]);
    await library.upsertChapter(replacement);
    final after = (await library.libraryMetadataRevision)!;
    final snapshotStore = HomeProjectionSnapshotStore.atPath('${root.path}/home.json');
    await snapshotStore.write(HomeProjectionSnapshot(
      entries: [ImportedLibraryEntry(chapter: chapter)], savedComics: const [],
      categories: const [], preferences: const [], readStates: const [],
      sourcePreferences: const [], versionRelations: const [],
      libraryRevision: after.revision, chapterRevision: before.chapterRevision));
    final downloads = MemoryChapterDownloadService(pageLoader: (_, _) async => Uint8List(1));
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(library: library, snapshotStore: snapshotStore,
      chapterDownloads: downloads, wholeComicDownloads: queue, sources: const [],
      ownsLibrary: true, ownsChapterDownloads: true, ownsWholeComicDownloads: true);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await root.delete(recursive: true);
    });
    await session.ready;
    expect(session.entries.single.chapter.pages.first.sourceId, 'memory:new.png');
    await session.flushSnapshotWrites();
    expect((await snapshotStore.read())!.chapterRevision, after.chapterRevision);
  });

  test('metadata reconciliation cannot overwrite a concurrent chapter upsert', () async {
    final root = await Directory.systemTemp.createTemp('home-metadata-concurrent-');
    final delegate = SqliteImportedLibraryStore('${root.path}/library.sqlite');
    await delegate.open();
    final chapter = _preparedBoundaryChapter();
    await delegate.upsertChapter(chapter);
    final library = _GatedLibraryStore(delegate, Future.value(const []),
      readCategoriesFromDelegate: true);
    final downloads = MemoryChapterDownloadService(pageLoader: (_, _) async => Uint8List(1));
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(library: library,
      chapterDownloads: downloads, wholeComicDownloads: queue, sources: const [],
      ownsLibrary: true, ownsChapterDownloads: true, ownsWholeComicDownloads: true);
    final gate = Completer<void>();
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await session.close();
      session.dispose();
      await root.delete(recursive: true);
    });
    await session.ready;
    final listCalls = library.listCalls;
    library.categoryListCalls = 0;
    library.categoryListStarted = Completer<void>();
    library.categoryListReturnGate = gate.future;
    final reload = session.reload();
    await library.categoryListStarted!.future;
    final replacement = chapter.copyWith(displayName: 'Concurrent chapter');
    await session.upsertChapter(replacement);
    gate.complete();
    await reload;
    expect(library.listCalls, listCalls,
      reason: 'unchanged chapter proof must keep reconciliation metadata-only');
    expect(session.entries.single.chapter.displayName, 'Concurrent chapter');
    expect(session.versionAuthorityEntry(sourceId: chapter.sourceId,
      comicId: chapter.comicId, chapterId: chapter.chapterId)!.chapter, same(replacement));
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

  test('public reload waits for an already admitted service adoption',
      () async {
    final bootstrapDelegate = MemoryImportedLibraryStore();
    final bootstrapLibrary = _GatedLibraryStore(
      bootstrapDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(
      downloads: bootstrapDownloads,
    );
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    await session.ready;

    final closeGate = Completer<void>();
    bootstrapLibrary.closeReturnGate = closeGate.future;
    final durableDelegate = MemoryImportedLibraryStore();
    await durableDelegate.open();
    final durableLibrary = _GatedLibraryStore(
      durableDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    addTearDown(() async {
      if (!closeGate.isCompleted) {
        closeGate.complete();
      }
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
    });

    var adoptionDone = false;
    final adoption = session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    )..then((_) => adoptionDone = true);

    for (var attempt = 0;
        attempt < 100 && !identical(session.library, durableLibrary);
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(session.library, same(durableLibrary));
    for (var attempt = 0;
        attempt < 100 && bootstrapLibrary.closeCalls == 0;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(bootstrapLibrary.closeCalls, 1);
    expect(adoptionDone, isFalse);

    var reloadDone = false;
    final reload = session.reload()..then((_) => reloadDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(reloadDone, isFalse);
    expect(durableLibrary.listCalls, 0);

    closeGate.complete();
    await adoption;
    await reload;
    expect(adoptionDone, isTrue);
    expect(durableLibrary.listCalls, greaterThanOrEqualTo(2));
  });

  test('service adoption waits for an already admitted public reload',
      () async {
    final bootstrapDelegate = MemoryImportedLibraryStore();
    final bootstrapLibrary = _GatedLibraryStore(
      bootstrapDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(
      downloads: bootstrapDownloads,
    );
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    await session.ready;

    final reloadStarted = Completer<void>();
    final reloadGate = Completer<void>();
    bootstrapLibrary.listStarted = reloadStarted;
    bootstrapLibrary.listReturnGate = reloadGate.future;
    final reload = session.reload();
    await reloadStarted.future;

    final durableLibrary = MemoryImportedLibraryStore();
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    addTearDown(() async {
      if (!reloadGate.isCompleted) {
        reloadGate.complete();
      }
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
    });

    var adoptionDone = false;
    final adoption = session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    )..then((_) => adoptionDone = true);

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(adoptionDone, isFalse);
    expect(session.library, same(bootstrapLibrary));

    reloadGate.complete();
    await reload;
    await adoption;
    expect(adoptionDone, isTrue);
    expect(session.library, same(durableLibrary));
  });

  test('retry joins an already admitted service adoption before open',
      () async {
    final bootstrapDelegate = MemoryImportedLibraryStore();
    final bootstrapLibrary = _GatedLibraryStore(
      bootstrapDelegate,
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue = WholeComicDownloadQueue(
      downloads: bootstrapDownloads,
    );
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    await session.ready;

    final closeGate = Completer<void>();
    bootstrapLibrary.closeReturnGate = closeGate.future;
    final durableLibrary = _GatedLibraryStore(
      MemoryImportedLibraryStore(),
      Future<List<LibraryCategory>>.value(const <LibraryCategory>[]),
    );
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    addTearDown(() async {
      if (!closeGate.isCompleted) {
        closeGate.complete();
      }
      await session.close();
      session.dispose();
      await durableQueue.close();
      await durableDownloads.close();
      await durableLibrary.close();
    });

    final adoption = session.adoptServices(
      library: durableLibrary,
      chapterDownloads: durableDownloads,
      wholeComicDownloads: durableQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    for (var attempt = 0;
        attempt < 100 && !identical(session.library, durableLibrary);
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(session.library, same(durableLibrary));
    for (var attempt = 0;
        attempt < 100 && bootstrapLibrary.closeCalls == 0;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(bootstrapLibrary.closeCalls, 1);
    // Adoption opens authority before retiring bootstrap. Retry must not open
    // it again until that retirement and the projection tail have drained.
    expect(durableLibrary.openCalls, 1);

    var retryDone = false;
    final retry = session.retry()..then((_) => retryDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(retryDone, isFalse);
    expect(durableLibrary.openCalls, 1);

    closeGate.complete();
    await adoption;
    await retry;
    expect(retryDone, isTrue);
    expect(durableLibrary.openCalls, 2);
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


  test('chapter hydration reuses matching full entry and rejects stale revision',
      () async {
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

    final firstManifest = _versionManifest(
      comicId: 'hydrate-cache-comic',
      chapterId: 'hydrate-cache-chapter',
      revision: 'hydrate-r1',
      pageCount: 2,
    );
    final firstRecord = ImportedChapterRecord.remote(
      comic: _versionComic(firstManifest.comicId),
      manifest: firstManifest,
    );
    await delegate.upsertChapter(firstRecord);
    final requested = ImportedLibraryEntry(chapter: firstRecord);

    final first = await session.hydrateEntry(requested);
    final second = await session.hydrateEntry(requested);
    expect(first.chapter.sourceRevision, 'hydrate-r1');
    expect(second, same(first));
    expect(library.getCalls, 1);

    final compactRequest = ImportedLibraryEntry(
      chapter: firstRecord.copyWith(
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: 'snapshot-page',
            sourceId: 'zic-home-snapshot-page:0',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final compactHydrated = await session.hydrateEntry(compactRequest);
    expect(compactHydrated, same(first));
    expect(
      library.getCalls,
      1,
      reason: 'a compact projection must reuse same-revision hydrated authority',
    );

    final secondManifest = _versionManifest(
      comicId: 'hydrate-cache-comic',
      chapterId: 'hydrate-cache-chapter',
      revision: 'hydrate-r2',
      pageCount: 2,
    );
    final secondRecord = ImportedChapterRecord.remote(
      comic: _versionComic(secondManifest.comicId),
      manifest: secondManifest,
    );
    await delegate.upsertChapter(secondRecord);
    final refreshed = await session.hydrateEntry(
      ImportedLibraryEntry(chapter: secondRecord),
    );
    expect(refreshed.chapter.sourceRevision, 'hydrate-r2');
    expect(library.getCalls, 2);
  });

  test('source upsert replaces same-revision hydrated provider locators',
      () async {
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

    ChapterManifest manifest(String carrier) => ChapterManifest(
          sourceId: 'venera:jm',
          comicId: 'comic',
          chapter: const Chapter(
            chapterId: 'chapter',
            comicId: 'comic',
            title: 'Chapter',
            sequence: 1,
            pageCount: 1,
            sourceRevision: 'ep-1',
          ),
          pages: <PageAsset>[
            PageAsset(
              pageId: 'chapter:0',
              chapterId: 'chapter',
              index: 0,
              uri: Uri.parse('venera-resource:$carrier'),
            ),
          ],
          readingDirection: ReadingDirection.ltr,
        );
    Comic comic() => Comic(
          comicId: 'comic',
          sourceId: 'venera:jm',
          title: 'Comic',
          authors: const <String>[],
          readingDirection: ReadingDirection.ltr,
        );

    await session.upsertChapter(
      ImportedChapterRecord.remote(comic: comic(), manifest: manifest('first')),
    );
    final progress = ReadingProgress(
      sourceId: 'venera:jm',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 0,
      subPageOffset: 0.5,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 9, 15, 1),
    );
    await session.persistProgress(progress);

    await session.upsertChapter(
      ImportedChapterRecord.remote(comic: comic(), manifest: manifest('second')),
    );
    final authority = session.versionAuthorityEntry(
      sourceId: 'venera:jm',
      comicId: 'comic',
      chapterId: 'chapter',
    );
    expect(authority, isNotNull);
    expect(
      authority!.chapter.toManifest().pages.single.uri,
      Uri.parse('venera-resource:second'),
    );
    expect(authority.progress?.updatedAt, progress.updatedAt);
  });

  test('canonical refresh reuses unchanged manifests and evicts removed authority',
      () async {
    final messages = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
    addTearDown(() => debugPrint = previousDebugPrint);
    final root = await Directory.systemTemp.createTemp('unchanged-upsert-');
    final composition = await PersistentDownloadComposition.open(
      root.path,
      transferNet: DownloadResourceCoordinator().networkLane,
    );
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      downloadComposition: composition,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await composition.close();
      await root.delete(recursive: true);
    });
    await session.ready;
    final siblingManifest = _versionManifestWithImageKeys(
      comicId: 'cached-sibling', chapterId: 'cached-sibling-chapter',
      revision: 'cached-sibling-r1', imageKeys: List<String>.generate(
        256, (index) => index.toRadixString(16).padLeft(32, 'a')),
    );
    final sibling = ImportedChapterRecord.remote(
      comic: _versionComic(siblingManifest.comicId), manifest: siblingManifest,
    );
    // Chapters without resolvable physical media must also avoid repeat page
    // scans. The runtime filters them out of its published resolvable scope.
    final opaqueManifest = _versionManifest(comicId: 'cached-unresolved',
      chapterId: 'cached-unresolved-chapter', revision: 'unresolved-r1',
      pageCount: 512);
    await session.upsertChapter(sibling);
    await session.upsertChapter(ImportedChapterRecord.remote(
      comic: _versionComic(opaqueManifest.comicId), manifest: opaqueManifest));
    final siblingId = readerPageDownloadId(siblingManifest, siblingManifest.pages.first);
    final siblingPhysical = composition.transferRuntime.physicalMediaIdFor(siblingId);
    expect(siblingPhysical.isExactFallback, isFalse);
    final manifest = _versionManifest(
      comicId: 'unchanged-comic',
      chapterId: 'unchanged-chapter',
      revision: 'unchanged-revision',
      pageCount: 1,
    );
    final chapter = ImportedChapterRecord.remote(
      comic: _versionComic(manifest.comicId),
      manifest: manifest,
    );
    await session.upsertChapter(chapter);
    messages.clear();
    final reloaded = ImportedChapterRecord.fromJson(chapter.toJson());
    expect(reloaded, isNot(same(chapter)));
    await session.upsertChapter(reloaded);
    await session.upsertChapter(ImportedChapterRecord.fromJson(sibling.toJson()));
    expect(
      messages.where((value) =>
          value.contains('canonical-media-authority-refresh-complete')),
      isEmpty,
      reason: 'a cached boundary must not rebuild all hydrated chapters',
    );
    final updated = chapter.copyWith(
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          pageId: chapter.pages.single.pageId,
          displayName: chapter.pages.single.displayName,
          sourceId: 'venera-resource:changed-provider',
          contentKindHint: chapter.pages.single.contentKindHint,
        ),
      ],
    );
    messages.clear();
    await session.upsertChapter(updated);
    expect(
      messages.where((value) =>
          value.contains('canonical-media-authority-refresh-complete')),
      hasLength(1),
      reason: 'a real same-revision provider change publishes once',
    );
    expect(messages.singleWhere((value) =>
      value.contains('canonical-media-authority-refresh-complete')),
      contains('rebuilt=1 reused=2 scannedPages=1'),
      reason: 'one changed page must not rescan 768 unrelated manifest pages');
    expect(composition.transferRuntime.physicalMediaIdFor(siblingId), siblingPhysical);
    final authority = session.versionAuthorityEntry(
      sourceId: updated.sourceId,
      comicId: updated.comicId,
      chapterId: updated.chapterId,
    );
    expect(authority!.chapter.pages.single.sourceId,
        'venera-resource:changed-provider');
    messages.clear();
    await session.removeChapter(sibling.sourceId, sibling.chapterId);
    expect(messages.singleWhere((value) =>
      value.contains('canonical-media-authority-refresh-complete')),
      contains('rebuilt=0 reused=2 scannedPages=0'));
    expect(composition.transferRuntime.physicalMediaIdFor(siblingId).isExactFallback,
      isTrue, reason: 'a removed chapter cannot retain cached routing authority');
    messages.clear();
    await session.upsertChapter(sibling);
    expect(messages.singleWhere((value) =>
      value.contains('canonical-media-authority-refresh-complete')),
      contains('rebuilt=1 reused=2 scannedPages=256'),
      reason: 'removed authority was evicted even when the same record returns');
    expect(composition.transferRuntime.physicalMediaIdFor(siblingId), siblingPhysical);
    await session.upsertChapter(sibling.copyWith(directoryRecursive: false));
    expect(session.versionAuthorityEntry(sourceId: sibling.sourceId,
      comicId: sibling.comicId, chapterId: sibling.chapterId)!
        .chapter.directoryRecursive, isFalse,
      reason: 'preserving an unchanged record must still compare all persisted fields');
    ImportedChapterRecord collision(String chapterId, String revision) =>
      ImportedChapterRecord.remote(comic: _versionComic('collision'),
        manifest: _versionManifestWithImageKeys(comicId: 'collision',
          chapterId: chapterId, revision: revision, imageKeys: ['c' * 32]));
    final first = collision('chapter', 'rev\u0000part');
    final second = collision('chapter\u0000rev', 'part');
    await session.upsertChapter(first);
    final firstManifest = first.toManifest();
    final firstId = readerPageDownloadId(firstManifest, firstManifest.pages.first);
    final physical = composition.transferRuntime.physicalMediaIdFor(firstId);
    await expectLater(session.upsertChapter(second), throwsStateError,
      reason: 'reuse must preserve runtime duplicate-key rejection, not overwrite it');
    expect(composition.transferRuntime.physicalMediaIdFor(firstId), physical);
    await session.removeChapter(second.sourceId, second.chapterId);
    expect(composition.transferRuntime.physicalMediaIdFor(firstId), physical);
  });

  test('hydrated chapter cache follows newer Reader progress projection',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final manifest = _versionManifest(
      comicId: 'progress-cache-comic',
      chapterId: 'progress-cache-chapter',
      revision: 'progress-cache-r1',
      pageCount: 3,
    );
    final record = ImportedChapterRecord.remote(
      comic: _versionComic(manifest.comicId),
      manifest: manifest,
    );
    await delegate.upsertChapter(record);
    await delegate.saveProgress(
      ReadingProgress(
        sourceId: manifest.sourceId,
        comicId: manifest.comicId,
        chapterId: manifest.chapter.chapterId,
        pageIndex: 2,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 10, 1),
      ),
    );
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

    final first = await session.hydrateEntry(session.entries.single);
    expect(first.progress?.pageIndex, 2);
    expect(
      library.getCalls,
      0,
      reason: 'authoritative list() already supplied the full chapter payload',
    );

    session.replaceProgress(
      ReadingProgress(
        sourceId: manifest.sourceId,
        comicId: manifest.comicId,
        chapterId: manifest.chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 10, 1, 1),
      ),
    );

    final reopened = await session.hydrateEntry(session.entries.single);
    expect(reopened.progress?.pageIndex, 0);
    expect(reopened.chapter.pages, hasLength(3));
    expect(
      reopened.chapter.pages.first.sourceId,
      record.pages.first.sourceId,
      reason: 'progress refresh must preserve the fully hydrated chapter payload',
    );
    expect(
      library.getCalls,
      0,
      reason: 'Reader reopen should keep using the authoritative list payload',
    );
  });

  test('hydrated chapter cache never outranks newer store Reader progress',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    final manifest = _versionManifest(
      comicId: 'progress-owner-comic',
      chapterId: 'progress-owner-chapter',
      revision: 'progress-owner-r1',
      pageCount: 4,
    );
    final record = ImportedChapterRecord.remote(
      comic: _versionComic(manifest.comicId),
      manifest: manifest,
    );
    await library.upsertChapter(record);
    final oldProgress = ReadingProgress(
      sourceId: manifest.sourceId,
      comicId: manifest.comicId,
      chapterId: manifest.chapter.chapterId,
      pageIndex: 1,
      subPageOffset: 0,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 9, 19, 1),
    );
    await library.saveProgress(oldProgress);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: false,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
      await library.close();
    });
    await session.ready;

    final first = await session.hydrateEntry(session.entries.single);
    expect(first.progress?.pageIndex, 1);

    final advanced = oldProgress.copyWith(
      pageIndex: 3,
      updatedAt: DateTime.utc(2026, 9, 19, 1, 1),
    );
    // Simulate the Reader checkpoint writer advancing durable progress before
    // the route-local Home projection has been replaced.
    await library.saveProgress(advanced);
    expect(session.entries.single.progress?.pageIndex, 1);

    final reopened = await session.hydrateEntry(session.entries.single);
    expect(reopened.progress?.pageIndex, 3);
    expect(reopened.chapter.pages, hasLength(4));
    expect(
      session.versionAuthorityEntry(
        sourceId: manifest.sourceId,
        comicId: manifest.comicId,
        chapterId: manifest.chapter.chapterId,
      )?.progress?.pageIndex,
      3,
    );
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

  test('service adoption drains old projection reads before owned retirement',
      () async {
    final old = _ProjectionRaceChapterDownloads();
    final oldQueue = WholeComicDownloadQueue(downloads: old);
    final next = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final nextQueue = WholeComicDownloadQueue(downloads: next);
    final nextLibrary = MemoryImportedLibraryStore();
    final session = HomeLibrarySession(
      library: MemoryImportedLibraryStore(),
      chapterDownloads: old,
      wholeComicDownloads: oldQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      if (!old.cacheRelease.isCompleted) old.cacheRelease.complete();
      await session.close();
      session.dispose();
      await nextQueue.close();
      await next.close();
      await nextLibrary.close();
    });
    await session.ready;
    final read = session.refreshDownloadCacheProjection(
      const <ImportedLibraryEntry>[],
    );
    await old.cacheStarted.future;
    var adopted = false;
    final adoption = session.adoptServices(
      library: nextLibrary,
      chapterDownloads: next,
      wholeComicDownloads: nextQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    ).then((_) => adopted = true);
    await Future<void>.delayed(Duration.zero);
    expect(session.chapterDownloads, same(next));
    expect(adopted, isFalse);
    expect(old.closed, isFalse);
    old.cacheRelease.complete();
    await read;
    await adoption;
    expect(old.closed, isTrue);
    expect(session.downloadCacheProjection, isNull,
        reason: 'retired service must not publish its late cache projection');
  });

  for (final cacheOnly in <bool>[false, true]) {
    test('close drains admitted download projection I/O (cacheOnly=$cacheOnly)',
        () async {
      final downloads = _ProjectionRaceChapterDownloads();
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: MemoryImportedLibraryStore(),
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: true,
        ownsWholeComicDownloads: true,
      );
      await session.ready;
      await Future<void>.delayed(Duration.zero);
      downloads.managementStarted = Completer<void>();
      downloads.managementRelease = Completer<void>();
      final read = cacheOnly
          ? session.refreshDownloadCacheProjection(const <ImportedLibraryEntry>[])
          : session.refreshDownloadSnapshots(const <ImportedLibraryEntry>[]);
      await (cacheOnly
          ? downloads.cacheStarted.future
          : downloads.managementStarted!.future);
      if (cacheOnly) downloads.notifyCacheChanged();
      var closed = false;
      final closing = session.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(downloads.closed, isFalse);
      final callsAtClose = downloads.managementCalls;
      await session.refreshDownloadSnapshots(const <ImportedLibraryEntry>[]);
      expect(downloads.managementCalls, callsAtClose);
      (cacheOnly ? downloads.cacheRelease : downloads.managementRelease!)
          .complete();
      await read;
      await closing;
      expect(downloads.closed, isTrue);
      if (cacheOnly) {
        expect(downloads.cacheCalls, 1,
            reason: 'close drains the stale read without admitting a retry');
      }
      session.dispose();
    });
  }

  for (final scenario in <(ChapterDownloadPhase, String)>[
    (ChapterDownloadPhase.downloading, 'r1'),
    (ChapterDownloadPhase.complete, 'r1'),
    (ChapterDownloadPhase.idle, 'r1'),
    (ChapterDownloadPhase.downloading, 'r2'),
    (ChapterDownloadPhase.complete, 'r2'),
    (ChapterDownloadPhase.idle, 'r2'),
  ]) {
    final (phase, revision) = scenario;
    test('management scan preserves concurrent $phase revision=$revision',
        () async {
      final downloads = _ProjectionRaceChapterDownloads();
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: MemoryImportedLibraryStore(),
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: true,
        ownsWholeComicDownloads: true,
      );
      addTearDown(() async {
        downloads.managementRelease?.complete();
        await session.close();
        session.dispose();
      });
      await session.ready;
      await Future<void>.delayed(Duration.zero);
      const stale = ChapterDownloadSnapshot(
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapterId: 'chapter', sourceRevision: 'r1', title: 'Chapter',
        completedPages: 1, totalPages: 2, receivedBytes: 50,
        phase: ChapterDownloadPhase.downloading,
      );
      session.acceptDownloadSnapshot(stale);
      downloads.managementSnapshots = <ChapterDownloadSnapshot>[stale];
      downloads.managementStarted = Completer<void>();
      downloads.managementRelease = Completer<void>();
      final refresh = session.refreshDownloadSnapshots(
        const <ImportedLibraryEntry>[],
      );
      await downloads.managementStarted!.future;
      final live = ChapterDownloadSnapshot(
        sourceId: 'source', comicId: 'comic', comicTitle: 'Comic',
        chapterId: 'chapter', sourceRevision: revision, title: 'Chapter',
        completedPages: phase == ChapterDownloadPhase.complete ? 2 : 0,
        totalPages: 2,
        receivedBytes: phase == ChapterDownloadPhase.idle ? 0 : 100,
        phase: phase,
      );
      downloads.publish(live);
      await Future<void>.delayed(Duration.zero);
      downloads.managementRelease!.complete();
      downloads.managementRelease = null;
      await refresh;
      expect(session.downloadSnapshots.values, <ChapterDownloadSnapshot>[live]);
      if (revision != stale.sourceRevision) {
        expect(session.downloadSnapshots.containsKey(stale.identity), isFalse);
      }
    });
  }

  test(
    'manual download refresh fences and retries an older cache-only publication',
    () async {
      final downloads = _ProjectionRaceChapterDownloads();
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: MemoryImportedLibraryStore(),
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: true,
        ownsWholeComicDownloads: true,
      );
      addTearDown(() async {
        if (!downloads.cacheRelease.isCompleted) {
          downloads.cacheRelease.complete();
        }
        await session.close();
        session.dispose();
      });
      await session.ready;

      final staleRefresh = session.refreshDownloadCacheProjection(
        const <ImportedLibraryEntry>[],
      );
      await downloads.cacheStarted.future;

      await session.refreshDownloadSnapshots(
        const <ImportedLibraryEntry>[],
      );
      expect(session.downloadCacheProjection, isNull,
          reason: 'manual management must not eagerly build cache inventory');

      downloads.cacheRelease.complete();
      await staleRefresh;

      expect(
        session.downloadCacheProjection?.exact.single.title,
        'authoritative-full',
      );
    },
  );

  test('cache invalidation rejects an in-flight pre-clear projection', () async {
    final downloads = _ProjectionRaceChapterDownloads();
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: MemoryImportedLibraryStore(), chapterDownloads: downloads,
      wholeComicDownloads: queue, sources: const <BrowsableComicSource>[],
      ownsLibrary: true, ownsChapterDownloads: true, ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      if (!downloads.cacheRelease.isCompleted) downloads.cacheRelease.complete();
      await session.close();
      session.dispose();
    });
    await session.ready;
    final read = session.refreshDownloadCacheProjection(const []);
    final joined = session.refreshDownloadCacheProjection(const []);
    await downloads.cacheStarted.future;
    expect(downloads.cacheCalls, 1);
    downloads.notifyCacheChanged();
    downloads.cacheRelease.complete();
    await Future.wait([read, joined]);
    expect(downloads.cacheCalls, 2);
    expect(session.downloadCacheProjection?.exact.single.title, 'authoritative-full');
    final fullCalls = downloads.managementCalls;
    downloads.notifyCacheChanged();
    expect(session.downloadCacheProjection, isNull);
    await session.refreshDownloadCacheProjection(const []);
    expect(downloads.cacheCalls, 3);
    expect(downloads.managementCalls, fullCalls);
  });

}


ImportedChapterRecord _preparedBoundaryChapter() => ImportedChapterRecord(
      directoryId: 'remote:prepared',
      displayName: 'Prepared chapter',
      sourceId: 'fixture-source',
      comicId: 'prepared-comic',
      chapterId: 'prepared-chapter',
      sourceRevision: 'prepared-revision',
      comicTitle: 'Prepared comic',
      comicAuthors: const <String>['Author'],
      comicTags: const <String>['Tag'],
      comicDescription: 'Description',
      coverSourceId: 'https://example.test/cover.webp',
      coverMediaFormat: 'webp',
      coverAnimatedHint: true,
      sequence: 6,
      sourceUpdatedAt: DateTime.utc(2026, 9, 30),
      importedAt: DateTime.utc(2026, 9, 30),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'first.webp',
          sourceId: 'mihon-page:opaque-carrier',
          pageId: 'first',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          byteLength: 100,
          checksum: 'aabb',
          checksumAlgorithm: 'sha256',
          animatedHint: true,
        ),
        ImportedPageRecord(
          displayName: 'last.jpg',
          sourceId: 'https://example.test/last.jpg?signature=a%2Fb',
          pageId: 'last',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );

final class _ProjectionRaceChapterDownloads
    implements
        ChapterDownloadService,
        ChapterDownloadManagementProjectionReader,
        ChapterCacheManagementProjectionReader,
        ChapterDownloadManagementChangeSource {
  final StreamController<void> _cacheChanges =
      StreamController<void>.broadcast(sync: true);
  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast();
  final Completer<void> cacheStarted = Completer<void>();
  final Completer<void> cacheRelease = Completer<void>();
  Completer<void>? managementStarted;
  Completer<void>? managementRelease;
  List<ChapterDownloadSnapshot> managementSnapshots =
      const <ChapterDownloadSnapshot>[];

  bool closed = false;
  int managementCalls = 0;
  int cacheCalls = 0;

  @override
  Stream<void> get managementProjectionChanges => _cacheChanges.stream;

  void notifyCacheChanged() => _cacheChanges.add(null);

  void publish(ChapterDownloadSnapshot snapshot) => _changes.add(snapshot);

  ChapterCacheManagementProjection get _staleCache =>
      ChapterCacheManagementProjection(
        canonical: const <CanonicalChapterCacheSnapshot>[],
        exact: const <ExactChapterCacheSnapshot>[
          ExactChapterCacheSnapshot(
            sourceId: 'source',
            comicId: 'comic',
            comicTitle: 'comic',
            chapterId: 'chapter',
            sourceRevision: 'r1',
            title: 'stale-cache-only',
            readyPages: 1,
            partialPages: 0,
            receivedBytes: 1,
          ),
        ],
      );

  ChapterCacheManagementProjection get _authoritativeCache =>
      ChapterCacheManagementProjection(
        canonical: const <CanonicalChapterCacheSnapshot>[],
        exact: const <ExactChapterCacheSnapshot>[
          ExactChapterCacheSnapshot(
            sourceId: 'source',
            comicId: 'comic',
            comicTitle: 'comic',
            chapterId: 'chapter',
            sourceRevision: 'r1',
            title: 'authoritative-full',
            readyPages: 1,
            partialPages: 0,
            receivedBytes: 1,
          ),
        ],
      );

  @override
  Stream<ChapterDownloadSnapshot> get changes => _changes.stream;

  @override
  Future<ChapterCacheManagementProjection> inspectCacheManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    final captured = cacheCalls++ == 0 ? _staleCache : _authoritativeCache;
    if (!cacheStarted.isCompleted) {
      cacheStarted.complete();
    }
    await cacheRelease.future;
    return captured;
  }

  @override
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries, {
    bool includeCache = true,
  }) async {
    managementCalls++;
    final snapshots = managementSnapshots;
    managementStarted?.complete();
    await managementRelease?.future;
    return ChapterDownloadManagementProjection(
      orphanedEntries: const <ImportedLibraryEntry>[],
      snapshots: snapshots,
      cache: includeCache ? _authoritativeCache : null,
    );
  }

  @override
  void updateVersionBaselines(List<ComicVersionRelation> relations) {}

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {}

  @override
  Future<void> close() {
    closed = true;
    unawaited(_cacheChanges.close());
    return _changes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}


Comic _versionComic(String comicId) => Comic(
      comicId: comicId,
      sourceId: 'version-source',
      title: comicId,
      authors: const <String>[],
      readingDirection: ReadingDirection.ltr,
    );

ChapterManifest _versionManifestWithImageKeys({
  required String comicId,
  required String chapterId,
  required String revision,
  required List<String> imageKeys,
}) {
  final chapter = Chapter(
    chapterId: chapterId,
    comicId: comicId,
    title: chapterId,
    sequence: 1,
    pageCount: imageKeys.length,
    sourceRevision: revision,
  );
  return ChapterManifest(
    sourceId: 'version-source',
    comicId: comicId,
    chapter: chapter,
    readingDirection: ReadingDirection.ltr,
    pages: <PageAsset>[
      for (var index = 0; index < imageKeys.length; index++)
        PageAsset(
          pageId: '$chapterId-page-$index',
          chapterId: chapterId,
          index: index,
          uri: Uri.parse(
            'https://e-hentai.org/s/${imageKeys[index]}/100-$index',
          ),
          contentKindHint: ContentKindHint.webp,
        ),
    ],
  );
}

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

final class _FixtureBrowsableSource implements BrowsableComicSource {
  const _FixtureBrowsableSource(this.sourceId);

  @override
  final String sourceId;

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: sourceId,
        language: 'en',
        website: Uri.https('example.test', '/$sourceId'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<Uint8List> loadResource(Uri uri) async => Uint8List(0);

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnsupportedError('fixture source does not load comics');

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnsupportedError('fixture source does not load chapters');
}

final class _GatedLibraryStore
    implements
        ImportedLibraryStore,
        ImportedLibraryBatchLookup,
        ImportedLibraryRevisionStore,
        ImportedLibraryMetadataStore,
        ComicVersionRelationStore {
  _GatedLibraryStore(
    this.delegate,
    this.categories, {
    this.openGate,
    this.libraryRevision,
    this.readCategoriesFromDelegate = false,
  });

  final ImportedLibraryStore delegate;
  final Future<List<LibraryCategory>> categories;
  final Future<void>? openGate;
  final bool readCategoriesFromDelegate;
  int? libraryRevision;
  Future<void>? libraryRevisionReadGate;
  Future<void>? closeReturnGate;
  var libraryRevisionReads = 0;
  var openCalls = 0;
  var closeCalls = 0;
  var comicPreferenceWrites = 0;
  var sourcePreferenceWrites = 0;
  var listCalls = 0;
  Completer<void>? listStarted;
  Future<void>? listReturnGate;
  var getCalls = 0;
  Completer<void>? getStarted;
  Completer<void>? twoGetsStarted;
  Future<void>? getReturnGate;
  var getManyCalls = 0;
  var categoryListCalls = 0;
  Completer<void>? categoryListStarted;
  Future<void>? categoryListReturnGate;
  var sourcePreferenceListCalls = 0;
  Completer<void>? sourcePreferenceListStarted;
  Future<void>? sourcePreferenceListReturnGate;
  Completer<void>? categoryRemoveStarted;
  Future<void>? categoryRemoveReturnGate;
  Completer<void>? chapterWriteStarted;
  Future<void>? chapterWriteReturnGate;
  Completer<void>? comicPreferenceWriteStarted;
  Future<void>? comicPreferenceWriteReturnGate;
  Completer<void>? versionRelationWriteStarted;
  Future<void>? versionRelationWriteReturnGate;
  Object? versionRelationWriteError;
  Object? versionRelationReadError;
  Future<void>? versionRelationReadGate;
  Completer<void>? versionRelationReadStarted;

  ComicVersionRelationStore get _versionRelations =>
      delegate as ComicVersionRelationStore;

  @override
  Future<({int revision, String chapterRevision})?> get libraryMetadataRevision async =>
      delegate is ImportedLibraryMetadataStore
          ? await (delegate as ImportedLibraryMetadataStore).libraryMetadataRevision
          : null;

  @override
  Future<List<ReadingProgress>> listReadingProgress() =>
      (delegate as ImportedLibraryMetadataStore).listReadingProgress();

  @override
  Future<int?> get libraryProjectionRevision async {
    libraryRevisionReads++;
    await libraryRevisionReadGate;
    return libraryRevision;
  }

  @override
  Future<void> open() async {
    openCalls++;
    await openGate;
    await delegate.open();
  }
  @override
  Future<List<ImportedLibraryEntry>> list() async {
    listCalls++;
    final started = listStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await listReturnGate;
    return delegate.list();
  }
  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) async {
    getCalls++;
    if (getCalls >= 2) {
      final twoStarted = twoGetsStarted;
      if (twoStarted != null && !twoStarted.isCompleted) {
        twoStarted.complete();
      }
    }
    final started = getStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await getReturnGate;
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
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    await delegate.upsertChapter(chapter);
    final started = chapterWriteStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await chapterWriteReturnGate;
  }
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
  Future<List<LibraryCategory>> listCategories() async {
    if (!readCategoriesFromDelegate) {
      return categories;
    }
    final result = await delegate.listCategories();
    categoryListCalls++;
    final started = categoryListStarted;
    if (categoryListCalls == 1 &&
        started != null &&
        !started.isCompleted) {
      started.complete();
      await categoryListReturnGate;
    }
    return result;
  }
  @override
  Future<void> upsertCategory(LibraryCategory category) =>
      delegate.upsertCategory(category);
  @override
  Future<void> removeCategory(String categoryId) async {
    await delegate.removeCategory(categoryId);
    final started = categoryRemoveStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await categoryRemoveReturnGate;
  }
  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      delegate.listComicPreferences();
  @override
  Future<ComicPreference?> getComicPreference(String sourceId, String comicId) =>
      delegate.getComicPreference(sourceId, comicId);
  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    comicPreferenceWrites++;
    await delegate.saveComicPreference(preference);
    final started = comicPreferenceWriteStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await comicPreferenceWriteReturnGate;
  }
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
  Future<List<ComicSourcePreference>> listSourcePreferences() async {
    final result = await delegate.listSourcePreferences();
    sourcePreferenceListCalls++;
    final started = sourcePreferenceListStarted;
    if (sourcePreferenceListCalls == 1 &&
        started != null &&
        !started.isCompleted) {
      started.complete();
      await sourcePreferenceListReturnGate;
    }
    return result;
  }
  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) =>
      Future<void>(() {
        sourcePreferenceWrites++;
        return delegate.saveSourcePreference(preference);
      });
  @override
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() async {
    final started = versionRelationReadStarted;
    if (started != null && !started.isCompleted) started.complete();
    await versionRelationReadGate;
    final error = versionRelationReadError;
    if (error != null) throw error;
    return _versionRelations.listAllComicVersionRelations();
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) =>
      _versionRelations.listComicVersionPredecessors(
        sourceId,
        successorComicId,
      );

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) =>
      _versionRelations.listComicVersionSuccessors(
        sourceId,
        predecessorComicId,
      );

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) async {
    final error = versionRelationWriteError;
    if (error != null) {
      throw error;
    }
    await _versionRelations.saveComicVersionRelation(relation);
    final started = versionRelationWriteStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await versionRelationWriteReturnGate;
  }

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
  Future<void> close() async {
    closeCalls++;
    await delegate.close();
    await closeReturnGate;
  }
}
