import 'package:domain/domain.dart';

import 'imported_chapter.dart';
import 'library_preferences.dart';
import 'saved_comic.dart';

final class ImportedLibraryEntry {
  const ImportedLibraryEntry({
    required this.chapter,
    this.progress,
  });

  final ImportedChapterRecord chapter;
  final ReadingProgress? progress;

  ImportedLibraryEntry copyWith({
    ImportedChapterRecord? chapter,
    ReadingProgress? progress,
    bool clearProgress = false,
  }) {
    return ImportedLibraryEntry(
      chapter: chapter ?? this.chapter,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }
}


ReadingProgress? reconcileImportedProgress({
  required ImportedChapterRecord? previousChapter,
  required ImportedChapterRecord refreshedChapter,
  required ReadingProgress? progress,
}) {
  if (progress == null) {
    return null;
  }
  var pageIndex = progress.pageIndex;
  if (pageIndex < 0) {
    pageIndex = 0;
  } else if (pageIndex >= refreshedChapter.pages.length) {
    pageIndex = refreshedChapter.pages.length - 1;
  }
  var preserveOffset = false;
  if (previousChapter != null &&
      progress.pageIndex >= 0 &&
      progress.pageIndex < previousChapter.pages.length) {
    final previousPage = previousChapter.pages[progress.pageIndex];
    var refreshedIndex = refreshedChapter.pages.indexWhere(
      (page) => page.stablePageId == previousPage.stablePageId,
    );
    if (refreshedIndex < 0 && previousPage.pageId == null) {
      final displayMatches = <int>[
        for (var index = 0; index < refreshedChapter.pages.length; index++)
          if (refreshedChapter.pages[index].displayName ==
              previousPage.displayName)
            index,
      ];
      if (displayMatches.length == 1) {
        refreshedIndex = displayMatches.single;
      }
    }
    if (refreshedIndex >= 0) {
      pageIndex = refreshedIndex;
      preserveOffset = true;
    }
  }
  return ReadingProgress(
    comicId: refreshedChapter.comicId,
    chapterId: refreshedChapter.chapterId,
    pageIndex: pageIndex,
    subPageOffset: preserveOffset ? progress.subPageOffset : 0,
    readerMode: progress.readerMode,
    updatedAt: progress.updatedAt,
  );
}

abstract interface class ImportedLibraryStore {
  Future<void> open();

  Future<List<ImportedLibraryEntry>> list();

  Future<ImportedLibraryEntry?> get(String chapterId);

  Future<void> upsertChapter(ImportedChapterRecord chapter);

  Future<void> saveProgress(ReadingProgress progress);

  Future<void> removeChapter(String chapterId);

  Future<List<SavedComicRecord>> listSavedComics();

  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId);

  Future<void> upsertSavedComic(SavedComicRecord comic);

  Future<void> removeSavedComic(String sourceId, String comicId);

  Future<List<LibraryCategory>> listCategories();

  Future<void> upsertCategory(LibraryCategory category);

  Future<void> removeCategory(String categoryId);

  Future<List<ComicPreference>> listComicPreferences();

  Future<ComicPreference?> getComicPreference(String comicId);

  Future<void> saveComicPreference(ComicPreference preference);

  Future<List<ChapterReadState>> listChapterReadStates(String comicId);

  Future<void> saveChapterReadState(ChapterReadState state);

  Future<List<ComicSourcePreference>> listSourcePreferences();

  Future<void> saveSourcePreference(ComicSourcePreference preference);

  Future<void> close();
}

final class MemoryImportedLibraryStore implements ImportedLibraryStore {
  final Map<String, ImportedChapterRecord> _chapters =
      <String, ImportedChapterRecord>{};
  final Map<String, ReadingProgress> _progress = <String, ReadingProgress>{};
  final Map<String, SavedComicRecord> _savedComics =
      <String, SavedComicRecord>{};
  final Map<String, LibraryCategory> _categories =
      <String, LibraryCategory>{};
  final Map<String, ComicPreference> _preferences =
      <String, ComicPreference>{};
  final Map<String, ChapterReadState> _readStates =
      <String, ChapterReadState>{};
  final Map<String, ComicSourcePreference> _sourcePreferences =
      <String, ComicSourcePreference>{};
  bool _open = false;

  @override
  Future<void> open() async {
    _open = true;
  }

