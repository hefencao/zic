import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:telemetry/telemetry.dart';

const _frameRatePolicyChannel = MethodChannel(
  'dev.zic/reader_runtime_frame_rate_policy',
);

/// Reader-scoped Android frame-rate policy used to falsify the Android 15+
/// Adaptive Refresh Rate boundary independently from Reader scroll semantics.
///
/// The native adapter disables Window frame-rate power-savings balancing only
/// while a vertical Reader is mounted, then restores the exact prior value.
/// It never writes ScrollPosition, changes ScrollPhysics, requests Flutter
/// frames, or changes Reader geometry.
final class FlutterReaderPlatformFrameRatePolicy {
  FlutterReaderPlatformFrameRatePolicy({
    required this.clock,
    required this.traceSink,
    required this.sessionId,
    required this.revision,
    MethodChannel channel = _frameRatePolicyChannel,
  }) : _channel = channel;

  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final int Function() revision;
  final MethodChannel _channel;

  bool _started = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed || _started || !_supportedPlatform) return;
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'setVerticalReaderFrameRatePolicy',
        const <String, Object?>{'active': true},
      );
      if (_disposed) {
        await _setNativeActive(false);
        return;
      }
      _started = true;
      _record('start', response);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    if (!_started) return;
    _started = false;
    try {
      final response = await _setNativeActive(false);
      _record('stop', response);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<Map<String, Object?>?> _setNativeActive(bool active) =>
      _channel.invokeMapMethod<String, Object?>(
        'setVerticalReaderFrameRatePolicy',
        <String, Object?>{'active': active},
      );

  void _record(String phase, Map<String, Object?>? response) {
    traceSink.record(
      TraceEvent(
        monotonicMicros: clock.nowMicros(),
        sessionId: sessionId,
        kind: TraceEventKind.platformFrameRatePolicy,
        revision: revision(),
        payload: <String, Object?>{
          'phase': phase,
          if (response != null) ...response,
        },
      ),
    );
  }

  bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
