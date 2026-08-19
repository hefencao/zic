import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';

void main() {
  test('trim uses LRU but leaves protected and busy sessions intact', () async {
    final temp = await Directory.systemTemp.createTemp('cache_ops_test_');
    addTearDown(() => temp.delete(recursive: true));
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final registry = DownloadRegistry(
      layout: CacheLayout(temp.path),
      clock: FakeMonoClock(),
      index: index,
    );
    addTearDown(registry.dispose);

    final old = _id('old');
    final protected = _id('protected');
    final busy = _id('busy');
    await _writeReady(registry.get(old), 40);
    await _writeReady(registry.get(protected), 30);
    await _writeReady(registry.get(busy), 50);
    await index.touch(old.key, 1);
    await index.touch(protected.key, 2);
    await index.touch(busy.key, 3);
    final run = registry.get(busy).beginRun();
    addTearDown(() => registry.get(busy).endRun(run));

    final report = await CacheOps(
      index: index,
      registry: registry,
      clock: FakeMonoClock(),
    ).trim(
      const CacheLimits(maxBytes: 100, targetBytes: 60),
      protected: <DownloadId>{protected},
    );

    expect(report.releasedBytes, 40);
    expect(report.evicted, 1);
    expect(report.skippedBusy, 1);
    expect(await index.get(old.key), isNull);
    expect(await index.get(protected.key), isNotNull);
    expect(await index.get(busy.key), isNotNull);
  });
}

Future<void> _writeReady(DownloadSession session, int count) async {
  await session.restore();
  final writer = session.acquireWriter();
  await session.append(writer, 0, List<int>.filled(count, 1));
  await session.seal(writer, expectedLength: count);
  await session.promote();
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$page'),
    );
