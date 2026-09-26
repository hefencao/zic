import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'cache_index.dart';
import 'download_placement.dart';
import 'physical_media_artifact_index.dart';
import 'physical_media_projection_index.dart';
import 'physical_partial_index.dart';
import 'storage_root_access.dart';

part 'sqlite_artifact_read_worker.dart';
part 'sqlite_artifact_touch_worker.dart';

final class SqliteIndex
    implements
        CacheIndex,
        CacheBindingOperations,
        CachePathBindingQuery,
        CacheLogicalBindingQuery,
        StorageAccessAuthorityQuery,
        ArtifactPromotionIndex,
        PhysicalMediaArtifactIndex,
        PhysicalMediaProjectionIndex,
        PhysicalPartialIndex {
  SqliteIndex(this.path);

  SqliteIndex.memory() : path = null;

  static const int _schemaVersion = 20;
  static const _replicaLocatorIndexSql =
      'CREATE INDEX IF NOT EXISTS artifact_replica_access_locator '
      'ON artifact_replica(access_locator)';

  final String? path;
  sql.Database? _db;
  Map<String, CacheRec>? _cachedEntries;
  Future<_SqliteArtifactReadWorker>? _artifactReadWorker;
  Future<_SqliteArtifactTouchWorker>? _artifactTouchWorker;

  void _invalidateCache() {
    _cachedEntries = null;
  }

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
    db.execute('PRAGMA busy_timeout = 5000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > _schemaVersion) {
      throw StateError('unsupported cache schema version: $version');
    }
    // Schema/data migrations are one-time work. Re-running every historical
    // backfill on every process start turns Reader-created cache rows into an
    // O(N) cold-start tax and also opens a write transaction before Home's
    // first frame. Version 10 records completion of the v1-v9 backfills.
    if (version == _schemaVersion) return;
    if (version >= 11) {
      db.execute('BEGIN IMMEDIATE');
      try {
        if (version < 19) {
          db.execute(
            'CREATE INDEX IF NOT EXISTS cache_entry_path '
            'ON cache_entry(path)',
          );
          _createPhysicalMediaTables(db);
          _ensureCacheLogicalIdentityColumns(db);
          _createStorageCleanupDebtTable(db);
          _createArtifactPromotionTable(db);
          _migrateLegacyLeadingSlashSafIdentity(db);
          if (version == 18) {
            _removeDeprecatedVolatilePagePhysicalBindings(db);
          }
        }
        // v19 -> v20 adds only an access path. Do not replay historical
        // identity backfills or rewrite body/replica authority on cold open.
        db.execute(_replicaLocatorIndexSql);
        db.execute('PRAGMA user_version = $_schemaVersion');
        db.execute('COMMIT');
      } on Object {
        db.execute('ROLLBACK');
        rethrow;
      }
      return;
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
            storage_root_id TEXT NOT NULL DEFAULT 'default',
            content_key TEXT NOT NULL DEFAULT '',
            source_revision TEXT NOT NULL DEFAULT ''
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
      db.execute(
        'CREATE INDEX IF NOT EXISTS cache_entry_path '
        'ON cache_entry(path)',
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
        CREATE TABLE IF NOT EXISTS export_page_binding (
          source_id TEXT NOT NULL,
          comic_id TEXT NOT NULL,
          chapter_id TEXT NOT NULL,
          page_id TEXT NOT NULL,
          logical_index INTEGER NOT NULL,
          export_ordinal INTEGER NOT NULL,
          placement_generation INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (source_id, comic_id, chapter_id, page_id),
          CHECK (logical_index >= 0),
          CHECK (export_ordinal > 0)
        )
      ''');
      db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS export_page_binding_ordinal '
        'ON export_page_binding(source_id, comic_id, chapter_id, export_ordinal)',
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
      db.execute('''
        CREATE TABLE IF NOT EXISTS artifact_replica (
          replica_id TEXT NOT NULL PRIMARY KEY,
          artifact_id TEXT NOT NULL,
          access_locator TEXT NOT NULL,
          storage_root_id TEXT NOT NULL DEFAULT 'default',
          created_us INTEGER NOT NULL,
          touched_us INTEGER NOT NULL,
          FOREIGN KEY (artifact_id) REFERENCES artifact_object(artifact_id) ON DELETE CASCADE,
          UNIQUE (artifact_id, access_locator, storage_root_id)
        )
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS artifact_replica_artifact '
        'ON artifact_replica(artifact_id, touched_us)',
      );
      db.execute(_replicaLocatorIndexSql);
      db.execute('''
        CREATE TABLE IF NOT EXISTS artifact_replica_migration (
          replica_id TEXT NOT NULL PRIMARY KEY,
          source_access_locator TEXT NOT NULL,
          source_storage_root_id TEXT NOT NULL,
          destination_access_locator TEXT NOT NULL,
          destination_storage_root_id TEXT NOT NULL,
          temporary_access_locator TEXT NOT NULL,
          phase TEXT NOT NULL,
          created_us INTEGER NOT NULL,
          touched_us INTEGER NOT NULL,
          FOREIGN KEY (replica_id) REFERENCES artifact_replica(replica_id) ON DELETE CASCADE,
          CHECK (phase IN ('copying', 'cleanupPending'))
        )
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS artifact_replica_migration_phase '
        'ON artifact_replica_migration(phase, touched_us)',
      );
      db.execute('''
        CREATE TABLE IF NOT EXISTS storage_root (
          root_id TEXT NOT NULL PRIMARY KEY,
          created_us INTEGER NOT NULL,
          touched_us INTEGER NOT NULL
        )
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS storage_access_locator (
          kind TEXT NOT NULL,
          locator TEXT NOT NULL,
          root_id TEXT NOT NULL,
          health TEXT NOT NULL DEFAULT 'unknown',
          verified_us INTEGER,
          touched_us INTEGER NOT NULL,
          PRIMARY KEY (kind, locator),
          FOREIGN KEY (root_id) REFERENCES storage_root(root_id) ON DELETE CASCADE,
          CHECK (kind IN ('direct', 'saf')),
          CHECK (health IN ('unknown', 'healthy', 'accessDenied'))
        )
      ''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS storage_access_locator_root '
        'ON storage_access_locator(root_id)',
      );
      _createPhysicalMediaTables(db);
      _createStorageCleanupDebtTable(db);
      _createArtifactPromotionTable(db);
      _backfillArtifactObjects(db);
      _backfillArtifactReplicas(db);
      _backfillStorageRootRegistry(db);
      _migrateLegacyLeadingSlashSafIdentity(db);
      _migrateDownloadIdentityKeys(db);
      _ensureCacheLogicalIdentityColumns(db);
      if (version < 11) {
        _migrateLegacyPinnedRetention(db);
      }
      db.execute('PRAGMA user_version = $_schemaVersion');
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<CacheRec?> get(String key) async {
    final cached = _cachedEntries;
    if (cached != null) {
      return cached[key];
    }
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
  Future<List<CacheRec>> getMany(Iterable<String> keys) async {
    final unique = keys.toSet().toList(growable: false);
    if (unique.isEmpty) return const <CacheRec>[];
    final cached = _cachedEntries;
    if (cached != null) {
      return <CacheRec>[
        for (final key in unique)
          if (cached[key] case final record?) record,
      ];
    }
    final db = _requireDb();
    final result = <CacheRec>[];
    const chunkSize = 400;
    for (var start = 0; start < unique.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, unique.length);
      final chunk = unique.sublist(start, end);
      final placeholders = List<String>.filled(chunk.length, '?').join(',');
      final rows = db.select(
        'SELECT * FROM cache_entry WHERE key IN ($placeholders)',
        <Object?>[...chunk],
      );
      result.addAll(rows.map(_read));
    }
    return result;
  }

  @override
  Future<List<CacheRec>> listLogicalBindings({
    required ContentId content,
    required String sourceRevision,
    CacheState? state,
  }) async {
    final cached = _cachedEntries;
    if (cached != null) {
      final records =
          cached.values
              .where(
                (record) =>
                    record.id.content == content &&
                    record.id.sourceRevision == sourceRevision &&
                    (state == null || record.state == state),
              )
              .toList(growable: false)
            ..sort((left, right) {
              final touched = right.touchedUs.compareTo(left.touchedUs);
              return touched != 0 ? touched : left.key.compareTo(right.key);
            });
      return records;
    }
    final db = _requireDb();
    final rows = state == null
        ? db.select(
            'SELECT * FROM cache_entry '
            'WHERE content_key = ? AND source_revision = ? '
            'ORDER BY touched_us DESC, key',
            <Object?>[content.key, sourceRevision],
          )
        : db.select(
            'SELECT * FROM cache_entry '
            'WHERE content_key = ? AND source_revision = ? AND state = ? '
            'ORDER BY touched_us DESC, key',
            <Object?>[content.key, sourceRevision, state.name],
          );
    return rows.map(_read).toList(growable: false);
  }

  Future<ArtifactObjectRecord?> getArtifactObject(String artifactId) async {
    final normalized = artifactId.trim();
    if (normalized.isEmpty) return null;
    final rows = _requireDb().select(
      'SELECT artifact_id, path, bytes, checksum, checksum_algorithm, '
      'storage_root_id '
      'FROM artifact_object WHERE artifact_id = ? LIMIT 1',
      <Object?>[normalized],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ArtifactObjectRecord(
      artifactId: row['artifact_id']! as String,
      accessLocator: row['path']! as String,
      bytes: row['bytes']! as int,
      checksum: row['checksum']! as String,
      checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
    );
  }

  Future<List<ArtifactReplicaRecord>> listArtifactReplicas(
    String artifactId,
  ) async {
    final normalized = artifactId.trim();
    if (normalized.isEmpty) return const <ArtifactReplicaRecord>[];
    final rows = _requireDb().select(
      'SELECT replica_id, artifact_id, access_locator, storage_root_id, '
      'created_us, touched_us FROM artifact_replica WHERE artifact_id = ? '
      'ORDER BY touched_us DESC, replica_id',
      <Object?>[normalized],
    );
    return rows
        .map(
          (row) => ArtifactReplicaRecord(
            replicaId: row['replica_id']! as String,
            artifactId: row['artifact_id']! as String,
            accessLocator: row['access_locator']! as String,
            storageRootId: (row['storage_root_id'] as String?) ?? 'default',
            createdUs: row['created_us']! as int,
            touchedUs: row['touched_us']! as int,
          ),
        )
        .toList(growable: false);
  }

  /// Reads immutable artifact/replica/root authority on a dedicated SQLite
  /// read connection when this index is file-backed.
  ///
  /// The worker never mutates durable state and therefore is not a second
  /// storage owner. It exists so Reader materialization does not execute
  /// sqlite3 prepare/step on the UI isolate. In-memory indexes keep the direct
  /// path used by unit tests because their database cannot be shared by path.
  Future<ArtifactAuthorityReadSnapshot> readArtifactAuthorityInBackground(
    String artifactId,
  ) async {
    final normalized = artifactId.trim();
    if (normalized.isEmpty) {
      return const ArtifactAuthorityReadSnapshot(
        object: null,
        replicas: <ArtifactReplicaRecord>[],
        storageRootsByIdentity: <String, StorageRootRecord>{},
      );
    }
    final dbPath = path;
    if (dbPath == null) {
      return _readArtifactAuthoritySnapshot(_requireDb(), normalized);
    }
    try {
      final worker = await _artifactReadWorkerFor(dbPath);
      return await worker.read(normalized);
    } on Object {
      // The worker is an execution optimization, not durable authority. A
      // startup/read failure must not make a valid artifact unreadable.
      return _readArtifactAuthoritySnapshot(_requireDb(), normalized);
    }
  }

  Future<_SqliteArtifactReadWorker> _artifactReadWorkerFor(String dbPath) {
    final existing = _artifactReadWorker;
    if (existing != null) return existing;
    final created = _SqliteArtifactReadWorker.spawn(dbPath);
    _artifactReadWorker = created;
    unawaited(created.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        if (identical(_artifactReadWorker, created)) {
          _artifactReadWorker = null;
        }
      },
    ));
    return created;
  }

  Future<ArtifactReplicaRecord?> getArtifactReplica(String replicaId) async {
    final normalized = replicaId.trim();
    if (normalized.isEmpty) return null;
    final rows = _requireDb().select(
      'SELECT replica_id, artifact_id, access_locator, storage_root_id, '
      'created_us, touched_us FROM artifact_replica WHERE replica_id = ? '
      'LIMIT 1',
      <Object?>[normalized],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ArtifactReplicaRecord(
      replicaId: row['replica_id']! as String,
      artifactId: row['artifact_id']! as String,
      accessLocator: row['access_locator']! as String,
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
      createdUs: row['created_us']! as int,
      touchedUs: row['touched_us']! as int,
    );
  }

  Future<List<ArtifactReplicaRecord>> listArtifactReplicasForStorageRoot(
    String storageRootId,
  ) async {
    final normalized = storageRootId.trim();
    if (normalized.isEmpty) return const <ArtifactReplicaRecord>[];
    final rows = _requireDb().select(
      'SELECT replica_id, artifact_id, access_locator, storage_root_id, '
      'created_us, touched_us FROM artifact_replica WHERE storage_root_id = ? '
      'ORDER BY touched_us DESC, replica_id',
      <Object?>[normalized],
    );
    return rows
        .map(
          (row) => ArtifactReplicaRecord(
            replicaId: row['replica_id']! as String,
            artifactId: row['artifact_id']! as String,
            accessLocator: row['access_locator']! as String,
            storageRootId: (row['storage_root_id'] as String?) ?? 'default',
            createdUs: row['created_us']! as int,
            touchedUs: row['touched_us']! as int,
          ),
        )
        .toList(growable: false);
  }

  Future<ArtifactReplicaRecord?> artifactReplicaForAccessLocator(
    String accessLocator,
  ) async {
    final normalized = accessLocator.trim();
    if (normalized.isEmpty) return null;
    final rows = _requireDb().select(
      'SELECT replica_id, artifact_id, access_locator, storage_root_id, '
      'created_us, touched_us FROM artifact_replica WHERE access_locator = ? '
      'LIMIT 1',
      <Object?>[normalized],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ArtifactReplicaRecord(
      replicaId: row['replica_id']! as String,
      artifactId: row['artifact_id']! as String,
      accessLocator: row['access_locator']! as String,
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
      createdUs: row['created_us']! as int,
      touchedUs: row['touched_us']! as int,
    );
  }

  Future<void> putStorageCleanupDebt(StorageCleanupDebtRecord record) async {
    final locator = record.accessLocator.trim();
    final root = record.storageRootId.trim();
    final kind = record.kind;
    if (locator.isEmpty) {
      throw ArgumentError('cleanup debt requires an exact storage locator');
    }
    final expectedChecksum = record.expectedChecksum?.trim().toLowerCase();
    final expectedAlgorithm =
        record.expectedChecksumAlgorithm?.trim().toLowerCase();
    if (kind != StorageCleanupDebtKind.temporary &&
        ((record.expectedBytes ?? 0) <= 0 ||
            expectedChecksum == null ||
            expectedChecksum.isEmpty ||
            expectedAlgorithm == null ||
            expectedAlgorithm.isEmpty)) {
      throw ArgumentError(
        'obsolete cleanup debt requires exact content proof',
      );
    }
    final effectiveRoot = root.isEmpty ? 'default' : root;
    _requireDb().execute(
      'INSERT INTO storage_cleanup_debt '
      '(access_locator, storage_root_id, kind, created_us, touched_us, '
      'expected_bytes, expected_checksum, expected_checksum_algorithm) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(access_locator) DO UPDATE SET '
      'storage_root_id = excluded.storage_root_id, kind = excluded.kind, '
      'touched_us = excluded.touched_us, expected_bytes = excluded.expected_bytes, '
      'expected_checksum = excluded.expected_checksum, '
      'expected_checksum_algorithm = excluded.expected_checksum_algorithm',
      <Object?>[
        locator,
        effectiveRoot,
        kind.name,
        record.createdUs,
        record.touchedUs,
        record.expectedBytes,
        expectedChecksum,
        expectedAlgorithm,
      ],
    );
  }

  Future<List<StorageCleanupDebtRecord>> listStorageCleanupDebts() async {
    final rows = _requireDb().select(
      'SELECT access_locator, storage_root_id, kind, created_us, touched_us, '
      'expected_bytes, expected_checksum, expected_checksum_algorithm '
      'FROM storage_cleanup_debt ORDER BY touched_us, access_locator',
    );
    return rows
        .map(
          (row) => StorageCleanupDebtRecord(
            accessLocator: row['access_locator']! as String,
            storageRootId: (row['storage_root_id'] as String?) ?? 'default',
            kind: StorageCleanupDebtKind.values.byName(row['kind']! as String),
            createdUs: row['created_us']! as int,
            touchedUs: row['touched_us']! as int,
            expectedBytes: row['expected_bytes'] as int?,
            expectedChecksum: row['expected_checksum'] as String?,
            expectedChecksumAlgorithm:
                row['expected_checksum_algorithm'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Future<void> removeStorageCleanupDebt(String accessLocator) async {
    final locator = accessLocator.trim();
    if (locator.isEmpty) return;
    _requireDb().execute(
      'DELETE FROM storage_cleanup_debt WHERE access_locator = ?',
      <Object?>[locator],
    );
  }

  @override
  Future<ArtifactPromotionRecord> beginArtifactPromotion({
    required DownloadId id,
    required PhysicalMediaId physicalId,
    required String sourceAccessLocator,
    required String destinationAccessLocator,
    required int bytes,
    required String checksum,
    required String storageRootId,
  }) async {
    final source = sourceAccessLocator.trim();
    final destination = destinationAccessLocator.trim();
    final normalizedChecksum = checksum.trim().toLowerCase();
    final effectiveRoot = storageRootId.trim().isEmpty
        ? 'default'
        : storageRootId.trim();
    if (source.isEmpty ||
        destination.isEmpty ||
        source == destination ||
        bytes <= 0 ||
        normalizedChecksum.isEmpty) {
      throw ArgumentError(
        'artifact promotion requires sealed source/destination proof',
      );
    }
    final promotionKey = physicalId.key;
    final bindPhysical = !physicalId.isExactFallback;
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final existingPromotion = db.select(
        'SELECT * FROM artifact_promotion WHERE promotion_key = ? LIMIT 1',
        <Object?>[promotionKey],
      );
      if (existingPromotion.isNotEmpty) {
        final record = _readArtifactPromotion(existingPromotion.first);
        if (record.id != id ||
            record.physicalId != (bindPhysical ? physicalId : null) ||
            record.sourceAccessLocator != source ||
            record.destinationAccessLocator != destination ||
            record.bytes != bytes ||
            record.checksum.trim().toLowerCase() != normalizedChecksum ||
            record.storageRootId != effectiveRoot) {
          throw StateError(
            'artifact promotion already exists with different transaction state',
          );
        }
        db.execute('COMMIT');
        return record;
      }

      String checksumAlgorithm;
      int sourceCreatedUs;
      if (bindPhysical) {
        final rows = db.select(
          'SELECT * FROM physical_partial WHERE physical_key = ? LIMIT 1',
          <Object?>[physicalId.key],
        );
        if (rows.isEmpty) {
          throw StateError('sealed physical partial authority is missing');
        }
        final partial = _readPhysicalPartial(rows.first);
        if (partial.id != physicalId ||
            partial.path != source ||
            partial.bytes != bytes ||
            partial.checksum.trim().toLowerCase() != normalizedChecksum) {
          throw StateError(
            'sealed physical partial proof changed before promotion',
          );
        }
        checksumAlgorithm = partial.checksumAlgorithm.trim().toLowerCase();
        sourceCreatedUs = partial.createdUs;
      } else {
        final rows = db.select(
          "SELECT * FROM cache_entry WHERE key = ? AND state = 'partial' LIMIT 1",
          <Object?>[id.key],
        );
        if (rows.isEmpty) {
          throw StateError('sealed exact partial authority is missing');
        }
        final partial = _read(rows.first);
        if (partial.id != id ||
            partial.path != source ||
            partial.bytes != bytes ||
            partial.checksum.trim().toLowerCase() != normalizedChecksum) {
          throw StateError(
            'sealed exact partial proof changed before promotion',
          );
        }
        checksumAlgorithm = partial.checksumAlgorithm.trim().toLowerCase();
        sourceCreatedUs = partial.createdUs;
      }
      if (checksumAlgorithm.isEmpty) checksumAlgorithm = 'crc32';

      final exactRows = db.select(
        'SELECT * FROM cache_entry WHERE key = ? LIMIT 1',
        <Object?>[id.key],
      );
      final existingExact = exactRows.isEmpty ? null : _read(exactRows.first);
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      final artifactId = existingExact != null &&
              existingExact.state == CacheState.ready &&
              existingExact.path == destination &&
              existingExact.artifactId.isNotEmpty
          ? existingExact.artifactId
          : defaultArtifactIdForPath(destination);
      final record = ArtifactPromotionRecord(
        promotionKey: promotionKey,
        id: id,
        physicalId: bindPhysical ? physicalId : null,
        sourceAccessLocator: source,
        destinationAccessLocator: destination,
        bytes: bytes,
        checksum: normalizedChecksum,
        checksumAlgorithm: checksumAlgorithm,
        artifactId: artifactId,
        storageRootId: effectiveRoot,
        createdUs: existingExact?.createdUs ?? sourceCreatedUs,
        touchedUs: now,
        pinned: existingExact?.pinned ?? false,
      );
      _ensureStorageRootLocator(db, effectiveRoot, touchedUs: now);
      db.execute(
        'INSERT INTO artifact_promotion '
        '(promotion_key, download_json, physical_json, source_access_locator, '
        'destination_access_locator, bytes, checksum, checksum_algorithm, '
        'artifact_id, storage_root_id, created_us, touched_us, pinned) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          record.promotionKey,
          jsonEncode(record.id.toJson()),
          record.physicalId == null
              ? null
              : jsonEncode(record.physicalId!.toJson()),
          record.sourceAccessLocator,
          record.destinationAccessLocator,
          record.bytes,
          record.checksum,
          record.checksumAlgorithm,
          record.artifactId,
          record.storageRootId,
          record.createdUs,
          record.touchedUs,
          record.pinned ? 1 : 0,
        ],
      );
      db.execute('COMMIT');
      return record;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<ArtifactPromotionRecord>> listArtifactPromotions() async =>
      _requireDb()
          .select(
            'SELECT * FROM artifact_promotion ORDER BY touched_us, promotion_key',
          )
          .map(_readArtifactPromotion)
          .toList(growable: false);

  @override
  Future<CacheRec> commitArtifactPromotion(String promotionKey) async {
    final normalized = promotionKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('artifact promotion key must not be empty');
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT * FROM artifact_promotion WHERE promotion_key = ? LIMIT 1',
        <Object?>[normalized],
      );
      if (rows.isEmpty) {
        throw StateError('artifact promotion transaction does not exist');
      }
      final promotion = _readArtifactPromotion(rows.first);
      final collision = db.select(
        'SELECT replica_id FROM artifact_replica WHERE access_locator = ? '
        'AND artifact_id != ? LIMIT 1',
        <Object?>[
          promotion.destinationAccessLocator,
          promotion.artifactId,
        ],
      );
      if (collision.isNotEmpty) {
        throw StateError(
          'artifact promotion destination belongs to another replica',
        );
      }
      final ready = CacheRec(
        id: promotion.id,
        state: CacheState.ready,
        path: promotion.destinationAccessLocator,
        bytes: promotion.bytes,
        checksum: promotion.checksum,
        createdUs: promotion.createdUs,
        touchedUs: promotion.touchedUs,
        pinned: promotion.pinned,
        checksumAlgorithm: promotion.checksumAlgorithm,
        artifactId: promotion.artifactId,
        storageRootId: promotion.storageRootId,
      );
      _putArtifactObject(db, ready, promotion.artifactId);
      _putBinding(db, ready, promotion.artifactId);
      final physicalId = promotion.physicalId;
      if (physicalId != null) {
        db.execute(
          '''
          INSERT INTO physical_media_artifact (
            physical_key, physical_json, artifact_id, created_us, touched_us
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(physical_key) DO UPDATE SET
            physical_json = excluded.physical_json,
            artifact_id = excluded.artifact_id,
            created_us = excluded.created_us,
            touched_us = excluded.touched_us
          ''',
          <Object?>[
            physicalId.key,
            jsonEncode(physicalId.toJson()),
            promotion.artifactId,
            promotion.createdUs,
            promotion.touchedUs,
          ],
        );
        db.execute(
          'DELETE FROM physical_partial WHERE physical_key = ?',
          <Object?>[physicalId.key],
        );
      }
      db.execute(
        'DELETE FROM artifact_promotion WHERE promotion_key = ?',
        <Object?>[normalized],
      );
      db.execute('COMMIT');
      final cached = _cachedEntries;
      if (cached != null) cached[ready.key] = ready;
      return ready;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> removeArtifactPromotion(String promotionKey) async {
    final normalized = promotionKey.trim();
    if (normalized.isEmpty) return;
    _requireDb().execute(
      'DELETE FROM artifact_promotion WHERE promotion_key = ?',
      <Object?>[normalized],
    );
  }

  /// Returns whether [accessLocator] still names durable body/progress
  /// authority. Compatibility READY binding/object paths are intentionally
  /// excluded: schema-8 [artifact_replica] is the sealed-body authority.
  @override
  Future<bool> isStorageAccessLocatorAuthoritative(String accessLocator) async {
    final locator = accessLocator.trim();
    if (locator.isEmpty) return false;
    final db = _requireDb();
    if (db.select(
      "SELECT 1 FROM cache_entry WHERE state = 'partial' AND path = ? LIMIT 1",
      <Object?>[locator],
    ).isNotEmpty) {
      return true;
    }
    if (db.select(
      'SELECT 1 FROM physical_partial WHERE path = ? LIMIT 1',
      <Object?>[locator],
    ).isNotEmpty) {
      return true;
    }
    if (db.select(
      'SELECT 1 FROM artifact_replica WHERE access_locator = ? LIMIT 1',
      <Object?>[locator],
    ).isNotEmpty) {
      return true;
    }
    if (db.select(
      'SELECT 1 FROM artifact_promotion WHERE source_access_locator = ? '
      'OR destination_access_locator = ? LIMIT 1',
      <Object?>[locator, locator],
    ).isNotEmpty) {
      return true;
    }
    return db.select(
      'SELECT 1 FROM artifact_replica_migration WHERE '
      "(phase = 'copying' AND (source_access_locator = ? OR "
      'destination_access_locator = ? OR temporary_access_locator = ?)) OR '
      "(phase = 'cleanupPending' AND destination_access_locator = ?) LIMIT 1",
      <Object?>[locator, locator, locator, locator],
    ).isNotEmpty;
  }

  Future<ArtifactReplicaMigrationRecord?> getArtifactReplicaMigration(
    String replicaId,
  ) async {
    final normalized = replicaId.trim();
    if (normalized.isEmpty) return null;
    final rows = _requireDb().select(
      'SELECT replica_id, source_access_locator, source_storage_root_id, '
      'destination_access_locator, destination_storage_root_id, '
      'temporary_access_locator, phase, created_us, touched_us '
      'FROM artifact_replica_migration WHERE replica_id = ? LIMIT 1',
      <Object?>[normalized],
    );
    if (rows.isEmpty) return null;
    return _readArtifactReplicaMigration(rows.first);
  }

  Future<List<ArtifactReplicaMigrationRecord>> listArtifactReplicaMigrations({
    ArtifactReplicaMigrationPhase? phase,
  }) async {
    final rows = phase == null
        ? _requireDb().select(
            'SELECT replica_id, source_access_locator, source_storage_root_id, '
            'destination_access_locator, destination_storage_root_id, '
            'temporary_access_locator, phase, created_us, touched_us '
            'FROM artifact_replica_migration ORDER BY touched_us, replica_id',
          )
        : _requireDb().select(
            'SELECT replica_id, source_access_locator, source_storage_root_id, '
            'destination_access_locator, destination_storage_root_id, '
            'temporary_access_locator, phase, created_us, touched_us '
            'FROM artifact_replica_migration WHERE phase = ? '
            'ORDER BY touched_us, replica_id',
            <Object?>[phase.name],
          );
    return rows.map(_readArtifactReplicaMigration).toList(growable: false);
  }

  Future<List<ArtifactReplicaMigrationRecord>>
      listArtifactReplicaMigrationsForArtifact(String artifactId) async {
    final normalized = artifactId.trim();
    if (normalized.isEmpty) {
      return const <ArtifactReplicaMigrationRecord>[];
    }
    final rows = _requireDb().select(
      'SELECT m.replica_id, m.source_access_locator, '
      'm.source_storage_root_id, m.destination_access_locator, '
      'm.destination_storage_root_id, m.temporary_access_locator, m.phase, '
      'm.created_us, m.touched_us FROM artifact_replica_migration m '
      'JOIN artifact_replica r ON r.replica_id = m.replica_id '
      'WHERE r.artifact_id = ? ORDER BY m.touched_us, m.replica_id',
      <Object?>[normalized],
    );
    return rows.map(_readArtifactReplicaMigration).toList(growable: false);
  }

  Future<ArtifactReplicaMigrationRecord> beginArtifactReplicaMigration({
    required String replicaId,
    required String sourceAccessLocator,
    required String sourceStorageRootId,
    required String destinationAccessLocator,
    required String destinationStorageRootId,
    required String temporaryAccessLocator,
    required int touchedUs,
  }) async {
    final db = _requireDb();
    final normalizedReplicaId = replicaId.trim();
    final sourceLocator = sourceAccessLocator.trim();
    final sourceRoot = sourceStorageRootId.trim();
    final destinationLocator = destinationAccessLocator.trim();
    final destinationRoot = destinationStorageRootId.trim();
    final temporaryLocator = temporaryAccessLocator.trim();
    if (normalizedReplicaId.isEmpty ||
        sourceLocator.isEmpty ||
        destinationLocator.isEmpty ||
        temporaryLocator.isEmpty) {
      throw ArgumentError('replica migration identities must not be empty');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final existing = db.select(
        'SELECT replica_id, source_access_locator, source_storage_root_id, '
        'destination_access_locator, destination_storage_root_id, '
        'temporary_access_locator, phase, created_us, touched_us '
        'FROM artifact_replica_migration WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (existing.isNotEmpty) {
        final record = _readArtifactReplicaMigration(existing.first);
        if (record.phase != ArtifactReplicaMigrationPhase.copying ||
            record.sourceAccessLocator != sourceLocator ||
            record.sourceStorageRootId !=
                (sourceRoot.isEmpty ? 'default' : sourceRoot) ||
            record.destinationAccessLocator != destinationLocator ||
            record.destinationStorageRootId !=
                (destinationRoot.isEmpty ? 'default' : destinationRoot) ||
            record.temporaryAccessLocator != temporaryLocator) {
          throw StateError(
            'replica migration already exists with a different durable state',
          );
        }
        db.execute('COMMIT');
        return record;
      }
      final replicas = db.select(
        'SELECT access_locator, storage_root_id FROM artifact_replica '
        'WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (replicas.isEmpty) {
        throw StateError(
          'artifact replica $normalizedReplicaId does not exist',
        );
      }
      final replica = replicas.first;
      final effectiveSourceRoot = sourceRoot.isEmpty ? 'default' : sourceRoot;
      if (replica['access_locator'] != sourceLocator ||
          ((replica['storage_root_id'] as String?) ?? 'default') !=
              effectiveSourceRoot) {
        throw StateError(
          'replica source authority changed before migration began',
        );
      }
      final effectiveDestinationRoot = destinationRoot.isEmpty
          ? 'default'
          : destinationRoot;
      db.execute(
        'INSERT INTO artifact_replica_migration '
        '(replica_id, source_access_locator, source_storage_root_id, '
        'destination_access_locator, destination_storage_root_id, '
        'temporary_access_locator, phase, created_us, touched_us) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          normalizedReplicaId,
          sourceLocator,
          effectiveSourceRoot,
          destinationLocator,
          effectiveDestinationRoot,
          temporaryLocator,
          ArtifactReplicaMigrationPhase.copying.name,
          touchedUs,
          touchedUs,
        ],
      );
      db.execute('COMMIT');
      return ArtifactReplicaMigrationRecord(
        replicaId: normalizedReplicaId,
        sourceAccessLocator: sourceLocator,
        sourceStorageRootId: effectiveSourceRoot,
        destinationAccessLocator: destinationLocator,
        destinationStorageRootId: effectiveDestinationRoot,
        temporaryAccessLocator: temporaryLocator,
        phase: ArtifactReplicaMigrationPhase.copying,
        createdUs: touchedUs,
        touchedUs: touchedUs,
      );
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<ArtifactReplicaMigrationRecord>
      rebindCopyingArtifactReplicaMigration({
    required String replicaId,
    required String expectedDestinationAccessLocator,
    required String expectedTemporaryAccessLocator,
    required String destinationAccessLocator,
    required String destinationStorageRootId,
    required String temporaryAccessLocator,
    required int touchedUs,
  }) async {
    final normalizedReplicaId = replicaId.trim();
    final expectedDestination = expectedDestinationAccessLocator.trim();
    final expectedTemporary = expectedTemporaryAccessLocator.trim();
    final destination = destinationAccessLocator.trim();
    final destinationRoot = destinationStorageRootId.trim();
    final temporary = temporaryAccessLocator.trim();
    if (normalizedReplicaId.isEmpty ||
        expectedDestination.isEmpty ||
        expectedTemporary.isEmpty ||
        destination.isEmpty ||
        temporary.isEmpty) {
      throw ArgumentError('replica migration rebind locators must not be empty');
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT replica_id, source_access_locator, source_storage_root_id, '
        'destination_access_locator, destination_storage_root_id, '
        'temporary_access_locator, phase, created_us, touched_us '
        'FROM artifact_replica_migration WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (rows.isEmpty) {
        throw StateError('artifact replica migration does not exist');
      }
      final current = _readArtifactReplicaMigration(rows.first);
      if (current.phase != ArtifactReplicaMigrationPhase.copying ||
          current.destinationAccessLocator != expectedDestination ||
          current.temporaryAccessLocator != expectedTemporary) {
        throw StateError('artifact replica migration changed before locator rebind');
      }
      final replicaRows = db.select(
        'SELECT access_locator, storage_root_id FROM artifact_replica '
        'WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (replicaRows.isEmpty ||
          replicaRows.first['access_locator'] != current.sourceAccessLocator ||
          ((replicaRows.first['storage_root_id'] as String?) ?? 'default') !=
              current.sourceStorageRootId) {
        throw StateError('replica source authority changed during migration rebind');
      }
      final collision = db.select(
        'SELECT replica_id FROM artifact_replica WHERE access_locator = ? '
        'AND replica_id != ? LIMIT 1',
        <Object?>[destination, normalizedReplicaId],
      );
      if (collision.isNotEmpty) {
        throw StateError(
          'artifact replica migration destination is owned by another replica',
        );
      }
      final effectiveRoot = destinationRoot.isEmpty ? 'default' : destinationRoot;
      _ensureStorageRootLocator(db, effectiveRoot, touchedUs: touchedUs);
      db.execute(
        'UPDATE artifact_replica_migration SET destination_access_locator = ?, '
        'destination_storage_root_id = ?, temporary_access_locator = ?, '
        'touched_us = ? WHERE replica_id = ? AND phase = ?',
        <Object?>[
          destination,
          effectiveRoot,
          temporary,
          touchedUs,
          normalizedReplicaId,
          ArtifactReplicaMigrationPhase.copying.name,
        ],
      );
      db.execute('COMMIT');
      return ArtifactReplicaMigrationRecord(
        replicaId: current.replicaId,
        sourceAccessLocator: current.sourceAccessLocator,
        sourceStorageRootId: current.sourceStorageRootId,
        destinationAccessLocator: destination,
        destinationStorageRootId: effectiveRoot,
        temporaryAccessLocator: temporary,
        phase: current.phase,
        createdUs: current.createdUs,
        touchedUs: touchedUs,
      );
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<ArtifactReplicaRecord> putArtifactReplica({
    required String artifactId,
    required String accessLocator,
    required String storageRootId,
    required int createdUs,
    required int touchedUs,
  }) async {
    final db = _requireDb();
    final normalizedArtifactId = artifactId.trim();
    final normalizedLocator = accessLocator.trim();
    final normalizedRoot = storageRootId.trim();
    if (normalizedArtifactId.isEmpty || normalizedLocator.isEmpty) {
      throw ArgumentError(
        'artifact replica identity and locator must not be empty',
      );
    }
    if (db.select(
      'SELECT 1 FROM artifact_object WHERE artifact_id = ? LIMIT 1',
      <Object?>[normalizedArtifactId],
    ).isEmpty) {
      throw StateError('artifact object $normalizedArtifactId does not exist');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final record = _putArtifactReplica(
        db,
        artifactId: normalizedArtifactId,
        accessLocator: normalizedLocator,
        storageRootId: normalizedRoot.isEmpty ? 'default' : normalizedRoot,
        createdUs: createdUs,
        touchedUs: touchedUs,
      );
      db.execute('COMMIT');
      return record;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> removeArtifactReplica(String replicaId) async {
    final normalized = replicaId.trim();
    if (normalized.isEmpty) return;
    _requireDb().execute(
      'DELETE FROM artifact_replica WHERE replica_id = ?',
      <Object?>[normalized],
    );
  }

  /// Moves one already-verified physical replica to a new locator/root without
  /// changing its replica identity. The destination bytes must be proven by
  /// the caller before this metadata transaction is committed.
  Future<ArtifactReplicaRecord> relocateArtifactReplica({
    required String replicaId,
    required String accessLocator,
    required String storageRootId,
    required int touchedUs,
  }) async {
    final db = _requireDb();
    final normalizedReplicaId = replicaId.trim();
    final normalizedLocator = accessLocator.trim();
    final normalizedRoot = storageRootId.trim();
    if (normalizedReplicaId.isEmpty || normalizedLocator.isEmpty) {
      throw ArgumentError(
        'replica identity and destination locator must not be empty',
      );
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT artifact_id, created_us FROM artifact_replica '
        'WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (rows.isEmpty) {
        throw StateError(
          'artifact replica $normalizedReplicaId does not exist',
        );
      }
      final artifactId = rows.first['artifact_id']! as String;
      final createdUs = rows.first['created_us']! as int;
      final effectiveRoot = normalizedRoot.isEmpty ? 'default' : normalizedRoot;
      final collision = db.select(
        'SELECT replica_id FROM artifact_replica WHERE access_locator = ? '
        'AND replica_id != ? LIMIT 1',
        <Object?>[normalizedLocator, normalizedReplicaId],
      );
      if (collision.isNotEmpty) {
        throw StateError(
          'artifact replica destination is already owned by another replica',
        );
      }
      _ensureStorageRootLocator(db, effectiveRoot, touchedUs: touchedUs);
      db.execute(
        'UPDATE artifact_replica SET access_locator = ?, storage_root_id = ?, '
        'touched_us = ? WHERE replica_id = ?',
        <Object?>[
          normalizedLocator,
          effectiveRoot,
          touchedUs,
          normalizedReplicaId,
        ],
      );
      if (normalizedReplicaId == artifactId) {
        // Replica one is also the compatibility locator mirror used by older
        // readers/tools. Keep those rows coherent without creating a second
        // physical-copy fact or manufacturing logical-cache recency.
        db.execute(
          'UPDATE artifact_object SET path = ?, storage_root_id = ?, '
          'touched_us = ? WHERE artifact_id = ?',
          <Object?>[normalizedLocator, effectiveRoot, touchedUs, artifactId],
        );
        db.execute(
          'UPDATE cache_entry SET path = ?, storage_root_id = ? '
          "WHERE artifact_id = ? AND state = 'ready'",
          <Object?>[normalizedLocator, effectiveRoot, artifactId],
        );
      }
      db.execute('COMMIT');
      _invalidateCache();
      return ArtifactReplicaRecord(
        replicaId: normalizedReplicaId,
        artifactId: artifactId,
        accessLocator: normalizedLocator,
        storageRootId: effectiveRoot,
        createdUs: createdUs,
        touchedUs: touchedUs,
      );
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Atomically moves replica authority to the durable migration destination
  /// and marks the old source as cleanup debt.
  Future<ArtifactReplicaRecord> commitArtifactReplicaMigration({
    required String replicaId,
    required int touchedUs,
  }) async {
    final db = _requireDb();
    final normalizedReplicaId = replicaId.trim();
    if (normalizedReplicaId.isEmpty) {
      throw ArgumentError('replica identity must not be empty');
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      final migrationRows = db.select(
        'SELECT replica_id, source_access_locator, source_storage_root_id, '
        'destination_access_locator, destination_storage_root_id, '
        'temporary_access_locator, phase, created_us, touched_us '
        'FROM artifact_replica_migration WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (migrationRows.isEmpty) {
        throw StateError('artifact replica migration does not exist');
      }
      final migration = _readArtifactReplicaMigration(migrationRows.first);
      if (migration.phase != ArtifactReplicaMigrationPhase.copying) {
        throw StateError('artifact replica migration is not in copying phase');
      }
      final rows = db.select(
        'SELECT artifact_id, access_locator, storage_root_id, created_us '
        'FROM artifact_replica WHERE replica_id = ? LIMIT 1',
        <Object?>[normalizedReplicaId],
      );
      if (rows.isEmpty) {
        throw StateError(
          'artifact replica $normalizedReplicaId does not exist',
        );
      }
      final current = rows.first;
      if (current['access_locator'] != migration.sourceAccessLocator ||
          ((current['storage_root_id'] as String?) ?? 'default') !=
              migration.sourceStorageRootId) {
        throw StateError('replica source authority changed during migration');
      }
      final artifactId = current['artifact_id']! as String;
      final createdUs = current['created_us']! as int;
      final collision = db.select(
        'SELECT replica_id FROM artifact_replica WHERE access_locator = ? '
        'AND replica_id != ? LIMIT 1',
        <Object?>[migration.destinationAccessLocator, normalizedReplicaId],
      );
      if (collision.isNotEmpty) {
        throw StateError(
          'artifact replica destination is already owned by another replica',
        );
      }
      _ensureStorageRootLocator(
        db,
        migration.destinationStorageRootId,
        touchedUs: touchedUs,
      );
      db.execute(
        'UPDATE artifact_replica SET access_locator = ?, storage_root_id = ?, '
        'touched_us = ? WHERE replica_id = ?',
        <Object?>[
          migration.destinationAccessLocator,
          migration.destinationStorageRootId,
          touchedUs,
          normalizedReplicaId,
        ],
      );
      if (normalizedReplicaId == artifactId) {
        db.execute(
          'UPDATE artifact_object SET path = ?, storage_root_id = ?, '
          'touched_us = ? WHERE artifact_id = ?',
          <Object?>[
            migration.destinationAccessLocator,
            migration.destinationStorageRootId,
            touchedUs,
            artifactId,
          ],
        );
        db.execute(
          'UPDATE cache_entry SET path = ?, storage_root_id = ? '
          "WHERE artifact_id = ? AND state = 'ready'",
          <Object?>[
            migration.destinationAccessLocator,
            migration.destinationStorageRootId,
            artifactId,
          ],
        );
      }
      db.execute(
        'UPDATE artifact_replica_migration SET phase = ?, touched_us = ? '
        'WHERE replica_id = ?',
        <Object?>[
          ArtifactReplicaMigrationPhase.cleanupPending.name,
          touchedUs,
          normalizedReplicaId,
        ],
      );
      db.execute('COMMIT');
      _invalidateCache();
      return ArtifactReplicaRecord(
        replicaId: normalizedReplicaId,
        artifactId: artifactId,
        accessLocator: migration.destinationAccessLocator,
        storageRootId: migration.destinationStorageRootId,
        createdUs: createdUs,
        touchedUs: touchedUs,
      );
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> finishArtifactReplicaMigrationCleanup(String replicaId) async {
    final normalized = replicaId.trim();
    if (normalized.isEmpty) return;
    _requireDb().execute(
      'DELETE FROM artifact_replica_migration '
      "WHERE replica_id = ? AND phase = 'cleanupPending'",
      <Object?>[normalized],
    );
  }

  Future<StorageRootRecord?> getStorageRoot(String rootIdOrLocator) async {
    final identity = rootIdOrLocator.trim();
    if (identity.isEmpty || identity == 'default') return null;
    final db = _requireDb();
    var rootId = identity;
    final byId = db.select(
      'SELECT root_id FROM storage_root WHERE root_id = ? LIMIT 1',
      <Object?>[identity],
    );
    if (byId.isEmpty) {
      final byLocator = db.select(
        'SELECT root_id FROM storage_access_locator WHERE locator = ? '
        "ORDER BY CASE kind WHEN 'direct' THEN 0 ELSE 1 END LIMIT 1",
        <Object?>[identity],
      );
      if (byLocator.isEmpty) return null;
      rootId = byLocator.first['root_id']! as String;
    }
    return _readStorageRoot(db, rootId);
  }

  Future<StorageRootRecord> registerStorageRootAccessAliasProof(
    StorageRootAccessAliasProof proof, {
    required int verifiedUs,
  }) async {
    if (verifiedUs < 0) {
      throw ArgumentError.value(
        verifiedUs,
        'verifiedUs',
        'must not be negative',
      );
    }
    final direct = proof.direct.path.trim();
    final saf = proof.saf.treeUri.trim();
    if (direct.isEmpty || saf.isEmpty) {
      throw ArgumentError('storage access locators must not be empty');
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      String? locatorRoot(StorageAccessLocatorKind kind, String locator) {
        final rows = db.select(
          'SELECT root_id FROM storage_access_locator '
          'WHERE kind = ? AND locator = ? LIMIT 1',
          <Object?>[kind.name, locator],
        );
        return rows.isEmpty ? null : rows.first['root_id']! as String;
      }

      bool rootExists(String rootId) => db.select(
            'SELECT 1 FROM storage_root WHERE root_id = ? LIMIT 1',
            <Object?>[rootId],
          ).isNotEmpty;

      final safRoot = locatorRoot(StorageAccessLocatorKind.saf, saf);
      final directRoot = locatorRoot(StorageAccessLocatorKind.direct, direct);
      final rootId =
          safRoot ??
          directRoot ??
          (rootExists(saf)
              ? saf
              : rootExists(direct)
              ? direct
              : saf);
      db.execute(
        'INSERT INTO storage_root (root_id, created_us, touched_us) '
        'VALUES (?, ?, ?) ON CONFLICT(root_id) DO UPDATE SET '
        'touched_us = excluded.touched_us',
        <Object?>[rootId, verifiedUs, verifiedUs],
      );

      final mergeRoots = <String>{
        if (safRoot != null) safRoot,
        if (directRoot != null) directRoot,
        if (rootExists(saf)) saf,
        if (rootExists(direct)) direct,
      }..remove(rootId);
      for (final oldRoot in mergeRoots) {
        db.execute(
          'UPDATE storage_access_locator SET root_id = ?, touched_us = ? '
          'WHERE root_id = ?',
          <Object?>[rootId, verifiedUs, oldRoot],
        );
        db.execute(
          'UPDATE artifact_replica SET storage_root_id = ? '
          'WHERE storage_root_id = ?',
          <Object?>[rootId, oldRoot],
        );
        db.execute(
          'UPDATE artifact_replica_migration SET source_storage_root_id = ? '
          'WHERE source_storage_root_id = ?',
          <Object?>[rootId, oldRoot],
        );
        db.execute(
          'UPDATE artifact_replica_migration SET destination_storage_root_id = ? '
          'WHERE destination_storage_root_id = ?',
          <Object?>[rootId, oldRoot],
        );
        db.execute('DELETE FROM storage_root WHERE root_id = ?', <Object?>[
          oldRoot,
        ]);
      }
      // A migration destination may name a not-yet-materialized root before
      // it has its own storage_root row. The alias proof itself is enough to
      // canonicalize those durable progress references; requiring the root to
      // have existed already would leave a migration split across two names
      // for the same physical directory.
      db.execute(
        'UPDATE artifact_replica_migration SET source_storage_root_id = ? '
        'WHERE source_storage_root_id = ? OR source_storage_root_id = ?',
        <Object?>[rootId, direct, saf],
      );
      db.execute(
        'UPDATE artifact_replica_migration SET destination_storage_root_id = ? '
        'WHERE destination_storage_root_id = ? OR destination_storage_root_id = ?',
        <Object?>[rootId, direct, saf],
      );

      void upsertLocator(StorageAccessLocatorKind kind, String locator) {
        db.execute(
          'INSERT INTO storage_access_locator '
          '(kind, locator, root_id, health, verified_us, touched_us) '
          "VALUES (?, ?, ?, 'healthy', ?, ?) "
          'ON CONFLICT(kind, locator) DO UPDATE SET '
          'root_id = excluded.root_id, health = excluded.health, '
          'verified_us = excluded.verified_us, touched_us = excluded.touched_us',
          <Object?>[kind.name, locator, rootId, verifiedUs, verifiedUs],
        );
      }

      upsertLocator(StorageAccessLocatorKind.direct, direct);
      upsertLocator(StorageAccessLocatorKind.saf, saf);
      db.execute('COMMIT');
      return _readStorageRoot(db, rootId)!;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> updateStorageAccessHealth({
    required StorageAccessLocatorKind kind,
    required String locator,
    required StorageAccessHealth health,
    required int touchedUs,
  }) async {
    final normalized = locator.trim();
    if (normalized.isEmpty) return;
    final db = _requireDb();
    final rows = db.select(
      'SELECT health FROM storage_access_locator '
      'WHERE kind = ? AND locator = ? LIMIT 1',
      <Object?>[kind.name, normalized],
    );
    if (rows.isEmpty || rows.first['health'] == health.name) return;
    db.execute(
      'UPDATE storage_access_locator SET health = ?, touched_us = ? '
      'WHERE kind = ? AND locator = ?',
      <Object?>[health.name, touchedUs, kind.name, normalized],
    );
  }

  @override
  Future<List<CacheRec>> list({CacheState? state}) async {
    final cached = _cachedEntries;
    if (cached != null) {
      if (state == null) {
        return cached.values.toList(growable: false);
      }
      return cached.values
          .where((rec) => rec.state == state)
          .toList(growable: false);
    }
    final rows = state == null
        ? _requireDb().select('SELECT * FROM cache_entry ORDER BY key')
        : _requireDb().select(
            'SELECT * FROM cache_entry WHERE state = ? ORDER BY key',
            <Object?>[state.name],
          );
    final list = rows.map(_read).toList(growable: false);
    if (state == null) {
      _cachedEntries = <String, CacheRec>{for (final rec in list) rec.key: rec};
    }
    return list;
  }

  @override
  Future<List<CacheRec>> listPathBindings(
    String path, {
    String? excludingKey,
  }) async {
    final db = _requireDb();
    final rows = excludingKey == null
        ? db.select(
            'SELECT * FROM cache_entry WHERE path = ? ORDER BY key',
            <Object?>[path],
          )
        : db.select(
            'SELECT * FROM cache_entry WHERE path = ? AND key != ? ORDER BY key',
            <Object?>[path, excludingKey],
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
      final cached = _cachedEntries;
      if (cached != null) {
        cached[rec.key] = rec.copyWith(artifactId: artifactId);
      }
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
      db.execute('DELETE FROM cache_entry WHERE key = ?', <Object?>[key]);
      if (rows.isNotEmpty) {
        final artifactId = rows.first['artifact_id'] as String?;
        if (artifactId != null && artifactId.isNotEmpty) {
          db.execute(
            'DELETE FROM artifact_object WHERE artifact_id = ? '
            'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?) '
            'AND NOT EXISTS (SELECT 1 FROM physical_media_artifact WHERE artifact_id = ?)',
            <Object?>[artifactId, artifactId, artifactId],
          );
        }
      }
      db.execute('COMMIT');
      final cached = _cachedEntries;
      if (cached != null) {
        cached.remove(key);
      }
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<PhysicalMediaArtifactRecord?> getPhysicalMediaArtifact(
    PhysicalMediaId id,
  ) async {
    final rows = _requireDb().select(
      '''
      SELECT p.physical_key, p.physical_json, p.artifact_id,
             p.created_us AS binding_created_us,
             p.touched_us AS binding_touched_us,
             o.path, o.bytes, o.checksum, o.checksum_algorithm,
             o.storage_root_id
      FROM physical_media_artifact p
      JOIN artifact_object o ON o.artifact_id = p.artifact_id
      WHERE p.physical_key = ?
      LIMIT 1
    ''',
      <Object?>[id.key],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final decoded = jsonDecode(row['physical_json']! as String);
    if (decoded is! Map) {
      throw const FormatException('physical artifact identity is invalid');
    }
    final storedId = PhysicalMediaId.fromJson(
      Map<String, Object?>.from(decoded),
    );
    if (storedId != id || row['physical_key']! as String != id.key) {
      throw const FormatException('physical artifact key/identity mismatch');
    }
    return PhysicalMediaArtifactRecord(
      id: storedId,
      artifactId: row['artifact_id']! as String,
      accessLocator: row['path']! as String,
      bytes: row['bytes']! as int,
      checksum: row['checksum']! as String,
      checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
      createdUs: row['binding_created_us']! as int,
      touchedUs: row['binding_touched_us']! as int,
    );
  }

  /// Atomically retires one canonical physical binding only when the exact
  /// physical generation is unchanged and no exact READY binding still owns
  /// the same immutable artifact. Maintenance uses this to close the window
  /// between its LRU snapshot and physical-row deletion without taking a
  /// process-global lock.
  Future<bool> removePhysicalMediaArtifactBindingForMaintenance({
    required PhysicalMediaId id,
    required String expectedArtifactId,
    required int expectedTouchedUs,
  }) async {
    final normalized = expectedArtifactId.trim();
    if (normalized.isEmpty) return false;
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT artifact_id, touched_us FROM physical_media_artifact '
        'WHERE physical_key = ? LIMIT 1',
        <Object?>[id.key],
      );
      if (rows.isEmpty ||
          rows.first['artifact_id'] != normalized ||
          rows.first['touched_us'] != expectedTouchedUs) {
        db.execute('COMMIT');
        return false;
      }
      final exact = db.select(
        "SELECT 1 FROM cache_entry WHERE artifact_id = ? AND state = 'ready' LIMIT 1",
        <Object?>[normalized],
      );
      if (exact.isNotEmpty) {
        db.execute('COMMIT');
        return false;
      }
      db.execute(
        'DELETE FROM physical_media_artifact '
        'WHERE physical_key = ? AND artifact_id = ? AND touched_us = ?',
        <Object?>[id.key, normalized, expectedTouchedUs],
      );
      db.execute(
        'DELETE FROM artifact_object WHERE artifact_id = ? '
        'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?) '
        'AND NOT EXISTS (SELECT 1 FROM physical_media_artifact WHERE artifact_id = ?)',
        <Object?>[normalized, normalized, normalized],
      );
      db.execute('COMMIT');
      return true;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<PhysicalMediaArtifactRecord>> listPhysicalMediaArtifacts() async {
    final rows = _requireDb().select('''
      SELECT p.physical_key, p.physical_json, p.artifact_id,
             p.created_us AS binding_created_us,
             p.touched_us AS binding_touched_us,
             o.path, o.bytes, o.checksum, o.checksum_algorithm,
             o.storage_root_id
      FROM physical_media_artifact p
      JOIN artifact_object o ON o.artifact_id = p.artifact_id
      ORDER BY p.physical_key
    ''');
    final records = <PhysicalMediaArtifactRecord>[];
    for (final row in rows) {
      final decoded = jsonDecode(row['physical_json']! as String);
      if (decoded is! Map) {
        throw const FormatException('physical artifact identity is invalid');
      }
      final id = PhysicalMediaId.fromJson(Map<String, Object?>.from(decoded));
      if (row['physical_key']! as String != id.key) {
        throw const FormatException('physical artifact key/identity mismatch');
      }
      records.add(
        PhysicalMediaArtifactRecord(
          id: id,
          artifactId: row['artifact_id']! as String,
          accessLocator: row['path']! as String,
          bytes: row['bytes']! as int,
          checksum: row['checksum']! as String,
          checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
          storageRootId: (row['storage_root_id'] as String?) ?? 'default',
          createdUs: row['binding_created_us']! as int,
          touchedUs: row['binding_touched_us']! as int,
        ),
      );
    }
    return records;
  }

  @override
  Future<void> putPhysicalMediaArtifactBinding({
    required PhysicalMediaId id,
    required String artifactId,
    required int createdUs,
    required int touchedUs,
  }) async {
    final normalized = artifactId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(artifactId, 'artifactId', 'must not be empty');
    }
    final db = _requireDb();
    if (db.select(
      'SELECT 1 FROM artifact_object WHERE artifact_id = ? LIMIT 1',
      <Object?>[normalized],
    ).isEmpty) {
      throw StateError('artifact identity $artifactId does not exist');
    }
    db.execute(
      '''
      INSERT INTO physical_media_artifact (
        physical_key, physical_json, artifact_id, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(physical_key) DO UPDATE SET
        physical_json = excluded.physical_json,
        artifact_id = excluded.artifact_id,
        created_us = excluded.created_us,
        touched_us = excluded.touched_us
    ''',
      <Object?>[
        id.key,
        jsonEncode(id.toJson()),
        normalized,
        createdUs,
        touchedUs,
      ],
    );
  }

  @override
  Future<void> touchPhysicalMediaArtifact(
    PhysicalMediaId id,
    int touchedUs,
  ) async {
    _requireDb().execute(
      'UPDATE physical_media_artifact SET touched_us = ? WHERE physical_key = ?',
      <Object?>[touchedUs, id.key],
    );
  }

  @override
  Future<void> removePhysicalMediaArtifactBinding(PhysicalMediaId id) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT artifact_id FROM physical_media_artifact WHERE physical_key = ? LIMIT 1',
        <Object?>[id.key],
      );
      db.execute(
        'DELETE FROM physical_media_artifact WHERE physical_key = ?',
        <Object?>[id.key],
      );
      if (rows.isNotEmpty) {
        final artifactId = rows.first['artifact_id']! as String;
        db.execute(
          'DELETE FROM artifact_object WHERE artifact_id = ? '
          'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?) '
          'AND NOT EXISTS (SELECT 1 FROM physical_media_artifact WHERE artifact_id = ?)',
          <Object?>[artifactId, artifactId, artifactId],
        );
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<PhysicalPartialRecord?> getPhysicalPartial(PhysicalMediaId id) async {
    final rows = _requireDb().select(
      'SELECT * FROM physical_partial WHERE physical_key = ? LIMIT 1',
      <Object?>[id.key],
    );
    if (rows.isEmpty) return null;
    final record = _readPhysicalPartial(rows.first);
    return record.id == id ? record : null;
  }

  @override
  Future<List<PhysicalPartialRecord>> listPhysicalPartials() async {
    final rows = _requireDb().select(
      'SELECT * FROM physical_partial ORDER BY physical_key',
    );
    return rows.map(_readPhysicalPartial).toList(growable: false);
  }

  @override
  Future<void> putPhysicalPartial(PhysicalPartialRecord record) async {
    if (record.path.isEmpty || record.bytes <= 0) {
      throw ArgumentError('physical partial path/bytes must be valid');
    }
    _requireDb().execute(
      '''
      INSERT INTO physical_partial (
        physical_key, physical_json, path, bytes, checksum,
        checksum_algorithm, storage_root_id, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(physical_key) DO UPDATE SET
        physical_json = excluded.physical_json,
        path = excluded.path,
        bytes = excluded.bytes,
        checksum = excluded.checksum,
        checksum_algorithm = excluded.checksum_algorithm,
        storage_root_id = excluded.storage_root_id,
        created_us = excluded.created_us,
        touched_us = excluded.touched_us
    ''',
      <Object?>[
        record.key,
        jsonEncode(record.id.toJson()),
        record.path,
        record.bytes,
        record.checksum,
        record.checksumAlgorithm,
        record.storageRootId,
        record.createdUs,
        record.touchedUs,
      ],
    );
  }

  @override
  Future<void> removePhysicalPartial(PhysicalMediaId id) async {
    _requireDb().execute(
      'DELETE FROM physical_partial WHERE physical_key = ?',
      <Object?>[id.key],
    );
  }

  @override
  Future<void> touchPhysicalPartial(PhysicalMediaId id, int touchedUs) async {
    _requireDb().execute(
      'UPDATE physical_partial SET touched_us = ? WHERE physical_key = ?',
      <Object?>[touchedUs, id.key],
    );
  }

  @override
  Future<PhysicalMediaProjectionRecord?> getPhysicalMediaProjection(
    String exactKey,
  ) async {
    final rows = _requireDb().select(
      'SELECT * FROM physical_media_projection WHERE exact_key = ? LIMIT 1',
      <Object?>[exactKey],
    );
    if (rows.isEmpty) return null;
    return _readPhysicalMediaProjection(rows.first);
  }

  @override
  Future<List<PhysicalMediaProjectionRecord>>
  listPhysicalMediaProjections() async {
    final rows = _requireDb().select(
      'SELECT * FROM physical_media_projection ORDER BY family_key, exact_key',
    );
    return rows.map(_readPhysicalMediaProjection).toList(growable: false);
  }

  @override
  Future<void> putPhysicalMediaProjection(
    PhysicalMediaProjectionRecord record,
  ) => putPhysicalMediaProjections(<PhysicalMediaProjectionRecord>[record]);

  @override
  Future<void> putPhysicalMediaProjections(
    Iterable<PhysicalMediaProjectionRecord> records,
  ) async {
    final values = records.toList(growable: false);
    if (values.isEmpty) return;
    for (final record in values) {
      if (record.exactKey.isEmpty ||
          record.familyKey.isEmpty ||
          record.projectionJson.isEmpty) {
        throw ArgumentError('physical media projection fields must not be empty');
      }
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final record in values) {
        db.execute(
          '''
          INSERT INTO physical_media_projection (
            exact_key, family_key, projection_json, created_us, touched_us
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(exact_key) DO UPDATE SET
            family_key = excluded.family_key,
            projection_json = excluded.projection_json,
            created_us = physical_media_projection.created_us,
            touched_us = excluded.touched_us
        ''',
          <Object?>[
            record.exactKey,
            record.familyKey,
            record.projectionJson,
            record.createdUs,
            record.touchedUs,
          ],
        );
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> removePhysicalMediaProjection(String exactKey) async {
    _requireDb().execute(
      'DELETE FROM physical_media_projection WHERE exact_key = ?',
      <Object?>[exactKey],
    );
  }

  @override
  Future<void> putExistingArtifactBinding(CacheRec record) async {
    final artifactId = record.artifactId.trim();
    if (record.state != CacheState.ready || artifactId.isEmpty) {
      throw ArgumentError(
        'existing artifact bindings require ready artifactId',
      );
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        'SELECT bytes, checksum, checksum_algorithm FROM artifact_object '
        'WHERE artifact_id = ? LIMIT 1',
        <Object?>[artifactId],
      );
      if (rows.isEmpty) {
        throw StateError('artifact identity $artifactId does not exist');
      }
      final object = rows.first;
      final objectBytes = object['bytes']! as int;
      final objectChecksum = (object['checksum']! as String)
          .trim()
          .toLowerCase();
      final objectAlgorithm =
          ((object['checksum_algorithm'] as String?) ?? 'crc32')
              .trim()
              .toLowerCase();
      if (objectBytes != record.bytes ||
          objectChecksum != record.checksum.trim().toLowerCase() ||
          objectAlgorithm != record.checksumAlgorithm.trim().toLowerCase()) {
        throw StateError('artifact identity $artifactId has different content');
      }
      _putBinding(db, record, artifactId);
      db.execute('COMMIT');
      final cached = _cachedEntries;
      if (cached != null) cached[record.key] = record;
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
            'AND NOT EXISTS (SELECT 1 FROM cache_entry WHERE artifact_id = ?) '
            'AND NOT EXISTS (SELECT 1 FROM physical_media_artifact WHERE artifact_id = ?)',
            <Object?>[removedId, removedId, removedId],
          );
        }
      }
      db.execute('COMMIT');
      _invalidateCache();
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
    final cached = _cachedEntries;
    if (cached != null && cached.containsKey(key)) {
      cached[key] = cached[key]!.copyWith(touchedUs: touchedUs);
    }
  }

  Future<void> touchIfArtifact({
    required String key,
    required String expectedArtifactId,
    required int touchedUs,
  }) async {
    _requireDb().execute(
      'UPDATE cache_entry SET touched_us = MAX(touched_us, ?) '
      'WHERE key = ? AND artifact_id = ?',
      <Object?>[touchedUs, key, expectedArtifactId],
    );
    final cached = _cachedEntries;
    final current = cached?[key];
    if (current != null &&
        current.effectiveArtifactId == expectedArtifactId &&
        current.touchedUs < touchedUs) {
      cached![key] = current.copyWith(touchedUs: touchedUs);
    }
  }

  /// Executes best-effort recency maintenance on a dedicated SQLite writer.
  /// The artifact id condition prevents a delayed touch from refreshing a
  /// logical key after that key has rebound to different durable authority.
  Future<void> touchIfArtifactInBackground({
    required String key,
    required String expectedArtifactId,
    required int touchedUs,
  }) async {
    final dbPath = path;
    if (dbPath == null) {
      return touchIfArtifact(
        key: key,
        expectedArtifactId: expectedArtifactId,
        touchedUs: touchedUs,
      );
    }
    final worker = await _artifactTouchWorkerFor(dbPath);
    await worker.touch(
      key: key,
      expectedArtifactId: expectedArtifactId,
      touchedUs: touchedUs,
    );
    final cached = _cachedEntries;
    final current = cached?[key];
    if (current != null &&
        current.effectiveArtifactId == expectedArtifactId &&
        current.touchedUs < touchedUs) {
      cached![key] = current.copyWith(touchedUs: touchedUs);
    }
  }

  Future<_SqliteArtifactTouchWorker> _artifactTouchWorkerFor(String dbPath) {
    final existing = _artifactTouchWorker;
    if (existing != null) return existing;
    final created = _SqliteArtifactTouchWorker.spawn(dbPath);
    _artifactTouchWorker = created;
    unawaited(created.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        if (identical(_artifactTouchWorker, created)) {
          _artifactTouchWorker = null;
        }
      },
    ));
    return created;
  }

  @override
  Future<int> totalBytes({CacheState? state}) async {
    final cached = _cachedEntries;
    if (cached != null) {
      return physicalCacheBytes(
        cached.values.where((record) => state == null || record.state == state),
      );
    }
    final db = _requireDb();
    if (state == CacheState.partial) {
      return db
              .select(
        "SELECT COALESCE(SUM(bytes), 0) AS total "
        "FROM cache_entry WHERE state = 'partial'",
              )
              .first['total']!
          as int;
    }
    final ready =
        db.select("""
      SELECT COALESCE(SUM(bytes), 0) AS total FROM (
        SELECT MAX(bytes) AS bytes
        FROM cache_entry
        WHERE state = 'ready'
        GROUP BY CASE WHEN artifact_id = '' THEN key ELSE artifact_id END
      )
    """).first['total']!
            as int;
    if (state == CacheState.ready) return ready;
    final partial =
        db
                .select(
      "SELECT COALESCE(SUM(bytes), 0) AS total "
      "FROM cache_entry WHERE state = 'partial'",
                )
                .first['total']!
            as int;
    return ready + partial;
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
              (placementRows.first['comic_id'] as String) !=
                  placement.comicId)) {
        throw StateError(
          'placement id is already owned by another download placement',
        );
      }
      _ensureStorageRootLocator(
        db,
        placement.storageRootId,
        touchedUs: placement.updatedAt.toUtc().microsecondsSinceEpoch,
      );
      db.execute(
        '''
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
      ''',
        <Object?>[
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
        ],
      );
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
  Future<List<ExportPageBinding>> listExportPageBindings({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) async {
    final rows = _requireDb().select(
      'SELECT source_id, comic_id, chapter_id, page_id, logical_index, '
      'export_ordinal, placement_generation FROM export_page_binding '
      'WHERE source_id = ? AND comic_id = ? AND chapter_id = ? '
      'ORDER BY export_ordinal',
      <Object?>[sourceId, comicId, chapterId],
    );
    return rows
        .map(
          (row) => ExportPageBinding(
            sourceId: row['source_id']! as String,
            comicId: row['comic_id']! as String,
            chapterId: row['chapter_id']! as String,
            pageId: row['page_id']! as String,
            logicalIndex: row['logical_index']! as int,
            exportOrdinal: row['export_ordinal']! as int,
            placementGeneration: row['placement_generation']! as int,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> putExportPageBindings(
    Iterable<ExportPageBinding> bindings,
  ) async {
    final values = bindings.toList(growable: false);
    if (values.isEmpty) return;
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final binding in values) {
        if (binding.sourceId.isEmpty ||
            binding.comicId.isEmpty ||
            binding.chapterId.isEmpty ||
            binding.pageId.isEmpty ||
            binding.logicalIndex < 0 ||
            binding.exportOrdinal <= 0) {
          throw ArgumentError('invalid export page binding');
        }
        final existing = db.select(
          'SELECT export_ordinal FROM export_page_binding '
          'WHERE source_id = ? AND comic_id = ? AND chapter_id = ? '
          'AND page_id = ? LIMIT 1',
          <Object?>[
            binding.sourceId,
            binding.comicId,
            binding.chapterId,
            binding.pageId,
          ],
        );
        if (existing.isNotEmpty &&
            existing.first['export_ordinal'] != binding.exportOrdinal) {
          throw StateError(
            'export ordinal is immutable for '
            '${binding.sourceId}:${binding.comicId}:${binding.chapterId}:${binding.pageId}',
          );
        }
        final ordinalOwner = db.select(
          'SELECT page_id FROM export_page_binding '
          'WHERE source_id = ? AND comic_id = ? AND chapter_id = ? '
          'AND export_ordinal = ? AND page_id != ? LIMIT 1',
          <Object?>[
            binding.sourceId,
            binding.comicId,
            binding.chapterId,
            binding.exportOrdinal,
            binding.pageId,
          ],
        );
        if (ordinalOwner.isNotEmpty) {
          throw StateError(
            'export ordinal ${binding.exportOrdinal} is already bound to '
            '${ordinalOwner.first['page_id']}',
          );
        }
        db.execute(
          '''
          INSERT INTO export_page_binding (
            source_id, comic_id, chapter_id, page_id, logical_index,
            export_ordinal, placement_generation
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(source_id, comic_id, chapter_id, page_id) DO UPDATE SET
            logical_index = excluded.logical_index,
            placement_generation = excluded.placement_generation
        ''',
          <Object?>[
          binding.sourceId,
          binding.comicId,
          binding.chapterId,
          binding.pageId,
          binding.logicalIndex,
          binding.exportOrdinal,
          binding.placementGeneration,
          ],
        );
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'DELETE FROM export_page_binding WHERE source_id = ? AND comic_id = ?',
        <Object?>[sourceId, comicId],
      );
      db.execute(
        'DELETE FROM download_placement WHERE source_id = ? AND comic_id = ?',
        <Object?>[sourceId, comicId],
      );
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<bool> isPathOrArtifactReferenced({
    required String path,
    required String artifactId,
    String? excludingKey,
  }) async {
    final cached = _cachedEntries;
    final effectiveTargetArtifactId = artifactId.isEmpty
        ? defaultArtifactIdForPath(path)
        : artifactId;
    if (cached != null &&
        cached.values.any(
          (r) =>
              r.key != excludingKey &&
              (r.path == path ||
                  r.effectiveArtifactId == effectiveTargetArtifactId),
        )) {
      return true;
    }
    final db = _requireDb();
    if (cached == null) {
      final rows = db.select(
        'SELECT 1 FROM cache_entry WHERE (path = ? OR artifact_id = ?) AND key != ? LIMIT 1',
        <Object?>[path, effectiveTargetArtifactId, excludingKey ?? ''],
      );
      if (rows.isNotEmpty) return true;
    }
    final physicalRows = db.select(
      'SELECT 1 FROM physical_media_artifact p '
      'JOIN artifact_object o ON o.artifact_id = p.artifact_id '
      'WHERE p.artifact_id = ? OR o.path = ? LIMIT 1',
      <Object?>[effectiveTargetArtifactId, path],
    );
    return physicalRows.isNotEmpty;
  }

  @override
  Future<void> close() async {
    final touchWorker = _artifactTouchWorker;
    _artifactTouchWorker = null;
    if (touchWorker != null) {
      try {
        final worker = await touchWorker;
        await worker.close();
      } on Object {
        // Auxiliary recency maintenance must not block durable index close.
      }
    }
    final readWorker = _artifactReadWorker;
    _artifactReadWorker = null;
    if (readWorker != null) {
      try {
        final worker = await readWorker;
        await worker.close();
      } on Object {
        // Background reads own no durable mutation or close authority.
      }
    }
    _invalidateCache();
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

  void _putArtifactObject(sql.Database db, CacheRec record, String artifactId) {
    _ensureStorageRootLocator(
      db,
      record.storageRootId,
      touchedUs: record.touchedUs,
    );
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
    db.execute(
      '''
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
    ''',
      <Object?>[
      artifactId,
      record.path,
      record.bytes,
      record.checksum,
      record.checksumAlgorithm,
      record.storageRootId,
      record.createdUs,
      record.touchedUs,
      ],
    );
    if (record.state == CacheState.ready) {
      _syncCompatibilityArtifactReplica(
        db,
        artifactId: artifactId,
        accessLocator: record.path,
        storageRootId: record.storageRootId,
        createdUs: record.createdUs,
        touchedUs: record.touchedUs,
      );
    }
  }

  void _syncCompatibilityArtifactReplica(
    sql.Database db, {
    required String artifactId,
    required String accessLocator,
    required String storageRootId,
    required int createdUs,
    required int touchedUs,
  }) {
    _ensureStorageRootLocator(db, storageRootId, touchedUs: touchedUs);
    final matching = db.select(
      'SELECT replica_id FROM artifact_replica WHERE artifact_id = ? '
      'AND access_locator = ? AND storage_root_id = ? LIMIT 1',
      <Object?>[artifactId, accessLocator, storageRootId],
    );
    if (matching.isNotEmpty) {
      db.execute(
        'UPDATE artifact_replica SET touched_us = ? WHERE replica_id = ?',
        <Object?>[touchedUs, matching.first['replica_id']! as String],
      );
      return;
    }
    final primary = db.select(
      'SELECT created_us FROM artifact_replica WHERE replica_id = ? LIMIT 1',
      <Object?>[artifactId],
    );
    if (primary.isNotEmpty) {
      db.execute(
        'UPDATE artifact_replica SET access_locator = ?, storage_root_id = ?, '
        'touched_us = ? WHERE replica_id = ?',
        <Object?>[accessLocator, storageRootId, touchedUs, artifactId],
      );
      return;
    }
    db.execute(
      'INSERT INTO artifact_replica '
      '(replica_id, artifact_id, access_locator, storage_root_id, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[
        artifactId,
        artifactId,
        accessLocator,
        storageRootId,
        createdUs,
        touchedUs,
      ],
    );
  }

  ArtifactReplicaRecord _putArtifactReplica(
    sql.Database db, {
    required String artifactId,
    required String accessLocator,
    required String storageRootId,
    required int createdUs,
    required int touchedUs,
  }) {
    _ensureStorageRootLocator(db, storageRootId, touchedUs: touchedUs);
    final existing = db.select(
      'SELECT replica_id, created_us FROM artifact_replica '
      'WHERE artifact_id = ? AND access_locator = ? AND storage_root_id = ? '
      'LIMIT 1',
      <Object?>[artifactId, accessLocator, storageRootId],
    );
    final replicaId = existing.isNotEmpty
        ? existing.first['replica_id']! as String
        : _allocateArtifactReplicaId(
            db,
            artifactId: artifactId,
            accessLocator: accessLocator,
            storageRootId: storageRootId,
          );
    final effectiveCreatedUs = existing.isNotEmpty
        ? existing.first['created_us']! as int
        : createdUs;
    db.execute(
      'INSERT INTO artifact_replica '
      '(replica_id, artifact_id, access_locator, storage_root_id, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(replica_id) DO UPDATE SET '
      'access_locator = excluded.access_locator, '
      'storage_root_id = excluded.storage_root_id, touched_us = excluded.touched_us',
      <Object?>[
        replicaId,
        artifactId,
        accessLocator,
        storageRootId,
        effectiveCreatedUs,
        touchedUs,
      ],
    );
    return ArtifactReplicaRecord(
      replicaId: replicaId,
      artifactId: artifactId,
      accessLocator: accessLocator,
      storageRootId: storageRootId,
      createdUs: effectiveCreatedUs,
      touchedUs: touchedUs,
    );
  }

  String _allocateArtifactReplicaId(
    sql.Database db, {
    required String artifactId,
    required String accessLocator,
    required String storageRootId,
  }) {
    if (db.select(
      'SELECT 1 FROM artifact_replica WHERE artifact_id = ? LIMIT 1',
      <Object?>[artifactId],
    ).isEmpty) {
      return artifactId;
    }
    final token = defaultArtifactIdForPath(
      '$artifactId\u0000$storageRootId\u0000$accessLocator',
    );
    var candidate = '$artifactId:$token';
    var suffix = 1;
    while (db.select(
      'SELECT 1 FROM artifact_replica WHERE replica_id = ? LIMIT 1',
      <Object?>[candidate],
    ).isNotEmpty) {
      candidate = '$artifactId:$token:$suffix';
      suffix++;
    }
    return candidate;
  }

  void _migrateLegacyPinnedRetention(sql.Database db) {
    // Historical Reader promotion treated the existence of a comic download
    // placement as manual retention and could therefore pin App-private cache
    // finals. A placement is only export-location policy. Clear only states
    // that cannot represent a completed manual export; keep older structured
    // pins intact and leave ambiguous unpinned structured rows to the existing
    // compatibility projection rather than guessing new retention intent.
    db.execute('''
      UPDATE cache_entry
      SET pinned = 0
      WHERE pinned != 0 AND (
        state != 'ready' OR (
          path NOT LIKE 'saf:%' AND
          instr(replace(path, char(92), '/'), '/final/') > 0
        )
      )
    ''');
  }

  void _putBinding(sql.Database db, CacheRec record, String artifactId) {
    db.execute(
      '''
      INSERT INTO cache_entry (
        key, download_json, state, path, bytes, checksum, created_us, touched_us,
        pinned, checksum_algorithm, artifact_id, storage_root_id,
        content_key, source_revision
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        storage_root_id = excluded.storage_root_id,
        content_key = excluded.content_key,
        source_revision = excluded.source_revision
    ''',
      <Object?>[
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
        record.id.content.key,
        record.id.sourceRevision,
      ],
    );
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

  PhysicalPartialRecord _readPhysicalPartial(sql.Row row) {
    final decoded = jsonDecode(row['physical_json']! as String);
    if (decoded is! Map) {
      throw const FormatException('physical partial identity is invalid');
    }
    final id = PhysicalMediaId.fromJson(Map<String, Object?>.from(decoded));
    if (row['physical_key']! as String != id.key) {
      throw const FormatException('physical partial key/identity mismatch');
    }
    return PhysicalPartialRecord(
      id: id,
      path: row['path']! as String,
      bytes: row['bytes']! as int,
      checksum: row['checksum']! as String,
      createdUs: row['created_us']! as int,
      touchedUs: row['touched_us']! as int,
      checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
      storageRootId: (row['storage_root_id'] as String?) ?? 'default',
    );
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

PhysicalMediaProjectionRecord _readPhysicalMediaProjection(sql.Row row) =>
    PhysicalMediaProjectionRecord(
      exactKey: row['exact_key']! as String,
      familyKey: row['family_key']! as String,
      projectionJson: row['projection_json']! as String,
      createdUs: row['created_us']! as int,
      touchedUs: row['touched_us']! as int,
    );

void _createArtifactPromotionTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS artifact_promotion (
      promotion_key TEXT NOT NULL PRIMARY KEY,
      download_json TEXT NOT NULL,
      physical_json TEXT,
      source_access_locator TEXT NOT NULL,
      destination_access_locator TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      checksum TEXT NOT NULL,
      checksum_algorithm TEXT NOT NULL DEFAULT 'crc32',
      artifact_id TEXT NOT NULL,
      storage_root_id TEXT NOT NULL DEFAULT 'default',
      created_us INTEGER NOT NULL,
      touched_us INTEGER NOT NULL,
      pinned INTEGER NOT NULL DEFAULT 0,
      CHECK (bytes > 0),
      CHECK (source_access_locator != destination_access_locator)
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS artifact_promotion_source '
    'ON artifact_promotion(source_access_locator)',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS artifact_promotion_destination '
    'ON artifact_promotion(destination_access_locator)',
  );
}

void _createStorageCleanupDebtTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS storage_cleanup_debt (
      access_locator TEXT NOT NULL PRIMARY KEY,
      storage_root_id TEXT NOT NULL DEFAULT 'default',
      kind TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      touched_us INTEGER NOT NULL,
      expected_bytes INTEGER,
      expected_checksum TEXT,
      expected_checksum_algorithm TEXT,
      CHECK (
        (kind = 'temporary' AND expected_bytes IS NULL AND
          expected_checksum IS NULL AND expected_checksum_algorithm IS NULL) OR
        (kind IN ('obsoleteSealedSource', 'obsoletePartialSource') AND
          expected_bytes > 0 AND length(expected_checksum) > 0 AND
          length(expected_checksum_algorithm) > 0)
      )
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS storage_cleanup_debt_touch '
    'ON storage_cleanup_debt(kind, touched_us)',
  );
}

void _createPhysicalMediaTables(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS physical_media_artifact (
      physical_key TEXT NOT NULL PRIMARY KEY,
      physical_json TEXT NOT NULL,
      artifact_id TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      touched_us INTEGER NOT NULL,
      FOREIGN KEY (artifact_id) REFERENCES artifact_object(artifact_id) ON DELETE CASCADE
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS physical_media_artifact_object '
    'ON physical_media_artifact(artifact_id)',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS physical_partial (
      physical_key TEXT NOT NULL PRIMARY KEY,
      physical_json TEXT NOT NULL,
      path TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      checksum TEXT NOT NULL,
      checksum_algorithm TEXT NOT NULL DEFAULT 'crc32',
      storage_root_id TEXT NOT NULL DEFAULT 'default',
      created_us INTEGER NOT NULL,
      touched_us INTEGER NOT NULL,
      CHECK (bytes > 0)
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS physical_partial_touch '
    'ON physical_partial(touched_us)',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS physical_partial_path '
    'ON physical_partial(path)',
  );
  _createPhysicalMediaProjectionTable(db);
}

void _createPhysicalMediaProjectionTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS physical_media_projection (
      exact_key TEXT NOT NULL PRIMARY KEY,
      family_key TEXT NOT NULL,
      projection_json TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      touched_us INTEGER NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS physical_media_projection_family '
    'ON physical_media_projection(family_key, exact_key)',
  );
}

void _ensureCacheLogicalIdentityColumns(sql.Database db) {
  if (!_hasColumn(db, 'cache_entry', 'content_key')) {
    db.execute(
      "ALTER TABLE cache_entry ADD COLUMN content_key TEXT NOT NULL DEFAULT ''",
    );
  }
  if (!_hasColumn(db, 'cache_entry', 'source_revision')) {
    db.execute(
      "ALTER TABLE cache_entry ADD COLUMN source_revision TEXT NOT NULL DEFAULT ''",
    );
  }
  final rows = db.select(
    "SELECT key, download_json FROM cache_entry "
    "WHERE content_key = '' OR source_revision = ''",
  );
  for (final row in rows) {
    final raw = row['download_json'];
    if (raw is! String) continue;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) continue;
      final id = DownloadId.fromJson(Map<String, Object?>.from(decoded));
      db.execute(
        'UPDATE cache_entry SET content_key = ?, source_revision = ? '
        'WHERE key = ?',
        <Object?>[id.content.key, id.sourceRevision, row['key']! as String],
      );
    } on FormatException {
      // Malformed historical rows remain available to explicit repair.
    } on TypeError {
      // Same fail-closed rule for partially written historical JSON.
    }
  }
  db.execute(
    'CREATE INDEX IF NOT EXISTS cache_entry_logical_identity '
    'ON cache_entry(content_key, source_revision, state, touched_us DESC)',
  );
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
          db.execute('DELETE FROM cache_entry WHERE key = ?', <Object?>[
            oldKey,
          ]);
        }
        continue;
      }
      db.execute('UPDATE cache_entry SET key = ? WHERE key = ?', <Object?>[
        newKey,
        oldKey,
      ]);
    } on FormatException {
      // A malformed legacy row remains available to the existing repair and
      // scanner paths; do not make an otherwise readable cache unopenable.
    } on TypeError {
      // Same compatibility rule for partially written legacy JSON.
    }
  }
}

ArtifactPromotionRecord _readArtifactPromotion(sql.Row row) {
  final decodedDownload = jsonDecode(row['download_json']! as String);
  if (decodedDownload is! Map) {
    throw const FormatException('artifact promotion download identity is invalid');
  }
  final rawPhysical = row['physical_json'];
  PhysicalMediaId? physicalId;
  if (rawPhysical is String) {
    final decodedPhysical = jsonDecode(rawPhysical);
    if (decodedPhysical is! Map) {
      throw const FormatException('artifact promotion physical identity is invalid');
    }
    physicalId = PhysicalMediaId.fromJson(
      Map<String, Object?>.from(decodedPhysical),
    );
  }
  return ArtifactPromotionRecord(
    promotionKey: row['promotion_key']! as String,
    id: DownloadId.fromJson(Map<String, Object?>.from(decodedDownload)),
    physicalId: physicalId,
    sourceAccessLocator: row['source_access_locator']! as String,
    destinationAccessLocator: row['destination_access_locator']! as String,
    bytes: row['bytes']! as int,
    checksum: row['checksum']! as String,
    checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
    artifactId: row['artifact_id']! as String,
    storageRootId: (row['storage_root_id'] as String?) ?? 'default',
    createdUs: row['created_us']! as int,
    touchedUs: row['touched_us']! as int,
    pinned: row['pinned'] == 1,
  );
}

ArtifactReplicaMigrationRecord _readArtifactReplicaMigration(sql.Row row) {
  return ArtifactReplicaMigrationRecord(
    replicaId: row['replica_id']! as String,
    sourceAccessLocator: row['source_access_locator']! as String,
    sourceStorageRootId:
        (row['source_storage_root_id'] as String?) ?? 'default',
    destinationAccessLocator: row['destination_access_locator']! as String,
    destinationStorageRootId:
        (row['destination_storage_root_id'] as String?) ?? 'default',
    temporaryAccessLocator: row['temporary_access_locator']! as String,
    phase: ArtifactReplicaMigrationPhase.values.byName(row['phase']! as String),
    createdUs: row['created_us']! as int,
    touchedUs: row['touched_us']! as int,
  );
}

StorageRootRecord? _readStorageRoot(sql.Database db, String rootId) {
  final roots = db.select(
    'SELECT root_id, created_us, touched_us FROM storage_root '
    'WHERE root_id = ? LIMIT 1',
    <Object?>[rootId],
  );
  if (roots.isEmpty) return null;
  final root = roots.first;
  final locators = db
      .select(
    'SELECT kind, locator, health, verified_us, touched_us '
    'FROM storage_access_locator WHERE root_id = ?',
    <Object?>[rootId],
      )
      .map(
        (row) => StorageAccessLocatorRecord(
        rootId: rootId,
        kind: StorageAccessLocatorKind.values.byName(row['kind']! as String),
        locator: row['locator']! as String,
        health: StorageAccessHealth.values.byName(row['health']! as String),
        verifiedUs: row['verified_us'] as int?,
        touchedUs: row['touched_us']! as int,
        ),
      )
      .toList(growable: false);
  return StorageRootRecord(
    rootId: rootId,
    createdUs: root['created_us']! as int,
    touchedUs: root['touched_us']! as int,
    accessLocators: List<StorageAccessLocatorRecord>.unmodifiable(locators),
  );
}

String? _normalizeLegacyLeadingSlashSafIdentity(String value) {
  final normalized = value.trim();
  return normalized.startsWith('/content://') ? normalized.substring(1) : null;
}

String? _normalizeLegacyLeadingSlashSafRecord(String value) {
  if (!value.startsWith('saf:')) return null;
  final marker = value.indexOf('?path=');
  if (marker < 0) return null;
  final encodedTree = value.substring(4, marker);
  final tree = Uri.decodeComponent(encodedTree);
  final normalizedTree = _normalizeLegacyLeadingSlashSafIdentity(tree);
  if (normalizedTree == null) return null;
  return 'saf:${Uri.encodeComponent(normalizedTree)}${value.substring(marker)}';
}

/// Removes the short-lived v18 logical-page Venera physical alias. Device
/// evidence showed that one pageId/sourceRevision can resolve to different
/// decoded pixels across provider carriers, so these rows are routing debt,
/// not reusable media proof. Exact READY bindings and artifact replicas remain.
void _removeDeprecatedVolatilePagePhysicalBindings(sql.Database db) {
  db.execute(
    "DELETE FROM physical_media_artifact "
    "WHERE physical_json LIKE '%\"value\":\"volatile-page:v1%'",
  );
}

/// Repairs the historical app-side `saf://` prefix off-by-one that persisted
/// `/content://...` as the SAF tree identity. The signature is intentionally
/// narrow: a leading-slash content URI cannot be a valid app-owned absolute
/// filesystem root, so no POSIX locator is inferred or manufactured here.
///
/// Body bytes never move. Only App-private metadata is canonicalized so the
/// existing SAF document remains the same immutable artifact/partial owner.
void _migrateLegacyLeadingSlashSafIdentity(sql.Database db) {
  bool tableExists(String table) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
    <Object?>[table],
  ).isNotEmpty;

  final rootColumns = <(String, String)>[
    ('artifact_object', 'storage_root_id'),
    ('artifact_promotion', 'storage_root_id'),
    ('artifact_replica', 'storage_root_id'),
    ('artifact_replica_migration', 'source_storage_root_id'),
    ('artifact_replica_migration', 'destination_storage_root_id'),
    ('cache_entry', 'storage_root_id'),
    ('download_placement', 'storage_root_id'),
    ('physical_partial', 'storage_root_id'),
    ('storage_cleanup_debt', 'storage_root_id'),
    ('storage_access_locator', 'root_id'),
  ];
  final roots = <String>{};
  if (tableExists('storage_root')) {
    for (final row in db.select(
      "SELECT root_id FROM storage_root WHERE root_id LIKE '/content://%'",
    )) {
      roots.add(row['root_id']! as String);
    }
  }
  for (final (table, column) in rootColumns) {
    if (!tableExists(table)) continue;
    for (final row in db.select(
      "SELECT DISTINCT $column AS value FROM $table WHERE $column LIKE '/content://%'",
    )) {
      roots.add(row['value']! as String);
    }
  }

  final locatorColumns = <(String, String, String)>[
    ('artifact_object', 'artifact_id', 'path'),
    ('artifact_promotion', 'promotion_key', 'source_access_locator'),
    ('artifact_promotion', 'promotion_key', 'destination_access_locator'),
    ('artifact_replica', 'replica_id', 'access_locator'),
    ('artifact_replica_migration', 'replica_id', 'source_access_locator'),
    ('artifact_replica_migration', 'replica_id', 'destination_access_locator'),
    ('artifact_replica_migration', 'replica_id', 'temporary_access_locator'),
    ('cache_entry', 'key', 'path'),
    ('physical_partial', 'physical_key', 'path'),
  ];
  for (final (table, keyColumn, valueColumn) in locatorColumns) {
    if (!tableExists(table)) continue;
    final rows = db.select('SELECT $keyColumn AS row_key, $valueColumn AS value FROM $table');
    for (final row in rows) {
      final value = row['value']! as String;
      final repaired = _normalizeLegacyLeadingSlashSafRecord(value);
      if (repaired == null || repaired == value) continue;
      db.execute(
        'UPDATE $table SET $valueColumn = ? WHERE $keyColumn = ?',
        <Object?>[repaired, row['row_key']],
      );
    }
  }

  // cleanup debt is keyed by the locator itself, so rewrite it separately.
  final debts = tableExists('storage_cleanup_debt')
      ? db.select('SELECT * FROM storage_cleanup_debt')
      : const <sql.Row>[];
  for (final row in debts) {
    final value = row['access_locator']! as String;
    final repaired = _normalizeLegacyLeadingSlashSafRecord(value);
    if (repaired == null || repaired == value) continue;
    final conflict = db.select(
      'SELECT 1 FROM storage_cleanup_debt WHERE access_locator = ? LIMIT 1',
      <Object?>[repaired],
    );
    if (conflict.isNotEmpty) continue;
    db.execute(
      'UPDATE storage_cleanup_debt SET access_locator = ? WHERE access_locator = ?',
      <Object?>[repaired, value],
    );
  }

  if (!tableExists('storage_root')) return;

  for (final legacyRoot in roots) {
    final repairedRoot = _normalizeLegacyLeadingSlashSafIdentity(legacyRoot);
    if (repairedRoot == null) continue;
    final oldRows = db.select(
      'SELECT created_us, touched_us FROM storage_root WHERE root_id = ? LIMIT 1',
      <Object?>[legacyRoot],
    );
    final newRows = db.select(
      'SELECT created_us, touched_us FROM storage_root WHERE root_id = ? LIMIT 1',
      <Object?>[repairedRoot],
    );
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final oldCreated = oldRows.isEmpty ? nowUs : oldRows.first['created_us']! as int;
    final oldTouched = oldRows.isEmpty ? nowUs : oldRows.first['touched_us']! as int;
    if (newRows.isEmpty) {
      db.execute(
        'INSERT INTO storage_root (root_id, created_us, touched_us) VALUES (?, ?, ?)',
        <Object?>[repairedRoot, oldCreated, oldTouched],
      );
    } else {
      final created = newRows.first['created_us']! as int;
      final touched = newRows.first['touched_us']! as int;
      db.execute(
        'UPDATE storage_root SET created_us = ?, touched_us = ? WHERE root_id = ?',
        <Object?>[
          created < oldCreated ? created : oldCreated,
          touched > oldTouched ? touched : oldTouched,
          repairedRoot,
        ],
      );
    }

    for (final (table, column) in rootColumns) {
      if (table == 'storage_access_locator' || !tableExists(table)) continue;
      db.execute(
        'UPDATE $table SET $column = ? WHERE $column = ?',
        <Object?>[repairedRoot, legacyRoot],
      );
    }

    final accessRows = tableExists('storage_access_locator')
        ? db.select(
            'SELECT kind, locator, health, verified_us, touched_us '
            'FROM storage_access_locator WHERE root_id = ?',
            <Object?>[legacyRoot],
          )
        : const <sql.Row>[];
    for (final row in accessRows) {
      final kind = row['kind']! as String;
      final locator = row['locator']! as String;
      final repairedLocator =
          _normalizeLegacyLeadingSlashSafIdentity(locator) ?? locator;
      final malformedTreeIdentity = locator.startsWith('/content://');
      final repairedKind = malformedTreeIdentity ? 'saf' : kind;
      final health = malformedTreeIdentity ? 'unknown' : row['health']! as String;
      final verifiedUs = malformedTreeIdentity ? null : row['verified_us'];
      final touchedUs = row['touched_us']! as int;
      db.execute(
        'DELETE FROM storage_access_locator WHERE kind = ? AND locator = ?',
        <Object?>[kind, locator],
      );
      final existing = db.select(
        'SELECT health, verified_us, touched_us FROM storage_access_locator '
        'WHERE kind = ? AND locator = ? LIMIT 1',
        <Object?>[repairedKind, repairedLocator],
      );
      if (existing.isEmpty) {
        db.execute(
          'INSERT INTO storage_access_locator '
          '(kind, locator, root_id, health, verified_us, touched_us) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>[
            repairedKind,
            repairedLocator,
            repairedRoot,
            health,
            verifiedUs,
            touchedUs,
          ],
        );
      } else {
        final existingTouched = existing.first['touched_us']! as int;
        db.execute(
          'UPDATE storage_access_locator SET root_id = ?, touched_us = ? '
          'WHERE kind = ? AND locator = ?',
          <Object?>[
            repairedRoot,
            existingTouched > touchedUs ? existingTouched : touchedUs,
            repairedKind,
            repairedLocator,
          ],
        );
      }
    }
    db.execute(
      'DELETE FROM storage_root WHERE root_id = ?',
      <Object?>[legacyRoot],
    );
  }
}

void _ensureStorageRootLocator(
  sql.Database db,
  String identity, {
  required int touchedUs,
}) {
  final normalized = identity.trim();
  if (normalized.isEmpty || normalized == 'default') return;
  final kind = normalized.startsWith('content://')
      ? StorageAccessLocatorKind.saf
      : StorageAccessLocatorKind.direct;
  db.execute(
    'INSERT OR IGNORE INTO storage_root (root_id, created_us, touched_us) '
    'VALUES (?, ?, ?)',
    <Object?>[normalized, touchedUs, touchedUs],
  );
  db.execute(
    'INSERT OR IGNORE INTO storage_access_locator '
    '(kind, locator, root_id, health, verified_us, touched_us) '
    "VALUES (?, ?, ?, 'unknown', NULL, ?)",
    <Object?>[kind.name, normalized, normalized, touchedUs],
  );
}

void _backfillArtifactReplicas(sql.Database db) {
  final rows = db.select(
    'SELECT o.artifact_id, o.path, o.storage_root_id, o.created_us, o.touched_us '
    'FROM artifact_object o WHERE EXISTS ('
    "SELECT 1 FROM cache_entry e WHERE e.artifact_id = o.artifact_id AND e.state = 'ready'"
    ')',
  );
  for (final row in rows) {
    final artifactId = row['artifact_id']! as String;
    db.execute(
      'INSERT OR IGNORE INTO artifact_replica '
      '(replica_id, artifact_id, access_locator, storage_root_id, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>[
        artifactId,
        artifactId,
        row['path']! as String,
        (row['storage_root_id'] as String?) ?? 'default',
        row['created_us']! as int,
        row['touched_us']! as int,
      ],
    );
  }
}

void _backfillStorageRootRegistry(sql.Database db) {
  final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
  final identities = <String>{};
  for (final table in const <String>[
    'artifact_object',
    'cache_entry',
    'download_placement',
  ]) {
    final rows = db.select(
      'SELECT DISTINCT storage_root_id FROM $table '
      "WHERE storage_root_id IS NOT NULL AND storage_root_id != '' "
      "AND storage_root_id != 'default'",
    );
    for (final row in rows) {
      identities.add(row['storage_root_id']! as String);
    }
  }
  for (final identity in identities) {
    _ensureStorageRootLocator(db, identity, touchedUs: nowUs);
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

bool _hasColumn(sql.Database db, String table, String column) =>
    db.select('PRAGMA table_info($table)').any((row) => row['name'] == column);

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
    db.execute(
      '''
      INSERT INTO artifact_object (
        artifact_id, path, bytes, checksum, checksum_algorithm,
        storage_root_id, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(artifact_id) DO NOTHING
    ''',
      <Object?>[
      artifactId,
      row['path']! as String,
      row['bytes']! as int,
      row['checksum']! as String,
      (row['checksum_algorithm'] as String?) ?? 'crc32',
      (row['storage_root_id'] as String?) ?? 'default',
      row['created_us']! as int,
      row['touched_us']! as int,
      ],
    );
  }
}
