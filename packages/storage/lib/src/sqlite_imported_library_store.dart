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
          db.execute('PRAGMA user_version = 1');
          db.execute('COMMIT');
        } on Object {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version != 1) {
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
    _requireDb().execute(
      'DELETE FROM imported_chapter WHERE chapter_id = ?',
      <Object?>[chapterId],
    );
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

  sql.Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('imported library store is not open');
    }
    return db;
  }
}
