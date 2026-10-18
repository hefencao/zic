part of 'source_browser.dart';

const comicTitleSearchPageKey = ValueKey<String>('comic-title-search-page');
const comicTitleSearchInputKey = ValueKey<String>('comic-title-search-input');
const comicTitleSearchAllKey = ValueKey<String>('comic-title-search-all');
const comicTitleSearchExactKey = ValueKey<String>('comic-title-search-exact');
const comicTitleSearchEmptyKey = ValueKey<String>('comic-title-search-empty');
const comicTitleSearchNativeIdKey = ValueKey<String>('comic-title-search-native-id');
Key comicTitleSearchGroupKey(String sourceId) =>
    ValueKey<String>('comic-title-search-group:$sourceId');

/// A separate search route; each source keeps its own read-only request result.
final class ComicTitleSearchPage extends StatefulWidget {
  const ComicTitleSearchPage({
    required this.query,
    required this.sources,
    required this.loadCover,
    required this.onOpenComic,
    this.resolveSource,
    this.isInShelf,
    this.hasUpdate,
    this.onOpenUpdate,
    this.onOpenSourceWebView,
    this.onSearchCommitted,
    this.onPrepareSources,
    this.title,
    this.inputLabel = '搜索漫画',
    this.header,
    this.onSelectNativeId,
    this.isComicVisible,
    super.key,
  });

  final String query;
  final List<BrowsableComicSource> sources;
  final SourceComicCoverLoader loadCover;
  final Future<void> Function(BrowsableComicSource, SourceComicSummary)
      onOpenComic;
  final BrowsableComicSource? Function(String sourceId)? resolveSource;
  final SourceComicShelfResolver? isInShelf;
  final SourceComicUpdateResolver? hasUpdate;
  final SourceComicUpdateOpener? onOpenUpdate;
  final Future<void> Function(BrowsableComicSource, Uri,
      {required bool cloudflareVerification})? onOpenSourceWebView;
  final ValueChanged<String>? onSearchCommitted;
  final VoidCallback? onPrepareSources;
  final String? title;
  final String inputLabel;
  final Widget? header;
  final Future<void> Function(BrowsableComicSource, String)? onSelectNativeId;
  final bool Function(BrowsableComicSource, SourceComicSummary)? isComicVisible;

  @override
  State<ComicTitleSearchPage> createState() => _ComicTitleSearchPageState();
}

final class _TitleSourceResult {
  const _TitleSourceResult({this.page, this.failure});
  final SourceBrowsePage? page;
  final _SourceFailure? failure;
}

final class _TitleSourceSearch {
  _TitleSourceSearch(this.source);
  final BrowsableComicSource source;
  final List<int> offsets = <int>[0];
  int pageIndex = 0;
  bool verifying = false;
  Future<_TitleSourceResult>? result;
  _TitleSourceResult? completed;
  int requestRevision = 0;
}

final class _ComicTitleSearchPageState extends State<ComicTitleSearchPage> {
  late final TextEditingController _input;
  late String _query;
  List<_TitleSourceSearch> _groups = <_TitleSourceSearch>[];
  final Set<String> _knownSourceIds = <String>{};
  final Set<String> _selectedSourceIds = <String>{};
  bool _hideEmptySources = false;
  bool _exactTitle = false;
  String? _nativeIdSourceId;

  List<BrowsableComicSource> get _sources {
    final seen = <String>{};
    return <BrowsableComicSource>[
      for (final source in widget.sources)
        if (seen.add(source.sourceId)) source,
    ];
  }

