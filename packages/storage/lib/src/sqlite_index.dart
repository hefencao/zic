import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sql;

import 'cache_index.dart';

final class SqliteIndex implements CacheIndex {
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
    if (version == 0) {
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute('''
          CREATE TABLE IF NOT EXISTS cache_entry (
            key TEXT NOT NULL PRIMARY KEY,
            download_json TEXT NOT NULL,
            state TEXT NOT NULL,
            path TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            checksum TEXT NOT NULL,
            created_us INTEGER NOT NULL,
            touched_us INTEGER NOT NULL
          )
        ''');
        db.execute(
          'CREATE INDEX IF NOT EXISTS cache_entry_state_touch '
          'ON cache_entry(state, touched_us)',
        );
        db.execute('PRAGMA user_version = 1');
        db.execute('COMMIT');
      } on Object {
        db.execute('ROLLBACK');
        rethrow;
      }
    } else if (version != 1) {
      throw StateError('unsupported cache schema version: $version');
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
    _requireDb().execute('''
      INSERT INTO cache_entry (
        key, download_json, state, path, bytes, checksum, created_us, touched_us
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        download_json = excluded.download_json,
        state = excluded.state,
        path = excluded.path,
        bytes = excluded.bytes,
        checksum = excluded.checksum,
        created_us = excluded.created_us,
        touched_us = excluded.touched_us
    ''', <Object?>[
      rec.key,
      jsonEncode(rec.id.toJson()),
      rec.state.name,
      rec.path,
      rec.bytes,
      rec.checksum,
      rec.createdUs,
      rec.touchedUs,
    ]);
  }

  @override
  Future<void> remove(String key) async {
    _requireDb().execute(
      'DELETE FROM cache_entry WHERE key = ?',
      <Object?>[key],
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
    });
  }
}
