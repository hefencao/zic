import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/media_load_token.dart';
import 'package:zic/reader_page_cache.dart';

void main() {
  test('shares a warm load with a foreground page without caller ownership', () async {
    final cache = ReaderPageBytesCache(maxBytes: 32, maxEntries: 3);
    final gate = Completer<Uint8List>();
    var loads = 0;

    Future<Uint8List> loader(MediaLoadToken token) {
      loads++;
      return gate.future;
    }

    final warm = cache.warm('page-1', loader);
    final caller = MediaLoadToken();
    final foreground = cache.load('page-1', caller, loader);
    expect(loads, 1);

    gate.complete(Uint8List.fromList(<int>[1, 2, 3]));
    await warm;
    expect(await foreground, hasLength(3));
    expect(cache.stats.hits, 1);
    await cache.close();
  });

  test('caller cancellation does not cancel shared internal warmup', () async {
    final cache = ReaderPageBytesCache(maxBytes: 32, maxEntries: 3);
    final gate = Completer<Uint8List>();
    final caller = MediaLoadToken();

    final foreground = cache.load('page-1', caller, (_) => gate.future);
    caller.cancel();
    await expectLater(
      foreground,
      throwsA(isA<Failure>().having(
        (failure) => failure.code,
        'code',
        ErrorCode.cancelled,
      )),
    );

    gate.complete(Uint8List.fromList(<int>[4, 5]));
    await Future<void>.delayed(Duration.zero);
    final second = MediaLoadToken();
    expect(await cache.load('page-1', second, (_) async => Uint8List(0)),
        hasLength(2));
    await cache.close();
  });

  test('obsolete background warmups are cancelled', () async {
    final cache = ReaderPageBytesCache(maxBytes: 32, maxEntries: 3);
    final cancelled = Completer<void>();

    unawaited(cache.warm('old', (token) async {
      await token.whenCancelled;
      cancelled.complete();
      token.throwIfCancelled();
      return Uint8List(0);
    }));
    await Future<void>.delayed(Duration.zero);
    cache.retainWarmKeys(<String>{'new'});
    await cancelled.future;
    await cache.close();
  });
}
