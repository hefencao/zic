import 'dart:async';
import 'dart:math' as math;

import 'package:domain/domain.dart';

typedef LaneTask = Future<void> Function(CancelToken token);
typedef LaneError = void Function(String key, Object error, StackTrace stack);

final class CancelToken implements TaskControl {
  CancelToken({int priority = 0}) : _priority = priority;

  bool _cancelled = false;
  int _priority;
  final Completer<void> _cancelledSignal = Completer<void>();

  @override
  bool get cancelled => _cancelled;
  @override
  Future<void> get whenCancelled => _cancelledSignal.future;
  @override
  int get priority => _priority;

  void updatePriority(int priority) {
    _priority = priority;
  }

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
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


abstract interface class TaskLane {
  int get maxActive;
  int get queued;
  int get active;
  bool get isIdle;

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
  bool submit({required String key, required int priority, required LaneTask task}) =>
      _core.submit(key: key, priority: priority, task: task);

  bool submitRanked({
    required String key,
    required int priority,
    required String bucket,
    required int bucketLimit,
    bool preemptible = true,
    required LaneTask task,
  }) =>
      _core.submit(
        key: key,
        priority: priority,
        bucket: bucket,
        bucketLimit: bucketLimit,
        preemptible: preemptible,
        task: task,
      );

  Future<void> idleKeys(Iterable<String> keys) => _core.idleKeys(keys);

