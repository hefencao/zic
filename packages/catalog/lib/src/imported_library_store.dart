import 'package:domain/domain.dart';

import 'imported_chapter.dart';
import 'library_migration_issue.dart';
import 'library_preferences.dart';
import 'saved_comic.dart';
import 'source_catalog.dart';
import 'source_migration_journal.dart';

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

/// Optional Reader checkpoint queue for persistence implementations whose
/// durable writer runs outside Flutter's UI isolate.
///
/// Reader-facing composition may enqueue latest-wins checkpoints without
/// waiting for disk I/O during ordinary page turns. Reader route exit and app
/// background transitions may request [flushProgressCheckpoints] as a durable
/// barrier without changing the per-page write cadence. Ordinary
/// [ImportedLibraryStore.saveProgress] keeps durable-completion semantics for
/// non-Reader callers.
abstract interface class ReaderProgressCheckpointStore {
  void enqueueProgress(ReadingProgress progress);

  Future<void> flushProgressCheckpoints();
}

/// Optional durable revision for the Home projection.
///
/// A snapshot may be reused without decoding every SQLite row only when the
/// storage implementation can prove that the Home-owned tables have not
/// changed since the snapshot was written. Implementations that cannot provide
/// that proof should omit this capability and let Home reconcile normally.
abstract interface class ImportedLibraryRevisionStore {
  Future<int?> get libraryProjectionRevision;
}

/// One coherent semantic view used by user-requested library backup/export.
///
/// The snapshot belongs to the library store because only the store can define
/// a consistency boundary across chapters, progress, preferences and migration
/// metadata. It deliberately contains semantic records rather than SQLite rows
/// or storage paths so callers do not gain storage authority.
final class ImportedLibraryBackupSnapshot {
  const ImportedLibraryBackupSnapshot({
    required this.entries,
    required this.savedComics,
    required this.categories,
    required this.comicPreferences,
    required this.chapterReadStates,
    required this.sourcePreferences,
    required this.migrationIssues,
  });

  final List<ImportedLibraryEntry> entries;
  final List<SavedComicRecord> savedComics;
  final List<LibraryCategory> categories;
  final List<ComicPreference> comicPreferences;
  final List<ChapterReadState> chapterReadStates;
  final List<ComicSourcePreference> sourcePreferences;
  final List<LibraryMigrationIssue> migrationIssues;
}

/// Optional store-owned consistent read for backup/export.
///
/// Implementations with independent durable writers should include all writes
/// that were durably acknowledged before this operation starts, then keep the
/// returned sections on one storage snapshot. Stores that do not implement
/// this capability remain compatible with callers that can tolerate ordinary
/// per-section reads.
abstract interface class ImportedLibraryBackupSnapshotStore {
  Future<ImportedLibraryBackupSnapshot> readLibraryBackupSnapshot();
}

final class ImportedLibraryChapterKey {
  const ImportedLibraryChapterKey({
    required this.sourceId,
    required this.chapterId,
  });

  final String sourceId;
  final String chapterId;

  String get identity => chapterLibraryIdentity(sourceId, chapterId);
}

