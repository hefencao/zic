part of 'comic_details.dart';

IconData _sourcePluginIcon(String sourceId) {
  if (sourceId.startsWith('mihon:')) {
    return Icons.extension_outlined;
  }
  if (sourceId.startsWith('venera:')) {
    return Icons.javascript_outlined;
  }
  return Icons.public;
}

final class _ComicDetailsFailureScaffold extends StatelessWidget {
  const _ComicDetailsFailureScaffold({
    required this.title,
    required this.comicId,
    required this.sourceId,
    required this.sourceLabel,
    required this.failure,
    required this.onRetry,
    required this.refreshing,
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
  });

  final String title;
  final String comicId;
  final String sourceId;
  final String sourceLabel;
  final _DetailFailure failure;
  final VoidCallback onRetry;
  final bool refreshing;
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(
        actions: <Widget>[
          if (onOpenSourceWebView != null)
            IconButton(
              key: comicDetailsOpenWebViewKey,
              tooltip: '在 WebView 中访问该漫画详情页',
              onPressed: () => unawaited(onOpenSourceWebView!()),
              icon: const Icon(Icons.public),
            ),
          _ComicDetailsMiscMenu(comicId: comicId, title: title),
          if (onOpenSourceSettings != null)
            _SourceSettingsAction(
              sourceId: sourceId,
              sourceLabel: sourceLabel,
              onPressed: () => unawaited(onOpenSourceSettings!()),
            ),
        ],
      ),
      body: _DetailFailurePanel(
        failure: failure,
        onRetry: refreshing ? null : onRetry,
      ),
    );
  }
}

final class _ComicDetailsScaffold extends StatefulWidget {
  const _ComicDetailsScaffold({
    required this.screenKey,
    required this.title,
    required this.comicId,
    required this.sourceId,
    required this.sourceLabel,
    required this.authors,
    required this.tags,
    required this.description,
    required this.cover,
    required this.preference,
    required this.categories,
    required this.descending,
    required this.onRefresh,
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.onSearchMetadata,
    this.onSearchTitle,
    this.onMigrateSource,
    required this.onPreferenceChanged,
    required this.progressLabel,
    this.onContinueReading,
    required this.downloadingComic,
    required this.onDownloadComic,
    this.onToggleWholeComicPause,
    this.wholeComicPausable = false,
    this.wholeComicPaused = false,
    required this.onReverse,
    required this.chapterCount,
    required this.pageCount,
    this.pageCountPending = false,
    required this.chapterSliver,
    this.loadVersionState,
    this.onViewVersion,
    this.onMigrateVersion,
    this.previewSection,
    this.commentsSection,
  });

  final Key screenKey;
  final String title;
  final String comicId;
  final String sourceId;
  final String sourceLabel;
  final List<String> authors;
  final List<String> tags;
  final String? description;
  final Widget cover;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final bool descending;
  final Future<bool> Function() onRefresh;
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final ComicDetailsMetadataSearch? onSearchTitle;
  final ComicDetailsSourceMigrator? onMigrateSource;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final String? progressLabel;
  final Future<void> Function()? onContinueReading;
  final bool downloadingComic;
  final Future<void> Function()? onDownloadComic;
  final Future<void> Function()? onToggleWholeComicPause;
  final bool wholeComicPausable;
  final bool wholeComicPaused;
  final VoidCallback onReverse;
  final int chapterCount;
  final int pageCount;
  final bool pageCountPending;
  final Widget chapterSliver;
  final ComicDetailsVersionStateLoader? loadVersionState;
  final ComicDetailsVersionViewer? onViewVersion;
  final ComicDetailsVersionMigrator? onMigrateVersion;
  final Widget? previewSection;
  final Widget? commentsSection;

  @override
  State<_ComicDetailsScaffold> createState() => _ComicDetailsScaffoldState();
}

