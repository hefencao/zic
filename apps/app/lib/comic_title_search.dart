part of 'source_browser.dart';

const comicTitleSearchPageKey = ValueKey<String>('comic-title-search-page');
const comicTitleSearchInputKey = ValueKey<String>('comic-title-search-input');
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
  late Future<_TitleSourceResult> result;
}

final class _ComicTitleSearchPageState extends State<ComicTitleSearchPage> {
  late final TextEditingController _input;
  late String _query;
  List<_TitleSourceSearch> _groups = <_TitleSourceSearch>[];

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
    final seen = <String>{};
    _groups = <_TitleSourceSearch>[
      for (final source in widget.sources)
        if (source.descriptor.supportsSearch && seen.add(source.sourceId))
          previous[source.sourceId] ?? _TitleSourceSearch(source),
    ];
    if (_query.isEmpty) {
      _groups = <_TitleSourceSearch>[];
      return;
    }
    for (final group in _groups) {
      if (!previous.containsKey(group.source.sourceId)) {
        group.result = _search(group);
      }
    }
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    widget.onSearchCommitted?.call(query);
    setState(() {
      _query = query;
      _startSearch();
    });
  }

  void _reload(_TitleSourceSearch group) {
    if (!mounted || !_groups.contains(group)) return;
    setState(() {
      group.result = _search(group);
    });
  }

  void _previous(_TitleSourceSearch group) {
    setState(() {
      group.pageIndex--;
      group.result = _search(group);
    });
  }

  void _next(_TitleSourceSearch group, SourceBrowsePage page) {
    setState(() {
      final offset = page.nextOffset ?? page.offset + page.items.length;
      group.offsets.removeRange(group.pageIndex + 1, group.offsets.length);
      group.offsets.add(offset);
      group.pageIndex++;
      group.result = _search(group);
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
      builder: (context, snapshot) {
        final complete = snapshot.connectionState == ConnectionState.done;
        final page = complete ? snapshot.data?.page : null;
        final failure = complete ? snapshot.data?.failure : null;
        return Padding(
          key: comicTitleSearchGroupKey(source.sourceId),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(source.descriptor.name,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (source.sourceId.startsWith('mihon:') ||
                          source.sourceId.startsWith('venera:'))
                        Text(source.sourceId.startsWith('mihon:') ? 'Mihon' : 'Venera',
                            style: Theme.of(context).textTheme.labelSmall),
                    ],
                  )),
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
              else if (page == null || page.items.isEmpty)
                const Padding(padding: EdgeInsets.all(20), child: Text('没有搜索结果'))
              else
                SizedBox(
                  height: 224,
                  child: ListView.separated(
                    key: ValueKey<(String, String, int)>((
                      source.sourceId, _query, group.offsets[group.pageIndex])),
                    scrollDirection: Axis.horizontal,
                    itemCount: page.items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final comic = page.items[index];
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
                          onCoverDecodeFailure: () {},
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
    return Scaffold(
      key: comicTitleSearchPageKey,
      appBar: AppBar(title: Text('聚合搜索：$_query')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: comicTitleSearchInputKey,
              controller: _input,
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              decoration: InputDecoration(
                labelText: '搜索漫画',
                suffixIcon: IconButton(tooltip: '搜索',
                    onPressed: () => _submit(_input.text),
                    icon: const Icon(Icons.search)),
              ),
            ),
          ),
          Expanded(
            child: _groups.isEmpty
                ? const Center(child: Text('没有可搜索的漫画源'))
                : ListView(children: <Widget>[
                    for (final group in _groups) _group(group),
                  ]),
          ),
        ],
      ),
    );
  }
}
