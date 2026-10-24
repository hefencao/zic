part of 'sqlite_index.dart';

void _createCacheRecordQueryIndexes(sql.Database db) {
  for (final column in ['source_id', 'comic_id', 'chapter_id']) {
    if (!_hasColumn(db, 'cache_entry', column)) {
      db.execute("ALTER TABLE cache_entry ADD COLUMN $column TEXT NOT NULL DEFAULT ''");
    }
  }
  db.execute('CREATE INDEX IF NOT EXISTS cache_entry_comic_chapter '
      'ON cache_entry(source_id, comic_id, chapter_id, source_revision)');
  _createCacheRecordReferenceIds(db);
  _createCacheIdentityTable(db, 'cache_entry_identity');
  _createCacheIdentityReferenceIndex(db);
  final rows = db.select('SELECT * FROM cache_entry');
  for (final row in rows) {
    try {
      final id = DownloadId.fromJson(Map<String, Object?>.from(
        jsonDecode(row['download_json']! as String) as Map,
      ));
      db.execute('UPDATE cache_entry SET source_id = ?, comic_id = ?, '
          'chapter_id = ? WHERE key = ?', <Object?>[
        id.content.sourceId, id.content.comicId, id.content.chapterId, row['key'],
      ]);
      _putCacheIdentityTerms(db, CacheRec(
        id: id, state: CacheState.values.byName(row['state']! as String),
        path: row['path']! as String, bytes: row['bytes']! as int,
        checksum: row['checksum']! as String,
        checksumAlgorithm: row['checksum_algorithm']! as String,
        createdUs: row['created_us']! as int, touchedUs: row['touched_us']! as int,
      ), bindingId: row['binding_id']! as int);
    } on FormatException {
      // Historical corrupt rows remain available to explicit repair.
    } on TypeError {
      // Do not let an unrelated malformed legacy identity break migration.
    } on ArgumentError {
      // Invalid legacy enum values are not reusable candidates.
    }
  }
}

void _createCacheRecordReferenceIds(sql.Database db) {
  if (!_hasColumn(db, 'cache_entry', 'binding_id')) {
    db.execute('ALTER TABLE cache_entry ADD COLUMN binding_id INTEGER');
    // Persist the initial row number once; later VACUUM may renumber rowid.
    // New bindings allocate from this indexed column inside the binding write.
    db.execute('UPDATE cache_entry SET binding_id = rowid');
  }
  db.execute('CREATE UNIQUE INDEX IF NOT EXISTS cache_entry_binding_id '
      'ON cache_entry(binding_id)');
}

