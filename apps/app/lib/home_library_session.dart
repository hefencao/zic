import 'dart:async';
import 'dart:collection';
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

String _versionAuthorityEntryKey(ImportedLibraryEntry entry) =>
    '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}'
    '\u0000${entry.chapter.chapterId}';

bool _samePersistedChapterPayload(
  ImportedChapterRecord left,
  ImportedChapterRecord right,
) {
  if (identical(left, right)) return true;
  // Compare all persisted values without encoding opaque request carriers or
  // constructing a fresh manifest. Mutable progress is read back separately.
  if (left.directoryId != right.directoryId ||
      left.displayName != right.displayName ||
      left.sourceId != right.sourceId ||
      left.comicId != right.comicId ||
      left.chapterId != right.chapterId ||
      left.sourceRevision != right.sourceRevision ||
      left.comicTitle != right.comicTitle ||
      !listEquals(left.comicAuthors, right.comicAuthors) ||
      !listEquals(left.comicTags, right.comicTags) ||
      left.comicDescription != right.comicDescription ||
      left.coverSourceId != right.coverSourceId ||
      left.coverMediaFormat != right.coverMediaFormat ||
      left.coverAnimatedHint != right.coverAnimatedHint ||
      left.sequence != right.sequence ||
      left.readingDirection != right.readingDirection ||
      left.sourceUpdatedAt?.toUtc() != right.sourceUpdatedAt?.toUtc() ||
      left.importedAt != right.importedAt ||
      left.pages.length != right.pages.length) {
    return false;
  }
  for (var index = 0; index < left.pages.length; index++) {
    final a = left.pages[index];
    final b = right.pages[index];
    if (identical(a, b)) continue;
    if (a.displayName != b.displayName ||
        a.sourceId != b.sourceId ||
        a.contentKindHint != b.contentKindHint ||
        a.pageId != b.pageId ||
        a.mediaFormat != b.mediaFormat ||
        a.byteLength != b.byteLength ||
        a.checksum != b.checksum ||
        a.checksumAlgorithm != b.checksumAlgorithm ||
        a.animatedHint != b.animatedHint) {
      return false;
    }
  }
  return true;
}

