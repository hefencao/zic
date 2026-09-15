import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:test/test.dart';

void main() {
  test('active family projection outranks standalone strong locator identity', () {
    final manifest = ChapterManifest(
      sourceId: 'venera:ehentai',
      comicId: 'version-a',
      chapter: const Chapter(
        chapterId: 'chapter-a',
        comicId: 'version-a',
        title: 'Chapter',
        sequence: 0,
        pageCount: 1,
        sourceRevision: 'a-r1',
      ),
      pages: <PageAsset>[
        PageAsset(
          pageId: 'page-0',
          chapterId: 'chapter-a',
          index: 0,
          uri: Uri.parse('https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1'),
        ),
      ],
      readingDirection: ReadingDirection.vertical,
    );
    const segment = CanonicalMediaSegmentId('shared');
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('chapter-family'),
      sourceId: manifest.sourceId,
      comicId: manifest.comicId,
      chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision,
      pageCount: 1,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: segment,
          segmentStart: 0,
        ),
      ],
    );
    final id = readerPageDownloadId(manifest, manifest.pages.single);
    final projected = PhysicalMediaId.canonical(
      projection.coordinateForPageIndex(0).stableKey,
    );
    final stable = verifiedPhysicalMediaId(
      sourceId: manifest.sourceId,
      page: manifest.pages.single,
    );
    expect(stable, isNotNull);
    expect(stable, isNot(projected));

    final active = CanonicalMediaChapterAuthority(
      manifest: manifest,
      projection: projection,
      activeProjectionRanges: const <CanonicalMediaActiveRange>[
        CanonicalMediaActiveRange(start: 0, endExclusive: 1),
      ],
    );
    expect(active.resolve(id), projected);

    final inactive = CanonicalMediaChapterAuthority(
      manifest: manifest,
      projection: projection,
    );
    expect(inactive.resolve(id), stable);
  });

  test('volatile Venera carriers do not prove a physical page owner', () {
    ChapterManifest manifest(String carrier) => ChapterManifest(
          sourceId: 'venera:jm',
          comicId: 'comic',
          chapter: const Chapter(
            chapterId: 'chapter',
            comicId: 'comic',
            title: 'Chapter',
            sequence: 0,
            pageCount: 1,
            sourceRevision: 'ep-1',
          ),
          pages: <PageAsset>[
            PageAsset(
              pageId: 'chapter:0',
              chapterId: 'chapter',
              index: 0,
              uri: Uri.parse('venera-resource:$carrier'),
            ),
          ],
          readingDirection: ReadingDirection.vertical,
        );

    final first = manifest('first-provider-carrier');
    final second = manifest('second-provider-carrier');
    final firstId = readerPageDownloadId(first, first.pages.single);
    final secondId = readerPageDownloadId(second, second.pages.single);
    final firstAuthority = CanonicalMediaChapterAuthority(manifest: first);
    final secondAuthority = CanonicalMediaChapterAuthority(manifest: second);

    expect(firstAuthority.resolve(firstId), isNull);
    expect(secondAuthority.resolve(secondId), isNull);
    expect(
      firstAuthority.resolve(secondId),
      isNull,
      reason: 'a stale provider carrier must not pass current-manifest validation',
    );
  });

  test('canonical projection batch rejects partial durable publication', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-canonical-projection-batch-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    const family = VersionFamilyId('family');
    const chapterFamily = CanonicalChapterId('chapter-family');
    const originalSegment = CanonicalMediaSegmentId('original');
    final original = VersionChapterCanonicalProjection(
      familyId: family,
      canonicalChapterId: chapterFamily,
      sourceId: 'source',
      comicId: 'comic-a',
      chapterId: 'chapter-a',
      sourceRevision: 'a-r1',
      pageCount: 1,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: originalSegment,
          segmentStart: 0,
        ),
      ],
    );
    await store.persistCanonicalMediaProjection(original);

    final sibling = VersionChapterCanonicalProjection(
      familyId: family,
      canonicalChapterId: chapterFamily,
      sourceId: 'source',
      comicId: 'comic-b',
      chapterId: 'chapter-b',
      sourceRevision: 'b-r1',
      pageCount: 1,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: originalSegment,
          segmentStart: 0,
        ),
      ],
    );
    final rebased = original.copyWithIntervals(
      const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: CanonicalMediaSegmentId('replacement'),
          segmentStart: 0,
        ),
      ],
    );

    await expectLater(
      store.persistCanonicalMediaProjections(
        <VersionChapterCanonicalProjection>[sibling, rebased],
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );

    final loaded = await store.loadCanonicalMediaProjections();
    expect(loaded, hasLength(1));
    expect(loaded.single.exactKey, original.exactKey);
    expect(
      loaded.single.coordinateForPageIndex(0),
      original.coordinateForPageIndex(0),
    );
  });

}
