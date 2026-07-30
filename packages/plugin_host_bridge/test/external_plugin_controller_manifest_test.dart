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

    final controller = await ExternalPluginController.open(storage.path);
    addTearDown(() async {
      await controller.close();
      await outside.delete();
      await storage.delete(recursive: true);
    });

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
