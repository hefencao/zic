part of 'sqlite_index.dart';

void _createCacheMaintenanceTables(sql.Database db) {
  db.execute('CREATE INDEX IF NOT EXISTS cache_entry_artifact '
      'ON cache_entry(artifact_id, state, touched_us)');
  db.execute('''
    CREATE TABLE IF NOT EXISTS cache_download_retention (
      source_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      source_revision TEXT NOT NULL,
      physical_key TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (source_id, comic_id, chapter_id, source_revision, physical_key)
    ) WITHOUT ROWID
  ''');
  db.execute('CREATE INDEX IF NOT EXISTS cache_download_retention_physical '
      'ON cache_download_retention(physical_key) WHERE physical_key != \'\'');
}

/// Physical cache candidate. This snapshot is maintenance metadata, not a
/// durable read proof. The owner must recheck it in the retirement transaction.
final class CacheMaintenanceArtifact {
  const CacheMaintenanceArtifact({
    required this.object,
    required this.createdUs,
    required this.touchedUs,
    required this.exactBindings,
    required this.physicalBindings,
    required this.retained,
  });

  final ArtifactObjectRecord object;
  final int createdUs;
  final int touchedUs;
  final int exactBindings;
  final int physicalBindings;
  final bool retained;
}

const _cacheMaintenanceArtifactSelect = '''
  SELECT o.*,
    MAX(o.touched_us,
      COALESCE((SELECT MAX(c.touched_us) FROM cache_entry c
        WHERE c.artifact_id = o.artifact_id AND c.state = 'ready'), 0),
      COALESCE((SELECT MAX(p.touched_us) FROM physical_media_artifact p
        WHERE p.artifact_id = o.artifact_id), 0)) AS last_touch,
    (SELECT COUNT(*) FROM cache_entry c WHERE c.artifact_id = o.artifact_id
      AND c.state = 'ready') AS exact_count,
    (SELECT COUNT(*) FROM physical_media_artifact p
      WHERE p.artifact_id = o.artifact_id) AS physical_count,
    (EXISTS(SELECT 1 FROM cache_entry c WHERE c.artifact_id = o.artifact_id
      AND c.state = 'ready' AND ($_downloadChapterCacheRetained))
      OR EXISTS(SELECT 1 FROM physical_media_artifact p
        JOIN cache_download_retention r ON r.physical_key = p.physical_key
        WHERE p.artifact_id = o.artifact_id AND r.physical_key != '')) AS retained
  FROM artifact_object o
''';

// An admitted chapter intent protects bytes until local export/pinning exits.
// A legacy pin discovers adoption candidates, not authority over every stale
// carrier ever stored under that chapter. The owner checks its actual manifest.
const _downloadChapterCacheRetained = '''
  c.pinned != 0 OR EXISTS(
    SELECT 1 FROM cache_download_retention r WHERE r.physical_key = ''
      AND r.source_id = c.source_id AND r.comic_id = c.comic_id
      AND r.chapter_id = c.chapter_id AND r.source_revision = c.source_revision)
''';

const _downloadCacheOwnershipScopes = '''
  SELECT source_id, comic_id, chapter_id, source_revision
  FROM cache_download_retention WHERE physical_key = ''
  UNION SELECT source_id, comic_id, chapter_id, source_revision
  FROM cache_entry WHERE state = 'ready' AND pinned != 0
''';

CacheMaintenanceArtifact _readCacheMaintenanceArtifact(sql.Row row) =>
    CacheMaintenanceArtifact(
      object: ArtifactObjectRecord(
        artifactId: row['artifact_id']! as String,
        accessLocator: row['path']! as String,
        bytes: row['bytes']! as int,
        checksum: row['checksum']! as String,
        checksumAlgorithm: row['checksum_algorithm']! as String,
        storageRootId: row['storage_root_id']! as String,
      ),
      createdUs: row['created_us']! as int,
      touchedUs: row['last_touch']! as int,
      exactBindings: row['exact_count']! as int,
      physicalBindings: row['physical_count']! as int,
      retained: (row['retained']! as int) != 0,
    );

Future<List<CacheMaintenanceArtifact>> _readCacheMaintenanceArtifactsOffIsolate(
    String path) => Isolate.run(() async {
  final db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    return await _readCacheMaintenanceArtifacts(db);
  } finally {
    db.dispose();
  }
}, debugName: 'zic-cache-inventory');

Future<List<CacheMaintenanceArtifact>> _readCacheMaintenanceArtifacts(
    sql.Database db) async {
  final result = <CacheMaintenanceArtifact>[];
  String? after;
  while (true) {
    final rows = db.select('$_cacheMaintenanceArtifactSelect '
        '${after == null ? '' : 'WHERE o.artifact_id > ? '}ORDER BY o.artifact_id LIMIT 128',
        after == null ? const <Object?>[] : <Object?>[after]);
    for (final row in rows) {
      final value = _readCacheMaintenanceArtifact(row);
      if (value.exactBindings != 0 || value.physicalBindings != 0) result.add(value);
    }
    if (rows.length < 128) break;
    after = rows.last['artifact_id']! as String;
    await Future<void>.delayed(Duration.zero);
  }
  return result;
}

