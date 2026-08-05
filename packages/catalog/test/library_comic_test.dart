import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  test('comic aggregate groups chapters and selects latest reading progress', () {
    final first = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-1',
        title: '第 1 话',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 26),
      ),
      progress: ReadingProgress(
        sourceId: 'local-folder',
        comicId: 'comic-1',
        chapterId: 'chapter-1',
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 27),
      ),
    );
    final second = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-2',
        title: '第 2 话',
        sequence: 2,
        importedAt: DateTime.utc(2026, 7, 28),
      ),
    );

    final comic = LibraryComic.fromEntries(<ImportedLibraryEntry>[second, first]);

    expect(comic.comicId, 'comic-1');
    expect(comic.title, '聚合漫画');
    expect(
      comic.chapters.map((entry) => entry.chapter.chapterId),
      <String>['chapter-1', 'chapter-2'],
    );
    expect(comic.totalPages, 4);
    expect(comic.latestChapter!.chapter.chapterId, 'chapter-2');
    expect(comic.resumeChapter!.chapter.chapterId, 'chapter-1');
  });

  test('library aggregation emits one comic per comic identity', () {
    final comics = aggregateImportedLibrary(<ImportedLibraryEntry>[
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'chapter-2',
          title: '第 2 话',
          sequence: 2,
          importedAt: DateTime.utc(2026, 7, 28),
        ),
      ),
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'chapter-1',
          title: '第 1 话',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 27),
        ),
      ),
      ImportedLibraryEntry(
        chapter: _chapter(
          comicId: 'comic-2',
          chapterId: 'chapter-other',
          title: '单章',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 26),
        ),
      ),
    ]);

    expect(comics, hasLength(2));
    expect(comics.first.comicId, 'comic-1');
    expect(comics.first.chapters, hasLength(2));
    expect(comics.last.comicId, 'comic-2');
  });

  test('aggregate selects and combines persisted remote metadata', () {
    final first = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-meta-1',
        title: '第 1 话',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 27),
      ).copyWith(
        comicAuthors: const <String>['作者 A'],
      ),
    );
    final second = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-meta-2',
        title: '第 2 话',
        sequence: 2,
        importedAt: DateTime.utc(2026, 7, 28),
      ).copyWith(
        comicAuthors: const <String>['作者 B'],
        comicDescription: '远程简介',
        coverSourceId: 'https://example.invalid/cover.jpg',
      ),
    );

    final comic = LibraryComic.fromEntries(<ImportedLibraryEntry>[first, second]);

    expect(comic.authors, containsAll(<String>['作者 A', '作者 B']));
    expect(comic.description, '远程简介');
    expect(comic.coverChapter!.chapter.chapterId, 'chapter-meta-2');
  });

  test('same native comic id from different sources stays separated', () {
    final local = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-local',
        title: '本地章节',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 27),
      ),
    );
    final remote = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'chapter-remote',
        title: '远程章节',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 28),
      ).copyWith(sourceId: 'remote-fixture'),
    );

    final comics = aggregateImportedLibrary(<ImportedLibraryEntry>[local, remote]);

    expect(comics, hasLength(2));
    expect(comics.map((comic) => comic.sourceId),
        containsAll(<String>['local-folder', 'remote-fixture']));
  });


  test('saved remote comic projects a whole work without importing chapters', () {
    final manifest = _remoteManifest(
      sourceId: 'remote-source',
      comicId: 'saved-comic',
      chapterTitles: const <String>['第 1 话', '第 2 话'],
    );
    final saved = SavedComicRecord.fromManifest(
      manifest,
      savedAt: DateTime.utc(2026, 7, 28),
      updatedAt: DateTime.utc(2026, 7, 28, 1),
    );

    final comic = aggregateImportedLibrary(
      const <ImportedLibraryEntry>[],
      savedComics: <SavedComicRecord>[saved],
    ).single;

    expect(comic.sourceId, 'remote-source');
    expect(comic.comicId, 'saved-comic');
    expect(comic.chapters, isEmpty);
    expect(comic.sourceChapters, hasLength(2));
    expect(comic.resumeChapter, isNull);
    expect(comic.hasSourceCatalog, isTrue);
  });

  test('source migration only marks title and sequence matches exact', () {
    final sourceEntry = ImportedLibraryEntry(
      chapter: _chapter(
        chapterId: 'source-chapter-1',
        title: '第 1 话',
        sequence: 1,
        importedAt: DateTime.utc(2026, 7, 28),
      ).copyWith(sourceId: 'source-a'),
      progress: ReadingProgress(
        sourceId: 'source-a',
        comicId: 'comic-1',
        chapterId: 'source-chapter-1',
        pageIndex: 1,
        subPageOffset: 0.5,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      ),
    );
    final source = LibraryComic.fromEntries(<ImportedLibraryEntry>[sourceEntry]);
    final target = _remoteManifest(
      sourceId: 'source-b',
      comicId: 'target-comic',
      chapterTitles: const <String>['第 1 话'],
    );

    final plan = ComicSourceMigrationPlan.build(
      source: source,
      target: target,
    );

    expect(plan.chapterMatches, hasLength(1));
    expect(
      plan.chapterMatches.single.confidence,
      ChapterMigrationConfidence.exact,
    );
    final migrated = plan.migratePreference(
      ComicPreference.defaults(sourceId: source.sourceId, comicId: source.comicId).copyWith(
        liked: true,
        collected: true,
        categoryIds: const <String>{'reading'},
      ),
      targetCustomOrder: 9,
    );
    expect(migrated.sourceId, 'source-b');
    expect(migrated.comicId, 'target-comic');
    expect(migrated.liked, isTrue);
    expect(migrated.collected, isTrue);
    expect(migrated.categoryIds, contains('reading'));
    expect(migrated.customOrder, 9);
  });

  test('source migration comparison normalizes title and author evidence', () {
    final source = LibraryComic.fromEntries(<ImportedLibraryEntry>[
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'source-normalized',
          title: '第 1 话',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 28),
        ).copyWith(
          sourceId: 'source-a',
          comicAuthors: const <String>['作者 A'],
        ),
      ),
    ]);
    final plan = ComicSourceMigrationPlan.build(
      source: source,
      target: _remoteManifest(
        sourceId: 'source-b',
        comicId: 'target-normalized',
        chapterTitles: const <String>['第 1 话'],
        title: '聚合 漫画',
        authors: const <String>['作者-A'],
      ),
    );

    final comparison = plan.comparison();

    expect(comparison.titleMatches, isTrue);
    expect(comparison.sharedAuthors, const <String>['作者 A']);
    expect(comparison.exactChapterMatches, 1);
    expect(comparison.risks, isEmpty);
  });

  test('source migration comparison exposes identity and risk evidence', () {
    final source = LibraryComic.fromEntries(<ImportedLibraryEntry>[
      for (var index = 0; index < 3; index++)
        ImportedLibraryEntry(
          chapter: _chapter(
            chapterId: 'source-compare-${index + 1}',
            title: '第 ${index + 1} 话',
            sequence: index + 1,
            importedAt: DateTime.utc(2026, 7, 28, index),
          ).copyWith(
            sourceId: 'source-a',
            comicAuthors: const <String>['源作者'],
          ),
        ),
    ]);
    final plan = ComicSourceMigrationPlan.build(
      source: source,
      target: _remoteManifest(
        sourceId: 'source-b',
        comicId: 'target-comic',
        chapterTitles: const <String>['目标第一章', '目标第二章'],
        title: '另一个标题',
        authors: const <String>['目标作者'],
        readingDirection: ReadingDirection.rtl,
      ),
    );

    final comparison = plan.comparison(sampleLimit: 3);

    expect(comparison.sourceIdentity, 'source-a:comic-1');
    expect(comparison.targetIdentity, 'source-b:target-comic');
    expect(comparison.titleMatches, isFalse);
    expect(comparison.sharedAuthors, isEmpty);
    expect(comparison.readingDirectionDiffers, isTrue);
    expect(comparison.exactChapterMatches, 0);
    expect(comparison.sequenceOnlyChapterMatches, 2);
    expect(comparison.unmatchedSourceChapters, 1);
    expect(
      comparison.risks,
      containsAll(<ComicSourceMigrationRisk>[
        ComicSourceMigrationRisk.titleDiffers,
        ComicSourceMigrationRisk.noSharedAuthors,
        ComicSourceMigrationRisk.readingDirectionDiffers,
        ComicSourceMigrationRisk.sequenceOnlyMatches,
        ComicSourceMigrationRisk.unmatchedSourceChapters,
      ]),
    );
    expect(comparison.chapterSamples, hasLength(3));
    expect(comparison.chapterSamples.last.matched, isFalse);
  });

  test('source migration merges instead of erasing target preferences', () {
    final source = LibraryComic.fromEntries(<ImportedLibraryEntry>[
      ImportedLibraryEntry(
        chapter: _chapter(
          chapterId: 'source-chapter-1',
          title: '第 1 话',
          sequence: 1,
          importedAt: DateTime.utc(2026, 7, 28),
        ).copyWith(sourceId: 'source-a'),
      ),
    ]);
    final plan = ComicSourceMigrationPlan.build(
      source: source,
      target: _remoteManifest(
        sourceId: 'source-b',
        comicId: 'target-comic',
        chapterTitles: const <String>['第 1 话'],
      ),
    );
    final sourcePreference = ComicPreference.defaults(
      sourceId: source.sourceId,
      comicId: source.comicId,
    ).copyWith(
      inShelf: false,
      liked: true,
      categoryIds: const <String>{'source-category'},
    );
    final targetPreference = ComicPreference.defaults(
      sourceId: 'source-b',
      comicId: 'target-comic',
      sourceKind: ComicSourceKind.remote,
      customOrder: 4,
    ).copyWith(
      collected: true,
      categoryIds: const <String>{'target-category'},
    );
    final updatedAt = DateTime.utc(2026, 7, 28, 3);

    final merged = plan.mergePreference(
      sourcePreference,
      existingTarget: targetPreference,
      targetCustomOrder: 99,
      updatedAt: updatedAt,
    );

    expect(merged.sourceId, 'source-b');
    expect(merged.comicId, 'target-comic');
    expect(merged.inShelf, isTrue);
    expect(merged.liked, isTrue);
    expect(merged.collected, isTrue);
    expect(
      merged.categoryIds,
      const <String>{'source-category', 'target-category'},
    );
    expect(merged.customOrder, 4);
    expect(merged.updatedAt, updatedAt);
  });

  test('saved comic JSON keeps a lightweight chapter catalog', () {
    final saved = SavedComicRecord.fromManifest(
      _remoteManifest(
        sourceId: 'remote-json',
        comicId: 'comic-json',
        chapterTitles: const <String>['第一章'],
      ),
      canonicalComicId: 'https://example.invalid/comic-json',
      savedAt: DateTime.utc(2026, 7, 28),
      updatedAt: DateTime.utc(2026, 7, 28, 2),
    );

    final restored = SavedComicRecord.fromJson(saved.toJson());
    expect(restored.toJson(), saved.toJson());
    expect(restored.canonicalComicId, 'https://example.invalid/comic-json');
    expect(restored.chapters.single.title, '第一章');
    expect(restored.tags, const <String>['剧情', '全彩']);

    final legacy = Map<String, Object?>.from(saved.toJson())..remove('chapters');
    expect(SavedComicRecord.fromJson(legacy).chapters, isEmpty);
  });

  test('chapter JSON remains compatible while persisting aggregate metadata', () {
    final chapter = _chapter(
      chapterId: 'chapter-7',
      title: '第 7 话',
      sequence: 7,
      importedAt: DateTime.utc(2026, 7, 28),
    );

    final restored = ImportedChapterRecord.fromJson(chapter.toJson());

    expect(restored.comicTitle, '聚合漫画');
    expect(restored.sequence, 7);
    expect(restored.toJson(), chapter.toJson());

    final legacy = Map<String, Object?>.from(chapter.toJson())
      ..remove('comicTitle')
      ..remove('comicAuthors')
      ..remove('comicTags')
      ..remove('comicDescription')
      ..remove('sequence');
    final legacyRestored = ImportedChapterRecord.fromJson(legacy);
    expect(legacyRestored.comicTitle, chapter.displayName);
    expect(legacyRestored.comicAuthors, isEmpty);
    expect(legacyRestored.comicTags, isEmpty);
    expect(legacyRestored.comicDescription, isNull);
    expect(legacyRestored.sequence, 0);
  });

  test('chapter JSON rejects malformed aggregate metadata', () {
    final json = _chapter(
      chapterId: 'chapter-3',
      title: '第 3 话',
      sequence: 3,
      importedAt: DateTime.utc(2026, 7, 28),
    ).toJson();

    expect(
      () => ImportedChapterRecord.fromJson(
        Map<String, Object?>.from(json)..['comicTitle'] = '',
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedChapterRecord.fromJson(
        Map<String, Object?>.from(json)..['sequence'] = '3',
      ),
      throwsFormatException,
    );
  });

  test('canonical alias projection keeps the richer source catalog', () {
    final short = SavedComicRecord.fromManifest(
      _remoteManifest(
        sourceId: 'mihon:fixture',
        comicId: 'mutable-alias-short',
        chapterTitles: const <String>['第一话'],
      ),
      updatedAt: DateTime.utc(2026, 8, 2, 1),
    );
    final complete = SavedComicRecord.fromManifest(
      _remoteManifest(
        sourceId: 'mihon:fixture',
        comicId: 'mutable-alias-complete',
        chapterTitles: <String>[
          for (var index = 1; index <= 12; index++) '第 $index 话',
        ],
      ),
      updatedAt: DateTime.utc(2026, 8, 2),
    );

    final collapsed = collapseCanonicalLibraryComics(
      aggregateImportedLibrary(
        const <ImportedLibraryEntry>[],
        savedComics: <SavedComicRecord>[short, complete],
      ),
      canonicalIdentity: (sourceId, comicId) =>
          '$sourceId\u0000https://example.invalid/work/42',
    );

    expect(collapsed, hasLength(1));
    expect(collapsed.single.comicId, 'mutable-alias-complete');
    expect(collapsed.single.sourceChapters, hasLength(12));
  });

  test('chapter copy preserves aggregate identity while replacing page data', () {
    final chapter = _chapter(
      chapterId: 'chapter-4',
      title: '第 4 话',
      sequence: 4,
      importedAt: DateTime.utc(2026, 7, 28),
    );
    final refreshed = chapter.copyWith(
      sourceRevision: 'revision-refreshed',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'new.png',
          sourceId: '/library/chapter-4/new.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

    expect(refreshed.comicId, chapter.comicId);
    expect(refreshed.comicTitle, chapter.comicTitle);
    expect(refreshed.chapterId, chapter.chapterId);
    expect(refreshed.sequence, chapter.sequence);
    expect(refreshed.sourceRevision, 'revision-refreshed');
    expect(refreshed.pages.single.displayName, 'new.png');
  });
}

ImportedChapterRecord _chapter({
  String comicId = 'comic-1',
  required String chapterId,
  required String title,
  required int sequence,
  required DateTime importedAt,
}) {
  return ImportedChapterRecord(
    directoryId: '/library/$chapterId',
    displayName: title,
    sourceId: 'local-folder',
    comicId: comicId,
    comicTitle: comicId == 'comic-1' ? '聚合漫画' : '其他漫画',
    chapterId: chapterId,
    sourceRevision: 'revision-$chapterId',
    sequence: sequence,
    importedAt: importedAt,
    pages: <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '001.png',
        sourceId: '/library/$chapterId/001.png',
        contentKindHint: ContentKindHint.png,
      ),
      ImportedPageRecord(
        displayName: '002.png',
        sourceId: '/library/$chapterId/002.png',
        contentKindHint: ContentKindHint.png,
      ),
    ],
  );
}


ComicManifest _remoteManifest({
  required String sourceId,
  required String comicId,
  required List<String> chapterTitles,
  String title = '远程漫画',
  List<String> authors = const <String>['作者'],
  ReadingDirection readingDirection = ReadingDirection.ltr,
}) =>
    ComicManifest(
      comic: Comic(
        comicId: comicId,
        sourceId: sourceId,
        title: title,
        authors: authors,
        tags: const <String>['剧情', '全彩'],
        coverUri: Uri.https('example.invalid', '/cover.png'),
        description: '简介',
        readingDirection: readingDirection,
      ),
      chapters: <Chapter>[
        for (var index = 0; index < chapterTitles.length; index++)
          Chapter(
            chapterId: '$sourceId-chapter-${index + 1}',
            comicId: comicId,
            title: chapterTitles[index],
            sequence: index + 1,
            pageCount: 2,
            sourceRevision: '$sourceId-r${index + 1}',
          ),
      ],
    );
