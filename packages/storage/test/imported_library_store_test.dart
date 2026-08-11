import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

void main() {
  test('sqlite persists discovered comic version predecessors', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-comic-version-relation-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/library.sqlite3';
    final relation = ComicVersionRelation(
      sourceId: 'venera:ehentai',
      predecessorComicId: 'old-comic',
      successorComicId: 'new-comic',
      predecessorTitle: '旧版标题',
      discoveredAt: DateTime.utc(2026, 8, 11, 1),
    );

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    await store.saveComicVersionRelation(relation);
    await store.close();

    final reopened = SqliteImportedLibraryStore(path);
    await reopened.open();
    addTearDown(reopened.close);
    final predecessors = await reopened.listComicVersionPredecessors(
      relation.sourceId,
      relation.successorComicId,
    );
    expect(predecessors, hasLength(1));
    expect(predecessors.single.sourceId, relation.sourceId);
    expect(
      predecessors.single.predecessorComicId,
      relation.predecessorComicId,
    );
    expect(predecessors.single.successorComicId, relation.successorComicId);
    expect(predecessors.single.predecessorTitle, relation.predecessorTitle);
    expect(predecessors.single.discoveredAt, relation.discoveredAt);
    final all = await reopened.listAllComicVersionRelations();
    expect(all, hasLength(1));
    expect(all.single.successorComicId, relation.successorComicId);
    expect(all.single.discoveredAt, relation.discoveredAt);
    final successors = await reopened.listComicVersionSuccessors(
      relation.sourceId,
      relation.predecessorComicId,
    );
    expect(successors, hasLength(1));
    expect(successors.single.successorComicId, relation.successorComicId);
    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 7);
  });

  test('sqlite imported library persists chapter, progress, and cascade delete',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);

    final chapter = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/chapter',
      displayName: 'Chapter',
      importedAt: DateTime.utc(2026, 7, 28),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/001',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          byteLength: 140,
          animatedHint: true,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'content://provider/document/002',
          contentKindHint: ContentKindHint.png,
          mediaFormat: 'png',
          byteLength: 68,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final progress = ReadingProgress(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 1,
      subPageOffset: 0,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 7, 28, 2),
    );
    await store.saveProgress(progress);

    final entry = await store.get(chapter.sourceId, chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.toJson(), progress.toJson());
    expect((await store.list()).single.chapter.chapterId, chapter.chapterId);

    await store.removeChapter(chapter.sourceId, chapter.chapterId);
    expect(await store.get(chapter.sourceId, chapter.chapterId), isNull);
  });


  test('sqlite refresh follows the same page source after insertion', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);

    final first = ImportedChapterRecord.folder(
      directoryId: '/library/refresh',
      displayName: 'Refresh',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/library/refresh/2.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '3.png',
          sourceId: '/library/refresh/3.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(first);
    await store.saveProgress(
      ReadingProgress(
        sourceId: first.sourceId,
        comicId: first.comicId,
        chapterId: first.chapterId,
        pageIndex: 1,
        subPageOffset: 0.25,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 7, 28, 4),
      ),
    );

    final refreshed = ImportedChapterRecord.folder(
      directoryId: '/library/refresh',
      displayName: 'Refresh',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/library/refresh/1.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: '/library/refresh/2.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '3.png',
          sourceId: '/library/refresh/3.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(refreshed);

    final entry = await store.get(refreshed.sourceId, refreshed.chapterId);
    expect(entry?.progress?.pageIndex, 2);
    expect(entry?.progress?.subPageOffset, 0.25);
  });

  test('sqlite imported library survives close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-imported-library-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/catalog/library.sqlite3';
    final chapter = ImportedChapterRecord.folder(
      directoryId: 'content://provider/tree/persisted',
      displayName: 'Persisted chapter',
      importedAt: DateTime.utc(2026, 7, 28),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'content://provider/document/persisted-001',
          contentKindHint: ContentKindHint.webp,
          mediaFormat: 'webp',
          byteLength: 140,
          animatedHint: true,
        ),
      ],
    );
    final progress = ReadingProgress(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 0,
      subPageOffset: 0.25,
      readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 7, 28, 3),
    );

    final first = SqliteImportedLibraryStore(path);
    await first.open();
    await first.upsertChapter(chapter);
    await first.saveProgress(progress);
    await first.close();

    final reopened = SqliteImportedLibraryStore(path);
    await reopened.open();
    addTearDown(reopened.close);
    final entry = await reopened.get(chapter.sourceId, chapter.chapterId);
    expect(entry?.chapter.toJson(), chapter.toJson());
    expect(entry?.progress?.toJson(), progress.toJson());
  });

  test('sqlite library persists shelf preferences and chapter read state',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '/library/preferences',
      displayName: 'Preferences',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: '/library/preferences/1.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final now = DateTime.utc(2026, 7, 28, 9);
    final category = LibraryCategory(
      categoryId: 'reading',
      name: '阅读中',
      sortOrder: 1,
      createdAt: now,
    );
    await store.upsertCategory(category);
    final preference = ComicPreference.defaults(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
    ).copyWith(
      liked: true,
      categoryIds: const <String>{'reading'},
      customOrder: 7,
      updatedAt: now,
    );
    await store.saveComicPreference(preference);
    final state = ChapterReadState(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      isRead: true,
      updatedAt: now,
    );
    await store.saveChapterReadState(state);

    expect((await store.listCategories()).single.toJson(), category.toJson());
    expect(
      (await store.getComicPreference(chapter.sourceId, chapter.comicId))?.toJson(),
      preference.toJson(),
    );
    expect(
      (await store.listChapterReadStates(chapter.sourceId, chapter.comicId)).single.toJson(),
      state.toJson(),
    );
    expect(
      (await store.listAllChapterReadStates()).single.toJson(),
      state.toJson(),
    );

    await store.removeChapter(chapter.sourceId, chapter.chapterId);
    expect(await store.listChapterReadStates(chapter.sourceId, chapter.comicId), isEmpty);
    expect(await store.getComicPreference(chapter.sourceId, chapter.comicId), isNull);
  });

  test('sqlite migrates schema 2 source preferences', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-source-preference-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA user_version = 2');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    await store.saveSourcePreference(
      ComicSourcePreference(
        sourceId: 'mangadex',
        enabled: true,
        sortOrder: 0,
        updatedAt: DateTime.utc(2026, 7, 28, 11),
      ),
    );

    expect((await store.listSourcePreferences()).single.sourceId, 'mangadex');
  });

  test('sqlite persists comic source enablement and order', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final first = ComicSourcePreference(
      sourceId: 'mangadex',
      enabled: true,
      sortOrder: 1,
      updatedAt: DateTime.utc(2026, 7, 28, 11),
    );
    final second = ComicSourcePreference(
      sourceId: 'fixture',
      enabled: false,
      sortOrder: 0,
      updatedAt: DateTime.utc(2026, 7, 28, 12),
    );

    await store.saveSourcePreference(first);
    await store.saveSourcePreference(second);

    final values = await store.listSourcePreferences();
    expect(values.map((item) => item.sourceId), <String>['fixture', 'mangadex']);
    expect(values.first.enabled, isFalse);
    expect(values.last.toJson(), first.toJson());
  });


  test('sqlite persists a whole comic without importing a chapter', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final saved = _savedComic();
    final preference = ComicPreference.defaults(
      sourceId: saved.sourceId,
      comicId: saved.comicId,
      sourceKind: ComicSourceKind.remote,
    ).copyWith(
      inShelf: true,
      collected: true,
      updatedAt: DateTime.utc(2026, 7, 28, 12),
    );

    await store.upsertSavedComic(saved);
    await store.saveComicPreference(preference);

    expect(await store.list(), isEmpty);
    expect(
      (await store.getSavedComic(saved.sourceId, saved.comicId))?.toJson(),
      saved.toJson(),
    );
    expect((await store.listSavedComics()).single.chapters, hasLength(2));

    await store.removeSavedComic(saved.sourceId, saved.comicId);
    expect(await store.listSavedComics(), isEmpty);
    expect(await store.getComicPreference(saved.sourceId, saved.comicId), isNull);
  });

  test('sqlite migrates schema 3 through composite schema 7', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-saved-comic-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA user_version = 3');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final saved = _savedComic();
    await store.upsertSavedComic(saved);

    expect(
      (await store.getSavedComic(saved.sourceId, saved.comicId))?.toJson(),
      saved.toJson(),
    );
    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 7);
  });

  test('sqlite schema 5 adds durable migration issue acknowledgement',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-migration-issue-ack-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE library_migration_issue (
        issue_id INTEGER PRIMARY KEY AUTOINCREMENT,
        schema_from INTEGER NOT NULL,
        entity_kind TEXT NOT NULL,
        legacy_key TEXT NOT NULL,
        resolved_source_id TEXT,
        detail_json TEXT NOT NULL,
        created_us INTEGER NOT NULL
      )
    ''');
    legacy.execute(
      'INSERT INTO library_migration_issue VALUES (?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        1,
        4,
        'comic_preference',
        'legacy-comic',
        'source-a',
        jsonEncode(<String, Object?>{'reason': 'ambiguous owner'}),
        DateTime.utc(2026, 7, 29).microsecondsSinceEpoch,
      ],
    );
    legacy.execute('PRAGMA user_version = 5');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    expect((await store.listMigrationIssues()).single.issueId, 1);

    final acknowledgedAt = DateTime.utc(2026, 7, 29, 1);
    await store.acknowledgeMigrationIssues(
      const <int>[1],
      acknowledgedAt: acknowledgedAt,
    );
    expect(await store.listMigrationIssues(), isEmpty);
    final retained = await store.listMigrationIssues(includeAcknowledged: true);
    expect(retained, hasLength(1));
    expect(retained.single.acknowledgedAt, acknowledgedAt);

    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 7);
    expect(
      db.select('PRAGMA table_info(library_migration_issue)')
          .map((row) => row['name'])
          .toSet(),
      contains('acknowledged_us'),
    );
  });

  test('sqlite keeps comic preference until the last grouped chapter is removed',
      () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final first = _groupedChapter('chapter-1', 1);
    final second = _groupedChapter('chapter-2', 2);
    await store.upsertChapter(first);
    await store.upsertChapter(second);
    final preference = ComicPreference.defaults(
      sourceId: first.sourceId,
      comicId: first.comicId,
    ).copyWith(
      liked: true,
      updatedAt: DateTime.utc(2026, 7, 28, 10),
    );
    await store.saveComicPreference(preference);

    expect(aggregateImportedLibrary(await store.list()).single.chapters,
        hasLength(2));

    await store.removeChapter(first.sourceId, first.chapterId);
    expect(await store.getComicPreference(first.sourceId, first.comicId), isNotNull);
    expect(aggregateImportedLibrary(await store.list()).single.chapters,
        hasLength(1));

    await store.removeChapter(second.sourceId, second.chapterId);
    expect(await store.getComicPreference(first.sourceId, first.comicId), isNull);
  });

  test('schema 5 isolates identical native ids across sources', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);

    final first = _sourceChapter('source-a');
    final second = _sourceChapter('source-b');
    await store.upsertChapter(first);
    await store.upsertChapter(second);
    await store.saveProgress(
      _progressFor(first, pageIndex: 0, minute: 1),
    );
    await store.saveProgress(
      _progressFor(second, pageIndex: 1, minute: 2),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: first.sourceId,
        comicId: first.comicId,
        sourceKind: ComicSourceKind.remote,
      ).copyWith(liked: true, updatedAt: DateTime.utc(2026, 7, 28, 13, 1)),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: second.sourceId,
        comicId: second.comicId,
        sourceKind: ComicSourceKind.remote,
      ).copyWith(collected: true, updatedAt: DateTime.utc(2026, 7, 28, 13, 2)),
    );
    await store.saveChapterReadState(
      ChapterReadState(
        sourceId: first.sourceId,
        comicId: first.comicId,
        chapterId: first.chapterId,
        isRead: true,
        updatedAt: DateTime.utc(2026, 7, 28, 13, 3),
      ),
    );
    await store.saveChapterReadState(
      ChapterReadState(
        sourceId: second.sourceId,
        comicId: second.comicId,
        chapterId: second.chapterId,
        isRead: false,
        updatedAt: DateTime.utc(2026, 7, 28, 13, 4),
      ),
    );

    expect((await store.list()), hasLength(2));
    expect((await store.get(first.sourceId, first.chapterId))?.progress?.pageIndex, 0);
    expect((await store.get(second.sourceId, second.chapterId))?.progress?.pageIndex, 1);
    expect(
      (await store.getComicPreference(first.sourceId, first.comicId))?.liked,
      isTrue,
    );
    expect(
      (await store.getComicPreference(second.sourceId, second.comicId))
          ?.collected,
      isTrue,
    );
    expect(
      (await store.listChapterReadStates(first.sourceId, first.comicId))
          .single
          .isRead,
      isTrue,
    );
    expect(
      (await store.listChapterReadStates(second.sourceId, second.comicId))
          .single
          .isRead,
      isFalse,
    );

    await store.removeChapter(first.sourceId, first.chapterId);
    expect(await store.get(first.sourceId, first.chapterId), isNull);
    expect(await store.get(second.sourceId, second.chapterId), isNotNull);
  });

  test('schema 4 migration resolves ambiguous preference and reports it',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-composite-schema-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    final chapter = _sourceChapter('source-a');
    final progress = _progressFor(chapter, pageIndex: 1, minute: 5);
    final readState = ChapterReadState(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      isRead: true,
      updatedAt: DateTime.utc(2026, 7, 28, 14, 6),
    );
    final preference = ComicPreference.defaults(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true, updatedAt: DateTime.utc(2026, 7, 28, 14, 7));
    final legacyPreference = Map<String, Object?>.from(preference.toJson())
      ..remove('sourceId');
    final legacyProgress = Map<String, Object?>.from(progress.toJson())
      ..remove('sourceId');
    final legacyReadState = Map<String, Object?>.from(readState.toJson())
      ..remove('sourceId');
    final sourceAComic = _savedComicFor(
      sourceId: 'source-a',
      updatedAt: DateTime.utc(2026, 7, 28, 14, 1),
    );
    final sourceBComic = _savedComicFor(
      sourceId: 'source-b',
      updatedAt: DateTime.utc(2026, 7, 28, 14, 2),
    );

    legacy.execute('PRAGMA foreign_keys = ON');
    legacy.execute('''
      CREATE TABLE imported_chapter (
        chapter_id TEXT NOT NULL PRIMARY KEY,
        comic_id TEXT NOT NULL,
        imported_us INTEGER NOT NULL,
        chapter_json TEXT NOT NULL
      )
    ''');
    legacy.execute('''
      CREATE TABLE reading_progress (
        chapter_id TEXT NOT NULL PRIMARY KEY,
        updated_us INTEGER NOT NULL,
        progress_json TEXT NOT NULL
      )
    ''');
    legacy.execute('''
      CREATE TABLE comic_preference (
        comic_id TEXT NOT NULL PRIMARY KEY,
        updated_us INTEGER NOT NULL,
        preference_json TEXT NOT NULL
      )
    ''');
    legacy.execute('''
      CREATE TABLE chapter_read_state (
        chapter_id TEXT NOT NULL PRIMARY KEY,
        comic_id TEXT NOT NULL,
        updated_us INTEGER NOT NULL,
        read_json TEXT NOT NULL
      )
    ''');
    legacy.execute('''
      CREATE TABLE saved_comic (
        source_id TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        saved_us INTEGER NOT NULL,
        updated_us INTEGER NOT NULL,
        comic_json TEXT NOT NULL,
        PRIMARY KEY(source_id, comic_id)
      )
    ''');
    legacy.execute(
      'INSERT INTO imported_chapter VALUES (?, ?, ?, ?)',
      <Object?>[
        chapter.chapterId,
        chapter.comicId,
        chapter.importedAt.microsecondsSinceEpoch,
        jsonEncode(chapter.toJson()),
      ],
    );
    legacy.execute(
      'INSERT INTO reading_progress VALUES (?, ?, ?)',
      <Object?>[
        progress.chapterId,
        progress.updatedAt.microsecondsSinceEpoch,
        jsonEncode(legacyProgress),
      ],
    );
    legacy.execute(
      'INSERT INTO comic_preference VALUES (?, ?, ?)',
      <Object?>[
        preference.comicId,
        preference.updatedAt.microsecondsSinceEpoch,
        jsonEncode(legacyPreference),
      ],
    );
    legacy.execute(
      'INSERT INTO chapter_read_state VALUES (?, ?, ?, ?)',
      <Object?>[
        readState.chapterId,
        readState.comicId,
        readState.updatedAt.microsecondsSinceEpoch,
        jsonEncode(legacyReadState),
      ],
    );
    for (final saved in <SavedComicRecord>[sourceAComic, sourceBComic]) {
      legacy.execute(
        'INSERT INTO saved_comic VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          saved.sourceId,
          saved.comicId,
          saved.savedAt.microsecondsSinceEpoch,
          saved.updatedAt.microsecondsSinceEpoch,
          jsonEncode(saved.toJson()),
        ],
      );
    }
    legacy.execute('PRAGMA user_version = 4');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);

    expect((await store.get('source-a', chapter.chapterId))?.progress?.pageIndex, 1);
    expect(
      (await store.listChapterReadStates('source-a', chapter.comicId))
          .single
          .isRead,
      isTrue,
    );
    expect(await store.getComicPreference('source-a', chapter.comicId), isNull);
    expect(
      (await store.getComicPreference('source-b', chapter.comicId))?.liked,
      isTrue,
    );
    final issues = await store.listMigrationIssues();
    expect(issues, hasLength(1));
    expect(issues.single.schemaFrom, 4);
    expect(issues.single.entityKind, 'comic_preference');
    expect(issues.single.legacyKey, chapter.comicId);
    expect(issues.single.resolvedSourceId, 'source-b');
    expect(
      issues.single.details['reason'],
      'remote preference had multiple source owners',
    );
    await store.acknowledgeMigrationIssues(
      <int>[issues.single.issueId],
      acknowledgedAt: DateTime.utc(2026, 7, 29),
    );
    expect(await store.listMigrationIssues(), isEmpty);
    expect(
      (await store.listMigrationIssues(includeAcknowledged: true))
          .single
          .acknowledged,
      isTrue,
    );
  });

}

ImportedChapterRecord _groupedChapter(String chapterId, int sequence) {
  return ImportedChapterRecord(
    directoryId: '/library/$chapterId',
    displayName: '第 $sequence 话',
    sourceId: 'local-folder',
    comicId: 'comic-grouped',
    comicTitle: '聚合漫画',
    chapterId: chapterId,
    sourceRevision: 'revision-$chapterId',
    sequence: sequence,
    importedAt: DateTime.utc(2026, 7, 28, sequence),
    pages: <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '$chapterId.png',
        sourceId: '/library/$chapterId.png',
        contentKindHint: ContentKindHint.png,
      ),
    ],
  );
}


ImportedChapterRecord _sourceChapter(String sourceId) => ImportedChapterRecord(
      directoryId: '$sourceId:shared-comic',
      displayName: '第 1 话',
      sourceId: sourceId,
      comicId: 'shared-comic',
      comicTitle: '跨源漫画',
      chapterId: 'shared-chapter',
      sourceRevision: '$sourceId-r1',
      sequence: 1,
      importedAt: DateTime.utc(2026, 7, 28, 13),
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.png',
          sourceId: 'https://example.invalid/$sourceId/1.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '2.png',
          sourceId: 'https://example.invalid/$sourceId/2.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );

ReadingProgress _progressFor(
  ImportedChapterRecord chapter, {
  required int pageIndex,
  required int minute,
}) =>
    ReadingProgress(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: pageIndex,
      subPageOffset: 0,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 7, 28, 13, minute),
    );

SavedComicRecord _savedComicFor({
  required String sourceId,
  required DateTime updatedAt,
}) =>
    SavedComicRecord(
      sourceId: sourceId,
      comicId: 'shared-comic',
      title: '跨源漫画',
      chapters: const <SavedChapterRecord>[
        SavedChapterRecord(
          chapterId: 'shared-chapter',
          title: '第 1 话',
          sequence: 1,
          pageCount: 2,
          sourceRevision: 'r1',
        ),
      ],
      savedAt: DateTime.utc(2026, 7, 28, 14),
      updatedAt: updatedAt,
    );


SavedComicRecord _savedComic() => SavedComicRecord(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      title: '整部漫画',
      authors: const <String>['作者'],
      description: '简介',
      coverSourceId: 'https://example.invalid/cover.png',
      readingDirection: ReadingDirection.ltr,
      chapters: const <SavedChapterRecord>[
        SavedChapterRecord(
          chapterId: 'fixture-chapter-1',
          title: '第 1 话',
          sequence: 1,
          pageCount: 1,
          sourceRevision: 'r1',
        ),
        SavedChapterRecord(
          chapterId: 'fixture-chapter-2',
          title: '第 2 话',
          sequence: 2,
          pageCount: 1,
          sourceRevision: 'r2',
        ),
      ],
      savedAt: DateTime.utc(2026, 7, 28),
      updatedAt: DateTime.utc(2026, 7, 28, 1),
    );
