import 'dart:async';
import 'dart:io';
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

  for (final action in <String>['consume', 'discard', 'close']) {
    test('platform body lease $action releases its verified file once', () async {
      final root = await Directory.systemTemp.createTemp('zic-body-channel-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]);
      final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
      final reference = _bodyReference(bytes);
      var releases = 0;
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          ExternalPluginRuntimeServiceMethods.activateMihon => <String, Object?>{
            'processId': 'process-1', 'sessionId': 'session-1',
            'handshake': _handshake('body-runtime'),
          },
          ExternalPluginRuntimeServiceMethods.invoke =>
            ExternalPluginRuntimeResponse.success(
              requestId: 'body-request', payload: reference.toMessage(),
            ).toMessage(),
          'claimExternalRuntimeResourceBody' => (() {
            expect(call.arguments, <String, Object?>{
              'processId': 'process-1', 'sessionId': 'session-1',
              'requestId': 'body-request', 'reference': reference.toMessage(),
            });
            return file.path;
          })(),
          'releaseExternalRuntimeResourceBody' => await (() async {
            releases++;
            await file.delete();
          })(),
          ExternalPluginRuntimeServiceMethods.closeSession => null,
          _ => throw MissingPluginException(call.method),
        };
      });
      final connection = await AndroidMihonIsolatedRuntimeBackend(channel: channel)
          .activate(_mihonRequest());
      final bodyConnection = connection as BodyExternalPluginRuntimeConnection;
      final response = await connection.invoke(_bodyRequest());
      expect(response.payload, reference.toMessage());
      if (action == 'close') {
        await connection.close();
      } else if (action == 'discard') {
        await bodyConnection.discardResourceBody(reference);
        await connection.close();
      } else {
        final body = await bodyConnection.takeResourceBody(reference);
        await expectLater(bodyConnection.takeResourceBody(reference), throwsStateError);
        expect((await body.open().toList()).expand((c) => c), bytes);
        await body.dispose();
        await connection.close();
      }
      expect(releases, 1);
      expect(await file.exists(), isFalse);
      expect(calls.where((m) => m == 'claimExternalRuntimeResourceBody'), hasLength(1));
    });
  }

  for (final binding in <String>[
    'valid', 'authority', 'operation', 'uri', 'runtime', 'source', 'no negotiation',
  ]) {
    test('Venera transform body $binding binding is checked before claim', () async {
      final root = await Directory.systemTemp.createTemp('zic-transform-channel-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]);
      final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
      final message = _veneraBodyReference(bytes).toMessage();
      if (binding == 'authority') message['authorityRevision'] = 'venera-runtime-transform-v1:old';
      if (binding == 'uri') message['resourceUri'] = 'venera-resource:other';
      if (binding == 'runtime') message['runtimeId'] = 'other-runtime';
      if (binding == 'source') message['externalSourceId'] = 'other-source';
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          ExternalPluginRuntimeServiceMethods.activateVenera => <String, Object?>{
            'processId': 'process-1', 'sessionId': 'session-1',
            'handshake': _handshake('body-runtime'),
          },
          ExternalPluginRuntimeServiceMethods.invoke => ExternalPluginRuntimeResponse.success(
            requestId: 'body-request', payload: message,
          ).toMessage(),
          'claimExternalRuntimeResourceBody' => file.path,
          'releaseExternalRuntimeResourceBody' => await (() async {
            await file.delete();
          })(),
          'discardExternalRuntimeResourceBody' => null,
          ExternalPluginRuntimeServiceMethods.closeSession => null,
          _ => throw MissingPluginException(call.method),
        };
      });
      final connection = await AndroidVeneraSandboxRuntimeBackend(channel: channel)
          .activate(_veneraRequest());
      final request = binding == 'operation' ? ExternalPluginRuntimeRequest(
        requestId: 'body-request', operation: ExternalPluginRuntimeOperation.loadResource,
        externalSourceId: 'fixture', arguments: <String, Object?>{
          'uri': 'venera-resource:unchanged', 'bodyDelivery': 'sealed-file-v1',
        },
      ) : _veneraBodyRequest(delivery: binding != 'no negotiation');
      if (binding == 'valid') {
        final response = await connection.invoke(request);
        final body = await (connection as BodyExternalPluginRuntimeConnection)
            .takeResourceBody(ExternalPluginRuntimeBodyFile.fromMessage(response.payload));
        expect((await body.open().toList()).expand((c) => c), bytes);
        await body.dispose();
        expect(calls.where((c) => c == 'releaseExternalRuntimeResourceBody'), hasLength(1));
      } else {
        await expectLater(connection.invoke(request), throwsFormatException);
        expect(calls, contains('discardExternalRuntimeResourceBody'));
        expect(calls, isNot(contains('claimExternalRuntimeResourceBody')));
      }
      await connection.close();
    });
  }

  test('runtime close joins a body release already in progress', () async {
    final root = await Directory.systemTemp.createTemp('zic-body-release-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]);
    final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
    final reference = _bodyReference(bytes);
    final releasing = Completer<void>();
    final finishRelease = Completer<void>();
    var closed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case ExternalPluginRuntimeServiceMethods.activateMihon:
          return <String, Object?>{
            'processId': 'process-1', 'sessionId': 'session-1',
            'handshake': _handshake('body-runtime'),
          };
        case ExternalPluginRuntimeServiceMethods.invoke:
          return ExternalPluginRuntimeResponse.success(
            requestId: 'body-request', payload: reference.toMessage(),
          ).toMessage();
        case 'claimExternalRuntimeResourceBody':
          return file.path;
        case 'releaseExternalRuntimeResourceBody':
          releasing.complete();
          await finishRelease.future;
          await file.delete();
          return null;
        case ExternalPluginRuntimeServiceMethods.closeSession:
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    final connection = await AndroidMihonIsolatedRuntimeBackend(channel: channel)
        .activate(_mihonRequest());
    await connection.invoke(_bodyRequest());
    final body = await (connection as BodyExternalPluginRuntimeConnection)
        .takeResourceBody(reference);
    final disposal = body.dispose();
    await releasing.future;
    final closing = connection.close().then((_) { closed = true; });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(await file.exists(), isTrue);
    } finally {
      finishRelease.complete();
      await disposal;
      await closing;
    }
    expect(closed, isTrue);
    expect(await file.exists(), isFalse);
  });

  test('late body response after close is discarded while close joins invocation',
      () async {
    final responseGate = Completer<Object?>();
    final invoked = Completer<void>();
    var discarded = false;
    var closed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case ExternalPluginRuntimeServiceMethods.activateMihon:
          return <String, Object?>{
            'processId': 'process-1', 'sessionId': 'session-1',
            'handshake': _handshake('body-runtime'),
          };
        case ExternalPluginRuntimeServiceMethods.invoke:
          invoked.complete();
          return responseGate.future;
        case ExternalPluginRuntimeServiceMethods.closeSession:
          return null;
        case 'discardExternalRuntimeResourceBody':
          discarded = true;
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    final connection = await AndroidMihonIsolatedRuntimeBackend(channel: channel)
        .activate(_mihonRequest());
    final pending = expectLater(connection.invoke(_bodyRequest()), throwsFormatException);
    await invoked.future;
    final close = connection.close().then((_) { closed = true; });
    await Future<void>.value();
    expect(closed, isFalse);
    responseGate.complete(ExternalPluginRuntimeResponse.success(
      requestId: 'body-request',
      payload: _bodyReference(Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1])).toMessage(),
    ).toMessage());
    await pending;
    await close;
    expect(discarded, isTrue);
    expect(closed, isTrue);
  });

  test('body binding mismatch is discarded before any physical claim', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        ExternalPluginRuntimeServiceMethods.activateMihon => <String, Object?>{
          'processId': 'process-1', 'sessionId': 'session-1',
          'handshake': _handshake('body-runtime'),
        },
        ExternalPluginRuntimeServiceMethods.invoke =>
          ExternalPluginRuntimeResponse.success(requestId: 'body-request', payload: <String, Object?>{
            ..._bodyReference(Uint8List(4)).toMessage(), 'resourceUri': 'mihon:resource:other',
          }).toMessage(),
        'discardExternalRuntimeResourceBody' => null,
        ExternalPluginRuntimeServiceMethods.closeSession => null,
        _ => throw MissingPluginException(call.method),
      };
    });
    final connection = await AndroidMihonIsolatedRuntimeBackend(channel: channel)
        .activate(_mihonRequest());
    await expectLater(connection.invoke(_bodyRequest()), throwsFormatException);
    await connection.close();
    expect(calls, contains('discardExternalRuntimeResourceBody'));
    expect(calls, isNot(contains('claimExternalRuntimeResourceBody')));
  });

  for (final venera in <bool>[false, true]) {
  for (final phase in <String>['before claim', 'during claim', 'after claim']) {
    test('${venera ? 'Venera transform' : 'Mihon'} body cancellation $phase waits for physical cleanup without replay', () async {
      final root = await Directory.systemTemp.createTemp('zic-body-cancel-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]);
      final file = await File('${root.path}/verified.lease').writeAsBytes(bytes);
      final reference = venera ? _veneraBodyReference(bytes) : _bodyReference(bytes);
      final responseGate = Completer<Object?>();
      final claimGate = Completer<String>();
      final cleanupGate = Completer<void>();
      final invoked = Completer<void>();
      final claimed = Completer<void>();
      final discarded = Completer<void>();
      var activations = 0;
      var settled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case ExternalPluginRuntimeServiceMethods.activateVenera:
          case ExternalPluginRuntimeServiceMethods.activateMihon:
            activations++;
            return <String, Object?>{
              'processId': 'process-1', 'sessionId': 'session-1',
              'handshake': _handshake('body-runtime'),
            };
          case ExternalPluginRuntimeServiceMethods.invoke:
            invoked.complete();
            return responseGate.future;
          case 'claimExternalRuntimeResourceBody':
            claimed.complete();
            return claimGate.future;
          case 'discardExternalRuntimeResourceBody':
          case 'releaseExternalRuntimeResourceBody':
            discarded.complete();
            await cleanupGate.future;
            return null;
          case ExternalPluginRuntimeServiceMethods.cancel:
          case ExternalPluginRuntimeServiceMethods.closeSession:
            return null;
          default:
            throw MissingPluginException(call.method);
        }
      });
      final connection = venera
          ? await AndroidVeneraSandboxRuntimeBackend(channel: channel).activate(_veneraRequest())
          : await AndroidMihonIsolatedRuntimeBackend(channel: channel).activate(_mihonRequest());
      final pending = connection.invoke(venera ? _veneraBodyRequest() : _bodyRequest()).then((response) {
        settled = true;
        return response;
      });
      await invoked.future;
      if (phase != 'before claim') {
        responseGate.complete(ExternalPluginRuntimeResponse.success(
          requestId: 'body-request', payload: reference.toMessage(),
        ).toMessage());
        await claimed.future;
      }
      await (connection as CancellableExternalPluginRuntimeConnection).cancel('body-request');
      expect(settled, isFalse);
      if (phase == 'before claim') {
        responseGate.complete(ExternalPluginRuntimeResponse.success(
          requestId: 'body-request', payload: reference.toMessage(),
        ).toMessage());
        await discarded.future;
        expect(claimed.isCompleted, isFalse);
        expect(settled, isFalse);
        cleanupGate.complete();
      } else if (phase == 'during claim') {
        claimGate.completeError(PlatformException(code: 'runtime-body-cancelled'));
      } else {
        claimGate.complete(file.path);
        await discarded.future;
        expect(settled, isFalse);
        cleanupGate.complete();
      }
      final response = await pending;
      expect(response.error?.code, 'runtime-request-cancelled');
      expect(response.error?.retryable, isFalse);
      expect(activations, 1);
      await connection.close();
    });
  }
  }

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

  test('Venera backend leaves service-generation recovery to Android', () async {
    var activations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == ExternalPluginRuntimeServiceMethods.activateVenera) {
        activations++;
        throw PlatformException(
          code: 'runtime-service-died',
          message: 'runtime service process died during activation',
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
          'runtime-service-died',
        ),
      ),
    );
    expect(activations, 1);
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

  for (final failure in <String>['envelope', 'platform']) {
    for (final stage in <String>[
      'reactivation', 'replay', 'cancelled reactivation', 'cancelled replay',
    ]) {
      test('$failure recovery does not retry a failed $stage', () async {
        final cancelled = stage.startsWith('cancelled');
        final reactivation = stage.endsWith('reactivation');
        final failing = Completer<void>();
        final release = Completer<void>();
        var activations = 0;
        var invocations = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method == ExternalPluginRuntimeServiceMethods.activateMihon) {
            activations++;
            if (activations == 2 && reactivation) {
              if (cancelled) {
                failing.complete();
                await release.future;
              }
              throw PlatformException(code: 'runtime-service-died');
            }
            return <String, Object?>{
              'processId': 'process-$activations',
              'sessionId': 'session-$activations',
              'handshake': _handshake('mihon-runtime'),
            };
          }
          if (call.method == ExternalPluginRuntimeServiceMethods.invoke) {
            invocations++;
            if (invocations == 1 && failure == 'envelope') {
              return ExternalPluginRuntimeResponse.failure(
                requestId: 'replayed',
                error: ExternalPluginRuntimeError(
                  code: 'runtime-process-mismatch',
                  message: 'runtime service restarted',
                  retryable: true,
                ),
              ).toMessage();
            }
            if (invocations == 2 && cancelled) {
              failing.complete();
              await release.future;
            }
            throw PlatformException(code: 'runtime-service-died');
          }
          return null;
        });
        final connection = await AndroidMihonIsolatedRuntimeBackend(channel: channel)
            .activate(_mihonRequest());
        var settled = false;
        final pending = connection.invoke(
          ExternalPluginRuntimeRequest.browse(
            requestId: 'replayed', externalSourceId: 'fixture',
            query: '', offset: 0, limit: 24,
          ),
        ).whenComplete(() => settled = true);
        if (cancelled) {
          await failing.future;
          await (connection as CancellableExternalPluginRuntimeConnection).cancel('replayed');
          expect(settled, isFalse);
          release.complete();
          expect((await pending).error?.code, 'runtime-request-cancelled');
        } else {
          await expectLater(
            pending,
            throwsA(isA<PlatformException>().having(
              (error) => error.code, 'code', 'runtime-service-died',
            )),
          );
        }
        expect(activations, 2);
        expect(invocations, reactivation ? 1 : 2);
        await connection.close();
      });
    }
  }

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

