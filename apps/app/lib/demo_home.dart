import 'dart:async';
import 'dart:typed_data';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';
import 'package:downloads/downloads.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'app_preferences.dart';
import 'app_settings_screen.dart';
import 'comic_details.dart' as details;
import 'dialog_actions.dart';
import 'debug_trace.dart';
import 'debug_trace_export.dart';
import 'diagnostic_error_ui.dart';
import 'deferred_reader_route.dart';
import 'download_manager.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'library_backup.dart';
import 'library_diagnostics.dart';
import 'source_browser.dart';
import 'misc_page.dart';
import 'reader_preferences.dart';
import 'source_migration_compare.dart';
import 'source_resource_gateway.dart';
import 'static_demo.dart';
import 'startup_platform.dart';
import 'webp_demo.dart';
import 'home_library_session.dart';
import 'home_external_source_lifecycle.dart';
import 'home_download_commands.dart';
import 'home_reader_composition.dart';
import 'home_service_cache_binding.dart';
import 'home_source_migration_transaction.dart';
import 'home_source_projection.dart';
import 'home_version_reuse_lifecycle.dart';
import 'home_widgets.dart';
export 'home_widgets.dart' show ComicCoverCard, ComicDownloadProgress, ComicDownloadProgressKind;
part 'demo_home_views.dart';
part 'demo_home_source_compat.dart';
part 'demo_home_details.dart';
part 'demo_home_catalog_identity.dart';
part 'demo_home_source_migration.dart';
part 'demo_home_reader_route.dart';
part 'demo_home_service_handoff.dart';
part 'demo_home_local_cover.dart';
const homePageKey = ValueKey<String>('home-page');
const bookshelfPageKey = ValueKey<String>('bookshelf-page');
const homeUpdatesSectionKey = ValueKey<String>('home-updates-section');
const homeHistorySectionKey = ValueKey<String>('home-history-section');
const homeDiagnosticsKey = ValueKey<String>('home-diagnostics');
const homeTraceQuickExportKey = ValueKey<String>('home-trace-quick-export');
const bookshelfManageKey = ValueKey<String>('bookshelf-manage');
const bookshelfSourceFilterKey = ValueKey<String>('bookshelf-source-filter');
const bookshelfSortKey = ValueKey<String>('bookshelf-sort');
const bookshelfSortCustomKey = ValueKey<String>('bookshelf-sort-custom');
const bookshelfSortRecentKey = ValueKey<String>('bookshelf-sort-recent');
const bookshelfSortTitleKey = ValueKey<String>('bookshelf-sort-title');
const bookshelfSortPageCountKey = ValueKey<String>('bookshelf-sort-page-count');
const bookshelfViewKey = ValueKey<String>('bookshelf-view');
const bookshelfAddCategoryKey = ValueKey<String>('bookshelf-add-category');
const bookshelfAddComicToCategoryKey =
    ValueKey<String>('bookshelf-add-comic-to-category');
const bookshelfBatchBarKey = ValueKey<String>('bookshelf-batch-bar');
const bookshelfBatchMoveKey = ValueKey<String>('bookshelf-batch-move');
const bookshelfBatchDeleteKey = ValueKey<String>('bookshelf-batch-delete');
const bookshelfBatchClearKey = ValueKey<String>('bookshelf-batch-clear');
const downloadManagerEntryKey = ValueKey<String>('download-manager-entry');
const comicDetailsScreenKey = ValueKey<String>('comic-details-screen');
const comicDetailsReverseKey = ValueKey<String>('comic-details-reverse');
const staticDemoEntryKey = ValueKey<String>('demo-entry-static');
const mediaPipelineReaderEntryKey =
    ValueKey<String>('demo-entry-media-pipeline-reader');
const bundledWebpEntryKey = ValueKey<String>('demo-entry-bundled-webp');
const localWebpImportKey = ValueKey<String>('demo-entry-local-webp');
const localImageFolderImportKey =
    ValueKey<String>('demo-entry-local-image-folder');
const localWebpPickerProgressKey =
    ValueKey<String>('local-webp-picker-progress');
const localImageFolderPickerProgressKey =
    ValueKey<String>('local-image-folder-picker-progress');
const importedLibraryLoadingKey = ValueKey<String>('imported-library-loading');
const importedLibraryErrorKey = ValueKey<String>('imported-library-error');

Key importedChapterEntryKey(String sourceId, String chapterId) =>
    ValueKey<String>('imported-chapter:$sourceId\u0000$chapterId');

Key historyChapterEntryKey(String sourceId, String chapterId) =>
    ValueKey<String>('history-chapter:$sourceId\u0000$chapterId');
Key comicCoverKey(String sourceId, String comicId) =>
    ValueKey<String>('comic-cover:$sourceId\u0000$comicId');
Key comicDeleteKey(String sourceId, String comicId) =>
    ValueKey<String>('comic-delete:$sourceId\u0000$comicId');
Key comicMoveKey(String sourceId, String comicId) =>
    ValueKey<String>('comic-move:$sourceId\u0000$comicId');
Key comicReorderKey(String sourceId, String comicId) =>
    ValueKey<String>('comic-reorder:$sourceId\u0000$comicId');
Key comicCategoryKey(String sourceId, String comicId) =>
    ValueKey<String>('comic-category:$sourceId\u0000$comicId');
Key bookshelfMoveToCategoryKey(String categoryId) =>
    ValueKey<String>('bookshelf-move-to:$categoryId');
Key chapterReadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-read:$sourceId\u0000$chapterId');

String _comicIdentityTraceHash(
  String sourceId,
  String comicId, {
  required String canonical,
}) =>
    'source:${_stableTraceHash(sourceId)}'
    '/comic:${_stableTraceHash(comicId)}'
    '/canonical:${_stableTraceHash(canonical)}';

