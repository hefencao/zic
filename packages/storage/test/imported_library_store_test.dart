import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

void main() {
  test('sqlite batch lookup returns exact requested chapters with progress', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    ImportedChapterRecord chapter(String id) => ImportedChapterRecord.folder(
          directoryId: '/batch/$id',
          displayName: id,
          pages: <ImportedPageRecord>[
            ImportedPageRecord(
              displayName: '001.png',
              sourceId: '/batch/$id/001.png',
              contentKindHint: ContentKindHint.png,
            ),
          ],
        );
    final first = chapter('first');
    final second = chapter('second');
    final unrequested = chapter('unrequested');
    await store.upsertChapter(first);
    await store.upsertChapter(second);
    await store.upsertChapter(unrequested);
    final progress = ReadingProgress(
      sourceId: second.sourceId,
      comicId: second.comicId,
      chapterId: second.chapterId,
      pageIndex: 0,
      subPageOffset: 0.25,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 9, 9),
    );
    await store.saveProgress(progress);

    final entries = await store.getMany(<ImportedLibraryChapterKey>[
      ImportedLibraryChapterKey(
        sourceId: first.sourceId,
        chapterId: first.chapterId,
      ),
      ImportedLibraryChapterKey(
        sourceId: second.sourceId,
        chapterId: second.chapterId,
      ),
      ImportedLibraryChapterKey(
        sourceId: first.sourceId,
        chapterId: first.chapterId,
      ),
      const ImportedLibraryChapterKey(
        sourceId: 'local-folder',
        chapterId: '/batch/missing',
      ),
    ]);

    expect(entries, hasLength(2));
    final byIdentity = <String, ImportedLibraryEntry>{
      for (final entry in entries) entry.identity: entry,
    };
    final firstIdentity = chapterLibraryIdentity(first.sourceId, first.chapterId);
    final secondIdentity =
        chapterLibraryIdentity(second.sourceId, second.chapterId);
    expect(byIdentity, contains(firstIdentity));
    expect(byIdentity, contains(secondIdentity));
    expect(
      byIdentity,
      isNot(contains(chapterLibraryIdentity(
        unrequested.sourceId,
        unrequested.chapterId,
      ))),
    );
    final restoredProgress = byIdentity[secondIdentity]!.progress;
    expect(restoredProgress, isNotNull);
    expect(restoredProgress!.pageIndex, progress.pageIndex);
    expect(restoredProgress.subPageOffset, progress.subPageOffset);
    expect(restoredProgress.readerMode, progress.readerMode);
    expect(restoredProgress.updatedAt, progress.updatedAt);
  });

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
      pageMappings: <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'old-chapter',
          successorChapterId: 'new-chapter',
          predecessorPageCount: 370,
          successorPageCount: 371,
          successorOffset: 1,
          predecessorSourceRevision: 'old-r1',
          successorSourceRevision: 'new-r1',
          verifiedPredecessorPageIndexes: const <int>[0, 369],
          verifiedIntervals: const <VerifiedComicVersionPageInterval>[
            VerifiedComicVersionPageInterval(
              predecessorStart: 0,
              predecessorEndExclusive: 370,
              successorOffset: 1,
            ),
          ],
          verifiedAt: DateTime.utc(2026, 8, 11, 1, 1),
        ),
      ],
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
    expect(predecessors.single.pageMappings, hasLength(1));
    expect(predecessors.single.pageMappings.single.successorOffset, 1);
    expect(
      predecessors.single.pageMappings.single.predecessorSourceRevision,
      'old-r1',
    );
    expect(
      predecessors.single.pageMappings.single.successorSourceRevision,
      'new-r1',
    );
    expect(
      predecessors.single.pageMappings.single.verifiedPredecessorPageIndexes,
      <int>[0, 369],
    );
    expect(
      predecessors.single.pageMappings.single.effectiveVerifiedIntervals
          .map((interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ))
          .toList(),
      <(int, int, int)>[(0, 370, 1)],
    );
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
    expect(db.select('PRAGMA user_version').single.values.single, 11);
  });

  test('sqlite persists a Home projection revision across writes and reopen',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-library-projection-revision-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/library.sqlite3';
    final store = SqliteImportedLibraryStore(path);
    await store.open();
    final initial = await store.libraryProjectionRevision;
    expect(initial, 0);
    final initialRevision = initial!;

    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Revision chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'file:///revision/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final afterWrite = await store.libraryProjectionRevision;
    expect(afterWrite, greaterThan(initialRevision));
    final afterWriteRevision = afterWrite!;
    await store.close();

    final reopened = SqliteImportedLibraryStore(path);
    await reopened.open();
    expect(await reopened.libraryProjectionRevision, afterWriteRevision);
    await reopened.removeChapter(chapter.sourceId, chapter.chapterId);
    expect(
      await reopened.libraryProjectionRevision,
      greaterThan(afterWriteRevision),
    );
    await reopened.close();
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


  test('reader progress flush persists the latest queued checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-progress-flush-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/library.sqlite3';
    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Progress flush',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///progress/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///progress/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);

    store.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 7, 1),
      ),
    );
    expect(
      (await store.get(chapter.sourceId, chapter.chapterId))?.progress,
      isNull,
      reason: 'Reader enqueue must not synchronously write SQLite on page turn',
    );
    await store.flushProgressCheckpoints();

    store.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 7, 1, 1),
      ),
    );
    await store.flushProgressCheckpoints();

    final observer = sql.sqlite3.open(path);
    addTearDown(observer.dispose);
    final rows = observer.select(
      'SELECT progress_json FROM reading_progress '
      'WHERE source_id = ? AND chapter_id = ?',
      <Object?>[chapter.sourceId, chapter.chapterId],
    );
    expect(rows, hasLength(1));
    final persisted = jsonDecode(rows.single['progress_json']! as String)
        as Map<String, Object?>;
    expect(persisted['pageIndex'], 1);
  });

  test('targeted progress lookup flushes the latest Reader checkpoint',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-progress-lookup-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final store =
        SqliteImportedLibraryStore('${directory.path}/library.sqlite3');
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Progress lookup',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///progress-lookup/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///progress-lookup/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    store.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 19, 8),
      ),
    );

    final lookup = store as ImportedLibraryProgressLookup;
    final progress = await lookup.getProgress(
      chapter.sourceId,
      chapter.chapterId,
    );
    expect(progress?.pageIndex, 1);
    expect(
      (await store.get(chapter.sourceId, chapter.chapterId))?.progress?.pageIndex,
      1,
      reason: 'the targeted lookup is itself a Reader re-entry durability barrier',
    );
  });

  test('backup snapshot flushes the latest queued Reader checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-library-backup-progress-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/library.sqlite3';
    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Backup progress',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///backup-progress/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///backup-progress/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    final progress = ReadingProgress(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      pageIndex: 1,
      subPageOffset: 0.5,
      readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 9, 17, 22),
    );
    store.enqueueProgress(progress);

    final snapshot = await store.readLibraryBackupSnapshot();

    expect(snapshot.entries, hasLength(1));
    expect(snapshot.entries.single.progress?.toJson(), progress.toJson());
    final observer = sql.sqlite3.open(path);
    addTearDown(observer.dispose);
    final persisted = observer.select(
      'SELECT progress_json FROM reading_progress '
      'WHERE source_id = ? AND chapter_id = ?',
      <Object?>[chapter.sourceId, chapter.chapterId],
    );
    expect(persisted, hasLength(1));
    expect(
      jsonDecode(persisted.single['progress_json']! as String),
      progress.toJson(),
    );
  });

  test('reader progress failed flush preserves the latest checkpoint for retry', () async {
    final directory = await Directory.systemTemp.createTemp('zic-progress-retry-');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/library.sqlite3';
    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'Progress retry',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///progress-retry/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///progress-retry/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    store.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 10, 1),
      ),
    );
    await store.flushProgressCheckpoints();

    final blocker = sql.sqlite3.open(path);
    addTearDown(blocker.dispose);
    blocker.execute('PRAGMA busy_timeout = 100');
    blocker.execute('BEGIN IMMEDIATE');
    store.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 10, 1, 1),
      ),
    );
    await expectLater(
      store.flushProgressCheckpoints(),
      throwsA(isA<StateError>()),
    );
    blocker.execute('ROLLBACK');

    await store.flushProgressCheckpoints();
    final persisted = await store.get(chapter.sourceId, chapter.chapterId);
    expect(persisted?.progress?.pageIndex, 1);
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

  test('sqlite accepts read state before chapter hydration', () async {
    final store = SqliteImportedLibraryStore.memory();
    await store.open();
    addTearDown(store.close);
    final state = ChapterReadState(
      sourceId: 'remote-source',
      comicId: 'remote-comic',
      chapterId: 'remote-chapter',
      isRead: true,
      updatedAt: DateTime.utc(2026, 8, 25, 1),
    );

    await store.saveChapterReadState(state);
    expect(
      (await store.listChapterReadStates(state.sourceId, state.comicId))
          .single
          .toJson(),
      state.toJson(),
    );

    await store.removeChapter(state.sourceId, state.chapterId);
    expect(
      await store.listChapterReadStates(state.sourceId, state.comicId),
      isEmpty,
    );
  });

  test('sqlite schema 9 migrates read state to an unowned table', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-read-state-ownership-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final chapter = _sourceChapter('source-v9');
    final oldState = ChapterReadState(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
      isRead: true,
      updatedAt: DateTime.utc(2026, 8, 25, 2),
    );
    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA foreign_keys = ON');
    legacy.execute('''
      CREATE TABLE imported_chapter (
        source_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        imported_us INTEGER NOT NULL,
        chapter_json TEXT NOT NULL,
        PRIMARY KEY(source_id, chapter_id)
      )
    ''');
    legacy.execute('''
      CREATE TABLE chapter_read_state (
        source_id TEXT NOT NULL,
        chapter_id TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        updated_us INTEGER NOT NULL,
        read_json TEXT NOT NULL,
        PRIMARY KEY(source_id, chapter_id),
        FOREIGN KEY(source_id, chapter_id)
          REFERENCES imported_chapter(source_id, chapter_id)
          ON DELETE CASCADE
      )
    ''');
    legacy.execute('''
      CREATE INDEX chapter_read_state_comic
      ON chapter_read_state(source_id, comic_id, chapter_id)
    ''');
    legacy.execute(
      'INSERT INTO imported_chapter VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        chapter.sourceId,
        chapter.chapterId,
        chapter.comicId,
        chapter.importedAt.microsecondsSinceEpoch,
        jsonEncode(chapter.toJson()),
      ],
    );
    legacy.execute(
      'INSERT INTO chapter_read_state VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        oldState.sourceId,
        oldState.chapterId,
        oldState.comicId,
        oldState.updatedAt.microsecondsSinceEpoch,
        jsonEncode(oldState.toJson()),
      ],
    );
    legacy.execute('PRAGMA user_version = 9');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    expect(
      (await store.listChapterReadStates(oldState.sourceId, oldState.comicId))
          .single
          .toJson(),
      oldState.toJson(),
    );
    final newState = ChapterReadState(
      sourceId: oldState.sourceId,
      comicId: oldState.comicId,
      chapterId: 'chapter-without-entry',
      isRead: false,
      updatedAt: DateTime.utc(2026, 8, 25, 3),
    );
    await store.saveChapterReadState(newState);
    expect(
      (await store.listChapterReadStates(newState.sourceId, newState.comicId))
          .map((state) => state.chapterId),
      contains(newState.chapterId),
    );
    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 11);
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

  test('sqlite migrates schema 3 through composite schema 11', () async {
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
    expect(db.select('PRAGMA user_version').single.values.single, 11);
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
    expect(db.select('PRAGMA user_version').single.values.single, 11);
    expect(
      db.select('PRAGMA table_info(library_migration_issue)')
          .map((row) => row['name'])
          .toSet(),
      contains('acknowledged_us'),
    );
  });

  test('sqlite schema 7 adds durable version page mappings', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-version-page-mapping-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final legacy = sql.sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE comic_version_relation (
        source_id TEXT NOT NULL,
        predecessor_comic_id TEXT NOT NULL,
        successor_comic_id TEXT NOT NULL,
        predecessor_title TEXT NOT NULL,
        discovered_us INTEGER NOT NULL,
        PRIMARY KEY(source_id, predecessor_comic_id, successor_comic_id)
      )
    ''');
    legacy.execute(
      'INSERT INTO comic_version_relation VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        'venera:ehentai',
        'old-gallery',
        'new-gallery',
        '旧版',
        DateTime.utc(2026, 8, 11).microsecondsSinceEpoch,
      ],
    );
    legacy.execute('PRAGMA user_version = 7');
    legacy.dispose();

    final store = SqliteImportedLibraryStore(path);
    await store.open();
    addTearDown(store.close);
    final relations = await store.listAllComicVersionRelations();
    expect(relations, hasLength(1));
    expect(relations.single.pageMappings, isEmpty);

    final db = sql.sqlite3.open(path);
    addTearDown(db.dispose);
    expect(db.select('PRAGMA user_version').single.values.single, 11);
    expect(
      db.select('PRAGMA table_info(comic_version_relation)')
          .map((row) => row['name'])
          .toSet(),
      contains('page_mappings_json'),
    );
  });

  test(
    'sqlite source migration journal survives reopen and advances monotonically',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-source-migration-journal-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/library.sqlite3';
      final createdAt = DateTime.utc(2026, 9, 9, 1);
      final record = SourceMigrationJournalRecord(
        migrationId: sourceMigrationJournalId(
          sourceSourceId: 'source-a',
          sourceComicId: 'comic-old',
          targetSourceId: 'source-b',
          targetComicId: 'comic-new',
        ),
        sourceSourceId: 'source-a',
        sourceComicId: 'comic-old',
        targetSourceId: 'source-b',
        targetComicId: 'comic-new',
        replacingSource: true,
        preparedFingerprint: 'fingerprint-v1',
        phase: SourceMigrationPhase.prepared,
        createdAt: createdAt,
        updatedAt: createdAt,
      );

      final first = SqliteImportedLibraryStore(path);
      await first.open();
      final projectionRevision = await first.libraryProjectionRevision;
      final begun = await first.beginSourceMigrationJournal(record);
      expect(begun.migrationId, record.migrationId);
      expect(begun.phase, SourceMigrationPhase.prepared);
      final repeated = await first.beginSourceMigrationJournal(record);
      expect(repeated.migrationId, record.migrationId);
      expect(repeated.phase, SourceMigrationPhase.prepared);
      final artifactsReady = await first.advanceSourceMigrationJournal(
        record.migrationId,
        phase: SourceMigrationPhase.artifactsReady,
        updatedAt: createdAt.add(const Duration(seconds: 1)),
      );
      expect(artifactsReady.phase, SourceMigrationPhase.artifactsReady);
      expect(
        await first.libraryProjectionRevision,
        projectionRevision,
        reason: 'journal control phases must not dirty the Home projection',
      );
      await expectLater(
        first.advanceSourceMigrationJournal(
          record.migrationId,
          phase: SourceMigrationPhase.cleanupPending,
          updatedAt: createdAt.add(const Duration(seconds: 2)),
        ),
        throwsStateError,
      );
      await first.close();

      final reopened = SqliteImportedLibraryStore(path);
      await reopened.open();
      addTearDown(reopened.close);
      expect(
        (await reopened.getSourceMigrationJournal(record.migrationId))?.phase,
        SourceMigrationPhase.artifactsReady,
      );
      expect(await reopened.listPendingSourceMigrations(), hasLength(1));
      await reopened.advanceSourceMigrationJournal(
        record.migrationId,
        phase: SourceMigrationPhase.metadataCommitted,
        updatedAt: createdAt.add(const Duration(seconds: 3)),
      );
      await reopened.advanceSourceMigrationJournal(
        record.migrationId,
        phase: SourceMigrationPhase.cleanupPending,
        updatedAt: createdAt.add(const Duration(seconds: 4)),
      );
      await reopened.advanceSourceMigrationJournal(
        record.migrationId,
        phase: SourceMigrationPhase.done,
        updatedAt: createdAt.add(const Duration(seconds: 5)),
      );
      expect(await reopened.listPendingSourceMigrations(), isEmpty);
    },
  );


  test(
    'library schema 10 upgrades to source migration journal schema 11',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-source-migration-schema11-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/library.sqlite3';
      final current = SqliteImportedLibraryStore(path);
      await current.open();
      final saved = _savedComic();
      await current.upsertSavedComic(saved);
      await current.close();

      final legacy = sql.sqlite3.open(path);
      legacy.execute('DROP TABLE source_migration_journal');
      legacy.execute('PRAGMA user_version = 10');
      legacy.dispose();

      final migrated = SqliteImportedLibraryStore(path);
      await migrated.open();
      addTearDown(migrated.close);
      expect(
        (await migrated.getSavedComic(saved.sourceId, saved.comicId))?.toJson(),
        saved.toJson(),
      );
      expect(await migrated.listPendingSourceMigrations(), isEmpty);
      final db = sql.sqlite3.open(path);
      addTearDown(db.dispose);
      expect(db.select('PRAGMA user_version').single.values.single, 11);
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='source_migration_journal'",
        ),
        hasLength(1),
      );
    },
  );


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
