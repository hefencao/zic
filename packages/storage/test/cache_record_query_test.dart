import 'dart:async';
import 'dart:io';
import 'dart:math';

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

void _schema21References(sql.Database db) {
  db.execute('PRAGMA foreign_keys = ON');
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute('CREATE TABLE cache_entry_identity_v21 ('
        'source_id TEXT NOT NULL, identity TEXT NOT NULL, '
        'cache_key TEXT NOT NULL REFERENCES cache_entry(key) ON DELETE CASCADE ON UPDATE CASCADE, '
        'PRIMARY KEY(source_id, identity, cache_key)) WITHOUT ROWID');
    db.execute('INSERT INTO cache_entry_identity_v21 '
        'SELECT i.source_id, i.identity, c.key FROM cache_entry_identity i '
        'JOIN cache_entry c ON c.binding_id = i.binding_id');
    db.execute('DROP TABLE cache_entry_identity');
    db.execute('ALTER TABLE cache_entry_identity_v21 RENAME TO cache_entry_identity');
    db.execute('CREATE INDEX cache_entry_identity_key ON cache_entry_identity(cache_key)');
    db.execute('DROP INDEX cache_entry_binding_id');
    db.execute('ALTER TABLE cache_entry DROP COLUMN binding_id');
    db.execute('PRAGMA user_version = 21');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _schema20References(sql.Database db) {
  _schema21References(db);
  db.execute('DROP TABLE cache_entry_identity');
  db.execute('DROP INDEX cache_entry_comic_chapter');
  for (final column in ['source_id', 'comic_id', 'chapter_id']) {
    db.execute('ALTER TABLE cache_entry DROP COLUMN $column');
  }
  db.execute('PRAGMA user_version = 20');
}

void main() {
  test('URI candidate tokens preserve the persisted hex and path vocabulary', () {
    final previousHash = RegExp(r'[a-fA-F0-9]{32,64}');
    List<String> previous(Uri uri) {
      final segments = uri.pathSegments;
      final marker = segments.indexOf('s');
      final imageKey = marker >= 0 && marker + 1 < segments.length
          ? segments[marker + 1].trim().toLowerCase() : '';
      final hash = previousHash.firstMatch(uri.toString())?.group(0)?.toLowerCase();
      return [if (imageKey.isNotEmpty) 'eh:$imageKey', if (hash != null) 'hash:$hash'];
    }
    final random = Random(701);
    final inputs = <Uri>[
      Uri.parse('https://test/%73/%20KEY%20/other'),
      Uri.parse('https://test/s//s/second'),
      Uri.parse('https://test/%73%2Fkey'),
      Uri.parse('venera-resource:s%2Fkey'),
      Uri.parse('file:///s/KEY/other'),
      for (final length in [0, 31, 32, 33, 63, 64, 65, 130])
        for (final ending in ['', 'x', 'x${'b' * 40}'])
          Uri.parse('venera-resource:${'A' * length}$ending'),
      for (var i = 0; i < 2000; i++)
        Uri(scheme: i.isEven ? 'https' : 'venera-resource',
          host: i.isEven ? 'identity.test' : null,
          path: '${List.generate(random.nextInt(80), (_) =>
            'aB09zG/汉🙂'[random.nextInt(8)]).join()}x${'cD12' * random.nextInt(25)}',
          query: 'next=${'F' * random.nextInt(80)}'),
    ];
    for (final uri in inputs) {
      expect(cacheUriIdentityTerms(uri), previous(uri), reason: '$uri');
    }
    expect(cacheUriIdentityTerms(inputs.first), ['eh:key']);
    expect(cacheUriIdentityTerms(Uri.parse('venera-resource:${'A' * 65}')),
      ['hash:${'a' * 64}']);
  });

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
      // Reusing owner-maintained decoded records must observe later mutations.
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

  test('small warm queries do not enumerate unrelated decoded records', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final target = _record('target', checksum: 'target');
    await index.put(target);
    for (var i = 0; i < 200; i++) {
      await index.put(_record('unrelated-$i'));
    }
    final cached = {for (final record in await index.list()) record.key: record};
    for (final lookup in <Future<List<CacheRec>> Function()>[
      () => index.listScopedBindings([
        const CacheBindingScope(sourceId: 'source', comicId: 'target'),
      ]),
      () => index.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:target']),
    ]) {
      var eventTurnRan = false;
      final eventTurn = Future<void>.delayed(Duration.zero,
        () => eventTurnRan = true);
      final selected = await lookup();
      expect(selected, hasLength(1));
      expect(identical(selected.single, cached[target.key]), isTrue);
      expect(eventTurnRan, isFalse);
      await eventTurn;
    }
  });

  test('warm SQLite queries reuse decoded records and drain across a yield', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    for (var i = 0; i < 200; i++) {
      await index.put(_record('warm', page: 'page-$i'));
    }
    final cached = {for (final record in await index.list()) record.key: record};
    var eventTurnRan = false;
    Timer.run(() => eventTurnRan = true);
    final scoped = index.listScopedBindings([
      const CacheBindingScope(sourceId: 'source', comicId: 'warm'),
    ]);
    final identities = index.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:abcd']);
    final closing = index.close();
    for (final records in [await scoped, await identities]) {
      expect(records, hasLength(200));
      expect(records.every((record) => identical(record, cached[record.key])), isTrue);
    }
    expect(eventTurnRan, isTrue);
    await closing;
  });

  test('warm row reuse preserves the selected snapshot across mutations', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final records = [for (var i = 0; i < 200; i++) _record('warm', page: 'page-$i')];
    for (final record in records) await index.put(record);
    await index.list();
    final mutated = Completer<void>();
    Timer.run(() async {
      try {
        for (final record in records) await index.put(record.copyWith(checksum: 'changed'));
        mutated.complete();
      } catch (error, stack) {
        mutated.completeError(error, stack);
      }
    });
    final selected = await index.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:abcd']);
    await mutated.future;
    expect(selected, hasLength(200));
    expect(selected.every((record) => record.checksum == 'abcd'), isTrue);
    expect(await index.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:abcd']), isEmpty);
  });

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
    _schema20References(legacy);
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
          expect(db.select('PRAGMA user_version').single.values.single, 22);
          for (final statement in [
            "SELECT * FROM cache_entry WHERE source_id = 'source' AND comic_id = 'old' AND chapter_id = 'chapter' AND source_revision = 'r1'",
            "SELECT c.* FROM cache_entry_identity i JOIN cache_entry c ON c.binding_id = i.binding_id WHERE i.source_id = 'source' AND i.identity IN ('checksum:crc32:abcd')",
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

  test('schema20 migration keeps write contention off the caller and close drains it', () async {
    final root = await Directory.systemTemp.createTemp('cache-scope-contention-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/cache.sqlite';
    final initial = SqliteIndex(path);
    await initial.open();
    final record = _record('old');
    await initial.put(record);
    await initial.close();
    final legacy = sql.sqlite3.open(path);
    _schema20References(legacy);
    legacy.execute('BEGIN IMMEDIATE');
    var released = false;
    // A caller-owned event must be able to retire a competing writer while
    // the migration is waiting. A synchronous busy wait starves this release.
    final release = Timer(const Duration(milliseconds: 100), () {
      legacy.execute('ROLLBACK');
      released = true;
    });
    final index = SqliteIndex(path);
    final opening = index.open();
    final closing = index.close();
    try {
      await opening;
      await closing;
      expect(released, isTrue);
    } finally {
      release.cancel();
      if (!released) legacy.execute('ROLLBACK');
      legacy.close();
      await closing;
    }
    await index.open();
    try {
      expect((await index.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd'])).single.key, record.key);
    } finally {
      await index.close();
    }
  });

  for (final version in [20, 21]) {
    test('schema$version reference migration rolls back and preserves all authority bytes', () async {
      final root = await Directory.systemTemp.createTemp('cache-reference-migration-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/cache.sqlite';
      final ready = _record('ready');
      final partial = _record('partial', source: 'other', state: CacheState.partial);
      final initial = SqliteIndex(path);
      await initial.open();
      await initial.put(ready);
      await initial.put(partial);
      await initial.close();
      final legacy = sql.sqlite3.open(path);
      if (version == 20) {
        _schema20References(legacy);
      } else {
        _schema21References(legacy);
      }
      // Neither upgrade may repair or rewrite unrelated historical payloads.
      legacy.execute('UPDATE cache_entry SET download_json = ? WHERE key = ?',
        ['malformed historical JSON', partial.key]);
      final columns = legacy.select('PRAGMA table_info(cache_entry)')
          .map((row) => row['name']! as String).join(',');
      List<List<Object?>> rows(sql.Database db, String table, [String fields = '*']) =>
          db.select('SELECT $fields FROM $table ORDER BY 1')
              .map((row) => row.values.toList()).toList();
      final before = {for (final table in ['cache_entry', 'artifact_object', 'artifact_replica'])
        table: rows(legacy, table)};
      legacy.execute("CREATE TRIGGER reject_reference_migration BEFORE UPDATE ON cache_entry "
          "BEGIN SELECT RAISE(ABORT, 'injected reference failure'); END");
      legacy.close();
      final failed = SqliteIndex(path);
      try {
        await expectLater(failed.open(), throwsA(isA<sql.SqliteException>()));
      } finally {
        await failed.close();
      }
      final rolledBack = sql.sqlite3.open(path);
      expect(rolledBack.select('PRAGMA user_version').single.values.single, version);
      expect(rolledBack.select('PRAGMA table_info(cache_entry)')
          .any((row) => row['name'] == 'binding_id'), isFalse);
      expect(rows(rolledBack, 'cache_entry'), before['cache_entry']);
      if (version == 21) {
        expect(rolledBack.select('SELECT cache_key FROM cache_entry_identity').single['cache_key'], ready.key);
      } else {
        expect(rolledBack.select("SELECT name FROM sqlite_master WHERE name = 'cache_entry_identity'"), isEmpty);
      }
      rolledBack.execute('DROP TRIGGER reject_reference_migration');
      rolledBack.close();
      for (var attempt = 0; attempt < 2; attempt++) {
        final index = SqliteIndex(path);
        await index.open();
        try {
          expect((await index.listIdentityBindings(sourceId: 'source',
            identities: ['checksum:crc32:abcd'])).single.key, ready.key);
          final db = sql.sqlite3.open(path);
          try {
            expect(db.select('PRAGMA user_version').single.values.single, 22);
            for (final table in before.keys) {
              expect(rows(db, table, table == 'cache_entry' ? columns : '*'), before[table]);
            }
            expect(db.select('PRAGMA foreign_key_check'), isEmpty);
            expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
            final plan = db.select('EXPLAIN QUERY PLAN SELECT max(binding_id) FROM cache_entry')
                .map((row) => row['detail']).join(' ');
            expect(plan, contains('cache_entry_binding_id'));
            expect(plan, isNot(contains('SCAN')));
          } finally {
            db.close();
          }
        } finally {
          await index.close();
        }
      }
    });
  }

  test('reference IDs survive VACUUM and upsert while retirement removes candidates', () async {
    final root = await Directory.systemTemp.createTemp('cache-reference-lifetime-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/cache.sqlite';
    final first = _record('first', checksum: 'first');
    final second = _record('second', checksum: 'second');
    final third = _record('third', checksum: 'third');
    final initial = SqliteIndex(path);
    await initial.open();
    for (final record in [first, second, third]) await initial.put(record);
    await initial.remove(first.key);
    await initial.close();
    final raw = sql.sqlite3.open(path);
    Map<String, int> referenceIds(sql.Database db) => {
      for (final row in db.select('SELECT key,binding_id FROM cache_entry'))
        row['key']! as String: row['binding_id']! as int,
    };
    final before = referenceIds(raw);
    raw.execute('VACUUM');
    expect(referenceIds(raw), before);
    raw.close();
    final reopened = SqliteIndex(path);
    await reopened.open();
    addTearDown(reopened.close);
    await reopened.put(second.copyWith(pinned: true, touchedUs: 90));
    await reopened.put(_record('fourth', checksum: 'first'));
    expect((await reopened.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:first'])).single.id.content.comicId, 'fourth');
    final checked = sql.sqlite3.open(path);
    try {
      final after = referenceIds(checked);
      expect(after[second.key], before[second.key]);
      expect(after[third.key], before[third.key]);
      expect(after.values.toSet(), hasLength(3));
      expect(checked.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      checked.close();
    }
    await reopened.remove(second.key);
    await reopened.put(second.copyWith(checksum: 'replacement'));
    expect(await reopened.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:second']), isEmpty);
    expect((await reopened.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:replacement'])).single.key, second.key);
    await reopened.put(second.copyWith(state: CacheState.partial));
    expect(await reopened.listIdentityBindings(sourceId: 'source',
      identities: ['checksum:crc32:replacement']), isEmpty);
  });

  test('reference upgrade has one opener and close waits for its worker exit', () async {
    final root = await Directory.systemTemp.createTemp('cache-reference-open-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/cache.sqlite';
    final record = _record('target');
    final initial = SqliteIndex(path);
    await initial.open();
    await initial.put(record);
    await initial.close();
    final legacy = sql.sqlite3.open(path);
    _schema21References(legacy);
    legacy.close();
    final index = SqliteIndex(path);
    var eventTurnRan = false;
    Timer.run(() => eventTurnRan = true);
    final opening = index.open();
    expect(identical(index.open(), opening), isTrue);
    final closing = index.close();
    await opening;
    await closing;
    expect(eventTurnRan, isTrue);
    await expectLater(index.get(record.key), throwsStateError);
    await index.open();
    try {
      expect((await index.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd'])).single.key, record.key);
    } finally {
      await index.close();
    }
  });

  test('queries chunk scopes and identity terms without losing matches', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    for (var i = 0; i < 430; i++) {
      await index.put(_record('comic-$i', checksum: 'checksum-$i'));
    }
    var eventTurnRan = false;
    Timer.run(() => eventTurnRan = true);
    final scoped = await index.listScopedBindings([
      for (var i = 0; i < 430; i++) CacheBindingScope(sourceId: 'source',
        comicId: 'comic-$i', chapterId: 'chapter', sourceRevision: 'r1'),
    ]);
    expect(eventTurnRan, isTrue);
    eventTurnRan = false;
    Timer.run(() => eventTurnRan = true);
    final identity = await index.listIdentityBindings(sourceId: 'source', identities: [
      for (var i = 0; i < 430; i++) 'checksum:crc32:checksum-$i',
    ]);
    expect(eventTurnRan, isTrue);
    expect(scoped.map((r) => r.key).toSet(), identity.map((r) => r.key).toSet());
    expect(scoped, hasLength(430));
  });

  for (final persistent in [false, true]) {
    test('${persistent ? "persistent" : "memory"} single-scope and identity results leave an event turn', () async {
      final root = await Directory.systemTemp.createTemp('cache-result-budget-');
      addTearDown(() => root.delete(recursive: true));
      final index = SqliteIndex(persistent ? '${root.path}/cache.sqlite' : null);
      await index.open();
      addTearDown(index.close);
      for (var i = 0; i < 200; i++) {
        await index.put(_record('large', page: 'page-$i'));
      }
      var eventTurnRan = false;
      Timer.run(() => eventTurnRan = true);
      final scoped = await index.listScopedBindings([
        const CacheBindingScope(sourceId: 'source', comicId: 'large'),
      ]);
      expect(eventTurnRan, isTrue);
      eventTurnRan = false;
      Timer.run(() => eventTurnRan = true);
      final identity = index.listIdentityBindings(sourceId: 'source',
        identities: ['checksum:crc32:abcd']);
      final closing = index.close();
      expect((await identity).map((record) => record.key).toSet(),
        scoped.map((record) => record.key).toSet());
      expect(eventTurnRan, isTrue);
      expect(scoped, hasLength(200));
      await closing;
      if (persistent) {
        await index.open();
        final large = _record('oversized', page: 'x' * (256 * 1024),
          checksum: 'oversized');
        await index.put(large);
        eventTurnRan = false;
        Timer.run(() => eventTurnRan = true);
        expect((await index.listScopedBindings([
          const CacheBindingScope(sourceId: 'source', comicId: 'oversized'),
        ])).single.key, large.key);
        expect(eventTurnRan, isTrue);
        eventTurnRan = false;
        Timer.run(() => eventTurnRan = true);
        expect((await index.listIdentityBindings(sourceId: 'source',
          identities: ['checksum:crc32:oversized'])).single.key, large.key);
        expect(eventTurnRan, isTrue);
      }
    });
  }

  for (final sqlite in [false, true]) {
    test('${sqlite ? "sqlite" : "memory"} physical batches preserve selected and global inventory', () async {
      final CacheIndex index = sqlite ? SqliteIndex.memory() : MemIndex();
      await index.open();
      addTearDown(index.close);
      final artifacts = index as PhysicalMediaArtifactIndex;
      final partials = index as PhysicalPartialIndex;
      final ids = <PhysicalMediaId>[];
      for (var i = 0; i < 431; i++) {
        final record = _record('physical-$i');
        await index.put(record);
        final id = PhysicalMediaId.canonical('physical-$i');
        if (i < 430) ids.add(id);
        await artifacts.putPhysicalMediaArtifactBinding(id: id,
          artifactId: record.effectiveArtifactId, createdUs: 1, touchedUs: 2);
        await partials.putPhysicalPartial(PhysicalPartialRecord(id: id,
          path: '/partial/$i', bytes: 5, checksum: 'abc',
          createdUs: 1, touchedUs: 2));
      }
      expect(await artifacts.listPhysicalMediaArtifacts(ids: []), isEmpty);
      expect(await partials.listPhysicalPartials(ids: []), isEmpty);
      expect(await artifacts.listPhysicalMediaArtifacts(), hasLength(431));
      expect(await partials.listPhysicalPartials(), hasLength(431));
      final selected = [...ids.reversed, ids.first,
        PhysicalMediaId.canonical('missing')];
      final ready = await artifacts.listPhysicalMediaArtifacts(ids: selected);
      final partial = await partials.listPhysicalPartials(ids: selected);
      final expectedKeys = ids.map((id) => id.key).toList()..sort();
      expect(ready.map((r) => r.id.key), expectedKeys);
      expect(partial.map((r) => r.id.key), expectedKeys);
      expect(ready.first.bytes, 10);
      expect(partial.first.bytes, 5);
      if (index is SqliteIndex) {
        for (var i = 0; i < 431; i++) {
          await index.putPhysicalMediaProjection(PhysicalMediaProjectionRecord(
            exactKey: 'exact-$i', familyKey: i.isEven ? 'a' : 'b',
            projectionJson: '{}', createdUs: 1, touchedUs: 2));
        }
        expect(await index.listPhysicalMediaProjections(exactKeys: []), isEmpty);
        expect(await index.listPhysicalMediaProjections(), hasLength(431));
        final projections = await index.listPhysicalMediaProjections(exactKeys: [
          for (var i = 429; i >= 0; i--) 'exact-$i', 'exact-1', 'missing',
        ]);
        expect(projections, hasLength(430));
        expect(projections.map((r) => r.exactKey).toSet(),
          {for (var i = 0; i < 430; i++) 'exact-$i'});
        final ordering = projections.map((r) => '${r.familyKey}:${r.exactKey}').toList();
        expect(ordering, [...ordering]..sort());
      }
    });
  }

  test('close drains admitted record batches and rejects new reads until reopen', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final ids = <PhysicalMediaId>[];
    for (var i = 0; i < 430; i++) {
      final id = PhysicalMediaId.canonical('close-$i');
      ids.add(id);
      await index.putPhysicalPartial(PhysicalPartialRecord(id: id,
        path: '/partial/$i', bytes: 1, checksum: 'abc', createdUs: 1, touchedUs: 1));
      await index.put(_record('close-$i', checksum: 'checksum-$i'));
    }
    final read = index.listPhysicalPartials(ids: ids);
    final scopes = [for (var i = 0; i < 430; i++)
      CacheBindingScope(sourceId: 'source', comicId: 'close-$i')];
    final terms = [for (var i = 0; i < 430; i++) 'checksum:crc32:checksum-$i'];
    final scoped = index.listScopedBindings(scopes);
    final identity = index.listIdentityBindings(sourceId: 'source', identities: terms);
    final closing = index.close();
    await expectLater(index.listPhysicalPartials(ids: ids), throwsStateError);
    await expectLater(index.listScopedBindings(scopes), throwsStateError);
    await expectLater(index.listIdentityBindings(sourceId: 'source', identities: terms),
      throwsStateError);
    expect(await read, hasLength(430));
    expect(await scoped, hasLength(430));
    expect(await identity, hasLength(430));
    await closing;
    await index.open();
    expect(await index.listPhysicalPartials(ids: []), isEmpty);
  });
}
