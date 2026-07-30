import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/foundation.dart';

import 'package:downloads/downloads.dart';

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
      await reload(waitForOpen: false);
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
    final entries = await library.list();
    final savedComics = await library.listSavedComics();
    final categories = await library.listCategories();
    final storedPreferences = await library.listComicPreferences();
    final storedSourcePreferences = await library.listSourcePreferences();
    final sourcePreferences = <String, ComicSourcePreference>{
      for (final preference in storedSourcePreferences)
        preference.sourceId: preference,
    };
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (sourcePreferences.containsKey(source.sourceId)) {
        continue;
      }
      final preference = ComicSourcePreference.defaults(
        sourceId: source.sourceId,
        sortOrder: index,
      ).copyWith(updatedAt: DateTime.now().toUtc());
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
    final comicSeeds = <({
      String sourceId,
      String comicId,
      ComicSourceKind sourceKind,
    })>[
      for (final entry in entries)
        (
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          sourceKind: entry.chapter.sourceId == 'local-folder'
              ? ComicSourceKind.local
              : ComicSourceKind.remote,
        ),
      for (final comic in savedComics)
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
      for (final state in await library.listAllChapterReadStates())
        state.identity: state,
    };

    _entries = List<ImportedLibraryEntry>.unmodifiable(entries);
    _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
    _categories = List<LibraryCategory>.unmodifiable(categories);
    _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
    _readStates = Map<String, ChapterReadState>.unmodifiable(readStates);
    _sourcePreferences =
        Map<String, ComicSourcePreference>.unmodifiable(sourcePreferences);
    _activeSourceId = nextActiveSourceId;
    _error = null;
    _loading = false;
    _publish();
    unawaited(refreshDownloadSnapshots(entries));
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

  Future<void> replaceSources(List<BrowsableComicSource> sources) async {
    _sources = List<BrowsableComicSource>.unmodifiable(sources);
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
