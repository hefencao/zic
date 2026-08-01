import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:downloads/downloads.dart';
import 'comic_details.dart' as details;
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'external_plugin_repository_model.dart';
import 'external_plugin_repository_screen.dart';
import 'external_source_settings_screen.dart';

const comicSourcesPageKey = ValueKey<String>('comic-sources-page');
const comicSourceManageKey = ValueKey<String>('comic-source-manage');
const sourceManagementScreenKey =
    ValueKey<String>('source-management-screen');
const comicSourceSearchKey = ValueKey<String>('comic-source-search');
const comicSourceSwitcherKey = ValueKey<String>('comic-source-switcher');
const comicSourceLoadingKey = ValueKey<String>('comic-source-loading');
const comicSourceErrorKey = ValueKey<String>('comic-source-error');
const comicSourceErrorDetailsKey =
    ValueKey<String>('comic-source-error-details');
const comicSourceCopyErrorKey = ValueKey<String>('comic-source-copy-error');
const comicSourceEmptyKey = ValueKey<String>('comic-source-empty');
Key comicSourceChoiceKey(String sourceId) =>
    ValueKey<String>('comic-source-choice:$sourceId');
Key sourceComicCardKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic:$sourceId\u0000$comicId');
Key sourceChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

typedef SourceComicCoverLoader = Future<Uint8List> Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
  Uri uri,
);

