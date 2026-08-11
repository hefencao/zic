import 'dart:async';

import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'download_job.dart';
import 'download_registry.dart';
import 'download_session.dart';
import 'net_lane.dart';
import 'retry_policy.dart';

typedef TransferTransportPick = Transport Function(Uri uri);
typedef TransferPrepare = Future<void> Function(DownloadSession session);
typedef TransferSleep = Future<void> Function(Duration delay);
typedef TransferPersistUnclaimed = Future<void> Function(DownloadSession session);

Future<void> _defaultTransferSleep(Duration delay) =>
    Future<void>.delayed(delay);

/// Composition-owned physical image-transfer scheduler.
///
/// [DownloadRegistry], network task identity, retry/terminal state and the
/// active writer all live here. Reader sessions attach scoped
/// [DownloadTransferConsumer] objects; removing one consumer never destroys a
/// transfer still demanded by another consumer.
final class DownloadTransferOwner {
  DownloadTransferOwner({
    required this.registry,
    required this.clock,
    this.prepareDownload,
    this.persistUnclaimed,
    required this.net,
  });

  final DownloadRegistry registry;
  final MonoClock clock;
  final TransferPrepare? prepareDownload;
  final TransferPersistUnclaimed? persistUnclaimed;
  final NetLane net;

  final Map<DownloadId, Map<String, _TransferClaim>> _claims =
      <DownloadId, Map<String, _TransferClaim>>{};
  final Map<DownloadId, String> _networkTaskKeys = <DownloadId, String>{};
  final Map<DownloadId, int> _downloadRetryRounds = <DownloadId, int>{};
  final Set<DownloadId> _downloadRetryPending = <DownloadId>{};
  final Set<DownloadId> _downloadTerminalFailures = <DownloadId>{};
  final Map<DownloadId, int> _downloadDeferredAtLength = <DownloadId, int>{};
  final Map<DownloadId, String> _activeProviderScopes = <DownloadId, String>{};
  final Map<DownloadId, int> _progressLengths = <DownloadId, int>{};
  final Map<DownloadId, Future<void>> _unclaimedFlushes =
      <DownloadId, Future<void>>{};
  final Map<DownloadId, DownloadSnapshotListener> _sessionListeners =
      <DownloadId, DownloadSnapshotListener>{};
  final Set<DownloadTransferConsumer> _consumers =
      <DownloadTransferConsumer>{};
  int _taskSequence = 0;
  int _claimSequence = 0;
  bool _disposed = false;

  static const int _maxDownloadRetryRounds = 4;

  Iterable<DownloadTransferConsumer> get consumers =>
      List<DownloadTransferConsumer>.unmodifiable(_consumers);

  int claimCount(DownloadId id) => _claims[id]?.length ?? 0;

  String? activeProviderScope(DownloadId id) => _activeProviderScopes[id];

  String? taskKeyFor(DownloadId id) => _networkTaskKeys[id];

  DownloadTransferConsumer attachConsumer({
    required String scopeId,
    required TransferTransportPick transportFor,
    required TraceSink traceSink,
    RetryPolicy retry = const RetryPolicy(),
    TransferSleep sleep = _defaultTransferSleep,
    String Function(DownloadId id)? downloadBucketFor,
    int Function(DownloadId id)? downloadBucketLimitFor,
  }) {
    if (_disposed) {
      throw StateError('download transfer owner is disposed');
    }
    if (_consumers.any((consumer) => consumer.scopeId == scopeId)) {
      throw ArgumentError.value(scopeId, 'scopeId', 'must be unique');
    }
    retry.validate();
    final consumer = DownloadTransferConsumer._(
      owner: this,
      scopeId: scopeId,
      transportFor: transportFor,
      traceSink: traceSink,
      retry: retry,
      sleep: sleep,
      downloadBucketFor:
          downloadBucketFor ?? ((id) => 'source:${id.content.sourceId}'),
      downloadBucketLimitFor: downloadBucketLimitFor ?? ((_) => 5),
    );
    _consumers.add(consumer);
    return consumer;
  }

