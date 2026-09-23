import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

void main() {
  test('legacy Mihon resource locator detection follows replay coordinates', () {
    String locator(Map<String, Object?> payload) {
      final json = jsonEncode(<String, Object?>{
        ...payload,
        'kind': 'resource',
      });
      final encoded = base64UrlEncode(utf8.encode(json)).replaceAll('=', '');
      return 'mihon:resource:' + encoded;
    }

    final current = locator(<String, Object?>{
      'url': 'https://example.invalid/page.webp',
      'retryChapterId': 'mihon:chapter:fixture',
      'retryPageIndex': 2,
    });
    final legacy = locator(<String, Object?>{
      'url': 'https://example.invalid/page.webp',
    });

    expect(mihonResourceLocatorHasReplayCoordinates(current), isTrue);
    expect(isLegacyMihonResourceLocator(current), isFalse);
    expect(mihonResourceLocatorHasReplayCoordinates(legacy), isFalse);
    expect(isLegacyMihonResourceLocator(legacy), isTrue);
    expect(
      isLegacyMihonResourceLocator('https://example.invalid/page.webp'),
      isFalse,
    );
  });

  test('controller close is joinable across concurrent callers', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-joinable-close-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );

    final first = controller.close();
    final second = controller.close();

    expect(identical(first, second), isTrue);
    await expectLater(
      controller.loadRepository(
        format: ExternalComicPluginFormat.veneraJavaScript,
        index: Uri.https('example.com', '/closed.json'),
      ),
      throwsA(isA<StateError>()),
    );
    await Future.wait<void>(<Future<void>>[first, second]);
  });

  test('controller close deletes an unconsumed install preview payload',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-preview-close-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    final client = _StaticHttpClient(
      utf8.encode('''
class PreviewSource extends ComicSource {
  key = "preview-close";
}
'''),
    );
    late ExternalPluginInstallPreview preview;

    await HttpOverrides.runZoned(() async {
      preview = await controller.inspect(
        plugin: ExternalComicPluginCatalogEntry(
          format: ExternalComicPluginFormat.veneraJavaScript,
          pluginId: 'venera:test-preview-close',
          name: 'Preview close',
          version: '1.0.0',
          entrypoint: Uri.https('example.com', '/preview-close.js'),
          sources: const <ExternalComicPluginSource>[],
          requiresRuntimeDiscovery: true,
        ),
        repository: Uri.https('example.com', '/index.json'),
      );
    }, createHttpClient: (_) => client);

    final payload = File(preview.inspection.payloadPath!);
    expect(await payload.exists(), isTrue);

    await controller.close();

    expect(await payload.exists(), isFalse);
  });

  test('stale preview cannot claim a newer pending payload', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-stale-preview-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:test-stale-preview',
      name: 'Stale preview',
      version: '1.0.0',
      entrypoint: Uri.https('example.com', '/stale-preview.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    Future<ExternalPluginInstallPreview> inspect(String marker) =>
        HttpOverrides.runZoned(
          () => controller.inspect(
            plugin: plugin,
            repository: Uri.https('example.com', '/index.json'),
          ),
          createHttpClient: (_) => _StaticHttpClient(
            utf8.encode('''
class PreviewSource extends ComicSource {
  key = "stale-preview";
  marker = "$marker";
}
'''),
          ),
        );

    final first = await inspect('first');
    final firstPayload = File(first.inspection.payloadPath!);
    expect(await firstPayload.exists(), isTrue);

    final second = await inspect('second');
    final secondPayload = File(second.inspection.payloadPath!);
    expect(await firstPayload.exists(), isFalse);
    expect(await secondPayload.exists(), isTrue);

    await expectLater(
      controller.approveAndActivate(first),
      throwsA(isA<StateError>()),
    );
    expect(await secondPayload.exists(), isTrue);

    await controller.discardPreview(second);
    expect(await secondPayload.exists(), isFalse);
  });

  test('later same-plugin inspect supersedes an earlier slow download',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-overlap-preview-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:test-overlap-preview',
      name: 'Overlap preview',
      version: '1.0.0',
      entrypoint: Uri.https('example.com', '/overlap-preview.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    final firstRelease = Completer<void>();
    final firstClient = _GatedStaticHttpClient(
      utf8.encode('''
class PreviewSource extends ComicSource {
  key = "overlap-preview";
  marker = "first";
}
'''),
      firstRelease.future,
    );
    final first = HttpOverrides.runZoned(
      () => controller.inspect(
        plugin: plugin,
        repository: Uri.https('example.com', '/index.json'),
      ),
      createHttpClient: (_) => firstClient,
    );
    await firstClient.requestStarted.future;

    final second = await HttpOverrides.runZoned(
      () => controller.inspect(
        plugin: plugin,
        repository: Uri.https('example.com', '/index.json'),
      ),
      createHttpClient: (_) => _StaticHttpClient(
        utf8.encode('''
class PreviewSource extends ComicSource {
  key = "overlap-preview";
  marker = "second";
}
'''),
      ),
    );
    final secondPayload = File(second.inspection.payloadPath!);
    expect(await secondPayload.exists(), isTrue);

    firstRelease.complete();
    await expectLater(first, throwsA(isA<StateError>()));
    expect(await secondPayload.exists(), isTrue);

    await controller.discardPreview(second);
    expect(await secondPayload.exists(), isFalse);
  });

  test('controller close keeps manifest-owned installed payload', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-installed-close-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final payload = await File('${pluginRoot.path}/installed.js').writeAsString(
      'class InstalledSource extends ComicSource { key = "installed"; }',
    );
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          _record('installed', payload.path, sourceKey: 'installed'),
        ],
      }),
    );
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );

    await controller.close();

    expect(await payload.exists(), isTrue);
  });

  test(
    'legacy Keiyoushi install discovers updates from current index',
    () async {
      final storage = await Directory.systemTemp.createTemp(
        'zic-external-plugin-legacy-keiyoushi-update-',
      );
      addTearDown(() => storage.delete(recursive: true));
      final pluginRoot = Directory('${storage.path}/external_plugins');
      await pluginRoot.create(recursive: true);
      final payload = await File(
        '${pluginRoot.path}/wnacg.apk',
      ).writeAsBytes(const <int>[0]);
      await File('${pluginRoot.path}/installed.json').writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'plugins': <Object?>[
            <String, Object?>{
              'plugin': <String, Object?>{
                'format': 'mihonExtension',
                'pluginId': 'mihon:eu.kanade.tachiyomi.extension.zh.wnacg',
                'name': 'WNACG',
                'version': '1.4.23',
                'entrypoint':
                    'https://cdn.jsdelivr.net/gh/keiyoushi/extensions@repo/'
                    'apk/tachiyomi-zh.wnacg-v1.4.23.apk',
                'language': 'zh',
                'versionCode': 23,
                'adult': true,
                'requiresRuntimeDiscovery': false,
                'sources': <Object?>[
                  <String, Object?>{
                    'sourceId': 'mihon:6551136894818591762',
                    'externalId': '6551136894818591762',
                    'name': '紳士漫畫',
                    'language': 'zh',
                    'baseUri': 'https://www.wn07.cfd',
                  },
                ],
              },
              'payloadPath': payload.path,
              'payloadSha256': List<String>.filled(64, '0').join(),
              // Manifest v1 intentionally only has the trust origin.
              'repositoryOrigin': 'https://github.com',
              'packageName': 'eu.kanade.tachiyomi.extension.zh.wnacg',
              'versionCode': 23,
              'extensionLib': '1.4',
              'entryClasses': <Object?>[
                'eu.kanade.tachiyomi.extension.zh.wnacg.ExtensionGenerated',
              ],
              'sourceIds': <Object?>['mihon:6551136894818591762'],
            },
          ],
        }),
      );
      final controller = await ExternalPluginController.openDeferred(
        storage.path,
        discoverDeviceMihonExtensions: false,
        deferRuntimeActivation: true,
      );
      addTearDown(controller.close);

      expect(
        externalPluginUpdateRepositoryIndex(controller.installed.single),
        Uri.parse(defaultMihonExtensionRepository),
      );

      expect(
        controller.resourceAuthorityRevisionForSource(
          'mihon:6551136894818591762',
        ),
        'mihon-runtime-transform-v3:${List<String>.filled(64, '0').join()}',
      );

      final repository = utf8.encode('''
{
  "name": "Keiyoushi",
  "extensionList": {
    "extensions": [
      {
        "name": "WNACG",
        "packageName": "eu.kanade.tachiyomi.extension.zh.wnacg",
        "resources": {
          "apkUrl": "https://github.com/keiyoushi/extensions/releases/download/current/tachiyomi-zh.wnacg-v1.6.0.apk"
        },
        "extensionLib": "1.6",
        "versionCode": "106000",
        "versionName": "1.6.0",
        "contentWarning": "CONTENT_WARNING_NSFW",
        "sources": [
          {
            "id": "6551136894818591762",
            "name": "紳士漫畫",
            "language": "zh",
            "homeUrl": "https://www.wn07.cfd"
          }
        ]
      }
    ]
  }
}
''');
      final updates = await HttpOverrides.runZoned(
        () => controller.checkUpdates(
          format: ExternalComicPluginFormat.mihonExtension,
        ),
        createHttpClient: (_) => _StaticHttpClient(repository),
      );

      final update = updates['mihon:eu.kanade.tachiyomi.extension.zh.wnacg'];
      expect(update, isNotNull);
      expect(update!.version, '1.6.0');
      expect(update.versionCode, 106000);
    },
  );


  test('controller close cancels an active repository request', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-network-close-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
    );
    final client = _BlockingHttpClient();

    await HttpOverrides.runZoned(() async {
      final loading = controller.loadRepository(
        format: ExternalComicPluginFormat.veneraJavaScript,
        index: Uri.https('example.com', '/index.json'),
      );
      final failed = expectLater(loading, throwsA(anything));
      await client.requestStarted.future;
      await controller.close();
      expect(client.forceClosed, isTrue);
      await failed;
    }, createHttpClient: (_) => client);
  });

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

  test('deferred controller activates only the requested persisted source',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-targeted-activation-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final targetPayload = await File('${pluginRoot.path}/target.js')
        .writeAsString('class TargetSource extends ComicSource {}');
    final siblingPayload = await File('${pluginRoot.path}/sibling.js')
        .writeAsString('class SiblingSource extends ComicSource {}');
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          _record(
            'target',
            targetPayload.path,
            sourceKey: 'target',
            sourceIds: const <String>['venera:target'],
          ),
          _record(
            'sibling',
            siblingPayload.path,
            sourceKey: 'sibling',
            sourceIds: const <String>['venera:sibling'],
          ),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    expect(controller.activationFailures, isEmpty);

    expect(await controller.ensureSourceActive('venera:target'), isFalse);
    expect(
      controller.activationFailures.keys,
      unorderedEquals(<String>['venera:test-target']),
    );
    expect(
      controller.activationFailures,
      isNot(contains('venera:test-sibling')),
    );
  });

  test('queued startup activation drops a record removed before its turn',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-stale-startup-remove-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final payload = await File('${pluginRoot.path}/stale.js').writeAsString(
      'class StaleSource extends ComicSource { key = "stale"; }',
    );
    const pluginId = 'venera:test-stale-startup';
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          _record(
            'stale-startup',
            payload.path,
            sourceKey: 'stale',
            sourceIds: const <String>['venera:stale'],
          ),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    var sourceChanges = 0;
    final subscription = controller.sourceChanges.listen((_) {
      sourceChanges++;
    });
    addTearDown(subscription.cancel);

    final removing = controller.remove(pluginId);
    final ready = controller.ready;
    await Future.wait<void>(<Future<void>>[removing, ready]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.installed, isEmpty);
    expect(controller.activationFailures, isNot(contains(pluginId)));
    expect(sourceChanges, 1);
  });

  test('recoverable activation failure keeps the enabled record for retry',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-retry-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final payload = await File('${pluginRoot.path}/retryable.js').writeAsString(
      '''
class RetryableSource extends ComicSource {
  key = "retryable";
}
''',
    );
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          _record('retryable', payload.path, sourceKey: 'retryable'),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(storage.path);
    addTearDown(controller.close);
    await controller.ready;

    expect(
      controller.installed.map((record) => record.plugin.pluginId),
      orderedEquals(<String>['venera:test-retryable']),
    );
    expect(controller.canRetryActivation('venera:test-retryable'), isTrue);
    expect(await payload.exists(), isTrue);

    await expectLater(
      controller.retryActivation('venera:test-retryable'),
      throwsA(anything),
    );
    expect(controller.canRetryActivation('venera:test-retryable'), isTrue);
    expect(await payload.exists(), isTrue);
  });

  test('unclaimed preview cannot install an arbitrary payload', () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-unclaimed-preview-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final payload = await File('${storage.path}/unclaimed.js').writeAsString(
      'class UnclaimedSource extends ComicSource { key = "unclaimed"; }',
    );
    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:test-unclaimed',
      name: 'Test unclaimed',
      version: '1.0.0',
      entrypoint: Uri.https('example.com', '/unclaimed.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    final preview = ExternalPluginInstallPreview(
      plugin: plugin,
      inspection: ExternalPluginInspection(
        format: ExternalComicPluginFormat.veneraJavaScript,
        payloadSha256: List<String>.filled(64, '0').join(),
        payloadPath: payload.path,
        payloadByteLength: await payload.length(),
        sourceKey: 'unclaimed',
      ),
      repository: Uri.https('example.com', '/index.json'),
    );

    await expectLater(
      controller.approveAndActivate(preview),
      throwsA(isA<StateError>()),
    );
    expect(controller.installed, isEmpty);
    expect(await payload.exists(), isTrue);
  });

  test('pending preview cannot replace the installed payload used by retry',
      () async {
    final storage = await Directory.systemTemp.createTemp(
      'zic-external-plugin-retry-exact-payload-',
    );
    addTearDown(() => storage.delete(recursive: true));
    final pluginRoot = Directory('${storage.path}/external_plugins');
    await pluginRoot.create(recursive: true);
    final installedPayload = await File('${pluginRoot.path}/installed.js')
        .writeAsString('''
class InstalledSource extends ComicSource {
  key = "exact-retry";
  marker = "installed";
}
''');
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:test-exact-retry',
      name: 'Test exact retry',
      version: '1.0.0',
      entrypoint: Uri.https('example.com', '/exact-retry.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    final installedInspection = await VeneraJavaScriptInspector(
      payloads: CallbackExternalPluginPayloadLoader(
        (_) async => ExternalPluginPayloadFile(
          path: installedPayload.path,
          byteLength: await installedPayload.length(),
        ),
      ),
    ).inspect(plugin);
    await File('${pluginRoot.path}/installed.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'plugins': <Object?>[
          _record(
            'exact-retry',
            installedPayload.path,
            payloadSha256: installedInspection.payloadSha256,
            sourceKey: 'exact-retry',
          ),
        ],
      }),
    );

    final controller = await ExternalPluginController.openDeferred(
      storage.path,
      discoverDeviceMihonExtensions: false,
      deferRuntimeActivation: true,
    );
    addTearDown(controller.close);
    final pending = await HttpOverrides.runZoned(
      () => controller.inspect(
        plugin: plugin,
        repository: Uri.https('example.com', '/index.json'),
      ),
      createHttpClient: (_) => _StaticHttpClient(
        utf8.encode('''
class PendingSource extends ComicSource {
  key = "exact-retry";
  marker = "pending";
}
'''),
      ),
    );

    Object? retryError;
    try {
      await controller.retryActivation(plugin.pluginId);
    } on Object catch (error) {
      retryError = error;
    }

    expect(retryError, isA<ExternalPluginActivationException>());
    expect(
      (retryError! as ExternalPluginActivationException).denials,
      isNot(contains(ExternalPluginDenial.payloadNotTrusted)),
    );
    await controller.discardPreview(pending);
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

