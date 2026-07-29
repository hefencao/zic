import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zic/cover_cache.dart';

void main() {
  test('coalesces in-flight cover loads and records a cache hit', () async {
    final gate = Completer<Uint8List>();
    final cache = CoverMemoryCache(maxBytes: 32, maxEntries: 4);
    var loads = 0;

    Future<Uint8List> loader() {
      loads++;
      return gate.future;
    }

    final first = cache.load('cover', loader);
    final second = cache.load('cover', loader);
    expect(loads, 1);
    gate.complete(Uint8List.fromList(<int>[1, 2, 3]));

    expect(await first, hasLength(3));
    expect(await second, hasLength(3));
    expect(cache.stats.hits, 1);
    expect(cache.stats.misses, 1);
  });

  test('evicts least-recently-used completed covers within byte budget', () async {
    final cache = CoverMemoryCache(maxBytes: 6, maxEntries: 4);
    var loads = 0;

    Future<Uint8List> load(String key) => cache.load(key, () async {
          loads++;
          return Uint8List.fromList(<int>[1, 2, 3, 4]);
        });

    await load('a');
    await load('b');
    expect(cache.stats.entries, 1);
    expect(cache.stats.bytes, 4);

    await load('a');
    expect(loads, 3, reason: 'a was the LRU victim after b completed');
  });

  test('does not retain a single cover larger than the configured budget', () async {
    final cache = CoverMemoryCache(maxBytes: 2, maxEntries: 4);
    var loads = 0;
    Future<Uint8List> loader() async {
      loads++;
      return Uint8List.fromList(<int>[1, 2, 3]);
    }

    await cache.load('large', loader);
    await cache.load('large', loader);
    expect(loads, 2);
    expect(cache.stats.entries, 0);
    expect(cache.stats.bytes, 0);
  });
}
