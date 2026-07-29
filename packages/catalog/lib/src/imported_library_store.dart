import 'package:domain/domain.dart';

import 'imported_chapter.dart';
import 'library_migration_issue.dart';
import 'library_preferences.dart';
import 'saved_comic.dart';

String comicLibraryIdentity(String sourceId, String comicId) =>
    '$sourceId\u0000$comicId';

String chapterLibraryIdentity(String sourceId, String chapterId) =>
    '$sourceId\u0000$chapterId';

final class ImportedLibraryEntry {
  const ImportedLibraryEntry({
    required this.chapter,
    this.progress,
  });

  final ImportedChapterRecord chapter;
  final ReadingProgress? progress;

  String get identity =>
      chapterLibraryIdentity(chapter.sourceId, chapter.chapterId);

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
    sourceId: refreshedChapter.sourceId,
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

  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId);

  Future<void> upsertChapter(ImportedChapterRecord chapter);

  Future<void> saveProgress(ReadingProgress progress);

  Future<void> removeChapter(String sourceId, String chapterId);

  Future<List<SavedComicRecord>> listSavedComics();

  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId);

  Future<void> upsertSavedComic(SavedComicRecord comic);

  Future<void> removeSavedComic(String sourceId, String comicId);

  Future<List<LibraryCategory>> listCategories();

  Future<void> upsertCategory(LibraryCategory category);

  Future<void> removeCategory(String categoryId);

  Future<List<ComicPreference>> listComicPreferences();

  Future<ComicPreference?> getComicPreference(
    String sourceId,
    String comicId,
  );

  Future<void> saveComicPreference(ComicPreference preference);

  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  );

  /// Bulk startup projection avoiding one storage query per comic.
  Future<List<ChapterReadState>> listAllChapterReadStates();

  Future<void> saveChapterReadState(ChapterReadState state);

  Future<List<ComicSourcePreference>> listSourcePreferences();

  Future<void> saveSourcePreference(ComicSourcePreference preference);

  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  });

  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  });

  Future<void> close();
}

