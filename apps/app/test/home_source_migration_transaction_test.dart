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
