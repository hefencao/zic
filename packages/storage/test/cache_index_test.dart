import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  runCacheSchemaV2Tests();

  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/page.webp'),
  );

  for (final fixture in <String, CacheIndex Function()>{
    'memory': MemIndex.new,
    'sqlite': SqliteIndex.memory,
  }.entries) {
    test('${fixture.key} index upserts and totals records', () async {
      final index = fixture.value();
      await index.open();
      addTearDown(index.close);

      final partial = CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/tmp/page.part',
        bytes: 10,
        checksum: 'a',
        createdUs: 1,
        touchedUs: 2,
      );
      await index.put(partial);
      expect((await index.get(id.key))?.state, CacheState.partial);
      expect(await index.totalBytes(), 10);

      await index.put(
        partial.copyWith(
          state: CacheState.ready,
          path: '/tmp/page.bin',
          bytes: 20,
          checksum: 'b',
          touchedUs: 3,
        ),
      );
      expect(await index.list(state: CacheState.partial), isEmpty);
      expect(await index.totalBytes(state: CacheState.ready), 20);

      await index.remove(id.key);
      expect(await index.get(id.key), isNull);
    });
  }
}
void runCacheSchemaV2Tests() {
  test('v1 cache databases migrate to v2 and keep records readable', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v2_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath =
        '${temp.path}${Platform.pathSeparator}cache.sqlite';

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('PRAGMA user_version = 1');
    legacy.execute('''
      CREATE TABLE cache_entry (
        key TEXT NOT NULL PRIMARY KEY,
        download_json TEXT NOT NULL,
        state TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        created_us INTEGER NOT NULL,
        touched_us INTEGER NOT NULL
      )
    ''');
    final id = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'legacy',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/legacy.webp'),
    );
    legacy.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.key,
        jsonEncode(id.toJson()),
        'ready',
        '${temp.path}/final/legacy.bin',
        123,
        'checksum',
        1,
        2,
      ],
    );
    legacy.dispose();

    final index = SqliteIndex(dbPath);
    await index.open();
    addTearDown(index.close);
    final record = await index.get(id.key);
    expect(record, isNotNull);
    expect(record!.pinned, isFalse);

    final pinnedId = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'pinned',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/pinned.webp'),
    );
    await index.put(
      CacheRec(
        id: pinnedId,
        state: CacheState.ready,
        path: '${temp.path}/final/pinned.bin',
        bytes: 10,
        checksum: 'c',
        createdUs: 3,
        touchedUs: 4,
        pinned: true,
      ),
    );
    expect((await index.get(pinnedId.key))!.pinned, isTrue);
    expect(await index.totalBytes(), 133);
  });
}
