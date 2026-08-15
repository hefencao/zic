import 'dart:async';
import 'dart:math' as math;

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

typedef LaneTask = Future<void> Function(CancelToken token);
typedef LaneError = void Function(String key, Object error, StackTrace stack);

final class CancelToken implements PriorityObservableTaskControl {
  CancelToken({
    int priority = 0,
    int flowTargetFrames = 0,
    bool demanded = true,
    Future<void> Function()? acquireResponseReadPermit,
    void Function(bool responseRetained)? releaseResponseReadPermit,
    MonoClock clock = const SystemClock(),
  })  : assert(flowTargetFrames >= 0),
        _priority = priority,
        _flowTargetFrames = flowTargetFrames,
        _demanded = demanded,
        _acquireResponseReadPermit = acquireResponseReadPermit,
        _releaseResponseReadPermit = releaseResponseReadPermit,
        _clock = clock,
        _activatedAtMicros = clock.nowMicros();

  final MonoClock _clock;
  final int _activatedAtMicros;
  bool _cancelled = false;
  int _priority;
  int _flowTargetFrames;
  bool _demanded;
  final Future<void> Function()? _acquireResponseReadPermit;
  final void Function(bool responseRetained)? _releaseResponseReadPermit;
  Completer<void>? _flowChanged;
  int? _restartCostStartedAtMicros;
  int _restartCostBytes = 0;
  TaskPreemptionSnapshot? _preemptionSnapshot;
  TaskRetentionEvictionSnapshot? _retentionEvictionSnapshot;
  final Completer<void> _cancelledSignal = Completer<void>();
  final StreamController<int> _priorityChanges =
      StreamController<int>.broadcast(sync: true);

  @override
  bool get cancelled => _cancelled;
  @override
  Future<void> get whenCancelled => _cancelledSignal.future;
  @override
  int get priority => _priority;
  @override
  Stream<int> get priorityChanges => _priorityChanges.stream;
  int get flowTargetFrames => _flowTargetFrames;
  bool get demanded => _demanded;

  bool flowBlockedAt(int completedFrames) =>
      _flowTargetFrames > 0 && completedFrames >= _flowTargetFrames;

  void updateFlowTargetFrames(int frames) {
    assert(frames >= 0);
    if (_flowTargetFrames == frames) return;
    _flowTargetFrames = frames;
    _wakeFlowWaiters();
  }

  void updateDemanded(bool demanded) {
    if (_demanded == demanded) return;
    _demanded = demanded;
    _wakeFlowWaiters();
  }

  Future<void> waitForControlChangeOrTimeout(Duration timeout) async {
    final wake = _flowChanged ??= Completer<void>();
    await Future.any<void>(<Future<void>>[
      wake.future,
      whenCancelled,
      Future<void>.delayed(timeout),
    ]);
    throwIfCancelled();
  }

  void releaseResponseReadPermit({bool responseRetained = true}) {
    _releaseResponseReadPermit?.call(responseRetained);
  }

  Future<void> acquireResponseReadPermit() async {
    final acquire = _acquireResponseReadPermit;
    if (acquire == null) return;
    await Future.any<void>(<Future<void>>[
      acquire(),
      whenCancelled,
    ]);
    throwIfCancelled();
  }

  void _wakeFlowWaiters() {
    final wake = _flowChanged;
    _flowChanged = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  int get restartCostElapsedMicros {
    final startedAt = _restartCostStartedAtMicros;
    if (startedAt == null) return 0;
    return (_clock.nowMicros() - startedAt).clamp(0, 1 << 62).toInt();
  }

  int get restartCostBytes => _restartCostBytes;
  TaskPreemptionSnapshot? get preemptionSnapshot => _preemptionSnapshot;
  TaskRetentionEvictionSnapshot? get retentionEvictionSnapshot =>
      _retentionEvictionSnapshot;

  void beginRestartCost() {
    _restartCostStartedAtMicros ??= _activatedAtMicros;
  }

  void recordRestartCostBytes(int totalBytes) {
    if (totalBytes <= _restartCostBytes) return;
    _restartCostBytes = totalBytes;
  }

  void cancelForPreemption(TaskPreemptionSnapshot snapshot) {
    if (_cancelled) return;
    _preemptionSnapshot = snapshot;
    cancel();
  }

  void cancelForRetentionEviction(TaskRetentionEvictionSnapshot snapshot) {
    if (_cancelled) return;
    _retentionEvictionSnapshot = snapshot;
    cancel();
  }

  void updatePriority(int priority) {
    if (_priority == priority) return;
    _priority = priority;
    if (!_priorityChanges.isClosed) {
      _priorityChanges.add(priority);
    }
  }

  void dispose() {
    final wake = _flowChanged;
    _flowChanged = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    if (!_priorityChanges.isClosed) {
      unawaited(_priorityChanges.close());
    }
  }

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final wake = _flowChanged;
    _flowChanged = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    _cancelledSignal.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'task was cancelled',
      );
    }
  }
}


final class TaskPreemptionSnapshot {
  const TaskPreemptionSnapshot({
    required this.incomingPriority,
    required this.basePriority,
    required this.retentionPriority,
    required this.retentionBonus,
    required this.restartCostElapsedMicros,
    required this.restartCostBytes,
    required this.incomingWaitMicros,
    this.reason = 'priority',
  });

  final int incomingPriority;
  final int basePriority;
  final int retentionPriority;
  final int retentionBonus;
  final int restartCostElapsedMicros;
  final int restartCostBytes;
  final int incomingWaitMicros;
  final String reason;
}



final class TaskRetentionEvictionSnapshot {
  const TaskRetentionEvictionSnapshot({
    required this.basePriority,
    required this.retentionPriority,
    required this.retentionBonus,
    required this.restartCostElapsedMicros,
    required this.restartCostBytes,
    this.reason = 'inactive-transport-lease-reclaim',
  });

  final int basePriority;
  final int retentionPriority;
  final int retentionBonus;
  final int restartCostElapsedMicros;
  final int restartCostBytes;
  final String reason;
}

