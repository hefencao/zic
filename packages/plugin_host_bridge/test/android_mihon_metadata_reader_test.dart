import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.zic/plugin_host_bridge');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('maps Android archive metadata without loading extension code', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'packageName': 'eu.kanade.tachiyomi.extension.en.example',
        'signerSha256': 'aabb',
        'versionCode': 42,
        'extensionLib': '1.6',
      };
    });

    final metadata = await const AndroidMihonApkMetadataReader(
      channel: channel,
    ).readMetadata('/cache/example.apk');

    expect(received?.method, 'readMihonApkMetadata');
    expect(received?.arguments, <String, Object?>{
      'apkPath': '/cache/example.apk',
    });
    expect(metadata.packageName, 'eu.kanade.tachiyomi.extension.en.example');
    expect(metadata.signerSha256, 'aabb');
    expect(metadata.versionCode, 42);
    expect(metadata.extensionLib, '1.6');
  });

  test('rejects incomplete platform metadata', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'packageName': 'example',
              'signerSha256': '',
              'versionCode': 1,
              'extensionLib': '1.6',
            });

    expect(
      const AndroidMihonApkMetadataReader(channel: channel)
          .readMetadata('/cache/example.apk'),
      throwsFormatException,
    );
  });
}
