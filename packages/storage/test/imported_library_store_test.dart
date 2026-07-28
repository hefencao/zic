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
}