  void refreshForLocalArtifact(DownloadId id, {String? sessionId}) {
    if (_disposed) return;
    final session = registry.find(id);
    if (session == null ||
        session.state == DownloadState.promoted ||
        session.state == DownloadState.disposed ||
        session.residentCacheBacked) {
      return;
    }
    _downloadRetryRounds.remove(id);
    _downloadRetryPending.remove(id);
    _downloadTerminalFailures.remove(id);
    _downloadDeferredAtLength.remove(id);
    final claim = _preferredClaim(id);
    final taskKey = _networkTaskKeys[id];
    _record(
      claim,
      sessionId: sessionId,
      kind: TraceEventKind.artifactSource,
      id: id,
      payload: <String, Object?>{
        'stage': 'verified-equivalent-promotion-takeover',
        'committedLength': session.committedLength,
        'taskState': taskKey == null
            ? 'absent'
            : net.isActive(taskKey)
                ? 'active'
                : 'queued',
      },
    );
    if (!session.demanded) {
      return;
    }
    if (taskKey == null) {
      _ensureDownloadTask(id, session);
      return;
    }
    if (net.cancelQueued(taskKey)) {
      if (_networkTaskKeys[id] == taskKey) {
        _networkTaskKeys.remove(id);
      }
      _ensureDownloadTask(id, session);
      return;
    }
    // Active cancellation preserves the authoritative physical session and
    // writer prefix. The task finally path reopens under the strongest
    // remaining consumer context.
    net.cancel(taskKey);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final keys = _networkTaskKeys.values.toList(growable: false);
    for (final consumer in _consumers.toList(growable: false)) {
      _detachClaims(consumer, consumerDisposing: true);
      consumer._disposed = true;
    }
    _consumers.clear();
    for (final key in keys) {
      net.cancel(key);
    }
    await net.idleKeys(keys);
    if (_unclaimedFlushes.isNotEmpty) {
      await Future.wait<void>(
        _unclaimedFlushes.values.toList(growable: false),
      );
    }
    _networkTaskKeys.clear();
    _downloadRetryRounds.clear();
    _downloadRetryPending.clear();
    _downloadTerminalFailures.clear();
    _downloadDeferredAtLength.clear();
    _activeProviderScopes.clear();
    for (final entry in _sessionListeners.entries) {
      registry.find(entry.key)?.removeSnapshotListener(entry.value);
    }
    _sessionListeners.clear();
    _progressLengths.clear();
    _unclaimedFlushes.clear();
    _claims.clear();
  }

