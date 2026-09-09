import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'sqlite_progress_writer.dart';

const _schemaVersion = 11;

final class SqliteImportedLibraryStore
    implements
        ImportedLibraryStore,
        ImportedLibraryBatchLookup,
        ComicVersionRelationStore,
        ReaderProgressCheckpointStore,
        ImportedLibraryRevisionStore,
        SourceMigrationJournalStore {
  SqliteImportedLibraryStore(this.path);

  SqliteImportedLibraryStore.memory() : path = null;

  final String? path;
  sql.Database? _db;
  SqliteProgressWriter? _progressWriter;
  Future<void>? _progressWriterOpening;
  DateTime? _progressWriterRetryAfter;
  final Map<String, ReadingProgress> _pendingReaderProgress =
      <String, ReadingProgress>{};

  @override
  Future<void> open() async {
    if (_db != null) {
      _storageLog('library-open-skipped reason=already-open');
      return;
    }
    final startedAt = Stopwatch()..start();
    final dbPath = path;
    _storageLog(
      'library-open-start persistent=${dbPath != null}',
    );
    if (dbPath != null) {
      await File(dbPath).parent.create(recursive: true);
    }
    _storageLog('library-parent-ready durationMs=${startedAt.elapsedMilliseconds}');
    final sqliteOpenStartedAt = Stopwatch()..start();
    final db = dbPath == null
        ? sql.sqlite3.openInMemory()
        : sql.sqlite3.open(dbPath);
    _storageLog(
      'library-sqlite-connection-opened '
      'durationMs=${sqliteOpenStartedAt.elapsedMilliseconds}',
    );
    try {
      final pragmaStartedAt = Stopwatch()..start();
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA busy_timeout = 5000');
      _storageLog(
        'library-pragmas-complete '
        'durationMs=${pragmaStartedAt.elapsedMilliseconds}',
      );
      final version =
          db.select('PRAGMA user_version').first.values.first as int;
      _storageLog('library-schema-version version=$version');
      if (version == 0) {
        final schemaStartedAt = Stopwatch()..start();
        _storageLog('library-schema-create-start from=0');
        db.execute('BEGIN IMMEDIATE');
        try {
          _createCompositeLibraryTables(db);
          _createCategoryTable(db);
          _createSourcePreferenceTables(db);
          _createSavedComicTables(db);
          _createMigrationIssueTable(db);
          _createComicVersionRelationTable(db);
          _createLibraryProjectionRevision(db);
          _createSourceMigrationJournalTable(db);
          db.execute('PRAGMA user_version = $_schemaVersion');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
        _storageLog(
          'library-schema-create-complete '
          'version=$_schemaVersion '
          'durationMs=${schemaStartedAt.elapsedMilliseconds}',
        );
      } else if (version >= 1 && version <= 4) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=$version');
        _prepareLegacySchemaForMigration(db);
        _migrateToCompositeSchema(db, fromVersion: version);
        _storageLog(
          'library-schema-migration-complete from=$version '
          'to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 5) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=5');
        _migrateMigrationIssueAcknowledgement(db);
        _storageLog(
          'library-schema-migration-complete from=5 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 6) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=6');
        _migrateComicVersionRelations(db);
        _storageLog(
          'library-schema-migration-complete from=6 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 7) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=7');
        _migrateComicVersionPageMappings(db);
        _storageLog(
          'library-schema-migration-complete from=7 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 8) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=8');
        _migrateLibraryProjectionRevision(db);
        _storageLog(
          'library-schema-migration-complete from=8 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 9) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=9');
        _migrateChapterReadStateOwnership(db);
        _storageLog(
          'library-schema-migration-complete from=9 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version == 10) {
        final migrationStartedAt = Stopwatch()..start();
        _storageLog('library-schema-migration-start from=10');
        _migrateSourceMigrationJournal(db);
        _storageLog(
          'library-schema-migration-complete from=10 to=$_schemaVersion '
          'durationMs=${migrationStartedAt.elapsedMilliseconds}',
        );
      } else if (version != _schemaVersion) {
        throw StateError(
          'unsupported imported library schema version: $version',
        );
      }
      _db = db;
      _storageLog(
        'library-open-complete version=$_schemaVersion '
        'durationMs=${startedAt.elapsedMilliseconds}',
      );
      if (dbPath != null) {
        // This is diagnostic only and deliberately does not delay the first
        // Home projection. It makes the distinction between the authoritative
        // SQLite library and the compact startup snapshot visible in a cold
        // start trace.
        unawaited(_logLibraryStorageBytes(dbPath));
      }
    } on Object catch (error) {
      _storageLog(
        'library-open-failed '
        'durationMs=${startedAt.elapsedMilliseconds} '
        'errorType=${error.runtimeType}',
      );
      db.dispose();
      rethrow;
    }
  }

  @override
  Future<int?> get libraryProjectionRevision async {
    final rows = _requireDb().select('''
      SELECT revision
      FROM library_projection_revision
      WHERE singleton = 1
      LIMIT 1
    ''');
    return rows.isEmpty ? null : rows.first['revision']! as int;
  }

  @override
  Future<List<ImportedLibraryEntry>> list() async {
    final rows = _requireDb().select('''
      SELECT c.chapter_json, p.progress_json
      FROM imported_chapter AS c
      LEFT JOIN reading_progress AS p
        ON p.source_id = c.source_id AND p.chapter_id = c.chapter_id
      ORDER BY c.imported_us DESC, c.source_id, c.chapter_id
    ''');
    return rows.map(_readEntry).toList(growable: false);
  }

  @override
  Future<ImportedLibraryEntry?> get(
    String sourceId,
    String chapterId,
  ) async {
    final rows = _requireDb().select('''
      SELECT c.chapter_json, p.progress_json
      FROM imported_chapter AS c
      LEFT JOIN reading_progress AS p
        ON p.source_id = c.source_id AND p.chapter_id = c.chapter_id
      WHERE c.source_id = ? AND c.chapter_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, chapterId]);
    return rows.isEmpty ? null : _readEntry(rows.first);
  }

  @override
  Future<List<ImportedLibraryEntry>> getMany(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) async {
    final unique = <String, ImportedLibraryChapterKey>{};
    for (final key in chapters) {
      unique.putIfAbsent(key.identity, () => key);
    }
    if (unique.isEmpty) return const <ImportedLibraryEntry>[];
    final db = _requireDb();
    final result = <ImportedLibraryEntry>[];
    final keys = unique.values.toList(growable: false);
    const chunkSize = 200;
    for (var offset = 0; offset < keys.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, keys.length);
      final chunk = keys.sublist(offset, end);
      final where = List<String>.filled(
        chunk.length,
        '(c.source_id = ? AND c.chapter_id = ?)',
      ).join(' OR ');
      final args = <Object?>[];
      for (final key in chunk) {
        args
          ..add(key.sourceId)
          ..add(key.chapterId);
      }
      final statement = 'SELECT c.chapter_json, p.progress_json '
          'FROM imported_chapter AS c '
          'LEFT JOIN reading_progress AS p '
          'ON p.source_id = c.source_id AND p.chapter_id = c.chapter_id '
          'WHERE $where';
      result.addAll(db.select(statement, args).map(_readEntry));
    }
    return List<ImportedLibraryEntry>.unmodifiable(result);
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final existingRows = db.select('''
        SELECT c.chapter_json, p.progress_json
        FROM imported_chapter AS c
        LEFT JOIN reading_progress AS p
          ON p.source_id = c.source_id AND p.chapter_id = c.chapter_id
        WHERE c.source_id = ? AND c.chapter_id = ?
        LIMIT 1
      ''', <Object?>[chapter.sourceId, chapter.chapterId]);
      final previousChapter = existingRows.isEmpty
          ? null
          : _decodeChapter(existingRows.first['chapter_json']! as String);
      final previousProgress = existingRows.isEmpty ||
              existingRows.first['progress_json'] == null
          ? null
          : _decodeProgress(
              existingRows.first['progress_json']! as String,
              fallbackSourceId: chapter.sourceId,
            );
      db.execute('''
        INSERT INTO imported_chapter (
          source_id, chapter_id, comic_id, imported_us, chapter_json
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(source_id, chapter_id) DO UPDATE SET
          comic_id = excluded.comic_id,
          imported_us = excluded.imported_us,
          chapter_json = excluded.chapter_json
      ''', <Object?>[
        chapter.sourceId,
        chapter.chapterId,
        chapter.comicId,
        chapter.importedAt.microsecondsSinceEpoch,
        jsonEncode(chapter.toJson()),
      ]);
      final reconciled = reconcileImportedProgress(
        previousChapter: previousChapter,
        refreshedChapter: chapter,
        progress: previousProgress,
      );
      if (reconciled != null) {
        _putProgress(db, reconciled);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    final writer = _progressWriter;
    if (writer != null) {
      await writer.save(progress);
      return;
    }
    final db = _requireDb();
    _saveProgressSynchronously(db, progress);
    _startProgressWriter(db);
  }

  @override
  void enqueueProgress(ReadingProgress progress) {
    final writer = _progressWriter;
    if (writer != null) {
      writer.enqueue(progress);
      return;
    }
    final db = _requireDb();
    if (path == null) {
      // In-memory stores are test/compatibility implementations and have no
      // secondary SQLite connection. Keep their immediate semantics.
      _saveProgressSynchronously(db, progress);
      return;
    }
    // Reader page turns are a UI hot path. If the optional isolate writer is
    // still opening (or a prior open attempt failed), retain only the latest
    // checkpoint in memory and return immediately. In particular, do not
    // SELECT + jsonDecode the full chapter on Flutter's UI isolate here.
    _rememberPendingReaderProgress(progress);
    _startProgressWriter(db);
  }

  @override
  Future<void> flushProgressCheckpoints() async {
    final opening = _progressWriterOpening;
    if (opening != null) {
      await opening;
    }
    final writer = _progressWriter;
    if (writer != null) {
      _drainPendingReaderProgress(writer);
      await writer.flush();
      return;
    }
    // A lifecycle/route flush is a durability barrier, not a page-turn hot
    // path. If the optional isolate writer cannot be established, this is the
    // one safe boundary where synchronous SQLite fallback is acceptable.
    final db = _requireDb();
    _flushPendingReaderProgressSynchronously(db);
  }

  void _saveProgressSynchronously(
    sql.Database db,
    ReadingProgress progress,
  ) {
    final rows = db.select('''
      SELECT comic_id, chapter_json
      FROM imported_chapter
      WHERE source_id = ? AND chapter_id = ?
      LIMIT 1
    ''', <Object?>[progress.sourceId, progress.chapterId]);
    if (rows.isEmpty) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    if (rows.first['comic_id'] != progress.comicId) {
      throw StateError('progress identity does not match the chapter');
    }
    final rawChapter = jsonDecode(rows.first['chapter_json']! as String);
    final pages = rawChapter is Map ? rawChapter['pages'] : null;
    final pageCount = pages is List ? pages.length : 0;
    if (progress.pageIndex < 0 || progress.pageIndex >= pageCount) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        pageCount - 1,
        'progress.pageIndex',
      );
    }
    final current = db.select('''
      SELECT updated_us
      FROM reading_progress
      WHERE source_id = ? AND chapter_id = ?
      LIMIT 1
    ''', <Object?>[progress.sourceId, progress.chapterId]);
    if (current.isNotEmpty &&
        (current.first['updated_us']! as int) >
            progress.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    _putProgress(db, progress);
  }

  @override
  Future<void> removeChapter(String sourceId, String chapterId) async {
    final db = _requireDb();
    final rows = db.select('''
      SELECT comic_id
      FROM imported_chapter
      WHERE source_id = ? AND chapter_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, chapterId]);
    final comicId = rows.isEmpty ? null : rows.first['comic_id']! as String;
    db.execute(
      'DELETE FROM chapter_read_state WHERE source_id = ? AND chapter_id = ?',
      <Object?>[sourceId, chapterId],
    );
    db.execute(
      'DELETE FROM reading_progress WHERE source_id = ? AND chapter_id = ?',
      <Object?>[sourceId, chapterId],
    );
    if (comicId == null) {
      return;
    }
    db.execute(
      'DELETE FROM imported_chapter WHERE source_id = ? AND chapter_id = ?',
      <Object?>[sourceId, chapterId],
    );
    final remaining = db.select('''
      SELECT 1 FROM imported_chapter
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, comicId]);
    final saved = db.select('''
      SELECT 1 FROM saved_comic
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, comicId]);
    if (remaining.isEmpty && saved.isEmpty) {
      db.execute(
        'DELETE FROM comic_preference WHERE source_id = ? AND comic_id = ?',
        <Object?>[sourceId, comicId],
      );
    }
  }

  @override
  Future<List<SavedComicRecord>> listSavedComics() async {
    final rows = _requireDb().select('''
      SELECT comic_json
      FROM saved_comic
      ORDER BY updated_us DESC, source_id, comic_id
    ''');
    return rows
        .map((row) => _decodeSavedComic(row['comic_json']! as String))
        .toList(growable: false);
  }

  @override
  Future<SavedComicRecord?> getSavedComic(
    String sourceId,
    String comicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT comic_json
      FROM saved_comic
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, comicId]);
    return rows.isEmpty
        ? null
        : _decodeSavedComic(rows.first['comic_json']! as String);
  }

  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) async {
    final db = _requireDb();
    final rows = db.select('''
      SELECT updated_us
      FROM saved_comic
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[comic.sourceId, comic.comicId]);
    final updatedUs = comic.updatedAt.toUtc().microsecondsSinceEpoch;
    if (rows.isNotEmpty && (rows.first['updated_us']! as int) > updatedUs) {
      return;
    }
    db.execute('''
      INSERT INTO saved_comic (
        source_id, comic_id, saved_us, updated_us, comic_json
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_id, comic_id) DO UPDATE SET
        saved_us = excluded.saved_us,
        updated_us = excluded.updated_us,
        comic_json = excluded.comic_json
    ''', <Object?>[
      comic.sourceId,
      comic.comicId,
      comic.savedAt.toUtc().microsecondsSinceEpoch,
      updatedUs,
      jsonEncode(comic.toJson()),
    ]);
  }

  @override
  Future<void> removeSavedComic(String sourceId, String comicId) async {
    final db = _requireDb();
    db.execute(
      'DELETE FROM saved_comic WHERE source_id = ? AND comic_id = ?',
      <Object?>[sourceId, comicId],
    );
    final chapters = db.select('''
      SELECT 1 FROM imported_chapter
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, comicId]);
    if (chapters.isEmpty) {
      db.execute(
        'DELETE FROM comic_preference WHERE source_id = ? AND comic_id = ?',
        <Object?>[sourceId, comicId],
      );
    }
  }

  @override
  Future<List<LibraryCategory>> listCategories() async {
    final rows = _requireDb().select('''
      SELECT category_json
      FROM library_category
      ORDER BY sort_order, name, category_id
    ''');
    return rows
        .map((row) => _decodeCategory(row['category_json']! as String))
        .toList(growable: false);
  }

  @override
  Future<void> upsertCategory(LibraryCategory category) async {
    _requireDb().execute('''
      INSERT INTO library_category (
        category_id, name, sort_order, category_json
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(category_id) DO UPDATE SET
        name = excluded.name,
        sort_order = excluded.sort_order,
        category_json = excluded.category_json
    ''', <Object?>[
      category.categoryId,
      category.name,
      category.sortOrder,
      jsonEncode(category.toJson()),
    ]);
  }

  @override
  Future<void> removeCategory(String categoryId) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'DELETE FROM library_category WHERE category_id = ?',
        <Object?>[categoryId],
      );
      final rows = db.select(
        'SELECT source_id, comic_id, preference_json FROM comic_preference',
      );
      for (final row in rows) {
        final preference = _decodePreference(
          row['preference_json']! as String,
          fallbackSourceId: row['source_id']! as String,
        );
        if (!preference.categoryIds.contains(categoryId)) {
          continue;
        }
        _putComicPreference(
          db,
          preference.copyWith(
            categoryIds:
                preference.categoryIds.where((id) => id != categoryId),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<ComicPreference>> listComicPreferences() async {
    final rows = _requireDb().select('''
      SELECT source_id, preference_json
      FROM comic_preference
    ''');
    return rows
        .map(
          (row) => _decodePreference(
            row['preference_json']! as String,
            fallbackSourceId: row['source_id']! as String,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ComicPreference?> getComicPreference(
    String sourceId,
    String comicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT preference_json
      FROM comic_preference
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[sourceId, comicId]);
    return rows.isEmpty
        ? null
        : _decodePreference(
            rows.first['preference_json']! as String,
            fallbackSourceId: sourceId,
          );
  }

  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    final db = _requireDb();
    final rows = db.select('''
      SELECT updated_us
      FROM comic_preference
      WHERE source_id = ? AND comic_id = ?
      LIMIT 1
    ''', <Object?>[preference.sourceId, preference.comicId]);
    if (rows.isNotEmpty &&
        (rows.first['updated_us']! as int) >
            preference.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    _putComicPreference(db, preference);
  }

  @override
  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT read_json
      FROM chapter_read_state
      WHERE source_id = ? AND comic_id = ?
      ORDER BY chapter_id
    ''', <Object?>[sourceId, comicId]);
    return rows
        .map(
          (row) => _decodeReadState(
            row['read_json']! as String,
            fallbackSourceId: sourceId,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() async {
    final rows = _requireDb().select('''
      SELECT source_id, read_json
      FROM chapter_read_state
      ORDER BY source_id, chapter_id
    ''');
    return rows
        .map(
          (row) => _decodeReadState(
            row['read_json']! as String,
            fallbackSourceId: row['source_id']! as String,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> saveChapterReadState(ChapterReadState state) async {
    final db = _requireDb();
    final rows = db.select('''
      SELECT updated_us
      FROM chapter_read_state
      WHERE source_id = ? AND chapter_id = ?
      LIMIT 1
    ''', <Object?>[state.sourceId, state.chapterId]);
    if (rows.isNotEmpty &&
        (rows.first['updated_us']! as int) >
            state.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    db.execute('''
      INSERT INTO chapter_read_state (
        source_id, chapter_id, comic_id, updated_us, read_json
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_id, chapter_id) DO UPDATE SET
        comic_id = excluded.comic_id,
        updated_us = excluded.updated_us,
        read_json = excluded.read_json
    ''', <Object?>[
      state.sourceId,
      state.chapterId,
      state.comicId,
      state.updatedAt.toUtc().microsecondsSinceEpoch,
      jsonEncode(state.toJson()),
    ]);
  }

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() async {
    final rows = _requireDb().select('''
      SELECT preference_json
      FROM comic_source_preference
      ORDER BY sort_order, source_id
    ''');
    return rows
        .map(
          (row) => _decodeSourcePreference(
            row['preference_json']! as String,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> saveSourcePreference(
    ComicSourcePreference preference,
  ) async {
    final db = _requireDb();
    final rows = db.select('''
      SELECT updated_us
      FROM comic_source_preference
      WHERE source_id = ?
      LIMIT 1
    ''', <Object?>[preference.sourceId]);
    if (rows.isNotEmpty &&
        (rows.first['updated_us']! as int) >
            preference.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    db.execute('''
      INSERT INTO comic_source_preference (
        source_id, enabled, sort_order, updated_us, preference_json
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        enabled = excluded.enabled,
        sort_order = excluded.sort_order,
        updated_us = excluded.updated_us,
        preference_json = excluded.preference_json
    ''', <Object?>[
      preference.sourceId,
      preference.enabled ? 1 : 0,
      preference.sortOrder,
      preference.updatedAt.toUtc().microsecondsSinceEpoch,
      jsonEncode(preference.toJson()),
    ]);
  }

  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) async {
    final rows = _requireDb().select('''
      SELECT issue_id, schema_from, entity_kind, legacy_key,
             resolved_source_id, detail_json, created_us, acknowledged_us
      FROM library_migration_issue
      ${includeAcknowledged ? '' : 'WHERE acknowledged_us IS NULL'}
      ORDER BY issue_id
    ''');
    return rows.map((row) {
      final rawDetails = jsonDecode(row['detail_json']! as String);
      if (rawDetails is! Map) {
        throw const FormatException('migration issue details must be an object');
      }
      return LibraryMigrationIssue(
        issueId: row['issue_id']! as int,
        schemaFrom: row['schema_from']! as int,
        entityKind: row['entity_kind']! as String,
        legacyKey: row['legacy_key']! as String,
        resolvedSourceId: row['resolved_source_id'] as String?,
        details: Map<String, Object?>.from(rawDetails),
        createdAt: DateTime.fromMicrosecondsSinceEpoch(
          row['created_us']! as int,
          isUtc: true,
        ),
        acknowledgedAt: row['acknowledged_us'] == null
            ? null
            : DateTime.fromMicrosecondsSinceEpoch(
                row['acknowledged_us']! as int,
                isUtc: true,
              ),
      );
    }).toList(growable: false);
  }

  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) async {
    final ids = issueIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final issueId in ids) {
        db.execute('''
          UPDATE library_migration_issue
          SET acknowledged_us = COALESCE(acknowledged_us, ?)
          WHERE issue_id = ?
        ''', <Object?>[
          acknowledgedAt.toUtc().microsecondsSinceEpoch,
          issueId,
        ]);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<SourceMigrationJournalRecord?> getSourceMigrationJournal(
    String migrationId,
  ) async {
    final rows = _requireDb().select(
      '''
      SELECT migration_id, source_source_id, source_comic_id,
             target_source_id, target_comic_id, replacing_source,
             prepared_fingerprint, phase, created_us, updated_us
      FROM source_migration_journal
      WHERE migration_id = ?
      LIMIT 1
    ''',
      <Object?>[migrationId],
    );
    return rows.isEmpty ? null : _readSourceMigrationJournal(rows.first);
  }

  @override
  Future<List<SourceMigrationJournalRecord>>
  listPendingSourceMigrations() async {
    final rows = _requireDb().select('''
      SELECT migration_id, source_source_id, source_comic_id,
             target_source_id, target_comic_id, replacing_source,
             prepared_fingerprint, phase, created_us, updated_us
      FROM source_migration_journal
      WHERE phase != 'done'
      ORDER BY created_us, migration_id
    ''');
    return rows.map(_readSourceMigrationJournal).toList(growable: false);
  }

  @override
  Future<SourceMigrationJournalRecord> beginSourceMigrationJournal(
    SourceMigrationJournalRecord record,
  ) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final existingRows = db.select(
        '''
        SELECT migration_id, source_source_id, source_comic_id,
               target_source_id, target_comic_id, replacing_source,
               prepared_fingerprint, phase, created_us, updated_us
        FROM source_migration_journal
        WHERE migration_id = ?
        LIMIT 1
      ''',
        <Object?>[record.migrationId],
      );
      if (existingRows.isNotEmpty) {
        final existing = _readSourceMigrationJournal(existingRows.first);
        if (existing.sourceSourceId != record.sourceSourceId ||
            existing.sourceComicId != record.sourceComicId ||
            existing.targetSourceId != record.targetSourceId ||
            existing.targetComicId != record.targetComicId ||
            existing.replacingSource != record.replacingSource ||
            existing.preparedFingerprint != record.preparedFingerprint) {
          throw StateError('source migration journal identity changed');
        }
        db.execute('COMMIT');
        return existing;
      }
      final conflicts = db.select(
        '''
        SELECT 1
        FROM source_migration_journal
        WHERE source_source_id = ? AND source_comic_id = ? AND phase != 'done'
        LIMIT 1
      ''',
        <Object?>[record.sourceSourceId, record.sourceComicId],
      );
      if (conflicts.isNotEmpty) {
        throw StateError('another source migration is already pending');
      }
      db.execute(
        '''
        INSERT INTO source_migration_journal (
          migration_id, source_source_id, source_comic_id,
          target_source_id, target_comic_id, replacing_source,
          prepared_fingerprint, phase, created_us, updated_us
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        <Object?>[
          record.migrationId,
          record.sourceSourceId,
          record.sourceComicId,
          record.targetSourceId,
          record.targetComicId,
          record.replacingSource ? 1 : 0,
          record.preparedFingerprint,
          record.phase.name,
          record.createdAt.toUtc().microsecondsSinceEpoch,
          record.updatedAt.toUtc().microsecondsSinceEpoch,
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
  Future<SourceMigrationJournalRecord> advanceSourceMigrationJournal(
    String migrationId, {
    required SourceMigrationPhase phase,
    required DateTime updatedAt,
  }) async {
    final db = _requireDb();
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        '''
        SELECT migration_id, source_source_id, source_comic_id,
               target_source_id, target_comic_id, replacing_source,
               prepared_fingerprint, phase, created_us, updated_us
        FROM source_migration_journal
        WHERE migration_id = ?
        LIMIT 1
      ''',
        <Object?>[migrationId],
      );
      if (rows.isEmpty) {
        throw StateError('source migration journal is missing');
      }
      final current = _readSourceMigrationJournal(rows.first);
      if (current.phase == phase) {
        db.execute('COMMIT');
        return current;
      }
      if (phase.index != current.phase.index + 1) {
        throw StateError('source migration phase must advance exactly once');
      }
      final next = SourceMigrationJournalRecord(
        migrationId: current.migrationId,
        sourceSourceId: current.sourceSourceId,
        sourceComicId: current.sourceComicId,
        targetSourceId: current.targetSourceId,
        targetComicId: current.targetComicId,
        replacingSource: current.replacingSource,
        preparedFingerprint: current.preparedFingerprint,
        phase: phase,
        createdAt: current.createdAt,
        updatedAt: updatedAt.toUtc(),
      );
      db.execute(
        '''
        UPDATE source_migration_journal
        SET phase = ?, updated_us = ?
        WHERE migration_id = ? AND phase = ?
      ''',
        <Object?>[
          phase.name,
          next.updatedAt.microsecondsSinceEpoch,
          migrationId,
          current.phase.name,
        ],
      );
      if (db.updatedRows != 1) {
        throw StateError('source migration journal changed concurrently');
      }
      db.execute('COMMIT');
      return next;
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> removeSourceMigrationJournal(String migrationId) async {
    _requireDb().execute(
      'DELETE FROM source_migration_journal WHERE migration_id = ?',
      <Object?>[migrationId],
    );
  }

  @override
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() async {
    final rows = _requireDb().select('''
      SELECT source_id, predecessor_comic_id, successor_comic_id,
             predecessor_title, discovered_us, page_mappings_json
      FROM comic_version_relation
      ORDER BY discovered_us DESC, source_id, predecessor_comic_id,
               successor_comic_id
    ''');
    return rows.map(_comicVersionRelationFromRow).toList(growable: false);
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT source_id, predecessor_comic_id, successor_comic_id,
             predecessor_title, discovered_us, page_mappings_json
      FROM comic_version_relation
      WHERE source_id = ? AND successor_comic_id = ?
      ORDER BY discovered_us DESC, predecessor_comic_id
    ''', <Object?>[sourceId, successorComicId]);
    return rows.map(_comicVersionRelationFromRow).toList(growable: false);
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT source_id, predecessor_comic_id, successor_comic_id,
             predecessor_title, discovered_us, page_mappings_json
      FROM comic_version_relation
      WHERE source_id = ? AND predecessor_comic_id = ?
      ORDER BY discovered_us DESC, successor_comic_id
    ''', <Object?>[sourceId, predecessorComicId]);
    return rows.map(_comicVersionRelationFromRow).toList(growable: false);
  }

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) async {
    if (relation.sourceId.trim().isEmpty ||
        relation.predecessorComicId.trim().isEmpty ||
        relation.successorComicId.trim().isEmpty ||
        relation.predecessorComicId == relation.successorComicId) {
      throw ArgumentError.value(relation, 'relation');
    }
    _requireDb().execute('''
      INSERT INTO comic_version_relation (
        source_id, predecessor_comic_id, successor_comic_id,
        predecessor_title, discovered_us, page_mappings_json
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(source_id, predecessor_comic_id, successor_comic_id)
      DO UPDATE SET
        predecessor_title = excluded.predecessor_title,
        page_mappings_json = CASE
          WHEN excluded.page_mappings_json = '[]'
          THEN comic_version_relation.page_mappings_json
          ELSE excluded.page_mappings_json
        END
    ''', <Object?>[
      relation.sourceId,
      relation.predecessorComicId,
      relation.successorComicId,
      relation.predecessorTitle,
      (relation.discoveredAt ?? DateTime.now().toUtc()).microsecondsSinceEpoch,
      jsonEncode(
        relation.pageMappings.map((mapping) => mapping.toJson()).toList(),
      ),
    ]);
  }

  SourceMigrationJournalRecord _readSourceMigrationJournal(sql.Row row) {
    return SourceMigrationJournalRecord(
      migrationId: row['migration_id']! as String,
      sourceSourceId: row['source_source_id']! as String,
      sourceComicId: row['source_comic_id']! as String,
      targetSourceId: row['target_source_id']! as String,
      targetComicId: row['target_comic_id']! as String,
      replacingSource: (row['replacing_source']! as int) != 0,
      preparedFingerprint: row['prepared_fingerprint']! as String,
      phase: SourceMigrationPhase.values.byName(row['phase']! as String),
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        row['created_us']! as int,
        isUtc: true,
      ),
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        row['updated_us']! as int,
        isUtc: true,
      ),
    );
  }

  ComicVersionRelation _comicVersionRelationFromRow(sql.Row row) =>
      ComicVersionRelation(
        sourceId: row['source_id']! as String,
        predecessorComicId: row['predecessor_comic_id']! as String,
        successorComicId: row['successor_comic_id']! as String,
        predecessorTitle: row['predecessor_title']! as String,
        discoveredAt: DateTime.fromMicrosecondsSinceEpoch(
          row['discovered_us']! as int,
          isUtc: true,
        ),
        pageMappings: _comicVersionPageMappingsFromJson(
          row['page_mappings_json']! as String,
        ),
      );

  @override
  Future<void> close() async {
    // Release the foreground connection before waiting for a background
    // writer that may still be waiting for SQLite's WAL lock. Waiting first
    // can deadlock on a fresh database where the writer is opening its second
    // connection for the first time.
    final db = _db;
    final progressWriter = _progressWriter;
    if (progressWriter != null) {
      _drainPendingReaderProgress(progressWriter);
    } else if (db != null) {
      // Close is a durable boundary. Preserve a checkpoint that arrived while
      // the isolate writer was unavailable without moving this fallback back
      // onto ordinary Reader page turns.
      _flushPendingReaderProgressSynchronously(db);
    }
    _db = null;
    _progressWriter = null;
    final progressWriterOpening = _progressWriterOpening;
    _progressWriterOpening = null;
    db?.dispose();
    await progressWriter?.close();
    await progressWriterOpening;
  }

  void _startProgressWriter(sql.Database db) {
    final dbPath = path;
    if (dbPath == null ||
        _progressWriter != null ||
        _progressWriterOpening != null) {
      return;
    }
    final retryAfter = _progressWriterRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return;
    }
    late final Future<void> opening;
    opening = SqliteProgressWriter.open(dbPath)
        .then<void>((writer) async {
          if (identical(_db, db)) {
            _progressWriter = writer;
            _progressWriterRetryAfter = null;
            _drainPendingReaderProgress(writer);
          } else {
            await writer.close();
          }
        })
        .catchError((Object _, StackTrace __) {
          // Keep the latest checkpoint buffered. A later Reader page turn may
          // retry opening the optional writer, but rate-limit repeated isolate
          // spawn failures so an unavailable optimization stays off the hot
          // path. Lifecycle/close flush remains the synchronous fallback.
          _progressWriterRetryAfter =
              DateTime.now().add(const Duration(seconds: 2));
        }).whenComplete(() {
          if (identical(_progressWriterOpening, opening)) {
            _progressWriterOpening = null;
          }
        });
    _progressWriterOpening = opening;
  }

  String _readerProgressIdentity(ReadingProgress progress) =>
      '${progress.sourceId}\u0000${progress.chapterId}';

  void _rememberPendingReaderProgress(ReadingProgress progress) {
    final key = _readerProgressIdentity(progress);
    final prior = _pendingReaderProgress[key];
    if (prior == null || !progress.updatedAt.isBefore(prior.updatedAt)) {
      _pendingReaderProgress[key] = progress;
    }
  }

  void _drainPendingReaderProgress(SqliteProgressWriter writer) {
    if (_pendingReaderProgress.isEmpty) return;
    final pending = _pendingReaderProgress.values.toList(growable: false);
    _pendingReaderProgress.clear();
    for (final progress in pending) {
      writer.enqueue(progress);
    }
  }

  void _flushPendingReaderProgressSynchronously(sql.Database db) {
    if (_pendingReaderProgress.isEmpty) return;
    final pending = _pendingReaderProgress.values.toList(growable: false);
    _pendingReaderProgress.clear();
    for (final progress in pending) {
      _saveProgressSynchronously(db, progress);
    }
  }

  void _putProgress(sql.Database db, ReadingProgress progress) {
    db.execute('''
      INSERT INTO reading_progress (
        source_id, chapter_id, updated_us, progress_json
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id, chapter_id) DO UPDATE SET
        updated_us = excluded.updated_us,
        progress_json = excluded.progress_json
    ''', <Object?>[
      progress.sourceId,
      progress.chapterId,
      progress.updatedAt.toUtc().microsecondsSinceEpoch,
      jsonEncode(progress.toJson()),
    ]);
  }

  void _putComicPreference(
    sql.Database db,
    ComicPreference preference,
  ) {
    db.execute('''
      INSERT INTO comic_preference (
        source_id, comic_id, updated_us, preference_json
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id, comic_id) DO UPDATE SET
        updated_us = excluded.updated_us,
        preference_json = excluded.preference_json
    ''', <Object?>[
      preference.sourceId,
      preference.comicId,
      preference.updatedAt.toUtc().microsecondsSinceEpoch,
      jsonEncode(preference.toJson()),
    ]);
  }

  ImportedLibraryEntry _readEntry(sql.Row row) {
    final chapter = _decodeChapter(row['chapter_json']! as String);
    final progressJson = row['progress_json'] as String?;
    return ImportedLibraryEntry(
      chapter: chapter,
      progress: progressJson == null
          ? null
          : _decodeProgress(
              progressJson,
              fallbackSourceId: chapter.sourceId,
            ),
    );
  }

  ImportedChapterRecord _decodeChapter(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored chapter must be an object');
    }
    return ImportedChapterRecord.fromJson(Map<String, Object?>.from(value));
  }

  ReadingProgress _decodeProgress(
    String source, {
    required String fallbackSourceId,
  }) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored progress must be an object');
    }
    return ReadingProgress.fromJson(
      Map<String, Object?>.from(value),
      fallbackSourceId: fallbackSourceId,
    );
  }

  SavedComicRecord _decodeSavedComic(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored comic must be an object');
    }
    return SavedComicRecord.fromJson(Map<String, Object?>.from(value));
  }

  LibraryCategory _decodeCategory(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored category must be an object');
    }
    return LibraryCategory.fromJson(Map<String, Object?>.from(value));
  }

  ComicPreference _decodePreference(
    String source, {
    required String fallbackSourceId,
  }) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored preference must be an object');
    }
    return ComicPreference.fromJson(
      Map<String, Object?>.from(value),
      fallbackSourceId: fallbackSourceId,
    );
  }

  ComicSourcePreference _decodeSourcePreference(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored source preference must be an object');
    }
    return ComicSourcePreference.fromJson(
      Map<String, Object?>.from(value),
    );
  }

  ChapterReadState _decodeReadState(
    String source, {
    required String fallbackSourceId,
  }) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored read state must be an object');
    }
    return ChapterReadState.fromJson(
      Map<String, Object?>.from(value),
      fallbackSourceId: fallbackSourceId,
    );
  }

  sql.Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('imported library store is not open');
    }
    return db;
  }
}

