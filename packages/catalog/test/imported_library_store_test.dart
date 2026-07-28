import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('memory imported library stores chapters and latest progress', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);

    final chapter = _chapter(pageCount: 3);
    await store.upsertChapter(chapter);
    await store.saveProgress(
      ReadingProgress(
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
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    final entry = await store.get(chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.pageIndex, 2);
  });


  test('chapter refresh preserves the same current source after insertion', () async {
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

    final entry = await store.get(refreshed.chapterId);
    expect(entry?.progress?.pageIndex, 2);
    expect(entry?.progress?.subPageOffset, 0.5);
  });

  test('chapter refresh clamps progress after pages are removed', () async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);

    final first = _chapter(pageCount: 3);
    await store.upsertChapter(first);
    await store.saveProgress(
      ReadingProgress(
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
    final entry = await store.get(refreshed.chapterId);
    expect(entry?.progress?.pageIndex, 0);
    expect(entry?.progress?.readerMode, ReaderMode.continuous);
  });

  test('memory library persists categories, comic preferences, and read state',
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
    final preference = ComicPreference.defaults(comicId: 'comic-1').copyWith(
      liked: true,
      collected: true,
      categoryIds: const <String>{'favorites'},
      customOrder: 3,
      updatedAt: now,
    );
    await store.saveComicPreference(preference);
    final readState = ChapterReadState(
      comicId: 'comic-1',
      chapterId: 'chapter-1',
      isRead: true,
      updatedAt: now,
    );
    await store.saveChapterReadState(readState);

    expect((await store.listCategories()).single.toJson(), category.toJson());
    expect(
      (await store.getComicPreference('comic-1'))?.toJson(),
      preference.toJson(),
    );
    expect(
      (await store.listChapterReadStates('comic-1')).single.toJson(),
      readState.toJson(),
    );

    await store.removeCategory('favorites');
    expect(await store.listCategories(), isEmpty);
    expect(
      (await store.getComicPreference('comic-1'))?.categoryIds,
      isEmpty,
    );
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
