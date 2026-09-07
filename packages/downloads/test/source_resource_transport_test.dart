import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('source transport self-bounds open only with both proven owners', () {
    final locator = Uri.parse('venera-resource:bounded');
    final request = ComicResourceRequest(
      uri: Uri.parse('https://fixture/bounded'),
    );
    final boundedSource = _BoundedFixtureSource(request: request);
    final unboundedSource = _FixtureSource(request: request);
    final boundedPool = ExternalPluginResourceTransportPool(
      directTransport: _FixtureBoundedDirectTransport(),
    );
    final unboundedDirectPool = ExternalPluginResourceTransportPool(
      directTransport: _FixtureDirectTransport(),
    );
    addTearDown(boundedPool.close);
    addTearDown(unboundedDirectPool.close);

    expect(boundedPool.selfBoundsOpenFor(boundedSource, locator), isTrue);
    expect(boundedPool.selfBoundsOpenFor(unboundedSource, locator), isFalse);
    expect(
      unboundedDirectPool.selfBoundsOpenFor(boundedSource, locator),
      isFalse,
    );
  });

  test('resolved source request exposes the first chunk before completion',
      () async {
    final body = _ControlledBody();
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened = request;
        return body.response(totalLength: 6, etag: '"fixture"');
      },
    );
    addTearDown(pool.close);
    final loader = pool.loaderFor(
      source,
      Uri.parse('venera-resource:fixture'),
    );

    final response = await loader();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(<int>[1, 2, 3]);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[1, 2, 3]);
    expect(body.closed, isFalse);
    expect(opened?.uri, Uri.parse('https://fixture/page'));
    expect(response.totalLength, 6);
    expect(response.validators.etag, '"fixture"');

    body.add(<int>[4, 5, 6]);
    final closed = body.close();
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[4, 5, 6]);
    expect(await iterator.moveNext(), isFalse);
    await closed;
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('source open exposes request-plan and host-open stage diagnostics',
      () async {
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/staged'),
        diagnostics: const <String, Object?>{
          'sourcePlanGateWaitMicros': 1200,
          'sourcePlanRuntimeInvocationMicros': 2400,
          'sourcePlanHookMicros': 1800,
          'sourcePlanBridgeNetworkMicros': 900,
          'sourcePlanBridgeNetworkCalls': 2,
          'sourcePlanBridgeNetworkCacheHits': 1,
          'sourcePlanBridgeNetworkOriginCalls': 1,
        },
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => ByteResponse(
        bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: 3,
      ),
    );
    addTearDown(pool.close);
    final loader = pool.loaderFor(
      source,
      Uri.parse('venera-resource:staged-diagnostics'),
    );

    final first = await loader();
    expect(await _collect(first.bytes), <int>[1, 2, 3]);
    expect(first.diagnostics['sourceRequestPlanMicros'], isA<int>());
    expect(
      first.diagnostics['sourceRequestPlanMicros'] as int,
      greaterThanOrEqualTo(0),
    );
    expect(first.diagnostics['sourceRequestPlanCacheHit'], isFalse);
    expect(first.diagnostics['sourcePlanGateWaitMicros'], 1200);
    expect(first.diagnostics['sourcePlanRuntimeInvocationMicros'], 2400);
    expect(first.diagnostics['sourcePlanHookMicros'], 1800);
    expect(first.diagnostics['sourcePlanBridgeNetworkMicros'], 900);
    expect(first.diagnostics['sourcePlanBridgeNetworkCalls'], 2);
    expect(first.diagnostics['sourcePlanBridgeNetworkCacheHits'], 1);
    expect(first.diagnostics['sourcePlanBridgeNetworkOriginCalls'], 1);
    expect(first.diagnostics['sourceHostOpenMicros'], isA<int>());
    expect(first.diagnostics['sourceOpenPath'], 'direct');
    expect(first.diagnostics['sourceRetryUsed'], isFalse);

    final second = await loader();
    expect(await _collect(second.bytes), <int>[1, 2, 3]);
    expect(second.diagnostics['sourceRequestPlanCacheHit'], isTrue);
    expect(second.diagnostics.containsKey('sourcePlanGateWaitMicros'), isFalse);
    expect(second.diagnostics.containsKey('sourcePlanHookMicros'), isFalse);
    expect(source.resolveCalls, 1);
  });

  test('a replacement source identity does not discard an active response',
      () async {
    final body = _ControlledBody();
    final target = Uri.parse('https://fixture/page');
    final firstSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final replacementSource = _FixtureSource(
      request: ComicResourceRequest(uri: target),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => body.response(totalLength: 6),
    );
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(firstSource, Uri.parse('venera-resource:first'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(<int>[1, 2, 3]);
    expect(await iterator.moveNext(), isTrue);

    pool.loaderFor(
      replacementSource,
      Uri.parse('venera-resource:replacement'),
    );
    expect(body.discarded, isFalse);
    body.add(<int>[4, 5, 6]);
    final closed = body.close();

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, <int>[4, 5, 6]);
    expect(await iterator.moveNext(), isFalse);
    await closed;
  });

  test('source replacement cannot reuse an in-flight old request plan', () async {
    final gate = Completer<ComicResourceRequest>();
    final firstSource = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/old')),
      resolveGate: gate,
    );
    final replacementSource = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/new')),
    );
    Uri? opened;
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened = request.uri;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 3,
        );
      },
    );
    addTearDown(pool.close);

    final pending = pool
        .loaderFor(firstSource, Uri.parse('venera-resource:replacement-plan'))();
    await Future<void>.delayed(Duration.zero);
    pool.loaderFor(
      replacementSource,
      Uri.parse('venera-resource:replacement-plan-new'),
    );
    gate.complete(firstSource.request);

    final response = await pending;
    expect(await _collect(response.bytes), <int>[1, 2, 3]);
    expect(opened, Uri.parse('https://fixture/new'));
    expect(replacementSource.resolveCalls, 1);
  });

  test('default UA reaches directOpen when source omits it', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
    );
    final pool = ExternalPluginResourceTransportPool(
      defaultUserAgentProvider: () => 'fixture-default-ua',
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:default-ua'))();

    expect(await _collect(response.bytes), <int>[1, 2, 3, 4]);
    expect(opened?.headers[HttpHeaders.userAgentHeader], 'fixture-default-ua');
  });

  test('source UA wins over the default UA', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/page'),
        headers: const <String, String>{'User-Agent': 'source-owned-ua'},
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
      defaultUserAgentProvider: () => 'fixture-default-ua',
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[4, 3, 2, 1]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:source-ua'))();

    expect(await _collect(response.bytes), <int>[4, 3, 2, 1]);
    expect(opened?.headers['User-Agent'], 'source-owned-ua');
  });

  test('GET request normalization removes body and entity headers', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/page'),
        method: 'get',
        headers: const <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '4096',
          'Transfer-Encoding': 'chunked',
          'X-Fixture': 'kept',
        },
        body: Uint8List.fromList(List<int>.filled(4096, 7)),
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[9, 8, 7, 6]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:no-upload'))();

    expect(await _collect(response.bytes), <int>[9, 8, 7, 6]);
    expect(opened?.method, 'GET');
    expect(opened?.body, isNull);
    expect(opened?.headers['Content-Type'], isNull);
    expect(opened?.headers['Content-Length'], isNull);
    expect(opened?.headers['Transfer-Encoding'], isNull);
    expect(opened?.headers['X-Fixture'], 'kept');
    expect(opened?.headers[HttpHeaders.acceptEncodingHeader], 'identity');
  });

  test('discard cancels a controlled response without awaiting completion',
      () async {
    final body = _ControlledBody();
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/slow')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => body.response(totalLength: 1024 * 1024),
    );
    addTearDown(pool.close);
    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:discard'))();
    final iterator = StreamIterator<List<int>>(response.bytes);
    body.add(List<int>.filled(4096, 1));
    expect(await iterator.moveNext(), isTrue);

    await response.discard();
    expect(body.discarded, isTrue);
    expect(body.closed, isTrue);
    await iterator.cancel();
    await body.done;
  });

  test('controlled Reader loader preserves scheduler control through source resolution',
      () async {
    final control = _MutableTaskControl(priority: 1000);
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/current')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async => ByteResponse(
        bytes: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: 4,
      ),
    );
    addTearDown(pool.close);

    final response = await pool
        .controlledLoaderFor(source, Uri.parse('venera-resource:current'))(
      control: control,
    );

    expect(identical(source.lastResolveControl, control), isTrue);
    expect(await _collect(response.bytes), <int>[1, 2, 3, 4]);
  });

  test('platform direct transport receives the same scheduler control', () async {
    final control = _MutableTaskControl(priority: 1000);
    final direct = _FixtureDirectTransport();
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/current')),
    );
    final pool = ExternalPluginResourceTransportPool(
      directTransport: direct,
    );
    addTearDown(pool.close);

    final response = await pool
        .controlledLoaderFor(source, Uri.parse('venera-resource:platform'))(
      control: control,
    );

    expect(identical(source.lastResolveControl, control), isTrue);
    expect(identical(direct.lastControl, control), isTrue);
    expect(await _collect(response.bytes), <int>[1, 2, 3, 4]);
    pool.close();
    expect(direct.closed, isTrue);
  });

  test('controlled cancellation aborts an already streaming host response',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final secondWrite = Completer<void>();
    unawaited(server.forEach((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add(const <int>[
        0x52, 0x49, 0x46, 0x46,
        0x00, 0x00, 0x00, 0x00,
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x20,
      ]);
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        request.response.add(List<int>.filled(4096, 7));
        await request.response.flush();
      } on Object {
        // The expected scheduler cancellation can close the client first.
      } finally {
        if (!secondWrite.isCompleted) secondWrite.complete();
        try {
          await request.response.close();
        } on Object {
          // Client cancellation already owns the close.
        }
      }
    }));

    final control = _MutableTaskControl(priority: 1000);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse(
          'http://${server.address.address}:${server.port}/stream.webp',
        ),
      ),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);
    final response = await pool
        .controlledLoaderFor(source, Uri.parse('venera-resource:stream'))(
      control: control,
    );
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);

    control.cancel();
    expect(
      await iterator.moveNext().timeout(const Duration(milliseconds: 150)),
      isFalse,
    );
    await secondWrite.future;
  });

  test('failed direct retry falls back to the source-owned byte transform',
      () async {
    final failed = Uri.parse('https://fixture/failed');
    final retried = Uri.parse('https://fixture/retried');
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 6, 5, 4, 3, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: retried),
      runtimeBytes: runtimeImage,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => Future<ByteResponse>.error(
        const Failure(
          code: ErrorCode.network,
          message: 'controlled direct failure',
        ),
      ),
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('mihon:resource:fixture'))();

    expect(await _collect(response.bytes), runtimeImage);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 1);
  });

  test('runtime body path is reserved for actual response transforms',
      () async {
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 7, 8, 9, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('venera-resource:fixture'),
        requiresRuntimeTransform: true,
      ),
      runtimeBytes: runtimeImage,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => throw StateError('direct transport must not run'),
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:fixture'))();

    expect(await _collect(response.bytes), runtimeImage);
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 1);
  });

  test('runtime body rejects non-image bytes before transfer admission',
      () async {
    final locator = Uri.parse('venera-resource:invalid-runtime-body');
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: locator,
        requiresRuntimeTransform: true,
      ),
      runtimeBytes: Uint8List.fromList('<html>source error</html>'.codeUnits),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);

    await expectLater(
      pool.loaderFor(source, locator)(),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.source)
            .having(
              (error) => error.details['runtimeBodyImageSignatureRejected'],
              'runtime signature rejection',
              isTrue,
            ),
      ),
    );
    expect(source.loadCalls, 1);
  });

  test('non-image direct response uses one source semantic retry plan', () async {
    final failed = Uri.parse('https://fixture/non-image');
    final recovered = Uri.parse('https://fixture/recovered.webp');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: recovered),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri == failed) {
          throw const Failure(
            code: ErrorCode.network,
            message: 'source host returned non-image bytes',
            details: <String, Object?>{
              'sourceMediaProtocolMismatch': true,
              'sourceMediaSemanticRejected': true,
            },
          );
        }
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[
            0xff,
            0xd8,
            0xff,
            1,
            2,
            3,
            0xff,
            0xd9,
          ]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 8,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:semantic-retry'))();

    expect(await _collect(response.bytes), hasLength(8));
    expect(opened, <Uri>[failed, recovered]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('replacement non-image response is terminal after one semantic retry',
      () async {
    final failed = Uri.parse('https://fixture/non-image');
    final recovered = Uri.parse('https://fixture/still-non-image');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: recovered),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        throw const Failure(
          code: ErrorCode.network,
          message: 'source host returned non-image bytes',
          details: <String, Object?>{
            'sourceMediaProtocolMismatch': true,
            'sourceMediaSemanticRejected': true,
          },
        );
      },
    );
    addTearDown(pool.close);

    await expectLater(
      pool.loaderFor(source, Uri.parse('venera-resource:semantic-terminal'))(),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.source)
            .having(
              (error) => error.details['sourceSemanticRetryExhausted'],
              'semantic retry exhausted',
              isTrue,
            ),
      ),
    );
    expect(opened, <Uri>[failed, recovered]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('source-client state mismatch still falls back to runtime ownership',
      () async {
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 9, 8, 7, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/source-client-state'),
      ),
      runtimeBytes: runtimeImage,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => Future<ByteResponse>.error(
        const Failure(
          code: ErrorCode.network,
          message: 'source client state is required',
          details: <String, Object?>{
            'sourceMediaProtocolMismatch': true,
            'sourceClientStateRequired': true,
          },
        ),
      ),
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:client-state'))();

    expect(await _collect(response.bytes), runtimeImage);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 0);
    expect(source.loadCalls, 1);
  });

  test('source retry replaces only the failed request plan', () async {
    final failed = Uri.parse('https://fixture/failed');
    final recovered = Uri.parse('https://fixture/recovered');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: recovered),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri == failed) {
          throw const Failure(
            code: ErrorCode.network,
            message: 'controlled failure',
          );
        }
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[4, 3, 2, 1]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:retry'))();

    expect(await _collect(response.bytes), <int>[4, 3, 2, 1]);
    expect(opened, <Uri>[failed, recovered]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}

