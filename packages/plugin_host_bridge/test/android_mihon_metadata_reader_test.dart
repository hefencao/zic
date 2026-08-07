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

  test('maps structured installed Mihon scan without loading code', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'extensions': <Object?>[
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
        ],
        'failures': <Object?>[
          <String, Object?>{
            'packageName': 'eu.kanade.tachiyomi.extension.all.bad',
            'displayName': 'Bad',
            'stage': 'metadata',
            'errorType': 'java.lang.IllegalArgumentException',
            'message': 'entry metadata missing',
          },
        ],
        'enumeratedPackageCount': 3,
        'candidatePackageCount': 2,
        'directProbeCount': 1,
        'directMatchCount': 1,
        'enumerationErrors': <Object?>[],
        'visibilityLimited': false,
        'sharedExtensionOnly': true,
      };
    });

    final scan = await const AndroidMihonApkMetadataReader(
      channel: channel,
    ).scanInstalled(
      knownPackageNames: const <String>[
        ' eu.kanade.tachiyomi.extension.all.example ',
      ],
    );

    expect(received?.method, 'scanInstalledMihonExtensions');
    expect(received?.arguments, <String, Object?>{
      'knownPackageNames': <String>[
        'eu.kanade.tachiyomi.extension.all.example',
      ],
    });
    expect(scan.extensions, hasLength(1));
    expect(scan.extensions.single.displayName, 'Example');
    expect(scan.failures.single.stage, 'metadata');
    expect(scan.enumeratedPackageCount, 3);
    expect(scan.directMatchCount, 1);
    expect(scan.sharedExtensionOnly, isTrue);
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
        .setMockMethodCallHandler(channel, (_) async => <String, Object?>{
              'extensions': <Object?>[
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
              ],
              'failures': <Object?>[],
              'enumeratedPackageCount': 1,
              'candidatePackageCount': 1,
              'directProbeCount': 0,
              'directMatchCount': 0,
              'enumerationErrors': <Object?>[],
              'visibilityLimited': false,
              'sharedExtensionOnly': true,
            });

    final installed = await const AndroidMihonApkMetadataReader(
      channel: channel,
    ).listInstalled();

    expect(installed.single.extensionLib, '1.4');
    expect(installed.single.extensionLibSource, 'versionName');
    expect(installed.single.declaredExtensionLib, isNull);
  });
}
