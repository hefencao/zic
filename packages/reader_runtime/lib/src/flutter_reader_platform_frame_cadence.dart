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
      if (raw == null) return;
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
                'frameRatePolicyRequested': frameRatePolicyRequested != 0,
              if (displayHasArrSupport is int)
                'displayHasArrSupport': displayHasArrSupport != 0,
            },
          ),
        );
      }
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
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
