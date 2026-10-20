import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

CacheRec _record(String comic, {String source = 'source', String revision = 'r1',
  String page = 'page', String checksum = 'abcd',
  CacheState state = CacheState.ready}) => CacheRec(
  id: DownloadId(content: ContentId(sourceId: source, comicId: comic,
    chapterId: 'chapter', pageId: page), sourceRevision: revision,
    canonicalUri: Uri.parse('https://example.test/$comic/$page')),
  state: state, path: '/export/$source/$comic/$revision/$page', bytes: 10,
  checksum: checksum, createdUs: 1, touchedUs: 2,
);

void main() {
  for (final sqlite in [false, true]) {
    test('${sqlite ? "sqlite" : "memory"} scopes and identities preserve cross-comic candidates', () async {
      final CacheIndex index = sqlite ? SqliteIndex.memory() : MemIndex();
      await index.open();
      addTearDown(index.close);
      final query = index as CacheRecordQuery;
      final old = _record('old');
      final current = _record('current', revision: 'r2', checksum: 'other');
      final stale = _record('current', revision: 'r1', checksum: 'stale');
      final partial = _record('partial', state: CacheState.partial);
      for (final record in [old, current, stale, partial,
        _record('foreign', source: 'other'), _record('unrelated', checksum: 'no')]) {
        await index.put(record);
      }
      // Warming the full-list cache must not replace indexed scope reads with
      // a filter over stale cached projections after subsequent mutations.
      await index.list();
      final scopes = [const CacheBindingScope(sourceId: 'source',
        comicId: 'current', chapterId: 'chapter', sourceRevision: 'r2')];
      expect((await query.listScopedBindings(scopes)).map((r) => r.key), [current.key]);
      expect((await query.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd', 'checksum:crc32:abcd']))
          .map((r) => r.key), [old.key]);
      expect(await query.listScopedBindings([]), isEmpty);
      expect(await query.listIdentityBindings(sourceId: 'source', identities: []), isEmpty);
      await index.put(old.copyWith(checksum: 'changed', artifactId: 'changed-object',
        path: '${old.path}-changed'));
      expect(await query.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd']), isEmpty);
      await index.put(old.copyWith(state: CacheState.partial));
      expect(await query.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd']), isEmpty);
      await index.put(old);
      await index.remove(old.key);
      expect(await query.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd']), isEmpty);
    });
  }

  test('schema20 backfill preserves authority and uses indexed reads on reopen', () async {
    final root = await Directory.systemTemp.createTemp('cache-scope-migration-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/cache.sqlite';
    final initial = SqliteIndex(path);
    await initial.open();
    final old = _record('old');
    await initial.put(old);
    await initial.close();
    final legacy = sql.sqlite3.open(path);
    legacy.execute('DROP TABLE cache_entry_identity');
    legacy.execute('DROP INDEX cache_entry_comic_chapter');
    for (final column in ['source_id', 'comic_id', 'chapter_id']) {
      legacy.execute('ALTER TABLE cache_entry DROP COLUMN $column');
    }
    legacy.execute('PRAGMA user_version = 20');
    legacy.close();
    for (var attempt = 0; attempt < 2; attempt++) {
      final index = SqliteIndex(path);
      await index.open();
      try {
        expect((await index.listIdentityBindings(sourceId: 'source',
          identities: ['checksum:crc32:abcd'])).single.key, old.key);
        expect((await index.get(old.key))?.path, old.path);
        final db = sql.sqlite3.open(path);
        try {
          expect(db.select('PRAGMA user_version').single.values.single, 21);
          for (final statement in [
            "SELECT * FROM cache_entry WHERE source_id = 'source' AND comic_id = 'old' AND chapter_id = 'chapter' AND source_revision = 'r1'",
            "SELECT c.* FROM cache_entry_identity i JOIN cache_entry c ON c.key = i.cache_key WHERE i.source_id = 'source' AND i.identity IN ('checksum:crc32:abcd')",
          ]) {
            final plan = db.select('EXPLAIN QUERY PLAN $statement')
                .map((r) => r['detail']).join(' ');
            expect(plan, contains('SEARCH'));
            expect(plan, isNot(contains('SCAN')));
          }
          expect(db.select('SELECT count(*) AS n FROM artifact_replica').single['n'], 1);
        } finally {
          db.close();
        }
      } finally {
        await index.close();
      }
    }
  });

  test('queries chunk scopes and identity terms without losing matches', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    for (var i = 0; i < 430; i++) {
      await index.put(_record('comic-$i', checksum: 'checksum-$i'));
    }
    final scoped = await index.listScopedBindings([
      for (var i = 0; i < 430; i++) CacheBindingScope(sourceId: 'source',
        comicId: 'comic-$i', chapterId: 'chapter', sourceRevision: 'r1'),
    ]);
    final identity = await index.listIdentityBindings(sourceId: 'source', identities: [
      for (var i = 0; i < 430; i++) 'checksum:crc32:checksum-$i',
    ]);
    expect(scoped.map((r) => r.key).toSet(), identity.map((r) => r.key).toSet());
    expect(scoped, hasLength(430));
  });
}
