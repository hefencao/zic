import 'dart:isolate';

// A bound callable copies only one byte chunk and the running checksum into
// Isolate.run, never the artifact/session or its cancellation/scheduler state.
final class _Crc32Chunk {
  const _Crc32Chunk(this.value, this.bytes);

  final int value;
  final List<int> bytes;

  int call() => (Crc32._raw(value)..add(bytes))._value;
}

final class Crc32 {
  Crc32() : _value = 0xffffffff;

  factory Crc32.fromHex(String checksum) {
    if (!RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(checksum)) {
      throw FormatException('CRC32 checksum must contain eight hex digits');
    }
    final value = int.parse(checksum, radix: 16);
    return Crc32._raw(value ^ 0xffffffff);
  }

  Crc32._raw(this._value);

  int _value;
  bool _addingAsync = false;

  void add(List<int> bytes) {
    if (_addingAsync) {
      throw StateError('await the pending CRC32 chunk before adding bytes');
    }
    var crc = _value;
    for (final byte in bytes) {
      if (byte < 0 || byte > 255) {
        throw ArgumentError.value(byte, 'bytes', 'must contain byte values');
      }
      crc = _table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    _value = crc;
  }

  /// Adds a serial chunk without running a large byte loop on the caller.
  /// The caller must await physical completion before cancellation or reuse.
  Future<void> addAsync(List<int> bytes) async {
    if (bytes.length < 64 * 1024) {
      add(bytes);
      return;
    }
    if (_addingAsync) {
      throw StateError('await the pending CRC32 chunk before adding bytes');
    }
    _addingAsync = true;
    try {
      final chunk = _Crc32Chunk(_value, bytes);
      _value = await Isolate.run<int>(chunk.call);
    } finally {
      _addingAsync = false;
    }
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
