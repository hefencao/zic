import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('response discard is idempotent', () async {
    var discards = 0;
    final response = ByteResponse(
      bytes: const Stream<List<int>>.empty(),
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: 0,
      onDiscard: () async {
        discards++;
      },
    );

    await Future.wait<void>(<Future<void>>[
      response.discard(),
      response.discard(),
    ]);

    expect(discards, 1);
  });

  test('HTTP transport exposes range and validators', () async {
    final bytes = List<int>.generate(16, (index) => index);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });

    server.listen((request) async {
      const etag = '"fixture-v1"';
      request.response.headers
        ..set(HttpHeaders.etagHeader, etag)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      if (range == 'bytes=5-' && ifRange == etag) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 5-15/16',
        );
        request.response.add(bytes.sublist(5));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.add(bytes);
      }
      await request.response.close();
    });

    final transport = HttpTransport();
    addTearDown(transport.close);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/page');
    final response = await transport.open(
      uri,
      range: const ByteRange(start: 5),
      validators: const Validators(etag: '"fixture-v1"'),
    );

    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.rangeStart, 5);
    expect(response.totalLength, 16);
    expect(response.validators.etag, '"fixture-v1"');
    expect(await response.bytes.expand((chunk) => chunk).toList(), bytes.sublist(5));
  });

  test('HTTP open reports cancellation when request aborts', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    final serving = server.listen((request) async {
      if (!requestSeen.isCompleted) requestSeen.complete();
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        request.response
          ..statusCode = HttpStatus.ok
          ..add(<int>[1]);
        await request.response.close();
      } on Object {
        // The client is expected to abort this response.
      }
    });
    addTearDown(serving.cancel);
    addTearDown(() => server.close(force: true));

    final transport = HttpTransport();
    addTearDown(transport.close);
    final control = _TestTaskControl();
    final pending = transport.openControlled(
      Uri.parse('http://127.0.0.1:${server.port}/slow'),
      control: control,
    );
    await requestSeen.future;
    control.cancel();

    await expectLater(
      pending,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
  });

  test('dynamic user-agent provider is read per request', () async {
    var userAgent = 'fixture-ua-one';
    final seen = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = server.listen((request) async {
      seen.add(request.headers.value(HttpHeaders.userAgentHeader));
      request.response
        ..statusCode = HttpStatus.ok
        ..add(<int>[1]);
      await request.response.close();
    });
    addTearDown(serving.cancel);
    final transport = HttpTransport(userAgentProvider: () => userAgent);
    addTearDown(transport.close);
    final uri = Uri.parse('http://${server.address.host}:${server.port}/resource');

    await (await transport.open(uri)).bytes.drain<void>();
    userAgent = 'fixture-ua-two';
    await (await transport.open(uri)).bytes.drain<void>();

    expect(seen, <String?>['fixture-ua-one', 'fixture-ua-two']);
  });

  test('metadata HTTP preserves a complete error response for protocol handling', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.set(HttpHeaders.dateHeader, 'Mon, 26 Oct 2026 05:00:00 GMT');
      request.response.write('Not Found');
      await request.response.close();
    });
    final response = await const MetadataHttpTransport().request('GET',
      Uri.parse('http://127.0.0.1:${server.port}/missing'),
      control: _TestTaskControl(), timeout: const Duration(seconds: 2), maxBytes: 1024);
    expect(response.status, HttpStatus.notFound);
    expect(response.date, DateTime.utc(2026, 10, 26, 5));
    expect(String.fromCharCodes(response.bytes), 'Not Found');
  });

  test('metadata HTTP reports truncated bodies without exposing endpoint secrets', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      var replied = false;
      socket.listen((_) async {
        if (replied) return;
        replied = true;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\npartial');
        await socket.flush();
        await socket.close();
      });
    });
    await expectLater(const MetadataHttpTransport().request('GET',
      Uri.parse('http://127.0.0.1:${server.port}/secret-path?token=secret'),
      control: _TestTaskControl(), timeout: const Duration(seconds: 2), maxBytes: 1024),
      throwsA(isA<MetadataHttpException>()
        .having((e) => e.reason, 'reason', MetadataHttpFailure.protocol)
        .having((e) => e.phase, 'phase', MetadataHttpPhase.body)
        .having((e) => e.status, 'status', HttpStatus.ok)
        .having((e) => e.errorType, 'type only', 'HttpException')));
  });

  test('metadata HTTP parses retry delays without granting them scheduling authority', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var value = '2';
    server.listen((request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.headers.set(HttpHeaders.retryAfterHeader, value);
      await request.response.close();
    });
    Future<MetadataHttpResponse> read() => const MetadataHttpTransport().request('GET',
      Uri.parse('http://127.0.0.1:${server.port}/file'),
      control: _TestTaskControl(), timeout: const Duration(seconds: 2), maxBytes: 1024);
    expect((await read()).retryAfter, const Duration(seconds: 2));
    value = HttpDate.format(DateTime.now().toUtc().add(const Duration(seconds: 120)));
    expect((await read()).retryAfter!.inSeconds, inInclusiveRange(118, 120));
    value = 'invalid';
    expect((await read()).retryAfter, isNull);
  });

  test('metadata HTTP distinguishes ambiguous response validators from connectivity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.noFolding(HttpHeaders.etagHeader);
      request.response.headers.add(HttpHeaders.etagHeader, ['"one"', '"two"']);
      request.response.write('complete');
      await request.response.close();
    });
    await expectLater(const MetadataHttpTransport().request('GET',
      Uri.parse('http://127.0.0.1:${server.port}/file'),
      control: _TestTaskControl(), timeout: const Duration(seconds: 2), maxBytes: 1024),
      throwsA(isA<MetadataHttpException>()
        .having((e) => e.reason, 'reason', MetadataHttpFailure.protocol)
        .having((e) => e.phase, 'phase', MetadataHttpPhase.headers)
        .having((e) => e.status, 'status', HttpStatus.ok)));
  });

  test('metadata gzip validates content and enforces the expanded byte bound', () {
    const codec = MetadataGzipCodec();
    final bytes = Uint8List(64 * 1024);
    final packed = codec.encode(bytes);
    expect(packed.length, lessThan(1024));
    expect(codec.decode(packed, maxBytes: bytes.length), bytes);
    expect(() => codec.decode(packed, maxBytes: bytes.length - 1),
      throwsA(isA<MetadataGzipLimitException>()));
    final damaged = packed.toList()..[packed.length - 8] ^= 1;
    expect(() => codec.decode(damaged, maxBytes: bytes.length), throwsFormatException);
  });

  test('metadata idle connections reuse completed sockets without another scheduler', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final ports = <int>[];
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      request.response.write('ok');
      await request.response.close();
    });
    final connections = MetadataHttpConnections();
    addTearDown(connections.close);
    for (var i = 0; i < 20; i++) {
      await const MetadataHttpTransport().request('GET',
        Uri.parse('http://127.0.0.1:${server.port}/metadata'),
        control: _TestTaskControl(), connections: connections,
        timeout: const Duration(seconds: 2), maxBytes: 1024);
    }
    expect(ports, hasLength(20));
    expect(ports.toSet(), hasLength(1), reason: ports.toString());
  });

  test('metadata cancellation retires its lease while another idle connection remains reusable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    final release = Completer<void>();
    final ports = <String, int>{};
    server.listen((request) async {
      ports[request.uri.path] = request.connectionInfo!.remotePort;
      if (request.uri.path == '/blocked') {
        request.response.write('partial');
        await request.response.flush();
        entered.complete();
        await release.future;
      } else {
        request.response.write('ok');
      }
      await request.response.close();
    });
    final connections = MetadataHttpConnections();
    addTearDown(connections.close);
    Future<MetadataHttpResponse> read(String path, _TestTaskControl control) =>
      const MetadataHttpTransport().request('GET',
        Uri.parse('http://127.0.0.1:${server.port}' + path),
        control: control, connections: connections,
        timeout: const Duration(seconds: 2), maxBytes: 1024);
    final control = _TestTaskControl();
    final blocked = expectLater(read('/blocked', control), throwsA(isA<MetadataHttpException>()
      .having((e) => e.reason, 'cancelled', MetadataHttpFailure.cancelled)));
    await entered.future;
    await read('/other', _TestTaskControl());
    control.cancel();
    await blocked;
    release.complete();
    await read('/reuse', _TestTaskControl());
    expect(ports['/blocked'], isNot(ports['/other']));
    expect(ports['/reuse'], ports['/other']);
  });
}

final class _TestTaskControl implements TaskControl {
  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  int get priority => 0;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
