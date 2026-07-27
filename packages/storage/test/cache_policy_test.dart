import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('LRU plan trims to target without protected records', () {
    final records = <CacheRec>[
      _rec('a', 40, 1),
      _rec('b', 30, 2),
      _rec('c', 50, 3),
    ];
    final plan = const CachePolicy().plan(
      records: records,
      limits: const CacheLimits(maxBytes: 100, targetBytes: 70),
      protectedKeys: <String>{records.first.key},
    );

    expect(plan.totalBytes, 120);
    expect(plan.protectedBytes, 40);
    expect(plan.candidates.map((record) => record.id.content.pageId), <String>['b', 'c']);
    expect(plan.projectedBytes, 40);
  });

  test('plan is empty while under the hard limit', () {
    final plan = const CachePolicy().plan(
      records: <CacheRec>[_rec('a', 10, 1)],
      limits: const CacheLimits(maxBytes: 20, targetBytes: 10),
    );
    expect(plan.candidates, isEmpty);
  });
}

CacheRec _rec(String page, int bytes, int touched) {
  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: page,
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/$page'),
  );
  return CacheRec(
    id: id,
    state: CacheState.ready,
    path: '/cache/$page',
    bytes: bytes,
    checksum: page,
    createdUs: touched,
    touchedUs: touched,
  );
}
