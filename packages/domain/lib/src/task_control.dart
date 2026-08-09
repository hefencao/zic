import 'dart:async';

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
