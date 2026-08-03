import 'dart:async';

/// Process-composition scheduler for persistent artifact streams.
///
/// Reader sessions keep their normal download window and network lane. This
/// scheduler only prevents multiple sessions from multiplying local artifact
/// reads against the same persistent store. One slot is reserved for current
/// or transition work so background session copies cannot occupy every reader.
/// Pending work reads its authoritative demand priority again whenever the
/// scheduler is refreshed, allowing an existing transition/background stream
/// to become foreground without cancellation or a second artifact request.
final class ArtifactCacheReadScheduler {
  ArtifactCacheReadScheduler({
    this.maxActive = 5,
    this.foregroundPriority = 900,
  }) : assert(maxActive >= 2);

  final int maxActive;
  final int foregroundPriority;

  final List<_PendingRead> _pending = <_PendingRead>[];
  int _active = 0;
  int _activeBackground = 0;
  int _sequence = 0;

  int get activeCount => _active;
  int get pendingCount => _pending.length;

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
    return completer.future;
  }

  /// Re-evaluates pending demand priorities after the authoritative Reader plan
  /// changes. Active streams are never cancelled or reclassified.
  void refresh() => _pump();

  bool _isForeground(int priority) => priority >= foregroundPriority;

  bool _canStart(bool foreground) {
    if (_active >= maxActive) return false;
    if (foreground) return true;
    return _activeBackground < maxActive - 1;
  }

  ArtifactCacheReadLease _start(bool foreground, int priority) {
    _active++;
    if (!foreground) _activeBackground++;
    var released = false;
    return ArtifactCacheReadLease._(
      priority: priority,
      release: () {
        if (released) return;
        released = true;
        _active--;
        if (!foreground) _activeBackground--;
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

final class ArtifactCacheReadLease {
  ArtifactCacheReadLease._({
    required this.priority,
    required void Function() release,
  }) : _release = release;

  final int priority;
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
