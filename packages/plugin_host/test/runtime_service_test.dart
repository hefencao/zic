import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory verified;
  late File payload;
  late String payloadHash;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zic-runtime-service-');
    verified = Directory('${root.path}/verified');
    payload = File('${root.path}/fixture.apk');
    await payload.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    payloadHash = sha256.convert(await payload.readAsBytes()).toString();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('service endpoint owns activation invoke cancel and close routing',
      () async {
    final factory = _ServiceDriverFactory();
    final endpoint = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[factory],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
        sessionIdFactory: (_) => 'session-1',
      ),
      processId: 'process-1',
    );

    final activatedValue = await endpoint.handle(
      ExternalPluginRuntimeServiceMethods.activateMihon,
      _mihonMessage(payload, payloadHash),
    );
    final activated = Map<String, Object?>.from(
      activatedValue! as Map<Object?, Object?>,
    );
    expect(activated['processId'], 'process-1');
    expect(activated['sessionId'], 'session-1');

    final response = ExternalPluginRuntimeResponse.fromMessage(
      await endpoint.handle(
        ExternalPluginRuntimeServiceMethods.invoke,
        <String, Object?>{
          'processId': 'process-1',
          'sessionId': 'session-1',
          'request': ExternalPluginRuntimeRequest.loadResource(
            requestId: 'request-1',
            externalSourceId: 'fixture',
            uri: Uri.parse('https://cdn.invalid/page.webp'),
          ).toMessage(),
        },
      ),
    );
    expect(response.payload, orderedEquals(<int>[7, 8, 9]));

    await endpoint.handle(
      ExternalPluginRuntimeServiceMethods.cancel,
      const <String, Object?>{
        'processId': 'process-1',
        'sessionId': 'session-1',
        'requestId': 'request-1',
      },
    );
    await endpoint.handle(
      ExternalPluginRuntimeServiceMethods.closeSession,
      const <String, Object?>{
        'processId': 'process-1',
        'sessionId': 'session-1',
      },
    );
    expect(endpoint.activeSessionCount, 0);
    expect(factory.driver?.closed, isTrue);
  });

  test('Venera activation uses the same service endpoint contract', () async {
    final factory = _ServiceDriverFactory(
      format: ExternalComicPluginFormat.veneraJavaScript,
      sourceId: 'fixture-venera',
    );
    final endpoint = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[factory],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
        sessionIdFactory: (_) => 'venera-session',
      ),
      processId: 'process-venera',
    );

    final activatedValue = await endpoint.handle(
      ExternalPluginRuntimeServiceMethods.activateVenera,
      _veneraMessage(payload, payloadHash),
    );
    final activated = Map<String, Object?>.from(
      activatedValue! as Map<Object?, Object?>,
    );
    final handshake = ExternalPluginRuntimeHandshake.fromMessage(
      activated['handshake'],
    );

    expect(activated['processId'], 'process-venera');
    expect(activated['sessionId'], 'venera-session');
    expect(handshake.sources.single.externalId, 'fixture-venera');
    await endpoint.close();
  });

  test('new service process rejects an old process generation', () async {
    final old = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[
          _ServiceDriverFactory(),
        ],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
        sessionIdFactory: (_) => 'reused-session-id',
      ),
      processId: 'old-process',
    );
    final activatedValue = await old.handle(
      ExternalPluginRuntimeServiceMethods.activateMihon,
      _mihonMessage(payload, payloadHash),
    );
    final activated = Map<String, Object?>.from(
      activatedValue! as Map<Object?, Object?>,
    );
    expect(activated['sessionId'], 'reused-session-id');
    await old.close();

    final restarted = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[
          _ServiceDriverFactory(),
        ],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
        sessionIdFactory: (_) => 'reused-session-id',
      ),
      processId: 'new-process',
    );

    await expectLater(
      restarted.handle(
        ExternalPluginRuntimeServiceMethods.invoke,
        <String, Object?>{
          'processId': 'old-process',
          'sessionId': 'reused-session-id',
          'request': ExternalPluginRuntimeRequest.browse(
            requestId: 'must-not-replay',
            externalSourceId: 'fixture',
            query: '',
            offset: 0,
            limit: 24,
          ).toMessage(),
        },
      ),
      throwsA(
        isA<ExternalPluginRuntimeServiceException>().having(
          (error) => error.code,
          'code',
          'runtime-process-mismatch',
        ),
      ),
    );
    expect(restarted.activeSessionCount, 0);
    await restarted.close();
  });

  test('activation method must match the payload ecosystem', () async {
    final endpoint = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[
          _ServiceDriverFactory(),
        ],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
      ),
      processId: 'process-1',
    );

    await expectLater(
      endpoint.handle(
        ExternalPluginRuntimeServiceMethods.activateVenera,
        _mihonMessage(payload, payloadHash),
      ),
      throwsA(
        isA<ExternalPluginRuntimeServiceException>().having(
          (error) => error.code,
          'code',
          'runtime-format-mismatch',
        ),
      ),
    );
    expect(endpoint.activeSessionCount, 0);
    await endpoint.close();
  });

  test('process close is joinable and rejects later activation', () async {
    final closeGate = Completer<void>();
    final endpoint = ExternalPluginRuntimeServiceEndpoint(
      processHost: ExternalPluginRuntimeProcessHost(
        factories: <ExternalPluginRuntimeDriverFactory>[
          _ServiceDriverFactory(closeGate: closeGate),
        ],
        payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
          verifiedDirectory: verified,
        ),
      ),
      processId: 'process-1',
    );
    await endpoint.handle(
      ExternalPluginRuntimeServiceMethods.activateMihon,
      _mihonMessage(payload, payloadHash),
    );

    final first = endpoint.close();
    final second = endpoint.close();
    expect(identical(first, second), isTrue);
    closeGate.complete();
    await first;

    await expectLater(
      endpoint.handle(
        ExternalPluginRuntimeServiceMethods.activateMihon,
        _mihonMessage(payload, payloadHash),
      ),
      throwsA(
        isA<ExternalPluginRuntimeServiceException>().having(
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


Map<String, Object?> _veneraMessage(File payload, String hash) =>
    <String, Object?>{
      'schemaVersion': 1,
      'format': ExternalComicPluginFormat.veneraJavaScript.name,
      'pluginId': 'venera:fixture-venera',
      'pluginVersion': '1.0.0',
      'payloadPath': payload.path,
      'payloadByteLength': 4,
      'payloadSha256': hash,
      'sourceKey': 'fixture-venera',
      'capabilities': const <String>['network'],
      'limits': const ExternalPluginRuntimeLimits().toMessage(),
    };

final class _ServiceDriverFactory
    implements ExternalPluginRuntimeDriverFactory {
  _ServiceDriverFactory({
    this.format = ExternalComicPluginFormat.mihonExtension,
    this.sourceId = 'fixture',
    this.closeGate,
  });

  @override
  final ExternalComicPluginFormat format;
  final String sourceId;
  final Completer<void>? closeGate;
  _ServiceDriver? driver;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeDriver> create(
    ExternalPluginRuntimeActivationEnvelope activation,
    ExternalPluginRuntimeVerifiedPayload payload,
  ) async => driver = _ServiceDriver(
        sourceId: sourceId,
        closeGate: closeGate,
      );
}

final class _ServiceDriver implements ExternalPluginRuntimeDriver {
  _ServiceDriver({
    required this.sourceId,
    this.closeGate,
  });

  final String sourceId;
  final Completer<void>? closeGate;
  bool closed = false;

  @override
  String get runtimeId => 'fixture-runtime';

  @override
  List<ExternalPluginRuntimeSourceDescriptor> get sources =>
      <ExternalPluginRuntimeSourceDescriptor>[
        ExternalPluginRuntimeSourceDescriptor(
          externalId: sourceId,
          name: 'Fixture',
          language: 'en',
          website: Uri.parse('https://example.invalid'),
        ),
      ];

  @override
  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    if (request.operation == ExternalPluginRuntimeOperation.loadResource) {
      return Uint8List.fromList(<int>[7, 8, 9]);
    }
    return const <String, Object?>{
      'items': <Object?>[],
      'nextOffset': null,
    };
  }

  @override
  Future<void> close() async {
    final gate = closeGate;
    if (gate != null) {
      await gate.future;
    }
    closed = true;
  }
}
