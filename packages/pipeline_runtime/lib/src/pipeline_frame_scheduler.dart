/// Presentation-frame scheduling boundary used by Pipeline projections.
///
/// Pipeline runtime code must not depend on Flutter bindings directly. The
/// platform/presentation adapter supplies the implementation so output claims
/// can retire after a visual swap and high-frequency projections can yield to
/// an already queued Flutter frame without importing Flutter scheduler types
/// into the resource runtime.
abstract interface class PipelineFrameScheduler {
  bool get inPersistentCallbacks;
  bool get isIdle;

  /// Whether Flutter has queued or is currently composing a frame before the
  /// post-frame handoff.
  ///
  /// Presentation-only animation successors can yield to this frame without
  /// changing playback state. The adapter includes transient, mid-frame and
  /// persistent callbacks because Flutter clears its queued-frame bit once a
  /// frame begins. A frame requested from a post-frame callback is
  /// intentionally not reported here: that callback is the safe handoff for
  /// the successor already being drained. The adapter owns the
  /// scheduler-specific source of this signal so the resource runtime remains
  /// Flutter-independent.
  bool get hasScheduledFrame;

  void afterFrame(void Function() callback);

  /// Runs low-priority work only when Flutter has an idle event-loop budget.
  ///
  /// Presentation adapters must keep resource preparation behind active
  /// animation/touch callbacks. The callback is not a frame request and must
  /// not be used to change playback or freeze state.
  void scheduleIdle(void Function() callback);

  void requestFrame();
}
