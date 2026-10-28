part of 'chapter_downloads.dart';

final class _CacheDeleteSelection {
  final Set<String> artifactIds = {};
  final Set<String> exactPartialKeys = {};
  final Set<String> physicalPartialKeys = {};

  void addExact(CacheRec? record) {
    if (record == null) return;
    if (record.state == CacheState.ready && record.artifactId.isNotEmpty) {
      artifactIds.add(record.artifactId);
    } else if (record.state == CacheState.partial) {
      exactPartialKeys.add(record.key);
    }
  }

  void addPhysical(
    ({PhysicalMediaArtifactRecord? artifact, PhysicalPartialRecord? partial})? page,
  ) {
    if (page?.artifact case final artifact?) artifactIds.add(artifact.artifactId);
    if (page?.partial case final partial?) physicalPartialKeys.add(partial.id.key);
  }

  ChapterCacheDeleteTarget? target(PersistentDownloadArtifactStore owner) {
    if (artifactIds.isEmpty && exactPartialKeys.isEmpty && physicalPartialKeys.isEmpty) return null;
    return _PersistentChapterCacheDeleteTarget(owner, this);
  }
}

final class _PersistentChapterCacheDeleteTarget implements ChapterCacheDeleteTarget {
  _PersistentChapterCacheDeleteTarget(this.owner, _CacheDeleteSelection source)
      : selection = _CacheDeleteSelection()
          ..artifactIds.addAll(source.artifactIds)
          ..exactPartialKeys.addAll(source.exactPartialKeys)
          ..physicalPartialKeys.addAll(source.physicalPartialKeys);

  final PersistentDownloadArtifactStore owner;
  final _CacheDeleteSelection selection;
}

final class _PersistentCacheSnapshot {
  const _PersistentCacheSnapshot({required this.usage, required this.artifacts,
    required this.partials, required this.physicalPartials,
    required this.dominatedPartials, required this.debts});

  final ArtifactCacheUsage usage;
  final List<CacheMaintenanceArtifact> artifacts;
  final List<CacheRec> partials;
  final List<PhysicalPartialRecord> physicalPartials;
  final List<PhysicalPartialRecord> dominatedPartials;
  final List<StorageCleanupDebtRecord> debts;
}

final class _CacheMaintenanceBatch {
  final Stopwatch _clock = Stopwatch()..start();
  int _entries = 0;
  int _bytes = 0;

  Future<void> yieldIfNeeded({int bytes = 0}) async {
    _entries++;
    _bytes += bytes;
    if (_entries >= 16 || _bytes >= 64 * 1024 * 1024 ||
        _clock.elapsedMilliseconds >= 8) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      _entries = 0;
      _bytes = 0;
      _clock.reset();
    }
  }
}

extension _PersistentCacheMaintenance on PersistentDownloadArtifactStore {
  void _configureAutomaticCacheMaintenance({required int maxBytes, required int targetBytes}) {
    if (maxBytes < 0 || targetBytes < 0 || targetBytes > maxBytes) {
      throw ArgumentError('invalid artifact cache limits');
    }
    _requireOpen();
    final initial = _automaticCacheLimits == null;
    _automaticCacheLimits = (maxBytes: maxBytes, targetBytes: targetBytes);
    _scheduleAutomaticCacheMaintenance(delay: initial
        ? const Duration(seconds: 2) : const Duration(milliseconds: 750));
  }

  void _scheduleAutomaticCacheMaintenance({Duration delay = const Duration(milliseconds: 750)}) {
    if (_closed || _automaticCacheLimits == null) return;
    if (_cacheMaintenanceRun != null) {
      _cacheMaintenanceRequested = true;
      return;
    }
    // Do not reset the timer on every write: a continuous download must not
    // postpone reclamation forever. This work never joins a Reader open.
    _automaticCacheTimer ??= Timer(delay, () {
      _automaticCacheTimer = null;
      if (_closed) return;
      final limits = _automaticCacheLimits!;
      unawaited(_runCacheMaintenance(maxBytes: limits.maxBytes,
          targetBytes: limits.targetBytes).then<void>((_) {},
          onError: (Object error, StackTrace stackTrace) {
        _recordCleanupDebtFailure(stage: 'automatic-cache-maintenance',
            accessLocator: layout.root, error: error, stackTrace: stackTrace);
      }));
    });
  }

  void _cacheMaintenanceActivityReleased() {
    if (_cacheMaintenanceBlocked) _scheduleAutomaticCacheMaintenance();
  }

