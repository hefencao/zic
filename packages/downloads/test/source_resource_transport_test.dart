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

  test('verified reuse identity preserves scheduler control through resolver',
      () async {
    final locator = Uri.parse('venera-resource:reuse-identity');
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/reuse-identity'),
      ),
    );
    final pool = ExternalPluginResourceTransportPool();
    addTearDown(pool.close);
    final control = _MutableTaskControl(priority: 100);

    await pool.verifiedReuseIdentityFor(
      source,
      locator,
      control: control,
    );
    expect(source.lastResolveControl, same(control));
  });


  test('decorator churn preserves request plan for the same source generation',
      () async {
    final locator = Uri.parse('venera-resource:same-generation');
    final generation = Object();
    final first = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
      resourceGenerationIdentity: generation,
    );
    final second = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/page')),
      resourceGenerationIdentity: generation,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async => ByteResponse(
        bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: 3,
      ),
    );
    addTearDown(pool.close);

    await _collect((await pool.loaderFor(first, locator)()).bytes);
    await _collect((await pool.loaderFor(second, locator)()).bytes);

    expect(first.resolveCalls, 1);
    expect(second.resolveCalls, 0);
  });

  test('source generation replacement invalidates retained request plan', () async {
    final locator = Uri.parse('venera-resource:new-generation');
    final first = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/old')),
      resourceGenerationIdentity: Object(),
    );
    final second = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/new')),
      resourceGenerationIdentity: Object(),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 3,
        );
      },
    );
    addTearDown(pool.close);

    await _collect((await pool.loaderFor(first, locator)()).bytes);
    await _collect((await pool.loaderFor(second, locator)()).bytes);

    expect(first.resolveCalls, 1);
    expect(second.resolveCalls, 1);
    expect(opened, <Uri>[
      Uri.parse('https://fixture/old'),
      Uri.parse('https://fixture/new'),
    ]);
  });

  test('fresh resource generation drops a retained request plan', () async {
    final locator = Uri.parse('venera-resource:fresh-generation');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: Uri.parse('https://fixture/stale')),
      refreshRequest: ComicResourceRequest(uri: Uri.parse('https://fixture/fresh')),
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        return ByteResponse(
          bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 3,
        );
      },
    );
    addTearDown(pool.close);

    final first = await pool.loaderFor(source, locator)();
    await _collect(first.bytes);
    final cached = await pool.loaderFor(source, locator)();
    await _collect(cached.bytes);
    expect(source.resolveCalls, 1);

    await pool.refreshResourceFor(source, locator);
    final refreshed = await pool.loaderFor(source, locator)();
    await _collect(refreshed.bytes);

    expect(source.refreshCalls, 1);
    expect(source.resolveCalls, 2);
    expect(opened, <Uri>[
      Uri.parse('https://fixture/stale'),
      Uri.parse('https://fixture/stale'),
      Uri.parse('https://fixture/fresh'),
    ]);
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
        uri: Uri.parse('https://e-hentai.org/s/aabbccddeeff0011/1-1'),
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
    expect(
      first.diagnostics['sourceVerifiedReuseIdentity'],
      'eh:aabbccddeeff0011',
    );

    final second = await loader();
    expect(await _collect(second.bytes), <int>[1, 2, 3]);
    expect(second.diagnostics['sourceRequestPlanCacheHit'], isTrue);
    expect(second.diagnostics.containsKey('sourcePlanGateWaitMicros'), isFalse);
    expect(second.diagnostics.containsKey('sourcePlanHookMicros'), isFalse);
    expect(
      second.diagnostics['sourceVerifiedReuseIdentity'],
      'eh:aabbccddeeff0011',
    );
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

  test('transport ByteRange owns Range and If-Range request headers', () async {
    ComicResourceRequest? opened;
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://fixture/page'),
        headers: const <String, String>{'X-Fixture': 'kept'},
      ),
    );
    final pool = ExternalPluginResourceTransportPool(
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

    final response = await pool.loaderFor(
      source,
      Uri.parse('venera-resource:range-provenance'),
    )(
      range: const ByteRange(start: 6743904),
      validators: const Validators(etag: '"fixture-etag"'),
    );

    expect(await _collect(response.bytes), <int>[1, 2, 3, 4]);
    expect(opened?.headers[HttpHeaders.rangeHeader], 'bytes=6743904-');
    expect(opened?.headers[HttpHeaders.ifRangeHeader], '"fixture-etag"');
    expect(opened?.headers['X-Fixture'], 'kept');
    expect(opened?.headers[HttpHeaders.acceptEncodingHeader], 'identity');
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

  test('retry request with explicit transform uses source-owned byte transform',
      () async {
    final failed = Uri.parse('https://fixture/failed');
    final retried = Uri.parse('https://fixture/retried');
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 6, 5, 4, 3, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(
        uri: retried,
        requiresRuntimeTransform: true,
      ),
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
    final control = _MutableTaskControl(priority: 1000);
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 7, 8, 9, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://e-hentai.org/s/deadbeefdeadbeef/1-1'),
        requiresRuntimeTransform: true,
      ),
      runtimeBytes: runtimeImage,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => throw StateError('direct transport must not run'),
    );
    addTearDown(pool.close);

    final response = await pool
        .controlledLoaderFor(source, Uri.parse('venera-resource:fixture'))(
      control: control,
    );

    expect(await _collect(response.bytes), runtimeImage);
    expect(response.diagnostics.containsKey('sourceVerifiedReuseIdentity'), isFalse);
    expect(source.resolveCalls, 1);
    expect(source.loadCalls, 1);
    expect(identical(source.lastLoadControl, control), isTrue);
  });

  test('runtime transform fetches full body on host before source transform',
      () async {
    final control = _MutableTaskControl(priority: 1000);
    final locator = Uri.parse('venera-resource:host-transform');
    final rawBytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5, 9]);
    final transformed =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 6, 5, 4, 3, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://cdn.invalid/encrypted.bin'),
        requiresRuntimeTransform: true,
      ),
      supportsTransform: true,
      transform: (bytes) async {
        expect(bytes, rawBytes);
        return transformed;
      },
    );
    ComicResourceRequest? hostRequest;
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        hostRequest = request;
        return ByteResponse(
          bytes: Stream<List<int>>.value(rawBytes),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: rawBytes.length,
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool.controlledLoaderFor(source, locator)(
      range: const ByteRange(start: 3, end: 5),
      control: control,
    );

    expect(await _collect(response.bytes), transformed.sublist(3, 6));
    expect(response.rangeStart, 3);
    expect(response.totalLength, transformed.length);
    expect(response.diagnostics['sourceOpenPath'], 'host-fetch-runtime-transform');
    expect(hostRequest, isNotNull);
    expect(hostRequest!.headers.keys.any(
      (name) => name.toLowerCase() == HttpHeaders.rangeHeader,
    ), isFalse);
    expect(source.loadCalls, 0);
    expect(source.transformCalls, 1);
    expect(source.lastTransformInput, rawBytes);
    expect(identical(source.lastTransformControl, control), isTrue);
  });

  test('runtime transform falls back to source client for stateful host response',
      () async {
    final locator = Uri.parse('venera-resource:stateful-transform');
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 7, 8, 9, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(
        uri: Uri.parse('https://cdn.invalid/stateful'),
        requiresRuntimeTransform: true,
      ),
      supportsTransform: true,
      runtimeBytes: runtimeImage,
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => Future<ByteResponse>.error(
        const Failure(
          code: ErrorCode.network,
          message: 'source session state required',
          details: <String, Object?>{
            'sourceMediaProtocolMismatch': true,
            'sourceClientStateRequired': true,
          },
        ),
      ),
    );
    addTearDown(pool.close);

    final response = await pool.loaderFor(source, locator)();

    expect(await _collect(response.bytes), runtimeImage);
    expect(
      response.diagnostics['sourceOpenPath'],
      'transform-client-runtime-fallback',
    );
    expect(source.loadCalls, 1);
    expect(source.transformCalls, 0);
  });

  test('runtime transform failure consumes existing five-plan semantic budget',
      () async {
    final locator = Uri.parse('venera-resource:transform-retry-budget');
    ComicResourceRequest plan(int index) => ComicResourceRequest(
          uri: Uri.parse('https://cdn.invalid/raw-$index.bin'),
          requiresRuntimeTransform: true,
        );
    final source = _FixtureSource(
      request: plan(0),
      retryRequests: <ComicResourceRequest?>[
        for (var index = 1; index <= 5; index++) plan(index),
      ],
      supportsTransform: true,
      transform: (_) async => throw StateError('fixture transform rejected'),
    );
    var hostLoads = 0;
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async {
        hostLoads++;
        return ByteResponse(
          bytes: Stream<List<int>>.value(const <int>[1, 2, 3, 4]),
          statusCode: HttpStatus.ok,
          rangeStart: 0,
          totalLength: 4,
        );
      },
    );
    addTearDown(pool.close);

    await expectLater(
      pool.loaderFor(source, locator)(),
      throwsA(
        isA<Failure>()
            .having(
              (error) => error.details['sourceSemanticRetryExhausted'],
              'semantic retry exhausted',
              isTrue,
            )
            .having(
              (error) => error.details['sourceSemanticAcceptedPlans'],
              'accepted retry plans',
              5,
            )
            .having(
              (error) => error.details['sourceSemanticRuntimeTransformPlans'],
              'runtime transform plans',
              5,
            ),
      ),
    );
    expect(source.retryCalls, 5);
    expect(source.transformCalls, 6);
    expect(source.loadCalls, 0);
    expect(hostLoads, 6);
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

  test(
      'semantic rejection re-resolves the locator when source retry is unavailable',
      () async {
    final locator = Uri.parse('venera-resource:fresh-resolve');
    final failed = Uri.parse('https://fixture/non-image-generation');
    final recovered = Uri.parse('https://fixture/re-resolved.webp');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      resolveRequests: <ComicResourceRequest>[
        ComicResourceRequest(uri: failed),
        ComicResourceRequest(uri: recovered),
      ],
    );
    final opened = <Uri>[];
    final control = _MutableTaskControl(priority: 1000);
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

    final response = await pool.controlledLoaderFor(source, locator)(
      control: control,
    );

    expect(await _collect(response.bytes), hasLength(8));
    expect(opened, <Uri>[failed, recovered]);
    expect(source.resolveCalls, 2);
    expect(source.retryCalls, 1);
    expect(identical(source.lastResolveControl, control), isTrue);
    expect(response.diagnostics['sourceOpenPath'], 'fresh-resolve-direct');
  });

  test('semantic fresh re-resolve is bounded before terminal failure', () async {
    final locator = Uri.parse('venera-resource:fresh-resolve-terminal');
    final failed = Uri.parse('https://fixture/still-non-image');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      resolveRequests: <ComicResourceRequest>[
        ComicResourceRequest(uri: failed),
        ComicResourceRequest(uri: failed),
      ],
    );
    var hostLoads = 0;
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) async {
        hostLoads++;
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
      pool.loaderFor(source, locator)(),
      throwsA(
        isA<Failure>()
            .having(
              (error) => error.details['sourceSemanticAcceptedPlans'],
              'accepted retry plans',
              0,
            )
            .having(
              (error) => error.details['sourceSemanticFreshResolvePlans'],
              'fresh resolve plans',
              1,
            )
            .having(
              (error) => error.details['sourceSemanticRecoveryUnavailable'],
              'resource recovery unavailable',
              isTrue,
            ),
      ),
    );
    expect(source.resolveCalls, 2);
    expect(source.retryCalls, 1);
    expect(hostLoads, 2);
  });

  test('replacement non-image follows the current source semantic retry chain',
      () async {
    final failed = Uri.parse('https://fixture/non-image');
    final recovered = Uri.parse('https://fixture/still-non-image');
    final recoveredAgain = Uri.parse('https://fixture/recovered.webp');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequests: <ComicResourceRequest?>[
        ComicResourceRequest(uri: recovered),
        ComicResourceRequest(uri: recoveredAgain),
      ],
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri != recoveredAgain) {
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
        .loaderFor(source, Uri.parse('venera-resource:semantic-chain'))();

    expect(await _collect(response.bytes), hasLength(8));
    expect(opened, <Uri>[failed, recovered, recoveredAgain]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 2);
    expect(source.loadCalls, 0);
  });

  test('source semantic recovery stops after five replacement configs',
      () async {
    final failed = Uri.parse('https://fixture/non-image');
    final replacements = List<Uri>.generate(
      5,
      (index) => Uri.parse('https://fixture/replacement-$index'),
    );
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequests: replacements
          .map<ComicResourceRequest?>((uri) => ComicResourceRequest(uri: uri))
          .toList(),
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
      pool.loaderFor(source, Uri.parse('venera-resource:semantic-limit'))(),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.source)
            .having(
              (error) => error.details['sourceSemanticRetryExhausted'],
              'semantic retry exhausted',
              isTrue,
            )
            .having(
              (error) => error.details['sourceSemanticAcceptedPlans'],
              'accepted replacement plans',
              5,
            )
            .having(
              (error) => error.details['sourceSemanticSameUrlPlans'],
              'same-url replacement plans',
              0,
            )
            .having(
              (error) => error.details['sourceSemanticChangedUrlPlans'],
              'changed-url replacement plans',
              5,
            )
            .having(
              (error) => error.details['sourceSemanticRuntimeTransformPlans'],
              'runtime-transform replacement plans',
              0,
            ),
      ),
    );
    expect(opened, <Uri>[failed, ...replacements]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 5);
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

  test('unavailable source recovery preserves the original network failure',
      () async {
    final failed = Uri.parse('https://fixture/no-source-recovery');
    final original = Failure(
      code: ErrorCode.network,
      message: 'original direct network failure',
    );
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
    );
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (_) => Future<ByteResponse>.error(original),
    );
    addTearDown(pool.close);

    Object? observed;
    try {
      await pool
          .loaderFor(source, Uri.parse('venera-resource:no-source-recovery'))();
    } on Object catch (error) {
      observed = error;
    }

    expect(observed, same(original));
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('retry replacement network failure stays on streaming transport', () async {
    final failed = Uri.parse('https://fixture/failed');
    final replacement = Uri.parse('https://fixture/replacement');
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: replacement),
      runtimeBytes: Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]),
    );
    final replacementFailure = Failure(
      code: ErrorCode.network,
      message: 'replacement transport is temporarily unavailable',
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri == failed) {
          throw const Failure(
            code: ErrorCode.network,
            message: 'initial transport failure',
          );
        }
        throw replacementFailure;
      },
    );
    addTearDown(pool.close);

    Object? observed;
    try {
      await pool
          .loaderFor(source, Uri.parse('venera-resource:retry-network'))();
    } on Object catch (error) {
      observed = error;
    }

    expect(observed, same(replacementFailure));
    expect(opened, <Uri>[failed, replacement]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 0);
  });

  test('retry replacement client-state failure keeps runtime compatibility', () async {
    final failed = Uri.parse('https://fixture/failed-client-state');
    final replacement = Uri.parse('https://fixture/replacement-client-state');
    final runtimeImage =
        Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 9, 8, 7, 0xff, 0xd9]);
    final source = _FixtureSource(
      request: ComicResourceRequest(uri: failed),
      retryRequest: ComicResourceRequest(uri: replacement),
      runtimeBytes: runtimeImage,
    );
    final opened = <Uri>[];
    final pool = ExternalPluginResourceTransportPool(
      directOpen: (request) async {
        opened.add(request.uri);
        if (request.uri == failed) {
          throw const Failure(
            code: ErrorCode.network,
            message: 'initial transport failure',
          );
        }
        throw const Failure(
          code: ErrorCode.network,
          message: 'source client state is required',
          details: <String, Object?>{
            'sourceClientStateRequired': true,
          },
        );
      },
    );
    addTearDown(pool.close);

    final response = await pool
        .loaderFor(source, Uri.parse('venera-resource:retry-client-state'))();

    expect(await _collect(response.bytes), runtimeImage);
    expect(opened, <Uri>[failed, replacement]);
    expect(source.resolveCalls, 1);
    expect(source.retryCalls, 1);
    expect(source.loadCalls, 1);
    expect(
      response.diagnostics['sourceOpenPath'],
      'retry-client-runtime-fallback',
    );
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
        RefreshableComicResourceSource,
        ControlledRefreshableComicResourceSource,
        ControlledComicResourceSource,
        TransformingComicResourceSource,
        ControlledTransformingComicResourceSource,
        ComicResourceTransportGenerationSource {
  _FixtureSource({
    required this.request,
    this.resolveRequests,
    this.retryRequest,
    this.retryRequests,
    this.refreshRequest,
    this.resolveGate,
    this.supportsTransform = false,
    this.transform,
    Object? resourceGenerationIdentity,
    Uint8List? runtimeBytes,
  })  : resourceTransportGenerationIdentity =
            resourceGenerationIdentity ?? Object(),
        runtimeBytes = runtimeBytes ?? Uint8List(0);

  final ComicResourceRequest request;
  final List<ComicResourceRequest>? resolveRequests;
  final ComicResourceRequest? retryRequest;
  final List<ComicResourceRequest?>? retryRequests;
  final ComicResourceRequest? refreshRequest;
  final Completer<ComicResourceRequest>? resolveGate;
  final Uint8List runtimeBytes;
  final bool supportsTransform;
  final Future<Uint8List> Function(Uint8List bytes)? transform;
  @override
  final Object resourceTransportGenerationIdentity;
  int resolveCalls = 0;
  int retryCalls = 0;
  int refreshCalls = 0;
  int loadCalls = 0;
  int transformCalls = 0;
  bool _refreshed = false;
  TaskControl? lastResolveControl;
  TaskControl? lastLoadControl;
  TaskControl? lastTransformControl;
  Uint8List? lastTransformInput;

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
    final resolves = resolveRequests;
    if (resolves != null && resolves.isNotEmpty) {
      final index = (resolveCalls - 1).clamp(0, resolves.length - 1);
      return resolves[index];
    }
    return _refreshed ? (refreshRequest ?? request) : request;
  }

  @override
  Future<void> refreshResource(Uri uri) => refreshResourceControlled(uri);

  @override
  Future<void> refreshResourceControlled(
    Uri uri, {
    TaskControl? control,
  }) async {
    refreshCalls++;
    _refreshed = true;
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
    final retries = retryRequests;
    if (retries != null) {
      final index = retryCalls - 1;
      return index < retries.length ? retries[index] : null;
    }
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
    lastLoadControl = control;
    return runtimeBytes;
  }

  @override
  bool get supportsResourceTransformation => supportsTransform;

  @override
  Future<Uint8List> transformResource(Uri uri, Uint8List bytes) =>
      transformResourceControlled(uri, bytes);

  @override
  Future<Uint8List> transformResourceControlled(
    Uri uri,
    Uint8List bytes, {
    TaskControl? control,
  }) async {
    transformCalls++;
    lastTransformControl = control;
    lastTransformInput = Uint8List.fromList(bytes);
    final callback = transform;
    return callback == null
        ? Uint8List.fromList(bytes)
        : callback(Uint8List.fromList(bytes));
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
