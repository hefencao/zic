import 'dart:async';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

SavedComicRecord _saved({
  String source = 'source', String comic = 'comic', DateTime? updatedAt,
  Iterable<SavedChapterRecord>? chapters,
}) => SavedComicRecord(
      sourceId: source, comicId: comic, canonicalComicId: 'canonical:$comic',
      title: '目录 📚 $source/$comic', authors: const ['作者'],
      tags: const ['中文', 'tag'], description: '完整漫画元数据',
      coverSourceId: 'https://example.test/cover%2F1?token=a%2Bb#cover',
      readingDirection: ReadingDirection.rtl,
      chapters: chapters ?? [
        SavedChapterRecord(chapterId: 'opaque:2', title: '二', sequence: 2,
          pageCount: 17, sourceRevision: 'r2', publishedAt: DateTime.utc(2026, 1)),
        SavedChapterRecord(chapterId: 'opaque:1', title: '一', sequence: 1,
          pageCount: 9, sourceRevision: 'r1', updatedAt: DateTime.utc(2026, 2)),
      ],
      savedAt: DateTime.utc(2026, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 2),
      sourceUpdateAt: DateTime.utc(2026, 1, 30),
      unseenChapterIds: const ['opaque:2'],
    );

void main() {
  for (final persistent in [false, true]) {
    test('saved list preserves full models and SQL order persistent=$persistent',
        () async {
      final dir = await Directory.systemTemp.createTemp('saved-read-order-');
      addTearDown(() => dir.delete(recursive: true));
      final store = persistent
          ? SqliteImportedLibraryStore('${dir.path}/library.sqlite')
          : SqliteImportedLibraryStore.memory();
      await store.open();
      addTearDown(store.close);
      final rows = [
        _saved(source: 'z', comic: 'same'),
        _saved(source: 'a', comic: 'b'),
        _saved(source: 'a', comic: 'a'),
        _saved(comic: 'older', updatedAt: DateTime.utc(2026, 1)),
        _saved(comic: 'newer', updatedAt: DateTime.utc(2026, 3)),
      ];
      for (final row in rows) {
        await store.upsertSavedComic(row);
      }
      final expected = [rows[4], rows[2], rows[1], rows[0], rows[3]];

      expect((await store.listSavedComics()).map((r) => r.toJson()).toList(),
          expected.map((r) => r.toJson()).toList());
      expect((await store.readLibraryBackupSnapshot()).savedComics
          .map((r) => r.toJson()).toList(), expected.map((r) => r.toJson()).toList());
      expect((await store.getSavedComic('a', 'a'))!.toJson(), rows[2].toJson());
      expect(await store.getSavedComic('missing', 'a'), isNull);
      expect(await store.list(), isEmpty,
          reason: 'saved catalogs do not import chapter manifests');
    });
  }

  test('one large persistent saved row leaves the caller free and drains on close',
      () async {
    final dir = await Directory.systemTemp.createTemp('saved-read-large-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteImportedLibraryStore('${dir.path}/library.sqlite');
    await store.open();
    addTearDown(store.close);
    final original = _saved(chapters: List.generate(3000, (i) =>
      SavedChapterRecord(chapterId: 'opaque:$i:${'x' * 256}',
        title: '章节 $i ${'标题' * 64}', sequence: i, pageCount: i + 1,
        sourceRevision: 'r$i', publishedAt: DateTime.utc(2026, 1))));
    await store.upsertSavedComic(original);
    var completed = false;
    final event = Completer<void>();
    Timer.run(() {
      try {
        expect(completed, isFalse,
            reason: 'even one large comic must not decode on the caller');
        event.complete();
      } on Object catch (error, stack) {
        event.completeError(error, stack);
      }
    });
    final read = store.listSavedComics().then((rows) {
      expect(rows.single.toJson(), original.toJson());
      completed = true;
    });
    final closing = store.close();
    await expectLater(store.listSavedComics(), throwsStateError);
    await Future.wait<void>([read, closing, event.future]);
    expect(completed, isTrue);
    await store.open();
    expect((await store.listSavedComics()).single.toJson(), original.toJson());
  });

  test('memory saved list yields detached rows safely while closing', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final rows = List.generate(40, (i) => _saved(comic: 'comic-$i'));
    for (final row in rows) {
      await store.upsertSavedComic(row);
    }
    rows.sort((a, b) => a.comicId.compareTo(b.comicId));
    var eventTurn = false;
    Timer.run(() => eventTurn = true);
    final read = store.listSavedComics();
    final closing = store.close();
    final actual = await read;
    await closing;

    expect(eventTurn, isTrue);
    expect(actual.map((r) => r.toJson()).toList(),
        rows.map((r) => r.toJson()).toList());
  });

  test('persistent saved reads observe metadata writes and removals without a cache',
      () async {
    final dir = await Directory.systemTemp.createTemp('saved-read-refresh-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteImportedLibraryStore('${dir.path}/library.sqlite');
    await store.open();
    addTearDown(store.close);
    final original = _saved();
    await store.upsertSavedComic(original);
    final old = await store.listSavedComics();
    final updated = original.copyWith(title: '更新', chapters: [],
        unseenChapterIds: [], updatedAt: DateTime.utc(2026, 3));
    await store.upsertSavedComic(updated);

    expect((await store.listSavedComics()).single.toJson(), updated.toJson());
    expect(old.single.toJson(), original.toJson());
    await store.removeSavedComic(updated.sourceId, updated.comicId);
    expect(await store.listSavedComics(), isEmpty);
  });

  for (final malformed in ['[]', '{broken']) {
    test('saved worker propagates malformed JSON and retires on close: $malformed',
        () async {
      final dir = await Directory.systemTemp.createTemp('saved-read-failure-');
      addTearDown(() => dir.delete(recursive: true));
      final store = SqliteImportedLibraryStore('${dir.path}/library.sqlite');
      await store.open();
      addTearDown(store.close);
      await store.upsertSavedComic(_saved());
      final db = sql.sqlite3.open(store.path!);
      try {
        db.execute('UPDATE saved_comic SET comic_json=?', [malformed]);
      } finally {
        db.close();
      }
      final failure = expectLater(store.listSavedComics(), throwsFormatException);
      final closing = store.close();
      await Future.wait<void>([failure, closing]);
      await store.open();
      await store.upsertSavedComic(_saved());
      expect((await store.listSavedComics()).single.toJson(), _saved().toJson());
    });
  }
}
