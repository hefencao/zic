part of 'demo_home.dart';

extension _DemoHomeViews on _DemoHomeState {
  List<LibraryComic> _selectedManagedComics() => _libraryComics
      .where((comic) => _managedComicIdentities.contains(comic.identity))
      .toList(growable: false);

  bool _matchesShelfFilter(LibraryComic comic) {
    final preference = _preferenceForComic(comic);
    if (!preference.inShelf) {
      return false;
    }
    if (_sourceFilter == ShelfSourceFilter.local &&
        preference.sourceKind != ComicSourceKind.local) {
      return false;
    }
    if (_sourceFilter == ShelfSourceFilter.remote &&
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
    final error = _libraryError;
    if (error != null && _libraryComics.isEmpty) {
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IndexedStack(
          index: _navigationIndex,
          children: <Widget>[
            _LazyIndexedPage(
              active: _navigationIndex == 0,
              builder: (_) => _buildHomePage(),
            ),
            _LazyIndexedPage(
              active: _navigationIndex == 1,
              builder: (_) => _buildBookshelfPage(),
            ),
            _LazyIndexedPage(
              active: _navigationIndex == 2,
              builder: (_) => _sourcePageVisited
                  ? ComicSourcesPage(
                      sources: _enabledSources,
                      activeSourceId: _activeSourceId,
                      onSourceSelected: (sourceId) {
                        setState(() => _activeSourceId = sourceId);
                      },
                      loadCover: _loadSourceBrowseCover,
                      onOpenComic: _openSourceComic,
                      onOpenSourceWebView: _openSourceWebView,
                      traceSink: widget.debugTrace,
                      requestedQuery: _sourceSearchQuery,
                      queryRevision: _sourceSearchRevision,
                      searchHistory: widget.preferences.sourceSearchHistory,
                      onSearchCommitted:
                          widget.preferences.rememberSourceSearch,
                      onSearchRemoved:
                          widget.preferences.removeSourceSearch,
                      onSearchHistoryCleared:
                          widget.preferences.clearSourceSearchHistory,
                    )
                  : const SizedBox.shrink(),
            ),
            _LazyIndexedPage(
              active: _navigationIndex == 3,
              builder: (_) => MiscPage(
                preferences: widget.preferences,
                debugTrace: widget.debugTrace,
                onOpenSettings: _openSettings,
                onOpenDownloads: _openDownloadManager,
                onImportFolder: _picking || _pickingFolder
                    ? null
                    : () => unawaited(_importImageFolder()),
              ),
            ),
          ],
        ),
        if (_libraryLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              key: importedLibraryLoadingKey,
              minHeight: 2,
            ),
          ),
      ],
    );
  }

  Widget _buildHomePage() {
    final updates = _libraryComics
        .where(
          (comic) =>
              _preferenceForComic(comic).inShelf,
        )
        .toList(growable: true)
      ..sort(
        (left, right) =>
            right.metadataUpdatedAt.compareTo(left.metadataUpdatedAt),
      );
    final visibleUpdates = updates.take(10).toList(growable: false);
    final telemetryOwners = <String>{};
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
          HomeSectionTitle(
            key: homeUpdatesSectionKey,
            title: '更新漫画',
            subtitle: updates.isEmpty ? '导入漫画后会显示最近更新' : null,
          ),
          const SizedBox(height: 10),
          _buildHorizontalComics(
            visibleUpdates,
            telemetryOwners: telemetryOwners,
          ),
          const SizedBox(height: 24),
          HomeSectionTitle(
            key: homeHistorySectionKey,
            title: '阅读历史',
            subtitle: history.isEmpty ? '开始阅读后会保留最后位置' : null,
          ),
          const SizedBox(height: 10),
          _buildHorizontalComics(
            history,
            history: true,
            telemetryOwners: telemetryOwners,
          ),
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
    Set<String>? telemetryOwners,
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
              key: ValueKey<String>(
                '${history ? 'home-history' : 'home-update'}:${comic.identity}',
              ),
              interactionKey: resume == null
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
              coverSource: _coverSourceLoaderForComic(comic),
              recoveryCoverSource: _coverRecoverySourceLoaderForComic(comic),
              startupTelemetry: telemetryOwners == null ||
                      telemetryOwners.add(comic.identity)
                  ? widget.startupTelemetry
                  : null,
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
        HomeActionCard(
          key: libraryDiagnosticsEntryKey,
          icon: Icons.rule_folder_outlined,
          title: '书架迁移诊断',
          subtitle: '查看、复制并明确确认旧数据库来源归属；不会删除记录。',
          onTap: _openLibraryDiagnostics,
        ),
        const SizedBox(height: 10),
        HomeActionCard(
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
        HomeActionCard(
          key: bundledWebpEntryKey,
          icon: Icons.animation,
          title: '内置动图 WebP',
          subtitle: '真实 assets 与播放引擎切换诊断。',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const WebpCatalogScreen()),
          ),
        ),
        const SizedBox(height: 10),
        HomeActionCard(
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
        HomeActionCard(
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
          AppDialogActions(
            onClose: () => Navigator.of(context).pop(false),
            actions: <Widget>[
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
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
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
            AppDialogActions(
              onClose: () => Navigator.of(context).pop(false),
              actions: <Widget>[
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(true),
                  child: const Text('添加'),
                ),
              ],
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
      coverSource: _coverSourceLoaderForComic(comic),
      recoveryCoverSource: _coverRecoverySourceLoaderForComic(comic),
      startupTelemetry: widget.startupTelemetry,
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
            child: CoverActionSurface(
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
            child: CoverActionSurface(child: _comicMovePopup(comic)),
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
                childWhenDragging: const CoverActionSurface(
                  child: Icon(Icons.drag_indicator),
                ),
                child: const CoverActionSurface(
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
    Widget item(LibraryComic comic, int index) => ShelfListTile(
          key: ValueKey<String>(comic.identity),
          comic: comic,
          preference: _preferenceForComic(comic),
          coverSource: _coverSourceLoaderForComic(comic),
          recoveryCoverSource: _coverRecoverySourceLoaderForComic(comic),
          startupTelemetry: widget.startupTelemetry,
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
                    child: SegmentedButton<ShelfSourceFilter>(
                      key: bookshelfSourceFilterKey,
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<ShelfSourceFilter>>[
                        ButtonSegment(
                          value: ShelfSourceFilter.all,
                          label: Text('全部'),
                        ),
                        ButtonSegment(
                          value: ShelfSourceFilter.local,
                          label: Text('本地'),
                        ),
                        ButtonSegment(
                          value: ShelfSourceFilter.remote,
                          label: Text('远程'),
                        ),
                      ],
                      selected: <ShelfSourceFilter>{_sourceFilter},
                      onSelectionChanged: (selection) {
                        widget.preferences.setShelfSourceFilter(
                          selection.single,
                        );
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
                    tooltip: _shelfViewMode == ShelfViewPreference.gallery
                        ? '切换列表视图'
                        : '切换画廊视图',
                    onPressed: () => widget.preferences.setShelfView(
                      _shelfViewMode == ShelfViewPreference.gallery
                          ? ShelfViewPreference.list
                          : ShelfViewPreference.gallery,
                    ),
                    icon: Icon(
                      _shelfViewMode == ShelfViewPreference.gallery
                          ? Icons.view_list_outlined
                          : Icons.grid_view_outlined,
                    ),
                  ),
                  PopupMenuButton<LibrarySortMode>(
                    key: bookshelfSortKey,
                    tooltip: '排序方式',
                    initialValue: _sortMode,
                    onSelected: widget.preferences.setShelfSortMode,
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
              : _shelfViewMode == ShelfViewPreference.gallery
                  ? _buildShelfGallery(comics)
                  : _buildShelfList(comics),
        ),
      ],
    );
  }
}

final class _LazyIndexedPage extends StatefulWidget {
  const _LazyIndexedPage({
    required this.active,
    required this.builder,
  });

  final bool active;
  final WidgetBuilder builder;

  @override
  State<_LazyIndexedPage> createState() => _LazyIndexedPageState();
}

final class _LazyIndexedPageState extends State<_LazyIndexedPage> {
  Widget? _child;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (widget.active) {
      child = widget.builder(context);
      _child = child;
    } else {
      final retained = _child;
      if (retained == null) {
        return const SizedBox.shrink();
      }
      child = retained;
    }
    return Offstage(
      offstage: !widget.active,
      child: TickerMode(enabled: widget.active, child: child),
    );
  }
}
