part of 'sqlite_index.dart';

/// Immutable durable authority needed to open one artifact without executing
/// SQLite prepare/step work on the Reader/UI isolate.
final class ArtifactAuthorityReadSnapshot {
  const ArtifactAuthorityReadSnapshot({
    required this.object,
    required this.replicas,
    required this.storageRootsByIdentity,
  });

  final ArtifactObjectRecord? object;
  final List<ArtifactReplicaRecord> replicas;
  final Map<String, StorageRootRecord> storageRootsByIdentity;
}

final class _SqliteArtifactReadWorker {
  _SqliteArtifactReadWorker._({
    required this.isolate,
    required this.commands,
    required this.responses,
  });

  final Isolate isolate;
  final SendPort commands;
  final ReceivePort responses;
  final Map<int, Completer<ArtifactAuthorityReadSnapshot>> _pending =
      <int, Completer<ArtifactAuthorityReadSnapshot>>{};
  StreamSubscription<Object?>? _subscription;
  var _nextRequestId = 1;
  var _closed = false;

  static Future<_SqliteArtifactReadWorker> spawn(String path) async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    late _SqliteArtifactReadWorker worker;
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
      _runSqliteArtifactReadWorker,
      <Object?>[path, responses.sendPort],
      debugName: 'zic-artifact-read',
    );
    try {
      final commands = await ready.future;
      worker = _SqliteArtifactReadWorker._(
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

  Future<ArtifactAuthorityReadSnapshot> read(String artifactId) {
    if (_closed) {
      return Future<ArtifactAuthorityReadSnapshot>.error(
        StateError('artifact read worker is closed'),
      );
    }
    final id = _nextRequestId++;
    final completer = Completer<ArtifactAuthorityReadSnapshot>();
    _pending[id] = completer;
    commands.send(<String, Object?>{
      'op': 'read',
      'id': id,
      'artifactId': artifactId,
    });
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final id = _nextRequestId++;
    final completer = Completer<ArtifactAuthorityReadSnapshot>();
    _pending[id] = completer;
    commands.send(<String, Object?>{'op': 'close', 'id': id});
    try {
      await completer.future;
    } finally {
      await _subscription?.cancel();
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('artifact read worker closed'));
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
      final snapshot = message['snapshot'];
      if (snapshot is ArtifactAuthorityReadSnapshot) {
        completer.complete(snapshot);
      } else {
        // close acknowledgement carries no payload.
        completer.complete(const ArtifactAuthorityReadSnapshot(
          object: null,
          replicas: <ArtifactReplicaRecord>[],
          storageRootsByIdentity: <String, StorageRootRecord>{},
        ));
      }
      return;
    }
    completer.completeError(
      StateError((message['error'] as String?) ?? 'artifact read failed'),
    );
  }
}

void _runSqliteArtifactReadWorker(List<Object?> bootstrap) {
  final path = bootstrap[0]! as String;
  final parent = bootstrap[1]! as SendPort;
  final commands = ReceivePort();
  late final sql.Database db;
  try {
    db = sql.sqlite3.open(path, mode: sql.OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout = 5000');
  } on Object catch (error) {
    parent.send(<String, Object?>{'startupError': error.toString()});
    commands.close();
    return;
  }
  parent.send(commands.sendPort);
  var disposed = false;
  commands.listen((message) {
    if (message is! Map) return;
    final id = message['id'];
    if (id is! int) return;
    try {
      switch (message['op']) {
        case 'read':
          final artifactId = message['artifactId']! as String;
          db.execute('BEGIN');
          late final ArtifactAuthorityReadSnapshot snapshot;
          try {
            snapshot = _readArtifactAuthoritySnapshot(db, artifactId);
            db.execute('COMMIT');
          } on Object {
            _rollbackArtifactReadSnapshot(db);
            rethrow;
          }
          parent.send(<String, Object?>{
            'id': id,
            'ok': true,
            'snapshot': snapshot,
          });
          break;
        case 'close':
          db.close();
          disposed = true;
          parent.send(<String, Object?>{'id': id, 'ok': true});
          commands.close();
          break;
        default:
          throw StateError('unknown artifact read worker operation');
      }
    } on Object catch (error) {
      parent.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
      if (message['op'] == 'close' && !disposed) {
        db.close();
        disposed = true;
        commands.close();
      }
    }
  });
}

void _rollbackArtifactReadSnapshot(sql.Database db) {
  try {
    db.execute('ROLLBACK');
  } on Object {
    // BEGIN may itself have failed; preserve the original read failure.
  }
}

ArtifactAuthorityReadSnapshot _readArtifactAuthoritySnapshot(
  sql.Database db,
  String artifactId,
) {
  final objectRows = db.select(
    'SELECT artifact_id, path, bytes, checksum, checksum_algorithm, '
    'storage_root_id FROM artifact_object WHERE artifact_id = ? LIMIT 1',
    <Object?>[artifactId],
  );
  final object = objectRows.isEmpty
      ? null
      : ArtifactObjectRecord(
          artifactId: objectRows.first['artifact_id']! as String,
          accessLocator: objectRows.first['path']! as String,
          bytes: objectRows.first['bytes']! as int,
          checksum: objectRows.first['checksum']! as String,
          checksumAlgorithm:
              (objectRows.first['checksum_algorithm'] as String?) ?? 'crc32',
          storageRootId:
              (objectRows.first['storage_root_id'] as String?) ?? 'default',
        );
  final replicas = db
      .select(
        'SELECT replica_id, artifact_id, access_locator, storage_root_id, '
        'created_us, touched_us FROM artifact_replica WHERE artifact_id = ? '
        'ORDER BY touched_us DESC, replica_id',
        <Object?>[artifactId],
      )
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
  final rootIds = <String>{
    if (object != null) object.storageRootId,
    for (final replica in replicas) replica.storageRootId,
  };
  final roots = <String, StorageRootRecord>{};
  for (final rootId in rootIds) {
    final root = _readStorageRoot(db, rootId);
    if (root != null) roots[rootId] = root;
  }
  return ArtifactAuthorityReadSnapshot(
    object: object,
    replicas: List<ArtifactReplicaRecord>.unmodifiable(replicas),
    storageRootsByIdentity: Map<String, StorageRootRecord>.unmodifiable(roots),
  );
}
