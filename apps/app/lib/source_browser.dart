import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';

import 'package:downloads/downloads.dart';
import 'app_preferences.dart';
import 'app_pull_to_refresh.dart';
import 'artwork_placeholder.dart';
import 'comic_details.dart' as details;
import 'diagnostic_error_ui.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'external_plugin_repository_model.dart';
import 'external_plugin_repository_screen.dart';
import 'external_source_settings_screen.dart';
import 'source_settings_screen.dart';
import 'startup_platform.dart';

part 'comic_title_search.dart';

const comicSourcesPageKey = ValueKey<String>('comic-sources-page');
const comicSourceManageKey = ValueKey<String>('comic-source-manage');
const sourceManagementScreenKey =
    ValueKey<String>('source-management-screen');
const comicSourceSearchKey = ValueKey<String>('comic-source-search');
const comicSourceSearchLockKey =
    ValueKey<String>('comic-source-search-lock');
const comicSourceSearchFabKey = ValueKey<String>('comic-source-search-fab');
const comicSourceSearchHistoryKey =
    ValueKey<String>('comic-source-search-history');
const comicSourceSearchExpandKey =
    ValueKey<String>('comic-source-search-expand');
const comicSourceAggregateSearchKey =
    ValueKey<String>('comic-source-aggregate-search');
const comicSourceAggregateResultsKey =
    ValueKey<String>('comic-source-aggregate-results');
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
const comicSourcePullRefreshKey =
    ValueKey<String>('comic-source-pull-refresh');
const comicSourceRefreshStateKey =
    ValueKey<String>('comic-source-refresh-state');
const comicSourceFilterBarKey =
    ValueKey<String>('comic-source-filter-bar');
const comicSourceFilterActionKey =
    ValueKey<String>('comic-source-filter-action');
const comicSourceFilterSheetKey =
    ValueKey<String>('comic-source-filter-sheet');
const comicSourcePreviousPageKey =
    ValueKey<String>('comic-source-previous-page');
const comicSourceNextPageKey = ValueKey<String>('comic-source-next-page');
const comicSourcePageLabelKey = ValueKey<String>('comic-source-page-label');
Key comicSourceCategoryKey(String category) =>
    ValueKey<String>('comic-source-category:$category');
Key comicSourceFilterKey(String filterId) =>
    ValueKey<String>('comic-source-filter:$filterId');
Key comicSourceChoiceKey(String sourceId) =>
    ValueKey<String>('comic-source-choice:$sourceId');
Key comicSourcePluginChoiceKey(String pluginId) =>
    ValueKey<String>('comic-source-plugin-choice:$pluginId');
Key sourceSettingsEntryKey(String sourceId) =>
    ValueKey<String>('source-settings:$sourceId');
Key sourcePropertiesEntryKey(String sourceId) =>
    ValueKey<String>('source-properties:$sourceId');
Key comicSourceAggregatePluginKey(String pluginId) =>
    ValueKey<String>('comic-source-aggregate-plugin:$pluginId');
Key comicSourceAggregateCategoryKey(String categoryId) =>
    ValueKey<String>('comic-source-aggregate-category:$categoryId');
/// The source's canonical identity keeps the card's presentation subtree live.
Key sourceComicCardKey(String sourceId, String canonicalComicId) =>
    ValueKey<String>('source-comic:$sourceId\u0000$canonicalComicId');
Key sourceComicCoverVerificationKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-verify:$sourceId\u0000$comicId');
Key sourceComicShelfMarkerKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-shelf:$sourceId\u0000$comicId');
Key sourceComicShelfDimKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-shelf-dim:$sourceId\u0000$comicId');
Key sourceComicUpdateMarkerKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-update:$sourceId\u0000$comicId');
Key sourceChapterKey(String sourceId, String chapterId) =>
    details.comicDetailsChapterKey(sourceId, chapterId);

typedef SourceComicCoverLoader = Future<EncodedResourceSource> Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
  Uri uri, {
  bool forceRefresh,
});

typedef SourceComicShelfResolver = bool Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
);

typedef SourceComicUpdateResolver = bool Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
);

typedef SourceComicUpdateOpener = Future<void> Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
);

String _stableSourceComicIdentity(
  BrowsableComicSource source,
  String comicId,
) {
  final Object candidate = source;
  if (candidate is CanonicalComicIdentitySource) {
    return candidate.canonicalComicIdentity(comicId);
  }
  return comicId;
}

SourceBrowsePage _canonicalSourceBrowsePage(
  BrowsableComicSource source,
  SourceBrowsePage page,
) {
  final seen = <String>{};
  final items = <SourceComicSummary>[];
  for (final comic in page.items) {
    if (seen.add(_stableSourceComicIdentity(source, comic.comicId))) {
      items.add(comic);
    }
  }
  if (items.length == page.items.length) return page;
  return SourceBrowsePage(
    items: items,
    offset: page.offset,
    hasMore: page.hasMore,
    // Paging belongs to the original source page, before card projection.
    nextOffset: page.hasMore
        ? (page.nextOffset ?? page.offset + page.items.length)
        : null,
  );
}

Color _comicSourceAccent(BrowsableComicSource source) {
  if (source.sourceId.startsWith('venera:')) {
    return Colors.blue;
  }
  if (source.sourceId.startsWith('mihon:')) {
    return Colors.green;
  }
  return Colors.orange;
}

ExternalComicPluginFormat? _comicSourcePluginFormat(String sourceId) {
  if (sourceId.startsWith('mihon:')) {
    return ExternalComicPluginFormat.mihonExtension;
  }
  if (sourceId.startsWith('venera:')) {
    return ExternalComicPluginFormat.veneraJavaScript;
  }
  return null;
}

Widget? _comicSourcePluginIcon(ExternalComicPluginFormat? format) =>
    switch (format) {
      ExternalComicPluginFormat.mihonExtension =>
        const Icon(Icons.extension_outlined, size: 18, semanticLabel: 'Mihon'),
      ExternalComicPluginFormat.veneraJavaScript =>
        const Icon(Icons.javascript, size: 18, semanticLabel: 'Venera'),
      null => null,
    };

/// Shared source presentation; callers retain selection and activation policy.
final class _ComicSourceChip extends StatelessWidget {
  const _ComicSourceChip({
    required this.label,
    required this.accent,
    required this.selected,
    required this.onSelected,
    this.format,
    this.chipKey,
    this.multiple = false,
  });

  final String label;
  final Color accent;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final ExternalComicPluginFormat? format;
  final Key? chipKey;
  final bool multiple;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final avatar = selected ? _comicSourcePluginIcon(format) : null;
    final side = BorderSide(color: accent.withValues(alpha: .7));
    final labelStyle = TextStyle(color: selected
        ? Theme.of(context).colorScheme.onPrimary : accent);
    if (multiple) {
      return FilterChip(
        key: chipKey,
        label: text,
        avatar: avatar,
        selected: selected,
        showCheckmark: false,
        selectedColor: accent,
        side: side,
        labelStyle: labelStyle,
        onSelected: onSelected,
      );
    }
    return ChoiceChip(
      key: chipKey,
      label: text,
      avatar: avatar,
      selected: selected,
      showCheckmark: false,
      selectedColor: accent,
      side: side,
      labelStyle: labelStyle,
      onSelected: onSelected,
    );
  }
}

final class _ComicSourceBar extends StatelessWidget {
  const _ComicSourceBar({required this.chips, this.barKey});

  final List<Widget> chips;
  final Key? barKey;

