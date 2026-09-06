import 'dart:async';

import 'errors.dart';

/// Cross-layer control plane for cancellable, priority-bearing work.
///
/// The scheduler owns implementations. Transport/source/runtime layers may
/// observe the signal but must not mutate scheduling policy themselves.
abstract interface class TaskControl {
  bool get cancelled;
  Future<void> get whenCancelled;
  int get priority;
}

/// Optional scheduler-owned notification for priority changes on active work.
///
/// Lower layers may use this only to keep an already-admitted operation in
/// sync with scheduler rank changes. It does not grant them authority to set
/// priority or create a second scheduler.
abstract interface class PriorityObservableTaskControl implements TaskControl {
  Stream<int> get priorityChanges;
}

/// Optional scheduler-owned reporting seam for transport open phases.
///
/// Lower layers may only report that the current open has entered a phase whose
/// own finite deadline is already proven. This does not let them set timeout
/// values, retry policy, priority or admission.
abstract interface class OpenPhaseReportingTaskControl implements TaskControl {
  void markOpenSelfBounded();
}

extension TaskControlCancellation on TaskControl {
  void throwIfCancelled() {
    if (cancelled) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'task cancelled',
      );
    }
  }
}
