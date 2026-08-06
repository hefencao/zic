import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'package:downloads/downloads.dart';
import 'artwork_placeholder.dart';
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
const comicSourceOpenWebViewKey =
    ValueKey<String>('comic-source-open-webview');
const comicSourceEmptyKey = ValueKey<String>('comic-source-empty');
const comicSourceCategoryBarKey =
    ValueKey<String>('comic-source-category-bar');
const comicSourcePagerKey = ValueKey<String>('comic-source-pager');
const comicSourcePreviousPageKey =
    ValueKey<String>('comic-source-previous-page');
const comicSourceNextPageKey = ValueKey<String>('comic-source-next-page');
const comicSourcePageLabelKey = ValueKey<String>('comic-source-page-label');
Key comicSourceCategoryKey(String category) =>
    ValueKey<String>('comic-source-category:$category');
Key comicSourceChoiceKey(String sourceId) =>
    ValueKey<String>('comic-source-choice:$sourceId');
Key sourceComicCardKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic:$sourceId\u0000$comicId');
Key sourceComicCoverVerificationKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-verify:$sourceId\u0000$comicId');
Key sourceChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

typedef SourceComicCoverLoader = Future<EncodedResourceSource> Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
  Uri uri,
);

enum _ComicSourceCategory { all, native, mihon, venera }

_ComicSourceCategory _comicSourceCategoryOf(BrowsableComicSource source) {
  if (source.sourceId.startsWith('mihon:')) {
    return _ComicSourceCategory.mihon;
  }
  if (source.sourceId.startsWith('venera:')) {
    return _ComicSourceCategory.venera;
  }
  return _ComicSourceCategory.native;
}

String _comicSourceCategoryLabel(_ComicSourceCategory category) =>
    switch (category) {
      _ComicSourceCategory.all => '全部',
      _ComicSourceCategory.native => '原生',
      _ComicSourceCategory.mihon => 'Mihon',
      _ComicSourceCategory.venera => 'Venera',
    };

IconData _comicSourceCategoryIcon(_ComicSourceCategory category) =>
    switch (category) {
      _ComicSourceCategory.all => Icons.apps_outlined,
      _ComicSourceCategory.native => Icons.public,
      _ComicSourceCategory.mihon => Icons.extension_outlined,
      _ComicSourceCategory.venera => Icons.javascript_outlined,
    };

bool _comicSourceCategoryContains(
  _ComicSourceCategory category,
  BrowsableComicSource source,
) =>
    category == _ComicSourceCategory.all ||
    _comicSourceCategoryOf(source) == category;

ComicWebViewRequest _browserRequestForSource(
  BrowsableComicSource source,
  Uri url,
) {
  final Object candidate = source;
  final ComicWebViewRequestSource? requestSource =
      candidate is ComicWebViewRequestSource ? candidate : null;
  return requestSource?.webViewRequest(url) ?? ComicWebViewRequest(url: url);
}

bool sourceSupportsSettings(BrowsableComicSource source) {
  final Object candidate =
      source is CachedBrowsableComicSource ? source.source : source;
  return candidate is ConfigurableComicSource;
}