void _prepareLegacySchemaForMigration(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    // A few development builds wrote user_version before every table had been
    // created. Reconstruct the complete legacy surface with IF NOT EXISTS so
    // v1-v4 databases remain recoverable instead of failing midway through
    // the source-composite migration.
    _createLegacyImportedTables(db);
    _createLegacyPreferenceTables(db);
    _createSourcePreferenceTables(db);
    _createSavedComicTables(db);
    _createMigrationIssueTable(db);
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateMigrationIssueAcknowledgement(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _createMigrationIssueTable(db);
    final columns = db
        .select('PRAGMA table_info(library_migration_issue)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('acknowledged_us')) {
      db.execute('''
        ALTER TABLE library_migration_issue
        ADD COLUMN acknowledged_us INTEGER
      ''');
    }
    db.execute('''
      CREATE INDEX IF NOT EXISTS library_migration_issue_pending
      ON library_migration_issue(acknowledged_us, issue_id)
    ''');
    _createComicVersionRelationTable(db);
    _createLibraryProjectionRevision(db);
    _rebuildChapterReadStateWithoutChapterForeignKey(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateComicVersionRelations(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _createComicVersionRelationTable(db);
    _createLibraryProjectionRevision(db);
    _rebuildChapterReadStateWithoutChapterForeignKey(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateComicVersionPageMappings(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _createComicVersionRelationTable(db);
    final columns = db
        .select('PRAGMA table_info(comic_version_relation)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('page_mappings_json')) {
      db.execute("""
        ALTER TABLE comic_version_relation
        ADD COLUMN page_mappings_json TEXT NOT NULL DEFAULT '[]'
      """);
    }
    _createLibraryProjectionRevision(db);
    _rebuildChapterReadStateWithoutChapterForeignKey(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateLibraryProjectionRevision(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _createLibraryProjectionRevision(db);
    _rebuildChapterReadStateWithoutChapterForeignKey(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateChapterReadStateOwnership(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _rebuildChapterReadStateWithoutChapterForeignKey(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _migrateSourceMigrationJournal(sql.Database db) {
  db.execute('BEGIN IMMEDIATE');
  try {
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _rebuildChapterReadStateWithoutChapterForeignKey(sql.Database db) {
  // Read state is keyed by the source-owned chapter identity and may be
  // created while a compact detail projection has not materialized a full
  // imported chapter. Rebuild the v9 table once so that this path does not
  // need to fetch chapter metadata merely to toggle read/unread.
  final table = db.select('''
    SELECT 1
    FROM sqlite_master
    WHERE type = 'table' AND name = 'chapter_read_state'
    LIMIT 1
  ''');
  if (table.isEmpty) return;
  db.execute('DROP INDEX IF EXISTS chapter_read_state_comic');
  db.execute('ALTER TABLE chapter_read_state RENAME TO chapter_read_state_v9');
  db.execute('''
    CREATE TABLE chapter_read_state (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      read_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id)
    )
  ''');
  db.execute('''
    INSERT INTO chapter_read_state (
      source_id, chapter_id, comic_id, updated_us, read_json
    )
    SELECT source_id, chapter_id, comic_id, updated_us, read_json
    FROM chapter_read_state_v9
  ''');
  db.execute('DROP TABLE chapter_read_state_v9');
  db.execute('''
    CREATE INDEX chapter_read_state_comic
    ON chapter_read_state(source_id, comic_id, chapter_id)
  ''');
}

void _migrateToCompositeSchema(
  sql.Database db, {
  required int fromVersion,
}) {
  db.execute('PRAGMA foreign_keys = OFF');
  db.execute('BEGIN IMMEDIATE');
  try {
    _createMigrationIssueTable(db);
    _createCompositeMigrationTables(db);

    final chapterSources = <String, String>{};
    final chapterComics = <String, String>{};
    final sourcesByComic = <String, Set<String>>{};
    final importedUsByComicSource = <String, int>{};
    for (final row in db.select('''
      SELECT chapter_id, comic_id, imported_us, chapter_json
      FROM imported_chapter
    ''')) {
      final rowChapterId = row['chapter_id']! as String;
      final rowComicId = row['comic_id']! as String;
      final raw = jsonDecode(row['chapter_json']! as String);
      if (raw is! Map) {
        throw const FormatException('legacy chapter must be an object');
      }
      final decoded = ImportedChapterRecord.fromJson(
        Map<String, Object?>.from(raw),
      );
      final chapter = decoded.chapterId == rowChapterId &&
              decoded.comicId == rowComicId
          ? decoded
          : decoded.copyWith(
              chapterId: rowChapterId,
              comicId: rowComicId,
            );
      if (!identical(chapter, decoded)) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'imported_chapter',
          legacyKey: rowChapterId,
          resolvedSourceId: chapter.sourceId,
          details: <String, Object?>{
            'reason': 'row and JSON identities differed',
            'jsonChapterId': decoded.chapterId,
            'jsonComicId': decoded.comicId,
            'resolvedComicId': rowComicId,
            'action': 'row identity retained and JSON normalized',
          },
        );
      }
      chapterSources[rowChapterId] = chapter.sourceId;
      chapterComics[rowChapterId] = rowComicId;
      sourcesByComic
          .putIfAbsent(rowComicId, () => <String>{})
          .add(chapter.sourceId);
      final recentKey = comicLibraryIdentity(chapter.sourceId, rowComicId);
      final importedUs = row['imported_us']! as int;
      final previous = importedUsByComicSource[recentKey];
      if (previous == null || importedUs > previous) {
        importedUsByComicSource[recentKey] = importedUs;
      }
      db.execute('''
        INSERT INTO imported_chapter_v5 (
          source_id, chapter_id, comic_id, imported_us, chapter_json
        ) VALUES (?, ?, ?, ?, ?)
      ''', <Object?>[
        chapter.sourceId,
        rowChapterId,
        rowComicId,
        importedUs,
        jsonEncode(chapter.toJson()),
      ]);
    }

    for (final row in db.select('''
      SELECT chapter_id, updated_us, progress_json
      FROM reading_progress
    ''')) {
      final chapterId = row['chapter_id']! as String;
      final sourceId = chapterSources[chapterId];
      if (sourceId == null) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'reading_progress',
          legacyKey: chapterId,
          resolvedSourceId: null,
          details: const <String, Object?>{
            'reason': 'missing imported chapter owner',
            'action': 'record skipped',
          },
        );
        continue;
      }
      final raw = jsonDecode(row['progress_json']! as String);
      if (raw is! Map) {
        throw const FormatException('legacy progress must be an object');
      }
      final decoded = ReadingProgress.fromJson(
        Map<String, Object?>.from(raw),
        fallbackSourceId: sourceId,
      );
      final comicId = chapterComics[chapterId]!;
      final progress = ReadingProgress(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        pageIndex: decoded.pageIndex,
        subPageOffset: decoded.subPageOffset,
        readerMode: decoded.readerMode,
        updatedAt: decoded.updatedAt,
      );
      if (decoded.sourceId != sourceId ||
          decoded.comicId != comicId ||
          decoded.chapterId != chapterId) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'reading_progress',
          legacyKey: chapterId,
          resolvedSourceId: sourceId,
          details: <String, Object?>{
            'reason': 'progress identity differed from owning chapter',
            'jsonSourceId': decoded.sourceId,
            'jsonComicId': decoded.comicId,
            'jsonChapterId': decoded.chapterId,
            'resolvedComicId': comicId,
            'action': 'owning chapter identity retained',
          },
        );
      }
      db.execute('''
        INSERT INTO reading_progress_v5 (
          source_id, chapter_id, updated_us, progress_json
        ) VALUES (?, ?, ?, ?)
      ''', <Object?>[
        sourceId,
        chapterId,
        row['updated_us']! as int,
        jsonEncode(progress.toJson()),
      ]);
    }

    final savedCandidates = <String, Map<String, int>>{};
    for (final row in db.select('''
      SELECT source_id, comic_id, updated_us
      FROM saved_comic
    ''')) {
      final sourceId = row['source_id']! as String;
      final comicId = row['comic_id']! as String;
      sourcesByComic.putIfAbsent(comicId, () => <String>{}).add(sourceId);
      savedCandidates
          .putIfAbsent(comicId, () => <String, int>{})[sourceId] =
          row['updated_us']! as int;
    }

    for (final row in db.select('''
      SELECT comic_id, updated_us, preference_json
      FROM comic_preference
    ''')) {
      final comicId = row['comic_id']! as String;
      final raw = jsonDecode(row['preference_json']! as String);
      if (raw is! Map) {
        throw const FormatException('legacy preference must be an object');
      }
      final legacyJson = Map<String, Object?>.from(raw);
      final sourceKind = ComicSourceKind.values.byName(
        legacyJson['sourceKind']! as String,
      );
      final candidates = sourcesByComic[comicId] ?? const <String>{};
      final resolution = _resolveLegacyPreferenceSource(
        comicId: comicId,
        sourceKind: sourceKind,
        candidates: candidates,
        savedUpdatedUs: savedCandidates[comicId] ?? const <String, int>{},
        importedUsByComicSource: importedUsByComicSource,
      );
      final decoded = ComicPreference.fromJson(
        legacyJson,
        fallbackSourceId: resolution.sourceId,
      );
      final preference = ComicPreference(
        sourceId: resolution.sourceId,
        comicId: comicId,
        sourceKind: decoded.sourceKind,
        inShelf: decoded.inShelf,
        liked: decoded.liked,
        collected: decoded.collected,
        categoryIds: decoded.categoryIds,
        customOrder: decoded.customOrder,
        updatedAt: decoded.updatedAt,
      );
      db.execute('''
        INSERT INTO comic_preference_v5 (
          source_id, comic_id, updated_us, preference_json
        ) VALUES (?, ?, ?, ?)
      ''', <Object?>[
        resolution.sourceId,
        comicId,
        row['updated_us']! as int,
        jsonEncode(preference.toJson()),
      ]);
      if (resolution.reason != null ||
          decoded.sourceId != resolution.sourceId ||
          decoded.comicId != comicId) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'comic_preference',
          legacyKey: comicId,
          resolvedSourceId: resolution.sourceId,
          details: <String, Object?>{
            'reason': resolution.reason ??
                'preference identity differed from legacy row ownership',
            'jsonSourceId': decoded.sourceId,
            'jsonComicId': decoded.comicId,
            'candidates': candidates.toList(growable: false)..sort(),
            'action': 'preference assigned to resolved source and row comic',
          },
        );
      }
    }

    for (final row in db.select('''
      SELECT chapter_id, comic_id, updated_us, read_json
      FROM chapter_read_state
    ''')) {
      final chapterId = row['chapter_id']! as String;
      final sourceId = chapterSources[chapterId];
      if (sourceId == null) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'chapter_read_state',
          legacyKey: chapterId,
          resolvedSourceId: null,
          details: const <String, Object?>{
            'reason': 'missing imported chapter owner',
            'action': 'record skipped',
          },
        );
        continue;
      }
      final raw = jsonDecode(row['read_json']! as String);
      if (raw is! Map) {
        throw const FormatException('legacy read state must be an object');
      }
      final decoded = ChapterReadState.fromJson(
        Map<String, Object?>.from(raw),
        fallbackSourceId: sourceId,
      );
      final comicId = chapterComics[chapterId]!;
      final state = ChapterReadState(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        isRead: decoded.isRead,
        updatedAt: decoded.updatedAt,
      );
      if (decoded.sourceId != sourceId ||
          decoded.comicId != comicId ||
          decoded.chapterId != chapterId) {
        _recordMigrationIssue(
          db,
          schemaFrom: fromVersion,
          entityKind: 'chapter_read_state',
          legacyKey: chapterId,
          resolvedSourceId: sourceId,
          details: <String, Object?>{
            'reason': 'read-state identity differed from owning chapter',
            'jsonSourceId': decoded.sourceId,
            'jsonComicId': decoded.comicId,
            'jsonChapterId': decoded.chapterId,
            'resolvedComicId': comicId,
            'action': 'owning chapter identity retained',
          },
        );
      }
      db.execute('''
        INSERT INTO chapter_read_state_v5 (
          source_id, chapter_id, comic_id, updated_us, read_json
        ) VALUES (?, ?, ?, ?, ?)
      ''', <Object?>[
        sourceId,
        chapterId,
        comicId,
        row['updated_us']! as int,
        jsonEncode(state.toJson()),
      ]);
    }

    db.execute('DROP TABLE reading_progress');
    db.execute('DROP TABLE chapter_read_state');
    db.execute('DROP TABLE comic_preference');
    db.execute('DROP TABLE imported_chapter');
    db.execute('ALTER TABLE imported_chapter_v5 RENAME TO imported_chapter');
    db.execute('ALTER TABLE reading_progress_v5 RENAME TO reading_progress');
    db.execute('ALTER TABLE comic_preference_v5 RENAME TO comic_preference');
    db.execute('ALTER TABLE chapter_read_state_v5 RENAME TO chapter_read_state');
    _createCompositeIndexes(db);
    final foreignKeyFailures = db.select('PRAGMA foreign_key_check');
    if (foreignKeyFailures.isNotEmpty) {
      throw StateError(
        'composite library migration created invalid foreign keys: '
        '${foreignKeyFailures.length}',
      );
    }
    _createComicVersionRelationTable(db);
    _createLibraryProjectionRevision(db);
    _createSourceMigrationJournalTable(db);
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.execute('PRAGMA foreign_keys = ON');
  }
}

final class _PreferenceSourceResolution {
  const _PreferenceSourceResolution(this.sourceId, this.reason);

  final String sourceId;
  final String? reason;
}

_PreferenceSourceResolution _resolveLegacyPreferenceSource({
  required String comicId,
  required ComicSourceKind sourceKind,
  required Set<String> candidates,
  required Map<String, int> savedUpdatedUs,
  required Map<String, int> importedUsByComicSource,
}) {
  if (sourceKind == ComicSourceKind.local) {
    return _PreferenceSourceResolution(
      'local-folder',
      candidates.isEmpty || candidates.contains('local-folder')
          ? null
          : 'local preference had non-local source candidates',
    );
  }
  if (candidates.length == 1) {
    return _PreferenceSourceResolution(candidates.single, null);
  }
  if (candidates.isEmpty) {
    return const _PreferenceSourceResolution(
      'legacy-remote',
      'remote preference had no source owner',
    );
  }
  final ordered = candidates.toList(growable: false)
    ..sort((left, right) {
      final leftSaved = savedUpdatedUs[left] ?? -1;
      final rightSaved = savedUpdatedUs[right] ?? -1;
      final savedOrder = rightSaved.compareTo(leftSaved);
      if (savedOrder != 0) {
        return savedOrder;
      }
      final leftImported =
          importedUsByComicSource[comicLibraryIdentity(left, comicId)] ?? -1;
      final rightImported =
          importedUsByComicSource[comicLibraryIdentity(right, comicId)] ?? -1;
      final importedOrder = rightImported.compareTo(leftImported);
      return importedOrder != 0 ? importedOrder : left.compareTo(right);
    });
  return _PreferenceSourceResolution(
    ordered.first,
    'remote preference had multiple source owners',
  );
}

void _recordMigrationIssue(
  sql.Database db, {
  required int schemaFrom,
  required String entityKind,
  required String legacyKey,
  required String? resolvedSourceId,
  required Map<String, Object?> details,
}) {
  db.execute('''
    INSERT INTO library_migration_issue (
      schema_from, entity_kind, legacy_key, resolved_source_id,
      detail_json, created_us
    ) VALUES (?, ?, ?, ?, ?, ?)
  ''', <Object?>[
    schemaFrom,
    entityKind,
    legacyKey,
    resolvedSourceId,
    jsonEncode(details),
    DateTime.now().toUtc().microsecondsSinceEpoch,
  ]);
}

void _createCompositeLibraryTables(sql.Database db) {
  db.execute('''
    CREATE TABLE imported_chapter (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      imported_us INTEGER NOT NULL,
      chapter_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id)
    )
  ''');
  db.execute('''
    CREATE TABLE reading_progress (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      progress_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id),
      FOREIGN KEY(source_id, chapter_id)
        REFERENCES imported_chapter(source_id, chapter_id)
        ON DELETE CASCADE
    )
  ''');
  db.execute('''
    CREATE TABLE comic_preference (
      source_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      preference_json TEXT NOT NULL,
      PRIMARY KEY(source_id, comic_id)
    )
  ''');
  db.execute('''
    CREATE TABLE chapter_read_state (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      read_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id)
    )
  ''');
  _createCompositeIndexes(db);
}

void _createCompositeMigrationTables(sql.Database db) {
  db.execute('''
    CREATE TABLE imported_chapter_v5 (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      imported_us INTEGER NOT NULL,
      chapter_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id)
    )
  ''');
  db.execute('''
    CREATE TABLE reading_progress_v5 (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      progress_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id),
      FOREIGN KEY(source_id, chapter_id)
        REFERENCES imported_chapter_v5(source_id, chapter_id)
        ON DELETE CASCADE
    )
  ''');
  db.execute('''
    CREATE TABLE comic_preference_v5 (
      source_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      preference_json TEXT NOT NULL,
      PRIMARY KEY(source_id, comic_id)
    )
  ''');
  db.execute('''
    CREATE TABLE chapter_read_state_v5 (
      source_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      read_json TEXT NOT NULL,
      PRIMARY KEY(source_id, chapter_id),
      FOREIGN KEY(source_id, chapter_id)
        REFERENCES imported_chapter_v5(source_id, chapter_id)
        ON DELETE CASCADE
    )
  ''');
}

void _createCompositeIndexes(sql.Database db) {
  db.execute('''
    CREATE INDEX IF NOT EXISTS imported_chapter_recent
    ON imported_chapter(imported_us DESC, source_id, chapter_id)
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS imported_chapter_comic
    ON imported_chapter(source_id, comic_id, chapter_id)
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS chapter_read_state_comic
    ON chapter_read_state(source_id, comic_id, chapter_id)
  ''');
}

void _createCategoryTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS library_category (
      category_id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL,
      category_json TEXT NOT NULL
    )
  ''');
}

void _createLegacyImportedTables(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS imported_chapter (
      chapter_id TEXT NOT NULL PRIMARY KEY,
      comic_id TEXT NOT NULL,
      imported_us INTEGER NOT NULL,
      chapter_json TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS reading_progress (
      chapter_id TEXT NOT NULL PRIMARY KEY,
      updated_us INTEGER NOT NULL,
      progress_json TEXT NOT NULL,
      FOREIGN KEY(chapter_id) REFERENCES imported_chapter(chapter_id)
        ON DELETE CASCADE
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS imported_chapter_recent
    ON imported_chapter(imported_us DESC, chapter_id)
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS imported_chapter_comic
    ON imported_chapter(comic_id, chapter_id)
  ''');
}

void _createLegacyPreferenceTables(sql.Database db) {
  _createCategoryTable(db);
  db.execute('''
    CREATE TABLE IF NOT EXISTS comic_preference (
      comic_id TEXT NOT NULL PRIMARY KEY,
      updated_us INTEGER NOT NULL,
      preference_json TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS chapter_read_state (
      chapter_id TEXT NOT NULL PRIMARY KEY,
      comic_id TEXT NOT NULL,
      updated_us INTEGER NOT NULL,
      read_json TEXT NOT NULL,
      FOREIGN KEY(chapter_id) REFERENCES imported_chapter(chapter_id)
        ON DELETE CASCADE
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS chapter_read_state_comic
    ON chapter_read_state(comic_id, chapter_id)
  ''');
}

void _createSavedComicTables(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS saved_comic (
      source_id TEXT NOT NULL,
      comic_id TEXT NOT NULL,
      saved_us INTEGER NOT NULL,
      updated_us INTEGER NOT NULL,
      comic_json TEXT NOT NULL,
      PRIMARY KEY(source_id, comic_id)
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS saved_comic_recent
    ON saved_comic(updated_us DESC, source_id, comic_id)
  ''');
}

void _createSourcePreferenceTables(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS comic_source_preference (
      source_id TEXT NOT NULL PRIMARY KEY,
      enabled INTEGER NOT NULL,
      sort_order INTEGER NOT NULL,
      updated_us INTEGER NOT NULL,
      preference_json TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS comic_source_preference_order
    ON comic_source_preference(sort_order, source_id)
  ''');
}

void _createSourceMigrationJournalTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS source_migration_journal (
      migration_id TEXT NOT NULL PRIMARY KEY,
      source_source_id TEXT NOT NULL,
      source_comic_id TEXT NOT NULL,
      target_source_id TEXT NOT NULL,
      target_comic_id TEXT NOT NULL,
      replacing_source INTEGER NOT NULL,
      prepared_fingerprint TEXT NOT NULL,
      phase TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      updated_us INTEGER NOT NULL,
      CHECK (replacing_source IN (0, 1)),
      CHECK (phase IN ('prepared', 'artifactsReady', 'metadataCommitted', 'cleanupPending', 'done'))
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS source_migration_journal_pending_source
    ON source_migration_journal(source_source_id, source_comic_id, phase, created_us)
  ''');
}

void _createMigrationIssueTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS library_migration_issue (
      issue_id INTEGER PRIMARY KEY AUTOINCREMENT,
      schema_from INTEGER NOT NULL,
      entity_kind TEXT NOT NULL,
      legacy_key TEXT NOT NULL,
      resolved_source_id TEXT,
      detail_json TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      acknowledged_us INTEGER
    )
  ''');
  final columns = db
      .select('PRAGMA table_info(library_migration_issue)')
      .map((row) => row['name'] as String)
      .toSet();
  if (columns.contains('acknowledged_us')) {
    db.execute('''
      CREATE INDEX IF NOT EXISTS library_migration_issue_pending
      ON library_migration_issue(acknowledged_us, issue_id)
    ''');
  }
}