  void _reconcile(
    DownloadTransferConsumer consumer,
    String sessionId,
    int revision,
    MapDiff<DownloadId, DownloadDemand> diff,
  ) {
    if (_disposed || consumer._disposed) return;
    consumer._sessionId = sessionId;
    consumer._revision = revision;
    for (final id in diff.removed) {
      consumer._demands.remove(id);
      _removeClaim(consumer, id, sessionId: sessionId);
    }
    final toSchedule = <MapEntry<DownloadId, DownloadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ];
    for (final entry in toSchedule) {
      consumer._demands[entry.key] = entry.value;
      _upsertClaim(
        consumer,
        entry.key,
        entry.value,
        sessionId: sessionId,
        revision: revision,
      );
    }
    for (final entry in toSchedule) {
      _ensureDownloadTask(entry.key, registry.get(entry.key));
    }
  }

  void _upsertClaim(
    DownloadTransferConsumer consumer,
    DownloadId id,
    DownloadDemand demand, {
    required String sessionId,
    required int revision,
  }) {
    final session = registry.get(id);
    _watchSession(session);
    final byScope = _claims.putIfAbsent(id, () => <String, _TransferClaim>{});
    final existing = byScope[consumer.scopeId];
    if (existing == null) {
      final lease = session.attachDemand(
        scopeId: consumer.scopeId,
        priority: demand.priority,
      );
      byScope[consumer.scopeId] = _TransferClaim(
        consumer: consumer,
        lease: lease,
        demand: demand,
        sessionId: sessionId,
        revision: revision,
        sequence: ++_claimSequence,
      );
    } else {
      existing.demand = demand;
      existing.sessionId = sessionId;
      existing.revision = revision;
      existing.lease.updatePriority(demand.priority);
    }
    if (!session.activeRun) {
      _downloadRetryRounds.remove(id);
      _downloadRetryPending.remove(id);
      _downloadTerminalFailures.remove(id);
      final deferredAtLength = _downloadDeferredAtLength[id];
      final deferredStillMatches = deferredAtLength == session.committedLength;
      if (!deferredStillMatches ||
          _allowsCostlyFullBodyCatchup(
            priority: demand.priority,
            preservedLength: session.committedLength,
          )) {
        _downloadDeferredAtLength.remove(id);
      }
    }
    final taskKey = _networkTaskKeys[id];
    if (taskKey != null) {
      _migrateDownloadPriority(
        id,
        taskKey,
        session.effectivePriority,
        reason: session.demandCount > 1 ? 'consumer-aggregate' : 'demand-role',
      );
    }
  }

  void _removeClaim(
    DownloadTransferConsumer consumer,
    DownloadId id, {
    required String sessionId,
  }) {
    final byScope = _claims[id];
    final claim = byScope?.remove(consumer.scopeId);
    claim?.lease.detach();
    if (byScope != null && byScope.isEmpty) {
      _claims.remove(id);
    }
    final session = registry.find(id);
    final taskKey = _networkTaskKeys[id];
    final taskIsActive = taskKey != null && net.isActive(taskKey);
    final receiving = session?.state == DownloadState.receiving;
    if (session != null && session.demanded && taskKey != null) {
      _migrateDownloadPriority(
        id,
        taskKey,
        session.effectivePriority,
        reason: 'remaining-consumer',
      );
    } else if (receiving && taskIsActive) {
      _migrateDownloadPriority(
        id,
        taskKey!,
        0,
        reason: 'retained-background',
      );
    } else if (taskKey != null && taskIsActive) {
      // A pre-open run is not worth retaining after its final logical demand
      // disappears. An established receiving writer may finish at priority 0.
      net.cancel(taskKey);
    } else {
      if (taskKey != null) {
        net.cancelQueued(taskKey);
      }
      _networkTaskKeys.remove(id);
      if (session != null && !session.demanded) {
        unawaited(_persistUnclaimed(session));
      }
      _retireDownloadTracking(id, session);
    }
  }

  Future<void> _disposeConsumer(DownloadTransferConsumer consumer) async {
    if (consumer._disposed) return;
    consumer._disposed = true;
    final releasedIds = consumer._demands.keys.toList(growable: false);
    final providerKeys = <String>[];
    for (final entry in _activeProviderScopes.entries.toList(growable: false)) {
      if (entry.value != consumer.scopeId) continue;
      final key = _networkTaskKeys[entry.key];
      if (key != null) {
        providerKeys.add(key);
        net.cancel(key);
      }
    }
    _detachClaims(consumer, consumerDisposing: true);
    _consumers.remove(consumer);
    // A Reader-owned transport may be closed immediately after this Future.
    // Wait until every active task that captured that transport has physically
    // exited. New work uses a fresh task key and the strongest remaining
    // consumer, so it is intentionally not part of this barrier.
    if (providerKeys.isNotEmpty) {
      await net.idleKeys(providerKeys);
      await Future<void>.delayed(Duration.zero);
    }
    final pendingFlushes = <Future<void>>[];
    for (final id in releasedIds) {
      final flush = _unclaimedFlushes[id];
      if (flush != null) {
        pendingFlushes.add(flush);
      }
    }
    if (pendingFlushes.isNotEmpty) {
      await Future.wait<void>(pendingFlushes);
    }
  }

  void _detachClaims(
    DownloadTransferConsumer consumer, {
    required bool consumerDisposing,
  }) {
    final ids = consumer._demands.keys.toList(growable: false);
    consumer._demands.clear();
    for (final id in ids) {
      _removeClaim(
        consumer,
        id,
        sessionId: consumer._sessionId ?? consumer.scopeId,
      );
    }
    if (!consumerDisposing) return;
    // A retained background transfer may no longer have a claim but can still
    // be running under this consumer's transport. It cannot outlive the
    // transport owner, so cancel it now. The hot physical prefix stays in the
    // composition registry and is reusable by a later consumer.
    for (final entry in _activeProviderScopes.entries.toList(growable: false)) {
      if (entry.value != consumer.scopeId) continue;
      final key = _networkTaskKeys[entry.key];
      if (key != null) {
        net.cancel(key);
      }
    }
  }

  void _refreshScheduling(DownloadTransferConsumer consumer) {
    if (_disposed || consumer._disposed) return;
    for (final id in consumer._demands.keys) {
      final session = registry.find(id);
      if (session != null) {
        _ensureDownloadTask(id, session);
      }
    }
  }

  Future<void> _idleFor(DownloadTransferConsumer consumer) async {
    while (!_disposed && !consumer._disposed) {
      final ids = consumer._demands.keys.toList(growable: false);
      final keys = <String>{};
      for (final id in ids) {
        final key = _networkTaskKeys[id];
        if (key != null) {
          keys.add(key);
        }
      }
      if (keys.isNotEmpty) {
        await net.idleKeys(keys);
      }
      await Future<void>.delayed(Duration.zero);
      var pending = false;
      for (final id in ids) {
        final session = registry.find(id);
        if (session == null) continue;
        if (_networkTaskKeys.containsKey(id) ||
            _downloadRetryPending.contains(id) ||
            (session.demanded &&
                session.state != DownloadState.promoted &&
                session.state != DownloadState.failed &&
                session.state != DownloadState.disposed &&
                !_downloadTerminalFailures.contains(id))) {
          pending = true;
          break;
        }
      }
      if (!pending) return;
    }
  }

  void _ensureDownloadTask(DownloadId id, DownloadSession session) {
    final claim = _preferredClaim(id);
    if (claim == null || !session.demanded) return;
    final effectivePriority = session.effectivePriority;
    final existingTaskKey = _networkTaskKeys[id];
    if (existingTaskKey != null) {
      // A DownloadId has one physical task identity while that task is queued
      // or active. Policy revisions only migrate its priority; they must not
      // manufacture a second task key for the same DownloadSession.
      if (net.priorityOf(existingTaskKey) != null) {
        _migrateDownloadPriority(
          id,
          existingTaskKey,
          effectivePriority,
          reason: session.demandCount > 1 ? 'consumer-aggregate' : 'demand-role',
        );
        return;
      }
      // Defensive stale-key recovery: the lane has already retired this key.
      // Only then may this exact DownloadId acquire a new physical task key.
      if (_networkTaskKeys[id] == existingTaskKey) {
        _networkTaskKeys.remove(id);
      }
    }
    if (_disposed ||
        session.state == DownloadState.promoted ||
        session.state == DownloadState.disposed ||
        session.activeRun ||
        session.hasWriter ||
        _downloadRetryPending.contains(id) ||
        _downloadTerminalFailures.contains(id) ||
        (_downloadDeferredAtLength[id] == session.committedLength &&
            !_allowsCostlyFullBodyCatchup(
              priority: effectivePriority,
              preservedLength: session.committedLength,
            )) ||
        (_downloadRetryRounds[id] ?? 0) > _maxDownloadRetryRounds) {
      return;
    }
    final taskKey = 'transfer:${++_taskSequence}:${id.key}';
    _networkTaskKeys[id] = taskKey;
    net.submitRanked(
      key: taskKey,
      priority: effectivePriority,
      bucket: claim.consumer.downloadBucketFor(id),
      bucketLimit: claim.consumer.downloadBucketLimitFor(id),
      task: (token) => _runDownload(id, session, taskKey, token),
    );
  }

  Future<void> _runDownload(
    DownloadId id,
    DownloadSession session,
    String taskKey,
    CancelToken token,
  ) async {
    // A queued task can become stale only if its physical identity was
    // explicitly retired/replaced. Never let a stale lane entry begin a
    // second run against the authoritative DownloadSession.
    if (_networkTaskKeys[id] != taskKey) return;
    final claim = _preferredClaim(id);
    if (claim == null) return;
    final provider = claim.consumer;
    _activeProviderScopes[id] = provider.scopeId;
    try {
      final bucket = provider.downloadBucketFor(id);
      final bucketLimit = provider.downloadBucketLimitFor(id);
      final prepare = prepareDownload;
      if (prepare != null && session.committedLength == 0) {
        await prepare(session);
        token.throwIfCancelled();
      }
      _record(
        claim,
        kind: TraceEventKind.downloadStarted,
        id: id,
        payload: <String, Object?>{
          'priority': session.effectivePriority,
          'bucket': bucket,
          'bucketLimit': bucketLimit,
          'globalActive': net.active,
          'globalLimit': net.maxActive,
          'handoffActive': net.handoffActive,
          'effectivePriority': net.priorityOf(taskKey),
          'bucketActive': net.activeForBucket(bucket),
          'committedLength': session.committedLength,
          'physicalOwner': true,
          'providerScope': provider.scopeId,
        },
      );
      for (var attempt = 1; ; attempt++) {
        token.throwIfCancelled();
        final attemptStartedAtMicros = clock.nowMicros();
        try {
          await DownloadJob(
            transport: provider.transportFor(id.canonicalUri),
            session: session,
            attachLegacyDemand: false,
            allowFullBodyCatchup: (preservedLength) =>
                _allowsCostlyFullBodyCatchup(
              priority: token.priority,
              preservedLength: preservedLength,
            ),
          ).run(cancel: token);
          _downloadRetryRounds.remove(id);
          _downloadRetryPending.remove(id);
          _downloadTerminalFailures.remove(id);
          _downloadDeferredAtLength.remove(id);
          return;
        } on DownloadCatchupDeferred {
          final remainingPriority =
              session.demanded ? session.effectivePriority : null;
          if (remainingPriority != null &&
              _allowsCostlyFullBodyCatchup(
                priority: remainingPriority,
                preservedLength: session.committedLength,
              )) {
            _downloadDeferredAtLength.remove(id);
          } else {
            _downloadDeferredAtLength[id] = session.committedLength;
          }
          return;
        } on Object catch (error) {
          if (!provider.retry.allows(error, attempt)) {
            if (error is Failure && error.code == ErrorCode.cancelled) {
              final preemption = token.preemptionSnapshot;
              if (preemption != null) {
                _record(
                  claim,
                  kind: TraceEventKind.downloadPreempted,
                  id: id,
                  payload: <String, Object?>{
                    'incomingPriority': preemption.incomingPriority,
                    'basePriority': preemption.basePriority,
                    'retentionPriority': preemption.retentionPriority,
                    'retentionBonus': preemption.retentionBonus,
                    'restartCostElapsedMicros':
                        preemption.restartCostElapsedMicros,
                    'restartCostBytes': preemption.restartCostBytes,
                    'committedLength': session.committedLength,
                  },
                );
              }
              return;
            }
            final failedAtMicros = clock.nowMicros();
            _recordError(
              claim,
              id,
              error,
              details: <String, Object?>{
                'attempt': attempt,
                'executionMicros': (failedAtMicros - attemptStartedAtMicros)
                    .clamp(0, 1 << 62)
                    .toInt(),
              },
            );
            if (session.demanded && error is Failure) {
              final retryScheduled = error.code == ErrorCode.network &&
                  _scheduleDownloadRetry(id, session, error);
              if (!retryScheduled) {
                _downloadTerminalFailures.add(id);
              }
            } else if (session.demanded) {
              _downloadTerminalFailures.add(id);
            }
            return;
          }
          final delay = provider.retry.delayAfter(attempt);
          _record(
            claim,
            kind: TraceEventKind.retryScheduled,
            id: id,
            payload: <String, Object?>{
              'stage': 'download-attempt',
              'attempt': attempt + 1,
              'delayUs': delay.inMicroseconds,
              'error': '$error',
            },
          );
          await _sleepOrCancel(delay, token, provider.sleep);
        }
      }
    } finally {
      if (_activeProviderScopes[id] == provider.scopeId) {
        _activeProviderScopes.remove(id);
      }
      if (_networkTaskKeys[id] == taskKey) {
        _networkTaskKeys.remove(id);
      }
      if (!session.demanded && !session.activeRun) {
        await _persistUnclaimed(session);
        _retireDownloadTracking(id, session);
      } else if (session.demanded &&
          !_downloadTerminalFailures.contains(id) &&
          session.state != DownloadState.promoted &&
          session.state != DownloadState.disposed) {
        scheduleMicrotask(() {
          if (!_disposed && session.demanded) {
            _ensureDownloadTask(id, session);
          }
        });
      }
    }
  }

  bool _scheduleDownloadRetry(
    DownloadId id,
    DownloadSession session,
    Failure failure,
  ) {
    if (_disposed || _downloadRetryPending.contains(id) || !session.demanded) {
      return false;
    }
    final claim = _preferredClaim(id);
    if (claim == null) return false;
    final round = (_downloadRetryRounds[id] ?? 0) + 1;
    if (round > _maxDownloadRetryRounds) {
      return false;
    }
    _downloadRetryRounds[id] = round;
    _downloadRetryPending.add(id);
    final delay = claim.consumer.retry.delayAfter(round);
    _record(
      claim,
      kind: TraceEventKind.retryScheduled,
      id: id,
      payload: <String, Object?>{
        'stage': 'download-recovery',
        'attempt': round,
        'delayUs': delay.inMicroseconds,
        'committedLength': session.committedLength,
        'error': '$failure',
      },
    );
    unawaited(() async {
      await claim.consumer.sleep(delay);
      await Future<void>.delayed(Duration.zero);
      _downloadRetryPending.remove(id);
      if (_disposed || !session.demanded) return;
      _ensureDownloadTask(id, session);
    }());
    return true;
  }


  Future<void> _persistUnclaimed(DownloadSession session) async {
    final callback = persistUnclaimed;
    if (callback == null ||
        session.demanded ||
        session.activeRun ||
        session.state == DownloadState.promoted ||
        session.state == DownloadState.disposed ||
        session.residentCacheBacked ||
        session.committedLength <= 0) {
      return;
    }
    final existing = _unclaimedFlushes[session.id];
    if (existing != null) {
      await existing;
      return;
    }
    final flush = callback(session);
    _unclaimedFlushes[session.id] = flush;
    try {
      await flush;
    } finally {
      if (identical(_unclaimedFlushes[session.id], flush)) {
        _unclaimedFlushes.remove(session.id);
      }
    }
  }

  void _watchSession(DownloadSession session) {
    final id = session.id;
    if (_sessionListeners.containsKey(id)) return;
    _progressLengths[id] = session.committedLength;
    void listener(DownloadSnapshot snapshot) {
      final prior = _progressLengths[id] ?? 0;
      if (snapshot.committedLength > prior) {
        _progressLengths[id] = snapshot.committedLength;
        _downloadRetryRounds.remove(id);
        _downloadRetryPending.remove(id);
        _downloadTerminalFailures.remove(id);
      }
    }
    _sessionListeners[id] = listener;
    session.addSnapshotListener(listener, fireImmediately: false);
  }

  void _retireDownloadTracking(DownloadId id, DownloadSession? session) {
    _downloadRetryRounds.remove(id);
    _downloadRetryPending.remove(id);
    _downloadTerminalFailures.remove(id);
    final deferredAtLength = _downloadDeferredAtLength[id];
    final preserveDeferred = session != null &&
        session.state == DownloadState.idle &&
        deferredAtLength == session.committedLength;
    if (!preserveDeferred) {
      _downloadDeferredAtLength.remove(id);
    }
  }

  void _migrateDownloadPriority(
    DownloadId id,
    String taskKey,
    int priority, {
    required String reason,
  }) {
    final oldPriority = net.priorityOf(taskKey);
    final active = net.isActive(taskKey);
    if (!net.updatePriority(taskKey, priority) ||
        oldPriority == null ||
        oldPriority == priority) {
      return;
    }
    _record(
      _preferredClaim(id),
      kind: TraceEventKind.downloadPriorityChanged,
      id: id,
      payload: <String, Object?>{
        'oldPriority': oldPriority,
        'newPriority': priority,
        'active': active,
        'reason': reason,
        'physicalOwner': true,
      },
    );
  }

  _TransferClaim? _preferredClaim(DownloadId id) {
    final values = _claims[id]?.values;
    if (values == null || values.isEmpty) return null;
    return values.reduce((left, right) {
      final priorityOrder = left.demand.priority.compareTo(right.demand.priority);
      if (priorityOrder != 0) {
        return priorityOrder > 0 ? left : right;
      }
      return left.sequence <= right.sequence ? left : right;
    });
  }

  bool _allowsCostlyFullBodyCatchup({
    required int priority,
    required int preservedLength,
  }) {
    const largePrefixBytes = 1024 * 1024;
    const veryLargePrefixBytes = 8 * 1024 * 1024;
    const foregroundAdjacentPriorityFloor = 820;
    const visibleTransitionPriorityFloor = 900;
    if (preservedLength < largePrefixBytes) return true;
    if (preservedLength >= veryLargePrefixBytes) {
      return priority >= visibleTransitionPriorityFloor;
    }
    return priority >= foregroundAdjacentPriorityFloor;
  }

  Future<void> _sleepOrCancel(
    Duration delay,
    CancelToken token,
    TransferSleep sleep,
  ) async {
    if (delay == Duration.zero) {
      token.throwIfCancelled();
      return;
    }
    await Future.any<void>(<Future<void>>[
      sleep(delay),
      token.whenCancelled,
    ]);
    token.throwIfCancelled();
  }

  void _record(
    _TransferClaim? claim, {
    String? sessionId,
    required TraceEventKind kind,
    required DownloadId id,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    if (claim == null) return;
    try {
      claim.consumer.traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId ?? claim.sessionId,
          kind: kind,
          identityHash: id.key,
          revision: claim.revision,
          payload: payload,
        ),
      );
    } on Object {
      // Observability must never break the physical transfer owner.
    }
  }

  void _recordError(
    _TransferClaim claim,
    DownloadId id,
    Object error, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    _record(
      claim,
      kind: TraceEventKind.taskFailed,
      id: id,
      payload: <String, Object?>{
        'lane': 'network',
        'error': '$error',
        ...details,
      },
    );
  }
}

