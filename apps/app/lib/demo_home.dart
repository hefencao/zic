import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:local_media/local_media.dart';

import 'static_demo.dart';
import 'webp_demo.dart';

const homePageKey = ValueKey<String>('home-page');
const bookshelfPageKey = ValueKey<String>('bookshelf-page');
const homeUpdatesSectionKey = ValueKey<String>('home-updates-section');
const homeHistorySectionKey = ValueKey<String>('home-history-section');
const bookshelfManageKey = ValueKey<String>('bookshelf-manage');
const bookshelfSourceFilterKey = ValueKey<String>('bookshelf-source-filter');
const bookshelfSortKey = ValueKey<String>('bookshelf-sort');
const bookshelfAddCategoryKey = ValueKey<String>('bookshelf-add-category');
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
const importedLibrarySectionKey = ValueKey<String>('imported-library-section');
const importedLibraryLoadingKey = ValueKey<String>('imported-library-loading');
const importedLibraryErrorKey = ValueKey<String>('imported-library-error');
Key importedChapterEntryKey(String chapterId) =>
    ValueKey<String>('imported-chapter:$chapterId');
Key historyChapterEntryKey(String chapterId) =>
    ValueKey<String>('history-chapter:$chapterId');
Key importedChapterRefreshKey(String chapterId) =>
    ValueKey<String>('refresh-imported-chapter:$chapterId');
Key importedChapterRefreshProgressKey(String chapterId) =>
    ValueKey<String>('refreshing-imported-chapter:$chapterId');
Key importedChapterRemoveKey(String chapterId) =>
    ValueKey<String>('remove-imported-chapter:$chapterId');
Key comicCoverKey(String comicId) => ValueKey<String>('comic-cover:$comicId');
Key comicDeleteKey(String comicId) => ValueKey<String>('comic-delete:$comicId');
Key comicCategoryKey(String comicId) =>
    ValueKey<String>('comic-category:$comicId');
Key chapterReadKey(String chapterId) =>
    ValueKey<String>('chapter-read:$chapterId');
@Deprecated('Use localImageFolderPickerProgressKey')
const localWebpFolderPickerProgressKey = localImageFolderPickerProgressKey;

enum _SourceFilter { all, local, remote }

final class DemoHome extends StatefulWidget {
  const DemoHome({
    required this.picker,
    required this.folderPicker,
    this.folderRefresher = defaultImageFolderRefresher,
    this.libraryStore,
    super.key,
  });

  final WebpPicker picker;
  final ImageFolderPicker folderPicker;
  final ImageFolderRefresher folderRefresher;
  final ImportedLibraryStore? libraryStore;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

final class _DemoHomeState extends State<DemoHome> {
  late final ImportedLibraryStore _library;
  late final bool _ownsLibrary;
  late final Future<void> _libraryReady;
  final Map<String, Future<Uint8List>> _coverBytes =
      <String, Future<Uint8List>>{};
  final Set<String> _refreshingChapters = <String>{};

  List<ImportedLibraryEntry> _libraryEntries = const <ImportedLibraryEntry>[];
  List<LibraryCategory> _categories = const <LibraryCategory>[];
  Map<String, ComicPreference> _preferences =
      const <String, ComicPreference>{};
  Map<String, ChapterReadState> _chapterReadStates =
      const <String, ChapterReadState>{};
  Object? _libraryError;
  bool _libraryLoading = true;
  bool _picking = false;
  bool _pickingFolder = false;
  bool _manageShelf = false;
  int _navigationIndex = 0;
  _SourceFilter _sourceFilter = _SourceFilter.all;
  String? _selectedCategoryId;
  LibrarySortMode _sortMode = LibrarySortMode.recent;

  List<LibraryComic> get _libraryComics =>
      aggregateImportedLibrary(_libraryEntries);

