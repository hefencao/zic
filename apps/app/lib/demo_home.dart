import 'dart:async';
import 'dart:typed_data';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:plugin_host/plugin_host.dart'
    show
        isCurrentSyntheticMihonChapterIdentity,
        isSyntheticMihonChapterIdentity;
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';
import 'package:downloads/downloads.dart';
import 'app_preferences.dart';
import 'app_settings_screen.dart';
import 'comic_details.dart' as details;
import 'dialog_actions.dart';
import 'debug_trace.dart';
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
import 'webp_demo.dart';
import 'home_library_session.dart';
import 'home_widgets.dart';
export 'home_widgets.dart' show ComicCoverCard, ComicDownloadProgress, ComicDownloadProgressKind;
part 'demo_home_views.dart';
part 'demo_home_source_compat.dart';
part 'demo_home_catalog_identity.dart';
part 'demo_home_source_migration.dart';
part 'demo_home_reader_route.dart';
const homePageKey = ValueKey<String>('home-page');
const bookshelfPageKey = ValueKey<String>('bookshelf-page');
const homeUpdatesSectionKey = ValueKey<String>('home-updates-section');
const homeHistorySectionKey = ValueKey<String>('home-history-section');
const homeDiagnosticsKey = ValueKey<String>('home-diagnostics');
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

List<Chapter> reconcileComicDetailsSourceChapters({
  required Iterable<Chapter> chapters,
  required bool Function(String chapterId) isCompatibilityFallback,
}) {
  final values = chapters.toList(growable: false);
  final hasAuthoritativeChapter = values.any(
    (chapter) => !isCompatibilityFallback(chapter.chapterId),
  );
  if (!hasAuthoritativeChapter) {
    return List<Chapter>.unmodifiable(values);
  }
  return List<Chapter>.unmodifiable(
    values.where(
      (chapter) => !isCompatibilityFallback(chapter.chapterId),
    ),
  );
}