final class _ComicDetailsScaffoldState extends State<_ComicDetailsScaffold> {
  Future<void> _editCategories(Rect anchor) async {
    if (widget.categories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无书架分类，请先在书架中新建分类')),
      );
      return;
    }
    final overlay = Navigator.of(context, rootNavigator: true)
        .overlay?.context.findRenderObject();
    if (overlay is! RenderBox || !overlay.hasSize) return;
    final localAnchor = Rect.fromPoints(
      overlay.globalToLocal(anchor.topLeft), overlay.globalToLocal(anchor.bottomRight),
    );
    final result = await showGeneralDialog<Set<String>>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      barrierLabel: '关闭书架分类',
      transitionDuration: const Duration(milliseconds: 180),
      transitionBuilder: (context, animation, secondary, child) => child,
      pageBuilder: (context, animation, secondary) => _ComicCategoryRing(
        anchor: localAnchor,
        categories: widget.categories,
        initialSelected: widget.preference.categoryIds,
        animation: animation,
      ),
    );
    if (!mounted || result == null) return;
    final current = widget.preference;
    if (current.inShelf && result.length == current.categoryIds.length &&
        result.containsAll(current.categoryIds)) return;
    await widget.onPreferenceChanged(current.copyWith(inShelf: true, categoryIds: result));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(
        actions: <Widget>[
          if (widget.onOpenSourceWebView != null)
            IconButton(
              key: comicDetailsOpenWebViewKey,
              tooltip: '在 WebView 中访问该漫画详情页',
              onPressed: () => unawaited(widget.onOpenSourceWebView!()),
              icon: const Icon(Icons.public),
            ),
          if (widget.loadVersionState != null &&
              widget.onViewVersion != null &&
              widget.onMigrateVersion != null)
            _ComicDetailsVersionActions(
              key: comicDetailsVersionSectionKey,
              load: widget.loadVersionState!,
              onView: widget.onViewVersion!,
              onMigrate: widget.onMigrateVersion!,
              onOpenMigration: widget.onMigrateSource,
            )
          else if (widget.onMigrateSource != null)
            IconButton(
              key: comicDetailsMigrateKey,
              tooltip: '迁移漫画源',
              onPressed: () => unawaited(widget.onMigrateSource!()),
              icon: const Icon(Icons.swap_horiz),
            ),
          _ComicDetailsMiscMenu(comicId: widget.comicId, title: widget.title),
          if (widget.onOpenSourceSettings != null)
            _SourceSettingsAction(
              sourceId: widget.sourceId,
              sourceLabel: widget.sourceLabel,
              onPressed: () => unawaited(widget.onOpenSourceSettings!()),
            ),
        ],
      ),
      body: KeyedSubtree(
        key: widget.screenKey,
        child: AppPullToRefresh(
          key: comicDetailsPullRefreshKey,
          resultKey: comicDetailsRefreshStateKey,
          onRefresh: widget.onRefresh,
          child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  sliver: SliverToBoxAdapter(
                    child: _ComicDetailsHeader(
                      title: widget.title,
                      sourceLabel: widget.sourceLabel,
                      authors: widget.authors,
                      tags: widget.tags,
                      description: widget.description,
                      cover: widget.cover,
                      preference: widget.preference,
                      onEditCategories: (anchor) => unawaited(_editCategories(anchor)),
                      onPreferenceChanged: widget.onPreferenceChanged,
                      onSearchMetadata: widget.onSearchMetadata,
                      onSearchTitle: widget.onSearchTitle,
                      downloadingComic: widget.downloadingComic,
                      onDownloadComic: widget.onDownloadComic,
                      onToggleWholeComicPause: widget.onToggleWholeComicPause,
                      wholeComicPausable: widget.wholeComicPausable,
                      wholeComicPaused: widget.wholeComicPaused,
                    ),
                  ),
                ),
                if (widget.onContinueReading != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    sliver: SliverToBoxAdapter(
                      child: _ComicDetailsReadingActions(
                        onContinueReading: widget.onContinueReading!,
                        progressLabel: widget.progressLabel,
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                  sliver: SliverToBoxAdapter(
                    child: KeyedSubtree(
                      key: comicDetailsChapterCountKey,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              widget.pageCountPending
                                  ? widget.pageCount == 0
                                      ? '${widget.chapterCount} 章 · 页数待加载'
                                      : '${widget.chapterCount} 章 · 已知 ${widget.pageCount} 页'
                                  : '${widget.chapterCount} 章 · ${widget.pageCount} 页',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            key: comicDetailsReverseKey,
                            tooltip: widget.descending ? '切换正序' : '切换倒序',
                            onPressed: widget.onReverse,
                            icon: Icon(
                              widget.descending
                                  ? Icons.arrow_downward
                                  : Icons.arrow_upward,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                KeyedSubtree(
                  key: comicDetailsChapterListKey,
                  child: widget.chapterSliver,
                ),
                if (widget.commentsSection != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: KeyedSubtree(
                        key: comicDetailsCommentsKey,
                        child: widget.commentsSection!,
                      ),
                    ),
                  ),
                if (widget.previewSection != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                    sliver: SliverToBoxAdapter(
                      child: KeyedSubtree(
                        key: comicDetailsPreviewKey,
                        child: widget.previewSection!,
                      ),
                    ),
                  ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 36)),
              ],
          ),
        ),
      ),
    );
  }
}

