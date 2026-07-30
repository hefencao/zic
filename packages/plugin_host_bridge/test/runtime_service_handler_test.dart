import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File payload;
  late String payloadHash;
  late AndroidExternalPluginRuntimeServiceHandler handler;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zic-runtime-handler-');
    payload = File('${root.path}/fixture.apk');
    await payload.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    payloadHash = sha256.convert(await payload.readAsBytes()).toString();
    handler = AndroidExternalPluginRuntimeServiceHandler(
      endpoint: ExternalPluginRuntimeServiceEndpoint(
        processHost: ExternalPluginRuntimeProcessHost(
          factories: <ExternalPluginRuntimeDriverFactory>[
            _HandlerDriverFactory(),
          ],
          payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
            verifiedDirectory: Directory('${root.path}/verified'),
          ),
          sessionIdFactory: (_) => 'session-1',
        ),
        processId: 'process-1',
      ),
      channel: const MethodChannel('dev.zic/runtime-service-handler-test'),
    );
    handler.attach();
  });

  tearDown(() async {
    await handler.detach();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('handler delegates raw methods to the process endpoint', () async {
    final activation = Map<String, Object?>.from(
      (await handler.dispatch(
        MethodCall(
          ExternalPluginRuntimeServiceMethods.activateMihon,
          _mihonMessage(payload, payloadHash),
        ),
      ))! as Map<Object?, Object?>,
    );
    expect(activation['processId'], 'process-1');
    expect(activation['sessionId'], 'session-1');

    final response = ExternalPluginRuntimeResponse.fromMessage(
      await handler.dispatch(
        MethodCall(
          ExternalPluginRuntimeServiceMethods.invoke,
          <String, Object?>{
            'processId': 'process-1',
            'sessionId': 'session-1',
            'request': ExternalPluginRuntimeRequest.loadResource(
              requestId: 'resource-1',
              externalSourceId: 'fixture',
              uri: Uri.parse('https://cdn.invalid/page.webp'),
            ).toMessage(),
          },
        ),
      ),
    );
    expect(response.payload, orderedEquals(<int>[4, 5, 6]));
  });

  test('handler maps stale generations to a stable platform error', () async {
    await expectLater(
      handler.dispatch(
        MethodCall(
          ExternalPluginRuntimeServiceMethods.invoke,
          <String, Object?>{
            'processId': 'dead-process',
            'sessionId': 'session-1',
            'request': ExternalPluginRuntimeRequest.browse(
              requestId: 'must-not-replay',
              externalSourceId: 'fixture',
              query: '',
              offset: 0,
              limit: 24,
            ).toMessage(),
          },
        ),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'runtime-process-mismatch',
        ),
      ),
    );
  });

  test('detach closes the process and is joinable', () async {
    final first = handler.detach();
    final second = handler.detach();
    expect(identical(first, second), isTrue);
    await first;

    await expectLater(
      handler.dispatch(
        MethodCall(
          ExternalPluginRuntimeServiceMethods.activateMihon,
          _mihonMessage(payload, payloadHash),
        ),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'runtime-process-closing',
        ),
      ),
    );
  });
}

Map<String, Object?> _mihonMessage(File payload, String hash) =>
    <String, Object?>{
      'schemaVersion': 1,
      'format': ExternalComicPluginFormat.mihonExtension.name,
      'pluginId': 'mihon:fixture',
      'pluginVersion': '1.0.0',
      'payloadPath': payload.path,
      'payloadByteLength': 4,
      'payloadSha256': hash,
      'packageName': 'dev.fixture.extension',
      'signerSha256': List<String>.filled(64, 'a').join(),
      'versionCode': 1,
      'extensionLib': '1.6',
      'entryClasses': const <String>['dev.fixture.Extension'],
      'capabilities': const <String>['network'],
      'limits': const ExternalPluginRuntimeLimits().toMessage(),
    };

final class _HandlerDriverFactory
    implements ExternalPluginRuntimeDriverFactory {
  @override
  ExternalComicPluginFormat get format =>
      ExternalComicPluginFormat.mihonExtension;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeDriver> create(
    ExternalPluginRuntimeActivationEnvelope activation,
    ExternalPluginRuntimeVerifiedPayload payload,
  ) async => _HandlerDriver();
}

final class _HandlerDriver implements ExternalPluginRuntimeDriver {
  @override
  String get runtimeId => 'fixture-runtime';

  @override
  List<ExternalPluginRuntimeSourceDescriptor> get sources =>
      <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: 'fixture',
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
        ),
      ];

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async => Uint8List.fromList(<int>[4, 5, 6]);

  @override
  Future<void> close() async {}
}
