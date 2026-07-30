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
        'entryClasses': <String>[
          'eu.kanade.tachiyomi.extension.en.example.ExampleFactory',
        ],
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
    expect(
      metadata.entryClasses,
      <String>['eu.kanade.tachiyomi.extension.en.example.ExampleFactory'],
    );
  });

  test('rejects incomplete platform metadata', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'packageName': 'example',
              'signerSha256': '',
              'versionCode': 1,
              'extensionLib': '1.6',
              'entryClasses': <String>['example.Source'],
            });

    expect(
      const AndroidMihonApkMetadataReader(channel: channel)
          .readMetadata('/cache/example.apk'),
      throwsFormatException,
    );
  });

  test('maps installed Mihon extensions without loading their code', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <Object?>[
        <String, Object?>{
          'packageName': 'eu.kanade.tachiyomi.extension.all.example',
          'displayName': 'Example',
          'versionName': '1.6.4',
          'versionCode': 64,
          'signerSha256': 'aabb',
          'extensionLib': '1.6',
          'extensionLibSource': 'manifest',
          'declaredExtensionLib': '1.6',
          'entryClasses': <String>[
            'eu.kanade.tachiyomi.extension.all.example.ExtensionGenerated',
          ],
        },
      ];
    });

    final installed = await const AndroidMihonApkMetadataReader(
      channel: channel,
    ).listInstalled();

    expect(received?.method, 'listInstalledMihonExtensions');
    expect(installed, hasLength(1));
    expect(
      installed.single.packageName,
      'eu.kanade.tachiyomi.extension.all.example',
    );
    expect(installed.single.displayName, 'Example');
    expect(installed.single.versionName, '1.6.4');
    expect(installed.single.extensionLib, '1.6');
    expect(installed.single.extensionLibSource, 'manifest');
    expect(installed.single.declaredExtensionLib, '1.6');
  });

  test('requests a private copy of an installed Mihon extension', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'packageName': 'eu.kanade.tachiyomi.extension.all.example',
      };
    });

    await const AndroidMihonApkMetadataReader(channel: channel).copyInstalled(
      packageName: 'eu.kanade.tachiyomi.extension.all.example',
      destinationPath: '/data/user/0/dev.zic/files/example.apk.part',
    );

    expect(received?.method, 'copyInstalledMihonExtension');
    expect(received?.arguments, <String, Object?>{
      'packageName': 'eu.kanade.tachiyomi.extension.all.example',
      'destinationPath': '/data/user/0/dev.zic/files/example.apk.part',
    });
  });

  test('reports when installed extension ABI came from versionName', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => <Object?>[
              <String, Object?>{
                'packageName': 'eu.kanade.tachiyomi.extension.all.legacy',
                'displayName': 'Legacy',
                'versionName': '1.4.12',
                'versionCode': 12,
                'signerSha256': 'aabb',
                'extensionLib': '1.4',
                'extensionLibSource': 'versionName',
                'entryClasses': <String>[
                  'eu.kanade.tachiyomi.extension.all.legacy.Legacy',
                ],
              },
            ]);

    final installed = await const AndroidMihonApkMetadataReader(
      channel: channel,
    ).listInstalled();

    expect(installed.single.extensionLib, '1.4');
    expect(installed.single.extensionLibSource, 'versionName');
    expect(installed.single.declaredExtensionLib, isNull);
  });
}
