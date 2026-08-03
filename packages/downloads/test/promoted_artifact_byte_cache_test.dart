import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces concurrent immutable artifact reads', () async {
    final id = _id('coalesced');
    final cache = PromotedArtifactByteCache(maxEntries: 2, maxBytes: 1024);
    final ready = Completer<Uint8List>();
    var loads = 0;

    Future<Uint8List> loader() {
      loads++;
      return ready.future;
    }

    final first = cache.read(id: id, length: 4, loader: loader);
    final second = cache.read(id: id, length: 4, loader: loader);
    ready.complete(Uint8List.fromList(<int>[1, 2, 3, 4]));

    final results = await Future.wait(<Future<PromotedArtifactByteRead>>[
      first,
      second,
    ]);
    expect(loads, 1);
    expect(results[0].joined, isFalse);
    expect(results[1].joined, isTrue);
    expect(results[0].bytes, <int>[1, 2, 3, 4]);
    expect(identical(results[0].bytes, results[1].bytes), isTrue);
    expect(cache.entryCount, 1);
    expect(cache.retainedBytes, 4);
  });

  test('evicts least-recently-used bytes within entry and byte bounds',
      () async {
    final cache = PromotedArtifactByteCache(maxEntries: 2, maxBytes: 7);
    final first = _id('first');
    final second = _id('second');
    final third = _id('third');

    await cache.read(
      id: first,
      length: 3,
      loader: () async => Uint8List(3),
    );
    await cache.read(
      id: second,
      length: 3,
      loader: () async => Uint8List(3),
    );
    expect(cache.lookup(first, length: 3), isNotNull);
    await cache.read(
      id: third,
      length: 4,
      loader: () async => Uint8List(4),
    );

    expect(cache.lookup(first, length: 3), isNotNull);
    expect(cache.lookup(second, length: 3), isNull);
    expect(cache.lookup(third, length: 4), isNotNull);
    expect(cache.entryCount, 2);
    expect(cache.retainedBytes, 7);
  });

  test('rejects a changed artifact length without retaining bytes', () async {
    final id = _id('changed');
    final cache = PromotedArtifactByteCache();

    await expectLater(
      cache.read(
        id: id,
        length: 4,
        loader: () async => Uint8List(5),
      ),
      throwsStateError,
    );
    expect(cache.lookup(id), isNull);
    expect(cache.entryCount, 0);
  });
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('file:///$page.webp'),
    );
