import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

final class SqliteImportedLibraryStore implements ImportedLibraryStore {
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
          _createImportedLibraryTables(db);
          _createLibraryPreferenceTables(db);
          _createSourcePreferenceTables(db);
          db.execute('PRAGMA user_version = 3');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version == 1) {
        db.execute('BEGIN IMMEDIATE');
        try {
          _createLibraryPreferenceTables(db);
          _createSourcePreferenceTables(db);
          db.execute('PRAGMA user_version = 3');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version == 2) {
        db.execute('BEGIN IMMEDIATE');
        try {
          _createSourcePreferenceTables(db);
          db.execute('PRAGMA user_version = 3');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version != 3) {
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
      LEFT JOIN reading_progress AS p ON p.chapter_id = c.chapter_id
      ORDER BY c.imported_us DESC, c.chapter_id
    ''');
    return rows.map(_readEntry).toList(growable: false);
  }

  @override
  Future<ImportedLibraryEntry?> get(String chapterId) async {
    final rows = _requireDb().select('''
      SELECT c.chapter_json, p.progress_json
      FROM imported_chapter AS c
      LEFT JOIN reading_progress AS p ON p.chapter_id = c.chapter_id
      WHERE c.chapter_id = ?
      LIMIT 1
    ''', <Object?>[chapterId]);
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
        LEFT JOIN reading_progress AS p ON p.chapter_id = c.chapter_id
        WHERE c.chapter_id = ?
        LIMIT 1
      ''', <Object?>[chapter.chapterId]);
      final previousChapter = existingRows.isEmpty
          ? null
          : _decodeChapter(existingRows.first['chapter_json']! as String);
      final previousProgress = existingRows.isEmpty ||
              existingRows.first['progress_json'] == null
          ? null
          : _decodeProgress(existingRows.first['progress_json']! as String);
      db.execute('''
        INSERT INTO imported_chapter (
          chapter_id, comic_id, imported_us, chapter_json
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT(chapter_id) DO UPDATE SET
          comic_id = excluded.comic_id,
          imported_us = excluded.imported_us,
          chapter_json = excluded.chapter_json
      ''', <Object?>[
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
    final rows = db.select(
      'SELECT comic_id, chapter_json FROM imported_chapter '
      'WHERE chapter_id = ? LIMIT 1',
      <Object?>[progress.chapterId],
    );
    if (rows.isEmpty) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    final chapter = _decodeChapter(rows.first['chapter_json']! as String);
    if (progress.comicId != chapter.comicId) {
      throw StateError('progress comic identity does not match the chapter');
    }
    if (progress.pageIndex < 0 || progress.pageIndex >= chapter.pages.length) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        chapter.pages.length - 1,
        'progress.pageIndex',
      );
    }
    final current = db.select(
      'SELECT updated_us FROM reading_progress WHERE chapter_id = ? LIMIT 1',
      <Object?>[progress.chapterId],
    );
    if (current.isNotEmpty &&
        (current.first['updated_us']! as int) >
            progress.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    _putProgress(db, progress);
  }

  @override
  Future<void> removeChapter(String chapterId) async {
    final db = _requireDb();
    final rows = db.select(
      'SELECT comic_id FROM imported_chapter WHERE chapter_id = ? LIMIT 1',
      <Object?>[chapterId],
    );
    if (rows.isEmpty) {
      return;
    }
    final comicId = rows.first['comic_id']! as String;
    db.execute(
      'DELETE FROM imported_chapter WHERE chapter_id = ?',
      <Object?>[chapterId],
    );
    final remaining = db.select(
      'SELECT 1 FROM imported_chapter WHERE comic_id = ? LIMIT 1',
      <Object?>[comicId],
    );
    if (remaining.isEmpty) {
      db.execute(
        'DELETE FROM comic_preference WHERE comic_id = ?',
        <Object?>[comicId],
      );
    }
  }

  @override
  Future<List<LibraryCategory>> listCategories() async {
    final rows = _requireDb().select('''
      SELECT category_json
      FROM library_category
      ORDER BY sort_order, name COLLATE NOCASE, category_id
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
        'SELECT preference_json FROM comic_preference',
      );
      for (final row in rows) {
        final preference =
            _decodePreference(row['preference_json']! as String);
        if (!preference.categoryIds.contains(categoryId)) {
          continue;
        }
        final updated = preference.copyWith(
          categoryIds: preference.categoryIds.where((id) => id != categoryId),
          updatedAt: DateTime.now().toUtc(),
        );
        _putComicPreference(db, updated);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<ComicPreference>> listComicPreferences() async {
    final rows = _requireDb().select(
      'SELECT preference_json FROM comic_preference',
    );
    return rows
        .map((row) => _decodePreference(row['preference_json']! as String))
        .toList(growable: false);
  }

  @override
  Future<ComicPreference?> getComicPreference(String comicId) async {
    final rows = _requireDb().select(
      'SELECT preference_json FROM comic_preference '
      'WHERE comic_id = ? LIMIT 1',
      <Object?>[comicId],
    );
    return rows.isEmpty
        ? null
        : _decodePreference(rows.first['preference_json']! as String);
  }

  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    final db = _requireDb();
    final rows = db.select(
      'SELECT updated_us FROM comic_preference WHERE comic_id = ? LIMIT 1',
      <Object?>[preference.comicId],
    );
    if (rows.isNotEmpty &&
        (rows.first['updated_us']! as int) >
            preference.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    _putComicPreference(db, preference);
  }

  @override
  Future<List<ChapterReadState>> listChapterReadStates(String comicId) async {
    final rows = _requireDb().select('''
      SELECT read_json
      FROM chapter_read_state
      WHERE comic_id = ?
      ORDER BY chapter_id
    ''', <Object?>[comicId]);
    return rows
        .map((row) => _decodeReadState(row['read_json']! as String))
        .toList(growable: false);
  }

  @override
  Future<void> saveChapterReadState(ChapterReadState state) async {
    final db = _requireDb();
    final rows = db.select(
      'SELECT updated_us FROM chapter_read_state '
      'WHERE chapter_id = ? LIMIT 1',
      <Object?>[state.chapterId],
    );
    if (rows.isNotEmpty &&
        (rows.first['updated_us']! as int) >
            state.updatedAt.toUtc().microsecondsSinceEpoch) {
      return;
    }
    db.execute('''
      INSERT INTO chapter_read_state (
        chapter_id, comic_id, updated_us, read_json
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(chapter_id) DO UPDATE SET
        comic_id = excluded.comic_id,
        updated_us = excluded.updated_us,
        read_json = excluded.read_json
    ''', <Object?>[
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
        .map((row) => _decodeSourcePreference(
              row['preference_json']! as String,
            ))
        .toList(growable: false);
  }

  @override
  Future<void> saveSourcePreference(
    ComicSourcePreference preference,
  ) async {
    final db = _requireDb();
    final rows = db.select(
      'SELECT updated_us FROM comic_source_preference '
      'WHERE source_id = ? LIMIT 1',
      <Object?>[preference.sourceId],
    );
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
  Future<void> close() async {
    _db?.dispose();
    _db = null;
  }

  void _putProgress(sql.Database db, ReadingProgress progress) {
    db.execute('''
      INSERT INTO reading_progress (chapter_id, updated_us, progress_json)
      VALUES (?, ?, ?)
      ON CONFLICT(chapter_id) DO UPDATE SET
        updated_us = excluded.updated_us,
        progress_json = excluded.progress_json
    ''', <Object?>[
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
      INSERT INTO comic_preference (comic_id, updated_us, preference_json)
      VALUES (?, ?, ?)
      ON CONFLICT(comic_id) DO UPDATE SET
        updated_us = excluded.updated_us,
        preference_json = excluded.preference_json
    ''', <Object?>[
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
      progress: progressJson == null ? null : _decodeProgress(progressJson),
    );
  }

  ImportedChapterRecord _decodeChapter(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored chapter must be an object');
    }
    return ImportedChapterRecord.fromJson(Map<String, Object?>.from(value));
  }

  ReadingProgress _decodeProgress(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored progress must be an object');
    }
    return ReadingProgress.fromJson(Map<String, Object?>.from(value));
  }

  LibraryCategory _decodeCategory(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored category must be an object');
    }
    return LibraryCategory.fromJson(Map<String, Object?>.from(value));
  }

  ComicPreference _decodePreference(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored preference must be an object');
    }
    return ComicPreference.fromJson(Map<String, Object?>.from(value));
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

  ChapterReadState _decodeReadState(String source) {
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('stored read state must be an object');
    }
    return ChapterReadState.fromJson(Map<String, Object?>.from(value));
  }

  sql.Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('imported library store is not open');
    }
    return db;
  }
}

