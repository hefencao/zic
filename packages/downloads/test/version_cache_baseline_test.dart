import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('artifact cache version reuse is independent from manual download head',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-cache-version-baseline-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    const sourceId = 'source';
    const chapterId = 'chapter';
    const pageId = 'shared-page';
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: sourceId,
        comicId: 'old',
        chapterId: chapterId,
        pageId: pageId,
      ),
      sourceRevision: 'old-r1',
      canonicalUri: Uri.parse('https://example.test/old/page.webp'),
    );
    final newerId = DownloadId(
      content: const ContentId(
        sourceId: sourceId,
        comicId: 'newer-unstarted',
        chapterId: chapterId,
        pageId: pageId,
      ),
      sourceRevision: 'new-r1',
      canonicalUri: Uri.parse('https://example.test/new/page.webp'),
    );
    const relation = ComicVersionRelation(
      sourceId: sourceId,
      predecessorComicId: 'old',
      successorComicId: 'newer-unstarted',
      pageMappings: <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: chapterId,
          successorChapterId: chapterId,
          predecessorPageCount: 1,
          successorPageCount: 1,
          successorOffset: 0,
        ),
      ],
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 1, 2, 3, 4,
    ]);
    await service.storePromotedArtifact(id: newerId, bytes: bytes);

    // A manual/export baseline alone must not grant cache equivalence.
    service.updateVersionBaselines(const <ComicVersionRelation>[relation]);
    service.updateCacheVersionRelations(const <ComicVersionRelation>[]);
    expect(await service.openArtifactStream(oldId), isNull);

    // Persistent storage remains exact even when the app knows a verified
    // version relation. Cross-version reuse belongs to ArtifactCacheManager,
    // which must preserve the actual storage identity of the reused body.
    service.updateCacheVersionRelations(const <ComicVersionRelation>[relation]);
    expect(await service.openArtifactStream(oldId), isNull);
    expect(await service.artifactCacheManager.lookupAuthoritative(oldId), isNull);

    service.artifactCacheManager.linkEquivalent(first: oldId, second: newerId);
    final lookup = await service.artifactCacheManager.lookup(oldId);
    expect(lookup, isNotNull);
    expect(lookup!.id, oldId);
    expect(lookup.storageId, newerId);
    expect(lookup.durable, isTrue);
    final read = await service.artifactCacheManager.readForegroundLookup(lookup);
    expect(read.bytes, bytes);
  });
  test('persistent backend never aliases a same-URI sibling as exact storage',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-cache-exact-same-uri-');
    addTearDown(() => root.delete(recursive: true));
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);

    final uri = Uri.parse('https://example.test/shared/page.webp');
    final target = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'target',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'target-r1',
      canonicalUri: uri,
    );
    final sibling = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'sibling',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'sibling-r1',
      canonicalUri: uri,
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 5, 6, 7, 8,
    ]);
    await service.storePromotedArtifact(id: sibling, bytes: bytes);

    expect(await service.openArtifactStream(target), isNull);
    expect(await service.artifactCacheManager.lookupAuthoritative(target), isNull);
    expect(
      await service.artifactCacheManager.containsBackendExact(
        id: target,
        expectedLength: bytes.length,
      ),
      isFalse,
    );

    service.artifactCacheManager.linkEquivalent(first: target, second: sibling);
    final lookup = await service.artifactCacheManager.lookup(target);
    expect(lookup, isNotNull);
    expect(lookup!.storageId, sibling);
    expect((await service.artifactCacheManager.readForegroundLookup(lookup)).bytes,
        bytes);
  });

}
