import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('comic version page mapping parses verified time strictly', () {
    final mapping = ComicVersionPageMapping.fromJson(<String, Object?>{
      'predecessorChapterId': 'old-chapter',
      'successorChapterId': 'new-chapter',
      'predecessorPageCount': 370,
      'successorPageCount': 371,
      'successorOffset': 1,
      'verifiedAt': '2026-08-11T02:00:00+08:00',
    });
    expect(mapping.verifiedAt, DateTime.utc(2026, 8, 10, 18));
    expect(
      () => ComicVersionPageMapping.fromJson(<String, Object?>{
        'predecessorChapterId': 'old-chapter',
        'successorChapterId': 'new-chapter',
        'predecessorPageCount': 370,
        'successorPageCount': 371,
        'successorOffset': 1,
        'verifiedAt': 123,
      }),
      throwsFormatException,
    );
    expect(
      () => ComicVersionPageMapping.fromJson(<String, Object?>{
        'predecessorChapterId': 'old-chapter',
        'successorChapterId': 'new-chapter',
        'predecessorPageCount': 370,
        'successorPageCount': 371,
        'successorOffset': 1,
        'verifiedAt': 'not-a-date',
      }),
      throwsFormatException,
    );
  });

  test(
    'version mapping preserves verified affine intervals and legacy fallback',
    () {
      final legacy = ComicVersionPageMapping.fromJson(<String, Object?>{
        'predecessorChapterId': 'old',
        'successorChapterId': 'new',
        'predecessorPageCount': 4,
        'successorPageCount': 5,
        'successorOffset': 1,
        'verifiedPredecessorPageIndexes': <int>[0, 3],
      });
      expect(legacy.intervalProbeVersion, 0);
      expect(
        legacy.effectiveVerifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 4, 1)],
      );

      final mapping = ComicVersionPageMapping.fromJson(<String, Object?>{
        'predecessorChapterId': 'old',
        'successorChapterId': 'new',
        'predecessorPageCount': 6,
        'successorPageCount': 7,
        'successorOffset': 0,
        'intervalProbeVersion': 1,
        'verifiedIntervals': <Object?>[
          <String, Object?>{
            'predecessorStart': 0,
            'predecessorEndExclusive': 2,
            'successorOffset': 0,
          },
          <String, Object?>{
            'predecessorStart': 2,
            'predecessorEndExclusive': 3,
            'successorOffset': 0,
          },
          <String, Object?>{
            'predecessorStart': 4,
            'predecessorEndExclusive': 6,
            'successorOffset': 1,
          },
        ],
      });
      expect(
        mapping.effectiveVerifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 3, 0), (4, 6, 1)],
      );
      expect(mapping.uniqueVerifiedSuccessorIndexForPredecessor(2), 2);
      expect(mapping.uniqueVerifiedSuccessorIndexForPredecessor(3), isNull);
      expect(mapping.uniqueVerifiedSuccessorIndexForPredecessor(4), 5);
      expect(mapping.intervalProbeVersion, 1);
      final roundTrip = ComicVersionPageMapping.fromJson(mapping.toJson());
      expect(roundTrip.verifiedIntervals, hasLength(2));
      expect(roundTrip.intervalProbeVersion, 1);
      expect(roundTrip.uniqueVerifiedPredecessorIndexForSuccessor(6), 5);
    },
  );

  test(
    'verified affine evidence expands, splits, and changes local offset',
    () {
      const mapping = ComicVersionPageMapping(
        predecessorChapterId: 'old',
        successorChapterId: 'new',
        predecessorPageCount: 6,
        successorPageCount: 7,
        successorOffset: 1,
        verifiedIntervals: <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 4,
            successorOffset: 1,
          ),
        ],
      );

      final split = mapping.recordVerifiedPageMismatch(
        predecessorIndex: 2,
        successorIndex: 3,
        observedAt: DateTime.utc(2026, 9, 9),
      );
      expect(
        split.effectiveVerifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 2, 1), (3, 4, 1)],
      );

      final restored = split.recordVerifiedPageMatch(
        predecessorIndex: 2,
        successorIndex: 3,
      );
      expect(
        restored.effectiveVerifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 4, 1)],
      );

      final changedOffset = restored.recordVerifiedPageMatch(
        predecessorIndex: 2,
        successorIndex: 2,
      );
      expect(
        changedOffset.effectiveVerifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 2, 1), (2, 3, 0), (3, 4, 1)],
      );
    },
  );

  test('memory imported library stores comic version predecessors', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const relation = ComicVersionRelation(
      sourceId: 'venera:ehentai',
      predecessorComicId: 'old-comic',
      successorComicId: 'new-comic',
      predecessorTitle: '旧版标题',
      pageMappings: <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'old-chapter',
          successorChapterId: 'new-chapter',
          predecessorPageCount: 370,
          successorPageCount: 371,
          successorOffset: 1,
        ),
      ],
    );

    await store.saveComicVersionRelation(relation);

    final predecessors = await store.listComicVersionPredecessors(
      relation.sourceId,
      relation.successorComicId,
    );
    expect(predecessors, hasLength(1));
    expect(predecessors.single.sourceId, relation.sourceId);
    expect(predecessors.single.predecessorComicId, relation.predecessorComicId);
    expect(predecessors.single.successorComicId, relation.successorComicId);
    expect(predecessors.single.predecessorTitle, relation.predecessorTitle);
    expect(predecessors.single.pageMappings, hasLength(1));
    expect(predecessors.single.pageMappings.single.successorOffset, 1);
    final all = await store.listAllComicVersionRelations();
    expect(all, hasLength(1));
    expect(all.single.predecessorComicId, relation.predecessorComicId);

    final successors = await store.listComicVersionSuccessors(
      relation.sourceId,
      relation.predecessorComicId,
    );
    expect(successors, hasLength(1));
    expect(successors.single.successorComicId, relation.successorComicId);
  });

  test('memory imported library stores chapters and latest progress', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);

    final chapter = _chapter(pageCount: 3);
    await store.upsertChapter(chapter);
    await store.saveProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 2,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      ),
    );
    await store.saveProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    final entry = await store.get(chapter.sourceId, chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.pageIndex, 2);
  });

  test(
    'chapter refresh preserves the same current source after insertion',
    () async {
      final store = MemoryImportedLibraryStore();
      await store.open();
      addTearDown(store.close);

      final first = ImportedChapterRecord.folder(
        directoryId: '/library/chapter',
        displayName: 'Chapter',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '2.png',
            sourceId: '/library/chapter/2.png',
            contentKindHint: ContentKindHint.png,
          ),
          ImportedPageRecord(
            displayName: '3.png',
            sourceId: '/library/chapter/3.png',
            contentKindHint: ContentKindHint.png,
          ),
        ],
      );
      await store.upsertChapter(first);
      await store.saveProgress(
        ReadingProgress(
          sourceId: first.sourceId,
          comicId: first.comicId,
          chapterId: first.chapterId,
          pageIndex: 1,
          subPageOffset: 0.5,
          readerMode: ReaderMode.continuous,
          updatedAt: DateTime.utc(2026, 7, 28),
        ),
      );

      final refreshed = ImportedChapterRecord.folder(
        directoryId: '/library/chapter',
        displayName: 'Chapter',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.png',
            sourceId: '/library/chapter/1.png',
            contentKindHint: ContentKindHint.png,
          ),
          ImportedPageRecord(
            displayName: '2.png',
            sourceId: '/library/chapter/2.png',
            contentKindHint: ContentKindHint.png,
          ),
          ImportedPageRecord(
            displayName: '3.png',
            sourceId: '/library/chapter/3.png',
            contentKindHint: ContentKindHint.png,
          ),
        ],
      );
      await store.upsertChapter(refreshed);

      final entry = await store.get(refreshed.sourceId, refreshed.chapterId);
      expect(entry?.progress?.pageIndex, 2);
      expect(entry?.progress?.subPageOffset, 0.5);
    },
  );

  test('chapter refresh clamps progress after pages are removed', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);

    final first = _chapter(pageCount: 3);
    await store.upsertChapter(first);
    await store.saveProgress(
      ReadingProgress(
        sourceId: first.sourceId,
        comicId: first.comicId,
        chapterId: first.chapterId,
        pageIndex: 2,
        subPageOffset: 0,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    final refreshed = _chapter(pageCount: 1);
    await store.upsertChapter(refreshed);
    final entry = await store.get(refreshed.sourceId, refreshed.chapterId);
    expect(entry?.progress?.pageIndex, 0);
    expect(entry?.progress?.readerMode, ReaderMode.continuous);
  });

  test(
    'memory library persists categories, comic preferences, and read state',
    () async {
      final store = MemoryImportedLibraryStore();
      await store.open();
      addTearDown(store.close);
      final now = DateTime.utc(2026, 7, 28, 8);
      final category = LibraryCategory(
        categoryId: 'favorites',
        name: '收藏夹',
        sortOrder: 0,
        createdAt: now,
      );
      await store.upsertCategory(category);
      final preference =
          ComicPreference.defaults(
            sourceId: 'source-1',
            comicId: 'comic-1',
          ).copyWith(
            liked: true,
            collected: true,
            categoryIds: const <String>{'favorites'},
            customOrder: 3,
            updatedAt: now,
          );
      await store.saveComicPreference(preference);
      final readState = ChapterReadState(
        sourceId: 'source-1',
        comicId: 'comic-1',
        chapterId: 'chapter-1',
        isRead: true,
        updatedAt: now,
      );
      await store.saveChapterReadState(readState);

      expect((await store.listCategories()).single.toJson(), category.toJson());
      expect(
        (await store.getComicPreference('source-1', 'comic-1'))?.toJson(),
        preference.toJson(),
      );
      expect(
        (await store.listChapterReadStates(
          'source-1',
          'comic-1',
        )).single.toJson(),
        readState.toJson(),
      );
      expect(
        (await store.listAllChapterReadStates()).single.toJson(),
        readState.toJson(),
      );

      await store.removeCategory('favorites');
      expect(await store.listCategories(), isEmpty);
      expect(
        (await store.getComicPreference('source-1', 'comic-1'))?.categoryIds,
        isEmpty,
      );
    },
  );

  test(
    'memory library keeps a whole comic without an imported chapter',
    () async {
      final store = MemoryImportedLibraryStore();
      await store.open();
      addTearDown(store.close);
      final manifest = _savedManifest();
      final saved = SavedComicRecord.fromManifest(
        manifest,
        savedAt: DateTime.utc(2026, 7, 28),
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      );
      final preference =
          ComicPreference.defaults(
            sourceId: manifest.comic.sourceId,
            comicId: manifest.comic.comicId,
            sourceKind: ComicSourceKind.remote,
          ).copyWith(
            inShelf: true,
            collected: true,
            updatedAt: DateTime.utc(2026, 7, 28, 2),
          );

      await store.upsertSavedComic(saved);
      await store.saveComicPreference(preference);

      expect(await store.list(), isEmpty);
      expect(
        (await store.getSavedComic(
          'fixture-source',
          'fixture-comic',
        ))?.toJson(),
        saved.toJson(),
      );
      expect(
        aggregateImportedLibrary(
          await store.list(),
          savedComics: await store.listSavedComics(),
        ).single.sourceChapters,
        hasLength(2),
      );

      await store.removeSavedComic('fixture-source', 'fixture-comic');
      expect(await store.listSavedComics(), isEmpty);
      expect(
        await store.getComicPreference('fixture-source', 'fixture-comic'),
        isNull,
      );
    },
  );

  test('remote refresh keeps progress by stable page identity', () async {
    final previous = _remoteChapter(
      urls: const <String>[
        'https://old.example/chapter/a.jpg',
        'https://old.example/chapter/b.jpg',
      ],
    );
    final refreshed = _remoteChapter(
      urls: const <String>[
        'https://new.example/chapter/a.jpg',
        'https://new.example/chapter/b.jpg',
      ],
    );
    final progress = ReadingProgress(
      sourceId: previous.sourceId,
      comicId: previous.comicId,
      chapterId: previous.chapterId,
      pageIndex: 1,
      subPageOffset: 0.4,
      readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 7, 28, 10),
    );

    final reconciled = reconcileImportedProgress(
      previousChapter: previous,
      refreshedChapter: refreshed,
      progress: progress,
    );

    expect(reconciled?.pageIndex, 1);
    expect(reconciled?.subPageOffset, 0.4);
  });

  test('legacy preference and read-state JSON accept a source fallback', () {
    final preference = ComicPreference.fromJson(<String, Object?>{
      'comicId': 'comic-legacy',
      'sourceKind': ComicSourceKind.remote.name,
      'inShelf': true,
      'liked': false,
      'collected': true,
      'categoryIds': <Object?>[],
      'customOrder': 4,
      'updatedAt': DateTime.utc(2026, 7, 28).toIso8601String(),
    }, fallbackSourceId: 'legacy-source');
    final readState = ChapterReadState.fromJson(<String, Object?>{
      'comicId': 'comic-legacy',
      'chapterId': 'chapter-legacy',
      'isRead': true,
      'updatedAt': DateTime.utc(2026, 7, 28).toIso8601String(),
    }, fallbackSourceId: 'legacy-source');

    expect(preference.identity, 'legacy-source\u0000comic-legacy');
    expect(readState.identity, 'legacy-source\u0000chapter-legacy');
  });

  test('memory library persists comic source preferences', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    final preference = ComicSourcePreference(
      sourceId: 'mangadex',
      enabled: false,
      sortOrder: 3,
      updatedAt: DateTime.utc(2026, 7, 28),
    );

    await store.saveSourcePreference(preference);

    expect(await store.listSourcePreferences(), <ComicSourcePreference>[
      preference,
    ]);
    await store.close();
  });

  test('memory migration diagnostics retain acknowledged records', () async {
    final issue = LibraryMigrationIssue(
      issueId: 7,
      schemaFrom: 4,
      entityKind: 'comic_preference',
      legacyKey: 'legacy-comic',
      resolvedSourceId: 'source-a',
      details: const <String, Object?>{'reason': 'ambiguous owner'},
      createdAt: DateTime.utc(2026, 7, 29),
    );
    final store = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[issue],
    );
    await store.open();
    addTearDown(store.close);

    expect((await store.listMigrationIssues()).single.issueId, 7);
    final acknowledgedAt = DateTime.utc(2026, 7, 29, 1);
    await store.acknowledgeMigrationIssues(const <int>[
      7,
    ], acknowledgedAt: acknowledgedAt);

    expect(await store.listMigrationIssues(), isEmpty);
    final retained = await store.listMigrationIssues(includeAcknowledged: true);
    expect(retained.single.acknowledgedAt, acknowledgedAt);
    expect(retained.single.details, issue.details);
  });
}

