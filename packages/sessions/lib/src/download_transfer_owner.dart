import 'dart:async';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'decode_session.dart';
import 'download_job.dart';
import 'download_registry.dart';
import 'download_session.dart';
import 'net_lane.dart';
import 'retry_policy.dart';
import 'transfer_rank_policy.dart';
import 'webp_decode_prefix_hints.dart';

typedef TransferTransportPick = Transport Function(Uri uri);
typedef TransferRetainedTransportPick = Transport? Function(Uri uri);
typedef TransferIdentityResolver = DownloadId Function(DownloadId exactId);

DownloadId _identityTransferId(DownloadId id) => id;

String? _normalizeExpectedChecksum(String? checksum) =>
    checksum?.trim().toLowerCase();

enum TransferCompletionIntent {
  opportunistic,
  required,
}

final class TransferDemand {
  const TransferDemand({
    required this.priority,
    required this.reason,
    this.flowTargetFrames = 0,
    this.expectedChecksum,
    this.completionIntent = TransferCompletionIntent.opportunistic,
  })  : assert(priority >= 0),
        assert(flowTargetFrames >= 0);

  final int priority;
  final String reason;
  final int flowTargetFrames;
  final String? expectedChecksum;
  final TransferCompletionIntent completionIntent;

  @override
  bool operator ==(Object other) =>
      other is TransferDemand &&
      priority == other.priority &&
      reason == other.reason &&
      flowTargetFrames == other.flowTargetFrames &&
      expectedChecksum == other.expectedChecksum &&
      completionIntent == other.completionIntent;

  @override
  int get hashCode => Object.hash(
        priority,
        reason,
        flowTargetFrames,
        expectedChecksum,
        completionIntent,
      );
}

