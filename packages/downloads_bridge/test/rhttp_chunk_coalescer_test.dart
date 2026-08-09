import 'dart:typed_data';

import 'package:downloads_bridge/src/rhttp_chunk_coalescer.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces small packets into VibeVenera-sized stream chunks', () {
    final coalescer = RhttpChunkCoalescer();
    final emitted = <Uint8List>[];

    for (var i = 0; i < 46; i += 1) {
      final ready = coalescer.add(Uint8List(1460));
      if (ready != null) emitted.add(ready);
    }
    expect(emitted, hasLength(1));
    expect(emitted.single.length, greaterThanOrEqualTo(64 * 1024));
    expect(emitted.single.length, lessThan(64 * 1024 + 1460));

    for (var i = 0; i < 180; i += 1) {
      final ready = coalescer.add(Uint8List(1460));
      if (ready != null) emitted.add(ready);
    }
    expect(emitted, hasLength(2));
    expect(emitted[1].length, greaterThanOrEqualTo(256 * 1024));
    expect(emitted[1].length, lessThan(256 * 1024 + 1460));

    final tail = coalescer.flush();
    expect(tail, isNotNull);
    expect(tail, isNotEmpty);
  });

  test('does not emit an incomplete startup chunk until final flush', () {
    final coalescer = RhttpChunkCoalescer();
    expect(coalescer.add(Uint8List(16)), isNull);
    expect(coalescer.add(Uint8List(4096)), isNull);
    final tail = coalescer.flush();
    expect(tail, isNotNull);
    expect(tail!.length, 4112);
  });
}