Future<void> openComicSourceSettings(
  BuildContext context, {
  required BrowsableComicSource source,
  required AndroidNetworkBridge networkBridge,
  ExternalPluginController? externalPlugins,
  Future<void> Function()? onExternalSourcesChanged,
}) async {
  if (!sourceSupportsSettings(source)) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ExternalSourceSettingsScreen(
        source: source,
        onApply: () async {
          if (externalPlugins != null &&
              (source.sourceId.startsWith('mihon:') ||
                  source.sourceId.startsWith('venera:'))) {
            await externalPlugins.restartSource(source.sourceId);
          }
          await onExternalSourcesChanged?.call();
        },
        onLogin: source.sourceId.startsWith('mihon:') ||
                source.sourceId.startsWith('venera:')
            ? (url) {
                final request = _browserRequestForSource(source, url);
                return networkBridge.openBrowser(
                  request.url,
                  userAgent: request.userAgent,
                );
              }
            : null,
        onReadLogin: source.sourceId.startsWith('venera:')
            ? (url) async {
                final snapshot =
                    await networkBridge.readBrowserSnapshot(url);
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
}

final class ComicSourcesPage extends StatefulWidget {
  const ComicSourcesPage({
    required this.sources,
    required this.activeSourceId,
    required this.onSourceSelected,
    required this.loadCover,
    required this.onOpenComic,
    this.onOpenSourceWebView,
    this.traceSink = const NoopTraceSink(),
    this.requestedQuery,
    this.queryRevision = 0,
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
  final Future<void> Function(
    BrowsableComicSource source,
    Uri url,
  )? onOpenSourceWebView;
  final TraceSink traceSink;
  final String? requestedQuery;
  final int queryRevision;

  @override
  State<ComicSourcesPage> createState() => _ComicSourcesPageState();
}

final class _ComicSourcesPageState extends State<ComicSourcesPage> {
  static const int _pageSize = 24;

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<SourceComicSummary> _items = const <SourceComicSummary>[];
  String _query = '';
  bool _loading = false;
  bool _hasMore = false;
  int _pageOffset = 0;
  int _nextOffset = 0;
  _ComicSourceCategory _sourceCategory = _ComicSourceCategory.all;
  _SourceFailure? _failure;
  int _generation = 0;
  bool _recoveringSourceAccess = false;
  final Stopwatch _traceClock = Stopwatch()..start();

  void _recordSourceTrace(
    TraceEventKind kind,
    String stage,
    BrowsableComicSource source, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-browser:${source.sourceId}',
        kind: kind,
        payload: <String, Object?>{
          'stage': stage,
          ...payload,
        },
      ),
    );
  }

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
    scheduleMicrotask(() => unawaited(_reload()));
  }

  @override
  void didUpdateWidget(covariant ComicSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queryRevision != widget.queryRevision) {
      _query = widget.requestedQuery?.trim() ?? '';
      _pageOffset = 0;
      _search.value = TextEditingValue(
        text: _query,
        selection: TextSelection.collapsed(offset: _query.length),
      );
      scheduleMicrotask(() => unawaited(_reload(offset: 0)));
      return;
    }
    if (oldWidget.activeSourceId != widget.activeSourceId ||
        !_sameSourceIds(oldWidget.sources, widget.sources)) {
      _query = '';
      _pageOffset = 0;
      _search.clear();
      final active = _activeSource;
      if (active != null &&
          !_comicSourceCategoryContains(_sourceCategory, active)) {
        _sourceCategory = _comicSourceCategoryOf(active);
      }
      if (!widget.sources.any(
        (source) => _comicSourceCategoryContains(_sourceCategory, source),
      )) {
        _sourceCategory = _ComicSourceCategory.all;
      }
      scheduleMicrotask(() => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload({
    bool forceRefresh = false,
    int? offset,
  }) async {
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
        _hasMore = false;
        _pageOffset = 0;
        _nextOffset = 0;
        _failure = null;
      });
      return;
    }
    final requestedOffset = (offset ?? _pageOffset).clamp(0, 1 << 30).toInt();
    final startedMicros = _traceClock.elapsedMicroseconds;
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'browse-start',
      source,
      payload: <String, Object?>{
        'forceRefresh': forceRefresh,
        'queryLength': _query.length,
        'offset': requestedOffset,
        'limit': _pageSize,
      },
    );
    if (forceRefresh) {
      invalidateCachedSearch(source);
    }
    setState(() {
      _loading = true;
      _failure = null;
      _items = const <SourceComicSummary>[];
      _hasMore = false;
      _pageOffset = requestedOffset;
      _nextOffset = requestedOffset;
    });
    try {
      final page = await source.browse(
        query: _query,
        offset: requestedOffset,
        limit: _pageSize,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _pageOffset = page.offset;
        _nextOffset = page.offset + page.items.length;
      });
      _recordSourceTrace(
        TraceEventKind.sourceReady,
        'browse-complete',
        source,
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'itemCount': page.items.length,
          'offset': page.offset,
          'hasMore': page.hasMore,
        },
      );
    } on Object catch (error, stackTrace) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _failure = _SourceFailure.capture(error, stackTrace);
      });
      _recordSourceTrace(
        TraceEventKind.taskFailed,
        'browse-failed',
        source,
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
        },
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _recoverSourceAccess(BrowsableComicSource source) async {
    final open = widget.onOpenSourceWebView;
    if (open == null || _recoveringSourceAccess) return;
    setState(() => _recoveringSourceAccess = true);
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'verification-recovery-start',
      source,
    );
    try {
      await open(source, source.descriptor.website);
      if (mounted) {
        await _reload(forceRefresh: true);
        _recordSourceTrace(
          TraceEventKind.sourceReady,
          'verification-recovery-complete',
          source,
        );
      }
    } on Object catch (error, stackTrace) {
      _recordSourceTrace(
        TraceEventKind.taskFailed,
        'verification-recovery-failed',
        source,
        payload: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
        },
      );
      if (mounted) {
        _showSourceFailureSnackBar(
          context,
          prefix: 'WebView 访问失败',
          failure: _SourceFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) setState(() => _recoveringSourceAccess = false);
    }
  }

  void _submitSearch(String value) {
    _query = value.trim();
    _pageOffset = 0;
    unawaited(_reload(offset: 0));
  }

  void _selectSourceCategory(_ComicSourceCategory category) {
    if (_sourceCategory == category) return;
    final visibleSources = widget.sources
        .where((source) => _comicSourceCategoryContains(category, source))
        .toList(growable: false);
    if (visibleSources.isEmpty) return;
    setState(() => _sourceCategory = category);
    final active = _activeSource;
    if (active == null ||
        !visibleSources.any((source) => source.sourceId == active.sourceId)) {
      widget.onSourceSelected(visibleSources.first.sourceId);
    }
  }

  Future<void> _goToPage(int offset) async {
    if (_loading || offset < 0) return;
    await _reload(offset: offset);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
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
        if (source != null &&
            !_loading &&
            _failure == null &&
            (_items.isNotEmpty || _pageOffset > 0))
          _SourcePager(
            page: (_pageOffset ~/ _pageSize) + 1,
            hasPrevious: _pageOffset > 0,
            hasNext: _hasMore,
            onPrevious: () => unawaited(
              _goToPage((_pageOffset - _pageSize).clamp(0, 1 << 30).toInt()),
            ),
            onNext: () => unawaited(_goToPage(_nextOffset)),
          ),
        _SourceSwitcher(
          sources: widget.sources,
          activeSourceId: widget.activeSourceId,
          selectedCategory: _sourceCategory,
          onCategorySelected: _selectSourceCategory,
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
        onOpenWebView: failure.requiresSourceVerification &&
                widget.onOpenSourceWebView != null
            ? () => unawaited(_recoverSourceAccess(source))
            : null,
        openingWebView: _recoveringSourceAccess,
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
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final comic = _items[index];
            return _SourceComicCard(
              key: sourceComicCardKey(source.sourceId, comic.comicId),
              source: source,
              comic: comic,
              reloadToken: _generation,
              loadCover: widget.loadCover,
              onSourceVerificationRequired:
                  widget.onOpenSourceWebView == null
                      ? null
                      : () => unawaited(_recoverSourceAccess(source)),
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

final class _SourcePager extends StatelessWidget {
  const _SourcePager({
    required this.page,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: comicSourcePagerKey,
      elevation: 1,
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            IconButton(
              key: comicSourcePreviousPageKey,
              tooltip: '上一页',
              onPressed: hasPrevious ? onPrevious : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '第 $page 页',
                key: comicSourcePageLabelKey,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              key: comicSourceNextPageKey,
              tooltip: '下一页',
              onPressed: hasNext ? onNext : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SourceSwitcher extends StatelessWidget {
  const _SourceSwitcher({
    required this.sources,
    required this.activeSourceId,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.onSelected,
  });

  final List<BrowsableComicSource> sources;
  final String? activeSourceId;
  final _ComicSourceCategory selectedCategory;
  final ValueChanged<_ComicSourceCategory> onCategorySelected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final categories = <_ComicSourceCategory>[
      _ComicSourceCategory.all,
      for (final category in _ComicSourceCategory.values.skip(1))
        if (sources.any(
          (source) => _comicSourceCategoryContains(category, source),
        ))
          category,
    ];
    final visibleSources = sources
        .where(
          (source) => _comicSourceCategoryContains(selectedCategory, source),
        )
        .toList(growable: false);
    return Material(
      key: comicSourceSwitcherKey,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: sources.isEmpty
            ? const SizedBox(
                height: 58,
                child: Center(child: Text('没有已启用的漫画源')),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    key: comicSourceCategoryBarKey,
                    height: 48,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                      scrollDirection: Axis.horizontal,
                      itemCount: categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        final count = category == _ComicSourceCategory.all
                            ? sources.length
                            : sources
                                .where(
                                  (source) => _comicSourceCategoryContains(
                                    category,
                                    source,
                                  ),
                                )
                                .length;
                        return ChoiceChip(
                          key: comicSourceCategoryKey(category.name),
                          avatar: Icon(
                            _comicSourceCategoryIcon(category),
                            size: 18,
                          ),
                          label: Text(
                            '${_comicSourceCategoryLabel(category)}（$count）',
                          ),
                          selected: category == selectedCategory,
                          showCheckmark: false,
                          onSelected: (_) => onCategorySelected(category),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 58,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      scrollDirection: Axis.horizontal,
                      itemCount: visibleSources.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final source = visibleSources[index];
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
                ],
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
    this.onSourceVerificationRequired,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary comic;
  final int reloadToken;
  final SourceComicCoverLoader loadCover;
  final VoidCallback onTap;
  final VoidCallback? onSourceVerificationRequired;

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
                loadSource: (uri) => loadCover(source, comic, uri),
                reloadToken: reloadToken,
                verificationKey:
                    sourceComicCoverVerificationKey(
                      source.sourceId,
                      comic.comicId,
                    ),
                onSourceVerificationRequired:
                    onSourceVerificationRequired,
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
    this.networkBridge = const AndroidNetworkBridge(),
    this.onExternalSourcesChanged,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final Map<String, ComicSourcePreference> preferences;
  final Future<void> Function(ComicSourcePreference preference)
      onPreferenceChanged;
  final ExternalPluginController? externalPlugins;
  final AndroidNetworkBridge networkBridge;
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
    await openComicSourceSettings(
      context,
      source: source,
      networkBridge: widget.networkBridge,
      externalPlugins: widget.externalPlugins,
      onExternalSourcesChanged: widget.onExternalSourcesChanged,
    );
    final controller = widget.externalPlugins;
    if (mounted && controller != null) {
      _refreshExternalSources(controller);
    }
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
              sourceSupportsSettings(source))
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
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.onSearchMetadata,
    this.onMigrateSource,
    this.onOpenVersions,
    this.sameComicIdentity,
    this.traceSink = const NoopTraceSink(),
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
  final details.ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final details.ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final details.ComicDetailsMetadataSearch? onSearchMetadata;
  final details.ComicDetailsVersionsOpener? onMigrateSource;
  final details.ComicDetailsVersionsOpener? onOpenVersions;
  final details.ComicDetailsIdentityMatcher? sameComicIdentity;
  final TraceSink traceSink;

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
      onOpenSourceWebView: onOpenSourceWebView,
      onOpenSourceSettings: onOpenSourceSettings,
      onSearchMetadata: onSearchMetadata,
      onMigrateSource: onMigrateSource,
      onOpenVersions: onOpenVersions,
      sameComicIdentity: sameComicIdentity ?? (left, right) => left == right,
      traceSink: traceSink,
    );
  }
}

final class _SourceFailure {
  const _SourceFailure({
    required this.summary,
    required this.guidance,
    required this.details,
    this.requiresSourceVerification = false,
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

    if (error is Failure &&
        error.code == ErrorCode.sourceVerificationRequired) {
      return _SourceFailure(
        summary: '漫画源需要完成网页验证',
        guidance: '请打开 WebView 完成 Cloudflare 或站点验证；返回后会自动重新加载当前列表。',
        details: details,
        requiresSourceVerification: true,
      );
    }
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
  final bool requiresSourceVerification;
}

final class _SourceFailurePanel extends StatelessWidget {
  const _SourceFailurePanel({
    required this.title,
    required this.failure,
    required this.onRetry,
    this.onOpenWebView,
    this.openingWebView = false,
    super.key,
  });

  final String title;
  final _SourceFailure failure;
  final VoidCallback onRetry;
  final VoidCallback? onOpenWebView;
  final bool openingWebView;

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
                      if (onOpenWebView != null)
                        FilledButton.icon(
                          key: comicSourceOpenWebViewKey,
                          onPressed: openingWebView ? null : onOpenWebView,
                          icon: openingWebView
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.public),
                          label: const Text('WebView 验证'),
                        ),
                      OutlinedButton.icon(
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
  String? actionLabel,
  VoidCallback? onAction,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$prefix：${failure.summary}'),
      action: SnackBarAction(
        label: actionLabel ?? '复制',
        onPressed: onAction ?? () {
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
    required this.loadSource,
    required this.reloadToken,
    required this.verificationKey,
    this.onSourceVerificationRequired,
  });

  final Uri? uri;
  final Future<EncodedResourceSource> Function(Uri uri) loadSource;
  final int reloadToken;
  final Key verificationKey;
  final VoidCallback? onSourceVerificationRequired;

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

final class _RemoteImageState extends State<_RemoteImage> {
  Future<EncodedResourceSource>? _source;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        (oldWidget.reloadToken != widget.reloadToken && _failed)) {
      _load();
    }
  }

  void _load() {
    final uri = widget.uri;
    _failed = false;
    _source = uri == null
        ? null
        : widget.loadSource(uri).catchError((Object error, StackTrace stack) {
            _failed = true;
            Error.throwWithStackTrace(error, stack);
          });
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source == null) {
      return SoftArtworkPlaceholder(
        seed: widget.uri?.toString() ?? 'source-comic-cover',
      );
    }
    return FutureBuilder<EncodedResourceSource>(
      future: source,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return Image(
            image: encodedResourceImageProvider(data),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => SoftArtworkPlaceholder(
              seed: widget.uri?.toString() ?? 'source-comic-cover',
            ),
          );
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          final canVerify = error is Failure &&
              error.code == ErrorCode.sourceVerificationRequired &&
              widget.onSourceVerificationRequired != null;
          return canVerify
              ? ColoredBox(
                  color: const Color(0x11000000),
                  child: Center(
                    child: IconButton(
                      key: widget.verificationKey,
                      tooltip: '在 WebView 中完成来源验证',
                      onPressed: widget.onSourceVerificationRequired,
                      icon: const Icon(Icons.public),
                    ),
                  ),
                )
              : SoftArtworkPlaceholder(
                  seed: widget.uri?.toString() ?? 'source-comic-cover',
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
