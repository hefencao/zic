import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('comic aggregate groups chapters and selects latest reading progress', () {
    final first = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-1',
        title: '第 1 话',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 26),
      ),
      progress: ReadingProgress(
        comicId: 'comic-1',
        chapterId: 'chapter-1',
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 27),
      ),
    );
    final second = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-2',
        title: '第 2 话',
        sequence: 2,
        importedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    final comic = LibraryComic.fromEntries(<ImportedLibraryEntry>[second, first]);

    expect(comic.comicId, 'comic-1');
    expect(comic.title, '聚合漫画');
    expect(
      comic.chapters.map((entry) => entry.chapter.chapterId),
      <String>['chapter-1', 'chapter-2'],
    );
    expect(comic.totalPages, 4);
    expect(comic.latestChapter.chapter.chapterId, 'chapter-2');
    expect(comic.resumeChapter.chapter.chapterId, 'chapter-1');
  });

  test('library aggregation emits one comic per comic identity', () {
    final comics = aggregateImportedLibrary(<ImportedLibraryEntry>[
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'chapter-2',
          title: '第 2 话',
          sequence: 2,
          importedAt: DateTime.utc(2026, 7, 28),
        ),
      ),
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'chapter-1',
          title: '第 1 话',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 27),
        ),
      ),
      ImportedLibraryEntry(
        chapter: _chapter(
          comicId: 'comic-2',
          chapterId: 'chapter-other',
          title: '单章',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 26),
        ),
      ),
    ]);

    expect(comics, hasLength(2));
    expect(comics.first.comicId, 'comic-1');
    expect(comics.first.chapters, hasLength(2));
    expect(comics.last.comicId, 'comic-2');
  });

  test('chapter JSON remains compatible while persisting aggregate metadata', () {
    final chapter = _chapter(
      chapterId: 'chapter-7',
      title: '第 7 话',
      sequence: 7,
      importedAt: DateTime.utc(2026, 7, 28),
    );

    final restored = ImportedChapterRecord.fromJson(chapter.toJson());

    expect(restored.comicTitle, '聚合漫画');
    expect(restored.sequence, 7);
    expect(restored.toJson(), chapter.toJson());

    final legacy = Map<String, Object?>.from(chapter.toJson())
      ..remove('comicTitle')
      ..remove('sequence');
    final legacyRestored = ImportedChapterRecord.fromJson(legacy);
    expect(legacyRestored.comicTitle, chapter.displayName);
    expect(legacyRestored.sequence, 0);
  });

  test('chapter JSON rejects malformed aggregate metadata', () {
    final json = _chapter(
      chapterId: 'chapter-3',
      title: '第 3 话',
      sequence: 3,
      importedAt: DateTime.utc(2026, 7, 28),
    ).toJson();

    expect(
      () => ImportedChapterRecord.fromJson(
        Map<String, Object?>.from(json)..['comicTitle'] = '',
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedChapterRecord.fromJson(
        Map<String, Object?>.from(json)..['sequence'] = '3',
      ),
      throwsFormatException,
    );
  });

  test('chapter copy preserves aggregate identity while replacing page data', () {
    final chapter = _chapter(
      chapterId: 'chapter-4',
      title: '第 4 话',
      sequence: 4,
      importedAt: DateTime.utc(2026, 7, 28),
    );
    final refreshed = chapter.copyWith(
      sourceRevision: 'revision-refreshed',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'new.png',
          sourceId: '/library/chapter-4/new.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

    expect(refreshed.comicId, chapter.comicId);
    expect(refreshed.comicTitle, chapter.comicTitle);
    expect(refreshed.chapterId, chapter.chapterId);
    expect(refreshed.sequence, chapter.sequence);
    expect(refreshed.sourceRevision, 'revision-refreshed');
    expect(refreshed.pages.single.displayName, 'new.png');
  });
}

ImportedChapterRecord _chapter({
  String comicId = 'comic-1',
  required String chapterId,
  required String title,
  required int sequence,
  required DateTime importedAt,
}) {
  return ImportedChapterRecord(
    directoryId: '/library/$chapterId',
    displayName: title,
    sourceId: 'local-folder',
    comicId: comicId,
    comicTitle: comicId == 'comic-1' ? '聚合漫画' : '其他漫画',
    chapterId: chapterId,
    sourceRevision: 'revision-$chapterId',
    sequence: sequence,
    importedAt: importedAt,
    pages: <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '001.png',
        sourceId: '/library/$chapterId/001.png',
        contentKindHint: ContentKindHint.png,
      ),
      ImportedPageRecord(
        displayName: '002.png',
        sourceId: '/library/$chapterId/002.png',
        contentKindHint: ContentKindHint.png,
      ),
    ],
  );
}