void _createImportedLibraryTables(sql.Database db) {
  db.execute('''
    CREATE TABLE imported_chapter (
      chapter_id TEXT NOT NULL PRIMARY KEY,
      comic_id TEXT NOT NULL,
      imported_us INTEGER NOT NULL,
      chapter_json TEXT NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE reading_progress (
      chapter_id TEXT NOT NULL PRIMARY KEY,
      updated_us INTEGER NOT NULL,
      progress_json TEXT NOT NULL,
      FOREIGN KEY(chapter_id) REFERENCES imported_chapter(chapter_id)
        ON DELETE CASCADE
    )
  ''');
  db.execute(
    'CREATE INDEX imported_chapter_recent '
    'ON imported_chapter(imported_us DESC, chapter_id)',
  );
}

void _createLibraryPreferenceTables(sql.Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS library_category (
      category_id TEXT NOT NULL PRIMARY KEY,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL,
      category_json TEXT NOT NULL
    )
  ''');
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
  db.execute(
    'CREATE INDEX IF NOT EXISTS chapter_read_state_comic '
    'ON chapter_read_state(comic_id, chapter_id)',
  );
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
  db.execute(
    'CREATE INDEX IF NOT EXISTS comic_source_preference_order '
    'ON comic_source_preference(sort_order, source_id)',
  );
}