final class _ControlledBody {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>(sync: true);
  bool discarded = false;
  bool closed = false;
  Future<void>? _done;

  Future<void> get done => _done ?? Future<void>.value();

  ByteResponse response({required int? totalLength, String? etag}) =>
      ByteResponse(
        bytes: _controller.stream,
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: totalLength,
        validators: Validators(etag: etag),
        onDiscard: discard,
      );

  void add(List<int> bytes) {
    if (closed) throw StateError('controlled body is closed');
    _controller.add(bytes);
  }

  Future<void> close() {
    if (!closed) {
      closed = true;
      _done = _controller.close();
    }
    return done;
  }

  Future<void> discard() async {
    discarded = true;
    if (!closed) {
      closed = true;
      _done = _controller.close();
    }
  }
}

final class _MutableTaskControl implements TaskControl {
  _MutableTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();
  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class _FixtureDirectTransport implements SourceResourceDirectTransport {
  TaskControl? lastControl;
  bool closed = false;

  @override
  Future<ByteResponse> open(
    ComicResourceRequest request, {
    TaskControl? control,
  }) async {
    lastControl = control;
    return ByteResponse(
      bytes: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: 4,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

final class _FixtureBoundedDirectTransport extends _FixtureDirectTransport
    implements SelfBoundedSourceResourceDirectTransport {}


final class _BoundedFixtureSource extends _FixtureSource
    implements BoundedComicResourceSource {
  _BoundedFixtureSource({required super.request});

  @override
  Duration get resourceOperationTimeout => const Duration(seconds: 30);
}

class _FixtureSource
    implements
        BrowsableComicSource,
        ResolvableComicResourceSource,
        ControlledResolvableComicResourceSource,
        RetryableComicResourceSource,
        ControlledRetryableComicResourceSource,
        ControlledComicResourceSource {
  _FixtureSource({
    required this.request,
    this.retryRequest,
    this.resolveGate,
    Uint8List? runtimeBytes,
  }) : runtimeBytes = runtimeBytes ?? Uint8List(0);

  final ComicResourceRequest request;
  final ComicResourceRequest? retryRequest;
  final Completer<ComicResourceRequest>? resolveGate;
  final Uint8List runtimeBytes;
  int resolveCalls = 0;
  int retryCalls = 0;
  int loadCalls = 0;
  TaskControl? lastResolveControl;

  @override
  String get sourceId => 'venera:fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  Future<ComicResourceRequest> resolveResource(Uri uri) =>
      resolveResourceControlled(uri);

  @override
  Future<ComicResourceRequest> resolveResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    resolveCalls++;
    lastResolveControl = control;
    final gate = resolveGate;
    if (gate != null) return gate.future;
    return request;
  }

  @override
  Future<ComicResourceRequest?> retryResource(Uri uri) =>
      retryResourceControlled(uri);

  @override
  Future<ComicResourceRequest?> retryResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    retryCalls++;
    return retryRequest;
  }

  @override
  Future<Uint8List> loadResource(Uri uri) =>
      loadResourceControlled(uri);

  @override
  Future<Uint8List> loadResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    loadCalls++;
    return runtimeBytes;
  }

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();
}
