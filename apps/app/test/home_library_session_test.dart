import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:zic/home_library_session.dart';

void main() {
  test('home session owns durable projection outside DemoHome state', () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;

    expect(session.loading, isFalse);
    expect(session.error, isNull);
    expect(session.entries, isEmpty);
    expect(session.savedComics, isEmpty);
    expect(session.activeSourceId, isNull);

    var notifications = 0;
    session.addListener(() => notifications++);
    final preference = ComicPreference.defaults(
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(liked: true);

    session.replacePreference(preference);

    expect(session.preferences[preference.identity]?.liked, isTrue);
    expect(notifications, 1);
  });

  test('chapter writes and final progress update the mounted Home projection',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.ready;

    final chapter = ImportedChapterRecord(
      directoryId: 'remote:fixture',
      displayName: 'Chapter',
      sourceId: 'fixture-source',
      comicId: 'raw-current',
      comicTitle: 'Fixture',
      chapterId: 'chapter-1',
      sourceRevision: 'r1',
      importedAt: DateTime.utc(2026, 8, 8),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.jpg',
          sourceId: 'https://example.test/1.jpg',
          contentKindHint: ContentKindHint.jpeg,
          mediaFormat: 'jpeg',
          byteLength: 100,
        ),
      ],
    );

    final entry = await session.upsertChapter(chapter);
    expect(entry.chapter.chapterId, 'chapter-1');
    expect(session.entries, hasLength(1));

    session.replaceProgress(
      ReadingProgress(
        sourceId: 'fixture-source',
        comicId: 'raw-stale-alias',
        chapterId: 'chapter-1',
        pageIndex: 0,
        subPageOffset: 0.5,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 8, 8, 1),
      ),
    );
    expect(session.entries.single.progress?.comicId, 'raw-current');
    expect(session.entries.single.progress?.subPageOffset, 0.5);

    final saved = SavedComicRecord(
      sourceId: 'fixture-source',
      comicId: 'raw-current',
      title: 'Fixture',
    );
    await session.upsertSavedComic(saved);
    expect(session.savedComics.single.identity, saved.identity);
    await session.removeSavedComic(saved.sourceId, saved.comicId);
    expect(session.savedComics, isEmpty);

    await session.removeChapter(chapter.sourceId, chapter.chapterId);
    expect(session.entries, isEmpty);
  });

  test('confirmed version relations are a write-through Home projection',
      () async {
    final library = MemoryImportedLibraryStore();
    await library.open();
    await library.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'old-gallery',
        successorComicId: 'new-gallery',
        discoveredAt: DateTime.utc(2026, 8, 11),
      ),
    );
    await library.close();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    await session.ready;
    expect(session.versionRelations, hasLength(1));
    expect(session.versionRelations.single.predecessorComicId, 'old-gallery');

    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'venera:ehentai',
        predecessorComicId: 'new-gallery',
        successorComicId: 'newest-gallery',
        discoveredAt: DateTime.utc(2026, 8, 11, 1),
      ),
    );
    expect(session.versionRelations, hasLength(2));
    final durable = await library.listAllComicVersionRelations();
    expect(durable, hasLength(2));
  });

  test('stale reload snapshot cannot overwrite a write-through chapter',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    final categories = Completer<List<LibraryCategory>>();
    final library = _GatedLibraryStore(delegate, categories.future);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final primaryFrame = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: () => primaryFrame.future,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    // _reload has already captured its empty primary snapshot when it waits for
    // this frame barrier. A newly materialized chapter must become the newer
    // mounted projection and survive the rest of that old reload.
    await Future<void>.delayed(Duration.zero);
    final chapter = ImportedChapterRecord(
      directoryId: 'remote:race',
      displayName: 'Race Chapter',
      sourceId: 'fixture-source',
      comicId: 'fixture-comic',
      comicTitle: 'Fixture',
      chapterId: 'chapter-race',
      sourceRevision: 'r1',
      importedAt: DateTime.utc(2026, 8, 8),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '1.jpg',
          sourceId: 'https://example.test/race.jpg',
          contentKindHint: ContentKindHint.jpeg,
          mediaFormat: 'jpeg',
          byteLength: 100,
        ),
      ],
    );
    await session.upsertChapter(chapter);
    expect(session.entries.single.chapter.chapterId, 'chapter-race');

    primaryFrame.complete();
    categories.complete(const <LibraryCategory>[]);
    await session.ready;

    expect(session.entries, hasLength(1));
    expect(session.entries.single.chapter.chapterId, 'chapter-race');
  });

  test('publishes cover-bearing primary library before enrichment finishes',
      () async {
    final delegate = MemoryImportedLibraryStore();
    await delegate.open();
    await delegate.upsertSavedComic(
      SavedComicRecord(
        sourceId: 'fixture-source',
        comicId: 'fixture-comic',
        title: 'Fixture Comic',
        coverSourceId: 'https://example.test/cover.webp',
      ),
    );
    final categories = Completer<List<LibraryCategory>>();
    final library = _GatedLibraryStore(delegate, categories.future);
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, __) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final primaryFrame = Completer<void>();
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
      waitForPrimaryFrame: () => primaryFrame.future,
    );
    addTearDown(() async {
      await session.close();
      session.dispose();
    });

    var readyCompleted = false;
    unawaited(session.ready.then((_) => readyCompleted = true));
    for (var attempt = 0;
        attempt < 20 && session.savedComics.isEmpty;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(session.savedComics, hasLength(1));
    expect(session.savedComics.single.coverSourceId, isNotNull);
    expect(session.loading, isTrue);
    expect(readyCompleted, isFalse);

    categories.complete(const <LibraryCategory>[]);
    primaryFrame.complete();
    await session.ready;
    expect(session.loading, isFalse);
  });

}


