import 'dart:async';

import 'package:domain/domain.dart';

typedef LaneTask = Future<void> Function(CancelToken token);
typedef LaneError = void Function(String key, Object error, StackTrace stack);

final class CancelToken {
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get cancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledSignal.future;

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
  NetLane({required int maxActive, LaneError? onError})
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

  bool submitRanked({
    required String key,
    required int priority,
    required String bucket,
    required int bucketLimit,
    required LaneTask task,
  }) =>
      _core.submit(
        key: key,
        priority: priority,
        bucket: bucket,
        bucketLimit: bucketLimit,
        task: task,
      );

  Future<void> idleKeys(Iterable<String> keys) => _core.idleKeys(keys);

  int activeForBucket(String bucket) => _core.activeForBucket(bucket);

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
  _Lane({required this.maxActive, this.onError}) : assert(maxActive > 0);

  final int maxActive;
  final LaneError? onError;
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, _ActiveTask> _active = <String, _ActiveTask>{};
  final Map<String, int> _activeByBucket = <String, int>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  final List<_KeyIdleWaiter> _keyIdleWaiters = <_KeyIdleWaiter>[];
  int _seq = 0;

  int get queued => _pending.length;
  int get active => _active.length;
  bool get isIdle => _pending.isEmpty && _active.isEmpty;

  int activeForBucket(String bucket) => _activeByBucket[bucket] ?? 0;

  bool submit({
    required String key,
    required int priority,
    String? bucket,
    int? bucketLimit,
    required LaneTask task,
  }) {
    if (_active.containsKey(key)) {
      return false;
    }
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      bucket: bucket,
      bucketLimit: bucketLimit,
      task: task,
    );
    _pump();
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

  bool _bucketAvailable(_Pending pending) {
    final bucket = pending.bucket;
    final limit = pending.bucketLimit;
    if (bucket == null || limit == null) return true;
    return (_activeByBucket[bucket] ?? 0) < limit;
  }

  void _pump() {
    while (_active.length < maxActive && _pending.isNotEmpty) {
      final eligible = _pending.values
          .where(
            (pending) =>
                !_active.containsKey(pending.key) && _bucketAvailable(pending),
          )
          .toList(growable: false);
      if (eligible.isEmpty) {
        break;
      }
      final next = eligible.reduce((a, b) {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) {
          return priority > 0 ? b : a;
        }
        return a.seq <= b.seq ? a : b;
      });
      _pending.remove(next.key);
      final token = CancelToken();
      _active[next.key] = _ActiveTask(token: token, bucket: next.bucket);
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
  const _Pending({
    required this.key,
    required this.priority,
    required this.seq,
    required this.bucket,
    required this.bucketLimit,
    required this.task,
  });

  final String key;
  final int priority;
  final int seq;
  final String? bucket;
  final int? bucketLimit;
  final LaneTask task;
}

final class _ActiveTask {
  const _ActiveTask({required this.token, required this.bucket});

  final CancelToken token;
  final String? bucket;
}

final class _KeyIdleWaiter {
  const _KeyIdleWaiter(this.keys, this.completer);

  final Set<String> keys;
  final Completer<void> completer;
}