final class _ComicDetailsVersionActions extends StatefulWidget {
  const _ComicDetailsVersionActions({
    required this.load,
    required this.onView,
    required this.onMigrate,
    this.onOpenMigration,
    super.key,
  });

  final ComicDetailsVersionStateLoader load;
  final ComicDetailsVersionViewer onView;
  final ComicDetailsVersionMigrator onMigrate;
  final ComicDetailsSourceMigrator? onOpenMigration;

  @override
  State<_ComicDetailsVersionActions> createState() =>
      _ComicDetailsVersionActionsState();
}

final class _ComicDetailsVersionActionsState
    extends State<_ComicDetailsVersionActions> {
  late Future<ComicDetailsVersionState> _state;
  final ValueNotifier<ComicDetailsVersionState?> _resolvedState =
      ValueNotifier<ComicDetailsVersionState?>(null);
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _state = widget.load();
    unawaited(_consumeState(_state));
  }

  Future<void> _consumeState(
    Future<ComicDetailsVersionState> initial,
  ) async {
    final ComicDetailsVersionState state;
    try {
      state = await initial;
    } on Object {
      return;
    }
    if (!mounted) return;
    _resolvedState.value = state;
    final refresh = state.backgroundRefresh;
    if (refresh == null) return;
    final refreshed = await refresh;
    if (!mounted) return;
    _resolvedState.value = refreshed;
    setState(() {
      _state = Future<ComicDetailsVersionState>.value(refreshed);
    });
  }

  @override
  void dispose() {
    _resolvedState.dispose();
    super.dispose();
  }

  Future<void> _showVersions() async {
    // showDialog<SourceComicVersion> upgraded to _ComicDetailsVersionCommand
    final command = await showDialog<_ComicDetailsVersionCommand>(
      context: context,
      builder: (context) => _ComicDetailsVersionDialog(
        state: _resolvedState,
      ),
    );
    if (command == null || !mounted) return;
    setState(() => _working = true);
    try {
      await (command.migrate
          ? widget.onMigrate(command.version)
          : widget.onView(command.version));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openMigration() async {
    setState(() => _working = true);
    try {
      await widget.onOpenMigration!(versionState: _state);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _indicatorIcon(ComicDetailsVersionState state) {
    final hasSuccessors = state.successors.isNotEmpty;
    final hasPredecessors = state.predecessors.isNotEmpty;
    final angle = hasSuccessors && hasPredecessors
        ? math.pi / 2
        : hasPredecessors
            ? math.pi
            : 0.0;
    return Transform.rotate(
      angle: angle,
      child: const Icon(Icons.error_outline),
    );
  }

  String _tooltip(ComicDetailsVersionState state) {
    if (state.successors.isNotEmpty && state.predecessors.isNotEmpty) {
      return '存在新旧版本';
    }
    return state.predecessors.isNotEmpty ? '存在旧版本' : '发现同源更新';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ComicDetailsVersionState>(
      future: _state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final hasVersions = state != null && !state.isEmpty;
        final unified = widget.onOpenMigration != null;
        if (!hasVersions && !unified) {
          return const SizedBox.square(dimension: 48);
        }
        return IconButton(
          key: unified ? comicDetailsMigrateKey : comicDetailsVersionActionKey,
          tooltip: unified
              ? '迁移漫画源${hasVersions ? ' · ${_tooltip(state)}' : ''}'
              : _tooltip(state!),
          onPressed: _working
              ? null
              : () => unawaited(unified ? _openMigration() : _showVersions()),
          icon: _working
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : unified
                  ? Badge(
                      isLabelVisible: hasVersions,
                      label: const ExcludeSemantics(child: Text('!')),
                      child: const Icon(Icons.swap_horiz),
                    )
                  : _indicatorIcon(state!),
        );
      },
    );
  }
  // Historical dev.146 actions: child: Text('查看$label'), child: const Text('迁移')
  // superseded by _ComicDetailsVersionDialog ListTile actions.
}

final class _ComicDetailsVersionCommand {
  const _ComicDetailsVersionCommand({
    required this.version,
    required this.migrate,
  });

  final SourceComicVersion version;
  final bool migrate;
}

final class _ComicDetailsVersionDialog extends StatefulWidget {
  const _ComicDetailsVersionDialog({required this.state});

  final ValueNotifier<ComicDetailsVersionState?> state;

  @override
  State<_ComicDetailsVersionDialog> createState() =>
      _ComicDetailsVersionDialogState();
}

final class _ComicDetailsVersionDialogState
    extends State<_ComicDetailsVersionDialog> {
  late bool _showPredecessors;

  @override
  void initState() {
    super.initState();
    _showPredecessors = widget.state.value?.successors.isEmpty ?? false;
  }

  _ComicDetailsVersionCommand _command(
    SourceComicVersion version, {
    required bool migrate,
  }) =>
      _ComicDetailsVersionCommand(version: version, migrate: migrate);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ComicDetailsVersionState?>(
      valueListenable: widget.state,
      builder: (context, state, child) {
        if (state == null) return const SizedBox.shrink();
        final showPredecessors = _showPredecessors
            ? state.predecessors.isNotEmpty || state.successors.isEmpty
            : state.successors.isEmpty && state.predecessors.isNotEmpty;
        final versions = showPredecessors
            ? state.predecessors
            : state.successors;
        final canFlip = state.successors.isNotEmpty &&
            state.predecessors.isNotEmpty;
        final migrateToCurrent = state.predecessors.isEmpty
            ? null
            : state.predecessors.first;
        return AlertDialog(
          title: Text(showPredecessors ? '旧版本' : '新版本'),
          content: SizedBox(
            width: 520,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: versions.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final version = versions[index];
                final title = version.title.trim().isEmpty
                    ? (showPredecessors
                        ? '未命名旧版本'
                        : '未命名新版本')
                    : version.title.trim();
                final date = version.date?.trim();
                return ListTile(
                  key: index == 0 ? comicDetailsVersionViewKey : null,
                  title: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: date == null || date.isEmpty
                      ? null
                      : Text('更新日期：$date'),
                  onTap: () => Navigator.pop(
                    context,
                    _command(version, migrate: false),
                  ),
                  trailing: IconButton(
                    key: index == 0 ? comicDetailsVersionMigrateKey : null,
                    tooltip: version.isPredecessor
                        ? '迁移到当前版本'
                        : '迁移到此版本',
                    onPressed: () => Navigator.pop(
                      context,
                      _command(version, migrate: true),
                    ),
                    icon: const Icon(Icons.compare_arrows),
                  ),
                );
              },
            ),
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: <Widget>[
                IconButton(
                  key: comicDetailsVersionMigrateCurrentKey,
                  tooltip: '迁移到当前版本',
                  onPressed: migrateToCurrent == null
                      ? null
                      : () => Navigator.pop(
                            context,
                            _command(migrateToCurrent, migrate: true),
                          ),
                  icon: const Icon(Icons.compare_arrows),
                ),
                IconButton(
                  tooltip: showPredecessors ? '显示新版本' : '显示旧版本',
                  onPressed: canFlip
                      ? () => setState(() => _showPredecessors = !showPredecessors)
                      : null,
                  icon: const Icon(Icons.flip),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

final class _ComicCategoryRing extends StatefulWidget {
  const _ComicCategoryRing({required this.anchor, required this.categories,
    required this.initialSelected, required this.animation});

  final Rect anchor;
  final List<LibraryCategory> categories;
  final Set<String> initialSelected;
  final Animation<double> animation;

  @override
  State<_ComicCategoryRing> createState() => _ComicCategoryRingState();
}

final class _ComicCategoryRingState extends State<_ComicCategoryRing> {
  late final Set<String> _selected = widget.initialSelected.toSet();
  int _page = 0;
  static const _pageSize = 6;

  Widget _discBackground(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final highlight = Color.alphaBlend(
      colors.primary.withValues(alpha: dark ? 0.10 : 0.035),
      colors.surfaceContainerHigh,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(color: colors.shadow.withValues(alpha: dark ? 0.32 : 0.16),
            blurRadius: 32, offset: const Offset(0, 12)),
          BoxShadow(color: colors.shadow.withValues(alpha: 0.10),
            blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: <Color>[
                  Colors.white.withValues(alpha: dark ? 0.32 : 0.95),
                  colors.outlineVariant.withValues(alpha: 0.28),
                  colors.onSurface.withValues(alpha: 0.10),
                ],
                stops: const <double>[0, 0.45, 1],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: <Color>[
                      highlight.withValues(alpha: 0.90),
                      colors.surfaceContainerHigh.withValues(alpha: 0.82),
                      colors.surfaceContainer.withValues(alpha: 0.94),
                    ],
                  ),
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  onTap: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: LayoutBuilder(builder: (context, constraints) {
      final padding = MediaQuery.paddingOf(context);
      final safe = Rect.fromLTRB(padding.left + 12, padding.top + 12,
        constraints.maxWidth - padding.right - 12,
        constraints.maxHeight - padding.bottom - 12);
      final pillWidth = math.min(104.0, safe.width / 3);
      final preferredRadius = widget.categories.length <= 2 ? 72.0 : 104.0;
      final maxDiscRadius = math.min(safe.width, safe.height) / 2;
      final radius = math.max(0.0,
        math.min(preferredRadius, maxDiscRadius - pillWidth / 2 - 8));
      final discRadius = math.min(maxDiscRadius, radius + pillWidth / 2 + 8);
      final center = Offset(
        widget.anchor.center.dx.clamp(safe.left + discRadius,
          safe.right - discRadius).toDouble(),
        widget.anchor.center.dy.clamp(safe.top + discRadius,
          safe.bottom - discRadius).toDouble(),
      );
      final pageCount = (widget.categories.length + _pageSize - 1) ~/ _pageSize;
      final categories = widget.categories.skip(_page * _pageSize).take(_pageSize).toList();
      final centerHeight = pageCount > 1 ? 80.0 : 48.0;
      return AnimatedBuilder(animation: widget.animation,
        child: _discBackground(context), builder: (context, disc) {
        final t = Curves.easeOutCubic.transform(widget.animation.value);
        final movingCenter = Offset.lerp(widget.anchor.center, center, t)!;
        return Stack(children: <Widget>[
          Positioned.fill(child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(context),
          )),
          Positioned(
            left: movingCenter.dx - discRadius,
            top: movingCenter.dy - discRadius,
            width: discRadius * 2,
            height: discRadius * 2,
            child: Opacity(opacity: t, child: Transform.scale(scale: t,
              child: disc,
            )),
          ),
          for (var index = 0; index < categories.length; index++)
            Positioned(
              left: movingCenter.dx + math.cos(-math.pi / 2 + index * math.pi * 2 / categories.length) * radius * t - pillWidth / 2,
              top: movingCenter.dy + math.sin(-math.pi / 2 + index * math.pi * 2 / categories.length) * radius * t - 20,
              width: pillWidth,
              height: 40,
              child: Opacity(opacity: t, child: Transform.scale(scale: t,
                child: Center(child: Tooltip(message: categories[index].name,
                  child: FilterChip(
                    key: ValueKey<String>('comic-category:${categories[index].categoryId}'),
                    label: Text(categories[index].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    shape: const StadiumBorder(),
                    elevation: 5,
                    pressElevation: 7,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    showCheckmark: false,
                    selected: _selected.contains(categories[index].categoryId),
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selected.add(categories[index].categoryId);
                      } else {
                        _selected.remove(categories[index].categoryId);
                      }
                    }),
                  ),
                )),
              )),
            ),
          Positioned(
            left: movingCenter.dx - 40,
            top: movingCenter.dy - 24,
            width: 80,
            height: centerHeight,
            child: Opacity(opacity: t, child: Transform.scale(scale: t,
              child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                SizedBox.square(
                  dimension: 48,
                  child: IconButton.filledTonal(
                    tooltip: '保存分类',
                    style: IconButton.styleFrom(shape: const CircleBorder()),
                    onPressed: () => Navigator.pop(context, _selected),
                    icon: const Icon(Icons.save_outlined),
                  ),
                ),
                if (pageCount > 1) ...<Widget>[
                  const SizedBox(height: 4),
                  Row(children: <Widget>[
                    SizedBox.square(dimension: 28, child: IconButton(
                      tooltip: '上一组分类', padding: EdgeInsets.zero, iconSize: 16,
                      onPressed: () => setState(() => _page = (_page - 1 + pageCount) % pageCount),
                      icon: const Icon(Icons.chevron_left),
                    )),
                    Expanded(child: Text('${_page + 1}/$pageCount', textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall, maxLines: 1)),
                    SizedBox.square(dimension: 28, child: IconButton(
                      tooltip: '下一组分类', padding: EdgeInsets.zero, iconSize: 16,
                      onPressed: () => setState(() => _page = (_page + 1) % pageCount),
                      icon: const Icon(Icons.chevron_right),
                    )),
                  ]),
                ],
              ]),
            )),
          ),
        ]);
      });
    }),
  );
}

final class _ComicDetailsReadingActions extends StatelessWidget {
  const _ComicDetailsReadingActions({
    required this.onContinueReading,
    required this.progressLabel,
  });

  final Future<void> Function() onContinueReading;
  final String? progressLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          key: comicDetailsContinueReadingKey,
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
          onPressed: () => unawaited(onContinueReading()),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('继续'),
        ),
        if (progressLabel != null) ...<Widget>[
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              key: comicDetailsReadingHistoryKey,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.history, size: 18),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text('阅读历史 · $progressLabel')),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

enum _ComicDetailsMiscCommand { copyId, copyTitle, copyIdAndTitle }

final class _ComicDetailsMiscMenu extends StatelessWidget {
  const _ComicDetailsMiscMenu({required this.comicId, required this.title});

  final String comicId;
  final String title;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ComicDetailsMiscCommand>(
      key: comicDetailsMiscKey,
      tooltip: '杂项',
      icon: const Icon(Icons.more_horiz),
      onSelected: (command) => unawaited(_copy(context, command)),
      itemBuilder: (_) => const <PopupMenuEntry<_ComicDetailsMiscCommand>>[
        PopupMenuItem(
          value: _ComicDetailsMiscCommand.copyId,
          child: Text('复制漫画 ID'),
        ),
        PopupMenuItem(
          value: _ComicDetailsMiscCommand.copyTitle,
          child: Text('复制漫画标题'),
        ),
        PopupMenuItem(
          value: _ComicDetailsMiscCommand.copyIdAndTitle,
          child: Text('复制 ID 与标题'),
        ),
      ],
    );
  }

  Future<void> _copy(
    BuildContext context,
    _ComicDetailsMiscCommand command,
  ) async {
    final value = switch (command) {
      _ComicDetailsMiscCommand.copyId => comicId,
      _ComicDetailsMiscCommand.copyTitle => title,
      _ComicDetailsMiscCommand.copyIdAndTitle => '$title\n$comicId',
    };
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    final label = switch (command) {
      _ComicDetailsMiscCommand.copyId => '漫画 ID',
      _ComicDetailsMiscCommand.copyTitle => '漫画标题',
      _ComicDetailsMiscCommand.copyIdAndTitle => '漫画 ID 与标题',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制$label')),
    );
  }
}

final class _SourceSettingsAction extends StatelessWidget {
  const _SourceSettingsAction({
    required this.sourceId,
    required this.sourceLabel,
    required this.onPressed,
  });

  final String sourceId;
  final String sourceLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: comicDetailsSourceSettingsKey,
      tooltip: '设置漫画源：$sourceLabel',
      onPressed: onPressed,
      icon: Icon(_sourcePluginIcon(sourceId)),
    );
  }
}

