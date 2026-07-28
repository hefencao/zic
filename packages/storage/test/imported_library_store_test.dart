import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

void main() {
  test('sqlite imported library persists chapter, progress, and cascade delete',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);

    final chapter = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'Chapter',
      importedAt: DateTime.utc(2026, 7, 28),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/001',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          byteLength: 140,
          animatedHint: true,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'content://provider/document/002',
          contentKindHint: ContentKindHint.png,
          mediaFormat: 'png',
          byteLength: 68,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final progress = ReadingProgress(
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 1,
      subPageOffset: 0,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 7, 28, 2),
    );
    await store.saveProgress(progress);

    final entry = await store.get(chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.toJson(), progress.toJson());
    expect((await store.list()).single.chapter.chapterId, chapter.chapterId);

    await store.removeChapter(chapter.chapterId);
    expect(await store.get(chapter.chapterId), isNull);
  });


  test('sqlite refresh follows the same page source after insertion', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);

    final first = ImportedChapterRecord.folder(
      directoryId: '/library/refresh',
      displayName: 'Refresh',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/library/refresh/2.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '3.png',
          sourceId: '/library/refresh/3.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(first);
    await store.saveProgress(
      ReadingProgress(
        comicId: first.comicId,
        chapterId: first.chapterId,
        pageIndex: 1,
        subPageOffset: 0.25,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 7, 28, 4),
      ),
    );

    final refreshed = ImportedChapterRecord.folder(
      directoryId: '/library/refresh',
      displayName: 'Refresh',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/library/refresh/1.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/library/refresh/2.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '3.png',
          sourceId: '/library/refresh/3.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(refreshed);

    final entry = await store.get(refreshed.chapterId);
    expect(entry?.progress?.pageIndex, 2);
    expect(entry?.progress?.subPageOffset, 0.25);
  });

  test('sqlite imported library survives close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-imported-library-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/catalog/library.sqlite3';
    final chapter = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/persisted',
      displayName: 'Persisted chapter',
      importedAt: DateTime.utc(2026, 7, 28),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/persisted-001',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          byteLength: 140,
          animatedHint: true,
        ),
      ],
    );
    final progress = ReadingProgress(
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 0,
      subPageOffset: 0.25,
      readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 7, 28, 3),
    );

    final first = SqliteImportedLibraryStore(path);
    await first.open();
    await first.upsertChapter(chapter);
    await first.saveProgress(progress);
    await first.close();

    final reopened = SqliteImportedLibraryStore(path);
    await reopened.open();
    addTearDown(reopened.close);
    final entry = await reopened.get(chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.toJson(), progress.toJson());
  });

  test('sqlite library persists shelf preferences and chapter read state',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '/library/preferences',
      displayName: 'Preferences',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/library/preferences/1.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final now = DateTime.utc(2026, 7, 28, 9);
    final category = LibraryCategory(
      categoryId: 'reading',
      name: '阅读中',
      sortOrder: 1,
      createdAt: now,
    );
    await store.upsertCategory(category);
    final preference = ComicPreference.defaults(comicId: chapter.comicId)
        .copyWith(
      liked: true,
      categoryIds: const <String>{'reading'},
      customOrder: 7,
      updatedAt: now,
    );
    await store.saveComicPreference(preference);
    final state = ChapterReadState(
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      isRead: true,
      updatedAt: now,
    );
    await store.saveChapterReadState(state);

    expect((await store.listCategories()).single.toJson(), category.toJson());
    expect(
      (await store.getComicPreference(chapter.comicId))?.toJson(),
      preference.toJson(),
    );
    expect(
      (await store.listChapterReadStates(chapter.comicId)).single.toJson(),
      state.toJson(),
    );

    await store.removeChapter(chapter.chapterId);
    expect(await store.listChapterReadStates(chapter.comicId), isEmpty);
    expect(await store.getComicPreference(chapter.comicId), isNull);
  });

  test('sqlite migrates schema 2 source preferences', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-source-preference-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA user_version = 2');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    await store.saveSourcePreference(
      ComicSourcePreference(
        sourceId: 'mangadex',
        enabled: true,
        sortOrder: 0,
        updatedAt: DateTime.utc(2026, 7, 28, 11),
      ),
    );

    expect((await store.listSourcePreferences()).single.sourceId, 'mangadex');
  });

  test('sqlite persists comic source enablement and order', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final first = ComicSourcePreference(
      sourceId: 'mangadex',
      enabled: true,
      sortOrder: 1,
      updatedAt: DateTime.utc(2026, 7, 28, 11),
    );
    final second = ComicSourcePreference(
      sourceId: 'fixture',
      enabled: false,
      sortOrder: 0,
      updatedAt: DateTime.utc(2026, 7, 28, 12),
    );

    await store.saveSourcePreference(first);
    await store.saveSourcePreference(second);

    final values = await store.listSourcePreferences();
    expect(values.map((item) => item.sourceId), <String>['fixture', 'mangadex']);
    expect(values.first.enabled, isFalse);
    expect(values.last.toJson(), first.toJson());
  });


  test('sqlite persists a whole comic without importing a chapter', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final saved = _savedComic();
    final preference = ComicPreference.defaults(
      comicId: saved.comicId,
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      collected: true,
      updatedAt: DateTime.utc(2026, 7, 28, 12),
    );

    await store.upsertSavedComic(saved);
    await store.saveComicPreference(preference);

    expect(await store.list(), isEmpty);
    expect(
      (await store.getSavedComic(saved.sourceId, saved.comicId))?.toJson(),
      saved.toJson(),
    );
    expect((await store.listSavedComics()).single.chapters, hasLength(2));

    await store.removeSavedComic(saved.sourceId, saved.comicId);
    expect(await store.listSavedComics(), isEmpty);
    expect(await store.getComicPreference(saved.comicId), isNull);
  });

  test('sqlite migrates schema 3 to saved comic schema 4', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-saved-comic-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA user_version = 3');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final saved = _savedComic();
    await store.upsertSavedComic(saved);

    expect(
      (await store.getSavedComic(saved.sourceId, saved.comicId))?.toJson(),
      saved.toJson(),
    );
    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 4);
  });

  test('sqlite keeps comic preference until the last grouped chapter is removed',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final first = _groupedChapter('chapter-1', 1);
    final second = _groupedChapter('chapter-2', 2);
    await store.upsertChapter(first);
    await store.upsertChapter(second);
    final preference = ComicPreference.defaults(comicId: first.comicId).copyWith(
      liked: true,
      updatedAt: DateTime.utc(2026, 7, 28, 10),
    );
    await store.saveComicPreference(preference);

    expect(aggregateImportedLibrary(await store.list()).single.chapters,
        hasLength(2));

    await store.removeChapter(first.chapterId);
    expect(await store.getComicPreference(first.comicId), isNotNull);
    expect(aggregateImportedLibrary(await store.list()).single.chapters,
        hasLength(1));

    await store.removeChapter(second.chapterId);
    expect(await store.getComicPreference(first.comicId), isNull);
  });
}