extension SqliteCacheMaintenance on SqliteIndex {
  Future<bool> hasDownloadCacheIntent(CacheBindingScope scope) async =>
      _requireDb().select('''
        SELECT 1 FROM cache_download_retention WHERE physical_key = ''
          AND source_id = ? AND comic_id = ? AND chapter_id = ? AND source_revision = ? LIMIT 1
      ''', <Object?>[scope.sourceId, scope.comicId, scope.chapterId, scope.sourceRevision]).isNotEmpty;

  Future<bool> hasDownloadCacheOwnership(CacheBindingScope scope) async =>
      _requireDb().select('''
        SELECT 1 FROM cache_download_retention WHERE physical_key = ''
          AND source_id = ? AND comic_id = ? AND chapter_id = ? AND source_revision = ?
        UNION ALL SELECT 1 FROM cache_entry WHERE state = 'ready' AND pinned != 0
          AND source_id = ? AND comic_id = ? AND chapter_id = ? AND source_revision = ? LIMIT 1
      ''', <Object?>[for (var i = 0; i < 2; i++) ...[
        scope.sourceId, scope.comicId, scope.chapterId, scope.sourceRevision,
      ]]).isNotEmpty;

  Future<List<CacheBindingScope>> readDownloadCacheOwnershipScopes() async =>
      _requireDb().select(_downloadCacheOwnershipScopes)
          .map((row) => CacheBindingScope(sourceId: row['source_id']! as String,
          comicId: row['comic_id']! as String, chapterId: row['chapter_id']! as String,
          sourceRevision: row['source_revision']! as String)).toList(growable: false);

  Future<List<CacheBindingScope>> readDownloadCacheAdoptionScopes() async =>
      _requireDb().select('''
        SELECT d.* FROM ($_downloadCacheOwnershipScopes) d
        WHERE EXISTS(SELECT 1 FROM cache_entry c WHERE c.pinned = 0
          AND c.source_id = d.source_id AND c.comic_id = d.comic_id
          AND c.chapter_id = d.chapter_id AND c.source_revision = d.source_revision
          AND (c.state = 'ready' OR (c.state = 'partial' AND c.bytes > 0 AND NOT EXISTS(
            SELECT 1 FROM cache_download_retention r WHERE r.physical_key = ''
              AND r.source_id = d.source_id AND r.comic_id = d.comic_id
              AND r.chapter_id = d.chapter_id AND r.source_revision = d.source_revision))))
          OR EXISTS(SELECT 1 FROM cache_download_retention r
            JOIN physical_media_artifact p ON p.physical_key = r.physical_key
            WHERE r.source_id = d.source_id AND r.comic_id = d.comic_id
              AND r.chapter_id = d.chapter_id AND r.source_revision = d.source_revision)
      ''').map((row) => CacheBindingScope(sourceId: row['source_id']! as String,
          comicId: row['comic_id']! as String, chapterId: row['chapter_id']! as String,
          sourceRevision: row['source_revision']! as String)).toList(growable: false);

  /// One compact row per resident immutable body, with no DownloadId JSON or
  /// version-family expansion. File-backed inventory uses a read-only worker;
  /// a timer/zero-delay batch on the UI isolate still blocks platform replies.
  /// Retirement rechecks every candidate through the owning connection.
  Future<List<CacheMaintenanceArtifact>> readCacheMaintenanceArtifacts() =>
      _readRecords((db) {
    final dbPath = path;
    if (dbPath != null) return _readCacheMaintenanceArtifactsOffIsolate(dbPath);
    return _readCacheMaintenanceArtifacts(db);
  });