// Visibility only: keep the source metadata and meaningful description intact.
final _descriptionMarkup = RegExp(
  r'<!--[\s\S]*?-->|</?[a-z][^>]*>|&(?:nbsp|ensp|emsp|thinsp|zwnj|zwj|hellip|mdash|ndash|amp|lt|gt|quot|apos);',
  caseSensitive: false,
);
final _descriptionNumericEntity = RegExp(r'&#(x[0-9a-f]+|[0-9]+);', caseSensitive: false);
final _descriptionNonText = RegExp(r'[^\p{L}\p{N}]', unicode: true);

String? _meaningfulComicDescription(String? description) {
  final value = description?.trim();
  if (value == null || value.isEmpty) return null;
  final content = value.replaceAll(_descriptionMarkup, '').replaceAllMapped(
    _descriptionNumericEntity,
    (match) {
      final raw = match.group(1)!;
      final hex = raw.toLowerCase().startsWith('x');
      final code = int.tryParse(hex ? raw.substring(1) : raw, radix: hex ? 16 : 10);
      return code == null || code > 0x10ffff || code >= 0xd800 && code <= 0xdfff
          ? match.group(0)!
          : String.fromCharCode(code);
    },
  );
  final key = content.replaceAll(_descriptionNonText, '').toLowerCase();
  const placeholders = <String>{
    '', '无', '暂无', '无简介', '暂无简介', '暂无介绍', '暂无描述', '没有简介',
    '未提供简介', '暫無簡介', '無簡介', '暫無介紹', '暫無描述',
    'na', 'none', 'null', 'undefined', 'nodescription',
    'nodescriptionavailable', 'nodescriptionyet', 'descriptionunavailable',
  };
  return placeholders.contains(key) ? null : value;
}

