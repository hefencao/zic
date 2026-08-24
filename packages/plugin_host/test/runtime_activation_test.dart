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
    root = await Directory.systemTemp.createTemp('zic-runtime-activation-');
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

  test('process entry stages and revalidates the exact approved payload',
      () async {
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
      sessionIdFactory: (_) => 'session-1',
    );

    final activation = await host.activate(_mihonMessage(payload, payloadHash));

    expect(activation.sessionId, 'session-1');
    expect(activation.handshake.runtimeId, 'fixture-runtime');
    expect(factory.lastActivation, isA<MihonRuntimeActivationEnvelope>());
    expect(factory.lastPayload, isNotNull);
    expect(factory.lastPayload!.path, isNot(equals(payload.path)));
    expect(await File(factory.lastPayload!.path).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(factory.lastPayload!.sha256, payloadHash);
    await payload.writeAsBytes(<int>[9, 9, 9, 9], flush: true);
    expect(
      await File(factory.lastPayload!.path).readAsBytes(),
      <int>[1, 2, 3, 4],
    );

    final response = ExternalPluginRuntimeResponse.fromMessage(
      await host.invoke(
        activation.sessionId,
        ExternalPluginRuntimeRequest.loadResource(
          requestId: 'resource-1',
          externalSourceId: 'fixture',
          uri: Uri.parse('https://cdn.invalid/page.webp'),
        ).toMessage(),
      ),
    );
    expect(response.payload, orderedEquals(<int>[7, 8, 9]));

    final stagedPath = factory.lastPayload!.path;
    final firstClose = host.closeSession(activation.sessionId);
    final secondClose = host.closeSession(activation.sessionId);
    expect(identical(firstClose, secondClose), isTrue);
    await firstClose;
    expect(await File(stagedPath).exists(), isFalse);
    expect(factory.driver?.closed, isTrue);
  });

  test('independent process activations do not wait behind a slow sibling',
      () async {
    final createGate = Completer<void>();
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
      createGate: createGate,
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
      maxActiveSessions: 2,
      sessionIdFactory: (activation) => activation.pluginVersion,
    );
    final first = host.activate(_mihonMessage(payload, payloadHash));
    await factory.createStarted.future;
    final second = host.activate(
      _mihonMessage(payload, payloadHash)..['pluginVersion'] = '2.0.0',
    );

    await factory.secondCreateStarted.future.timeout(
      const Duration(seconds: 1),
    );
    expect(factory.createCount, 2);
    createGate.complete();
    await Future.wait(<Future<ExternalPluginRuntimeProcessActivation>>[
      first,
      second,
    ]);
    await host.close();
  });

  test('payload mutation is rejected before a driver is created', () async {
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
    );
    final message = _mihonMessage(payload, payloadHash);
    await payload.writeAsBytes(<int>[9, 9, 9, 9], flush: true);

    await expectLater(
      host.activate(message),
      throwsA(
        isA<ExternalPluginRuntimeProcessException>().having(
          (error) => error.code,
          'code',
          'payload-identity-mismatch',
        ),
      ),
    );
    expect(factory.createCount, 0);
    expect(await _directoryEntries(verified), isEmpty);
  });

  test('Venera activation must expose the inspected source key exactly once',
      () async {
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.veneraJavaScript,
      sourceId: 'other',
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
    );

    await expectLater(
      host.activate(_veneraMessage(payload, payloadHash)),
      throwsA(
        isA<ExternalPluginRuntimeProcessException>().having(
          (error) => error.code,
          'code',
          'source-identity-mismatch',
        ),
      ),
    );
    expect(factory.driver?.closed, isTrue);
    expect(await _directoryEntries(verified), isEmpty);
  });

  test('process restart has no sessions and never replays a request', () async {
    final firstFactory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
    );
    final first = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[firstFactory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
      sessionIdFactory: (_) => 'old-session',
    );
    final activation = await first.activate(_mihonMessage(payload, payloadHash));
    await first.close();

    final restarted = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[
        _FixtureDriverFactory(
          format: ExternalComicPluginFormat.mihonExtension,
        ),
      ],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
    );
    expect(restarted.activeSessionCount, 0);
    expect(
      () => restarted.invoke(
        activation.sessionId,
        ExternalPluginRuntimeRequest.loadResource(
          requestId: 'must-not-replay',
          externalSourceId: 'fixture',
          uri: Uri.parse('https://cdn.invalid/page.webp'),
        ).toMessage(),
      ),
      throwsA(
        isA<ExternalPluginRuntimeProcessException>().having(
          (error) => error.code,
          'code',
          'session-missing',
        ),
      ),
    );
  });


  test('process close rejects an activation whose driver is still starting',
      () async {
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
      createGate: Completer<void>(),
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
    );

    final activating = host.activate(_mihonMessage(payload, payloadHash));
    await factory.createStarted.future;
    final closing = host.close();
    factory.createGate!.complete();

    await expectLater(
      activating,
      throwsA(
        isA<ExternalPluginRuntimeProcessException>().having(
          (error) => error.code,
          'code',
          'process-closing',
        ),
      ),
    );
    await closing;
    expect(factory.driver?.closed, isTrue);
    expect(host.activeSessionCount, 0);
    expect(await _directoryEntries(verified), isEmpty);
  });

  test('closing sessions still count against the process session limit',
      () async {
    final closeGate = Completer<void>();
    final factory = _FixtureDriverFactory(
      format: ExternalComicPluginFormat.mihonExtension,
      driverCloseGate: closeGate,
    );
    final host = ExternalPluginRuntimeProcessHost(
      factories: <ExternalPluginRuntimeDriverFactory>[factory],
      payloadVerifier: FileExternalPluginRuntimePayloadVerifier(
        verifiedDirectory: verified,
      ),
      maxActiveSessions: 1,
    );
    final first = await host.activate(_mihonMessage(payload, payloadHash));
    final closing = host.closeSession(first.sessionId);

    await expectLater(
      host.activate(_mihonMessage(payload, payloadHash)),
      throwsA(
        isA<ExternalPluginRuntimeProcessException>().having(
          (error) => error.code,
          'code',
          'session-limit',
        ),
      ),
    );
    closeGate.complete();
    await closing;
  });

  test('activation wire is strict and rejects undeclared fields', () {
    final message = _mihonMessage(payload, payloadHash)..['unexpected'] = true;
    expect(
      () => ExternalPluginRuntimeActivationEnvelope.fromMessage(message),
      throwsFormatException,
    );
  });
}