/// Reader/command-local demand lease into the composition transfer owner.
final class DownloadTransferConsumer {
  DownloadTransferConsumer._({
    required this.owner,
    required this.scopeId,
    required this.transportFor,
    required this.traceSink,
    required this.retry,
    required this.sleep,
    required this.downloadBucketFor,
    required this.downloadBucketLimitFor,
  });

  final DownloadTransferOwner owner;
  final String scopeId;
  final TransferTransportPick transportFor;
  final TraceSink traceSink;
  final RetryPolicy retry;
  final TransferSleep sleep;
  final String Function(DownloadId id) downloadBucketFor;
  final int Function(DownloadId id) downloadBucketLimitFor;
  final Map<DownloadId, DownloadDemand> _demands =
      <DownloadId, DownloadDemand>{};
  String? _sessionId;
  int _revision = 0;
  bool _disposed = false;

  DownloadRegistry get registry => owner.registry;
  NetLane get net => owner.net;
  bool get disposed => _disposed;
  Map<DownloadId, DownloadDemand> get demands =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_demands);

  void reconcile(
    String sessionId,
    int revision,
    MapDiff<DownloadId, DownloadDemand> diff,
  ) =>
      owner._reconcile(this, sessionId, revision, diff);

  void refreshScheduling() => owner._refreshScheduling(this);

  void refreshForLocalArtifact(DownloadId id) =>
      owner.refreshForLocalArtifact(id, sessionId: _sessionId);

  Future<void> idle() => owner._idleFor(this);

  Future<void> dispose() => owner._disposeConsumer(this);
}

final class _TransferClaim {
  _TransferClaim({
    required this.consumer,
    required this.lease,
    required this.demand,
    required this.sessionId,
    required this.revision,
    required this.sequence,
  });

  final DownloadTransferConsumer consumer;
  final DownloadDemandLease lease;
  DownloadDemand demand;
  String sessionId;
  int revision;
  final int sequence;
}
