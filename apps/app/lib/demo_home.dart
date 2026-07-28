import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';

import 'static_demo.dart';
import 'webp_demo.dart';

const homePageKey = ValueKey<String>('home-page');
const bookshelfPageKey = ValueKey<String>('bookshelf-page');
const homeUpdatesSectionKey = ValueKey<String>('home-updates-section');
const homeHistorySectionKey = ValueKey<String>('home-history-section');
const homeDiagnosticsKey = ValueKey<String>('home-diagnostics');
const bookshelfManageKey = ValueKey<String>('bookshelf-manage');
const bookshelfSourceFilterKey = ValueKey<String>('bookshelf-source-filter');
const bookshelfSortKey = ValueKey<String>('bookshelf-sort');
const bookshelfViewKey = ValueKey<String>('bookshelf-view');
const bookshelfAddCategoryKey = ValueKey<String>('bookshelf-add-category');
const bookshelfAddComicToCategoryKey =
    ValueKey<String>('bookshelf-add-comic-to-category');
const bookshelfManagementBarKey =
    ValueKey<String>('bookshelf-management-bar');
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
Key importedChapterEntryKey(String chapterId) =>
    ValueKey<String>('imported-chapter:$chapterId');
Key historyChapterEntryKey(String chapterId) =>
    ValueKey<String>('history-chapter:$chapterId');
Key comicCoverKey(String comicId) => ValueKey<String>('comic-cover:$comicId');
Key comicDeleteKey(String comicId) => ValueKey<String>('comic-delete:$comicId');
Key comicCategoryKey(String comicId) =>
    ValueKey<String>('comic-category:$comicId');
Key chapterReadKey(String chapterId) =>
    ValueKey<String>('chapter-read:$chapterId');
@Deprecated('Use localImageFolderPickerProgressKey')
const localWebpFolderPickerProgressKey = localImageFolderPickerProgressKey;

enum _SourceFilter { all, local, remote }

