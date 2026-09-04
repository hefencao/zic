import 'dart:convert';
import 'dart:io';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('Home projection snapshot round-trips every durable projection', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/comic',
      displayName: 'Snapshot chapter',
      importedAt: DateTime.utc(2026, 8, 24),
      pages: <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: '${directory.path}/comic/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
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
      updatedAt: DateTime.utc(2026, 8, 24, 1),
    );
    final relation = ComicVersionRelation(
      sourceId: 'fixture-source',
      predecessorComicId: 'old',
      successorComicId: 'new',
      predecessorTitle: 'Old title',
      discoveredAt: DateTime.utc(2026, 8, 24, 2),
      pageMappings: const <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'old-chapter',
          successorChapterId: 'new-chapter',
          predecessorPageCount: 10,
          successorPageCount: 11,
          successorOffset: 1,
        ),
      ],
    );
    final snapshot = HomeProjectionSnapshot(
      entries: <ImportedLibraryEntry>[
        ImportedLibraryEntry(chapter: chapter, progress: progress),
      ],
      savedComics: <SavedComicRecord>[
        SavedComicRecord(
          sourceId: 'fixture-source',
          comicId: 'fixture-comic',
          title: 'Fixture',
          sourceUpdateAt: DateTime.utc(2026, 8, 24, 3),
        ),
      ],
      categories: <LibraryCategory>[
        LibraryCategory(
          categoryId: 'category-1',
          name: 'Category',
          sortOrder: 0,
          createdAt: DateTime.utc(2026, 8, 24),
        ),
      ],
      preferences: <ComicPreference>[
        ComicPreference.defaults(
          sourceId: 'fixture-source',
          comicId: 'fixture-comic',
          sourceKind: ComicSourceKind.remote,
        ).copyWith(liked: true),
      ],
      readStates: <ChapterReadState>[
        ChapterReadState(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          chapterId: chapter.chapterId,
          isRead: true,
          updatedAt: DateTime.utc(2026, 8, 24, 4),
        ),
      ],
      sourcePreferences: <ComicSourcePreference>[
        ComicSourcePreference(
          sourceId: 'fixture-source',
          enabled: false,
          sortOrder: 2,
          updatedAt: DateTime.utc(2026, 8, 24, 5),
        ),
      ],
      versionRelations: <ComicVersionRelation>[relation],
      orphanedDownloadEntries: <ImportedLibraryEntry>[
        ImportedLibraryEntry(chapter: chapter),
      ],
      chapterDownloads: const <HomeChapterDownloadSummary>[
        HomeChapterDownloadSummary(
          sourceId: 'fixture-source',
          comicId: 'fixture-comic',
          comicTitle: 'Fixture',
          chapterId: 'fixture-chapter',
          sourceRevision: 'fixture-r1',
          title: 'Downloaded chapter',
          completedPages: 1,
          totalPages: 2,
          receivedBytes: 128,
          pinnedPages: 1,
          totalBytes: 256,
          pageProgressUnits: 1.5,
          phase: 'downloading',
          failure: 'interrupted',
          started: true,
        ),
      ],
      libraryRevision: 42,
    );
    final store = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/snapshot.json',
    );

    await store.write(snapshot);
    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.entriesAreCompact, isTrue);
    expect(restored.entries.single.chapter.directoryId, chapter.directoryId);
    expect(restored.entries.single.chapter.comicTitle, chapter.comicTitle);
    expect(restored.entries.single.chapter.pages, hasLength(chapter.pages.length));
    expect(restored.entries.single.chapter.pages.first.sourceId,
        isNot(chapter.pages.first.sourceId));
    expect(restored.entries.single.progress?.toJson(), progress.toJson());
    expect(restored.savedComics.single.toJson(), snapshot.savedComics.single.toJson());
    expect(restored.preferences.single.liked, isTrue);
    expect(restored.readStates.single.isRead, isTrue);
    expect(restored.sourcePreferences.single.enabled, isFalse);
    expect(restored.versionRelations.single.pageMappings, hasLength(1));
    expect(restored.orphanedDownloadEntries, hasLength(1));
    expect(restored.chapterDownloads, hasLength(1));
    expect(restored.chapterDownloads.single.phase, 'downloading');
    expect(restored.chapterDownloads.single.pageProgressUnits, 1.5);
    expect(restored.chapterDownloads.single.started, isTrue);
    expect(restored.includesDownloadProjection, isTrue);
    expect(restored.libraryRevision, 42);

    final encoded = jsonDecode(await File(storePath(directory)).readAsString())
        as Map<Object?, Object?>;
    expect(encoded['version'], 3);
    final firstEntry = (encoded['entries']! as List<Object?>).single
        as Map<Object?, Object?>;
    expect(
      (firstEntry['chapter']! as Map<Object?, Object?>).containsKey('pages'),
      isFalse,
    );
  });

  test('legacy v1 Home snapshots are readable and compact on rewrite', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-v1-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/comic',
      displayName: 'Legacy chapter',
      pages: <ImportedPageRecord>[
        for (var index = 0; index < 3; index++)
          ImportedPageRecord(
            displayName: '$index.jpg',
            sourceId: '${directory.path}/comic/$index.jpg',
            contentKindHint: ContentKindHint.jpeg,
          ),
      ],
    );
    final legacyJson = <String, Object?>{
      'format': 'zic-home-projection',
      'version': 1,
      'entries': <Object?>[
        <String, Object?>{'chapter': chapter.toJson()},
      ],
      'savedComics': const <Object?>[],
      'categories': const <Object?>[],
      'preferences': const <Object?>[],
      'readStates': const <Object?>[],
      'sourcePreferences': const <Object?>[],
      'versionRelations': const <Object?>[],
    };
    final path = '${directory.path}/snapshot.json';
    await File(path).writeAsString(jsonEncode(legacyJson));
    final store = HomeProjectionSnapshotStore.atPath(path);

    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.entriesAreCompact, isFalse);
    expect(restored.entries.single.chapter.toJson(), chapter.toJson());
    await store.write(restored);
    final compact = jsonDecode(await File(path).readAsString())
        as Map<Object?, Object?>;
    expect(compact['version'], 3);
    expect(
      ((compact['entries']! as List<Object?>).single
              as Map<Object?, Object?>)['chapter'],
      isA<Map<Object?, Object?>>(),
    );
    expect(
      (((compact['entries']! as List<Object?>).single
                  as Map<Object?, Object?>)['chapter']!
              as Map<Object?, Object?>)
          .containsKey('pages'),
      isFalse,
    );
  });

  test('v2 compact snapshots remain readable and request a v3 rewrite',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-v2-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/snapshot.json';
    final v2Json = <String, Object?>{
      'format': 'zic-home-projection',
      'version': 2,
      'entries': const <Object?>[],
      'savedComics': const <Object?>[],
      'categories': const <Object?>[],
      'preferences': const <Object?>[],
      'readStates': const <Object?>[],
      'sourcePreferences': const <Object?>[],
      'versionRelations': const <Object?>[],
    };
    await File(path).writeAsString(jsonEncode(v2Json));
    final store = HomeProjectionSnapshotStore.atPath(path);

    final restored = await store.read();

    expect(restored, isNotNull);
    expect(restored!.entriesAreCompact, isTrue);
    expect(restored.includesDownloadProjection, isFalse);
    expect(restored.chapterDownloads, isEmpty);
    expect(restored.requiresRewrite, isTrue);
  });

  test('large Home snapshots are gzip-compressed without changing the model',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-gzip-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/snapshot.json';
    final description = List<String>.filled(700000, 'x').join();
    final snapshot = HomeProjectionSnapshot(
      entries: const <ImportedLibraryEntry>[],
      savedComics: <SavedComicRecord>[
        SavedComicRecord(
          sourceId: 'fixture-source',
          comicId: 'fixture-comic',
          title: 'Fixture',
          description: description,
        ),
      ],
      categories: const <LibraryCategory>[],
      preferences: const <ComicPreference>[],
      readStates: const <ChapterReadState>[],
      sourcePreferences: const <ComicSourcePreference>[],
      versionRelations: const <ComicVersionRelation>[],
    );
    final store = HomeProjectionSnapshotStore.atPath(path);

    await store.write(snapshot);

    final stored = await File(path).readAsBytes();
    expect(stored.sublist(0, 2), <int>[0x1f, 0x8b]);
    final restored = await store.read();
    expect(restored?.savedComics.single.description, description);
    expect(restored?.storedCompressed, isTrue);
  });

  test('corrupt or incompatible Home snapshots are ignored', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-invalid-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final path = '${directory.path}/snapshot.json';
    final store = HomeProjectionSnapshotStore.atPath(path);

    await File(path).writeAsString('{not-json');
    expect(await store.read(), isNull);
    await File(path).writeAsString('{"format":"zic-home-projection","version":0}');
    expect(await store.read(), isNull);
  });

  test('metadata-probed missing Home snapshots remain optional', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-metadata-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final store = HomeProjectionSnapshotStore.atPath(
      '${directory.path}/missing.json',
      metadataAlreadyProbed: true,
    );
    expect(await store.read(), isNull);
  });
}

String storePath(Directory directory) => '${directory.path}/snapshot.json';
