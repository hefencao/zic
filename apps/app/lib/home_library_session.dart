import 'dart:async';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';

import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';

/// Owns the durable library projection and background download subscriptions
/// used by the home shell. Navigation, dialogs and transient UI selection stay
/// in DemoHome; storage loading and service lifecycle do not.
final class HomeLibrarySession extends ChangeNotifier {
  HomeLibrarySession({
    required this.library,
    required this.chapterDownloads,
    required this.wholeComicDownloads,
    required List<BrowsableComicSource> sources,
    required this.ownsLibrary,
    required this.ownsChapterDownloads,
    required this.ownsWholeComicDownloads,
    this.waitForPrimaryFrame,
    this.startupTelemetry,
  }) : _sources = List<BrowsableComicSource>.unmodifiable(sources) {
    _downloadSubscription = chapterDownloads.changes.listen(
      acceptDownloadSnapshot,
    );
    _wholeComicSubscription = wholeComicDownloads.changes.listen((snapshot) {
      _wholeComicQueueSnapshot = snapshot;
      _publish();
    });
    _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;
    ready = _initialize();
  }

  final ImportedLibraryStore library;
  final ChapterDownloadService chapterDownloads;
  final WholeComicDownloadQueue wholeComicDownloads;
  List<BrowsableComicSource> _sources;
  List<BrowsableComicSource> get sources => _sources;
  final bool ownsLibrary;
  final bool ownsChapterDownloads;
  final bool ownsWholeComicDownloads;
  final Future<void> Function()? waitForPrimaryFrame;
  final HomeStartupTelemetry? startupTelemetry;

  late final StreamSubscription<ChapterDownloadSnapshot> _downloadSubscription;
  late final StreamSubscription<WholeComicQueueSnapshot> _wholeComicSubscription;
  late final Future<void> ready;

  List<ImportedLibraryEntry> _entries = const <ImportedLibraryEntry>[];
  List<SavedComicRecord> _savedComics = const <SavedComicRecord>[];
  List<LibraryCategory> _categories = const <LibraryCategory>[];
  Map<String, ComicPreference> _preferences = const <String, ComicPreference>{};
  Map<String, ChapterReadState> _readStates =
      const <String, ChapterReadState>{};
  Map<String, ComicSourcePreference> _sourcePreferences =
      const <String, ComicSourcePreference>{};
  Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      const <String, ChapterDownloadSnapshot>{};
  late WholeComicQueueSnapshot _wholeComicQueueSnapshot;
  Object? _error;
  bool _loading = true;
  String? _activeSourceId;
  bool _closed = false;
  int _libraryProjectionRevision = 0;

  List<ImportedLibraryEntry> get entries => _entries;
  List<SavedComicRecord> get savedComics => _savedComics;
  List<LibraryCategory> get categories => _categories;
  Map<String, ComicPreference> get preferences => _preferences;
  Map<String, ChapterReadState> get readStates => _readStates;
  Map<String, ComicSourcePreference> get sourcePreferences =>
      _sourcePreferences;
  Map<String, ChapterDownloadSnapshot> get downloadSnapshots =>
      _downloadSnapshots;
  WholeComicQueueSnapshot get wholeComicQueueSnapshot =>
      _wholeComicQueueSnapshot;
  Object? get error => _error;
  bool get loading => _loading;
  String? get activeSourceId => _activeSourceId;

  set activeSourceId(String? value) {
    if (_activeSourceId == value) {
      return;
    }
    _activeSourceId = value;
    _publish();
  }

  List<BrowsableComicSource> get enabledSources {
    final result = sources
        .where(
          (source) => _sourcePreferences[source.sourceId]?.enabled ?? true,
        )
        .toList(growable: false)
      ..sort((left, right) =>
          (_sourcePreferences[left.sourceId]?.sortOrder ?? 0).compareTo(
            _sourcePreferences[right.sourceId]?.sortOrder ?? 0,
          ));
    return result;
  }

  Future<void> _initialize() async {
    try {
      await library.open();
      await _reload(publishPrimary: true);
      await wholeComicDownloads.ready;
      _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;
      _publish();
    } on Object catch (error) {
      _error = error;
      _loading = false;
      _publish();
    }
  }

  Future<void> reload({bool waitForOpen = true}) async {
    if (waitForOpen) {
      await ready;
    }
    await _reload(publishPrimary: false);
  }