  Future<ArtifactCacheReport> _runCacheMaintenance({required int maxBytes,
    required int targetBytes, _CacheDeleteSelection? selection}) async {
    _requireOpen();
    if (maxBytes < 0 || targetBytes < 0 || targetBytes > maxBytes) {
      throw ArgumentError('invalid artifact cache limits');
    }
    while (_cacheMaintenanceRun != null) {
      await _cacheMaintenanceRun;
      _requireOpen();
    }
    final run = _performCacheMaintenance(maxBytes: maxBytes, targetBytes: targetBytes,
        selection: selection);
    _cacheMaintenanceRun = run;
    try {
      return await run;
    } finally {
      _cacheMaintenanceRun = null;
      if (_cacheMaintenanceRequested) {
        _cacheMaintenanceRequested = false;
        _scheduleAutomaticCacheMaintenance();
      }
    }
  }

  Future<_PersistentCacheSnapshot> _readCacheMaintenanceSnapshot() async {
    final artifacts = await _index.readCacheMaintenanceArtifacts();
    final readyPhysical = await _index.readReadyPhysicalCacheKeys();
    final allPhysicalPartials = await _index.listPhysicalPartials();
    final physicalPartials = allPhysicalPartials
        .where((record) => !readyPhysical.contains(record.id.key)).toList();
    final partials = await _index.readCacheMaintenancePartials();
    final retainedKeys = await _index.readRetainedPhysicalCacheKeys();
    var bytes = partials.fold<int>(0, (sum, partial) => sum + partial.record.bytes);
    var entries = partials.length + physicalPartials.length;
    var retained = 0;
    final eligible = <CacheMaintenanceArtifact>[];
    final budget = _DownloadProjectionWorkBudget();
    for (final artifact in artifacts) {
      if (budget.exhausted) await budget.yieldTurn();
      final object = artifact.object;
      bytes += object.bytes;
      entries += artifact.exactBindings + artifact.physicalBindings;
      if (artifact.retained || !_isAutomaticCacheFinalLocator(
          object.accessLocator, object.storageRootId)) {
        retained += object.bytes;
      } else {
        eligible.add(artifact);
      }
    }
    final eligiblePhysicalPartials = <PhysicalPartialRecord>[];
    for (final partial in physicalPartials) {
      if (budget.exhausted) await budget.yieldTurn();
      bytes += partial.bytes;
      if (retainedKeys.contains(partial.id.key)) {
        retained += partial.bytes;
      } else {
        eligiblePhysicalPartials.add(partial);
      }
    }
    final eligiblePartials = <CacheRec>[];
    for (final partial in partials) {
      if (budget.exhausted) await budget.yieldTurn();
      if (partial.retained) {
        retained += partial.record.bytes;
      } else {
        eligiblePartials.add(partial.record);
      }
    }
    // A retired row is not released disk space. Keep failed file deletions in
    // the usage until the existing cleanup owner confirms absence.
    final debts = <StorageCleanupDebtRecord>[];
    final seen = <String>{};
    var pending = 0;
    var automaticPending = 0;
    for (final debt in await _index.listStorageCleanupDebts()) {
      if (budget.exhausted) await budget.yieldTurn();
      if (debt.kind == StorageCleanupDebtKind.temporary ||
          !seen.add(debt.accessLocator) ||
          await _index.isStorageAccessLocatorAuthoritative(debt.accessLocator)) {
        continue;
      }
      final size = debt.expectedBytes ?? 0;
      bytes += size;
      pending += size;
      if (_isAutomaticCacheFinalLocator(debt.accessLocator, debt.storageRootId)) {
        automaticPending += size;
        debts.add(debt);
      } else {
        retained += size;
      }
    }
    return _PersistentCacheSnapshot(
      usage: ArtifactCacheUsage(bytes: bytes,
          entries: entries + debts.length,
          retainedBytes: retained.clamp(0, bytes), pendingCleanupBytes: pending,
          automaticPendingCleanupBytes: automaticPending),
      artifacts: eligible, partials: eligiblePartials,
      physicalPartials: eligiblePhysicalPartials, debts: debts,
      dominatedPartials: allPhysicalPartials
          .where((record) => readyPhysical.contains(record.id.key)).toList(),
    );
  }

