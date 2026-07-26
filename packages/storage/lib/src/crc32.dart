final class Crc32 {
  Crc32() : _value = 0xffffffff;

  int _value;

  void add(List<int> bytes) {
    var crc = _value;
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw ArgumentError.value(byte, 'bytes', 'must contain byte values');
      }
      crc = _table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    _value = crc;
  }

  int get value => (_value ^ 0xffffffff) & 0xffffffff;

  String get hex => value.toRadixString(16).padLeft(8, '0');

  static final List<int> _table = List<int>.generate(256, (index) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 1
          ? 0xedb88320 ^ (value >> 1)
          : value >> 1;
    }
    return value;
  }, growable: false);
}
