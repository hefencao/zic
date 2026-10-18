part of 'home_shell.dart';

extension _HomeShellViews on _HomeShellState {
  Widget _buildSourceAwareCover({Key? key, required TransitionBuilder builder}) =>
      StreamBuilder<void>(
        key: key,
        stream: _externalSources.sourceProjectionChanges,
        builder: (context, _) => AnimatedBuilder(
          animation: _librarySession.downloadProjectionChanges,
          builder: builder,
        ),
      );

  List<LibraryComic> _selectedManagedComics() => _libraryComics
      .where((comic) => _shelfManagement.isSelected(comic.identity))
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
    if (_shelfPluginSourceIds.isNotEmpty && !_shelfPluginSourceIds.contains(comic.sourceId)) {
      return false;
    }
    final categoryId = _selectedCategoryId;
    return categoryId == null || preference.categoryIds.contains(categoryId);
  }

  List<LibraryComic> _filteredShelfComics({List<LibraryComic>? libraryComics}) {
    final comics = (libraryComics ?? _libraryComics)
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
              SelectableText('$error', textAlign: TextAlign.center),
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
                        _setState(() => _activeSourceId = sourceId);
                      },
                      loadCover: _loadSourceBrowseCover,
                      onOpenComic: _openSourceComic,
                      isInShelf: (source, comic) => _mergedPreferenceFor(
                        source.sourceId,
                        comic.comicId,
                        fallbackSourceKind: ComicSourceKind.remote,
                        fallbackInShelf: false,
                      ).inShelf,
                      hasUpdate: _sourceComicHasUpdate,
                      onOpenUpdate: _openSourceUpdateForSummary,
                      onOpenSourceWebView: _openSourceWebView,
                      resolveSource: _sourceForId,
                      externalPlugins: _externalSources.activeController,
                      onExternalPluginRetry: (plugin) => _externalSources
                          .retryActivation(plugin.plugin.pluginId),
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

  Future<void> _exportHomeDebugTrace() async {
    if (_exportingHomeTrace) return;
    _setState(() => _exportingHomeTrace = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      final result = await exportDebugTraceEvents(
        events: widget.debugTrace.exportEvents,
        relativeDirectory: widget.preferences.debugTraceExportDirectory,
      );
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${result.eventCount} 条 Trace 到 '
            '${debugTraceExportDisplayPath(result.relativeDirectory)}',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        copyableDiagnosticSnackBar('Trace 快捷导出失败：$error'),
      );
    } finally {
      if (mounted) _setState(() => _exportingHomeTrace = false);
    }
  }

  Widget _buildHomePage() {
    final identityQuery = _catalogIdentityQuery();
    final comics = _projectLibraryComics(identityQuery);
    final updates = comics
        .where(
          (comic) =>
              _sourceUpdateAtForComic(comic) != null &&
              _preferenceForComic(comic,
                aliases: identityQuery.aliasesFor(comic.sourceId, comic.comicId),
              ).inShelf,
        )
        .toList(growable: true)
      ..sort(
        (left, right) => _sourceUpdateAtForComic(right)!
            .compareTo(_sourceUpdateAtForComic(left)!),
      );
    final visibleUpdates = updates.take(10).toList(growable: false);
    final telemetryOwners = <String>{};
    final history = comics
        .where((comic) => comic.lastReadChapter != null)
        .toList(growable: true)
      ..sort(
        (left, right) => right.lastReadChapter!.progress!.updatedAt
            .compareTo(left.lastReadChapter!.progress!.updatedAt),
      );
    final hasPrimaryLibraryProjection =
        _libraryEntries.isNotEmpty || !_libraryLoading;
    return CustomScrollView(
      key: homePageKey,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          sliver: SliverToBoxAdapter(child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeSectionTitle(
                key: hasPrimaryLibraryProjection ? homeUpdatesSectionKey : null,
                title: '更新漫画',
                subtitle: updates.isEmpty ? '加入书架的漫画有新章节或新版本时显示' : null,
              ),
              const SizedBox(height: 10),
              _buildHorizontalComics(
                visibleUpdates,
                canonicalKeyFor: identityQuery.keyFor,
                telemetryOwners: telemetryOwners,
              ),
              const SizedBox(height: 24),
              HomeSectionTitle(
                key: hasPrimaryLibraryProjection ? homeHistorySectionKey : null,
                title: '阅读历史',
                subtitle: history.isEmpty ? '开始阅读后会保留最后位置' : null,
                trailing: IconButton(
                  key: homeHistoryLayoutKey,
                  tooltip: '阅读历史布局',
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => HomeHistoryLayoutSheet(preferences: widget.preferences),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          )),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          sliver: ListenableBuilder(
            listenable: widget.preferences,
            builder: (_, _) => _buildHistorySliver(history,
              canonicalKeyFor: identityQuery.keyFor, telemetryOwners: telemetryOwners),
          ),
        ),
      ],
    );
  }

  Widget _buildHomeComicCard(LibraryComic comic, {
    required String coverIdentity,
    required String presentationIdentity,
    required bool history,
    Set<String>? telemetryOwners,
  }) {
    final resume = comic.resumeChapter;
    final interactionKey = resume == null
        ? ValueKey<String>('comic-entry:${comic.identity}')
        : history
            ? historyChapterEntryKey(resume.chapter.sourceId, resume.chapter.chapterId)
            : importedChapterEntryKey(resume.chapter.sourceId, resume.chapter.chapterId);
    final startupTelemetry = telemetryOwners == null || telemetryOwners.add(presentationIdentity)
        ? widget.startupTelemetry : null;
    return _buildSourceAwareCover(
      builder: (context, _) {
        if (history && widget.preferences.homeHistoryLayout == HomeHistoryLayout.list) {
          final progress = resume?.progress;
          return ShelfListTile(
            interactionKey: interactionKey,
            comic: comic,
            preference: _preferenceForComic(comic),
            coverSource: _coverSourceLoaderForComic(comic),
            coverIdentity: coverIdentity,
            telemetryIdentity: presentationIdentity,
            sourceAvailable: _coverSourceAvailableForComic(comic),
            startupTelemetry: startupTelemetry,
            downloadProgress: _downloadProgressForComic(comic),
            selected: false,
            subtitle: resume == null || progress == null ? null :
              '${resume.chapter.displayName} · 第 ${progress.pageIndex + 1} / ${resume.chapter.pages.length} 页',
            onTap: () => unawaited(_openComic(comic)),
            onLongPress: () => unawaited(_openComicDetails(comic)),
          );
        }
        return ComicCoverCard(
          interactionKey: interactionKey,
          comic: comic,
          preference: _preferenceForComic(comic),
          coverIdentity: coverIdentity,
          telemetryIdentity: presentationIdentity,
          coverSource: _coverSourceLoaderForComic(comic),
          sourceAvailable: _coverSourceAvailableForComic(comic),
          startupTelemetry: startupTelemetry,
          downloadProgress: _downloadProgressForComic(comic),
          onTap: () => unawaited(_openComic(comic)),
          onLongPress: () => unawaited(_openComicDetails(comic)),
        );
      },
    );
  }

  Widget _buildHistorySliver(List<LibraryComic> comics, {
    required String Function(String sourceId, String comicId) canonicalKeyFor,
    required Set<String> telemetryOwners,
  }) {
    if (comics.isEmpty) {
      return SliverToBoxAdapter(child: _buildHorizontalComics(comics));
    }
    final coverIdentities = [for (final comic in comics) canonicalKeyFor(comic.sourceId, comic.comicId)];
    final identities = [for (final identity in coverIdentities) 'home-history:$identity'];
    final itemIndexByKey = {for (var i = 0; i < identities.length; i++) identities[i]: i};
    final delegate = SliverChildBuilderDelegate(
      (context, index) => SizedBox(
        key: ValueKey<String>(identities[index]),
        child: _buildHomeComicCard(comics[index], coverIdentity: coverIdentities[index],
          presentationIdentity: identities[index], history: true, telemetryOwners: telemetryOwners),
      ),
      childCount: comics.length,
      findChildIndexCallback: (key) => key is ValueKey<String> ? itemIndexByKey[key.value] : null,
    );
    final layout = widget.preferences.homeHistoryLayout;
    if (layout == HomeHistoryLayout.list) {
      return SliverList(key: const ValueKey('home-history-list'), delegate: delegate);
    }
    const spacing = 12.0;
    if (layout == HomeHistoryLayout.carousel) {
      final rows = widget.preferences.homeHistoryRows;
      return SliverToBoxAdapter(child: SizedBox(
        height: rows * ComicCoverCard.cardExtent + (rows - 1) * spacing,
        child: GridView.custom(
          key: const PageStorageKey('home-history-carousel'),
          scrollDirection: Axis.horizontal,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: rows,
            mainAxisExtent: ComicCoverCard.cardWidth,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          childrenDelegate: delegate,
        ),
      ));
    }
    return SliverLayoutBuilder(builder: (context, constraints) {
      // Keep narrow windows usable even when a higher column count is saved.
      final capacity = ((constraints.crossAxisExtent + spacing) / (88 + spacing)).floor().clamp(1, 6).toInt();
      final columns = widget.preferences.homeHistoryColumns.clamp(1, capacity).toInt();
      final width = (constraints.crossAxisExtent - (columns - 1) * spacing) / columns;
      return SliverGrid(
        key: const ValueKey('home-history-grid'),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: width * ComicCoverCard.cardExtent / ComicCoverCard.cardWidth,
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
        ),
        delegate: delegate,
      );
    });
  }

  Widget _buildHorizontalComics(
    List<LibraryComic> comics, {
    Set<String>? telemetryOwners,
    String Function(String sourceId, String comicId)? canonicalKeyFor,
  }) {
    if (comics.isEmpty) {
      return const SizedBox(
        height: 92,
        child: Card(
          child: Center(child: Text('暂无内容')),
        ),
      );
    }
    final coverIdentities = <String>[
      for (final comic in comics)
        (canonicalKeyFor ?? _canonicalComicKey)(comic.sourceId, comic.comicId),
    ];
    final presentationIdentities = <String>[
      for (final identity in coverIdentities) 'home-update:$identity',
    ];
    final itemIndexByKey = <String, int>{
      for (var index = 0; index < presentationIdentities.length; index++)
        presentationIdentities[index]: index,
    };
    return SizedBox(
      height: ComicCoverCard.cardExtent,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: comics.length,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final itemIndex = itemIndexByKey[key.value];
          return itemIndex == null ? null : itemIndex * 2;
        },
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final comic = comics[index];
          final coverIdentity = coverIdentities[index];
          final presentationIdentity = presentationIdentities[index];
          return SizedBox(
            key: ValueKey<String>(presentationIdentity),
            width: ComicCoverCard.cardWidth,
            child: _buildHomeComicCard(comic, coverIdentity: coverIdentity,
              presentationIdentity: presentationIdentity, history: false,
              telemetryOwners: telemetryOwners),
          );
        },
      ),
    );
  }

  void _openTranslationTest() => unawaited(Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ComicTranslationTestScreen()),
  ));

  void _openDiagnostics() => unawaited(Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => StatefulBuilder(builder: (context, update) => Scaffold(
        appBar: AppBar(title: const Text('开发与媒体诊断')),
        body: SingleChildScrollView(padding: const EdgeInsets.all(16),
          child: _buildImportAndDemoCards(importWebp: () async {
            final pending = _importWebp();
            update(() {});
            try {
              await pending;
            } finally {
              if (context.mounted) update(() {});
            }
          })),
      ))),
  ));

  Widget _buildImportAndDemoCards({Future<void> Function()? importWebp}) {
    return Column(
      children: <Widget>[
        HomeActionCard(
          key: comicTranslationTestEntryKey,
          icon: Icons.translate,
          title: '翻译测试',
          subtitle: '测试文字、整页 OCR 与翻译耗时。',
          onTap: _openTranslationTest,
        ),
        const SizedBox(height: 10),
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
          onTap: _picking || _pickingFolder ? null : importWebp ?? _importWebp,
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
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('删除漫画'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('从书架和本地记录中删除“${comic.title}”？此操作不可撤销。'),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除本地下载文件'),
                value: deleteFiles,
                onChanged: (val) {
                  setDialogState(() {
                    deleteFiles = val ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
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
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _removeComic(comic, deleteFiles: deleteFiles);
    if (mounted && _shelfManagement.isSelected(comic.identity)) {
      _setState(() => _shelfManagement.removeSelection(comic.identity));
    }
  }

  Future<void> _confirmArchiveComic(LibraryComic comic) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档漫画'),
        content: Text('归档“${comic.title}”将清理所有本地已下载文件与正文缓存，但会完整保留书架收藏、阅读进度、已读状态和封面。\n\n后续打开时将重新按需在线加载。'),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('归档'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _archiveComic(comic);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('已归档“${comic.title}”（已清理下载文件与正文缓存）'),
        ),
      );
    }
  }

  Future<void> _createCategory() async {
    var draft = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分类'),
        content: TextFormField(
          onChanged: (value) => draft = value,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分类名称'),
          onFieldSubmitted: (value) =>
              Navigator.of(context).pop(value.trim()),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.of(context).pop(),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.of(context).pop(draft.trim()),
                child: const Text('创建'),
              ),
            ],
          ),
        ],
      ),
    );
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
    await _librarySession.upsertCategory(category);
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
    await _librarySession.removeCategory(category.categoryId);
    if (_shelfCategoryId == category.categoryId) {
      if (mounted) {
        _setState(() => _selectedCategoryId = null);
      } else {
        _selectedCategoryId = null;
      }
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
      _setState(_clearManagedSelection);
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
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('删除 ${selected.length} 部漫画？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('将删除书架记录、章节元数据与阅读状态。'),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除本地下载文件'),
                value: deleteFiles,
                onChanged: (val) {
                  setDialogState(() {
                    deleteFiles = val ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
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
      ),
    );
    if (confirmed != true) {
      return;
    }
    for (final comic in selected) {
      await _removeComic(comic, deleteFiles: deleteFiles);
    }
    if (mounted) {
      _setState(_clearManagedSelection);
    }
  }

  Future<void> _archiveManagedComics() async {
    final selected = _selectedManagedComics();
    if (selected.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('归档 ${selected.length} 部漫画？'),
        content: const Text('将清理所选漫画的本地已下载文件与正文缓存，但会完整保留书架收藏、阅读进度、已读状态和封面。\n\n后续打开时将重新按需在线加载。'),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context, false),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('归档'),
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
      await _archiveComic(comic);
    }
    if (mounted) {
      _setState(_clearManagedSelection);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('已归档 ${selected.length} 部漫画（已清理下载文件与正文缓存）'),
        ),
      );
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
    if (_shelfManagement.managing) {
      if (_shelfManagement.batchSelecting) {
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
              onPressed: () => _setState(_clearManagedSelection),
              icon: const Icon(Icons.close),
            ),
            const SizedBox(width: 14),
            const SizedBox(height: 32, child: VerticalDivider(width: 18)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '批量归档 (释放空间)',
              onPressed: selected.isEmpty ? null : _archiveManagedComics,
              icon: const Icon(Icons.archive_outlined),
            ),
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
    final selected = _shelfManagement.isSelected(comic.identity);
    final coverIdentity = _canonicalComicKey(comic.sourceId, comic.comicId);
    final card = _buildSourceAwareCover(
      key: ValueKey<String>('library-cover:$coverIdentity'),
      builder: (context, _) => ComicCoverCard(
        interactionKey: comicCoverKey(comic.sourceId, comic.comicId),
        comic: comic,
        preference: _preferenceForComic(comic),
        coverIdentity: coverIdentity,
        coverSource: _coverSourceLoaderForComic(comic),
        sourceAvailable: _coverSourceAvailableForComic(comic),
        startupTelemetry: widget.startupTelemetry,
        downloadProgress: _downloadProgressForComic(comic),
        selected: selected,
        onTap: () => _handleShelfTap(comic),
        onLongPress: _shelfManagement.managing
            ? () => _startBatchSelection(comic)
            : () => unawaited(_openComicDetails(comic)),
      ),
    );
    Widget tile = card;
    if (_shelfManagement.managing && !_shelfManagement.batchSelecting) {
      tile = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          card,
          Positioned(
            top: 4,
            right: 4,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CoverActionSurface(
                  child: IconButton(
                    tooltip: '归档 (释放空间)',
                    onPressed: () => _confirmArchiveComic(comic),
                    icon: const Icon(Icons.archive_outlined),
                  ),
                ),
                const SizedBox(width: 4),
                CoverActionSurface(
                  child: IconButton(
                    key: comicDeleteKey(comic.sourceId, comic.comicId),
                    tooltip: '删除漫画',
                    color: Theme.of(context).colorScheme.error,
                    onPressed: () => _confirmRemoveComic(comic),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: CoverActionSurface(child: _comicMovePopup(comic)),
          ),
          if (_sortMode == LibrarySortMode.custom && !_shelfManagement.batchSelecting)
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
    if (!_shelfManagement.managing ||
        _sortMode != LibrarySortMode.custom ||
        _shelfManagement.batchSelecting) {
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

  double get _shelfScrollBottomPadding =>
      ComicFilterPanel.rowHeight * (widget.preferences.shelfPluginFilterExpanded ? 2 : 1) +
      ComicFilterPanel.bottomInset + MediaQuery.paddingOf(context).bottom + 16;

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
          padding: EdgeInsets.fromLTRB(sidePadding, 8, sidePadding, _shelfScrollBottomPadding),
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
    Widget item(LibraryComic comic, int index) {
      final coverIdentity = _canonicalComicKey(comic.sourceId, comic.comicId);
      return _buildSourceAwareCover(
        key: ValueKey<String>('library-list:$coverIdentity'),
        builder: (context, _) => ShelfListTile(
          comic: comic,
          preference: _preferenceForComic(comic),
          coverSource: _coverSourceLoaderForComic(comic),
          coverIdentity: coverIdentity,
          sourceAvailable: _coverSourceAvailableForComic(comic),
          startupTelemetry: widget.startupTelemetry,
          downloadProgress: _downloadProgressForComic(comic),
          selected: _shelfManagement.isSelected(comic.identity),
          onTap: () => _handleShelfTap(comic),
          onLongPress: _shelfManagement.managing
              ? () => _startBatchSelection(comic)
              : () => unawaited(_openComicDetails(comic)),
          trailing: _shelfManagement.managing && !_shelfManagement.batchSelecting
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _comicMovePopup(comic),
                    IconButton(
                      tooltip: '归档 (释放空间)',
                      onPressed: () => _confirmArchiveComic(comic),
                      icon: const Icon(Icons.archive_outlined),
                    ),
                    IconButton(
                      key: comicDeleteKey(comic.sourceId, comic.comicId),
                      tooltip: '删除漫画',
                      color: Theme.of(context).colorScheme.error,
                      onPressed: () => _confirmRemoveComic(comic),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    if (_sortMode == LibrarySortMode.custom &&
                        !_shelfManagement.batchSelecting)
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
        ),
      );
    }
    if (_shelfManagement.managing &&
        _sortMode == LibrarySortMode.custom &&
        !_shelfManagement.batchSelecting) {
      return ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: EdgeInsets.fromLTRB(12, 8, 12, _shelfScrollBottomPadding),
        itemCount: comics.length,
        onReorder: (oldIndex, newIndex) {
          unawaited(_reorderCustom(oldIndex, newIndex));
        },
        itemBuilder: (context, index) => item(comics[index], index),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 8, 12, _shelfScrollBottomPadding),
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

  Widget _buildBookshelfToolbar(int count) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(children: [
      Expanded(child: TextButton(
        key: bookshelfSourceFilterKey,
        onPressed: widget.preferences.cycleShelfSourceFilter,
        style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            const Icon(Icons.filter_list, size: 20),
            const SizedBox(width: 6),
            Flexible(child: Text('${switch (_sourceFilter) {
              ShelfSourceFilter.all => '全部', ShelfSourceFilter.local => '本地',
              ShelfSourceFilter.remote => '远程',
            }} · $count', maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            const Icon(Icons.swap_horiz, size: 18),
          ])),
      )),
      PopupMenuButton<LibrarySortMode>(
        key: bookshelfSortKey,
        tooltip: '排序：${_librarySortLabel(_sortMode)}',
        icon: const Icon(Icons.sort),
        initialValue: _sortMode,
        onSelected: widget.preferences.setShelfSortMode,
        itemBuilder: (_) => [
          _sortMenuItem(bookshelfSortRecentKey, LibrarySortMode.recent, '最近更新'),
          _sortMenuItem(bookshelfSortTitleKey, LibrarySortMode.title, '标题'),
          _sortMenuItem(bookshelfSortPageCountKey, LibrarySortMode.pageCount, '页数'),
          _sortMenuItem(bookshelfSortCustomKey, LibrarySortMode.custom, '自定义排序'),
        ],
      ),
      IconButton(key: bookshelfViewKey,
        tooltip: _shelfViewMode == ShelfViewPreference.gallery ? '切换列表视图' : '切换画廊视图',
        onPressed: () => widget.preferences.setShelfView(
          _shelfViewMode == ShelfViewPreference.gallery ? ShelfViewPreference.list : ShelfViewPreference.gallery),
        icon: Icon(_shelfViewMode == ShelfViewPreference.gallery
          ? Icons.view_list_outlined : Icons.grid_view_outlined)),
      IconButton(key: bookshelfManageKey,
        tooltip: _shelfManagement.managing ? '完成书架管理' : '管理书架',
        onPressed: () => _setState(_shelfManagement.toggleManaging),
        icon: Icon(_shelfManagement.managing ? Icons.done : Icons.edit_outlined)),
      IconButton(key: bookshelfSettingsKey,
        tooltip: '书架设置',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => BookshelfSettingsScreen(preferences: widget.preferences))),
        icon: Badge(isLabelVisible: _shelfPluginSourceIds.isNotEmpty,
          child: const Icon(Icons.tune))),
    ]),
  );

  List<BookshelfPluginGroup> _shelfPluginGroups(List<LibraryComic> libraryComics) {
    final identityQuery = _catalogIdentityQuery();
    final sourceIds = <String>{};
    final localSourceIds = <String>{};
    for (final comic in libraryComics) {
      final preference = _preferenceForComic(comic,
        aliases: identityQuery.aliasesFor(comic.sourceId, comic.comicId));
      if (!preference.inShelf) continue;
      final local = preference.sourceKind == ComicSourceKind.local;
      if ((_sourceFilter == ShelfSourceFilter.local && !local) ||
          (_sourceFilter == ShelfSourceFilter.remote && local)) {
        continue;
      }
      sourceIds.add(comic.sourceId);
      if (local) localSourceIds.add(comic.sourceId);
    }
    sourceIds.addAll(_shelfPluginSourceIds);
    return groupBookshelfPlugins(
      sourceIds: sourceIds,
      localSourceIds: localSourceIds,
      sources: _sourceProjection.sources,
      installed: _externalSources.activeController?.installed ?? const [],
      activeOwnerOfSource: _externalSources.ownerOfSource,
    );
  }

  void _selectShelfPlugin(BookshelfPluginGroup group, {bool longPress = false}) {
    final next = _shelfPluginSourceIds.toSet();
    final selected = group.sourceIds.any(next.contains);
    if (longPress) {
      selected ? next.removeAll(group.sourceIds) : next.addAll(group.sourceIds);
    } else {
      next.clear();
      if (!selected || !_shelfPluginSourceIds.every(group.sourceIds.contains)) {
        next.addAll(group.sourceIds);
      }
    }
    widget.preferences.setShelfPluginSourceIds(next);
  }

  Widget _buildShelfPluginBar(List<LibraryComic> libraryComics) {
    final groups = _shelfPluginGroups(libraryComics);
    return SizedBox(key: bookshelfPluginBarKey, height: ComicFilterPanel.rowHeight, child: Row(children: [
      Expanded(child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          ChoiceChip(key: bookshelfAllPluginsKey, label: const Text('所有'),
            selected: _shelfPluginSourceIds.isEmpty, showCheckmark: false,
            onSelected: (_) => widget.preferences.setShelfPluginSourceIds(const [])),
          for (final group in groups) ...[
            const SizedBox(width: 8),
            GestureDetector(onLongPress: () => _selectShelfPlugin(group, longPress: true),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 144),
                child: ComicSourceChip(chipKey: bookshelfPluginChoiceKey(group.id),
                  label: group.label, format: group.format,
                  accent: switch (group.format) {
                    ExternalComicPluginFormat.mihonExtension => Colors.green,
                    ExternalComicPluginFormat.veneraJavaScript => Colors.blue,
                    null => Theme.of(context).colorScheme.primary,
                  },
                  multiple: true,
                  selected: group.sourceIds.any(_shelfPluginSourceIds.contains),
                  onSelected: (_) => _selectShelfPlugin(group),
                ))),
          ],
        ])),
    ]));
  }

  void _maybeShowShelfGestureHint() {
    final preferences = widget.preferences;
    if (_shelfGestureHintQueued || _navigationIndex != 1 || !preferences.isAttached ||
        preferences.hasSeenOperationHint(bookshelfPluginGestureHintId)) {
      return;
    }
    _shelfGestureHintQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || _navigationIndex != 1 || ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        final expanded = preferences.shelfPluginFilterExpanded;
        final result = await showOperationHint(context: context, target: _shelfCategoryHintTarget,
          title: '滑动分类栏，展开或收起插件',
          message: expanded
            ? '在亮起的分类栏向下滑动收起，向上滑动可再次展开。点击插件单选，长按追加或取消。'
            : '在亮起的分类栏向上滑动，展开插件筛选；向下滑动收起。点击插件单选，长按追加或取消。',
          gesture: expanded ? OperationHintGesture.swipeDown : OperationHintGesture.swipeUp);
        if (!mounted || result == null) {
          return;
        }
        preferences.dismissOperationHint(bookshelfPluginGestureHintId);
        if (result == OperationHintResult.performed) {
          preferences.setShelfPluginFilterExpanded(!expanded);
        }
      } finally {
        _shelfGestureHintQueued = false;
      }
    });
  }

  Widget _buildShelfFilters(List<LibraryComic> libraryComics) => ComicFilterPanel(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(key: _shelfCategoryHintTarget, container: true,
        label: widget.preferences.shelfPluginFilterExpanded ? '下划收起插件筛选' : '上划展开插件筛选',
        onIncrease: () => widget.preferences.setShelfPluginFilterExpanded(true),
        onDecrease: () => widget.preferences.setShelfPluginFilterExpanded(false),
        child: GestureDetector(behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => _shelfFilterDragDistance = 0,
          onVerticalDragUpdate: (details) => _shelfFilterDragDistance += details.primaryDelta ?? 0,
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (_shelfFilterDragDistance.abs() >= 24 || velocity.abs() >= 300) {
              widget.preferences.setShelfPluginFilterExpanded(
                _shelfFilterDragDistance.abs() >= 24 ? _shelfFilterDragDistance < 0 : velocity < 0);
            }
          },
          child: _buildShelfCategoryBar())),
      AnimatedSize(duration: const Duration(milliseconds: 180), curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: widget.preferences.shelfPluginFilterExpanded
          ? StreamBuilder<void>(stream: _externalSources.sourceProjectionChanges,
              builder: (_, _) => _buildShelfPluginBar(libraryComics))
          : const SizedBox(width: double.infinity)),
    ]),
  );

  Widget _buildShelfCategoryBar() => SizedBox(
    key: bookshelfCategoryBarKey, height: ComicFilterPanel.rowHeight,
    child: Row(children: [
      Expanded(child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0), children: [
          if (_shelfShowAllCategory) ...[
            ChoiceChip(key: bookshelfAllCategoryKey, label: const Text('全部'),
              selected: _selectedCategoryId == null, showCheckmark: false,
              onSelected: (_) => _setState(() {
                _selectedCategoryId = null;
                _clearManagedSelection();
              })),
            const SizedBox(width: 8),
          ],
          for (final category in _categories) ...[
            GestureDetector(
              onLongPress: _shelfManagement.managing ? () => _deleteCategory(category) : null,
              child: ChoiceChip(label: Text(category.name), showCheckmark: false,
                selected: _selectedCategoryId == category.categoryId,
                onSelected: (_) => _setState(() {
                  _selectedCategoryId = category.categoryId;
                  _clearManagedSelection();
                }))),
            const SizedBox(width: 8),
          ],
          if (!_shelfShowAllCategory && _categories.isEmpty)
            const Center(child: Text('暂无分类')),
        ])),
      if (_selectedCategoryId != null)
        IconButton(key: bookshelfAddComicToCategoryKey, tooltip: '添加漫画到当前分类',
          onPressed: _addComicsToSelectedCategory, icon: const Icon(Icons.playlist_add)),
      IconButton(key: bookshelfAddCategoryKey, tooltip: '新建分类',
        onPressed: _createCategory, icon: const Icon(Icons.add)),
      const SizedBox(width: 4),
    ]),
  );

  Widget _buildBookshelfPage() => ListenableBuilder(
    listenable: widget.preferences,
    builder: (context, _) {
      _maybeShowShelfGestureHint();
      final libraryComics = _libraryComics;
      final comics = _filteredShelfComics(libraryComics: libraryComics);
      return Column(key: bookshelfPageKey, children: [
        _buildBookshelfToolbar(comics.length),
        if (_shelfManagement.managing && _shelfManagement.batchSelecting && _shelfManagement.hasSelection)
          _buildBatchManagementBar(),
        if (_shelfManagement.managing && _sortMode == LibrarySortMode.custom)
          const Padding(padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Align(alignment: Alignment.centerLeft,
              child: Text('使用封面左上角拖动柄调整顺序；长按封面进入批量选择'))),
        Expanded(child: Stack(fit: StackFit.expand, children: [
          comics.isEmpty ? const Center(child: Text('当前筛选下没有漫画'))
            : _shelfViewMode == ShelfViewPreference.gallery ? _buildShelfGallery(comics) : _buildShelfList(comics),
          Positioned(left: ComicFilterPanel.horizontalInset, right: ComicFilterPanel.horizontalInset,
            bottom: ComicFilterPanel.bottomInset, child: _buildShelfFilters(libraryComics)),
        ])),
      ]);
    },
  );

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
