import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:network_bridge/network_bridge.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';

import 'package:downloads/downloads.dart';
import 'app_pull_to_refresh.dart';
import 'artwork_placeholder.dart';
import 'comic_details.dart' as details;
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'external_plugin_repository_model.dart';
import 'external_plugin_repository_screen.dart';
import 'external_source_settings_screen.dart';
import 'startup_platform.dart';

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
Key sourceComicCardKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic:$sourceId\u0000$comicId');
Key sourceComicCoverVerificationKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-verify:$sourceId\u0000$comicId');
Key sourceComicShelfMarkerKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-shelf:$sourceId\u0000$comicId');
Key sourceComicShelfDimKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-shelf-dim:$sourceId\u0000$comicId');
Key sourceComicUpdateMarkerKey(String sourceId, String comicId) =>
    ValueKey<String>('source-comic-update:$sourceId\u0000$comicId');
Key sourceChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

typedef SourceComicCoverLoader = Future<EncodedResourceSource> Function(
  BrowsableComicSource source,
  SourceComicSummary comic,
  Uri uri,
);

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
  Future<void> Function()? onExternalSourcesChanged,
}) async {
  if (!sourceSupportsSettings(source)) {
    return;
  }
  await attachAndroidPlugin('network_bridge');
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
    required this.filterState,
    required this.filterViewActive,
  });

  final String? sectionId;
  final String query;
  final int offset;
  final SourceSearchFilterState filterState;
  final bool filterViewActive;
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
  List<SourceSearchFilterNode> _searchFilters =
      const <SourceSearchFilterNode>[];
  SourceSearchFilterState _filterState = const <String, Object?>{};
  bool _filterViewActive = false;
  bool _searchExpanded = false;
  bool _refreshing = false;
  _SourceFailure? _failure;
  int _generation = 0;
  int _artworkRetryRevision = 0;
  final Map<String, Future<EncodedResourceSource>> _cardCoverFutures =
      <String, Future<EncodedResourceSource>>{};
  bool _recoveringSourceAccess = false;
  final Set<String> _verificationBrowserAttempts = <String>{};
  final Stopwatch _traceClock = Stopwatch()..start();

  void _recordSourceTrace(
    TraceEventKind kind,
    String stage,
    BrowsableComicSource source, {
    String? identityHash,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
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
      filterState: Map<String, Object?>.unmodifiable(_filterState),
      filterViewActive: _filterViewActive,
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
    _filterState = remembered?.filterState ?? const <String, Object?>{};
    _filterViewActive = remembered?.filterViewActive ?? false;
    _search.value = TextEditingValue(
      text: _query,
      selection: TextSelection.collapsed(offset: _query.length),
    );
    final cache = source is CachedSourceBrowseProjection
        ? source as CachedSourceBrowseProjection
        : null;
    final cached = remembered == null
        ? null
        : cache?.peekBrowsePage(
            sectionId: _requestSectionId,
            query: _query,
            offset: _pageOffset,
            limit: _pageSize,
            filterState: _filterState,
            useFilters: _filterViewActive,
          );
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
      _searchFilters = const <SourceSearchFilterNode>[];
      _restoreTargetProjection(_activeSource);
      if (!_recoveringSourceAccess) {
        scheduleMicrotask(() => unawaited(_loadSource()));
      }
    }
  }

  @override
  void dispose() {
    _cardCoverFutures.clear();
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
    setState(() {
      _sections = sections;
      _selectedSectionId = selected;
      _searchFilters = filters;
      _filterState = Map<String, Object?>.unmodifiable(retainedFilterState);
      if (filters.isEmpty) _filterViewActive = false;
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
            sectionId: _requestSectionId,
            query: _query,
            offset: requestedOffset,
            limit: _pageSize,
            filterState: _filterState,
            useFilters: _filterViewActive,
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
      if (forceRefresh) _cardCoverFutures.clear();
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
    final future = _loadSourceCardCoverUncached(source, comic, uri, identity);
    _cardCoverFutures[identity] = future;
    return future;
  }

  Future<EncodedResourceSource> _loadSourceCardCoverUncached(
    BrowsableComicSource source,
    SourceComicSummary comic,
    Uri uri,
    String identity,
  ) async {
    _recordSourceTrace(
      TraceEventKind.retryScheduled,
      'cover-load-start',
      source,
      identityHash: identity,
      payload: <String, Object?>{'uriHash': uri.toString().hashCode},
    );
    try {
      final encoded = await widget.loadCover(source, comic, uri);
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
      _cardCoverFutures.remove(identity);
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
    final initial = Map<String, Object?>.from(_filterState);
    final selected = await showModalBottomSheet<SourceSearchFilterState>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final draft = Map<String, Object?>.from(initial);
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
    if (_selectedSectionId == sectionId && !_filterViewActive) return;
    setState(() {
      _selectedSectionId = sectionId;
      _filterViewActive = false;
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
            externalPlugins: widget.externalPlugins,
            onExternalPluginRetry: widget.onExternalPluginRetry,
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
                        onCoverDecodeFailure: () => _recordSourceTrace(
                          TraceEventKind.taskFailed,
                          'cover-decode-failed',
                          source,
                          identityHash: _sourceCoverIdentity(source, comic),
                          payload: const <String, Object?>{
                            'failureLayer': 'presentation-decode',
                          },
                        ),
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
    final plugins = controller.installed.where((plugin) {
      final failure = controller.activationFailures[plugin.plugin.pluginId];
      // A terminal activation failure is intentionally not presented as an
      // enabled source control. Recoverable failures stay visible so a tap
      // can retry the already-owned payload.
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
          SnackBar(content: Text('$displayName 加载失败：$error')),
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
      child: ChoiceChip(
        key: comicSourcePluginChoiceKey(pluginId),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        selected: selected,
        showCheckmark: false,
        selectedColor: accent,
        side: BorderSide(color: accent.withValues(alpha: .7)),
        labelStyle: selected
            ? TextStyle(color: Theme.of(context).colorScheme.onPrimary)
            : TextStyle(color: accent),
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
    // A plugin control represents all of that plugin's sources. Keep the
    // original source switcher as the only bottom control and collapse the
    // represented source chips instead of rendering a second set beside it.
    final sourceControls = controller == null
        ? widget.sources
        : widget.sources
            .where(
              (source) => !visiblePluginIds.contains(
                controller.ownerOfSource(source.sourceId),
              ),
            )
            .toList(growable: false);
    final itemCount = sourceControls.length + plugins.length;
    return Material(
      key: comicSourceSwitcherKey,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: itemCount == 0
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
                  itemCount: itemCount,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index < plugins.length) {
                      return _pluginChip(
                        context,
                        controller!,
                        plugins[index],
                      );
                    }
                    final source = sourceControls[index - plugins.length];
                    final accent = _comicSourceAccent(source);
                    final selected = source.sourceId == widget.activeSourceId;
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
                      onSelected: (_) => widget.onSelected(source.sourceId),
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
  final SourceComicCoverLoader loadCover;
  final VoidCallback onCoverFrameReady;
  final VoidCallback onCoverDecodeFailure;
  final VoidCallback onTap;
  final VoidCallback? onOpenUpdate;
  final VoidCallback? onSourceVerificationRequired;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      key: sourceComicCardKey(source.sourceId, comic.comicId),
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
    this.artworkIdentity,
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.resolveSource,
    this.onSearchMetadata,
    this.onMigrateSource,
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
  final details.ComicDetailsArtworkLoader loadCover;
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
  final String? artworkIdentity;
  final details.ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final details.ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final details.ComicDetailsSourceResolver? resolveSource;
  final details.ComicDetailsMetadataSearch? onSearchMetadata;
  final details.ComicDetailsSourceMigrator? onMigrateSource;
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
      artworkIdentity: artworkIdentity,
      onOpenSourceWebView: onOpenSourceWebView,
      onOpenSourceSettings: onOpenSourceSettings,
      resolveSource: resolveSource,
      onSearchMetadata: onSearchMetadata,
      onMigrateSource: onMigrateSource,
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
    this.onFrameReady,
    this.onDecodeFailure,
    this.onSourceVerificationRequired,
  });

  final Uri? uri;
  final Future<EncodedResourceSource> Function(Uri uri) loadSource;
  final int reloadToken;
  final Key verificationKey;
  final VoidCallback? onFrameReady;
  final VoidCallback? onDecodeFailure;
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
                onDecodeFailure: widget.onDecodeFailure,
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
