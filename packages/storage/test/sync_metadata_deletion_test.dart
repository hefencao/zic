import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('sync deletion flushes newer checkpoints and preserves chapter/files after reopen', () async {
    final directory = await Directory.systemTemp.createTemp('zic-sync-store-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/page.png');
    await file.writeAsBytes([1, 2, 3]);
    final store = SqliteImportedLibraryStore('${directory.path}/library.sqlite');
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(directoryId: directory.path,
      displayName: 'Local', pages: [ImportedPageRecord(displayName: 'page.png',
        sourceId: file.path, contentKindHint: ContentKindHint.png)]);
    await store.upsertChapter(chapter);
    final old = DateTime.utc(2026);
    final newer = DateTime.utc(2026, 2);
    store.enqueueProgress(ReadingProgress(sourceId: chapter.sourceId,
      comicId: chapter.comicId, chapterId: chapter.chapterId,
      pageIndex: 0, subPageOffset: .6, readerMode: ReaderMode.paged, updatedAt: newer));
    await store.removeSyncedMetadata(LibrarySyncMetadataKind.progress,
      chapter.sourceId, chapter.chapterId, notAfter: old);
    expect((await store.get(chapter.sourceId, chapter.chapterId))!.progress!.subPageOffset, .6);
    await store.saveComicPreference(ComicPreference.defaults(sourceId: chapter.sourceId,
      comicId: chapter.comicId).copyWith(updatedAt: newer));
    await store.saveChapterReadState(ChapterReadState(sourceId: chapter.sourceId,
      comicId: chapter.comicId, chapterId: chapter.chapterId, isRead: true, updatedAt: newer));
    for (final kind in LibrarySyncMetadataKind.values) {
      await store.removeSyncedMetadata(kind, chapter.sourceId,
        kind == LibrarySyncMetadataKind.preference ? chapter.comicId : chapter.chapterId,
        notAfter: old);
    }
    expect(await store.getComicPreference(chapter.sourceId, chapter.comicId), isNotNull);
    expect(await store.listChapterReadStates(chapter.sourceId, chapter.comicId), hasLength(1));
    for (final kind in LibrarySyncMetadataKind.values) {
      await store.removeSyncedMetadata(kind, chapter.sourceId,
        kind == LibrarySyncMetadataKind.preference ? chapter.comicId : chapter.chapterId,
        notAfter: newer);
    }
    await store.close();
    await store.open();
    expect((await store.get(chapter.sourceId, chapter.chapterId))!.progress, isNull);
    expect(await store.getComicPreference(chapter.sourceId, chapter.comicId), isNull);
    expect(await store.listChapterReadStates(chapter.sourceId, chapter.comicId), isEmpty);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test('legacy categories retain their clock and real edits persist a new clock', () async {
    final created = DateTime.utc(2025);
    final legacy = LibraryCategory.fromJson({'categoryId': 'legacy', 'name': 'Old',
      'sortOrder': 0, 'createdAt': created.toIso8601String()});
    expect(legacy.updatedAt, created);
    expect(legacy.copyWith().toJson(), legacy.toJson());
    final renamed = legacy.copyWith(name: 'New');
    expect(renamed.updatedAt.isAfter(created), isTrue);
    final store = SqliteImportedLibraryStore(null);
    await store.open();
    addTearDown(store.close);
    await store.upsertCategory(renamed);
    expect((await store.listCategories()).single.toJson(), renamed.toJson());
  });

  test('lazy sync deletion materializes the existing library before applying its guard', () async {
    final directory = await Directory.systemTemp.createTemp('zic-lazy-sync-');
    addTearDown(() => directory.delete(recursive: true));
    final durable = SqliteImportedLibraryStore('${directory.path}/imported_library.sqlite3');
    await durable.open();
    final time = DateTime.utc(2026);
    await durable.saveComicPreference(ComicPreference.defaults(sourceId: 'remote',
      comicId: 'book').copyWith(liked: true, updatedAt: time));
    await durable.close();
    final lazy = LazyImportedLibraryStore(rootProvider: () async => directory.path);
    await lazy.open();
    addTearDown(lazy.close);
    expect(lazy.isDurable, isFalse);
    await lazy.removeSyncedMetadata(LibrarySyncMetadataKind.preference,
      'remote', 'book', notAfter: time.subtract(const Duration(seconds: 1)));
    expect((await lazy.getComicPreference('remote', 'book'))!.liked, isTrue);
    await lazy.removeSyncedMetadata(LibrarySyncMetadataKind.preference,
      'remote', 'book', notAfter: time);
    expect(await lazy.getComicPreference('remote', 'book'), isNull);
  });
}