final class ComicSourcesPage extends StatefulWidget {
  const ComicSourcesPage({
    required this.sources,
    required this.activeSourceId,
    required this.onSourceSelected,
    required this.loadCover,
    required this.onOpenComic,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final String? activeSourceId;
  final ValueChanged<String> onSourceSelected;
  final SourceComicCoverLoader loadCover;
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
  _SourceFailure? _failure;
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

  Future<void> _reload({bool forceRefresh = false}) async {
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
        _failure = null;
      });
      return;
    }
    if (forceRefresh) {
      invalidateCachedSearch(source);
    }
    setState(() {
      _loading = true;
      _loadingMore = false;
      _failure = null;
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
    } on Object catch (error, stackTrace) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _failure = _SourceFailure.capture(error, stackTrace);
      });
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
    } on Object catch (error, stackTrace) {
      if (mounted && generation == _generation) {
        _showSourceFailureSnackBar(
          context,
          prefix: '加载更多失败',
          failure: _SourceFailure.capture(error, stackTrace),
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
                    : () => unawaited(_reload(forceRefresh: true)),
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
    final failure = _failure;
    if (failure != null) {
      return _SourceFailurePanel(
        key: comicSourceErrorKey,
        title: '漫画源加载失败',
        failure: failure,
        onRetry: () => unawaited(_reload(forceRefresh: true)),
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
              key: sourceComicCardKey(source.sourceId, comic.comicId),
              source: source,
              comic: comic,
              reloadToken: _generation,
              loadCover: widget.loadCover,
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
    required this.loadCover,
    required this.onTap,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary comic;
  final int reloadToken;
  final SourceComicCoverLoader loadCover;
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
                loadBytes: (uri) => loadCover(source, comic, uri),
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
    this.externalPlugins,
    this.onExternalSourcesChanged,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final Map<String, ComicSourcePreference> preferences;
  final Future<void> Function(ComicSourcePreference preference)
      onPreferenceChanged;
  final ExternalPluginController? externalPlugins;
  final Future<void> Function()? onExternalSourcesChanged;

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
    } on Object catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      setState(() => _preferences[source.sourceId] = previous);
      _showSourceFailureSnackBar(
        context,
        prefix: '保存漫画源设置失败',
        failure: _SourceFailure.capture(error, stackTrace),
      );
    }
  }


  Future<void> _persistSourceOrder(
    List<BrowsableComicSource> ordered,
  ) async {
    final previous = List<BrowsableComicSource>.of(_sources);
    final previousPreferences =
        Map<String, ComicSourcePreference>.of(_preferences);
    final now = DateTime.now().toUtc();
    final updates = <ComicSourcePreference>[];
    setState(() {
      _sources = List<BrowsableComicSource>.of(ordered);
      for (var index = 0; index < _sources.length; index++) {
        final source = _sources[index];
        final next = _preference(source).copyWith(
          sortOrder: index,
          updatedAt: now.add(Duration(microseconds: index)),
        );
        _preferences[source.sourceId] = next;
        updates.add(next);
      }
    });
    try {
      for (final preference in updates) {
        await widget.onPreferenceChanged(preference);
      }
    } on Object catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _sources = previous;
        _preferences = previousPreferences;
      });
      _showSourceFailureSnackBar(
        context,
        prefix: '保存漫画源顺序失败',
        failure: _SourceFailure.capture(error, stackTrace),
      );
    }
  }

  Future<void> _persistSourceCategory(
    List<BrowsableComicSource> orderedCategory,
  ) async {
    if (orderedCategory.isEmpty) return;
    final native = _sources
        .where((source) =>
            !source.sourceId.startsWith('mihon:') &&
            !source.sourceId.startsWith('venera:'))
        .toList(growable: false);
    final mihon = _sources
        .where((source) => source.sourceId.startsWith('mihon:'))
        .toList(growable: false);
    final venera = _sources
        .where((source) => source.sourceId.startsWith('venera:'))
        .toList(growable: false);
    if (orderedCategory.first.sourceId.startsWith('mihon:')) {
      await _persistSourceOrder(<BrowsableComicSource>[
        ...native,
        ...orderedCategory,
        ...venera,
      ]);
    } else if (orderedCategory.first.sourceId.startsWith('venera:')) {
      await _persistSourceOrder(<BrowsableComicSource>[
        ...native,
        ...mihon,
        ...orderedCategory,
      ]);
    } else {
      await _persistSourceOrder(<BrowsableComicSource>[
        ...orderedCategory,
        ...mihon,
        ...venera,
      ]);
    }
  }

  Future<void> _reorderSourceCategory(
    List<BrowsableComicSource> category,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex--;
    final reordered = List<BrowsableComicSource>.of(category);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    await _persistSourceCategory(reordered);
  }

  Widget _reorderableSourceList(List<BrowsableComicSource> sources) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sources.length,
      onReorder: (oldIndex, newIndex) =>
          unawaited(_reorderSourceCategory(sources, oldIndex, newIndex)),
      itemBuilder: (context, index) => _sourceTile(sources[index]),
    );
  }

  Future<void> _openExternalRepository(
    ExternalComicPluginFormat format,
  ) async {
    final controller = widget.externalPlugins;
    final changed = widget.onExternalSourcesChanged;
    if (controller == null || changed == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExternalPluginRepositoryScreen(
          format: format,
          controller: controller,
          onSourcesChanged: changed,
        ),
      ),
    );
    if (mounted) {
      _refreshExternalSources(controller);
    }
  }

  void _refreshExternalSources(ExternalPluginController controller) {
    final builtIn = _sources.where(
      (source) =>
          !source.sourceId.startsWith('mihon:') &&
          !source.sourceId.startsWith('venera:'),
    );
    setState(() {
      _sources = <BrowsableComicSource>[
        ...builtIn,
        ...controller.activeSources,
      ]..sort((left, right) => _preference(left).sortOrder.compareTo(
            _preference(right).sortOrder,
          ));
    });
  }


  Future<void> _openSourceSettings(BrowsableComicSource source) async {
    final controller = widget.externalPlugins;
    final changed = widget.onExternalSourcesChanged;
    if (controller == null || changed == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExternalSourceSettingsScreen(
          source: source,
          onApply: () async {
            await controller.restartSource(source.sourceId);
            await changed();
          },
          onLogin: source.sourceId.startsWith('mihon:') ||
                  source.sourceId.startsWith('venera:')
              ? controller.openMihonLogin
              : null,
          onReadLogin: source.sourceId.startsWith('venera:')
              ? (url) async {
                  final snapshot =
                      await controller.readExternalLoginSnapshot(url);
                  return snapshot == null
                      ? null
                      : (
                          currentUrl: snapshot.currentUrl,
                          title: snapshot.title,
                          cookies: snapshot.cookies,
                          localStorage: snapshot.localStorage,
                        );
                }
              : null,
        ),
      ),
    );
    if (mounted) _refreshExternalSources(controller);
  }

  Widget _sourceTile(
    BrowsableComicSource source, {
    bool nested = false,
  }) {
    final preference = _preference(source);
    return SwitchListTile(
      key: ValueKey<String>('source-manager:${source.sourceId}'),
      contentPadding: EdgeInsets.fromLTRB(nested ? 40 : 16, 0, 12, 0),
      value: preference.enabled,
      onChanged: (value) => unawaited(_toggle(source, value)),
      secondary: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            source.sourceId.startsWith('mihon:')
                ? Icons.extension_outlined
                : source.sourceId.startsWith('venera:')
                    ? Icons.javascript_outlined
                    : Icons.public,
          ),
          if ((source.sourceId.startsWith('mihon:') ||
                  source.sourceId.startsWith('venera:')) &&
              source is ConfigurableComicSource)
            IconButton(
              key: ValueKey<String>('source-settings:${source.sourceId}'),
              tooltip: '插件设置与登录',
              onPressed: () => unawaited(_openSourceSettings(source)),
              icon: const Icon(Icons.settings_outlined),
            ),
        ],
      ),
      title: Text(source.descriptor.name),
      subtitle: Text(
        '${source.descriptor.language} · ${source.descriptor.website.host}',
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required IconData icon,
    required int count,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text('$title（$count）', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );

  Widget _mihonSourceList(BuildContext context) {
    final mihonSources = _sources
        .where((source) => source.sourceId.startsWith('mihon:'))
        .toList(growable: false);
    final groups = groupMihonSourcesByLanguage(
      mihonSources,
      preferredLanguage: Localizations.localeOf(context).languageCode,
      pluginOwner: (sourceId) =>
          widget.externalPlugins?.ownerOfSource(sourceId),
    );
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: groups.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        final reordered = List<MihonSourceLanguageGroup>.of(groups);
        final moved = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, moved);
        final flattened = <BrowsableComicSource>[
          for (final group in reordered)
            ...<BrowsableComicSource>[
              group.defaultSource,
              ...group.otherLanguages,
            ],
        ];
        unawaited(_persistSourceCategory(flattened));
      },
      itemBuilder: (context, index) {
        final group = groups[index];
        return KeyedSubtree(
          key: ValueKey<String>('mihon-source-group:${group.groupKey}'),
          child: Column(
            children: <Widget>[
              _sourceTile(group.defaultSource),
              if (group.otherLanguages.isNotEmpty)
                ExpansionTile(
                  key: PageStorageKey<String>(
                    'source-manager-mihon-languages:${group.groupKey}',
                  ),
                  initiallyExpanded: false,
                  leading: const Icon(Icons.translate_outlined),
                  title: Text('其他语言（${group.otherLanguages.length}）'),
                  subtitle: Text(
                    group.otherLanguages
                        .map((source) => source.descriptor.language)
                        .join('、'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  children: <Widget>[
                    for (final source in group.otherLanguages)
                      _sourceTile(source, nested: true),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final nativeSources = _sources
        .where(
          (source) =>
              !source.sourceId.startsWith('mihon:') &&
              !source.sourceId.startsWith('venera:'),
        )
        .toList(growable: false);
    final mihonSources = _sources
        .where((source) => source.sourceId.startsWith('mihon:'))
        .toList(growable: false);
    final veneraSources = _sources
        .where((source) => source.sourceId.startsWith('venera:'))
        .toList(growable: false);

    return Scaffold(
      key: sourceManagementScreenKey,
      appBar: AppBar(title: const Text('漫画源管理')),
      body: Column(
        children: <Widget>[
          if (widget.externalPlugins != null)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: const Text('Mihon 扩展'),
                    subtitle: const Text('管理已安装 APK、设备扩展与兼容仓库'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(
                      _openExternalRepository(
                        ExternalComicPluginFormat.mihonExtension,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.javascript_outlined),
                    title: const Text('Venera 漫画源'),
                    subtitle: const Text('管理已安装 JavaScript 源与兼容仓库'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(
                      _openExternalRepository(
                        ExternalComicPluginFormat.veneraJavaScript,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: <Widget>[
                _sectionHeader(
                  context,
                  title: '原生',
                  icon: Icons.apps_outlined,
                  count: nativeSources.length,
                ),
                if (nativeSources.isEmpty)
                  const ListTile(title: Text('没有原生漫画源'))
                else
                  _reorderableSourceList(nativeSources),
                const Divider(height: 1),
                _sectionHeader(
                  context,
                  title: 'Mihon',
                  icon: Icons.extension_outlined,
                  count: mihonSources.length,
                ),
                if (mihonSources.isEmpty)
                  const ListTile(title: Text('没有已启用的 Mihon 漫画源'))
                else
                  _mihonSourceList(context),
                const Divider(height: 1),
                _sectionHeader(
                  context,
                  title: 'Venera',
                  icon: Icons.javascript_outlined,
                  count: veneraSources.length,
                ),
                if (veneraSources.isEmpty)
                  const ListTile(title: Text('没有已启用的 Venera 漫画源'))
                else
                  _reorderableSourceList(veneraSources),
              ],
            ),
          ),
        ],
      ),
    );
  }

}

final class SourceComicDetailsScreen extends StatelessWidget {
  const SourceComicDetailsScreen({
    required this.initialLibrary,
    required this.source,
    required this.summary,
    required this.categories,
    required this.loadCover,
    required this.reloadLibrary,
    required this.ensureSourceChapter,
    required this.persistComic,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    required this.onDownloadChapter,
    required this.inspectChapterDownload,
    required this.downloadChanges,
    required this.onDownloadComic,
    super.key,
  });

  final details.ComicDetailsLibrarySnapshot initialLibrary;
  final BrowsableComicSource source;
  final SourceComicSummary summary;
  final List<LibraryCategory> categories;
  final details.ComicDetailsCoverLoader loadCover;
  final details.ComicDetailsLibraryReloader reloadLibrary;
  final details.ComicDetailsChapterEnsurer ensureSourceChapter;
  final details.ComicDetailsComicPersister persistComic;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final details.ComicDetailsChapterOpener onOpenChapter;
  final details.ComicDetailsChapterDownloader onDownloadChapter;
  final details.ComicDetailsChapterDownloadInspector inspectChapterDownload;
  final Stream<ChapterDownloadSnapshot> downloadChanges;
  final details.ComicDetailsComicDownloader onDownloadComic;

  @override
  Widget build(BuildContext context) {
    return details.RemoteComicDetailsScreen(
      initialLibrary: initialLibrary,
      source: source,
      summary: summary,
      categories: categories,
      loadCover: loadCover,
      reloadLibrary: reloadLibrary,
      ensureSourceChapter: ensureSourceChapter,
      persistComic: persistComic,
      onPreferenceChanged: onPreferenceChanged,
      onReadChanged: onReadChanged,
      onOpenChapter: onOpenChapter,
      onDownloadChapter: onDownloadChapter,
      inspectChapterDownload: inspectChapterDownload,
      downloadChanges: downloadChanges,
      onDownloadComic: onDownloadComic,
    );
  }
}

final class _SourceFailure {
  const _SourceFailure({
    required this.summary,
    required this.guidance,
    required this.details,
  });

  factory _SourceFailure.capture(
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final detailLines = <String>[error.toString()];
    if (error is Failure) {
      final cause = error.cause;
      if (cause != null && cause.toString() != error.toString()) {
        detailLines.add('Cause: $cause');
      }
    }
    if (stackTrace != null) {
      detailLines
        ..add('')
        ..add('Stack trace:')
        ..add(stackTrace.toString().trimRight());
    }
    final details = detailLines.join('\n');
    final lower = details.toLowerCase();
    final host = _hostFromFailure(details);

    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname provided')) {
      return _SourceFailure(
        summary: host == null ? '无法解析漫画源主机' : '无法解析 $host',
        guidance: 'Android 应用必须在主清单中声明 INTERNET 权限。若已重新构建并安装，'
            '仍出现该错误，则设备的系统 DNS 可能与浏览器使用的安全 DNS 不同。',
        details: details,
      );
    }
    if (error is Failure && error.code == ErrorCode.network) {
      return _SourceFailure(
        summary: '无法连接漫画源',
        guidance: '请检查网络、系统代理或 VPN 后重试。完整请求与底层错误可在下方选择或复制。',
        details: details,
      );
    }
    return _SourceFailure(
      summary: '漫画源返回了错误',
      guidance: '完整错误可在下方长按选择或一键复制。',
      details: details,
    );
  }

  final String summary;
  final String guidance;
  final String details;
}

final class _SourceFailurePanel extends StatelessWidget {
  const _SourceFailurePanel({
    required this.title,
    required this.failure,
    required this.onRetry,
    super.key,
  });

  final String title;
  final _SourceFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 44,
                    color: colors.error,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    failure.summary,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(failure.guidance, textAlign: TextAlign.center),
                  const SizedBox(height: 14),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                      OutlinedButton.icon(
                        key: comicSourceCopyErrorKey,
                        onPressed: () => unawaited(
                          _copySourceFailure(context, failure),
                        ),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制完整错误'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          failure.details,
                          key: comicSourceErrorDetailsKey,
                          style: Theme.of(context).textTheme.bodySmall,
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

Future<void> _copySourceFailure(
  BuildContext context,
  _SourceFailure failure,
) async {
  await Clipboard.setData(ClipboardData(text: failure.details));
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已复制完整错误')),
  );
}

void _showSourceFailureSnackBar(
  BuildContext context, {
  required String prefix,
  required _SourceFailure failure,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$prefix：${failure.summary}'),
      action: SnackBarAction(
        label: '复制',
        onPressed: () {
          unawaited(_copySourceFailure(context, failure));
        },
      ),
    ),
  );
}

String? _hostFromFailure(String details) {
  final match = RegExp(r'https?://([^/\s?#]+)').firstMatch(details);
  return match?.group(1);
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
