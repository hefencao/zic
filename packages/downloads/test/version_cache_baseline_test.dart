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

    // The full verified relation set is a separate cache authority. The newer
    // version need not be a manual download head for its immutable body to be
    // reused by a related version.
    service.updateCacheVersionRelations(const <ComicVersionRelation>[relation]);
    final stream = await service.openArtifactStream(oldId);
    expect(stream, isNotNull);
    final chunks = await stream!.open(start: 0).toList();
    expect(Uint8List.fromList(chunks.expand((chunk) => chunk).toList()), bytes);
  });
}
