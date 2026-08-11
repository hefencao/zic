import 'dart:async';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'download_job.dart';
import 'download_registry.dart';
import 'download_session.dart';
import 'net_lane.dart';
import 'retry_policy.dart';

typedef TransferTransportPick = Transport Function(Uri uri);
typedef TransferIdentityResolver = DownloadId Function(DownloadId exactId);

DownloadId _identityTransferId(DownloadId id) => id;

enum TransferCompletionIntent {
  opportunistic,
  required,
}

final class TransferDemand {
  const TransferDemand({
    required this.priority,
    required this.reason,
    this.expectedChecksum,
    this.completionIntent = TransferCompletionIntent.opportunistic,
  }) : assert(priority >= 0);

  final int priority;
  final String reason;
  final String? expectedChecksum;
  final TransferCompletionIntent completionIntent;

  @override
  bool operator ==(Object other) =>
      other is TransferDemand &&
      priority == other.priority &&
      reason == other.reason &&
      expectedChecksum == other.expectedChecksum &&
      completionIntent == other.completionIntent;

  @override
  int get hashCode =>
      Object.hash(priority, reason, expectedChecksum, completionIntent);
}

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
    this.resolveTransferId = _identityTransferId,
  });

  final DownloadRegistry registry;
  final MonoClock clock;
  final TransferPrepare? prepareDownload;
  final TransferPersistUnclaimed? persistUnclaimed;
  final NetLane net;
  final TransferIdentityResolver resolveTransferId;

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

  int claimCount(DownloadId id) =>
      _claims[registry.resolvePhysicalId(id)]?.length ?? 0;

  String? activeProviderScope(DownloadId id) =>
      _activeProviderScopes[registry.resolvePhysicalId(id)];

  String? taskKeyFor(DownloadId id) =>
      _networkTaskKeys[registry.resolvePhysicalId(id)];

  /// Reopens a resident immutable body through a currently attached consumer
  /// without transferring ownership of the durable artifact to that consumer.
  ///
  /// This is used only when the physical session intentionally has no hot
  /// artifact copy. The authoritative transfer validates the replay boundary
  /// and source validators before exposing bytes to composition-level durable
  /// materialization.
  Future<Stream<List<int>>> openResidentReplay(
    DownloadId id, {
    required int endExclusive,
  }) async {
    if (_disposed) {
      throw StateError('download transfer owner is disposed');
    }
    final physicalId = registry.resolvePhysicalId(id);
    final session = registry.find(physicalId);
    if (session == null ||
        session.state != DownloadState.promoted ||
        !session.residentBodyBacked) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'resident replay requires a promoted resident transfer',
      );
    }
    if (endExclusive <= 0 || endExclusive > session.committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'invalid resident replay boundary $endExclusive/'
            '${session.committedLength}',
      );
    }
    final claim = _preferredClaim(physicalId);
    if (claim == null) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'resident replay requires an attached transfer consumer',
      );
    }
    final sourceId = claim.exactId;
    final response = await claim.consumer.transportFor(sourceId.canonicalUri).open(
          sourceId.canonicalUri,
          range: ByteRange(start: 0, end: endExclusive - 1),
          validators: session.validators,
        );
    try {
      if (response.rangeStart != 0) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay started at ${response.rangeStart}, expected 0',
        );
      }
      final expectedTotal = session.totalLength;
      if (expectedTotal != null &&
          response.totalLength != null &&
          response.totalLength != expectedTotal) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay source length changed: '
              '${response.totalLength}/$expectedTotal',
        );
      }
      if (session.validators.canResume &&
          !session.validators.matches(response.validators)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay source validators changed',
        );
      }
    } on Object {
      await response.discard();
      rethrow;
    }
    return _boundedResidentReplay(response, endExclusive, id);
  }

  Stream<List<int>> _boundedResidentReplay(
    ByteResponse response,
    int endExclusive,
    DownloadId id,
  ) async* {
    var emitted = 0;
    final iterator = StreamIterator<List<int>>(response.bytes);
    try {
      while (emitted < endExclusive && await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        final remaining = endExclusive - emitted;
        final part = chunk.length <= remaining
            ? chunk
            : chunk.sublist(0, remaining);
        emitted += part.length;
        if (part.isNotEmpty) yield part;
      }
      if (emitted != endExclusive) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay was short for ${id.key}: '
              '$emitted/$endExclusive',
        );
      }
    } finally {
      await iterator.cancel();
      await response.discard();
    }
  }

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
    final physicalId = registry.resolvePhysicalId(id);
    final session = registry.find(physicalId);
    if (session == null ||
        session.state == DownloadState.promoted ||
        session.state == DownloadState.disposed ||
        session.residentBodyBacked) {
      return;
    }
    _downloadRetryRounds.remove(physicalId);
    _downloadRetryPending.remove(physicalId);
    _downloadTerminalFailures.remove(physicalId);
    _downloadDeferredAtLength.remove(physicalId);
    final claim = _preferredClaim(physicalId);
    final taskKey = _networkTaskKeys[physicalId];
    _record(
      claim,
      sessionId: sessionId,
      kind: TraceEventKind.artifactSource,
      id: physicalId,
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
      _ensureDownloadTask(physicalId, session);
      return;
    }
    if (net.cancelQueued(taskKey)) {
      if (_networkTaskKeys[physicalId] == taskKey) {
        _networkTaskKeys.remove(id);
      }
      _ensureDownloadTask(physicalId, session);
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

  void _replaceDemands(
    DownloadTransferConsumer consumer,
    String sessionId,
    int revision,
    Map<DownloadId, TransferDemand> desired,
  ) {
    if (_disposed || consumer._disposed) return;
    final normalized = _normalizeDemands(desired);
    _validateDemandChecksums(consumer, normalized);
    consumer._sessionId = sessionId;
    consumer._revision = revision;
    final removed = consumer._physicalDemands.keys
        .where((id) => !normalized.containsKey(id))
        .toList(growable: false);
    for (final id in removed) {
      consumer._physicalDemands.remove(id);
      _removeClaim(consumer, id, sessionId: sessionId);
    }
    final toSchedule = <DownloadId>[];
    for (final entry in normalized.entries) {
      final prior = consumer._physicalDemands[entry.key];
      if (prior == entry.value) continue;
      _upsertClaim(
        consumer,
        entry.key,
        entry.value.exactId,
        entry.value.demand,
        sessionId: sessionId,
        revision: revision,
      );
      consumer._physicalDemands[entry.key] = entry.value;
      toSchedule.add(entry.key);
    }
    consumer._demands
      ..clear()
      ..addAll(desired);
    for (final physicalId in toSchedule) {
      _ensureDownloadTask(physicalId, registry.get(physicalId));
    }
  }

  Map<DownloadId, _ConsumerPhysicalDemand> _normalizeDemands(
    Map<DownloadId, TransferDemand> desired,
  ) {
    final normalized = <DownloadId, _ConsumerPhysicalDemand>{};
    for (final entry in desired.entries) {
      final physicalId = resolveTransferId(entry.key);
      final candidate = _ConsumerPhysicalDemand(
        exactId: entry.key,
        demand: entry.value,
      );
      final existing = normalized[physicalId];
      if (existing == null) {
        normalized[physicalId] = candidate;
        continue;
      }
      final leftChecksum = existing.demand.expectedChecksum;
      final rightChecksum = candidate.demand.expectedChecksum;
      if (leftChecksum != null &&
          rightChecksum != null &&
          leftChecksum != rightChecksum) {
        throw StateError(
          'conflicting checksums for physical transfer ${physicalId.key}: '
          '$leftChecksum != $rightChecksum',
        );
      }
      final selected = candidate.demand.priority > existing.demand.priority
          ? candidate
          : existing;
      final required = existing.demand.completionIntent ==
              TransferCompletionIntent.required ||
          candidate.demand.completionIntent == TransferCompletionIntent.required;
      normalized[physicalId] = _ConsumerPhysicalDemand(
        exactId: selected.exactId,
        demand: TransferDemand(
          priority: selected.demand.priority,
          reason: selected.demand.reason,
          expectedChecksum: leftChecksum ?? rightChecksum,
          completionIntent: required
              ? TransferCompletionIntent.required
              : TransferCompletionIntent.opportunistic,
        ),
      );
    }
    return normalized;
  }

  void _validateDemandChecksums(
    DownloadTransferConsumer consumer,
    Map<DownloadId, _ConsumerPhysicalDemand> desired,
  ) {
    for (final entry in desired.entries) {
      final checksum = entry.value.demand.expectedChecksum;
      if (checksum == null) continue;
      final byScope = _claims[entry.key];
      if (byScope == null) continue;
      for (final claim in byScope.values) {
        if (identical(claim.consumer, consumer)) continue;
        final other = claim.demand.expectedChecksum;
        if (other != null && other != checksum) {
          throw StateError(
            'conflicting checksums for physical transfer ${entry.key.key}: '
            '$other != $checksum',
          );
        }
      }
    }
  }

  void _upsertClaim(
    DownloadTransferConsumer consumer,
    DownloadId id,
    DownloadId exactId,
    TransferDemand demand, {
    required String sessionId,
    required int revision,
  }) {
    final session = registry.get(id);
    _watchSession(session);
    final byScope = _claims.putIfAbsent(id, () => <String, _TransferClaim>{});
    final checksum = demand.expectedChecksum;
    if (checksum != null) {
      for (final claim in byScope.values) {
        if (identical(claim.consumer, consumer)) continue;
        final other = claim.demand.expectedChecksum;
        if (other != null && other != checksum) {
          throw StateError(
            'conflicting checksums for physical transfer ${id.key}: '
            '$other != $checksum',
          );
        }
      }
    }
    final existing = byScope[consumer.scopeId];
    if (existing == null) {
      final lease = session.attachDemand(
        scopeId: consumer.scopeId,
        priority: demand.priority,
      );
      byScope[consumer.scopeId] = _TransferClaim(
        consumer: consumer,
        exactId: exactId,
        lease: lease,
        demand: demand,
        sessionId: sessionId,
        revision: revision,
        sequence: ++_claimSequence,
      );
    } else {
      existing.exactId = exactId;
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
            id: id,
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
    final releasedIds = consumer._physicalDemands.keys.toList(growable: false);
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
    final ids = consumer._physicalDemands.keys.toList(growable: false);
    consumer._demands.clear();
    consumer._physicalDemands.clear();
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
    for (final id in consumer._physicalDemands.keys) {
      final session = registry.find(id);
      if (session != null) {
        _ensureDownloadTask(id, session);
      }
    }
  }

  Future<void> _idleFor(DownloadTransferConsumer consumer) async {
    while (!_disposed && !consumer._disposed) {
      final ids = consumer._physicalDemands.keys.toList(growable: false);
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
        final deferredForCurrentClaims =
            _downloadDeferredAtLength[id] == session.committedLength &&
                !_allowsCostlyFullBodyCatchup(
                  id: id,
                  priority: session.effectivePriority,
                  preservedLength: session.committedLength,
                );
        if (_networkTaskKeys.containsKey(id) ||
            _downloadRetryPending.contains(id) ||
            (session.demanded &&
                !deferredForCurrentClaims &&
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
              id: id,
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
      bucket: claim.consumer.downloadBucketFor(claim.exactId),
      bucketLimit: claim.consumer.downloadBucketLimitFor(claim.exactId),
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
      final sourceId = claim.exactId;
      final bucket = provider.downloadBucketFor(sourceId);
      final bucketLimit = provider.downloadBucketLimitFor(sourceId);
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
          'providerExactId': sourceId.key,
        },
      );
      for (var attempt = 1; ; attempt++) {
        token.throwIfCancelled();
        final attemptStartedAtMicros = clock.nowMicros();
        try {
          await DownloadJob(
            transport: provider.transportFor(sourceId.canonicalUri),
            session: session,
            attachLegacyDemand: false,
            allowFullBodyCatchup: (preservedLength) =>
                _allowsCostlyFullBodyCatchup(
              id: id,
              priority: token.priority,
              preservedLength: preservedLength,
            ),
          ).run(
            expectedChecksum: _expectedChecksum(id),
            cancel: token,
          );
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
                id: id,
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
        session.residentBodyBacked ||
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

  String? _expectedChecksum(DownloadId id) {
    String? checksum;
    for (final claim in _claims[id]?.values ?? const <_TransferClaim>[]) {
      final candidate = claim.demand.expectedChecksum;
      if (candidate == null) continue;
      if (checksum != null && checksum != candidate) {
        throw StateError('conflicting checksums for physical transfer ${id.key}');
      }
      checksum = candidate;
    }
    return checksum;
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

  bool _requiresCompletion(DownloadId id) =>
      (_claims[id]?.values ?? const <_TransferClaim>[]).any(
        (claim) =>
            claim.demand.completionIntent == TransferCompletionIntent.required,
      );

  bool _allowsCostlyFullBodyCatchup({
    required DownloadId id,
    required int priority,
    required int preservedLength,
  }) {
    if (_requiresCompletion(id)) return true;
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
  final Map<DownloadId, TransferDemand> _demands =
      <DownloadId, TransferDemand>{};
  final Map<DownloadId, _ConsumerPhysicalDemand> _physicalDemands =
      <DownloadId, _ConsumerPhysicalDemand>{};
  String? _sessionId;
  int _revision = 0;
  bool _disposed = false;

  DownloadRegistry get registry => owner.registry;
  NetLane get net => owner.net;
  bool get disposed => _disposed;
  Map<DownloadId, TransferDemand> get demands =>
      Map<DownloadId, TransferDemand>.unmodifiable(_demands);

  void replaceDemands(
    String sessionId,
    int revision,
    Map<DownloadId, TransferDemand> desired,
  ) =>
      owner._replaceDemands(this, sessionId, revision, desired);

  void refreshScheduling() => owner._refreshScheduling(this);

  void refreshForLocalArtifact(DownloadId id) =>
      owner.refreshForLocalArtifact(id, sessionId: _sessionId);

  Future<void> idle() => owner._idleFor(this);

  Future<void> dispose() => owner._disposeConsumer(this);
}

final class _ConsumerPhysicalDemand {
  const _ConsumerPhysicalDemand({
    required this.exactId,
    required this.demand,
  });

  final DownloadId exactId;
  final TransferDemand demand;

  @override
  bool operator ==(Object other) =>
      other is _ConsumerPhysicalDemand &&
      exactId == other.exactId &&
      demand == other.demand;

  @override
  int get hashCode => Object.hash(exactId, demand);
}

final class _TransferClaim {
  _TransferClaim({
    required this.consumer,
    required this.exactId,
    required this.lease,
    required this.demand,
    required this.sessionId,
    required this.revision,
    required this.sequence,
  });

  final DownloadTransferConsumer consumer;
  DownloadId exactId;
  final DownloadDemandLease lease;
  TransferDemand demand;
  String sessionId;
  int revision;
  final int sequence;
}
