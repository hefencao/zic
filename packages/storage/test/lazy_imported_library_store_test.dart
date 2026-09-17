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