  @override
  void initState() {
    super.initState();
    _query = widget.query.trim();
    _input = TextEditingController(text: _query);
    _startSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPrepareSources?.call();
    });
  }

  @override
  void didUpdateWidget(covariant ComicTitleSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSources();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  BrowsableComicSource _active(BrowsableComicSource source) {
    final resolved = widget.resolveSource?.call(source.sourceId);
    if (resolved != null) return resolved;
    for (final candidate in widget.sources) {
      if (candidate.sourceId == source.sourceId) return candidate;
    }
    return source;
  }

  Future<_TitleSourceResult> _search(_TitleSourceSearch group) async {
    final source = _active(group.source);
    final query = _query;
    final offset = group.offsets[group.pageIndex];
    try {
      final page = await source.browse(query: query, offset: offset, limit: 24);
      return _TitleSourceResult(page: _canonicalSourceBrowsePage(source, page));
    } on Object catch (error, stackTrace) {
      return _TitleSourceResult(failure: _SourceFailure.capture(error, stackTrace));
    }
  }

  void _startSearch() {
    _groups = <_TitleSourceSearch>[];
    _syncSources();
  }

  void _syncSources() {
    final previous = <String, _TitleSourceSearch>{
      for (final group in _groups) group.source.sourceId: group,
    };
    final sources = _sources;
    final available = sources.map((source) => source.sourceId).toSet();
    for (final sourceId in available) {
      if (_knownSourceIds.add(sourceId)) _selectedSourceIds.add(sourceId);
    }
    _knownSourceIds.retainAll(available);
    _selectedSourceIds.retainAll(available);
    if (_nativeIdSourceId != null && (_selectedSourceIds.length != 1 ||
        !_selectedSourceIds.contains(_nativeIdSourceId))) {
      _nativeIdSourceId = null;
      _input.text = _query;
    }
    _groups = <_TitleSourceSearch>[
      for (final source in sources)
        if (source.descriptor.supportsSearch)
          previous[source.sourceId] ?? _TitleSourceSearch(source),
    ];
    for (final group in _groups) {
      if (_query.isNotEmpty && _selectedSourceIds.contains(group.source.sourceId) &&
          group.result == null) {
        _load(group);
      }
    }
  }

  void _load(_TitleSourceSearch group) {
    final revision = ++group.requestRevision;
    group.completed = null;
    group.result = _search(group).then((result) {
      if (mounted && _groups.contains(group) && group.requestRevision == revision) {
        setState(() => group.completed = result);
      }
      return result;
    });
  }

  void _selectSource(String sourceId, bool selected) {
    setState(() {
      if (selected) {
        _selectedSourceIds.add(sourceId);
      } else {
        _selectedSourceIds.remove(sourceId);
      }
      _syncSources();
    });
  }

  void _selectAll(bool selected) {
    setState(() {
      _selectedSourceIds.clear();
      if (selected) _selectedSourceIds.addAll(_sources.map((source) => source.sourceId));
      _syncSources();
    });
  }

  void _toggleNativeId(BrowsableComicSource source) {
    setState(() {
      _nativeIdSourceId = _nativeIdSourceId == null ? source.sourceId : null;
      _input.text = _nativeIdSourceId == null ? _query : '';
    });
  }

  List<SourceComicSummary> _visibleItems(
    BrowsableComicSource source,
    SourceBrowsePage page,
  ) {
    final title = _normalizedSearchTitle(_query);
    return page.items.where((comic) =>
        (widget.isComicVisible?.call(source, comic) ?? true) &&
        (!_exactTitle || _normalizedSearchTitle(comic.title) == title)).toList();
  }

  bool _emptySource(_TitleSourceSearch group) {
    final page = group.completed?.page;
    // An empty intermediate page cannot prove that this source has no result.
    return page != null && group.pageIndex == 0 && !page.hasMore &&
        _visibleItems(_active(group.source), page).isEmpty;
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (_nativeIdSourceId case final sourceId?) {
      final source = _sources.where((source) => source.sourceId == sourceId).firstOrNull;
      if (source != null) unawaited(widget.onSelectNativeId?.call(_active(source), query));
      return;
    }
    widget.onSearchCommitted?.call(query);
    setState(() {
      _query = query;
      _startSearch();
    });
  }

  void _reload(_TitleSourceSearch group) {
    if (!mounted || !_groups.contains(group) ||
        !_selectedSourceIds.contains(group.source.sourceId)) return;
    setState(() {
      _load(group);
    });
  }

  void _previous(_TitleSourceSearch group) {
    setState(() {
      group.pageIndex--;
      _load(group);
    });
  }

  void _next(_TitleSourceSearch group, SourceBrowsePage page) {
    setState(() {
      final offset = page.nextOffset ?? page.offset + page.items.length;
      group.offsets.removeRange(group.pageIndex + 1, group.offsets.length);
      group.offsets.add(offset);
      group.pageIndex++;
      _load(group);
    });
  }

  Future<void> _verify(_TitleSourceSearch group, Uri? uri) async {
    final open = widget.onOpenSourceWebView;
    if (open == null || group.verifying) return;
    setState(() => group.verifying = true);
    try {
      final source = _active(group.source);
      await open(source, uri ?? source.descriptor.website,
          cloudflareVerification: true);
      _reload(group);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showSourceFailureSnackBar(context, failure: _SourceFailure.capture(error, stackTrace),
            prefix: 'WebView 访问失败');
      }
    } finally {
      if (mounted && _groups.contains(group)) {
        setState(() => group.verifying = false);
      }
    }
  }

  Widget _group(_TitleSourceSearch group) {
    final source = _active(group.source);
    return FutureBuilder<_TitleSourceResult>(
      key: ValueKey<(String, String)>((source.sourceId, _query)),
      future: group.result,
      initialData: group.completed,
      builder: (context, snapshot) {
        final result = group.completed ??
            (snapshot.connectionState == ConnectionState.done ? snapshot.data : null);
        final complete = result != null;
        final page = result?.page;
        final failure = result?.failure;
        final items = page == null ? null : _visibleItems(source, page);
        return Padding(
          key: comicTitleSearchGroupKey(source.sourceId),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (_comicSourcePluginIcon(_comicSourcePluginFormat(source.sourceId))
                      case final icon?) ...<Widget>[
                    icon,
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: Text(source.descriptor.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: _comicSourceAccent(source),
                      ))),
                  IconButton(
                    tooltip: '上一页',
                    onPressed: complete && group.pageIndex > 0
                        ? () => _previous(group) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${group.pageIndex + 1}'),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: page?.hasMore == true
                        ? () => _next(group, page!) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (!complete)
                const Padding(padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()))
              else if (failure != null)
                _SourceRetainedFailureBanner(
                  failure: failure,
                  onRetry: () => _reload(group),
                  onOpenWebView: failure.requiresSourceVerification &&
                          widget.onOpenSourceWebView != null
                      ? () => unawaited(_verify(group, failure.verificationUri))
                      : null,
                  openingWebView: group.verifying,
                )
              else if (items == null || items.isEmpty)
                Padding(padding: const EdgeInsets.all(20), child: Text(
                    _exactTitle ? '当前页没有完全一致的标题' : '没有搜索结果'))
              else
                SizedBox(
                  height: 224,
                  child: ListView.separated(
                    key: ValueKey<(String, String, int)>((
                      source.sourceId, _query, group.offsets[group.pageIndex])),
                    scrollDirection: Axis.horizontal,
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final comic = items[index];
                      final active = _active(source);
                      return SizedBox(
                        width: 132,
                        child: _SourceComicCard(
                          key: ValueKey<String>(_stableSourceComicIdentity(active, comic.comicId)),
                          source: active,
                          comic: comic,
                          inShelf: widget.isInShelf?.call(active, comic) ?? false,
                          hasUpdate: widget.hasUpdate?.call(active, comic) ?? false,
                          reloadToken: 0,
                          loadCover: widget.loadCover,
                          onCoverFrameReady: () {},
                          onCoverDecodeFailure: (_) {},
                          onSourceVerificationRequired: widget.onOpenSourceWebView == null
                              ? null : () => unawaited(_verify(group, null)),
                          onOpenUpdate: widget.onOpenUpdate == null ? null
                              : () => unawaited(widget.onOpenUpdate!(active, comic)),
                          onTap: () => unawaited(widget.onOpenComic(active, comic)),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final emptySources = <String>{
      if (_hideEmptySources)
        for (final group in _groups)
          if (_emptySource(group)) group.source.sourceId,
    };
    final groups = _groups.where((group) => _query.isNotEmpty &&
        _selectedSourceIds.contains(group.source.sourceId) &&
        !emptySources.contains(group.source.sourceId)).toList();
    final selectedSources = sources.where((source) =>
        _selectedSourceIds.contains(source.sourceId)).toList(growable: false);
    final single = selectedSources.length == 1 ? selectedSources.single : null;
    final nativeId = _nativeIdSourceId != null;
    final allSelected = sources.isNotEmpty && selectedSources.length == sources.length;
    return Scaffold(
      key: comicTitleSearchPageKey,
      appBar: AppBar(title: Text(widget.title ?? '聚合搜索：$_query')),
      body: Column(children: <Widget>[
        Expanded(child: ListView(
          children: <Widget>[
            if (widget.header != null) widget.header!,
            if (groups.isEmpty)
              Padding(padding: const EdgeInsets.all(20), child: Text(
                  _query.isEmpty ? '输入标题开始搜索'
                      : selectedSources.isEmpty ? '选择来源开始搜索'
                      : emptySources.isNotEmpty ? '所选来源暂无匹配结果'
                      : '没有可搜索的漫画源')),
            for (final group in groups) _group(group),
          ],
        )),
        Material(
          elevation: 3,
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: <Widget>[
                Expanded(child: TextField(
                  key: comicTitleSearchInputKey,
                  controller: _input,
                  textInputAction: nativeId ? TextInputAction.go : TextInputAction.search,
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    labelText: nativeId ? '原生 ID · ${single?.descriptor.name ?? ''}' : widget.inputLabel,
                    suffixIcon: IconButton(tooltip: nativeId ? '使用原生 ID' : '搜索',
                        onPressed: () => _submit(_input.text),
                        icon: Icon(nativeId ? Icons.arrow_forward : Icons.search)),
                  ),
                )),
                if (widget.onSelectNativeId != null)
                  IconButton(
                    key: comicTitleSearchNativeIdKey,
                    tooltip: single == null ? '单选来源后可输入原生 ID' : '原生 ID',
                    isSelected: nativeId,
                    onPressed: single == null ? null : () => _toggleNativeId(single),
                    icon: const Icon(Icons.numbers),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Wrap(spacing: 8, children: <Widget>[
                FilterChip(
                  key: comicTitleSearchExactKey,
                  label: const Text('精确匹配'),
                  selected: _exactTitle,
                  showCheckmark: false,
                  onSelected: (value) => setState(() => _exactTitle = value),
                ),
                FilterChip(
                  key: comicTitleSearchEmptyKey,
                  label: const Text('隐藏空结果'),
                  selected: _hideEmptySources,
                  showCheckmark: false,
                  onSelected: (value) => setState(() => _hideEmptySources = value),
                ),
              ]),
            ),
            _ComicSourceBar(chips: <Widget>[
              ComicSourceChip(
                chipKey: comicTitleSearchAllKey,
                label: '全部',
                accent: Theme.of(context).colorScheme.primary,
                selected: allSelected,
                multiple: true,
                onSelected: sources.isEmpty ? null : _selectAll,
              ),
              for (final source in sources)
                if (!emptySources.contains(source.sourceId))
                  ComicSourceChip(
                    chipKey: comicSourceChoiceKey(source.sourceId),
                    label: source.descriptor.name,
                    accent: _comicSourceAccent(source),
                    format: _comicSourcePluginFormat(source.sourceId),
                    multiple: true,
                    selected: _selectedSourceIds.contains(source.sourceId),
                    onSelected: (selected) => _selectSource(source.sourceId, selected),
                  ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

final _titleSearchWhitespace = RegExp(r'\s+');
String _normalizedSearchTitle(String title) =>
    title.trim().replaceAll(_titleSearchWhitespace, ' ').toLowerCase();
