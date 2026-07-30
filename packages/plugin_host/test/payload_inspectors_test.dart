import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('Venera inspector discovers a source key without executing script',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-venera-inspector-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/source.js');
    await script.writeAsString('''
class ReaderSource extends ComicSource {
  key = "reader-source";
  name = "Reader Source";
}
throw new Error("must never execute during inspection");
''');
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:https://example.invalid/source.js',
      name: 'Reader Source',
      version: '1.0.0',
      entrypoint: Uri.parse('https://example.invalid/source.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );
    final inspector = VeneraJavaScriptInspector(
      payloads: _payloadLoader(script),
    );

    final result = await inspector.inspect(plugin);

    expect(result.sourceKey, 'reader-source');
    expect(result.payloadPath, script.path);
    expect(result.payloadByteLength, await script.length());
    expect(result.payloadSha256, hasLength(64));
    expect(
      result.requestedCapabilities,
      contains(ExternalPluginCapability.network),
    );
  });

  test('Venera inspector rejects repository and script key mismatch',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-venera-key-mismatch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/source.js');
    await script.writeAsString('''
class ActualSource extends ComicSource {
  key = "actual";
}
''');
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:declared',
      name: 'Declared',
      version: '1.0.0',
      entrypoint: Uri.parse('https://example.invalid/source.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:declared',
          externalId: 'declared',
          name: 'Declared',
          language: 'en',
        ),
      ],
    );

    await expectLater(
      VeneraJavaScriptInspector(payloads: _payloadLoader(script))
          .inspect(plugin),
      throwsFormatException,
    );
  });


  test('Venera inspector ignores method-local key variables', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-venera-local-key-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/source.js');
    await script.writeAsString('''
class PicacgSource extends ComicSource {
  name = "Picacg" key = "picacg" version = "1.0.5"
  createSignature() {
    let key = "request-signing-secret"
    return key
  }
}
''');
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:picacg',
      name: 'Picacg',
      version: '1.0.0',
      entrypoint: Uri.parse('https://example.invalid/picacg.js'),
      sources: const <ExternalComicPluginSource>[
        ExternalComicPluginSource(
          sourceId: 'venera:picacg',
          externalId: 'picacg',
          name: 'Picacg',
          language: 'zh',
        ),
      ],
    );

    final result = await VeneraJavaScriptInspector(
      payloads: _payloadLoader(script),
    ).inspect(plugin);

    expect(result.sourceKey, 'picacg');
  });

  test('Venera inspector rejects invalid UTF-8 without executing payload',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-venera-invalid-utf8-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/source.js');
    await script.writeAsBytes(<int>[0xff, 0xfe, 0xfd]);
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.veneraJavaScript,
      pluginId: 'venera:https://example.invalid/source.js',
      name: 'Invalid',
      version: '1.0.0',
      entrypoint: Uri.parse('https://example.invalid/source.js'),
      sources: const <ExternalComicPluginSource>[],
      requiresRuntimeDiscovery: true,
    );

    await expectLater(
      VeneraJavaScriptInspector(payloads: _payloadLoader(script))
          .inspect(plugin),
      throwsFormatException,
    );
  });

  test('Mihon inspector streams APK digest and reads metadata without loading',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-mihon-inspector-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final apk = File('${directory.path}/extension.apk');
    await apk.writeAsBytes(List<int>.generate(1024, (index) => index & 0xff));
    final metadata = _MihonMetadataReader();
    final plugin = ExternalComicPluginCatalogEntry(
      format: ExternalComicPluginFormat.mihonExtension,
      pluginId: 'mihon:org.example.extension',
      name: 'Example',
      version: '1.2.3',
      versionCode: 12,
      entrypoint: Uri.parse('https://example.invalid/extension.apk'),
      sources: const <ExternalComicPluginSource>[],
    );

    final result = await MihonApkInspector(
      payloads: _payloadLoader(apk),
      metadata: metadata,
    ).inspect(plugin);

    expect(metadata.paths, <String>[apk.path]);
    expect(result.packageName, 'org.example.extension');
    expect(result.versionCode, 12);
    expect(result.extensionLib, 'tachiyomix-1.6');
    expect(result.mihonEntryClasses, <String>['org.example.extension.Source']);
    expect(result.payloadSha256, hasLength(64));
    expect(
      result.requestedCapabilities,
      contains(ExternalPluginCapability.nativeCode),
    );
  });
}

ExternalPluginPayloadLoader _payloadLoader(File file) =>
    CallbackExternalPluginPayloadLoader(
      (_) async => ExternalPluginPayloadFile(
        path: file.path,
        byteLength: await file.length(),
      ),
    );

final class _MihonMetadataReader implements MihonApkMetadataReader {
  final List<String> paths = <String>[];

  @override
  Future<MihonApkMetadata> readMetadata(String apkPath) async {
    paths.add(apkPath);
    return MihonApkMetadata(
      packageName: 'org.example.extension',
      signerSha256: 'aa',
      versionCode: 12,
      extensionLib: 'tachiyomix-1.6',
      entryClasses: <String>['org.example.extension.Source'],
    );
  }
}
