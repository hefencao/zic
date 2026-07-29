import 'dart:async';

import 'package:downloads/downloads.dart';
import 'package:runtime_bridge/runtime_bridge.dart';
import 'package:storage_bridge/storage_bridge.dart';

final class PlatformWholeComicQueueEnvironment
    implements WholeComicQueueEnvironmentSource {
  PlatformWholeComicQueueEnvironment({
    RuntimeEnvironmentBridge bridge = const RuntimeEnvironmentBridge(),
  }) : _bridge = bridge;

  final RuntimeEnvironmentBridge _bridge;
  final StreamController<WholeComicQueueEnvironment> _changes =
      StreamController<WholeComicQueueEnvironment>.broadcast(sync: true);
  WholeComicQueueEnvironment _current =
      const WholeComicQueueEnvironment.assumedAvailable();
  StreamSubscription<RuntimeEnvironmentSnapshot>? _subscription;

  @override
  WholeComicQueueEnvironment get current => _current;

  @override
  Stream<WholeComicQueueEnvironment> get changes => _changes.stream;

  Future<void> initialize() async {
    _accept(await _bridge.current());
    _subscription ??= _bridge.changes.listen(
      _accept,
      onError: _changes.addError,
    );
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_changes.isClosed) {
      await _changes.close();
    }
  }

  void _accept(RuntimeEnvironmentSnapshot snapshot) {
    final next = WholeComicQueueEnvironment(
      networkAvailable: snapshot.networkAvailable,
      unmetered: snapshot.unmetered,
      charging: snapshot.charging,
    );
    _current = next;
    if (!_changes.isClosed) {
      _changes.add(next);
    }
  }
}

final class JsonWholeComicQueueStore implements WholeComicQueueStore {
  JsonWholeComicQueueStore(this.path);

  final String path;

  @override
  Future<Map<String, Object?>?> load() => readJsonObjectFile(path);

  @override
  Future<void> save(Map<String, Object?> data) =>
      writeJsonObjectFile(path, data);

  @override
  Future<void> close() async {}
}

Future<WholeComicDownloadQueue> openPersistentWholeComicDownloadQueue({
  required String path,
  required ChapterDownloadService downloads,
  WholeComicQueueEnvironmentSource? environment,
  bool ownsEnvironment = false,
}) async {
  final queue = WholeComicDownloadQueue(
    downloads: downloads,
    store: JsonWholeComicQueueStore(path),
    environment: environment,
    ownsEnvironment: ownsEnvironment,
  );
  await queue.ready;
  return queue;
}