ExternalPluginRuntimeRequest _veneraBodyRequest({bool delivery = true}) =>
    ExternalPluginRuntimeRequest(
      requestId: 'body-request', operation: ExternalPluginRuntimeOperation.transformResource,
      externalSourceId: 'fixture', arguments: <String, Object?>{
        'uri': 'venera-resource:unchanged', 'bytes': Uint8List.fromList(<int>[1, 2, 3]),
        if (delivery) 'bodyDelivery': 'sealed-file-v1',
      },
    );

ExternalPluginRuntimeBodyFile _veneraBodyReference(Uint8List bytes) =>
    ExternalPluginRuntimeBodyFile.fromMessage(<String, Object?>{
      ..._bodyReference(bytes).toMessage(),
      'authorityRevision': 'venera-runtime-transform-v1:${_veneraRequest().payloadSha256}',
      'resourceUri': 'venera-resource:unchanged',
    });

ExternalPluginRuntimeRequest _bodyRequest() => ExternalPluginRuntimeRequest(
      requestId: 'body-request', operation: ExternalPluginRuntimeOperation.loadResource,
      externalSourceId: 'fixture', arguments: <String, Object?>{
        'uri': 'mihon:resource:unchanged', 'bodyDelivery': 'sealed-file-v1',
      },
    );

ExternalPluginRuntimeBodyFile _bodyReference(Uint8List bytes) =>
    ExternalPluginRuntimeBodyFile.fromMessage(<String, Object?>{
      'bodyDelivery': 'sealed-file-v1',
      'ownerId': 'native-11111111-1111-1111-1111-111111111111',
      'bodyId': '22222222-2222-2222-2222-222222222222',
      'requestId': 'body-request', 'externalSourceId': 'fixture',
      'runtimeId': 'body-runtime',
      'authorityRevision': 'mihon-runtime-transform-v3:${_mihonRequest().payloadSha256}',
      'resourceUri': 'mihon:resource:unchanged', 'byteLength': bytes.length,
      'sha256': 'a' * 64, 'fnv64': '0123456789abcdef', 'metadataPrefix': bytes,
    });

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
