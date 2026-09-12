import 'dart:async';

import 'package:domain/domain.dart';

/// Process-composition scheduler for persistent artifact read quanta.
///
/// Reader sessions keep their normal download window and network lane. This
/// scheduler only prevents multiple sessions from multiplying local artifact
/// reads against the same persistent store. Foreground streams may keep their
/// lease while they remain current/transition. Background streams release the
/// lease after each chunk so pending foreground work can take the next quantum
/// without cancelling or reopening the artifact stream.
final class ArtifactCacheReadScheduler {
  ArtifactCacheReadScheduler({
    this.maxActive = 5,
    this.foregroundPriority = 900,
    this.maxBackgroundWhileForeground = 1,
  })  : assert(maxActive >= 2),
        assert(maxBackgroundWhileForeground >= 0),
        assert(maxBackgroundWhileForeground < maxActive);

  final int maxActive;
  final int foregroundPriority;
  final int maxBackgroundWhileForeground;

  final List<_PendingRead> _pending = <_PendingRead>[];
  final List<_PendingPressureRelief> _pressureReliefWaiters =
      <_PendingPressureRelief>[];
  int _active = 0;
  int _activeForeground = 0;
  int _activeBackground = 0;
  int _foregroundPressureHolds = 0;
  int _pressureReservationSequence = 0;
  final Set<int> _pendingFirstForegroundReservations = <int>{};
  int _sequence = 0;

  int get activeCount => _active;
  int get activeForegroundCount => _activeForeground;
  int get activeBackgroundCount => _activeBackground;
  int get pendingCount => _pending.length;
  bool get foregroundPressure => _hasForegroundPressure;
  int get foregroundPressureHoldCount => _foregroundPressureHolds;

  /// Completes once no foreground read is active, queued, or explicitly held.
  ///
  /// Storage-write scheduling uses this only at bounded I/O quantum boundaries;
  /// it does not consume a local-read slot or affect unrelated network work.
  Future<void> waitForForegroundRelief({TaskControl? control}) {
    if (control?.cancelled == true) {
      return Future<void>.error(const Failure(
        code: ErrorCode.cancelled,
        message: 'storage write was cancelled while yielding to local reads',
      ));
    }
    if (!_hasForegroundPressure) return Future<void>.value();
    final completer = Completer<void>();
    final pending = _PendingPressureRelief(
      completer: completer,
      control: control,
    );
    _pressureReliefWaiters.add(pending);
    if (control != null) {
      unawaited(
        control.whenCancelled.then<void>((_) {
          if (completer.isCompleted ||
              !_pressureReliefWaiters.remove(pending)) {
            return;
          }
          completer.completeError(const Failure(
            code: ErrorCode.cancelled,
            message: 'storage write was cancelled while yielding to local reads',
          ));
        }),
      );
    }
    return completer.future;
  }

  /// Holds foreground pressure without consuming a read slot.
  ///
  /// Reader startup uses this while the current output is not yet presented
  /// with its successor watermark. Background reads remain queued or limited,
  /// but the current artifact stream still has access to the full read pool.
  ArtifactCachePressureLease holdForegroundPressure({
    bool reserveFirstForegroundQuantum = false,
  }) {
    _foregroundPressureHolds++;
    final reservation = reserveFirstForegroundQuantum
        ? _pressureReservationSequence++
        : null;
    if (reservation != null) {
      _pendingFirstForegroundReservations.add(reservation);
    }
    _pump();
    var released = false;
    return ArtifactCachePressureLease._(() {
      if (released) return;
      released = true;
      if (_foregroundPressureHolds > 0) {
        _foregroundPressureHolds--;
      }
      if (reservation != null) {
        _pendingFirstForegroundReservations.remove(reservation);
      }
      _pump();
    });
  }

  Future<ArtifactCacheReadLease> acquire({
    required int Function() priority,
    TaskControl? control,
    bool allowBackgroundDuringForegroundPressure = true,
  }) {
    if (control?.cancelled == true) {
      return Future<ArtifactCacheReadLease>.error(const Failure(
        code: ErrorCode.cancelled,
        message: 'artifact cache read was cancelled while waiting for a lease',
      ));
    }
    final currentPriority = priority();
    final foreground = _isForeground(currentPriority);
    if (_canStart(
      foreground,
      allowBackgroundDuringForegroundPressure:
          allowBackgroundDuringForegroundPressure,
    )) {
      return Future<ArtifactCacheReadLease>.value(
        _start(foreground, currentPriority),
      );
    }
    final completer = Completer<ArtifactCacheReadLease>();
    final pending = _PendingRead(
      priority: priority,
      sequence: _sequence++,
      completer: completer,
      control: control,
      allowBackgroundDuringForegroundPressure:
          allowBackgroundDuringForegroundPressure,
    );
    _pending.add(pending);
    if (control != null) {
      unawaited(
        control.whenCancelled.then<void>((_) {
          if (completer.isCompleted || !_pending.remove(pending)) return;
          completer.completeError(const Failure(
            code: ErrorCode.cancelled,
            message:
                'artifact cache read was cancelled while waiting for a lease',
          ));
          _pump();
        }),
      );
    }
    _pump();
    return completer.future;
  }