/// Scheduler-owned effective rank for one active network task.
///
/// [basePriority] is the semantic rank supplied by the caller that owns the
/// competing policy choice. [effectivePriority] adds only NetLane-owned
/// restart-cost retention. Consumers compare candidates against this value
/// rather than reproducing current/orphan/restart-cost cases themselves.
final class NetPolicyRank {
  const NetPolicyRank({
    required this.basePriority,
    required this.effectivePriority,
    required this.retentionBonus,
    required this.restartCostElapsedMicros,
    required this.restartCostBytes,
  });

  final int basePriority;
  final int effectivePriority;
  final int retentionBonus;
  final int restartCostElapsedMicros;
  final int restartCostBytes;
}


abstract interface class TaskLane {
  int get maxActive;
  int get queued;
  int get active;
  bool get isIdle;

  /// Applies one scheduling transaction atomically. Mutations made inside the
  /// callback update lane state immediately but defer scheduler pumping until
  /// the outermost batch exits, so one authoritative plan revision cannot
  /// repeatedly re-run the same admission/preemption scan.
  void batch(void Function() action);

  bool submit({
    required String key,
    required int priority,
    required LaneTask task,
  });

  bool replace({
    required String key,
    required int priority,
    required LaneTask task,
  });

  bool follow({
    required String key,
    required int priority,
    required LaneTask task,
  });

  bool cancelQueued(String key);
  bool cancel(String key);
  void cancelAll();
  Future<void> idle();
}

final class NetLane implements TaskLane {
  NetLane({
    required int maxActive,
    int reservedHighPrioritySlots = 0,
    int highPriorityThreshold = 1000,
    int preemptionThreshold = 40,
    Duration preemptionCandidateGrace = Duration.zero,
    MonoClock clock = const SystemClock(),
    LaneError? onError,
  }) : _core = _Lane(
          maxActive: maxActive,
          reservedHighPrioritySlots: reservedHighPrioritySlots,
          highPriorityThreshold: highPriorityThreshold,
          preemptionThreshold: preemptionThreshold,
          preemptionCandidateGrace: preemptionCandidateGrace,
          clock: clock,
          onError: onError,
        );

  final _Lane _core;

  @override
  int get maxActive => _core.maxActive;
  @override
  int get queued => _core.queued;
  @override
  int get active => _core.active;
  int get running => _core.running;
  int get readPermitReleasedTasks => _core.readPermitReleasedTasks;
  int get demandedParkedResponses => _core.demandedParkedResponses;
  int get inactiveParkedResponses => _core.inactiveParkedResponses;
  @override
  bool get isIdle => _core.isIdle;
  @override
  void batch(void Function() action) => _core.batch(action);
  @override
  bool submit({required String key, required int priority, required LaneTask task}) =>
      _core.submit(key: key, priority: priority, task: task);

  bool submitRanked({
    required String key,
    required int priority,
    required String bucket,
    required int bucketLimit,
    bool preemptible = true,
    int flowTargetFrames = 0,
    bool demanded = true,
    required LaneTask task,
  }) =>
      _core.submit(
        key: key,
        priority: priority,
        bucket: bucket,
        bucketLimit: bucketLimit,
        preemptible: preemptible,
        flowTargetFrames: flowTargetFrames,
        demanded: demanded,
        task: task,
      );

  Future<void> idleKeys(Iterable<String> keys) => _core.idleKeys(keys);

  int activeForBucket(String bucket) => _core.activeForBucket(bucket);
  int get transportLeases => _core.transportLeases;
  int transportLeasesForBucket(String bucket) =>
      _core.transportLeasesForBucket(bucket);
  int get handoffActive => _core.handoffActive;
  int? priorityOf(String key) => _core.priorityOf(key);
  bool isActive(String key) => _core.isActive(key);
  NetPolicyRank? activePolicyRank(
    String key, {
    required int basePriority,
  }) =>
      _core.activePolicyRank(key, basePriority: basePriority);
  bool incomingOutranks(int incomingPriority, NetPolicyRank incumbent) =>
      _core.incomingOutranks(incomingPriority, incumbent);
  bool updatePriority(String key, int priority) =>
      _core.updatePriority(key, priority);
  bool updateFlowTargetFrames(String key, int frames) =>
      _core.updateFlowTargetFrames(key, frames);
  bool updateDemanded(String key, bool demanded) =>
      _core.updateDemanded(key, demanded);
  bool? demandedOf(String key) => _core.demandedOf(key);
  bool? responseReadPermitHeldOf(String key) =>
      _core.responseReadPermitHeldOf(key);
  bool? transportLeaseHeldOf(String key) =>
      _core.transportLeaseHeldOf(key);

  @override
  bool replace({required String key, required int priority, required LaneTask task}) =>
      _core.replace(key: key, priority: priority, task: task);
  @override
  bool follow({required String key, required int priority, required LaneTask task}) =>
      _core.follow(key: key, priority: priority, task: task);
  @override
  bool cancelQueued(String key) => _core.cancelQueued(key);
  @override
  bool cancel(String key) => _core.cancel(key);
  @override
  void cancelAll() => _core.cancelAll();
  @override
  Future<void> idle() => _core.idle();
}

final class DecodeLane implements TaskLane {
  DecodeLane({
    required int maxActive,
    int reservedHighPrioritySlots = 0,
    int highPriorityThreshold = 1 << 30,
    int preemptionThreshold = 1 << 30,
    LaneError? onError,
  }) : _core = _Lane(
          maxActive: maxActive,
          reservedHighPrioritySlots: reservedHighPrioritySlots,
          highPriorityThreshold: highPriorityThreshold,
          preemptionThreshold: preemptionThreshold,
          onError: onError,
        );

  final _Lane _core;

