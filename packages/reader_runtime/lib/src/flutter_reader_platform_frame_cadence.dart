import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';

const _frameCadenceChannel = MethodChannel(
  'dev.zic/reader_runtime_frame_cadence',
);

/// Android-system frame cadence observer for a mounted vertical Reader.
///
/// This adapter is observation-only. It never requests a Flutter frame,
/// changes ScrollPhysics, or interpolates a Reader position. Android samples
/// Choreographer on the platform thread into a bounded ring; Dart drains that
/// ring at low frequency and maps native monotonic timestamps onto the shared
/// Reader trace clock.
final class FlutterReaderPlatformFrameCadenceProbe {
  FlutterReaderPlatformFrameCadenceProbe({
    required this.clock,
    required this.traceSink,
    required this.sessionId,
    required this.revision,
    MethodChannel channel = _frameCadenceChannel,
    this.drainInterval = const Duration(seconds: 2),
  }) : _channel = channel;

  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final int Function() revision;
  final Duration drainInterval;
  final MethodChannel _channel;

  Timer? _drainTimer;
  Future<void>? _drainInFlight;
  int? _dartAnchorMicros;
  int? _nativeAnchorNanos;
  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed || _started || !_supportedPlatform) return;
    final dartSendMicros = clock.nowMicros();
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'startFrameCadenceProbe',
      );
      final dartReceiveMicros = clock.nowMicros();
      if (response == null) return;
      if (_disposed) {
        await _stopNativeBestEffort();
        return;
      }
      final nativeAnchor = response['nativeAnchorNanos'];
      if (nativeAnchor is! int) {
        await _stopNativeBestEffort();
        return;
      }
      _dartAnchorMicros = (dartSendMicros + dartReceiveMicros) ~/ 2;
      _nativeAnchorNanos = nativeAnchor;
      _started = true;
      _drainTimer = Timer.periodic(
        drainInterval,
        (_) => unawaited(drain()),
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  /// Drains the native outlier ring without requesting a Flutter frame.
  Future<void> drain() async {
    if (_disposed || !_started) return;
    final existing = _drainInFlight;
    if (existing != null) {
      await existing;
      return;
    }
    final work = _performDrain(stop: false);
    _drainInFlight = work;
    try {
      await work;
    } finally {
      if (identical(_drainInFlight, work)) {
        _drainInFlight = null;
      }
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    _drainTimer?.cancel();
    _drainTimer = null;
    final inFlight = _drainInFlight;
    if (inFlight != null) {
      await inFlight;
    }
    if (!_started) return;
    _started = false;
    await _performDrain(stop: true);
  }

  Future<void> _performDrain({required bool stop}) async {
    final dartAnchor = _dartAnchorMicros;
    final nativeAnchor = _nativeAnchorNanos;
    if (dartAnchor == null || nativeAnchor == null) return;
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        stop ? 'stopFrameCadenceProbe' : 'drainFrameCadenceProbe',
      );
      if (raw != null) {
        for (final entry in raw) {
          if (entry is! Map<Object?, Object?>) continue;
          final sample = entry.cast<String, Object?>();
          final frameTimeNanos = sample['frameTimeNanos'];
          final callbackNanos = sample['callbackNanos'];
          final frameGapMicros = sample['frameGapMicros'];
          final callbackGapMicros = sample['callbackGapMicros'];
          final callbackLagMicros = sample['callbackLagMicros'];
          final threadCpuGapMicros = sample['threadCpuGapMicros'];
          final displayRefreshRateMilliHz =
              sample['displayRefreshRateMilliHz'];
          final frameRatePolicyRequested =
              sample['frameRatePolicyRequested'];
          final displayHasArrSupport = sample['displayHasArrSupport'];
          if (frameTimeNanos is! int ||
              callbackNanos is! int ||
              frameGapMicros is! int ||
              callbackGapMicros is! int ||
              callbackLagMicros is! int) {
            continue;
          }
          final mappedMicros =
              dartAnchor + ((frameTimeNanos - nativeAnchor) ~/ 1000);
          traceSink.record(
            TraceEvent(
              monotonicMicros: mappedMicros,
              sessionId: sessionId,
              kind: TraceEventKind.platformFrameCadenceOutlier,
              revision: revision(),
              payload: <String, Object?>{
                'systemFrameGapMicros': frameGapMicros,
                'callbackGapMicros': callbackGapMicros,
                'callbackLagMicros': callbackLagMicros,
                'callbackOffsetMicros':
                    (callbackNanos - frameTimeNanos) ~/ 1000,
                if (threadCpuGapMicros is int)
                  'threadCpuGapMicros': threadCpuGapMicros,
                if (displayRefreshRateMilliHz is int)
                  'displayRefreshRateMilliHz': displayRefreshRateMilliHz,
                if (frameRatePolicyRequested is int)
                  'frameRatePolicyRequested':
                      frameRatePolicyRequested != 0,
                if (displayHasArrSupport is int)
                  'displayHasArrSupport': displayHasArrSupport != 0,
              },
            ),
          );
        }
      }
      final summary = await _channel.invokeMapMethod<String, Object?>(
        'drainFrameCadenceSummary',
      );
      if (summary != null) {
        _recordSummary(
          summary,
          dartAnchorMicros: dartAnchor,
          nativeAnchorNanos: nativeAnchor,
        );
      }
      final windowRaw = await _channel.invokeMethod<List<Object?>>(
        'drainWindowFrameMetricsProbe',
      );
      if (windowRaw != null) {
        for (final entry in windowRaw) {
          if (entry is! Map<Object?, Object?>) continue;
          _recordWindowFrameMetricOutlier(
            entry.cast<String, Object?>(),
            dartAnchorMicros: dartAnchor,
            nativeAnchorNanos: nativeAnchor,
          );
        }
      }
      final windowSummary = await _channel.invokeMapMethod<String, Object?>(
        'drainWindowFrameMetricsSummary',
      );
      if (windowSummary != null) {
        _recordWindowFrameMetricsSummary(windowSummary);
      }
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  void _recordSummary(
    Map<String, Object?> summary, {
    required int dartAnchorMicros,
    required int nativeAnchorNanos,
  }) {
    final lastFrameTimeNanos = summary['lastFrameTimeNanos'];
    final intervalCount = summary['frameIntervalCount'];
    if (lastFrameTimeNanos is! int ||
        intervalCount is! int ||
        intervalCount <= 0) {
      return;
    }
    final mappedMicros = dartAnchorMicros +
        ((lastFrameTimeNanos - nativeAnchorNanos) ~/ 1000);
    final payload = <String, Object?>{};
    for (final key in const <String>[
      'firstFrameTimeNanos',
      'lastFrameTimeNanos',
      'frameIntervalCount',
      'frameGapSumMicros',
      'minFrameGapMicros',
      'maxFrameGapMicros',
      'gapLt10msCount',
      'gap10To14msCount',
      'gap14To18msCount',
      'gap18To20msCount',
      'gap20To25msCount',
      'gap25To35msCount',
      'gapGe35msCount',
      'displayRefreshRateMilliHz',
    ]) {
      final value = summary[key];
      if (value is int) payload[key] = value;
    }
    final frameRatePolicyRequested = summary['frameRatePolicyRequested'];
    if (frameRatePolicyRequested is int) {
      payload['frameRatePolicyRequested'] = frameRatePolicyRequested != 0;
    }
    final displayHasArrSupport = summary['displayHasArrSupport'];
    if (displayHasArrSupport is int) {
      payload['displayHasArrSupport'] = displayHasArrSupport != 0;
    }
    traceSink.record(
      TraceEvent(
        monotonicMicros: mappedMicros,
        sessionId: sessionId,
        kind: TraceEventKind.platformFrameCadenceSummary,
        revision: revision(),
        payload: payload,
      ),
    );
  }

  void _recordWindowFrameMetricOutlier(
    Map<String, Object?> sample, {
    required int dartAnchorMicros,
    required int nativeAnchorNanos,
  }) {
    final callbackNanos = sample['callbackNanos'];
    final vsyncNanos = sample['vsyncNanos'];
    final sourceNanos = vsyncNanos is int && vsyncNanos > 0
        ? vsyncNanos
        : callbackNanos;
    if (sourceNanos is! int) return;
    final mappedMicros = dartAnchorMicros +
        ((sourceNanos - nativeAnchorNanos) ~/ 1000);
    final payload = <String, Object?>{};
    for (final key in const <String>[
      'callbackNanos',
      'totalDurationMicros',
      'unknownDelayMicros',
      'inputHandlingMicros',
      'animationMicros',
      'layoutMeasureMicros',
      'drawMicros',
      'syncMicros',
      'commandIssueMicros',
      'swapBuffersMicros',
      'droppedReports',
      'intendedVsyncNanos',
      'vsyncNanos',
      'displayRefreshRateMilliHz',
    ]) {
      final value = sample[key];
      if (value is int) payload[key] = value;
    }
    traceSink.record(
      TraceEvent(
        monotonicMicros: mappedMicros,
        sessionId: sessionId,
        kind: TraceEventKind.platformWindowFrameMetricsOutlier,
        revision: revision(),
        payload: payload,
      ),
    );
  }

  void _recordWindowFrameMetricsSummary(
    Map<String, Object?> summary,
  ) {
    final frameCount = summary['frameCount'];
    if (frameCount is! int || frameCount <= 0) return;
    final payload = <String, Object?>{};
    for (final key in const <String>[
      'frameCount',
      'droppedReports',
      'firstVsyncNanos',
      'lastVsyncNanos',
      'totalDurationSumMicros',
      'unknownDelaySumMicros',
      'maxTotalDurationMicros',
      'maxUnknownDelayMicros',
      'totalLt8msCount',
      'total8To12msCount',
      'total12To20msCount',
      'total20To35msCount',
      'totalGe35msCount',
      'unknownLt2msCount',
      'unknown2To8msCount',
      'unknownGe8msCount',
      'displayRefreshRateMilliHz',
    ]) {
      final value = summary[key];
      if (value is int) payload[key] = value;
    }
    traceSink.record(
      TraceEvent(
        monotonicMicros: clock.nowMicros(),
        sessionId: sessionId,
        kind: TraceEventKind.platformWindowFrameMetricsSummary,
        revision: revision(),
        payload: payload,
      ),
    );
  }

  Future<void> _stopNativeBestEffort() async {
    try {
      await _channel.invokeMethod<Object?>('stopFrameCadenceProbe');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
