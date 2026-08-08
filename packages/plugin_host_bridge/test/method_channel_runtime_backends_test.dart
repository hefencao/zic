import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.zic/plugin_host_runtime_bridge-test');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Mihon backend serializes activation and owns invoke/cancel/close',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        ExternalPluginRuntimeServiceMethods.activateMihon => <String, Object?>{
            'processId': 'process-1',
            'sessionId': 'mihon-session-1',
            'handshake': _handshake('mihon-runtime'),
          },
        ExternalPluginRuntimeServiceMethods.invoke =>
          ExternalPluginRuntimeResponse.success(
            requestId: 'request-1',
            payload: Uint8List.fromList(<int>[1, 2, 3]),
          ).toMessage(),
        ExternalPluginRuntimeServiceMethods.cancel => null,
        ExternalPluginRuntimeServiceMethods.closeSession => null,
        _ => throw MissingPluginException(call.method),
      };
    });

    final backend = AndroidMihonIsolatedRuntimeBackend(channel: channel);
    final connection = await backend.activate(_mihonRequest());
    final response = await connection.invoke(
      ExternalPluginRuntimeRequest.loadResource(
        requestId: 'request-1',
        externalSourceId: 'fixture',
        uri: Uri.parse('https://cdn.invalid/page.webp'),
      ),
    );
    await (connection as CancellableExternalPluginRuntimeConnection)
        .cancel('request-1');
    final firstClose = connection.close();
    final secondClose = connection.close();
    expect(identical(firstClose, secondClose), isTrue);
    await firstClose;

    expect(response.payload, <int>[1, 2, 3]);
    expect(calls.map((call) => call.method), <String>[
      ExternalPluginRuntimeServiceMethods.activateMihon,
      ExternalPluginRuntimeServiceMethods.invoke,
      ExternalPluginRuntimeServiceMethods.cancel,
      ExternalPluginRuntimeServiceMethods.closeSession,
    ]);
    final activation = calls.first.arguments! as Map<Object?, Object?>;
    expect(activation['payloadPath'], '/cache/fixture.apk');
    expect(activation['packageName'], 'dev.fixture.extension');
    expect(activation['entryClasses'], <String>['dev.fixture.Extension']);
    expect(
      (activation['limits']! as Map<Object?, Object?>)[
          'maxConcurrentInvocations'],
      2,
    );
    final invoke = calls[1].arguments! as Map<Object?, Object?>;
    expect(invoke['processId'], 'process-1');
    expect(invoke['sessionId'], 'mihon-session-1');
    expect(invoke['request'], isA<Map<Object?, Object?>>());
    final cancel = calls[2].arguments! as Map<Object?, Object?>;
    final close = calls[3].arguments! as Map<Object?, Object?>;
    expect(cancel['processId'], 'process-1');
    expect(close['processId'], 'process-1');
  });

  test('Venera backend uses the same raw runtime channel contract', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        ExternalPluginRuntimeServiceMethods.activateVenera => <String, Object?>{
            'processId': 'process-2',
            'sessionId': 'venera-session-1',
            'handshake': _handshake('venera-runtime'),
          },
        ExternalPluginRuntimeServiceMethods.closeSession => null,
        _ => throw MissingPluginException(call.method),
      };
    });

    final backend = AndroidVeneraSandboxRuntimeBackend(channel: channel);
    final connection = await backend.activate(_veneraRequest());
    await connection.close();

    expect(calls.map((call) => call.method), <String>[
      ExternalPluginRuntimeServiceMethods.activateVenera,
      ExternalPluginRuntimeServiceMethods.closeSession,
    ]);
    final activation = calls.first.arguments! as Map<Object?, Object?>;
    expect(activation['sourceKey'], 'fixture');
    expect(activation['payloadPath'], '/cache/fixture.js');
  });

  test('Venera activation rebinds once when runtime service dies', () async {
    final calls = <MethodCall>[];
    var activations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        ExternalPluginRuntimeServiceMethods.activateVenera =>
          activations++ == 0
              ? throw PlatformException(
                  code: 'runtime-service-died',
                  message: 'runtime service process died during activation',
                )
              : <String, Object?>{
                  'processId': 'rebound-process',
                  'sessionId': 'venera-session-2',
                  'handshake': _handshake('venera-runtime'),
                },
        ExternalPluginRuntimeServiceMethods.closeSession => null,
        _ => throw MissingPluginException(call.method),
      };
    });

    final backend = AndroidVeneraSandboxRuntimeBackend(channel: channel);
    final connection = await backend.activate(_veneraRequest());
    await connection.close();

    expect(activations, 2);
    expect(
      calls.map((call) => call.method),
      <String>[
        ExternalPluginRuntimeServiceMethods.activateVenera,
        ExternalPluginRuntimeServiceMethods.activateVenera,
        ExternalPluginRuntimeServiceMethods.closeSession,
      ],
    );
  });

  test('Venera activation does not replay plugin activation errors', () async {
    var activations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == ExternalPluginRuntimeServiceMethods.activateVenera) {
        activations++;
        throw PlatformException(
          code: 'runtime-request-invalid',
          message: 'plugin activation payload rejected',
        );
      }
      throw MissingPluginException(call.method);
    });

    final backend = AndroidVeneraSandboxRuntimeBackend(channel: channel);
    await expectLater(
      backend.activate(_veneraRequest()),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'runtime-request-invalid',
        ),
      ),
    );
    expect(activations, 1);
  });

  test('stale process is reactivated and the invocation is replayed once',
      () async {
    final calls = <MethodCall>[];
    var activations = 0;
    var invocations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        ExternalPluginRuntimeServiceMethods.activateMihon =>
          <String, Object?>{
            'processId': activations++ == 0
                ? 'dead-process'
                : 'recovered-process',
            'sessionId': activations == 1
                ? 'stale-session'
                : 'recovered-session',
            'handshake': _handshake('mihon-runtime'),
          },
        ExternalPluginRuntimeServiceMethods.invoke => invocations++ == 0
            ? throw PlatformException(
                code: 'runtime-process-mismatch',
                message: 'runtime service restarted',
              )
            : ExternalPluginRuntimeResponse.success(
                requestId: 'replayed',
                payload: <String, Object?>{
                  'items': <Object?>[],
                  'offset': 0,
                  'hasMore': false,
                },
              ).toMessage(),
        _ => null,
      };
    });

    final backend = AndroidMihonIsolatedRuntimeBackend(channel: channel);
    final connection = await backend.activate(_mihonRequest());
    final response = await connection.invoke(
      ExternalPluginRuntimeRequest.browse(
        requestId: 'replayed',
        externalSourceId: 'fixture',
        query: '',
        offset: 0,
        limit: 24,
      ),
    );
    expect(response.isSuccess, isTrue);

    expect(
      calls.map((call) => call.method),
      <String>[
        ExternalPluginRuntimeServiceMethods.activateMihon,
        ExternalPluginRuntimeServiceMethods.invoke,
        ExternalPluginRuntimeServiceMethods.activateMihon,
        ExternalPluginRuntimeServiceMethods.invoke,
      ],
    );
    final replay = calls.last.arguments! as Map<Object?, Object?>;
    expect(replay['processId'], 'recovered-process');
    expect(replay['sessionId'], 'recovered-session');
  });

  test('platform support rejects an unenforceable runtime envelope', () {
    const support = PlatformExternalPluginRuntimeSupport(
      maxRuntimeHeapBytes: 1024,
    );
    expect(
      support.supports(
        const ExternalPluginRuntimeLimits(maxRuntimeHeapBytes: 2048),
      ),
      isFalse,
    );
  });
}

