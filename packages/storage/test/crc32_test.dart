import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('matches the standard CRC32 vector', () {
    final crc = Crc32()..add('123456789'.codeUnits);
    expect(crc.hex, 'cbf43926');
  });
}
