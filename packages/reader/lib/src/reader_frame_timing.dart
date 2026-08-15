/// Framework-neutral frame cadence sample consumed by Reader diagnostics.
///
/// The concrete Flutter engine timing API belongs to the presentation adapter.
/// Reader only decorates these samples with its own scroll/navigation context.
final class ReaderFrameTimingSample {
  const ReaderFrameTimingSample({
    required this.buildMicros,
    required this.rasterMicros,
    required this.totalSpanMicros,
    required this.vsyncOverheadMicros,
    required this.vsyncStartMicros,
    this.frameIntervalMicros,
  });

  final int buildMicros;
  final int rasterMicros;
  final int totalSpanMicros;
  final int vsyncOverheadMicros;
  final int vsyncStartMicros;
  final int? frameIntervalMicros;
}

typedef ReaderFrameTimingListener = void Function(
  List<ReaderFrameTimingSample> samples,
);

abstract interface class ReaderFrameTimingSubscription {
  void cancel();
}

/// Presentation-owned source of normalized frame cadence samples.
///
/// Implementations may depend on Flutter/dart:ui. Reader must not.
abstract interface class ReaderFrameTimingSource {
  ReaderFrameTimingSubscription subscribe(ReaderFrameTimingListener listener);
}