  Future<void> _reload({required bool publishPrimary}) async {
    final projectionRevisionAtStart = _libraryProjectionRevision;
    final primaryStartedAt = startupTelemetry?.nowMicros();
    final entriesFuture = library.list();
    final savedComicsFuture = library.listSavedComics();
    final entries = await entriesFuture;
    final savedComics = await savedComicsFuture;
    if (publishPrimary) {
      if (_libraryProjectionRevision == projectionRevisionAtStart) {
        _entries = List<ImportedLibraryEntry>.unmodifiable(entries);
        _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
      }
      _error = null;
      _publish();
      if (primaryStartedAt != null) {
        startupTelemetry?.serviceReady(
          'home-library-primary',
          startedAtMicros: primaryStartedAt,
        );
      }
      // Let Flutter present the cover-bearing primary projection before the
      // synchronous catalog enrichment and default writes continue on the
      // same isolate.
      await (waitForPrimaryFrame?.call() ??
          Future<void>.delayed(const Duration(milliseconds: 16)));
    }

    final enrichmentStartedAt = startupTelemetry?.nowMicros();
    final categoriesFuture = library.listCategories();
    final preferencesFuture = library.listComicPreferences();
    final sourcePreferencesFuture = library.listSourcePreferences();
    final readStatesFuture = library.listAllChapterReadStates();
    final categories = await categoriesFuture;
    final storedPreferences = await preferencesFuture;
    final storedSourcePreferences = await sourcePreferencesFuture;
    final sourcePreferences = <String, ComicSourcePreference>{
      for (final preference in storedSourcePreferences)
        preference.sourceId: preference,
    };
    final systemLanguage =
        ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    final defaultLanguages = <String>{'all', 'en', systemLanguage};
    defaultLanguages.addAll(
      sources
          .map((source) => source.descriptor.language.toLowerCase())
          .where((language) => language.startsWith('$systemLanguage-')),
    );
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (sourcePreferences.containsKey(source.sourceId)) {
        continue;
      }
      final preference = ComicSourcePreference.defaults(
        sourceId: source.sourceId,
        sortOrder: index,
      ).copyWith(
        enabled: defaultComicSourceEnabled(
          source,
          defaultLanguages: defaultLanguages,
        ),
        updatedAt: DateTime.now().toUtc(),
      );
      sourcePreferences[source.sourceId] = preference;
      await library.saveSourcePreference(preference);
    }

    final enabled = sources
        .where((source) => sourcePreferences[source.sourceId]?.enabled ?? true)
        .toList(growable: false)
      ..sort((left, right) =>
          (sourcePreferences[left.sourceId]?.sortOrder ?? 0).compareTo(
            sourcePreferences[right.sourceId]?.sortOrder ?? 0,
          ));
    final nextActiveSourceId = enabled.any(
      (source) => source.sourceId == _activeSourceId,
    )
        ? _activeSourceId
        : (enabled.isEmpty ? null : enabled.first.sourceId);

    final preferences = <String, ComicPreference>{
      for (final preference in storedPreferences)
        preference.identity: preference,
    };
    var nextOrder = preferences.values.fold<int>(
      0,
      (value, preference) =>
          preference.customOrder >= value ? preference.customOrder + 1 : value,
    );
    // A write-through mutation may land while this reload is doing enrichment.
    // In that case the mounted projection is newer than the snapshot captured
    // above and must remain the seed/visible authority.
    final projectionChanged =
        _libraryProjectionRevision != projectionRevisionAtStart;
    final seedEntries = projectionChanged ? _entries : entries;
    final seedSavedComics = projectionChanged ? _savedComics : savedComics;
    final comicSeeds = <({
      String sourceId,
      String comicId,
      ComicSourceKind sourceKind,
    })>[
      for (final entry in seedEntries)
        (
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          sourceKind: entry.chapter.sourceId == 'local-folder'
              ? ComicSourceKind.local
              : ComicSourceKind.remote,
        ),
      for (final comic in seedSavedComics)
        (
          sourceId: comic.sourceId,
          comicId: comic.comicId,
          sourceKind: comic.sourceId == 'local-folder'
              ? ComicSourceKind.local
              : ComicSourceKind.remote,
        ),
    ];
    for (final seed in comicSeeds) {
      final identity = comicLibraryIdentity(seed.sourceId, seed.comicId);
      if (preferences.containsKey(identity)) {
        continue;
      }
      final preference = ComicPreference.defaults(
        sourceId: seed.sourceId,
        comicId: seed.comicId,
        sourceKind: seed.sourceKind,
        customOrder: nextOrder++,
      ).copyWith(
        inShelf: seed.sourceKind == ComicSourceKind.local,
        updatedAt: DateTime.now().toUtc(),
      );
      preferences[preference.identity] = preference;
      await library.saveComicPreference(preference);
    }

