import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
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