  /// Only live owner identities need checking. Do not load every historical
  /// version's DownloadId just to prove that its binding is idle.
  bool hasBusyCacheArtifactBindings(String artifactId, {
    required Set<String> exactKeys, required Set<String> physicalKeys,
  }) {
    final db = _requireDb();
    for (final (table, column, keys) in [
      ('cache_entry', 'key', exactKeys),
      ('physical_media_artifact', 'physical_key', physicalKeys),
    ]) {
      final values = keys.toList(growable: false);
      for (var start = 0; start < values.length; start += 400) {
        final batch = values.sublist(start, start + 400 < values.length ? start + 400 : values.length);
        if (db.select('SELECT 1 FROM $table WHERE artifact_id = ? '
            'AND $column IN (${List.filled(batch.length, '?').join(',')}) LIMIT 1',
            <Object?>[artifactId, ...batch]).isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  Future<bool> isPhysicalCacheRetained(String key) async => _requireDb().select(
      'SELECT 1 FROM cache_download_retention WHERE physical_key = ? LIMIT 1',
      <Object?>[key]).isNotEmpty;

  Future<bool> isExactCacheRetained(String key) async => _requireDb().select('''
    SELECT 1 FROM cache_entry c WHERE c.key = ? AND ($_downloadChapterCacheRetained)
  ''', <Object?>[key]).isNotEmpty;

  Future<List<({CacheRec record, bool retained})>> readCacheMaintenancePartials() async =>
      _requireDb().select('''
        SELECT c.*, ($_downloadChapterCacheRetained) AS retained
        FROM cache_entry c WHERE c.state = 'partial'
      ''').map((row) => (record: SqliteIndex._read(row),
          retained: (row['retained']! as int) != 0)).toList(growable: false);

  Future<Set<String>> readRetainedPhysicalCacheKeys() async =>
      _requireDb().select("SELECT DISTINCT physical_key FROM cache_download_retention "
          "WHERE physical_key != ''").map((row) => row['physical_key']! as String).toSet();

  Future<Set<String>> readReadyPhysicalCacheKeys() async =>
      _requireDb().select('SELECT physical_key FROM physical_media_artifact')
          .map((row) => row['physical_key']! as String).toSet();

  Future<void> retainDownloadCache({required String sourceId,
    required String comicId, required String chapterId, required String sourceRevision,
    String physicalKey = ''}) async {
    _requireDb().execute('INSERT OR IGNORE INTO cache_download_retention '
        '(source_id, comic_id, chapter_id, source_revision, physical_key) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[sourceId, comicId, chapterId, sourceRevision, physicalKey]);
  }

  Future<void> releaseDownloadCache({required String sourceId,
    required String comicId, String? chapterId, String? sourceRevision,
    String? physicalKey}) async {
    final conditions = <String>['source_id = ?', 'comic_id = ?'];
    final args = <Object?>[sourceId, comicId];
    if (chapterId != null) { conditions.add('chapter_id = ?'); args.add(chapterId); }
    if (sourceRevision != null) { conditions.add('source_revision = ?'); args.add(sourceRevision); }
    if (physicalKey != null) { conditions.add('physical_key = ?'); args.add(physicalKey); }
    _requireDb().execute('DELETE FROM cache_download_retention WHERE '
        '${conditions.join(' AND ')}', args);
  }

  /// Retires every exact/canonical binding of one unchanged, unprotected body
  /// together with its cleanup intents. No version relation is removed.
  Future<bool> retireCacheArtifactForMaintenance({
    required CacheMaintenanceArtifact expected,
    required List<StorageCleanupDebtRecord> cleanupDebts,
    required bool Function() canRetire,
    bool compareRecency = true,
  }) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select('$_cacheMaintenanceArtifactSelect WHERE o.artifact_id = ?',
          <Object?>[expected.object.artifactId]);
      if (rows.isEmpty) { db.execute('COMMIT'); return false; }
      final current = _readCacheMaintenanceArtifact(rows.single);
      final migrating = db.select('SELECT 1 FROM artifact_replica_migration m '
          'JOIN artifact_replica r ON r.replica_id = m.replica_id '
          'WHERE r.artifact_id = ? LIMIT 1', <Object?>[expected.object.artifactId]);
      final a = current.object;
      final b = expected.object;
      if (current.retained || migrating.isNotEmpty || current.createdUs != expected.createdUs ||
          (compareRecency && current.touchedUs != expected.touchedUs) ||
          current.exactBindings != expected.exactBindings ||
          current.physicalBindings != expected.physicalBindings ||
          a.accessLocator != b.accessLocator || a.storageRootId != b.storageRootId ||
          a.bytes != b.bytes || a.checksum != b.checksum ||
          a.checksumAlgorithm != b.checksumAlgorithm || !canRetire()) {
        db.execute('COMMIT');
        return false;
      }
      final keys = db.select("SELECT key FROM cache_entry WHERE artifact_id = ? AND state = 'ready'",
          <Object?>[b.artifactId]);
      for (final debt in cleanupDebts) {
        db.execute('INSERT OR REPLACE INTO storage_cleanup_debt '
            '(access_locator, storage_root_id, kind, created_us, touched_us, '
            'expected_bytes, expected_checksum, expected_checksum_algorithm) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', <Object?>[
          debt.accessLocator, debt.storageRootId, debt.kind.name, debt.createdUs,
          debt.touchedUs, debt.expectedBytes, debt.expectedChecksum, debt.expectedChecksumAlgorithm,
        ]);
      }
      db.execute("DELETE FROM cache_entry WHERE artifact_id = ? AND state = 'ready'",
          <Object?>[b.artifactId]);
      db.execute('DELETE FROM physical_media_artifact WHERE artifact_id = ?', <Object?>[b.artifactId]);
      db.execute('DELETE FROM artifact_object WHERE artifact_id = ?', <Object?>[b.artifactId]);
      db.execute('COMMIT');
      for (final row in keys) { _cachedEntries?.remove(row['key']! as String); }
      return true;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