Map<String, Object?> _record(
  String suffix,
  String payloadPath, {
  String? payloadSha256,
  String? sourceKey,
  List<String> sourceIds = const <String>[],
}) =>
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
      'payloadSha256': payloadSha256 ?? List<String>.filled(64, '0').join(),
      'repositoryOrigin': 'https://example.com',
      'entryClasses': const <Object?>[],
      if (sourceKey != null) 'sourceKey': sourceKey,
      if (sourceIds.isNotEmpty) 'sourceIds': sourceIds,
    };

final class _StaticHttpClient implements HttpClient {
  _StaticHttpClient(this.bytes);

  final List<int> bytes;

  Duration? _connectionTimeout;
  Duration _idleTimeout = const Duration(seconds: 15);

  @override
  Duration? get connectionTimeout => _connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _connectionTimeout = value;

  @override
  Duration get idleTimeout => _idleTimeout;

  @override
  set idleTimeout(Duration value) => _idleTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _StaticHttpClientRequest(bytes);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _GatedStaticHttpClient implements HttpClient {
  _GatedStaticHttpClient(this.bytes, this.gate);

  final List<int> bytes;
  final Future<void> gate;
  final Completer<void> requestStarted = Completer<void>();

  Duration? _connectionTimeout;
  Duration _idleTimeout = const Duration(seconds: 15);

  @override
  Duration? get connectionTimeout => _connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _connectionTimeout = value;

  @override
  Duration get idleTimeout => _idleTimeout;

  @override
  set idleTimeout(Duration value) => _idleTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return _GatedStaticHttpClientRequest(bytes, gate);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _GatedStaticHttpClientRequest implements HttpClientRequest {
  _GatedStaticHttpClientRequest(this.bytes, this.gate);

  final List<int> bytes;
  final Future<void> gate;
  final HttpHeaders _headers = _NoopHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async {
    await gate;
    return _StaticHttpClientResponse(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StaticHttpClientRequest implements HttpClientRequest {
  _StaticHttpClientRequest(this.bytes);

  final List<int> bytes;
  final HttpHeaders _headers = _NoopHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() async => _StaticHttpClientResponse(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StaticHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _StaticHttpClientResponse(this.bytes);

  final List<int> bytes;
  final HttpHeaders _headers = _NoopHttpHeaders();

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bytes.length;

  @override
  bool get isRedirect => false;

  @override
  HttpHeaders get headers => _headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(bytes).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BlockingHttpClient implements HttpClient {
  Duration? _connectionTimeout;
  Duration _idleTimeout = const Duration(seconds: 15);
  final Completer<void> requestStarted = Completer<void>();
  final _BlockingHttpClientRequest _request = _BlockingHttpClientRequest();
  bool forceClosed = false;

  @override
  Duration? get connectionTimeout => _connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _connectionTimeout = value;

  @override
  Duration get idleTimeout => _idleTimeout;

  @override
  set idleTimeout(Duration value) => _idleTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (!requestStarted.isCompleted) requestStarted.complete();
    return _request;
  }

  @override
  void close({bool force = false}) {
    forceClosed = forceClosed || force;
    _request.fail();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BlockingHttpClientRequest implements HttpClientRequest {
  final Completer<HttpClientResponse> _response =
      Completer<HttpClientResponse>();
  final HttpHeaders _headers = _NoopHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  void add(List<int> data) {}

  @override
  Future<HttpClientResponse> close() => _response.future;

  void fail() {
    if (!_response.isCompleted) {
      _response.completeError(const HttpException('client closed'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _NoopHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