ImportedChapterRecord _chapter({required int pageCount}) {
  return ImportedChapterRecord.folder(
    directoryId: '/library/chapter',
    displayName: 'Chapter',
    importedAt: DateTime.utc(2026, 7, 28),
    pages: <ImportedPageRecord>[
      for (var index = 0; index < pageCount; index++)
        ImportedPageRecord(
          displayName: '$index.png',
          sourceId: '/library/chapter/$index.png',
          contentKindHint: ContentKindHint.png,
          mediaFormat: 'png',
          byteLength: 32 + index,
        ),
    ],
  );
}

ImportedChapterRecord _remoteChapter({required List<String> urls}) {
  return ImportedChapterRecord(
    directoryId: 'mangadex:comic-1',
    displayName: 'Chapter 1',
    sourceId: 'mangadex',
    comicId: 'comic-1',
    comicTitle: 'Remote comic',
    chapterId: 'remote-chapter-1',
    sourceRevision: urls.first,
    pages: <ImportedPageRecord>[
      for (var index = 0; index < urls.length; index++)
        ImportedPageRecord(
          displayName: '${index + 1}.jpg',
          sourceId: urls[index],
          pageId: 'remote-page-${index + 1}',
          contentKindHint: ContentKindHint.jpeg,
        ),
    ],
  );
}

ComicManifest _savedManifest() => ComicManifest(
  comic: Comic(
    comicId: 'fixture-comic',
    sourceId: 'fixture-source',
    title: '整部漫画',
    authors: const <String>['作者'],
    readingDirection: ReadingDirection.ltr,
  ),
  chapters: const <Chapter>[
    Chapter(
      chapterId: 'fixture-chapter-1',
      comicId: 'fixture-comic',
      title: '第 1 话',
      sequence: 1,
      pageCount: 1,
      sourceRevision: 'r1',
    ),
    Chapter(
      chapterId: 'fixture-chapter-2',
      comicId: 'fixture-comic',
      title: '第 2 话',
      sequence: 2,
      pageCount: 1,
      sourceRevision: 'r2',
    ),
  ],
);
