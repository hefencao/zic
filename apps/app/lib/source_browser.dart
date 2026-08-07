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
import 'app_pull_to_refresh.dart';
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
const comicSourceSearchFabKey = ValueKey<String>('comic-source-search-fab');
const comicSourceSearchHistoryKey =
    ValueKey<String>('comic-source-search-history');
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

Color _comicSourceAccent(BrowsableComicSource source) {
  if (source.sourceId.startsWith('venera:')) {
    return Colors.blue;
  }
  if (source.sourceId.startsWith('mihon:')) {
    return Colors.green;
  }
  return Colors.orange;
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
    this.resolveSource,
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
  final Future<void> Function(
    BrowsableComicSource source,
    Uri url, {
    required bool cloudflareVerification,
  })? onOpenSourceWebView;
  final BrowsableComicSource? Function(String sourceId)? resolveSource;
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
    required this.selectedFilterIds,
  });

  final String? sectionId;
  final String query;
  final int offset;
  final Set<String> selectedFilterIds;
}

final class _ComicSourcesPageState extends State<ComicSourcesPage> {
  static const int _pageSize = 24;

  final TextEditingController _search = TextEditingController();
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
  List<SourceBrowseSection> _sections = const <SourceBrowseSection>[];
  String? _selectedSectionId;
  List<SourceSearchFilterOption> _searchFilters =
      const <SourceSearchFilterOption>[];
  Set<String> _selectedFilterIds = const <String>{};
  bool _searchExpanded = false;
  bool _refreshing = false;
  _SourceFailure? _failure;
  int _generation = 0;
  int _contentRevision = 0;
  int _artworkRetryRevision = 0;
  bool _recoveringSourceAccess = false;
  final Set<String> _verificationBrowserAttempts = <String>{};
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
    final resolved = widget.resolveSource?.call(id);
    if (resolved != null) {
      return resolved;
    }
    return _sourceForId(widget.sources, id);
  }

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
      selectedFilterIds: Set<String>.unmodifiable(_selectedFilterIds),
    );
  }

  void _restoreTargetProjection(BrowsableComicSource? source) {
    if (source == null) {
      setState(() {
        _projectionSourceId = null;
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
    _selectedSectionId = remembered?.sectionId;
    _selectedFilterIds = remembered?.selectedFilterIds ?? const <String>{};
    _search.value = TextEditingValue(
      text: _query,
      selection: TextSelection.collapsed(offset: _query.length),
    );
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    var cached = cache?.peekBrowsePage(
      sectionId: _selectedSectionId,
      query: _query,
      offset: _pageOffset,
      limit: _pageSize,
      selectedFilterIds: _selectedFilterIds,
    );
    if (cached == null) {
      final latest = cache?.peekLatestBrowseProjection();
      if (latest != null) {
        _selectedSectionId = latest.sectionId;
        _query = latest.query;
        _pageOffset = latest.offset;
        _selectedFilterIds = latest.selectedFilterIds;
        _search.value = TextEditingValue(
          text: _query,
          selection: TextSelection.collapsed(offset: _query.length),
        );
        cached = latest.page;
      }
    }
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
        _applyBrowsePage(cached!, sourceId: source.sourceId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() => unawaited(_loadSource()));
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
    final activeSourceReplaced = widget.activeSourceId != null &&
        !identical(
          _sourceForId(oldWidget.sources, widget.activeSourceId!),
          _sourceForId(widget.sources, widget.activeSourceId!),
        );
    if (oldWidget.activeSourceId != widget.activeSourceId ||
        !_sameSourceIds(oldWidget.sources, widget.sources) ||
        activeSourceReplaced) {
      _rememberSourceView(oldWidget.activeSourceId);
      _sections = const <SourceBrowseSection>[];
      _searchFilters = const <SourceSearchFilterOption>[];
      _restoreTargetProjection(_activeSource);
      if (!_recoveringSourceAccess) {
        scheduleMicrotask(() => unawaited(_loadSource()));
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
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
    var filters = const <SourceSearchFilterOption>[];
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
        // Search filters are optional. A plugin with an unsupported custom
        // filter subtype must not make its Popular/Latest browse unusable.
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
    final selected = sections.any(
      (section) => section.sectionId == _selectedSectionId,
    )
        ? _selectedSectionId
        : (sections.isEmpty ? null : sections.first.sectionId);
    final availableFilterIds = filters.map((option) => option.filterId).toSet();
    final selectedFilters = <String>{
      ...filters.where((option) => option.selected).map(
            (option) => option.filterId,
          ),
      ..._selectedFilterIds.where(availableFilterIds.contains),
    };
    setState(() {
      _sections = sections;
      _selectedSectionId = selected;
      _searchFilters = filters;
      _selectedFilterIds = Set<String>.unmodifiable(selectedFilters);
    });
    return _reload(
      forceRefresh: forceRefresh,
      allowVerificationFallback: allowVerificationFallback,
      offset: browseOffset,
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
        sectionId: _selectedSectionId,
        query: _query,
        offset: offset,
        limit: _pageSize,
        selectedFilterIds: _selectedFilterIds,
      );
    }
    final filterable = source is FilterableBrowsableComicSource
        ? source as FilterableBrowsableComicSource
        : null;
    if (filterable != null && _selectedFilterIds.isNotEmpty) {
      return filterable.browseWithFilters(
        sectionId: _selectedSectionId,
        query: _query,
        offset: offset,
        limit: _pageSize,
        selectedFilterIds: _selectedFilterIds,
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
    _contentRevision++;
    _projectionSourceId = sourceId ?? _activeSource?.sourceId;
    _items = page.items;
    _hasMore = page.hasMore;
    _pageOffset = page.offset;
    _nextOffset = page.offset + page.items.length;
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
        _nextOffset = 0;
        _failure = null;
      });
      return false;
    }
    final requestedOffset = (offset ?? _pageOffset).clamp(0, 1 << 30).toInt();
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    final cached = forceRefresh
        ? null
        : cache?.peekBrowsePage(
            sectionId: _selectedSectionId,
            query: _query,
            offset: requestedOffset,
            limit: _pageSize,
            selectedFilterIds: _selectedFilterIds,
          );
    final hasCached = cached != null;
    final projectionMatchesSource = _projectionSourceId == source.sourceId;
    final hasVisibleItems = projectionMatchesSource && _items.isNotEmpty;
    final cachedChanged = cached != null &&
        (!projectionMatchesSource ||
            !_sameBrowsePage(_items, _pageOffset, _hasMore, cached));
    final startedMicros = _traceClock.elapsedMicroseconds;
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'browse-start',
      source,
      payload: <String, Object?>{
        'forceRefresh': forceRefresh,
        'cacheHit': hasCached,
        'cacheChanged': cachedChanged,
        'queryLength': _query.length,
        'sectionId': _selectedSectionId,
        'offset': requestedOffset,
        'limit': _pageSize,
        'filterCount': _selectedFilterIds.length,
      },
    );
    if (forceRefresh) {
      invalidateCachedSearch(source);
    }
    setState(() {
      _failure = null;
      if (forceRefresh) _artworkRetryRevision++;
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
      final page = cache != null
          ? await cache.refreshBrowsePage(
              sectionId: _selectedSectionId,
              query: _query,
              offset: requestedOffset,
              limit: _pageSize,
              selectedFilterIds: _selectedFilterIds,
            )
          : await _loadBrowsePage(
              source,
              offset: requestedOffset,
              forceRefresh: forceRefresh,
            );
      if (!mounted || generation != _generation) return false;
      final changed = !_sameBrowsePage(
        _items,
        _pageOffset,
        _hasMore,
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
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'itemCount': page.items.length,
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
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
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

  String _exclusiveFilterGroup(String filterId) {
    final select = filterId.indexOf(':select:');
    if (select >= 0) return filterId.substring(0, select);
    if (filterId.endsWith(':include') || filterId.endsWith(':exclude')) {
      return filterId.substring(0, filterId.lastIndexOf(':'));
    }
    return filterId;
  }

  void _toggleSearchFilter(SourceSearchFilterOption option, bool selected) {
    final next = _selectedFilterIds.toSet();
    final group = _exclusiveFilterGroup(option.filterId);
    if (selected) {
      next.removeWhere(
        (filterId) =>
            filterId != option.filterId &&
            _exclusiveFilterGroup(filterId) == group,
      );
      next.add(option.filterId);
    } else {
      next.remove(option.filterId);
    }
    setState(() {
      _selectedFilterIds = Set<String>.unmodifiable(next);
      _pageOffset = 0;
    });
    unawaited(_reload(offset: 0));
  }

  void _collapseSearch() {
    if (!_searchExpanded) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _searchExpanded = false);
  }

  bool _handleSourceScroll(ScrollNotification notification) {
    if (_searchExpanded &&
        (notification is ScrollStartNotification ||
            notification is UserScrollNotification)) {
      scheduleMicrotask(_collapseSearch);
    }
    return false;
  }

  void _submitSearch(String value) {
    final normalized = value.trim();
    _query = normalized;
    _pageOffset = 0;
    if (normalized.isNotEmpty) {
      widget.onSearchCommitted?.call(normalized);
    }
    _collapseSearch();
    unawaited(_reload(offset: 0));
  }

  void _selectBrowseSection(String sectionId) {
    if (_selectedSectionId == sectionId) return;
    setState(() {
      _selectedSectionId = sectionId;
      _pageOffset = 0;
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
        if (!_searchExpanded) return true;
        _collapseSearch();
        return false;
      },
      child: Column(
        key: comicSourcesPageKey,
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _buildBody(source)),
              if (_refreshing)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Positioned(
                left: 12,
                bottom: 12,
                child: _buildFloatingSearch(context, source),
              ),
            ],
          ),
        ),
          _SourceSwitcher(
            sources: widget.sources,
            activeSourceId: widget.activeSourceId,
            onSelected: widget.onSourceSelected,
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingSearch(
    BuildContext context,
    BrowsableComicSource? source,
  ) {
    final maxWidth = MediaQuery.sizeOf(context).width;
    final expandedWidth = (maxWidth - 24).clamp(260.0, 480.0).toDouble();
    if (!_searchExpanded) {
      return FloatingActionButton.small(
        key: comicSourceSearchFabKey,
        heroTag: 'comic-source-search',
        tooltip: '搜索漫画源',
        onPressed: source == null
            ? null
            : () => setState(() => _searchExpanded = true),
        child: const Icon(Icons.search),
      );
    }
    final history = widget.searchHistory;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _collapseSearch(),
      child: Material(
        key: comicSourceSearchHistoryKey,
        elevation: 6,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
        width: expandedWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (history.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
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
                                selection: TextSelection.collapsed(
                                  offset: query.length,
                                ),
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
              ),
            if (_searchFilters.isNotEmpty)
              Container(
                key: comicSourceFilterBarKey,
                constraints: const BoxConstraints(maxHeight: 128),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final option in _searchFilters)
                        FilterChip(
                          key: comicSourceFilterKey(option.filterId),
                          label: Text(option.label),
                          selected: _selectedFilterIds.contains(option.filterId),
                          onSelected: (selected) =>
                              _toggleSearchFilter(option, selected),
                        ),
                    ],
                  ),
                ),
              ),
            SearchBar(
              key: comicSourceSearchKey,
              controller: _search,
              autoFocus: true,
              enabled: source != null,
              hintText:
                  source == null ? '请先启用漫画源' : '搜索 ${source.descriptor.name}',
              leading: IconButton(
                tooltip: '收起搜索',
                onPressed: _collapseSearch,
                icon: const Icon(Icons.chevron_left),
              ),
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
          ],
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
            if (_sections.length > 1)
              SliverToBoxAdapter(
                child: SizedBox(
                  key: comicSourceCategoryBarKey,
                  height: 52,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    scrollDirection: Axis.horizontal,
                    itemCount: _sections.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final section = _sections[index];
                      return ChoiceChip(
                        key: comicSourceCategoryKey(section.sectionId),
                        label: Text(section.label),
                        selected: section.sectionId == _selectedSectionId,
                        showCheckmark: false,
                        onSelected: (_) =>
                            _selectBrowseSection(section.sectionId),
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
                        key: sourceComicCardKey(source.sourceId, comic.comicId),
                        source: source,
                        comic: comic,
                        reloadToken: Object.hash(_contentRevision, _artworkRetryRevision),
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
                    childCount: _items.length,
                  ),
                ),
              ),
            if (_items.isNotEmpty || _pageOffset > 0)
              SliverToBoxAdapter(
                child: _SourcePager(
                  page: (_pageOffset ~/ _pageSize) + 1,
                  hasPrevious: _pageOffset > 0,
                  hasNext: _hasMore,
                  onPrevious: () => unawaited(
                    _goToPage(
                      (_pageOffset - _pageSize)
                          .clamp(0, 1 << 30)
                          .toInt(),
                    ),
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
        child: sources.isEmpty
            ? const SizedBox(
                height: 58,
                child: Center(child: Text('没有已启用的漫画源')),
              )
            : SizedBox(
                height: 58,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: sources.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final accent = _comicSourceAccent(source);
                    final selected = source.sourceId == activeSourceId;
                    return ChoiceChip(
                      key: comicSourceChoiceKey(source.sourceId),
                      label: Text(source.descriptor.name),
                      selected: selected,
                      showCheckmark: false,
                      selectedColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: .7)),
                      labelStyle: selected
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                            )
                          : TextStyle(color: accent),
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
    this.resolveSource,
    this.onSearchMetadata,
    this.loadVersionState,
    this.onViewVersion,
    this.onMigrateVersion,
    this.sameComicIdentity,
    this.previewMaxItemsPerRow = 4,
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
  final details.ComicDetailsSourceResolver? resolveSource;
  final details.ComicDetailsMetadataSearch? onSearchMetadata;
  final details.ComicDetailsVersionStateLoader? loadVersionState;
  final details.ComicDetailsVersionViewer? onViewVersion;
  final details.ComicDetailsVersionMigrator? onMigrateVersion;
  final details.ComicDetailsIdentityMatcher? sameComicIdentity;
  final int previewMaxItemsPerRow;
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
      resolveSource: resolveSource,
      onSearchMetadata: onSearchMetadata,
      loadVersionState: loadVersionState,
      onViewVersion: onViewVersion,
      onMigrateVersion: onMigrateVersion,
      previewMaxItemsPerRow: previewMaxItemsPerRow,
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

final class _RemoteImageState extends State<_RemoteImage>
    with WidgetsBindingObserver {
  Future<EncodedResourceSource>? _source;
  bool _failed = false;
  Object? _lastError;
  final ArtworkRetryController _retry = ArtworkRetryController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant _RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        (oldWidget.reloadToken != widget.reloadToken && _failed)) {
      _restartLoad(resetRetryBudget: true);
    }
  }

  bool _canRetry(Object error) =>
      error is! Failure || error.code != ErrorCode.sourceVerificationRequired;

  void _load({
    bool resetRetryBudget = false,
    bool preserveFailurePlaceholder = false,
  }) {
    if (resetRetryBudget) _retry.reset();
    final uri = widget.uri;
    if (!preserveFailurePlaceholder) {
      _failed = false;
      _lastError = null;
    }
    _source = uri == null ? null : _loadSource(uri);
  }

  Future<EncodedResourceSource> _loadSource(Uri uri) async {
    try {
      return await widget.loadSource(uri);
    } on Object catch (error, stackTrace) {
      _failed = true;
      _lastError = error;
      if (_canRetry(error)) _retry.schedule(() => _restartLoad());
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _restartLoad({bool resetRetryBudget = false}) {
    if (!mounted) return;
    setState(() => _load(
          resetRetryBudget: resetRetryBudget,
          preserveFailurePlaceholder: true,
        ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final error = _lastError;
    if (state == AppLifecycleState.resumed &&
        _failed &&
        (error == null || _canRetry(error))) {
      _retry.retryNow(
        () => _restartLoad(resetRetryBudget: true),
        resetBudget: true,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry.dispose();
    super.dispose();
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
          return RecoverableArtworkImage(
            image: encodedResourceImageProvider(data),
            seed: widget.uri?.toString() ?? 'source-comic-cover',
            fit: BoxFit.cover,
            onFrameReady: () {
              _failed = false;
              _lastError = null;
              _retry.reset();
            },
            onDecodeFailure: () => _failed = true,
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
  SourceBrowsePage next,
) {
  if (currentOffset != next.offset || currentHasMore != next.hasMore) {
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
