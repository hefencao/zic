import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:reader/reader.dart';

/// Flutter presentation adapter for Reader frame-cadence diagnostics.
///
/// SchedulerBinding and dart:ui timing phases stop here. Reader receives only
/// project-owned [ReaderFrameTimingSample] values and never parses engine API.
final class FlutterReaderFrameTimingSource implements ReaderFrameTimingSource {
  const FlutterReaderFrameTimingSource();

  @override
  ReaderFrameTimingSubscription subscribe(ReaderFrameTimingListener listener) {
    int? priorVsyncStartMicros;

    void handleTimings(List<ui.FrameTiming> timings) {
      if (timings.isEmpty) return;
      final samples = <ReaderFrameTimingSample>[];
      for (final timing in timings) {
        final vsyncStartMicros =
            timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
        final frameIntervalMicros = priorVsyncStartMicros == null
            ? null
            : vsyncStartMicros - priorVsyncStartMicros!;
        priorVsyncStartMicros = vsyncStartMicros;
        samples.add(
          ReaderFrameTimingSample(
            buildMicros: timing.buildDuration.inMicroseconds,
            rasterMicros: timing.rasterDuration.inMicroseconds,
            totalSpanMicros: timing.totalSpan.inMicroseconds,
            vsyncOverheadMicros: timing.vsyncOverhead.inMicroseconds,
            vsyncStartMicros: vsyncStartMicros,
            frameIntervalMicros: frameIntervalMicros,
          ),
        );
      }
      listener(List<ReaderFrameTimingSample>.unmodifiable(samples));
    }

    SchedulerBinding.instance.addTimingsCallback(handleTimings);
    return _FlutterReaderFrameTimingSubscription(handleTimings);
  }
}

final class _FlutterReaderFrameTimingSubscription
    implements ReaderFrameTimingSubscription {
  _FlutterReaderFrameTimingSubscription(this._callback);

  final void Function(List<ui.FrameTiming>) _callback;
  bool _cancelled = false;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    SchedulerBinding.instance.removeTimingsCallback(_callback);
  }
}