typedef TransferPrepare = Future<void> Function(DownloadSession session);
typedef TransferPrepareWithControl = Future<void> Function(
  DownloadSession session, {
  required TaskControl control,
});
typedef TransferSleep = Future<void> Function(Duration delay);

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
    this.prepareDownloadWithControl,
    required this.net,
    this.resolveTransferId = _identityTransferId,
    this.rankPolicy = const TransferRankPolicy(),
    this.readStallTimeout = DownloadJob.defaultReadStallTimeout,
  });

  final DownloadRegistry registry;
  final MonoClock clock;
  final TransferPrepare? prepareDownload;
  final TransferPrepareWithControl? prepareDownloadWithControl;
  final NetLane net;
  final Completer<void> _disposedCompleter = Completer<void>();
  final TransferIdentityResolver resolveTransferId;
  final TransferRankPolicy rankPolicy;

  final Duration readStallTimeout;

  final Map<DownloadId, Map<String, _TransferClaim>> _claims =
      <DownloadId, Map<String, _TransferClaim>>{};
  final Map<DownloadId, String> _networkTaskKeys = <DownloadId, String>{};
  // Local physical-session hydration is intentionally outside NetLane. Cold
  // partial/artifact restore is local I/O and may publish Reader-local ingress
  // before a source/network transport lease is available. One physical session
  // generation performs this initialization at most once.
  final Map<DownloadId, Future<void>> _localPreparations =
      <DownloadId, Future<void>>{};
  final Map<DownloadId, _LocalPreparationControl>
      _localPreparationControls = <DownloadId, _LocalPreparationControl>{};
  final Map<DownloadId, SourceEpoch> _locallyPreparedSessions =
      <DownloadId, SourceEpoch>{};
  // Local preparation may finish out of demand-priority order. Network/source
  // admission must not inherit that completion order: a lower-priority item
  // that finished its local phase waits while a higher-priority demanded
  // physical session is still in the same pre-admission phase. NetLane remains
  // the only network-capacity scheduler; this map only preserves rank across
  // the asynchronous local->network ownership seam.
  final Map<DownloadId, DownloadSession> _preparedNetworkAdmissions =
      <DownloadId, DownloadSession>{};
  final Set<DownloadId> _preparedAdmissionDeferrals = <DownloadId>{};
  final Map<DownloadId, int> _downloadRetryRounds = <DownloadId, int>{};
  final Set<DownloadId> _downloadRetryPending = <DownloadId>{};
  final Map<DownloadId, Completer<void>> _downloadRetryWaiters =
      <DownloadId, Completer<void>>{};
  final Set<DownloadId> _downloadTerminalFailures = <DownloadId>{};
  final Map<DownloadId, String> _ensureSkipReasons = <DownloadId, String>{};
  final Map<DownloadId, int> _downloadDeferredAtLength = <DownloadId, int>{};
  // The physical session owns bytes/writer state, while the source provider is
  // only a lease for one currently executing NetLane task. A later preferred
  // exact claim may revoke this lease without replacing the physical session.
  final Map<DownloadId, _ActiveProviderLease> _activeProviderLeases =
      <DownloadId, _ActiveProviderLease>{};
  final Map<DownloadId, int> _progressLengths = <DownloadId, int>{};
  final Map<DownloadId, DownloadSnapshotListener> _sessionListeners =
      <DownloadId, DownloadSnapshotListener>{};
  final Map<DownloadId, DownloadSession> _sessionListenerSessions =
      <DownloadId, DownloadSession>{};
  final Set<DownloadTransferConsumer> _consumers =
      <DownloadTransferConsumer>{};
  // Retirement barriers belong to one admitted lane task, not to the logical
  // DownloadId. A new task for the same physical session may be admitted in
  // the gap between the old lane entry retiring and its waiter continuation;
  // keying this set by DownloadId can then suppress the new task's barrier.
  final Set<String> _taskRetirementWaits = <String>{};
  int _taskSequence = 0;
  int _claimSequence = 0;
  bool _disposed = false;

  static const int _maxDownloadRetryRounds = 4;

  Iterable<DownloadTransferConsumer> get consumers =>
      List<DownloadTransferConsumer>.unmodifiable(_consumers);

  int claimCount(DownloadId id) =>
      _claims[registry.resolvePhysicalId(id)]?.length ?? 0;

  Iterable<DownloadId> requiredExactDurableTargets(DownloadId id) {
    final physicalId = registry.resolvePhysicalId(id);
    final targets = <DownloadId>{};
    for (final claim in _claims[physicalId]?.values ?? const <_TransferClaim>[]) {
      if (claim.demand.completionIntent == TransferCompletionIntent.required) {
        targets.add(claim.exactId);
      }
    }
    return List<DownloadId>.unmodifiable(targets);
  }

  String? activeProviderScope(DownloadId id) =>
      _activeProviderLeases[registry.resolvePhysicalId(id)]?.scopeId;

  DownloadId? activeProviderExactId(DownloadId id) =>
      _activeProviderLeases[registry.resolvePhysicalId(id)]?.exactId;

  String? taskKeyFor(DownloadId id) =>
      _networkTaskKeys[registry.resolvePhysicalId(id)];

  /// Retires one idle physical session after the composition owner has moved
  /// any bytes that must survive beyond the hot registry.
  ///
  /// This method owns only scheduler/session bookkeeping. It intentionally
  /// does not know whether the caller persisted a partial, reused a durable
  /// artifact, or discarded an empty session.
  Future<bool> retireIdlePhysical(DownloadId id) async {
    if (_disposed) return false;
    final physicalId = registry.resolvePhysicalId(id);
    final session = registry.findExact(physicalId);
    if (session == null ||
        !session.canEvict ||
        (_claims[physicalId]?.isNotEmpty ?? false) ||
        session.demanded ||
        session.activeRun ||
        session.hasWriter ||
        _localPreparations.containsKey(physicalId)) {
      return false;
    }
    // A final snapshot can arrive before the session's serialized index write
    // has completed. Settle that tail before removing the registry entry, then
    // re-check all ownership conditions because a new claim may have arrived
    // while the await was in flight.
    await session.settleCacheMutations();
    if (_disposed ||
        !identical(registry.findExact(physicalId), session) ||
        !session.canEvict ||
        (_claims[physicalId]?.isNotEmpty ?? false) ||
        session.demanded ||
        session.activeRun ||
        session.hasWriter ||
        _localPreparations.containsKey(physicalId)) {
      return false;
    }
    final taskKey = _networkTaskKeys[physicalId];
    if (taskKey != null) {
      if (net.isActive(taskKey)) return false;
      net.cancelQueued(taskKey);
      _networkTaskKeys.remove(physicalId);
    }
    if (_activeProviderLeases.containsKey(physicalId)) return false;

    final retired = registry.takeIdlePhysical(physicalId);
    if (!identical(retired, session)) return false;

    final listener = _sessionListeners.remove(physicalId);
    final watchedSession = _sessionListenerSessions.remove(physicalId);
    if (listener != null) {
      (watchedSession ?? session).removeSnapshotListener(listener);
    }
    _progressLengths.remove(physicalId);
    _localPreparations.remove(physicalId);
    _locallyPreparedSessions.remove(physicalId);
    _preparedNetworkAdmissions.remove(physicalId);
    _preparedAdmissionDeferrals.remove(physicalId);
    _cancelDownloadRetry(physicalId);
    _retireDownloadTracking(physicalId, session);
    await session.dispose();
    return true;
  }

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
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
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
    final resumeValidators = session.resumeValidatorsFor(sourceId.canonicalUri);
    final transport = claim.consumer.transportFor(sourceId.canonicalUri);
    final pendingResponse = transport is ControlledTransport
        ? transport.openControlled(
            sourceId.canonicalUri,
            range: ByteRange(start: 0, end: endExclusive - 1),
            validators: resumeValidators.canResume ? resumeValidators : null,
            control: control,
          )
        : transport.open(
            sourceId.canonicalUri,
            range: ByteRange(start: 0, end: endExclusive - 1),
            validators: resumeValidators.canResume ? resumeValidators : null,
          );
    final response = await _awaitResidentResponse(
      pendingResponse,
      control,
    );
    if (control?.cancelled == true) {
      await response.discard(control: control);
      control!.throwIfCancelled();
    }
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
      if (resumeValidators.canResume &&
          !resumeValidators.matches(response.validators)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'resident replay source validators changed',
        );
      }
    } on Object {
      await response.discard(control: control);
      rethrow;
    }
    final body = _ResidentReplayBody(response, control: control);
    if (control != null) {
      unawaited(
        control.whenCancelled.then<void>((_) async {
          try {
            await body.discard();
          } on Object {
            // The replay owner will surface the cancellation; cleanup must not
            // replace it with a late response-discard failure.
          }
        }),
      );
    }
    return _boundedResidentReplay(
      body,
      endExclusive,
      id,
      control: control,
    );
  }

  Future<ByteResponse> _awaitResidentResponse(
    Future<ByteResponse> pending,
    TaskControl? control,
  ) async {
    if (control == null) return pending;
    control.throwIfCancelled();
    try {
      return await Future.any<ByteResponse>(<Future<ByteResponse>>[
        pending,
        control.whenCancelled.then<ByteResponse>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'resident replay was cancelled while opening',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) {
        unawaited(
          pending.then<void>(
            (response) => response.discard(control: control),
            onError: (Object _, StackTrace __) {},
          ),
        );
        control.throwIfCancelled();
      }
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Stream<List<int>> _boundedResidentReplay(
    _ResidentReplayBody body,
    int endExclusive,
    DownloadId id, {
    TaskControl? control,
  }) async* {
    var emitted = 0;
    final iterator = StreamIterator<List<int>>(body.response.bytes);
    try {
      while (emitted < endExclusive &&
          await _moveNextResidentChunk(iterator, control)) {
        control?.throwIfCancelled();
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
      // Both operations are cleanup for the bounded replay. Keep them
      // best-effort and independent so a subscription close failure cannot
      // mask cancellation, a short-body corruption error, or a source read
      // failure; the response still receives its discard attempt.
      try {
        await iterator.cancel();
      } on Object {
        // Preserve the replay result.
      }
      try {
        await body.discard();
      } on Object {
        // Preserve the replay result.
      }
    }
  }

  Future<bool> _moveNextResidentChunk(
    StreamIterator<List<int>> iterator,
    TaskControl? control,
  ) async {
    if (control == null) return iterator.moveNext();
    control.throwIfCancelled();
    try {
      return await Future.any<bool>(<Future<bool>>[
        iterator.moveNext(),
        control.whenCancelled.then<bool>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'resident replay was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  DownloadTransferConsumer attachConsumer({
    required String scopeId,
    required TransferTransportPick transportFor,
    TransferRetainedTransportPick? retainedTransportFor,
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
      retainedTransportFor: retainedTransportFor,
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_disposedCompleter.isCompleted) {
      _disposedCompleter.complete();
    }
    final keys = _networkTaskKeys.values.toList(growable: false);
    final preparations = _localPreparations.values.toList(growable: false);
    for (final control in _localPreparationControls.values) {
      control.cancel();
    }
    for (final consumer in _consumers.toList(growable: false)) {
      _detachClaims(consumer, consumerDisposing: true);
      consumer._disposed = true;
      if (!consumer._disposedCompleter.isCompleted) {
        consumer._disposedCompleter.complete();
      }
    }
    _consumers.clear();
    for (final key in keys) {
      net.cancel(key);
    }
    await Future.wait<void>(<Future<void>>[
      net.idleKeys(keys),
      ...preparations,
    ]);
    _networkTaskKeys.clear();
    _localPreparations.clear();
    _localPreparationControls.clear();
    _locallyPreparedSessions.clear();
    _preparedNetworkAdmissions.clear();
    _preparedAdmissionDeferrals.clear();
    for (final waiter in _downloadRetryWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _downloadRetryWaiters.clear();
    _downloadRetryRounds.clear();
    _downloadRetryPending.clear();
    _downloadTerminalFailures.clear();
    _downloadDeferredAtLength.clear();
    _activeProviderLeases.clear();
    _taskRetirementWaits.clear();
    for (final entry in _sessionListeners.entries) {
      _sessionListenerSessions[entry.key]
          ?.removeSnapshotListener(entry.value);
    }
    _sessionListeners.clear();
    _sessionListenerSessions.clear();
    _progressLengths.clear();
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
      final schedulingOnly = prior != null &&
          _tryUpdateExistingClaimScheduling(
            consumer,
            entry.key,
            prior,
            entry.value,
            sessionId: sessionId,
            revision: revision,
          );
      if (!schedulingOnly) {
        _upsertClaim(
          consumer,
          entry.key,
          entry.value.exactId,
          entry.value.demand,
          sessionId: sessionId,
          revision: revision,
        );
        toSchedule.add(entry.key);
      }
      consumer._physicalDemands[entry.key] = entry.value;
    }
    consumer._demands
      ..clear()
      ..addAll(desired);
    for (final physicalId in toSchedule) {
      _ensureDownloadTask(physicalId, registry.get(physicalId));
    }
    _drainPreparedNetworkAdmissions();
  }

  Map<DownloadId, _ConsumerPhysicalDemand> _normalizeDemands(
    Map<DownloadId, TransferDemand> desired,
  ) {
    final normalized = <DownloadId, _ConsumerPhysicalDemand>{};
    for (final entry in desired.entries) {
      final physicalId = resolveTransferId(entry.key);
      final rawDemand = entry.value;
      final candidate = _ConsumerPhysicalDemand(
        exactId: entry.key,
        demand: TransferDemand(
          priority: rawDemand.priority,
          reason: rawDemand.reason,
          flowTargetFrames: rawDemand.flowTargetFrames,
          expectedChecksum:
              _normalizeExpectedChecksum(rawDemand.expectedChecksum),
          completionIntent: rawDemand.completionIntent,
        ),
      );
      final existing = normalized[physicalId];
      if (existing == null) {
        normalized[physicalId] = candidate;
        continue;
      }
      final leftChecksum =
          _normalizeExpectedChecksum(existing.demand.expectedChecksum);
      final rightChecksum =
          _normalizeExpectedChecksum(candidate.demand.expectedChecksum);
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
          flowTargetFrames: selected.demand.flowTargetFrames,
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
      final checksum =
          _normalizeExpectedChecksum(entry.value.demand.expectedChecksum);
      if (checksum == null) continue;
      final byScope = _claims[entry.key];
      if (byScope == null) continue;
      for (final claim in byScope.values) {
        if (identical(claim.consumer, consumer)) continue;
        final other =
            _normalizeExpectedChecksum(claim.demand.expectedChecksum);
        if (other != null && other != checksum) {
          throw StateError(
            'conflicting checksums for physical transfer ${entry.key.key}: '
            '$other != $checksum',
          );
        }
      }
    }
  }

  bool _tryUpdateExistingClaimScheduling(
    DownloadTransferConsumer consumer,
    DownloadId id,
    _ConsumerPhysicalDemand prior,
    _ConsumerPhysicalDemand next, {
    required String sessionId,
    required int revision,
  }) {
    // This fast path is deliberately narrower than demand equality. A change
    // in exact identity, integrity proof or completion intent can alter
    // provider/body authority and must re-enter the full claim establishment
    // path. Pure reason/priority/frame-target migration keeps the same physical
    // claim and only updates scheduling state.
    if (prior.exactId != next.exactId ||
        _normalizeExpectedChecksum(prior.demand.expectedChecksum) !=
            _normalizeExpectedChecksum(next.demand.expectedChecksum) ||
        prior.demand.completionIntent != next.demand.completionIntent) {
      return false;
    }
    final claim = _claims[id]?[consumer.scopeId];
    final session = registry.find(id);
    if (claim == null || session == null) {
      return false;
    }
    claim
      ..demand = next.demand
      ..sessionId = sessionId
      ..revision = revision;
    claim.lease.updatePriority(next.demand.priority);
    _refreshClaimScheduling(id, session, next.demand);

    // Existing claims may currently be locally preparing, flow-paused or fully
    // idle. The historical path re-ran ensure after every changed demand; keep
    // that wake edge without rebuilding claim/session/watch ownership.
    if (_networkTaskKeys[id] == null) {
      _ensureDownloadTask(id, session);
    }
    return true;
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
    final checksum = _normalizeExpectedChecksum(demand.expectedChecksum);
    if (checksum != null) {
      for (final claim in byScope.values) {
        if (identical(claim.consumer, consumer)) continue;
        final other =
            _normalizeExpectedChecksum(claim.demand.expectedChecksum);
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
    _refreshClaimScheduling(id, session, demand);
  }

  void _refreshClaimScheduling(
    DownloadId id,
    DownloadSession session,
    TransferDemand demand,
  ) {
    _localPreparationControls[id]?.updatePriority(session.effectivePriority);
    // A flow frame proof describes bytes already present in the physical
    // partial, not the policy target that happened to trigger suspension.
    // Demand/role changes therefore never invalidate it. A later positive
    // frame target at or below the proven frame floor is already satisfied;
    // target=0 remains foreground-unlimited and continues scheduling.
    if (!session.activeRun) {
      // A scheduling-only claim update can race the recovery sleeper. Cancel
      // the waiter itself, not just its bookkeeping; otherwise the old timer
      // can wake after a fresh attempt has already completed and reopen a
      // retired physical session.
      _cancelDownloadRetry(id);
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
      net.updateDemanded(taskKey, true);
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
    // A stale detach must not change scheduling for another consumer that may
    // have already replaced this claim. This can occur when a teardown and a
    // demand reconciliation cross an asynchronous task-retirement boundary.
    if (claim == null) return;
    // A recovery sleeper captures the consumer that supplied its retry policy.
    // If that claim is replaced or detached, wake the sleeper so it cannot
    // keep the physical session waiting on a disposed consumer's backoff hook.
    // Task retirement will admit the replacement attempt from the remaining
    // current claims.
    _cancelDownloadRetry(id);
    claim.lease.detach();
    if (byScope != null && byScope.isEmpty) {
      _claims.remove(id);
    }
    final session = registry.find(id);
    final taskKey = _networkTaskKeys[id];
    final taskIsActive = taskKey != null && net.isActive(taskKey);
    if (session != null && session.demanded && taskKey != null) {
      net.updateDemanded(taskKey, true);
      _migrateDownloadPriority(
        id,
        taskKey,
        session.effectivePriority,
        reason: 'remaining-consumer',
      );
    } else if (taskKey != null && taskIsActive) {
      // Working-set membership and physical transport lifetime are separate.
      // Losing the final Reader/other consumer claim never cancels an already
      // admitted task. It becomes rank-zero inactive physical work. DownloadJob
      // parks the same live response at its next safe body-read boundary and
      // releases only the bounded NetLane read permit. Keep this path even if
      // the registry entry disappeared during a concurrent retirement race;
      // dropping the owner key while the lane task is still active would
      // orphan its provider/transport cleanup.
      net.updateDemanded(taskKey, false);
      _migrateDownloadPriority(
        id,
        taskKey,
        0,
        reason: 'inactive-physical-retention',
      );
    } else {
      if (taskKey != null) {
        net.cancelQueued(taskKey);
      }
      _networkTaskKeys.remove(id);
      _retireDownloadTracking(id, session);
    }
    if (session == null || !session.demanded) {
      _preparedNetworkAdmissions.remove(id);
      _preparedAdmissionDeferrals.remove(id);
      _localPreparationControls[id]?.cancel();
      _cancelDownloadRetry(id);
    }
    _drainPreparedNetworkAdmissions();
  }

  Future<void> _disposeConsumer(DownloadTransferConsumer consumer) async {
    if (consumer._disposed) return;
    consumer._disposed = true;
    if (!consumer._disposedCompleter.isCompleted) {
      consumer._disposedCompleter.complete();
    }
    final providerKeys = <String>[];
    for (final entry in _activeProviderLeases.entries.toList(growable: false)) {
      if (entry.value.scopeId != consumer.scopeId ||
          entry.value.transportRetainedBeyondConsumer) {
        continue;
      }
      final key = _networkTaskKeys[entry.key];
      if (key != null) {
        providerKeys.add(key);
      }
    }
    // Consumer disposal revokes only active attempts whose transport is still
    // consumer-bound. A task-retained transport has its own lifetime lease and
    // deliberately stays outside this Reader close barrier.
    _detachClaims(consumer, consumerDisposing: true);
    _consumers.remove(consumer);
    // A consumer-bound transport may be closed immediately after this Future.
    // Wait until every active task that captured that transport has physically
    // exited. Task-retained transports are intentionally absent from providerKeys.
    if (providerKeys.isNotEmpty) {
      await net.idleKeys(providerKeys);
      await Future<void>.delayed(Duration.zero);
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
    // Claim detach alone deliberately retains an admitted provider attempt.
    // Consumer disposal cancels only leases that still depend on that consumer's
    // transport owner. Explicit task-retained transports survive this boundary;
    // the physical prefix and writer remain composition-owned in either case.
    for (final entry in _activeProviderLeases.entries.toList(growable: false)) {
      if (entry.value.scopeId != consumer.scopeId ||
          entry.value.transportRetainedBeyondConsumer) {
        continue;
      }
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
    _drainPreparedNetworkAdmissions();
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
      final waits = <Future<void>>[];
      if (keys.isNotEmpty) {
        waits.add(net.idleKeys(keys));
      }
      for (final id in ids) {
        final preparation = _localPreparations[id];
        if (preparation != null) waits.add(preparation);
      }
      if (waits.isNotEmpty) {
        // A flow-satisfied job may intentionally retain its live response after
        // releasing the body-read permit. Its lane key remains non-idle until
        // the physical response is retired, so key-idle alone cannot wake this
        // consumer when decoder evidence has already satisfied its target.
        // Poll the owner-side proof while still retaining the physical idle
        // barrier for ordinary completion and disposal.
        await Future.any<void>(<Future<void>>[
          Future.wait<void>(waits),
          Future<void>.delayed(const Duration(milliseconds: 20)),
          consumer.whenDisposed,
          _disposedCompleter.future,
        ]);
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      if (_disposed || consumer._disposed) return;
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
        final preferred = _preferredClaim(id);
        final flowSatisfiedForCurrentClaims = preferred != null &&
            _flowProofSatisfies(
              preferred.demand.flowTargetFrames,
              session,
            );
        final taskRetiring = _networkTaskKeys.containsKey(id) &&
            !flowSatisfiedForCurrentClaims &&
            session.state != DownloadState.disposed;
        if (_downloadRetryPending.contains(id) ||
            (!deferredForCurrentClaims &&
                !flowSatisfiedForCurrentClaims &&
                (taskRetiring ||
                    (session.state != DownloadState.promoted &&
                        session.state != DownloadState.failed &&
                        session.state != DownloadState.disposed &&
                        !_downloadTerminalFailures.contains(id) &&
                        session.demanded)))) {
          pending = true;
          break;
        }
      }
      if (!pending) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  bool _flowProofSatisfies(
    int targetFrames,
    DownloadSession session,
  ) {
    if (targetFrames <= 0 || session.networkFlowSatisfiedFrames <= 0) {
      return false;
    }
    final playableFloor = session.playableFlowPrefixFloorBytes(
      unresolvedFloorBytes: webpDecodePrefixQuantumBytesFor(session.id),
    );
    return session.committedLength >= session.networkFlowProofLength &&
        session.committedLength >= playableFloor &&
        session.networkFlowSatisfiedFrames >= targetFrames;
  }

  void _observeDecodePrefixEvidence(
    DownloadSession session,
    DecodeSnapshot snapshot,
  ) {
    if (_disposed || session.state == DownloadState.disposed) return;
    if (!identical(registry.findExact(session.id), session)) return;
    final changed = session.observePlayablePrefixEvidence(
      decodedPrefixFrames: snapshot.decodedPrefixFrames,
      sourceLength: snapshot.sourceLength,
      firstPlayablePrefixBytes: snapshot.firstPlayablePrefixBytes,
      firstFrameRequiredSourceLength:
          snapshot.firstFrameRequiredSourceLength,
    );
    if (!changed || !session.demanded) return;
    final claim = _preferredClaim(session.id);
    if (claim == null) return;
    if (!_flowProofSatisfies(
      claim.demand.flowTargetFrames,
      session,
    )) {
      _ensureDownloadTask(session.id, session);
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
        if (net.isCancelled(existingTaskKey)) {
          _waitForTaskRetirement(id, session, existingTaskKey);
          return;
        }
        net.updateDemanded(existingTaskKey, true);
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
    if (_flowProofSatisfies(
      claim.demand.flowTargetFrames,
      session,
    )) {
      _preparedNetworkAdmissions.remove(id);
      _preparedAdmissionDeferrals.remove(id);
      return;
    }
    if (identical(_preparedNetworkAdmissions[id], session)) {
      _drainPreparedNetworkAdmissions();
      return;
    }
    if (_localPreparations.containsKey(id)) {
      // Transition-gated so a healthy (millisecond) preparation stays silent;
      // a preparation that persists across scheduling refreshes is visible.
      const reason = 'local-preparing';
      if (_ensureSkipReasons[id] != reason) {
        _ensureSkipReasons[id] = reason;
        _record(
          claim,
          kind: TraceEventKind.policyDecision,
          id: id,
          payload: <String, Object?>{
            'stage': 'download-task-skip',
            'reasons': reason,
            'state': session.state.name,
            'committedLength': session.committedLength,
          },
        );
      }
      return;
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
      // Only a CHANGED skip reason set is recorded, else active transfers
      // spam the trace.
      final reasons = <String>[
        if (_disposed) 'disposed',
        if (session.state == DownloadState.promoted) 'promoted',
        if (session.state == DownloadState.disposed) 'session-disposed',
        if (session.activeRun) 'active-run',
        if (session.hasWriter) 'has-writer',
        if (_downloadRetryPending.contains(id)) 'retry-pending',
        if (_downloadTerminalFailures.contains(id)) 'terminal-failure',
        if (_downloadDeferredAtLength[id] == session.committedLength &&
            !_allowsCostlyFullBodyCatchup(
              id: id,
              priority: effectivePriority,
              preservedLength: session.committedLength,
            ))
          'deferred-at-length',
        if ((_downloadRetryRounds[id] ?? 0) > _maxDownloadRetryRounds)
          'retry-rounds-exhausted',
      ].join('+');
      if (_ensureSkipReasons[id] != reasons) {
        _ensureSkipReasons[id] = reasons;
        _record(
          claim,
          kind: TraceEventKind.policyDecision,
          id: id,
          payload: <String, Object?>{
            'stage': 'download-task-skip',
            'reasons': reasons,
            'state': session.state.name,
            'committedLength': session.committedLength,
          },
        );
      }
      return;
    }
    _ensureSkipReasons.remove(id);
    final prepare = prepareDownload;
    final prepareWithControl = prepareDownloadWithControl;
    if ((prepare != null || prepareWithControl != null) &&
        session.committedLength == 0 &&
        _locallyPreparedSessions[id] != session.epoch) {
      _startLocalPreparation(
        id,
        session,
        prepare: prepare,
        prepareWithControl: prepareWithControl,
      );
      return;
    }
    final taskKey = 'transfer:${++_taskSequence}:${id.key}';
    _networkTaskKeys[id] = taskKey;
    net.submitRanked(
      key: taskKey,
      priority: effectivePriority,
      bucket: claim.consumer.downloadBucketFor(claim.exactId),
      bucketLimit: claim.consumer.downloadBucketLimitFor(claim.exactId),
      flowTargetFrames: claim.demand.flowTargetFrames,
      demanded: true,
      task: (token) => _runDownload(id, session, taskKey, token),
    );
  }

  void _startLocalPreparation(
    DownloadId id,
    DownloadSession session, {
    required TransferPrepare? prepare,
    required TransferPrepareWithControl? prepareWithControl,
  }) {
    if (_localPreparations.containsKey(id)) return;
    final initialClaim = _preferredClaim(id);
    final control = _LocalPreparationControl(
      priority: session.effectivePriority,
    );
    _localPreparationControls[id] = control;
    final startedAtMicros = clock.nowMicros();
    // Install the preparation slot before invoking the callback. Preparation
    // is an async boundary, but its first part runs synchronously; a custom
    // prepare hook can therefore re-enter refreshScheduling/reconcile before
    // this method reaches its final assignment. The placeholder makes that
    // re-entry observe the existing preparation instead of starting a second
    // local hydration for the same physical generation.
    final slot = Completer<void>();
    _localPreparations[id] = slot.future;
    late final Future<void> tracked;
    tracked = _runLocalPreparation(
      id,
      session,
      prepare: prepare,
      prepareWithControl: prepareWithControl,
      control: control,
      initialClaim: initialClaim,
      startedAtMicros: startedAtMicros,
    ).whenComplete(() {
      if (!slot.isCompleted) slot.complete();
      if (identical(_localPreparations[id], tracked)) {
        _localPreparations.remove(id);
      }
      if (identical(_localPreparationControls[id], control)) {
        _localPreparationControls.remove(id);
      }
      if (!_disposed &&
          identical(registry.findExact(id), session) &&
          session.demanded &&
          !control.cancelled) {
        _preparedNetworkAdmissions[id] = session;
      } else {
        _preparedNetworkAdmissions.remove(id);
        _preparedAdmissionDeferrals.remove(id);
      }
      _drainPreparedNetworkAdmissions();
    });
    _localPreparations[id] = tracked;
  }

  void _drainPreparedNetworkAdmissions() {
    if (_disposed || _preparedNetworkAdmissions.isEmpty) return;
    while (true) {
      final candidates = _preparedNetworkAdmissions.entries
          .where((entry) =>
              identical(registry.findExact(entry.key), entry.value) &&
              entry.value.demanded)
          .toList(growable: false)
        ..sort((left, right) {
          final priority = right.value.effectivePriority
              .compareTo(left.value.effectivePriority);
          if (priority != 0) return priority;
          final leftSequence = _preferredClaim(left.key)?.sequence ?? (1 << 62);
          final rightSequence =
              _preferredClaim(right.key)?.sequence ?? (1 << 62);
          return leftSequence.compareTo(rightSequence);
        });
      if (candidates.isEmpty) {
        _preparedNetworkAdmissions.removeWhere((id, session) =>
            !identical(registry.findExact(id), session) || !session.demanded);
        return;
      }
      final candidate = candidates.first;
      final priority = candidate.value.effectivePriority;
      DownloadId? blockerId;
      var blockerPriority = -1;
      for (final entry in _localPreparations.entries) {
        final blockingSession = registry.findExact(entry.key);
        if (blockingSession == null || !blockingSession.demanded) {
          continue;
        }
        final blockingPriority = blockingSession.effectivePriority;
        if (blockingPriority > priority && blockingPriority > blockerPriority) {
          blockerId = entry.key;
          blockerPriority = blockingPriority;
        }
      }
      if (blockerId != null) {
        if (_preparedAdmissionDeferrals.add(candidate.key)) {
          _record(
            _preferredClaim(candidate.key),
            kind: TraceEventKind.artifactSource,
            id: candidate.key,
            payload: <String, Object?>{
              'stage': 'post-local-network-admission',
              'action': 'deferred-by-higher-local-priority',
              'effectivePriority': priority,
              'blockingPriority': blockerPriority,
              'physicalOwner': true,
            },
          );
        }
        return;
      }
      _preparedNetworkAdmissions.remove(candidate.key);
      _preparedAdmissionDeferrals.remove(candidate.key);
      _ensureDownloadTask(candidate.key, candidate.value);
    }
  }

  Future<void> _runLocalPreparation(
    DownloadId id,
    DownloadSession session, {
    required TransferPrepare? prepare,
    required TransferPrepareWithControl? prepareWithControl,
    required _LocalPreparationControl control,
    required _TransferClaim? initialClaim,
    required int startedAtMicros,
  }) async {
    final preparationEpoch = session.epoch;
    Object? prepareError;
    try {
      control.throwIfCancelled();
      final controlled = prepareWithControl;
      if (controlled != null) {
        await controlled(session, control: control);
      } else {
        await prepare!(session);
      }
      control.throwIfCancelled();
      if (session.epoch != preparationEpoch) return;
    } on Object catch (error) {
      if (control.cancelled) {
        // Cancellation withdraws local preparation ownership. The physical
        // partial remains resumable; a demand that returns after this future
        // retires will start a fresh preparation/admission pass.
        return;
      }
      // Durable local state is an acceleration/fallback input, not network
      // admission authority. If local hydration fails, keep the authoritative
      // physical session and allow the normal provider path to recover it.
      prepareError = error;
    }

    if (control.cancelled ||
        session.epoch != preparationEpoch ||
        !identical(registry.findExact(id), session)) {
      return;
    }
    _locallyPreparedSessions[id] = preparationEpoch;
    final claim = _preferredClaim(id) ?? initialClaim;
    if (prepareError != null) {
      _record(
        claim,
        kind: TraceEventKind.artifactSource,
        id: id,
        payload: <String, Object?>{
          'stage': 'physical-local-prepare',
          'action': 'local-hydration-failed-network-fallback',
          'error': '$prepareError',
          'committedLength': session.committedLength,
          'demanded': session.demanded,
          'prepareMicros':
              (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
        },
      );
      return;
    }

    if (control.cancelled) return;
    var completedLocally = false;
    try {
      completedLocally = await DownloadJob.completeWithoutTransport(
        session: session,
        expectedChecksum: _expectedChecksum(id),
        control: control,
      );
      if (session.epoch != preparationEpoch) return;
    } on Object catch (error) {
      if (control.cancelled) return;
      if (session.epoch != preparationEpoch) return;
      Object? recoveryError;
      try {
        // A full local partial that fails seal/checksum cannot be offered to
        // completeWithoutTransport again: doing so only repeats the same
        // deterministic failure and never reaches the provider. Retire that
        // corrupt generation before the normal post-prepare network admission.
        await session.reset();
        // This reset intentionally discards the already-attempted local
        // generation so the next admission is the provider fallback, not a
        // second pass through the same corrupt durable partial.
        _locallyPreparedSessions[id] = session.epoch;
      } on Object catch (resetError) {
        recoveryError = resetError;
        _downloadTerminalFailures.add(id);
        try {
          await session.failWithoutWriter(resetError);
        } on Object {
          // Preserve the terminal marker even if durable cleanup also failed.
        }
      }
      _record(
        claim,
        kind: TraceEventKind.artifactSource,
        id: id,
        payload: <String, Object?>{
          'stage': 'physical-local-prepare',
          'action': recoveryError == null
              ? 'local-completion-failed-network-fallback'
              : 'local-completion-recovery-failed-terminal',
          'error': '$error',
          if (recoveryError != null) 'recoveryError': '$recoveryError',
          'committedLength': session.committedLength,
          'demanded': session.demanded,
          'prepareMicros':
              (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
        },
      );
      return;
    }

    _record(
      claim,
      kind: TraceEventKind.artifactSource,
      id: id,
      payload: <String, Object?>{
        'stage': 'physical-local-prepare',
        'action': completedLocally
            ? 'local-completion-short-circuit'
            : session.committedLength > 0
                ? 'local-hydration-ready'
                : 'local-hydration-miss',
        'state': session.state.name,
        'committedLength': session.committedLength,
        'demanded': session.demanded,
        'prepareMicros':
            (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
        'networkAdmissionRequired': !completedLocally && session.demanded,
        'physicalOwner': true,
      },
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
    final taskEpoch = session.epoch;
    var claim = _preferredClaim(id);
    if (claim == null) {
      _cancelDownloadRetry(id);
      _downloadTerminalFailures.remove(id);
      if (_networkTaskKeys[id] == taskKey) {
        // Keep the owner key until NetLane has retired the task. A new claim
        // may arrive in the small interval between this future completing and
        // the lane releasing its permits; removing it here would allow two
        // physical task identities for one session during that interval.
        _waitForTaskRetirement(id, session, taskKey);
      }
      return;
    }
    _ActiveProviderLease? providerLease;
    try {
      if (await DownloadJob.completeWithoutTransport(
        session: session,
        expectedChecksum: _expectedChecksum(id),
        control: token,
      )) {
        _record(
          claim,
          kind: TraceEventKind.artifactSource,
          id: id,
          payload: <String, Object?>{
            'stage': 'transfer-admission',
            'action': 'local-completion-short-circuit',
            'state': session.state.name,
            'committedLength': session.committedLength,
            'physicalOwner': true,
          },
        );
        return;
      }
      // A reset may have completed while the transportless completion check
      // was awaiting local I/O. Retire this lane task and let its normal
      // retirement barrier schedule a fresh attempt for the new generation;
      // continuing here could bind a provider response to the cleared
      // DownloadSession.
      if (session.epoch != taskEpoch) return;
      token.throwIfCancelled();
      final currentClaim = _preferredClaim(id);
      if (currentClaim == null || !session.demanded) return;
      claim = currentClaim;
      final provider = claim.consumer;
      final sourceId = claim.exactId;
      final retainedTransport =
          provider.retainedTransportFor?.call(sourceId.canonicalUri);
      final taskTransport =
          retainedTransport ?? provider.transportFor(sourceId.canonicalUri);
      providerLease = _ActiveProviderLease(
        taskKey: taskKey,
        scopeId: provider.scopeId,
        exactId: sourceId,
        claimSequence: claim.sequence,
        admittedPriority: claim.demand.priority,
        transportRetainedBeyondConsumer: retainedTransport != null,
      );
      _activeProviderLeases[id] = providerLease;
      final bucket = provider.downloadBucketFor(sourceId);
      final bucketLimit = provider.downloadBucketLimitFor(sourceId);
      _record(
        claim,
        kind: TraceEventKind.downloadStarted,
        id: id,
        payload: <String, Object?>{
          'priority': session.effectivePriority,
          'bucket': bucket,
          'bucketLimit': bucketLimit,
          'globalRunning': net.running,
          'globalReadPermitReleasedTasks': net.readPermitReleasedTasks,
          'globalDemandedParkedResponses': net.demandedParkedResponses,
          'globalInactiveParkedResponses': net.inactiveParkedResponses,
          'globalActive': net.active,
          'globalReadPermitLimit': net.maxActive,
          'globalLimit': net.maxActive,
          'globalTransportLeases': net.transportLeases,
          'globalTransportLimit': net.maxActive,
          'handoffActive': net.handoffActive,
          'effectivePriority': net.priorityOf(taskKey),
          'demanded': net.demandedOf(taskKey),
          'bucketActive': net.activeForBucket(bucket),
          'bucketTransportLeases': net.transportLeasesForBucket(bucket),
          'flowTargetFrames': claim.demand.flowTargetFrames,
          'committedLength': session.committedLength,
          'physicalOwner': true,
          'providerScope': provider.scopeId,
          'providerExactId': sourceId.key,
          'providerTransportLifetime': retainedTransport != null
              ? 'task-retained'
              : 'consumer-bound',
        },
      );
      for (var attempt = 1; ; attempt++) {
        token.throwIfCancelled();
        // Demand withdrawal parks an already-admitted physical task; it must
        // not let a retry timer wake up and start a fresh provider request
        // while the session has no consumer claim. The current attempt may
        // still finish/park according to its response capability, but the
        // retry loop itself has no reason to open another response.
        if (!token.demanded || !session.demanded) return;
        final attemptStartedAtMicros = clock.nowMicros();
        try {
          await DownloadJob(
            transport: taskTransport,
            session: session,
            requestUri: sourceId.canonicalUri,
            attachLegacyDemand: false,
            readStallTimeout: readStallTimeout,
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
          _cancelDownloadRetry(id);
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
          final failure = error is Failure
              ? error
              : Failure(
                  code: ErrorCode.network,
                  message: 'download attempt failed for ${id.key}: $error',
                  cause: error,
                );
          // A transport failure can race a lane preemption. Once the lane has
          // cancelled this attempt, do not turn the preemption into a
          // session-terminal failure or schedule a replacement retry here.
          // Preserve the lane decision in the trace before returning; the
          // cancellation flag is already set when the preemption/eviction
          // snapshot is attached, so the lower branch cannot observe it.
          if (session.epoch != taskEpoch || _isStaleLifecycleFailure(failure)) {
            return;
          }
          if (token.cancelled) {
            _recordLaneCancellation(claim, id, session, token);
            return;
          }
          if (!provider.retry.allows(failure, attempt)) {
            if (failure.code == ErrorCode.cancelled) {
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
                    'incomingWaitMicros': preemption.incomingWaitMicros,
                    'preemptionReason': preemption.reason,
                    'committedLength': session.committedLength,
                    'partialPreserved': session.committedLength > 0,
                    'partialState': session.state.name,
                  },
                );
              } else {
                final eviction = token.retentionEvictionSnapshot;
                if (eviction != null) {
                  _record(
                    claim,
                    kind: TraceEventKind.downloadEvicted,
                    id: id,
                    payload: <String, Object?>{
                      'basePriority': eviction.basePriority,
                      'retentionPriority': eviction.retentionPriority,
                      'retentionBonus': eviction.retentionBonus,
                      'restartCostElapsedMicros':
                          eviction.restartCostElapsedMicros,
                      'restartCostBytes': eviction.restartCostBytes,
                      'evictionReason': eviction.reason,
                      'committedLength': session.committedLength,
                      'partialPreserved': session.committedLength > 0,
                      'partialState': session.state.name,
                    },
                  );
                }
              }
              return;
            }
            final failedAtMicros = clock.nowMicros();
            _recordError(
              claim,
              id,
              failure,
              details: <String, Object?>{
                'attempt': attempt,
                'executionMicros': (failedAtMicros - attemptStartedAtMicros)
                    .clamp(0, 1 << 62)
                    .toInt(),
              },
            );
            if (session.demanded && !token.cancelled) {
              final retryScheduled = failure.code == ErrorCode.network &&
                  _scheduleDownloadRetry(id, session, failure);
              if (!retryScheduled) {
                _downloadTerminalFailures.add(id);
              }
            }
            if (_downloadTerminalFailures.contains(id) && !token.cancelled) {
              // Terminal task outcome (no further retry): publish the failure
              // on the session. Demand holders wait for a terminal state; a
              // session left queued here would stall them until an inactivity
              // timeout instead of surfacing the real error.
              await session.failWithoutWriter(failure);
            }
            return;
          }
          if (!token.demanded || !session.demanded) return;
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
          if (!token.demanded || !session.demanded) return;
        }
      }
    } on Object catch (error, stackTrace) {
      final failedClaim = _preferredClaim(id) ?? claim;
      final failure = error is Failure
          ? error
          : Failure(
              code: ErrorCode.network,
              message: 'download transfer setup failed for ${id.key}: $error',
              cause: error,
            );
      if (session.epoch != taskEpoch || _isStaleLifecycleFailure(failure)) {
        return;
      }
      if (failure.code == ErrorCode.cancelled || token.cancelled) {
        if (token.cancelled) {
          _recordLaneCancellation(failedClaim, id, session, token);
        }
        return;
      }
      if (failedClaim != null) {
        _recordError(
          failedClaim,
          id,
          failure,
          details: <String, Object?>{
            'stage': 'transfer-setup',
            'stack': '$stackTrace',
          },
        );
      }
      if (token.cancelled) return;
      final retryScheduled = failedClaim != null &&
          session.demanded &&
          failure.code == ErrorCode.network &&
          _scheduleDownloadRetry(id, session, failure);
      if (session.demanded && !retryScheduled && !token.cancelled) {
        _downloadTerminalFailures.add(id);
        await session.failWithoutWriter(failure);
      }
    } finally {
      if (providerLease != null &&
          _activeProviderLeases[id]?.taskKey == taskKey) {
        _activeProviderLeases.remove(id);
      }
      if (_networkTaskKeys[id] == taskKey) {
        // Defer key retirement until NetLane has observed task completion.
        // In particular, cancellation/preemption can complete _runDownload
        // before the lane callback releases its transport/read permits. The
        // same barrier is needed for successful and terminal tasks so callers
        // never observe a retired session with a still-live owner key.
        _waitForTaskRetirement(id, session, taskKey);
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
    final waiter = Completer<void>();
    _downloadRetryWaiters[id] = waiter;
    unawaited(() async {
      var ownsWaiter = false;
      try {
        await Future.any<void>(<Future<void>>[
          claim.consumer.sleep(delay),
          waiter.future,
          _disposedCompleter.future,
        ]);
      } on Object {
        // A retry-sleep hook is advisory. The physical owner must not expose
        // an unhandled provider-policy error or keep a retry permanently
        // pending because a custom sleeper failed; the continuation below
        // immediately schedules the next bounded attempt.
      } finally {
        ownsWaiter = identical(_downloadRetryWaiters[id], waiter);
        if (ownsWaiter) {
          _downloadRetryWaiters.remove(id);
          _downloadRetryPending.remove(id);
        }
      }
      if (!ownsWaiter || _disposed || waiter.isCompleted ||
          !session.demanded) {
        return;
      }
      // A consumer-provided sleeper is advisory. If it fails, do not leave a
      // demanded session with neither a retry waiter nor a replacement task;
      // the bounded retry-round counter still prevents an immediate hot loop.
      // Fall through to the next attempt without backoff in that case.
      _downloadRetryPending.remove(id);
      await Future<void>.delayed(Duration.zero);
      if (_disposed || waiter.isCompleted || !session.demanded) return;
      _ensureDownloadTask(id, session);
    }());
    return true;
  }

  void _cancelDownloadRetry(DownloadId id) {
    final waiter = _downloadRetryWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _downloadRetryPending.remove(id);
    _downloadRetryRounds.remove(id);
  }



  void _watchSession(DownloadSession session) {
    final id = session.id;
    final watched = _sessionListenerSessions[id];
    if (identical(watched, session)) return;
    final priorListener = _sessionListeners.remove(id);
    if (priorListener != null) {
      (watched ?? session).removeSnapshotListener(priorListener);
    }
    _sessionListenerSessions[id] = session;
    _progressLengths[id] = session.committedLength;
    void listener(DownloadSnapshot snapshot) {
      final prior = _progressLengths[id] ?? 0;
      if (snapshot.committedLength != prior) {
        _progressLengths[id] = snapshot.committedLength;
      }
      if (snapshot.committedLength > prior) {
        // Fresh authoritative bytes make the pending recovery timer stale.
        // Clear the timer's waiter as well as its bookkeeping; otherwise the
        // old sleep can wake after progress and reopen a duplicate attempt.
        _cancelDownloadRetry(id);
        _downloadTerminalFailures.remove(id);
      }
    }
    _sessionListeners[id] = listener;
    session.addSnapshotListener(listener, fireImmediately: false);
  }

  void _retireDownloadTracking(DownloadId id, DownloadSession? session) {
    _cancelDownloadRetry(id);
    _downloadTerminalFailures.remove(id);
    _ensureSkipReasons.remove(id);
    final deferredAtLength = _downloadDeferredAtLength[id];
    final preserveDeferred = session != null &&
        session.state == DownloadState.idle &&
        deferredAtLength == session.committedLength;
    if (!preserveDeferred) {
      _downloadDeferredAtLength.remove(id);
    }
  }

  void _waitForTaskRetirement(
    DownloadId id,
    DownloadSession session,
    String taskKey,
  ) {
    if (!_taskRetirementWaits.add(taskKey)) return;
    unawaited(() async {
      try {
        await net.idleKeys(<String>[taskKey]);
      } finally {
        _taskRetirementWaits.remove(taskKey);
      }
      if (_networkTaskKeys[id] == taskKey) {
        _networkTaskKeys.remove(id);
      }
      if (!session.demanded && !session.activeRun &&
          identical(registry.findExact(id), session)) {
        _retireDownloadTracking(id, session);
      }
      if (_disposed ||
          (_networkTaskKeys[id] != null &&
              _networkTaskKeys[id] != taskKey) ||
          _downloadRetryPending.contains(id) ||
          !identical(registry.findExact(id), session) ||
          !session.demanded ||
          _downloadTerminalFailures.contains(id) ||
          session.state == DownloadState.promoted ||
          session.state == DownloadState.disposed) {
        return;
      }
      _ensureDownloadTask(id, session);
    }());
  }

  void _migrateDownloadPriority(
    DownloadId id,
    String taskKey,
    int priority, {
    required String reason,
  }) {
    final claim = _preferredClaim(id);
    if (claim != null) {
      net.updateFlowTargetFrames(taskKey, claim.demand.flowTargetFrames);
    }
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
        'demanded': net.demandedOf(taskKey),
        'physicalOwner': true,
      },
    );
  }

  String? _expectedChecksum(DownloadId id) {
    String? checksum;
    for (final claim in _claims[id]?.values ?? const <_TransferClaim>[]) {
      final candidate =
          _normalizeExpectedChecksum(claim.demand.expectedChecksum);
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
  }) =>
      rankPolicy.allowsFullBodyCatchup(
        priority: priority,
        completionRequired: _requiresCompletion(id),
        preservedLength: preservedLength,
      );

  Future<void> _sleepOrCancel(
    Duration delay,
    CancelToken token,
    TransferSleep sleep,
  ) async {
    if (delay == Duration.zero) {
      token.throwIfCancelled();
      return;
    }
    if (token.cancelled) {
      token.throwIfCancelled();
      return;
    }
    // Install the wake future before checking the current state. Otherwise a
    // demand withdrawal between the check and getter access could be missed,
    // leaving a custom backoff hook asleep after its final consumer left.
    final demandChanged = token.whenDemandChanged;
    if (!token.demanded) return;
    final waits = <Future<void>>[
      if (identical(sleep, _defaultTransferSleep))
        Future<void>.delayed(delay)
      else
        sleep(delay),
      token.whenCancelled,
      demandChanged,
    ];
    await Future.any<void>(waits);
    token.throwIfCancelled();
  }

  bool _isStaleLifecycleFailure(Failure failure) =>
      failure.code == ErrorCode.staleEpoch ||
      failure.code == ErrorCode.staleWriter ||
      failure.code == ErrorCode.staleRun;

  void _recordLaneCancellation(
    _TransferClaim? claim,
    DownloadId id,
    DownloadSession session,
    CancelToken token,
  ) {
    final preemption = token.preemptionSnapshot;
    final eviction = token.retentionEvictionSnapshot;
    if (preemption == null && eviction == null) return;
    final effectiveClaim = _preferredClaim(id) ?? claim;
    if (preemption != null) {
      _record(
        effectiveClaim,
        kind: TraceEventKind.downloadPreempted,
        id: id,
        payload: <String, Object?>{
          'incomingPriority': preemption.incomingPriority,
          'basePriority': preemption.basePriority,
          'retentionPriority': preemption.retentionPriority,
          'retentionBonus': preemption.retentionBonus,
          'restartCostElapsedMicros': preemption.restartCostElapsedMicros,
          'restartCostBytes': preemption.restartCostBytes,
          'incomingWaitMicros': preemption.incomingWaitMicros,
          'preemptionReason': preemption.reason,
          'committedLength': session.committedLength,
          'partialPreserved': session.committedLength > 0,
          'partialState': session.state.name,
        },
      );
      return;
    }
    final retention = eviction!;
    _record(
      effectiveClaim,
      kind: TraceEventKind.downloadEvicted,
      id: id,
      payload: <String, Object?>{
        'basePriority': retention.basePriority,
        'retentionPriority': retention.retentionPriority,
        'retentionBonus': retention.retentionBonus,
        'restartCostElapsedMicros': retention.restartCostElapsedMicros,
        'restartCostBytes': retention.restartCostBytes,
        'evictionReason': retention.reason,
        'committedLength': session.committedLength,
        'partialPreserved': session.committedLength > 0,
        'partialState': session.state.name,
      },
    );
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
    required this.retainedTransportFor,
    required this.traceSink,
    required this.retry,
    required this.sleep,
    required this.downloadBucketFor,
    required this.downloadBucketLimitFor,
  });

  final DownloadTransferOwner owner;
  final String scopeId;
  final TransferTransportPick transportFor;
  final TransferRetainedTransportPick? retainedTransportFor;
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
  final Completer<void> _disposedCompleter = Completer<void>();

  DownloadRegistry get registry => owner.registry;
  NetLane get net => owner.net;
  bool get disposed => _disposed;
  Future<void> get whenDisposed => _disposedCompleter.future;
  int get revision => _revision;
  Map<DownloadId, TransferDemand> get demands =>
      Map<DownloadId, TransferDemand>.unmodifiable(_demands);

  void replaceDemands(
    String sessionId,
    int revision,
    Map<DownloadId, TransferDemand> desired,
  ) =>
      owner._replaceDemands(this, sessionId, revision, desired);

  /// Projects decoder-owned playable-prefix evidence to the exact physical
  /// session currently watched by this Reader. This does not grant the Reader
  /// transfer ownership or permission to schedule outside existing demands.
  void observeDecodePrefixEvidence(
    DownloadSession session,
    DecodeSnapshot snapshot,
  ) =>
      owner._observeDecodePrefixEvidence(session, snapshot);

  void refreshScheduling() => owner._refreshScheduling(this);

  Future<void> idle() => owner._idleFor(this);

  Future<void> dispose() => owner._disposeConsumer(this);
}

final class _ResidentReplayBody {
  _ResidentReplayBody(this.response, {required this.control});

  final ByteResponse response;
  final TaskControl? control;
  Future<void>? _discardFuture;

  Future<void> discard() => _discardFuture ??=
      response.discard(control: control);
}

final class _LocalPreparationControl implements TaskControl {
  _LocalPreparationControl({required this.priority});

  final Completer<void> _cancelledSignal = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelledSignal.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelledSignal.future;

  void updatePriority(int value) {
    priority = value;
  }

  void cancel() {
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }

  void throwIfCancelled() {
    if (cancelled) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'local transfer preparation was cancelled',
      );
    }
  }
}

final class _ActiveProviderLease {
  const _ActiveProviderLease({
    required this.taskKey,
    required this.scopeId,
    required this.exactId,
    required this.claimSequence,
    required this.admittedPriority,
    required this.transportRetainedBeyondConsumer,
  });

  final String taskKey;
  final String scopeId;
  final DownloadId exactId;
  final int claimSequence;
  final int admittedPriority;
  final bool transportRetainedBeyondConsumer;
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
