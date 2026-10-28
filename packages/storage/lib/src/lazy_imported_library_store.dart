import 'dart:async';

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
        ImportedLibraryProgressLookup,
        ImportedLibraryBackupSnapshotStore,
        ImportedLibrarySyncDeletionStore,
        ReaderProgressCheckpointStore,
        ComicVersionRelationStore,
        ImportedLibraryRevisionStore,
        ImportedLibraryMetadataStore,
        SourceMigrationJournalStore {
  LazyImportedLibraryStore({required Future<String> Function() rootProvider})
      : _rootProvider = rootProvider;

  final Future<String> Function() _rootProvider;
  final MemoryImportedLibraryStore _memory = MemoryImportedLibraryStore();
  SqliteImportedLibraryStore? _durable;
  Future<SqliteImportedLibraryStore>? _opening;
  final Map<String, ReadingProgress> _pendingReaderProgress =
      <String, ReadingProgress>{};
  Future<void>? _readerProgressForwarding;
  Future<void>? _closeFuture;
  bool _closing = false;
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
  Future<({int revision, String chapterRevision})?> get libraryMetadataRevision async =>
      _durable == null ? null : await _durable!.libraryMetadataRevision;

  @override
  Future<List<ReadingProgress>> listReadingProgress() async {
    final durable = _durable;
    if (durable != null) return durable.listReadingProgress();
    return <ReadingProgress>[
      for (final entry in await _memory.list())
        if (entry.progress != null) entry.progress!,
    ];
  }

  @override
  Future<ImportedLibraryBackupSnapshot> readLibraryBackupSnapshot() async {
    // A backup is an explicit durability action, unlike passive Home/settings
    // inspection. Materialize the single durable library owner first so an
    // existing on-disk library cannot be hidden behind the bootstrap memory
    // projection while the normal post-first-frame handoff is still opening.
    final durable = await _ensureDurable();
    return (durable as ImportedLibraryBackupSnapshotStore)
        .readLibraryBackupSnapshot();
  }

  @override
  Future<void> removeSyncedMetadata(
    LibrarySyncMetadataKind kind,
    String sourceId,
    String entityId, {
    required DateTime notAfter,
  }) async {
    final durable = await _ensureDurable();
    await (durable as ImportedLibrarySyncDeletionStore).removeSyncedMetadata(
      kind, sourceId, entityId, notAfter: notAfter,
    );
  }

  @override
  Future<void> open() async {
    if (_closed) {
      throw StateError('lazy imported library store is closed');
    }
    await _memory.open();
  }

  Future<ImportedLibraryStore> _ensureDurable({
    bool allowClosing = false,
  }) async {
    if (_closed || (_closing && !allowClosing)) {
      throw StateError('lazy imported library store is closing');
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
  Future<ReadingProgress?> getProgress(
    String sourceId,
    String chapterId,
  ) async {
    await flushProgressCheckpoints();
    final active = _active;
    final ImportedLibraryProgressLookup? progressLookup =
        active is ImportedLibraryProgressLookup
            ? active as ImportedLibraryProgressLookup
            : null;
    if (progressLookup != null) {
      return progressLookup.getProgress(sourceId, chapterId);
    }
    return (await get(sourceId, chapterId))?.progress;
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
  void enqueueProgress(ReadingProgress progress) {
    if (_closed || _closing) {
      throw StateError('lazy imported library store is closing');
    }
    final durable = _durable;
    if (durable != null) {
      durable.enqueueProgress(progress);
      return;
    }
    final current = _pendingReaderProgress[progress.identity];
    if (current == null || !progress.updatedAt.isBefore(current.updatedAt)) {
      _pendingReaderProgress[progress.identity] = progress;
    }
    _startReaderProgressForwarding();
  }

  void _startReaderProgressForwarding({bool allowClosing = false}) {
    if (_closed ||
        (_closing && !allowClosing) ||
        _pendingReaderProgress.isEmpty ||
        _readerProgressForwarding != null) {
      return;
    }
    final forwarding = _forwardPendingReaderProgress(
      allowClosing: allowClosing,
    );
    _readerProgressForwarding = forwarding;
    // Page turns cannot await durable promotion. Observe the flight here so a
    // failed open is retained for the explicit flush barrier instead of
    // becoming an unhandled async error.
    unawaited(
      forwarding.catchError((Object _, StackTrace _) {}),
    );
  }

  Future<void> _forwardPendingReaderProgress({
    required bool allowClosing,
  }) async {
    final durable = await _ensureDurable(allowClosing: allowClosing);
    final checkpointStore = durable as ReaderProgressCheckpointStore;
    final pending = _pendingReaderProgress.values.toList(growable: false);
    for (final progress in pending) {
      checkpointStore.enqueueProgress(progress);
      if (identical(_pendingReaderProgress[progress.identity], progress)) {
        _pendingReaderProgress.remove(progress.identity);
      }
    }
  }

  @override
  Future<void> flushProgressCheckpoints() {
    if (_closed) {
      return Future<void>.error(
        StateError('lazy imported library store is closed'),
      );
    }
    if (_closing) {
      return _closeFuture ??
          Future<void>.error(
            StateError('lazy imported library store is closing'),
          );
    }
    return _flushProgressCheckpoints();
  }

  Future<void> _flushProgressCheckpoints({
    bool allowClosing = false,
  }) async {
    while (true) {
      if (_pendingReaderProgress.isNotEmpty &&
          _durable == null &&
          _readerProgressForwarding == null) {
        _startReaderProgressForwarding(allowClosing: allowClosing);
      }
      final forwarding = _readerProgressForwarding;
      if (forwarding != null) {
        try {
          await forwarding;
        } finally {
          if (identical(_readerProgressForwarding, forwarding)) {
            _readerProgressForwarding = null;
          }
        }
        continue;
      }
      if (_pendingReaderProgress.isNotEmpty) {
        _startReaderProgressForwarding(allowClosing: allowClosing);
        continue;
      }
      final durable = _durable;
      if (durable == null) return;
      await durable.flushProgressCheckpoints();
      return;
    }
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
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    late final Future<void> closeFuture;
    closeFuture = _close();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<void> _close() async {
    Object? checkpointError;
    StackTrace? checkpointStackTrace;
    if (_pendingReaderProgress.isNotEmpty ||
        _readerProgressForwarding != null) {
      try {
        await _flushProgressCheckpoints(allowClosing: true);
      } on Object catch (error, stackTrace) {
        checkpointError = error;
        checkpointStackTrace = stackTrace;
      }
    }
    _closed = true;
    try {
      await _opening;
    } finally {
      await _durable?.close();
      await _memory.close();
    }
    if (checkpointError != null) {
      Error.throwWithStackTrace(checkpointError, checkpointStackTrace!);
    }
  }
}