  @override
  int get maxActive => _core.maxActive;
  @override
  int get queued => _core.queued;
  @override
  int get active => _core.active;
  @override
  bool get isIdle => _core.isIdle;
  @override
  void batch(void Function() action) => _core.batch(action);
  @override
  bool submit({required String key, required int priority, required LaneTask task}) =>
      _core.submit(key: key, priority: priority, task: task);
  @override
  bool replace({required String key, required int priority, required LaneTask task}) =>
      _core.replace(key: key, priority: priority, task: task);
  @override
  bool follow({required String key, required int priority, required LaneTask task}) =>
      _core.follow(key: key, priority: priority, task: task);
  @override
  bool cancelQueued(String key) => _core.cancelQueued(key);
  @override
  bool cancel(String key) => _core.cancel(key);
  @override
  void cancelAll() => _core.cancelAll();
  @override
  Future<void> idle() => _core.idle();
}

final class UploadLane implements TaskLane {
  UploadLane({
    required int maxActive,
    int reservedHighPrioritySlots = 0,
    int highPriorityThreshold = 1 << 30,
    int preemptionThreshold = 1 << 30,
    LaneError? onError,
  }) : _core = _Lane(
          maxActive: maxActive,
          reservedHighPrioritySlots: reservedHighPrioritySlots,
          highPriorityThreshold: highPriorityThreshold,
          preemptionThreshold: preemptionThreshold,
          onError: onError,
        );

  final _Lane _core;

  @override
  int get maxActive => _core.maxActive;
  @override
  int get queued => _core.queued;
  @override
  int get active => _core.active;
  @override
  bool get isIdle => _core.isIdle;
  @override
  void batch(void Function() action) => _core.batch(action);
  @override
  bool submit({required String key, required int priority, required LaneTask task}) =>
      _core.submit(key: key, priority: priority, task: task);
  @override
  bool replace({required String key, required int priority, required LaneTask task}) =>
      _core.replace(key: key, priority: priority, task: task);
  @override
  bool follow({required String key, required int priority, required LaneTask task}) =>
      _core.follow(key: key, priority: priority, task: task);
  @override
  bool cancelQueued(String key) => _core.cancelQueued(key);
  @override
  bool cancel(String key) => _core.cancel(key);
  @override
  void cancelAll() => _core.cancelAll();
  @override
  Future<void> idle() => _core.idle();
}

final class MaintenanceLane implements TaskLane {
  MaintenanceLane({required int maxActive, LaneError? onError})
      : _core = _Lane(maxActive: maxActive, onError: onError);

  final _Lane _core;

  @override
  int get maxActive => _core.maxActive;
  @override
  int get queued => _core.queued;
  @override
  int get active => _core.active;
  @override
  bool get isIdle => _core.isIdle;
  @override
  void batch(void Function() action) => _core.batch(action);
  @override
  bool submit({required String key, required int priority, required LaneTask task}) =>
      _core.submit(key: key, priority: priority, task: task);
  @override
  bool replace({required String key, required int priority, required LaneTask task}) =>
      _core.replace(key: key, priority: priority, task: task);
  @override
  bool follow({required String key, required int priority, required LaneTask task}) =>
      _core.follow(key: key, priority: priority, task: task);
  @override
  bool cancelQueued(String key) => _core.cancelQueued(key);
  @override
  bool cancel(String key) => _core.cancel(key);
  @override
  void cancelAll() => _core.cancelAll();
  @override
  Future<void> idle() => _core.idle();
}

final class _Lane {
  _Lane({
    required this.maxActive,
    this.reservedHighPrioritySlots = 0,
    this.highPriorityThreshold = 1 << 30,
    this.preemptionThreshold = 1 << 30,
    this.preemptionCandidateGrace = Duration.zero,
    this.clock = const SystemClock(),
    this.onError,
  })  : assert(maxActive > 0),
        assert(reservedHighPrioritySlots >= 0),
        assert(preemptionThreshold >= 0),
        assert(!preemptionCandidateGrace.isNegative);

  final int maxActive;
  final int reservedHighPrioritySlots;
  final int highPriorityThreshold;
  final int preemptionThreshold;
  final Duration preemptionCandidateGrace;
  final MonoClock clock;
  final LaneError? onError;
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, _ActiveTask> _active = <String, _ActiveTask>{};
  final Map<String, int> _activeByBucket = <String, int>{};
  final Map<String, int> _transportLeasesByBucket = <String, int>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  final List<_KeyIdleWaiter> _keyIdleWaiters = <_KeyIdleWaiter>[];
  Timer? _preemptionWake;
  int? _preemptionWakeAtMicros;
  int _seq = 0;
  int _receivingActive = 0;
  int _transportLeasesActive = 0;
  int _batchDepth = 0;
  bool _pumpRequested = false;
  int _parkSeq = 0;

  int get queued => _pending.length;
  int get active => _receivingActive;
  int get running => _active.length;
  int get transportLeases => _transportLeasesActive;
  int get readPermitReleasedTasks =>
      _active.values.where((task) => !task.responseReadPermitHeld).length;
  int get demandedParkedResponses => _active.values
      .where((task) =>
          !task.responseReadPermitHeld &&
          task.responseRetainedWhilePermitReleased &&
          task.demanded)
      .length;
  int get inactiveParkedResponses => _active.values
      .where((task) =>
          !task.responseReadPermitHeld &&
          task.responseRetainedWhilePermitReleased &&
          !task.demanded)
      .length;
  int get handoffActive {
    var excess = math.max(
      math.max(0, active - maxActive),
      math.max(0, transportLeases - maxActive),
    );
    final limits = <String, int>{};
    for (final task in _active.values) {
      final bucket = task.bucket;
      final limit = task.bucketLimit;
      if (bucket != null && limit != null) limits[bucket] = limit;
    }
    for (final entry in limits.entries) {
      excess = math.max(
        excess,
        math.max(0, (_activeByBucket[entry.key] ?? 0) - entry.value),
      );
      excess = math.max(
        excess,
        math.max(
          0,
          (_transportLeasesByBucket[entry.key] ?? 0) - entry.value,
        ),
      );
    }
    return excess;
  }

  bool get isIdle => _pending.isEmpty && _active.isEmpty;

