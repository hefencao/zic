import 'dart:async';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/foundation.dart';

import 'package:downloads/downloads.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

String _downloadEntryIdentity(ImportedLibraryEntry entry) =>
    chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

HomeChapterDownloadSummary _downloadSummary(ChapterDownloadSnapshot snapshot) =>
    HomeChapterDownloadSummary(
      sourceId: snapshot.sourceId,
      comicId: snapshot.comicId,
      comicTitle: snapshot.comicTitle,
      chapterId: snapshot.chapterId,
      sourceRevision: snapshot.sourceRevision,
      title: snapshot.title,
      completedPages: snapshot.completedPages,
      totalPages: snapshot.totalPages,
      receivedBytes: snapshot.receivedBytes,
      pinnedPages: snapshot.pinnedPages,
      totalBytes: snapshot.totalBytes,
      pageProgressUnits: snapshot.pageProgressUnits,
      phase: snapshot.phase.name,
      failure: snapshot.failure,
      started: snapshot.started,
    );

ChapterDownloadSnapshot? _downloadSnapshot(HomeChapterDownloadSummary summary) {
  ChapterDownloadPhase? phase;
  for (final candidate in ChapterDownloadPhase.values) {
    if (candidate.name == summary.phase) {
      phase = candidate;
      break;
    }
  }
  if (phase == null) {
    return null;
  }
  return ChapterDownloadSnapshot(
    sourceId: summary.sourceId,
    comicId: summary.comicId,
    comicTitle: summary.comicTitle,
    chapterId: summary.chapterId,
    sourceRevision: summary.sourceRevision,
    title: summary.title,
    completedPages: summary.completedPages,
    totalPages: summary.totalPages,
    receivedBytes: summary.receivedBytes,
    pinnedPages: summary.pinnedPages,
    totalBytes: summary.totalBytes,
    pageProgressUnits: summary.pageProgressUnits,
    phase: phase,
    failure: summary.failure,
    started: summary.started,
  );
}

bool _shouldPersistDownloadTransition(
  ChapterDownloadSnapshot? previous,
  ChapterDownloadSnapshot next,
) =>
    previous == null ||
    previous.identity != next.identity ||
    previous.phase != next.phase ||
    previous.isManualDownload != next.isManualDownload ||
    previous.hasAutoCache != next.hasAutoCache;

Map<String, HomeChapterDownloadSummary> _persistedDownloadProjection(
  Map<String, ChapterDownloadSnapshot> snapshots,
) => <String, HomeChapterDownloadSummary>{
  for (final snapshot in snapshots.values)
    if (snapshot.isManualDownload || snapshot.hasAutoCache)
      snapshot.identity: _downloadSummary(snapshot),
};

bool _samePersistedDownloadProjection(
  Map<String, ChapterDownloadSnapshot> left,
  Map<String, ChapterDownloadSnapshot> right,
) {
  final leftPersisted = _persistedDownloadProjection(left);
  final rightPersisted = _persistedDownloadProjection(right);
  if (leftPersisted.length != rightPersisted.length) return false;
  for (final entry in leftPersisted.entries) {
    final other = rightPersisted[entry.key];
    if (other == null || !mapEquals(entry.value.toJson(), other.toJson())) {
      return false;
    }
  }
  return true;
}

bool _sameOrphanedDownloadProjection(
  Iterable<ImportedLibraryEntry> left,
  Iterable<ImportedLibraryEntry> right,
) {
  final leftIds = left.map(_downloadEntryIdentity).toSet();
  final rightIds = right.map(_downloadEntryIdentity).toSet();
  return setEquals(leftIds, rightIds);
}

/// Stable composition boundary between the bootstrap Home and durable app
/// services. Updating this object does not rebuild MaterialApp or DemoHome;
/// the existing Home session adopts the services in place.
final class HomeServiceHandoff extends ChangeNotifier {
  ImportedLibraryStore? libraryStore;
  ChapterDownloadService? chapterDownloads;
  ChapterDownloadTransferRuntimeProvider? downloadComposition;
  WholeComicDownloadQueue? wholeComicDownloads;
  ResourceCacheCoordinator? cacheCoordinator;
  ExternalPluginController? externalPlugins;
  Future<ExternalPluginController?> Function()? externalPluginLoader;
  Future<void> Function()? platformEnvironmentLoader;

  /// Opens and publishes the durable library/download composition on the
  /// first explicit download action when startup intentionally used the
  /// bootstrap projection.
  Future<void> Function()? ensureCoreServices;
  Future<void> Function()? checkpointHomeProjection;
  String? storageRoot;
  bool persistHomeProjectionSnapshot = false;

  /// Home-owned durability checkpoint used only by whole-App teardown.
  ///
  /// The runtime invokes this after durable Reader progress has been flushed,
  /// so the Home snapshot records the final SQLite projection revision before
  /// the FlutterEngine is destroyed.
  void setHomeProjectionCheckpoint(Future<void> Function()? callback) {
    checkpointHomeProjection = callback;
  }

  /// Runtime-owned capability for applying a new chapter-download directory.
  ///
  /// The settings UI only collects the user choice; the runtime owner closes,
  /// migrates and reopens the download services and republishes them through
  /// [updateServices]. Returns a user-facing error message on failure, or
  /// `null` on success. Absent when the runtime has not registered the
  /// capability (for example in widget-only test harnesses).
  Future<String?> Function({String? directory, required bool migrateFiles})?
  chapterDownloadRelay;

  void setChapterDownloadRelay(
    Future<String?> Function({String? directory, required bool migrateFiles})?
    relay,
  ) {
    chapterDownloadRelay = relay;
  }

  void setEnsureCoreServices(Future<void> Function()? callback) {
    ensureCoreServices = callback;
  }

  void setBootstrapCache(ResourceCacheCoordinator cache) {
    if (cacheCoordinator == null) {
      cacheCoordinator = cache;
    }
  }

  void setBootstrapLibrary(ImportedLibraryStore library) {
    libraryStore = library;
  }

  void updateServices({
    required ImportedLibraryStore? libraryStore,
    required ChapterDownloadService? chapterDownloads,
    required ChapterDownloadTransferRuntimeProvider? downloadComposition,
    required WholeComicDownloadQueue? wholeComicDownloads,
    required ResourceCacheCoordinator? cacheCoordinator,
    required ExternalPluginController? externalPlugins,
    required Future<ExternalPluginController?> Function()? externalPluginLoader,
    required Future<void> Function()? platformEnvironmentLoader,
    required Future<void> Function()? ensureCoreServices,
    required String? storageRoot,
    required bool persistHomeProjectionSnapshot,
  }) {
    final changed =
        !identical(this.libraryStore, libraryStore) ||
        !identical(this.chapterDownloads, chapterDownloads) ||
        !identical(this.downloadComposition, downloadComposition) ||
        !identical(this.wholeComicDownloads, wholeComicDownloads) ||
        !identical(this.cacheCoordinator, cacheCoordinator) ||
        !identical(this.externalPlugins, externalPlugins) ||
        this.externalPluginLoader != externalPluginLoader ||
        this.platformEnvironmentLoader != platformEnvironmentLoader ||
        this.ensureCoreServices != ensureCoreServices ||
        this.storageRoot != storageRoot ||
        this.persistHomeProjectionSnapshot != persistHomeProjectionSnapshot;
    this.libraryStore = libraryStore;
    this.chapterDownloads = chapterDownloads;
    this.downloadComposition = downloadComposition;
    this.wholeComicDownloads = wholeComicDownloads;
    this.cacheCoordinator = cacheCoordinator;
    this.externalPlugins = externalPlugins;
    this.externalPluginLoader = externalPluginLoader;
    this.platformEnvironmentLoader = platformEnvironmentLoader;
    this.ensureCoreServices = ensureCoreServices;
    this.storageRoot = storageRoot;
    this.persistHomeProjectionSnapshot = persistHomeProjectionSnapshot;
    if (changed) {
      notifyListeners();
    }
  }

