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
    expect(session.sources.single.sourceId, 'mihon:123');
    await session.close();
    expect(backend.connection.closed, isTrue);
  });

  test('Venera default timeout bounds native network reads', () {
    final executor = VeneraSandboxExecutor(backend: _VeneraBackend());
    expect(executor.limits.invocationTimeout, const Duration(seconds: 15));
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

    final session = await executor.activate(
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
    expect(session.sources.single.sourceId, 'venera:example');
    await session.close();
  });

  test('executor rejects a backend that cannot enforce limits', () async {
    final backend = _MihonBackend(supports: false);
    final executor = MihonIsolatedExecutor(backend: backend);

    await expectLater(
      executor.activate(
        _plugin(ExternalComicPluginFormat.mihonExtension),
        _mihonInspection(),
      ),
      throwsStateError,
    );
    expect(backend.request, isNull);
  });

  test('runtime duration is validated at activation, not const evaluation',
      () async {
    final backend = _MihonBackend();
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration.zero,
    );
    final executor = MihonIsolatedExecutor(
      backend: backend,
      limits: limits,
    );

    await expectLater(
      executor.activate(
        _plugin(ExternalComicPluginFormat.mihonExtension),
        _mihonInspection(),
      ),
      throwsArgumentError,
    );
    expect(backend.request, isNull);
  });

  test('runtime limit wire representation round-trips exactly', () {
    const limits = ExternalPluginRuntimeLimits(
      invocationTimeout: Duration(milliseconds: 250),
      maxResponseBytes: 4096,
      maxConcurrentInvocations: 2,
      maxRuntimeHeapBytes: 8192,
    );

    final restored = ExternalPluginRuntimeLimits.fromMessage(
      limits.toMessage(),
    );

    expect(restored.invocationTimeout, limits.invocationTimeout);
    expect(restored.maxResponseBytes, limits.maxResponseBytes);
    expect(
      restored.maxConcurrentInvocations,
      limits.maxConcurrentInvocations,
    );
    expect(restored.maxRuntimeHeapBytes, limits.maxRuntimeHeapBytes);
  });


  test('execution request constructors reject cross-format payloads', () {
    expect(
      () => MihonExecutionRequest(
        plugin: _plugin(ExternalComicPluginFormat.veneraJavaScript),
        payloadPath: '/cache/extension.apk',
        payloadByteLength: 1,
        payloadSha256: 'aa',
        packageName: 'org.example.extension',
        signerSha256: 'bb',
        versionCode: 1,
        extensionLib: '1.6',
        entryClasses: const <String>['org.example.Extension'],
        capabilities: const <ExternalPluginCapability>{},
        limits: const ExternalPluginRuntimeLimits(),
      ),
      throwsArgumentError,
    );
    expect(
      () => VeneraExecutionRequest(
        plugin: _plugin(ExternalComicPluginFormat.mihonExtension),
        payloadPath: '/cache/source.js',
        payloadByteLength: 1,
        payloadSha256: 'cc',
        sourceKey: 'example',
        capabilities: const <ExternalPluginCapability>{},
        limits: const ExternalPluginRuntimeLimits(),
      ),
      throwsArgumentError,
    );
  });

  test('executor rejects a plugin whose format does not match the request',
      () async {
    final backend = _MihonBackend();
    final executor = MihonIsolatedExecutor(backend: backend);

    await expectLater(
      executor.activate(
        _plugin(ExternalComicPluginFormat.veneraJavaScript),
        _mihonInspection(),
      ),
      throwsStateError,
    );
    expect(backend.request, isNull);
  });

  test('executors reject incomplete inspection before backend activation',
      () async {
    final backend = _MihonBackend();
    final executor = MihonIsolatedExecutor(backend: backend);

    await expectLater(
      executor.activate(
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

  test('invalid runtime source handshake closes the backend connection',
      () async {
    final connection = _Connection(
      descriptors: <ExternalPluginRuntimeSourceDescriptor>[
        _descriptor('duplicate'),
        _descriptor('duplicate'),
      ],
    );
    final backend = _MihonBackend(connection: connection);
    final executor = MihonIsolatedExecutor(backend: backend);

    await expectLater(
      executor.activate(
        _plugin(ExternalComicPluginFormat.mihonExtension),
        _mihonInspection(),
      ),
      throwsStateError,
    );
    expect(connection.closed, isTrue);
  });
}

ExternalPluginInspection _mihonInspection() => ExternalPluginInspection(
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
    );

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

ExternalPluginRuntimeSourceDescriptor _descriptor(String externalId) =>
    ExternalPluginRuntimeSourceDescriptor(
      externalId: externalId,
      name: 'Example',
      language: 'en',
      website: Uri.parse('https://example.invalid'),
    );

final class _MihonBackend implements MihonIsolatedRuntimeBackend {
  _MihonBackend({this.supports = true, _Connection? connection})
      : connection = connection ??
            _Connection(
              descriptors: <ExternalPluginRuntimeSourceDescriptor>[
                _descriptor('123'),
              ],
            );

  final bool supports;
  MihonExecutionRequest? request;
  final _Connection connection;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => supports;

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    MihonExecutionRequest value,
  ) async {
    request = value;
    return connection;
  }
}

final class _VeneraBackend implements VeneraSandboxRuntimeBackend {
  VeneraExecutionRequest? request;
  final _Connection connection = _Connection(
    descriptors: <ExternalPluginRuntimeSourceDescriptor>[
      _descriptor('example'),
    ],
  );

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    VeneraExecutionRequest value,
  ) async {
    request = value;
    return connection;
  }
}

final class _Connection implements ExternalPluginRuntimeConnection {
  _Connection({required List<ExternalPluginRuntimeSourceDescriptor> descriptors})
      : sources = List<ExternalPluginRuntimeSourceDescriptor>.unmodifiable(
          descriptors,
        );

  @override
  final List<ExternalPluginRuntimeSourceDescriptor> sources;

  bool closed = false;

  @override
  Future<ExternalPluginRuntimeResponse> invoke(
    ExternalPluginRuntimeRequest request,
  ) async =>
      ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'not-used',
          message: 'not used by executor tests',
        ),
      );

  @override
  Future<void> close() async {
    closed = true;
  }
}