final class _FixtureDriverFactory
    implements ExternalPluginRuntimeDriverFactory {
  _FixtureDriverFactory({
    required this.format,
    this.sourceId = 'fixture',
    this.createGate,
    this.driverCloseGate,
  });

  @override
  final ExternalComicPluginFormat format;
  final String sourceId;
  final Completer<void>? createGate;
  final Completer<void>? driverCloseGate;
  final Completer<void> createStarted = Completer<void>();
  final Completer<void> secondCreateStarted = Completer<void>();
  int createCount = 0;
  ExternalPluginRuntimeActivationEnvelope? lastActivation;
  ExternalPluginRuntimeVerifiedPayload? lastPayload;
  _FixtureDriver? driver;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) => true;

  @override
  Future<ExternalPluginRuntimeDriver> create(
    ExternalPluginRuntimeActivationEnvelope activation,
    ExternalPluginRuntimeVerifiedPayload payload,
  ) async {
    createCount++;
    lastActivation = activation;
    lastPayload = payload;
    if (!createStarted.isCompleted) {
      createStarted.complete();
    }
    if (createCount == 2 && !secondCreateStarted.isCompleted) {
      secondCreateStarted.complete();
    }
    await createGate?.future;
    return driver = _FixtureDriver(
      sourceId,
      closeGate: driverCloseGate,
    );
  }
}

final class _FixtureDriver implements ExternalPluginRuntimeDriver {
  _FixtureDriver(this.sourceId, {this.closeGate});

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
    cancellation.throwIfCancelled();
    return Uint8List.fromList(<int>[7, 8, 9]);
  }

  @override
  Future<void> close() async {
    await closeGate?.future;
    closed = true;
  }
}

Future<List<FileSystemEntity>> _directoryEntries(
  Directory directory,
) async {
  if (!await directory.exists()) {
    return const <FileSystemEntity>[];
  }
  return directory.list().toList();
}

Map<String, Object?> _mihonMessage(File payload, String payloadHash) =>
    MihonExecutionRequest(
      plugin: _plugin(ExternalComicPluginFormat.mihonExtension),
      payloadPath: payload.path,
      payloadByteLength: 4,
      payloadSha256: payloadHash,
      packageName: 'dev.fixture.extension',
      signerSha256: List<String>.filled(64, 'b').join(),
      versionCode: 1,
      extensionLib: '1.6',
      entryClasses: const <String>['dev.fixture.Extension'],
      capabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network,
      },
      limits: const ExternalPluginRuntimeLimits(),
    ).toMessage();

Map<String, Object?> _veneraMessage(File payload, String payloadHash) =>
    VeneraExecutionRequest(
      plugin: _plugin(ExternalComicPluginFormat.veneraJavaScript),
      payloadPath: payload.path,
      payloadByteLength: 4,
      payloadSha256: payloadHash,
      sourceKey: 'fixture',
      capabilities: const <ExternalPluginCapability>{
        ExternalPluginCapability.network,
      },
      limits: const ExternalPluginRuntimeLimits(),
    ).toMessage();

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
