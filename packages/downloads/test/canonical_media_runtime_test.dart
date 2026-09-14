import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:test/test.dart';

void main() {
  test('active exact projections share one canonical physical session', () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final first = _manifest('first', 'first-r1');
    final second = _manifest('second', 'second-r1');
    const family = VersionFamilyId('family');
    const chapter = CanonicalChapterId('chapter-family');
    const segment = CanonicalMediaSegmentId('shared-segment');
    final firstProjection = _projection(
      first,
      family: family,
      chapter: chapter,
      segment: segment,
    );
    final secondProjection = _projection(
      second,
      family: family,
      chapter: chapter,
      segment: segment,
    );
    runtime.replaceCanonicalMediaAuthorityScope(
      'library',
      <CanonicalMediaChapterAuthority>[
        _authority(first, firstProjection),
        _authority(second, secondProjection),
      ],
    );

    final firstId = readerPageDownloadId(first, first.pages.single);
    final secondId = readerPageDownloadId(second, second.pages.single);
    final firstPhysical = runtime.physicalMediaIdFor(firstId);
    final secondPhysical = runtime.physicalMediaIdFor(secondId);

    expect(firstPhysical.isExactFallback, isFalse);
    expect(secondPhysical, firstPhysical);
    expect(runtime.sessionFor(secondId), same(runtime.sessionFor(firstId)));
  });

  test('conflicting canonical scopes fail closed to exact ownership', () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final manifest = _manifest('conflict', 'conflict-r1');
    final first = _projection(
      manifest,
      family: const VersionFamilyId('family-a'),
      chapter: const CanonicalChapterId('chapter-a'),
      segment: const CanonicalMediaSegmentId('segment-a'),
    );
    final second = _projection(
      manifest,
      family: const VersionFamilyId('family-b'),
      chapter: const CanonicalChapterId('chapter-b'),
      segment: const CanonicalMediaSegmentId('segment-b'),
    );
    runtime.replaceCanonicalMediaAuthorityScope(
      'first',
      <CanonicalMediaChapterAuthority>[_authority(manifest, first)],
    );
    runtime.replaceCanonicalMediaAuthorityScope(
      'second',
      <CanonicalMediaChapterAuthority>[_authority(manifest, second)],
    );
    final id = readerPageDownloadId(manifest, manifest.pages.single);

    expect(runtime.physicalMediaIdFor(id).isExactFallback, isTrue);

    runtime.replaceCanonicalMediaAuthorityScope(
      'second',
      const <CanonicalMediaChapterAuthority>[],
    );
    final resolved = runtime.physicalMediaIdFor(id);
    expect(resolved.isExactFallback, isFalse);
    expect(runtime.sessionFor(id).physicalId, resolved);
  });
}

ChapterManifest _manifest(String comicId, String revision) {
  final chapterId = 'chapter-$comicId';
  return ChapterManifest(
    sourceId: 'source',
    comicId: comicId,
    chapter: Chapter(
      chapterId: chapterId,
      comicId: comicId,
      title: 'Chapter',
      sequence: 0,
      pageCount: 1,
      sourceRevision: revision,
    ),
    pages: <PageAsset>[
      PageAsset(
        pageId: 'page-$comicId',
        chapterId: chapterId,
        index: 0,
        uri: Uri.parse('venera-resource:$comicId'),
      ),
    ],
    readingDirection: ReadingDirection.vertical,
  );
}

VersionChapterCanonicalProjection _projection(
  ChapterManifest manifest, {
  required VersionFamilyId family,
  required CanonicalChapterId chapter,
  required CanonicalMediaSegmentId segment,
}) =>
    VersionChapterCanonicalProjection(
      familyId: family,
      canonicalChapterId: chapter,
      sourceId: manifest.sourceId,
      comicId: manifest.comicId,
      chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision,
      pageCount: 1,
      intervals: <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 1,
          segmentId: segment,
          segmentStart: 0,
        ),
      ],
    );

CanonicalMediaChapterAuthority _authority(
  ChapterManifest manifest,
  VersionChapterCanonicalProjection projection,
) =>
    CanonicalMediaChapterAuthority(
      manifest: manifest,
      projection: projection,
      activeProjectionRanges: const <CanonicalMediaActiveRange>[
        CanonicalMediaActiveRange(start: 0, endExclusive: 1),
      ],
    );
