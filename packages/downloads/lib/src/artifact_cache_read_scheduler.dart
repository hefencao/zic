import 'dart:async';

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
  int _active = 0;
  int _activeForeground = 0;
  int _activeBackground = 0;
  int _foregroundPressureHolds = 0;
  int _sequence = 0;

  int get activeCount => _active;
  int get activeForegroundCount => _activeForeground;
  int get activeBackgroundCount => _activeBackground;
  int get pendingCount => _pending.length;
  bool get foregroundPressure => _hasForegroundPressure;
  int get foregroundPressureHoldCount => _foregroundPressureHolds;

  /// Holds foreground pressure without consuming a read slot.
  ///
  /// Reader startup uses this while the current output is not yet presented
  /// with its successor watermark. Background reads remain queued or limited,
  /// but the current artifact stream still has access to the full read pool.
  ArtifactCachePressureLease holdForegroundPressure() {
    _foregroundPressureHolds++;
    _pump();
    var released = false;
    return ArtifactCachePressureLease._(() {
      if (released) return;
      released = true;
      if (_foregroundPressureHolds > 0) {
        _foregroundPressureHolds--;
      }
      _pump();
    });
  }

  Future<ArtifactCacheReadLease> acquire({
    required int Function() priority,
  }) {
    final currentPriority = priority();
    final foreground = _isForeground(currentPriority);
    if (_canStart(foreground)) {
      return Future<ArtifactCacheReadLease>.value(
        _start(foreground, currentPriority),
      );
    }
    final completer = Completer<ArtifactCacheReadLease>();
    _pending.add(
      _PendingRead(
        priority: priority,
        sequence: _sequence++,
        completer: completer,
      ),
    );
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

  bool _canStart(bool foreground) {
    if (_active >= maxActive) return false;
    if (foreground) return true;
    if (_hasForegroundPressure) {
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
        } else {
          _activeBackground--;
        }
        _pump();
      },
    );
  }

  void _pump() {
    while (_pending.isNotEmpty && _active < maxActive) {
      _pending.sort((left, right) {
        final priority = right.currentPriority.compareTo(left.currentPriority);
        if (priority != 0) return priority;
        return left.sequence.compareTo(right.sequence);
      });
      var selected = -1;
      for (var index = 0; index < _pending.length; index++) {
        if (_canStart(_isForeground(_pending[index].currentPriority))) {
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
  });

  final int Function() priority;
  final int sequence;
  final Completer<ArtifactCacheReadLease> completer;

  int get currentPriority => priority();
}
