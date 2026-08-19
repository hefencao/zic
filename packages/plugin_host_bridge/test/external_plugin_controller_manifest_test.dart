import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

void main() {
  test('manifest restore accepts only owned regular payload files', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-manifest-',
    );
    final outside = await File(
      '${storage.parent.path}/zic-outside-${storage.path.hashCode}.js',
    ).writeAsString('ComicSource = {};');
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final directoryPayload = Directory('${pluginRoot.path}/directory.js');
    await directoryPayload.create();
    final partialPayload = await File(
      '${pluginRoot.path}/preview.js.part',
    ).writeAsString('ComicSource = {};');
    final ownedPayload = await File(
      '${pluginRoot.path}/owned.js',
    ).writeAsString('ComicSource = {};');

    final records = <Map<String, Object?>>[
      _record('directory', directoryPayload.path),
      _record('outside', outside.path),
      _record('partial', partialPayload.path),
      _record('owned', ownedPayload.path),
    ];
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': records,
      }),
    );

    final controller = await ExternalPluginController.openDeferred(
      storage.path,
    );
    addTearDown(() async {
      await controller.close();
      await outside.delete();
      await storage.delete(recursive: true);
    });

    expect(controller.activeSources, isEmpty);
    await controller.ready;
    expect(
      controller.installed.map((record) => record.plugin.pluginId),
      orderedEquals(<String>['venera:test-owned']),
    );
    expect(controller.activeSources, isEmpty);
    expect(
      controller.activationFailures,
      containsPair('venera:test-owned', anything),
    );
  });

  test('manifest restore keeps valid plugins when one record is malformed',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-partial-manifest-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final ownedPayload = await File('${pluginRoot.path}/owned.js')
        .writeAsString('ComicSource = {};');
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          <String, Object?>{'broken': true},
          _record('owned', ownedPayload.path),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);

    expect(
      controller.installed.map((record) => record.plugin.pluginId),
      orderedEquals(<String>['venera:test-owned']),
    );
    expect(controller.manifestRestoreFailures, isNotEmpty);
    expect(
      await File('${pluginRoot.path}/installed.json.invalid').exists(),
      isFalse,
    );
  });

  test('manifest restore recovers valid records from legacy invalid file',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-invalid-recovery-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final ownedPayload = await File('${pluginRoot.path}/owned.js')
        .writeAsString('ComicSource = {};');
    await File('${pluginRoot.path}/installed.json.invalid').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          <String, Object?>{'broken': true},
          _record('owned', ownedPayload.path),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);

    expect(
      controller.installed.map((record) => record.plugin.pluginId),
      orderedEquals(<String>['venera:test-owned']),
    );
    expect(
      controller.manifestRestoreFailures,
      contains('manifest-record-0'),
    );
    expect(
      await File('${pluginRoot.path}/installed.json').exists(),
      isTrue,
    );
  });

  test('manifest restore falls back to backup when primary is corrupt',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-backup-recovery-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final ownedPayload = await File('${pluginRoot.path}/owned.js')
        .writeAsString('ComicSource = {};');
    await File('${pluginRoot.path}/installed.json').writeAsString('{broken');
    await File('${pluginRoot.path}/installed.json.bak').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[_record('owned', ownedPayload.path)],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);

    expect(controller.installed, hasLength(1));
    expect(controller.installed.single.plugin.pluginId, 'venera:test-owned');
    expect(controller.manifestRestoreFailures, isNotEmpty);
    final restored = jsonDecode(
      await File('${pluginRoot.path}/installed.json').readAsString(),
    ) as Map<String, Object?>;
    expect(restored['plugins'], isNotEmpty);
  });

  test('manifest write keeps the previous generation as backup', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-backup-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final ownedPayload = await File('${pluginRoot.path}/owned.js')
        .writeAsString('ComicSource = {};');
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[_record('owned', ownedPayload.path)],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);
    await controller.remove('venera:test-owned');

    expect(
      await File('${pluginRoot.path}/installed.json.bak').exists(),
      isTrue,
    );
  });

  test('manifest restore relocates a payload from an old sandbox root',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-relocate-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final ownedPayload = await File('${pluginRoot.path}/owned.js')
        .writeAsString('ComicSource = {};');
    final stalePath = '/data/user/0/old.zic/files/external_plugins/owned.js';
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[_record('owned', stalePath)],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);

    expect(controller.installed, hasLength(1));
    expect(controller.installed.single.payloadPath, ownedPayload.path);
    expect(controller.manifestRestoreFailures, isEmpty);
    final persisted = jsonDecode(
      await File('${pluginRoot.path}/installed.json').readAsString(),
    ) as Map<String, Object?>;
    final records = persisted['plugins'] as List<Object?>;
    final record = records.single as Map<String, Object?>;
    expect(record['payloadPath'], ownedPayload.path);
  });
}

Map<String, Object?> _record(String suffix, String payloadPath) =>
    <String, Object?>{
      'plugin': <String, Object?>{
        'format': 'veneraJavaScript',
        'pluginId': 'venera:test-$suffix',
        'name': 'Test $suffix',
        'version': '1.0.0',
        'entrypoint': 'https://example.com/$suffix.js',
        'adult': false,
        'requiresRuntimeDiscovery': true,
        'sources': const <Object?>[],
      },
      'payloadPath': payloadPath,
      'payloadSha256': List<String>.filled(64, '0').join(),
      'repositoryOrigin': 'https://example.com',
      'entryClasses': const <Object?>[],
    };
