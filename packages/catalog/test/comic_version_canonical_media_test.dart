import 'package:catalog/catalog.dart';
import 'package:catalog/src/comic_version_canonical_media.dart';
import 'package:test/test.dart';

ComicVersionPageMapping _mapping({
  required String predecessorChapterId,
  required String successorChapterId,
  required int predecessorPageCount,
  required int successorPageCount,
  required String predecessorRevision,
  required String successorRevision,
  required List<VerifiedComicVersionPageInterval> intervals,
}) =>
    ComicVersionPageMapping(
      predecessorChapterId: predecessorChapterId,
      successorChapterId: successorChapterId,
      predecessorPageCount: predecessorPageCount,
      successorPageCount: successorPageCount,
      successorOffset: intervals.isEmpty ? 0 : intervals.first.successorOffset,
      predecessorSourceRevision: predecessorRevision,
      successorSourceRevision: successorRevision,
      verifiedIntervals: intervals,
    );

void main() {
  test('canonical media stable key round-trips without version expansion', () {
    const coordinate = CanonicalMediaCoordinate(
      familyId: VersionFamilyId('family:历史'),
      chapterId: CanonicalChapterId('chapter:2'),
      segmentId: CanonicalMediaSegmentId('segment:3'),
      offset: 120004,
    );

    expect(
      CanonicalMediaCoordinate.tryParseStableKey(coordinate.stableKey),
      coordinate,
    );
    expect(
      CanonicalMediaCoordinate.tryParseStableKey('unrelated-canonical-key'),
      isNull,
    );
    expect(
      CanonicalMediaCoordinate.tryParseStableKey(
        '${coordinate.stableKey}trailing',
      ),
      isNull,
    );
  });

  test('large seed chapter is one stable canonical segment', () {
    final union = ComicVersionCanonicalMediaUnion(
      familyId: const VersionFamilyId('family'),
    );
    final a = union.seedChapter(
      sourceId: 'source',
      comicId: 'A',
      chapterId: 'chapter-A',
      sourceRevision: 'A-r1',
      pageCount: 8000,
    );

    expect(union.chapterCount, 1);
    expect(union.segmentCount, 1);
    expect(a.intervals, hasLength(1));
    expect(a.intervals.single.length, 8000);
    expect(a.coordinateForPageIndex(7999).offset, 7999);
  });

  test('successor insertion appends one segment without rebasing old media', () {
    final union = ComicVersionCanonicalMediaUnion(
      familyId: const VersionFamilyId('family'),
    );
    final a = union.seedChapter(
      sourceId: 'source',
      comicId: 'A',
      chapterId: 'chapter-A',
      sourceRevision: 'A-r1',
      pageCount: 8000,
    );
    final before3999 = a.coordinateForPageIndex(3999);
    final before4000 = a.coordinateForPageIndex(4000);

    final b = union.integrateSuccessor(
      predecessor: a,
      successorComicId: 'B',
      successorChapterId: 'chapter-B',
      successorSourceRevision: 'B-r1',
      successorPageCount: 8003,
      mapping: _mapping(
        predecessorChapterId: 'chapter-A',
        successorChapterId: 'chapter-B',
        predecessorPageCount: 8000,
        successorPageCount: 8003,
        predecessorRevision: 'A-r1',
        successorRevision: 'B-r1',
        intervals: const <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 4000,
            successorOffset: 0,
          ),
          VerifiedComicVersionPageInterval(
            predecessorStart: 4000,
            predecessorEndExclusive: 8000,
            successorOffset: 3,
          ),
        ],
      ),
    );

    expect(union.segmentCount, 1);
    expect(a.coordinateForPageIndex(3999), before3999);
    expect(a.coordinateForPageIndex(4000), before4000);
    expect(b.intervals, hasLength(2));
    expect(b.coordinateForPageIndex(3999), before3999);
    expect(b.coordinateForPageIndex(4003), before4000);
    expect(b.coordinateForPageIndexOrNull(4000), isNull);
    expect(b.coordinateForPageIndexOrNull(4002), isNull);
  });

  test('later successor reuses inherited insertion without rewriting A or B', () {
    final union = ComicVersionCanonicalMediaUnion(
      familyId: const VersionFamilyId('family'),
    );
    final a = union.seedChapter(
      sourceId: 'source',
      comicId: 'A',
      chapterId: 'chapter-A',
      sourceRevision: 'A-r1',
      pageCount: 6,
    );
    final b = union.integrateSuccessor(
      predecessor: a,
      successorComicId: 'B',
      successorChapterId: 'chapter-B',
      successorSourceRevision: 'B-r1',
      successorPageCount: 8,
      mapping: _mapping(
        predecessorChapterId: 'chapter-A',
        successorChapterId: 'chapter-B',
        predecessorPageCount: 6,
        successorPageCount: 8,
        predecessorRevision: 'A-r1',
        successorRevision: 'B-r1',
        intervals: const <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 3,
            successorOffset: 0,
          ),
          VerifiedComicVersionPageInterval(
            predecessorStart: 3,
            predecessorEndExclusive: 6,
            successorOffset: 2,
          ),
        ],
      ),
    );
    final aCoordinates = <CanonicalMediaCoordinate>[
      for (var i = 0; i < a.pageCount; i++) a.coordinateForPageIndex(i),
    ];
    final bCoordinates = <CanonicalMediaCoordinate?>[
      for (var i = 0; i < b.pageCount; i++)
        b.coordinateForPageIndexOrNull(i),
    ];

    final c = union.integrateSuccessor(
      predecessor: b,
      successorComicId: 'C',
      successorChapterId: 'chapter-C',
      successorSourceRevision: 'C-r1',
      successorPageCount: 9,
      mapping: _mapping(
        predecessorChapterId: 'chapter-B',
        successorChapterId: 'chapter-C',
        predecessorPageCount: 8,
        successorPageCount: 9,
        predecessorRevision: 'B-r1',
        successorRevision: 'C-r1',
        intervals: const <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 8,
            successorOffset: 0,
          ),
        ],
      ),
    );

    expect(union.segmentCount, 1);
    expect(
      <CanonicalMediaCoordinate>[
        for (var i = 0; i < a.pageCount; i++) a.coordinateForPageIndex(i),
      ],
      aCoordinates,
    );
    expect(
      <CanonicalMediaCoordinate?>[
        for (var i = 0; i < b.pageCount; i++)
          b.coordinateForPageIndexOrNull(i),
      ],
      bCoordinates,
    );
    for (var i = 0; i < 8; i++) {
      expect(c.coordinateForPageIndexOrNull(i), bCoordinates[i]);
    }
    expect(c.coordinateForPageIndexOrNull(8), isNull);
  });

  test('replacement stays version-specific while surrounding pages still share', () {
    final union = ComicVersionCanonicalMediaUnion(
      familyId: const VersionFamilyId('family'),
    );
    final a = union.seedChapter(
      sourceId: 'source',
      comicId: 'A',
      chapterId: 'chapter-A',
      sourceRevision: 'A-r1',
      pageCount: 6,
    );
    final b = union.integrateSuccessor(
      predecessor: a,
      successorComicId: 'B',
      successorChapterId: 'chapter-B',
      successorSourceRevision: 'B-r1',
      successorPageCount: 6,
      mapping: _mapping(
        predecessorChapterId: 'chapter-A',
        successorChapterId: 'chapter-B',
        predecessorPageCount: 6,
        successorPageCount: 6,
        predecessorRevision: 'A-r1',
        successorRevision: 'B-r1',
        intervals: const <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 2,
            successorOffset: 0,
          ),
          VerifiedComicVersionPageInterval(
            predecessorStart: 3,
            predecessorEndExclusive: 6,
            successorOffset: 0,
          ),
        ],
      ),
    );

    expect(a.coordinateForPageIndex(1), b.coordinateForPageIndex(1));
    expect(a.coordinateForPageIndex(3), b.coordinateForPageIndex(3));
    expect(b.coordinateForPageIndexOrNull(2), isNull);
    expect(union.segmentCount, 1);
  });

  test('no verified overlap creates one private run and no shared coordinates', () {
    final union = ComicVersionCanonicalMediaUnion(
      familyId: const VersionFamilyId('family'),
    );
    final a = union.seedChapter(
      sourceId: 'source',
      comicId: 'A',
      chapterId: 'chapter-A',
      sourceRevision: 'A-r1',
      pageCount: 10000,
    );
    final b = union.integrateSuccessor(
      predecessor: a,
      successorComicId: 'B',
      successorChapterId: 'chapter-B',
      successorSourceRevision: 'B-r1',
      successorPageCount: 12000,
      mapping: _mapping(
        predecessorChapterId: 'chapter-A',
        successorChapterId: 'chapter-B',
        predecessorPageCount: 10000,
        successorPageCount: 12000,
        predecessorRevision: 'A-r1',
        successorRevision: 'B-r1',
        intervals: const <VerifiedComicVersionPageInterval>[],
      ),
    );

    expect(union.segmentCount, 1);
    expect(b.intervals, isEmpty);
    expect(b.coordinateForPageIndexOrNull(0), isNull);
  });

  _ledgerTests();
}