  /// Re-evaluates pending demand priorities after the authoritative Reader plan
  /// changes. Active work is never cancelled; a background stream is
  /// reclassified when it requests its next chunk quantum.
  void refresh() => _pump();

  bool _isForeground(int priority) => priority >= foregroundPriority;

  bool get _hasForegroundPressure {
    if (_foregroundPressureHolds > 0 || _activeForeground > 0) {
      return true;
    }
    for (final pending in _pending) {
      if (_isForeground(pending.currentPriority)) {
        return true;
      }
    }
    return false;
  }

  bool _canStart(
    bool foreground, {
    required bool allowBackgroundDuringForegroundPressure,
  }) {
    if (_active >= maxActive) return false;
    if (foreground) return true;
    if (_pendingFirstForegroundReservations.isNotEmpty) return false;
    if (_hasForegroundPressure) {
      if (!allowBackgroundDuringForegroundPressure) return false;
      return _activeBackground < maxBackgroundWhileForeground;
    }
    return true;
  }

  ArtifactCacheReadLease _start(bool foreground, int priority) {
    _active++;
    if (foreground) {
      _activeForeground++;
    } else {
      _activeBackground++;
    }
    final satisfiedReservations = foreground
        ? Set<int>.of(_pendingFirstForegroundReservations)
        : const <int>{};
    var released = false;
    return ArtifactCacheReadLease._(
      priority: priority,
      foreground: foreground,
      release: () {
        if (released) return;
        released = true;
        _active--;
        if (foreground) {
          _activeForeground--;
          _pendingFirstForegroundReservations.removeAll(satisfiedReservations);
        } else {
          _activeBackground--;
        }
        _pump();
      },
    );
  }

  void _pump() {
    _completePressureReliefWaitersIfIdle();
    while (_pending.isNotEmpty && _active < maxActive) {
      for (final pending in _pending
          .where((pending) => pending.control?.cancelled == true)
          .toList(growable: false)) {
        _pending.remove(pending);
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(const Failure(
            code: ErrorCode.cancelled,
            message:
                'artifact cache read was cancelled while waiting for a lease',
          ));
        }
      }
      if (_pending.isEmpty) break;
      _pending.sort((left, right) {
        final priority = right.currentPriority.compareTo(left.currentPriority);
        if (priority != 0) return priority;
        return left.sequence.compareTo(right.sequence);
      });
      var selected = -1;
      for (var index = 0; index < _pending.length; index++) {
        final pending = _pending[index];
        final priority = pending.currentPriority;
        if (_canStart(
          _isForeground(priority),
          allowBackgroundDuringForegroundPressure:
              pending.allowBackgroundDuringForegroundPressure,
        )) {
          selected = index;
          break;
        }
      }
      if (selected < 0) return;
      final pending = _pending.removeAt(selected);
      if (!pending.completer.isCompleted) {
        final priority = pending.currentPriority;
        pending.completer.complete(
          _start(_isForeground(priority), priority),
        );
      }
    }
  }

  void _completePressureReliefWaitersIfIdle() {
    if (_hasForegroundPressure || _pressureReliefWaiters.isEmpty) return;
    final waiters = _pressureReliefWaiters.toList(growable: false);
    _pressureReliefWaiters.clear();
    for (final pending in waiters) {
      if (pending.completer.isCompleted) continue;
      if (pending.control?.cancelled == true) {
        pending.completer.completeError(const Failure(
          code: ErrorCode.cancelled,
          message: 'storage write was cancelled while yielding to local reads',
        ));
      } else {
        pending.completer.complete();
      }
    }
  }
}

final class ArtifactCachePressureLease {
  ArtifactCachePressureLease._(this._release);

  final void Function() _release;

  void release() => _release();
}

final class ArtifactCacheReadLease {
  ArtifactCacheReadLease._({
    required this.priority,
    required this.foreground,
    required void Function() release,
  }) : _release = release;

  final int priority;
  final bool foreground;
  final void Function() _release;

  void release() => _release();
}

final class _PendingRead {
  const _PendingRead({
    required this.priority,
    required this.sequence,
    required this.completer,
    required this.control,
    required this.allowBackgroundDuringForegroundPressure,
  });

  final int Function() priority;
  final int sequence;
  final Completer<ArtifactCacheReadLease> completer;
  final TaskControl? control;
  final bool allowBackgroundDuringForegroundPressure;

  int get currentPriority => priority();
}

final class _PendingPressureRelief {
  const _PendingPressureRelief({
    required this.completer,
    required this.control,
  });

  final Completer<void> completer;
  final TaskControl? control;
}