/// Optional targeted bulk lookup for callers that already know the exact
/// chapter identities they need. This is not a library enumeration API.
abstract interface class ImportedLibraryBatchLookup {
  Future<List<ImportedLibraryEntry>> getMany(
    Iterable<ImportedLibraryChapterKey> chapters,
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

final class MemoryImportedLibraryStore
    implements
        ImportedLibraryStore,
        ImportedLibraryBatchLookup,
        ImportedLibraryBackupSnapshotStore,
        ComicVersionRelationStore,
        SourceMigrationJournalStore {
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
  final Map<String, List<ComicVersionRelation>> _versionRelations =
      <String, List<ComicVersionRelation>>{};
  final Map<int, LibraryMigrationIssue> _migrationIssues;
  final Map<String, SourceMigrationJournalRecord> _sourceMigrationJournals =
      <String, SourceMigrationJournalRecord>{};
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
  Future<List<ImportedLibraryEntry>> getMany(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) async {
    _requireOpen();
    final seen = <String>{};
    final result = <ImportedLibraryEntry>[];
    for (final key in chapters) {
      if (!seen.add(key.identity)) continue;
      final chapter = _chapters[key.identity];
      if (chapter == null) continue;
      result.add(
        ImportedLibraryEntry(
          chapter: chapter,
          progress: _progress[key.identity],
        ),
      );
    }
    return List<ImportedLibraryEntry>.unmodifiable(result);
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
  Future<ImportedLibraryBackupSnapshot> readLibraryBackupSnapshot() async {
    _requireOpen();
    final chapters = _chapters.values.toList(growable: false)
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
    final savedComics = _savedComics.values.toList(growable: false)
      ..sort((left, right) {
        final updated = right.updatedAt.compareTo(left.updatedAt);
        return updated != 0
            ? updated
            : left.identity.compareTo(right.identity);
      });
    final categories = _categories.values.toList(growable: false)
      ..sort((left, right) {
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0 ? order : left.name.compareTo(right.name);
      });
    final readStates = _readStates.values.toList(growable: false)
      ..sort((left, right) {
        final sourceOrder = left.sourceId.compareTo(right.sourceId);
        if (sourceOrder != 0) {
          return sourceOrder;
        }
        return left.chapterId.compareTo(right.chapterId);
      });
    final sourcePreferences =
        _sourcePreferences.values.toList(growable: false)
          ..sort((left, right) {
            final order = left.sortOrder.compareTo(right.sortOrder);
            return order != 0
                ? order
                : left.sourceId.compareTo(right.sourceId);
          });
    final migrationIssues = _migrationIssues.values.toList(growable: false)
      ..sort((left, right) => left.issueId.compareTo(right.issueId));
    return ImportedLibraryBackupSnapshot(
      entries: List<ImportedLibraryEntry>.unmodifiable(
        chapters.map(
          (chapter) => ImportedLibraryEntry(
            chapter: chapter,
            progress: _progress[
              chapterLibraryIdentity(chapter.sourceId, chapter.chapterId)
            ],
          ),
        ),
      ),
      savedComics: List<SavedComicRecord>.unmodifiable(savedComics),
      categories: List<LibraryCategory>.unmodifiable(categories),
      comicPreferences:
          List<ComicPreference>.unmodifiable(_preferences.values),
      chapterReadStates: List<ChapterReadState>.unmodifiable(readStates),
      sourcePreferences:
          List<ComicSourcePreference>.unmodifiable(sourcePreferences),
      migrationIssues:
          List<LibraryMigrationIssue>.unmodifiable(migrationIssues),
    );
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
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() async {
    _requireOpen();
    final result = <ComicVersionRelation>[
      for (final relations in _versionRelations.values) ...relations,
    ]..sort((left, right) {
        final source = left.sourceId.compareTo(right.sourceId);
        if (source != 0) return source;
        final predecessor =
            left.predecessorComicId.compareTo(right.predecessorComicId);
        if (predecessor != 0) return predecessor;
        return left.successorComicId.compareTo(right.successorComicId);
      });
    return List<ComicVersionRelation>.unmodifiable(result);
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) async {
    _requireOpen();
    final key = comicLibraryIdentity(sourceId, successorComicId);
    return List<ComicVersionRelation>.unmodifiable(
      _versionRelations[key] ?? const <ComicVersionRelation>[],
    );
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) async {
    _requireOpen();
    final result = <ComicVersionRelation>[];
    for (final relations in _versionRelations.values) {
      for (final relation in relations) {
        if (relation.sourceId == sourceId &&
            relation.predecessorComicId == predecessorComicId) {
          result.add(relation);
        }
      }
    }
    return List<ComicVersionRelation>.unmodifiable(result);
  }

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) async {
    _requireOpen();
    if (relation.sourceId.trim().isEmpty ||
        relation.predecessorComicId.trim().isEmpty ||
        relation.successorComicId.trim().isEmpty ||
        relation.predecessorComicId == relation.successorComicId) {
      throw ArgumentError.value(relation, 'relation');
    }
    final key = comicLibraryIdentity(
      relation.sourceId,
      relation.successorComicId,
    );
    final values = <ComicVersionRelation>[...
      (_versionRelations[key] ?? const <ComicVersionRelation>[]),
    ];
    final index = values.indexWhere(
      (value) => value.predecessorComicId == relation.predecessorComicId,
    );
    if (index >= 0) {
      final previous = values[index];
      values[index] = ComicVersionRelation(
        sourceId: relation.sourceId,
        predecessorComicId: relation.predecessorComicId,
        successorComicId: relation.successorComicId,
        predecessorTitle: relation.predecessorTitle,
        discoveredAt: previous.discoveredAt ?? relation.discoveredAt,
        pageMappings: relation.pageMappings.isEmpty
            ? previous.pageMappings
            : relation.pageMappings,
      );
    } else {
      values.add(relation);
    }
    _versionRelations[key] = List<ComicVersionRelation>.unmodifiable(values);
    while (_versionRelations.length > 256) {
      _versionRelations.remove(_versionRelations.keys.first);
    }
  }

  @override
  Future<SourceMigrationJournalRecord?> getSourceMigrationJournal(
    String migrationId,
  ) async {
    _requireOpen();
    return _sourceMigrationJournals[migrationId];
  }

  @override
  Future<List<SourceMigrationJournalRecord>>
  listPendingSourceMigrations() async {
    _requireOpen();
    final records =
        _sourceMigrationJournals.values
            .where((record) => record.phase != SourceMigrationPhase.done)
            .toList(growable: false)
          ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return records;
  }

  @override
  Future<SourceMigrationJournalRecord> beginSourceMigrationJournal(
    SourceMigrationJournalRecord record,
  ) async {
    _requireOpen();
    final existing = _sourceMigrationJournals[record.migrationId];
    if (existing != null) {
      if (existing.sourceSourceId != record.sourceSourceId ||
          existing.sourceComicId != record.sourceComicId ||
          existing.targetSourceId != record.targetSourceId ||
          existing.targetComicId != record.targetComicId ||
          existing.replacingSource != record.replacingSource ||
          existing.preparedFingerprint != record.preparedFingerprint) {
        throw StateError('source migration journal identity changed');
      }
      return existing;
    }
    for (final active in _sourceMigrationJournals.values) {
      if (active.phase != SourceMigrationPhase.done &&
          active.sourceSourceId == record.sourceSourceId &&
          active.sourceComicId == record.sourceComicId) {
        throw StateError('another source migration is already pending');
      }
    }
    _sourceMigrationJournals[record.migrationId] = record;
    return record;
  }

  @override
  Future<SourceMigrationJournalRecord> advanceSourceMigrationJournal(
    String migrationId, {
    required SourceMigrationPhase phase,
    required DateTime updatedAt,
  }) async {
    _requireOpen();
    final current = _sourceMigrationJournals[migrationId];
    if (current == null) {
      throw StateError('source migration journal is missing');
    }
    if (current.phase == phase) return current;
    if (phase.index != current.phase.index + 1) {
      throw StateError('source migration phase must advance exactly once');
    }
    final next = SourceMigrationJournalRecord(
      migrationId: current.migrationId,
      sourceSourceId: current.sourceSourceId,
      sourceComicId: current.sourceComicId,
      targetSourceId: current.targetSourceId,
      targetComicId: current.targetComicId,
      replacingSource: current.replacingSource,
      preparedFingerprint: current.preparedFingerprint,
      phase: phase,
      createdAt: current.createdAt,
      updatedAt: updatedAt.toUtc(),
    );
    _sourceMigrationJournals[migrationId] = next;
    return next;
  }

  @override
  Future<void> removeSourceMigrationJournal(String migrationId) async {
    _requireOpen();
    _sourceMigrationJournals.remove(migrationId);
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