  @override
  void initState() {
    super.initState();
    _ownsLibrary = widget.libraryStore == null;
    _library = widget.libraryStore ?? MemoryImportedLibraryStore();
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
    final categories = await _library.listCategories();
    final storedPreferences = await _library.listComicPreferences();
    final preferences = <String, ComicPreference>{
      for (final preference in storedPreferences)
        preference.comicId: preference,
    };
    var nextOrder = preferences.values.fold<int>(
          0,
          (value, preference) =>
              preference.customOrder >= value
                  ? preference.customOrder + 1
                  : value,
        );
    for (final entry in entries) {
      if (preferences.containsKey(entry.chapter.comicId)) {
        continue;
      }
      final preference = ComicPreference.defaults(
        comicId: entry.chapter.comicId,
        customOrder: nextOrder++,
      ).copyWith(updatedAt: DateTime.now().toUtc());
      preferences[preference.comicId] = preference;
      await _library.saveComicPreference(preference);
    }
    final readStates = <String, ChapterReadState>{};
    for (final comicId in entries.map((entry) => entry.chapter.comicId).toSet()) {
      for (final state in await _library.listChapterReadStates(comicId)) {
        readStates[state.chapterId] = state;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _libraryEntries = entries;
      _categories = categories;
      _preferences = Map<String, ComicPreference>.unmodifiable(preferences);
      _chapterReadStates =
          Map<String, ChapterReadState>.unmodifiable(readStates);
      _libraryError = null;
      _libraryLoading = false;
    });
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
    if (_ownsLibrary) {
      unawaited(_library.close());
    }
    super.dispose();
  }

