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
                      categories: widget.categories,
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
            SizedBox(
              width: double.infinity,
              child: Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  const Spacer(),
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
                  const Spacer(),
                  IconButton(
                    tooltip:
                        showPredecessors ? '显示新版本' : '显示旧版本',
                    onPressed: canFlip
                        ? () => setState(
                              () => _showPredecessors = !showPredecessors,
                            )
                        : null,
                    icon: const Icon(Icons.flip),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
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
    this.label,
    required this.tags,
    this.onSearch,
  });

  final String? label;
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
    if (widget.label == null && !selectionMode) {
      return Wrap(spacing: 6, runSpacing: 6, children: chips);
    }
    final showAll = widget.label == null || _expanded;
    final selectionLabel = widget.label == null
        ? '已选 ${_selected.length}'
        : '${widget.label} · 已选 ${_selected.length}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              selectionMode
                  ? selectionLabel
                  : widget.label!,
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
            if (widget.label != null)
              IconButton(
                tooltip: _expanded ? '收起' : '展开',
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topLeft,
          child: showAll
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
