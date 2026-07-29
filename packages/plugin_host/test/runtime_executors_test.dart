import 'package:catalog/catalog.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  test('Mihon executor forwards the exact trusted immutable payload', () async {
    final backend = _MihonBackend();
    final executor = MihonIsolatedExecutor(backend: backend);
    final plugin = _plugin(ExternalComicPluginFormat.mihonExtension);
    final session = await executor.activate(
      plugin,
      ExternalPluginInspection(
        format: ExternalComicPluginFormat.mihonExtension,
        payloadSha256: 'aa',
        payloadPath: '/cache/extension.apk',
        payloadByteLength: 123,
        packageName: 'org.example.extension',
        signerSha256: 'bb',
        versionCode: 7,
        extensionLib: 'tachiyomix-1.6',
        mihonEntryClasses: const <String>[
          'org.example.extension.ExampleFactory',
        ],
      ),
    );

    expect(backend.request?.payloadPath, '/cache/extension.apk');
    expect(backend.request?.payloadByteLength, 123);
    expect(backend.request?.payloadSha256, 'aa');
    expect(
      backend.request?.entryClasses,
      <String>['org.example.extension.ExampleFactory'],
    );
    expect(session, same(backend.session));
  });

  test('Venera executor forwards limits and one inspected source key', () async {
    final backend = _VeneraBackend();
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(seconds: 3),
      maxResponseBytes: 1024,
      maxConcurrentInvocations: 1,
      maxRuntimeHeapBytes: 4096,
    );
    final executor = VeneraSandboxExecutor(backend: backend, limits: limits);
    final plugin = _plugin(ExternalComicPluginFormat.veneraJavaScript);

    await executor.activate(
      plugin,
      ExternalPluginInspection(
        format: ExternalComicPluginFormat.veneraJavaScript,
        payloadSha256: 'cc',
        payloadPath: '/cache/source.js',
        payloadByteLength: 88,
        sourceKey: 'example',
      ),
    );

    expect(backend.request?.payloadPath, '/cache/source.js');
    expect(backend.request?.sourceKey, 'example');
    expect(backend.request?.payloadSha256, 'cc');
    expect(backend.request?.limits, same(limits));
  });

  test('executor rejects a backend that cannot enforce limits', () {
    final backend = _MihonBackend(supports: false);
    final executor = MihonIsolatedExecutor(backend: backend);

    expect(
      () => executor.activate(
        _plugin(ExternalComicPluginFormat.mihonExtension),
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.mihonExtension,
          payloadSha256: 'aa',
          payloadPath: '/cache/extension.apk',
          payloadByteLength: 123,
          packageName: 'org.example.extension',
          signerSha256: 'bb',
          versionCode: 7,
          extensionLib: 'tachiyomix-1.6',
          mihonEntryClasses: const <String>[
            'org.example.extension.ExampleFactory',
          ],
        ),
      ),
      throwsStateError,
    );
    expect(backend.request, isNull);
  });

  test('executor rejects a plugin whose format does not match the request', () {
    final backend = _MihonBackend();
    final executor = MihonIsolatedExecutor(backend: backend);

    expect(
      () => executor.activate(
        _plugin(ExternalComicPluginFormat.veneraJavaScript),
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.mihonExtension,
          payloadSha256: 'aa',
          payloadPath: '/cache/extension.apk',
          payloadByteLength: 123,
          packageName: 'org.example.extension',
          signerSha256: 'bb',
          versionCode: 7,
          extensionLib: 'tachiyomix-1.6',
          mihonEntryClasses: const <String>[
            'org.example.extension.ExampleFactory',
          ],
        ),
      ),
      throwsStateError,
    );
    expect(backend.request, isNull);
  });

  test('executors reject incomplete inspection before backend activation', () {
    final backend = _MihonBackend();
    final executor = MihonIsolatedExecutor(backend: backend);

    expect(
      () => executor.activate(
        _plugin(ExternalComicPluginFormat.mihonExtension),
        ExternalPluginInspection(
          format: ExternalComicPluginFormat.mihonExtension,
          payloadSha256: 'aa',
        ),
      ),
      throwsStateError,
    );
    expect(backend.request, isNull);
  });
}

ExternalComicPluginCatalogEntry _plugin(ExternalComicPluginFormat format) =>
    ExternalComicPluginCatalogEntry(
      format: format,
      pluginId: format == ExternalComicPluginFormat.mihonExtension
          ? 'mihon:org.example.extension'
          : 'venera:example',
      name: 'Example',
      version: '1.0.0',
      entrypoint: Uri.parse(
        format == ExternalComicPluginFormat.mihonExtension
            ? 'https://example.invalid/extension.apk'
            : 'https://example.invalid/source.js',
      ),
      sources: const <ExternalComicPluginSource>[],
    );

final class _MihonBackend implements MihonIsolatedRuntimeBackend {
  _MihonBackend({this.supports = true});

  final bool supports;
  MihonExecutionRequest? request;
  final _Session session = _Session();

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => supports;

  @override
  Future<ExternalComicPluginSession> activate(
    MihonExecutionRequest value,
  ) async {
    request = value;
    return session;
  }
}

final class _VeneraBackend implements VeneraSandboxRuntimeBackend {
  VeneraExecutionRequest? request;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalComicPluginSession> activate(
    VeneraExecutionRequest value,
  ) async {
    request = value;
    return _Session();
  }
}

final class _Session implements ExternalComicPluginSession {
  @override
  ExternalComicPluginCatalogEntry get plugin =>
      _plugin(ExternalComicPluginFormat.veneraJavaScript);

  @override
  List<BrowsableComicSource> get sources => const <BrowsableComicSource>[];

  @override
  Future<void> close() async {}
}