List<ComicVersionPageMapping> _comicVersionPageMappingsFromJson(
  String raw,
) {
  final value = jsonDecode(raw);
  if (value is! List) {
    throw const FormatException(
      'stored comic version page mappings must be a list',
    );
  }
  return List<ComicVersionPageMapping>.unmodifiable(
    value.map((item) {
      if (item is! Map) {
        throw const FormatException(
          'stored comic version page mapping must be an object',
        );
      }
      return ComicVersionPageMapping.fromJson(
        Map<String, Object?>.from(item),
      );
    }),
  );
}

void _createComicVersionRelationTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS comic_version_relation (
      source_id TEXT NOT NULL,
      predecessor_comic_id TEXT NOT NULL,
      successor_comic_id TEXT NOT NULL,
      predecessor_title TEXT NOT NULL,
      discovered_us INTEGER NOT NULL,
      page_mappings_json TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY(source_id, predecessor_comic_id, successor_comic_id)
    )
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS comic_version_relation_successor
    ON comic_version_relation(source_id, successor_comic_id, discovered_us DESC)
  ''');
  db.execute('''
    CREATE INDEX IF NOT EXISTS comic_version_relation_predecessor
    ON comic_version_relation(source_id, predecessor_comic_id, discovered_us DESC)
  ''');
}

void _createLibraryProjectionRevision(sql.Database db) {
  final startedAt = Stopwatch()..start();
  _storageLog('projection-revision-schema-start');
  db.execute('''
    CREATE TABLE IF NOT EXISTS library_projection_revision (
      singleton INTEGER NOT NULL PRIMARY KEY CHECK(singleton = 1),
      revision INTEGER NOT NULL
    )
  ''');
  db.execute('''
    INSERT OR IGNORE INTO library_projection_revision (singleton, revision)
    VALUES (1, 0)
  ''');

  const tables = <String>[
    'imported_chapter',
    'reading_progress',
    'comic_preference',
    'chapter_read_state',
    'library_category',
    'saved_comic',
    'comic_source_preference',
    'comic_version_relation',
  ];
  final existingTables = db
      .select("SELECT name FROM sqlite_master WHERE type = 'table'")
      .map((row) => row['name']! as String)
      .toSet();
  for (final table in tables) {
    if (!existingTables.contains(table)) {
      continue;
    }
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${table}_projection_revision_insert
      AFTER INSERT ON $table
      BEGIN
        UPDATE library_projection_revision
        SET revision = revision + 1
        WHERE singleton = 1;
      END
    ''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${table}_projection_revision_update
      AFTER UPDATE ON $table
      BEGIN
        UPDATE library_projection_revision
        SET revision = revision + 1
        WHERE singleton = 1;
      END
    ''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS ${table}_projection_revision_delete
      AFTER DELETE ON $table
      BEGIN
        UPDATE library_projection_revision
        SET revision = revision + 1
        WHERE singleton = 1;
      END
    ''');
  }
  _storageLog(
    'projection-revision-schema-complete '
    'durationMs=${startedAt.elapsedMilliseconds}',
  );
}

void _storageLog(String message) {
  print('[zic-storage] $message');
}

Future<void> _logLibraryStorageBytes(String dbPath) async {
  final startedAt = Stopwatch()..start();
  try {
    final sizes = await Future.wait<int>(<Future<int>>[
      File(dbPath).length(),
      File('$dbPath-wal').length(),
      File('$dbPath-shm').length(),
    ]);
    _storageLog(
      'library-storage-size databaseBytes=${sizes[0]} '
      'walBytes=${sizes[1]} shmBytes=${sizes[2]} '
      'durationMs=${startedAt.elapsedMilliseconds}',
    );
  } on Object catch (error) {
    _storageLog(
      'library-storage-size-failed '
      'durationMs=${startedAt.elapsedMilliseconds} '
      'errorType=${error.runtimeType}',
    );
  }
}
