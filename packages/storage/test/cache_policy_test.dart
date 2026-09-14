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

  test('shared ready bindings count one physical artifact and protect as a group', () {
    final first = _rec('shared-a', 40, 1).copyWith(artifactId: 'shared-artifact');
    final second = _rec('shared-b', 40, 5).copyWith(artifactId: 'shared-artifact');
    final other = _rec('other', 30, 2);

    final plan = const CachePolicy().plan(
      records: <CacheRec>[first, second, other],
      limits: const CacheLimits(maxBytes: 60, targetBytes: 30),
      protectedKeys: <String>{second.key},
    );

    expect(plan.totalBytes, 70,
        reason: 'two logical bindings share one 40-byte physical artifact');
    expect(plan.protectedBytes, 40);
    expect(plan.candidates.map((record) => record.key), <String>[other.key]);
    expect(plan.plannedBytes, 30);
    expect(plan.projectedBytes, 40);
  });

  test('shared artifact eviction selects every logical binding once', () {
    final first = _rec('shared-a', 40, 1).copyWith(artifactId: 'shared-artifact');
    final second = _rec('shared-b', 40, 5).copyWith(artifactId: 'shared-artifact');

    final plan = const CachePolicy().plan(
      records: <CacheRec>[first, second],
      limits: const CacheLimits(maxBytes: 39, targetBytes: 0),
    );

    expect(plan.totalBytes, 40);
    expect(plan.candidates.map((record) => record.key).toSet(),
        <String>{first.key, second.key});
    expect(plan.plannedBytes, 40);
    expect(plan.projectedBytes, 0);
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