    final readStates = <String, ChapterReadState>{
      for (final state in await readStatesFuture) state.identity: state,
    };

    if (_libraryProjectionRevision == projectionRevisionAtStart) {
      _entries = List<ImportedLibraryEntry>.unmodifiable(entries);
      _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
    }
    _categories = List<LibraryCategory>.unmodifiable(categories);
    _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
    _readStates = Map<String, ChapterReadState>.unmodifiable(readStates);
    _sourcePreferences =
        Map<String, ComicSourcePreference>.unmodifiable(sourcePreferences);
    _activeSourceId = nextActiveSourceId;
    _error = null;
    _loading = false;
    _publish();
    if (enrichmentStartedAt != null) {
      startupTelemetry?.serviceReady(
        'home-library-enrichment',
        startedAtMicros: enrichmentStartedAt,
      );
    }
    final visibleEntries =
        _libraryProjectionRevision == projectionRevisionAtStart ? entries : _entries;
    unawaited(refreshDownloadSnapshots(visibleEntries));
  }

  Future<void> ensureReady() async {
    await ready;
    if (_error == null) {
      return;
    }
    await library.open();
    await reload(waitForOpen: false);
  }

  Future<void> retry() async {
    _loading = true;
    _publish();
    try {
      await library.open();
      await reload(waitForOpen: false);
    } on Object catch (error) {
      _error = error;
      _loading = false;
      _publish();
    }
  }

  void replacePreference(ComicPreference preference) {
    _preferences = Map<String, ComicPreference>.unmodifiable(
      <String, ComicPreference>{
        ..._preferences,
        preference.identity: preference,
      },
    );
    _publish();
  }

  void replaceReadState(ChapterReadState state) {
    _readStates = Map<String, ChapterReadState>.unmodifiable(
      <String, ChapterReadState>{..._readStates, state.identity: state},
    );
    _publish();
  }

  /// Persists a chapter and updates the Home projection in the same owner.
  ///
  /// Callers must not write a chapter directly to [library] and wait for a
  /// later full reload: a newly materialized source chapter can enter Reader
  /// immediately, so Home needs the same authoritative entry before the route
  /// returns and publishes progress.
  Future<ImportedLibraryEntry> upsertChapter(
    ImportedChapterRecord chapter,
  ) async {
    await library.upsertChapter(chapter);
    final entry = await library.get(chapter.sourceId, chapter.chapterId);
    if (entry == null) {
      throw StateError('chapter write completed without a readable entry');
    }
    _replaceEntry(entry);
    return entry;
  }

  Future<void> removeChapter(String sourceId, String chapterId) async {
    await library.removeChapter(sourceId, chapterId);
    final identity = chapterLibraryIdentity(sourceId, chapterId);
    final next = _entries
        .where((entry) => entry.identity != identity)
        .toList(growable: false);
    if (next.length == _entries.length) return;
    _entries = List<ImportedLibraryEntry>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
  }

  Future<void> upsertSavedComic(SavedComicRecord comic) async {
    await library.upsertSavedComic(comic);
    final stored = await library.getSavedComic(comic.sourceId, comic.comicId);
    if (stored == null) {
      throw StateError('saved comic write completed without a readable record');
    }
    final next = _savedComics.toList(growable: true);
    final index = next.indexWhere((current) => current.identity == stored.identity);
    if (index < 0) {
      next.add(stored);
    } else {
      next[index] = stored;
    }
    _savedComics = List<SavedComicRecord>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
  }

  Future<void> removeSavedComic(String sourceId, String comicId) async {
    await library.removeSavedComic(sourceId, comicId);
    final identity = comicLibraryIdentity(sourceId, comicId);
    final next = _savedComics
        .where((comic) => comic.identity != identity)
        .toList(growable: false);
    if (next.length == _savedComics.length) return;
    _savedComics = List<SavedComicRecord>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
  }

  /// Persists progress for non-Reader mutation flows and updates Home.
  ///
  /// Reader callbacks must continue using the checkpoint writer and call
  /// [replaceProgress] only once when the route returns.
  Future<void> persistProgress(ReadingProgress progress) async {
    await library.saveProgress(progress);
    replaceProgress(progress);
  }

  /// Updates the visible Home projection after a Reader route has returned.
  ///
  /// Reader page callbacks never call this method. Persistence is owned by the
  /// library store and may still be completing on its background writer; this
  /// method only replaces the matching in-memory projection once per route.
  void replaceProgress(ReadingProgress progress) {
    final identity = chapterLibraryIdentity(
      progress.sourceId,
      progress.chapterId,
    );
    final index = _entries.indexWhere((entry) => entry.identity == identity);
    if (index < 0) return;
    final entry = _entries[index];
    final current = entry.progress;
    if (current != null && current.updatedAt.isAfter(progress.updatedAt)) return;
    // Chapter identity is source + chapter. Raw comic locators may have a
    // source-verified alias while the durable chapter remains the same; keep
    // the entry's comic locator authoritative for the visible projection.
    final normalized = progress.comicId == entry.chapter.comicId
        ? progress
        : ReadingProgress(
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
            chapterId: entry.chapter.chapterId,
            pageIndex: progress.pageIndex,
            subPageOffset: progress.subPageOffset,
            readerMode: progress.readerMode,
            updatedAt: progress.updatedAt,
          );
    _replaceEntry(entry.copyWith(progress: normalized));
  }

  void _replaceEntry(ImportedLibraryEntry entry) {
    final next = _entries.toList(growable: true);
    final index = next.indexWhere((current) => current.identity == entry.identity);
    if (index < 0) {
      next.add(entry);
    } else {
      next[index] = entry;
    }
    _entries = List<ImportedLibraryEntry>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
  }

  Future<void> replaceSources(
    List<BrowsableComicSource> sources, {
    bool reloadLibrary = true,
  }) async {
    _sources = List<BrowsableComicSource>.unmodifiable(sources);
    if (!reloadLibrary) {
      final enabled = enabledSources;
      if (!enabled.any((source) => source.sourceId == _activeSourceId)) {
        _activeSourceId = enabled.isEmpty ? null : enabled.first.sourceId;
      }
      _publish();
      return;
    }
    await reload();
  }

  void replaceSourcePreference(ComicSourcePreference preference) {
    _sourcePreferences = Map<String, ComicSourcePreference>.unmodifiable(
      <String, ComicSourcePreference>{
        ..._sourcePreferences,
        preference.sourceId: preference,
      },
    );
    final enabled = enabledSources;
    if (!enabled.any((source) => source.sourceId == _activeSourceId)) {
      _activeSourceId = enabled.isEmpty ? null : enabled.first.sourceId;
    }
    _publish();
  }

  void acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    _downloadSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      <String, ChapterDownloadSnapshot>{
        ..._downloadSnapshots,
        snapshot.identity: snapshot,
      },
    );
    _publish();
  }

  Future<void> refreshDownloadSnapshots(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final requested = entries.toList(growable: false);
    final snapshots = <String, ChapterDownloadSnapshot>{};
    try {
      for (final snapshot in await chapterDownloads.inspectMany(requested)) {
        snapshots[snapshot.identity] = snapshot;
      }
    } on Object {
      // Preserve per-entry recovery for a single stale diagnostic record while
      // keeping the normal startup path to one bulk index projection.
      for (final entry in requested) {
        try {
          final snapshot = await chapterDownloads.inspect(entry);
          snapshots[snapshot.identity] = snapshot;
        } on Object {
          // A stale diagnostic record must not block the durable library.
        }
      }
    }
    if (_closed) {
      return;
    }
    _downloadSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      snapshots,
    );
    _publish();
  }

  void refreshWholeComicSnapshot() {
    _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;
    _publish();
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _downloadSubscription.cancel();
    await _wholeComicSubscription.cancel();
    if (ownsWholeComicDownloads) {
      await wholeComicDownloads.close();
    }
    if (ownsChapterDownloads) {
      await chapterDownloads.close();
    }
    if (ownsLibrary) {
      await library.close();
    }
  }

  void _publish() {
    if (!_closed) {
      notifyListeners();
    }
  }
}

bool defaultComicSourceEnabled(
  BrowsableComicSource source, {
  required Set<String> defaultLanguages,
}) {
  if (!source.sourceId.startsWith('mihon:')) return true;
  return defaultLanguages.contains(source.descriptor.language.toLowerCase());
}