final class MemoryImportedLibraryStore implements ImportedLibraryStore {
  MemoryImportedLibraryStore({
    Iterable<LibraryMigrationIssue> migrationIssues =
        const <LibraryMigrationIssue>[],
  }) : _migrationIssues = <int, LibraryMigrationIssue>{
          for (final issue in migrationIssues) issue.issueId: issue,
        };

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
  final Map<int, LibraryMigrationIssue> _migrationIssues;
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
        final source = left.sourceId.compareTo(right.sourceId);
        return source != 0
            ? source
            : left.chapterId.compareTo(right.chapterId);
      });
    return values
        .map(
          (chapter) => ImportedLibraryEntry(
            chapter: chapter,
            progress: _progress[
              chapterLibraryIdentity(chapter.sourceId, chapter.chapterId)
            ],
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<ImportedLibraryEntry?> get(
    String sourceId,
    String chapterId,
  ) async {
    _requireOpen();
    final identity = chapterLibraryIdentity(sourceId, chapterId);
    final chapter = _chapters[identity];
    if (chapter == null) {
      return null;
    }
    return ImportedLibraryEntry(
      chapter: chapter,
      progress: _progress[identity],
    );
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    _requireOpen();
    final identity = chapterLibraryIdentity(chapter.sourceId, chapter.chapterId);
    final previous = _chapters[identity];
    final progress = reconcileImportedProgress(
      previousChapter: previous,
      refreshedChapter: chapter,
      progress: _progress[identity],
    );
    _chapters[identity] = chapter;
    if (progress != null) {
      _progress[identity] = progress;
    }
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    _requireOpen();
    final identity = progress.identity;
    final chapter = _chapters[identity];
    if (chapter == null) {
      throw StateError('cannot save progress for an unknown chapter');
    }
    if (progress.comicId != chapter.comicId ||
        progress.sourceId != chapter.sourceId) {
      throw StateError('progress identity does not match the chapter');
    }
    if (progress.pageIndex < 0 || progress.pageIndex >= chapter.pages.length) {
      throw RangeError.range(
        progress.pageIndex,
        0,
        chapter.pages.length - 1,
        'progress.pageIndex',
      );
    }
    final current = _progress[identity];
    if (current == null || !progress.updatedAt.isBefore(current.updatedAt)) {
      _progress[identity] = progress;
    }
  }

  @override
  Future<void> removeChapter(String sourceId, String chapterId) async {
    _requireOpen();
    final identity = chapterLibraryIdentity(sourceId, chapterId);
    final chapter = _chapters.remove(identity);
    _progress.remove(identity);
    _readStates.remove(identity);
    if (chapter != null &&
        !_chapters.values.any(
          (item) =>
              item.sourceId == chapter.sourceId &&
              item.comicId == chapter.comicId,
        ) &&
        !_savedComics.containsKey(
          comicLibraryIdentity(chapter.sourceId, chapter.comicId),
        )) {
      _preferences.remove(
        comicLibraryIdentity(chapter.sourceId, chapter.comicId),
      );
    }
  }

  @override
  Future<List<SavedComicRecord>> listSavedComics() async {
    _requireOpen();
    final values = _savedComics.values.toList(growable: false)
      ..sort((left, right) {
        final updated = right.updatedAt.compareTo(left.updatedAt);
        return updated != 0
            ? updated
            : left.identity.compareTo(right.identity);
      });
    return values;
  }

  @override
  Future<SavedComicRecord?> getSavedComic(
    String sourceId,
    String comicId,
  ) async {
    _requireOpen();
    return _savedComics[comicLibraryIdentity(sourceId, comicId)];
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
    final identity = comicLibraryIdentity(sourceId, comicId);
    _savedComics.remove(identity);
    if (!_chapters.values.any(
      (chapter) =>
          chapter.sourceId == sourceId && chapter.comicId == comicId,
    )) {
      _preferences.remove(identity);
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
  Future<ComicPreference?> getComicPreference(
    String sourceId,
    String comicId,
  ) async {
    _requireOpen();
    return _preferences[comicLibraryIdentity(sourceId, comicId)];
  }

  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    _requireOpen();
    final current = _preferences[preference.identity];
    if (current == null || !preference.updatedAt.isBefore(current.updatedAt)) {
      _preferences[preference.identity] = preference;
    }
  }

  @override
  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  ) async {
    _requireOpen();
    final values = _readStates.values
        .where(
          (state) =>
              state.sourceId == sourceId && state.comicId == comicId,
        )
        .toList(growable: false)
      ..sort((left, right) => left.chapterId.compareTo(right.chapterId));
    return values;
  }

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() async {
    _requireOpen();
    final values = _readStates.values.toList(growable: false)
      ..sort((left, right) {
        final sourceOrder = left.sourceId.compareTo(right.sourceId);
        if (sourceOrder != 0) {
          return sourceOrder;
        }
        return left.chapterId.compareTo(right.chapterId);
      });
    return values;
  }

  @override
  Future<void> saveChapterReadState(ChapterReadState state) async {
    _requireOpen();
    final current = _readStates[state.identity];
    if (current == null || !state.updatedAt.isBefore(current.updatedAt)) {
      _readStates[state.identity] = state;
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
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) async {
    _requireOpen();
    final issues = _migrationIssues.values
        .where((issue) => includeAcknowledged || !issue.acknowledged)
        .toList(growable: false)
      ..sort((left, right) => left.issueId.compareTo(right.issueId));
    return issues;
  }

  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) async {
    _requireOpen();
    for (final issueId in issueIds.toSet()) {
      final issue = _migrationIssues[issueId];
      if (issue != null) {
        _migrationIssues[issueId] = issue.copyWith(
          acknowledgedAt: acknowledgedAt.toUtc(),
        );
      }
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