Map<String, Object?> _handshake(String runtimeId) =>
    ExternalPluginRuntimeHandshake(
      runtimeId: runtimeId,
      sources: <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
        ),
      ],
    ).toMessage();

MihonExecutionRequest _mihonRequest() => MihonExecutionRequest(
      plugin: _plugin(ExternalComicPluginFormat.mihonExtension),
      payloadPath: '/cache/fixture.apk',
      payloadByteLength: 12,
      payloadSha256: 'aa',
      packageName: 'dev.fixture.extension',
      signerSha256: 'bb',
      versionCode: 1,
      extensionLib: '1.6',
      entryClasses: const <String>['dev.fixture.Extension'],
      capabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network,
      },
      limits: const ExternalPluginRuntimeLimits(
        maxConcurrentInvocations: 2,
      ),
    );

VeneraExecutionRequest _veneraRequest() => VeneraExecutionRequest(
      plugin: _plugin(ExternalComicPluginFormat.veneraJavaScript),
      payloadPath: '/cache/fixture.js',
      payloadByteLength: 12,
      payloadSha256: 'cc',
      sourceKey: 'fixture',
      capabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network,
      },
      limits: const ExternalPluginRuntimeLimits(),
    );

ExternalComicPluginCatalogEntry _plugin(ExternalComicPluginFormat format) =>
    ExternalComicPluginCatalogEntry(
      format: format,
      pluginId: format == ExternalComicPluginFormat.mihonExtension
          ? 'mihon:fixture'
          : 'venera:fixture',
      name: 'Fixture',
      version: '1.0.0',
      entrypoint: Uri.parse('https://repo.invalid/fixture'),
      sources: const <ExternalComicPluginSource>[],
    );
