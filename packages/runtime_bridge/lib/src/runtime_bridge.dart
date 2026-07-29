import 'package:flutter/services.dart';

const runtimeBridgeProtocolVersion = 1;
const runtimeBridgeMethodChannelName = 'dev.zic/runtime_environment';
const runtimeBridgeEventChannelName = 'dev.zic/runtime_environment/events';

final class RuntimeEnvironmentSnapshot {
  const RuntimeEnvironmentSnapshot({
    required this.networkAvailable,
    required this.unmetered,
    required this.charging,
  });

  final bool networkAvailable;
  final bool unmetered;
  final bool charging;

  factory RuntimeEnvironmentSnapshot.fromMap(Map<String, Object?> values) {
    final protocol = values['protocolVersion'];
    if (protocol is! int || protocol < runtimeBridgeProtocolVersion) {
      throw StateError(
        'runtime bridge version is stale '
        '(native=${protocol ?? 'missing'}, Dart=$runtimeBridgeProtocolVersion)',
      );
    }
    return RuntimeEnvironmentSnapshot(
      networkAvailable: _requiredBool(values, 'networkAvailable'),
      unmetered: _requiredBool(values, 'unmetered'),
      charging: _requiredBool(values, 'charging'),
    );
  }
}

final class RuntimeEnvironmentBridge {
  const RuntimeEnvironmentBridge({
    MethodChannel methodChannel =
        const MethodChannel(runtimeBridgeMethodChannelName),
    EventChannel eventChannel =
        const EventChannel(runtimeBridgeEventChannelName),
  })  : _methodChannel = methodChannel,
        _eventChannel = eventChannel;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Future<RuntimeEnvironmentSnapshot> current() async {
    final raw = await _methodChannel.invokeMapMethod<String, Object?>(
      'currentEnvironment',
    );
    if (raw == null) {
      throw StateError('runtime bridge returned no environment');
    }
    return RuntimeEnvironmentSnapshot.fromMap(raw);
  }

  Stream<RuntimeEnvironmentSnapshot> get changes =>
      _eventChannel.receiveBroadcastStream().map((raw) {
        if (raw is! Map<Object?, Object?>) {
          throw const FormatException(
            'runtime bridge event must be an object',
          );
        }
        return RuntimeEnvironmentSnapshot.fromMap(
          raw.cast<String, Object?>(),
        );
      });
}

bool _requiredBool(Map<String, Object?> values, String key) {
  final value = values[key];
  if (value is! bool) {
    throw FormatException('runtime bridge returned invalid $key');
  }
  return value;
}
