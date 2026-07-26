import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/page.webp'),
  );

  for (final fixture in <String, CacheIndex Function()>{
    'memory': MemIndex.new,
    'sqlite': SqliteIndex.memory,
  }.entries) {
    test('${fixture.key} index upserts and totals records', () async {
      final index = fixture.value();
      await index.open();
      addTearDown(index.close);

      final partial = CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/tmp/page.part',
        bytes: 10,
        checksum: 'a',
        createdUs: 1,
        touchedUs: 2,
      );
      await index.put(partial);
      expect((await index.get(id.key))?.state, CacheState.partial);
      expect(await index.totalBytes(), 10);

      await index.put(
        partial.copyWith(
          state: CacheState.ready,
          path: '/tmp/page.bin',
          bytes: 20,
          checksum: 'b',
          touchedUs: 3,
        ),
      );
      expect(await index.list(state: CacheState.partial), isEmpty);
      expect(await index.totalBytes(state: CacheState.ready), 20);

      await index.remove(id.key);
      expect(await index.get(id.key), isNull);
    });
  }
}
