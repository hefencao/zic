import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';

import 'download_session.dart';

final class DownloadRegistry {
  DownloadRegistry({
    required this.layout,
    required this.clock,
    this.index,
    this.traceSink = const NoopTraceSink(),
    this.onSessionCreated,
  });

  final CacheLayout layout;
  final MonoClock clock;
  final CacheIndex? index;
  final TraceSink traceSink;
  final void Function(DownloadSession session)? onSessionCreated;

  final Map<DownloadId, DownloadSession> _sessions =
      <DownloadId, DownloadSession>{};

  Iterable<DownloadSession> get sessions => _sessions.values;

  DownloadSession get(DownloadId id) {
    return _sessions.putIfAbsent(id, () {
      final session = DownloadSession(
        id: id,
        artifact: layout.artifactFor(id),
        clock: clock,
        traceSink: traceSink,
        sessionId: 'download:${layout.tokenFor(id)}',
        index: index,
        initiallyDemanded: false,
      );
      try {
        onSessionCreated?.call(session);
      } on Object {
        // Lifecycle observers must not break authoritative session creation.
      }
      return session;
    });
  }

  DownloadSession? find(DownloadId id) => _sessions[id];

  Set<String> get activePaths => <String>{
        for (final session in _sessions.values)
          if (session.activeRun || session.hasWriter)
            session.artifact.partialPath,
        for (final session in _sessions.values)
          if (session.activeRun || session.hasWriter)
            session.artifact.finalPath,
      };

  Future<int> restoreIndexed() async {
    final cache = index;
    if (cache == null) {
      return 0;
    }
    var restored = 0;
    for (final rec in await cache.list()) {
      await get(rec.id).restore();
      restored++;
    }
    return restored;
  }

  Future<int> evict(DownloadId id) async {
    var session = _sessions[id];
    final record = await index?.get(id.key);
    if (session == null) {
      if (record == null) {
        return 0;
      }
      session = get(id);
    }
    if (session.artifact.state == ArtifactState.empty) {
      await session.restore();
    }
    return session.evict();
  }

  Future<void> dispose() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
  }
}