String _stableTraceHash(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
String _librarySortLabel(LibrarySortMode mode) => switch (mode) {
      LibrarySortMode.recent => '最近更新',
      LibrarySortMode.title => '标题',
      LibrarySortMode.pageCount => '页数',
      LibrarySortMode.custom => '自定义排序',
    };
final class DemoHome extends StatefulWidget {
  const DemoHome({
    required this.picker,
    required this.folderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    this.homeProjectionSnapshotStore,
    this.persistHomeProjectionSnapshot = true,
    this.chapterDownloads,
    this.downloadComposition,
    this.wholeComicDownloads,
    this.comicSources,
    this.externalPlugins,
    this.externalPluginLoader,
    this.platformEnvironmentLoader,
    this.networkBridge = const AndroidNetworkBridge(),
    this.cacheCoordinator,
    this.serviceHandoff,
    this.persistMissingPreferences = true,
    required this.preferences,
    required this.debugTrace,
    this.storageRoot,
    this.startupTelemetry,
    super.key,
  }) : assert(
          wholeComicDownloads == null || chapterDownloads != null,
          'a supplied whole-comic queue must share the supplied chapter service',
        );
  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;
  final HomeProjectionSnapshotStore? homeProjectionSnapshotStore;
  final bool persistHomeProjectionSnapshot;
  final ChapterDownloadService? chapterDownloads;
  final ChapterDownloadTransferRuntimeProvider? downloadComposition;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final List<BrowsableComicSource>? comicSources;
  final ExternalPluginController? externalPlugins;
  final Future<ExternalPluginController?> Function()? externalPluginLoader;
  final Future<void> Function()? platformEnvironmentLoader;
  final AndroidNetworkBridge networkBridge;
  final ResourceCacheCoordinator? cacheCoordinator;
  final HomeServiceHandoff? serviceHandoff;
  final bool persistMissingPreferences;
  final AppPreferencesController preferences;
  final DebugTraceLog debugTrace;
  final String? storageRoot;
  final HomeStartupTelemetry? startupTelemetry;
  @override
  State<DemoHome> createState() => _DemoHomeState();
}

enum _DownloadCompletionKind { chapter, wholeComic }

final class _DemoHomeState extends State<DemoHome> {
  final MonoClock _traceClock = const SystemClock();
  late final ComicSourceResourceGateway _sourceResources;
  late final HomeReaderChapterComposition _readerChapterComposition;
  late final HomeSourceProjection _sourceProjection;
  late final HomeLibrarySession _librarySession;
  late HomeServiceCacheBinding _serviceCache;
  late final HomeExternalSourceLifecycle _externalSources;
  late final HomeDownloadCommands _downloadCommands;
  late final HomeSourceMigrationTransaction _sourceMigrationTransaction;
  late final HomeVersionReuseLifecycle _versionReuseLifecycle;
  Future<void>? _durableAdoption;
  ChapterDownloadTransferRuntimeProvider? _localReadBackendPrewarmTarget;
  bool _suppressLibrarySessionRebuild = false;
  bool _readerRouteOpen = false;
  bool _downloadManagerRouteOpen = false;

  bool _picking = false;
  bool _pickingFolder = false;
  bool _exportingHomeTrace = false;
  bool _manageShelf = false;
  bool _batchManagement = false;
  final Set<String> _managedComicIdentities = <String>{};
  final Set<String> _openingComicIdentities = <String>{};
  final Map<String, ({String originComicId, Future<void> future})>
      _versionViewReusePreparations =
      <String, ({String originComicId, Future<void> future})>{};
  final Map<String, _DownloadCompletionKind> _downloadCompletionBadges =
      <String, _DownloadCompletionKind>{};
  final Map<String, String> _pendingWholeComicCompletionBadges =
      <String, String>{};
  int _navigationIndex = 0;
  bool _sourcePageVisited = false;
  String? _sourceSearchQuery;
  int _sourceSearchRevision = 0;
  late ShelfSourceFilter _sourceFilter;
  String? _selectedCategoryId;
  late LibrarySortMode _sortMode;
  late ShelfViewPreference _shelfViewMode;

  ImportedLibraryStore get _library => _librarySession.library;
  ChapterDownloadService get _chapterDownloads =>
      _librarySession.chapterDownloads;
  ChapterDownloadTransferRuntimeProvider? get _downloadComposition =>
      _librarySession.downloadComposition;
  WholeComicDownloadQueue get _wholeComicDownloads =>
      _librarySession.wholeComicDownloads;
  ArtifactCacheManager? get _readerArtifactCache =>
      _serviceCache.readerArtifactCache;
  ResourceCacheCoordinator get _cacheCoordinator =>
      _serviceCache.coordinator;

  List<ImportedLibraryEntry> get _libraryEntries => _librarySession.entries;
  List<SavedComicRecord> get _savedComics => _librarySession.savedComics;
  List<LibraryCategory> get _categories => _librarySession.categories;
  Map<String, ComicPreference> get _preferences =>
      _librarySession.preferences;
  Map<String, ChapterReadState> get _chapterReadStates =>
      _librarySession.readStates;
  Map<String, ComicSourcePreference> get _sourcePreferences =>
      _librarySession.sourcePreferences;
  Map<String, ChapterDownloadSnapshot> get _downloadSnapshots =>
      _librarySession.downloadSnapshots;
  WholeComicQueueSnapshot get _wholeComicQueueSnapshot =>
      _librarySession.wholeComicQueueSnapshot;
  Object? get _libraryError => _librarySession.error;
  bool get _libraryLoading => _librarySession.loading;
  String? get _activeSourceId => _librarySession.activeSourceId;
  set _activeSourceId(String? value) => _librarySession.activeSourceId = value;

  void _setState(VoidCallback fn) => setState(fn);

  HomeServiceHandoff? get _serviceHandoff => widget.serviceHandoff;

  ImportedLibraryStore? get _incomingLibraryStore =>
      widget.libraryStore ?? _serviceHandoff?.libraryStore;

  ChapterDownloadService? get _incomingChapterDownloads =>
      widget.chapterDownloads ?? _serviceHandoff?.chapterDownloads;

  ChapterDownloadTransferRuntimeProvider? get _incomingDownloadComposition =>
      widget.downloadComposition ?? _serviceHandoff?.downloadComposition;

  WholeComicDownloadQueue? get _incomingWholeComicDownloads =>
      widget.wholeComicDownloads ?? _serviceHandoff?.wholeComicDownloads;

  ResourceCacheCoordinator? get _incomingCacheCoordinator =>
      widget.cacheCoordinator ?? _serviceHandoff?.cacheCoordinator;

  ExternalPluginController? get _incomingExternalPlugins =>
      widget.externalPlugins ?? _serviceHandoff?.externalPlugins;

  Future<ExternalPluginController?> Function()? get _externalPluginLoader =>
      widget.externalPluginLoader ?? _serviceHandoff?.externalPluginLoader;

  Future<void> Function()? get _platformEnvironmentLoader =>
      widget.platformEnvironmentLoader ??
      _serviceHandoff?.platformEnvironmentLoader;

  String? get _storageRoot => widget.storageRoot ?? _serviceHandoff?.storageRoot;

  bool get _persistHomeProjectionSnapshot =>
      _serviceHandoff?.persistHomeProjectionSnapshot ??
      widget.persistHomeProjectionSnapshot;

  Future<void> _ensurePlatformEnvironment() async {
    try {
      await _platformEnvironmentLoader?.call();
    } on Object catch (error) {
      debugPrint('runtime download policy signals unavailable: $error');
    }
  }

  List<LibraryComic> get _libraryComics => collapseCanonicalLibraryComics(
        aggregateImportedLibrary(
          _libraryEntries,
          savedComics: _savedComics,
        ),
        canonicalIdentity: _canonicalComicKey,
      );

  @override
  void initState() {
    super.initState();
    _sourceFilter = widget.preferences.shelfSourceFilter;
    _sortMode = widget.preferences.shelfSortMode;
    _shelfViewMode = widget.preferences.shelfView;
    _syncReaderPrefetchReadBudget();
    widget.preferences.addListener(_handleAppPreferencesChanged);
    final incomingLibrary = _incomingLibraryStore;
    final ownsLibrary = incomingLibrary == null;
    final initialLibrary = incomingLibrary ?? MemoryImportedLibraryStore();
    // Ownership rule: the whole-comic job table must never wrap a chapter
    // service it does not co-own. A RAM queue around a durable service
    // writes artifacts to disk while losing the task list on restart; a
    // durable queue over a RAM service would enqueue jobs nothing can seal.
    // Bind the durable pair only when BOTH arrive together; otherwise own a
    // matching memory pair until handoff adoption swaps in the matched trio.
    final initialChapterDownloads = _incomingChapterDownloads;
    final initialWholeComicDownloads = _incomingWholeComicDownloads;
    final ownsChapterDownloads = initialChapterDownloads == null;
    final ownsWholeComicDownloads = initialWholeComicDownloads == null;
    final chapterDownloads = initialChapterDownloads ??
        MemoryChapterDownloadService(pageLoader: _loadChapterPageBytes);
    final downloadComposition = HomeLibrarySession.resolveDownloadComposition(
      chapterDownloads,
      _incomingDownloadComposition,
    );
    final suppliedCache = _incomingCacheCoordinator;
    _serviceCache = HomeServiceCacheBinding.create(
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      suppliedCoordinator: suppliedCache,
    );
    _sourceProjection = HomeSourceProjection(
      suppliedSources: widget.comicSources,
      defaultSources: () => <BrowsableComicSource>[
        MangaDexSource(
          userAgentProvider: () => widget.preferences.networkUserAgent,
        ),
      ],
      cache: _cacheCoordinator,
      externalSources:
          _incomingExternalPlugins?.activeSources ??
          const <BrowsableComicSource>[],
      publishSources: _publishSourceProjection,
      ensureLibraryReady: _ensureLibraryReady,
      savedComics: () => _savedComics,
      upsertSavedComic: (comic) => _librarySession.upsertSavedComic(comic),
      reloadLibrary: _reloadLibrary,
      requestPresentationRefresh: _refreshSourcePagePresentation,
    );
    _externalSources = HomeExternalSourceLifecycle(
      loaderProvider: () => _externalPluginLoader,
      sourceAvailable: (sourceId) => _sourceForId(sourceId) != null,
      isDeferredSource: _isDeferredExternalSourceId,
      refreshProjection: (controller) =>
          _sourceProjection.refreshExternalSources(controller.activeSources),
      reportError: (stage, error) => debugPrint('$stage failed: $error'),
    );
    _syncCachedCarrierTrustMode();
    _sourceResources = ComicSourceResourceGateway(
      sourceForId: _sourceForId,
      waitForSource: (sourceId) => _externalSources.waitForSource(sourceId),
      directTransport: RhttpSourceResourceDirectTransport(
        preparePlatform: prepareRhttpPlatform,
      ),
      defaultUserAgentProvider: () => widget.preferences.networkUserAgent,
    );
    _sourceResources.bindTo(chapterDownloads);
    final wholeComicDownloads = (initialWholeComicDownloads != null
        ? initialWholeComicDownloads
        : WholeComicDownloadQueue(downloads: chapterDownloads))
      ..refreshStaleChapter = _refreshStaleQueueChapter;
    _librarySession = HomeLibrarySession(
      library: initialLibrary,
      snapshotStore: widget.homeProjectionSnapshotStore,
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      wholeComicDownloads: wholeComicDownloads,
      sources: _sourceProjection.sources,
      ownsLibrary: ownsLibrary,
      ownsChapterDownloads: ownsChapterDownloads,
      ownsWholeComicDownloads: ownsWholeComicDownloads,
      persistMissingPreferences: widget.persistMissingPreferences,
      persistSnapshot: _persistHomeProjectionSnapshot,
      waitForPrimaryFrame: () => WidgetsBinding.instance.endOfFrame,
      startupTelemetry: widget.startupTelemetry,
    )..addListener(_handleLibrarySessionChanged);
    _sourceMigrationTransaction = HomeSourceMigrationTransaction(
      session: _librarySession,
      artifactCache: () => _readerArtifactCache,
      verifiedPageReuseIdentity: ({required sourceId, required locator}) =>
          _sourceResources.verifiedPageReuseIdentity(
        sourceId: sourceId,
        locator: locator,
      ),
      savePreference: _savePreference,
      canonicalComicIdForPersistence: _canonicalComicIdForPersistence,
      reportError: (stage, error) => debugPrint('$stage: $error'),
    );
    _versionReuseLifecycle = HomeVersionReuseLifecycle(
      session: _librarySession,
      loadRemoteEntrySnapshot: (entry, {control}) =>
          _loadRemoteEntrySnapshot(entry, control: control),
      verifiedPageReuseIdentity: ({
        required sourceId,
        required locator,
        control,
      }) =>
          _sourceResources.verifiedPageReuseIdentity(
        sourceId: sourceId,
        locator: locator,
        control: control,
      ),
      requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) =>
          defaultDownloadResourceCoordinator.networkLane.submit(
        key: key,
        priority: priority,
        task: task,
      ),
      trace: widget.debugTrace,
      monotonicMicros: () => _traceClock.nowMicros(),
    );
    _downloadCommands = HomeDownloadCommands(
      session: _librarySession,
      ensureDurableServices: () async {
        await _serviceHandoff?.ensureCoreServices?.call();
        await _adoptDurableServices();
      },
      ensurePlatformEnvironment: _ensurePlatformEnvironment,
      requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) =>
          _refreshRemoteEntry(
        entry,
        forceSourceRefresh: forceSourceRefresh,
      ),
      refreshStaleChapter: _refreshStaleQueueChapter,
    );
    _readerChapterComposition = HomeReaderChapterComposition(
      hydrateEntry: (entry, {required awaitCanonicalPhysicalBackfill}) =>
          _librarySession.hydrateEntry(
        entry,
        awaitCanonicalPhysicalBackfill: awaitCanonicalPhysicalBackfill,
      ),
      sourceResources: _sourceResources,
      downloadComposition: () => _downloadComposition,
      requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,
      refreshRemoteEntry: (entry, {required forceSourceRefresh}) =>
          _refreshRemoteEntry(
        entry,
        forceSourceRefresh: forceSourceRefresh,
      ),
      prepareVersionAuthority: _prepareReaderVersionAuthority,
      markChapterRead: _markChapterReadForNavigation,
      trace: widget.debugTrace,
      monotonicMicros: () => _traceClock.nowMicros(),
    );
    _sourceResources.setVerifiedPageReuseObserver(
      _librarySession.observeVerifiedPageReuseIdentity,
    );
    _librarySession.downloadProjectionChanges.addListener(
      _handleDownloadProjectionChanged,
    );
    _serviceHandoff?.setHomeProjectionCheckpoint(
      _librarySession.checkpointSnapshot,
    );
    _externalSources.initialize(_incomingExternalPlugins);
    _serviceHandoff?.addListener(_handleServiceHandoffChanged);
    _scheduleLocalReadBackendPrewarm();
  }

  @override
  void didUpdateWidget(covariant DemoHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.serviceHandoff, widget.serviceHandoff)) {
      oldWidget.serviceHandoff?.setHomeProjectionCheckpoint(null);
      oldWidget.serviceHandoff?.removeListener(_handleServiceHandoffChanged);
      widget.serviceHandoff?.addListener(_handleServiceHandoffChanged);
      widget.serviceHandoff?.setHomeProjectionCheckpoint(
        _librarySession.checkpointSnapshot,
      );
    }
    _handleServiceHandoffChanged();
  }

  bool _isDeferredExternalSourceId(String sourceId) =>
      sourceId.startsWith('mihon:') || sourceId.startsWith('venera:');

  void _syncReaderPrefetchReadBudget() {
    defaultDownloadResourceCoordinator.speculativeEncodedReadBudget
        .updateLimitBytes(
      widget.preferences.readerPrefetchReadBudgetMiB * 1024 * 1024,
    );
  }

  void _syncCachedCarrierTrustMode() {
    final cache = _readerArtifactCache;
    if (cache == null) return;
    cache.updateCarrierMismatchPolicy(
      switch (widget.preferences.cachedCarrierTrustMode) {
        CachedCarrierTrustMode.strictReload =>
          CachedCarrierMismatchPolicy.strictReload,
        CachedCarrierTrustMode.reuseThenRefresh =>
          CachedCarrierMismatchPolicy.reuseThenRefresh,
        CachedCarrierTrustMode.trustCached =>
          CachedCarrierMismatchPolicy.trustCached,
      },
    );
    cache.updateHistoricalCarrierSignatureConflictTrust((sourceId) {
      final pluginId = _externalSources.ownerOfSource(sourceId);
      return pluginId != null &&
          widget.preferences
              .trustConflictingHistoricalCarriersForPlugin(pluginId);
    });
  }

  void _handleAppPreferencesChanged() {
    _syncReaderPrefetchReadBudget();
    _syncCachedCarrierTrustMode();
    final sourceFilter = widget.preferences.shelfSourceFilter;
    final sortMode = widget.preferences.shelfSortMode;
    final shelfView = widget.preferences.shelfView;
    if (_sourceFilter == sourceFilter &&
        _sortMode == sortMode &&
        _shelfViewMode == shelfView) {
      return;
    }
    if (mounted) {
      setState(() {
        _sourceFilter = sourceFilter;
        _sortMode = sortMode;
        _shelfViewMode = shelfView;
        _clearManagedSelection();
      });
    }
  }

  void _beginReaderRoute() {
    _readerRouteOpen = true;
  }

  void _endReaderRoute() {
    if (!_readerRouteOpen) return;
    _readerRouteOpen = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _handleLibrarySessionChanged() {
    _syncWholeComicCompletionBadges();
    if (_suppressLibrarySessionRebuild || _readerRouteOpen) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleDownloadProjectionChanged() {
    // Download progress has its own card-level listenable. Keep completion
    // badge bookkeeping in sync without invalidating the library projection
    // that drives the Home update/history lists.
    _syncWholeComicCompletionBadges();
  }

  void _syncWholeComicCompletionBadges() {
    if (_pendingWholeComicCompletionBadges.isEmpty) return;
    final jobsById = <String, WholeComicQueueJobSnapshot>{
      for (final job in _wholeComicQueueSnapshot.jobs) job.jobId: job,
    };
    final finished = <String>[];
    for (final entry in _pendingWholeComicCompletionBadges.entries) {
      final job = jobsById[entry.key];
      if (job == null) continue;
      switch (job.phase) {
        case WholeComicQueuePhase.complete:
          _downloadCompletionBadges[entry.value] =
              _DownloadCompletionKind.wholeComic;
          finished.add(entry.key);
          break;
        case WholeComicQueuePhase.failed:
        case WholeComicQueuePhase.cancelled:
          finished.add(entry.key);
          break;
        case WholeComicQueuePhase.queued:
        case WholeComicQueuePhase.running:
        case WholeComicQueuePhase.waitingForPolicy:
        case WholeComicQueuePhase.requiresUserAction:
        case WholeComicQueuePhase.paused:
          break;
      }
    }
    for (final jobId in finished) {
      _pendingWholeComicCompletionBadges.remove(jobId);
    }
  }

  void _recordChapterDownloadCompletion(String sourceId, String comicId) {
    final identity = _canonicalComicKey(sourceId, comicId);
    if (!mounted) {
      _downloadCompletionBadges[identity] = _DownloadCompletionKind.chapter;
      return;
    }
    setState(() {
      _downloadCompletionBadges[identity] = _DownloadCompletionKind.chapter;
    });
  }

  void _trackWholeComicDownloadCompletion(String sourceId, String comicId) {
    final jobId = comicLibraryIdentity(sourceId, comicId);
    final canonical = _canonicalComicKey(sourceId, comicId);
    final job = _wholeComicDownloads.snapshot.jobFor(sourceId, comicId);
    if (job?.phase == WholeComicQueuePhase.complete) {
      _downloadCompletionBadges[canonical] =
          _DownloadCompletionKind.wholeComic;
      _pendingWholeComicCompletionBadges.remove(jobId);
      return;
    }
    _pendingWholeComicCompletionBadges[jobId] = canonical;
    _syncWholeComicCompletionBadges();
  }

  void _clearDownloadCompletionBadge(String sourceId, String comicId) {
    final identity = _canonicalComicKey(sourceId, comicId);
    if (!_downloadCompletionBadges.containsKey(identity)) return;
    if (mounted) {
      setState(() => _downloadCompletionBadges.remove(identity));
    } else {
      _downloadCompletionBadges.remove(identity);
    }
  }

  Future<void> _reloadLibrary({bool waitForOpen = true}) =>
      _librarySession.reload(waitForOpen: waitForOpen);

  Future<void> _ensureLibraryReady() => _librarySession.ensureReady();

  Future<void> _retryLibrary() => _librarySession.retry();

  @override
  void dispose() {
    widget.preferences.removeListener(_handleAppPreferencesChanged);
    _serviceHandoff?.setHomeProjectionCheckpoint(null);
    _serviceHandoff?.removeListener(_handleServiceHandoffChanged);
    unawaited(_externalSources.close());
    _librarySession.removeListener(_handleLibrarySessionChanged);
    _librarySession.downloadProjectionChanges.removeListener(
      _handleDownloadProjectionChanged,
    );
    unawaited(_closeHomeComposition());
    super.dispose();
  }

  Future<void> _closeHomeComposition() async {
    try {
      await _librarySession.close();
    } finally {
      // ChangeNotifier disposal must follow the asynchronous owner close. Doing
      // it synchronously from State.dispose() marks the session closed while an
      // admitted Home snapshot is still draining and silently cancels that
      // snapshot before its SQLite owner has shut down.
      _librarySession.dispose();
    }
    _sourceResources.close();
    await _serviceCache.closeIfOwned();
  }

  BrowsableComicSource? _sourceForId(String sourceId) =>
      _sourceProjection.sourceForId(sourceId);

  List<BrowsableComicSource> get _enabledSources =>
      _librarySession.enabledSources;

  Future<void> _saveSourcePreference(
    ComicSourcePreference preference,
  ) async {
    final updated = preference.copyWith(updatedAt: DateTime.now().toUtc());
    await _library.saveSourcePreference(updated);
    _librarySession.replaceSourcePreference(updated);
  }

  Future<void> _publishSourceProjection(
    List<BrowsableComicSource> sources,
  ) async {
    _suppressLibrarySessionRebuild = true;
    try {
      await _librarySession.replaceSources(sources, reloadLibrary: false);
    } finally {
      _suppressLibrarySessionRebuild = false;
    }
  }

  void _refreshSourcePagePresentation() {
    // Home cover loaders observe the source projection directly. Rebuilding
    // the Home tree for source-only publication would recreate pending cover
    // widgets. Only the visible source page needs an explicit refresh.
    if (mounted && _navigationIndex == 2) {
      setState(() {});
    }
  }

  Future<void> _openSourceManagement() async {
    final externalPlugins = await _externalSources.ensureController();
    if (!mounted) return;
    await _externalSources.refreshCurrentProjection();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceManagementScreen(
          sources: _sourceProjection.sources,
          preferences: _sourcePreferences,
          onPreferenceChanged: _saveSourcePreference,
          externalPlugins: externalPlugins,
          networkBridge: widget.networkBridge,
          onExternalSourcesChanged: _externalSources.refreshCurrentProjection,
          appPreferences: widget.preferences,
        ),
      ),
    );
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            preferences: widget.preferences,
            downloadPolicy: WholeComicPolicySettingsBinding(
              changes: _librarySession.downloadProjectionChanges,
              readSnapshot: () => _librarySession.wholeComicQueueSnapshot,
              updatePolicy: _downloadCommands.updateWholeComicPolicy,
            ),
            cacheCoordinator: _cacheCoordinator,
            storageRoot: _storageRoot,
            exportBackup: () => exportImportedLibraryBackup(_library),
            onChangeChapterDownloadDirectory:
                _serviceHandoff?.chapterDownloadRelay,
          ),
        ),
      ),
    );
  }

  void _openLibraryDiagnostics() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LibraryDiagnosticsScreen(store: _library),
        ),
      ),
    );
  }

  ComicDownloadProgress? _downloadProgressForComic(LibraryComic comic) {
    final snapshots = <ChapterDownloadSnapshot>[];
    for (final entry in _libraryEntries) {
      if (entry.chapter.sourceId != comic.sourceId ||
          entry.chapter.comicId != comic.comicId) {
        continue;
      }
      final snapshot = _downloadSnapshots[chapterDownloadIdentity(
        entry.chapter.sourceId,
        entry.chapter.comicId,
        entry.chapter.chapterId,
        entry.chapter.sourceRevision,
      )] ??
          _downloadSnapshots.values
              .where(
                (s) =>
                    s.sourceId == entry.chapter.sourceId &&
                    s.comicId == entry.chapter.comicId &&
                    s.chapterId == entry.chapter.chapterId,
              )
              .firstOrNull;
      if (snapshot != null) {
        snapshots.add(snapshot);
      }
    }
    final active = snapshots.where((snapshot) => snapshot.isActive).toList();
    final wholeJob = _wholeComicQueueSnapshot.jobFor(
      comic.sourceId,
      comic.comicId,
    );
    if (wholeJob != null &&
        wholeJob.hasPendingWork &&
        wholeJob.totalPages > 0) {
      return ComicDownloadProgress.active(
        label: wholeJob.totalChapters > 0
            ? '整本下载 (${wholeJob.completedChapters}/${wholeJob.totalChapters}章)'
            : '整本下载',
        completedPageUnits: wholeJob.completedPageUnits,
        totalPages: wholeJob.totalPages,
      );
    }

    if (active.isNotEmpty) {
      final snapshot = active.first;
      return ComicDownloadProgress.active(
        label: snapshot.title,
        completedPageUnits: snapshot.completedPageUnits,
        totalPages: snapshot.totalPages,
      );
    }

    final completion = _downloadCompletionBadges[
      _canonicalComicKey(comic.sourceId, comic.comicId)
    ];
    return switch (completion) {
      _DownloadCompletionKind.chapter =>
        const ComicDownloadProgress.chapterComplete(),
      _DownloadCompletionKind.wholeComic =>
        const ComicDownloadProgress.comicComplete(),
      null => null,
    };
  }

  int get _nextCustomOrder => _preferences.values.fold<int>(
        0,
        (value, preference) => preference.customOrder >= value
            ? preference.customOrder + 1
            : value,
      );

  Future<ImportedLibraryEntry> _ensureSourceChapter(
    BrowsableComicSource source,
    Comic comic,
    Chapter chapter,
  ) async {
    await _ensureLibraryReady();
    final manifest = await _loadCompatibleSourceChapter(
      source,
      chapter.chapterId,
    );
    final record = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
    );
    return _librarySession.upsertChapter(record);
  }

  /// Queue self-heal hook: re-pull the chapter manifest from its source so
  /// page URIs invalidated by a plugin runtime restart get fresh tokens.
  /// Returns null when the refresh is impossible or fails; the queue then
  /// records a normal chapter failure.
  Future<ImportedLibraryEntry?> _refreshStaleQueueChapter(
    ImportedLibraryEntry entry,
  ) async {
    try {
      final refreshed = await _refreshRemoteEntry(
        entry,
        forceSourceRefresh: true,
      );
      return identical(refreshed, entry) ? null : refreshed;
    } on Object catch (error) {
      debugPrint('stale chapter manifest refresh failed: $error');
      return null;
    }
  }

  Future<ImportedLibraryEntry> _refreshRemoteEntry(
    ImportedLibraryEntry entry, {
    bool forceSourceRefresh = false,
    TaskControl? control,
  }) async {
    final snapshot = await _loadRemoteEntrySnapshot(
      entry,
      forceSourceRefresh: forceSourceRefresh,
      control: control,
    );
    control?.throwIfCancelled();
    if (identical(snapshot, entry)) return entry;
    return _librarySession.upsertChapter(snapshot.chapter);
  }

  ComicPreference _preferenceForComic(LibraryComic comic) =>
      _mergedPreferenceFor(
        comic.sourceId,
        comic.comicId,
        fallbackSourceKind: comic.sourceId == 'local-folder'
            ? ComicSourceKind.local
            : ComicSourceKind.remote,
        fallbackInShelf: comic.sourceId == 'local-folder',
      );

  ComicPreference _mergedPreferenceFor(
    String sourceId,
    String comicId, {
    ComicPreference? fallbackPreference,
    ComicSourceKind? fallbackSourceKind,
    bool fallbackInShelf = false,
  }) {
    final aliases = _canonicalComicAliases(sourceId, comicId);
    final values = <ComicPreference>[];
    for (final alias in aliases) {
      final value = _preferences[comicLibraryIdentity(sourceId, alias)];
      if (value != null) values.add(value);
    }
    if (values.isEmpty) {
      final fallback = fallbackPreference;
      if (fallback != null) {
        return fallback;
      }
      return ComicPreference.defaults(
        sourceId: sourceId,
        comicId: comicId,
        sourceKind: fallbackSourceKind ??
            (sourceId == 'local-folder'
                ? ComicSourceKind.local
                : ComicSourceKind.remote),
      ).copyWith(inShelf: fallbackInShelf);
    }
    final categories = <String>{};
    var inShelf = false;
    var liked = false;
    var collected = false;
    var customOrder = values.first.customOrder;
    var updatedAt = values.first.updatedAt;
    var sourceKind = values.first.sourceKind;
    for (final value in values) {
      inShelf = inShelf || value.inShelf;
      liked = liked || value.liked;
      collected = collected || value.collected;
      categories.addAll(value.categoryIds);
      if (value.customOrder < customOrder) customOrder = value.customOrder;
      if (value.updatedAt.isAfter(updatedAt)) {
        updatedAt = value.updatedAt;
        sourceKind = value.sourceKind;
      }
    }
    return ComicPreference(
      sourceId: sourceId,
      comicId: comicId,
      sourceKind: sourceKind,
      inShelf: inShelf,
      liked: liked,
      collected: collected,
      categoryIds: categories,
      customOrder: customOrder,
      updatedAt: updatedAt,
    );
  }

  Future<void> _savePreference(ComicPreference preference) async {
    final previous = _mergedPreferenceFor(
      preference.sourceId,
      preference.comicId,
      fallbackSourceKind: preference.sourceKind,
      fallbackInShelf: false,
    );
    final now = DateTime.now().toUtc();
    final updated = preference.copyWith(updatedAt: now);
    if (!previous.inShelf && updated.inShelf) {
      for (final saved in _savedComicAliasesFor(
        preference.sourceId,
        preference.comicId,
      )) {
        if (saved.sourceUpdateAt == null) continue;
        await _librarySession.upsertSavedComic(
          saved.copyWith(clearSourceUpdateAt: true),
        );
      }
    }
    await _library.saveComicPreference(updated);
    _librarySession.replacePreference(updated);
    for (final alias in _canonicalComicAliases(
      preference.sourceId,
      preference.comicId,
    )) {
      if (alias == preference.comicId) continue;
      final identity = comicLibraryIdentity(preference.sourceId, alias);
      final prior = _preferences[identity];
      if (prior == null ||
          (!prior.inShelf &&
              !prior.liked &&
              !prior.collected &&
              prior.categoryIds.isEmpty)) {
        continue;
      }
      final neutral = ComicPreference(
        sourceId: prior.sourceId,
        comicId: prior.comicId,
        sourceKind: prior.sourceKind,
        inShelf: false,
        liked: false,
        collected: false,
        categoryIds: const <String>{},
        customOrder: prior.customOrder,
        updatedAt: now,
      );
      await _library.saveComicPreference(neutral);
      _librarySession.replacePreference(neutral);
    }
  }

  Future<void> _setChapterRead(
    ImportedLibraryEntry entry,
    bool isRead,
  ) async {
    final identity = chapterLibraryIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
    );
    final existing = _chapterReadStates[identity];
    if (existing != null &&
        existing.comicId == entry.chapter.comicId &&
        existing.isRead == isRead) {
      return;
    }
    final state = ChapterReadState(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId,
      isRead: isRead,
      updatedAt: DateTime.now().toUtc(),
    );
    await _library.saveChapterReadState(state);
    _librarySession.replaceReadState(state);
  }

  Future<void> _enqueueReaderProgress(ReadingProgress progress) {
    final library = _library;
    if (library is ReaderProgressCheckpointStore) {
      (library as ReaderProgressCheckpointStore).enqueueProgress(progress);
      return Future<void>.value();
    }
    // Non-buffered stores are compatibility/test implementations. Do not make
    // the Reader await their durable completion.
    unawaited(library.saveProgress(progress));
    return Future<void>.value();
  }

  Future<void> _flushReaderProgressCheckpoints() async {
    final library = _library;
    if (library is ReaderProgressCheckpointStore) {
      await (library as ReaderProgressCheckpointStore)
          .flushProgressCheckpoints();
    }
  }


  Future<void> _markChapterReadForNavigation(
    ImportedLibraryEntry entry,
  ) async {
    try {
      await _setChapterRead(entry, true);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        copyableDiagnosticSnackBar('已进入 Reader，但已读状态保存失败：$error'),
      );
    }
  }

  Future<void> _importWebp() async {
    if (_picking || _pickingFolder) {
      return;
    }
    setState(() => _picking = true);
    try {
      await attachAndroidPlugin('file_selector_android');
      final picked = await widget.picker();
      if (!mounted || picked == null) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WebpPlayerScreen.picked(picked),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          copyableDiagnosticSnackBar('导入 WebP 失败：$error'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _importImageFolder() async {
    if (_picking || _pickingFolder) {
      return;
    }
    setState(() => _pickingFolder = true);
    try {
      await attachAndroidPlugin('file_selector_android');
      await attachAndroidPlugin('local_media_bridge');
      final folder = await widget.folderPicker();
      if (!mounted || folder == null) {
        return;
      }
      await _ensureLibraryReady();
      final record = imageFolderChapterRecord(folder);
      // Match the local-comic ownership used by Venera without copying the
      // whole SAF tree: publish a small retained cover artifact before the
      // library entry becomes the long-lived Home/Bookshelf identity.
      await this._materializeLocalFolderCover(record);
      final entry = await _librarySession.upsertChapter(record);
      final existingPreference = await _library.getComicPreference(
        record.sourceId,
        record.comicId,
      );
      if (existingPreference == null) {
        final preference = ComicPreference.defaults(
          sourceId: record.sourceId,
          comicId: record.comicId,
          customOrder: _preferences.length,
        ).copyWith(updatedAt: DateTime.now().toUtc());
        await _library.saveComicPreference(preference);
        _librarySession.replacePreference(preference);
      }
      if (!mounted) {
        return;
      }
      await _openImportedChapter(entry);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          copyableDiagnosticSnackBar('导入图片文件夹失败：$error'),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _pickingFolder = false);
      }
    }
  }

  Future<void> _openImportedChapter(
    ImportedLibraryEntry entry, {
    bool? refreshRemote,
    int? initialPageIndex,
  }) async {
    await _openImportedChapterLoader(
      () => Future<ImportedLibraryEntry>.value(entry),
      title: entry.chapter.displayName,
      refreshRemote: refreshRemote ??
          (entry.chapter.sourceId != 'local-folder' &&
              entry.chapter.pages.isEmpty),
      initialPageIndex: initialPageIndex,
    );
  }


  Future<EncodedResourceSource> _loadSourceBrowseCover(
    BrowsableComicSource source,
    SourceComicSummary comic,
    Uri uri,
  ) =>
      _sourceResources.loadArtworkSource(
        cache: _cacheCoordinator.responses,
        sourceId: source.sourceId,
        comicId: comic.comicId,
        cacheComicId: _canonicalComicId(source.sourceId, comic.comicId),
        uri: uri,
      );

  Future<Uint8List> _loadMigrationCoverBytes({
    required String sourceId,
    required String comicId,
    required Uri? coverUri,
    required ImportedLibraryEntry? fallbackChapter,
  }) async {
    final fallback = fallbackChapter;
    final fallbackPage = sourceId != 'local-folder' ||
            fallback == null ||
            fallback.chapter.pages.isEmpty
        ? null
        : fallback.chapter.pages.first.sourceId;
    final sourceValue = coverUri?.toString() ??
        fallback?.chapter.coverSourceId ??
        fallbackPage;
    if (sourceValue == null || sourceValue.trim().isEmpty) {
      throw StateError('漫画详情没有可用封面');
    }
    final uri = Uri.tryParse(sourceValue);
    if (sourceId != 'local-folder' && uri != null) {
      return _sourceResources.loadArtworkBytes(
        cache: _cacheCoordinator.responses,
        sourceId: sourceId,
        comicId: comicId,
        cacheComicId: _canonicalComicId(sourceId, comicId),
        uri: uri,
      );
    }
    return loadCachedComicImage(
      cache: _cacheCoordinator.responses,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: 'cover',
      revision: comicArtworkCacheSchemaRevision,
      loader: () => readLocalImageSource(sourceValue),
    );
  }


  Future<EncodedResourceSource> _loadCoverSource({
    required String sourceId,
    required String comicId,
    required Uri? coverUri,
    required ImportedLibraryEntry? fallbackChapter,
    required String resourceRole,
  }) async {
    final fallback = fallbackChapter;
    final fallbackPage = sourceId != 'local-folder' ||
            fallback == null ||
            fallback.chapter.pages.isEmpty
        ? null
        : fallback.chapter.pages.first.sourceId;
    final sourceValue = coverUri?.toString() ??
        fallback?.chapter.coverSourceId ??
        fallbackPage;
    if (sourceValue == null || sourceValue.trim().isEmpty) {
      throw StateError('漫画详情没有可用封面');
    }
    final uri = Uri.tryParse(sourceValue);
    if (sourceId == 'local-folder' &&
        resourceRole == 'cover' &&
        uri?.scheme.toLowerCase() == 'content') {
      return this._loadLocalFolderCoverArtifact(
        comicId: comicId,
        sourceValue: sourceValue,
        chapter: fallback?.chapter,
        awaitPersistenceOnMiss: false,
      );
    }
    final directPath = localImageFilePath(sourceValue);
    if (directPath != null) {
      return FileEncodedResourceSource(
        path: directPath,
      );
    }
    if (sourceId != 'local-folder' && uri != null) {
      return _sourceResources.loadArtworkSource(
        cache: _cacheCoordinator.responses,
        sourceId: sourceId,
        comicId: comicId,
        cacheComicId: _canonicalComicId(sourceId, comicId),
        uri: uri,
        resourceRole: resourceRole,
        retention: resourceRole == 'cover'
            ? ResourceCacheRetention.retained
            : ResourceCacheRetention.transient,
      );
    }
    // Android content URIs cannot be opened by FileImage. Copy them into the
    // unified response cache; library/history covers are retained durably while
    // preview-like artwork remains transient.
    return loadCachedComicImageSource(
      cache: _cacheCoordinator.responses,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: resourceRole,
      revision: comicArtworkCacheSchemaRevision,
      awaitPersistence: false,
      retention: resourceRole == 'cover'
          ? ResourceCacheRetention.retained
          : ResourceCacheRetention.transient,
      loader: () => readLocalImageSource(sourceValue),
    );
  }

  Future<Uint8List> Function() _migrationCoverLoaderForComic(LibraryComic comic) {
    return () => _loadMigrationCoverBytes(
          sourceId: comic.sourceId,
          comicId: comic.comicId,
          coverUri: comic.coverSourceId == null
              ? null
              : Uri.tryParse(comic.coverSourceId!),
          fallbackChapter: comic.coverChapter,
        );
  }

  Future<EncodedResourceSource> Function() _coverSourceLoaderForComic(
    LibraryComic comic,
  ) =>
      () => _loadCoverSource(
            sourceId: comic.sourceId,
            comicId: comic.comicId,
            coverUri: comic.coverSourceId == null
                ? null
                : Uri.tryParse(comic.coverSourceId!),
            fallbackChapter: comic.coverChapter,
            resourceRole: 'cover',
          );

  bool _coverSourceAvailableForComic(LibraryComic comic) =>
      comic.sourceId == 'local-folder' || _sourceForId(comic.sourceId) != null;

  Future<void> _withComicRouteLock(
    LibraryComic comic,
    Future<void> Function() open,
  ) async {
    if (!_openingComicIdentities.add(comic.identity)) {
      return;
    }
    try {
      await open();
    } finally {
      _openingComicIdentities.remove(comic.identity);
    }
  }

  Future<void> _openComicDetails(LibraryComic comic) =>
      _withComicRouteLock(comic, () => _pushComicDetails(comic));

  Future<void> _openComic(LibraryComic comic) =>
      _withComicRouteLock(comic, () => _openShelfComicDirectly(comic));

  Future<void> _removeComic(
    LibraryComic comic, {
    bool deleteFiles = false,
  }) async {
    await _ensureLibraryReady();
    for (final entry in comic.chapters) {
      await _downloadCommands.deleteChapter(entry, deleteFiles: deleteFiles);
    }
    await _librarySession.removeSavedComic(comic.sourceId, comic.comicId);
    final source = _sourceForId(comic.sourceId);
    if (source != null) {
      invalidateCachedComicMetadata(source, comic.comicId);
    }
    invalidateAllComicResources(
      _cacheCoordinator.responses,
      sourceId: comic.sourceId,
      comicId: _canonicalComicId(comic.sourceId, comic.comicId),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _archiveComic(LibraryComic comic) async {
    await _ensureLibraryReady();
    for (final entry in comic.chapters) {
      await _downloadCommands.deleteChapterFiles(entry);
    }
    invalidateAllComicResources(
      _cacheCoordinator.responses,
      sourceId: comic.sourceId,
      comicId: _canonicalComicId(comic.sourceId, comic.comicId),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _createCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分类名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.of(context).pop(),
            actions: <Widget>[
              FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(controller.text.trim()),
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    final category = LibraryCategory(
      categoryId: 'category-${now.microsecondsSinceEpoch}',
      name: name,
      sortOrder: _categories.length,
      createdAt: now,
    );
    await _library.upsertCategory(category);
    await _reloadLibrary();
  }

  Future<void> _deleteCategory(LibraryCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('删除“${category.name}”？漫画本身不会被删除。'),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.of(context).pop(false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _library.removeCategory(category.categoryId);
    if (_selectedCategoryId == category.categoryId) {
      _selectedCategoryId = null;
    }
    await _reloadLibrary();
  }

  Future<void> _reorderCustom(int oldIndex, int newIndex) async {
    final visible = _filteredShelfComics().toList(growable: true);
    if (newIndex > oldIndex) {
      newIndex--;
    }
    final moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);

    final allShelf = _libraryComics
        .where((comic) => _preferenceForComic(comic).inShelf)
        .toList(growable: true)
      ..sort(
        (left, right) => _preferenceForComic(left)
            .customOrder
            .compareTo(_preferenceForComic(right).customOrder),
      );
    final reorderedVisible = visible.iterator;
    final merged = <LibraryComic>[];
    for (final comic in allShelf) {
      if (_matchesShelfFilter(comic)) {
        reorderedVisible.moveNext();
        merged.add(reorderedVisible.current);
      } else {
        merged.add(comic);
      }
    }
    final now = DateTime.now().toUtc();
    for (var index = 0; index < merged.length; index++) {
      final comic = merged[index];
      final preference = _preferenceForComic(comic).copyWith(
        customOrder: index,
        updatedAt: now.add(Duration(microseconds: index)),
      );
      await _library.saveComicPreference(preference);
    }
    await _reloadLibrary();
  }

  void _clearManagedSelection() {
    _managedComicIdentities.clear();
    _batchManagement = false;
  }

  void _startBatchSelection(LibraryComic comic) {
    setState(() {
      _batchManagement = true;
      _managedComicIdentities.add(comic.identity);
    });
  }

  void _toggleBatchSelection(LibraryComic comic) {
    if (!_batchManagement) {
      return;
    }
    setState(() {
      if (!_managedComicIdentities.add(comic.identity)) {
        _managedComicIdentities.remove(comic.identity);
      }
      if (_managedComicIdentities.isEmpty) {
        _batchManagement = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: _navigationIndex != 2,
      appBar: AppBar(
        title: Text(
          switch (_navigationIndex) {
            0 => 'zic',
            1 => '书架',
            2 => '漫画源',
            _ => '杂项',
          },
        ),
        actions: <Widget>[
          if (_navigationIndex == 2)
            TextButton.icon(
              key: comicSourceManageKey,
              onPressed: _openSourceManagement,
              icon: const Icon(Icons.tune),
              label: const Text('漫画源管理'),
            ),
          if (_navigationIndex < 2)
            IconButton(
              key: downloadManagerEntryKey,
              tooltip: '下载管理',
              onPressed: _openDownloadManager,
              icon: const Icon(Icons.download_for_offline_outlined),
            ),
          if (_navigationIndex < 2)
            IconButton(
              tooltip: '导入漫画文件夹',
              onPressed: _picking || _pickingFolder ? null : _importImageFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
        ],
      ),
      body: _buildLibraryState(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navigationIndex,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: '漫画源',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more),
            label: '杂项',
          ),
        ],
        onDestinationSelected: (index) {
          widget.startupTelemetry?.interaction(
            'navigation-destination',
            payload: <String, Object?>{
              'fromIndex': _navigationIndex,
              'toIndex': index,
            },
          );
          setState(() {
            _navigationIndex = index;
            if (index == 2) {
              _sourcePageVisited = true;
            }
          });
          if (index == 2) {
            // External runtimes are optional source capability. Opening the
            // source tab is an explicit demand boundary; it must not be part
            // of a fresh-install Home/background startup turn.
            unawaited(_externalSources.ensureSourcesPublished());
          }
        },
      ),
    );
  }
}
