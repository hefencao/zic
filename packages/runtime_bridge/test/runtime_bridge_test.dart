import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runtime_bridge/runtime_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel(runtimeBridgeMethodChannelName);
  const bridge = RuntimeEnvironmentBridge(methodChannel: method);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null);
  });

  test('current environment preserves network and power signals', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      expect(call.method, 'currentEnvironment');
      return <String, Object?>{
        'protocolVersion': runtimeBridgeProtocolVersion,
        'networkAvailable': true,
        'unmetered': false,
        'charging': true,
      };
    });

    final snapshot = await bridge.current();
    expect(snapshot.networkAvailable, isTrue);
    expect(snapshot.unmetered, isFalse);
    expect(snapshot.charging, isTrue);
  });

  test('stale native protocol is rejected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (_) async => <String, Object?>{
              'protocolVersion': 0,
              'networkAvailable': true,
              'unmetered': true,
              'charging': true,
            });

    await expectLater(bridge.current(), throwsA(isA<StateError>()));
  });
}
