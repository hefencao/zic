import 'dart:async';

import 'package:sessions/sessions.dart';
import 'package:telemetry/telemetry.dart';

import 'partial_download_handoff.dart';
import 'promoted_artifact_cache_handoff.dart';

/// Bounded hot-session retention for the composition-owned physical transfer
/// registry.
///
/// Logical consumers never choose eviction. Recently idle promoted immutable
/// sessions remain in a small composition-owned LRU so nearby reverse traversal
/// can reuse the same physical/source generation instead of rebuilding it from
/// the durable artifact. Promoted pressure victims first settle through
/// [PromotedArtifactCacheHandoff]; unfinished prefixes move through
/// [PartialDownloadHandoff] only under their separate hot-partial pressure.
/// [DownloadTransferOwner] remains the sole scheduler and performs the final
/// mechanical session retirement.
final class PhysicalTransferRetention {
  PhysicalTransferRetention({
    required this.registry,
    required this.owner,
    required this.clock,
    required this.traceSink,
    this.artifactHandoff,
    this.partialHandoff,
    this.sessionId = 'composition-transfer-owner',
    this.maxIdlePromotedSessions = 8,
    this.maxIdlePartialSessions = 32,
    this.maxIdlePartialBytes = 256 * 1024 * 1024,
  })  : assert(maxIdlePromotedSessions >= 0),
        assert(maxIdlePartialSessions >= 0),
        assert(maxIdlePartialBytes >= 0);

  final DownloadRegistry registry;
  final DownloadTransferOwner owner;
  final MonoClock clock;
  final TraceSink traceSink;
  final PromotedArtifactCacheHandoff? artifactHandoff;
  final PartialDownloadHandoff? partialHandoff;
  final String sessionId;
  final int maxIdlePromotedSessions;
  final int maxIdlePartialSessions;
  final int maxIdlePartialBytes;

  final Map<DownloadSession, DownloadSnapshotListener> _listeners =
      <DownloadSession, DownloadSnapshotListener>{};
  final Map<DownloadSession, int> _touchOrder = <DownloadSession, int>{};
  int _touchSequence = 0;
  bool _dirty = false;
  bool _disposed = false;
  Future<void>? _maintenance;

  void observe(DownloadSession session) {
    if (_disposed || _listeners.containsKey(session)) return;
    void listener(DownloadSnapshot snapshot) {
      if (_disposed) return;
      _touchOrder[session] = ++_touchSequence;
      if (_isIdle(snapshot)) _scheduleMaintenance();
    }

    _listeners[session] = listener;
    _touchOrder[session] = ++_touchSequence;
    session.addSnapshotListener(listener, fireImmediately: false);
  }

  Future<void> settle() async {
    _scheduleMaintenance();
    while (true) {
      final running = _maintenance;
      if (running == null) return;
      await running;
      if (!_dirty && _maintenance == null) return;
    }
  }

  /// Drops the retention observer for a session that was explicitly deleted
  /// rather than evicted by this retention policy.
  void forget(DownloadSession session) {
    _forget(session);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final running = _maintenance;
    if (running != null) await running;
    for (final entry in _listeners.entries) {
      entry.key.removeSnapshotListener(entry.value);
    }
    _listeners.clear();
    _touchOrder.clear();
  }

  void _scheduleMaintenance() {
    if (_disposed) return;
    _dirty = true;
    if (_maintenance != null) return;
    late final Future<void> running;
    running = Future<void>.microtask(_runMaintenance).whenComplete(() {
      if (identical(_maintenance, running)) _maintenance = null;
      if (_dirty && !_disposed) _scheduleMaintenance();
    });
    _maintenance = running;
  }

