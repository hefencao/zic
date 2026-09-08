import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';

import 'sqlite_imported_library_store.dart';

/// Keeps a fresh-install Home projection in memory until the first explicit
/// library mutation needs durable storage.
///
/// SQLite is intentionally not opened from the Home constructor. When the
/// first mutation crosses the boundary, the memory projection is copied into
/// the newly opened store before the mutation is forwarded, so delaying the
/// database cannot lose a user action made during the startup window.
final class LazyImportedLibraryStore
    implements
        ImportedLibraryStore,
        ImportedLibraryBatchLookup,
        ComicVersionRelationStore,
        ImportedLibraryRevisionStore,
        SourceMigrationJournalStore {
  LazyImportedLibraryStore({required Future<String> Function() rootProvider})
      : _rootProvider = rootProvider;

  final Future<String> Function() _rootProvider;
  final MemoryImportedLibraryStore _memory = MemoryImportedLibraryStore();
  SqliteImportedLibraryStore? _durable;
  Future<SqliteImportedLibraryStore>? _opening;
  bool _closed = false;

  ImportedLibraryStore get _active => _durable ?? _memory;

  /// Materializes the SQLite store used by the runtime handoff.
  ///
  /// The bootstrap Home and the durable composition must share one library
  /// owner. Opening a second SQLite handle for the same path would make a
  /// first-install handoff race with memory promotion and could lose writes.
  /// This method therefore exposes the single-flight durable instance instead
  /// of requiring the app runtime to open a second store.
  Future<ImportedLibraryStore> ensureDurable() => _ensureDurable();

  bool get isDurable => _durable != null;

  @override
  Future<int?> get libraryProjectionRevision async {
    // The memory-only bootstrap has no durable revision to compare. Returning
    // null deliberately forces the eventual durable Home composition to
    // reconcile instead of trusting a snapshot against an unopened database.
    final durable = _durable;
    return durable == null ? null : await durable.libraryProjectionRevision;
  }

  @override
  Future<void> open() async {
    if (_closed) {
      throw StateError('lazy imported library store is closed');
    }
    await _memory.open();
  }

  Future<ImportedLibraryStore> _ensureDurable() async {
    if (_closed) {
      throw StateError('lazy imported library store is closed');
    }
    final durable = _durable;
    if (durable != null) return durable;
    final opening = _opening;
    if (opening != null) return opening;
    late final Future<SqliteImportedLibraryStore> next;
    next = _openDurable().whenComplete(() {
      if (identical(_opening, next)) {
        _opening = null;
      }
    });
    _opening = next;
    return next;
  }

  Future<SqliteImportedLibraryStore> _openDurable() async {
    final root = await _rootProvider();
    final store = SqliteImportedLibraryStore(
      '$root/imported_library.sqlite3',
    );
    try {
      await store.open();
      await _copyMemoryTo(store);
      if (_closed) {
        await store.close();
        throw StateError('lazy imported library store was closed');
      }
      _durable = store;
      return store;
    } on Object {
      await store.close();
      rethrow;
    }
  }

  Future<void> _copyMemoryTo(ImportedLibraryStore target) async {
    for (final entry in await _memory.list()) {
      await target.upsertChapter(entry.chapter);
      final progress = entry.progress;
      if (progress != null) {
        await target.saveProgress(progress);
      }
    }
    for (final comic in await _memory.listSavedComics()) {
      await target.upsertSavedComic(comic);
    }
    for (final category in await _memory.listCategories()) {
      await target.upsertCategory(category);
    }
    for (final preference in await _memory.listComicPreferences()) {
      await target.saveComicPreference(preference);
    }
    for (final state in await _memory.listAllChapterReadStates()) {
      await target.saveChapterReadState(state);
    }
    for (final preference in await _memory.listSourcePreferences()) {
      await target.saveSourcePreference(preference);
    }
    final memoryRelations = _memory as ComicVersionRelationStore;
    final targetRelations = target is ComicVersionRelationStore
        ? target as ComicVersionRelationStore
        : null;
    if (targetRelations != null) {
      for (final relation in await memoryRelations
          .listAllComicVersionRelations()) {
        await targetRelations.saveComicVersionRelation(relation);
      }
    }
  }

  @override
  Future<List<ImportedLibraryEntry>> list() => _active.list();

  @override
  Future<ImportedLibraryEntry?> get(
    String sourceId,
    String chapterId,
  ) async {
    final active = _active;
    final entry = await active.get(sourceId, chapterId);
    if (entry != null || _durable != null) {
      return entry;
    }
    // Bootstrap Home can display a compact snapshot while this lazy store is
    // still memory-backed. An explicit chapter action is the first point at
    // which it is safe to open the existing SQLite projection and hydrate the
    // full page locators. Unknown identities still follow the normal lazy
    // semantics and may create an empty durable store on explicit access.
    final durable = await _ensureDurable();
    return durable.get(sourceId, chapterId);
  }

  @override
  Future<List<ImportedLibraryEntry>> getMany(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) async {
    final keys = <String, ImportedLibraryChapterKey>{};
    for (final key in chapters) {
      keys.putIfAbsent(key.identity, () => key);
    }
    if (keys.isEmpty) return const <ImportedLibraryEntry>[];
    final active = _active as ImportedLibraryBatchLookup;
    final entries = await active.getMany(keys.values);
    if (_durable != null || entries.length == keys.length) {
      return entries;
    }
    final durable = await _ensureDurable();
    return (durable as ImportedLibraryBatchLookup).getMany(keys.values);
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) async {
    final store = await _ensureDurable();
    await store.upsertChapter(chapter);
  }

  @override
  Future<void> saveProgress(ReadingProgress progress) async {
    final store = await _ensureDurable();
    await store.saveProgress(progress);
  }

  @override
  Future<void> removeChapter(String sourceId, String chapterId) async {
    final store = await _ensureDurable();
    await store.removeChapter(sourceId, chapterId);
  }

  @override
  Future<List<SavedComicRecord>> listSavedComics() => _active.listSavedComics();

  @override
  Future<SavedComicRecord?> getSavedComic(String sourceId, String comicId) =>
      _active.getSavedComic(sourceId, comicId);

  @override
  Future<void> upsertSavedComic(SavedComicRecord comic) async {
    final store = await _ensureDurable();
    await store.upsertSavedComic(comic);
  }

  @override
  Future<void> removeSavedComic(String sourceId, String comicId) async {
    final store = await _ensureDurable();
    await store.removeSavedComic(sourceId, comicId);
  }

  @override
  Future<List<LibraryCategory>> listCategories() => _active.listCategories();

  @override
  Future<void> upsertCategory(LibraryCategory category) async {
    final store = await _ensureDurable();
    await store.upsertCategory(category);
  }

  @override
  Future<void> removeCategory(String categoryId) async {
    final store = await _ensureDurable();
    await store.removeCategory(categoryId);
  }

  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      _active.listComicPreferences();

  @override
  Future<ComicPreference?> getComicPreference(
    String sourceId,
    String comicId,
  ) =>
      _active.getComicPreference(sourceId, comicId);

  @override
  Future<void> saveComicPreference(ComicPreference preference) async {
    final store = await _ensureDurable();
    await store.saveComicPreference(preference);
  }

  @override
  Future<List<ChapterReadState>> listChapterReadStates(
    String sourceId,
    String comicId,
  ) =>
      _active.listChapterReadStates(sourceId, comicId);

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      _active.listAllChapterReadStates();

  @override
  Future<void> saveChapterReadState(ChapterReadState state) async {
    final store = await _ensureDurable();
    await store.saveChapterReadState(state);
  }

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      _active.listSourcePreferences();

  @override
  Future<void> saveSourcePreference(ComicSourcePreference preference) async {
    final store = await _ensureDurable();
    await store.saveSourcePreference(preference);
  }

  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) =>
      _active.listMigrationIssues(includeAcknowledged: includeAcknowledged);

  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) async {
    final store = await _ensureDurable();
    await store.acknowledgeMigrationIssues(
      issueIds,
      acknowledgedAt: acknowledgedAt,
    );
  }

  @override
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() {
    final store = _active;
    if (store is ComicVersionRelationStore) {
      return (store as ComicVersionRelationStore)
          .listAllComicVersionRelations();
    }
    return Future<List<ComicVersionRelation>>.value(
      const <ComicVersionRelation>[],
    );
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) {
    final store = _active;
    if (store is ComicVersionRelationStore) {
      return (store as ComicVersionRelationStore)
          .listComicVersionPredecessors(sourceId, successorComicId);
    }
    return Future<List<ComicVersionRelation>>.value(
      const <ComicVersionRelation>[],
    );
  }

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) {
    final store = _active;
    if (store is ComicVersionRelationStore) {
      return (store as ComicVersionRelationStore)
          .listComicVersionSuccessors(sourceId, predecessorComicId);
    }
    return Future<List<ComicVersionRelation>>.value(
      const <ComicVersionRelation>[],
    );
  }

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) async {
    final store = await _ensureDurable();
    final relations = store as ComicVersionRelationStore;
    await relations.saveComicVersionRelation(relation);
  }

  @override
  Future<SourceMigrationJournalRecord?> getSourceMigrationJournal(
    String migrationId,
  ) async {
    final store = await _ensureDurable();
    return (store as SourceMigrationJournalStore).getSourceMigrationJournal(
      migrationId,
    );
  }

  @override
  Future<List<SourceMigrationJournalRecord>>
  listPendingSourceMigrations() async {
    final store = await _ensureDurable();
    return (store as SourceMigrationJournalStore).listPendingSourceMigrations();
  }

  @override
  Future<SourceMigrationJournalRecord> beginSourceMigrationJournal(
    SourceMigrationJournalRecord record,
  ) async {
    final store = await _ensureDurable();
    return (store as SourceMigrationJournalStore).beginSourceMigrationJournal(
      record,
    );
  }

  @override
  Future<SourceMigrationJournalRecord> advanceSourceMigrationJournal(
    String migrationId, {
    required SourceMigrationPhase phase,
    required DateTime updatedAt,
  }) async {
    final store = await _ensureDurable();
    return (store as SourceMigrationJournalStore).advanceSourceMigrationJournal(
      migrationId,
      phase: phase,
      updatedAt: updatedAt,
    );
  }

  @override
  Future<void> removeSourceMigrationJournal(String migrationId) async {
    final store = await _ensureDurable();
    await (store as SourceMigrationJournalStore).removeSourceMigrationJournal(
      migrationId,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _opening;
    } finally {
      await _durable?.close();
      await _memory.close();
    }
  }
}
