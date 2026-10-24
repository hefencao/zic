import 'dart:async';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('lazy store keeps a fresh install memory-only until first write', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final store = LazyImportedLibraryStore(
      rootProvider: () async => directory.path,
    );
    await store.open();
    expect(await store.libraryMetadataRevision, isNull);
    expect(await store.listReadingProgress(), isEmpty);
    expect(
      await File('${directory.path}/imported_library.sqlite3').exists(),
      isFalse,
    );

    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'chapter',
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: '${directory.path}/chapter/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    expect(await store.libraryMetadataRevision, isNotNull);
    await store.close();

    final reopened = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await reopened.open();
    addTearDown(reopened.close);
    expect(
      (await reopened.get(chapter.sourceId, chapter.chapterId))?.chapter.toJson(),
      chapter.toJson(),
    );
  });

  test('backup snapshot materializes the authoritative lazy library', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-backup-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    var rootCalls = 0;
    final durable = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await durable.open();
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/existing',
      displayName: 'Existing durable chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///existing/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await durable.upsertChapter(chapter);
    await durable.close();
    final store = LazyImportedLibraryStore(
      rootProvider: () async {
        rootCalls++;
        return directory.path;
      },
    );
    await store.open();
    addTearDown(store.close);

    final snapshot = await store.readLibraryBackupSnapshot();

    expect(snapshot.entries, hasLength(1));
    expect(snapshot.entries.single.chapter.chapterId, chapter.chapterId);
    expect(snapshot.savedComics, isEmpty);
    expect(rootCalls, 1);
    expect(store.isDurable, isTrue);
  });

  test('explicit get hydrates an existing durable chapter during bootstrap',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-hydrate-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'chapter',
      pages: <ImportedPageRecord>[
        for (var index = 0; index < 2; index++)
          ImportedPageRecord(
            displayName: '00${index + 1}.png',
            sourceId: '${directory.path}/chapter/00${index + 1}.png',
            contentKindHint: ContentKindHint.png,
          ),
      ],
    );
    final durable = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await durable.open();
    await durable.upsertChapter(chapter);
    await durable.close();

    final store = LazyImportedLibraryStore(
      rootProvider: () async => directory.path,
    );
    await store.open();
    addTearDown(store.close);

    expect(await store.list(), isEmpty);
    final hydrated = await store.get(chapter.sourceId, chapter.chapterId);

    expect(hydrated?.chapter.toJson(), chapter.toJson());
  });

  test('Reader checkpoint enqueue stays non-blocking and flush waits durable promotion',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-reader-progress-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'reader progress',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///reader-progress/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///reader-progress/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final durable = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await durable.open();
    await durable.upsertChapter(chapter);
    await durable.close();

    final rootGate = Completer<void>();
    final store = LazyImportedLibraryStore(
      rootProvider: () async {
        await rootGate.future;
        return directory.path;
      },
    );
    await store.open();
    addTearDown(store.close);

    final checkpoints = store as ReaderProgressCheckpointStore;
    checkpoints.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 18, 1),
      ),
    );
    checkpoints.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0.25,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 18, 1, 1),
      ),
    );

    expect(store.isDurable, isFalse);
    var flushed = false;
    final flush = checkpoints.flushProgressCheckpoints().then((_) {
      flushed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);

    rootGate.complete();
    await flush;

    expect(store.isDurable, isTrue);
    final persisted = await store.get(chapter.sourceId, chapter.chapterId);
    expect(persisted?.progress?.pageIndex, 1);
    expect(persisted?.progress?.subPageOffset, 0.25);
  });

  test('Lazy close flushes a pending Reader checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-reader-close-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/chapter',
      displayName: 'reader close progress',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///reader-close/001.png',
          contentKindHint: ContentKindHint.png,
        ),
        ImportedPageRecord(
          displayName: '002.png',
          sourceId: 'file:///reader-close/002.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final durable = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await durable.open();
    await durable.upsertChapter(chapter);
    await durable.close();

    final store = LazyImportedLibraryStore(
      rootProvider: () async => directory.path,
    );
    await store.open();
    final checkpoints = store as ReaderProgressCheckpointStore;
    checkpoints.enqueueProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 1,
        subPageOffset: 0.5,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 18, 1, 2),
      ),
    );

    await store.close();

    final reopened = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await reopened.open();
    addTearDown(reopened.close);
    final persisted = await reopened.get(chapter.sourceId, chapter.chapterId);
    expect(persisted?.progress?.pageIndex, 1);
    expect(persisted?.progress?.subPageOffset, 0.5);
  });

  test('Lazy close is joinable and fences new work during pending promotion',
      () async {
    final rootStarted = Completer<void>();
    final releaseRoot = Completer<void>();
    var rootCalls = 0;
    final store = LazyImportedLibraryStore(
      rootProvider: () async {
        rootCalls++;
        if (!rootStarted.isCompleted) rootStarted.complete();
        await releaseRoot.future;
        throw StateError('fixture close promotion failure');
      },
    );
    await store.open();

    final checkpoints = store as ReaderProgressCheckpointStore;
    checkpoints.enqueueProgress(
      ReadingProgress(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        chapterId: 'fixture-chapter',
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 18, 1),
      ),
    );
    await rootStarted.future;

    final firstClose = store.close();
    final secondClose = store.close();
    expect(identical(firstClose, secondClose), isTrue);
    expect(
      () => checkpoints.enqueueProgress(
        ReadingProgress(
          sourceId: 'fixture-source',
          comicId: 'fixture-comic',
          chapterId: 'fixture-chapter',
          pageIndex: 2,
          subPageOffset: 0,
          readerMode: ReaderMode.paged,
          updatedAt: DateTime.utc(2026, 9, 18, 1, 1),
        ),
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(store.ensureDurable(), throwsA(isA<StateError>()));
    expect(rootCalls, 1);

    releaseRoot.complete();
    await expectLater(firstClose, throwsA(isA<StateError>()));
    await expectLater(secondClose, throwsA(isA<StateError>()));
    expect(rootCalls, 1);
  });

  test('Reader checkpoint flush retries failed durable promotion', () async {
    var rootCalls = 0;
    final store = LazyImportedLibraryStore(
      rootProvider: () async {
        rootCalls++;
        throw StateError('fixture root failure $rootCalls');
      },
    );
    await store.open();
    addTearDown(() async {
      try {
        await store.close();
      } on Object {
        // The fixture intentionally keeps durable promotion unavailable.
      }
    });

    final checkpoints = store as ReaderProgressCheckpointStore;
    checkpoints.enqueueProgress(
      ReadingProgress(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        chapterId: 'fixture-chapter',
        pageIndex: 1,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 9, 18, 1),
      ),
    );

    await expectLater(
      checkpoints.flushProgressCheckpoints(),
      throwsA(isA<StateError>()),
    );
    expect(rootCalls, 1);
    await expectLater(
      checkpoints.flushProgressCheckpoints(),
      throwsA(isA<StateError>()),
    );
    expect(rootCalls, 2);
  });

  test('batch get opens durable store once when bootstrap memory is incomplete',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-lazy-library-batch-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final first = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/first',
      displayName: 'first',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///batch/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final second = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/second',
      displayName: 'second',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.png',
          sourceId: 'file:///batch/001.png',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    final durable = SqliteImportedLibraryStore(
      '${directory.path}/imported_library.sqlite3',
    );
    await durable.open();
    await durable.upsertChapter(first);
    await durable.upsertChapter(second);
    await durable.close();

    var rootCalls = 0;
    final store = LazyImportedLibraryStore(
      rootProvider: () async {
        rootCalls++;
        return directory.path;
      },
    );
    await store.open();
    addTearDown(store.close);

    final result = await store.getMany(<ImportedLibraryChapterKey>[
      ImportedLibraryChapterKey(
        sourceId: first.sourceId,
        chapterId: first.chapterId,
      ),
      ImportedLibraryChapterKey(
        sourceId: second.sourceId,
        chapterId: second.chapterId,
      ),
    ]);

    expect(result, hasLength(2));
    expect(rootCalls, 1);
    expect(store.isDurable, isTrue);
  });

}
