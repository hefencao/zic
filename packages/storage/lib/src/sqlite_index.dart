import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'cache_index.dart';
import 'download_placement.dart';

final class SqliteIndex implements CacheIndex, CacheBindingOperations {
  SqliteIndex(this.path);

  SqliteIndex.memory() : path = null;

  final String? path;
  sql.Database? _db;

  @override
  Future<void> open() async {
    if (_db != null) {
      return;
    }
    final dbPath = path;
    if (dbPath == null) {
      _db = sql.sqlite3.openInMemory();
    } else {
      await File(dbPath).parent.create(recursive: true);
      _db = sql.sqlite3.open(dbPath);
    }
    final db = _db!;
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 5) {
      throw StateError('unsupported cache schema version: $version');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      if (version == 0) {
        db.execute('''
          CREATE TABLE IF NOT EXISTS cache_entry (
            key TEXT NOT NULL PRIMARY KEY,
            download_json TEXT NOT NULL,
            state TEXT NOT NULL,
            path TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            checksum TEXT NOT NULL,
            created_us INTEGER NOT NULL,
            touched_us INTEGER NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            checksum_algorithm TEXT NOT NULL DEFAULT 'crc32',
            artifact_id TEXT NOT NULL DEFAULT '',
            storage_root_id TEXT NOT NULL DEFAULT 'default'
          )
        ''');
      } else {
        if (!_hasColumn(db, 'cache_entry', 'pinned')) {
          db.execute(
            'ALTER TABLE cache_entry '
            'ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (!_hasColumn(db, 'cache_entry', 'checksum_algorithm')) {
          db.execute(
            'ALTER TABLE cache_entry '
            "ADD COLUMN checksum_algorithm TEXT NOT NULL DEFAULT 'crc32'",
          );
        }
        if (!_hasColumn(db, 'cache_entry', 'artifact_id')) {
          db.execute(
            'ALTER TABLE cache_entry '
            "ADD COLUMN artifact_id TEXT NOT NULL DEFAULT ''",
          );
        }
        if (!_hasColumn(db, 'cache_entry', 'storage_root_id')) {
          db.execute(
            'ALTER TABLE cache_entry '
            "ADD COLUMN storage_root_id TEXT NOT NULL DEFAULT 'default'",
          );
        }
      }
      db.execute(
        'CREATE INDEX IF NOT EXISTS cache_entry_state_touch '
        'ON cache_entry(state, touched_us)',
      );
      db.execute('''
        CREATE TABLE IF NOT EXISTS download_placement (
          placement_id TEXT NOT NULL PRIMARY KEY,
          source_id TEXT NOT NULL,
          comic_id TEXT NOT NULL,
          comic_title TEXT NOT NULL,
          mode TEXT NOT NULL,
          relative_directory TEXT NOT NULL,
          storage_root_id TEXT NOT NULL,
          comic_family_id TEXT,
          observed_owner_key TEXT,
          generation INTEGER NOT NULL DEFAULT 0,
          fingerprint TEXT,
          page_order TEXT NOT NULL DEFAULT 'auto',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      if (!_hasColumn(db, 'download_placement', 'generation')) {
        db.execute(
          'ALTER TABLE download_placement '
          'ADD COLUMN generation INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!_hasColumn(db, 'download_placement', 'fingerprint')) {
        db.execute(
          'ALTER TABLE download_placement ADD COLUMN fingerprint TEXT',
        );
      }
      if (!_hasColumn(db, 'download_placement', 'page_order')) {
        db.execute(
          "ALTER TABLE download_placement ADD COLUMN page_order TEXT NOT NULL DEFAULT 'auto'",
        );
      }
      db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS download_placement_source_comic '
        'ON download_placement(source_id, comic_id)',
      );
      db.execute('''
        CREATE TABLE IF NOT EXISTS artifact_object (
          artifact_id TEXT NOT NULL PRIMARY KEY,
          path TEXT NOT NULL,
          bytes INTEGER NOT NULL,
          checksum TEXT NOT NULL,
          checksum_algorithm TEXT NOT NULL DEFAULT 'crc32',
          storage_root_id TEXT NOT NULL DEFAULT 'default',
          created_us INTEGER NOT NULL,
          touched_us INTEGER NOT NULL
        )
      ''');
      _backfillArtifactObjects(db);
      _migrateDownloadIdentityKeys(db);
      db.execute('PRAGMA user_version = 5');
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<CacheRec?> get(String key) async {
    final rows = _requireDb().select(
      'SELECT * FROM cache_entry WHERE key = ? LIMIT 1',
      <Object?>[key],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _read(rows.first);
  }

  @override
  Future<List<CacheRec>> list({CacheState? state}) async {
    final rows = state == null
        ? _requireDb().select(
            'SELECT * FROM cache_entry ORDER BY key',
          )
        : _requireDb().select(
            'SELECT * FROM cache_entry WHERE state = ? ORDER BY key',
            <Object?>[state.name],
          );
    return rows.map(_read).toList(growable: false);
  }

  @override
  Future<void> put(CacheRec rec) async {
    final db = _requireDb();
    final artifactId = rec.effectiveArtifactId;
    db.execute('BEGIN IMMEDIATE');
    try {
      _putArtifactObject(db, rec, artifactId);
      _putBinding(db, rec, artifactId);
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> remove(String key) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT artifact_id FROM cache_entry WHERE key = ? LIMIT 1',
        <Object?>[key],
      );
      db.execute(
        'DELETE FROM cache_entry WHERE key = ?',
        <Object?>[key],
      );
      if (rows.isNotEmpty) {
        final artifactId = rows.first['artifact_id'] as String?;
        if (artifactId != null && artifactId.isNotEmpty) {
          db.execute(
            'DELETE FROM artifact_object WHERE artifact_id = ? '
            'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?)',
            <Object?>[artifactId, artifactId],
          );
        }
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> replacePathBindings({
    required CacheRec record,
    required String path,
  }) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final removed = db.select(
        'SELECT artifact_id FROM cache_entry WHERE path = ? AND key != ?',
        <Object?>[path, record.key],
      );
      db.execute(
        'DELETE FROM cache_entry WHERE path = ? AND key != ?',
        <Object?>[path, record.key],
      );
      final artifactId = record.effectiveArtifactId;
      _putArtifactObject(db, record, artifactId);
      _putBinding(db, record, artifactId);
      for (final row in removed) {
        final removedId = row['artifact_id'] as String?;
        if (removedId != null && removedId.isNotEmpty) {
          db.execute(
            'DELETE FROM artifact_object WHERE artifact_id = ? '
            'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?)',
            <Object?>[removedId, removedId],
          );
        }
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> touch(String key, int touchedUs) async {
    _requireDb().execute(
      'UPDATE cache_entry SET touched_us = ? WHERE key = ?',
      <Object?>[touchedUs, key],
    );
  }

  @override
  Future<int> totalBytes({CacheState? state}) async {
    final rows = state == null
        ? _requireDb().select(
            'SELECT COALESCE(SUM(bytes), 0) AS total FROM cache_entry',
          )
        : _requireDb().select(
            'SELECT COALESCE(SUM(bytes), 0) AS total '
            'FROM cache_entry WHERE state = ?',
            <Object?>[state.name],
          );
    return rows.first['total']! as int;
  }

  @override
  Future<DownloadPlacement?> getPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final rows = _requireDb().select(
      'SELECT * FROM download_placement WHERE source_id = ? AND comic_id = ? LIMIT 1',
      <Object?>[sourceId, comicId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _readPlacement(rows.first);
  }

  @override
  Future<List<DownloadPlacement>> listPlacements() async {
    final rows = _requireDb().select(
      'SELECT * FROM download_placement ORDER BY created_at',
    );
    return rows.map(_readPlacement).toList(growable: false);
  }

  @override
  Future<void> putPlacement(DownloadPlacement placement) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      // The durable owner key is (source_id, comic_id), not placement_id.
      // Placement ids may change when a conflict is resolved or a new export
      // directory is allocated; mirror MemIndex's owner-key upsert semantics
      // instead of allowing the unique owner index to turn that normal update
      // into a constraint failure.
      final ownerRows = db.select(
        'SELECT * FROM download_placement WHERE source_id = ? AND comic_id = ? '
        'LIMIT 1',
        <Object?>[placement.sourceId, placement.comicId],
      );
      if (ownerRows.isNotEmpty) {
        final existing = _readPlacement(ownerRows.first);
        final staleGeneration = placement.generation < existing.generation;
        final conflictingEqualGeneration =
            placement.generation == existing.generation &&
                !_samePlacementBinding(placement, existing);
        if (staleGeneration || conflictingEqualGeneration) {
          throw StateError(
            'stale download placement commit for ${placement.ownerKey}',
          );
        }
        if (existing.placementId != placement.placementId) {
          db.execute(
            'DELETE FROM download_placement WHERE source_id = ? AND comic_id = ?',
            <Object?>[placement.sourceId, placement.comicId],
          );
        }
      }
      final placementRows = db.select(
        'SELECT source_id, comic_id FROM download_placement '
        'WHERE placement_id = ? LIMIT 1',
        <Object?>[placement.placementId],
      );
      if (placementRows.isNotEmpty &&
          ((placementRows.first['source_id'] as String) != placement.sourceId ||
              (placementRows.first['comic_id'] as String) != placement.comicId)) {
        throw StateError(
          'placement id is already owned by another download placement',
        );
      }
      db.execute('''
        INSERT INTO download_placement (
          placement_id, source_id, comic_id, comic_title, mode,
          relative_directory, storage_root_id, comic_family_id,
          observed_owner_key, generation, fingerprint, page_order, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(placement_id) DO UPDATE SET
          source_id = excluded.source_id,
          comic_id = excluded.comic_id,
          comic_title = excluded.comic_title,
          mode = excluded.mode,
          relative_directory = excluded.relative_directory,
          storage_root_id = excluded.storage_root_id,
          comic_family_id = excluded.comic_family_id,
          observed_owner_key = excluded.observed_owner_key,
          generation = excluded.generation,
          fingerprint = excluded.fingerprint,
          page_order = excluded.page_order,
          updated_at = excluded.updated_at
      ''', <Object?>[
        placement.placementId,
        placement.sourceId,
        placement.comicId,
        placement.comicTitle,
        placement.mode.name,
        placement.relativeDirectory,
        placement.storageRootId,
        placement.comicFamilyId,
        placement.observedOwnerKey,
        placement.generation,
        placement.fingerprint,
        placement.pageOrder.name,
        placement.createdAt.toUtc().toIso8601String(),
        placement.updatedAt.toUtc().toIso8601String(),
      ]);
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  bool _samePlacementBinding(
    DownloadPlacement first,
    DownloadPlacement second,
  ) =>
      first.sourceId == second.sourceId &&
      first.comicId == second.comicId &&
      first.comicTitle == second.comicTitle &&
      first.mode == second.mode &&
      first.relativeDirectory == second.relativeDirectory &&
      first.storageRootId == second.storageRootId &&
      first.comicFamilyId == second.comicFamilyId &&
      first.observedOwnerKey == second.observedOwnerKey &&
      first.pageOrder == second.pageOrder &&
      first.fingerprint == second.fingerprint;

  @override
  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  }) async {
    _requireDb().execute(
      'DELETE FROM download_placement WHERE source_id = ? AND comic_id = ?',
      <Object?>[sourceId, comicId],
    );
  }

  @override
  Future<void> close() async {
    _db?.dispose();
    _db = null;
  }

  sql.Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('cache index is not open');
    }
    return db;
  }

  void _putArtifactObject(
    sql.Database db,
    CacheRec record,
    String artifactId,
  ) {
    final existingReady = db.select(
      'SELECT key, bytes, checksum, checksum_algorithm '
      'FROM cache_entry WHERE artifact_id = ? AND key != ? '
      "AND state = 'ready'",
      <Object?>[artifactId, record.key],
    );
    for (final row in existingReady) {
      if (_artifactObjectDiffers(
        bytes: row['bytes']! as int,
        checksum: row['checksum']! as String,
        checksumAlgorithm: row['checksum_algorithm'] as String?,
        record: record,
      )) {
        throw StateError(
          'artifact identity $artifactId is already bound to different bytes',
        );
      }
    }
    db.execute('''
      INSERT INTO artifact_object (
        artifact_id, path, bytes, checksum, checksum_algorithm,
        storage_root_id, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(artifact_id) DO UPDATE SET
        path = excluded.path,
        bytes = excluded.bytes,
        checksum = excluded.checksum,
        checksum_algorithm = excluded.checksum_algorithm,
        storage_root_id = excluded.storage_root_id,
        touched_us = excluded.touched_us
    ''', <Object?>[
      artifactId,
      record.path,
      record.bytes,
      record.checksum,
      record.checksumAlgorithm,
      record.storageRootId,
      record.createdUs,
      record.touchedUs,
    ]);
  }

  void _putBinding(sql.Database db, CacheRec record, String artifactId) {
    db.execute('''
      INSERT INTO cache_entry (
        key, download_json, state, path, bytes, checksum, created_us, touched_us,
        pinned, checksum_algorithm, artifact_id, storage_root_id
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        download_json = excluded.download_json,
        state = excluded.state,
        path = excluded.path,
        bytes = excluded.bytes,
        checksum = excluded.checksum,
        created_us = excluded.created_us,
        touched_us = excluded.touched_us,
        pinned = excluded.pinned,
        checksum_algorithm = excluded.checksum_algorithm,
        artifact_id = excluded.artifact_id,
        storage_root_id = excluded.storage_root_id
    ''', <Object?>[
      record.key,
      jsonEncode(record.id.toJson()),
      record.state.name,
      record.path,
      record.bytes,
      record.checksum,
      record.createdUs,
      record.touchedUs,
      record.pinned ? 1 : 0,
      record.checksumAlgorithm,
      artifactId,
      record.storageRootId,
    ]);
  }

  CacheRec _read(sql.Row row) {
    final decoded = jsonDecode(row['download_json']! as String);
    if (decoded is! Map) {
      throw const FormatException('cached download identity is invalid');
    }
    return CacheRec.fromJson(<String, Object?>{
      'download': Map<String, Object?>.from(decoded),
      'state': row['state']! as String,
      'path': row['path']! as String,
      'bytes': row['bytes']! as int,
      'checksum': row['checksum']! as String,
      'createdUs': row['created_us']! as int,
      'touchedUs': row['touched_us']! as int,
      'pinned': row['pinned'] == 1,
      'checksumAlgorithm': (row['checksum_algorithm'] as String?) ?? 'crc32',
      'artifactId': (row['artifact_id'] as String?) ?? '',
      'storageRootId': (row['storage_root_id'] as String?) ?? 'default',
    });
  }

  DownloadPlacement _readPlacement(sql.Row row) {
    return DownloadPlacement(
      placementId: row['placement_id']! as String,
      sourceId: row['source_id']! as String,
      comicId: row['comic_id']! as String,
      comicTitle: row['comic_title']! as String,
      mode: DownloadPlacementMode.values.byName(row['mode']! as String),
      relativeDirectory: row['relative_directory']! as String,
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
      comicFamilyId: row['comic_family_id'] as String?,
      observedOwnerKey: row['observed_owner_key'] as String?,
      generation: (row['generation'] as int?) ?? 0,
      fingerprint: row['fingerprint'] as String?,
      pageOrder: ComicPageOrder.values.firstWhere(
        (p) => p.name == (row['page_order'] as String?),
        orElse: () => ComicPageOrder.auto,
      ),
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
    );
  }
}

void _migrateDownloadIdentityKeys(sql.Database db) {
  final rows = db.select('SELECT key, download_json FROM cache_entry');
  for (final row in rows) {
    final oldKey = row['key']! as String;
    final raw = row['download_json'];
    if (raw is! String) continue;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) continue;
      final id = DownloadId.fromJson(Map<String, Object?>.from(decoded));
      final newKey = id.key;
      if (newKey == oldKey) continue;
      final conflict = db.select(
        'SELECT download_json FROM cache_entry WHERE key = ? LIMIT 1',
        <Object?>[newKey],
      );
      if (conflict.isNotEmpty) {
        // A prior interrupted migration may already have installed the new
        // row. Only remove the legacy duplicate when it claims the same
        // identity; never resolve a genuine identity collision by overwriting
        // either binding.
        final conflictJson = conflict.first['download_json'];
        if (conflictJson == raw) {
          db.execute(
            'DELETE FROM cache_entry WHERE key = ?',
            <Object?>[oldKey],
          );
        }
        continue;
      }
      db.execute(
        'UPDATE cache_entry SET key = ? WHERE key = ?',
        <Object?>[newKey, oldKey],
      );
    } on FormatException {
      // A malformed legacy row remains available to the existing repair and
      // scanner paths; do not make an otherwise readable cache unopenable.
    } on TypeError {
      // Same compatibility rule for partially written legacy JSON.
    }
  }
}

bool _artifactObjectDiffers({
  required int bytes,
  required String checksum,
  required String? checksumAlgorithm,
  required CacheRec record,
}) {
  if (bytes != record.bytes) return true;
  final leftChecksum = checksum.trim().toLowerCase();
  final rightChecksum = record.checksum.trim().toLowerCase();
  if (leftChecksum.isNotEmpty &&
      rightChecksum.isNotEmpty &&
      leftChecksum != rightChecksum) {
    return true;
  }
  final leftAlgorithm = (checksumAlgorithm ?? 'crc32').trim().toLowerCase();
  final rightAlgorithm = record.checksumAlgorithm.trim().toLowerCase();
  return leftAlgorithm != rightAlgorithm &&
      leftChecksum.isNotEmpty &&
      rightChecksum.isNotEmpty;
}

bool _hasColumn(sql.Database db, String table, String column) => db
    .select('PRAGMA table_info($table)')
    .any((row) => row['name'] == column);

void _backfillArtifactObjects(sql.Database db) {
  final rows = db.select(
    'SELECT key, path, bytes, checksum, checksum_algorithm, '
    'storage_root_id, created_us, touched_us, artifact_id '
    'FROM cache_entry',
  );
  for (final row in rows) {
    final current = row['artifact_id'] as String? ?? '';
    final artifactId = current.isEmpty
        ? defaultArtifactIdForPath(row['path']! as String)
        : current;
    if (current.isEmpty) {
      db.execute(
        'UPDATE cache_entry SET artifact_id = ? WHERE key = ?',
        <Object?>[artifactId, row['key']! as String],
      );
    }
    db.execute('''
      INSERT INTO artifact_object (
        artifact_id, path, bytes, checksum, checksum_algorithm,
        storage_root_id, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(artifact_id) DO NOTHING
    ''', <Object?>[
      artifactId,
      row['path']! as String,
      row['bytes']! as int,
      row['checksum']! as String,
      (row['checksum_algorithm'] as String?) ?? 'crc32',
      (row['storage_root_id'] as String?) ?? 'default',
      row['created_us']! as int,
      row['touched_us']! as int,
    ]);
  }
}
