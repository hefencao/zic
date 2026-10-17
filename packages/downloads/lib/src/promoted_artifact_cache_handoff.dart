import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_store.dart';

typedef ArtifactCacheHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);

typedef DefaultArtifactTarget = DownloadId Function(DownloadSession session);

typedef RequiredArtifactTargets = Iterable<DownloadId> Function(
  DownloadSession session,
);
typedef ExactDurableRestoreProof = bool Function(
  DownloadSession session,
  DownloadId targetId,
  int length,
);
typedef SuppressAutomaticArtifactCommit = bool Function(
  DownloadSession session,
);

/// Commits only fully promoted session artifacts to the persistent cache tier.
///
/// This observer does not create demand, start downloads or choose retention.
/// It follows DownloadSession state, copies a final artifact after promotion,
/// and drains pending commits before the owning ephemeral workspace is removed.
final class PromotedArtifactCacheHandoff {
  PromotedArtifactCacheHandoff({
    required this.cache,
    this.onError,
    this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'artifact-cache-handoff',
    this.residentReplaySource,
    this.defaultTarget,
    this.requiredExactTargets,
    this.exactDurableRestoreProof,
    this.suppressAutomaticCommit,
  });

  final ArtifactCacheManager cache;
  final ArtifactCacheHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;
  final DownloadResidentReplaySource? residentReplaySource;
  final DefaultArtifactTarget? defaultTarget;
  final RequiredArtifactTargets? requiredExactTargets;
  final ExactDurableRestoreProof? exactDurableRestoreProof;
  final SuppressAutomaticArtifactCommit? suppressAutomaticCommit;
  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadId, Future<void>> _commits =
      <DownloadId, Future<void>>{};
  // Automatic handoff is one-shot only for one immutable physical epoch. A
  // reset can deliberately create a new generation under the same exact id;
  // retaining a plain id here would suppress the new generation's handoff.
  final Map<DownloadId, SourceEpoch> _completedAutomaticCommits =
      <DownloadId, SourceEpoch>{};

  void observe(DownloadSession session) {
    if (_listeners.containsKey(session)) {
      return;
    }
    void listener(DownloadSnapshot snapshot) {
      if (snapshot.state == DownloadState.promoted) {
        _submit(session);
      }
    }

    _listeners[session] = listener;
    session.addSnapshotListener(listener);
    if (session.state == DownloadState.promoted) {
      _submit(session);
    }
  }

  Future<void> drain(Iterable<DownloadSession> sessions) async {
    final current = sessions.toList(growable: false);
    for (var attempt = 0; attempt < 2; attempt++) {
      for (final session in current) {
        if (session.state == DownloadState.promoted) {
          _submit(session);
        }
      }
      for (final commit in _commits.values.toList(growable: false)) {
        await commit;
      }
    }
  }

  /// Waits for the ordinary automatic promotion policy for one immutable
  /// session without upgrading it to an exact-durable requirement.
  ///
  /// This is used before composition-level physical-session retirement. A
  /// verified equivalent durable body may therefore remain the storage
  /// authority, preserving the equivalence-only policy from dev.230.
  Future<bool> settleAutomatic(DownloadSession session) async {
    if (session.state != DownloadState.promoted) return false;
    _submit(session);
    while (true) {
      final pending = _commits[session.id];
      if (pending == null) break;
      await pending;
    }
    return _completedAutomaticCommits[session.id] == session.epoch;
  }

  /// Read-only barrier for a promotion already being persisted. Unlike
  /// [settleAutomatic], this never submits, retries or upgrades a commit.
  Future<void> waitForPendingCommit(DownloadId id) =>
      _commits[id] ?? Future<void>.value();

  /// Ensures a promoted transfer has a durable cache-owned body.
  ///
  /// Ordinary promotion observation does not materialize a reopenable source
  /// body merely because a Reader displayed it. Explicit durable commands call
  /// this barrier when their completion semantics require persistent bytes.
  Future<void> persist(
    DownloadSession session, {
    DownloadId? exactId,
  }) async {
    if (session.state != DownloadState.promoted) return;
    while (true) {
      final pending = _commits[session.id];
      if (pending == null) break;
      await pending;
    }
    final targetId = exactId ?? session.id;
    await _commitTarget(
      session,
      targetId,
      requireExactDurableBody: true,
    );
    await _bindCanonicalPhysicalAuthority(session, targetId);
  }

