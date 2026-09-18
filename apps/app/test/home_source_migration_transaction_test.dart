import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_source_migration_transaction.dart';

void main() {
  test('confirmed replacing-source migration owns journal metadata and cleanup',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final source = MangaDexSource();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: <BrowsableComicSource>[source],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;

    final sourceComic = _comic(source.sourceId, 'old-comic', 'Old comic');
    final targetComic = _comic(source.sourceId, 'new-comic', 'New comic');
    final sourceManifest = ComicManifest(
      comic: sourceComic,
      chapters: const <Chapter>[],
    );
    final targetManifest = ComicManifest(
      comic: targetComic,
      chapters: const <Chapter>[],
    );
    await session.upsertSavedComic(SavedComicRecord.fromManifest(sourceManifest));
    final sourcePreference = ComicPreference(
      sourceId: source.sourceId,
      comicId: sourceComic.comicId,
      sourceKind: ComicSourceKind.remote,
      inShelf: true,
      liked: true,
      collected: false,
      categoryIds: const <String>{'fixture-category'},
      customOrder: 7,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await library.saveComicPreference(sourcePreference);
    session.replacePreference(sourcePreference);
    final sourceProjection = _libraryComic(sourceComic);
    final plan = ComicSourceMigrationPlan.build(
      source: sourceProjection,
      target: targetManifest,
    );
    final transaction = HomeSourceMigrationTransaction(
      session: session,
      ensureDurableLibrary: () async {},
      artifactCache: () => null,
      verifiedPageReuseIdentity: ({required sourceId, required locator}) async =>
          null,
      savePreference: (preference) async {
        await session.library.saveComicPreference(preference);
        session.replacePreference(preference);
      },
      canonicalComicIdForPersistence: (_, _, {fallback}) => fallback,
      reportError: (_, _) {},
    );

    final result = await transaction.executeConfirmed(
      sourceComic: sourceProjection,
      targetSource: source,
      targetManifest: targetManifest,
      plan: plan,
      replacingSource: true,
      sourcePreference: sourcePreference,
      targetCustomOrder: 11,
    );

    expect(result.replacingSource, isTrue);
    expect(result.migratedChapters, 0);
    expect(
      await library.getSavedComic(source.sourceId, sourceComic.comicId),
      isNull,
    );
    expect(
      await library.getSavedComic(source.sourceId, targetComic.comicId),
      isNotNull,
    );
    expect(
      await library.getComicPreference(source.sourceId, sourceComic.comicId),
      isNull,
    );
    final targetPreference = await library.getComicPreference(
      source.sourceId,
      targetComic.comicId,
    );
    expect(targetPreference, isNotNull);
    expect(targetPreference!.inShelf, isTrue);
    expect(targetPreference.liked, isTrue);
    expect(targetPreference.categoryIds, contains('fixture-category'));
    expect(
      await (library as SourceMigrationJournalStore)
          .listPendingSourceMigrations(),
      isEmpty,
    );
  });

  test('migrated read-state publishes through HomeLibrarySession owner',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final source = _MigrationSource('fixture-source');
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: <BrowsableComicSource>[source],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;

    final sourceComic = _comic(source.sourceId, 'old-comic', 'Old comic');
    final targetComic = _comic(source.sourceId, 'new-comic', 'New comic');
    final sourceChapter = _chapterManifest(
      sourceId: source.sourceId,
      comicId: sourceComic.comicId,
      chapterId: 'old-chapter',
      title: 'Chapter 1',
      sequence: 1,
      revision: 'old-r1',
    );
    final targetChapter = _chapterManifest(
      sourceId: source.sourceId,
      comicId: targetComic.comicId,
      chapterId: 'new-chapter',
      title: 'Chapter 1',
      sequence: 1,
      revision: 'new-r1',
    );
    source.chapter = targetChapter;

    final sourceEntry = await session.upsertChapter(
      ImportedChapterRecord.remote(
        comic: sourceComic,
        manifest: sourceChapter,
      ),
    );
    final sourceRead = ChapterReadState(
      sourceId: source.sourceId,
      comicId: sourceComic.comicId,
      chapterId: sourceChapter.chapter.chapterId,
      isRead: true,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await session.persistReadState(sourceRead);

    final sourceProjection = LibraryComic(
      sourceId: sourceComic.sourceId,
      comicId: sourceComic.comicId,
      title: sourceComic.title,
      authors: sourceComic.authors,
      tags: sourceComic.tags,
      description: sourceComic.description,
      coverSourceId: sourceComic.coverUri?.toString(),
      readingDirection: sourceComic.readingDirection,
      chapters: <ImportedLibraryEntry>[sourceEntry],
      sourceChapters: <Chapter>[sourceChapter.chapter],
      savedAt: DateTime.utc(2026, 1, 1),
      metadataUpdatedAt: DateTime.utc(2026, 1, 1),
    );
    final targetManifest = ComicManifest(
      comic: targetComic,
      chapters: <Chapter>[targetChapter.chapter],
    );
    final sourcePreference = ComicPreference(
      sourceId: source.sourceId,
      comicId: sourceComic.comicId,
      sourceKind: ComicSourceKind.remote,
      inShelf: true,
      liked: false,
      collected: false,
      categoryIds: const <String>{},
      customOrder: 1,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await session.persistPreference(sourcePreference);

    final transaction = HomeSourceMigrationTransaction(
      session: session,
      ensureDurableLibrary: () async {},
      artifactCache: () => null,
      verifiedPageReuseIdentity: ({required sourceId, required locator}) async =>
          null,
      savePreference: session.persistPreference,
      canonicalComicIdForPersistence: (_, _, {fallback}) => fallback,
      reportError: (_, _) {},
    );

    final result = await transaction.executeConfirmed(
      sourceComic: sourceProjection,
      targetSource: source,
      targetManifest: targetManifest,
      plan: ComicSourceMigrationPlan.build(
        source: sourceProjection,
        target: targetManifest,
      ),
      replacingSource: false,
      sourcePreference: sourcePreference,
      targetCustomOrder: 2,
    );

    expect(result.migratedChapters, 1);
    expect(result.migratedReadStates, 1);
    final targetIdentity = chapterLibraryIdentity(
      source.sourceId,
      targetChapter.chapter.chapterId,
    );
    expect(session.readStates[targetIdentity]?.isRead, isTrue);
    expect(
      (await library.listChapterReadStates(
        source.sourceId,
        targetComic.comicId,
      ))
          .single
          .isRead,
      isTrue,
    );
  });

  test('confirmed migration crosses durable boundary before journal lookup',
      () async {
    final bootstrapLibrary = MemoryImportedLibraryStore();
    final bootstrapDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final bootstrapQueue =
        WholeComicDownloadQueue(downloads: bootstrapDownloads);
    final source = MangaDexSource();
    final session = HomeLibrarySession(
      library: bootstrapLibrary,
      chapterDownloads: bootstrapDownloads,
      wholeComicDownloads: bootstrapQueue,
      sources: <BrowsableComicSource>[source],
      ownsLibrary: false,
      ownsChapterDownloads: false,
      ownsWholeComicDownloads: false,
    );
    await session.ready;

    final durableLibrary = MemoryImportedLibraryStore();
    final durableDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final durableQueue = WholeComicDownloadQueue(downloads: durableDownloads);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await bootstrapQueue.close();
      await bootstrapDownloads.close();
      await bootstrapLibrary.close();
      await durableQueue.close();
      await durableDownloads.close();
      await durableLibrary.close();
    });

    var durableBoundaryCalls = 0;
    var adopted = false;
    Future<void> ensureDurableLibrary() async {
      durableBoundaryCalls++;
      if (adopted) return;
      adopted = true;
      await session.adoptServices(
        library: durableLibrary,
        chapterDownloads: durableDownloads,
        wholeComicDownloads: durableQueue,
        sources: <BrowsableComicSource>[source],
        persistSnapshot: false,
      );
    }

    final sourceComic = _comic(source.sourceId, 'old-comic', 'Old comic');
    final targetComic = _comic(source.sourceId, 'new-comic', 'New comic');
    final targetManifest = ComicManifest(
      comic: targetComic,
      chapters: const <Chapter>[],
    );
    final sourceProjection = _libraryComic(sourceComic);
    final sourcePreference = ComicPreference(
      sourceId: source.sourceId,
      comicId: sourceComic.comicId,
      sourceKind: ComicSourceKind.remote,
      inShelf: true,
      liked: false,
      collected: false,
      categoryIds: const <String>{},
      customOrder: 1,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    final transaction = HomeSourceMigrationTransaction(
      session: session,
      ensureDurableLibrary: ensureDurableLibrary,
      artifactCache: () => null,
      verifiedPageReuseIdentity: ({required sourceId, required locator}) async =>
          null,
      savePreference: (_) async {
        throw StateError('stop after target metadata write');
      },
      canonicalComicIdForPersistence: (_, _, {fallback}) => fallback,
      reportError: (_, _) {},
    );

    await expectLater(
      transaction.executeConfirmed(
        sourceComic: sourceProjection,
        targetSource: source,
        targetManifest: targetManifest,
        plan: ComicSourceMigrationPlan.build(
          source: sourceProjection,
          target: targetManifest,
        ),
        replacingSource: false,
        sourcePreference: sourcePreference,
        targetCustomOrder: 1,
      ),
      throwsA(isA<StateError>()),
    );

    expect(durableBoundaryCalls, 1);
    expect(session.library, same(durableLibrary));
    expect(
      await bootstrapLibrary.getSavedComic(source.sourceId, targetComic.comicId),
      isNull,
    );
    expect(
      await (bootstrapLibrary as SourceMigrationJournalStore)
          .listPendingSourceMigrations(),
      isEmpty,
    );
    expect(
      await durableLibrary.getSavedComic(source.sourceId, targetComic.comicId),
      isNotNull,
    );
    expect(
      await (durableLibrary as SourceMigrationJournalStore)
          .listPendingSourceMigrations(),
      hasLength(1),
    );
  });

  test('recovery follows the current HomeLibrarySession service generation',
      () async {
    final firstLibrary = MemoryImportedLibraryStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });
    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );

    final sourceComic = _comic('fixture-source', 'old-comic', 'Old comic');
    final sourceManifest = ComicManifest(
      comic: sourceComic,
      chapters: const <Chapter>[],
    );
    await session.upsertSavedComic(SavedComicRecord.fromManifest(sourceManifest));
    final sourcePreference = ComicPreference(
      sourceId: sourceComic.sourceId,
      comicId: sourceComic.comicId,
      sourceKind: ComicSourceKind.remote,
      inShelf: true,
      liked: true,
      collected: true,
      categoryIds: const <String>{'old'},
      customOrder: 1,
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await secondLibrary.saveComicPreference(sourcePreference);
    session.replacePreference(sourcePreference);

    final store = secondLibrary as SourceMigrationJournalStore;
    final migrationId = sourceMigrationJournalId(
      sourceSourceId: sourceComic.sourceId,
      sourceComicId: sourceComic.comicId,
      targetSourceId: sourceComic.sourceId,
      targetComicId: 'new-comic',
    );
    final now = DateTime.utc(2026, 1, 2);
    await store.beginSourceMigrationJournal(
      SourceMigrationJournalRecord(
        migrationId: migrationId,
        sourceSourceId: sourceComic.sourceId,
        sourceComicId: sourceComic.comicId,
        targetSourceId: sourceComic.sourceId,
        targetComicId: 'new-comic',
        replacingSource: true,
        preparedFingerprint: 'fixture',
        phase: SourceMigrationPhase.prepared,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.advanceSourceMigrationJournal(
      migrationId,
      phase: SourceMigrationPhase.artifactsReady,
      updatedAt: now,
    );
    await store.advanceSourceMigrationJournal(
      migrationId,
      phase: SourceMigrationPhase.metadataCommitted,
      updatedAt: now,
    );

    final errors = <Object>[];
    final transaction = HomeSourceMigrationTransaction(
      session: session,
      ensureDurableLibrary: () async {},
      artifactCache: () => null,
      verifiedPageReuseIdentity: ({required sourceId, required locator}) async =>
          null,
      savePreference: (_) async {},
      canonicalComicIdForPersistence: (_, _, {fallback}) => fallback,
      reportError: (_, error) => errors.add(error),
    );

    expect(await transaction.recoverCommitted(), isTrue);
    expect(errors, isEmpty);
    expect(await store.listPendingSourceMigrations(), isEmpty);
    expect(
      await secondLibrary.getSavedComic(
        sourceComic.sourceId,
        sourceComic.comicId,
      ),
      isNull,
    );
    expect(
      await secondLibrary.getComicPreference(
        sourceComic.sourceId,
        sourceComic.comicId,
      ),
      isNull,
    );
  });
}