final class _GatedLibraryStore implements ImportedLibraryStore {
  _GatedLibraryStore(this.delegate, this.categories);

  final ImportedLibraryStore delegate;
  final Future<List<LibraryCategory>> categories;

  @override
  Future<void> open() => delegate.open();
  @override
  Future<List<ImportedLibraryEntry>> list() => delegate.list();
  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) =>
      delegate.get(sourceId, chapterId);
  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) =>
      delegate.upsertChapter(chapter);
  @override
  Future<void> saveProgress(ReadingProgress progress) =>
      delegate.saveProgress(progress);
  @override
  Future<void> removeChapter(String sourceId, String chapterId) =>
      delegate.removeChapter(sourceId, chapterId);
  @override
  Future<List<SavedComicRecord>> listSavedComics() =>
      delegate.listSavedComics();
  @override
  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId) =>
      delegate.getSavedComic(sourceId, comicId);
  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) =>
      delegate.upsertSavedComic(comic);
  @override
  Future<void> removeSavedComic(String sourceId, String comicId) =>
      delegate.removeSavedComic(sourceId, comicId);
  @override
  Future<List<LibraryCategory>> listCategories() => categories;
  @override
  Future<void> upsertCategory(LibraryCategory category) =>
      delegate.upsertCategory(category);
  @override
  Future<void> removeCategory(String categoryId) =>
      delegate.removeCategory(categoryId);
  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      delegate.listComicPreferences();
  @override
  Future<ComicPreference?> getComicPreference(String sourceId, String comicId) =>
      delegate.getComicPreference(sourceId, comicId);
  @override
  Future<void> saveComicPreference(ComicPreference preference) =>
      delegate.saveComicPreference(preference);
  @override
  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  ) =>
      delegate.listChapterReadStates(sourceId, comicId);
  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      delegate.listAllChapterReadStates();
  @override
  Future<void> saveChapterReadState(ChapterReadState state) =>
      delegate.saveChapterReadState(state);
  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      delegate.listSourcePreferences();
  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) =>
      delegate.saveSourcePreference(preference);
  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) =>
      delegate.listMigrationIssues(includeAcknowledged: includeAcknowledged);
  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) =>
      delegate.acknowledgeMigrationIssues(
        issueIds,
        acknowledgedAt: acknowledgedAt,
      );
  @override
  Future<void> close() => delegate.close();
}
