import 'dart:async';
import 'dart:typed_data';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';
import 'package:downloads/downloads.dart';
import 'app_preferences.dart';
import 'app_settings_screen.dart';
import 'comic_details.dart' as details;
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
@Deprecated('Use localImageFolderImportKey')
const localWebpFolderImportKey = localImageFolderImportKey;
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
@Deprecated('Use localImageFolderPickerProgressKey')
const localWebpFolderPickerProgressKey = localImageFolderPickerProgressKey;
final class _PreparedChapterMigration {
  const _PreparedChapterMigration({
    required this.targetRecord,
    required this.sourceProgress,
    required this.sourceReadState,
    required this.targetProgress,
    required this.targetReadState,
  });
  final ImportedChapterRecord targetRecord;
  final ReadingProgress? sourceProgress;
  final ChapterReadState? sourceReadState;
  final ReadingProgress? targetProgress;
  final ChapterReadState? targetReadState;
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
  final ResourceCacheCoordinator? cacheCoordinator;
  final AppPreferencesController preferences;
  final DebugTraceLog debugTrace;
  final String? storageRoot;
  final HomeStartupTelemetry? startupTelemetry;
  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  late final ImportedLibraryStore _library;
  late final ChapterDownloadService _chapterDownloads;
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
  int _navigationIndex = 0;
  bool _sourcePageVisited = false;
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