final class _SourceMetadataGroups {
  const _SourceMetadataGroups({
    required this.categories,
    required this.tags,
  });

  final List<String> categories;
  final List<String> tags;
}

_SourceMetadataGroups _groupSourceMetadata(List<String> rawTags) {
  const categoryNamespaces = <String>{
    'category',
    'categories',
    'type',
    '分类',
    '分類',
    '类型',
    '類型',
  };
  const tagNamespaces = <String>{
    'tag',
    'tags',
    'genre',
    'genres',
    '标签',
    '標籤',
  };
  const duplicatedAuthorNamespaces = <String>{
    'author',
    'authors',
    'artist',
    'artists',
    '作者',
    '画师',
    '畫師',
  };
  final categories = <String>[];
  final tags = <String>[];
  final categoryKeys = <String>{};
  final tagKeys = <String>{};

  void add(List<String> target, Set<String> keys, String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    final key = normalized.toLowerCase();
    if (keys.add(key)) target.add(normalized);
  }

  for (final raw in rawTags) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      add(tags, tagKeys, value);
      continue;
    }
    final namespace = value.substring(0, separator).trim().toLowerCase();
    final payload = value.substring(separator + 1).trim();
    if (categoryNamespaces.contains(namespace)) {
      add(categories, categoryKeys, payload);
    } else if (duplicatedAuthorNamespaces.contains(namespace)) {
      continue;
    } else if (tagNamespaces.contains(namespace)) {
      add(tags, tagKeys, payload);
    } else {
      add(tags, tagKeys, '$namespace：$payload');
    }
  }
  return _SourceMetadataGroups(
    categories: List<String>.unmodifiable(categories),
    tags: List<String>.unmodifiable(tags),
  );
}