  ComicPreference _preferenceForComic(LibraryComic comic) {
    return _preferences[comic.comicId] ??
        ComicPreference.defaults(comicId: comic.comicId);
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
        updated.comicId: updated,
      };
    });
  }

  Future<void> _setChapterRead(
    ImportedLibraryEntry entry,
    bool isRead,
  ) async {
    final state = ChapterReadState(
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
        state.chapterId: state,
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
          await _library.getComicPreference(record.comicId);
      if (existingPreference == null) {
        await _library.saveComicPreference(
          ComicPreference.defaults(
            comicId: record.comicId,
            customOrder: _preferences.length,
          ).copyWith(updatedAt: DateTime.now().toUtc()),
        );
      }
      final entry = await _library.get(record.chapterId);
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

  Future<void> _openImportedChapter(ImportedLibraryEntry entry) async {
    await _setChapterRead(entry, true);
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImportedImageChapterScreen(
          record: entry.chapter,
          initialProgress: entry.progress,
          onProgressChanged: _library.saveProgress,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _openComicDetails(LibraryComic comic) async {
    final preference = _preferenceForComic(comic);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicDetailsScreen(
          comic: comic,
          preference: preference,
          categories: _categories,
          readStates: <String, ChapterReadState>{
            for (final chapter in comic.chapters)
              if (_chapterReadStates.containsKey(chapter.chapter.chapterId))
                chapter.chapter.chapterId:
                    _chapterReadStates[chapter.chapter.chapterId]!,
          },
          coverBytes: _coverLoaderForComic(comic),
          onPreferenceChanged: _savePreference,
          onReadChanged: _setChapterRead,
          onOpenChapter: _openImportedChapter,
        ),
      ),
    );
  }

  Future<Uint8List> Function() _coverLoader(ImportedLibraryEntry entry) {
    final page = entry.chapter.pages.first;
    return () => _coverBytes.putIfAbsent(
          page.sourceId,
          () => readLocalImageSource(page.sourceId),
        );
  }

  Future<Uint8List> Function() _coverLoaderForComic(LibraryComic comic) {
    return _coverLoader(comic.coverChapter);
  }

  bool _hasDetails(LibraryComic comic) {
    return comic.hasMultipleChapters ||
        comic.chapters.any((entry) => entry.chapter.sourceId != 'local-folder');
  }

  Future<void> _openComic(LibraryComic comic) async {
    if (comic.hasMultipleChapters) {
      await _openComicDetails(comic);
      return;
    }
    await _openImportedChapter(comic.resumeChapter);
  }

  Future<void> _refreshImportedChapter(ImportedLibraryEntry entry) async {
    final chapterId = entry.chapter.chapterId;
    if (_refreshingChapters.contains(chapterId)) {
      return;
    }
    setState(() => _refreshingChapters.add(chapterId));
    try {
      await _ensureLibraryReady();
      final folder = await widget.folderRefresher(entry.chapter);
      final scanned = imageFolderChapterRecord(
        folder,
        readingDirection: entry.chapter.readingDirection,
        importedAt: entry.chapter.importedAt,
      );
      final refreshed = entry.chapter.copyWith(
        directoryId: scanned.directoryId,
        displayName: scanned.displayName,
        sourceId: scanned.sourceId,
        sourceRevision: scanned.sourceRevision,
        pages: scanned.pages,
        readingDirection: scanned.readingDirection,
      );
      if (refreshed.chapterId != chapterId) {
        throw StateError('刷新结果改变了目录章节 identity');
      }
      final previousSources =
          entry.chapter.pages.map((page) => page.sourceId).toSet();
      final refreshedSources =
          refreshed.pages.map((page) => page.sourceId).toSet();
      final added = refreshedSources.difference(previousSources).length;
      final removed = previousSources.difference(refreshedSources).length;
      await _library.upsertChapter(refreshed);
      _coverBytes.clear();
      await _reloadLibrary();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '目录已刷新：${refreshed.pages.length} 页'
            '（新增 $added，移除 $removed）',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新图片文件夹失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingChapters.remove(chapterId));
      }
    }
  }

  Future<void> _removeImportedChapter(ImportedLibraryEntry entry) async {
    await _ensureLibraryReady();
    await _library.removeChapter(entry.chapter.chapterId);
    _coverBytes.remove(entry.chapter.pages.first.sourceId);
    if (mounted) {
      await _reloadLibrary();
    }
  }

  Future<void> _removeComic(LibraryComic comic) async {
    await _ensureLibraryReady();
    for (final entry in comic.chapters) {
      await _library.removeChapter(entry.chapter.chapterId);
      _coverBytes.remove(entry.chapter.pages.first.sourceId);
    }
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
          const SizedBox(height: 28),
          _SectionTitle(
            key: homeHistorySectionKey,
            title: '阅读历史',
            subtitle: history.isEmpty ? '开始阅读后会保留最后位置' : null,
          ),
          const SizedBox(height: 10),
          _buildHorizontalComics(history, history: true),
          const SizedBox(height: 28),
          Text('导入与媒体诊断', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          _buildImportAndDemoCards(),
          const SizedBox(height: 28),
          Text(
            '本地目录维护',
            key: importedLibrarySectionKey,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Card(child: _buildImportedLibraryMaintenance()),
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
      height: 226,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: comics.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final comic = comics[index];
          final resume = comic.resumeChapter;
          return SizedBox(
            width: 132,
            child: ComicCoverCard(
              key: history
                  ? historyChapterEntryKey(resume.chapter.chapterId)
                  : importedChapterEntryKey(resume.chapter.chapterId),
              comic: comic,
              preference: _preferenceForComic(comic),
              coverBytes: _coverLoaderForComic(comic),
              onTap: () => _openComic(comic),
              onLongPress: () => _hasDetails(comic)
                  ? _openComicDetails(comic)
                  : _openImportedChapter(resume),
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
          key: localImageFolderImportKey,
          icon: Icons.create_new_folder_outlined,
          title: '导入图片文件夹',
          subtitle: 'Android 文档树批量导入图片并加入书架。',
          trailing: _pickingFolder
              ? const SizedBox.square(
                  key: localImageFolderPickerProgressKey,
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _picking || _pickingFolder ? null : _importImageFolder,
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

  Widget _buildImportedLibraryMaintenance() {
    if (_libraryEntries.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.library_books_outlined),
        title: Text('尚未导入本地漫画'),
      );
    }
    return Column(
      children: <Widget>[
        for (final entry in _libraryEntries)
          ListTile(
            title: Text(entry.chapter.displayName),
            subtitle: Text(
              '${entry.chapter.pages.length} 页 · '
              '${entry.progress == null ? '未开始' : '第 ${entry.progress!.pageIndex + 1} 页'}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_refreshingChapters.contains(entry.chapter.chapterId))
                  SizedBox.square(
                    key: importedChapterRefreshProgressKey(
                      entry.chapter.chapterId,
                    ),
                    dimension: 24,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    key: importedChapterRefreshKey(entry.chapter.chapterId),
                    tooltip: '重新扫描目录',
                    onPressed: () => _refreshImportedChapter(entry),
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  key: importedChapterRemoveKey(entry.chapter.chapterId),
                  tooltip: '移除漫画',
                  onPressed: () => _removeImportedChapter(entry),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            onTap: () => _openImportedChapter(entry),
          ),
      ],
    );
  }

  Widget _buildBookshelfPage() {
    final comics = _filteredShelfComics();
    return Column(
      key: bookshelfPageKey,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text('书架', style: Theme.of(context).textTheme.titleLarge),
              ),
              TextButton.icon(
                key: bookshelfManageKey,
                onPressed: () => setState(() => _manageShelf = !_manageShelf),
                icon: Icon(_manageShelf ? Icons.done : Icons.edit_outlined),
                label: Text(_manageShelf ? '完成' : '管理'),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              SegmentedButton<_SourceFilter>(
                key: bookshelfSourceFilterKey,
                segments: const <ButtonSegment<_SourceFilter>>[
                  ButtonSegment(value: _SourceFilter.all, label: Text('全部')),
                  ButtonSegment(value: _SourceFilter.local, label: Text('本地')),
                  ButtonSegment(value: _SourceFilter.remote, label: Text('远程')),
                ],
                selected: <_SourceFilter>{_sourceFilter},
                onSelectionChanged: (selection) {
                  setState(() => _sourceFilter = selection.single);
                },
              ),
              const SizedBox(width: 12),
              DropdownButton<LibrarySortMode>(
                key: bookshelfSortKey,
                value: _sortMode,
                items: const <DropdownMenuItem<LibrarySortMode>>[
                  DropdownMenuItem(
                    value: LibrarySortMode.recent,
                    child: Text('最近更新'),
                  ),
                  DropdownMenuItem(
                    value: LibrarySortMode.title,
                    child: Text('标题'),
                  ),
                  DropdownMenuItem(
                    value: LibrarySortMode.pageCount,
                    child: Text('页数'),
                  ),
                  DropdownMenuItem(
                    value: LibrarySortMode.custom,
                    child: Text('自定义'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _sortMode = value);
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: <Widget>[
              FilterChip(
                label: const Text('全部分类'),
                selected: _selectedCategoryId == null,
                onSelected: (_) => setState(() => _selectedCategoryId = null),
              ),
              const SizedBox(width: 8),
              for (final category in _categories) ...<Widget>[
                InputChip(
                  label: Text(category.name),
                  selected: _selectedCategoryId == category.categoryId,
                  onPressed: () => setState(
                    () => _selectedCategoryId = category.categoryId,
                  ),
                  onDeleted:
                      _manageShelf ? () => _deleteCategory(category) : null,
                ),
                const SizedBox(width: 8),
              ],
              ActionChip(
                key: bookshelfAddCategoryKey,
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('分类'),
                onPressed: _createCategory,
              ),
            ],
          ),
        ),
        Expanded(
          child: comics.isEmpty
              ? const Center(child: Text('当前筛选下没有漫画'))
              : _sortMode == LibrarySortMode.custom
                  ? ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: comics.length,
                      onReorder: (oldIndex, newIndex) {
                        unawaited(_reorderCustom(oldIndex, newIndex));
                      },
                      itemBuilder: (context, index) {
                        final comic = comics[index];
                        return _ShelfListTile(
                          key: ValueKey<String>(comic.comicId),
                          comic: comic,
                          preference: _preferenceForComic(comic),
                          coverBytes: _coverLoaderForComic(comic),
                          manage: _manageShelf,
                          categories: _categories,
                          onTap: () => _openComic(comic),
                          onLongPress: () => _hasDetails(comic)
                              ? _openComicDetails(comic)
                              : _openImportedChapter(comic.resumeChapter),
                          onDelete: () => _removeComic(comic),
                          onToggleCategory: (categoryId) =>
                              _toggleCategory(comic, categoryId),
                        );
                      },
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 0.58,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: comics.length,
                      itemBuilder: (context, index) {
                        final comic = comics[index];
                        return Stack(
                          children: <Widget>[
                            Positioned.fill(
                              child: ComicCoverCard(
                                key: comicCoverKey(comic.comicId),
                                comic: comic,
                                preference: _preferenceForComic(comic),
                                coverBytes: _coverLoaderForComic(comic),
                                onTap: () => _openComic(comic),
                                onLongPress: () => _hasDetails(comic)
                                    ? _openComicDetails(comic)
                                    : _openImportedChapter(comic.resumeChapter),
                              ),
                            ),
                            if (_manageShelf)
                              Positioned(
                                top: 2,
                                right: 2,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _CategoryPopup(
                                      key: comicCategoryKey(comic.comicId),
                                      categories: _categories,
                                      selectedIds:
                                          _preferenceForComic(comic).categoryIds,
                                      onToggle: (categoryId) =>
                                          _toggleCategory(comic, categoryId),
                                    ),
                                    IconButton.filledTonal(
                                      key: comicDeleteKey(comic.comicId),
                                      tooltip: '删除漫画',
                                      onPressed: () => _removeComic(comic),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_navigationIndex == 0 ? 'zic' : '书架'),
        actions: <Widget>[
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
        ],
        onDestinationSelected: (index) {
          setState(() => _navigationIndex = index);
        },
      ),
    );
  }
}

final class ComicDownloadProgress {
  const ComicDownloadProgress({
    required this.completedPages,
    required this.totalPages,
  })  : assert(completedPages >= 0),
        assert(totalPages > 0),
        assert(completedPages <= totalPages);

  final int completedPages;
  final int totalPages;

  double get fraction => completedPages / totalPages;
}

final class ComicCoverCard extends StatelessWidget {
  const ComicCoverCard({
    required this.comic,
    required this.preference,
    required this.coverBytes,
    required this.onTap,
    required this.onLongPress,
    this.downloadProgress,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ComicDownloadProgress? downloadProgress;

  @override
  Widget build(BuildContext context) {
    final progress = comic.resumeChapter.progress;
    final scope = comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页';
    return Semantics(
      button: true,
      label: '${comic.title}，$scope',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _CoverImage(loader: coverBytes),
                    if (downloadProgress != null)
                      _DownloadWatermark(progress: downloadProgress!),
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
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              comic.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              progress == null
                  ? scope
                  : '上次 ${comic.resumeChapter.chapter.displayName} '
                      '第 ${progress.pageIndex + 1} 页',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
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
      future: loader(),
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
    final percent = (progress.fraction * 100).round();
    return Stack(
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
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                '$percent%\n${progress.completedPages}/${progress.totalPages} 页',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ),
      ],
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

  @override
  State<ComicDetailsScreen> createState() => _ComicDetailsScreenState();
}

final class _ComicDetailsScreenState extends State<ComicDetailsScreen> {
  late ComicPreference _preference;
  late Map<String, bool> _readStates;
  bool _descending = true;

  @override
  void initState() {
    super.initState();
    _preference = widget.preference;
    _readStates = <String, bool>{
      for (final chapter in widget.comic.chapters)
        chapter.chapter.chapterId:
            widget.readStates[chapter.chapter.chapterId]?.isRead ?? false,
    };
  }

  Future<void> _updatePreference(ComicPreference next) async {
    setState(() => _preference = next);
    await widget.onPreferenceChanged(next);
  }

  Future<void> _markRead(
    ImportedLibraryEntry chapter,
    bool value,
  ) async {
    final chapterId = chapter.chapter.chapterId;
    if (_readStates[chapterId] == value) {
      return;
    }
    setState(() => _readStates = <String, bool>{
          ..._readStates,
          chapterId: value,
        });
    await widget.onReadChanged(chapter, value);
  }

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final chapters = comic.chapters.toList(growable: false);
    final displayedChapters =
        _descending ? chapters.reversed.toList(growable: false) : chapters;
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(title: const Text('漫画详情')),
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 128,
                    height: 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _CoverImage(loader: widget.coverBytes),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          comic.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text('${comic.chapters.length} 章 · ${comic.totalPages} 页'),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          children: <Widget>[
                            _PreferenceButton(
                              icon: _preference.liked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              label: '喜欢',
                              selected: _preference.liked,
                              onPressed: () => _updatePreference(
                                _preference.copyWith(
                                  liked: !_preference.liked,
                                ),
                              ),
                            ),
                            _PreferenceButton(
                              icon: _preference.inShelf
                                  ? Icons.collections_bookmark
                                  : Icons.collections_bookmark_outlined,
                              label: '书架',
                              selected: _preference.inShelf,
                              onPressed: () => _updatePreference(
                                _preference.copyWith(
                                  inShelf: !_preference.inShelf,
                                ),
                              ),
                            ),
                            _PreferenceButton(
                              icon: _preference.collected
                                  ? Icons.bookmark
                                  : Icons.bookmark_border,
                              label: '收藏',
                              selected: _preference.collected,
                              onPressed: () => _updatePreference(
                                _preference.copyWith(
                                  collected: !_preference.collected,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (widget.categories.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            '分类',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final category in widget.categories)
                                FilterChip(
                                  label: Text(category.name),
                                  selected: _preference.categoryIds.contains(
                                    category.categoryId,
                                  ),
                                  onSelected: (_) {
                                    final ids = _preference.categoryIds.toSet();
                                    if (!ids.add(category.categoryId)) {
                                      ids.remove(category.categoryId);
                                    }
                                    unawaited(
                                      _updatePreference(
                                        _preference.copyWith(categoryIds: ids),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: ListTile(
              title: const Text('漫画章节'),
              subtitle: const Text('已阅读章节会黯淡；向右拖动可恢复未读'),
              trailing: IconButton(
                key: comicDetailsReverseKey,
                tooltip: _descending ? '切换正序' : '切换倒序',
                onPressed: () => setState(() => _descending = !_descending),
                icon: Icon(_descending ? Icons.south : Icons.north),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final chapter = displayedChapters[index];
                final chapterId = chapter.chapter.chapterId;
                final isRead = _readStates[chapterId] ?? false;
                return Dismissible(
                  key: chapterReadKey(chapterId),
                  direction: isRead
                      ? DismissDirection.startToEnd
                      : DismissDirection.none,
                  dismissThresholds: const <DismissDirection, double>{
                    DismissDirection.startToEnd: 0.18,
                  },
                  confirmDismiss: (_) async {
                    await _markRead(chapter, false);
                    return false;
                  },
                  background: Container(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: const Row(
                      children: <Widget>[
                        Icon(Icons.mark_chat_unread_outlined),
                        SizedBox(width: 8),
                        Text('恢复未读'),
                      ],
                    ),
                  ),
                  child: AnimatedOpacity(
                    opacity: isRead ? 0.42 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: ListTile(
                      leading: Icon(
                        isRead
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(chapter.chapter.displayName),
                      subtitle: Text('${chapter.chapter.pages.length} 页'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await _markRead(chapter, true);
                        await widget.onOpenChapter(chapter);
                      },
                    ),
                  ),
                );
              },
              childCount: displayedChapters.length,
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
        ],
      ),
    );
  }
}

final class _PreferenceButton extends StatelessWidget {
  const _PreferenceButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: label,
      isSelected: selected,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

final class _ShelfListTile extends StatelessWidget {
  const _ShelfListTile({
    required this.comic,
    required this.preference,
    required this.coverBytes,
    required this.manage,
    required this.categories,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onToggleCategory,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final bool manage;
  final List<LibraryCategory> categories;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final ValueChanged<String> onToggleCategory;

  @override
  Widget build(BuildContext context) {
    final subtitle = comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页';
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 48,
          height: 64,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _CoverImage(loader: coverBytes),
          ),
        ),
        title: Text(comic.title),
        subtitle: Text(subtitle),
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: manage
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _CategoryPopup(
                    categories: categories,
                    selectedIds: preference.categoryIds,
                    onToggle: onToggleCategory,
                  ),
                  IconButton(
                    tooltip: '删除漫画',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  const Icon(Icons.drag_handle),
                ],
              )
            : const Icon(Icons.drag_handle),
      ),
    );
  }
}

final class _CategoryPopup extends StatelessWidget {
  const _CategoryPopup({
    required this.categories,
    required this.selectedIds,
    required this.onToggle,
    super.key,
  });

  final List<LibraryCategory> categories;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '设置分类',
      enabled: categories.isNotEmpty,
      icon: const Icon(Icons.label_outline),
      onSelected: onToggle,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final category in categories)
          CheckedPopupMenuItem<String>(
            value: category.categoryId,
            checked: selectedIds.contains(category.categoryId),
            child: Text(category.name),
          ),
      ],
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