enum _ShelfViewMode { gallery, list }

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
  String? _managedComicId;
  int _navigationIndex = 0;
  _SourceFilter _sourceFilter = _SourceFilter.all;
  String? _selectedCategoryId;
  LibrarySortMode _sortMode = LibrarySortMode.recent;
  _ShelfViewMode _shelfViewMode = _ShelfViewMode.gallery;

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
        builder: (_) {
          final preference = _preferences[entry.chapter.comicId] ??
              ComicPreference.defaults(comicId: entry.chapter.comicId);
          return ImportedImageChapterScreen(
            record: entry.chapter,
            initialProgress: entry.progress,
            onProgressChanged: _library.saveProgress,
            initialFavorite: preference.collected,
            onFavoriteChanged: (favorite) {
              final current = _preferences[entry.chapter.comicId] ??
                  ComicPreference.defaults(comicId: entry.chapter.comicId);
              return _savePreference(current.copyWith(collected: favorite));
            },
          );
        },
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
    if (mounted && _managedComicId == comic.comicId) {
      setState(() => _managedComicId = null);
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
                  value: selected.contains(comic.comicId),
                  title: Text(comic.title),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (checked) {
                    setDialogState(() {
                      if (checked ?? false) {
                        selected.add(comic.comicId);
                      } else {
                        selected.remove(comic.comicId);
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
      (comic) => selected.contains(comic.comicId),
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
    String draggedComicId,
    String targetComicId,
  ) async {
    if (draggedComicId == targetComicId) {
      return;
    }
    final comics = _filteredShelfComics();
    final oldIndex =
        comics.indexWhere((comic) => comic.comicId == draggedComicId);
    final targetIndex =
        comics.indexWhere((comic) => comic.comicId == targetComicId);
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
      setState(() {
        _managedComicId = _managedComicId == comic.comicId ? null : comic.comicId;
      });
      return;
    }
    unawaited(_openComic(comic));
  }

  Widget _buildManagementBar(LibraryComic comic) {
    final currentCategoryId = _selectedCategoryId;
    final moveTargets = _categories
        .where((category) => category.categoryId != currentCategoryId)
        .toList(growable: false);
    return Card(
      key: bookshelfManagementBarKey,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                comic.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '移动到其他分类',
              enabled: moveTargets.isNotEmpty || currentCategoryId != null,
              onSelected: (value) => _moveComicToCategory(
                comic,
                value == '__uncategorized__' ? null : value,
              ),
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                if (currentCategoryId != null)
                  const PopupMenuItem<String>(
                    value: '__uncategorized__',
                    child: Text('移出当前分类'),
                  ),
                for (final category in moveTargets)
                  PopupMenuItem<String>(
                    value: category.categoryId,
                    child: Text('移动到 ${category.name}'),
                  ),
              ],
              icon: const Icon(Icons.drive_file_move_outline),
            ),
            _CategoryPopup(
              categories: _categories,
              selectedIds: _preferenceForComic(comic).categoryIds,
              onToggle: (categoryId) => _toggleCategory(comic, categoryId),
            ),
            IconButton(
              tooltip: '复制漫画信息',
              onPressed: () => _copyComicInfo(comic),
              icon: const Icon(Icons.copy_outlined),
            ),
            const SizedBox(width: 16),
            const SizedBox(
              height: 32,
              child: VerticalDivider(width: 24),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: comicDeleteKey(comic.comicId),
              tooltip: '删除漫画',
              color: Theme.of(context).colorScheme.error,
              onPressed: () => _confirmRemoveComic(comic),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryTile(LibraryComic comic) {
    final selected = _managedComicId == comic.comicId;
    Widget tile = ComicCoverCard(
      key: comicCoverKey(comic.comicId),
      comic: comic,
      preference: _preferenceForComic(comic),
      coverBytes: _coverLoaderForComic(comic),
      selected: selected,
      onTap: () => _handleShelfTap(comic),
      onLongPress: _manageShelf
          ? null
          : () => _hasDetails(comic)
              ? _openComicDetails(comic)
              : _openImportedChapter(comic.resumeChapter),
    );
    if (!_manageShelf || _sortMode != LibrarySortMode.custom) {
      return tile;
    }
    final baseTile = tile;
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != comic.comicId,
      onAcceptWithDetails: (details) {
        unawaited(_reorderCustomComic(details.data, comic.comicId));
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
        child: baseTile,
      ),
    );
    return LongPressDraggable<String>(
      data: comic.comicId,
      feedback: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: ComicCoverCard.cardWidth,
          height: ComicCoverCard.cardExtent,
          child: ComicCoverCard(
            comic: comic,
            preference: _preferenceForComic(comic),
            coverBytes: _coverLoaderForComic(comic),
            onTap: () {},
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: target),
      child: target,
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
    Widget item(LibraryComic comic) => _ShelfListTile(
          key: ValueKey<String>(comic.comicId),
          comic: comic,
          preference: _preferenceForComic(comic),
          coverBytes: _coverLoaderForComic(comic),
          selected: _managedComicId == comic.comicId,
          onTap: () => _handleShelfTap(comic),
          onLongPress: _manageShelf
              ? null
              : () => _hasDetails(comic)
                  ? _openComicDetails(comic)
                  : _openImportedChapter(comic.resumeChapter),
        );
    if (_manageShelf && _sortMode == LibrarySortMode.custom) {
      return ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: comics.length,
        onReorder: (oldIndex, newIndex) {
          unawaited(_reorderCustom(oldIndex, newIndex));
        },
        itemBuilder: (context, index) => item(comics[index]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: comics.length,
      itemBuilder: (context, index) => item(comics[index]),
    );
  }

  Widget _buildBookshelfPage() {
    final comics = _filteredShelfComics();
    LibraryComic? selectedComic;
    final managedComicId = _managedComicId;
    if (managedComicId != null) {
      for (final comic in _libraryComics) {
        if (comic.comicId == managedComicId) {
          selectedComic = comic;
          break;
        }
      }
    }
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
                      _managedComicId = null;
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
                    onSelected: (value) => setState(() {
                      _sortMode = value;
                      _managedComicId = null;
                    }),
                    itemBuilder: (context) =>
                        const <PopupMenuEntry<LibrarySortMode>>[
                      PopupMenuItem(
                        value: LibrarySortMode.recent,
                        child: Text('最近更新'),
                      ),
                      PopupMenuItem(
                        value: LibrarySortMode.title,
                        child: Text('标题'),
                      ),
                      PopupMenuItem(
                        value: LibrarySortMode.pageCount,
                        child: Text('页数'),
                      ),
                      PopupMenuItem(
                        value: LibrarySortMode.custom,
                        child: Text('自定义排序'),
                      ),
                    ],
                    icon: const Icon(Icons.sort),
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
                  _managedComicId = null;
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
                      _managedComicId = null;
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
        if (_manageShelf && selectedComic != null)
          _buildManagementBar(selectedComic),
        if (_manageShelf && _sortMode == LibrarySortMode.custom)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('长按漫画并拖动以调整顺序'),
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
    this.onLongPress,
    this.downloadProgress,
    this.selected = false,
    super.key,
  });

  static const double coverAspectRatio = 3 / 4;
  static const double cardWidth = 132;
  static const double cardExtent = 238;

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final progress = comic.resumeChapter.progress;
    final scope = comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页';
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      selected: selected,
      label: '${comic.title}，$scope',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AspectRatio(
                aspectRatio: coverAspectRatio,
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
    required this.selected,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<Uint8List> Function() coverBytes;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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
              child: _CoverImage(loader: coverBytes),
            ),
          ),
        ),
        title: Text(comic.title),
        subtitle: Text(subtitle),
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: selected
            ? Icon(
                Icons.radio_button_checked,
                color: Theme.of(context).colorScheme.primary,
              )
            : null,
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
