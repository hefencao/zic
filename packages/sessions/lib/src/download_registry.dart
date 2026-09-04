import 'dart:io';

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
    final existingTarget = _physicalAliases[id];
    if (existingTarget != null) {
      final resolvedExistingTarget = resolvePhysicalId(id);
      if (resolvedExistingTarget != resolvedTarget) {
        throw StateError(
          'cannot rebind physical alias ${id.key} from '
          '${resolvedExistingTarget.key} to ${resolvedTarget.key}',
        );
      }
      return;
    }
    if (id == resolvedTarget) {
      _physicalAliases.remove(id);
      return;
    }
    _physicalAliases[id] = resolvedTarget;
  }

  DownloadSession get(DownloadId id) {
    final physicalId = resolvePhysicalId(id);
    return _sessions.putIfAbsent(
      physicalId,
      () => _createSession(
        physicalId,
        artifact: layoutFor(physicalId).artifactFor(physicalId),
        storageRootId: layoutFor(physicalId).root,
      ),
    );
  }

  DownloadSession _createSession(
    DownloadId physicalId, {
    required Artifact artifact,
    required String storageRootId,
  }) {
    final session = DownloadSession(
      id: physicalId,
      artifact: artifact,
      clock: clock,
      traceSink: traceSink,
      sessionId: 'download:${layout.tokenFor(physicalId)}',
      index: index,
      storageRootId: storageRootId,
      initiallyDemanded: false,
    );
    try {
      onSessionCreated?.call(session);
    } on Object {
      // Lifecycle observers must not break authoritative session creation.
    }
    return session;
  }

  DownloadSession? find(DownloadId id) => _sessions[resolvePhysicalId(id)];

  /// Returns the physical layout selected for a new artifact generation.
  /// Existing indexed rows remain authoritative through their absolute path;
  /// callers use this only when creating structured output or a new session.
  CacheLayout layoutFor(DownloadId id) => layoutResolver?.call(id) ?? layout;

  /// Resolves a source-scoped root for structured comic metadata before a
  /// concrete page identity exists. Source layout resolvers are intentionally
  /// keyed by source id, so the synthetic identity never owns bytes.
  CacheLayout layoutForSource(String sourceId) => layoutFor(
        DownloadId(
          content: ContentId(
            sourceId: sourceId,
            comicId: '',
            chapterId: '',
            pageId: '',
          ),
          sourceRevision: '',
          canonicalUri: Uri.parse('about:blank'),
        ),
      );

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
        !session.canEvict ||
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
      final physicalId = resolvePhysicalId(rec.id);
      final artifact = _artifactForIndexedRecord(rec, physicalId);
      if (artifact == null) {
        // Indexed export/SAF bindings are already durable outside the
        // session-owned partial/final workspace. Do not create a synthetic
        // local Artifact for them: restore/evict would otherwise operate on a
        // different path and leave the indexed bytes orphaned.
        continue;
      }
      final session = _sessions.putIfAbsent(
        physicalId,
        () => _createSession(
          physicalId,
          artifact: artifact,
          // The record's root id is the durable binding metadata. It is not a
          // path resolver, but retaining it on the recovered session keeps a
          // later cache write from silently changing the recorded ownership.
          storageRootId: rec.storageRootId,
        ),
      );
      await session.restore();
      restored++;
    }
    return restored;
  }

  Artifact? _artifactForIndexedRecord(CacheRec record, DownloadId id) {
    final indexedPath = File(record.path).absolute.path;
    final indexedFile = File(indexedPath);
    final parent = indexedFile.parent;
    final parts = parent.path
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final parentName = parts.isEmpty ? null : parts.last;
    if (parentName != 'partial' && parentName != 'final') return null;

    final root = parent.parent.path;
    final layout = CacheLayout(root);
    for (final candidate in <Artifact>[
      layout.artifactFor(id),
      layout.legacyArtifactFor(id),
    ]) {
      if (File(candidate.partialPath).absolute.path == indexedPath ||
          File(candidate.finalPath).absolute.path == indexedPath) {
        return candidate;
      }
    }
    // An indexed path outside the deterministic artifact layout must not be
    // treated as a root merely because one of its parent directories is named
    // `partial`/`final`. The caller will fall back to the configured layout;
    // higher-level owners remain responsible for arbitrary export bindings.
    return null;
  }

  Future<int> evict(DownloadId id) async {
    final physicalId = resolvePhysicalId(id);
    var session = _sessions[physicalId];
    final record = await index?.get(physicalId.key);
    if (session == null) {
      if (record == null) {
        return 0;
      }
      // The indexed path may belong to a historical layout resolver root.
      // Creating a fresh session here would bind the deletion to the current
      // write root, remove the index row, and leave the historical bytes
      // orphaned (or delete an unrelated current-root file). The persistent
      // artifact owner must delete a cold indexed record by its exact path.
      final artifact = _artifactForIndexedRecord(record, physicalId);
      if (artifact == null) {
        return 0;
      }
      session = _sessions.putIfAbsent(
        physicalId,
        () => _createSession(
          physicalId,
          artifact: artifact,
          storageRootId: record.storageRootId,
        ),
      );
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