// Monotonic fallback ledger tests intentionally use pages without any strong
// content identity. They exercise only compact verified interval authority.
void _ledgerTests() {
  test('ledger reports identical verified merge as a no-op', () {
    final ledger = ComicVersionCanonicalMediaLedger();
    CanonicalMediaMergeResult merge() => ledger.mergeVerifiedMapping(
          sourceId: 'source',
          predecessorComicId: 'A',
          successorComicId: 'B',
          predecessorChapterId: 'a',
          successorChapterId: 'b',
          predecessorSourceRevision: 'a-r1',
          successorSourceRevision: 'b-r1',
          predecessorPageCount: 2,
          successorPageCount: 3,
          verifiedIntervals: const <VerifiedComicVersionPageInterval>[
            VerifiedComicVersionPageInterval(
              predecessorStart: 0,
              predecessorEndExclusive: 2,
              successorOffset: 1,
            ),
          ],
        );

    final first = merge();
    expect(first.predecessorChanged, isTrue);
    expect(first.successorChanged, isTrue);
    expect(first.changed, isTrue);

    final second = merge();
    expect(second.predecessorChanged, isFalse);
    expect(second.successorChanged, isFalse);
    expect(second.changed, isFalse);
    expect(second.predecessor.intervals, first.predecessor.intervals);
    expect(second.successor.intervals, first.successor.intervals);
  });

  test('ledger keeps unknown gaps exact-only and later fills them monotonically', () {
    final ledger = ComicVersionCanonicalMediaLedger();
    final ab = ledger.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'A',
      successorComicId: 'B',
      predecessorChapterId: 'a',
      successorChapterId: 'b',
      predecessorSourceRevision: 'a-r1',
      successorSourceRevision: 'b-r1',
      predecessorPageCount: 6,
      successorPageCount: 6,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 3,
          successorOffset: 0,
        ),
      ],
    );
    expect(ab.hasConflict, isFalse);
    expect(ab.predecessor.boundPageCount, 3);
    expect(ab.successor.boundPageCount, 3);
    expect(ab.successor.coordinateForPageIndexOrNull(3), isNull);
    final a0 = ab.predecessor.coordinateForPageIndex(0);
    final b0 = ab.successor.coordinateForPageIndex(0);
    expect(a0, b0);

    final bc = ledger.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'B',
      successorComicId: 'C',
      predecessorChapterId: 'b',
      successorChapterId: 'c',
      predecessorSourceRevision: 'b-r1',
      successorSourceRevision: 'c-r1',
      predecessorPageCount: 6,
      successorPageCount: 6,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 6,
          successorOffset: 0,
        ),
      ],
    );
    expect(bc.hasConflict, isFalse);
    expect(bc.predecessor.coordinateForPageIndex(0), b0);
    expect(bc.successor.coordinateForPageIndex(0), b0);
    final b4 = bc.predecessor.coordinateForPageIndex(4);
    expect(b4.segmentId, isNot(a0.segmentId));
    expect(bc.successor.coordinateForPageIndex(4), b4);

    final expandedAb = ledger.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'A',
      successorComicId: 'B',
      predecessorChapterId: 'a',
      successorChapterId: 'b',
      predecessorSourceRevision: 'a-r1',
      successorSourceRevision: 'b-r1',
      predecessorPageCount: 6,
      successorPageCount: 6,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 6,
          successorOffset: 0,
        ),
      ],
    );
    expect(expandedAb.hasConflict, isFalse);
    expect(expandedAb.successor.coordinateForPageIndex(4), b4);
    expect(
      expandedAb.predecessor.coordinateForPageIndex(4),
      b4,
      reason: 'later evidence must inherit the already-persisted B coordinate',
    );
    expect(expandedAb.predecessor.coordinateForPageIndex(0), a0);
  });

  test('ledger fails closed when verified evidence bridges different media', () {
    final first = ComicVersionCanonicalMediaLedger();
    final ab = first.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'A',
      successorComicId: 'B',
      predecessorChapterId: 'a',
      successorChapterId: 'b',
      predecessorSourceRevision: 'a-r1',
      successorSourceRevision: 'b-r1',
      predecessorPageCount: 2,
      successorPageCount: 2,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 2,
          successorOffset: 0,
        ),
      ],
    );
    final second = ComicVersionCanonicalMediaLedger();
    final cd = second.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'C',
      successorComicId: 'D',
      predecessorChapterId: 'c',
      successorChapterId: 'd',
      predecessorSourceRevision: 'c-r1',
      successorSourceRevision: 'd-r1',
      predecessorPageCount: 2,
      successorPageCount: 2,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 2,
          successorOffset: 0,
        ),
      ],
    );
    final merged = ComicVersionCanonicalMediaLedger(
      projections: <VersionChapterCanonicalProjection>[
        ab.predecessor,
        ab.successor,
        cd.predecessor,
        cd.successor,
      ],
    );
    final bridge = merged.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'B',
      successorComicId: 'C',
      predecessorChapterId: 'b',
      successorChapterId: 'c',
      predecessorSourceRevision: 'b-r1',
      successorSourceRevision: 'c-r1',
      predecessorPageCount: 2,
      successorPageCount: 2,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 2,
          successorOffset: 0,
        ),
      ],
    );
    expect(bridge.hasConflict, isTrue);
    expect(
      bridge.predecessor.coordinateForPageIndex(0),
      ab.successor.coordinateForPageIndex(0),
    );
    expect(
      bridge.successor.coordinateForPageIndex(0),
      cd.predecessor.coordinateForPageIndex(0),
    );
  });

  test('projection json roundtrip preserves sparse canonical coordinates', () {
    final ledger = ComicVersionCanonicalMediaLedger();
    final result = ledger.mergeVerifiedMapping(
      sourceId: 'source',
      predecessorComicId: 'A',
      successorComicId: 'B',
      predecessorChapterId: 'a',
      successorChapterId: 'b',
      predecessorSourceRevision: 'a-r1',
      successorSourceRevision: 'b-r1',
      predecessorPageCount: 8000,
      successorPageCount: 8003,
      verifiedIntervals: const <VerifiedComicVersionPageInterval>[
        VerifiedComicVersionPageInterval(
          predecessorStart: 0,
          predecessorEndExclusive: 4000,
          successorOffset: 0,
        ),
        VerifiedComicVersionPageInterval(
          predecessorStart: 4000,
          predecessorEndExclusive: 8000,
          successorOffset: 3,
        ),
      ],
    );
    final restored = VersionChapterCanonicalProjection.fromJson(
      result.successor.toJson(),
    );
    expect(restored.pageCount, 8003);
    expect(restored.intervals, hasLength(2));
    expect(restored.coordinateForPageIndexOrNull(4000), isNull);
    expect(
      restored.coordinateForPageIndex(4003),
      result.predecessor.coordinateForPageIndex(4000),
    );
  });
}