  List<LibraryComic> get _libraryComics => aggregateImportedLibrary(
        _libraryEntries,
        savedComics: _savedComics,
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
    )..addListener(_handleLibrarySessionChanged);
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
    await _librarySession.replaceSources(_sources);
    if (mounted) setState(() {});
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceManagementScreen(
          sources: _sources,
          preferences: _sourcePreferences,
          onPreferenceChanged: _saveSourcePreference,
          externalPlugins: widget.externalPlugins,
          onExternalSourcesChanged: _replaceExternalSources,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _openSourceComic(
    BrowsableComicSource source,
    SourceComicSummary comic,
  ) async {
    final route = details.resolveComicDetailsRoute(
      sourceId: source.sourceId,
      comicId: comic.comicId,
      library: _libraryComics,
    );
    if (route == details.ComicDetailsRouteKind.local) {
      final local = _libraryComics.firstWhere(
        (item) =>
            item.sourceId == source.sourceId && item.comicId == comic.comicId,
      );
      await _openComicDetails(local);
      return;
    }
    final identity = comicLibraryIdentity(source.sourceId, comic.comicId);
    if (!_openingComicIdentities.add(identity)) {
      return;
    }
    final preference = _preferences[identity] ??
        ComicPreference.defaults(
          sourceId: source.sourceId,
          comicId: comic.comicId,
          sourceKind: ComicSourceKind.remote,
          customOrder: _nextCustomOrder,
        ).copyWith(inShelf: false);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceComicDetailsScreen(
            initialLibrary: _detailsSnapshotForComic(
              source.sourceId,
              comic.comicId,
              preference: preference,
            ),
            source: source,
            summary: comic,
            categories: _categories,
            loadCover: _loadCoverSource,
            reloadLibrary: ({required bool refreshContent}) =>
                _reloadDetailsSnapshot(
              source.sourceId,
              comic.comicId,
              refreshContent: refreshContent,
              fallbackPreference: preference,
            ),
            ensureSourceChapter: _ensureSourceChapter,
            persistComic: _persistRemoteComic,
            onPreferenceChanged: _savePreference,
            onReadChanged: _setChapterRead,
            onOpenChapter: (
              loadChapter, {
              required bool refreshRemote,
              required String title,
            }) =>
                _openImportedChapterLoader(
              loadChapter,
              title: title,
              refreshRemote: refreshRemote,
            ),
            onDownloadChapter: _downloadChapter,
            inspectChapterDownload: _chapterDownloads.inspect,
            downloadChanges: _chapterDownloads.changes,
            onDownloadComic: (entries) =>
                _downloadComicEntries(identity, entries),
          ),
        ),
      );
      if (mounted) {
        await _reloadLibrary();
      }
    } finally {
      _openingComicIdentities.remove(identity);
    }
  }

  Future<void> _persistRemoteComic(
    ComicManifest manifest,
    bool retained,
  ) async {
    await _ensureLibraryReady();
    if (!retained) {
      await _library.removeSavedComic(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      return;
    }
    final existing = await _library.getSavedComic(
      manifest.comic.sourceId,
      manifest.comic.comicId,
    );
    await _library.upsertSavedComic(
      SavedComicRecord.fromManifest(
        manifest,
        savedAt: existing?.savedAt,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
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

  ComicPreference _preferenceForComic(LibraryComic comic) {
    return _preferences[comic.identity] ??
        ComicPreference.defaults(
          sourceId: comic.sourceId,
          comicId: comic.comicId,
          sourceKind: comic.sourceId == 'local-folder'
              ? ComicSourceKind.local
              : ComicSourceKind.remote,
        );
  }

  Future<void> _savePreference(ComicPreference preference) async {
    final updated = preference.copyWith(updatedAt: DateTime.now().toUtc());
    await _library.saveComicPreference(updated);
    _librarySession.replacePreference(updated);
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
  }) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeferredReaderRoute<_PreparedImportedChapter>(
          title: title,
          load: () => _prepareImportedChapter(
            loadChapter,
            refreshRemote: refreshRemote,
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
    );
  }

  Future<void> _pushComicDetails(LibraryComic comic) async {
    final source = _sourceForId(comic.sourceId);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => details.LocalComicDetailsScreen(
          comic: comic,
          initialLibrary: _detailsSnapshotForComic(
            comic.sourceId,
            comic.comicId,
          ),
          categories: _categories,
          loadCover: _loadCoverSource,
          reloadLibrary: ({required bool refreshContent}) =>
              _reloadDetailsSnapshot(
            comic.sourceId,
            comic.comicId,
            refreshContent: refreshContent,
          ),
          source: source,
          ensureSourceChapter: source == null ? null : _ensureSourceChapter,
          onPreferenceChanged: (preference) async {
            await _savePreference(preference);
            final retained = preference.inShelf ||
                preference.liked ||
                preference.collected ||
                preference.categoryIds.isNotEmpty ||
                _libraryEntries.any(
                  (entry) =>
                      entry.chapter.sourceId == comic.sourceId &&
                      entry.chapter.comicId == comic.comicId,
                );
            if (!retained) {
              await _library.removeSavedComic(comic.sourceId, comic.comicId);
            }
          },
          onReadChanged: _setChapterRead,
          onOpenChapter: (
            loadChapter, {
            required bool refreshRemote,
            required String title,
          }) =>
              _openImportedChapterLoader(
            loadChapter,
            title: title,
            refreshRemote: refreshRemote,
          ),
          onDownloadChapter: _downloadChapter,
          inspectChapterDownload: _chapterDownloads.inspect,
          downloadChanges: _chapterDownloads.changes,
          onDownloadComic: (entries) => _downloadComicEntries(
            comicLibraryIdentity(comic.sourceId, comic.comicId),
            entries,
          ),
          onMigrateSource: comic.sourceId == 'local-folder'
              ? null
              : _openSourceMigration,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<({BrowsableComicSource source, String id})?>
      _selectSourceMigrationTarget(
    LibraryComic comic,
    List<BrowsableComicSource> targets,
  ) async {
    var target = targets.first;
    final controller = TextEditingController();
    final choice = await showDialog<
        ({BrowsableComicSource source, String? id, bool search})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('迁移到其他漫画源'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  value: target.sourceId,
                  decoration: const InputDecoration(labelText: '目标漫画源'),
                  items: <DropdownMenuItem<String>>[
                    for (final source in targets)
                      DropdownMenuItem<String>(
                        value: source.sourceId,
                        child: Text(source.descriptor.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setDialogState(() {
                      target = targets.firstWhere(
                        (source) => source.sourceId == value,
                      );
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '目标漫画 ID（可选）',
                    helperText: '通常直接搜索同名作品；仅在搜索不到时手动填写原生 ID',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                const Text(
                  '只复制整部漫画偏好和可验证阅读状态；不复制来源 URL、离线字节，也不删除原来源。',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton.icon(
              onPressed: target.descriptor.supportsSearch
                  ? () => Navigator.pop(
                        context,
                        (source: target, id: null, search: true),
                      )
                  : null,
              icon: const Icon(Icons.search),
              label: const Text('搜索同名作品'),
            ),
            FilledButton(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                        context,
                        (
                          source: target,
                          id: controller.text.trim(),
                          search: false,
                        ),
                      ),
              child: const Text('使用漫画 ID'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (choice == null || !mounted) {
      return null;
    }
    final manualId = choice.id;
    if (!choice.search && manualId != null) {
      return (source: choice.source, id: manualId);
    }

    try {
      final page = await choice.source.browse(
        query: comic.title,
        limit: 12,
      );
      if (!mounted) {
        return null;
      }
      if (page.items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${choice.source.descriptor.name} 未找到“${comic.title}”；可重试并手动填写漫画 ID',
            ),
          ),
        );
        return null;
      }
      final candidate = await showDialog<SourceComicSummary>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('选择 ${choice.source.descriptor.name} 中的目标作品'),
          children: <Widget>[
            for (final item in page.items)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.authors.isNotEmpty)
                        Text(
                          item.authors.join('、'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      Text(
                        item.comicId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
      if (candidate == null) {
        return null;
      }
      if (candidate.sourceId != choice.source.sourceId) {
        throw StateError('目标漫画源搜索返回了不匹配的来源身份');
      }
      return (source: choice.source, id: candidate.comicId);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索目标漫画失败：$error')),
        );
      }
      return null;
    }
  }

  Future<void> _openSourceMigration(LibraryComic comic) async {
    final targets = _enabledSources
        .where((source) => source.sourceId != comic.sourceId)
        .toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有其他已启用漫画源可用于迁移')),
      );
      return;
    }
    final request = await _selectSourceMigrationTarget(comic, targets);
    if (request == null || !mounted) {
      return;
    }
    try {
      final manifest = await request.source.loadComic(request.id);
      if (manifest.comic.sourceId != request.source.sourceId ||
          manifest.comic.comicId != request.id ||
          manifest.chapters.any((chapter) => chapter.comicId != request.id)) {
        throw StateError('目标漫画源返回了不匹配的漫画或章节身份');
      }
      final plan = ComicSourceMigrationPlan.build(
        source: comic,
        target: manifest,
      );
      final sourceDescriptor = _sourceForId(comic.sourceId)?.descriptor;
      final confirmed = await showSourceMigrationComparison(
        context: context,
        plan: plan,
        sourceName: sourceDescriptor?.name ?? comic.sourceId,
        targetName: request.source.descriptor.name,
        loadSourceCover: comic.coverSourceId == null && comic.coverChapter == null
            ? null
            : _migrationCoverLoaderForComic(comic),
        loadTargetCover: manifest.comic.coverUri == null
            ? null
            : () => _sourceResources.loadArtworkBytes(
                  cache: _cacheCoordinator.responses,
                  sourceId: request.source.sourceId,
                  comicId: manifest.comic.comicId,
                  uri: manifest.comic.coverUri!,
                ),
      );
      if (!confirmed) {
        return;
      }

      // Resolve and validate every target chapter before the first durable
      // write. A late source identity error must not leave a half-created
      // target comic or preference behind.
      final targetReadStates = <String, ChapterReadState>{
        for (final state in await _library.listChapterReadStates(
          manifest.comic.sourceId,
          manifest.comic.comicId,
        ))
          state.identity: state,
      };
      final prepared = <_PreparedChapterMigration>[];
      for (final match in plan.chapterMatches) {
        if (match.confidence != ChapterMigrationConfidence.exact) {
          continue;
        }
        final targetManifest =
            await request.source.loadChapter(match.target.chapterId);
        if (targetManifest.sourceId != manifest.comic.sourceId ||
            targetManifest.comicId != manifest.comic.comicId ||
            targetManifest.chapter.chapterId != match.target.chapterId) {
          throw StateError('目标漫画源返回了不匹配的章节详情身份');
        }
        final targetRecord = ImportedChapterRecord.remote(
          comic: manifest.comic,
          manifest: targetManifest,
        );
        final targetEntry = await _library.get(
          targetRecord.sourceId,
          targetRecord.chapterId,
        );
        prepared.add(
          _PreparedChapterMigration(
            targetRecord: targetRecord,
            sourceProgress: match.source.progress,
            sourceReadState: _chapterReadStates[chapterLibraryIdentity(
              match.source.chapter.sourceId,
              match.source.chapter.chapterId,
            )],
            targetProgress: targetEntry?.progress,
            targetReadState: targetReadStates[chapterLibraryIdentity(
              targetRecord.sourceId,
              targetRecord.chapterId,
            )],
          ),
        );
      }

      final migrationTime = DateTime.now().toUtc();
      final existingSaved = await _library.getSavedComic(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      final existingPreference = await _library.getComicPreference(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      final mergedPreference = plan.mergePreference(
        _preferenceForComic(comic),
        existingTarget: existingPreference,
        targetCustomOrder: _nextCustomOrder,
        updatedAt: migrationTime,
      );

      await _library.upsertSavedComic(
        SavedComicRecord.fromManifest(
          manifest,
          savedAt: existingSaved?.savedAt,
          updatedAt: migrationTime,
        ),
      );
      await _library.saveComicPreference(mergedPreference);

      var migratedChapters = 0;
      var migratedProgress = 0;
      var migratedReadStates = 0;
      var preservedTargetStates = 0;
      for (final item in prepared) {
        final targetRecord = item.targetRecord;
        await _library.upsertChapter(targetRecord);
        migratedChapters++;

        final sourceProgress = item.sourceProgress;
        if (item.targetProgress != null) {
          preservedTargetStates++;
        } else if (sourceProgress != null) {
          final pageIndex = sourceProgress.pageIndex
              .clamp(0, targetRecord.pages.length - 1)
              .toInt();
          await _library.saveProgress(
            ReadingProgress(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              pageIndex: pageIndex,
              subPageOffset: pageIndex == sourceProgress.pageIndex
                  ? sourceProgress.subPageOffset
                  : 0,
              readerMode: sourceProgress.readerMode,
              updatedAt: migrationTime,
            ),
          );
          migratedProgress++;
        }

        final sourceRead = item.sourceReadState;
        if (item.targetReadState != null) {
          preservedTargetStates++;
        } else if (sourceRead != null) {
          await _library.saveChapterReadState(
            ChapterReadState(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              isRead: sourceRead.isRead,
              updatedAt: migrationTime,
            ),
          );
          migratedReadStates++;
        }
      }
      await _reloadLibrary();
      if (mounted) {
        final messages = <String>[
          '漫画偏好已合并',
          if (migratedChapters > 0) '迁移 $migratedChapters 个已验证章节',
          if (migratedProgress > 0) '$migratedProgress 个阅读位置',
          if (migratedReadStates > 0) '$migratedReadStates 个已读状态',
          if (preservedTargetStates > 0)
            '保留 $preservedTargetStates 项目标源已有状态',
          '原来源与离线文件保留',
        ];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(messages.join(' · '))),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('漫画源迁移失败：$error')),
        );
      }
    }
  }

  details.ComicDetailsLibrarySnapshot _detailsSnapshotForComic(
    String sourceId,
    String comicId, {
    ComicPreference? preference,
  }) {
    final chapters = _libraryEntries
        .where(
          (entry) =>
              entry.chapter.sourceId == sourceId &&
              entry.chapter.comicId == comicId,
        )
        .toList(growable: false);
    final saved = _savedComics.where(
      (item) => item.sourceId == sourceId && item.comicId == comicId,
    );
    return details.ComicDetailsLibrarySnapshot(
      chapters: chapters,
      sourceChapters: saved.isEmpty
          ? const <Chapter>[]
          : saved.first.chapters
              .map((chapter) => chapter.toChapter(comicId)),
      readStates: <String, ChapterReadState>{
        for (final chapter in chapters)
          if (_chapterReadStates.containsKey(chapter.identity))
            details.comicDetailsChapterIdentity(
              chapter.chapter.sourceId,
              chapter.chapter.chapterId,
            ): _chapterReadStates[chapter.identity]!,
      },
      preference: _preferences[comicLibraryIdentity(sourceId, comicId)] ??
          preference ??
          ComicPreference.defaults(
            sourceId: sourceId,
            comicId: comicId,
          ),
    );
  }

  Future<details.ComicDetailsLibrarySnapshot> _reloadDetailsSnapshot(
    String sourceId,
    String comicId, {
    required bool refreshContent,
    ComicPreference? fallbackPreference,
  }) async {
    if (refreshContent) {
      if (sourceId == 'local-folder') {
        final entries = _libraryEntries
            .where(
              (entry) =>
                  entry.chapter.sourceId == sourceId &&
                  entry.chapter.comicId == comicId,
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
        final manifest = await source.loadComic(comicId);
        final existing = await _library.getSavedComic(sourceId, comicId);
        await _library.upsertSavedComic(
          SavedComicRecord.fromManifest(
            manifest,
            savedAt: existing?.savedAt,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
      }
    }
    await _reloadLibrary();
    return _detailsSnapshotForComic(
      sourceId,
      comicId,
      preference: fallbackPreference,
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
    const revision = '';
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
      revision: revision,
      loader: () => readLocalImageSource(sourceValue),
    );
  }

  Future<EncodedResourceSource> _loadCoverSource({
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
    final directPath = localImageFilePath(sourceValue);
    if (directPath != null) {
      return FileEncodedResourceSource(
        path: directPath,
        origin: EncodedResourceOrigin.localFile,
      );
    }
    const revision = '';
    final source = _sourceForId(sourceId);
    final uri = Uri.tryParse(sourceValue);
    if (source != null && uri != null && uri.hasScheme) {
      return _sourceResources.loadArtworkSource(
        cache: _cacheCoordinator.responses,
        sourceId: source.sourceId,
        comicId: comicId,
        uri: uri,
        revision: revision,
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
      revision: revision,
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
  ) {
    return () => _loadCoverSource(
          sourceId: comic.sourceId,
          comicId: comic.comicId,
          coverUri: comic.coverSourceId == null
              ? null
              : Uri.tryParse(comic.coverSourceId!),
          fallbackChapter: comic.coverChapter,
        );
  }

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
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('创建'),
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
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
