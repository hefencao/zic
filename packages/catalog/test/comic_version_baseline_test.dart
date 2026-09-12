import 'package:catalog/catalog.dart';
import 'package:test/test.dart';

void main() {
  ComicVersionPageMapping mapping(
    String predecessorChapter,
    String successorChapter,
    int predecessorCount,
    int successorCount,
    int offset,
  ) =>
      ComicVersionPageMapping(
        predecessorChapterId: predecessorChapter,
        successorChapterId: successorChapter,
        predecessorPageCount: predecessorCount,
        successorPageCount: successorCount,
        successorOffset: offset,
        verifiedAt: DateTime.utc(2026, 9, 1),
      );

  test('resolves distinct latest shelf and download heads without moving newer history backward', () {
    final projection = resolveComicVersionBaselines(
      relations: <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B',
          pageMappings: <ComicVersionPageMapping>[
            mapping('a', 'b', 3, 4, 1),
          ],
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B',
          successorComicId: 'C',
          pageMappings: <ComicVersionPageMapping>[
            mapping('b', 'c', 4, 6, 2),
          ],
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'C',
          successorComicId: 'D',
          pageMappings: <ComicVersionPageMapping>[
            mapping('c', 'd', 6, 7, 1),
          ],
        ),
      ],
      shelfComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'A'),
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );

    expect(projection.latestKnownHeadFor('s', 'A'), 'D');
    expect(projection.shelfHeadFor('s', 'A'), 'C');
    expect(projection.downloadHeadFor('s', 'A'), 'C');
    expect(projection.downloadHeadFor('s', 'D'), isNull);
    final directA = projection.downloadHeadRelations.singleWhere(
      (relation) => relation.predecessorComicId == 'A',
    );
    expect(directA.successorComicId, 'C');
    expect(directA.pageMappings.single.predecessorChapterId, 'a');
    expect(directA.pageMappings.single.successorChapterId, 'c');
    expect(directA.pageMappings.single.successorOffset, 3);
    expect(
      projection.downloadHeadRelations.any(
        (relation) => relation.predecessorComicId == 'D',
      ),
      isFalse,
    );
  });

  test('composed version offsets keep affine anchor provenance across verified edges', () {
    final projection = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'a',
              successorChapterId: 'b',
              predecessorPageCount: 3,
              successorPageCount: 4,
              successorOffset: 1,
              predecessorSourceRevision: 'a-r1',
              successorSourceRevision: 'b-r1',
              verifiedPredecessorPageIndexes: <int>[0, 1, 2],
            ),
          ],
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B',
          successorComicId: 'C',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'b',
              successorChapterId: 'c',
              predecessorPageCount: 4,
              successorPageCount: 4,
              successorOffset: 0,
              predecessorSourceRevision: 'b-r1',
              successorSourceRevision: 'c-r1',
              verifiedPredecessorPageIndexes: <int>[1, 3],
            ),
          ],
        ),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );

    final composed = projection.downloadHeadRelations.singleWhere(
      (relation) => relation.predecessorComicId == 'A',
    ).pageMappings.single;
    expect(composed.successorOffset, 1);
    expect(composed.predecessorSourceRevision, 'a-r1');
    expect(composed.successorSourceRevision, 'c-r1');
    expect(composed.verifiedPredecessorPageIndexes, <int>[0, 1, 2]);
  });

  test('composes multiple verified affine intervals by translated intersection', () {
    final projection = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'a',
              successorChapterId: 'b',
              predecessorPageCount: 6,
              successorPageCount: 7,
              successorOffset: 0,
              predecessorSourceRevision: 'a-r1',
              successorSourceRevision: 'b-r1',
              verifiedIntervals: <VerifiedComicVersionPageInterval>[
                VerifiedComicVersionPageInterval(
                  predecessorStart: 0,
                  predecessorEndExclusive: 3,
                  successorOffset: 0,
                ),
                VerifiedComicVersionPageInterval(
                  predecessorStart: 3,
                  predecessorEndExclusive: 6,
                  successorOffset: 1,
                ),
              ],
            ),
          ],
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B',
          successorComicId: 'C',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'b',
              successorChapterId: 'c',
              predecessorPageCount: 7,
              successorPageCount: 9,
              successorOffset: 1,
              predecessorSourceRevision: 'b-r1',
              successorSourceRevision: 'c-r1',
              verifiedIntervals: <VerifiedComicVersionPageInterval>[
                VerifiedComicVersionPageInterval(
                  predecessorStart: 0,
                  predecessorEndExclusive: 5,
                  successorOffset: 1,
                ),
                VerifiedComicVersionPageInterval(
                  predecessorStart: 5,
                  predecessorEndExclusive: 7,
                  successorOffset: 2,
                ),
              ],
            ),
          ],
        ),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );

    final composed = projection.downloadHeadRelations.singleWhere(
      (relation) => relation.predecessorComicId == 'A',
    ).pageMappings.single;
    expect(
      composed.effectiveVerifiedIntervals
          .map((interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ))
          .toList(),
      <(int, int, int)>[(0, 3, 1), (3, 4, 2), (4, 6, 3)],
    );
  });

  test('composed offset drops proof across a revision discontinuity', () {
    final projection = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'a',
              successorChapterId: 'b',
              predecessorPageCount: 1,
              successorPageCount: 1,
              successorOffset: 0,
              predecessorSourceRevision: 'a-r1',
              successorSourceRevision: 'b-r1',
              verifiedPredecessorPageIndexes: <int>[0],
            ),
          ],
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B',
          successorComicId: 'C',
          pageMappings: <ComicVersionPageMapping>[
            ComicVersionPageMapping(
              predecessorChapterId: 'b',
              successorChapterId: 'c',
              predecessorPageCount: 1,
              successorPageCount: 1,
              successorOffset: 0,
              predecessorSourceRevision: 'b-r2',
              successorSourceRevision: 'c-r1',
              verifiedPredecessorPageIndexes: <int>[0],
            ),
          ],
        ),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );

    final composed = projection.downloadHeadRelations.singleWhere(
      (relation) => relation.predecessorComicId == 'A',
    ).pageMappings.single;
    expect(composed.successorOffset, 0);
    expect(composed.verifiedPredecessorPageIndexes, isEmpty);
  });

  test('does not invent a latest head for an ambiguous branch', () {
    final projection = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B',
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'C',
        ),
      ],
      shelfComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'A'),
      ],
    );

    expect(projection.latestKnownHeadFor('s', 'A'), isNull);
    expect(projection.shelfHeadFor('s', 'A'), 'A');
  });

  test('ambiguous historical paths do not produce a direct download reuse proof', () {
    final projection = resolveComicVersionBaselines(
      relations: const <ComicVersionRelation>[
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B1',
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'A',
          successorComicId: 'B2',
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B1',
          successorComicId: 'C',
        ),
        ComicVersionRelation(
          sourceId: 's',
          predecessorComicId: 'B2',
          successorComicId: 'C',
        ),
      ],
      manualDownloadComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'A'),
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );

    expect(projection.downloadHeadFor('s', 'A'), 'C');
    expect(
      projection.downloadHeadRelations.any(
        (relation) => relation.predecessorComicId == 'A',
      ),
      isFalse,
    );
  });

  test('cache reuse keeps only direct verified relations between materialized versions', () {
    const relations = <ComicVersionRelation>[
      ComicVersionRelation(
        sourceId: 's',
        predecessorComicId: 'A',
        successorComicId: 'B',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'a',
            successorChapterId: 'b',
            predecessorPageCount: 4,
            successorPageCount: 5,
            successorOffset: 1,
            predecessorSourceRevision: 'a-r1',
            successorSourceRevision: 'b-r1',
            verifiedIntervals: <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 0,
                predecessorEndExclusive: 4,
                successorOffset: 1,
              ),
            ],
          ),
        ],
      ),
      ComicVersionRelation(
        sourceId: 's',
        predecessorComicId: 'B',
        successorComicId: 'C',
        pageMappings: <ComicVersionPageMapping>[
          ComicVersionPageMapping(
            predecessorChapterId: 'b',
            successorChapterId: 'c',
            predecessorPageCount: 5,
            successorPageCount: 7,
            successorOffset: 2,
            predecessorSourceRevision: 'b-r1',
            successorSourceRevision: 'c-r1',
            verifiedIntervals: <VerifiedComicVersionPageInterval>[
              VerifiedComicVersionPageInterval(
                predecessorStart: 1,
                predecessorEndExclusive: 5,
                successorOffset: 2,
              ),
            ],
          ),
        ],
      ),
    ];

    final endpointsOnly = resolveComicVersionBaselines(
      relations: relations,
      cacheReuseComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'A'),
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );
    expect(endpointsOnly.cacheReuseRelations, isEmpty);

    final allMaterialized = resolveComicVersionBaselines(
      relations: relations,
      cacheReuseComics: const <ComicVersionIdentity>[
        ComicVersionIdentity(sourceId: 's', comicId: 'A'),
        ComicVersionIdentity(sourceId: 's', comicId: 'B'),
        ComicVersionIdentity(sourceId: 's', comicId: 'C'),
      ],
    );
    expect(allMaterialized.cacheReuseRelations, hasLength(2));
    expect(
      allMaterialized.cacheReuseRelations
          .map((relation) =>
              '${relation.predecessorComicId}->${relation.successorComicId}')
          .toSet(),
      <String>{'A->B', 'B->C'},
    );
    expect(
      allMaterialized.cacheReuseRelations.any(
        (relation) =>
            relation.predecessorComicId == 'A' &&
            relation.successorComicId == 'C',
      ),
      isFalse,
    );
  });
}
