import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// Dedicated SQLite connection for Reader progress checkpoints.
///
/// The primary imported-library connection remains the owner of schema and
/// catalog mutations. Reader checkpoints use this second WAL connection so
/// synchronous sqlite3 work and chapter JSON validation never run on Flutter's
/// UI isolate.
final class SqliteProgressWriter {
  SqliteProgressWriter._({
    required this.isolate,
    required this.commands,
    required this.responses,
  });

  final Isolate isolate;
  final SendPort commands;
  final ReceivePort responses;
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};
  StreamSubscription<Object?>? _subscription;
  var _nextRequestId = 1;
  var _closed = false;

  static Future<SqliteProgressWriter> open(String path) async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    late SqliteProgressWriter writer;
    late final StreamSubscription<Object?> subscription;
    subscription = responses.listen((message) {
      if (!ready.isCompleted) {
        if (message is SendPort) {
          ready.complete(message);
        } else if (message is Map && message['startupError'] is String) {
          ready.completeError(StateError(message['startupError']! as String));
        }
        return;
      }
      writer._acceptResponse(message);
    });
    final isolate = await Isolate.spawn<List<Object?>>(
      _runSqliteProgressWriter,
      <Object?>[path, responses.sendPort],
      debugName: 'zic-library-progress',
    );
    try {
      final commands = await ready.future;
      writer = SqliteProgressWriter._(
        isolate: isolate,
        commands: commands,
        responses: responses,
      ).._subscription = subscription;
      return writer;
    } on Object {
      await subscription.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<void> save(ReadingProgress progress) async {
    enqueue(progress);
    await flush();
  }

  void enqueue(ReadingProgress progress) {
    if (_closed) {
      throw StateError('library progress writer is closed');
    }
    commands.send(<String, Object?>{
      'op': 'save',
      'sourceId': progress.sourceId,
      'comicId': progress.comicId,
      'chapterId': progress.chapterId,
      'pageIndex': progress.pageIndex,
      'updatedUs': progress.updatedAt.toUtc().microsecondsSinceEpoch,
      'progressJson': jsonEncode(progress.toJson()),
    });
  }

  Future<void> flush() {
    if (_closed) {
      throw StateError('library progress writer is closed');
    }
    final id = _nextRequestId++;
    final completer = Completer<void>();
    _pending[id] = completer;
    // SendPort ordering makes this a barrier for every previously enqueued
    // checkpoint without making each checkpoint wait for a round trip.
    commands.send(<String, Object?>{'op': 'flush', 'id': id});
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    Object? flushError;
    StackTrace? flushStack;
    try {
      await flush();
    } on Object catch (error, stackTrace) {
      flushError = error;
      flushStack = stackTrace;
    }
    _closed = true;
    final id = _nextRequestId++;
    final completer = Completer<void>();
    _pending[id] = completer;
    commands.send(<String, Object?>{'op': 'close', 'id': id});
    try {
      await completer.future;
      if (flushError != null) {
        Error.throwWithStackTrace(flushError, flushStack!);
      }
    } finally {
      await _subscription?.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('library progress writer closed'));
        }
      }
      _pending.clear();
    }
  }

  void _acceptResponse(Object? message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      completer.complete();
      return;
    }
    completer.completeError(
      StateError((message['error'] as String?) ?? 'progress write failed'),
    );
  }
}

void _runSqliteProgressWriter(List<Object?> bootstrap) {
  final path = bootstrap[0]! as String;
  final parent = bootstrap[1]! as SendPort;
  final commands = ReceivePort();
  late final sql.Database db;
  try {
    db = sql.sqlite3.open(path);
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA busy_timeout = 5000');
  } on Object catch (error) {
    parent.send(<String, Object?>{'startupError': error.toString()});
    commands.close();
    return;
  }
  parent.send(commands.sendPort);
  String? bufferedFailure;
  commands.listen((message) {
    if (message is! Map) return;
    final operation = message['op'];
    if (operation == 'save') {
      try {
        _saveProgress(db, message);
      } on Object catch (error) {
        bufferedFailure ??= error.toString();
      }
      return;
    }
    final id = message['id'];
    if (id is! int) return;
    try {
      switch (operation) {
        case 'flush':
          final failure = bufferedFailure;
          bufferedFailure = null;
          if (failure == null) {
            parent.send(<String, Object?>{'id': id, 'ok': true});
          } else {
            parent.send(<String, Object?>{
              'id': id,
              'ok': false,
              'error': failure,
            });
          }
          break;
        case 'close':
          db.dispose();
          parent.send(<String, Object?>{'id': id, 'ok': true});
          commands.close();
          break;
        default:
          throw StateError('unknown library progress writer operation');
      }
    } on Object catch (error) {
      parent.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
    }
  });
}

void _saveProgress(sql.Database db, Map message) {
  final sourceId = message['sourceId']! as String;
  final comicId = message['comicId']! as String;
  final chapterId = message['chapterId']! as String;
  final pageIndex = message['pageIndex']! as int;
  final updatedUs = message['updatedUs']! as int;
  final progressJson = message['progressJson']! as String;

  final rows = db.select('''
    SELECT comic_id, chapter_json
    FROM imported_chapter
    WHERE source_id = ? AND chapter_id = ?
    LIMIT 1
  ''', <Object?>[sourceId, chapterId]);
  if (rows.isEmpty) {
    throw StateError('cannot save progress for an unknown chapter');
  }
  if (rows.first['comic_id'] != comicId) {
    throw StateError('progress identity does not match the chapter');
  }
  final rawChapter = jsonDecode(rows.first['chapter_json']! as String);
  final pages = rawChapter is Map ? rawChapter['pages'] : null;
  final pageCount = pages is List ? pages.length : 0;
  if (pageIndex < 0 || pageIndex >= pageCount) {
    throw RangeError.range(pageIndex, 0, pageCount - 1, 'progress.pageIndex');
  }

  final current = db.select('''
    SELECT updated_us
    FROM reading_progress
    WHERE source_id = ? AND chapter_id = ?
    LIMIT 1
  ''', <Object?>[sourceId, chapterId]);
  if (current.isNotEmpty && (current.first['updated_us']! as int) > updatedUs) {
    return;
  }
  db.execute('''
    INSERT INTO reading_progress (
      source_id, chapter_id, updated_us, progress_json
    ) VALUES (?, ?, ?, ?)
    ON CONFLICT(source_id, chapter_id) DO UPDATE SET
      updated_us = excluded.updated_us,
      progress_json = excluded.progress_json
  ''', <Object?>[sourceId, chapterId, updatedUs, progressJson]);
}
