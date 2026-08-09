/// Cross-layer control plane for cancellable, priority-bearing work.
///
/// The scheduler owns implementations. Transport/source/runtime layers may
/// observe the signal but must not mutate scheduling policy themselves.
abstract interface class TaskControl {
  bool get cancelled;
  Future<void> get whenCancelled;
  int get priority;
}
