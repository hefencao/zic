import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';

import 'chapter_downloads.dart';
import 'comic_details.dart' as details;
import 'download_manager.dart';
import 'library_diagnostics.dart';
import 'source_browser.dart';
import 'source_migration_compare.dart';
import 'static_demo.dart';
import 'webp_demo.dart';
import 'whole_comic_downloads.dart';

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

enum _SourceFilter { all, local, remote }

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

enum _ShelfViewMode { gallery, list }

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

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  late final ImportedLibraryStore _library;
  late final bool _ownsLibrary;
  late final Future<void> _libraryReady;
  late final ChapterDownloadService _chapterDownloads;
  late final bool _ownsChapterDownloads;
  late final StreamSubscription<ChapterDownloadSnapshot> _downloadSubscription;
  late final WholeComicDownloadQueue _wholeComicDownloads;
  late final bool _ownsWholeComicDownloads;
  late final StreamSubscription<WholeComicQueueSnapshot>
      _wholeComicDownloadSubscription;
  final Map<String, Future<Uint8List>> _coverBytes =
      <String, Future<Uint8List>>{};
  late final List<BrowsableComicSource> _sources;

  List<ImportedLibraryEntry> _libraryEntries = const <ImportedLibraryEntry>[];
  List<SavedComicRecord> _savedComics = const <SavedComicRecord>[];
  List<LibraryCategory> _categories = const <LibraryCategory>[];
  Map<String, ComicPreference> _preferences =
      const <String, ComicPreference>{};
  Map<String, ChapterReadState> _chapterReadStates =
      const <String, ChapterReadState>{};
  Map<String, ComicSourcePreference> _sourcePreferences =
      const <String, ComicSourcePreference>{};
  Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      const <String, ChapterDownloadSnapshot>{};
  Object? _libraryError;
  bool _libraryLoading = true;
  bool _picking = false;
  bool _pickingFolder = false;
  bool _manageShelf = false;
  bool _batchManagement = false;
  final Set<String> _managedComicIdentities = <String>{};
  final Set<String> _openingComicIdentities = <String>{};
  WholeComicQueueSnapshot _wholeComicQueueSnapshot =
      const WholeComicQueueSnapshot(
        policy: WholeComicQueuePolicy(),
        environment: WholeComicQueueEnvironment.assumedAvailable(),
        jobs: <WholeComicQueueJobSnapshot>[],
      );
  int _navigationIndex = 0;
  bool _sourcePageVisited = false;
  String? _activeSourceId;
  _SourceFilter _sourceFilter = _SourceFilter.all;
  String? _selectedCategoryId;
  LibrarySortMode _sortMode = LibrarySortMode.recent;
  _ShelfViewMode _shelfViewMode = _ShelfViewMode.gallery;

  List<LibraryComic> get _libraryComics => aggregateImportedLibrary(
        _libraryEntries,
        savedComics: _savedComics,
      );

  @override
  void initState() {
    super.initState();
    _sources = List<BrowsableComicSource>.unmodifiable(
      widget.comicSources ?? <BrowsableComicSource>[MangaDexSource()],
    );
    _ownsLibrary = widget.libraryStore == null;
    _library = widget.libraryStore ?? MemoryImportedLibraryStore();
    _ownsChapterDownloads = widget.chapterDownloads == null;
    _chapterDownloads = widget.chapterDownloads ??
        MemoryChapterDownloadService(pageLoader: _loadChapterPageBytes);
    _downloadSubscription = _chapterDownloads.changes.listen(
      _acceptDownloadSnapshot,
    );
    _ownsWholeComicDownloads = widget.wholeComicDownloads == null;
    _wholeComicDownloads = widget.wholeComicDownloads ??
        WholeComicDownloadQueue(downloads: _chapterDownloads);
    _wholeComicQueueSnapshot = _wholeComicDownloads.snapshot;
    _wholeComicDownloadSubscription = _wholeComicDownloads.changes.listen(
      (snapshot) {
        if (mounted) {
          setState(() => _wholeComicQueueSnapshot = snapshot);
        }
      },
    );
    scheduleMicrotask(() async {
      await _wholeComicDownloads.ready;
      if (mounted) {
        setState(() => _wholeComicQueueSnapshot = _wholeComicDownloads.snapshot);
      }
    });
    _libraryReady = _initializeLibrary();
  }

  Future<void> _initializeLibrary() async {
    try {
      await _library.open();
      await _reloadLibrary(waitForOpen: false);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryError = error;
        _libraryLoading = false;
      });
    }
  }

  Future<void> _reloadLibrary({bool waitForOpen = true}) async {
    if (waitForOpen) {
      await _libraryReady;
    }
    final entries = await _library.list();
    final savedComics = await _library.listSavedComics();
    final categories = await _library.listCategories();
    final storedPreferences = await _library.listComicPreferences();
    final storedSourcePreferences = await _library.listSourcePreferences();
    final sourcePreferences = <String, ComicSourcePreference>{
      for (final preference in storedSourcePreferences)
        preference.sourceId: preference,
    };
    for (var index = 0; index < _sources.length; index++) {
      final source = _sources[index];
      if (sourcePreferences.containsKey(source.sourceId)) {
        continue;
      }
      final preference = ComicSourcePreference.defaults(
        sourceId: source.sourceId,
        sortOrder: index,
      ).copyWith(updatedAt: DateTime.now().toUtc());
      sourcePreferences[source.sourceId] = preference;
      await _library.saveSourcePreference(preference);
    }
    final enabledSourceIds = _sources
        .where((source) => sourcePreferences[source.sourceId]?.enabled ?? true)
        .toList(growable: false)
      ..sort((left, right) => (sourcePreferences[left.sourceId]?.sortOrder ?? 0)
          .compareTo(sourcePreferences[right.sourceId]?.sortOrder ?? 0));
    final nextActiveSourceId = enabledSourceIds.any(
      (source) => source.sourceId == _activeSourceId,
    )
        ? _activeSourceId
        : (enabledSourceIds.isEmpty ? null : enabledSourceIds.first.sourceId);
    final preferences = <String, ComicPreference>{
      for (final preference in storedPreferences)
        preference.identity: preference,
    };
    var nextOrder = preferences.values.fold<int>(
          0,
          (value, preference) =>
              preference.customOrder >= value
                  ? preference.customOrder + 1
                  : value,
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
      await _library.saveComicPreference(preference);
    }
    final readStates = <String, ChapterReadState>{};
    final comicIdentities = <({String sourceId, String comicId})>{
      for (final entry in entries)
        (
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
        ),
    };
    for (final comic in comicIdentities) {
      for (final state in await _library.listChapterReadStates(
        comic.sourceId,
        comic.comicId,
      )) {
        readStates[state.identity] = state;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _libraryEntries = entries;
      _savedComics = savedComics;
      _categories = categories;
      _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
      _chapterReadStates =
          Map<String, ChapterReadState>.unmodifiable(readStates);
      _sourcePreferences =
          Map<String, ComicSourcePreference>.unmodifiable(sourcePreferences);
      _activeSourceId = nextActiveSourceId;
      _libraryError = null;
      _libraryLoading = false;
    });
    unawaited(_refreshDownloadSnapshots(entries));
  }

  Future<void> _ensureLibraryReady() async {
    await _libraryReady;
    if (_libraryError == null) {
      return;
    }
    await _library.open();
    await _reloadLibrary(waitForOpen: false);
  }

  Future<void> _retryLibrary() async {
    if (mounted) {
      setState(() => _libraryLoading = true);
    }
    try {
      await _library.open();
      await _reloadLibrary(waitForOpen: false);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _libraryError = error;
        _libraryLoading = false;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_downloadSubscription.cancel());
    unawaited(_wholeComicDownloadSubscription.cancel());
    if (_ownsLibrary) {
      unawaited(_library.close());
    }
    if (_ownsWholeComicDownloads) {
      unawaited(
        _wholeComicDownloads.close().whenComplete(() {
          if (_ownsChapterDownloads) {
            return _chapterDownloads.close();
          }
        }),
      );
    } else if (_ownsChapterDownloads) {
      unawaited(_chapterDownloads.close());
    }
    super.dispose();
  }

  BrowsableComicSource? _sourceForId(String sourceId) {
    for (final source in _sources) {
      if (source.sourceId == sourceId) {
        return source;
      }
    }
    return null;
  }

  List<BrowsableComicSource> get _enabledSources {
    final result = _sources
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

  Future<void> _saveSourcePreference(
    ComicSourcePreference preference,
  ) async {
    final updated = preference.copyWith(updatedAt: DateTime.now().toUtc());
    await _library.saveSourcePreference(updated);
    if (!mounted) {
      return;
    }
    setState(() {
      _sourcePreferences = <String, ComicSourcePreference>{
        ..._sourcePreferences,
        updated.sourceId: updated,
      };
      final enabled = _enabledSources;
      if (!enabled.any((source) => source.sourceId == _activeSourceId)) {
        _activeSourceId = enabled.isEmpty ? null : enabled.first.sourceId;
      }
    });
  }

  Future<void> _openSourceManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceManagementScreen(
          sources: _sources,
          preferences: _sourcePreferences,
          onPreferenceChanged: _saveSourcePreference,
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
            loadCover: _loadDetailsCover,
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
              chapter, {
              required bool refreshRemote,
            }) =>
                _openImportedChapter(
              chapter,
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

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    setState(() {
      _downloadSnapshots = <String, ChapterDownloadSnapshot>{
        ..._downloadSnapshots,
        snapshot.identity: snapshot,
      };
    });
  }

  Future<void> _refreshDownloadSnapshots(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final snapshots = <String, ChapterDownloadSnapshot>{};
    for (final entry in entries) {
      try {
        final snapshot = await _chapterDownloads.inspect(entry);
        snapshots[snapshot.identity] = snapshot;
      } on Object {
        // Download diagnostics remain available from the manager if a single
        // stale record cannot be inspected. Library loading must still finish.
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _downloadSnapshots = Map<String, ChapterDownloadSnapshot>.unmodifiable(
        snapshots,
      );
    });
  }

  void _openDownloadManager() {
    final route = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadManagerScreen(
          entries: List<ImportedLibraryEntry>.unmodifiable(_libraryEntries),
          downloads: _chapterDownloads,
          wholeComicDownloads: _wholeComicDownloads,
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

  Future<Uint8List> _loadChapterPageBytes(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) {
    final pages = entry.chapter.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    final page = pages[pageIndex];
    final source = _sourceForId(entry.chapter.sourceId);
    final uri = Uri.tryParse(page.sourceId);
    if (source != null && uri != null) {
      return source.loadResource(uri);
    }
    return readLocalImageSource(page.sourceId);
  }

  Future<void> _downloadChapter(ImportedLibraryEntry entry) async {
    await _chapterDownloads.download(entry);
    _acceptDownloadSnapshot(await _chapterDownloads.inspect(entry));
  }

  Future<void> _downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final chapters = entries.toList(growable: false);
    if (chapters.isEmpty) {
      throw StateError('没有可下载的章节');
    }
    final first = chapters.first.chapter;
    if (comicIdentity != comicLibraryIdentity(first.sourceId, first.comicId)) {
      throw StateError('整本下载身份与章节所有者不一致');
    }
    await _wholeComicDownloads.enqueue(
      sourceId: first.sourceId,
      comicId: first.comicId,
      comicTitle: first.comicTitle,
      chapters: chapters,
    );
    if (mounted) {
      setState(() => _wholeComicQueueSnapshot = _wholeComicDownloads.snapshot);
    }
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
    final manifest = await source.loadChapter(chapter.chapterId);
    final record = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
    );
    await _library.upsertChapter(record);
    final entry = await _library.get(record.sourceId, record.chapterId);
    if (entry == null) {
      throw StateError('漫画章节写入后无法重新读取：${record.chapterId}');
    }
    await _reloadLibrary();
    return entry;
  }

  Future<ImportedLibraryEntry> _refreshRemoteEntry(
    ImportedLibraryEntry entry,
  ) async {
    if (entry.chapter.sourceId == 'local-folder') {
      return entry;
    }
    final source = _sourceForId(entry.chapter.sourceId);
    if (source == null) {
      throw StateError('漫画源 ${entry.chapter.sourceId} 当前不可用');
    }
    final manifest = await source.loadChapter(entry.chapter.chapterId);
    final comic = Comic(
      comicId: entry.chapter.comicId,
      sourceId: entry.chapter.sourceId,
      title: entry.chapter.comicTitle,
      authors: entry.chapter.comicAuthors,
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
    if (!mounted) {
      return;
    }
    setState(() {
      _preferences = <String, ComicPreference>{
        ..._preferences,
        updated.identity: updated,
      };
    });
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
    if (!mounted) {
      return;
    }
    setState(() {
      _chapterReadStates = <String, ChapterReadState>{
        ..._chapterReadStates,
        state.identity: state,
      };
    });
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
  }) async {
    final current = refreshRemote ? await _refreshRemoteEntry(entry) : entry;
    await _setChapterRead(current, true);
    if (!mounted) {
      return;
    }
    final hasOfflineBytes = current.chapter.sourceId != 'local-folder' &&
        await _chapterDownloads.isDownloaded(current);
    if (!mounted) {
      return;
    }
    final byteLoaders = hasOfflineBytes
        ? <String, LocalImageFileBytesLoader>{
            for (var index = 0; index < current.chapter.pages.length; index++)
              current.chapter.pages[index].sourceId: () =>
                  _chapterDownloads.readPage(current, index),
          }
        : const <String, LocalImageFileBytesLoader>{};
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          final preference = _preferences[
                comicLibraryIdentity(
                  current.chapter.sourceId,
                  current.chapter.comicId,
                )
              ] ??
              ComicPreference.defaults(
                sourceId: current.chapter.sourceId,
                comicId: current.chapter.comicId,
              );
          return ImportedImageChapterScreen(
            record: current.chapter,
            byteLoaders: byteLoaders,
            initialProgress: current.progress,
            onProgressChanged: _library.saveProgress,
            onDownloadRequested: () => _downloadChapter(current),
            initialFavorite: preference.collected,
            onFavoriteChanged: (favorite) {
              final preference = _preferences[
                    comicLibraryIdentity(
                      current.chapter.sourceId,
                      current.chapter.comicId,
                    )
                  ] ??
                  ComicPreference.defaults(
                    sourceId: current.chapter.sourceId,
                    comicId: current.chapter.comicId,
                  );
              return _savePreference(
                preference.copyWith(collected: favorite),
              );
            },
          );
        },
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
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
          loadCover: _loadDetailsCover,
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
            chapter, {
            required bool refreshRemote,
          }) =>
              _openImportedChapter(
            chapter,
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
            : _coverLoaderForComic(comic),
        loadTargetCover: manifest.comic.coverUri == null
            ? null
            : () => request.source.loadResource(manifest.comic.coverUri!),
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

  Future<Uint8List> _loadDetailsCover({
    required String sourceId,
    required Uri? coverUri,
    required ImportedLibraryEntry? fallbackChapter,
  }) async {
    final fallback = fallbackChapter;
    final fallbackPage = fallback == null || fallback.chapter.pages.isEmpty
        ? null
        : fallback.chapter.pages.first.sourceId;
    final sourceValue = coverUri?.toString() ??
        fallback?.chapter.coverSourceId ??
        fallbackPage;
    if (sourceValue == null || sourceValue.trim().isEmpty) {
      throw StateError('漫画详情没有可用封面');
    }
    return _coverBytes.putIfAbsent(sourceValue, () {
      final source = _sourceForId(sourceId);
      final uri = Uri.tryParse(sourceValue);
      if (source != null &&
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https')) {
        return source.loadResource(uri);
      }
      return readLocalImageSource(sourceValue);
    });
  }

  Future<Uint8List> Function() _coverLoader(ImportedLibraryEntry entry) {
    return () => _loadDetailsCover(
          sourceId: entry.chapter.sourceId,
          coverUri: entry.chapter.coverSourceId == null
              ? null
              : Uri.tryParse(entry.chapter.coverSourceId!),
          fallbackChapter: entry,
        );
  }

  Future<Uint8List> Function() _coverLoaderForComic(LibraryComic comic) {
    return () => _loadDetailsCover(
          sourceId: comic.sourceId,
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
      _coverBytes.remove(entry.chapter.pages.first.sourceId);
      final coverSourceId = entry.chapter.coverSourceId;
      if (coverSourceId != null) {
        _coverBytes.remove(coverSourceId);
      }
    }
    await _library.removeSavedComic(comic.sourceId, comic.comicId);
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

  List<LibraryComic> _selectedManagedComics() => _libraryComics
      .where((comic) => _managedComicIdentities.contains(comic.identity))
      .toList(growable: false);

  bool _matchesShelfFilter(LibraryComic comic) {
    final preference = _preferenceForComic(comic);
    if (!preference.inShelf) {
      return false;
    }
    if (_sourceFilter == _SourceFilter.local &&
        preference.sourceKind != ComicSourceKind.local) {
      return false;
    }
    if (_sourceFilter == _SourceFilter.remote &&
        preference.sourceKind != ComicSourceKind.remote) {
      return false;
    }
    final categoryId = _selectedCategoryId;
    return categoryId == null || preference.categoryIds.contains(categoryId);
  }

  List<LibraryComic> _filteredShelfComics() {
    final comics = _libraryComics
        .where(_matchesShelfFilter)
        .toList(growable: true);
    switch (_sortMode) {
      case LibrarySortMode.recent:
        comics.sort(
          (left, right) => right.latestImportedAt.compareTo(left.latestImportedAt),
        );
        break;
      case LibrarySortMode.title:
        comics.sort(
          (left, right) =>
              left.title.toLowerCase().compareTo(right.title.toLowerCase()),
        );
        break;
      case LibrarySortMode.pageCount:
        comics.sort(
          (left, right) => right.totalPages.compareTo(left.totalPages),
        );
        break;
      case LibrarySortMode.custom:
        comics.sort(
          (left, right) => _preferenceForComic(left)
              .customOrder
              .compareTo(_preferenceForComic(right).customOrder),
        );
        break;
    }
    return comics;
  }

  Widget _buildLibraryState() {
    if (_libraryLoading) {
      return const Center(
        key: importedLibraryLoadingKey,
        child: CircularProgressIndicator(),
      );
    }
    final error = _libraryError;
    if (error != null) {
      return Center(
        key: importedLibraryErrorKey,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              const Text('本地漫画库加载失败'),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _retryLibrary,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return IndexedStack(
      index: _navigationIndex,
      children: <Widget>[
        _buildHomePage(),
        _buildBookshelfPage(),
        _sourcePageVisited
            ? ComicSourcesPage(
                sources: _enabledSources,
                activeSourceId: _activeSourceId,
                onSourceSelected: (sourceId) {
                  setState(() => _activeSourceId = sourceId);
                },
                onOpenComic: _openSourceComic,
              )
            : const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildHomePage() {
    final updates = _libraryComics.take(10).toList(growable: false);
    final history = _libraryComics
        .where((comic) => comic.lastReadChapter != null)
        .toList(growable: true)
      ..sort(
        (left, right) => right.lastReadChapter!.progress!.updatedAt
            .compareTo(left.lastReadChapter!.progress!.updatedAt),
      );
    return SingleChildScrollView(
      key: homePageKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SectionTitle(
            key: homeUpdatesSectionKey,
            title: '更新漫画',
            subtitle: updates.isEmpty ? '导入漫画后会显示最近更新' : null,
          ),
          const SizedBox(height: 10),
          _buildHorizontalComics(updates),
          const SizedBox(height: 24),
          _SectionTitle(
            key: homeHistorySectionKey,
            title: '阅读历史',
            subtitle: history.isEmpty ? '开始阅读后会保留最后位置' : null,
          ),
          const SizedBox(height: 10),
          _buildHorizontalComics(history, history: true),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: localImageFolderImportKey,
            onPressed: _picking || _pickingFolder ? null : _importImageFolder,
            icon: _pickingFolder
                ? const SizedBox.square(
                    key: localImageFolderPickerProgressKey,
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.create_new_folder_outlined),
            label: const Text('导入漫画文件夹'),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            key: homeDiagnosticsKey,
            tilePadding: EdgeInsets.zero,
            title: const Text('开发与媒体诊断'),
            subtitle: const Text('普通阅读无需使用'),
            children: <Widget>[_buildImportAndDemoCards()],
          ),
        ],
      ),
    );
  }

  Widget _buildHorizontalComics(
    List<LibraryComic> comics, {
    bool history = false,
  }) {
    if (comics.isEmpty) {
      return const SizedBox(
        height: 92,
        child: Card(
          child: Center(child: Text('暂无内容')),
        ),
      );
    }
    return SizedBox(
      height: ComicCoverCard.cardExtent,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: comics.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final comic = comics[index];
          final resume = comic.resumeChapter;
          return SizedBox(
            width: ComicCoverCard.cardWidth,
            child: ComicCoverCard(
              key: resume == null
                  ? ValueKey<String>('comic-entry:${comic.identity}')
                  : history
                      ? historyChapterEntryKey(
                          resume.chapter.sourceId,
                          resume.chapter.chapterId,
                        )
                      : importedChapterEntryKey(
                          resume.chapter.sourceId,
                          resume.chapter.chapterId,
                        ),
              comic: comic,
              preference: _preferenceForComic(comic),
              coverBytes: _coverLoaderForComic(comic),
              downloadProgress: _downloadProgressForComic(comic),
              onTap: () => unawaited(_openComic(comic)),
              onLongPress: () {
                if (resume == null || _hasDetails(comic)) {
                  unawaited(_openComicDetails(comic));
                } else {
                  unawaited(_openImportedChapter(resume));
                }
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildImportAndDemoCards() {
    return Column(
      children: <Widget>[
        _DemoCard(
          key: libraryDiagnosticsEntryKey,
          icon: Icons.rule_folder_outlined,
          title: '书架迁移诊断',
          subtitle: '查看、复制并明确确认旧数据库来源归属；不会删除记录。',
          onTap: _openLibraryDiagnostics,
        ),
        const SizedBox(height: 10),
        _DemoCard(
          key: localWebpImportKey,
          icon: Icons.file_open,
          title: '导入本地 WebP',
          subtitle: '单文件 Flutter/native 播放器诊断入口。',
          trailing: _picking
              ? const SizedBox.square(
                  key: localWebpPickerProgressKey,
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _picking || _pickingFolder ? null : _importWebp,
        ),
        const SizedBox(height: 10),
        _DemoCard(
          key: bundledWebpEntryKey,
          icon: Icons.animation,
          title: '内置动图 WebP',
          subtitle: '真实 assets 与播放引擎切换诊断。',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const WebpCatalogScreen()),
          ),
        ),
        const SizedBox(height: 10),
        _DemoCard(
          key: mediaPipelineReaderEntryKey,
          icon: Icons.texture,
          title: 'Reader 媒体管线',
          subtitle: '真实需求、artifact、decode 和 present 链路。',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const MediaPipelineReaderScreen(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _DemoCard(
          key: staticDemoEntryKey,
          icon: Icons.menu_book,
          title: '100 页静态章节',
          subtitle: 'Reader viewport 和 demand 基线。',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const StaticDemoScreen()),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmRemoveComic(LibraryComic comic) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除漫画'),
        content: Text('从书架和本地记录中删除“${comic.title}”？此操作不可撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _removeComic(comic);
    if (mounted && _managedComicIdentities.contains(comic.identity)) {
      setState(() {
        _managedComicIdentities.remove(comic.identity);
        if (_managedComicIdentities.isEmpty) {
          _batchManagement = false;
        }
      });
    }
  }

  Future<void> _copyComicInfo(LibraryComic comic) async {
    final sources = comic.chapters
        .map((entry) => entry.chapter.directoryId)
        .where((value) => value.isNotEmpty)
        .toSet()
        .join('\n');
    await Clipboard.setData(
      ClipboardData(
        text: sources.isEmpty ? comic.title : '${comic.title}\n$sources',
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('漫画信息已复制')),
      );
    }
  }

  Future<void> _moveComicToCategory(
    LibraryComic comic,
    String? targetCategoryId,
  ) async {
    final preference = _preferenceForComic(comic);
    final ids = preference.categoryIds.toSet();
    final current = _selectedCategoryId;
    if (current != null) {
      ids.remove(current);
    }
    if (targetCategoryId != null) {
      ids.add(targetCategoryId);
    }
    await _savePreference(preference.copyWith(categoryIds: ids));
  }

  List<PopupMenuEntry<String>> _moveMenuEntries() {
    final currentCategoryId = _selectedCategoryId;
    return <PopupMenuEntry<String>>[
      if (currentCategoryId != null)
        PopupMenuItem<String>(
          key: bookshelfMoveToCategoryKey('__uncategorized__'),
          value: '__uncategorized__',
          child: const Row(
            children: <Widget>[
              Icon(Icons.label_off_outlined),
              SizedBox(width: 10),
              Text('移出当前分类'),
            ],
          ),
        ),
      for (final category in _categories)
        if (category.categoryId != currentCategoryId)
          PopupMenuItem<String>(
            key: bookshelfMoveToCategoryKey(category.categoryId),
            value: category.categoryId,
            child: Row(
              children: <Widget>[
                const Icon(Icons.label_outline),
                const SizedBox(width: 10),
                Text('移动到 ${category.name}'),
              ],
            ),
          ),
    ];
  }

  Widget _comicMovePopup(LibraryComic comic) {
    final entries = _moveMenuEntries();
    return PopupMenuButton<String>(
      key: comicMoveKey(comic.sourceId, comic.comicId),
      tooltip: '迁移到其他分类',
      enabled: entries.isNotEmpty,
      icon: const Icon(Icons.drive_file_move_outline),
      onSelected: (target) => unawaited(
        _moveComicToCategory(
          comic,
          target == '__uncategorized__' ? null : target,
        ),
      ),
      itemBuilder: (_) => entries,
    );
  }

  Future<void> _moveManagedComicsToCategory(String? targetCategoryId) async {
    final selected = _selectedManagedComics();
    for (final comic in selected) {
      await _moveComicToCategory(comic, targetCategoryId);
    }
    if (mounted) {
      setState(_clearManagedSelection);
    }
  }

  Future<void> _copyManagedComicInfo() async {
    final selected = _selectedManagedComics();
    final lines = <String>[
      for (final comic in selected) '${comic.title} (${comic.sourceId})',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已复制 ${selected.length} 部漫画信息')),
      );
    }
  }

  Future<void> _deleteManagedComics() async {
    final selected = _selectedManagedComics();
    if (selected.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${selected.length} 部漫画？'),
        content: const Text('将删除书架记录、章节元数据与阅读状态；离线文件需在下载管理中单独清理。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    for (final comic in selected) {
      await _removeComic(comic);
    }
    if (mounted) {
      setState(_clearManagedSelection);
    }
  }

  Future<void> _addComicsToSelectedCategory() async {
    final categoryId = _selectedCategoryId;
    if (categoryId == null) {
      return;
    }
    LibraryCategory? category;
    for (final item in _categories) {
      if (item.categoryId == categoryId) {
        category = item;
        break;
      }
    }
    if (category == null) {
      return;
    }
    final selectedCategory = category;
    final candidates = _libraryComics
        .where((comic) => _preferenceForComic(comic).inShelf)
        .where(
          (comic) => !_preferenceForComic(comic).categoryIds.contains(categoryId),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所有书架漫画都已在该分类中')),
      );
      return;
    }
    final selected = <String>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('添加到“${selectedCategory.name}”'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final comic = candidates[index];
                return CheckboxListTile(
                  value: selected.contains(comic.identity),
                  title: Text(comic.title),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (checked) {
                    setDialogState(() {
                      if (checked ?? false) {
                        selected.add(comic.identity);
                      } else {
                        selected.remove(comic.identity);
                      }
                    });
                  },
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) {
      return;
    }
    for (final comic in candidates.where(
      (comic) => selected.contains(comic.identity),
    )) {
      final preference = _preferenceForComic(comic);
      await _savePreference(
        preference.copyWith(
          categoryIds: <String>{...preference.categoryIds, categoryId},
        ),
      );
    }
  }

  Future<void> _reorderCustomComic(
    String draggedComicIdentity,
    String targetComicIdentity,
  ) async {
    if (draggedComicIdentity == targetComicIdentity) {
      return;
    }
    final comics = _filteredShelfComics();
    final oldIndex =
        comics.indexWhere((comic) => comic.identity == draggedComicIdentity);
    final targetIndex =
        comics.indexWhere((comic) => comic.identity == targetComicIdentity);
    if (oldIndex < 0 || targetIndex < 0) {
      return;
    }
    await _reorderCustom(
      oldIndex,
      targetIndex > oldIndex ? targetIndex + 1 : targetIndex,
    );
  }

  void _handleShelfTap(LibraryComic comic) {
    if (_manageShelf) {
      if (_batchManagement) {
        _toggleBatchSelection(comic);
      }
      return;
    }
    unawaited(_openComic(comic));
  }

  Widget _buildBatchManagementBar() {
    final selected = _selectedManagedComics();
    final moveEntries = _moveMenuEntries();
    return Card(
      key: bookshelfBatchBarKey,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '已选择 ${selected.length} 部',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            PopupMenuButton<String>(
              key: bookshelfBatchMoveKey,
              tooltip: '批量迁移分类',
              enabled: moveEntries.isNotEmpty,
              icon: const Icon(Icons.drive_file_move_outline),
              onSelected: (target) => unawaited(
                _moveManagedComicsToCategory(
                  target == '__uncategorized__' ? null : target,
                ),
              ),
              itemBuilder: (_) => moveEntries,
            ),
            IconButton(
              tooltip: '复制所选漫画',
              onPressed: selected.isEmpty ? null : _copyManagedComicInfo,
              icon: const Icon(Icons.copy_outlined),
            ),
            IconButton(
              key: bookshelfBatchClearKey,
              tooltip: '清除选择',
              onPressed: () => setState(_clearManagedSelection),
              icon: const Icon(Icons.close),
            ),
            const SizedBox(width: 14),
            const SizedBox(height: 32, child: VerticalDivider(width: 18)),
            const SizedBox(width: 8),
            IconButton(
              key: bookshelfBatchDeleteKey,
              tooltip: '批量删除',
              color: Theme.of(context).colorScheme.error,
              onPressed: selected.isEmpty ? null : _deleteManagedComics,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryTile(LibraryComic comic) {
    final selected = _managedComicIdentities.contains(comic.identity);
    final card = ComicCoverCard(
      key: comicCoverKey(comic.sourceId, comic.comicId),
      comic: comic,
      preference: _preferenceForComic(comic),
      coverBytes: _coverLoaderForComic(comic),
      downloadProgress: _downloadProgressForComic(comic),
      selected: selected,
      onTap: () => _handleShelfTap(comic),
      onLongPress: _manageShelf
          ? () => _startBatchSelection(comic)
          : () {
              final resume = comic.resumeChapter;
              if (resume == null || _hasDetails(comic)) {
                unawaited(_openComicDetails(comic));
              } else {
                unawaited(_openImportedChapter(resume));
              }
            },
    );
    Widget tile = card;
    if (_manageShelf && !_batchManagement) {
      tile = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          card,
          Positioned(
            top: 4,
            right: 4,
            child: _CoverActionSurface(
              child: IconButton(
                key: comicDeleteKey(comic.sourceId, comic.comicId),
                tooltip: '删除漫画',
                color: Theme.of(context).colorScheme.error,
                onPressed: () => _confirmRemoveComic(comic),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: _CoverActionSurface(child: _comicMovePopup(comic)),
          ),
          if (_sortMode == LibrarySortMode.custom && !_batchManagement)
            Positioned(
              top: 4,
              left: 4,
              child: Draggable<String>(
                key: comicReorderKey(comic.sourceId, comic.comicId),
                data: comic.identity,
                feedback: Material(
                  elevation: 10,
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: ComicCoverCard.cardWidth,
                    height: ComicCoverCard.cardExtent,
                    child: card,
                  ),
                ),
                childWhenDragging: const _CoverActionSurface(
                  child: Icon(Icons.drag_indicator),
                ),
                child: const _CoverActionSurface(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (!_manageShelf ||
        _sortMode != LibrarySortMode.custom ||
        _batchManagement) {
      return tile;
    }
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != comic.identity,
      onAcceptWithDetails: (details) {
        unawaited(_reorderCustomComic(details.data, comic.identity));
      },
      builder: (context, candidates, rejected) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: candidates.isEmpty
              ? null
              : Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
        ),
        child: tile,
      ),
    );
  }

  Widget _buildShelfGallery(List<LibraryComic> comics) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final candidateCount = ((constraints.maxWidth + spacing) /
                (ComicCoverCard.cardWidth + spacing))
            .floor();
        final count = candidateCount < 1 ? 1 : candidateCount;
        final usedWidth = count * ComicCoverCard.cardWidth +
            (count - 1) * spacing;
        final centeredPadding = (constraints.maxWidth - usedWidth) / 2;
        final sidePadding = centeredPadding < 12 ? 12.0 : centeredPadding;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(sidePadding, 8, sidePadding, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisExtent: ComicCoverCard.cardExtent,
            crossAxisSpacing: spacing,
            mainAxisSpacing: 12,
          ),
          itemCount: comics.length,
          itemBuilder: (context, index) => _buildGalleryTile(comics[index]),
        );
      },
    );
  }

  Widget _buildShelfList(List<LibraryComic> comics) {
    Widget item(LibraryComic comic, int index) => _ShelfListTile(
          key: ValueKey<String>(comic.identity),
          comic: comic,
          preference: _preferenceForComic(comic),
          coverBytes: _coverLoaderForComic(comic),
          downloadProgress: _downloadProgressForComic(comic),
          selected: _managedComicIdentities.contains(comic.identity),
          onTap: () => _handleShelfTap(comic),
          onLongPress: _manageShelf
              ? () => _startBatchSelection(comic)
              : () {
                  final resume = comic.resumeChapter;
                  if (resume == null || _hasDetails(comic)) {
                    unawaited(_openComicDetails(comic));
                  } else {
                    unawaited(_openImportedChapter(resume));
                  }
                },
          trailing: _manageShelf && !_batchManagement
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _comicMovePopup(comic),
                    IconButton(
                      key: comicDeleteKey(comic.sourceId, comic.comicId),
                      tooltip: '删除漫画',
                      color: Theme.of(context).colorScheme.error,
                      onPressed: () => _confirmRemoveComic(comic),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    if (_sortMode == LibrarySortMode.custom && !_batchManagement)
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                  ],
                )
              : null,
        );
    if (_manageShelf &&
        _sortMode == LibrarySortMode.custom &&
        !_batchManagement) {
      return ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: comics.length,
        onReorder: (oldIndex, newIndex) {
          unawaited(_reorderCustom(oldIndex, newIndex));
        },
        itemBuilder: (context, index) => item(comics[index], index),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: comics.length,
      itemBuilder: (context, index) => item(comics[index], index),
    );
  }

  PopupMenuItem<LibrarySortMode> _sortMenuItem(
    Key key,
    LibrarySortMode mode,
    String label,
  ) {
    return PopupMenuItem<LibrarySortMode>(
      key: key,
      value: mode,
      child: Row(
        children: <Widget>[
          Icon(
            _sortMode == mode
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildBookshelfPage() {
    final comics = _filteredShelfComics();
    return Column(
      key: bookshelfPageKey,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: SegmentedButton<_SourceFilter>(
                      key: bookshelfSourceFilterKey,
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<_SourceFilter>>[
                        ButtonSegment(
                          value: _SourceFilter.all,
                          label: Text('全部'),
                        ),
                        ButtonSegment(
                          value: _SourceFilter.local,
                          label: Text('本地'),
                        ),
                        ButtonSegment(
                          value: _SourceFilter.remote,
                          label: Text('远程'),
                        ),
                      ],
                      selected: <_SourceFilter>{_sourceFilter},
                      onSelectionChanged: (selection) {
                        setState(() => _sourceFilter = selection.single);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: bookshelfManageKey,
                    onPressed: () => setState(() {
                      _manageShelf = !_manageShelf;
                      _clearManagedSelection();
                    }),
                    icon: Icon(
                      _manageShelf ? Icons.done : Icons.edit_outlined,
                    ),
                    label: Text(_manageShelf ? '完成' : '管理'),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    key: bookshelfViewKey,
                    tooltip: _shelfViewMode == _ShelfViewMode.gallery
                        ? '切换列表视图'
                        : '切换画廊视图',
                    onPressed: () => setState(() {
                      _shelfViewMode = _shelfViewMode == _ShelfViewMode.gallery
                          ? _ShelfViewMode.list
                          : _ShelfViewMode.gallery;
                    }),
                    icon: Icon(
                      _shelfViewMode == _ShelfViewMode.gallery
                          ? Icons.view_list_outlined
                          : Icons.grid_view_outlined,
                    ),
                  ),
                  PopupMenuButton<LibrarySortMode>(
                    key: bookshelfSortKey,
                    tooltip: '排序方式',
                    initialValue: _sortMode,
                    onSelected: (mode) => setState(() {
                      _sortMode = mode;
                      _clearManagedSelection();
                    }),
                    itemBuilder: (context) => <PopupMenuEntry<LibrarySortMode>>[
                      _sortMenuItem(
                        bookshelfSortRecentKey,
                        LibrarySortMode.recent,
                        '最近更新',
                      ),
                      _sortMenuItem(
                        bookshelfSortTitleKey,
                        LibrarySortMode.title,
                        '标题',
                      ),
                      _sortMenuItem(
                        bookshelfSortPageCountKey,
                        LibrarySortMode.pageCount,
                        '页数',
                      ),
                      _sortMenuItem(
                        bookshelfSortCustomKey,
                        LibrarySortMode.custom,
                        '自定义排序',
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.sort),
                          const SizedBox(width: 6),
                          Text(_librarySortLabel(_sortMode)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: <Widget>[
              ChoiceChip(
                label: const Text('全部分类'),
                selected: _selectedCategoryId == null,
                showCheckmark: false,
                onSelected: (_) => setState(() {
                  _selectedCategoryId = null;
                  _clearManagedSelection();
                }),
              ),
              const SizedBox(width: 8),
              for (final category in _categories) ...<Widget>[
                GestureDetector(
                  onLongPress:
                      _manageShelf ? () => _deleteCategory(category) : null,
                  child: ChoiceChip(
                    label: Text(category.name),
                    selected: _selectedCategoryId == category.categoryId,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _selectedCategoryId = category.categoryId;
                      _clearManagedSelection();
                    }),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              ActionChip(
                key: bookshelfAddCategoryKey,
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('分类'),
                onPressed: _createCategory,
              ),
              if (_selectedCategoryId != null) ...<Widget>[
                const SizedBox(width: 8),
                ActionChip(
                  key: bookshelfAddComicToCategoryKey,
                  avatar: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('添加漫画'),
                  onPressed: _addComicsToSelectedCategory,
                ),
              ],
            ],
          ),
        ),
        if (_manageShelf &&
            _batchManagement &&
            _managedComicIdentities.isNotEmpty)
          _buildBatchManagementBar(),
        if (_manageShelf && _sortMode == LibrarySortMode.custom)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('使用封面左上角拖动柄调整顺序；长按封面进入批量选择'),
            ),
          ),
        Expanded(
          child: comics.isEmpty
              ? const Center(child: Text('当前筛选下没有漫画'))
              : _shelfViewMode == _ShelfViewMode.gallery
                  ? _buildShelfGallery(comics)
                  : _buildShelfList(comics),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          switch (_navigationIndex) {
            0 => 'zic',
            1 => '书架',
            _ => '漫画源',
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
          if (_navigationIndex != 2)
            IconButton(
              key: downloadManagerEntryKey,
              tooltip: '下载管理',
              onPressed: _openDownloadManager,
              icon: const Icon(Icons.download_for_offline_outlined),
            ),
          if (_navigationIndex != 2)
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

enum ComicDownloadProgressKind { active, offline }

final class ComicDownloadProgress {
  const ComicDownloadProgress.active({
    required this.label,
    required double completedPageUnits,
    required this.totalPages,
  })  : kind = ComicDownloadProgressKind.active,
        completedPageUnits = completedPageUnits,
        offlineChapters = 0,
        assert(completedPageUnits >= 0),
        assert(totalPages > 0);

  const ComicDownloadProgress.offline({
    required this.label,
    required this.offlineChapters,
  })  : kind = ComicDownloadProgressKind.offline,
        completedPageUnits = 0,
        totalPages = 0,
        assert(offlineChapters > 0);

  final ComicDownloadProgressKind kind;
  final String label;
  final double completedPageUnits;
  final int totalPages;
  final int offlineChapters;

  bool get isActive => kind == ComicDownloadProgressKind.active;

  int get completedPages => completedPageUnits.floor();

  double get fraction => isActive
      ? (completedPageUnits / totalPages).clamp(0, 1).toDouble()
      : 1;
}

final class ComicCoverCard extends StatelessWidget {
  const ComicCoverCard({
    required this.comic,
    required this.preference,
    required this.coverBytes,
    required this.onTap,
    this.onLongPress,
    this.downloadProgress,
    this.selected = false,
    super.key,
  });

  static const double coverAspectRatio = 3 / 4;
  static const double cardWidth = 132;
  static const double cardExtent = 180;

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      selected: selected,
      label: '${comic.title}，来源 ${comic.sourceId}',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: AspectRatio(
              aspectRatio: coverAspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _CoverImage(loader: coverBytes),
                  if (downloadProgress != null)
                    _DownloadWatermark(progress: downloadProgress!),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: _CoverTitleGradient(),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      comic.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.12,
                        fontWeight: FontWeight.w700,
                        shadows: <Shadow>[
                          Shadow(blurRadius: 3, color: Colors.black),
                        ],
                      ),
                    ),
                  ),
                  if (preference.liked || preference.collected)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(
                            preference.collected
                                ? Icons.bookmark
                                : Icons.favorite,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CoverTitleGradient extends StatelessWidget {
  const _CoverTitleGradient();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: 78,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.transparent,
                Colors.black.withValues(alpha: 0.78),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.loader});

  final Future<Uint8List> Function() loader;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: Future<Uint8List>.sync(loader),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          );
        }
        if (snapshot.hasError) {
          return const ColoredBox(
            color: Color(0xff20232a),
            child: Icon(Icons.broken_image_outlined, size: 38),
          );
        }
        return const ColoredBox(
          color: Color(0xff20232a),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}

final class _DownloadWatermark extends StatelessWidget {
  const _DownloadWatermark({required this.progress});

  final ComicDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    if (!progress.isActive) {
      return Semantics(
        label: progress.label,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(
                  Icons.download_done,
                  size: 15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final percent = (progress.fraction * 100).round();
    return Semantics(
      label: '${progress.label}，$percent%，'
          '${progress.completedPages}/${progress.totalPages} 页',
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: progress.fraction,
              widthFactor: 1,
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.44),
              ),
            ),
          ),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.68),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  '${progress.label}\n$percent% · '
                  '${progress.completedPages}/${progress.totalPages} 页',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class ComicDetailsScreen extends StatefulWidget {
  const ComicDetailsScreen({
    required this.comic,
    required this.preference,
    required this.categories,
    required this.readStates,
    required this.coverBytes,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    this.onDownloadChapter,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final Map<String, ChapterReadState> readStates;
  final Future<Uint8List> Function() coverBytes;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final Future<void> Function(ImportedLibraryEntry chapter) onOpenChapter;
  final Future<void> Function(ImportedLibraryEntry chapter)? onDownloadChapter;

  @override
  State<ComicDetailsScreen> createState() => _ComicDetailsScreenState();
}

final class _ComicDetailsScreenState extends State<ComicDetailsScreen> {
  late ComicPreference _preference;
  late Map<String, ChapterReadState> _readStates;

  @override
  void initState() {
    super.initState();
    _preference = widget.preference;
    _readStates = Map<String, ChapterReadState>.from(widget.readStates);
  }

  details.ComicDetailsLibrarySnapshot _snapshot() {
    return details.ComicDetailsLibrarySnapshot(
      chapters: widget.comic.chapters,
      sourceChapters: widget.comic.sourceChapters,
      readStates: _readStates,
      preference: _preference,
    );
  }

  @override
  Widget build(BuildContext context) {
    return details.LocalComicDetailsScreen(
      comic: widget.comic,
      initialLibrary: _snapshot(),
      categories: widget.categories,
      loadCover: ({
        required String sourceId,
        required Uri? coverUri,
        required ImportedLibraryEntry? fallbackChapter,
      }) =>
          widget.coverBytes(),
      reloadLibrary: ({required bool refreshContent}) async => _snapshot(),
      onPreferenceChanged: (preference) async {
        _preference = preference;
        await widget.onPreferenceChanged(preference);
      },
      onReadChanged: (chapter, isRead) async {
        final state = ChapterReadState(
          sourceId: chapter.chapter.sourceId,
          comicId: chapter.chapter.comicId,
          chapterId: chapter.chapter.chapterId,
          isRead: isRead,
          updatedAt: DateTime.now().toUtc(),
        );
        _readStates = <String, ChapterReadState>{
          ..._readStates,
          state.identity: state,
        };
        await widget.onReadChanged(chapter, isRead);
      },
      onOpenChapter: (chapter, {required bool refreshRemote}) =>
          widget.onOpenChapter(chapter),
      onDownloadChapter: widget.onDownloadChapter ?? (_) async {},
      inspectChapterDownload: (chapter) async =>
          ChapterDownloadSnapshot.idle(chapter),
      downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
      onDownloadComic: (chapters) async {
        final download = widget.onDownloadChapter;
        if (download == null) {
          return;
        }
        for (final chapter in chapters) {
          await download(chapter);
        }
      },
    );
  }
}

final class _CoverActionSurface extends StatelessWidget {
  const _CoverActionSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.68),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconTheme(
        data: const IconThemeData(color: Colors.white, size: 20),
        child: SizedBox.square(dimension: 40, child: Center(child: child)),
      ),
    );
  }
}

final class _ShelfListTile extends StatelessWidget {
  const _ShelfListTile({
    required this.comic,
    required this.preference,
    required this.coverBytes,
    required this.downloadProgress,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitle = comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页';
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: SizedBox(
          width: 48,
          child: AspectRatio(
            aspectRatio: ComicCoverCard.coverAspectRatio,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _CoverImage(loader: coverBytes),
                  if (downloadProgress != null)
                    _DownloadWatermark(progress: downloadProgress!),
                ],
              ),
            ),
          ),
        ),
        title: Text(comic.title),
        subtitle: Text(subtitle),
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: trailing ??
            (selected
                ? Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null),
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle, super.key});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (subtitle != null)
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

final class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, size: 34),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: trailing ?? const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
