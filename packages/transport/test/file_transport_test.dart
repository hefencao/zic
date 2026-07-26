import 'dart:io';

import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('file transport serves a validated range', () async {
    final temp = await Directory.systemTemp.createTemp('file_transport_test_');
    addTearDown(() async {
      await temp.delete(recursive: true);
    });
    final file = File('${temp.path}/page.bin');
    await file.writeAsBytes(List<int>.generate(10, (index) => index));

    const transport = FileTransport();
    final full = await transport.open(file.uri);
    final partial = await transport.open(
      file.uri,
      range: const ByteRange(start: 4),
      validators: full.validators,
    );

    expect(partial.isPartial, isTrue);
    expect(partial.rangeStart, 4);
    expect(await partial.bytes.expand((chunk) => chunk).toList(), <int>[4, 5, 6, 7, 8, 9]);
  });
}