void _createCacheIdentityTable(sql.Database db, String name) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS $name (
      source_id TEXT NOT NULL,
      identity TEXT NOT NULL,
      binding_id INTEGER NOT NULL REFERENCES cache_entry(binding_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
      PRIMARY KEY (source_id, identity, binding_id)
    ) WITHOUT ROWID
  ''');
}

void _createCacheIdentityReferenceIndex(sql.Database db) {
  db.execute('CREATE INDEX IF NOT EXISTS cache_entry_identity_key '
      'ON cache_entry_identity(binding_id)');
}

void _migrateCacheRecordReferenceIds(sql.Database db) {
  _createCacheRecordReferenceIds(db);
  _createCacheIdentityTable(db, 'cache_entry_identity_next');
  db.execute('INSERT INTO cache_entry_identity_next(source_id, identity, binding_id) '
      'SELECT i.source_id, i.identity, c.binding_id FROM cache_entry_identity i '
      'JOIN cache_entry c ON c.key = i.cache_key');
  db.execute('DROP TABLE cache_entry_identity');
  db.execute('ALTER TABLE cache_entry_identity_next RENAME TO cache_entry_identity');
  _createCacheIdentityReferenceIndex(db);
}

Future<void> _migrateCacheRecordQueryIndexesOffIsolate(String path) => Isolate.run(() {
  // This one-time derived-index upgrade can rewrite large SQLite pages. The
  // SqliteIndex opener waits for the worker/connection to exit before use.
  final db = sql.sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 5000');
    db.execute('BEGIN IMMEDIATE');
    try {
      final version = db.select('PRAGMA user_version').single.values.single as int;
      if (version != SqliteIndex._schemaVersion) {
        if (version == 20) {
          db.execute(SqliteIndex._replicaLocatorIndexSql);
          _createCacheRecordQueryIndexes(db);
        } else if (version == 21) {
          _migrateCacheRecordReferenceIds(db);
        } else {
          throw StateError('unexpected cache schema version: $version');
        }
        db.execute('PRAGMA user_version = ${SqliteIndex._schemaVersion}');
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
});

void _putCacheIdentityTerms(sql.Database db, CacheRec record, {required int bindingId}) {
  // Both projections commit with the binding. This reference is never page
  // identity or a proof of equivalence; queries still return the complete row.
  db.execute('DELETE FROM cache_entry_identity WHERE binding_id = ?', [bindingId]);
  if (record.state != CacheState.ready) return;
  for (final identity in cacheRecordIdentityTerms(record).toSet()) {
    db.execute('INSERT INTO cache_entry_identity(source_id, identity, binding_id) '
        'VALUES (?, ?, ?)', [record.id.content.sourceId, identity, bindingId]);
  }
}

Future<List<CacheRec>> _readScopedBindings(SqliteIndex index,
    Iterable<CacheBindingScope> scopes) => index._readRecords((db) async {
  final selected = scopes.toSet().toList(growable: false);
  if (selected.isEmpty) return const <CacheRec>[];
  final cached = index._cachedEntries;
  if (cached != null) {
    return _readScopedBindingRows(db, selected, cached: cached);
  }
  final path = index.path;
  if (path != null && selected.length == 1) {
    final arguments = <Object?>[];
    final predicate = _cacheScopePredicate(selected.single, arguments);
    if (_smallCacheBindingResult(db.select(
      'SELECT length(CAST(download_json AS BLOB)) AS bytes FROM cache_entry '
      'WHERE $predicate LIMIT 17', arguments,
    ))) return _readScopedBindingRows(db, selected);
  }
  return path == null ? _readScopedBindingRows(db, selected)
      : _readCacheBindingsOffIsolate(path, scopes: selected);
});

Future<List<CacheRec>> _readIdentityBindings(SqliteIndex index, String sourceId,
    Iterable<String> identities) => index._readRecords((db) async {
  final selected = identities.toSet().toList(growable: false);
  if (selected.isEmpty) return const <CacheRec>[];
  final cached = index._cachedEntries;
  if (cached != null) {
    return _readIdentityBindingRows(db, sourceId, selected, cached: cached);
  }
  final path = index.path;
  if (path != null && selected.length == 1 && _smallCacheBindingResult(db.select(
    'SELECT length(CAST(c.download_json AS BLOB)) AS bytes '
    'FROM cache_entry_identity i JOIN cache_entry c ON c.binding_id = i.binding_id '
    'WHERE i.source_id = ? AND i.identity = ? LIMIT 17', [sourceId, selected.single],
  ))) return _readIdentityBindingRows(db, sourceId, selected);
  return path == null ? _readIdentityBindingRows(db, sourceId, selected)
      : _readCacheBindingsOffIsolate(path, sourceId: sourceId, identities: selected);
});

bool _smallCacheBindingResult(List<sql.Row> rows) {
  // Keep tiny hot lookups on the existing connection. Bound both rows and
  // encoded payload so a large single chapter/token still uses the worker.
  if (rows.length > 16) return false;
  var bytes = 0;
  for (final row in rows) {
    bytes += row['bytes']! as int;
    if (bytes > 64 * 1024) return false;
  }
  return true;
}

String _cacheScopePredicate(CacheBindingScope scope, List<Object?> arguments) {
  var predicate = 'source_id = ? AND comic_id = ?';
  arguments.addAll([scope.sourceId, scope.comicId]);
  if (scope.chapterId != null) {
    predicate += ' AND chapter_id = ?';
    arguments.add(scope.chapterId);
  }
  if (scope.sourceRevision != null) {
    predicate += ' AND source_revision = ?';
    arguments.add(scope.sourceRevision);
  }
  return '($predicate)';
}

Future<List<CacheRec>> _readCacheBindingsOffIsolate(String path, {
  List<CacheBindingScope>? scopes, String? sourceId,
  List<String> identities = const [],
}) => Isolate.run(() async {
  final db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    return await (scopes != null
        ? _readScopedBindingRows(db, scopes, yieldEvents: false)
        : _readIdentityBindingRows(db, sourceId!, identities, yieldEvents: false));
  } finally {
    db.dispose();
  }
});

Future<void> _decodeCacheRecordRows(Iterable<sql.Row> rows,
    Map<String, CacheRec> records, {required bool yieldEvents,
    Map<String, CacheRec>? cached}) async {
  final budget = Stopwatch()..start();
  var decoded = 0;
  for (final row in rows) {
    if (yieldEvents && (++decoded >= 64 || budget.elapsedMicroseconds >= 4000)) {
      await Future<void>.delayed(Duration.zero);
      decoded = 0;
      budget.reset();
    }
    if (records.containsKey(row['key'])) continue;
    final warm = cached?[row['key']];
    // An admitted writer may update/invalidate the owner's map while this
    // batch yields. Reuse only an object matching the selected row snapshot.
    final record = warm != null && _matchesCacheRecordRow(warm, row)
        ? warm : SqliteIndex._read(row);
    records[record.key] = record;
  }
}

bool _matchesCacheRecordRow(CacheRec record, sql.Row row) =>
    record.state.name == row['state'] && record.path == row['path'] &&
    record.bytes == row['bytes'] && record.checksum == row['checksum'] &&
    record.checksumAlgorithm == row['checksum_algorithm'] &&
    record.artifactId == row['artifact_id'] && record.storageRootId == row['storage_root_id'] &&
    record.createdUs == row['created_us'] && record.touchedUs == row['touched_us'] &&
    record.pinned == (row['pinned'] == 1);

Future<List<CacheRec>> _readScopedBindingRows(sql.Database db,
    List<CacheBindingScope> selected, {bool yieldEvents = true,
    Map<String, CacheRec>? cached}) async {
  final records = <String, CacheRec>{};
  // At most four parameters per scope; stay below older SQLite variable caps.
  for (var start = 0; start < selected.length; start += 100) {
    if (yieldEvents && start > 0) await Future<void>.delayed(Duration.zero);
    final chunk = selected.sublist(start, (start + 100).clamp(0, selected.length));
    final arguments = <Object?>[];
    final predicates = <String>[];
    for (final scope in chunk) {
      predicates.add(_cacheScopePredicate(scope, arguments));
    }
    await _decodeCacheRecordRows(db.select(
      'SELECT * FROM cache_entry WHERE ${predicates.join(' OR ')}', arguments,
    ), records, yieldEvents: yieldEvents, cached: cached);
  }
  return records.values.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
}

Future<List<CacheRec>> _readIdentityBindingRows(sql.Database db, String sourceId,
    List<String> selected, {bool yieldEvents = true,
    Map<String, CacheRec>? cached}) async {
  final records = <String, CacheRec>{};
  for (var start = 0; start < selected.length; start += 400) {
    if (yieldEvents && start > 0) await Future<void>.delayed(Duration.zero);
    final chunk = selected.sublist(start, (start + 400).clamp(0, selected.length));
    final slots = List.filled(chunk.length, '?').join(',');
    final rows = db.select(
      'SELECT c.* FROM cache_entry_identity i '
      'JOIN cache_entry c ON c.binding_id = i.binding_id '
      'WHERE i.source_id = ? AND i.identity IN ($slots)', [sourceId, ...chunk],
    );
    await _decodeCacheRecordRows(rows, records, yieldEvents: yieldEvents, cached: cached);
  }
  return records.values.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
}
