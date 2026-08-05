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
