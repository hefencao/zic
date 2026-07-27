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
  Future<void> idle() => _core.idle();
}

final class _Lane {
  _Lane({required this.maxActive, this.onError}) : assert(maxActive > 0);

  final int maxActive;
  final LaneError? onError;
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, CancelToken> _active = <String, CancelToken>{};
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];
  int _seq = 0;

  int get queued => _pending.length;
  int get active => _active.length;
  bool get isIdle => _pending.isEmpty && _active.isEmpty;

  bool submit({
    required String key,
    required int priority,
    required LaneTask task,
  }) {
    if (_active.containsKey(key)) {
      return false;
    }
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      task: task,
    );
    _pump();
    return true;
  }

  bool replace({
    required String key,
    required int priority,
    required LaneTask task,
  }) {
    _active[key]?.cancel();
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      task: task,
    );
    _pump();
    return true;
  }

  bool follow({
    required String key,
    required int priority,
    required LaneTask task,
  }) {
    _pending[key] = _Pending(
      key: key,
      priority: priority,
      seq: _seq++,
      task: task,
    );
    _pump();
    return true;
  }

  bool cancelQueued(String key) => _pending.remove(key) != null;

  bool cancel(String key) {
    final queued = cancelQueued(key);
    final token = _active[key];
    token?.cancel();
    _notifyIdle();
    return queued || token != null;
  }

  Future<void> idle() {
    if (isIdle) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  void _pump() {
    while (_active.length < maxActive && _pending.isNotEmpty) {
      final eligible = _pending.values
          .where((pending) => !_active.containsKey(pending.key))
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
      _active[next.key] = token;
      unawaited(
        Future<void>.sync(() => next.task(token)).catchError(
          (Object error, StackTrace stack) {
            onError?.call(next.key, error, stack);
          },
        ).whenComplete(() {
          _active.remove(next.key);
          _pump();
          _notifyIdle();
        }),
      );
    }
    _notifyIdle();
  }

  void _notifyIdle() {
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
    required this.task,
  });

  final String key;
  final int priority;
  final int seq;
  final LaneTask task;
}
