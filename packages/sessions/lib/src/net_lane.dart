import 'dart:async';

import 'package:domain/domain.dart';

typedef NetTask = Future<void> Function(CancelToken token);
typedef LaneError = void Function(String key, Object error, StackTrace stack);

final class CancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
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

final class NetLane {
  NetLane({
    required this.maxActive,
    this.onError,
  }) : assert(maxActive > 0);

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
    required NetTask task,
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
      final next = _pending.values.reduce((a, b) {
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
  final NetTask task;
}
