import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';

const comicSourcesPageKey = ValueKey<String>('comic-sources-page');
const comicSourceManageKey = ValueKey<String>('comic-source-manage');
const comicSourceSearchKey = ValueKey<String>('comic-source-search');
const comicSourceSwitcherKey = ValueKey<String>('comic-source-switcher');
const comicSourceLoadingKey = ValueKey<String>('comic-source-loading');
const comicSourceErrorKey = ValueKey<String>('comic-source-error');
const comicSourceEmptyKey = ValueKey<String>('comic-source-empty');
Key comicSourceChoiceKey(String sourceId) =>
    ValueKey<String>('comic-source-choice:$sourceId');
Key sourceComicCardKey(String comicId) =>
    ValueKey<String>('source-comic:$comicId');
Key sourceChapterKey(String chapterId) =>
    ValueKey<String>('source-chapter:$chapterId');

final class ComicSourcesPage extends StatefulWidget {
  const ComicSourcesPage({
    required this.sources,
    required this.activeSourceId,
    required this.onSourceSelected,
    required this.onOpenComic,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final String? activeSourceId;
  final ValueChanged<String> onSourceSelected;
  final Future<void> Function(
    BrowsableComicSource source,
    SourceComicSummary comic,
  ) onOpenComic;

  @override
  State<ComicSourcesPage> createState() => _ComicSourcesPageState();
}

final class _ComicSourcesPageState extends State<ComicSourcesPage> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<SourceComicSummary> _items = const <SourceComicSummary>[];
  String _query = '';
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextOffset = 0;
  Object? _error;
  int _generation = 0;

  BrowsableComicSource? get _activeSource {
    final id = widget.activeSourceId;
    if (id == null) {
      return null;
    }
    for (final source in widget.sources) {
      if (source.sourceId == id) {
        return source;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    scheduleMicrotask(() => unawaited(_reload()));
  }

  @override
  void didUpdateWidget(covariant ComicSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeSourceId != widget.activeSourceId ||
        !_sameSourceIds(oldWidget.sources, widget.sources)) {
      _query = '';
      _search.clear();
      scheduleMicrotask(() => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_handleScroll)
      ..dispose();
    _search.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scroll.hasClients ||
        _scroll.position.extentAfter > 520 ||
        _loading ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    unawaited(_loadMore());
  }

  Future<void> _reload() async {
    if (!mounted) {
      return;
    }
    final source = _activeSource;
    final generation = ++_generation;
    if (source == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _items = const <SourceComicSummary>[];
        _loading = false;
        _loadingMore = false;
        _hasMore = false;
        _nextOffset = 0;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _items = const <SourceComicSummary>[];
      _hasMore = false;
      _nextOffset = 0;
    });
    try {
      final page = await source.browse(query: _query, limit: 24);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _nextOffset = page.offset + page.items.length;
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() => _error = error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    final source = _activeSource;
    if (source == null || !_hasMore || _loadingMore) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await source.browse(
        query: _query,
        offset: _nextOffset,
        limit: 24,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      final known = _items.map((item) => item.comicId).toSet();
      setState(() {
        _items = <SourceComicSummary>[
          ..._items,
          ...page.items.where((item) => known.add(item.comicId)),
        ];
        _hasMore = page.hasMore;
        _nextOffset = page.offset + page.items.length;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载更多失败：$error')),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _submitSearch(String value) {
    _query = value.trim();
    unawaited(_reload());
  }

  @override
  Widget build(BuildContext context) {
    final source = _activeSource;
    return Column(
      key: comicSourcesPageKey,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: SearchBar(
            key: comicSourceSearchKey,
            controller: _search,
            enabled: source != null,
            hintText: source == null ? '请先启用漫画源' : '搜索 ${source.descriptor.name}',
            leading: const Icon(Icons.search),
            trailing: <Widget>[
              if (_search.text.isNotEmpty)
                IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _search.clear();
                    _submitSearch('');
                  },
                  icon: const Icon(Icons.close),
                ),
              IconButton(
                tooltip: '刷新',
                onPressed: source == null || _loading
                    ? null
                    : () => unawaited(_reload()),
                icon: const Icon(Icons.refresh),
              ),
            ],
            onChanged: (_) => setState(() {}),
            onSubmitted: _submitSearch,
          ),
        ),
        Expanded(child: _buildBody(source)),
        _SourceSwitcher(
          sources: widget.sources,
          activeSourceId: widget.activeSourceId,
          onSelected: widget.onSourceSelected,
        ),
      ],
    );
  }

  Widget _buildBody(BrowsableComicSource? source) {
    if (source == null) {
      return const Center(
        key: comicSourceEmptyKey,
        child: Text('没有已启用的漫画源，请从顶部管理入口启用。'),
      );
    }
    if (_loading) {
      return const Center(
        key: comicSourceLoadingKey,
        child: CircularProgressIndicator(),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        key: comicSourceErrorKey,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined, size: 44),
              const SizedBox(height: 12),
              Text('漫画源加载失败：$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => unawaited(_reload()),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        key: comicSourceEmptyKey,
        child: Text(_query.isEmpty ? '该漫画源暂无内容' : '没有匹配的漫画'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const width = 132.0;
        const spacing = 12.0;
        final count = ((constraints.maxWidth + spacing) / (width + spacing))
            .floor()
            .clamp(1, 12)
            .toInt();
        final used = count * width + (count - 1) * spacing;
        final padding = ((constraints.maxWidth - used) / 2).clamp(12, 80).toDouble();
        return GridView.builder(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(padding, 8, padding, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisExtent: 224,
            crossAxisSpacing: spacing,
            mainAxisSpacing: 12,
          ),
          itemCount: _items.length + (_loadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _items.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final comic = _items[index];
            return _SourceComicCard(
              key: sourceComicCardKey(comic.comicId),
              source: source,
              comic: comic,
              reloadToken: _generation,
              onTap: () => unawaited(
                widget.onOpenComic(source, comic),
              ),
            );
          },
        );
      },
    );
  }
}

final class _SourceSwitcher extends StatelessWidget {
  const _SourceSwitcher({
    required this.sources,
    required this.activeSourceId,
    required this.onSelected,
  });

  final List<BrowsableComicSource> sources;
  final String? activeSourceId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: comicSourceSwitcherKey,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: sources.isEmpty
              ? const Center(child: Text('没有已启用的漫画源'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: sources.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    return ChoiceChip(
                      key: comicSourceChoiceKey(source.sourceId),
                      label: Text(source.descriptor.name),
                      selected: source.sourceId == activeSourceId,
                      showCheckmark: false,
                      onSelected: (_) => onSelected(source.sourceId),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

final class _SourceComicCard extends StatelessWidget {
  const _SourceComicCard({
    required this.source,
    required this.comic,
    required this.reloadToken,
    required this.onTap,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary comic;
  final int reloadToken;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _RemoteImage(
                uri: comic.coverUri,
                loadBytes: source.loadResource,
                reloadToken: reloadToken,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            comic.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}

final class SourceManagementScreen extends StatefulWidget {
  const SourceManagementScreen({
    required this.sources,
    required this.preferences,
    required this.onPreferenceChanged,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final Map<String, ComicSourcePreference> preferences;
  final Future<void> Function(ComicSourcePreference preference)
      onPreferenceChanged;

  @override
  State<SourceManagementScreen> createState() =>
      _SourceManagementScreenState();
}

final class _SourceManagementScreenState
    extends State<SourceManagementScreen> {
  late List<BrowsableComicSource> _sources;
  late Map<String, ComicSourcePreference> _preferences;

  @override
  void initState() {
    super.initState();
    _preferences = Map<String, ComicSourcePreference>.from(widget.preferences);
    _sources = widget.sources.toList(growable: true)
      ..sort((left, right) => _preference(left).sortOrder.compareTo(
            _preference(right).sortOrder,
          ));
  }

  ComicSourcePreference _preference(BrowsableComicSource source) =>
      _preferences[source.sourceId] ??
      ComicSourcePreference.defaults(sourceId: source.sourceId);

  Future<void> _toggle(BrowsableComicSource source, bool enabled) async {
    final previous = _preference(source);
    final next = previous.copyWith(
      enabled: enabled,
      updatedAt: DateTime.now().toUtc(),
    );
    setState(() => _preferences[source.sourceId] = next);
    try {
      await widget.onPreferenceChanged(next);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _preferences[source.sourceId] = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存漫画源设置失败：$error')),
      );
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex--;
    }
    final moved = _sources.removeAt(oldIndex);
    _sources.insert(newIndex, moved);
    final now = DateTime.now().toUtc();
    final updates = <ComicSourcePreference>[];
    for (var index = 0; index < _sources.length; index++) {
      final source = _sources[index];
      final next = _preference(source).copyWith(
        sortOrder: index,
        updatedAt: now.add(Duration(microseconds: index)),
      );
      _preferences[source.sourceId] = next;
      updates.add(next);
    }
    setState(() {});
    try {
      for (final preference in updates) {
        await widget.onPreferenceChanged(preference);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存漫画源顺序失败：$error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('漫画源管理')),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _sources.length,
        onReorder: (oldIndex, newIndex) {
          unawaited(_reorder(oldIndex, newIndex));
        },
        itemBuilder: (context, index) {
          final source = _sources[index];
          final preference = _preference(source);
          return SwitchListTile(
            key: ValueKey<String>('source-manager:${source.sourceId}'),
            value: preference.enabled,
            onChanged: (value) {
              unawaited(_toggle(source, value));
            },
            secondary: const Icon(Icons.public),
            title: Text(source.descriptor.name),
            subtitle: Text(
              '${source.descriptor.language} · ${source.descriptor.website.host}',
            ),
          );
        },
      ),
    );
  }
}

typedef SourceChapterAction = Future<void> Function(
  BrowsableComicSource source,
  Comic comic,
  Chapter chapter, {
  required bool open,
});

final class SourceComicDetailsScreen extends StatefulWidget {
  const SourceComicDetailsScreen({
    required this.source,
    required this.summary,
    required this.onChapterAction,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary summary;
  final SourceChapterAction onChapterAction;

  @override
  State<SourceComicDetailsScreen> createState() =>
      _SourceComicDetailsScreenState();
}

final class _SourceComicDetailsScreenState
    extends State<SourceComicDetailsScreen> {
  late Future<ComicManifest> _manifest;
  final Set<String> _working = <String>{};

  @override
  void initState() {
    super.initState();
    _manifest = widget.source.loadComic(widget.summary.comicId);
  }

  void _reload() {
    setState(() {
      _manifest = widget.source.loadComic(widget.summary.comicId);
    });
  }

  Future<void> _run(
    Comic comic,
    Chapter chapter, {
    required bool open,
  }) async {
    if (!_working.add(chapter.chapterId)) {
      return;
    }
    setState(() {});
    try {
      await widget.onChapterAction(
        widget.source,
        comic,
        chapter,
        open: open,
      );
      if (mounted && !open) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将“${chapter.title}”加入书架')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${open ? '打开' : '加入书架'}失败：$error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _working.remove(chapter.chapterId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.summary.title)),
      body: FutureBuilder<ComicManifest>(
        future: _manifest,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.cloud_off_outlined, size: 44),
                    const SizedBox(height: 12),
                    Text(
                      '漫画详情加载失败：${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            );
          }
          final manifest = snapshot.data!;
          final chapters = manifest.chapters.reversed.toList(growable: false);
          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 112,
                        height: 150,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _RemoteImage(
                            uri: manifest.comic.coverUri,
                            loadBytes: widget.source.loadResource,
                            reloadToken: 0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              manifest.comic.title,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            if (manifest.comic.authors.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 6),
                              Text(manifest.comic.authors.join('、')),
                            ],
                            const SizedBox(height: 8),
                            Text('${chapters.length} 章'),
                            if (widget.summary.description != null) ...<Widget>[
                              const SizedBox(height: 10),
                              Text(
                                widget.summary.description!,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (chapters.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('当前语言下没有可读章节')),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final chapter = chapters[index];
                      final working = _working.contains(chapter.chapterId);
                      return ListTile(
                        key: sourceChapterKey(chapter.chapterId),
                        title: Text(chapter.title),
                        subtitle: chapter.publishedAt == null
                            ? Text('${chapter.pageCount} 页')
                            : Text(
                                '${chapter.pageCount} 页 · '
                                '${chapter.publishedAt!.toLocal().toString().split(' ').first}',
                              ),
                        onTap: working
                            ? null
                            : () => unawaited(
                                  _run(
                                    manifest.comic,
                                    chapter,
                                    open: true,
                                  ),
                                ),
                        trailing: working
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton(
                                tooltip: '加入书架',
                                onPressed: () => unawaited(
                                  _run(
                                    manifest.comic,
                                    chapter,
                                    open: false,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.bookmark_add_outlined,
                                ),
                              ),
                      );
                    },
                    childCount: chapters.length,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

final class _RemoteImage extends StatefulWidget {
  const _RemoteImage({
    required this.uri,
    required this.loadBytes,
    required this.reloadToken,
  });

  final Uri? uri;
  final Future<Uint8List> Function(Uri uri) loadBytes;
  final int reloadToken;

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

final class _RemoteImageState extends State<_RemoteImage> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.loadBytes != widget.loadBytes ||
        oldWidget.reloadToken != widget.reloadToken) {
      _load();
    }
  }

  void _load() {
    final uri = widget.uri;
    _bytes = uri == null ? null : widget.loadBytes(uri);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return Image.memory(
            data,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image_outlined),
            ),
          );
        }
        if (snapshot.hasError) {
          return const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          );
        }
        return const ColoredBox(
          color: Color(0x08000000),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}

bool _sameSourceIds(
  List<BrowsableComicSource> left,
  List<BrowsableComicSource> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index].sourceId != right[index].sourceId) {
      return false;
    }
  }
  return true;
}
