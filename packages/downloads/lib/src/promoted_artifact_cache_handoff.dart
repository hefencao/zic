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
  });

  final ArtifactCacheManager cache;
  final ArtifactCacheHandoffError? onError;
  final MonoClock? clock;
  final TraceSink traceSink;
  final String sessionId;
  final ResidentArtifactReplaySource? residentReplaySource;
  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadId, Future<void>> _commits =
      <DownloadId, Future<void>>{};

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

  /// Ensures a promoted transfer has a durable cache-owned body.
  ///
  /// Ordinary promotion observation does not materialize a reopenable source
  /// body merely because a Reader displayed it. Explicit durable commands call
  /// this barrier when their completion semantics require persistent bytes.
  Future<void> persist(DownloadSession session) async {
    if (session.state != DownloadState.promoted) return;
    while (true) {
      final pending = _commits[session.id];
      if (pending == null) break;
      await pending;
    }
    await _commit(session, requireExactDurableBody: true);
  }

  void detach() {
    for (final entry in _listeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _listeners.clear();
  }

  void _submit(DownloadSession session) {
    final id = session.id;
    if (_commits.containsKey(id)) {
      return;
    }
    final tracked = _runCommit(session);
    _commits[id] = tracked;
    unawaited(tracked);
  }

  Future<void> _runCommit(DownloadSession session) async {
    final id = session.id;
    try {
      await _commit(session);
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

  Future<void> _commit(
    DownloadSession session, {
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
        id: session.id,
        expectedLength: expectedLength,
      );
      if (alreadyDurable) {
        _recordCommit(
          session,
          action: 'skip-cache-resident',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }

      final lookup = await cache.lookup(session.id);
      if (lookup != null && lookup.entry.length == expectedLength) {
        if (lookup.storageId != session.id &&
            lookup.durable &&
            !requireExactDurableBody) {
          _recordCommit(
            session,
            action: 'skip-verified-equivalent-durable',
            bytes: expectedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
        if (!lookup.durable && !requireExactDurableBody) {
          _recordCommit(
            session,
            action: 'defer-resident-source',
            bytes: expectedLength,
            startedAtMicros: startedAtMicros,
          );
          return;
        }
        final read = await cache.readForegroundLookup(lookup);
        if (read.bytes.lengthInBytes != expectedLength) {
          throw StateError(
            'resident cache replay length changed for ${session.id.key}',
          );
        }
        await cache.storePromotedArtifact(id: session.id, bytes: read.bytes);
        _recordCommit(
          session,
          action: 'stored-resident-cache-authority',
          bytes: expectedLength,
          startedAtMicros: startedAtMicros,
        );
        return;
      }

      if (!requireExactDurableBody) {
        _recordCommit(
          session,
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
      await cache.storePromotedArtifact(id: session.id, bytes: bytes);
      _recordCommit(
        session,
        action: 'stored-resident-source',
        bytes: bytes.lengthInBytes,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final expectedLength = session.artifact.committedLength;
    if (expectedLength <= 0) {
      _recordCommit(
        session,
        action: 'skip-empty',
        bytes: 0,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    final alreadyDurable = await cache.containsBackendExact(
      id: session.id,
      expectedLength: expectedLength,
    );
    if (alreadyDurable) {
      _recordCommit(
        session,
        action: 'skip-existing',
        bytes: expectedLength,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    if (!requireExactDurableBody) {
      final equivalent = await cache.lookup(session.id);
      if (equivalent != null &&
          equivalent.storageId != session.id &&
          equivalent.durable &&
          equivalent.entry.length == expectedLength) {
        _recordCommit(
          session,
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
        action: 'skip-empty',
        bytes: 0,
        startedAtMicros: startedAtMicros,
      );
      return;
    }
    await cache.storePromotedArtifact(
      id: session.id,
      bytes: bytes,
    );
    _recordCommit(
      session,
      action: 'stored',
      bytes: bytes.lengthInBytes,
      startedAtMicros: startedAtMicros,
    );
  }

  void _recordCommit(
    DownloadSession session, {
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
        identityHash: session.id.key,
        payload: <String, Object?>{
          'source': 'session-artifact-handoff',
          'consumer': 'persistent-cache',
          'action': action,
          'bytes': bytes,
          if (startedAtMicros != null)
            'handoffMicros': (sourceClock.nowMicros() - startedAtMicros)
                .clamp(0, 1 << 62)
                .toInt(),
        },
      ),
    );
  }
}