ImportedChapterRecord _groupedChapter(String chapterId, int sequence) {
  return ImportedChapterRecord(
    directoryId: '/library/$chapterId',
    displayName: '第 $sequence 话',
    sourceId: 'local-folder',
    comicId: 'comic-grouped',
    comicTitle: '聚合漫画',
    chapterId: chapterId,
    sourceRevision: 'revision-$chapterId',
    sequence: sequence,
    importedAt: DateTime.utc(2026, 7, 28, sequence),
    pages: <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '$chapterId.png',
        sourceId: '/library/$chapterId.png',
        contentKindHint: ContentKindHint.png,
      ),
    ],
  );
}


SavedComicRecord _savedComic() => SavedComicRecord(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      title: '整部漫画',
      authors: const <String>['作者'],
      description: '简介',
      coverSourceId: 'https://example.invalid/cover.png',
      readingDirection: ReadingDirection.ltr,
      chapters: const <SavedChapterRecord>[
        SavedChapterRecord(
          chapterId: 'fixture-chapter-1',
          title: '第 1 话',
          sequence: 1,
          pageCount: 1,
          sourceRevision: 'r1',
        ),
        SavedChapterRecord(
          chapterId: 'fixture-chapter-2',
          title: '第 2 话',
          sequence: 2,
          pageCount: 1,
          sourceRevision: 'r2',
        ),
      ],
      savedAt: DateTime.utc(2026, 7, 28),
      updatedAt: DateTime.utc(2026, 7, 28, 1),
    );
