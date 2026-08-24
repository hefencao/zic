import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/runtime_service_entrypoint.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.zic/runtime-service-entrypoint-test');
  late Directory root;
  late MethodCall readyCall;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zic-runtime-entrypoint-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      readyCall = call;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('dedicated runtime bootstrap attaches and announces its generation',
      () async {
    final handler = await AndroidExternalPluginRuntimeServiceBootstrap.start(
      factories: const <ExternalPluginRuntimeDriverFactory>[],
      verifiedDirectory: Directory('${root.path}/verified'),
      processId: 'process-entrypoint-test',
      warmVeneraResolverHttp: false,
      channel: channel,
    );
    try {
      expect(readyCall.method, 'runtimeServiceReady');
      expect(
        readyCall.arguments,
        <String, Object?>{'processId': 'process-entrypoint-test'},
      );

      await expectLater(
        handler.dispatch(
          MethodCall(
            ExternalPluginRuntimeServiceMethods.activateMihon,
            _mihonActivation(root),
          ),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'driver-unavailable',
          ),
        ),
      );
    } finally {
      await handler.detach();
    }
  });
}

Map<String, Object?> _mihonActivation(Directory root) => <String, Object?>{
      'schemaVersion': 1,
      'format': ExternalComicPluginFormat.mihonExtension.name,
      'pluginId': 'mihon:fail-closed',
      'pluginVersion': '1.0.0',
      'payloadPath': '${root.path}/not-opened.apk',
      'payloadByteLength': 1,
      'payloadSha256': List<String>.filled(64, 'a').join(),
      'packageName': 'dev.fixture.extension',
      'signerSha256': List<String>.filled(64, 'b').join(),
      'versionCode': 1,
      'extensionLib': '1.6',
      'entryClasses': const <String>['dev.fixture.Extension'],
      'capabilities': const <String>['network'],
      'limits': const ExternalPluginRuntimeLimits().toMessage(),
    };