  int activeForBucket(String bucket) => _activeByBucket[bucket] ?? 0;
  int transportLeasesForBucket(String bucket) =>
      _transportLeasesByBucket[bucket] ?? 0;
  bool isActive(String key) => _active.containsKey(key);
  int? priorityOf(String key) =>
      _active[key]?.priority ?? _pending[key]?.priority;

  NetPolicyRank? activePolicyRank(
    String key, {
    required int basePriority,
  }) {
    final task = _active[key];
    if (task == null) return null;
    return _policyRank(task, basePriority: basePriority);
  }

  bool incomingOutranks(int incomingPriority, NetPolicyRank incumbent) =>
      incomingPriority - incumbent.effectivePriority >= preemptionThreshold;

  void batch(void Function() action) {
    _batchDepth++;
    try {
      action();
    } finally {
      _batchDepth--;
      if (_batchDepth == 0 && _pumpRequested) {
        _pumpRequested = false;
        _pump();
      }
    }
  }

  void _requestPump() {
    if (_batchDepth > 0) {
      _pumpRequested = true;
      return;
    }
    _pump();
  }

  bool submit({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    bool preemptible = true,
    int flowTargetFrames = 0,
    bool demanded = true,
    required LaneTask task,
  }) {
    assert(flowTargetFrames >= 0);
    final activeTask = _active[key];
    if (activeTask != null) {
      final increased = _updateActivePriority(activeTask, priority);
      activeTask
        ..preemptible = preemptible
        ..flowTargetFrames = flowTargetFrames
        ..demanded = demanded;
      activeTask.token.updateFlowTargetFrames(flowTargetFrames);
      activeTask.token.updateDemanded(demanded);
      if (increased) _requestPump();
      return false;
    }
    final pending = _pending[key];
    if (pending != null) {
      final increased = priority > pending.priority;
      _updatePendingPriority(pending, priority);
      pending
        ..bucket = bucket
        ..bucketLimit = bucketLimit
        ..preemptible = preemptible
        ..flowTargetFrames = flowTargetFrames
        ..demanded = demanded
        ..task = task;
      if (increased) _requestPump();
      return false;
    }
    _pending[key] = _createPending(
      key: key,
      priority: priority,
      bucket: bucket,
      bucketLimit: bucketLimit,
      preemptible: preemptible,
      flowTargetFrames: flowTargetFrames,
      demanded: demanded,
      task: task,
    );
    _requestPump();
    return true;
  }


  bool updatePriority(String key, int priority) {
    final activeTask = _active[key];
    if (activeTask != null) {
      final previous = activeTask.priority;
      _updateActivePriority(activeTask, priority);
      // Priority changes affect both queued admission and parked-response
      // resume order, so every real change re-runs the lane policy.
      if (previous != priority) _requestPump();
      return true;
    }
    final pending = _pending[key];
    if (pending == null) return false;
    final previous = pending.priority;
    _updatePendingPriority(pending, priority);
    if (previous != priority) _requestPump();
    return true;
  }

  bool updateFlowTargetFrames(String key, int frames) {
    assert(frames >= 0);
    final activeTask = _active[key];
    if (activeTask != null) {
      activeTask.flowTargetFrames = frames;
      activeTask.token.updateFlowTargetFrames(frames);
      return true;
    }
    final pending = _pending[key];
    if (pending == null) return false;
    pending.flowTargetFrames = frames;
    return true;
  }

  bool updateDemanded(String key, bool demanded) {
    final activeTask = _active[key];
    if (activeTask != null) {
      if (activeTask.demanded == demanded) return true;
      activeTask.demanded = demanded;
      activeTask.token.updateDemanded(demanded);
      // Demand membership does not own transport lifetime. An inactive
      // retained response keeps its transport lease until real lease pressure
      // needs that bounded network resource.
      _requestPump();
      return true;
    }
    final pending = _pending[key];
    if (pending == null) return false;
    if (pending.demanded == demanded) return true;
    pending.demanded = demanded;
    _requestPump();
    return true;
  }

  bool? demandedOf(String key) =>
      _active[key]?.demanded ?? _pending[key]?.demanded;
  bool? responseReadPermitHeldOf(String key) =>
      _active[key]?.responseReadPermitHeld;
  bool? transportLeaseHeldOf(String key) =>
      _active[key]?.transportLeaseHeld;

  void _updatePendingPriority(_Pending pending, int priority) {
    final previous = pending.priority;
    pending.priority = priority;
    if (priority >= highPriorityThreshold &&
        previous < highPriorityThreshold) {
      pending.highPrioritySinceMicros = clock.nowMicros();
    } else if (priority < highPriorityThreshold) {
      pending.highPrioritySinceMicros = null;
    }
  }

  bool _updateActivePriority(_ActiveTask task, int priority) {
    final previous = task.priority;
    if (previous == priority) return false;
    task.priority = priority;
    task.token.updatePriority(priority);
    return priority > previous;
  }