  bool _cacheBindingsAreBusy(String artifactId) {
    if ((_cacheReadLeases[artifactId] ?? 0) != 0) return true;
    final external = _externalCacheActivity?.call();
    final sessions = _registry.sessions.where((session) => !session.canEvict);
    return _index.hasBusyCacheArtifactBindings(artifactId,
      exactKeys: {...?external?.exact,
        for (final id in _borrowedPartialIds) id.key,
        for (final id in _artifactWrites.keys) id.key,
        for (final session in sessions) session.id.key},
      physicalKeys: {...?external?.physical,
        for (final id in _borrowedPhysicalPartialIds) id.key,
        for (final session in sessions) session.physicalId.key},
    );
  }

  Future<List<StorageCleanupDebtRecord>?> _retireMaintenanceArtifact(
      CacheMaintenanceArtifact expected, {required bool compareRecency}) async {
    final artifactId = expected.object.artifactId;
    // Acquire the shared storage quantum before the short artifact transaction.
    // Never hold an artifact lock while waiting for foreground reads to yield.
    return _withStorageWriteQuantum(() async {
      if (_closed || _artifactReplicaMutationTails.containsKey(artifactId) ||
          (_cacheReadLeases[artifactId] ?? 0) != 0) {
        return null;
      }
      return _serializeArtifactReplicaMutation(artifactId, () async {
        if (_cacheBindingsAreBusy(artifactId)) return null;
        final replicas = await _index.listArtifactReplicas(artifactId);
        if (replicas.isEmpty || replicas.any((replica) =>
            !_isAutomaticCacheFinalLocator(replica.accessLocator, replica.storageRootId))) {
          return null;
        }
        final now = DateTime.now().toUtc().microsecondsSinceEpoch;
        final debts = <StorageCleanupDebtRecord>[
          for (final replica in replicas) StorageCleanupDebtRecord(
            accessLocator: replica.accessLocator, storageRootId: replica.storageRootId,
            kind: StorageCleanupDebtKind.obsoleteSealedSource,
            createdUs: now, touchedUs: now, expectedBytes: expected.object.bytes,
            expectedChecksum: expected.object.checksum,
            expectedChecksumAlgorithm: expected.object.checksumAlgorithm,
          ),
        ];
        final retired = await _index.retireCacheArtifactForMaintenance(
          expected: expected, cleanupDebts: debts,
          compareRecency: compareRecency,
          canRetire: () => !_closed && !_cacheBindingsAreBusy(artifactId),
        );
        return retired ? debts : null;
      });
    });
  }

