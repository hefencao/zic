import 'dart:typed_data';

import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('matches the standard CRC32 vector', () {
    final crc = Crc32()..add('123456789'.codeUnits);
    expect(crc.hex, 'cbf43926');
  });

  test('background chunks preserve serial CRC and reject overlapping mutation',
      () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(256 * 1024, (index) => index & 255),
    );
    final expected = Crc32()..add('prefix'.codeUnits)..add(bytes)..add(bytes);
    final crc = Crc32()..add('prefix'.codeUnits);
    final first = crc.addAsync(bytes);
    expect(() => crc.add(<int>[1]), throwsStateError);
    await expectLater(crc.addAsync(bytes), throwsStateError);
    await first;
    await crc.addAsync(bytes);
    expect(crc.hex, expected.hex);
    await crc.addAsync('123'.codeUnits);
    expected.add('123'.codeUnits);
    expect(crc.hex, expected.hex);
  });

  test('failed background CRC leaves the previous checksum usable', () async {
    final crc = Crc32()..add('123456789'.codeUnits);
    final bytes = List<int>.filled(64 * 1024, 0)..last = 256;
    await expectLater(crc.addAsync(bytes), throwsArgumentError);
    expect(crc.hex, 'cbf43926');
    crc.add(<int>[0]);
    expect(crc.hex, (Crc32()..add('123456789'.codeUnits)..add(<int>[0])).hex);
  });
}
