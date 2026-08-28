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
    this.layoutResolver,
  });

  final CacheLayout layout;
  final MonoClock clock;
  final CacheIndex? index;
  final TraceSink traceSink;
  final void Function(DownloadSession session)? onSessionCreated;

  /// Optional per-download physical root override.
  ///
  /// Returns the [CacheLayout] that owns [id]'s bytes, or `null` to fall back
  /// to [layout]. This only decides where NEW artifacts and partials are
  /// written; durable reads always use the absolute record path in the index,
  /// so bytes previously stored under another root stay readable.
  final CacheLayout? Function(DownloadId id)? layoutResolver;

  final Map<DownloadId, DownloadSession> _sessions =
      <DownloadId, DownloadSession>{};
  final Map<DownloadId, DownloadId> _physicalAliases =
      <DownloadId, DownloadId>{};

  Iterable<DownloadSession> get sessions => _sessions.values;

  DownloadId resolvePhysicalId(DownloadId id) {
    var current = id;
    final visited = <DownloadId>{id};
    while (true) {
      final next = _physicalAliases[current];
      if (next == null) return current;
      if (!visited.add(next)) {
        throw StateError('circular physical transfer alias for ${next.key}');
      }
      current = next;
    }
  }

  DownloadSession? findExact(DownloadId id) => _sessions[id];

  bool isPhysicalAlias(DownloadId id, DownloadId target) =>
      id != target && resolvePhysicalId(id) == resolvePhysicalId(target);

  /// Binds an exact consumer identity to an already-existing physical session.
  ///
  /// This is deliberately acquire-time only: an exact identity that already
  /// owns its own session is never merged after the fact. Verified-equivalence
  /// proof and candidate selection remain outside this registry.
  void aliasPhysical({
    required DownloadId id,
    required DownloadId target,
  }) {
    if (_sessions.containsKey(id)) {
      if (id != resolvePhysicalId(target)) {
        throw StateError(
          'cannot alias an exact identity after its physical session exists',
        );
      }
      return;
    }
    final resolvedTarget = resolvePhysicalId(target);
    if (!_sessions.containsKey(resolvedTarget)) {
      throw StateError('physical alias target has no existing session');
    }
    if (id == resolvedTarget) {
      _physicalAliases.remove(id);
      return;
    }
    _physicalAliases[id] = resolvedTarget;
  }

  DownloadSession get(DownloadId id) {
    final physicalId = resolvePhysicalId(id);
    return _sessions.putIfAbsent(physicalId, () {
      final effectiveLayout =
          layoutResolver?.call(physicalId) ?? layout;
      final session = DownloadSession(
        id: physicalId,
        artifact: effectiveLayout.artifactFor(physicalId),
        clock: clock,
        traceSink: traceSink,
        sessionId: 'download:${layout.tokenFor(physicalId)}',
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

  DownloadSession? find(DownloadId id) => _sessions[resolvePhysicalId(id)];

  /// Removes an idle physical session from the registry without choosing any
  /// persistence policy.
  ///
  /// Higher-level composition owners may first hand hot bytes to their
  /// durable owner, then use this mechanical retirement primitive. The
  /// registry deliberately knows nothing about partial stores, artifact
  /// caches, Reader retention or eviction budgets.
  DownloadSession? takeIdlePhysical(DownloadId id) {
    final physicalId = resolvePhysicalId(id);
    final session = _sessions[physicalId];
    if (session == null ||
        session.demanded ||
        session.activeRun ||
        session.hasWriter ||
        session.state == DownloadState.disposed) {
      return null;
    }
    final aliases = <DownloadId>[];
    for (final alias in _physicalAliases.keys) {
      if (resolvePhysicalId(alias) == physicalId) aliases.add(alias);
    }
    _sessions.remove(physicalId);
    for (final alias in aliases) {
      _physicalAliases.remove(alias);
    }
    _physicalAliases.remove(physicalId);
    return session;
  }

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
    final physicalId = resolvePhysicalId(id);
    var session = _sessions[physicalId];
    final record = await index?.get(physicalId.key);
    if (session == null) {
      if (record == null) {
        return 0;
      }
      session = get(physicalId);
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
    _physicalAliases.clear();
  }
}
