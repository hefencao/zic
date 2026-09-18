import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:zic/home_library_session.dart';

void main() {
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
    'hydrated chapter outranks compact Home snapshot for canonical media authority',
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
      await composition.artifactStore.persistCanonicalMediaProjection(
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
      );
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

      final newId = readerPageDownloadId(newManifest, newManifest.pages[1]);
      expect(
        composition.transferRuntime.physicalMediaIdFor(newId).isExactFallback,
        isFalse,
      );
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
    expect(durableLibrary.openCalls, 0);

    var retryDone = false;
    final retry = session.retry()..then((_) => retryDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(retryDone, isFalse);
    expect(durableLibrary.openCalls, 0);

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

  ComicVersionRelationStore get _versionRelations =>
      delegate as ComicVersionRelationStore;

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
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() =>
      _versionRelations.listAllComicVersionRelations();

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