  /// Publishes optional runtime capabilities without replacing the
  /// memory-backed bootstrap services.
  ///
  /// An installation may have an external-plugin manifest without any core
  /// library/download state. Source management still needs the durable root
  /// and plugin loader in that case, while Home must keep its bootstrap
  /// library and response cache instead of opening empty SQLite stores.
  void updateDeferredCapabilities({
    required ExternalPluginController? externalPlugins,
    required Future<ExternalPluginController?> Function()? externalPluginLoader,
    required Future<void> Function()? platformEnvironmentLoader,
    required String? storageRoot,
  }) {
    final changed =
        !identical(this.externalPlugins, externalPlugins) ||
        this.externalPluginLoader != externalPluginLoader ||
        this.platformEnvironmentLoader != platformEnvironmentLoader ||
        this.storageRoot != storageRoot;
    this.externalPlugins = externalPlugins;
    this.externalPluginLoader = externalPluginLoader;
    this.platformEnvironmentLoader = platformEnvironmentLoader;
    this.storageRoot = storageRoot;
    if (changed) {
      notifyListeners();
    }
  }

  void updateExternalPlugins(ExternalPluginController? value) {
    if (identical(externalPlugins, value)) {
      return;
    }
    externalPlugins = value;
    notifyListeners();
  }
}

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
    this.snapshotStore,
    this.persistSnapshot = true,
    this.persistMissingPreferences = true,
    this.waitForPrimaryFrame,
    this.startupTelemetry,
  }) : _sources = List<BrowsableComicSource>.unmodifiable(sources) {
    _downloadSubscription = chapterDownloads.changes.listen(
      acceptDownloadSnapshot,
    );
    _wholeComicSubscription = wholeComicDownloads.changes.listen((snapshot) {
      _acceptWholeComicQueueSnapshot(snapshot);
    });
    _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;
    _ready = _initialize();
  }

  ImportedLibraryStore library;
  ChapterDownloadService chapterDownloads;
  WholeComicDownloadQueue wholeComicDownloads;
  List<BrowsableComicSource> _sources;
  List<BrowsableComicSource> get sources => _sources;
  bool ownsLibrary;
  bool ownsChapterDownloads;
  bool ownsWholeComicDownloads;
  final HomeProjectionSnapshotStore? snapshotStore;
  bool persistSnapshot;

  /// Missing source/comic preferences are projected from their defaults while
  /// the library is opening. The app disables persistence for the first Home
  /// projection because these writes are synchronous SQLite mutations on the
  /// UI isolate; explicit user changes still persist through DemoHome.
  final bool persistMissingPreferences;
  final Future<void> Function()? waitForPrimaryFrame;
  final HomeStartupTelemetry? startupTelemetry;

  late StreamSubscription<ChapterDownloadSnapshot> _downloadSubscription;
  late StreamSubscription<WholeComicQueueSnapshot> _wholeComicSubscription;
  late Future<void> _ready;
  Future<void> get ready => _ready;
  Future<void>? _serviceAdoption;
  Future<void>? _downloadProjectionRefresh;
  ChapterDownloadService? _downloadProjectionRefreshService;

  List<ImportedLibraryEntry> _entries = const <ImportedLibraryEntry>[];
  List<ImportedLibraryEntry> _orphanedDownloadEntries =
      const <ImportedLibraryEntry>[];
  List<SavedComicRecord> _savedComics = const <SavedComicRecord>[];
  List<LibraryCategory> _categories = const <LibraryCategory>[];
  Map<String, ComicPreference> _preferences = const <String, ComicPreference>{};
  Map<String, ChapterReadState> _readStates =
      const <String, ChapterReadState>{};
  Map<String, ComicSourcePreference> _sourcePreferences =
      const <String, ComicSourcePreference>{};
  List<ComicVersionRelation> _versionRelations = const <ComicVersionRelation>[];
  ComicVersionBaselineProjection _versionBaselines =
      ComicVersionBaselineProjection.empty;
  Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      const <String, ChapterDownloadSnapshot>{};
  late WholeComicQueueSnapshot _wholeComicQueueSnapshot;
  final ChangeNotifier _downloadProjectionChanges = ChangeNotifier();
  Object? _error;
  bool _loading = true;
  String? _activeSourceId;
  bool _closed = false;
  int _libraryProjectionRevision = 0;
  int? _snapshotLibraryRevision;
  bool _snapshotRewriteNeeded = false;
  Future<void> _snapshotWriteTail = Future<void>.value();
  final Stopwatch _homeStartupClock = Stopwatch()..start();

  List<ImportedLibraryEntry> get entries => _entries;
  List<SavedComicRecord> get savedComics => _savedComics;
  List<LibraryCategory> get categories => _categories;
  Map<String, ComicPreference> get preferences => _preferences;
  Map<String, ChapterReadState> get readStates => _readStates;
  Map<String, ComicSourcePreference> get sourcePreferences =>
      _sourcePreferences;
  List<ComicVersionRelation> get versionRelations => _versionRelations;
  ComicVersionBaselineProjection get versionBaselines => _versionBaselines;
  Map<String, ChapterDownloadSnapshot> get downloadSnapshots =>
      _downloadSnapshots;
  List<ImportedLibraryEntry> get downloadManagerEntries {
    final byIdentity = <String, ImportedLibraryEntry>{
      for (final entry in _entries) _downloadEntryIdentity(entry): entry,
    };
    for (final entry in _orphanedDownloadEntries) {
      byIdentity.putIfAbsent(_downloadEntryIdentity(entry), () => entry);
    }
    return List<ImportedLibraryEntry>.unmodifiable(byIdentity.values);
  }

  WholeComicQueueSnapshot get wholeComicQueueSnapshot =>
      _wholeComicQueueSnapshot;
  Listenable get downloadProjectionChanges => _downloadProjectionChanges;
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

  void _recomputeVersionBaselines() {
    _versionBaselines = resolveComicVersionBaselines(
      relations: _versionRelations,
      shelfComics: <ComicVersionIdentity>[
        for (final preference in _preferences.values)
          if (preference.inShelf)
            ComicVersionIdentity(
              sourceId: preference.sourceId,
              comicId: preference.comicId,
            ),
      ],
      manualDownloadComics: <ComicVersionIdentity>[
        for (final snapshot in _downloadSnapshots.values)
          if (snapshot.isManualDownload)
            ComicVersionIdentity(
              sourceId: snapshot.sourceId,
              comicId: snapshot.comicId,
            ),
      ],
    );
    // Manual/export consumers receive only direct predecessor -> current
    // download-head mappings. Artifact cache reuse is independent from manual
    // adoption and keeps the full source-verified relation set.
    chapterDownloads.updateVersionBaselines(
      _versionBaselines.downloadHeadRelations,
    );
    chapterDownloads.updateCacheVersionRelations(_versionRelations);
  }

  List<BrowsableComicSource> get enabledSources {
    final result =
        sources
            .where(
              (source) => _sourcePreferences[source.sourceId]?.enabled ?? true,
            )
            .toList(growable: false)
          ..sort(
            (left, right) => (_sourcePreferences[left.sourceId]?.sortOrder ?? 0)
                .compareTo(_sourcePreferences[right.sourceId]?.sortOrder ?? 0),
          );
    return result;
  }

  Future<void> _initialize() async {
    _homeLog(
      'initialize-start store=${library.runtimeType} '
      'snapshotStore=${snapshotStore != null} '
      'persistSnapshot=$persistSnapshot sources=${sources.length}',
    );
    try {
      final snapshotFuture = snapshotStore == null
          ? null
          : _traceStartupOperation<HomeProjectionSnapshot?>(
              'snapshot-read',
              () => snapshotStore!.read(),
              summary: (snapshot) => snapshot == null
                  ? 'present=false'
                  : _snapshotSummary(snapshot),
            );
      if (snapshotFuture == null) {
        _homeLog('snapshot-read-skipped reason=no-store');
      }
      final openFuture = _traceStartupOperation<void>(
        'library-open',
        library.open,
      );
      HomeProjectionSnapshot? loadedSnapshot;
      if (snapshotFuture != null) {
        final snapshot = await snapshotFuture;
        if (snapshot != null) {
          loadedSnapshot = snapshot;
          _applySnapshot(snapshot, publish: false);
        }
      }
      await openFuture;
      _homeLog('library-open-ready snapshotPresent=${loadedSnapshot != null}');
      if (loadedSnapshot != null && !persistSnapshot) {
        // The bootstrap Home is backed by an intentionally empty lazy memory
        // store. It may display a durable snapshot, but it must not reconcile
        // that snapshot against the empty memory store and erase the visible
        // projection before the real SQLite-backed Home is attached.
        _loading = false;
        _error = null;
        _publish();
        _homeLog(
          'bootstrap-snapshot-only-published '
          '${_snapshotSummary(loadedSnapshot)}',
        );
        _observeWholeComicQueueReady();
        _homeLog('initialize-complete mode=bootstrap-snapshot-only');
        return;
      }
      await _reload(
        publishPrimary: true,
        snapshotRevision: loadedSnapshot?.libraryRevision,
      );
      _observeWholeComicQueueReady();
      _homeLog(
        'initialize-complete entries=${_entries.length} '
        'saved=${_savedComics.length} readStates=${_readStates.length}',
      );
    } on Object catch (error) {
      _homeLog('initialize-failed errorType=${error.runtimeType}');
      _error = error;
      _loading = false;
      _publish();
    }
  }

  void _observeWholeComicQueueReady() {
    final queue = wholeComicDownloads;
    unawaited(
      _traceStartupOperation<void>(
        'whole-comic-downloads-ready',
        () => queue.ready,
      ).then<void>(
        (_) {
          if (_closed || !identical(queue, wholeComicDownloads)) {
            return;
          }
          final snapshot = queue.snapshot;
          _acceptWholeComicQueueSnapshot(snapshot);
          _homeLog(
            'whole-comic-downloads-snapshot-updated '
            'jobs=${snapshot.jobs.length} projection=download-only',
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          _homeLog(
            'whole-comic-downloads-ready-failed '
            'errorType=${error.runtimeType}',
          );
        },
      ),
    );
  }

  Future<void> reload({bool waitForOpen = true}) async {
    if (waitForOpen) {
      await ready;
    }
    await _reload(publishPrimary: false);
  }

  /// Replaces the bootstrap-only services without replacing the Home widget.
  ///
  /// The snapshot projection remains mounted while the durable services are
  /// adopted. If its revision still matches SQLite, no second library
  /// projection notification is needed; otherwise one authoritative reload
  /// replaces it in place.
  Future<void> adoptServices({
    required ImportedLibraryStore library,
    required ChapterDownloadService chapterDownloads,
    required WholeComicDownloadQueue wholeComicDownloads,
    required List<BrowsableComicSource> sources,
    required bool persistSnapshot,
  }) {
    final existing = _serviceAdoption;
    if (existing != null) {
      return existing;
    }
    late final Future<void> adoption;
    adoption =
        _adoptServices(
          library: library,
          chapterDownloads: chapterDownloads,
          wholeComicDownloads: wholeComicDownloads,
          sources: sources,
          persistSnapshot: persistSnapshot,
        ).whenComplete(() {
          if (identical(_serviceAdoption, adoption)) {
            _serviceAdoption = null;
          }
        });
    _serviceAdoption = adoption;
    return adoption;
  }

  Future<void> _adoptServices({
    required ImportedLibraryStore library,
    required ChapterDownloadService chapterDownloads,
    required WholeComicDownloadQueue wholeComicDownloads,
    required List<BrowsableComicSource> sources,
    required bool persistSnapshot,
  }) async {
    final previousReady = _ready;
    await previousReady;
    if (_closed) {
      return;
    }
    if (identical(this.library, library) &&
        identical(this.chapterDownloads, chapterDownloads) &&
        identical(this.wholeComicDownloads, wholeComicDownloads)) {
      this.persistSnapshot = persistSnapshot;
      return;
    }

    final previousLibrary = this.library;
    final previousChapterDownloads = this.chapterDownloads;
    final previousWholeComicDownloads = this.wholeComicDownloads;
    final previousOwnsLibrary = ownsLibrary;
    final previousOwnsChapterDownloads = ownsChapterDownloads;
    final previousOwnsWholeComicDownloads = ownsWholeComicDownloads;
    await _downloadSubscription.cancel();
    await _wholeComicSubscription.cancel();

    this.library = library;
    this.chapterDownloads = chapterDownloads;
    this.wholeComicDownloads = wholeComicDownloads;
    _recomputeVersionBaselines();
    // Preserve the snapshot-projected orphan entries until the adopted
    // service publishes its first authoritative download projection.
    ownsLibrary = false;
    ownsChapterDownloads = false;
    ownsWholeComicDownloads = false;
    this.persistSnapshot = persistSnapshot;
    _sources = List<BrowsableComicSource>.unmodifiable(sources);
    _downloadSubscription = chapterDownloads.changes.listen(
      acceptDownloadSnapshot,
    );
    _wholeComicSubscription = wholeComicDownloads.changes.listen((snapshot) {
      _acceptWholeComicQueueSnapshot(snapshot);
    });
    _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;

    if (previousOwnsWholeComicDownloads) {
      try {
        await previousWholeComicDownloads.close();
      } on Object {
        // A busy superseded service must not abort the adoption: the swap
        // above is already authoritative.
        _homeLog('adopt-close-whole-comic-failed');
      }
    }
    if (previousOwnsChapterDownloads) {
      try {
        await previousChapterDownloads.close();
      } on Object {
        _homeLog('adopt-close-chapter-downloads-failed');
      }
    }
    if (previousOwnsLibrary) {
      try {
        await previousLibrary.close();
      } on Object {
        _homeLog('adopt-close-library-failed');
      }
    }

    _ready = _reconcileAdoptedServices().then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // The composition swap is authoritative and irreversible: a failed
        // reconcile must not split Home's bindings from the adopted services;
        // ensureReady() retries the reconcile.
        _homeLog('adopt-reconcile-failed errorType=${error.runtimeType}');
        _error = error;
        _loading = false;
        _publish();
      },
    );
    await _ready;
  }

  Future<void> _reconcileAdoptedServices() async {
    await library.open();
    final snapshotRevision = _snapshotLibraryRevision;
    final currentRevision = snapshotRevision == null
        ? null
        : await _traceStartupOperation<int?>(
            'handoff-projection-revision-read',
            _readLibraryProjectionRevision,
            summary: (revision) => 'revision=${revision ?? 'none'}',
          );
    if (snapshotRevision != null && currentRevision == snapshotRevision) {
      _activeSourceId = _activeSourceIdForCurrentSources();
      _error = null;
      _loading = false;
      _observeWholeComicQueueReady();
      if (_snapshotRewriteNeeded) {
        _snapshotRewriteNeeded = false;
        _scheduleSnapshotWrite();
      }
      _homeLog(
        'services-handoff-complete mode=revision-fast-path '
        'entries=${_entries.length} saved=${_savedComics.length}',
      );
      unawaited(_refreshDownloadSnapshotsAfterFrame(_entries));
      return;
    }

    await _reload(publishPrimary: false);
    _observeWholeComicQueueReady();
    _homeLog(
      'services-handoff-complete mode=authoritative-reload '
      'entries=${_entries.length} saved=${_savedComics.length}',
    );
  }

  void _applySnapshot(HomeProjectionSnapshot snapshot, {bool publish = true}) {
    if (_closed) {
      return;
    }
    _entries = List<ImportedLibraryEntry>.unmodifiable(snapshot.entries);
    _savedComics = List<SavedComicRecord>.unmodifiable(snapshot.savedComics);
    _categories = List<LibraryCategory>.unmodifiable(snapshot.categories);
    _preferences =
        Map<String, ComicPreference>.unmodifiable(<String, ComicPreference>{
          for (final preference in snapshot.preferences)
            preference.identity: preference,
        });
    _readStates = Map<String, ChapterReadState>.unmodifiable(
      <String, ChapterReadState>{
        for (final state in snapshot.readStates) state.identity: state,
      },
    );
    _sourcePreferences = Map<String, ComicSourcePreference>.unmodifiable(
      <String, ComicSourcePreference>{
        for (final preference in snapshot.sourcePreferences)
          preference.sourceId: preference,
      },
    );
    _versionRelations = List<ComicVersionRelation>.unmodifiable(
      snapshot.versionRelations,
    );
    _orphanedDownloadEntries = List<ImportedLibraryEntry>.unmodifiable(
      snapshot.orphanedDownloadEntries,
    );
    final downloadSnapshots = <String, ChapterDownloadSnapshot>{};
    for (final summary in snapshot.chapterDownloads) {
      final downloadSnapshot = _downloadSnapshot(summary);
      if (downloadSnapshot != null) {
        downloadSnapshots[downloadSnapshot.identity] = downloadSnapshot;
      }
    }
    _downloadSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      downloadSnapshots,
    );
    _recomputeVersionBaselines();
    _downloadProjectionChanges.notifyListeners();
    _snapshotLibraryRevision = snapshot.libraryRevision;
    _snapshotRewriteNeeded = snapshot.requiresRewrite;
    _activeSourceId = _activeSourceIdForCurrentSources();
    _error = null;
    if (publish) {
      _publish();
    }
    _homeLog('snapshot-applied ${_snapshotSummary(snapshot)}');
  }

  Future<void> _reload({
    required bool publishPrimary,
    int? snapshotRevision,
  }) async {
    final primaryStartedAt = startupTelemetry?.nowMicros();
    _homeLog(
      'reload-start publishPrimary=$publishPrimary '
      'snapshotRevision=${snapshotRevision ?? 'none'}',
    );
    if (publishPrimary && snapshotRevision != null) {
      final currentRevision = await _traceStartupOperation<int?>(
        'projection-revision-read',
        _readLibraryProjectionRevision,
        summary: (revision) => 'revision=${revision ?? 'none'}',
      );
      _homeLog(
        'snapshot-revision-check snapshot=$snapshotRevision '
        'current=${currentRevision ?? 'none'} '
        'match=${currentRevision == snapshotRevision}',
      );
      if (currentRevision != null && currentRevision == snapshotRevision) {
        _activeSourceId = _activeSourceIdForCurrentSources();
        _error = null;
        _loading = false;
        _publish();
        if (primaryStartedAt != null) {
          startupTelemetry?.serviceReady(
            'home-library-primary',
            startedAtMicros: primaryStartedAt,
          );
        }
        unawaited(_refreshDownloadSnapshotsAfterFrame(_entries));
        if (_snapshotRewriteNeeded) {
          _snapshotRewriteNeeded = false;
          _homeLog('legacy-snapshot-rewrite-requested');
          _scheduleSnapshotWrite();
        }
        _homeLog(
          'reload-complete mode=revision-fast-path '
          'entries=${_entries.length} saved=${_savedComics.length}',
        );
        return;
      }
    }
    final projectionRevisionAtStart = _libraryProjectionRevision;
    _homeLog('primary-query-batch-start');
    final entriesFuture = _traceStartupOperation<List<ImportedLibraryEntry>>(
      'query-entries',
      library.list,
      summary: (entries) => 'count=${entries.length}',
    );
    final savedComicsFuture = _traceStartupOperation<List<SavedComicRecord>>(
      'query-saved-comics',
      library.listSavedComics,
      summary: (comics) => 'count=${comics.length}',
    );
    // These are read-only startup queries. Start them with the primary query
    // instead of waiting for the primary frame barrier; the Home update strip
    // needs the stored shelf preferences and confirmed versions, while the
    // history strip can already be projected from the chapter progress.
    final categoriesFuture = _traceStartupOperation<List<LibraryCategory>>(
      'query-categories',
      library.listCategories,
      summary: (categories) => 'count=${categories.length}',
    );
    final preferencesFuture = _traceStartupOperation<List<ComicPreference>>(
      'query-comic-preferences',
      library.listComicPreferences,
      summary: (preferences) => 'count=${preferences.length}',
    );
    final sourcePreferencesFuture =
        _traceStartupOperation<List<ComicSourcePreference>>(
          'query-source-preferences',
          library.listSourcePreferences,
          summary: (preferences) => 'count=${preferences.length}',
        );
    final readStatesFuture = _traceStartupOperation<List<ChapterReadState>>(
      'query-read-states',
      () => library.listAllChapterReadStates(),
      summary: (states) => 'count=${states.length}',
    );
    final versionRelationStore = library is ComicVersionRelationStore
        ? library as ComicVersionRelationStore
        : null;
    final versionRelationsFuture = versionRelationStore == null
        ? Future<List<ComicVersionRelation>>.value(
            const <ComicVersionRelation>[],
          )
        : _traceStartupOperation<List<ComicVersionRelation>>(
            'query-version-relations',
            versionRelationStore.listAllComicVersionRelations,
            summary: (relations) => 'count=${relations.length}',
          );
    final entries = await entriesFuture;
    final savedComics = await savedComicsFuture;
    final storedPreferences = await preferencesFuture;
    final versionRelations = await versionRelationsFuture;
    final preferences = <String, ComicPreference>{
      for (final preference in storedPreferences)
        preference.identity: preference,
    };
    _homeLog(
      'primary-query-batch-complete entries=${entries.length} '
      'saved=${savedComics.length} preferences=${preferences.length} '
      'versionRelations=${versionRelations.length}',
    );
    if (publishPrimary) {
      if (_libraryProjectionRevision == projectionRevisionAtStart) {
        _entries = List<ImportedLibraryEntry>.unmodifiable(entries);
        _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
        _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
        _versionRelations = List<ComicVersionRelation>.unmodifiable(
          versionRelations,
        );
        _recomputeVersionBaselines();
      }
      _error = null;
      _publish();
      if (primaryStartedAt != null) {
        startupTelemetry?.serviceReady(
          'home-library-primary',
          startedAtMicros: primaryStartedAt,
        );
      }
      _homeLog(
        'primary-published entries=${_entries.length} '
        'saved=${_savedComics.length} preferences=${_preferences.length} '
        'versionRelations=${_versionRelations.length}',
      );
      // Let Flutter present the cover-bearing primary projection before the
      // synchronous catalog enrichment and default writes continue on the
      // same isolate.
      await _traceStartupOperation<void>(
        'primary-frame-wait',
        () =>
            waitForPrimaryFrame?.call() ??
            Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }

    final enrichmentStartedAt = startupTelemetry?.nowMicros();
    _homeLog('enrichment-start');
    final categories = await categoriesFuture;
    final storedSourcePreferences = await sourcePreferencesFuture;
    final sourcePreferences = <String, ComicSourcePreference>{
      for (final preference in storedSourcePreferences)
        preference.sourceId: preference,
    };
    final systemLanguage = ui.PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    final defaultLanguages = <String>{'all', 'en', systemLanguage};
    defaultLanguages.addAll(
      sources
          .map((source) => source.descriptor.language.toLowerCase())
          .where((language) => language.startsWith('$systemLanguage-')),
    );
    final sourceDefaultsClock = Stopwatch()..start();
    var sourceDefaultsCreated = 0;
    var sourceDefaultsPersisted = 0;
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      if (sourcePreferences.containsKey(source.sourceId)) {
        continue;
      }
      final preference =
          ComicSourcePreference.defaults(
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
      sourceDefaultsCreated++;
      if (persistMissingPreferences) {
        await library.saveSourcePreference(preference);
        sourceDefaultsPersisted++;
      }
    }
    _homeLog(
      'source-preferences-defaults-complete '
      'created=$sourceDefaultsCreated persisted=$sourceDefaultsPersisted '
      'durationMs=${sourceDefaultsClock.elapsedMilliseconds}',
    );

    final nextActiveSourceId = _activeSourceIdFor(
      sourcePreferences,
      current: _activeSourceId,
    );

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
    final seedPreferences = projectionChanged
        ? <String, ComicPreference>{..._preferences}
        : preferences;
    final comicSeeds =
        <({String sourceId, String comicId, ComicSourceKind sourceKind})>[
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
    final comicDefaultsClock = Stopwatch()..start();
    var comicDefaultsCreated = 0;
    var comicDefaultsPersisted = 0;
    for (final seed in comicSeeds) {
      final identity = comicLibraryIdentity(seed.sourceId, seed.comicId);
      if (seedPreferences.containsKey(identity)) {
        continue;
      }
      final preference =
          ComicPreference.defaults(
            sourceId: seed.sourceId,
            comicId: seed.comicId,
            sourceKind: seed.sourceKind,
            customOrder: nextOrder++,
          ).copyWith(
            inShelf: seed.sourceKind == ComicSourceKind.local,
            updatedAt: DateTime.now().toUtc(),
          );
      seedPreferences[preference.identity] = preference;
      comicDefaultsCreated++;
      if (persistMissingPreferences) {
        await library.saveComicPreference(preference);
        comicDefaultsPersisted++;
      }
    }
    _homeLog(
      'comic-preferences-defaults-complete '
      'created=$comicDefaultsCreated persisted=$comicDefaultsPersisted '
      'durationMs=${comicDefaultsClock.elapsedMilliseconds}',
    );

    final readStates = <String, ChapterReadState>{
      for (final state in await readStatesFuture) state.identity: state,
    };
    final seedReadStates = projectionChanged ? _readStates : readStates;
    final seedSourcePreferences = projectionChanged
        ? _sourcePreferences
        : sourcePreferences;

    if (_libraryProjectionRevision == projectionRevisionAtStart) {
      _entries = List<ImportedLibraryEntry>.unmodifiable(entries);
      _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
      _versionRelations = List<ComicVersionRelation>.unmodifiable(
        versionRelations,
      );
      _recomputeVersionBaselines();
    }
    _categories = List<LibraryCategory>.unmodifiable(categories);
    _preferences = Map<String, ComicPreference>.unmodifiable(seedPreferences);
    _readStates = Map<String, ChapterReadState>.unmodifiable(seedReadStates);
    _sourcePreferences = Map<String, ComicSourcePreference>.unmodifiable(
      seedSourcePreferences,
    );
    _recomputeVersionBaselines();
    _activeSourceId = nextActiveSourceId;
    _error = null;
    _loading = false;
    _publish();
    _homeLog(
      'enrichment-published entries=${_entries.length} '
      'saved=${_savedComics.length} categories=${_categories.length} '
      'preferences=${_preferences.length} readStates=${_readStates.length} '
      'sourcePreferences=${_sourcePreferences.length}',
    );
    if (enrichmentStartedAt != null) {
      startupTelemetry?.serviceReady(
        'home-library-enrichment',
        startedAtMicros: enrichmentStartedAt,
      );
    }
    final visibleEntries =
        _libraryProjectionRevision == projectionRevisionAtStart
        ? entries
        : _entries;
    unawaited(_refreshDownloadSnapshotsAfterFrame(visibleEntries));
    _snapshotRewriteNeeded = false;
    _scheduleSnapshotWrite();
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

  /// Resolves a Home entry against the authoritative store before any path
  /// locator is consumed by Reader or downloads. Compact snapshot entries keep
  /// only the page count and cover metadata, so they are intentionally not
  /// suitable for page loading.
  Future<ImportedLibraryEntry> hydrateEntry(ImportedLibraryEntry entry) async {
    final hydrated = await _traceStartupOperation<ImportedLibraryEntry?>(
      'chapter-hydrate',
      () => library.get(entry.chapter.sourceId, entry.chapter.chapterId),
      summary: (value) => 'present=${value != null}',
    );
    return hydrated ?? entry;
  }

  Future<List<ImportedLibraryEntry>> loadAuthoritativeEntries() async {
    await ready;
    return library.list();
  }

  Future<void> upsertVersionRelation(ComicVersionRelation relation) async {
    await _persistVersionRelation(relation);
    replaceVersionRelation(relation);
  }

  /// Persists derived page-reuse evidence without publishing a Home mutation.
  ///
  /// Page mappings change cache/download reuse authority, but do not change the
  /// visible version family/head projection. Publishing them through the broad
  /// Home ChangeNotifier caused every background mapping write to rebuild the
  /// covered Home route and enqueue another full projection snapshot write.
  Future<void> upsertVersionRelationDerivedState(
    ComicVersionRelation relation,
  ) async {
    await _persistVersionRelation(relation);
    _replaceVersionRelation(relation, publishHome: false, writeSnapshot: false);
  }

  Future<void> _persistVersionRelation(ComicVersionRelation relation) async {
    final store = library is ComicVersionRelationStore
        ? library as ComicVersionRelationStore
        : null;
    if (store == null) {
      throw StateError('library does not persist comic version relations');
    }
    await store.saveComicVersionRelation(relation);
  }

  void replaceVersionRelation(ComicVersionRelation relation) {
    _replaceVersionRelation(relation, publishHome: true, writeSnapshot: true);
  }

  void _replaceVersionRelation(
    ComicVersionRelation relation, {
    required bool publishHome,
    required bool writeSnapshot,
  }) {
    final next = _versionRelations.toList(growable: true);
    final index = next.indexWhere(
      (current) =>
          current.sourceId == relation.sourceId &&
          current.predecessorComicId == relation.predecessorComicId &&
          current.successorComicId == relation.successorComicId,
    );
    if (index < 0) {
      next.add(relation);
    } else {
      final previous = next[index];
      next[index] = ComicVersionRelation(
        sourceId: relation.sourceId,
        predecessorComicId: relation.predecessorComicId,
        successorComicId: relation.successorComicId,
        predecessorTitle: relation.predecessorTitle,
        discoveredAt: previous.discoveredAt ?? relation.discoveredAt,
        pageMappings: relation.pageMappings.isEmpty
            ? previous.pageMappings
            : relation.pageMappings,
      );
    }
    _versionRelations = List<ComicVersionRelation>.unmodifiable(next);
    _recomputeVersionBaselines();
    _libraryProjectionRevision++;
    if (publishHome) {
      _publish();
    }
    if (writeSnapshot) {
      _scheduleSnapshotWrite();
    }
  }

  void replacePreference(ComicPreference preference) {
    _preferences = Map<String, ComicPreference>.unmodifiable(
      <String, ComicPreference>{
        ..._preferences,
        preference.identity: preference,
      },
    );
    _recomputeVersionBaselines();
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  void replaceReadState(ChapterReadState state) {
    _readStates = Map<String, ChapterReadState>.unmodifiable(
      <String, ChapterReadState>{..._readStates, state.identity: state},
    );
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
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
    final nextReadStates = <String, ChapterReadState>{..._readStates}
      ..remove(identity);
    final entriesChanged = next.length != _entries.length;
    final readStateChanged = nextReadStates.length != _readStates.length;
    if (!entriesChanged && !readStateChanged) return;
    if (entriesChanged) {
      _entries = List<ImportedLibraryEntry>.unmodifiable(next);
    }
    if (readStateChanged) {
      _readStates = Map<String, ChapterReadState>.unmodifiable(nextReadStates);
    }
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  Future<void> upsertSavedComic(SavedComicRecord comic) async {
    await library.upsertSavedComic(comic);
    final stored = await library.getSavedComic(comic.sourceId, comic.comicId);
    if (stored == null) {
      throw StateError('saved comic write completed without a readable record');
    }
    final next = _savedComics.toList(growable: true);
    final index = next.indexWhere(
      (current) => current.identity == stored.identity,
    );
    if (index < 0) {
      next.add(stored);
    } else {
      next[index] = stored;
    }
    _savedComics = List<SavedComicRecord>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
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
    _scheduleSnapshotWrite();
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
    if (current != null && current.updatedAt.isAfter(progress.updatedAt))
      return;
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
    final index = next.indexWhere(
      (current) => current.identity == entry.identity,
    );
    if (index < 0) {
      next.add(entry);
    } else {
      next[index] = entry;
    }
    _entries = List<ImportedLibraryEntry>.unmodifiable(next);
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
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
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  void acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    if (_closed) {
      return;
    }
    ChapterDownloadSnapshot? previous;
    final next = <String, ChapterDownloadSnapshot>{};
    for (final entry in _downloadSnapshots.entries) {
      if (entry.value.sourceId == snapshot.sourceId &&
          entry.value.comicId == snapshot.comicId &&
          entry.value.chapterId == snapshot.chapterId) {
        previous = entry.value;
        continue;
      }
      next[entry.key] = entry.value;
    }
    next[snapshot.identity] = snapshot;
    _downloadSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      next,
    );
    _recomputeVersionBaselines();
    _downloadProjectionChanges.notifyListeners();
    if (_shouldPersistDownloadTransition(previous, snapshot)) {
      _scheduleSnapshotWrite();
    }
  }

  Future<void> refreshDownloadSnapshots(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    final service = chapterDownloads;
    final existing = _downloadProjectionRefresh;
    if (existing != null &&
        identical(service, _downloadProjectionRefreshService)) {
      return existing;
    }
    final requested = entries.toList(growable: false);
    late final Future<void> refresh;
    refresh = _refreshDownloadSnapshotsOnce(service, requested).whenComplete(
      () {
        if (identical(_downloadProjectionRefresh, refresh)) {
          _downloadProjectionRefresh = null;
          _downloadProjectionRefreshService = null;
        }
      },
    );
    _downloadProjectionRefreshService = service;
    _downloadProjectionRefresh = refresh;
    return refresh;
  }

  Future<void> _refreshDownloadSnapshotsOnce(
    ChapterDownloadService service,
    List<ImportedLibraryEntry> requested,
  ) async {
    final previousSnapshots = _downloadSnapshots;
    final previousOrphaned = _orphanedDownloadEntries;
    final snapshots = <String, ChapterDownloadSnapshot>{};
    var orphaned = const <ImportedLibraryEntry>[];
    final startedAt = _homeStartupClock.elapsedMilliseconds;
    _homeLog('download-snapshot-refresh-start entries=${requested.length}');
    try {
      final projectionReader =
          service is ChapterDownloadManagementProjectionReader
          ? service as ChapterDownloadManagementProjectionReader
          : null;
      if (projectionReader != null) {
        final projection = await projectionReader.inspectDownloadManagement(
          requested,
        );
        orphaned = projection.orphanedEntries;
        for (final snapshot in projection.snapshots) {
          snapshots[snapshot.identity] = snapshot;
        }
      } else {
        orphaned = await service.discoverOrphanedEntries(requested);
        for (final snapshot in await service.inspectMany(<ImportedLibraryEntry>[
          ...requested,
          ...orphaned,
        ])) {
          snapshots[snapshot.identity] = snapshot;
        }
      }
      _homeLog(
        'download-snapshot-refresh-complete '
        'entries=${requested.length} orphaned=${orphaned.length} '
        'snapshots=${snapshots.length} '
        'durationMs=${_homeStartupClock.elapsedMilliseconds - startedAt}',
      );
    } on Object {
      // Preserve per-entry recovery for a single stale diagnostic record while
      // keeping the normal startup path to one bulk index projection.
      _homeLog('download-snapshot-refresh-bulk-failed');
      for (final entry in requested) {
        try {
          final snapshot = await service.inspect(entry);
          snapshots[snapshot.identity] = snapshot;
        } on Object {
          // A stale diagnostic record must not block the durable library.
        }
      }
      _homeLog(
        'download-snapshot-refresh-fallback-complete '
        'entries=${requested.length} snapshots=${snapshots.length} '
        'durationMs=${_homeStartupClock.elapsedMilliseconds - startedAt}',
      );
    }
    if (_closed || !identical(service, chapterDownloads)) {
      return;
    }
    final nextOrphaned = List<ImportedLibraryEntry>.unmodifiable(orphaned);
    final nextSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      snapshots,
    );
    final persistedChanged =
        !_samePersistedDownloadProjection(previousSnapshots, nextSnapshots) ||
        !_sameOrphanedDownloadProjection(previousOrphaned, nextOrphaned);
    _orphanedDownloadEntries = nextOrphaned;
    _downloadSnapshots = nextSnapshots;
    _recomputeVersionBaselines();
    _downloadProjectionChanges.notifyListeners();
    if (persistedChanged) {
      _scheduleSnapshotWrite();
    } else {
      _homeLog('download-snapshot-persist-skip reason=unchanged');
    }
  }

  List<ImportedLibraryEntry> _startupDownloadProjectionEntries(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    if (_snapshotLibraryRevision == null) {
      return entries.toList(growable: false);
    }
    final wanted = _persistedDownloadProjection(
      _downloadSnapshots,
    ).keys.toSet();
    if (wanted.isEmpty) return const <ImportedLibraryEntry>[];
    final selected = <String, ImportedLibraryEntry>{};
    for (final entry in <ImportedLibraryEntry>[
      ...entries,
      ..._orphanedDownloadEntries,
    ]) {
      final identity = _downloadEntryIdentity(entry);
      if (wanted.contains(identity)) {
        selected[identity] = entry;
      }
    }
    return List<ImportedLibraryEntry>.unmodifiable(selected.values);
  }

  Future<void> _refreshKnownDownloadSnapshots(
    List<ImportedLibraryEntry> requested,
  ) async {
    final service = chapterDownloads;
    final previous = _downloadSnapshots;
    final next = <String, ChapterDownloadSnapshot>{...previous};
    final startedAt = _homeStartupClock.elapsedMilliseconds;
    _homeLog(
      'download-snapshot-targeted-refresh-start entries=${requested.length}',
    );
    try {
      for (final snapshot in await service.inspectMany(requested)) {
        next[snapshot.identity] = snapshot;
      }
    } on Object {
      _homeLog('download-snapshot-targeted-refresh-bulk-failed');
      for (final entry in requested) {
        try {
          final snapshot = await service.inspect(entry);
          next[snapshot.identity] = snapshot;
        } on Object {
          // Preserve the snapshot accelerator's last known projection for an
          // individual stale entry; management UI can diagnose it explicitly.
        }
      }
    }
    if (_closed || !identical(service, chapterDownloads)) return;
    final nextSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      next,
    );
    final persistedChanged = !_samePersistedDownloadProjection(
      previous,
      nextSnapshots,
    );
    _homeLog(
      'download-snapshot-targeted-refresh-complete '
      'entries=${requested.length} changed=$persistedChanged '
      'durationMs=${_homeStartupClock.elapsedMilliseconds - startedAt}',
    );
    if (!persistedChanged) {
      _homeLog('download-snapshot-persist-skip reason=unchanged');
      return;
    }
    _downloadSnapshots = nextSnapshots;
    _recomputeVersionBaselines();
    _downloadProjectionChanges.notifyListeners();
    _scheduleSnapshotWrite();
  }

  Future<void> _refreshDownloadSnapshotsAfterFrame(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    // A revision-matched Home snapshot already contains every manual/auto-cache
    // download summary needed by Home. Revalidate only those identities here;
    // orphan discovery and the all-library management projection belong to the
    // Download Manager. Without a trustworthy snapshot, retain one full
    // recovery reconcile.
    final hasTrustedSnapshot = _snapshotLibraryRevision != null;
    final requested = _startupDownloadProjectionEntries(entries);
    if (requested.isEmpty) {
      _homeLog(
        'download-snapshot-startup-refresh-skip '
        'reason=no-persisted-downloads trusted=$hasTrustedSnapshot',
      );
      return;
    }
    final waitForFrame = waitForPrimaryFrame;
    if (waitForFrame == null) {
      await Future<void>.delayed(Duration.zero);
    } else {
      await waitForFrame();
      if (_closed) return;
      await waitForFrame();
    }
    if (_closed) return;
    if (hasTrustedSnapshot) {
      await _refreshKnownDownloadSnapshots(requested);
    } else {
      await refreshDownloadSnapshots(requested);
    }
  }

  void refreshWholeComicSnapshot() {
    _acceptWholeComicQueueSnapshot(wholeComicDownloads.snapshot);
  }

  /// Writes the current Home projection against the latest durable revision,
  /// then waits until that checkpoint has reached the snapshot store.
  ///
  /// Whole-App teardown calls this only after Reader progress checkpoints have
  /// been flushed to SQLite. Scheduling a fresh write here is intentional: the
  /// durable progress flush may advance the projection revision without any
  /// additional Home mutation to trigger the ordinary write-through path.
  Future<void> checkpointSnapshot() async {
    if (!persistSnapshot || snapshotStore == null || _closed) return;
    final startedAt = _homeStartupClock.elapsedMilliseconds;
    _homeLog('snapshot-checkpoint-start');
    _scheduleSnapshotWrite();
    await flushSnapshotWrites();
    _homeLog(
      'snapshot-checkpoint-complete durationMs='
      '${_homeStartupClock.elapsedMilliseconds - startedAt}',
    );
  }

  /// Waits for every Home projection snapshot already admitted by this owner.
  Future<void> flushSnapshotWrites() async {
    if (!persistSnapshot || snapshotStore == null) return;
    final startedAt = _homeStartupClock.elapsedMilliseconds;
    _homeLog('snapshot-flush-start');
    while (true) {
      final tail = _snapshotWriteTail;
      await tail;
      if (identical(tail, _snapshotWriteTail)) {
        _homeLog(
          'snapshot-flush-complete durationMs='
          '${_homeStartupClock.elapsedMilliseconds - startedAt}',
        );
        return;
      }
    }
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

  @override
  void dispose() {
    _closed = true;
    _downloadSubscription.cancel();
    _wholeComicSubscription.cancel();
    _downloadProjectionChanges.dispose();
    super.dispose();
  }

  void _publish() {
    if (!_closed) {
      notifyListeners();
    }
  }

  void _acceptWholeComicQueueSnapshot(WholeComicQueueSnapshot snapshot) {
    if (_closed) {
      return;
    }
    _wholeComicQueueSnapshot = snapshot;
    _downloadProjectionChanges.notifyListeners();
  }

  Future<int?> _readLibraryProjectionRevision() async {
    final candidate = library;
    if (candidate is! ImportedLibraryRevisionStore) {
      _homeLog('projection-revision-unavailable reason=store-unsupported');
      return null;
    }
    try {
      final revisionStore = candidate as ImportedLibraryRevisionStore;
      return await revisionStore.libraryProjectionRevision;
    } on Object {
      // Revision metadata is an optimization. A failed optional read must
      // fall back to the authoritative projection reconciliation.
      _homeLog('projection-revision-unavailable reason=read-failed');
      return null;
    }
  }

  String? _activeSourceIdForCurrentSources() =>
      _activeSourceIdFor(_sourcePreferences, current: _activeSourceId);

  String? _activeSourceIdFor(
    Map<String, ComicSourcePreference> preferences, {
    required String? current,
  }) {
    final enabled =
        sources
            .where((source) => preferences[source.sourceId]?.enabled ?? true)
            .toList(growable: false)
          ..sort(
            (left, right) => (preferences[left.sourceId]?.sortOrder ?? 0)
                .compareTo(preferences[right.sourceId]?.sortOrder ?? 0),
          );
    return enabled.any((source) => source.sourceId == current)
        ? current
        : (enabled.isEmpty ? null : enabled.first.sourceId);
  }

  void _scheduleSnapshotWrite() {
    if (_closed || !persistSnapshot) {
      return;
    }
    final store = snapshotStore;
    if (store == null) {
      return;
    }
    _homeLog(
      'snapshot-write-scheduled entries=${_entries.length} '
      'saved=${_savedComics.length} readStates=${_readStates.length}',
    );
    final operation = _snapshotWriteTail.then<void>((_) async {
      if (_closed) {
        return;
      }
      final startedAt = _homeStartupClock.elapsedMilliseconds;
      _homeLog('snapshot-write-start');
      final libraryRevision = await _traceStartupOperation<int?>(
        'snapshot-write-revision-read',
        _readLibraryProjectionRevision,
        summary: (revision) => 'revision=${revision ?? 'none'}',
      );
      if (_closed) {
        return;
      }
      final snapshot = HomeProjectionSnapshot(
        entries: List<ImportedLibraryEntry>.unmodifiable(_entries),
        savedComics: List<SavedComicRecord>.unmodifiable(_savedComics),
        categories: List<LibraryCategory>.unmodifiable(_categories),
        preferences: List<ComicPreference>.unmodifiable(_preferences.values),
        readStates: List<ChapterReadState>.unmodifiable(_readStates.values),
        sourcePreferences: List<ComicSourcePreference>.unmodifiable(
          _sourcePreferences.values,
        ),
        versionRelations: List<ComicVersionRelation>.unmodifiable(
          _versionRelations,
        ),
        orphanedDownloadEntries: List<ImportedLibraryEntry>.unmodifiable(
          _orphanedDownloadEntries,
        ),
        chapterDownloads: <HomeChapterDownloadSummary>[
          ..._downloadSnapshots.values
              .where(
                (snapshot) =>
                    snapshot.isManualDownload || snapshot.hasAutoCache,
              )
              .map(_downloadSummary),
        ],
        libraryRevision: libraryRevision,
      );
      await store.write(snapshot);
      _homeLog(
        'snapshot-write-complete ${_snapshotSummary(snapshot)} '
        'durationMs=${_homeStartupClock.elapsedMilliseconds - startedAt}',
      );
    });
    _snapshotWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      operation.catchError((Object error, StackTrace _) {
        _homeLog('snapshot-write-failed errorType=${error.runtimeType}');
      }),
    );
  }

  void _homeLog(String message) {
    debugPrint(
      '[zic-home] elapsedMs=${_homeStartupClock.elapsedMilliseconds} $message',
    );
  }

  Future<T> _traceStartupOperation<T>(
    String stage,
    Future<T> Function() operation, {
    String Function(T value)? summary,
  }) async {
    final startedAt = _homeStartupClock.elapsedMilliseconds;
    _homeLog('$stage-start');
    try {
      final value = await operation();
      final detail = summary == null ? '' : ' ${summary(value)}';
      _homeLog(
        '$stage-complete durationMs='
        '${_homeStartupClock.elapsedMilliseconds - startedAt}$detail',
      );
      return value;
    } on Object catch (error) {
      _homeLog(
        '$stage-failed durationMs='
        '${_homeStartupClock.elapsedMilliseconds - startedAt} '
        'errorType=${error.runtimeType}',
      );
      rethrow;
    }
  }

  String _snapshotSummary(HomeProjectionSnapshot snapshot) =>
      'present=true entries=${snapshot.entries.length} '
      'saved=${snapshot.savedComics.length} '
      'categories=${snapshot.categories.length} '
      'preferences=${snapshot.preferences.length} '
      'readStates=${snapshot.readStates.length} '
      'sourcePreferences=${snapshot.sourcePreferences.length} '
      'versionRelations=${snapshot.versionRelations.length} '
      'orphanedDownloads=${snapshot.orphanedDownloadEntries.length} '
      'chapterDownloads=${snapshot.chapterDownloads.length} '
      'revision=${snapshot.libraryRevision ?? 'none'}';
}

bool defaultComicSourceEnabled(
  BrowsableComicSource source, {
  required Set<String> defaultLanguages,
}) {
  if (!source.sourceId.startsWith('mihon:')) return true;
  return defaultLanguages.contains(source.descriptor.language.toLowerCase());
}
