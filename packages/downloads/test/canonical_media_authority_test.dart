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
}
