/// Presentation-frame scheduling boundary used by Pipeline projections.
///
/// Pipeline runtime code must not depend on Flutter bindings directly. The
/// platform/presentation adapter supplies the implementation so output claims
/// can retire after a visual swap and high-frequency projections can coalesce
/// outside persistent frame callbacks without importing Flutter scheduler
/// types into the resource runtime.
abstract interface class PipelineFrameScheduler {
  bool get inPersistentCallbacks;
  bool get isIdle;

  void afterFrame(void Function() callback);
  void requestFrame();
}