  void detach() {
    for (final entry in _listeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _listeners.clear();
    _completedAutomaticCommits.clear();
  }

  void unobserve(DownloadSession session) {
    final listener = _listeners.remove(session);
    if (listener != null) {
      session.removeSnapshotListener(listener);
    }
  }

  void _submit(DownloadSession session) {
    final id = session.id;
    if (_completedAutomaticCommits[id] == session.epoch ||
        _commits.containsKey(id)) {
      return;
    }
    final tracked = _runCommit(session);
    _commits[id] = tracked;
    unawaited(tracked);
  }

  Future<void> _runCommit(DownloadSession session) async {
    final id = session.id;
    final startedEpoch = session.epoch;
    try {
      final epoch = startedEpoch;
      final targets = requiredExactTargets?.call(session).toSet() ??
          <DownloadId>{};
      if (targets.isEmpty) {
        if (suppressAutomaticCommit?.call(session) == true) {
          // Keep this branch asynchronous so [_submit] has installed the
          // tracked Future before [_runCommit]'s finally removes it. Ordinary
          // commit branches already cross an async durable boundary.
          await Future<void>.delayed(Duration.zero);
          // A manual/offline exact binding is an explicit user-retention fact.
          // Presentation force-reload may refresh the hot physical epoch, but
          // must not silently replace or unpin that durable download. Keep the
          // fresh epoch hot-only and release its transient cache quarantine.
          cache.completeFreshSourceRecoveryWithoutReplacement(session.id);
          _recordCommit(
            session,
            targetId: session.id,
            action: 'skip-preserved-pinned-exact',
            bytes: session.committedLength,
            startedAtMicros: clock?.nowMicros(),
          );
        } else {
          final target = defaultTarget?.call(session) ?? session.id;
          await _commitTarget(session, target);
          await _bindCanonicalPhysicalAuthority(session, target);
        }
      } else {
        for (final target in targets) {
          await _commitTarget(
            session,
            target,
            requireExactDurableBody: true,
          );
          await _bindCanonicalPhysicalAuthority(session, target);
        }
      }
      if (session.state == DownloadState.promoted && session.epoch == epoch) {
        _completedAutomaticCommits[id] = epoch;
      }
    } on Object catch (error, stackTrace) {
      try {
        onError?.call(error, stackTrace);
      } on Object {
        // Error reporting must not create another failed cache Future.
      }
    } finally {
      _commits.remove(id);
      // A new physical epoch may have been promoted while the previous
      // generation's handoff was still draining. Its promotion snapshot was
      // intentionally coalesced by [_commits]; resubmit it now rather than
      // leaving the new immutable body without an automatic handoff.
      if (_listeners.containsKey(session) &&
          session.epoch != startedEpoch &&
          session.state == DownloadState.promoted &&
          _completedAutomaticCommits[id] != session.epoch) {
        _submit(session);
      }
    }
  }

  Future<void> _bindCanonicalPhysicalAuthority(
    DownloadSession session,
    DownloadId targetId,
  ) async {
    final physicalId = session.physicalId;
    if (physicalId.isExactFallback ||
        cache.backend is! PhysicalArtifactCacheBackend ||
        session.state != DownloadState.promoted) {
      return;
    }
    var sourceId = targetId;
    var durable = await cache.lookupAuthoritative(targetId);
    if (durable?.durable != true) {
      final reusable = await cache.lookup(targetId);
      if (reusable?.durable != true) return;
      sourceId = reusable!.storageId;
      durable = reusable;
    }
    final startedAtMicros = clock?.nowMicros();
    final bound = await cache.bindPhysicalArtifact(
      physicalId: physicalId,
      sourceId: sourceId,
    );
    if (!bound) {
      // The exact durable commit above is already a complete storage result.
      // Canonical binding is an additional version-family routing fact; a
      // conflicting/stale physical row must not turn the promoted epoch into
      // an endlessly retryable cache handoff. Preserve both durable facts,
      // fall back to exact routing for this epoch, and let the control-plane
      // backfill/reconciliation path repair canonical ownership later.
      _recordCanonicalBind(
        session,
        sourceId: sourceId,
        physicalId: physicalId,
        action: 'canonical-bind-unavailable-exact-fallback',
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    _recordCanonicalBind(
      session,
      sourceId: sourceId,
      physicalId: physicalId,
      action: 'canonical-bound',
      startedAtMicros: startedAtMicros,
    );
  }

  Future<void> _commitTarget(
    DownloadSession session,
    DownloadId targetId, {
    bool requireExactDurableBody = false,
  }) async {
    if (session.state != DownloadState.promoted) {
      return;
    }
    final expectedEpoch = session.epoch;
    final startedAtMicros = clock?.nowMicros();
    if (session.hasBorrowedDurableSpool && targetId == session.id) {
      // DownloadSession publishes promoted before its serialized CacheIndex
      // projection is enqueued. Yield one event turn so that same promotion
      // continuation can enqueue ready-state persistence, then wait for the
      // session tail. The durable spool itself is already the final body;
      // reading it into Uint8List merely to store it back into the same backend
      // would defeat zero-copy adoption.
      await Future<void>.delayed(Duration.zero);
      await session.settleCacheMutations();
      if (session.state != DownloadState.promoted ||
          session.epoch != expectedEpoch) {
        return;
      }
      final exactDurable = await cache.containsBackendExact(
        id: targetId,
        expectedLength: session.committedLength,
      );
      if (!exactDurable) {
        throw StateError(
          'adopted durable spool was not indexed after promotion for '
          '${session.id.key}',
        );
      }
      _recordCommit(
        session,
        targetId: targetId,
        action: 'skip-adopted-durable',
        bytes: session.committedLength,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    if (session.residentBodyBacked) {
      final expectedLength = session.committedLength;
      if (expectedLength <= 0) {
        throw StateError(
          'resident promoted transfer has no body for ${session.id.key}',
        );
      }
      if (session.residentBodyAuthority ==
              ByteResponseBodyAuthority.artifactCache &&
          exactDurableRestoreProof?.call(
                session,
                targetId,
                expectedLength,
              ) ==
              true) {
        _recordCommit(
          session,
          targetId: targetId,
          action: 'skip-bound-exact-durable',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }
      final alreadyDurable = await cache.containsBackendExact(
        id: targetId,
        expectedLength: expectedLength,
      );
      if (alreadyDurable) {
        _recordCommit(
          session,
          targetId: targetId,
          action: 'skip-cache-resident',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }

      if (requireExactDurableBody && !session.physicalId.isExactFallback) {
        final bound = await cache.materializeExactFromPhysical(
          physicalId: session.physicalId,
          targetId: targetId,
        );
        if (bound) {
          if (session.state != DownloadState.promoted ||
              session.epoch != expectedEpoch) {
            return;
          }
          _recordCommit(
            session,
            targetId: targetId,
            action: 'bound-required-exact-physical',
            bytes: expectedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
      }

      final lookup = await cache.lookup(targetId);
      if (lookup != null && lookup.entry.length == expectedLength) {
        if (lookup.storageId != targetId &&
            lookup.durable &&
            !requireExactDurableBody) {
          _recordCommit(
            session,
            targetId: targetId,
            action: 'skip-verified-equivalent-durable',
            bytes: expectedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
        if (!lookup.durable && !requireExactDurableBody) {
          _recordCommit(
            session,
            targetId: targetId,
            action: 'defer-resident-source',
            bytes: expectedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
        final expectedCacheGeneration = cache.generationFor(targetId);
        final read = await cache.readForegroundLookup(lookup);
        if (read.bytes.lengthInBytes != expectedLength) {
          throw StateError(
            'resident cache replay length changed for ${targetId.key}',
          );
        }
        if (session.state != DownloadState.promoted ||
            session.epoch != expectedEpoch) {
          return;
        }
        final stored = await cache.storePromotedArtifactIfGeneration(
          id: targetId,
          bytes: read.bytes,
          expectedGeneration: expectedCacheGeneration,
        );
        if (!stored) return;
        _recordCommit(
          session,
          targetId: targetId,
          action: targetId == session.id
              ? 'stored-resident-cache-authority'
              : 'stored-required-exact-alias',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }

      if (!requireExactDurableBody) {
        _recordCommit(
          session,
          targetId: targetId,
          action: 'defer-resident-source',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }
      final replay = residentReplaySource;
      if (replay == null) {
        throw StateError(
          'resident source materialization authority is unavailable for '
          '${session.id.key}',
        );
      }
      final expectedCacheGeneration = cache.generationFor(targetId);
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in await replay(session, expectedLength)) {
        if (chunk.isEmpty) continue;
        received += chunk.length;
        if (received > expectedLength) {
          throw StateError(
            'resident source replay exceeded $expectedLength for ${session.id.key}',
          );
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.lengthInBytes != expectedLength) {
        throw StateError(
          'resident source replay was short for ${session.id.key}: '
          '${bytes.lengthInBytes}/$expectedLength',
        );
      }
      if (session.state != DownloadState.promoted ||
          session.epoch != expectedEpoch) {
        return;
      }
      final stored = await cache.storePromotedArtifactIfGeneration(
        id: targetId,
        bytes: bytes,
        expectedGeneration: expectedCacheGeneration,
      );
      if (!stored) return;
      _recordCommit(
        session,
        targetId: targetId,
        action: targetId == session.id
            ? 'stored-resident-source'
            : 'stored-required-exact-alias',
        bytes: bytes.lengthInBytes,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final expectedLength = session.artifact.committedLength;
    if (expectedLength <= 0) {
      _recordCommit(
        session,
        targetId: targetId,
        action: 'skip-empty',
        bytes: 0,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    if (exactDurableRestoreProof?.call(
          session,
          targetId,
          expectedLength,
        ) ==
        true) {
      _recordCommit(
        session,
        targetId: targetId,
        action: 'skip-restored-exact-durable',
        bytes: expectedLength,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final alreadyDurable = await cache.containsBackendExact(
      id: targetId,
      expectedLength: expectedLength,
    );
    if (alreadyDurable) {
      _recordCommit(
        session,
        targetId: targetId,
        action: 'skip-existing',
        bytes: expectedLength,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    if (!requireExactDurableBody) {
      final physicalSeal = await _canonicalPhysicalSealMatch(
        session,
        targetId: targetId,
        expectedLength: expectedLength,
      );
      if (physicalSeal.matches) {
        if (session.state != DownloadState.promoted ||
            session.epoch != expectedEpoch) {
          return;
        }
        _recordCommit(
          session,
          targetId: targetId,
          action: 'skip-existing-physical-seal',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }
      _recordPhysicalSealMiss(
        session,
        targetId: targetId,
        expectedLength: expectedLength,
        match: physicalSeal,
      );
      final equivalent = await cache.lookup(targetId);
      if (equivalent != null &&
          equivalent.storageId != targetId &&
          equivalent.durable &&
          equivalent.entry.length == expectedLength) {
        _recordCommit(
          session,
          targetId: targetId,
          action: 'skip-verified-equivalent-durable',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }
    }
    final expectedCacheGeneration = cache.generationFor(targetId);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks()) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (session.state != DownloadState.promoted ||
        session.epoch != expectedEpoch) {
      return;
    }
    if (bytes.lengthInBytes != expectedLength) {
      throw StateError(
        'promoted artifact changed while handing off ${session.id.key}: '
        '${bytes.lengthInBytes}/$expectedLength',
      );
    }
    if (bytes.isEmpty) {
      _recordCommit(
        session,
        targetId: targetId,
        action: 'skip-empty',
        bytes: 0,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final stored = await cache.storePromotedArtifactIfGeneration(
      id: targetId,
      bytes: bytes,
      expectedGeneration: expectedCacheGeneration,
    );
    if (!stored) return;
    _recordCommit(
      session,
      targetId: targetId,
      action: targetId == session.id
          ? 'stored'
          : 'stored-required-exact-alias',
      bytes: bytes.lengthInBytes,
      startedAtMicros: startedAtMicros,
    );
  }


  Future<({
    bool matches,
    String reason,
    int? physicalLength,
    bool hotChecksumPresent,
    bool physicalChecksumPresent,
  })> _canonicalPhysicalSealMatch(
    DownloadSession session, {
    required DownloadId targetId,
    required int expectedLength,
  }) async {
    if (session.physicalId.isExactFallback) {
      return (
        matches: false,
        reason: 'exact-fallback',
        physicalLength: null,
        hotChecksumPresent: false,
        physicalChecksumPresent: false,
      );
    }
    if (cache.requiresFreshSource(targetId)) {
      return (
        matches: false,
        reason: 'fresh-source',
        physicalLength: null,
        hotChecksumPresent: false,
        physicalChecksumPresent: false,
      );
    }
    final sessionChecksum = session.artifact.checksum.trim().toLowerCase();
    if (sessionChecksum.isEmpty) {
      return (
        matches: false,
        reason: 'hot-checksum-empty',
        physicalLength: null,
        hotChecksumPresent: false,
        physicalChecksumPresent: false,
      );
    }
    final physical = await cache.openPhysicalArtifact(session.physicalId);
    if (physical == null) {
      return (
        matches: false,
        reason: 'no-physical',
        physicalLength: null,
        hotChecksumPresent: true,
        physicalChecksumPresent: false,
      );
    }
    if (physical.length != expectedLength) {
      return (
        matches: false,
        reason: 'length-mismatch',
        physicalLength: physical.length,
        hotChecksumPresent: true,
        physicalChecksumPresent:
            physical.sealedChecksum?.trim().isNotEmpty == true,
      );
    }
    final algorithm = physical.sealedChecksumAlgorithm?.trim().toLowerCase();
    final checksum = physical.sealedChecksum?.trim().toLowerCase();
    if (algorithm != 'crc32') {
      return (
        matches: false,
        reason: 'algorithm-mismatch',
        physicalLength: physical.length,
        hotChecksumPresent: true,
        physicalChecksumPresent: checksum?.isNotEmpty == true,
      );
    }
    if (checksum == null || checksum.isEmpty) {
      return (
        matches: false,
        reason: 'physical-checksum-empty',
        physicalLength: physical.length,
        hotChecksumPresent: true,
        physicalChecksumPresent: false,
      );
    }
    if (checksum != sessionChecksum) {
      return (
        matches: false,
        reason: 'checksum-mismatch',
        physicalLength: physical.length,
        hotChecksumPresent: true,
        physicalChecksumPresent: true,
      );
    }
    return (
      matches: true,
      reason: 'match',
      physicalLength: physical.length,
      hotChecksumPresent: true,
      physicalChecksumPresent: true,
    );
  }

  void _recordPhysicalSealMiss(
    DownloadSession session, {
    required DownloadId targetId,
    required int expectedLength,
    required ({
      bool matches,
      String reason,
      int? physicalLength,
      bool hotChecksumPresent,
      bool physicalChecksumPresent,
    }) match,
  }) {
    final sourceClock = clock;
    if (sourceClock == null) return;
    traceSink.record(
      traceEvent(
        clock: sourceClock,
        sessionId: sessionId,
        kind: TraceEventKind.artifactSource,
        identityHash: targetId.key,
        payload: <String, Object?>{
          'source': 'session-artifact-handoff',
          'consumer': 'persistent-cache',
          'action': 'physical-seal-skip-unavailable',
          'reason': match.reason,
          'expectedLength': expectedLength,
          if (match.physicalLength != null)
            'physicalLength': match.physicalLength,
          'hotChecksumPresent': match.hotChecksumPresent,
          'physicalChecksumPresent': match.physicalChecksumPresent,
          'physicalMediaKind': session.physicalId.kind.name,
        },
      ),
    );
  }

  void _recordCanonicalBind(
    DownloadSession session, {
    required DownloadId sourceId,
    required PhysicalMediaId physicalId,
    required String action,
    required int? startedAtMicros,
  }) {
    final sourceClock = clock;
    if (sourceClock == null) return;
    traceSink.record(
      traceEvent(
        clock: sourceClock,
        sessionId: sessionId,
        kind: TraceEventKind.artifactSource,
        identityHash: sourceId.key,
        payload: <String, Object?>{
          'source': 'session-artifact-handoff',
          'consumer': 'canonical-physical-binding',
          'action': action,
          'physicalMediaKey': physicalId.key,
          if (startedAtMicros != null)
            'handoffMicros': (sourceClock.nowMicros() - startedAtMicros)
                .clamp(0, 1 << 62)
                .toInt(),
        },
      ),
    );
  }

  void _recordCommit(
    DownloadSession session, {
    required DownloadId targetId,
    required String action,
    required int bytes,
    required int? startedAtMicros,
  }) {
    final sourceClock = clock;
    if (sourceClock == null) return;
    traceSink.record(
      traceEvent(
        clock: sourceClock,
        sessionId: sessionId,
        kind: TraceEventKind.artifactSource,
        identityHash: targetId.key,
        payload: <String, Object?>{
          'source': 'session-artifact-handoff',
          'consumer': 'persistent-cache',
          'action': action,
          'bytes': bytes,
          if (targetId != session.id) 'physicalIdentityHash': session.id.key,
          if (startedAtMicros != null)
            'handoffMicros': (sourceClock.nowMicros() - startedAtMicros)
                .clamp(0, 1 << 62)
                .toInt(),
        },
      ),
    );
  }
}