List<ImportedLibraryEntry> reconcileComicDetailsChapterEntries({
  required Iterable<ImportedLibraryEntry> entries,
  required Iterable<Chapter> sourceChapters,
  required bool Function(String chapterId) isCompatibilityFallback,
}) {
  final authoritativeChapterIds = sourceChapters
      .where((chapter) => !isCompatibilityFallback(chapter.chapterId))
      .map((chapter) => chapter.chapterId)
      .toSet();
  if (authoritativeChapterIds.isEmpty) {
    return List<ImportedLibraryEntry>.unmodifiable(entries);
  }
  return List<ImportedLibraryEntry>.unmodifiable(
    entries.where(
      (entry) => !isCompatibilityFallback(entry.chapter.chapterId),
    ),
  );
}
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
    this.chapterDownloads,
    this.wholeComicDownloads,
    this.comicSources,
    this.externalPlugins,
    this.networkBridge = const AndroidNetworkBridge(),
    this.cacheCoordinator,
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
  final ChapterDownloadService? chapterDownloads;
  final WholeComicDownloadQueue? wholeComicDownloads;
  final List<BrowsableComicSource>? comicSources;
  final ExternalPluginController? externalPlugins;
  final AndroidNetworkBridge networkBridge;
  final ResourceCacheCoordinator? cacheCoordinator;
  final AppPreferencesController preferences;
  final DebugTraceLog debugTrace;
  final String? storageRoot;
  final HomeStartupTelemetry? startupTelemetry;
  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  final Stopwatch _traceClock = Stopwatch()..start();
  late final ImportedLibraryStore _library;
  late final ChapterDownloadService _chapterDownloads;
  late final ArtifactCacheManager? _readerArtifactCache;
  late final ComicSourceResourceGateway _sourceResources;
  late final WholeComicDownloadQueue _wholeComicDownloads;
  late List<BrowsableComicSource> _sources;
  late final HomeLibrarySession _librarySession;
  late final ResourceCacheCoordinator _cacheCoordinator;
  late final bool _ownsCacheCoordinator;

  bool _picking = false;
  bool _pickingFolder = false;
  bool _manageShelf = false;
  bool _batchManagement = false;
  final Set<String> _managedComicIdentities = <String>{};
  final Set<String> _openingComicIdentities = <String>{};
  final Map<String, Future<EncodedResourceSource>> _coverSourceInflight =
      <String, Future<EncodedResourceSource>>{};
  int _navigationIndex = 0;
  bool _sourcePageVisited = false;
  String? _sourceSearchQuery;
  int _sourceSearchRevision = 0;
  late ShelfSourceFilter _sourceFilter;
  String? _selectedCategoryId;
  late LibrarySortMode _sortMode;
  late ShelfViewPreference _shelfViewMode;

  Future<void> get _libraryReady => _librarySession.ready;
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

  List<LibraryComic> get _libraryComics => collapseCanonicalLibraryComics(
        aggregateImportedLibrary(
          _libraryEntries,
          savedComics: _savedComics,
        ),
        canonicalIdentity: _canonicalComicKey,
        isCompatibilityChapter: isSyntheticMihonChapterIdentity,
      );

  @override
  void initState() {
    super.initState();
    _sourceFilter = widget.preferences.shelfSourceFilter;
    _sortMode = widget.preferences.shelfSortMode;
    _shelfViewMode = widget.preferences.shelfView;
    widget.preferences.addListener(_handleAppPreferencesChanged);
    final ownsLibrary = widget.libraryStore == null;
    _library = widget.libraryStore ?? MemoryImportedLibraryStore();
    final ownsChapterDownloads = widget.chapterDownloads == null;
    _chapterDownloads = widget.chapterDownloads ??
        MemoryChapterDownloadService(pageLoader: _loadChapterPageBytes);
    _readerArtifactCache = _chapterDownloads is ArtifactCacheBackend
        ? ArtifactCacheManager(
            backend: _chapterDownloads as ArtifactCacheBackend,
          )
        : null;
    final suppliedCache = widget.cacheCoordinator;
    _ownsCacheCoordinator = suppliedCache == null;
    _cacheCoordinator = suppliedCache ??
        ResourceCacheCoordinator(
          artifacts: _chapterDownloads is ArtifactCacheMaintenance
              ? _chapterDownloads as ArtifactCacheMaintenance
              : null,
        );
    final rawSources = widget.comicSources ??
        <BrowsableComicSource>[
          MangaDexSource(),
          ...?widget.externalPlugins?.activeSources,
        ];
    _sources = List<BrowsableComicSource>.unmodifiable(
      rawSources.map(
        (source) => source is CachedBrowsableComicSource
            ? source
            : CachedBrowsableComicSource(
                source: source,
                cache: _cacheCoordinator.responses,
              ),
      ),
    );
    _sourceResources = ComicSourceResourceGateway(sourceForId: _sourceForId);
    _sourceResources.bindTo(_chapterDownloads);
    final ownsWholeComicDownloads = widget.wholeComicDownloads == null;
    _wholeComicDownloads = widget.wholeComicDownloads ??
        WholeComicDownloadQueue(downloads: _chapterDownloads);
    _librarySession = HomeLibrarySession(
      library: _library,
      chapterDownloads: _chapterDownloads,
      wholeComicDownloads: _wholeComicDownloads,
      sources: _sources,
      ownsLibrary: ownsLibrary,
      ownsChapterDownloads: ownsChapterDownloads,
      ownsWholeComicDownloads: ownsWholeComicDownloads,
      waitForPrimaryFrame: () => WidgetsBinding.instance.endOfFrame,
      startupTelemetry: widget.startupTelemetry,
    )..addListener(_handleLibrarySessionChanged);
    final externalPlugins = widget.externalPlugins;
    if (externalPlugins != null) {
      unawaited(_refreshExternalSourcesWhenReady(externalPlugins));
    }
  }

  void _handleAppPreferencesChanged() {
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

  void _handleLibrarySessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _reloadLibrary({bool waitForOpen = true}) =>
      _librarySession.reload(waitForOpen: waitForOpen);

  Future<void> _ensureLibraryReady() => _librarySession.ensureReady();

  Future<void> _retryLibrary() => _librarySession.retry();

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) =>
      _librarySession.acceptDownloadSnapshot(snapshot);

  Future<void> _refreshDownloadSnapshots(
    Iterable<ImportedLibraryEntry> entries,
  ) =>
      _librarySession.refreshDownloadSnapshots(entries);

  @override
  void dispose() {
    widget.preferences.removeListener(_handleAppPreferencesChanged);
    _librarySession.removeListener(_handleLibrarySessionChanged);
    unawaited(_closeHomeComposition());
    _librarySession.dispose();
    super.dispose();
  }

  Future<void> _closeHomeComposition() async {
    await _librarySession.close();
    _sourceResources.close();
    if (_ownsCacheCoordinator) {
      await _cacheCoordinator.close();
    }
  }

  BrowsableComicSource? _sourceForId(String sourceId) {
    for (final source in _sources) {
      if (source.sourceId == sourceId) {
        return source;
      }
    }
    return null;
  }

  List<BrowsableComicSource> get _enabledSources =>
      _librarySession.enabledSources;

  Future<void> _saveSourcePreference(
    ComicSourcePreference preference,
  ) async {
    final updated = preference.copyWith(updatedAt: DateTime.now().toUtc());
    await _library.saveSourcePreference(updated);
    _librarySession.replaceSourcePreference(updated);
  }

  Future<void> _replaceExternalSources() async {
    final builtIn = _sources
        .where((source) =>
            !source.sourceId.startsWith('mihon:') &&
            !source.sourceId.startsWith('venera:'))
        .toList(growable: true);
    final external = widget.externalPlugins?.activeSources ??
        const <BrowsableComicSource>[];
    _sources = List<BrowsableComicSource>.unmodifiable(
      <BrowsableComicSource>[...builtIn, ...external].map(
        (source) => source is CachedBrowsableComicSource
            ? source
            : CachedBrowsableComicSource(
                source: source,
                cache: _cacheCoordinator.responses,
              ),
      ),
    );
    await _librarySession.replaceSources(_sources, reloadLibrary: false);
    final canonicalIdsPersisted = await _persistKnownCanonicalComicIds();
    if (canonicalIdsPersisted) {
      await _reloadLibrary();
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshExternalSourcesWhenReady(
    ExternalPluginController controller,
  ) async {
    try {
      await controller.ready;
    } on Object {
      return;
    }
    if (!mounted || !identical(widget.externalPlugins, controller)) {
      return;
    }
    await _replaceExternalSources();
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceManagementScreen(
          sources: _sources,
          preferences: _sourcePreferences,
          onPreferenceChanged: _saveSourcePreference,
          externalPlugins: widget.externalPlugins,
          networkBridge: widget.networkBridge,
          onExternalSourcesChanged: _replaceExternalSources,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  void _openDownloadManager() {
    final route = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadManagerScreen(
          entries: List<ImportedLibraryEntry>.unmodifiable(_libraryEntries),
          downloads: _chapterDownloads,
          wholeComicDownloads: _wholeComicDownloads,
          cacheCoordinator: _cacheCoordinator,
        ),
      ),
    );
    unawaited(
      route.then((_) async {
        if (mounted) {
          await _refreshDownloadSnapshots(_libraryEntries);
        }
      }),
    );
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            preferences: widget.preferences,
            downloads: _wholeComicDownloads,
            cacheCoordinator: _cacheCoordinator,
            storageRoot: widget.storageRoot,
            exportBackup: () => exportImportedLibraryBackup(_library),
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
        entry.chapter.chapterId,
        entry.chapter.sourceRevision,
      )];
      if (snapshot != null) {
        snapshots.add(snapshot);
      }
    }
    final active = snapshots.where((snapshot) => snapshot.isActive).toList();
    final completed = snapshots.where((snapshot) => snapshot.isComplete).toList();
    final wholeJob = _wholeComicQueueSnapshot.jobFor(
      comic.sourceId,
      comic.comicId,
    );
    final wholeComicActive = wholeJob?.isActive ?? false;

    if (wholeComicActive) {
      final entries = _libraryEntries.where(
        (entry) =>
            entry.chapter.sourceId == comic.sourceId &&
            entry.chapter.comicId == comic.comicId,
      );
      final totalPages = entries.fold<int>(
        0,
        (sum, entry) => sum + entry.chapter.pages.length,
      );
      if (totalPages > 0) {
        final completedUnits = snapshots.fold<double>(
          0,
          (sum, snapshot) => sum + snapshot.completedPageUnits,
        );
        return ComicDownloadProgress.active(
          label: '整本下载',
          completedPageUnits: completedUnits,
          totalPages: totalPages,
        );
      }
    }

    if (active.isNotEmpty) {
      final snapshot = active.first;
      return ComicDownloadProgress.active(
        label: snapshot.title,
        completedPageUnits: snapshot.completedPageUnits,
        totalPages: snapshot.totalPages,
      );
    }

    if (completed.isEmpty) {
      return null;
    }
    final catalogCount = comic.sourceChapters.isNotEmpty
        ? comic.sourceChapters.length
        : comic.chapters.length;
    return ComicDownloadProgress.offline(
      label: catalogCount > 0 && completed.length >= catalogCount
          ? '整本已离线'
          : '${completed.length} 章已离线',
      offlineChapters: completed.length,
    );
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
    await _library.upsertChapter(record);
    final entry = await _library.get(record.sourceId, record.chapterId);
    if (entry == null) {
      throw StateError('漫画章节写入后无法重新读取：${record.chapterId}');
    }
    return entry;
  }

  Future<ImportedLibraryEntry> _refreshRemoteEntry(
    ImportedLibraryEntry entry, {
    bool forceSourceRefresh = false,
  }) async {
    if (entry.chapter.sourceId == 'local-folder') {
      return entry;
    }
    final source = _sourceForId(entry.chapter.sourceId);
    if (source == null) {
      throw StateError('漫画源 ${entry.chapter.sourceId} 当前不可用');
    }
    final manifest = await _loadCompatibleSourceChapter(
      source,
      entry.chapter.chapterId,
      forceRefresh: forceSourceRefresh,
    );
    final comic = Comic(
      comicId: entry.chapter.comicId,
      sourceId: entry.chapter.sourceId,
      title: entry.chapter.comicTitle,
      authors: entry.chapter.comicAuthors,
      tags: entry.chapter.comicTags,
      coverUri: entry.chapter.coverSourceId == null
          ? null
          : Uri.tryParse(entry.chapter.coverSourceId!),
      description: entry.chapter.comicDescription,
      readingDirection: entry.chapter.readingDirection,
    );
    final refreshed = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
      importedAt: entry.chapter.importedAt,
    );
    await _library.upsertChapter(refreshed);
    return await _library.get(
          refreshed.sourceId,
          refreshed.chapterId,
        ) ??
        ImportedLibraryEntry(chapter: refreshed, progress: entry.progress);
  }

  ComicPreference _preferenceForComic(LibraryComic comic) =>
      _mergedPreferenceFor(comic.sourceId, comic.comicId);

  ComicPreference _mergedPreferenceFor(
    String sourceId,
    String comicId, {
    ComicPreference? fallbackPreference,
    ComicSourceKind? fallbackSourceKind,
    bool fallbackInShelf = true,
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
    final now = DateTime.now().toUtc();
    final updated = preference.copyWith(updatedAt: now);
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

  Future<void> _saveReaderProgress(ReadingProgress progress) async {
    await _library.saveProgress(progress);
    _librarySession.replaceProgress(progress);
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
        SnackBar(content: Text('已进入 Reader，但已读状态保存失败：$error')),
      );
    }
  }

  Future<void> _importWebp() async {
    if (_picking || _pickingFolder) {
      return;
    }
    setState(() => _picking = true);
    try {
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
          SnackBar(content: Text('导入 WebP 失败：$error')),
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
      final folder = await widget.folderPicker();
      if (!mounted || folder == null) {
        return;
      }
      await _ensureLibraryReady();
      final record = imageFolderChapterRecord(folder);
      await _library.upsertChapter(record);
      final existingPreference =
          await _library.getComicPreference(
        record.sourceId,
        record.comicId,
      );
      if (existingPreference == null) {
        await _library.saveComicPreference(
          ComicPreference.defaults(
            sourceId: record.sourceId,
            comicId: record.comicId,
            customOrder: _preferences.length,
          ).copyWith(updatedAt: DateTime.now().toUtc()),
        );
      }
      final entry = await _library.get(record.sourceId, record.chapterId);
      await _reloadLibrary();
      if (!mounted || entry == null) {
        return;
      }
      await _openImportedChapter(entry);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入图片文件夹失败：$error')),
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
    bool refreshRemote = true,
  }) =>
      _openImportedChapterLoader(
        () => Future<ImportedLibraryEntry>.value(entry),
        title: entry.chapter.displayName,
        refreshRemote: refreshRemote,
      );

  Future<void> _openImportedChapterLoader(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required String title,
    bool refreshRemote = true,
    int? initialPageIndex,
  }) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeferredReaderRoute<_PreparedImportedChapter>(
          title: title,
          load: () => _prepareImportedChapter(
            loadChapter,
            refreshRemote: refreshRemote,
            initialPageIndex: initialPageIndex,
          ),
          builder: (_, prepared) => this._buildImportedChapterScreen(prepared),
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<_PreparedImportedChapter> _prepareImportedChapter(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required bool refreshRemote,
    int? initialPageIndex,
  }) async {
    final entry = await loadChapter();
    final legacyVenera = _hasLegacyVeneraLocators(entry.chapter);
    final current = legacyVenera
        ? await _refreshRemoteEntry(entry, forceSourceRefresh: true)
        : refreshRemote
            ? await _refreshRemoteEntry(entry)
            : entry;
    if (_hasLegacyVeneraLocators(current.chapter)) {
      throw StateError(
        'Venera 章节仍包含已失效的运行时资源定位符，已阻止进入 Reader',
      );
    }
    final hasOfflineBytes = current.chapter.sourceId != 'local-folder' &&
        await _chapterDownloads.isDownloaded(current);
    final source = _sourceForId(current.chapter.sourceId);
    final byteLoaders = hasOfflineBytes
        ? <String, LocalImageFileBytesLoader>{
            for (var index = 0; index < current.chapter.pages.length; index++)
              current.chapter.pages[index].sourceId: () =>
                  _chapterDownloads.readPage(current, index),
          }
        : const <String, LocalImageFileBytesLoader>{};
    final responseLoaders = hasOfflineBytes || source == null
        ? const <String, ExternalPluginResourceResponseLoader>{}
        : <String, ExternalPluginResourceResponseLoader>{
            for (final page in current.chapter.pages)
              page.sourceId: _sourceResources.responseLoaderFor(
                current.chapter.sourceId,
                Uri.parse(page.sourceId),
              ),
          };
    unawaited(_markChapterReadForNavigation(current));
    return (
      entry: current,
      byteLoaders: byteLoaders,
      responseLoaders: responseLoaders,
      initialPageIndex: initialPageIndex,
    );
  }

  details.ComicDetailsLibrarySnapshot _detailsSnapshotForComic(
    String sourceId,
    String comicId, {
    ComicPreference? preference,
  }) {
    final preferred = _libraryComicForSourceIdentity(sourceId, comicId);
    final effectiveComicId = preferred?.comicId ?? comicId;
    final saved = _savedComics.where(
      (item) =>
          item.sourceId == sourceId && item.comicId == effectiveComicId,
    );
    final sourceChapters = saved.isEmpty
        ? const <Chapter>[]
        : reconcileComicDetailsSourceChapters(
            chapters: saved.first.chapters
                .map((chapter) => chapter.toChapter(effectiveComicId))
                .where(
                  (chapter) =>
                      !isSyntheticMihonChapterIdentity(chapter.chapterId) ||
                      isCurrentSyntheticMihonChapterIdentity(chapter.chapterId),
                ),
            isCompatibilityFallback: isSyntheticMihonChapterIdentity,
          );
    final chapters = reconcileComicDetailsChapterEntries(
      entries: _libraryEntries.where(
        (entry) =>
            entry.chapter.sourceId == sourceId &&
            entry.chapter.comicId == effectiveComicId &&
            (!isSyntheticMihonChapterIdentity(entry.chapter.chapterId) ||
                isCurrentSyntheticMihonChapterIdentity(
                  entry.chapter.chapterId,
                )),
      ),
      sourceChapters: sourceChapters,
      isCompatibilityFallback: isSyntheticMihonChapterIdentity,
    );
    return details.ComicDetailsLibrarySnapshot(
      chapters: chapters,
      sourceChapters: sourceChapters,
      sourceComic: saved.isEmpty ? null : saved.first.toComic(),
      readStates: <String, ChapterReadState>{
        for (final chapter in chapters)
          if (_chapterReadStates.containsKey(chapter.identity))
            details.comicDetailsChapterIdentity(
              chapter.chapter.sourceId,
              chapter.chapter.chapterId,
            ): _chapterReadStates[chapter.identity]!,
      },
      preference: _mergedPreferenceFor(
        sourceId,
        effectiveComicId,
        fallbackPreference: preference,
        fallbackSourceKind: preference?.sourceKind,
        fallbackInShelf: preference?.inShelf ?? true,
      ),
    );
  }

  Future<details.ComicDetailsLibrarySnapshot> _reloadDetailsSnapshot(
    String sourceId,
    String comicId, {
    required bool refreshContent,
    ComicPreference? fallbackPreference,
  }) async {
    final preferred = _libraryComicForSourceIdentity(sourceId, comicId);
    final effectiveComicId = preferred?.comicId ?? comicId;
    ComicManifest? sourceManifest;
    if (refreshContent) {
      if (sourceId == 'local-folder') {
        final entries = _libraryEntries
            .where(
              (entry) =>
                  entry.chapter.sourceId == sourceId &&
                  entry.chapter.comicId == effectiveComicId,
            )
            .toList(growable: false);
        for (final entry in entries) {
          final folder = await widget.folderRefresher(entry.chapter);
          final refreshed = imageFolderChapterRecord(folder).copyWith(
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            comicAuthors: entry.chapter.comicAuthors,
            comicTags: entry.chapter.comicTags,
            comicDescription: entry.chapter.comicDescription,
            coverSourceId: entry.chapter.coverSourceId,
            sequence: entry.chapter.sequence,
            importedAt: entry.chapter.importedAt,
          );
          await _library.upsertChapter(refreshed);
        }
      } else {
        final source = _sourceForId(sourceId);
        if (source == null) {
          throw StateError('漫画源 $sourceId 当前不可用');
        }
        final manifest = await source.loadComic(effectiveComicId);
        sourceManifest = manifest;
        final existing = _preferredSavedComicAlias(
              sourceId,
              effectiveComicId,
            ) ??
            await _library.getSavedComic(sourceId, effectiveComicId);
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
            sessionId: 'source-catalog:$sourceId',
            kind: TraceEventKind.sourceReady,
            identityHash: _comicIdentityTraceHash(
              sourceId,
              effectiveComicId,
              canonical: _canonicalComicKey(sourceId, effectiveComicId),
            ),
            payload: <String, Object?>{
              'stage': 'chapter-catalog-refresh-result',
              'comicIdLength': effectiveComicId.length,
              'requestedComicIdLength': comicId.length,
              'aliasCount': _canonicalComicAliases(
                sourceId,
                effectiveComicId,
              ).length,
              'previousRealChapterCount':
                  existing == null ? 0 : _savedRealChapterCount(existing),
              'chapterCount': manifest.chapters.length,
              'syntheticChapterCount': manifest.chapters
                  .where(
                    (chapter) => isSyntheticMihonChapterIdentity(
                      chapter.chapterId,
                    ),
                  )
                  .length,
            },
          ),
        );
        final persistedManifest = _withoutSyntheticMihonFallback(manifest);
        _rejectCatalogRegression(
          existing: existing,
          incoming: persistedManifest,
        );
        await _removePersistedSyntheticChapters(persistedManifest);
        final changed = _manifestContentChanged(existing, persistedManifest);
        await _library.upsertSavedComic(
          SavedComicRecord.fromManifest(
            persistedManifest,
            canonicalComicId: _canonicalComicIdForPersistence(
              manifest.comic.sourceId,
              manifest.comic.comicId,
              fallback: existing?.canonicalComicId,
            ),
            savedAt: existing?.savedAt,
            updatedAt: changed ? DateTime.now().toUtc() : existing?.updatedAt,
          ),
        );
      }
    }
    await _reloadLibrary();
    final snapshot = _detailsSnapshotForComic(
      sourceId,
      effectiveComicId,
      preference: fallbackPreference,
    );
    return sourceManifest == null
        ? snapshot
        : snapshot.copyWith(sourceManifest: sourceManifest);
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
    const revision = comicArtworkCacheRevision;
    final source = _sourceForId(sourceId);
    final uri = Uri.tryParse(sourceValue);
    if (source != null && uri != null && uri.hasScheme) {
      return _sourceResources.loadArtworkBytes(
        cache: _cacheCoordinator.responses,
        sourceId: source.sourceId,
        comicId: comicId,
        uri: uri,
        revision: revision,
      );
    }
    return loadCachedComicImage(
      cache: _cacheCoordinator.responses,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: 'cover',
      revision: revision,
      loader: () => readLocalImageSource(sourceValue),
    );
  }

  Future<EncodedResourceSource> _loadCoverSource({
    required String sourceId,
    required String comicId,
    required Uri? coverUri,
    required ImportedLibraryEntry? fallbackChapter,
    String resourceRole = 'cover',
    bool forceRefresh = false,
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
    final recoveryRequested = forceRefresh ||
        resourceRole.startsWith('cover-recovery');
    final cacheResourceRole = recoveryRequested ? 'cover' : resourceRole;
    final directPath = localImageFilePath(sourceValue);
    if (directPath != null) {
      return FileEncodedResourceSource(
        path: directPath,
        origin: EncodedResourceOrigin.localFile,
      );
    }
    const revision = comicArtworkCacheRevision;
    final source = _sourceForId(sourceId);
    final uri = Uri.tryParse(sourceValue);
    if (source != null && uri != null && uri.hasScheme) {
      return _sourceResources.loadArtworkSource(
        cache: _cacheCoordinator.responses,
        sourceId: source.sourceId,
        comicId: comicId,
        uri: uri,
        revision: revision,
        resourceRole: cacheResourceRole,
        forceRefresh: recoveryRequested,
      );
    }
    // Android content URIs cannot be opened by FileImage. Copy them once into
    // the durable response cache, then use that immutable file on later
    // launches instead of crossing MethodChannel for every cover build.
    return loadCachedComicImageSource(
      cache: _cacheCoordinator.responses,
      sourceId: sourceId,
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: cacheResourceRole,
      revision: revision,
      awaitPersistence: false,
      forceRefresh: recoveryRequested,
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

  Future<EncodedResourceSource> _joinCoverSourceLoad(
    LibraryComic comic, {
    required bool forceRefresh,
  }) {
    final key = '${comic.identity}\u0000${comic.coverSourceId ?? ''}'
        '\u0000${forceRefresh ? 'recovery' : 'normal'}';
    final existing = _coverSourceInflight[key];
    if (existing != null) return existing;
    final future = _loadCoverSource(
      sourceId: comic.sourceId,
      comicId: comic.comicId,
      coverUri: comic.coverSourceId == null
          ? null
          : Uri.tryParse(comic.coverSourceId!),
      fallbackChapter: comic.coverChapter,
      forceRefresh: forceRefresh,
    );
    _coverSourceInflight[key] = future;
    unawaited(() async {
      try {
        await future;
      } on Object {
        // A failed future must be removed immediately. Retaining it would make
        // the next bounded retry join the same completed failure.
        if (identical(_coverSourceInflight[key], future)) {
          _coverSourceInflight.remove(key);
        }
        return;
      }
      // Keep a very short presentation join window so simultaneous Home cards
      // share one source/provider without becoming a byte cache owned by App.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (identical(_coverSourceInflight[key], future)) {
        _coverSourceInflight.remove(key);
      }
    }());
    return future;
  }

  Future<EncodedResourceSource> Function() _coverSourceLoaderForComic(
    LibraryComic comic,
  ) =>
      () => _joinCoverSourceLoad(comic, forceRefresh: false);

  Future<EncodedResourceSource> Function() _coverRecoverySourceLoaderForComic(
    LibraryComic comic,
  ) =>
      () => _joinCoverSourceLoad(comic, forceRefresh: true);

  bool _hasDetails(LibraryComic comic) {
    return comic.hasSourceCatalog ||
        comic.hasMultipleChapters ||
        comic.chapters.any((entry) => entry.chapter.sourceId != 'local-folder');
  }

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

  Future<void> _openComic(LibraryComic comic) => _withComicRouteLock(
        comic,
        () async {
          final resume = comic.resumeChapter;
          if (resume == null ||
              comic.hasMultipleChapters ||
              comic.hasSourceCatalog) {
            await _pushComicDetails(comic);
            return;
          }
          await _openImportedChapter(resume);
        },
      );

  Future<void> _removeComic(LibraryComic comic) async {
    await _ensureLibraryReady();
    for (final entry in comic.chapters) {
      await _library.removeChapter(
        entry.chapter.sourceId,
        entry.chapter.chapterId,
      );
    }
    await _library.removeSavedComic(comic.sourceId, comic.comicId);
    final source = _sourceForId(comic.sourceId);
    if (source != null) {
      invalidateCachedComic(source, comic.comicId);
    }
    invalidateComicResourceCache(
      _cacheCoordinator.responses,
      sourceId: comic.sourceId,
      comicId: comic.comicId,
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

  Future<void> _toggleCategory(
    LibraryComic comic,
    String categoryId,
  ) async {
    final preference = _preferenceForComic(comic);
    final categories = preference.categoryIds.toSet();
    if (!categories.add(categoryId)) {
      categories.remove(categoryId);
    }
    await _savePreference(preference.copyWith(categoryIds: categories));
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
          setState(() {
            _navigationIndex = index;
            if (index == 2) {
              _sourcePageVisited = true;
            }
          });
        },
      ),
    );
  }
}
