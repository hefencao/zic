import 'dart:io';

import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
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
}