  Future<ArtifactCacheReport> _performCacheMaintenance({required int maxBytes,
    required int targetBytes, _CacheDeleteSelection? selection}) async {
    var snapshot = await _readCacheMaintenanceSnapshot();
    final before = snapshot.usage.bytes;
    var released = 0;
    var evicted = 0;
    var skipped = 0;
    var changed = false;
    var remaining = snapshot.usage.automaticBytes;
    final batch = _CacheMaintenanceBatch();
    final reclaim = remaining > maxBytes;
    if (reclaim) {
      // READY already owns these bytes. Remove only the obsolete mutable
      // backing, before retiring its READY route, so it cannot reappear in
      // quota accounting as an apparent surviving download prefix.
      for (final partial in snapshot.dominatedPartials) {
        if (_closed) break;
        if (selection != null && !selection.physicalPartialKeys.contains(partial.id.key)) continue;
        try {
          await _evictPhysicalPartialForMaintenance(partial, removeIfDominated: true);
        } on Failure catch (error) {
          if (error.code != ErrorCode.sessionBusy && error.code != ErrorCode.writerBusy) {
            rethrow;
          }
        }
        await batch.yieldIfNeeded();
      }
      for (final debt in selection == null ? snapshot.debts : const <StorageCleanupDebtRecord>[]) {
        if (_closed || remaining <= targetBytes) break;
        final previous = released;
        await _cleanupObsoleteSourceNow(debt, onDeleted: (bytes) { released += bytes; });
        final freed = released - previous;
        remaining = (remaining - freed).clamp(0, 1 << 62);
        if (freed > 0) evicted++;
        await batch.yieldIfNeeded(bytes: freed);
      }
      if (selection == null && snapshot.debts.isNotEmpty && !_closed) {
        snapshot = await _readCacheMaintenanceSnapshot();
        remaining = snapshot.usage.automaticBytes;
      }
      // All durable forms share one LRU ordered by physical last use. A body
      // shared by many versions is one candidate; no exact-first phase.
      final candidates = <({int touch, String key, Object value})>[
        for (final artifact in snapshot.artifacts)
          if (selection == null || selection.artifactIds.contains(artifact.object.artifactId))
          (touch: artifact.touchedUs, key: artifact.object.artifactId, value: artifact),
        for (final partial in snapshot.physicalPartials)
          if (selection == null || selection.physicalPartialKeys.contains(partial.id.key))
          (touch: partial.touchedUs, key: partial.id.key, value: partial),
        for (final partial in snapshot.partials)
          if (selection == null || selection.exactPartialKeys.contains(partial.id.key))
          (touch: partial.touchedUs, key: partial.id.key, value: partial),
      ]..sort((a, b) { final order = a.touch.compareTo(b.touch);
        return order != 0 ? order : a.key.compareTo(b.key); });
      for (final candidate in candidates) {
        if (_closed || remaining <= targetBytes) break;
        var removedBytes = 0;
        try {
          final value = candidate.value;
          if (value is CacheMaintenanceArtifact) {
            final debts = await _retireMaintenanceArtifact(value,
                compareRecency: maxBytes != 0);
            if (debts == null) {
              skipped++;
              _cacheMaintenanceBlocked = true;
              continue;
            }
            changed = true;
            for (final debt in debts) {
              await _cleanupObsoleteSourceNow(debt, onDeleted: (bytes) { removedBytes += bytes; });
            }
          } else if (value is PhysicalPartialRecord) {
            final result = await _evictPhysicalPartialForMaintenance(value);
            changed = changed || result.removed;
            if (result.removed && !result.dominated) removedBytes = value.bytes;
            if (!result.removed) skipped++;
          } else if (value is CacheRec) {
            removedBytes = await _evictCacheRecord(value.id, expected: value);
            if (removedBytes == 0) skipped++;
          }
        } on Failure catch (error) {
          if (error.code != ErrorCode.sessionBusy && error.code != ErrorCode.writerBusy) {
            rethrow;
          }
          skipped++;
          _cacheMaintenanceBlocked = true;
        } finally {
          await batch.yieldIfNeeded(bytes: removedBytes);
        }
        if (removedBytes > 0) {
          released += removedBytes;
          remaining = (remaining - removedBytes).clamp(0, 1 << 62);
          evicted++;
        }
      }
    }
    // No work or await occurs after the inventory when already under quota.
    // A second global inventory would repeat the same read without a change.
    final after = reclaim ? await _readCacheMaintenanceSnapshot() : snapshot;
    if (selection == null) {
      _cacheMaintenanceBlocked = after.usage.automaticBytes > maxBytes && skipped != 0;
    }
    if (changed || before != after.usage.bytes || released != 0) {
      _notifyManagementProjectionChanged(scheduleMaintenance: false);
    }
    return ArtifactCacheReport(beforeBytes: before, releasedBytes: released,
      remainingBytes: after.usage.bytes, evictedEntries: evicted, skippedBusy: skipped);
  }

  void Function() _retainCacheRead(String artifactId) {
    _cacheReadLeases[artifactId] = (_cacheReadLeases[artifactId] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = _cacheReadLeases[artifactId]! - 1;
      if (count == 0) {
        _cacheReadLeases.remove(artifactId);
        _cacheMaintenanceActivityReleased();
      } else {
        _cacheReadLeases[artifactId] = count;
      }
    };
  }

  Stream<Uint8List> _readLeasedArtifactCandidates(List<_ArtifactAccessCandidate> candidates,
      {required int start, int? endExclusive}) async* {
    final release = _retainCacheRead(candidates.first.access.artifactId);
    try {
      yield* _readArtifactCandidates(candidates, start: start, endExclusive: endExclusive);
    } finally {
      release();
    }
  }

  Future<ArtifactCachePresentationFileLease?> _openLeasedPresentationFile(
      _ArtifactAccessRecord access, {required int expectedLength}) async {
    final release = _retainCacheRead(access.artifactId);
    var retained = false;
    try {
      final lease = await presentationFileLeaseFactory!.open(access.accessLocator,
          expectedLength: expectedLength);
      if (lease == null) return null;
      retained = true;
      var closed = false;
      return ArtifactCachePresentationFileLease(path: lease.path, length: lease.length,
        width: lease.width, height: lease.height, release: () async {
          if (closed) return;
          closed = true;
          try { await lease.release(); } finally { release(); }
        });
    } finally {
      if (!retained) release();
    }
  }
}
