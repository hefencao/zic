part of 'sqlite_index.dart';

/// Off-isolate executor for one already-admitted READY-artifact recency update.
///
/// Scheduling remains outside this worker. In particular, this worker does not
/// debounce, retry or invent its own queue policy: callers keep the existing
/// storage-write lease until [touch] has actually returned.
final class _SqliteArtifactTouchWorker {
  _SqliteArtifactTouchWorker._({
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

  static Future<_SqliteArtifactTouchWorker> spawn(String path) async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    late _SqliteArtifactTouchWorker worker;
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
      worker._acceptResponse(message);
    });
    final isolate = await Isolate.spawn<List<Object?>>(
      _runSqliteArtifactTouchWorker,
      <Object?>[path, responses.sendPort],
      debugName: 'zic-artifact-touch',
    );
    try {
      final commands = await ready.future;
      worker = _SqliteArtifactTouchWorker._(
        isolate: isolate,
        commands: commands,
        responses: responses,
      ).._subscription = subscription;
      return worker;
    } on Object {
      await subscription.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Future<void> touch({
    required String key,
    required String expectedArtifactId,
    required int touchedUs,
  }) {
    if (_closed) {
      return Future<void>.error(StateError('artifact touch worker is closed'));
    }
    final id = _nextRequestId++;
    final completer = Completer<void>();
    _pending[id] = completer;
    commands.send(<String, Object?>{
      'op': 'touch',
      'id': id,
      'key': key,
      'expectedArtifactId': expectedArtifactId,
      'touchedUs': touchedUs,
    });
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final id = _nextRequestId++;
    final completer = Completer<void>();
    _pending[id] = completer;
    commands.send(<String, Object?>{'op': 'close', 'id': id});
    try {
      await completer.future.timeout(const Duration(seconds: 2));
    } finally {
      await _subscription?.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      final pending = _pending.values.toList(growable: false);
      _pending.clear();
      for (final request in pending) {
        if (!request.isCompleted) {
          request.completeError(StateError('artifact touch worker closed'));
        }
      }
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
      StateError(
        message['error'] is String
            ? message['error']! as String
            : 'artifact touch worker failed',
      ),
    );
  }
}

void _runSqliteArtifactTouchWorker(List<Object?> bootstrap) {
  final path = bootstrap[0]! as String;
  final parent = bootstrap[1]! as SendPort;
  final commands = ReceivePort();
  late final sql.Database db;
  try {
    db = sql.sqlite3.open(path);
    // Recency is best-effort and must never wait behind authoritative SQLite
    // mutation. Admission/retry policy remains with the caller/owner.
    db.execute('PRAGMA busy_timeout = 0');
  } on Object catch (error) {
    parent.send(<String, Object?>{'startupError': error.toString()});
    commands.close();
    return;
  }
  parent.send(commands.sendPort);

  commands.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    try {
      switch (message['op']) {
        case 'touch':
          db.execute(
            'UPDATE cache_entry SET touched_us = MAX(touched_us, ?) '
            'WHERE key = ? AND artifact_id = ?',
            <Object?>[
              message['touchedUs']! as int,
              message['key']! as String,
              message['expectedArtifactId']! as String,
            ],
          );
          parent.send(<String, Object?>{'id': id, 'ok': true});
          break;
        case 'close':
          db.close();
          parent.send(<String, Object?>{'id': id, 'ok': true});
          commands.close();
          break;
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