  @override
  Widget build(BuildContext context) => Material(
    key: barKey,
    elevation: 3,
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 58,
        child: chips.isEmpty
            ? const Center(child: Text('没有已启用的漫画源'))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) => chips[index],
              ),
      ),
    ),
  );
}


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
  Future<void> Function()? onExternalSourcesChanged,
}) async {
  if (!sourceSupportsSettings(source)) {
    return;
  }
  await attachAndroidPlugin('network_bridge');
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ExternalSourceSettingsScreen(
        source: source,
        onApply: () async {
          // updateSetting() already mutated the active runtime. Restarting the
          // whole plugin here creates a second session and can drop otherwise
          // healthy Venera/Mihon sources on a transient activation failure.
          // Refresh projections only; payload install/update remains the
          // lifecycle owner's responsibility.
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
    this.isInShelf,
    this.hasUpdate,
    this.onOpenUpdate,
    this.onOpenSourceWebView,
    this.resolveSource,
    this.externalPlugins,
    this.onExternalPluginRetry,
    this.traceSink = const NoopTraceSink(),
    this.requestedQuery,
    this.queryRevision = 0,
    this.searchHistory = const <String>[],
    this.onSearchCommitted,
    this.onSearchRemoved,
    this.onSearchHistoryCleared,
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
  final SourceComicShelfResolver? isInShelf;
  final SourceComicUpdateResolver? hasUpdate;
  final SourceComicUpdateOpener? onOpenUpdate;
  final Future<void> Function(
    BrowsableComicSource source,
    Uri url, {
    required bool cloudflareVerification,
  })? onOpenSourceWebView;
  final BrowsableComicSource? Function(String sourceId)? resolveSource;
  final ExternalPluginController? externalPlugins;
  final Future<void> Function(InstalledExternalPlugin plugin)?
      onExternalPluginRetry;
  final TraceSink traceSink;
  final String? requestedQuery;
  final int queryRevision;
  final List<String> searchHistory;
  final ValueChanged<String>? onSearchCommitted;
  final ValueChanged<String>? onSearchRemoved;
  final VoidCallback? onSearchHistoryCleared;

  @override
  State<ComicSourcesPage> createState() => _ComicSourcesPageState();
}

final class _SourceBrowseViewState {
  const _SourceBrowseViewState({
    required this.sectionId,
    required this.query,
    required this.offset,
    required this.pageOffsets,
    required this.filterState,
    required this.filterViewActive,
  });

  final String? sectionId;
  final String query;
  final int offset;
  final List<int> pageOffsets;
  final SourceSearchFilterState filterState;
  final bool filterViewActive;
}

final class _AggregateSearchPlugin {
  const _AggregateSearchPlugin({
    required this.pluginId,
    required this.label,
    required this.accent,
    required this.source,
  });

  final String pluginId;
  final String label;
  final Color accent;
  final BrowsableComicSource source;
}

final class _AggregateSearchResult {
  const _AggregateSearchResult({required this.source, required this.comic});

  final BrowsableComicSource source;
  final SourceComicSummary comic;
}

final class _AggregateSearchOptions extends ChangeNotifier {
  bool expanded = false;
  bool enabled = false;
  Set<String> pluginIds = <String>{};
  Set<String> categoryIds = <String>{};

  void setExpanded(bool value, Iterable<String> availablePluginIds) {
    if (value) {
      final available = availablePluginIds.toSet();
      pluginIds = pluginIds.intersection(available);
      if (pluginIds.isEmpty) pluginIds = available;
    }
    if (expanded == value) return;
    expanded = value;
    notifyListeners();
  }

  void setEnabled(bool value, Iterable<String> availablePluginIds) {
    if (value && pluginIds.isEmpty) {
      pluginIds = availablePluginIds.toSet();
    }
    if (enabled == value) return;
    enabled = value;
    notifyListeners();
  }

  void togglePlugin(String pluginId, bool selected) {
    final next = Set<String>.of(pluginIds);
    selected ? next.add(pluginId) : next.remove(pluginId);
    pluginIds = next;
    notifyListeners();
  }

  void toggleCategory(String categoryId, bool selected) {
    final next = Set<String>.of(categoryIds);
    selected ? next.add(categoryId) : next.remove(categoryId);
    categoryIds = next;
    notifyListeners();
  }
}

final class _ComicSourcesPageState extends State<ComicSourcesPage> {
  static const int _pageSize = 24;

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Map<String, _SourceBrowseViewState> _sourceViewStates =
      <String, _SourceBrowseViewState>{};
  List<SourceComicSummary> _items = const <SourceComicSummary>[];
  String? _projectionSourceId;
  String _query = '';
  bool _loading = false;
  bool _hasMore = false;
  int _pageOffset = 0;
  int _nextOffset = 0;
  final List<int> _browsePageOffsets = <int>[0];
  List<SourceBrowseSection> _sections = const <SourceBrowseSection>[];
  String? _selectedSectionId;
  List<SourceSearchFilterNode> _searchFilters =
      const <SourceSearchFilterNode>[];
  SourceSearchFilterState _filterState = const <String, Object?>{};
  bool _filterViewActive = false;
  final ValueNotifier<bool> _searchExpanded = ValueNotifier<bool>(false);
  bool _searchQueryLocked = false;
  final _AggregateSearchOptions _aggregateSearch = _AggregateSearchOptions();
  List<_AggregateSearchResult> _aggregateItems =
      const <_AggregateSearchResult>[];
  List<_AggregateSearchResult> _lastAggregateItems =
      const <_AggregateSearchResult>[];
  String _aggregateQuery = '';
  String _lastAggregateQuery = '';
  String _lastSearchQuery = '';
  bool _aggregateViewActive = false;
  bool _aggregateLoading = false;
  Object? _aggregateFailure;
  bool _refreshing = false;
  _SourceFailure? _failure;
  int _generation = 0;
  int _artworkRetryRevision = 0;
  final Map<String, Future<EncodedResourceSource>> _cardCoverFutures =
      <String, Future<EncodedResourceSource>>{};
  final Map<String, Future<EncodedResourceSource>> _cardCoverSourceFailures =
      <String, Future<EncodedResourceSource>>{};
  final Map<String, Future<EncodedResourceSource>> _cardCoverDecodeFailures =
      <String, Future<EncodedResourceSource>>{};
  final Set<String> _cardCoverRefreshIntents = <String>{};
  bool _recoveringSourceAccess = false;
  final Set<String> _verificationBrowserAttempts = <String>{};
  final MonoClock _traceClock = const SystemClock();

  void _recordSourceTrace(
    TraceEventKind kind,
    String stage,
    BrowsableComicSource source, {
    String? identityHash,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceClock.nowMicros(),
        sessionId: 'source-browser:${source.sourceId}',
        kind: kind,
        identityHash: identityHash,
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
    final resolved = widget.resolveSource?.call(id);
    if (resolved != null) {
      return resolved;
    }
    return _sourceForId(widget.sources, id);
  }

  String? get _requestSectionId =>
      _filterViewActive ? null : _selectedSectionId;

  String _verificationAttemptKey(
    BrowsableComicSource source,
    Uri? verificationUri,
  ) =>
      '${source.sourceId}\u0000${(verificationUri ?? source.descriptor.website).toString()}';

  void _clearVerificationBrowserAttempts(String sourceId) {
    _verificationBrowserAttempts.removeWhere(
      (key) => key.startsWith('$sourceId\u0000'),
    );
  }

  void _rememberSourceView(String? sourceId) {
    if (sourceId == null) return;
    _sourceViewStates[sourceId] = _SourceBrowseViewState(
      sectionId: _selectedSectionId,
      query: _query,
      offset: _pageOffset,
      pageOffsets: List<int>.unmodifiable(_browsePageOffsets),
      filterState: Map<String, Object?>.unmodifiable(_filterState),
      filterViewActive: _filterViewActive,
    );
  }

  void _restoreTargetProjection(BrowsableComicSource? source) {
    if (source == null) {
      setState(() {
        _projectionSourceId = null;
        _pageOffset = 0;
        _nextOffset = 0;
        _resetBrowseCoordinates();
        _items = const <SourceComicSummary>[];
        _loading = false;
        _refreshing = false;
        _failure = null;
      });
      return;
    }
    final remembered = _sourceViewStates[source.sourceId];
    _query = remembered?.query ?? '';
    _pageOffset = remembered?.offset ?? 0;
    _browsePageOffsets
      ..clear()
      ..addAll(remembered?.pageOffsets ?? const <int>[0]);
    _selectedSectionId = remembered?.sectionId;
    _filterState = remembered?.filterState ?? const <String, Object?>{};
    _filterViewActive = remembered?.filterViewActive ?? false;
    _search.value = TextEditingValue(
      text: _query,
      selection: TextSelection.collapsed(offset: _query.length),
    );
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    final rawCached = cache?.peekBrowsePage(
      sectionId: _requestSectionId,
      query: _query,
      offset: _pageOffset,
      limit: _pageSize,
      filterState: _filterState,
      useFilters: _filterViewActive,
    );
    final cached = rawCached == null
        ? null
        : _canonicalSourceBrowsePage(source, rawCached);
    setState(() {
      _projectionSourceId = source.sourceId;
      _failure = null;
      _refreshing = cached != null;
      _loading = cached == null;
      if (cached == null) {
        _items = const <SourceComicSummary>[];
        _hasMore = false;
        _nextOffset = _pageOffset;
      } else {
        _applyBrowsePage(cached, sourceId: source.sourceId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _query = widget.requestedQuery?.trim() ?? '';
    _search.value = TextEditingValue(
      text: _query,
      selection: TextSelection.collapsed(offset: _query.length),
    );
    scheduleMicrotask(() => unawaited(_loadSource()));
  }

  @override
  void didUpdateWidget(covariant ComicSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queryRevision != widget.queryRevision) {
      _exitAggregateSearchView(rebuild: false);
      _aggregateSearch.setEnabled(
        false,
        _aggregateSearchPlugins().map((plugin) => plugin.pluginId),
      );
      _query = widget.requestedQuery?.trim() ?? '';
      _pageOffset = 0;
      _resetBrowseCoordinates();
      _search.value = TextEditingValue(
        text: _query,
        selection: TextSelection.collapsed(offset: _query.length),
      );
      scheduleMicrotask(() => unawaited(_reload(offset: 0)));
      return;
    }
    final activeSourceReplaced = widget.activeSourceId != null &&
        !identical(
          _sourceForId(oldWidget.sources, widget.activeSourceId!),
          _sourceForId(widget.sources, widget.activeSourceId!),
        );
    final sourceIdsChanged = !_sameSourceIds(oldWidget.sources, widget.sources);
    final aggregateSourceSetChanged = sourceIdsChanged &&
        (_aggregateViewActive || _aggregateLoading || _aggregateSearch.enabled);
    if (sourceIdsChanged) {
      _lastAggregateItems = const <_AggregateSearchResult>[];
      _lastAggregateQuery = '';
      _lastSearchQuery = '';
    }
    if (oldWidget.activeSourceId != widget.activeSourceId ||
        activeSourceReplaced || aggregateSourceSetChanged) {
      _exitAggregateSearchView(rebuild: false);
      _aggregateSearch.setEnabled(
        false,
        _aggregateSearchPlugins().map((plugin) => plugin.pluginId),
      );
      _rememberSourceView(oldWidget.activeSourceId);
      _sections = const <SourceBrowseSection>[];
      _searchFilters = const <SourceSearchFilterNode>[];
      _restoreTargetProjection(_activeSource);
      if (!_recoveringSourceAccess) {
        scheduleMicrotask(() => unawaited(_loadSource(browseOffset: _pageOffset)));
      }
    }
  }

  @override
  void dispose() {
    _cardCoverFutures.clear();
    _cardCoverSourceFailures.clear();
    _cardCoverDecodeFailures.clear();
    _cardCoverRefreshIntents.clear();
    _scroll.dispose();
    _searchExpanded.dispose();
    _aggregateSearch.dispose();
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<bool> _loadSource({
    bool forceRefresh = false,
    bool allowVerificationFallback = true,
    int browseOffset = 0,
  }) async {
    final source = _activeSource;
    if (source == null) {
      return _reload(
        forceRefresh: forceRefresh,
        allowVerificationFallback: allowVerificationFallback,
      );
    }
    final generation = ++_generation;
    var sections = const <SourceBrowseSection>[];
    var filters = const <SourceSearchFilterNode>[];
    final sectioned = source is SectionedBrowsableComicSource
        ? source as SectionedBrowsableComicSource
        : null;
    final filterable = source is FilterableBrowsableComicSource
        ? source as FilterableBrowsableComicSource
        : null;
    if (sectioned != null) {
      try {
        sections = await sectioned.loadBrowseSections();
      } on Object catch (error) {
        _recordSourceTrace(
          TraceEventKind.taskFailed,
          'browse-sections-failed',
          source,
          payload: <String, Object?>{
            'errorType': error.runtimeType.toString(),
            if (error is Failure) 'errorCode': error.code.name,
          },
        );
      }
    }
    if (filterable != null) {
      try {
        filters = await filterable.loadSearchFilters();
      } on Object catch (error) {
        // Filter discovery is optional to ordinary browse. A broken custom
        // filter schema must not make Popular/Latest unusable.
        _recordSourceTrace(
          TraceEventKind.taskFailed,
          'search-filters-failed',
          source,
          payload: <String, Object?>{
            'errorType': error.runtimeType.toString(),
            if (error is Failure) 'errorCode': error.code.name,
          },
        );
      }
    }
    if (!mounted || generation != _generation) return false;
    final orderedSections = _orderedBrowseSections(sections);
    final selected = sections.any(
      (section) => section.sectionId == _selectedSectionId,
    )
        ? _selectedSectionId
        : (orderedSections.isEmpty ? null : orderedSections.first.sectionId);
    final availableFilterIds = _searchFilterNodesById(filters).keys.toSet();
    final retainedFilterState = <String, Object?>{
      for (final entry in _filterState.entries)
        if (availableFilterIds.contains(entry.key)) entry.key: entry.value,
    };
    final requestChanged = selected != _selectedSectionId ||
        !_filterStateEquals(retainedFilterState, _filterState) ||
        (_filterViewActive && filters.isEmpty);
    setState(() {
      _sections = sections;
      _selectedSectionId = selected;
      _searchFilters = filters;
      _filterState = Map<String, Object?>.unmodifiable(retainedFilterState);
      if (filters.isEmpty) _filterViewActive = false;
      if (requestChanged) {
        _pageOffset = 0;
        _resetBrowseCoordinates();
        // The restored page belongs to the request before schema discovery.
        // _reload may retain content only while that request stays unchanged.
        _items = const <SourceComicSummary>[];
        _hasMore = false;
        _nextOffset = 0;
      }
    });
    return _reload(
      forceRefresh: forceRefresh,
      allowVerificationFallback: allowVerificationFallback,
      offset: requestChanged ? 0 : browseOffset,
    );
  }

  Future<SourceBrowsePage> _loadBrowsePage(
    BrowsableComicSource source, {
    required int offset,
    required bool forceRefresh,
  }) {
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    if (cache != null && forceRefresh) {
      return cache.refreshBrowsePage(
        sectionId: _requestSectionId,
        query: _query,
        offset: offset,
        limit: _pageSize,
        filterState: _filterState,
        useFilters: _filterViewActive,
      );
    }
    final filterable = source is FilterableBrowsableComicSource
        ? source as FilterableBrowsableComicSource
        : null;
    if (filterable != null && _filterViewActive) {
      return filterable.browseWithFilters(
        sectionId: _requestSectionId,
        query: _query,
        offset: offset,
        limit: _pageSize,
        filterState: _filterState,
      );
    }
    final sectioned = source is SectionedBrowsableComicSource
        ? source as SectionedBrowsableComicSource
        : null;
    if (_selectedSectionId != null && sectioned != null) {
      return sectioned.browseSection(
        _selectedSectionId!,
        query: _query,
        offset: offset,
        limit: _pageSize,
      );
    }
    return source.browse(
      query: _query,
      offset: offset,
      limit: _pageSize,
    );
  }

  void _applyBrowsePage(
    SourceBrowsePage page, {
    String? sourceId,
  }) {
    final visited = _browsePageOffsets.lastIndexOf(page.offset);
    if (page.offset == 0) {
      _resetBrowseCoordinates();
    } else if (visited >= 0) {
      _browsePageOffsets.removeRange(visited + 1, _browsePageOffsets.length);
    } else {
      _browsePageOffsets.add(page.offset);
    }
    _projectionSourceId = sourceId ?? _activeSource?.sourceId;
    _items = page.items;
    _hasMore = page.hasMore;
    _pageOffset = page.offset;
    _nextOffset = page.nextOffset ?? page.offset + page.items.length;
  }

  void _resetBrowseCoordinates() {
    _browsePageOffsets
      ..clear()
      ..add(0);
  }

  int get _previousBrowseOffset {
    final index = _browsePageOffsets.lastIndexOf(_pageOffset);
    if (index > 0) return _browsePageOffsets[index - 1];
    if (index < 0) return _browsePageOffsets.last;
    return 0;
  }

  int get _browsePageNumber {
    final index = _browsePageOffsets.lastIndexOf(_pageOffset);
    return index < 0 ? _browsePageOffsets.length + 1 : index + 1;
  }

  Future<bool> _reload({
    bool forceRefresh = false,
    bool allowVerificationFallback = true,
    int? offset,
  }) async {
    if (!mounted) return false;
    final source = _activeSource;
    final generation = ++_generation;
    if (source == null) {
      setState(() {
        _projectionSourceId = null;
        _items = const <SourceComicSummary>[];
        _loading = false;
        _refreshing = false;
        _hasMore = false;
        _pageOffset = 0;
        _resetBrowseCoordinates();
        _nextOffset = 0;
        _failure = null;
      });
      return false;
    }
    final requestedOffset = (offset ?? _pageOffset).clamp(0, 1 << 30).toInt();
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    final cachedPage = forceRefresh
        ? null
        : cache?.peekBrowsePage(
            sectionId: _requestSectionId,
            query: _query,
            offset: requestedOffset,
            limit: _pageSize,
            filterState: _filterState,
            useFilters: _filterViewActive,
          );
    final cached = cachedPage == null
        ? null
        : _canonicalSourceBrowsePage(source, cachedPage);
    final hasCached = cached != null;
    final projectionMatchesSource = _projectionSourceId == source.sourceId;
    final hasVisibleItems = projectionMatchesSource && _items.isNotEmpty;
    final cachedChanged = cached != null &&
        (!projectionMatchesSource ||
            !_sameBrowsePage(_items, _pageOffset, _hasMore, _nextOffset, cached));
    final startedMicros = _traceClock.nowMicros();
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'browse-start',
      source,
      payload: <String, Object?>{
        'forceRefresh': forceRefresh,
        'cacheHit': hasCached,
        'cacheChanged': cachedChanged,
        'queryLength': _query.length,
        'sectionId': _requestSectionId,
        'offset': requestedOffset,
        'limit': _pageSize,
        'filterCount': _filterState.length,
        'filterViewActive': _filterViewActive,
      },
    );
    if (forceRefresh) {
      invalidateCachedSearch(source);
    }
    setState(() {
      _failure = null;
      if (forceRefresh) _artworkRetryRevision++;
      if (forceRefresh) _retireSourceCardCovers(source.sourceId);
      _loading = !hasCached && !hasVisibleItems;
      _refreshing = hasCached || hasVisibleItems;
      if (cached != null && cachedChanged) {
        _applyBrowsePage(cached, sourceId: source.sourceId);
      } else if (!hasVisibleItems) {
        _projectionSourceId = source.sourceId;
        _items = const <SourceComicSummary>[];
        _hasMore = false;
        _pageOffset = requestedOffset;
        _nextOffset = requestedOffset;
      }
    });
    var succeeded = false;
    try {
      final rawPage = cache != null
          ? await cache.refreshBrowsePage(
              sectionId: _requestSectionId,
              query: _query,
              offset: requestedOffset,
              limit: _pageSize,
              filterState: _filterState,
              useFilters: _filterViewActive,
            )
          : await _loadBrowsePage(
              source,
              offset: requestedOffset,
              forceRefresh: forceRefresh,
            );
      if (!mounted || generation != _generation) return false;
      final page = _canonicalSourceBrowsePage(source, rawPage);
      final changed = !_sameBrowsePage(
        _items,
        _pageOffset,
        _hasMore,
        _nextOffset,
        page,
      );
      setState(() {
        if (changed) {
          _applyBrowsePage(page, sourceId: source.sourceId);
        }
        _failure = null;
      });
      succeeded = true;
      _clearVerificationBrowserAttempts(source.sourceId);
      _recordSourceTrace(
        TraceEventKind.sourceReady,
        'browse-complete',
        source,
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
          'itemCount': rawPage.items.length,
          'projectedItemCount': page.items.length,
          'offset': page.offset,
          'hasMore': page.hasMore,
          'changed': changed,
          'backgroundRefresh': hasCached,
        },
      );
    } on Object catch (error, stackTrace) {
      if (!mounted || generation != _generation) return false;
      final failure = _SourceFailure.capture(error, stackTrace);
      setState(() => _failure = failure);
      _recordSourceTrace(
        TraceEventKind.taskFailed,
        'browse-failed',
        source,
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
          'cacheRetained': hasCached,
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
        },
      );
      final automaticVerificationKey = _verificationAttemptKey(
        source,
        failure.verificationUri,
      );
      if (forceRefresh &&
          allowVerificationFallback &&
          failure.shouldAutoOpenVerification &&
          widget.onOpenSourceWebView != null &&
          !_recoveringSourceAccess &&
          _verificationBrowserAttempts.add(automaticVerificationKey)) {
        scheduleMicrotask(
          () => unawaited(
            _recoverSourceAccess(
              source,
              verificationUri: failure.verificationUri,
              automatic: true,
            ),
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
    return succeeded;
  }

  Future<void> _recoverSourceAccess(
    BrowsableComicSource source, {
    Uri? verificationUri,
    bool automatic = false,
  }) async {
    final open = widget.onOpenSourceWebView;
    if (open == null || _recoveringSourceAccess) return;
    // Any browser handoff consumes the automatic fallback allowance for this
    // source/request URL. A manual verification followed by another failed
    // runtime request must not cause the next refresh to auto-open WebView.
    _verificationBrowserAttempts.add(
      _verificationAttemptKey(source, verificationUri),
    );
    setState(() => _recoveringSourceAccess = true);
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'verification-recovery-start',
      source,
      payload: <String, Object?>{'automatic': automatic},
    );
    try {
      await open(
        source,
        verificationUri ?? source.descriptor.website,
        cloudflareVerification: true,
      );
      if (!mounted) return;
      final replacement = _activeSource;
      if (replacement == null || replacement.sourceId != source.sourceId) {
        throw StateError(
          'source verification completed without an active replacement source',
        );
      }
      _recordSourceTrace(
        TraceEventKind.sourceReady,
        'verification-runtime-replaced',
        replacement,
        payload: <String, Object?>{
          'adapterReplaced': !identical(replacement, source),
        },
      );
      final recovered = await _loadSource(
        forceRefresh: true,
        allowVerificationFallback: false,
        browseOffset: _pageOffset,
      );
      if (recovered) {
        _recordSourceTrace(
          TraceEventKind.sourceReady,
          'verification-recovery-complete',
          replacement,
        );
      } else if (automatic) {
        _recordSourceTrace(
          TraceEventKind.taskFailed,
          'verification-auto-loop-guarded',
          replacement,
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


  String _sourceCoverIdentity(
    BrowsableComicSource source,
    SourceComicSummary comic,
  ) =>
      'source-cover:${source.sourceId}\u0000${_stableSourceComicIdentity(source, comic.comicId)}';

  Future<EncodedResourceSource> _loadSourceCardCover(
    BrowsableComicSource source,
    SourceComicSummary comic,
    Uri uri,
  ) {
    final identity = _sourceCoverIdentity(source, comic);
    final existing = _cardCoverFutures[identity];
    if (existing != null) return existing;
    late final Future<EncodedResourceSource> future;
    future = _loadSourceCardCoverUncached(source, comic, uri, identity,
      forceRefresh: _cardCoverRefreshIntents.remove(identity)).catchError(
        (Object error, StackTrace stackTrace) {
          if (mounted && identical(_cardCoverFutures[identity], future)) {
            _cardCoverSourceFailures[identity] = future;
          }
          Error.throwWithStackTrace(error, stackTrace);
        },
      );
    _cardCoverFutures[identity] = future;
    return future;
  }

  Future<EncodedResourceSource> _loadSourceCardCoverUncached(
    BrowsableComicSource source,
    SourceComicSummary comic,
    Uri uri,
    String identity, {
    required bool forceRefresh,
  }) async {
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'cover-load-start',
      source,
      identityHash: identity,
      payload: <String, Object?>{
        'uriHash': uri.toString().hashCode,
        'forceRefresh': forceRefresh,
      },
    );
    try {
      final encoded = await widget.loadCover(source, comic, uri,
        forceRefresh: forceRefresh);
      _recordSourceTrace(
        TraceEventKind.sourceReady,
        'cover-source-ready',
        source,
        identityHash: identity,
        payload: <String, Object?>{
          'source': encoded.origin.name,
          if (encoded.lengthInBytes != null)
            'byteLength': encoded.lengthInBytes,
        },
      );
      return encoded;
    } on Object catch (error) {
      _recordSourceTrace(
        TraceEventKind.taskFailed,
        'cover-source-failed',
        source,
        identityHash: identity,
        payload: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
          if (error is Failure) 'errorMessage': error.message,
        },
      );
      rethrow;
    }
  }

  void _retireSourceCardCovers(String sourceId) {
    final prefix = 'source-cover:$sourceId\u0000';
    final identities = _cardCoverFutures.keys
        .where((identity) => identity.startsWith(prefix)).toList();
    for (final identity in identities) {
      final future = _cardCoverFutures[identity];
      final decodeFailed = identical(_cardCoverDecodeFailures[identity], future);
      if (!decodeFailed && !identical(_cardCoverSourceFailures[identity], future)) {
        continue;
      }
      // Catalog refresh retries observed failures, not healthy or pending artwork.
      if (decodeFailed) {
        _cardCoverRefreshIntents.add(identity);
      }
      _cardCoverFutures.remove(identity);
      _cardCoverSourceFailures.remove(identity);
      _cardCoverDecodeFailures.remove(identity);
    }
  }

  void _recordCoverDecodeFailure(
    BrowsableComicSource source,
    SourceComicSummary comic,
    Future<EncodedResourceSource> future, {
    bool aggregate = false,
  }) {
    final identity = _sourceCoverIdentity(source, comic);
    if (!mounted || !identical(_cardCoverFutures[identity], future)) return;
    // This observation does not invalidate bytes or start a source request.
    // Only an explicit refresh turns it into a one-shot gateway command.
    _cardCoverDecodeFailures[identity] = future;
    _recordSourceTrace(
      TraceEventKind.taskFailed,
      aggregate ? 'aggregate-cover-decode-failed' : 'cover-decode-failed',
      source,
      identityHash: identity,
      payload: const <String, Object?>{'failureLayer': 'presentation-decode'},
    );
  }

  Map<String, SourceSearchFilterNode> _searchFilterNodesById(
    List<SourceSearchFilterNode> nodes,
  ) {
    final result = <String, SourceSearchFilterNode>{};
    void visit(List<SourceSearchFilterNode> values) {
      for (final node in values) {
        result[node.filterId] = node;
        if (node.children.isNotEmpty) visit(node.children);
      }
    }

    visit(nodes);
    return result;
  }

  bool _filterValueEquals(Object? left, Object? right) {
    if (identical(left, right) || left == right) return true;
    if (left is Map<Object?, Object?> && right is Map<Object?, Object?>) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_filterValueEquals(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  bool _filterStateEquals(
    SourceSearchFilterState left,
    SourceSearchFilterState right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_filterValueEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }

  Object? _effectiveFilterValue(
    SourceSearchFilterNode node,
    SourceSearchFilterState draft,
  ) =>
      draft.containsKey(node.filterId) ? draft[node.filterId] : node.value;

  void _setFilterDraftValue(
    Map<String, Object?> draft,
    SourceSearchFilterNode node,
    Object? value,
  ) {
    if (_filterValueEquals(value, node.value)) {
      draft.remove(node.filterId);
    } else {
      draft[node.filterId] = value;
    }
  }

  List<Widget> _buildSearchFilterControls(
    BuildContext context,
    List<SourceSearchFilterNode> nodes,
    Map<String, Object?> draft,
    StateSetter setSheetState, {
    int depth = 0,
  }) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final value = _effectiveFilterValue(node, draft);
      switch (node.kind) {
        case SourceSearchFilterKind.header:
          widgets.add(
            Padding(
              key: comicSourceFilterKey(node.filterId),
              padding: EdgeInsets.only(top: depth == 0 ? 8 : 4, bottom: 4),
              child: Text(
                node.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          );
          break;
        case SourceSearchFilterKind.separator:
          widgets.add(
            Divider(key: comicSourceFilterKey(node.filterId)),
          );
          break;
        case SourceSearchFilterKind.group:
          widgets.add(
            Padding(
              key: comicSourceFilterKey(node.filterId),
              padding: EdgeInsets.only(left: depth * 8.0, top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (node.label.isNotEmpty)
                    Text(
                      node.label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ..._buildSearchFilterControls(
                    context,
                    node.children,
                    draft,
                    setSheetState,
                    depth: depth + 1,
                  ),
                ],
              ),
            ),
          );
          break;
        case SourceSearchFilterKind.checkBox:
          widgets.add(
            CheckboxListTile(
              key: comicSourceFilterKey(node.filterId),
              dense: true,
              contentPadding: EdgeInsets.only(left: depth * 8.0),
              title: Text(node.label),
              value: value is bool ? value : false,
              onChanged: (next) => setSheetState(() {
                _setFilterDraftValue(draft, node, next ?? false);
              }),
            ),
          );
          break;
        case SourceSearchFilterKind.triState:
          widgets.add(
            Padding(
              key: comicSourceFilterKey(node.filterId),
              padding: EdgeInsets.only(left: depth * 8.0, top: 6, bottom: 6),
              child: DropdownButtonFormField<int>(
                value: value is int ? value : 0,
                decoration: InputDecoration(labelText: node.label),
                items: const <DropdownMenuItem<int>>[
                  DropdownMenuItem<int>(value: 0, child: Text('忽略')),
                  DropdownMenuItem<int>(value: 1, child: Text('包含')),
                  DropdownMenuItem<int>(value: 2, child: Text('排除')),
                ],
                onChanged: (next) {
                  if (next == null) return;
                  setSheetState(() => _setFilterDraftValue(draft, node, next));
                },
              ),
            ),
          );
          break;
        case SourceSearchFilterKind.select:
          final selectedIndex = value is int &&
                  value >= 0 &&
                  value < node.options.length
              ? value
              : null;
          widgets.add(
            Padding(
              key: comicSourceFilterKey(node.filterId),
              padding: EdgeInsets.only(left: depth * 8.0, top: 6, bottom: 6),
              child: DropdownButtonFormField<int>(
                value: selectedIndex,
                decoration: InputDecoration(labelText: node.label),
                items: <DropdownMenuItem<int>>[
                  for (var index = 0; index < node.options.length; index++)
                    DropdownMenuItem<int>(
                      value: index,
                      child: Text(node.options[index]),
                    ),
                ],
                onChanged: node.options.isEmpty
                    ? null
                    : (next) {
                        if (next == null) return;
                        setSheetState(
                          () => _setFilterDraftValue(draft, node, next),
                        );
                      },
              ),
            ),
          );
          break;
        case SourceSearchFilterKind.text:
          final text = value is String ? value : '';
          widgets.add(
            Padding(
              padding: EdgeInsets.only(left: depth * 8.0, top: 6, bottom: 6),
              child: TextFormField(
                key: ValueKey<String>(
                  'source-filter-text:${node.filterId}:$text',
                ),
                initialValue: text,
                decoration: InputDecoration(
                  labelText: node.label.isEmpty ? null : node.label,
                ),
                onChanged: (next) {
                  _setFilterDraftValue(draft, node, next);
                },
              ),
            ),
          );
          break;
        case SourceSearchFilterKind.sort:
          final sortState = value is Map<Object?, Object?> ? value : null;
          final rawIndex = sortState?['index'];
          final selectedIndex = rawIndex is int &&
                  rawIndex >= 0 &&
                  rawIndex < node.options.length
              ? rawIndex
              : null;
          final ascendingValue = sortState?['ascending'];
          final ascending = ascendingValue is bool ? ascendingValue : true;
          widgets.add(
            Padding(
              key: comicSourceFilterKey(node.filterId),
              padding: EdgeInsets.only(left: depth * 8.0, top: 6, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  DropdownButtonFormField<int>(
                    value: selectedIndex,
                    decoration: InputDecoration(
                      labelText: node.label.isEmpty ? '排序' : node.label,
                    ),
                    items: <DropdownMenuItem<int>>[
                      for (var index = 0; index < node.options.length; index++)
                        DropdownMenuItem<int>(
                          value: index,
                          child: Text(node.options[index]),
                        ),
                    ],
                    onChanged: node.options.isEmpty
                        ? null
                        : (next) {
                            if (next == null) return;
                            setSheetState(() {
                              _setFilterDraftValue(
                                draft,
                                node,
                                <String, Object?>{
                                  'index': next,
                                  'ascending': ascending,
                                },
                              );
                            });
                          },
                  ),
                  if (selectedIndex != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        children: <Widget>[
                          ChoiceChip(
                            label: const Text('升序'),
                            selected: ascending,
                            onSelected: (_) => setSheetState(() {
                              _setFilterDraftValue(
                                draft,
                                node,
                                <String, Object?>{
                                  'index': selectedIndex,
                                  'ascending': true,
                                },
                              );
                            }),
                          ),
                          ChoiceChip(
                            label: const Text('降序'),
                            selected: !ascending,
                            onSelected: (_) => setSheetState(() {
                              _setFilterDraftValue(
                                draft,
                                node,
                                <String, Object?>{
                                  'index': selectedIndex,
                                  'ascending': false,
                                },
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
          break;
      }
    }
    return widgets;
  }

  List<SourceBrowseSection> _orderedBrowseSections(
    List<SourceBrowseSection> sections,
  ) {
    final indexed = sections.indexed.toList(growable: false);
    indexed.sort((left, right) {
      int rank(SourceBrowseSection section) {
        final id = section.sectionId.toLowerCase();
        final label = section.label.trim().toLowerCase();
        if (id == 'latest' || label == 'latest' || label == '最新') return 0;
        if (id == 'popular' || label == 'popular' || label == '热门') return 1;
        return 2;
      }

      final ranked = rank(left.$2).compareTo(rank(right.$2));
      return ranked != 0 ? ranked : left.$1.compareTo(right.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  List<SourceBrowseSection> _displaySections() =>
      _orderedBrowseSections(_sections);

  Future<void> _openFilterSheet() async {
    if (_searchFilters.isEmpty) return;
    // A route/IME rebuild must keep the edits from this sheet invocation.
    final draft = Map<String, Object?>.from(_filterState);
    final selected = await showModalBottomSheet<SourceSearchFilterState>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            key: comicSourceFilterSheetKey,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('筛选', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      key: comicSourceFilterBarKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildSearchFilterControls(
                          context,
                          _searchFilters,
                          draft,
                          setSheetState,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: draft.isEmpty
                            ? null
                            : () => setSheetState(draft.clear),
                        child: const Text('恢复默认'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.of(sheetContext).pop(
                          Map<String, Object?>.unmodifiable(draft),
                        ),
                        child: const Text('应用'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null) return;
    final stateChanged = !_filterStateEquals(selected, _filterState);
    final viewChanged = !_filterViewActive;
    if (!stateChanged && !viewChanged) return;
    setState(() {
      _filterState = Map<String, Object?>.unmodifiable(selected);
      _filterViewActive = true;
      _pageOffset = 0;
      _resetBrowseCoordinates();
    });
    unawaited(_reload(offset: 0));
  }

  void _collapseSearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    _setSearchOptionsExpanded(false);
    if (!_searchExpanded.value) return;
    _searchExpanded.value = false;
  }

  void _expandSearch() {
    if (_searchExpanded.value) return;
    _searchExpanded.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchExpanded.value) {
        _searchFocus.requestFocus();
      }
    });
  }

  void _openAggregateSearch() {
    final plugins = _aggregateSearchPlugins();
    if (plugins.isEmpty) return;
    final enteredQuery = _search.text.trim();
    final cachedItems = _aggregateItems.isNotEmpty
        ? _aggregateItems
        : _lastAggregateItems;
    final cachedQuery = _aggregateItems.isNotEmpty
        ? (_aggregateQuery.isNotEmpty ? _aggregateQuery : _lastAggregateQuery)
        : _lastAggregateQuery;
    final query = enteredQuery.isNotEmpty
        ? enteredQuery
        : (cachedQuery.isNotEmpty ? cachedQuery : _lastSearchQuery);
    _setSearchOptionsExpanded(false);
    final selectedPlugins = plugins.toList(growable: false);
    setState(() {
      _aggregateViewActive = true;
      _aggregateLoading = false;
      _aggregateFailure = null;
      _aggregateItems = cachedItems;
      _aggregateQuery = cachedQuery;
    });
    if (cachedItems.isEmpty && query.isNotEmpty) {
      unawaited(_runAggregateSearch(query, selectedPlugins));
    }
  }

  void _exitAggregateSearchView({bool rebuild = true}) {
    final hasAggregateState =
        _aggregateViewActive ||
        _aggregateLoading ||
        _aggregateSearch.enabled ||
        _aggregateQuery.isNotEmpty ||
        _aggregateItems.isNotEmpty;
    if (!hasAggregateState) return;
    ++_generation;
    void clearState() {
      _aggregateViewActive = false;
      _aggregateLoading = false;
      _aggregateFailure = null;
      _aggregateItems = const <_AggregateSearchResult>[];
      _aggregateQuery = '';
    }
    if (rebuild && mounted) {
      setState(() {
        clearState();
      });
    } else {
      clearState();
    }
  }

  Future<bool> _refreshAggregateResults() async {
    final query = (_aggregateQuery.isNotEmpty
            ? _aggregateQuery
            : _lastAggregateQuery)
        .trim();
    if (query.isNotEmpty) {
      final plugins = _aggregateSearch.enabled
          ? _aggregateSearchPlugins()
              .where(
                (plugin) => _aggregateSearch.pluginIds.contains(plugin.pluginId),
              )
              .toList(growable: false)
          : _aggregateSearchPlugins();
      if (plugins.isNotEmpty) {
        setState(() {
          for (final sourceId in <String>{
            for (final plugin in plugins) plugin.source.sourceId,
          }) {
            _retireSourceCardCovers(sourceId);
          }
          _artworkRetryRevision++;
        });
        await _runAggregateSearch(query, plugins);
        return true;
      }
    }
    _exitAggregateSearchView();
    return _reload(forceRefresh: true);
  }

  List<_AggregateSearchPlugin> _aggregateSearchPlugins() {
    final controller = widget.externalPlugins;
    final plugins = <_AggregateSearchPlugin>[];
    final seen = <String>{};
    for (final source in widget.sources) {
      final owner = controller?.ownerOfSource(source.sourceId);
      final pluginId = owner ?? 'source:${source.sourceId}';
      if (!seen.add(pluginId)) continue;
      plugins.add(
        _AggregateSearchPlugin(
          pluginId: pluginId,
          label: source.descriptor.name,
          accent: _comicSourceAccent(source),
          source: source,
        ),
      );
    }
    return plugins;
  }

  void _setSearchOptionsExpanded(bool expanded) {
    _aggregateSearch.setExpanded(
      expanded,
      _aggregateSearchPlugins().map((plugin) => plugin.pluginId),
    );
  }

  bool _handleSourceScroll(ScrollNotification notification) {
    if (_searchExpanded.value &&
        (notification is ScrollStartNotification ||
            notification is UserScrollNotification)) {
      scheduleMicrotask(_collapseSearch);
    }
    return false;
  }

  void _submitSearch(String value) {
    final normalized = value.trim();
    if (_aggregateSearch.enabled || _aggregateViewActive) {
      final allPlugins = _aggregateSearchPlugins();
      final selectedPlugins = (_aggregateSearch.enabled
              ? allPlugins.where(
                  (plugin) =>
                      _aggregateSearch.pluginIds.contains(plugin.pluginId),
                )
              : allPlugins)
          .toList(growable: false);
      if (selectedPlugins.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请至少选择一个搜索插件')),
        );
        return;
      }
      _query = normalized;
      _aggregateQuery = normalized;
      _pageOffset = 0;
      _resetBrowseCoordinates();
      if (normalized.isNotEmpty) {
        _lastSearchQuery = normalized;
        widget.onSearchCommitted?.call(normalized);
      }
      _collapseSearch();
      unawaited(_runAggregateSearch(normalized, selectedPlugins));
      if (!_searchQueryLocked) {
        _query = '';
        _search.clear();
      }
      _aggregateSearch.setEnabled(
        false,
        allPlugins.map((plugin) => plugin.pluginId),
      );
      return;
    }
    _exitAggregateSearchView();
    _query = normalized;
    _pageOffset = 0;
    _resetBrowseCoordinates();
    if (normalized.isNotEmpty) {
      _lastSearchQuery = normalized;
      widget.onSearchCommitted?.call(normalized);
    }
    _collapseSearch();
    unawaited(_reload(offset: 0));
    if (!_searchQueryLocked) {
      _query = '';
      _aggregateQuery = '';
      _search.clear();
    }
  }

  Future<List<_AggregateSearchResult>> _searchAggregatePlugin(
    _AggregateSearchPlugin plugin,
    String query,
    Set<String> categoryIds,
  ) async {
    final source = plugin.source;
    final pages = <SourceBrowsePage>[];
    if (categoryIds.isEmpty) {
      pages.add(
        await source.browse(query: query, offset: 0, limit: _pageSize),
      );
    } else {
      final Object candidate = source;
      if (candidate is! SectionedBrowsableComicSource) {
        return const <_AggregateSearchResult>[];
      }
      final sections = await candidate.loadBrowseSections();
      for (final section in sections) {
        if (!categoryIds.contains(section.sectionId)) continue;
        pages.add(
          await candidate.browseSection(
            section.sectionId,
            query: query,
            offset: 0,
            limit: _pageSize,
          ),
        );
      }
    }
    final seen = <String>{};
    final results = <_AggregateSearchResult>[];
    for (final page in pages) {
      for (final comic in page.items) {
        final identity = _stableSourceComicIdentity(source, comic.comicId);
        if (!seen.add(identity)) continue;
        results.add(_AggregateSearchResult(source: source, comic: comic));
      }
    }
    return results;
  }

  Future<void> _runAggregateSearch(
    String query,
    List<_AggregateSearchPlugin> plugins,
  ) async {
    final generation = ++_generation;
    final categoryIds = Set<String>.of(_aggregateSearch.categoryIds);
    setState(() {
      _aggregateViewActive = true;
      _aggregateLoading = true;
      _aggregateFailure = null;
      _aggregateItems = const <_AggregateSearchResult>[];
      _aggregateQuery = query;
    });
    final batches = await Future.wait(
      plugins.map((plugin) async {
        try {
          return (
            items: await _searchAggregatePlugin(plugin, query, categoryIds),
            error: null as Object?,
          );
        } on Object catch (error) {
          return (
            items: const <_AggregateSearchResult>[],
            error: error as Object?,
          );
        }
      }),
    );
    if (!mounted || generation != _generation) return;
    final results = <_AggregateSearchResult>[];
    Object? firstError;
    for (final batch in batches) {
      results.addAll(batch.items);
      firstError ??= batch.error;
    }
    setState(() {
      _aggregateItems = List<_AggregateSearchResult>.unmodifiable(results);
      _lastAggregateItems = List<_AggregateSearchResult>.unmodifiable(results);
      _lastAggregateQuery = query;
      _aggregateFailure = results.isEmpty ? firstError : null;
      _aggregateLoading = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _selectBrowseSection(String sectionId) {
    _exitAggregateSearchView();
    if (_selectedSectionId == sectionId && !_filterViewActive) return;
    setState(() {
      _selectedSectionId = sectionId;
      _filterViewActive = false;
      _pageOffset = 0;
      _resetBrowseCoordinates();
    });
    unawaited(_reload(offset: 0));
  }

  Future<void> _goToPage(int offset) async {
    if (_loading || offset < 0) return;
    _pageOffset = offset;
    _rememberSourceView(_activeSource?.sourceId);
    await _reload(offset: offset);
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _activeSource;
    return WillPopScope(
      onWillPop: () async {
        if (_searchExpanded.value) {
          _collapseSearch();
          return false;
        }
        if (_aggregateViewActive) {
          _exitAggregateSearchView();
          return false;
        }
        return true;
      },
      child: Column(
        key: comicSourcesPageKey,
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: RepaintBoundary(child: _buildBody(source)),
                ),
                if (_refreshing)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _SourceSearchKeyboardInset(
                    onKeyboardHiding: () => _searchFocus.unfocus(),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _searchExpanded,
                      builder: (context, expanded, child) =>
                          _buildFloatingSearch(context, source, expanded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          RepaintBoundary(
            child: _SourceSwitcher(
              sources: widget.sources,
              activeSourceId: widget.activeSourceId,
              onSelected: (sourceId) {
                _exitAggregateSearchView();
                _aggregateSearch.setEnabled(
                  false,
                  _aggregateSearchPlugins().map((plugin) => plugin.pluginId),
                );
                widget.onSourceSelected(sourceId);
              },
              externalPlugins: widget.externalPlugins,
              onExternalPluginRetry: widget.onExternalPluginRetry,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHistory(
    BuildContext context,
    List<String> history,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '搜索历史',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const Spacer(),
              TextButton(
                onPressed: widget.onSearchHistoryCleared,
                child: const Text('清空'),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final query in history)
                InputChip(
                  label: Text(query),
                  onPressed: () {
                    _search.value = TextEditingValue(
                      text: query,
                      selection: TextSelection.collapsed(offset: query.length),
                    );
                    _submitSearch(query);
                  },
                  onDeleted: widget.onSearchRemoved == null
                      ? null
                      : () => widget.onSearchRemoved!(query),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAggregateSearchOptions(
    BuildContext context,
    List<_AggregateSearchPlugin> plugins,
    List<SourceBrowseSection> categories,
  ) {
    final options = _aggregateSearch;
    final pluginIds = plugins.map((plugin) => plugin.pluginId);
    final categoryAccent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              key: comicSourceAggregateSearchKey,
              avatar: const Icon(Icons.hub_outlined, size: 18),
              label: const Text('聚合搜索'),
              selected: options.enabled,
              showCheckmark: false,
              onSelected: (selected) =>
                  options.setEnabled(selected, pluginIds),
            ),
          ),
          const SizedBox(height: 8),
          Text('搜索插件', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final plugin in plugins)
                _ComicSourceChip(
                  chipKey: comicSourceAggregatePluginKey(plugin.pluginId),
                  label: plugin.label,
                  accent: plugin.accent,
                  format: _comicSourcePluginFormat(plugin.source.sourceId),
                  multiple: true,
                  selected: options.pluginIds.contains(plugin.pluginId),
                  onSelected: options.enabled
                      ? (selected) => options.togglePlugin(
                            plugin.pluginId,
                            selected,
                          )
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('搜索分类', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          if (categories.isEmpty)
            Text(
              '当前来源没有可选分类',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final category in categories)
                  FilterChip(
                    key: comicSourceAggregateCategoryKey(category.sectionId),
                    label: Text(category.label),
                    selected:
                        options.categoryIds.contains(category.sectionId),
                    showCheckmark: false,
                    selectedColor: categoryAccent,
                    side: BorderSide(
                      color: categoryAccent.withValues(alpha: .7),
                    ),
                    labelStyle:
                        options.categoryIds.contains(category.sectionId)
                            ? TextStyle(
                                color: Theme.of(context).colorScheme.onPrimary,
                              )
                            : TextStyle(color: categoryAccent),
                    onSelected: options.enabled
                        ? (selected) => options.toggleCategory(
                              category.sectionId,
                              selected,
                            )
                        : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildFloatingSearch(
    BuildContext context,
    BrowsableComicSource? source,
    bool expanded,
  ) {
    final maxWidth = MediaQuery.sizeOf(context).width;
    final expandedWidth = (maxWidth - 24).clamp(260.0, 480.0).toDouble();
    if (!expanded) {
      return GestureDetector(
        key: comicSourceSearchFabKey,
        behavior: HitTestBehavior.opaque,
        onTap: source == null
            ? null
            : _expandSearch,
        onLongPress: source == null ? null : _openAggregateSearch,
        child: IgnorePointer(
          child: FloatingActionButton.small(
            onPressed: source == null ? null : () {},
            heroTag: 'comic-source-search',
            tooltip: '搜索漫画源，长按打开聚合搜索',
            child: const Icon(Icons.search),
          ),
        ),
      );
    }
    final history = widget.searchHistory;
    final plugins = _aggregateSearchPlugins();
    final categories = _displaySections();
    return AnimatedBuilder(
      animation: _aggregateSearch,
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => _collapseSearch(),
        child: Material(
        key: comicSourceSearchHistoryKey,
        elevation: 6,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: expandedWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              GestureDetector(
                key: comicSourceSearchExpandKey,
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < 0) {
                    _setSearchOptionsExpanded(true);
                  } else if (velocity > 0) {
                    _setSearchOptionsExpanded(false);
                  }
                },
                child: SizedBox(
                  height: 30,
                  child: Center(
                    child: IconButton(
                      tooltip: _aggregateSearch.expanded
                          ? '收起扩展搜索'
                          : '展开扩展搜索',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      onPressed: () => _setSearchOptionsExpanded(
                        !_aggregateSearch.expanded,
                      ),
                      icon: Icon(
                        _aggregateSearch.expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                      ),
                    ),
                  ),
                ),
              ),
              if (_aggregateSearch.expanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildAggregateSearchOptions(
                          context,
                          plugins,
                          categories,
                        ),
                        if (history.isNotEmpty)
                          _buildSearchHistory(context, history),
                      ],
                    ),
                  ),
                )
              else if (history.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleSourceScroll,
                    child: SingleChildScrollView(
                      child: _buildSearchHistory(context, history),
                    ),
                  ),
                ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _search,
                builder: (context, value, child) => SearchBar(
                  key: comicSourceSearchKey,
                  controller: _search,
                  focusNode: _searchFocus,
                  autoFocus: false,
                  enabled: source != null,
                  hintText: source == null
                      ? '请先启用漫画源'
                      : '搜索 ${source.descriptor.name}',
                  leading: IconButton(
                    tooltip: '收起搜索',
                    onPressed: _collapseSearch,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  trailing: <Widget>[
                    if (value.text.isNotEmpty)
                      IconButton(
                        tooltip: '清除搜索',
                        onPressed: _search.clear,
                        icon: const Icon(Icons.close),
                      ),
                    IconButton(
                      key: comicSourceSearchLockKey,
                      tooltip: _searchQueryLocked ? '解除关键词锁定' : '锁定关键词',
                      onPressed: () => setState(
                        () => _searchQueryLocked = !_searchQueryLocked,
                      ),
                      icon: Icon(
                        _searchQueryLocked ? Icons.lock : Icons.lock_open,
                      ),
                    ),
                  ],
                  onSubmitted: _submitSearch,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  Widget _refreshableStatus(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleSourceScroll,
      child: AppPullToRefresh(
        key: comicSourcePullRefreshKey,
        resultKey: comicSourceRefreshStateKey,
        onRefresh: () => _reload(forceRefresh: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverFillRemaining(
              hasScrollBody: false,
              child: child,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BrowsableComicSource? source) {
    if (source == null) {
      return const Center(
        key: comicSourceEmptyKey,
        child: Text('没有已启用的漫画源，请从顶部管理入口启用。'),
      );
    }
    if (_aggregateViewActive) {
      return _buildAggregateResultsBody();
    }
    if (_loading && _items.isEmpty) {
      return _refreshableStatus(
        const Center(
          key: comicSourceLoadingKey,
          child: CircularProgressIndicator(),
        ),
      );
    }
    final failure = _failure;
    if (failure != null && _items.isEmpty) {
      return _refreshableStatus(
        _SourceFailurePanel(
          key: comicSourceErrorKey,
          title: '漫画源加载失败',
          failure: failure,
          onRetry: () => unawaited(_reload(forceRefresh: true)),
          onOpenWebView: failure.requiresSourceVerification &&
                  widget.onOpenSourceWebView != null
              ? () => unawaited(
                    _recoverSourceAccess(
                      source,
                      verificationUri: failure.verificationUri,
                    ),
                  )
              : null,
          openingWebView: _recoveringSourceAccess,
        ),
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
        final padding =
            ((constraints.maxWidth - used) / 2).clamp(12, 80).toDouble();
        return NotificationListener<ScrollNotification>(
          onNotification: _handleSourceScroll,
          child: AppPullToRefresh(
            key: comicSourcePullRefreshKey,
            resultKey: comicSourceRefreshStateKey,
            onRefresh: () => _reload(forceRefresh: true),
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: <Widget>[
            if (_sections.length > 1 || _searchFilters.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  key: comicSourceCategoryBarKey,
                  height: 52,
                  child: Builder(
                    builder: (context) {
                      final sections = _displaySections();
                      final itemCount = sections.length +
                          (_searchFilters.isNotEmpty ? 1 : 0);
                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        scrollDirection: Axis.horizontal,
                        itemCount: itemCount,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          if (index < sections.length) {
                            final section = sections[index];
                            return ChoiceChip(
                              key: comicSourceCategoryKey(section.sectionId),
                              label: Text(section.label),
                              selected: !_filterViewActive &&
                                  section.sectionId == _selectedSectionId,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  _selectBrowseSection(section.sectionId),
                            );
                          }
                          return ChoiceChip(
                            key: comicSourceFilterActionKey,
                            avatar: _filterState.isEmpty
                                ? const Icon(Icons.tune, size: 18)
                                : const Icon(Icons.filter_alt, size: 18),
                            label: Text(
                              _filterState.isEmpty
                                  ? '筛选'
                                  : '筛选 ${_filterState.length}',
                            ),
                            selected: _filterViewActive,
                            showCheckmark: false,
                            onSelected: (_) => unawaited(_openFilterSheet()),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            if (failure != null && _items.isNotEmpty)
              SliverToBoxAdapter(
                child: _SourceRetainedFailureBanner(
                  failure: failure,
                  onRetry: () => unawaited(_reload(forceRefresh: true)),
                  onOpenWebView: failure.requiresSourceVerification &&
                          widget.onOpenSourceWebView != null
                      ? () => unawaited(
                            _recoverSourceAccess(
                              source,
                              verificationUri: failure.verificationUri,
                            ),
                          )
                      : null,
                  openingWebView: _recoveringSourceAccess,
                ),
              ),
            if (_items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  key: comicSourceEmptyKey,
                  child: Text(_query.isEmpty ? '该分类暂无内容' : '没有匹配的漫画'),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(padding, 8, padding, 12),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: count,
                    mainAxisExtent: 224,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: 12,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final comic = _items[index];
                      return _SourceComicCard(
                        key: ValueKey<String>(
                          'source-comic-owner:${source.sourceId}\u0000${_stableSourceComicIdentity(source, comic.comicId)}',
                        ),
                        source: source,
                        comic: comic,
                        inShelf: widget.isInShelf?.call(source, comic) ?? false,
                        hasUpdate:
                            widget.hasUpdate?.call(source, comic) ?? false,
                        reloadToken: _artworkRetryRevision,
                        loadCover: _loadSourceCardCover,
                        onCoverFrameReady: () => _recordSourceTrace(
                          TraceEventKind.firstFrameReady,
                          'cover-first-frame',
                          source,
                          identityHash: _sourceCoverIdentity(source, comic),
                        ),
                        onCoverDecodeFailure: (future) =>
                            _recordCoverDecodeFailure(source, comic, future),
                        onSourceVerificationRequired:
                            widget.onOpenSourceWebView == null
                                ? null
                                : () => unawaited(_recoverSourceAccess(source)),
                        onOpenUpdate: widget.onOpenUpdate == null
                            ? null
                            : () => unawaited(
                                  widget.onOpenUpdate!(source, comic),
                                ),
                        onTap: () => unawaited(
                          widget.onOpenComic(source, comic),
                        ),
                      );
                    },
                    childCount: _items.length,
                  ),
                ),
              ),
            if (_items.isNotEmpty || _pageOffset > 0 || _hasMore)
              SliverToBoxAdapter(
                child: _SourcePager(
                  page: _browsePageNumber,
                  hasPrevious: _pageOffset > 0,
                  hasNext: _hasMore,
                  onPrevious: () => unawaited(
                    _goToPage(_previousBrowseOffset),
                  ),
                  onNext: () => unawaited(_goToPage(_nextOffset)),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 84)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAggregateResultsBody() {
    final query = _aggregateQuery;
    return LayoutBuilder(
      builder: (context, constraints) {
        const width = 132.0;
        const spacing = 12.0;
        final count = ((constraints.maxWidth + spacing) / (width + spacing))
            .floor()
            .clamp(1, 12)
            .toInt();
        final used = count * width + (count - 1) * spacing;
        final padding =
            ((constraints.maxWidth - used) / 2).clamp(12, 80).toDouble();
        return NotificationListener<ScrollNotification>(
          onNotification: _handleSourceScroll,
          child: AppPullToRefresh(
            key: comicSourcePullRefreshKey,
            resultKey: comicSourceRefreshStateKey,
            onRefresh: _refreshAggregateResults,
            child: CustomScrollView(
              key: comicSourceAggregateResultsKey,
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      query.isEmpty ? '聚合搜索' : '聚合搜索：$query',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                if (_aggregateLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_aggregateItems.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        _aggregateFailure == null
                            ? '请输入关键词开始聚合搜索'
                            : '聚合搜索失败：$_aggregateFailure',
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(padding, 8, padding, 84),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: count,
                        mainAxisExtent: 224,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final result = _aggregateItems[index];
                          final source = result.source;
                          final comic = result.comic;
                          return _SourceComicCard(
                            key: ValueKey<String>(
                              'aggregate-source-comic:${source.sourceId}\u0000'
                              '${_stableSourceComicIdentity(source, comic.comicId)}',
                            ),
                            source: source,
                            comic: comic,
                            inShelf: widget.isInShelf?.call(source, comic) ??
                                false,
                            hasUpdate: widget.hasUpdate?.call(source, comic) ??
                                false,
                            reloadToken: _artworkRetryRevision,
                            loadCover: _loadSourceCardCover,
                            onCoverFrameReady: () => _recordSourceTrace(
                              TraceEventKind.firstFrameReady,
                              'aggregate-cover-first-frame',
                              source,
                              identityHash: _sourceCoverIdentity(source, comic),
                            ),
                            onCoverDecodeFailure: (future) =>
                                _recordCoverDecodeFailure(source, comic, future,
                                  aggregate: true),
                            onSourceVerificationRequired:
                                widget.onOpenSourceWebView == null
                                    ? null
                                    : () => unawaited(
                                          _recoverSourceAccess(source),
                                        ),
                            onOpenUpdate: widget.onOpenUpdate == null
                                ? null
                                : () => unawaited(
                                      widget.onOpenUpdate!(source, comic),
                                    ),
                            onTap: () => unawaited(
                              widget.onOpenComic(source, comic),
                            ),
                          );
                        },
                        childCount: _aggregateItems.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _SourceSearchKeyboardInset extends StatefulWidget {
  const _SourceSearchKeyboardInset({
    required this.child,
    required this.onKeyboardHiding,
  });

  final Widget child;
  final VoidCallback onKeyboardHiding;

  @override
  State<_SourceSearchKeyboardInset> createState() =>
      _SourceSearchKeyboardInsetState();
}

final class _SourceSearchKeyboardInsetState
    extends State<_SourceSearchKeyboardInset> {
  double _bottomClearance = 0;
  double _keyboardInset = 0;
  bool _measurementScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset < _keyboardInset) widget.onKeyboardHiding();
    _keyboardInset = inset;
  }

  void _scheduleBottomClearanceMeasurement() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      final clearance = (MediaQuery.sizeOf(context).height - bottom)
          .clamp(0.0, double.infinity)
          .toDouble();
      if ((clearance - _bottomClearance).abs() < 0.5) return;
      setState(() => _bottomClearance = clearance);
    });
  }

  @override
  Widget build(BuildContext context) {
    _scheduleBottomClearanceMeasurement();
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final overlap = (keyboardInset - _bottomClearance)
        .clamp(0.0, keyboardInset)
        .toDouble();
    return Padding(
      padding: EdgeInsets.only(bottom: overlap),
      child: RepaintBoundary(child: widget.child),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        child: Material(
          key: comicSourcePagerKey,
          elevation: 1,
          borderRadius: BorderRadius.circular(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                key: comicSourcePreviousPageKey,
                tooltip: '上一页',
                onPressed: hasPrevious ? onPrevious : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
      ),
    );
  }
}

final class _SourceSwitcher extends StatefulWidget {
  const _SourceSwitcher({
    required this.sources,
    required this.activeSourceId,
    required this.onSelected,
    this.externalPlugins,
    this.onExternalPluginRetry,
  });

  final List<BrowsableComicSource> sources;
  final String? activeSourceId;
  final ValueChanged<String> onSelected;
  final ExternalPluginController? externalPlugins;
  final Future<void> Function(InstalledExternalPlugin plugin)?
      onExternalPluginRetry;

  @override
  State<_SourceSwitcher> createState() => _SourceSwitcherState();
}

final class _SourceSwitcherState extends State<_SourceSwitcher> {
  final Set<String> _workingPlugins = <String>{};
  StreamSubscription<void>? _externalPluginChanges;

  @override
  void initState() {
    super.initState();
    _listenToExternalPlugins(widget.externalPlugins);
  }

  @override
  void didUpdateWidget(covariant _SourceSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.externalPlugins, widget.externalPlugins)) {
      _listenToExternalPlugins(widget.externalPlugins);
    }
  }

  @override
  void dispose() {
    final changes = _externalPluginChanges;
    _externalPluginChanges = null;
    if (changes != null) {
      unawaited(changes.cancel());
    }
    super.dispose();
  }

  void _listenToExternalPlugins(ExternalPluginController? controller) {
    final previous = _externalPluginChanges;
    _externalPluginChanges = null;
    if (previous != null) {
      unawaited(previous.cancel());
    }
    _workingPlugins.clear();
    if (controller == null) return;
    _externalPluginChanges = controller.sourceChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  List<InstalledExternalPlugin> _visiblePlugins(
    ExternalPluginController controller,
  ) {
    final activePluginIds = <String>{};
    for (final source in widget.sources) {
      final owner = controller.ownerOfSource(source.sourceId);
      if (owner != null) activePluginIds.add(owner);
    }
    final plugins = controller.installed.where((plugin) {
      if (!activePluginIds.contains(plugin.plugin.pluginId)) return false;
      final failure = controller.activationFailures[plugin.plugin.pluginId];
      // Bottom controls represent enabled source sessions, not installed
      // payload records. An inactive Venera or Mihon plugin remains available
      // from management but must not appear as a disabled source control.
      return failure == null ||
          controller.canRetryActivation(plugin.plugin.pluginId);
    }).where((plugin) {
      // A plugin without a usable source name cannot produce a meaningful
      // source-page control. Do not invent a generic placeholder label.
      return _pluginDisplayName(plugin) != null;
    }).toList(growable: true)
      ..sort((left, right) => left.plugin.name.compareTo(right.plugin.name));
    return plugins;
  }

  Future<void> _retryPlugin(InstalledExternalPlugin plugin) async {
    final controller = widget.externalPlugins;
    final pluginId = plugin.plugin.pluginId;
    if (controller == null || !_workingPlugins.add(pluginId)) return;
    setState(() {});
    final displayName = _pluginDisplayName(plugin);
    if (displayName == null) {
      _workingPlugins.remove(pluginId);
      if (mounted) setState(() {});
      return;
    }
    try {
      final callback = widget.onExternalPluginRetry;
      if (callback != null) {
        await callback(plugin);
      } else {
        await controller.retryActivation(pluginId);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$displayName 已重新加载')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          copyableDiagnosticSnackBar('$displayName 加载失败：$error'),
        );
      }
    } finally {
      _workingPlugins.remove(pluginId);
      if (mounted) setState(() {});
    }
  }

  String? _pluginDisplayName(InstalledExternalPlugin plugin) {
    final pluginId = plugin.plugin.pluginId;
    final controller = widget.externalPlugins;
    if (controller != null) {
      for (final source in widget.sources) {
        if (controller.ownerOfSource(source.sourceId) != pluginId) continue;
        final activeName = source.descriptor.name.trim();
        if (activeName.isNotEmpty) return activeName;
      }
    }

    for (final source in plugin.plugin.sources) {
      final name = source.name.trim();
      if (name.isNotEmpty) return name;
    }
    return null;
  }

  Widget _pluginChip(
    BuildContext context,
    ExternalPluginController controller,
    InstalledExternalPlugin plugin,
  ) {
    final pluginId = plugin.plugin.pluginId;
    final failure = controller.activationFailures[pluginId];
    final retryable = controller.canRetryActivation(pluginId);
    final busy = _workingPlugins.contains(pluginId);
    final pluginSources = widget.sources
        .where((source) => controller.ownerOfSource(source.sourceId) == pluginId)
        .toList(growable: false);
    final selected = pluginSources.any(
      (source) => source.sourceId == widget.activeSourceId,
    );
    final accent = pluginSources.isNotEmpty
        ? _comicSourceAccent(pluginSources.first)
        : plugin.plugin.format == ExternalComicPluginFormat.mihonExtension
            ? Colors.green
            : Colors.blue;
    final displayName = _pluginDisplayName(plugin);
    if (displayName == null) return const SizedBox.shrink();
    final label = failure == null
        ? displayName
        : '$displayName · 点击重试';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: _ComicSourceChip(
        chipKey: comicSourcePluginChoiceKey(pluginId),
        label: label,
        accent: accent,
        format: plugin.plugin.format,
        selected: selected,
        onSelected: busy
            ? null
            : failure != null && retryable
                ? (_) => unawaited(_retryPlugin(plugin))
                : pluginSources.isEmpty
                    ? null
                    : (_) => widget.onSelected(pluginSources.first.sourceId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.externalPlugins;
    final plugins = controller == null
        ? const <InstalledExternalPlugin>[]
        : _visiblePlugins(controller);
    final visiblePluginIds = <String>{
      for (final plugin in plugins) plugin.plugin.pluginId,
    };
    final pluginById = <String, InstalledExternalPlugin>{
      for (final plugin in plugins) plugin.plugin.pluginId: plugin,
    };
    // Chip order follows the unified drag sort of the source-management page:
    // widget.sources arrives preference-ordered, so each plugin control is
    // emitted at the position of its first represented source.
    final chips = <Widget>[];
    final emittedOwners = <String>{};
    void emitSourceChip(BrowsableComicSource source) {
      final accent = _comicSourceAccent(source);
      final selected = source.sourceId == widget.activeSourceId;
      chips.add(
        _ComicSourceChip(
          chipKey: comicSourceChoiceKey(source.sourceId),
          label: source.descriptor.name,
          accent: accent,
          format: _comicSourcePluginFormat(source.sourceId),
          selected: selected,
          onSelected: (_) => widget.onSelected(source.sourceId),
        ),
      );
    }

    for (final source in widget.sources) {
      final owner = controller?.ownerOfSource(source.sourceId);
      if (owner != null && visiblePluginIds.contains(owner)) {
        if (emittedOwners.add(owner)) {
          chips.add(_pluginChip(context, controller!, pluginById[owner]!));
        }
        continue;
      }
      emitSourceChip(source);
    }
    // A visible plugin whose sources are all filtered out (for example an
    // activation failure being retried) still gets its control at the end.
    for (final plugin in plugins) {
      if (emittedOwners.add(plugin.plugin.pluginId)) {
        chips.add(_pluginChip(context, controller!, plugin));
      }
    }
    return _ComicSourceBar(barKey: comicSourceSwitcherKey, chips: chips);
  }
}

final class _SourceComicCard extends StatelessWidget {
  const _SourceComicCard({
    required this.source,
    required this.comic,
    required this.inShelf,
    required this.hasUpdate,
    required this.reloadToken,
    required this.loadCover,
    required this.onCoverFrameReady,
    required this.onCoverDecodeFailure,
    required this.onTap,
    this.onOpenUpdate,
    this.onSourceVerificationRequired,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary comic;
  final bool inShelf;
  final bool hasUpdate;
  final int reloadToken;
  final Future<EncodedResourceSource> Function(
    BrowsableComicSource source, SourceComicSummary comic, Uri uri,
  ) loadCover;
  final VoidCallback onCoverFrameReady;
  final ValueChanged<Future<EncodedResourceSource>> onCoverDecodeFailure;
  final VoidCallback onTap;
  final VoidCallback? onOpenUpdate;
  final VoidCallback? onSourceVerificationRequired;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      key: sourceComicCardKey(
        source.sourceId,
        _stableSourceComicIdentity(source, comic.comicId),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _RemoteImage(
                    uri: comic.coverUri,
                    loadSource: (uri) => loadCover(source, comic, uri),
                    reloadToken: reloadToken,
                    onFrameReady: onCoverFrameReady,
                    onDecodeFailure: onCoverDecodeFailure,
                    verificationKey: sourceComicCoverVerificationKey(
                      source.sourceId,
                      comic.comicId,
                    ),
                    onSourceVerificationRequired:
                        onSourceVerificationRequired,
                  ),
                  if (inShelf) ...<Widget>[
                    ColoredBox(
                      key: sourceComicShelfDimKey(
                        source.sourceId,
                        comic.comicId,
                      ),
                      color: Colors.black.withValues(alpha: 0.34),
                    ),
                    Align(
                      alignment: Alignment.topLeft,
                      child: Semantics(
                        label: '已加入书架',
                        child: Container(
                          key: sourceComicShelfMarkerKey(
                            source.sourceId,
                            comic.comicId,
                          ),
                          margin: const EdgeInsets.all(6),
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.library_books,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (inShelf && hasUpdate)
                    Align(
                      alignment: Alignment.topRight,
                      child: Semantics(
                        button: onOpenUpdate != null,
                        label: '漫画有更新',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onOpenUpdate,
                          child: Container(
                            key: sourceComicUpdateMarkerKey(
                              source.sourceId,
                              comic.comicId,
                            ),
                            margin: const EdgeInsets.all(6),
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .tertiaryContainer
                                  .withValues(alpha: 0.94),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.priority_high,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onTertiaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
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

/// One sortable row of the unified source-management list.
///
/// A Mihon extension family (multi-language variants of one installed plugin)
/// collapses into a single entry represented by its most recently enabled
/// variant; every other origin is a single-source entry.
final class _SourceManagementEntry {
  const _SourceManagementEntry.single(this.source)
      : family = null,
        representativeVariant = null;

  const _SourceManagementEntry.family(this.family, this.representativeVariant)
      : source = null;

  final BrowsableComicSource? source;
  final MihonSourceLanguageGroup? family;
  final BrowsableComicSource? representativeVariant;

  BrowsableComicSource get representative =>
      representativeVariant ?? source!;

  String get entryKey => family?.groupKey ?? source!.sourceId;
}

final class SourceManagementScreen extends StatefulWidget {
  const SourceManagementScreen({
    required this.sources,
    required this.preferences,
    required this.onPreferenceChanged,
    this.externalPlugins,
    this.initialExternalSourceIds,
    this.readExternalPlugins,
    this.readExternalSources,
    this.externalSourceChanges,
    this.networkBridge = const AndroidNetworkBridge(),
    this.onExternalSourcesChanged,
    this.appPreferences,
    super.key,
  });

  final List<BrowsableComicSource> sources;
  final Map<String, ComicSourcePreference> preferences;
  final Future<void> Function(ComicSourcePreference preference)
      onPreferenceChanged;
  final ExternalPluginController? externalPlugins;
  final Set<String>? initialExternalSourceIds;
  final ExternalPluginController? Function()? readExternalPlugins;
  final List<BrowsableComicSource> Function()? readExternalSources;
  final Stream<void>? externalSourceChanges;
  final AndroidNetworkBridge networkBridge;
  final Future<void> Function()? onExternalSourcesChanged;

  /// Application-level preferences owning per-source user choices such as
  /// download roots and adaptive-layout priors.
  final AppPreferencesController? appPreferences;

  @override
  State<SourceManagementScreen> createState() =>
      _SourceManagementScreenState();
}

final class _SourceManagementScreenState
    extends State<SourceManagementScreen> {
  late List<BrowsableComicSource> _sources;
  Set<String> _externalSourceIds = <String>{};
  final Set<String> _expandedFamilies = <String>{};
  late Map<String, ComicSourcePreference> _preferences;
  StreamSubscription<void>? _externalSourceChanges;

  ExternalPluginController? get _externalPlugins =>
      widget.readExternalPlugins?.call() ?? widget.externalPlugins;

  List<BrowsableComicSource> _readExternalSources() =>
      widget.readExternalSources?.call() ??
      _externalPlugins?.activeSources ??
      const <BrowsableComicSource>[];

  @override
  void initState() {
    super.initState();
    _preferences = Map<String, ComicSourcePreference>.from(widget.preferences);
    _externalSourceIds = widget.initialExternalSourceIds == null
        ? <String>{
            for (final source in widget.externalPlugins?.activeSources ??
                const <BrowsableComicSource>[])
              source.sourceId,
          }
        : Set<String>.of(widget.initialExternalSourceIds!);
    _sources = widget.sources.toList(growable: true)
      ..sort((left, right) => _preference(left).sortOrder.compareTo(
            _preference(right).sortOrder,
          ));
    _replaceExternalSources(_readExternalSources(), notify: false);
    _listenToExternalSourceChanges(widget.externalSourceChanges);
  }

  @override
  void didUpdateWidget(covariant SourceManagementScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.externalSourceChanges != widget.externalSourceChanges) {
      _listenToExternalSourceChanges(widget.externalSourceChanges);
    }
    if (oldWidget.readExternalPlugins != widget.readExternalPlugins ||
        oldWidget.readExternalSources != widget.readExternalSources ||
        !identical(oldWidget.externalPlugins, widget.externalPlugins)) {
      _refreshExternalSources(_readExternalSources());
    }
  }

  @override
  void dispose() {
    final changes = _externalSourceChanges;
    _externalSourceChanges = null;
    if (changes != null) {
      unawaited(changes.cancel());
    }
    super.dispose();
  }

  void _listenToExternalSourceChanges(Stream<void>? changes) {
    final previous = _externalSourceChanges;
    _externalSourceChanges = null;
    if (previous != null) {
      unawaited(previous.cancel());
    }
    if (changes == null) return;
    _externalSourceChanges = changes.listen((_) {
      if (mounted) {
        _refreshExternalSources(_readExternalSources());
      }
    });
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

  /// Enables one language variant of a Mihon extension family.
  ///
  /// Only the most recently enabled variant stays active: enabling [target]
  /// disables the currently enabled siblings, stamps [ComicSourcePreference
  /// .lastEnabledAt], and the family row then represents [target].
  Future<void> _enableMihonVariant(
    BrowsableComicSource target, {
    required List<BrowsableComicSource> variants,
  }) async {
    final now = DateTime.now().toUtc();
    final previousPreferences = Map<String, ComicSourcePreference>.of(
      _preferences,
    );
    final updates = <ComicSourcePreference>[];
    var changed = false;
    void apply(BrowsableComicSource source, ComicSourcePreference next) {
      final old = _preferences[source.sourceId];
      if (identical(old, next)) return;
      changed = true;
      _preferences[source.sourceId] = next;
      updates.add(next);
    }

    setState(() {
      apply(
        target,
        _preference(target).copyWith(
          enabled: true,
          lastEnabledAt: now,
          updatedAt: now,
        ),
      );
      for (final sibling in variants) {
        if (sibling.sourceId == target.sourceId) continue;
        final preference = _preference(sibling);
        if (preference.enabled) {
          apply(sibling, preference.copyWith(enabled: false, updatedAt: now));
        }
      }
    });
    if (!changed) return;
    try {
      for (final preference in updates) {
        await widget.onPreferenceChanged(preference);
      }
    } on Object catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _preferences = previousPreferences);
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

  Future<void> _reorderEntries(
    List<_SourceManagementEntry> entries,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex--;
    final reordered = List<_SourceManagementEntry>.of(entries);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final orderedSources = <BrowsableComicSource>[];
    for (final entry in reordered) {
      final family = entry.family;
      if (family == null) {
        orderedSources.add(entry.source!);
        continue;
      }
      orderedSources.add(entry.representative);
      for (final variant in family.otherLanguages) {
        if (variant.sourceId != entry.representative.sourceId) {
          orderedSources.add(variant);
        }
      }
      if (family.defaultSource.sourceId !=
          entry.representative.sourceId) {
        orderedSources.add(family.defaultSource);
      }
    }
    await _persistSourceOrder(orderedSources);
  }

  Widget _managementList(BuildContext context) {
    final entries = _buildManagementEntries(context);
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: entries.length,
      onReorder: (oldIndex, newIndex) =>
          unawaited(_reorderEntries(entries, oldIndex, newIndex)),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return KeyedSubtree(
          key: ValueKey<String>('source-entry:${entry.entryKey}'),
          child: entry.family == null
              ? _sourceTile(entry.source!)
              : _familyTile(context, entry),
        );
      },
    );
  }

  /// One flat sortable list across origins. Mihon language variants of the
  /// same extension collapse into a single draggable row that represents the
  /// most recently enabled variant.
  List<_SourceManagementEntry> _buildManagementEntries(
    BuildContext context,
  ) {
    final preferredLanguage = Localizations.localeOf(context).languageCode;
    final ownerBySourceId = <String, String?>{
      for (final source in _sources)
        source.sourceId: _externalPlugins?.ownerOfSource(source.sourceId),
    };
    String? ownerOf(BrowsableComicSource source) =>
        ownerBySourceId[source.sourceId];

    final placeholders = <_SourceManagementEntry?>[];
    final pendingVariants = <String, List<BrowsableComicSource>>{};
    for (final source in _sources) {
      if (source.sourceId.startsWith('mihon:')) {
        final key = mihonSourceGroupKey(source, ownerOf(source));
        final existing = pendingVariants[key];
        if (existing == null) {
          pendingVariants[key] = <BrowsableComicSource>[source];
          placeholders.add(null);
        } else {
          existing.add(source);
        }
        continue;
      }
      placeholders.add(_SourceManagementEntry.single(source));
    }
    final entries = <_SourceManagementEntry>[];
    for (final placeholder in placeholders) {
      if (placeholder != null) {
        entries.add(placeholder);
        continue;
      }
      // The next pending family in first-occurrence order fills this slot.
      final key = pendingVariants.keys.first;
      final variants = pendingVariants.remove(key)!;
      final group = groupMihonSourcesByLanguage(
        variants,
        preferredLanguage: preferredLanguage,
        pluginOwner: (sourceId) => ownerBySourceId[sourceId],
      ).single;
      entries.add(
        _SourceManagementEntry.family(
          group,
          _representativeOf(group),
        ),
      );
    }
    return entries;
  }

  BrowsableComicSource _representativeOf(MihonSourceLanguageGroup group) {
    BrowsableComicSource? best;
    DateTime? bestTime;
    for (final variant in [
      group.defaultSource,
      ...group.otherLanguages,
    ]) {
      final preference = _preference(variant);
      if (!preference.enabled) continue;
      final stamp = preference.lastEnabledAt ?? preference.updatedAt;
      if (best == null || stamp.isAfter(bestTime!)) {
        best = variant;
        bestTime = stamp;
      }
    }
    return best ?? group.defaultSource;
  }

  Widget _familyTile(BuildContext context, _SourceManagementEntry entry) {
    final family = entry.family!;
    final representative = entry.representative;
    final expanded = _expandedFamilies.contains(family.groupKey);
    final variants = <BrowsableComicSource>[
      ...family.otherLanguages,
      if (!family.otherLanguages.contains(representative))
        family.defaultSource,
    ].where((variant) => variant.sourceId != representative.sourceId).toList();
    return Column(
      children: <Widget>[
        _sourceTile(
          representative,
          iconTap: variants.isEmpty
              ? null
              : () => setState(() {
                    if (!_expandedFamilies.add(family.groupKey)) {
                      _expandedFamilies.remove(family.groupKey);
                    }
                  }),
          iconExpanded: expanded,
          onToggleOverride: (value) => unawaited(
            value
                ? _enableMihonVariant(
                    representative,
                    variants: [
                      representative,
                      ...variants,
                    ],
                  )
                : _toggle(representative, false),
          ),
        ),
        if (expanded)
          for (final variant in variants) ...<Widget>[
            _sourceTile(
              variant,
              nested: true,
              iconTap: null,
              onToggleOverride: (value) => unawaited(
                value
                    ? _enableMihonVariant(
                        variant,
                        variants: [representative, ...variants],
                      )
                    : _toggle(variant, false),
              ),
            ),
          ],
      ],
    );
  }

  Widget _sourceTile(
    BrowsableComicSource source, {
    bool nested = false,
    VoidCallback? iconTap,
    bool iconExpanded = false,
    ValueChanged<bool>? onToggleOverride,
  }) {
    final preference = _preference(source);
    final onChanged =
        onToggleOverride ?? (value) => unawaited(_toggle(source, value));
    final originIcon = Icon(
      source.sourceId.startsWith('mihon:')
          ? Icons.extension_outlined
          : source.sourceId.startsWith('venera:')
              ? Icons.javascript_outlined
              : Icons.public,
    );
    // Settings and language actions need their own semantics, rather than
    // being merged into the enabled switch's single action.
    return ListTile(
      key: ValueKey<String>('source-manager:${source.sourceId}'),
      contentPadding: EdgeInsets.fromLTRB(nested ? 40 : 16, 0, 12, 0),
      onTap: () => onChanged(!preference.enabled),
      trailing: Semantics(
        label: source.descriptor.name,
        child: Switch(value: preference.enabled, onChanged: onChanged),
      ),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The expandable family icon keeps the exact same 24px footprint as
          // the plain origin icon, so the representative row stays aligned
          // with single-source rows; only the collapsed state is highlighted.
          if (iconTap != null)
            Tooltip(
              message: iconExpanded ? '收起其他语言' : '展开其他语言',
              child: GestureDetector(
                onTap: iconTap,
                child: Icon(
                  source.sourceId.startsWith('mihon:')
                      ? Icons.extension_outlined
                      : source.sourceId.startsWith('venera:')
                          ? Icons.javascript_outlined
                          : Icons.public,
                  size: 24,
                  color: iconExpanded
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            )
          else
            originIcon,
          if (widget.appPreferences != null)
            IconButton(
              key: sourceSettingsEntryKey(source.sourceId),
              tooltip: '源设置',
              onPressed: () => unawaited(_openAppSourceSettings(source)),
              icon: const Icon(Icons.settings_outlined),
            ),
          if ((source.sourceId.startsWith('mihon:') ||
                  source.sourceId.startsWith('venera:')) &&
              sourceSupportsSettings(source))
            IconButton(
              key: sourcePropertiesEntryKey(source.sourceId),
              tooltip: '来源属性与登录',
              onPressed: () => unawaited(_openSourceProperties(source)),
              icon: const Icon(Icons.list_alt_outlined),
            ),
        ],
      ),
      title: Text(source.descriptor.name),
      subtitle: Text(
        '${source.descriptor.language} · ${source.descriptor.website.host}',
      ),
    );
  }

  Future<void> _openExternalRepository(
    ExternalComicPluginFormat format,
  ) async {
    final controller = _externalPlugins;
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
      _refreshExternalSources(_readExternalSources());
    }
  }

  void _refreshExternalSources(List<BrowsableComicSource> external) {
    _replaceExternalSources(external, notify: true);
  }

  void _replaceExternalSources(
    List<BrowsableComicSource> external, {
    required bool notify,
  }) {
    final nextExternalSourceIds = <String>{
      for (final source in external) source.sourceId,
    };
    final replacedSourceIds = <String>{
      ..._externalSourceIds,
      ...nextExternalSourceIds,
    };
    final builtIn = _sources.where(
      (source) => !replacedSourceIds.contains(source.sourceId),
    );
    final next = <BrowsableComicSource>[
      ...builtIn,
      ...external,
    ]..sort((left, right) => _preference(left).sortOrder.compareTo(
          _preference(right).sortOrder,
        ));
    void apply() {
      _sources = next;
      _externalSourceIds = nextExternalSourceIds;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _openAppSourceSettings(BrowsableComicSource source) async {
    final preferences = widget.appPreferences;
    if (preferences == null) return;
    final externalPlugins = _externalPlugins;
    final pluginId = externalPlugins?.ownerOfSource(source.sourceId);
    if (pluginId != null && externalPlugins != null) {
      final installedOwners = externalPlugins.installed
          .where((installed) => installed.plugin.pluginId == pluginId)
          .toList(growable: false);
      final installedOwner =
          installedOwners.length == 1 ? installedOwners.single : null;
      final knownSourceIds = <String>{
        source.sourceId,
        for (final candidate in _sources)
          if (externalPlugins.ownerOfSource(candidate.sourceId) == pluginId)
            candidate.sourceId,
        for (final installed in externalPlugins.installed)
          if (installed.plugin.pluginId == pluginId) ...<String>{
            ...installed.sourceIds,
            for (final descriptor in installed.plugin.sources)
              descriptor.sourceId,
            if (installed.plugin.format ==
                    ExternalComicPluginFormat.veneraJavaScript &&
                installed.sourceKey != null &&
                installed.sourceKey!.trim().isNotEmpty)
              'venera:${installed.sourceKey}',
          },
      };
      preferences.migratePluginTrustConflictingHistoricalCarriersToSources(
        pluginId,
        knownSourceIds,
        retirePluginOverride: installedOwner != null &&
            (installedOwner.sourceIds.isNotEmpty ||
                !installedOwner.plugin.requiresRuntimeDiscovery),
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceSettingsScreen(
          sourceId: source.sourceId,
          sourceName: source.descriptor.name,
          preferences: preferences,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSourceProperties(BrowsableComicSource source) async {
    await openComicSourceSettings(
      context,
      source: source,
      networkBridge: widget.networkBridge,
      onExternalSourcesChanged: widget.onExternalSourcesChanged,
    );
    if (mounted) {
      _refreshExternalSources(_readExternalSources());
    }
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

  @override
  Widget build(BuildContext context) {
    final entries = _buildManagementEntries(context);

    return Scaffold(
      key: sourceManagementScreenKey,
      appBar: AppBar(title: const Text('漫画源管理')),
      body: Column(
        children: <Widget>[
          if (_externalPlugins != null)
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
                  title: '漫画源 · 长按拖动排序',
                  icon: Icons.low_priority_outlined,
                  count: entries.length,
                ),
                if (entries.isEmpty)
                  const ListTile(title: Text('没有可用漫画源'))
                else
                  _managementList(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

}

final class _SourceFailure {
  const _SourceFailure({
    required this.summary,
    required this.guidance,
    required this.details,
    this.requiresSourceVerification = false,
    this.verificationUri,
    this.clearanceCookiePresent,
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
        guidance: error.details['clearanceCookiePresent'] == true
            ? '运行时请求已携带 cf_clearance 但站点仍返回挑战；不会再次自动打开 WebView，可手动重新验证或检查站点会话兼容性。'
            : '将自动打开一次 WebView。只要目标页已正常可访问，就同步完整浏览器 Cookie/UA 会话并重试；若仍失败，后续刷新不会反复跳 WebView，可使用手动验证入口。',
        details: details,
        requiresSourceVerification: true,
        verificationUri: switch (error.details['requestUrl']) {
          final String value => Uri.tryParse(value),
          _ => null,
        },
        clearanceCookiePresent:
            error.details['clearanceCookiePresent'] is bool
                ? error.details['clearanceCookiePresent'] as bool
                : null,
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
  final Uri? verificationUri;
  final bool? clearanceCookiePresent;

  bool get shouldAutoOpenVerification =>
      requiresSourceVerification && clearanceCookiePresent != true;
}

final class _SourceRetainedFailureBanner extends StatelessWidget {
  const _SourceRetainedFailureBanner({
    required this.failure,
    required this.onRetry,
    this.onOpenWebView,
    this.openingWebView = false,
  });

  final _SourceFailure failure;
  final VoidCallback onRetry;
  final VoidCallback? onOpenWebView;
  final bool openingWebView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                failure.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (onOpenWebView != null)
              TextButton(
                onPressed: openingWebView ? null : onOpenWebView,
                child: Text(openingWebView ? '打开中' : '网页验证'),
              ),
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );
  }
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
    this.onFrameReady,
    this.onDecodeFailure,
    this.onSourceVerificationRequired,
  });

  final Uri? uri;
  final Future<EncodedResourceSource> Function(Uri uri) loadSource;
  final int reloadToken;
  final Key verificationKey;
  final VoidCallback? onFrameReady;
  final ValueChanged<Future<EncodedResourceSource>>? onDecodeFailure;
  final VoidCallback? onSourceVerificationRequired;

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

final class _RemoteImageState extends State<_RemoteImage> {
  Future<EncodedResourceSource>? _source;

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
    _source = uri == null ? null : widget.loadSource(uri);
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
          return LayoutBuilder(
            builder: (context, constraints) {
              // Browse cards are deliberately small, but source responses can
              // be full-resolution covers. Without a decode bound every card
              // asks Flutter to decode the original image and a page of
              // covers can compete with scrolling/rasterization for several
              // frames. Keep the encoded source immutable while constraining
              // only the presentation decode to the actual card width.
              final logicalWidth = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : 132.0;
              final cacheWidth = (logicalWidth *
                      MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(64, 512)
                  .toInt();
              return StableArtworkImage(
                source: data,
                seed: widget.uri?.toString() ?? 'source-comic-cover',
                cacheWidth: cacheWidth,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                onFrameReady: widget.onFrameReady,
                onDecodeFailure: () {
                  if (snapshot.connectionState == ConnectionState.done &&
                      identical(_source, source)) {
                    widget.onDecodeFailure?.call(source);
                  }
                },
              );
            },
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
        return SoftArtworkPlaceholder(
          seed: widget.uri?.toString() ?? 'source-comic-cover',
        );
      },
    );
  }
}

bool _sameBrowsePage(
  List<SourceComicSummary> currentItems,
  int currentOffset,
  bool currentHasMore,
  int currentNextOffset,
  SourceBrowsePage next,
) {
  if (currentOffset != next.offset || currentHasMore != next.hasMore ||
      currentNextOffset != (next.nextOffset ?? next.offset + next.items.length)) {
    return false;
  }
  if (currentItems.length != next.items.length) return false;
  for (var index = 0; index < currentItems.length; index++) {
    final left = currentItems[index];
    final right = next.items[index];
    if (left.sourceId != right.sourceId ||
        left.comicId != right.comicId ||
        left.title != right.title ||
        left.coverUri != right.coverUri ||
        left.description != right.description ||
        left.contentRating != right.contentRating ||
        !_sameStringList(left.authors, right.authors) ||
        !_sameStringList(left.tags, right.tags)) {
      return false;
    }
  }
  return true;
}

bool _sameStringList(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

BrowsableComicSource? _sourceForId(
  List<BrowsableComicSource> sources,
  String sourceId,
) {
  for (final source in sources) {
    if (source.sourceId == sourceId) {
      return source;
    }
  }
  return null;
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