ChapterManifest _chapterManifest({
  required String sourceId,
  required String comicId,
  required String chapterId,
  required String title,
  required int sequence,
  required String revision,
}) {
  final chapter = Chapter(
    chapterId: chapterId,
    comicId: comicId,
    title: title,
    sequence: sequence,
    pageCount: 1,
    sourceRevision: revision,
  );
  return ChapterManifest(
    sourceId: sourceId,
    comicId: comicId,
    chapter: chapter,
    pages: <PageAsset>[
      PageAsset(
        pageId: '$chapterId-page-1',
        chapterId: chapterId,
        index: 0,
        uri: Uri.https('example.test', '/$chapterId/1.jpg'),
        contentKindHint: ContentKindHint.jpeg,
      ),
    ],
    readingDirection: ReadingDirection.ltr,
  );
}

final class _MigrationSource implements BrowsableComicSource {
  _MigrationSource(this.sourceId)
      : descriptor = ComicSourceDescriptor(
          sourceId: sourceId,
          name: 'Fixture migration source',
          language: 'en',
          website: Uri.https('example.test'),
        );

  @override
  final String sourceId;

  @override
  final ComicSourceDescriptor descriptor;

  ChapterManifest? chapter;

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) =>
      throw UnimplementedError();

  @override
  Future<ComicManifest> loadComic(String comicId) => throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    final value = chapter;
    if (value == null || value.chapter.chapterId != chapterId) {
      throw StateError('unexpected fixture chapter: $chapterId');
    }
    return value;
  }

  @override
  Future<Uint8List> loadResource(Uri uri) => throw UnimplementedError();
}

Comic _comic(String sourceId, String comicId, String title) => Comic(
      comicId: comicId,
      sourceId: sourceId,
      title: title,
      authors: const <String>['Fixture author'],
      tags: const <String>['fixture'],
      readingDirection: ReadingDirection.ltr,
    );

LibraryComic _libraryComic(Comic comic) => LibraryComic(
      sourceId: comic.sourceId,
      comicId: comic.comicId,
      title: comic.title,
      authors: comic.authors,
      tags: comic.tags,
      description: comic.description,
      coverSourceId: comic.coverUri?.toString(),
      readingDirection: comic.readingDirection,
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      savedAt: DateTime.utc(2026, 1, 1),
      metadataUpdatedAt: DateTime.utc(2026, 1, 1),
    );