  @override
  Future<List<ImportedLibraryEntry>> list() async {
    _requireOpen();
    final values = _chapters.values.toList(growable: false)
      ..sort((left, right) {
        final imported = right.importedAt.compareTo(left.importedAt);
        if (imported != 0) {
          return imported;
        }
        return left.chapterId.compareTo(right.chapterId);
      });
    return values
        .map(
          (chapter) => ImportedLibraryEntry(
            chapter: chapter,
            progress: _progress[chapter.chapterId],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ImportedLibraryEntry?> get(String chapterId) async {
    _requireOpen();
    final chapter = _chapters[chapterId];
    if (chapter == null) {
      return null;
    }
    return ImportedLibraryEntry(
      chapter: chapter,
      progress: _progress[chapterId],
    );
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    _requireOpen();
    final previous = _chapters[chapter.chapterId];
    final progress = reconcileImportedProgress(
      previousChapter: previous,
      refreshedChapter: chapter,
      progress: _progress[chapter.chapterId],
    );
    _chapters[chapter.chapterId] = chapter;
    if (progress != null) {
      _progress[chapter.chapterId] = progress;
    }
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    _requireOpen();
    final chapter = _chapters[progress.chapterId];
    if (chapter == null) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    if (progress.comicId != chapter.comicId) {
      throw StateError('progress comic identity does not match the chapter');
    }
    if (progress.pageIndex < 0 || progress.pageIndex >= chapter.pages.length) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        chapter.pages.length - 1,
        'progress.pageIndex',
      );
    }
    final current = _progress[progress.chapterId];
    if (current == null || !progress.updatedAt.isBefore(current.updatedAt)) {
      _progress[progress.chapterId] = progress;
    }
  }

  @override
  Future<void> removeChapter(String chapterId) async {
    _requireOpen();
    final chapter = _chapters.remove(chapterId);
    _progress.remove(chapterId);
    _readStates.remove(chapterId);
    if (chapter != null &&
        !_chapters.values.any((item) => item.comicId == chapter.comicId) &&
        !_savedComics.values.any((item) => item.comicId == chapter.comicId)) {
      _preferences.remove(chapter.comicId);
    }
  }

  @override
  Future<List<SavedComicRecord>> listSavedComics() async {
    _requireOpen();
    final values = _savedComics.values.toList(growable: false)
      ..sort((left, right) {
        final updated = right.updatedAt.compareTo(left.updatedAt);
        if (updated != 0) {
          return updated;
        }
        return left.identity.compareTo(right.identity);
      });
    return values;
  }

  @override
  Future<SavedComicRecord?> getSavedComic(
    String sourceId,
    String comicId,
  ) async {
    _requireOpen();
    return _savedComics[_savedComicIdentity(sourceId, comicId)];
  }

  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) async {
    _requireOpen();
    final current = _savedComics[comic.identity];
    if (current == null || !comic.updatedAt.isBefore(current.updatedAt)) {
      _savedComics[comic.identity] = comic;
    }
  }

  @override
  Future<void> removeSavedComic(String sourceId, String comicId) async {
    _requireOpen();
    _savedComics.remove(_savedComicIdentity(sourceId, comicId));
    if (!_chapters.values.any((chapter) => chapter.comicId == comicId)) {
      _preferences.remove(comicId);
    }
  }

  @override
  Future<List<LibraryCategory>> listCategories() async {
    _requireOpen();
    final values = _categories.values.toList(growable: false)
      ..sort((left, right) {
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0 ? order : left.name.compareTo(right.name);
      });
    return values;
  }

  @override
  Future<void> upsertCategory(LibraryCategory category) async {
    _requireOpen();
    _categories[category.categoryId] = category;
  }

  @override
  Future<void> removeCategory(String categoryId) async {
    _requireOpen();
    _categories.remove(categoryId);
    for (final entry in _preferences.entries.toList(growable: false)) {
      final preference = entry.value;
      if (!preference.categoryIds.contains(categoryId)) {
        continue;
      }
      _preferences[entry.key] = preference.copyWith(
        categoryIds: preference.categoryIds.where((id) => id != categoryId),
        updatedAt: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<List<ComicPreference>> listComicPreferences() async {
    _requireOpen();
    return _preferences.values.toList(growable: false);
  }

  @override
  Future<ComicPreference?> getComicPreference(String comicId) async {
    _requireOpen();
    return _preferences[comicId];
  }

  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    _requireOpen();
    final current = _preferences[preference.comicId];
    if (current == null || !preference.updatedAt.isBefore(current.updatedAt)) {
      _preferences[preference.comicId] = preference;
    }
  }

  @override
  Future<List<ChapterReadState>> listChapterReadStates(String comicId) async {
    _requireOpen();
    final values = _readStates.values
        .where((state) => state.comicId == comicId)
        .toList(growable: false)
      ..sort((left, right) => left.chapterId.compareTo(right.chapterId));
    return values;
  }

  @override
  Future<void> saveChapterReadState(ChapterReadState state) async {
    _requireOpen();
    final current = _readStates[state.chapterId];
    if (current == null || !state.updatedAt.isBefore(current.updatedAt)) {
      _readStates[state.chapterId] = state;
    }
  }

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() async {
    _requireOpen();
    final values = _sourcePreferences.values.toList(growable: false)
      ..sort((left, right) {
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0 ? order : left.sourceId.compareTo(right.sourceId);
      });
    return values;
  }

  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) async {
    _requireOpen();
    final current = _sourcePreferences[preference.sourceId];
    if (current == null || !preference.updatedAt.isBefore(current.updatedAt)) {
      _sourcePreferences[preference.sourceId] = preference;
    }
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  void _requireOpen() {
    if (!_open) {
      throw StateError('imported library store is not open');
    }
  }
}

String _savedComicIdentity(String sourceId, String comicId) =>
    '$sourceId\u0000$comicId';