  _Pending _createPending({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    bool preemptible = true,
    int flowTargetFrames = 0,
    bool demanded = true,
    required LaneTask task,
  }) {
    assert(flowTargetFrames >= 0);
    return _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      bucket: bucket,
      bucketLimit: bucketLimit,
      preemptible: preemptible,
      flowTargetFrames: flowTargetFrames,
      demanded: demanded,
      task: task,
      highPrioritySinceMicros:
          priority >= highPriorityThreshold ? clock.nowMicros() : null,
    );
  }

  bool replace({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    required LaneTask task,
  }) {
    _active[key]?.token.cancel();
    _pending[key] = _createPending(
      key: key,
      priority: priority,
      bucket: bucket,
      bucketLimit: bucketLimit,
      task: task,
    );
    _requestPump();
    return true;
  }

  bool follow({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    required LaneTask task,
  }) {
    _pending[key] = _createPending(
      key: key,
      priority: priority,
      bucket: bucket,
      bucketLimit: bucketLimit,
      task: task,
    );
    _requestPump();
    return true;
  }

  bool cancelQueued(String key) => _pending.remove(key) != null;

  bool cancel(String key) {
    final queued = cancelQueued(key);
    final active = _active[key];
    active?.token.cancel();
    _notifyIdle();
    return queued || active != null;
  }

  void cancelAll() {
    _pending.clear();
    for (final active in _active.values) {
      active.token.cancel();
    }
    _notifyIdle();
  }

  Future<void> idle() {
    if (isIdle) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  Future<void> idleKeys(Iterable<String> keys) {
    final pendingKeys = keys.toSet();
    if (!_containsAny(pendingKeys)) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _keyIdleWaiters.add(_KeyIdleWaiter(pendingKeys, completer));
    return completer.future;
  }

  bool _containsAny(Set<String> keys) =>
      keys.any((key) => _pending.containsKey(key) || _active.containsKey(key));

  bool _pendingBucketAvailable(
    _Pending pending, {
    required bool handoff,
  }) {
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    if (bucket == null || limit == null) return true;
    final allowance = handoff ? 1 : 0;
    return (_activeByBucket[bucket] ?? 0) < limit + allowance &&
        (_transportLeasesByBucket[bucket] ?? 0) < limit + allowance;
  }

  bool _transportLeaseAvailableForPending(
    _Pending pending, {
    required bool handoff,
  }) {
    final allowance = handoff ? reservedHighPrioritySlots : 0;
    if (_transportLeasesActive >= maxActive + allowance) return false;
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    if (bucket == null || limit == null) return true;
    return (_transportLeasesByBucket[bucket] ?? 0) < limit + allowance;
  }

  void _pump() {
    while (true) {
      final handoffCapacity = maxActive + reservedHighPrioritySlots;
      final pendingEligible = _pending.values.where((pending) {
        if (_active.containsKey(pending.key) || !pending.demanded) return false;
        final highPriority = pending.priority >= highPriorityThreshold;
        final handoff = highPriority && _needsHandoff(pending);
        if (!handoff &&
            (_receivingActive >= maxActive ||
                _transportLeasesActive >= maxActive ||
                !_pendingBucketAvailable(pending, handoff: false))) {
          return false;
        }
        if (handoff &&
            (reservedHighPrioritySlots <= 0 ||
                _receivingActive >= handoffCapacity ||
                _transportLeasesActive >= handoffCapacity)) {
          return false;
        }
        return _pendingBucketAvailable(pending, handoff: handoff) &&
            _transportLeaseAvailableForPending(
              pending,
              handoff: handoff,
            );
      }).toList(growable: false);
      final resumeEligible = _active.entries.where((entry) {
        final task = entry.value;
        if (!task.resumeRequested ||
            task.responseReadPermitHeld ||
            !task.demanded ||
            task.token.cancelled) {
          return false;
        }
        final highPriority = task.priority >= highPriorityThreshold;
        final handoff = highPriority && _activeNeedsHandoff(task);
        if (!handoff &&
            (_receivingActive >= maxActive ||
                !_activeBucketAvailable(task, handoff: false))) {
          return false;
        }
        if (handoff &&
            (reservedHighPrioritySlots <= 0 ||
                _receivingActive >= handoffCapacity)) {
          return false;
        }
        return _activeBucketAvailable(task, handoff: handoff);
      }).toList(growable: false);

      _Pending? nextPending;
      if (pendingEligible.isNotEmpty) {
        nextPending = pendingEligible.reduce((a, b) {
          final priority = b.priority.compareTo(a.priority);
          if (priority != 0) return priority > 0 ? b : a;
          return a.seq <= b.seq ? a : b;
        });
      }
      MapEntry<String, _ActiveTask>? nextResume;
      if (resumeEligible.isNotEmpty) {
        nextResume = resumeEligible.reduce((a, b) {
          final priority = b.value.priority.compareTo(a.value.priority);
          if (priority != 0) return priority > 0 ? b : a;
          return a.value.resumeSeq <= b.value.resumeSeq ? a : b;
        });
      }

      if (nextPending == null && nextResume == null) {
        // A live current response that only needs its body-read permit back is
        // the cheapest authoritative high-priority request. Resolve that
        // before considering destructive admission of a new high-priority
        // task; response retention and current read-permit authority must not
        // compete through a second scheduler policy.
        final blockedResume = _highestBlockedHighPriorityResume();
        if (blockedResume != null &&
            _preemptLowestRunningForResume(blockedResume)) {
          break;
        }
        if (_reclaimInactiveTransportLeaseForDemand()) {
          break;
        }
        final blockedHighPriority = _highestBlockedHighPriorityPending();
        if (blockedHighPriority != null) {
          if (!_preemptLowestRunningFor(blockedHighPriority)) {
            _schedulePreemptionCandidateWake(blockedHighPriority);
          }
        }
        break;
      }

      final resumeWins = nextResume != null &&
          (nextPending == null ||
              nextResume.value.priority > nextPending.priority ||
              (nextResume.value.priority == nextPending.priority &&
                  nextResume.value.resumeSeq <= nextPending.seq));
      if (resumeWins) {
        _grantResponseReadPermit(nextResume!.key, nextResume.value);
        continue;
      }

      final next = nextPending!;
      _pending.remove(next.key);
      late CancelToken token;
      token = CancelToken(
        priority: next.priority,
        flowTargetFrames: next.flowTargetFrames,
        demanded: next.demanded,
        acquireResponseReadPermit: () =>
            _acquireResponseReadPermit(next.key, token),
        releaseResponseReadPermit: (responseRetained) =>
            _releaseResponseReadPermit(
              next.key,
              token,
              responseRetained: responseRetained,
            ),
        clock: clock,
      );
      _active[next.key] = _ActiveTask(
        token: token,
        bucket: next.bucket,
        bucketLimit: next.bucketLimit,
        priority: next.priority,
        preemptible: next.preemptible,
        flowTargetFrames: next.flowTargetFrames,
        demanded: next.demanded,
        transportLeaseHeld: true,
        responseReadPermitHeld: true,
        responseRetainedWhilePermitReleased: false,
        resumeSeq: _seq++,
      );
      _incrementTransportLease(next.bucket);
      _incrementResponseReadPermit(next.bucket);
      unawaited(
        Future<void>.sync(() => next.task(token)).catchError(
          (Object error, StackTrace stack) {
            onError?.call(next.key, error, stack);
          },
        ).whenComplete(() {
          final removed = _active.remove(next.key);
          if (removed != null) {
            final waiter = removed.resumeCompleter;
            if (waiter != null && !waiter.isCompleted) waiter.complete();
            if (removed.responseReadPermitHeld) {
              _decrementResponseReadPermit(removed.bucket);
            }
            if (removed.transportLeaseHeld) {
              _decrementTransportLease(removed.bucket);
            }
            removed.token.dispose();
          }
          _requestPump();
          _notifyIdle();
        }),
      );
    }
    _notifyIdle();
  }

  void _incrementResponseReadPermit(String? bucket) {
    _receivingActive += 1;
    if (bucket != null) {
      _activeByBucket[bucket] = (_activeByBucket[bucket] ?? 0) + 1;
    }
  }

  void _decrementResponseReadPermit(String? bucket) {
    _receivingActive = math.max(0, _receivingActive - 1);
    if (bucket == null) return;
    final remaining = (_activeByBucket[bucket] ?? 1) - 1;
    if (remaining <= 0) {
      _activeByBucket.remove(bucket);
    } else {
      _activeByBucket[bucket] = remaining;
    }
  }

  void _incrementTransportLease(String? bucket) {
    _transportLeasesActive += 1;
    if (bucket != null) {
      _transportLeasesByBucket[bucket] =
          (_transportLeasesByBucket[bucket] ?? 0) + 1;
    }
  }

  void _decrementTransportLease(String? bucket) {
    _transportLeasesActive = math.max(0, _transportLeasesActive - 1);
    if (bucket == null) return;
    final remaining = (_transportLeasesByBucket[bucket] ?? 1) - 1;
    if (remaining <= 0) {
      _transportLeasesByBucket.remove(bucket);
    } else {
      _transportLeasesByBucket[bucket] = remaining;
    }
  }

  void _releaseResponseReadPermit(
    String key,
    CancelToken token, {
    required bool responseRetained,
  }) {
    final task = _active[key];
    if (task == null || !identical(task.token, token) ||
        !task.responseReadPermitHeld || token.cancelled) {
      return;
    }
    task
      ..responseReadPermitHeld = false
      ..responseRetainedWhilePermitReleased = responseRetained
      ..resumeRequested = false
      ..parkedSeq = responseRetained ? _parkSeq++ : task.parkedSeq;
    final waiter = task.resumeCompleter;
    task.resumeCompleter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _decrementResponseReadPermit(task.bucket);
    if (!responseRetained && task.transportLeaseHeld) {
      task.transportLeaseHeld = false;
      _decrementTransportLease(task.bucket);
    }
    _requestPump();
  }

  Future<void> _acquireResponseReadPermit(
    String key,
    CancelToken token,
  ) async {
    final task = _active[key];
    if (task == null || !identical(task.token, token)) {
      token.throwIfCancelled();
      return;
    }
    if (task.responseReadPermitHeld) return;
    task
      ..resumeRequested = true
      ..resumeSeq = _seq++;
    final waiter = task.resumeCompleter ??= Completer<void>();
    _requestPump();
    await Future.any<void>(<Future<void>>[
      waiter.future,
      token.whenCancelled,
    ]);
    token.throwIfCancelled();
  }

  void _grantResponseReadPermit(String key, _ActiveTask task) {
    if (task.responseReadPermitHeld || !task.transportLeaseHeld ||
        !task.resumeRequested || !task.demanded || task.token.cancelled ||
        _active[key] != task) {
      return;
    }
    task
      ..responseReadPermitHeld = true
      ..responseRetainedWhilePermitReleased = false
      ..resumeRequested = false;
    _incrementResponseReadPermit(task.bucket);
    final waiter = task.resumeCompleter;
    task.resumeCompleter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  bool _reclaimInactiveTransportLeaseForDemand() {
    if (_hasBodyPermitPreemptionInFlight || _hasRetentionEvictionInFlight) {
      return false;
    }
    _Pending? incoming;
    for (final pending in _pending.values) {
      if (!pending.demanded ||
          _active.containsKey(pending.key) ||
          _transportLeaseAvailableForPending(pending, handoff: false)) {
        continue;
      }
      if (incoming == null ||
          pending.priority > incoming.priority ||
          (pending.priority == incoming.priority &&
              pending.seq < incoming.seq)) {
        incoming = pending;
      }
    }
    if (incoming == null) return false;

    final bucket = incoming.bucket;
    final limit = incoming.bucketLimit;
    final bucketFull = bucket != null &&
        limit != null &&
        (_transportLeasesByBucket[bucket] ?? 0) >= limit;
    MapEntry<String, _ActiveTask>? victim;
    for (final entry in _active.entries) {
      final task = entry.value;
      if (!task.transportLeaseHeld ||
          task.responseReadPermitHeld ||
          !task.responseRetainedWhilePermitReleased ||
          task.demanded ||
          task.token.cancelled) {
        continue;
      }
      if (bucketFull && task.bucket != bucket) continue;
      if (victim == null ||
          _inactiveParkedVictimBefore(task, victim.value)) {
        victim = entry;
      }
    }
    if (victim == null) return false;
    final task = victim.value;
    final rank = _policyRank(task, basePriority: task.priority);
    task.token.cancelForRetentionEviction(
      TaskRetentionEvictionSnapshot(
        basePriority: task.priority,
        retentionPriority: rank.effectivePriority,
        retentionBonus: rank.retentionBonus,
        restartCostElapsedMicros: rank.restartCostElapsedMicros,
        restartCostBytes: rank.restartCostBytes,
        reason: 'inactive-transport-lease-reclaim',
      ),
    );
    return true;
  }

  bool _inactiveParkedVictimBefore(_ActiveTask a, _ActiveTask b) {
    if (a.resumeRequested != b.resumeRequested) return !a.resumeRequested;
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.parkedSeq < b.parkedSeq;
  }

  bool _activeBucketAvailable(_ActiveTask task, {required bool handoff}) {
    final bucket = task.bucket;
    final limit = task.bucketLimit;
    if (bucket == null || limit == null) return true;
    final allowance = handoff ? 1 : 0;
    return (_activeByBucket[bucket] ?? 0) < limit + allowance;
  }

  bool get _hasBodyPermitPreemptionInFlight => _active.values.any(
        (task) =>
            task.token.cancelled && task.token.preemptionSnapshot != null,
      );

  bool get _hasRetentionEvictionInFlight => _active.values.any(
        (task) => task.token.cancelled &&
            task.token.retentionEvictionSnapshot != null,
      );

  int _preemptionCandidateAgeMicros(_Pending pending) {
    final since = pending.highPrioritySinceMicros;
    if (since == null) return 0;
    return (clock.nowMicros() - since).clamp(0, 1 << 62).toInt();
  }

  bool _preemptionCandidateReady(_Pending pending) {
    if (preemptionCandidateGrace.inMicroseconds <= 0) return true;
    return _preemptionCandidateAgeMicros(pending) >=
        preemptionCandidateGrace.inMicroseconds;
  }

  void _schedulePreemptionCandidateWake(_Pending pending) {
    if (preemptionCandidateGrace.inMicroseconds <= 0) return;
    final since = pending.highPrioritySinceMicros;
    if (since == null) return;
    final now = clock.nowMicros();
    final eligibleAt = since + preemptionCandidateGrace.inMicroseconds;
    if (eligibleAt <= now) return;
    final scheduledAt = _preemptionWakeAtMicros;
    if (scheduledAt != null && scheduledAt <= eligibleAt) return;
    _preemptionWake?.cancel();
    _preemptionWakeAtMicros = eligibleAt;
    _preemptionWake = Timer(
      Duration(microseconds: math.max(1, eligibleAt - now)),
      () {
        _preemptionWake = null;
        _preemptionWakeAtMicros = null;
        _requestPump();
      },
    );
  }

  _Pending? _highestBlockedHighPriorityPending() {
    _Pending? highest;
    for (final pending in _pending.values) {
      if (_active.containsKey(pending.key) ||
          pending.priority < highPriorityThreshold ||
          !_needsHandoff(pending)) {
        continue;
      }
      if (highest == null ||
          pending.priority > highest.priority ||
          (pending.priority == highest.priority &&
              pending.seq < highest.seq)) {
        highest = pending;
      }
    }
    return highest;
  }

  bool _needsHandoff(_Pending pending) {
    if (_receivingActive >= maxActive ||
        _transportLeasesActive >= maxActive) {
      return true;
    }
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    if (bucket == null || limit == null) return false;
    return (_activeByBucket[bucket] ?? 0) >= limit ||
        (_transportLeasesByBucket[bucket] ?? 0) >= limit;
  }

  bool _activeNeedsHandoff(_ActiveTask task) {
    if (_receivingActive >= maxActive) return true;
    final bucket = task.bucket;
    final limit = task.bucketLimit;
    return bucket != null &&
        limit != null &&
        (_activeByBucket[bucket] ?? 0) >= limit;
  }

  MapEntry<String, _ActiveTask>? _highestBlockedHighPriorityResume() {
    MapEntry<String, _ActiveTask>? highest;
    for (final entry in _active.entries) {
      final task = entry.value;
      if (!task.resumeRequested || task.responseReadPermitHeld ||
          task.token.cancelled || task.priority < highPriorityThreshold ||
          !_activeNeedsHandoff(task)) {
        continue;
      }
      if (highest == null || task.priority > highest.value.priority ||
          (task.priority == highest.value.priority &&
              task.resumeSeq < highest.value.resumeSeq)) {
        highest = entry;
      }
    }
    return highest;
  }

  bool _preemptLowestRunningForResume(
    MapEntry<String, _ActiveTask> incoming,
  ) {
    if (_hasBodyPermitPreemptionInFlight) return false;
    final incomingTask = incoming.value;
    final incomingBucket = incomingTask.bucket;
    final incomingBucketLimit = incomingTask.bucketLimit;
    final bucketFull = incomingBucket != null &&
        incomingBucketLimit != null &&
        (_activeByBucket[incomingBucket] ?? 0) >= incomingBucketLimit;
    _ActiveTask? lowest;
    var lowestRetentionPriority = 1 << 30;
    for (final task in _active.values) {
      if (!task.responseReadPermitHeld || identical(task, incomingTask) ||
          !task.preemptible || task.token.cancelled) continue;
      if (bucketFull && task.bucket != incomingBucket) continue;
      final rank = _policyRank(task, basePriority: task.priority);
      if (!incomingOutranks(incomingTask.priority, rank)) continue;
      if (lowest == null || rank.effectivePriority < lowestRetentionPriority) {
        lowest = task;
        lowestRetentionPriority = rank.effectivePriority;
      }
    }
    if (lowest == null) return false;
    final elapsed = lowest.token.restartCostElapsedMicros;
    final bytes = lowest.token.restartCostBytes;
    final bonus = lowestRetentionPriority - lowest.priority;
    lowest.token.cancelForPreemption(
      TaskPreemptionSnapshot(
        incomingPriority: incomingTask.priority,
        basePriority: lowest.priority,
        retentionPriority: lowestRetentionPriority,
        retentionBonus: bonus,
        restartCostElapsedMicros: elapsed,
        restartCostBytes: bytes,
        incomingWaitMicros: 0,
        reason: 'high-priority',
      ),
    );
    return true;
  }

  bool _preemptLowestRunningFor(_Pending incoming) {
    if (_hasBodyPermitPreemptionInFlight ||
        !_preemptionCandidateReady(incoming)) {
      return false;
    }
    final incomingBucket = incoming.bucket;
    final incomingBucketLimit = incoming.bucketLimit;
    final readBucketFull = incomingBucket != null &&
        incomingBucketLimit != null &&
        (_activeByBucket[incomingBucket] ?? 0) >= incomingBucketLimit;
    final transportBucketFull = incomingBucket != null &&
        incomingBucketLimit != null &&
        (_transportLeasesByBucket[incomingBucket] ?? 0) >=
            incomingBucketLimit;
    final readFull = _receivingActive >= maxActive || readBucketFull;
    final transportFull =
        _transportLeasesActive >= maxActive || transportBucketFull;
    _ActiveTask? lowest;
    var lowestRetentionPriority = 1 << 30;
    for (final task in _active.values) {
      if (!task.preemptible || task.token.cancelled) continue;
      if (readFull && !task.responseReadPermitHeld) continue;
      if (transportFull && !task.transportLeaseHeld) continue;
      if ((readBucketFull || transportBucketFull) &&
          task.bucket != incomingBucket) {
        continue;
      }
      final rank = _policyRank(task, basePriority: task.priority);
      if (!incomingOutranks(incoming.priority, rank)) continue;
      if (lowest == null || rank.effectivePriority < lowestRetentionPriority) {
        lowest = task;
        lowestRetentionPriority = rank.effectivePriority;
      }
    }
    if (lowest == null) return false;
    final elapsed = lowest.token.restartCostElapsedMicros;
    final bytes = lowest.token.restartCostBytes;
    final bonus = lowestRetentionPriority - lowest.priority;
    lowest.token.cancelForPreemption(
      TaskPreemptionSnapshot(
        incomingPriority: incoming.priority,
        basePriority: lowest.priority,
        retentionPriority: lowestRetentionPriority,
        retentionBonus: bonus,
        restartCostElapsedMicros: elapsed,
        restartCostBytes: bytes,
        incomingWaitMicros: _preemptionCandidateAgeMicros(incoming),
        reason: 'high-priority',
      ),
    );
    return true;
  }

  NetPolicyRank _policyRank(
    _ActiveTask task, {
    required int basePriority,
  }) {
    final elapsed = task.token.restartCostElapsedMicros;
    final bytes = task.token.restartCostBytes;
    if (elapsed <= 0 && bytes <= 0) {
      return NetPolicyRank(
        basePriority: basePriority,
        effectivePriority: basePriority,
        retentionBonus: 0,
        restartCostElapsedMicros: elapsed,
        restartCostBytes: bytes,
      );
    }

    const timeScaleMicros = 5 * 1000 * 1000;
    const byteScale = 4 * 1024 * 1024;
    const timeWeight = 0.60;
    const trafficWeight = 0.40;
    const boundedMaxBonus = 100.0;
    const headroomWeight = 2.0 / 3.0;
    final timeCost = 1 - math.exp(-elapsed / timeScaleMicros);
    final trafficCost = 1 - math.exp(-bytes / byteScale);
    final costScore =
        (timeWeight * timeCost + trafficWeight * trafficCost)
            .clamp(0.0, 1.0);
    final bounded = basePriority + (boundedMaxBonus * costScore).round();

    int effectivePriority;
    if (highPriorityThreshold >= 1 << 29) {
      effectivePriority = bounded;
    } else {
      // Keep restart-cost protection below the scheduler's current-safe
      // ceiling. A current-ranked candidate can therefore always displace a
      // saturated lower-ranked incumbent by the normal preemption margin.
      final currentSafeCeiling =
          math.max(basePriority, highPriorityThreshold - preemptionThreshold);
      final boundedSafe = math.min(bounded, currentSafeCeiling);
      final headroom = currentSafeCeiling - basePriority;
      final headroomRetention =
          basePriority + (headroom * costScore).round();
      final blended = boundedSafe +
          ((headroomRetention - boundedSafe) * headroomWeight).round();
      effectivePriority = math.min(
        math.max(blended, basePriority),
        currentSafeCeiling,
      );
    }
    return NetPolicyRank(
      basePriority: basePriority,
      effectivePriority: effectivePriority,
      retentionBonus: effectivePriority - basePriority,
      restartCostElapsedMicros: elapsed,
      restartCostBytes: bytes,
    );
  }


  void _notifyIdle() {
    for (final waiter in List<_KeyIdleWaiter>.of(_keyIdleWaiters)) {
      if (!_containsAny(waiter.keys)) {
        _keyIdleWaiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete();
        }
      }
    }
    if (!isIdle) {
      return;
    }
    _preemptionWake?.cancel();
    _preemptionWake = null;
    _preemptionWakeAtMicros = null;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}

final class _Pending {
  _Pending({
    required this.key,
    required this.priority,
    required this.seq,
    required this.bucket,
    required this.bucketLimit,
    required this.preemptible,
    required this.flowTargetFrames,
    required this.demanded,
    required this.task,
    required this.highPrioritySinceMicros,
  });

  final String key;
  int priority;
  final int seq;
  String? bucket;
  int? bucketLimit;
  bool preemptible;
  int flowTargetFrames;
  bool demanded;
  LaneTask task;
  int? highPrioritySinceMicros;
}

final class _ActiveTask {
  _ActiveTask({
    required this.token,
    required this.bucket,
    required this.bucketLimit,
    required this.priority,
    required this.preemptible,
    required this.flowTargetFrames,
    required this.demanded,
    required this.transportLeaseHeld,
    required this.responseReadPermitHeld,
    required this.responseRetainedWhilePermitReleased,
    required this.resumeSeq,
  });

  final CancelToken token;
  final String? bucket;
  final int? bucketLimit;
  int priority;
  bool preemptible;
  int flowTargetFrames;
  bool demanded;
  bool transportLeaseHeld;
  bool responseReadPermitHeld;
  bool responseRetainedWhilePermitReleased;
  bool resumeRequested = false;
  int resumeSeq;
  int parkedSeq = 0;
  Completer<void>? resumeCompleter;
}

final class _KeyIdleWaiter {
  const _KeyIdleWaiter(this.keys, this.completer);

  final Set<String> keys;
  final Completer<void> completer;
}
