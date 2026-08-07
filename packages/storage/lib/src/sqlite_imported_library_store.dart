import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

const _schemaVersion = 7;

final class SqliteImportedLibraryStore
    implements ImportedLibraryStore, ComicVersionRelationStore {
  SqliteImportedLibraryStore(this.path);

  SqliteImportedLibraryStore.memory() : path = null;

  final String? path;
  sql.Database? _db;

  @override
  Future<void> open() async {
    if (_db != null) {
      return;
    }
    final dbPath = path;
    if (dbPath != null) {
      await File(dbPath).parent.create(recursive: true);
    }
    final db = dbPath == null
        ? sql.sqlite3.openInMemory()
        : sql.sqlite3.open(dbPath);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA busy_timeout = 5000');
      final version =
          db.select('PRAGMA user_version').first.values.first as int;
      if (version == 0) {
        db.execute('BEGIN IMMEDIATE');
        try {
          _createCompositeLibraryTables(db);
          _createCategoryTable(db);
          _createSourcePreferenceTables(db);
          _createSavedComicTables(db);
          _createMigrationIssueTable(db);
          _createComicVersionRelationTable(db);
          db.execute('PRAGMA user_version = $_schemaVersion');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version >= 1 && version <= 4) {
        _prepareLegacySchemaForMigration(db);
        _migrateToCompositeSchema(db, fromVersion: version);
      } else if (version == 5) {
        _migrateMigrationIssueAcknowledgement(db);
      } else if (version == 6) {
        _migrateComicVersionRelations(db);
      } else if (version != _schemaVersion) {
        throw StateError(
          'unsupported imported library schema version: $version',
        );
      }
      _db = db;
    } on Object {
      db.dispose();
      rethrow;
    }
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
    final db = _requireDb();
    final rows = db.select('''
      SELECT chapter_json
      FROM imported_chapter
      WHERE source_id = ? AND chapter_id = ?
      LIMIT 1
    ''', <Object?>[progress.sourceId, progress.chapterId]);
    if (rows.isEmpty) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    final chapter = _decodeChapter(rows.first['chapter_json']! as String);
    if (progress.sourceId != chapter.sourceId ||
        progress.comicId != chapter.comicId) {
      throw StateError('progress identity does not match the chapter');
    }
    if (progress.pageIndex < 0 || progress.pageIndex >= chapter.pages.length) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        chapter.pages.length - 1,
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
    if (rows.isEmpty) {
      return;
    }
    final comicId = rows.first['comic_id']! as String;
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
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT source_id, predecessor_comic_id, successor_comic_id,
             predecessor_title
      FROM comic_version_relation
      WHERE source_id = ? AND successor_comic_id = ?
      ORDER BY discovered_us DESC, predecessor_comic_id
    ''', <Object?>[sourceId, successorComicId]);
    return rows
        .map(
          (row) => ComicVersionRelation(
            sourceId: row['source_id']! as String,
            predecessorComicId: row['predecessor_comic_id']! as String,
            successorComicId: row['successor_comic_id']! as String,
            predecessorTitle: row['predecessor_title']! as String,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) async {
    final rows = _requireDb().select('''
      SELECT source_id, predecessor_comic_id, successor_comic_id,
             predecessor_title
      FROM comic_version_relation
      WHERE source_id = ? AND predecessor_comic_id = ?
      ORDER BY discovered_us DESC, successor_comic_id
    ''', <Object?>[sourceId, predecessorComicId]);
    return rows
        .map(
          (row) => ComicVersionRelation(
            sourceId: row['source_id']! as String,
            predecessorComicId: row['predecessor_comic_id']! as String,
            successorComicId: row['successor_comic_id']! as String,
            predecessorTitle: row['predecessor_title']! as String,
          ),
        )
        .toList(growable: false);
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
        predecessor_title, discovered_us
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(source_id, predecessor_comic_id, successor_comic_id)
      DO UPDATE SET
        predecessor_title = excluded.predecessor_title,
        discovered_us = excluded.discovered_us
    ''', <Object?>[
      relation.sourceId,
      relation.predecessorComicId,
      relation.successorComicId,
      relation.predecessorTitle,
      DateTime.now().toUtc().microsecondsSinceEpoch,
    ]);
  }

  @override
  Future<void> close() async {
    _db?.dispose();
    _db = null;
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
    db.execute('PRAGMA user_version = $_schemaVersion');
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
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
      PRIMARY KEY(source_id, chapter_id),
      FOREIGN KEY(source_id, chapter_id)
        REFERENCES imported_chapter(source_id, chapter_id)
        ON DELETE CASCADE
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

void _createComicVersionRelationTable(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS comic_version_relation (
      source_id TEXT NOT NULL,
      predecessor_comic_id TEXT NOT NULL,
      successor_comic_id TEXT NOT NULL,
      predecessor_title TEXT NOT NULL,
      discovered_us INTEGER NOT NULL,
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
