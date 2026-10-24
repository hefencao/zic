import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('binding usage matches full inventory through cold/warm mutations',
      () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final first = _record('first', artifactId: 'shared', bytes: 20);
    final alias = _record('alias', artifactId: 'shared', bytes: 20);
    final partial = _record('partial', state: CacheState.partial, bytes: 7);
    await index.put(first);
    await index.put(alias);
    await index.put(partial);

    final cold = await index.readBindingUsage();
    expect(cold.bytes, 27);
    expect(cold.entries, 3);
    expect(cold.readyArtifactIds, <String>{'shared'});
    await _expectInventory(index, cold);
    await _expectInventory(index, await index.readBindingUsage());

    await index.put(partial.copyWith(bytes: 11, pinned: true));
    await _expectInventory(index, await index.readBindingUsage());
    await index.remove(alias.key);
    await _expectInventory(index, await index.readBindingUsage());
    await index.put(partial.copyWith(state: CacheState.ready, bytes: 30));
    await _expectInventory(index, await index.readBindingUsage());
    expect(() => cold.readyArtifactIds.add('changed'), throwsUnsupportedError);
    expect(cold.bytes, 27);
    expect(cold.entries, 3);
    await index.remove(first.key);
    await index.remove(partial.key);
    final empty = await index.readBindingUsage();
    expect(empty.bytes, 0);
    expect(empty.entries, 0);
    expect(empty.readyArtifactIds, isEmpty);
  });

  test('legacy blank artifact IDs and duplicate partial keys keep list semantics',
      () async {
    final directory = await Directory.systemTemp.createTemp('binding-usage-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/cache.sqlite';
    final index = SqliteIndex(path);
    await index.open();
    addTearDown(index.close);
    final first = _record('first', path: '/legacy/shared', bytes: 20);
    final alias = _record('alias', path: first.path, bytes: 20);
    final partial = _record('partial', state: CacheState.partial, bytes: 7);
    await index.put(first);
    await index.put(alias);
    await index.put(partial);
    final db = sql.sqlite3.open(path);
    try {
      db.execute("UPDATE cache_entry SET artifact_id = '' WHERE state = 'ready'");
      db.execute('INSERT INTO cache_entry '
          '(key, download_json, state, path, bytes, checksum, created_us, touched_us) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', <Object?>[
        partial.id.legacyKey, jsonEncode(partial.id.toJson()), 'partial',
        partial.path, 11, 'abcd', 1, 2,
      ]);
    } finally {
      db.close();
    }

    final cold = await index.readBindingUsage();
    expect(cold.bytes, 31);
    expect(cold.entries, 4);
    expect(cold.readyArtifactIds, <String>{defaultArtifactIdForPath(first.path)});
    await _expectInventory(index, cold);
    final warm = await index.readBindingUsage();
    expect(warm.entries, 3);
    await _expectInventory(index, warm);
  });

  test('READY accounting does not load identity JSON or publish body authority',
      () async {
    final directory = await Directory.systemTemp.createTemp('usage-fields-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/cache.sqlite';
    final index = SqliteIndex(path);
    await index.open();
    addTearDown(index.close);
    final record = _record('ready', artifactId: 'object', bytes: 20);
    await index.put(record);
    final db = sql.sqlite3.open(path);
    try {
      db.execute("UPDATE cache_entry SET download_json = 'not-json'");
    } finally {
      db.close();
    }

    final usage = await index.readBindingUsage();
    expect(usage.bytes, 20);
    expect(usage.entries, 1);
    expect(usage.readyArtifactIds, <String>{'object'});
    await expectLater(index.get(record.key), throwsFormatException);
    await expectLater(index.list(), throwsFormatException);
    await index.put(record.copyWith(state: CacheState.partial));
    final corrupt = sql.sqlite3.open(path);
    try {
      corrupt.execute("UPDATE cache_entry SET download_json = 'not-json'");
    } finally {
      corrupt.close();
    }
    await expectLater(index.readBindingUsage(), throwsFormatException);
  });

  test('binding usage respects the index close admission boundary', () async {
    final index = SqliteIndex.memory();
    await index.open();
    await index.put(_record('ready', bytes: 20));
    final admitted = index.readBindingUsage();
    final closed = index.close();
    expect((await admitted).bytes, 20);
    await closed;
    await expectLater(index.readBindingUsage(), throwsStateError);
  });
}

Future<void> _expectInventory(SqliteIndex index, CacheBindingUsage usage) async {
  final records = await index.list();
  expect(usage.bytes, physicalCacheBytes(records));
  expect(usage.entries, records.length);
  expect(usage.readyArtifactIds, <String>{
    for (final record in records)
      if (record.state == CacheState.ready) record.effectiveArtifactId,
  });
}

CacheRec _record(String page, {
  String? path,
  String artifactId = '',
  CacheState state = CacheState.ready,
  required int bytes,
}) => CacheRec(
  id: DownloadId(
    content: ContentId(sourceId: 'source', comicId: 'comic',
      chapterId: 'chapter', pageId: page),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/$page.webp?token=signed'),
  ),
  state: state,
  path: path ?? '/cache/$page',
  bytes: bytes,
  checksum: 'abcd',
  createdUs: 1,
  touchedUs: 2,
  artifactId: artifactId,
);
