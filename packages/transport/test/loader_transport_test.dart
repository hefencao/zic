import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  final uri = Uri.parse('content://provider/document/page-1');

  test('loader transport serves full and resumed byte ranges', () async {
    var reads = 0;
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'r1',
        loadBytes: () async {
          reads++;
          return Uint8List.fromList(<int>[0, 1, 2, 3, 4]);
        },
      ),
    });

    final full = await transport.open(uri);
    expect(
      await full.bytes.expand((chunk) => chunk).toList(),
      <int>[0, 1, 2, 3, 4],
    );
    expect(full.statusCode, 200);
    expect(full.rangeSupported, isTrue);

    final resumed = await transport.open(
      uri,
      range: const ByteRange(start: 2),
      validators: full.validators,
    );
    expect(
      await resumed.bytes.expand((chunk) => chunk).toList(),
      <int>[2, 3, 4],
    );
    expect(resumed.statusCode, 206);
    expect(resumed.rangeStart, 2);
    expect(reads, 2);
  });

  test('same-length source changes invalidate resume validators', () async {
    var bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'r1',
        loadBytes: () async => bytes,
      ),
    });
    final first = await transport.open(uri);
    await first.bytes.drain<void>();

    bytes = Uint8List.fromList(<int>[4, 5, 6]);
    final changed = await transport.open(
      uri,
      range: const ByteRange(start: 1),
      validators: first.validators,
    );

    expect(changed.statusCode, 200);
    expect(changed.rangeStart, 0);
    expect(
      await changed.bytes.expand((chunk) => chunk).toList(),
      <int>[4, 5, 6],
    );
  });

  test('stale validators restart from zero', () async {
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'r2',
        loadBytes: () async => Uint8List.fromList(<int>[1, 2, 3]),
      ),
    });

    final response = await transport.open(
      uri,
      range: const ByteRange(start: 2),
      validators: const Validators(etag: '"old"'),
    );

    expect(response.statusCode, 200);
    expect(response.rangeStart, 0);
    expect(await response.bytes.expand((chunk) => chunk).toList(), <int>[1, 2, 3]);
  });

  test('unknown source is rejected', () async {
    final transport = LoaderTransport(const <Uri, LoaderTransportSource>{});

    await expectLater(
      transport.open(uri),
      throwsA(isA<Object>()),
    );
  });
}