  Future<void> _runMaintenance() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      await _trimIdlePromoted();
      await _trimIdlePartials();
    }
  }

  Future<void> _trimIdlePromoted() async {
    while (!_disposed) {
      final candidates = registry.sessions
          .where((session) =>
              session.state == DownloadState.promoted &&
              _isIdle(session.snapshot))
          .toList(growable: false)
        ..sort(_compareOldestFirst);
      if (candidates.length <= maxIdlePromotedSessions) return;

      // Promoted immutable sessions are cheap physical/source-generation
      // authorities compared with re-reading the durable body into a fresh
      // physical generation on every nearby reverse traversal. Retain a small
      // composition-owned LRU tail and retire only pressure victims. The
      // durable handoff remains the mandatory barrier before retirement.
      var retired = false;
      for (final session in candidates) {
        if (_disposed) return;
        if (session.state != DownloadState.promoted ||
            !_isIdle(session.snapshot)) {
          continue;
        }
        final handoff = artifactHandoff;
        if (handoff == null || !await handoff.settleAutomatic(session)) {
          continue;
        }
        if (session.state != DownloadState.promoted ||
            !_isIdle(session.snapshot)) {
          continue;
        }
        final bytes = session.committedLength;
        final residentBodyBacked = session.residentBodyBacked;
        if (!await owner.retireIdlePhysical(session.id)) continue;
        _forget(session);
        handoff.unobserve(session);
        _recordRetirement(
          session,
          action: residentBodyBacked
              ? 'retired-promoted-resident'
              : 'retired-promoted-durable',
          bytes: bytes,
          reason: 'hot-promoted-retention-pressure',
        );
        retired = true;
        break;
      }
      if (!retired) return;
    }
  }

  Future<void> _trimIdlePartials() async {
    while (!_disposed) {
      final candidates = registry.sessions
          .where((session) =>
              session.state != DownloadState.promoted &&
              session.state != DownloadState.disposed &&
              _isIdle(session.snapshot))
          .toList(growable: false)
        ..sort(_compareOldestFirst);
      final retainedBytes = candidates.fold<int>(
        0,
        (total, session) => total + session.artifact.committedLength,
      );
      if (candidates.length <= maxIdlePartialSessions &&
          retainedBytes <= maxIdlePartialBytes) {
        return;
      }
      final victim = candidates.first;
      final bytes = victim.artifact.committedLength;
      if (bytes > 0) {
        final handoff = partialHandoff;
        if (handoff == null ||
            !await handoff.persist(
              victim,
              reason: 'hot-retention-pressure',
            )) {
          return;
        }
      }
      if (!_isIdle(victim.snapshot)) continue;
      if (!await owner.retireIdlePhysical(victim.id)) continue;
      _forget(victim);
      artifactHandoff?.unobserve(victim);
      _recordRetirement(
        victim,
        action: bytes > 0 ? 'retired-partial' : 'retired-empty',
        bytes: bytes,
        reason: 'hot-partial-retention-pressure',
      );
    }
  }

  int _compareOldestFirst(DownloadSession left, DownloadSession right) {
    final order = (_touchOrder[left] ?? 0).compareTo(_touchOrder[right] ?? 0);
    if (order != 0) return order;
    return left.id.key.compareTo(right.id.key);
  }

  bool _isIdle(DownloadSnapshot snapshot) =>
      !snapshot.demanded && !snapshot.activeRun && !snapshot.hasWriter;

  void _forget(DownloadSession session) {
    final listener = _listeners.remove(session);
    if (listener != null) session.removeSnapshotListener(listener);
    _touchOrder.remove(session);
  }

  void _recordRetirement(
    DownloadSession session, {
    required String action,
    required int bytes,
    required String reason,
  }) {
    try {
      final idle = registry.sessions
          .where((candidate) => _isIdle(candidate.snapshot))
          .toList(growable: false);
      final idlePromoted = idle
          .where((candidate) => candidate.state == DownloadState.promoted)
          .toList(growable: false);
      final idlePartials = idle
          .where((candidate) => candidate.state != DownloadState.promoted)
          .toList(growable: false);
      traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.artifactSource,
          identityHash: session.id.key,
          payload: <String, Object?>{
            'source': 'composition-physical-retention',
            'consumer': 'hot-transfer-registry',
            'action': action,
            'reason': reason,
            'bytes': bytes,
            'maxIdlePromotedSessions': maxIdlePromotedSessions,
            'retainedIdlePromotedSessions': idlePromoted.length,
            'retainedIdleSessions': idle.length,
            'retainedIdlePartialBytes': idlePartials.fold<int>(
              0,
              (total, candidate) =>
                  total + candidate.artifact.committedLength,
            ),
          },
        ),
      );
    } on Object {
      // Diagnostics cannot alter physical retirement.
    }
  }
}
