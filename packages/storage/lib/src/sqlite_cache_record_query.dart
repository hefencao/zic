part of 'sqlite_index.dart';

void _createCacheRecordQueryIndexes(sql.Database db) {
  for (final column in ['source_id', 'comic_id', 'chapter_id']) {
    if (!_hasColumn(db, 'cache_entry', column)) {
      db.execute("ALTER TABLE cache_entry ADD COLUMN $column TEXT NOT NULL DEFAULT ''");
    }
  }
  db.execute('CREATE INDEX IF NOT EXISTS cache_entry_comic_chapter '
      'ON cache_entry(source_id, comic_id, chapter_id, source_revision)');
  db.execute('''
    CREATE TABLE IF NOT EXISTS cache_entry_identity (
      source_id TEXT NOT NULL,
      identity TEXT NOT NULL,
      cache_key TEXT NOT NULL REFERENCES cache_entry(key)
        ON DELETE CASCADE ON UPDATE CASCADE,
      PRIMARY KEY (source_id, identity, cache_key)
    ) WITHOUT ROWID
  ''');
  // Retirement must also find a binding's derived tokens without scanning the
  // identity index. Both projections commit with the original cache binding.
  db.execute('CREATE INDEX IF NOT EXISTS cache_entry_identity_key '
      'ON cache_entry_identity(cache_key)');
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
      ), key: row['key']! as String);
    } on FormatException {
      // Historical corrupt rows remain available to explicit repair.
    } on TypeError {
      // Do not let an unrelated malformed legacy identity break migration.
    } on ArgumentError {
      // Invalid legacy enum values are not reusable candidates.
    }
  }
}

void _putCacheIdentityTerms(sql.Database db, CacheRec record, {String? key}) {
  final cacheKey = key ?? record.key;
  db.execute('DELETE FROM cache_entry_identity WHERE cache_key = ?', [cacheKey]);
  if (record.state != CacheState.ready) return;
  for (final identity in cacheRecordIdentityTerms(record).toSet()) {
    db.execute('INSERT INTO cache_entry_identity(source_id, identity, cache_key) '
        'VALUES (?, ?, ?)', [record.id.content.sourceId, identity, cacheKey]);
  }
}

List<CacheRec> _readScopedBindings(SqliteIndex index,
    Iterable<CacheBindingScope> scopes) {
  final selected = scopes.toSet().toList(growable: false);
  final records = <String, CacheRec>{};
  // At most four parameters per scope; stay below older SQLite variable caps.
  for (var start = 0; start < selected.length; start += 100) {
    final chunk = selected.sublist(start, (start + 100).clamp(0, selected.length));
    final arguments = <Object?>[];
    final predicates = <String>[];
    for (final scope in chunk) {
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
      predicates.add('($predicate)');
    }
    for (final row in index._requireDb().select(
      'SELECT * FROM cache_entry WHERE ${predicates.join(' OR ')}', arguments,
    )) {
      final record = index._read(row);
      records[record.key] = record;
    }
  }
  return records.values.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
}

List<CacheRec> _readIdentityBindings(SqliteIndex index, String sourceId,
    Iterable<String> identities) {
  final selected = identities.toSet().toList(growable: false);
  final records = <String, CacheRec>{};
  for (var start = 0; start < selected.length; start += 400) {
    final chunk = selected.sublist(start, (start + 400).clamp(0, selected.length));
    final slots = List.filled(chunk.length, '?').join(',');
    final rows = index._requireDb().select(
      'SELECT c.* FROM cache_entry_identity i '
      'JOIN cache_entry c ON c.key = i.cache_key '
      'WHERE i.source_id = ? AND i.identity IN ($slots)', [sourceId, ...chunk],
    );
    for (final row in rows) {
      final record = index._read(row);
      records[record.key] = record;
    }
  }
  return records.values.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
}
