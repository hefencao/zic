import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('snapshot decode leaves the caller event loop free and joins reads',
      () async {
    final directory = await Directory.systemTemp.createTemp('snapshot-decode-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/home_projection_snapshot.json');
    final controlled = _ControlledSnapshotFile();
    final ownerPort = ReceivePort();
    addTearDown(ownerPort.close);
    final store = HomeProjectionSnapshotStore(rootProvider: () async {
      ownerPort.sendPort;
      return directory.path;
    });
    final snapshot = _emptySnapshot(7);
    final bytes = Uint8List.fromList(gzip.encode(utf8.encode(
      jsonEncode(snapshot.toJson()),
    )));
    var eventTurns = 0;

    await IOOverrides.runZoned(() async {
      final first = store.read();
      expect(identical(store.read(), first), isTrue);
      await controlled.readStarted.future;
      controlled.bytes.complete(bytes);
      Timer.run(() => eventTurns++);
      final restored = await first;

      expect(eventTurns, greaterThan(0));
      expect(restored?.toJson(), snapshot.toJson());
      expect(identical(await store.read(), restored), isTrue);
      expect(controlled.reads, 1);
    }, createFile: (path) => path == file.path ? controlled : file);
  });

  test('a pre-write read cannot populate or join the post-write read cache',
      () async {
    final directory = await Directory.systemTemp.createTemp('snapshot-race-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(storePath(directory));
    final temporary = File('${file.path}.tmp');
    final controlled = _ControlledSnapshotFile();
    final store = HomeProjectionSnapshotStore.atPath(file.path);
    var intercepted = false;

    await IOOverrides.runZoned(() async {
      final oldRead = store.read();
      await controlled.readStarted.future;
      await store.write(_emptySnapshot(8));
      final current = await store.read();
      expect(current?.libraryRevision, 8);

      controlled.bytes.complete(Uint8List.fromList(
        utf8.encode(jsonEncode(_emptySnapshot(7).toJson())),
      ));
      expect((await oldRead)?.libraryRevision, 7);
      expect(identical(await store.read(), current), isTrue);
    }, createFile: (path) {
      if (path == file.path && !intercepted) {
        intercepted = true;
        return controlled;
      }
      return path == file.path ? file : temporary;
    });
  });

  test('snapshot worker excludes nonpersistent projection owner state',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-worker-input-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/comic',
      displayName: 'Prepared chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'https://example.invalid/001.jpg?token=signed',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final manifest = chapter.toManifest();
    final entry = ImportedLibraryEntry(chapter: chapter);
    final entries = _OwnerBoundEntries(<ImportedLibraryEntry>[entry]);
    addTearDown(entries.ownerPort.close);
    final snapshot = HomeProjectionSnapshot(
      entries: entries,
      savedComics: const <SavedComicRecord>[],
      categories: const <LibraryCategory>[],
      preferences: const <ComicPreference>[],
      readStates: const <ChapterReadState>[],
      sourcePreferences: const <ComicSourcePreference>[],
      versionRelations: const <ComicVersionRelation>[],
      orphanedDownloadEntries: <ImportedLibraryEntry>[entry],
      libraryRevision: 7,
      chapterRevision: 'chapter-proof',
    );
    final store = HomeProjectionSnapshotStore.atPath(storePath(directory));

    await store.write(snapshot);
    final restored = (await store.read())!;

    expect(restored.libraryRevision, 7);
    expect(restored.chapterRevision, 'chapter-proof');
    expect(restored.entries.single.chapter.chapterId, chapter.chapterId);
    expect(restored.entries.single.chapter.pages, hasLength(1));
    expect(
      chapterHasHomeProjectionSnapshotPagePlaceholders(
        restored.entries.single.chapter,
      ),
      isTrue,
    );
    expect(
      restored.orphanedDownloadEntries.single.chapter.pages.single.sourceId,
      chapter.pages.single.sourceId,
    );
    expect(identical(chapter.toManifest(), manifest), isTrue);
  });

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
    ).copyWith(sourceUpdatedAt: DateTime.utc(2026, 8, 23, 18));
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
          unseenChapterIds: const <String>['fixture-new-chapter'],
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
        ).copyWith(liked: true, acknowledgedVersionComicId: 'known-successor'),
      ],
      readStates: <ChapterReadState>[
        ChapterReadState(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          chapterId: chapter.chapterId,
          isRead: true,
          updatedAt: DateTime.utc(2026, 8, 24, 4),
          manualOverride: true,
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
          exactCompletedPages: 1,
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
    expect(
      restored.entries.single.chapter.sourceUpdatedAt,
      chapter.sourceUpdatedAt,
    );
    expect(restored.entries.single.chapter.pages, hasLength(chapter.pages.length));
    expect(restored.entries.single.chapter.pages.first.sourceId,
        isNot(chapter.pages.first.sourceId));
    expect(restored.entries.single.progress?.toJson(), progress.toJson());
    expect(restored.savedComics.single.toJson(), snapshot.savedComics.single.toJson());
    expect(
      restored.savedComics.single.unseenChapterIds,
      const <String>{'fixture-new-chapter'},
    );
    expect(restored.preferences.single.liked, isTrue);
    expect(restored.preferences.single.acknowledgedVersionComicId,
        'known-successor');
    expect(restored.readStates.single.isRead, isTrue);
    expect(restored.readStates.single.manualOverride, isTrue);
    expect(restored.sourcePreferences.single.enabled, isFalse);
    expect(restored.versionRelations.single.pageMappings, hasLength(1));
    expect(restored.orphanedDownloadEntries, hasLength(1));
    expect(restored.chapterDownloads, hasLength(1));
    expect(restored.chapterDownloads.single.phase, 'downloading');
    expect(restored.chapterDownloads.single.exactCompletedPages, 1);
    expect(restored.chapterDownloads.single.reusablePages, 0);
    expect(restored.chapterDownloads.single.pageProgressUnits, 1.5);
    expect(restored.chapterDownloads.single.started, isTrue);
    expect(restored.includesDownloadProjection, isTrue);
    expect(restored.libraryRevision, 42);

    final encoded = jsonDecode(await File(storePath(directory)).readAsString())
        as Map<Object?, Object?>;
    expect(encoded, snapshot.toJson());
    expect(encoded['version'], 4);
    final firstEntry = (encoded['entries']! as List<Object?>).single
        as Map<Object?, Object?>;
    expect(
      (firstEntry['chapter']! as Map<Object?, Object?>).containsKey('pages'),
      isFalse,
    );
  });

  test('v3 download projection is discarded because exact identity is unknown',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-home-snapshot-v3-download-identity-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final chapter = ImportedChapterRecord.folder(
      directoryId: '${directory.path}/comic',
      displayName: 'Legacy download chapter',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'file:///legacy/001.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    final current = HomeProjectionSnapshot(
      entries: <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
      savedComics: const <SavedComicRecord>[],
      categories: const <LibraryCategory>[],
      preferences: const <ComicPreference>[],
      readStates: const <ChapterReadState>[],
      sourcePreferences: const <ComicSourcePreference>[],
      versionRelations: const <ComicVersionRelation>[],
      chapterDownloads: <HomeChapterDownloadSummary>[
        HomeChapterDownloadSummary(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          comicTitle: chapter.comicTitle,
          chapterId: chapter.chapterId,
          sourceRevision: chapter.sourceRevision,
          title: chapter.displayName,
          completedPages: 1,
          totalPages: 1,
          receivedBytes: 4,
          pinnedPages: 1,
          exactCompletedPages: 1,
          phase: 'complete',
          started: true,
        ),
      ],
    ).toJson();
    current['version'] = 3;
    final summaries = current['chapterDownloads']! as List<Object?>;
    (summaries.single as Map<String, Object?>).remove('exactCompletedPages');
    final path = '${directory.path}/snapshot.json';
    await File(path).writeAsString(jsonEncode(current));

    final restored = await HomeProjectionSnapshotStore.atPath(path).read();

    expect(restored, isNotNull);
    expect(restored!.entriesAreCompact, isTrue);
    expect(restored.includesDownloadProjection, isFalse);
    expect(restored.chapterDownloads, isEmpty);
    expect(restored.requiresRewrite, isTrue);
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
    expect(compact['version'], 4);
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

  test('v2 compact snapshots remain readable and request a v4 rewrite',
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
    for (final bytes in <List<int>>[
      utf8.encode('{not-json'),
      utf8.encode('{"format":"zic-home-projection","version":0}'),
      utf8.encode('[]'),
      <int>[0x1f, 0x8b, 0],
    ]) {
      await File(path).writeAsBytes(bytes);
      expect(await HomeProjectionSnapshotStore.atPath(path).read(), isNull);
    }
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

HomeProjectionSnapshot _emptySnapshot(int revision) => HomeProjectionSnapshot(
      entries: const <ImportedLibraryEntry>[],
      savedComics: const <SavedComicRecord>[],
      categories: const <LibraryCategory>[],
      preferences: const <ComicPreference>[],
      readStates: const <ChapterReadState>[],
      sourcePreferences: const <ComicSourcePreference>[],
      versionRelations: const <ComicVersionRelation>[],
      libraryRevision: revision,
    );

final class _ControlledSnapshotFile implements File {
  final readStarted = Completer<void>();
  final bytes = Completer<Uint8List>();
  int reads = 0;

  @override
  Future<bool> exists() async => true;

  @override
  Future<Uint8List> readAsBytes() {
    reads++;
    readStarted.complete();
    return bytes.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _OwnerBoundEntries
    extends UnmodifiableListView<ImportedLibraryEntry> {
  _OwnerBoundEntries(super.source);

  final ReceivePort ownerPort = ReceivePort();
}