bool _sameSourceInstances(
  List<BrowsableComicSource> left,
  List<BrowsableComicSource> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

final class _VersionReusePageObservation {
  const _VersionReusePageObservation({
    required this.id,
    required this.identity,
  });

  final DownloadId id;
  final String identity;

  int? get pageIndex => id.pageIndexHint;
}

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
      exactCompletedPages: snapshot.exactCompletedPages,
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
    exactCompletedPages: summary.exactCompletedPages,
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
/// services. Updating this object does not rebuild MaterialApp or HomeShell;
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
    if (chapterDownloadRelay == relay) {
      return;
    }
    chapterDownloadRelay = relay;
    notifyListeners();
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
/// in HomeShell; storage loading and service lifecycle do not.
final class HomeLibrarySession extends ChangeNotifier {
  HomeLibrarySession({
    required this.library,
    required this.chapterDownloads,
    ChapterDownloadTransferRuntimeProvider? downloadComposition,
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
  })  : downloadComposition = resolveDownloadComposition(
            chapterDownloads,
            downloadComposition,
          ),
        _sources = List<BrowsableComicSource>.unmodifiable(sources) {
    _downloadSubscription = chapterDownloads.changes.listen(
      acceptDownloadSnapshot,
    );
    _wholeComicSubscription = wholeComicDownloads.changes.listen((snapshot) {
      _acceptWholeComicQueueSnapshot(snapshot);
    });
    _wholeComicQueueSnapshot = wholeComicDownloads.snapshot;
    _ready = _initialize();
  }

  static ChapterDownloadTransferRuntimeProvider? resolveDownloadComposition(
    ChapterDownloadService chapterDownloads,
    ChapterDownloadTransferRuntimeProvider? explicit,
  ) =>
      explicit ??
      (chapterDownloads is ChapterDownloadTransferRuntimeProvider
          ? chapterDownloads as ChapterDownloadTransferRuntimeProvider
          : null);

  ImportedLibraryStore library;
  ChapterDownloadService chapterDownloads;
  ChapterDownloadTransferRuntimeProvider? downloadComposition;
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
  /// UI isolate; explicit user changes still persist through HomeShell.
  final bool persistMissingPreferences;
  final Future<void> Function()? waitForPrimaryFrame;
  final HomeStartupTelemetry? startupTelemetry;

  late StreamSubscription<ChapterDownloadSnapshot> _downloadSubscription;
  late StreamSubscription<WholeComicQueueSnapshot> _wholeComicSubscription;
  late Future<void> _ready;
  Future<void> get ready => _ready;
  Future<void>? _serviceAdoption;
  Future<void>? _libraryReload;
  Future<void>? _downloadProjectionRefresh;
  ChapterDownloadService? _downloadProjectionRefreshService;
  Future<void>? _downloadCacheProjectionRefresh;
  ChapterDownloadService? _downloadCacheProjectionRefreshService;
  var _downloadManagementProjectionEpoch = 0;
  final Map<Future<void>, ChapterDownloadService> _downloadProjectionReads =
      <Future<void>, ChapterDownloadService>{};

  List<ImportedLibraryEntry> _entries = const <ImportedLibraryEntry>[];
  final Map<String, ImportedLibraryEntry> _versionAuthorityHydratedEntries =
      <String, ImportedLibraryEntry>{};
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
  Map<String, VersionChapterCanonicalProjection> _canonicalMediaProjections =
      const <String, VersionChapterCanonicalProjection>{};
  ComicVersionCanonicalMediaLedger _canonicalMediaLedger =
      ComicVersionCanonicalMediaLedger();
  Future<void> _canonicalMediaWriteTail = Future<void>.value();
  Future<void> _canonicalPhysicalBackfillTail = Future<void>.value();
  String? _canonicalPhysicalBackfillFingerprint;
  ComicVersionBaselineProjection _versionBaselines =
      ComicVersionBaselineProjection.empty;
  Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      const <String, ChapterDownloadSnapshot>{};
  ChapterCacheManagementProjection? _downloadCacheProjection;
  late WholeComicQueueSnapshot _wholeComicQueueSnapshot;
  final ChangeNotifier _downloadProjectionChanges = ChangeNotifier();
  final ChangeNotifier _libraryGenerationChanges = ChangeNotifier();
  Object? _error;
  bool _loading = true;
  String? _activeSourceId;
  bool _closed = false;
  Future<void>? _closing;
  int _activeAdmissions = 0;
  Completer<void>? _admissionsDrained;
  int _libraryProjectionRevision = 0;
  int? _snapshotLibraryRevision;
  bool _snapshotRewriteNeeded = false;
  Future<void> _snapshotWriteTail = Future<void>.value();
  Future<void> _versionEvidenceWriteTail = Future<void>.value();
  final LinkedHashMap<String, _VersionReusePageObservation>
      _versionReuseIdentityObservations =
      LinkedHashMap<String, _VersionReusePageObservation>();
  static const int _versionReuseObservationLimit = 1024;
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
  ChapterCacheManagementProjection? get downloadCacheProjection =>
      _downloadCacheProjection;
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
  Listenable get libraryGenerationChanges => _libraryGenerationChanges;
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

  void _recomputeVersionBaselines({bool refreshAuthority = true}) {
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
      cacheReuseComics: <ComicVersionIdentity>[
        for (final entry in <ImportedLibraryEntry>[
          ..._entries,
          ..._orphanedDownloadEntries,
        ])
          ComicVersionIdentity(
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
          ),
      ],
    );
    // Manual/export consumers receive only predecessor -> current download-head
    // mappings. Artifact cache/hot reuse instead receives compact direct
    // projections composed between versions that have actually materialized.
    chapterDownloads.updateVersionBaselines(
      _versionBaselines.downloadHeadRelations,
    );
    chapterDownloads.updateCacheVersionRelations(
      _versionBaselines.cacheReuseRelations,
    );
    if (refreshAuthority) {
      _refreshVersionReuseAuthority();
    }
  }

  ChapterDownloadTransferRuntimeProvider? get _downloadCompositionProvider =>
      downloadComposition;

  Future<List<VersionChapterCanonicalProjection>>
      _queryCanonicalMediaProjections() async {
    final provider = _downloadCompositionProvider;
    if (provider == null) {
      return const <VersionChapterCanonicalProjection>[];
    }
    return provider.artifactStore.loadCanonicalMediaProjections();
  }

  void _replaceCanonicalMediaProjections(
    Iterable<VersionChapterCanonicalProjection> projections, {
    bool refreshAuthority = true,
  }) {
    final values = projections.toList(growable: false);
    _canonicalMediaLedger = ComicVersionCanonicalMediaLedger(
      projections: values,
    );
    _canonicalMediaProjections =
        Map<String, VersionChapterCanonicalProjection>.unmodifiable(
      <String, VersionChapterCanonicalProjection>{
        for (final projection in values) projection.exactKey: projection,
      },
    );
    if (refreshAuthority) {
      _refreshCanonicalMediaAuthority();
    }
  }

  Future<void> _assimilateCanonicalMediaRelation(
    ComicVersionRelation relation,
  ) =>
      _assimilateCanonicalMediaRelations(<ComicVersionRelation>[relation]);

  Future<void> _assimilateCanonicalMediaRelations(
    Iterable<ComicVersionRelation> relations, {
    bool awaitPhysicalBackfill = true,
  }) async {
    final captured = relations.toList(growable: false);
    final queuedAtMs = _homeStartupClock.elapsedMilliseconds;
    final operation = _canonicalMediaWriteTail.then((_) {
      final waitMs = _homeStartupClock.elapsedMilliseconds - queuedAtMs;
      if (waitMs > 0) {
        _homeLog(
          'canonical-media-write-tail-acquired waitMs=$waitMs '
          'relations=${captured.length}',
        );
      }
      return _assimilateCanonicalMediaRelationsNow(captured);
    });
    _canonicalMediaWriteTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final result = await operation;
    if (awaitPhysicalBackfill) {
      await result.backfill;
    }
  }

  Future<({Future<void> backfill})> _assimilateCanonicalMediaRelationsNow(
    Iterable<ComicVersionRelation> relations,
  ) async {
    final provider = _downloadCompositionProvider;
    if (provider == null) {
      return (backfill: Future<void>.value(),);
    }
    final mergeStartedAtMs = _homeStartupClock.elapsedMilliseconds;
    final nextLedger = ComicVersionCanonicalMediaLedger(
      projections: _canonicalMediaLedger.projections,
    );
    final affected = <String, VersionChapterCanonicalProjection>{};
    var conflictCount = 0;
    for (final relation in relations) {
      for (final mapping in relation.pageMappings) {
        final predecessorRevision = mapping.predecessorSourceRevision;
        final successorRevision = mapping.successorSourceRevision;
        final verifiedIntervals = mapping.effectiveVerifiedIntervals;
        if (predecessorRevision == null ||
            successorRevision == null ||
            verifiedIntervals.isEmpty) {
          continue;
        }
        final predecessor = _versionAuthorityEntryFor(
          relation.sourceId,
          relation.predecessorComicId,
          mapping.predecessorChapterId,
        );
        final successor = _versionAuthorityEntryFor(
          relation.sourceId,
          relation.successorComicId,
          mapping.successorChapterId,
        );
        if (predecessor == null || successor == null) continue;
        if (predecessor.chapter.sourceRevision != predecessorRevision ||
            successor.chapter.sourceRevision != successorRevision ||
            predecessor.chapter.pages.length != mapping.predecessorPageCount ||
            successor.chapter.pages.length != mapping.successorPageCount) {
          continue;
        }
        final result = nextLedger.mergeVerifiedMapping(
          sourceId: relation.sourceId,
          predecessorComicId: relation.predecessorComicId,
          successorComicId: relation.successorComicId,
          predecessorChapterId: mapping.predecessorChapterId,
          successorChapterId: mapping.successorChapterId,
          predecessorSourceRevision: predecessorRevision,
          successorSourceRevision: successorRevision,
          predecessorPageCount: mapping.predecessorPageCount,
          successorPageCount: mapping.successorPageCount,
          verifiedIntervals: verifiedIntervals,
        );
        if (result.predecessorChanged) {
          affected[result.predecessor.exactKey] = result.predecessor;
        }
        if (result.successorChanged) {
          affected[result.successor.exactKey] = result.successor;
        }
        conflictCount += result.conflicts.length;
      }
    }
    final mergeMs = _homeStartupClock.elapsedMilliseconds - mergeStartedAtMs;
    if (affected.isEmpty) {
      if (mergeMs > 0) {
        _homeLog(
          'canonical-media-merge-complete durationMs=$mergeMs '
          'relations=${relations.length} affected=0 conflicts=$conflictCount',
        );
      }
      return (backfill: Future<void>.value(),);
    }
    _homeLog(
      'canonical-media-merge-complete durationMs=$mergeMs '
      'relations=${relations.length} affected=${affected.length} '
      'conflicts=$conflictCount',
    );

    // Preserve the existing durable-authority contract: derived canonical
    // projection persistence must succeed before the in-memory ledger/runtime
    // advances. Reader latency is decoupled only from the historical physical
    // ready/partial backfill that follows this published authority.
    final persistStartedAtMs = _homeStartupClock.elapsedMilliseconds;
    await provider.artifactStore.persistCanonicalMediaProjections(
      affected.values,
    );
    _homeLog(
      'canonical-media-projection-persist-complete '
      'durationMs=${_homeStartupClock.elapsedMilliseconds - persistStartedAtMs} '
      'affected=${affected.length}',
    );
    _canonicalMediaLedger = nextLedger;
    _canonicalMediaProjections =
        Map<String, VersionChapterCanonicalProjection>.unmodifiable(
      <String, VersionChapterCanonicalProjection>{
        for (final projection in nextLedger.projections)
          projection.exactKey: projection,
      },
    );
    _refreshCanonicalMediaAuthority();
    final backfill = _canonicalPhysicalBackfillTail;
    if (conflictCount > 0) {
      _homeLog(
        'canonical-media-assimilation-conflict conflicts=$conflictCount',
      );
    }
    return (backfill: backfill,);
  }

  Future<void> _assimilateCanonicalMediaForEntries(
    Iterable<ImportedLibraryEntry> entries, {
    bool awaitPhysicalBackfill = true,
  }) async {
    final changedComics = <String>{
      for (final entry in entries)
        comicLibraryIdentity(entry.chapter.sourceId, entry.chapter.comicId),
    };
    if (changedComics.isEmpty) return;
    final relations = <ComicVersionRelation>[
      for (final relation in _versionRelations)
        if (changedComics.contains(
              comicLibraryIdentity(
                relation.sourceId,
                relation.predecessorComicId,
              ),
            ) ||
            changedComics.contains(
              comicLibraryIdentity(
                relation.sourceId,
                relation.successorComicId,
              ),
            ))
          relation,
    ];
    if (relations.isEmpty) return;
    await _assimilateCanonicalMediaRelations(
      relations,
      awaitPhysicalBackfill: awaitPhysicalBackfill,
    );
  }

  Map<String, ImportedLibraryEntry> _versionAuthorityEntriesByKey() =>
      Map<String, ImportedLibraryEntry>.of(_versionAuthorityHydratedEntries);

  void _refreshVersionPageAuthority() {
    _refreshCanonicalMediaAuthority();
    _refreshVersionReuseAuthority();
  }

  void _refreshCanonicalMediaAuthority() {
    final provider = _downloadCompositionProvider;
    if (provider == null) return;
    final refreshStartedAtMs = _homeStartupClock.elapsedMilliseconds;
    final runtime = provider.transferRuntime;
    final entriesByKey = _versionAuthorityEntriesByKey();
    final activeProjectionRanges =
        canonicalMediaActiveRangesFromRelations(_versionRelations);
    final canonicalAuthorities = <CanonicalMediaChapterAuthority>[];
    for (final entry in entriesByKey.values) {
      final manifest = entry.chapter.toManifest();
      final exactKey = canonicalMediaExactChapterKey(
        sourceId: manifest.sourceId,
        comicId: manifest.comicId,
        chapterId: manifest.chapter.chapterId,
        sourceRevision: manifest.chapter.sourceRevision,
      );
      final storedProjection = _canonicalMediaProjections[exactKey];
      final projection = storedProjection != null &&
              storedProjection.pageCount == manifest.pages.length
          ? storedProjection
          : null;
      final ranges = <CanonicalMediaActiveRange>[
        for (final range in activeProjectionRanges[exactKey] ??
            const <CanonicalMediaActiveRange>[])
          if (range.endExclusive <= manifest.pages.length) range,
      ];
      canonicalAuthorities.add(
        CanonicalMediaChapterAuthority(
          manifest: manifest,
          projection: projection,
          activeProjectionRanges: ranges,
        ),
      );
    }
    final builtAtMs = _homeStartupClock.elapsedMilliseconds;
    runtime.replaceCanonicalMediaAuthorityScope(
      'library-canonical-media',
      canonicalAuthorities,
    );
    final publishedAtMs = _homeStartupClock.elapsedMilliseconds;
    _scheduleCanonicalPhysicalBackfill(provider, canonicalAuthorities);
    final completedAtMs = _homeStartupClock.elapsedMilliseconds;
    final totalMs = completedAtMs - refreshStartedAtMs;
    _homeLog(
      'canonical-media-authority-refresh-complete totalMs=$totalMs '
      'buildMs=${builtAtMs - refreshStartedAtMs} '
      'publishMs=${publishedAtMs - builtAtMs} '
      'backfillScheduleMs=${completedAtMs - publishedAtMs} '
      'entries=${entriesByKey.length} authorities=${canonicalAuthorities.length}',
    );
  }

  void _refreshVersionReuseAuthority() {
    final provider = _downloadCompositionProvider;
    if (provider == null) return;
    final refreshStartedAtMs = _homeStartupClock.elapsedMilliseconds;
    final runtime = provider.transferRuntime;
    final entriesByKey = _versionAuthorityEntriesByKey();
    final resolvers = <String, VersionPageReuseResolver>{};
    for (final relation in _versionBaselines.cacheReuseRelations) {
      for (final mapping in relation.pageMappings) {
        if (mapping.effectiveVerifiedIntervals.isEmpty ||
            mapping.predecessorSourceRevision == null ||
            mapping.successorSourceRevision == null) {
          continue;
        }
        final predecessor = entriesByKey[
            '${relation.sourceId}\u0000${relation.predecessorComicId}\u0000${mapping.predecessorChapterId}'];
        final successor = entriesByKey[
            '${relation.sourceId}\u0000${relation.successorComicId}\u0000${mapping.successorChapterId}'];
        if (predecessor == null || successor == null) continue;
        final predecessorManifest = predecessor.chapter.toManifest();
        final successorManifest = successor.chapter.toManifest();
        if (predecessorManifest.pages.length != mapping.predecessorPageCount ||
            successorManifest.pages.length != mapping.successorPageCount ||
            predecessorManifest.chapter.sourceRevision !=
                mapping.predecessorSourceRevision ||
            successorManifest.chapter.sourceRevision !=
                mapping.successorSourceRevision) {
          continue;
        }
        final predecessorToSuccessor =
            VerifiedArtifactReuseResolver.predecessorToSuccessor(
          predecessorChapter: predecessorManifest,
          successorChapter: successorManifest,
          verifiedIntervals: mapping.effectiveVerifiedIntervals,
        );
        final successorToPredecessor = VerifiedArtifactReuseResolver(
          targetChapter: successorManifest,
        );
        for (final interval in mapping.effectiveVerifiedIntervals) {
          successorToPredecessor.addVerifiedInterval(
            sourceChapter: predecessorManifest,
            sourceStart: interval.predecessorStart,
            sourceEndExclusive: interval.predecessorEndExclusive,
            targetOffsetFromSource: interval.successorOffset,
          );
        }
        if (predecessorToSuccessor.relationCount == 0 ||
            successorToPredecessor.relationCount == 0) {
          continue;
        }
        final key =
            '${relation.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}'
            '\u0000${mapping.predecessorChapterId}\u0000${mapping.successorChapterId}';
        resolvers['$key:forward'] = predecessorToSuccessor.resolve;
        resolvers['$key:reverse'] = successorToPredecessor.resolve;
      }
    }
    final builtAtMs = _homeStartupClock.elapsedMilliseconds;
    runtime.versionPageAuthority.replaceScope(
      'library-version-relations',
      resolvers,
    );
    final completedAtMs = _homeStartupClock.elapsedMilliseconds;
    final totalMs = completedAtMs - refreshStartedAtMs;
    if (totalMs > 0) {
      _homeLog(
        'version-reuse-authority-refresh-complete totalMs=$totalMs '
        'buildMs=${builtAtMs - refreshStartedAtMs} '
        'publishMs=${completedAtMs - builtAtMs} '
        'entries=${entriesByKey.length} resolvers=${resolvers.length}',
      );
    }
  }

  void _scheduleCanonicalPhysicalBackfill(
    ChapterDownloadTransferRuntimeProvider provider,
    List<CanonicalMediaChapterAuthority> authorities,
  ) {
    final ordered = authorities.toList(growable: false)
      ..sort((left, right) => left.exactKey.compareTo(right.exactKey));
    final fingerprint = StringBuffer();
    for (final authority in ordered) {
      fingerprint
        ..write(authority.exactKey)
        ..write('|')
        ..write(authority.manifest.pages.length)
        ..write('|');
      final projection = authority.projection;
      if (projection != null) {
        fingerprint
          ..write(projection.familyId.value)
          ..write('|')
          ..write(projection.canonicalChapterId.value)
          ..write('|');
        for (final interval in projection.intervals) {
          fingerprint
            ..write(interval.exactStart)
            ..write(':')
            ..write(interval.exactEndExclusive)
            ..write(':')
            ..write(interval.segmentId.value)
            ..write(':')
            ..write(interval.segmentStart)
            ..write(';');
        }
      }
      fingerprint.write('|active=');
      for (final range in authority.activeProjectionRanges) {
        fingerprint
          ..write(range.start)
          ..write(':')
          ..write(range.endExclusive)
          ..write(';');
      }
      fingerprint.write('\n');
    }
    final nextFingerprint = fingerprint.toString();
    if (_canonicalPhysicalBackfillFingerprint == nextFingerprint) return;
    _canonicalPhysicalBackfillFingerprint = nextFingerprint;

    final captured = List<CanonicalMediaChapterAuthority>.unmodifiable(ordered);
    final previous = _canonicalPhysicalBackfillTail;
    late final Future<void> operation;
    operation = previous.then((_) async {
      if (_closed) return;
      if (!identical(_downloadCompositionProvider, provider)) {
        if (_canonicalPhysicalBackfillFingerprint == nextFingerprint) {
          _canonicalPhysicalBackfillFingerprint = null;
        }
        return;
      }
      try {
        final bound =
            await provider.artifactStore.backfillCanonicalReadyArtifacts(captured);
        final migratedPartials =
            await provider.artifactStore.backfillCanonicalPartials(captured);
        if (bound > 0 || migratedPartials > 0) {
          _homeLog(
            'canonical-physical-backfill-complete '
            'ready=$bound partials=$migratedPartials',
          );
        }
      } on Object catch (error) {
        if (_canonicalPhysicalBackfillFingerprint == nextFingerprint) {
          _canonicalPhysicalBackfillFingerprint = null;
        }
        _homeLog('canonical-physical-backfill-failed error=$error');
      }
    });
    _canonicalPhysicalBackfillTail = operation;
    unawaited(operation);
  }

  ImportedLibraryEntry? versionAuthorityEntry({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) {
    final key = '$sourceId\u0000$comicId\u0000$chapterId';
    final hydrated = _versionAuthorityHydratedEntries[key];
    if (hydrated != null) return hydrated;
    for (final entry in _entries) {
      if (_versionAuthorityEntryKey(entry) == key &&
          !chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter)) {
        return entry;
      }
    }
    for (final entry in _orphanedDownloadEntries) {
      if (_versionAuthorityEntryKey(entry) == key &&
          !chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter)) {
        return entry;
      }
    }
    return null;
  }

  void _rememberVersionAuthorityEntries(
    Iterable<ImportedLibraryEntry> entries, {
    bool replaceChapterPayload = false,
  }) {
    var changed = false;
    for (final entry in entries) {
      if (chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter)) {
        continue;
      }
      final key = _versionAuthorityEntryKey(entry);
      final previous = _versionAuthorityHydratedEntries[key];
      if (previous?.chapter.sourceRevision == entry.chapter.sourceRevision &&
          previous?.chapter.pages.length == entry.chapter.pages.length) {
        final previousProgress = previous?.progress;
        final nextProgress = entry.progress;
        final latestProgress = previousProgress != null &&
                (nextProgress == null ||
                    previousProgress.updatedAt.isAfter(nextProgress.updatedAt))
            ? previousProgress
            : nextProgress;
        if (replaceChapterPayload) {
          // A source upsert carries a fully materialized chapter. Its provider
          // request locators may legitimately change without a revision/count
          // change (notably Venera resource carriers), so it must replace the
          // version/media authority payload while preserving newer progress.
          _versionAuthorityHydratedEntries[key] = latestProgress == null
              ? entry
              : entry.copyWith(progress: latestProgress);
          // The same persisted chapter may be reloaded at every boundary.
          // Compare its full payload, not just revision/count: a changed
          // request carrier still has to replace media authority.
          changed = changed ||
              !_samePersistedChapterPayload(previous!.chapter, entry.chapter);
          continue;
        }
        // Ordinary Home/snapshot projection updates may be compact. Preserve
        // the cached full chapter while advancing only its progress; otherwise
        // a compact entry could erase the manifest used by Reader authority.
        if (previous != null && latestProgress != previousProgress) {
          _versionAuthorityHydratedEntries[key] =
              previous.copyWith(progress: latestProgress);
        }
        continue;
      }
      _versionAuthorityHydratedEntries[key] = entry;
      changed = true;
    }
    if (changed) _refreshVersionPageAuthority();
  }

  void _forgetVersionAuthorityChapter(String sourceId, String chapterId) {
    final keys = _versionAuthorityHydratedEntries.entries
        .where((entry) =>
            entry.value.chapter.sourceId == sourceId &&
            entry.value.chapter.chapterId == chapterId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final key in keys) {
      _versionAuthorityHydratedEntries.remove(key);
    }
    // The visible `_entries` projection may have changed even when this
    // chapter was never in the hydration-only cache. Always republish the
    // compact scope after a chapter removal.
    _refreshVersionPageAuthority();
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

  Future<void> reload({bool waitForOpen = true}) =>
      _runAdmittedOperation(
        () => _runLibraryReload(
          waitForReady: waitForOpen,
          openLibrary: false,
        ),
      );

  Future<void> _runLibraryReload({
    required bool waitForReady,
    required bool openLibrary,
  }) {
    final readyAtAdmission = _ready;
    final reloadAtAdmission = _libraryReload;
    final adoptionAtAdmission = _serviceAdoption;
    late final Future<void> operation;
    operation = (() async {
      if (waitForReady) {
        await readyAtAdmission;
      }
      if (reloadAtAdmission != null) {
        await reloadAtAdmission;
      }
      if (adoptionAtAdmission != null) {
        await adoptionAtAdmission;
        // Adoption now releases bindings before Home reconciliation. Join the
        // newly installed projection tail, not just the pre-adoption ready.
        await _ready;
      }
      if (openLibrary) {
        await library.open();
      }
      await _reload(publishPrimary: false);
    })().whenComplete(() {
      if (identical(_libraryReload, operation)) {
        _libraryReload = null;
      }
    });
    _libraryReload = operation;
    return operation;
  }

  /// Replaces the bootstrap-only services without replacing the Home widget.
  ///
  /// Completes when runtime bindings and durable version authority are usable,
  /// and previously owned services have retired. Home projection reconciliation
  /// continues through [ready]; capability consumers must not join an unrelated
  /// full-library reload merely to access the adopted services.
  Future<void> adoptServices({
    required ImportedLibraryStore library,
    required ChapterDownloadService chapterDownloads,
    ChapterDownloadTransferRuntimeProvider? downloadComposition,
    required WholeComicDownloadQueue wholeComicDownloads,
    required List<BrowsableComicSource> sources,
    required bool persistSnapshot,
  }) =>
      _runAdmittedOperation(
        () => _admitServices(
          library: library,
          chapterDownloads: chapterDownloads,
          downloadComposition: downloadComposition,
          wholeComicDownloads: wholeComicDownloads,
          sources: sources,
          persistSnapshot: persistSnapshot,
        ),
      );

  Future<void> _admitServices({
    required ImportedLibraryStore library,
    required ChapterDownloadService chapterDownloads,
    required ChapterDownloadTransferRuntimeProvider? downloadComposition,
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
          downloadComposition: downloadComposition,
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
    required ChapterDownloadTransferRuntimeProvider? downloadComposition,
    required WholeComicDownloadQueue wholeComicDownloads,
    required List<BrowsableComicSource> sources,
    required bool persistSnapshot,
  }) async {
    final resolvedDownloadComposition = resolveDownloadComposition(
      chapterDownloads,
      downloadComposition,
    );
    final bindingStartedAt = startupTelemetry?.nowMicros();
    final previousReady = _ready;
    final reloadAtAdmission = _libraryReload;
    await previousReady;
    if (reloadAtAdmission != null) {
      await reloadAtAdmission;
    }
    if (_closed) {
      return;
    }
    if (identical(this.library, library) &&
        identical(this.chapterDownloads, chapterDownloads) &&
        identical(this.downloadComposition, resolvedDownloadComposition) &&
        identical(this.wholeComicDownloads, wholeComicDownloads)) {
      this.persistSnapshot = persistSnapshot;
      if (!_sameSourceInstances(_sources, sources)) {
        await _replaceSources(sources, reloadLibrary: false);
      }
      return;
    }

    // Resolve safety-critical authority before changing any owner. This is not
    // Home's presentation projection: stale snapshot relations must not become
    // Reader reuse proof while the full Home reload runs independently.
    await library.open();
    final canonicalMediaProjections =
        await resolvedDownloadComposition?.artifactStore
            .loadCanonicalMediaProjections() ??
        const <VersionChapterCanonicalProjection>[];
    final relationStore = library is ComicVersionRelationStore
        ? library as ComicVersionRelationStore
        : null;
    final versionRelations = await relationStore?.listAllComicVersionRelations() ??
        const <ComicVersionRelation>[];

    final previousLibrary = this.library;
    final libraryChanged = !identical(previousLibrary, library);
    final previousChapterDownloads = this.chapterDownloads;
    final previousWholeComicDownloads = this.wholeComicDownloads;
    final previousOwnsLibrary = ownsLibrary;
    final previousOwnsChapterDownloads = ownsChapterDownloads;
    final previousOwnsWholeComicDownloads = ownsWholeComicDownloads;
    await _downloadSubscription.cancel();
    await _wholeComicSubscription.cancel();

    this.library = library;
    this.chapterDownloads = chapterDownloads;
    this.downloadComposition = resolvedDownloadComposition;
    this.wholeComicDownloads = wholeComicDownloads;
    _canonicalPhysicalBackfillFingerprint = null;
    _downloadCacheProjection = null;
    _versionRelations = List<ComicVersionRelation>.unmodifiable(versionRelations);
    _replaceCanonicalMediaProjections(
      canonicalMediaProjections,
      refreshAuthority: false,
    );
    _recomputeVersionBaselines(refreshAuthority: false);
    _refreshVersionPageAuthority();
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
      await _drainDownloadProjectionReads(previousChapterDownloads);
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

    // Keep reconciliation owned and drained here, but release the runtime
    // binding handoff before scheduling unrelated Home presentation work.
    _ready = Future<void>.delayed(Duration.zero)
        .then((_) => _reconcileAdoptedServices()).then<void>(
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
    if (bindingStartedAt != null) {
      startupTelemetry?.serviceReady(
        'home-runtime-bindings',
        startedAtMicros: bindingStartedAt,
      );
    }
    _homeLog('services-bindings-ready projection=pending');
    if (!_closed && libraryChanged) {
      _libraryGenerationChanges.notifyListeners();
    }
  }

  Future<void> _reconcileAdoptedServices() async {
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

  void _replaceAuthoritativeLibraryEntries(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    final values = List<ImportedLibraryEntry>.unmodifiable(entries);
    _entries = values;
    _versionAuthorityHydratedEntries
      ..clear()
      ..addEntries(
        values.map(
          (entry) => MapEntry(_versionAuthorityEntryKey(entry), entry),
        ),
      );
  }

  void _applySnapshot(HomeProjectionSnapshot snapshot, {bool publish = true}) {
    if (_closed) {
      return;
    }
    _versionAuthorityHydratedEntries.clear();
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
    _downloadCacheProjection = null;
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
        final canonicalMediaProjections = await _traceStartupOperation<
            List<VersionChapterCanonicalProjection>>(
          'query-canonical-media-projections',
          _queryCanonicalMediaProjections,
          summary: (projections) => 'count=${projections.length}',
        );
        _replaceCanonicalMediaProjections(canonicalMediaProjections);
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
    final canonicalMediaProjectionsFuture = _traceStartupOperation<
        List<VersionChapterCanonicalProjection>>(
      'query-canonical-media-projections',
      _queryCanonicalMediaProjections,
      summary: (projections) => 'count=${projections.length}',
    );
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
    final canonicalMediaProjections = await canonicalMediaProjectionsFuture;
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
        _replaceAuthoritativeLibraryEntries(entries);
        _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
        _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
        _versionRelations = List<ComicVersionRelation>.unmodifiable(
          versionRelations,
        );
        _replaceCanonicalMediaProjections(
          canonicalMediaProjections,
          refreshAuthority: false,
        );
        _recomputeVersionBaselines(refreshAuthority: false);
        _refreshVersionPageAuthority();
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
    final projectionChangedAtPublish =
        _libraryProjectionRevision != projectionRevisionAtStart;
    if (!projectionChangedAtPublish) {
      _replaceAuthoritativeLibraryEntries(entries);
      _savedComics = List<SavedComicRecord>.unmodifiable(savedComics);
      _versionRelations = List<ComicVersionRelation>.unmodifiable(
        versionRelations,
      );
      _replaceCanonicalMediaProjections(
        canonicalMediaProjections,
        refreshAuthority: false,
      );
    }
    _categories = projectionChangedAtPublish
        ? _categories
        : List<LibraryCategory>.unmodifiable(categories);
    _preferences = Map<String, ComicPreference>.unmodifiable(
      projectionChangedAtPublish
          ? <String, ComicPreference>{...seedPreferences, ..._preferences}
          : seedPreferences,
    );
    _readStates = projectionChangedAtPublish
        ? _readStates
        : Map<String, ChapterReadState>.unmodifiable(readStates);
    _sourcePreferences = Map<String, ComicSourcePreference>.unmodifiable(
      projectionChangedAtPublish
          ? <String, ComicSourcePreference>{
              ...sourcePreferences,
              ..._sourcePreferences,
            }
          : sourcePreferences,
    );
    _recomputeVersionBaselines(refreshAuthority: false);
    _refreshVersionPageAuthority();
    _activeSourceId = _activeSourceIdFor(
      _sourcePreferences,
      current: _activeSourceId,
    );
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

  Future<void> ensureReady() => _runAdmittedOperation(_ensureReady);

  Future<void> _ensureReady() async {
    await ready;
    if (_error == null) {
      return;
    }
    await _runLibraryReload(
      waitForReady: false,
      openLibrary: true,
    );
  }

  Future<void> retry() => _runAdmittedOperation(_retry);

  Future<void> _retry() async {
    _loading = true;
    _publish();
    try {
      await _runLibraryReload(
        waitForReady: true,
        openLibrary: true,
      );
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
  Future<ImportedLibraryEntry> hydrateEntry(
    ImportedLibraryEntry entry, {
    bool awaitCanonicalPhysicalBackfill = true,
  }) =>
      _runAdmittedOperation(
        () => _hydrateEntry(
          entry,
          awaitCanonicalPhysicalBackfill:
              awaitCanonicalPhysicalBackfill,
        ),
      );

  Future<ImportedLibraryEntry> _hydrateEntry(
    ImportedLibraryEntry entry, {
    required bool awaitCanonicalPhysicalBackfill,
  }) async {
    final cached = _versionAuthorityHydratedEntries[
      _versionAuthorityEntryKey(entry)
    ];
    final requestHasSnapshotPlaceholders =
        chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter);
    if (cached != null &&
        cached.chapter.sourceRevision == entry.chapter.sourceRevision &&
        !chapterHasHomeProjectionSnapshotPagePlaceholders(cached.chapter) &&
        (requestHasSnapshotPlaceholders ||
            cached.chapter.pages.length == entry.chapter.pages.length)) {
      // Version/page authority can stay cached, but mutable Reader progress
      // cannot. A Reader checkpoint may have advanced in the store without
      // rebuilding this hydrated manifest entry yet. Read the narrow progress
      // authority and merge only that field so a stale manifest cache can
      // never roll resume position backward on the next Reader entry.
      ReadingProgress? latestProgress = cached.progress;
      final requestedProgress = entry.progress;
      if (requestedProgress != null &&
          (latestProgress == null ||
              requestedProgress.updatedAt.isAfter(latestProgress.updatedAt))) {
        latestProgress = requestedProgress;
      }
      final store = library;
      final ImportedLibraryProgressLookup? progressLookup =
          store is ImportedLibraryProgressLookup
              ? store as ImportedLibraryProgressLookup
              : null;
      if (progressLookup != null) {
        final persisted = await progressLookup.getProgress(
          entry.chapter.sourceId,
          entry.chapter.chapterId,
        );
        if (persisted != null &&
            (latestProgress == null ||
                persisted.updatedAt.isAfter(latestProgress.updatedAt))) {
          latestProgress = persisted;
        }
      }
      if (latestProgress == null || identical(latestProgress, cached.progress)) {
        return cached;
      }
      final normalized = latestProgress.comicId == cached.chapter.comicId
          ? latestProgress
          : ReadingProgress(
              sourceId: cached.chapter.sourceId,
              comicId: cached.chapter.comicId,
              chapterId: cached.chapter.chapterId,
              pageIndex: latestProgress.pageIndex,
              subPageOffset: latestProgress.subPageOffset,
              readerMode: latestProgress.readerMode,
              updatedAt: latestProgress.updatedAt,
            );
      final refreshed = cached.copyWith(progress: normalized);
      _rememberVersionAuthorityEntries(<ImportedLibraryEntry>[refreshed]);
      return refreshed;
    }
    final hydrated = await _traceStartupOperation<ImportedLibraryEntry?>(
      'chapter-hydrate',
      () => library.get(entry.chapter.sourceId, entry.chapter.chapterId),
      summary: (value) => 'present=${value != null}',
    );
    final resolved = hydrated ?? entry;
    _rememberVersionAuthorityEntries(<ImportedLibraryEntry>[resolved]);
    await _assimilateCanonicalMediaForEntries(
      <ImportedLibraryEntry>[resolved],
      awaitPhysicalBackfill: awaitCanonicalPhysicalBackfill,
    );
    return resolved;
  }

  Future<void> ensureCanonicalMediaForEntry(
    ImportedLibraryEntry entry,
  ) =>
      _runAdmittedOperation(() => _ensureCanonicalMediaForEntry(entry));

  Future<void> _ensureCanonicalMediaForEntry(
    ImportedLibraryEntry entry,
  ) async {
    _rememberVersionAuthorityEntries(<ImportedLibraryEntry>[entry]);
    await _assimilateCanonicalMediaForEntries(<ImportedLibraryEntry>[entry]);
  }

  Future<Map<String, ImportedLibraryEntry>> hydrateChapterBatch(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) =>
      _runAdmittedOperation(() => _hydrateChapterBatch(chapters));

  Future<Map<String, ImportedLibraryEntry>> _hydrateChapterBatch(
    Iterable<ImportedLibraryChapterKey> chapters,
  ) async {
    final keys = <String, ImportedLibraryChapterKey>{};
    for (final key in chapters) {
      keys.putIfAbsent(key.identity, () => key);
    }
    if (keys.isEmpty) return const <String, ImportedLibraryEntry>{};
    final batch = library is ImportedLibraryBatchLookup
        ? library as ImportedLibraryBatchLookup
        : null;
    final entries = await _traceStartupOperation<List<ImportedLibraryEntry>>(
      'chapter-hydrate-batch',
      () async {
        if (batch != null) return batch.getMany(keys.values);
        final result = <ImportedLibraryEntry>[];
        for (final key in keys.values) {
          final entry = await library.get(key.sourceId, key.chapterId);
          if (entry != null) result.add(entry);
        }
        return result;
      },
      summary: (value) => 'requested=${keys.length} present=${value.length}',
    );
    _rememberVersionAuthorityEntries(entries);
    await _assimilateCanonicalMediaForEntries(entries);
    return <String, ImportedLibraryEntry>{
      for (final entry in entries) entry.identity: entry,
    };
  }

  Future<List<ImportedLibraryEntry>> loadAuthoritativeEntries() async {
    await ready;
    return library.list();
  }

  void observeVerifiedPageReuseIdentity(
    ChapterManifest chapter,
    PageAsset page,
    String identity,
  ) {
    if (_closed || identity.isEmpty ||
        page.chapterId != chapter.chapter.chapterId ||
        page.index < 0 || page.index >= chapter.pages.length) {
      return;
    }
    final exact = readerPageDownloadId(chapter, page);
    final previous = _versionReuseIdentityObservations.remove(exact.key);
    _versionReuseIdentityObservations[exact.key] = _VersionReusePageObservation(
      id: exact,
      identity: identity,
    );
    while (_versionReuseIdentityObservations.length >
        _versionReuseObservationLimit) {
      _versionReuseIdentityObservations.remove(
        _versionReuseIdentityObservations.keys.first,
      );
    }
    if (previous?.identity == identity) return;
    _versionEvidenceWriteTail = _versionEvidenceWriteTail.then((_) async {
      if (_closed) return;
      await _applyVerifiedPageReuseIdentity(chapter, page, identity);
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint('version reuse evidence update failed: $error');
    });
  }

  Future<void> _applyVerifiedPageReuseIdentity(
    ChapterManifest chapter,
    PageAsset page,
    String identity,
  ) async {
    final relations = List<ComicVersionRelation>.of(_versionRelations);
    relationLoop:
    for (final relation in relations) {
      if (relation.sourceId != chapter.sourceId) continue;
      final currentIsPredecessor = relation.predecessorComicId == chapter.comicId;
      final currentIsSuccessor = relation.successorComicId == chapter.comicId;
      if (!currentIsPredecessor && !currentIsSuccessor) continue;
      for (var mappingIndex = 0;
          mappingIndex < relation.pageMappings.length;
          mappingIndex++) {
        final mapping = relation.pageMappings[mappingIndex];
        if (currentIsPredecessor) {
          if (mapping.predecessorChapterId != chapter.chapter.chapterId ||
              mapping.predecessorSourceRevision !=
                  chapter.chapter.sourceRevision) {
            continue;
          }
        } else {
          if (mapping.successorChapterId != chapter.chapter.chapterId ||
              mapping.successorSourceRevision != chapter.chapter.sourceRevision) {
            continue;
          }
        }
        final relatedComicId = currentIsPredecessor
            ? relation.successorComicId
            : relation.predecessorComicId;
        final relatedChapterId = currentIsPredecessor
            ? mapping.successorChapterId
            : mapping.predecessorChapterId;
        final relatedEntry = _versionAuthorityEntryFor(
          relation.sourceId,
          relatedComicId,
          relatedChapterId,
        );
        if (relatedEntry == null) continue;
        final relatedManifest = relatedEntry.chapter.toManifest();
        if (currentIsPredecessor &&
            relatedManifest.chapter.sourceRevision !=
                mapping.successorSourceRevision) {
          continue;
        }
        if (currentIsSuccessor &&
            relatedManifest.chapter.sourceRevision !=
                mapping.predecessorSourceRevision) {
          continue;
        }

        final observedCounterpart = _uniqueObservedRelatedPage(
          sourceId: relation.sourceId,
          comicId: relatedComicId,
          chapterId: relatedChapterId,
          sourceRevision: relatedManifest.chapter.sourceRevision,
          identity: identity,
        );
        late final int predecessorIndex;
        late final int successorIndex;
        String? relatedIdentity;
        if (observedCounterpart != null &&
            observedCounterpart.pageIndex != null) {
          if (currentIsPredecessor) {
            predecessorIndex = page.index;
            successorIndex = observedCounterpart.pageIndex!;
          } else {
            successorIndex = page.index;
            predecessorIndex = observedCounterpart.pageIndex!;
          }
          relatedIdentity = observedCounterpart.identity;
        } else {
          if (currentIsPredecessor) {
            predecessorIndex = page.index;
            successorIndex = mapping
                    .uniqueVerifiedSuccessorIndexForPredecessor(page.index) ??
                page.index + mapping.successorOffset;
          } else {
            successorIndex = page.index;
            predecessorIndex = mapping
                    .uniqueVerifiedPredecessorIndexForSuccessor(page.index) ??
                page.index - mapping.successorOffset;
          }
        }
        if (predecessorIndex < 0 ||
            predecessorIndex >= mapping.predecessorPageCount ||
            successorIndex < 0 ||
            successorIndex >= mapping.successorPageCount ||
            predecessorIndex >=
                (currentIsPredecessor
                    ? chapter.pages.length
                    : relatedManifest.pages.length) ||
            successorIndex >=
                (currentIsSuccessor
                    ? chapter.pages.length
                    : relatedManifest.pages.length)) {
          continue;
        }
        if (relatedIdentity == null) {
          final relatedPage = currentIsPredecessor
              ? relatedManifest.pages[successorIndex]
              : relatedManifest.pages[predecessorIndex];
          final relatedId = readerPageDownloadId(relatedManifest, relatedPage);
          relatedIdentity =
              _versionReuseIdentityObservations[relatedId.key]?.identity ??
                  verifiedPageIdentity(relatedPage);
        }
        if (relatedIdentity == null) continue;
        final observedAt = DateTime.now().toUtc();
        final updated = identity == relatedIdentity
            ? mapping.recordVerifiedPageMatch(
                predecessorIndex: predecessorIndex,
                successorIndex: successorIndex,
                observedAt: observedAt,
              )
            : mapping.recordVerifiedPageMismatch(
                predecessorIndex: predecessorIndex,
                successorIndex: successorIndex,
                observedAt: observedAt,
              );
        if (identical(updated, mapping)) continue;
        final pageMappings = relation.pageMappings.toList(growable: false);
        final mutableMappings = pageMappings.toList(growable: true);
        mutableMappings[mappingIndex] = updated;
        await _upsertVersionRelationDerivedState(
          ComicVersionRelation(
            sourceId: relation.sourceId,
            predecessorComicId: relation.predecessorComicId,
            successorComicId: relation.successorComicId,
            predecessorTitle: relation.predecessorTitle,
            discoveredAt: relation.discoveredAt,
            pageMappings: List<ComicVersionPageMapping>.unmodifiable(
              mutableMappings,
            ),
          ),
        );
        // A page belongs to at most one chapter-pair mapping inside one direct
        // relation. Do not let a duplicate/stale mapping in the same relation
        // overwrite the evidence just persisted above.
        continue relationLoop;
      }
    }
  }

  _VersionReusePageObservation? _uniqueObservedRelatedPage({
    required String sourceId,
    required String comicId,
    required String chapterId,
    required String sourceRevision,
    required String identity,
  }) {
    _VersionReusePageObservation? match;
    for (final observation in _versionReuseIdentityObservations.values) {
      final id = observation.id;
      if (observation.identity != identity ||
          id.content.sourceId != sourceId ||
          id.content.comicId != comicId ||
          id.content.chapterId != chapterId ||
          id.sourceRevision != sourceRevision) {
        continue;
      }
      if (match != null && match.id != id) return null;
      match = observation;
    }
    return match;
  }

  ImportedLibraryEntry? _versionAuthorityEntryFor(
    String sourceId,
    String comicId,
    String chapterId,
  ) {
    final key = '$sourceId\u0000$comicId\u0000$chapterId';
    final hydrated = _versionAuthorityHydratedEntries[key];
    if (hydrated != null) return hydrated;
    for (final entry in _entries) {
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.comicId == comicId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    for (final entry in _orphanedDownloadEntries) {
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.comicId == comicId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    return null;
  }

  Future<void> flushVersionReuseEvidence() => _versionEvidenceWriteTail;

  Future<void> upsertVersionRelation(ComicVersionRelation relation) =>
      _runAdmittedOperation(() => _upsertVersionRelation(relation));

  Future<void> _upsertVersionRelation(ComicVersionRelation relation) async {
    while (true) {
      final persistedLibrary = await _persistVersionRelation(relation);
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      replaceVersionRelation(relation);
      break;
    }
    await _canonicalPhysicalBackfillTail;
  }

  /// Persists derived page-reuse evidence without publishing a Home mutation.
  ///
  /// Page mappings change cache/download reuse authority, but do not change the
  /// visible version family/head projection. Publishing them through the broad
  /// Home ChangeNotifier caused every background mapping write to rebuild the
  /// covered Home route and enqueue another full projection snapshot write.
  Future<void> upsertVersionRelationDerivedState(
    ComicVersionRelation relation,
  ) =>
      _runAdmittedOperation(
        () => _upsertVersionRelationDerivedState(relation),
      );

  Future<void> _upsertVersionRelationDerivedState(
    ComicVersionRelation relation,
  ) async {
    while (true) {
      final persistedLibrary = await _persistVersionRelation(relation);
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      _replaceVersionRelation(
        relation,
        publishHome: false,
        writeSnapshot: false,
      );
      break;
    }
    await _canonicalPhysicalBackfillTail;
  }

  Future<ImportedLibraryStore> _persistVersionRelation(
    ComicVersionRelation relation,
  ) async {
    while (true) {
      final libraryStore = library;
      final ComicVersionRelationStore? store =
          libraryStore is ComicVersionRelationStore
              ? libraryStore as ComicVersionRelationStore
              : null;
      if (store == null) {
        if (!identical(library, libraryStore)) {
          await _serviceAdoption;
          continue;
        }
        throw StateError('library does not persist comic version relations');
      }
      try {
        await store.saveComicVersionRelation(relation);
      } on Object {
        if (!identical(library, libraryStore)) {
          await _serviceAdoption;
          continue;
        }
        rethrow;
      }
      if (!identical(library, libraryStore)) {
        await _serviceAdoption;
        continue;
      }
      try {
        await _assimilateCanonicalMediaRelation(relation);
      } on Object catch (error) {
        if (!identical(library, libraryStore)) {
          await _serviceAdoption;
          continue;
        }
        _homeLog(
          'canonical-media-assimilation-failed '
          'sourceId=${relation.sourceId} errorType=${error.runtimeType}',
        );
        return libraryStore;
      }
      if (identical(library, libraryStore)) {
        return libraryStore;
      }
      await _serviceAdoption;
    }
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
    // Canonical projection identity is durable and monotonic, but whether it
    // is active for a page is relation-derived. Re-publish that scope after
    // the relation mutation so proof revoke/reverify changes only active
    // ranges without reallocating the persisted canonical coordinate.
    _refreshCanonicalMediaAuthority();
    _libraryProjectionRevision++;
    if (publishHome) {
      _publish();
    }
    if (writeSnapshot) {
      _scheduleSnapshotWrite();
    }
  }

  StateError? _admissionError() {
    if (_closing != null || _closed) {
      return StateError('Home library session is closing');
    }
    return null;
  }

  void _requireAdmissionOpen() {
    final error = _admissionError();
    if (error != null) {
      throw error;
    }
  }

  Future<T> _runAdmittedOperation<T>(
    Future<T> Function() operation,
  ) async {
    _requireAdmissionOpen();
    _activeAdmissions++;
    try {
      return await operation();
    } finally {
      _activeAdmissions--;
      if (_activeAdmissions == 0) {
        final drained = _admissionsDrained;
        if (drained != null && !drained.isCompleted) {
          drained.complete();
        }
        _admissionsDrained = null;
      }
    }
  }

  Future<void> _drainAdmittedOperations() {
    if (_activeAdmissions == 0) {
      return Future<void>.value();
    }
    final existing = _admissionsDrained;
    if (existing != null) {
      return existing.future;
    }
    final drained = Completer<void>();
    _admissionsDrained = drained;
    return drained.future;
  }

  Future<({ImportedLibraryStore store, T value})>
      _persistStableLibraryMutationResult<T>(
    Future<T> Function(ImportedLibraryStore store) mutate,
  ) async {
    while (true) {
      final libraryStore = library;
      try {
        final value = await mutate(libraryStore);
        if (identical(library, libraryStore)) {
          return (store: libraryStore, value: value);
        }
      } on Object {
        if (identical(library, libraryStore)) {
          rethrow;
        }
      }
      await _serviceAdoption;
    }
  }

  Future<ImportedLibraryStore> _persistStableLibraryMutation(
    Future<void> Function(ImportedLibraryStore store) mutate,
  ) async {
    final result = await _persistStableLibraryMutationResult<bool>(
      (store) async {
        await mutate(store);
        return true;
      },
    );
    return result.store;
  }

  Future<void> upsertCategory(LibraryCategory category) =>
      _runAdmittedOperation(() => _upsertCategory(category));

  Future<void> _upsertCategory(LibraryCategory category) async {
    while (true) {
      final result =
          await _persistStableLibraryMutationResult<LibraryCategory?>(
        (store) async {
          await store.upsertCategory(category);
          final categories = await store.listCategories();
          for (final stored in categories) {
            if (stored.categoryId == category.categoryId) {
              return stored;
            }
          }
          return null;
        },
      );
      if (!identical(library, result.store)) {
        continue;
      }
      final stored = result.value;
      if (stored == null) {
        throw StateError(
          'category write completed without a readable record',
        );
      }
      final next = _categories.toList(growable: true);
      final index = next.indexWhere(
        (current) => current.categoryId == stored.categoryId,
      );
      if (index < 0) {
        next.add(stored);
      } else {
        next[index] = stored;
      }
      next.sort((left, right) {
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0 ? order : left.name.compareTo(right.name);
      });
      _categories = List<LibraryCategory>.unmodifiable(next);
      _libraryProjectionRevision++;
      _publish();
      _scheduleSnapshotWrite();
      return;
    }
  }

  Future<void> removeCategory(String categoryId) =>
      _runAdmittedOperation(() => _removeCategory(categoryId));

  Future<void> _removeCategory(String categoryId) async {
    while (true) {
      final result = await _persistStableLibraryMutationResult<
          ({
            List<LibraryCategory> categories,
            List<ComicPreference> preferences,
          })>(
        (store) async {
          await store.removeCategory(categoryId);
          return (
            categories: await store.listCategories(),
            preferences: await store.listComicPreferences(),
          );
        },
      );
      if (!identical(library, result.store)) {
        continue;
      }
      if (result.value.categories.any(
        (category) => category.categoryId == categoryId,
      )) {
        throw StateError('category removal completed but category remains');
      }
      final persistedPreferences = <String, ComicPreference>{
        for (final preference in result.value.preferences)
          preference.identity: preference,
      };
      final nextPreferences = <String, ComicPreference>{..._preferences};
      for (final entry in _preferences.entries) {
        final current = entry.value;
        if (!current.categoryIds.contains(categoryId)) {
          continue;
        }
        final persisted = persistedPreferences[entry.key];
        if (persisted == null ||
            persisted.categoryIds.contains(categoryId)) {
          throw StateError(
            'category removal completed without preference cascade',
          );
        }
        nextPreferences[entry.key] = current.copyWith(
          categoryIds: current.categoryIds.where((id) => id != categoryId),
          updatedAt: persisted.updatedAt.isAfter(current.updatedAt)
              ? persisted.updatedAt
              : current.updatedAt,
        );
      }
      _categories = List<LibraryCategory>.unmodifiable(
        _categories
            .where((category) => category.categoryId != categoryId)
            .toList(growable: false),
      );
      _preferences = Map<String, ComicPreference>.unmodifiable(
        nextPreferences,
      );
      _libraryProjectionRevision++;
      _publish();
      _scheduleSnapshotWrite();
      return;
    }
  }

  Future<void> persistPreference(ComicPreference preference) =>
      persistPreferences(<ComicPreference>[preference]);

  Future<void> persistPreferences(Iterable<ComicPreference> preferences) =>
      _runAdmittedOperation(() => _persistPreferences(preferences));

  Future<void> _persistPreferences(
    Iterable<ComicPreference> preferences,
  ) async {
    final values = List<ComicPreference>.unmodifiable(preferences);
    if (values.isEmpty) return;
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) async {
          for (final preference in values) {
            await store.saveComicPreference(preference);
          }
        },
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      _replacePreferences(values);
      return;
    }
  }

  void _replacePreferences(Iterable<ComicPreference> preferences) {
    final next = <String, ComicPreference>{..._preferences};
    for (final preference in preferences) {
      next[preference.identity] = preference;
    }
    _preferences = Map<String, ComicPreference>.unmodifiable(next);
    _recomputeVersionBaselines();
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  void replacePreference(ComicPreference preference) {
    _replacePreferences(<ComicPreference>[preference]);
  }

  Future<void> persistReadState(ChapterReadState state) =>
      _runAdmittedOperation(() => _persistReadState(state));

  Future<void> _persistReadState(ChapterReadState state) async {
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) => store.saveChapterReadState(state),
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      replaceReadState(state);
      return;
    }
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
  ) =>
      _runAdmittedOperation(() => _upsertChapter(chapter));

  Future<ImportedLibraryEntry> _upsertChapter(
    ImportedChapterRecord chapter,
  ) async {
    while (true) {
      final result =
          await _persistStableLibraryMutationResult<ImportedLibraryEntry?>(
        (store) async {
          await store.upsertChapter(chapter);
          return store.get(chapter.sourceId, chapter.chapterId);
        },
      );
      if (!identical(library, result.store)) {
        continue;
      }
      final persistedEntry = result.value;
      if (persistedEntry == null) {
        throw StateError('chapter write completed without a readable entry');
      }
      // Exact durable reads may decode a fresh, equivalent record. Keep the
      // prepared immutable projection only when every persisted value matches,
      // while retaining the store's current progress and changed payloads.
      final entry = _samePersistedChapterPayload(chapter, persistedEntry.chapter)
          ? persistedEntry.copyWith(chapter: chapter)
          : persistedEntry;
      _replaceEntry(entry, replaceVersionAuthorityChapterPayload: true);
      await _assimilateCanonicalMediaForEntries(<ImportedLibraryEntry>[entry]);
      return entry;
    }
  }

  Future<void> removeChapter(String sourceId, String chapterId) =>
      _runAdmittedOperation(() => _removeChapter(sourceId, chapterId));

  Future<void> _removeChapter(String sourceId, String chapterId) async {
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) => store.removeChapter(sourceId, chapterId),
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      break;
    }
    final identity = chapterLibraryIdentity(sourceId, chapterId);
    final next = _entries
        .where((entry) => entry.identity != identity)
        .toList(growable: false);
    final nextReadStates = <String, ChapterReadState>{..._readStates}
      ..remove(identity);
    final entriesChanged = next.length != _entries.length;
    final readStateChanged = nextReadStates.length != _readStates.length;
    if (entriesChanged) {
      _entries = List<ImportedLibraryEntry>.unmodifiable(next);
    }
    _forgetVersionAuthorityChapter(sourceId, chapterId);
    if (!entriesChanged && !readStateChanged) return;
    if (readStateChanged) {
      _readStates = Map<String, ChapterReadState>.unmodifiable(nextReadStates);
    }
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  Future<void> upsertSavedComic(SavedComicRecord comic) =>
      _runAdmittedOperation(() => _upsertSavedComic(comic));

  Future<void> _upsertSavedComic(SavedComicRecord comic) async {
    while (true) {
      final result =
          await _persistStableLibraryMutationResult<SavedComicRecord?>(
        (store) async {
          await store.upsertSavedComic(comic);
          return store.getSavedComic(comic.sourceId, comic.comicId);
        },
      );
      if (!identical(library, result.store)) {
        continue;
      }
      final stored = result.value;
      if (stored == null) {
        throw StateError(
          'saved comic write completed without a readable record',
        );
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
      return;
    }
  }

  Future<void> removeSavedComic(String sourceId, String comicId) =>
      _runAdmittedOperation(() => _removeSavedComic(sourceId, comicId));

  Future<void> _removeSavedComic(String sourceId, String comicId) async {
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) => store.removeSavedComic(sourceId, comicId),
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      break;
    }
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
  Future<void> persistProgress(ReadingProgress progress) =>
      _runAdmittedOperation(() => _persistProgress(progress));

  Future<void> _persistProgress(ReadingProgress progress) async {
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) => store.saveProgress(progress),
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      replaceProgress(progress);
      return;
    }
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

  void _replaceEntry(
    ImportedLibraryEntry entry, {
    bool replaceVersionAuthorityChapterPayload = false,
  }) {
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
    _rememberVersionAuthorityEntries(
      <ImportedLibraryEntry>[entry],
      replaceChapterPayload: replaceVersionAuthorityChapterPayload,
    );
    _libraryProjectionRevision++;
    _publish();
    _scheduleSnapshotWrite();
  }

  Future<void> replaceSources(
    List<BrowsableComicSource> sources, {
    bool reloadLibrary = true,
  }) =>
      _runAdmittedOperation(
        () => _replaceSources(sources, reloadLibrary: reloadLibrary),
      );

  Future<void> _replaceSources(
    List<BrowsableComicSource> sources, {
    required bool reloadLibrary,
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
    await _runLibraryReload(
      waitForReady: true,
      openLibrary: false,
    );
  }

  Future<void> persistSourcePreference(
    ComicSourcePreference preference,
  ) =>
      _runAdmittedOperation(() => _persistSourcePreference(preference));

  Future<void> _persistSourcePreference(
    ComicSourcePreference preference,
  ) async {
    while (true) {
      final persistedLibrary = await _persistStableLibraryMutation(
        (store) => store.saveSourcePreference(preference),
      );
      if (!identical(library, persistedLibrary)) {
        continue;
      }
      replaceSourcePreference(preference);
      return;
    }
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

  Future<void> _trackDownloadProjectionRead(
    ChapterDownloadService service,
    Future<void> read,
  ) {
    _downloadProjectionReads[read] = service;
    unawaited(read.then<void>(
      (_) => _downloadProjectionReads.remove(read),
      onError: (Object _, StackTrace __) {
        _downloadProjectionReads.remove(read);
      },
    ));
    return read;
  }

  Future<void> _drainDownloadProjectionReads([
    ChapterDownloadService? service,
  ]) async {
    while (true) {
      final pending = <Future<void>>[
        for (final entry in _downloadProjectionReads.entries)
          if (service == null || identical(entry.value, service)) entry.key,
      ];
      if (pending.isEmpty) return;
      for (final read in pending) {
        try {
          await read;
        } on Object {
          // The requesting route handles errors; retirement joins all I/O.
        }
      }
    }
  }

  Future<void> refreshDownloadCacheProjection(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    if (_closed || _closing != null) return Future<void>.value();
    final service = chapterDownloads;
    final fullRefresh = _downloadProjectionRefresh;
    if (fullRefresh != null &&
        identical(service, _downloadProjectionRefreshService)) {
      return fullRefresh;
    }
    final reader = service is ChapterCacheManagementProjectionReader
        ? service as ChapterCacheManagementProjectionReader
        : null;
    if (reader == null) {
      return refreshDownloadSnapshots(entries);
    }
    final existing = _downloadCacheProjectionRefresh;
    if (existing != null &&
        identical(service, _downloadCacheProjectionRefreshService)) {
      return existing;
    }
    final requested = entries.toList(growable: false);
    final projectionEpoch = _downloadManagementProjectionEpoch;
    late final Future<void> refresh;
    refresh = reader.inspectCacheManagement(requested).then<void>((projection) {
      if (_closed ||
          !identical(service, chapterDownloads) ||
          projectionEpoch != _downloadManagementProjectionEpoch) {
        return;
      }
      _downloadCacheProjection = projection;
      _downloadProjectionChanges.notifyListeners();
    }).whenComplete(() {
      if (identical(_downloadCacheProjectionRefresh, refresh)) {
        _downloadCacheProjectionRefresh = null;
        _downloadCacheProjectionRefreshService = null;
      }
    });
    _downloadCacheProjectionRefreshService = service;
    _downloadCacheProjectionRefresh = refresh;
    return _trackDownloadProjectionRead(service, refresh);
  }

  Future<void> refreshDownloadSnapshots(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    if (_closed || _closing != null) return Future<void>.value();
    final service = chapterDownloads;
    final existing = _downloadProjectionRefresh;
    if (existing != null &&
        identical(service, _downloadProjectionRefreshService)) {
      return existing;
    }
    final requested = entries.toList(growable: false);
    _downloadManagementProjectionEpoch++;
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
    return _trackDownloadProjectionRead(service, refresh);
  }

  // A scan is a baseline, not a newer download event. Preserve events received
  // while I/O was pending, including lower progress after stop/delete and a new
  // revision of the same chapter. Never merge by max(bytes/pages).
  void _mergeConcurrentDownloadSnapshots(
    Map<String, ChapterDownloadSnapshot> before,
    Map<String, ChapterDownloadSnapshot> scanned,
  ) {
    for (final snapshot in _downloadSnapshots.values) {
      if (identical(before[snapshot.identity], snapshot)) continue;
      scanned.removeWhere((_, candidate) =>
          candidate.sourceId == snapshot.sourceId &&
          candidate.comicId == snapshot.comicId &&
          candidate.chapterId == snapshot.chapterId);
      scanned[snapshot.identity] = snapshot;
    }
  }

  Future<void> _refreshDownloadSnapshotsOnce(
    ChapterDownloadService service,
    List<ImportedLibraryEntry> requested,
  ) async {
    final previousSnapshots = _downloadSnapshots;
    final previousOrphaned = _orphanedDownloadEntries;
    final previousCacheProjection = _downloadCacheProjection;
    final snapshots = <String, ChapterDownloadSnapshot>{};
    var orphaned = const <ImportedLibraryEntry>[];
    ChapterCacheManagementProjection? cacheProjection;
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
        cacheProjection = projection.cache;
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
      cacheProjection = previousCacheProjection;
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
    _mergeConcurrentDownloadSnapshots(previousSnapshots, snapshots);
    final nextOrphaned = List<ImportedLibraryEntry>.unmodifiable(orphaned);
    final nextSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      snapshots,
    );
    final persistedChanged =
        !_samePersistedDownloadProjection(_downloadSnapshots, nextSnapshots) ||
        !_sameOrphanedDownloadProjection(previousOrphaned, nextOrphaned);
    _orphanedDownloadEntries = nextOrphaned;
    _downloadSnapshots = nextSnapshots;
    _downloadCacheProjection = cacheProjection;
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
    final managementEpoch = _downloadManagementProjectionEpoch;
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
    if (_closed || !identical(service, chapterDownloads) ||
        managementEpoch != _downloadManagementProjectionEpoch) return;
    _mergeConcurrentDownloadSnapshots(previous, next);
    final nextSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
      next,
    );
    final persistedChanged = !_samePersistedDownloadProjection(
      _downloadSnapshots,
      nextSnapshots,
    );
    _homeLog(
      'download-snapshot-targeted-refresh-complete '
      'entries=${requested.length} changed=$persistedChanged '
      'durationMs=${_homeStartupClock.elapsedMilliseconds - startedAt}',
    );
    _downloadSnapshots = nextSnapshots;
    _recomputeVersionBaselines();
    _downloadProjectionChanges.notifyListeners();
    if (persistedChanged) {
      _scheduleSnapshotWrite();
    } else {
      _homeLog('download-snapshot-persist-skip reason=unchanged');
    }
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
    if (_closed || _closing != null) return;
    if (hasTrustedSnapshot) {
      await _trackDownloadProjectionRead(
        chapterDownloads,
        _refreshKnownDownloadSnapshots(requested),
      );
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

  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    final closing = _closeOwnedResources();
    _closing = closing;
    return closing;
  }

  Future<void> _closeOwnedResources() async {
    // Constructor initialization is implicit pre-admitted work. Public
    // operations admitted before close are counted separately and may include
    // service adoption/reload or a durable write-through mutation.
    await _ready;
    await _drainAdmittedOperations();
    // An admitted adoption can install its projection tail while close waits
    // for admissions. Drain that new tail before releasing any store owners.
    await _ready;
    await _drainDownloadProjectionReads();
    await _versionEvidenceWriteTail;
    await _canonicalMediaWriteTail;
    await _canonicalPhysicalBackfillTail;
    // Snapshot writes admitted before close may still be reading the current
    // durable projection revision from [library]. Drain that tail before
    // closing its SQLite owner; setting [_closed] first would instead make an
    // admitted snapshot silently self-cancel at its next ownership check.
    await flushSnapshotWrites();
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
    _libraryGenerationChanges.dispose();
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