  int activeForBucket(String bucket) => _core.activeForBucket(bucket);
  int get handoffActive => _core.handoffActive;
  int? priorityOf(String key) => _core.priorityOf(key);
  bool isActive(String key) => _core.isActive(key);
  bool updatePriority(String key, int priority) =>
      _core.updatePriority(key, priority);

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
  DecodeLane({required int maxActive, LaneError? onError})
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
  UploadLane({required int maxActive, LaneError? onError})
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
    this.onError,
  })  : assert(maxActive > 0),
        assert(reservedHighPrioritySlots >= 0),
        assert(preemptionThreshold >= 0);

  final int maxActive;
  final int reservedHighPrioritySlots;
  final int highPriorityThreshold;
  final int preemptionThreshold;
  final LaneError? onError;
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, _ActiveTask> _active = <String, _ActiveTask>{};
  final Map<String, int> _activeByBucket = <String, int>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  final List<_KeyIdleWaiter> _keyIdleWaiters = <_KeyIdleWaiter>[];
  int _seq = 0;

  int get queued => _pending.length;
  int get active => _active.length;
  int get handoffActive {
    var excess = math.max(0, active - maxActive);
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
    }
    return excess;
  }
  bool get isIdle => _pending.isEmpty && _active.isEmpty;

  int activeForBucket(String bucket) => _activeByBucket[bucket] ?? 0;
  bool isActive(String key) => _active.containsKey(key);
  int? priorityOf(String key) =>
      _active[key]?.priority ?? _pending[key]?.priority;

  bool submit({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    bool preemptible = true,
    required LaneTask task,
  }) {
    final activeTask = _active[key];
    if (activeTask != null) {
      final increased = priority > activeTask.priority;
      activeTask
        ..priority = priority
        ..preemptible = preemptible;
      activeTask.token.updatePriority(priority);
      if (increased) _pump();
      return false;
    }
    final pending = _pending[key];
    if (pending != null) {
      final increased = priority > pending.priority;
      pending
        ..priority = priority
        ..bucket = bucket
        ..bucketLimit = bucketLimit
        ..preemptible = preemptible
        ..task = task;
      if (increased) _pump();
      return false;
    }
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      bucket: bucket,
      bucketLimit: bucketLimit,
      preemptible: preemptible,
      task: task,
    );
    _pump();
    return true;
  }

  bool updatePriority(String key, int priority) {
    final activeTask = _active[key];
    if (activeTask != null) {
      final increased = priority > activeTask.priority;
      activeTask.priority = priority;
      activeTask.token.updatePriority(priority);
      if (increased) _pump();
      return true;
    }
    final pending = _pending[key];
    if (pending == null) return false;
    final increased = priority > pending.priority;
    pending.priority = priority;
    if (increased) _pump();
    return true;
  }

  bool replace({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    required LaneTask task,
  }) {
    _active[key]?.token.cancel();
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      bucket: bucket,
      bucketLimit: bucketLimit,
      preemptible: true,
      task: task,
    );
    _pump();
    return true;
  }

  bool follow({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    required LaneTask task,
  }) {
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      bucket: bucket,
      bucketLimit: bucketLimit,
      preemptible: true,
      task: task,
    );
    _pump();
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

  bool _bucketAvailable(_Pending pending, {required bool handoff}) {
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    if (bucket == null || limit == null) return true;
    final allowance = handoff ? 1 : 0;
    return (_activeByBucket[bucket] ?? 0) < limit + allowance;
  }

  void _pump() {
    while (_pending.isNotEmpty) {
      final running = _active.length;
      final handoffCapacity = maxActive + reservedHighPrioritySlots;
      final eligible = _pending.values.where((pending) {
        if (_active.containsKey(pending.key)) return false;
        final highPriority = pending.priority >= highPriorityThreshold;
        final handoff = highPriority && _needsHandoff(pending);
        if (!handoff &&
            (running >= maxActive ||
                !_bucketAvailable(pending, handoff: false))) {
          return false;
        }
        if (handoff &&
            (reservedHighPrioritySlots <= 0 || running >= handoffCapacity)) {
          return false;
        }
        return _bucketAvailable(pending, handoff: handoff);
      }).toList(growable: false);
      if (eligible.isEmpty) {
        final blockedHighPriority = _highestBlockedHighPriorityPending();
        if (blockedHighPriority != null) {
          // Match the VibeVenera handoff rule: once the single temporary
          // max+1 slot is occupied, a newer current page must still be able
          // to ask another lower-ranked running prefetch to unwind. We do
          // not start the blocked task until a real lane/bucket permit is
          // released, so the active bound and single-writer invariant stay
          // intact.
          _preemptLowestRunningFor(blockedHighPriority);
        }
        break;
      }
      final next = eligible.reduce((a, b) {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) {
          return priority > 0 ? b : a;
        }
        return a.seq <= b.seq ? a : b;
      });
      final handoff = _needsHandoff(next);
      if (handoff && !_preemptLowestRunningFor(next)) break;
      _pending.remove(next.key);
      final token = CancelToken(priority: next.priority);
      _active[next.key] = _ActiveTask(
        token: token,
        bucket: next.bucket,
        bucketLimit: next.bucketLimit,
        priority: next.priority,
        preemptible: next.preemptible,
      );
      final bucket = next.bucket;
      if (bucket != null) {
        _activeByBucket[bucket] = (_activeByBucket[bucket] ?? 0) + 1;
      }
      unawaited(
        Future<void>.sync(() => next.task(token)).catchError(
          (Object error, StackTrace stack) {
            onError?.call(next.key, error, stack);
          },
        ).whenComplete(() {
          final removed = _active.remove(next.key);
          final removedBucket = removed?.bucket;
          if (removedBucket != null) {
            final remaining = (_activeByBucket[removedBucket] ?? 1) - 1;
            if (remaining <= 0) {
              _activeByBucket.remove(removedBucket);
            } else {
              _activeByBucket[removedBucket] = remaining;
            }
          }
          _pump();
          _notifyIdle();
        }),
      );
    }
    _notifyIdle();
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
    if (_active.length >= maxActive) return true;
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    return bucket != null &&
        limit != null &&
        (_activeByBucket[bucket] ?? 0) >= limit;
  }

  bool _preemptLowestRunningFor(_Pending incoming) {
    final incomingBucket = incoming.bucket;
    final incomingBucketLimit = incoming.bucketLimit;
    final bucketFull = incomingBucket != null &&
        incomingBucketLimit != null &&
        (_activeByBucket[incomingBucket] ?? 0) >= incomingBucketLimit;
    _ActiveTask? lowest;
    for (final task in _active.values) {
      if (!task.preemptible || task.token.cancelled) continue;
      if (bucketFull && task.bucket != incomingBucket) continue;
      if (incoming.priority - task.priority < preemptionThreshold) continue;
      if (lowest == null || task.priority < lowest.priority) {
        lowest = task;
      }
    }
    if (lowest == null) return false;
    lowest.token.cancel();
    return true;
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
    required this.task,
  });

  final String key;
  int priority;
  final int seq;
  String? bucket;
  int? bucketLimit;
  bool preemptible;
  LaneTask task;
}

final class _ActiveTask {
  _ActiveTask({
    required this.token,
    required this.bucket,
    required this.bucketLimit,
    required this.priority,
    required this.preemptible,
  });

  final CancelToken token;
  final String? bucket;
  final int? bucketLimit;
  int priority;
  bool preemptible;
}

final class _KeyIdleWaiter {
  const _KeyIdleWaiter(this.keys, this.completer);

  final Set<String> keys;
  final Completer<void> completer;
}
