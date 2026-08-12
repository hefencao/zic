import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';

typedef ArtifactCacheHandoffError = void Function(
  Object error,
  StackTrace stackTrace,
);

typedef ResidentArtifactReplaySource = Future<Stream<List<int>>> Function(
  DownloadSession session,
  int endExclusive,
);

typedef RequiredArtifactTargets = Iterable<DownloadId> Function(
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
    this.requiredExactTargets,
  });

  final ArtifactCacheManager cache;
  final ArtifactCacheHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;
  final ResidentArtifactReplaySource? residentReplaySource;
  final RequiredArtifactTargets? requiredExactTargets;
  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadId, Future<void>> _commits =
      <DownloadId, Future<void>>{};
  final Set<DownloadId> _completedAutomaticCommits = <DownloadId>{};

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
    return _completedAutomaticCommits.contains(session.id);
  }

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
    await _commitTarget(
      session,
      exactId ?? session.id,
      requireExactDurableBody: true,
    );
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
    if (_completedAutomaticCommits.contains(id) || _commits.containsKey(id)) {
      return;
    }
    final tracked = _runCommit(session);
    _commits[id] = tracked;
    unawaited(tracked);
  }

  Future<void> _runCommit(DownloadSession session) async {
    final id = session.id;
    try {
      final targets = requiredExactTargets?.call(session).toSet() ??
          <DownloadId>{};
      if (targets.isEmpty) {
        await _commitTarget(session, session.id);
      } else {
        for (final target in targets) {
          await _commitTarget(
            session,
            target,
            requireExactDurableBody: true,
          );
        }
      }
      _completedAutomaticCommits.add(id);
    } on Object catch (error, stackTrace) {
      try {
        onError?.call(error, stackTrace);
      } on Object {
        // Error reporting must not create another failed cache Future.
      }
    } finally {
      _commits.remove(id);
    }
  }

  Future<void> _commitTarget(
    DownloadSession session,
    DownloadId targetId, {
    bool requireExactDurableBody = false,
  }) async {
    if (session.state != DownloadState.promoted) {
      return;
    }
    final startedAtMicros = clock?.nowMicros();
    if (session.residentBodyBacked) {
      final expectedLength = session.committedLength;
      if (expectedLength <= 0) {
        throw StateError(
          'resident promoted transfer has no body for ${session.id.key}',
        );
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
        final read = await cache.readForegroundLookup(lookup);
        if (read.bytes.lengthInBytes != expectedLength) {
          throw StateError(
            'resident cache replay length changed for ${targetId.key}',
          );
        }
        await cache.storePromotedArtifact(id: targetId, bytes: read.bytes);
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
      if (session.residentBodyAuthority ==
          ByteResponseBodyAuthority.artifactCache) {
        throw StateError(
          'durable artifact-cache authority disappeared before persistence for '
          '${session.id.key}',
        );
      }
      final replay = residentReplaySource;
      if (replay == null) {
        throw StateError(
          'resident source materialization authority is unavailable for '
          '${session.id.key}',
        );
      }
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
      await cache.storePromotedArtifact(id: targetId, bytes: bytes);
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
    final builder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks()) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
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
    await cache.storePromotedArtifact(
      id: targetId,
      bytes: bytes,
    );
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