final class _ExpandableTagRow extends StatefulWidget {
  const _ExpandableTagRow({
    required this.label,
    this.showHeading = true,
    required this.tags,
    this.onSearch,
  });

  final String label;
  final bool showHeading;
  final List<String> tags;
  final ComicDetailsMetadataSearch? onSearch;

  @override
  State<_ExpandableTagRow> createState() => _ExpandableTagRowState();
}

final class _ExpandableTagRowState extends State<_ExpandableTagRow> {
  bool _expanded = false;
  final Set<String> _selected = <String>{};

  void _toggleSelection(String tag) {
    setState(() {
      if (!_selected.add(tag)) {
        _selected.remove(tag);
      }
    });
  }

  void _handleTap(String tag) {
    if (_selected.isNotEmpty) {
      _toggleSelection(tag);
      return;
    }
    widget.onSearch?.call(tag);
  }

  Future<void> _copySelected() async {
    if (_selected.isEmpty) {
      return;
    }
    final values = widget.tags
        .where(_selected.contains)
        .toList(growable: false);
    await Clipboard.setData(ClipboardData(text: values.join('\n')));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${values.length} 项')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectionMode = _selected.isNotEmpty;
    final chips = <Widget>[
      for (final tag in widget.tags)
        Semantics(
          button: true,
          selected: _selected.contains(tag),
          label: '$tag；点击搜索，长按多选复制',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _handleTap(tag),
            onLongPress: () => _toggleSelection(tag),
            child: Chip(
              visualDensity: VisualDensity.compact,
              avatar: _selected.contains(tag)
                  ? const Icon(Icons.check, size: 16)
                  : null,
              label: Text(tag),
            ),
          ),
        ),
    ];
    final selectionLabel = widget.showHeading
        ? '${widget.label} · 已选 ${_selected.length}'
        : '已选 ${_selected.length}';
    final toggle = IconButton(
      tooltip: _expanded ? '收起${widget.label}' : '展开${widget.label}',
      onPressed: () => setState(() => _expanded = !_expanded),
      icon: Icon(
        _expanded ? Icons.expand_less : Icons.expand_more,
        size: 20,
      ),
    );
    final content = AnimatedSize(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.topLeft,
      child: _expanded
          ? Wrap(spacing: 6, runSpacing: 6, children: chips)
          : SizedBox(
              height: 36,
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Row(
                    children: <Widget>[
                      for (var index = 0;
                          index < chips.length;
                          index++) ...<Widget>[
                        if (index > 0) const SizedBox(width: 6),
                        chips[index],
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (widget.showHeading || selectionMode) ...<Widget>[
          Row(
            children: <Widget>[
              Text(
                selectionMode ? selectionLabel : widget.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              if (selectionMode) ...<Widget>[
                IconButton(
                  tooltip: '复制已选内容',
                  onPressed: () => unawaited(_copySelected()),
                  icon: const Icon(Icons.copy_outlined, size: 20),
                ),
                IconButton(
                  tooltip: '取消多选',
                  onPressed: () => setState(_selected.clear),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
              if (widget.showHeading) toggle,
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (widget.showHeading) content else SizedBox(
          width: double.infinity,
          child: Stack(
          children: <Widget>[
            Padding(padding: const EdgeInsets.only(bottom: 10), child: content),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Center(
                child: Tooltip(
                  message: _expanded ? '收起${widget.label}' : '展开${widget.label}',
                  child: Semantics(
                    button: true,
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: SizedBox(
                          width: 40,
                          height: 16,
                          child: Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          ),
        ),
      ],
    );
  }
}

ImportedLibraryEntry? _latestReadingEntry(
  Iterable<ImportedLibraryEntry> entries,
) {
  ImportedLibraryEntry? latest;
  for (final entry in entries) {
    final progress = entry.progress;
    if (progress == null) {
      continue;
    }
    final current = latest?.progress;
    if (current == null || progress.updatedAt.isAfter(current.updatedAt)) {
      latest = entry;
    }
  }
  return latest;
}

String? _readingProgressLabel(Iterable<ImportedLibraryEntry> entries) {
  final entry = _latestReadingEntry(entries);
  final progress = entry?.progress;
  if (entry == null || progress == null) {
    return null;
  }
  return '阅读到 ${entry.chapter.displayName} · 第 ${progress.pageIndex + 1} 页';
}
