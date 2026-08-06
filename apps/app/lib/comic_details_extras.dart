part of 'comic_details.dart';

const _previewGridGap = 8.0;
const _previewPageIndicatorHeight = 28.0;
const _previewMinTargetEdge = 56.0;
const _previewMaxTargetEdge = 92.0;
const _previewMinAspect = .45;
const _previewMaxAspect = 2.2;

final class _ComicDetailsPreviewItemLayout {
  const _ComicDetailsPreviewItemLayout({
    required this.index,
    required this.width,
    required this.height,
  });

  final int index;
  final double width;
  final double height;

  double get area => width * height;
}

final class _ComicDetailsPreviewRow {
  const _ComicDetailsPreviewRow({
    required this.items,
    required this.width,
    required this.height,
  });

  final List<_ComicDetailsPreviewItemLayout> items;
  final double width;
  final double height;
}

final class _ComicDetailsPreviewPage {
  const _ComicDetailsPreviewPage({
    required this.rows,
    required this.height,
  });

  final List<_ComicDetailsPreviewRow> rows;
  final double height;
}

final class _ComicDetailsPreviewSection extends StatefulWidget {
  const _ComicDetailsPreviewSection({
    required this.sourceId,
    required this.comicId,
    required this.title,
    required this.loadArtwork,
    this.maxItemsPerRow = 4,
    this.initialPage,
    this.loader,
    this.onOpenPage,
  });

  final String sourceId;
  final String comicId;
  final String title;
  final ComicDetailsCoverLoader loadArtwork;
  final int maxItemsPerRow;
  final ComicPreviewPage? initialPage;
  final ComicDetailsPreviewLoader? loader;
  final ComicDetailsPreviewOpener? onOpenPage;

  @override
  State<_ComicDetailsPreviewSection> createState() =>
      _ComicDetailsPreviewSectionState();
}

final class _ComicDetailsPreviewSectionState
    extends State<_ComicDetailsPreviewSection> {
  late List<ComicPreviewAsset> _items;
  String? _nextToken;
  Object? _error;
  bool _loading = false;
  bool _expanded = false;
  bool _loadingAll = false;
  final PageController _previewPageController = PageController();
  final Map<String, Size> _measuredPreviewSizes = <String, Size>{};
  int _previewPageIndex = 0;

  @override
  void initState() {
    super.initState();
    _items = widget.initialPage?.items.toList(growable: false) ??
        const <ComicPreviewAsset>[];
    _nextToken = widget.initialPage?.nextToken;
    if (widget.initialPage == null && widget.loader != null) {
      scheduleMicrotask(() => unawaited(_loadNext()));
    }
  }

  Future<void> _loadNext() async {
    final loader = widget.loader;
    if (loader == null || _loading) return;
    if (_items.isNotEmpty && _nextToken == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await loader(_nextToken);
      if (!mounted) return;
      setState(() {
        _items = <ComicPreviewAsset>[..._items, ...page.items];
        _nextToken = page.nextToken;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _toggleExpanded() async {
    if (_expanded) {
      setState(() {
        _expanded = false;
        _previewPageIndex = 0;
      });
      if (_previewPageController.hasClients) {
        _previewPageController.jumpToPage(0);
      }
      return;
    }
    setState(() {
      _expanded = true;
      _previewPageIndex = 0;
    });
    if (_previewPageController.hasClients) {
      _previewPageController.jumpToPage(0);
    }
    await _loadAllPages();
  }

  Future<void> _loadAllPages() async {
    if (widget.loader == null || _loadingAll) return;
    setState(() => _loadingAll = true);
    try {
      while (mounted) {
        if (_loading) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
          continue;
        }
        final token = _nextToken;
        if (token == null) return;
        await _loadNext();
        if (!mounted || _nextToken == token) return;
      }
    } finally {
      if (mounted) {
        setState(() => _loadingAll = false);
      }
    }
  }

  void _onPreviewImageSize(ComicPreviewAsset asset, Size size) {
    if (!mounted || size.width <= 0 || size.height <= 0) return;
    final key = asset.uri.toString();
    if (_measuredPreviewSizes[key] == size) return;
    setState(() => _measuredPreviewSizes[key] = size);
  }

  Size? _knownPreviewSize(int index) {
    final asset = _items[index];
    final measured = _measuredPreviewSizes[asset.uri.toString()];
    if (measured != null) return measured;
    final width = asset.width;
    final height = asset.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final sizeWidth = width.toDouble();
    final sizeHeight = height.toDouble();
    return Size(sizeWidth, sizeHeight);
  }

  double _previewAspect(int index) {
    final size = _knownPreviewSize(index);
    final aspect = size == null ? 1.0 : size.width / size.height;
    return aspect.clamp(_previewMinAspect, _previewMaxAspect).toDouble();
  }

  double _previewTargetArea(double maxWidth, double maxHeight) {
    final edgeForWidth = maxWidth / math.sqrt(_previewMaxAspect);
    final edgeForHeight = maxHeight * math.sqrt(_previewMinAspect);
    final maxItems = widget.maxItemsPerRow.clamp(1, 8).toInt();
    final usableWidth = math.max(
      1.0,
      maxWidth - _previewGridGap * (maxItems - 1),
    );
    final nominalEdge = (usableWidth / maxItems)
        .clamp(_previewMinTargetEdge, _previewMaxTargetEdge)
        .toDouble();
    final edge = math.max(
      1.0,
      math.min(nominalEdge, math.min(edgeForWidth, edgeForHeight)),
    );
    return edge * edge;
  }

  _ComicDetailsPreviewItemLayout _previewItemLayout(
    int index,
    double targetArea,
  ) {
    final aspect = _previewAspect(index);
    return _ComicDetailsPreviewItemLayout(
      index: index,
      width: math.sqrt(targetArea * aspect),
      height: math.sqrt(targetArea / aspect),
    );
  }

  List<_ComicDetailsPreviewRow> _previewRows(
    double maxWidth,
    double maxHeight,
  ) {
    if (_items.isEmpty || maxWidth <= 0) {
      return const <_ComicDetailsPreviewRow>[];
    }
    final targetArea = _previewTargetArea(maxWidth, maxHeight);
    final naturalRows = <_ComicDetailsPreviewRow>[];
    var items = <_ComicDetailsPreviewItemLayout>[];
    var width = 0.0;
    var height = 0.0;

    void closeNaturalRow() {
      if (items.isEmpty) return;
      naturalRows.add(
        _ComicDetailsPreviewRow(
          items: List<_ComicDetailsPreviewItemLayout>.unmodifiable(items),
          width: width,
          height: height,
        ),
      );
      items = <_ComicDetailsPreviewItemLayout>[];
      width = 0;
      height = 0;
    }

    for (var index = 0; index < _items.length; index++) {
      final item = _previewItemLayout(index, targetArea);
      final nextWidth = items.isEmpty
          ? item.width
          : width + _previewGridGap + item.width;
      if (items.isNotEmpty &&
          (nextWidth > maxWidth ||
              items.length >= widget.maxItemsPerRow.clamp(1, 8).toInt())) {
        closeNaturalRow();
      }
      width = items.isEmpty
          ? item.width
          : width + _previewGridGap + item.width;
      height = math.max(height, item.height);
      items.add(item);
    }
    closeNaturalRow();
    if (naturalRows.isEmpty) return naturalRows;

    // Justify every row as far as the global equal-area constraint allows.
    // All natural items have the same area. Scaling one complete row by one
    // factor preserves equal area inside that row. Capping the largest scale
    // to sqrt(1.2) times the smallest keeps the global max/min area ratio at
    // or below 1.2 while still using nearly all portrait-screen width.
    final desiredScales = naturalRows.map((row) {
      final itemWidth = row.width - _previewGridGap * (row.items.length - 1);
      final availableItemWidth = math.max(
        1.0,
        maxWidth - _previewGridGap * (row.items.length - 1),
      );
      return availableItemWidth / math.max(1.0, itemWidth);
    }).toList(growable: false);
    final minimumScale = desiredScales.reduce(math.min);
    final maximumScale = minimumScale * math.sqrt(1.2);

    return List<_ComicDetailsPreviewRow>.generate(naturalRows.length, (index) {
      final row = naturalRows[index];
      final scale = desiredScales[index].clamp(
        minimumScale,
        maximumScale,
      ).toDouble();
      final scaledItems = row.items.map((item) {
        return _ComicDetailsPreviewItemLayout(
          index: item.index,
          width: item.width * scale,
          height: item.height * scale,
        );
      }).toList(growable: false);
      final scaledWidth = scaledItems.fold<double>(
            0,
            (sum, item) => sum + item.width,
          ) +
          _previewGridGap * (scaledItems.length - 1);
      final scaledHeight = scaledItems.fold<double>(
        0,
        (value, item) => math.max(value, item.height),
      );
      return _ComicDetailsPreviewRow(
        items: List<_ComicDetailsPreviewItemLayout>.unmodifiable(scaledItems),
        width: math.min(maxWidth, scaledWidth),
        height: scaledHeight,
      );
    }, growable: false);
  }

  List<_ComicDetailsPreviewPage> _previewPages(
    double maxWidth,
    double maxHeight,
  ) {
    final pages = <_ComicDetailsPreviewPage>[];
    var rows = <_ComicDetailsPreviewRow>[];
    var height = 0.0;

    void closePage() {
      if (rows.isEmpty) return;
      pages.add(
        _ComicDetailsPreviewPage(
          rows: List<_ComicDetailsPreviewRow>.unmodifiable(rows),
          height: height,
        ),
      );
      rows = <_ComicDetailsPreviewRow>[];
      height = 0;
    }

    for (final row in _previewRows(maxWidth, maxHeight)) {
      final nextHeight = rows.isEmpty
          ? row.height
          : height + _previewGridGap + row.height;
      if (rows.isNotEmpty && nextHeight > maxHeight) {
        closePage();
      }
      height = rows.isEmpty
          ? row.height
          : height + _previewGridGap + row.height;
      rows.add(row);
    }
    closePage();
    return pages;
  }

  Widget _previewTile(
    _ComicDetailsPreviewItemLayout layout,
  ) {
    final asset = _items[layout.index];
    return SizedBox(
      width: layout.width,
      height: layout.height,
      child: InkWell(
        key: comicDetailsPreviewItemKey(layout.index),
        onTap: () => unawaited(_openPreview(layout.index, asset)),
        borderRadius: BorderRadius.circular(10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ColoredBox(
            color: const Color(0x0A000000),
            child: _ComicDetailsArtwork(
              sourceId: widget.sourceId,
              comicId: widget.comicId,
              uri: asset.uri,
              loader: widget.loadArtwork,
              resourceRole: 'preview',
              fit: BoxFit.contain,
              onImageSize: (size) => _onPreviewImageSize(asset, size),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewPage(
    _ComicDetailsPreviewPage page,
    double maxWidth,
  ) {
    return Align(
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var rowIndex = 0; rowIndex < page.rows.length; rowIndex++)
            if (rowIndex == 0)
              _previewRow(page.rows[rowIndex], maxWidth)
            else ...<Widget>[
              const SizedBox(height: _previewGridGap),
              _previewRow(page.rows[rowIndex], maxWidth),
            ],
        ],
      ),
    );
  }

  Widget _previewRow(_ComicDetailsPreviewRow row, double maxWidth) {
    final residual = math.max(0.0, maxWidth - row.width);
    final extraGap = row.items.length > 1
        ? residual / (row.items.length - 1)
        : residual / 2;
    return SizedBox(
      width: maxWidth,
      height: row.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (row.items.length == 1) SizedBox(width: extraGap),
          for (var itemIndex = 0;
              itemIndex < row.items.length;
              itemIndex++)
            if (itemIndex == 0)
              _previewTile(row.items[itemIndex])
            else ...<Widget>[
              SizedBox(width: _previewGridGap + extraGap),
              _previewTile(row.items[itemIndex]),
            ],
          if (row.items.length == 1) SizedBox(width: extraGap),
        ],
      ),
    );
  }

  Widget _previewItems(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPreviewHeight = MediaQuery.sizeOf(context).height * .8;
        final maxGridHeight = math.max(
          1.0,
          maxPreviewHeight - _previewPageIndicatorHeight,
        );
        final pages = _previewPages(constraints.maxWidth, maxGridHeight);
        if (pages.isEmpty) return const SizedBox.shrink();
        if (!_expanded) {
          final firstRow = pages.first.rows.first;
          return SizedBox(
            height: firstRow.height,
            child: _previewRow(firstRow, constraints.maxWidth),
          );
        }
        final pageHeight = pages.fold<double>(
          0,
          (height, page) => math.max(height, page.height),
        );
        final hasPageIndicator = pages.length > 1;
        return SizedBox(
          height: pageHeight +
              (hasPageIndicator ? _previewPageIndicatorHeight : 0),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: pageHeight,
                child: PageView.builder(
                  controller: _previewPageController,
                  itemCount: pages.length,
                  onPageChanged: (index) {
                    if (mounted) setState(() => _previewPageIndex = index);
                  },
                  itemBuilder: (_, index) => _previewPage(
                    pages[index],
                    constraints.maxWidth,
                  ),
                ),
              ),
              if (hasPageIndicator)
                SizedBox(
                  height: _previewPageIndicatorHeight,
                  child: Center(
                    child: Text(
                      '${_previewPageIndex.clamp(0, pages.length - 1) + 1} / '
                      '${pages.length}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openPreview(int index, ComicPreviewAsset asset) async {
    final openPage = widget.onOpenPage;
    if (openPage != null) {
      await openPage(index);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final height = MediaQuery.sizeOf(dialogContext).height * .78;
        return Dialog(
          child: SizedBox(
            width: 420,
            height: height.clamp(320, 720).toDouble(),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: InteractiveViewer(
                    child: _ComicDetailsArtwork(
                      sourceId: widget.sourceId,
                      comicId: widget.comicId,
                      uri: asset.uri,
                      loader: widget.loadArtwork,
                      resourceRole: 'preview',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                AppDialogActions(
                  onClose: () => Navigator.of(dialogContext).pop(),
                  actions: const <Widget>[],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void didUpdateWidget(covariant _ComicDetailsPreviewSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initial = widget.initialPage;
    if (initial != null &&
        oldWidget.initialPage == null &&
        _items.isEmpty) {
      setState(() {
        _items = initial.items.toList(growable: false);
        _nextToken = initial.nextToken;
      });
    }
  }

  @override
  void dispose() {
    _previewPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canExpand = _items.isNotEmpty;
    final canLoadInitial = widget.loader != null && _items.isEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.collections_outlined, size: 20),
                const SizedBox(width: 8),
                Text('预览', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (_loading && _items.isNotEmpty)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_items.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              _previewItems(context),
            ] else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无预览'),
              ),
            if (_error != null)
              Text(
                '预览加载失败，请重试',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (canExpand)
              Align(
                alignment: Alignment.center,
                child: IconButton(
                  key: comicDetailsPreviewExpandKey,
                  tooltip: _expanded ? '收起预览' : '展开预览',
                  onPressed: _loadingAll
                      ? null
                      : () => unawaited(_toggleExpanded()),
                  icon: Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  ),
                ),
              )
            else if (canLoadInitial)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loading ? null : () => unawaited(_loadNext()),
                  child: Text(_error == null ? '加载预览' : '重试'),
                ),
              ),
            if (_expanded && _error != null && _nextToken != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loadingAll
                      ? null
                      : () => unawaited(_loadAllPages()),
                  child: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ComicDetailsCommentsSection extends StatefulWidget {
  const _ComicDetailsCommentsSection({
    required this.sourceId,
    required this.comicId,
    required this.sourceSubId,
    required this.title,
    required this.loadArtwork,
    this.initialPage,
    this.loader,
  });

  final String sourceId;
  final String comicId;
  final String? sourceSubId;
  final String title;
  final ComicDetailsCoverLoader loadArtwork;
  final ComicCommentPage? initialPage;
  final ComicDetailsCommentsLoader? loader;

  @override
  State<_ComicDetailsCommentsSection> createState() =>
      _ComicDetailsCommentsSectionState();
}

final class _ComicDetailsCommentsSectionState
    extends State<_ComicDetailsCommentsSection> {
  late List<ComicComment> _items;
  int _page = 1;
  int? _maxPage;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPage;
    _items = initial?.items.toList(growable: false) ??
        const <ComicComment>[];
    _page = initial?.page ?? 1;
    _maxPage = initial?.maxPage;
    if (initial == null && widget.loader != null) {
      scheduleMicrotask(() => unawaited(_loadPage(1, replace: true)));
    }
  }

  Future<void> _loadPage(int page, {required bool replace}) async {
    final loader = widget.loader;
    if (loader == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await loader(page: page, replyTo: null);
      if (!mounted) return;
      setState(() {
        _items = replace && result.items.isNotEmpty
            ? result.items.toList(growable: false)
            : <ComicComment>[..._items, ...result.items];
        _page = result.page;
        _maxPage = result.maxPage;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _ComicDetailsCommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initial = widget.initialPage;
    if (initial != null &&
        oldWidget.initialPage == null &&
        _items.isEmpty) {
      setState(() {
        _items = initial.items.toList(growable: false);
        _page = initial.page;
        _maxPage = initial.maxPage;
      });
    }
  }

  void _openCommentsPage() {
    final loader = widget.loader;
    if (loader == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ComicDetailsCommentsPage(
          sourceId: widget.sourceId,
          comicId: widget.comicId,
          sourceSubId: widget.sourceSubId,
          title: widget.title,
          loadArtwork: widget.loadArtwork,
          initialPage: ComicCommentPage(
            page: _page,
            items: _items,
            maxPage: _maxPage == null || _maxPage! >= _page
                ? _maxPage
                : _page,
          ),
          loader: loader,
        ),
      ),
    );
  }

  void _openReplies(ComicComment comment) {
    final loader = widget.loader;
    final id = comment.id;
    if (loader == null || id == null || id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ComicDetailsCommentsPage(
          sourceId: widget.sourceId,
          comicId: widget.comicId,
          sourceSubId: widget.sourceSubId,
          title: widget.title,
          loadArtwork: widget.loadArtwork,
          replyTo: id,
          parentComment: comment,
          loader: loader,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _items.take(3).toList(growable: false);
    final canOpenAll = widget.loader != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.comment_outlined, size: 20),
                const SizedBox(width: 8),
                Text('评论', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (canOpenAll)
                  TextButton(
                    onPressed: _openCommentsPage,
                    child: const Text('查看全部'),
                  ),
              ],
            ),
            if (_loading && visible.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无评论'),
              )
            else
              SizedBox(
                height: 178,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final comment = visible[index];
                    return SizedBox(
                      width: 286,
                      child: _ComicDetailsCommentCard(
                        sourceId: widget.sourceId,
                        comicId: widget.comicId,
                        comment: comment,
                        loadArtwork: widget.loadArtwork,
                        onOpenReplies: comment.replyCount != null &&
                                comment.replyCount! > 0
                            ? () => _openReplies(comment)
                            : null,
                      ),
                    );
                  },
                ),
              ),
            if (_error != null)
              Text(
                '评论加载失败，请打开评论页重试',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ComicDetailsCommentsPage extends StatefulWidget {
  const _ComicDetailsCommentsPage({
    required this.sourceId,
    required this.comicId,
    required this.sourceSubId,
    required this.title,
    required this.loadArtwork,
    required this.loader,
    this.initialPage,
    this.replyTo,
    this.parentComment,
  });

  final String sourceId;
  final String comicId;
  final String? sourceSubId;
  final String title;
  final ComicDetailsCoverLoader loadArtwork;
  final ComicDetailsCommentsLoader loader;
  final ComicCommentPage? initialPage;
  final String? replyTo;
  final ComicComment? parentComment;

  @override
  State<_ComicDetailsCommentsPage> createState() =>
      _ComicDetailsCommentsPageState();
}

final class _ComicDetailsCommentsPageState
    extends State<_ComicDetailsCommentsPage> {
  late List<ComicComment> _items;
  int _page = 0;
  int? _maxPage;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPage;
    _items = initial?.items.toList(growable: false) ??
        const <ComicComment>[];
    _page = initial?.page ?? 0;
    _maxPage = initial?.maxPage;
    if (initial == null) {
      scheduleMicrotask(() => unawaited(_loadPage(1, replace: true)));
    }
  }

  Future<void> _loadPage(int page, {required bool replace}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.loader(
        page: page,
        replyTo: widget.replyTo,
      );
      if (!mounted) return;
      setState(() {
        _items = replace
            ? result.items.toList(growable: false)
            : <ComicComment>[..._items, ...result.items];
        _page = result.page;
        _maxPage = result.maxPage;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openReplies(ComicComment comment) {
    final id = comment.id;
    if (id == null || id.isEmpty || comment.replyCount == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ComicDetailsCommentsPage(
          sourceId: widget.sourceId,
          comicId: widget.comicId,
          sourceSubId: widget.sourceSubId,
          title: widget.title,
          loadArtwork: widget.loadArtwork,
          loader: widget.loader,
          replyTo: id,
          parentComment: comment,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMore = _maxPage == null || _page < _maxPage!;
    return Scaffold(
      key: comicDetailsCommentsPageKey,
      appBar: AppBar(
        title: Text(widget.replyTo == null ? '评论' : '回复'),
      ),
      body: _error != null && _items.isEmpty
          ? Center(
              child: TextButton(
                onPressed: _loading
                    ? null
                    : () => unawaited(
                          _loadPage(_page == 0 ? 1 : _page, replace: true),
                        ),
                child: const Text('加载失败，点击重试'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              children: <Widget>[
                if (widget.parentComment != null)
                  _ComicDetailsCommentCard(
                    sourceId: widget.sourceId,
                    comicId: widget.comicId,
                    comment: widget.parentComment!,
                    loadArtwork: widget.loadArtwork,
                  ),
                if (widget.parentComment != null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('回复'),
                  ),
                for (final comment in _items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ComicDetailsCommentCard(
                      sourceId: widget.sourceId,
                      comicId: widget.comicId,
                      comment: comment,
                      loadArtwork: widget.loadArtwork,
                      onOpenReplies: comment.replyCount != null &&
                              comment.replyCount! > 0
                          ? () => _openReplies(comment)
                          : null,
                    ),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!_loading && hasMore)
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: () => unawaited(
                        _loadPage(_page + 1, replace: false),
                      ),
                      child: const Text('加载更多评论'),
                    ),
                  ),
                if (_error != null && _items.isNotEmpty)
                  Text(
                    '加载下一页失败',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
    );
  }
}

final class _ComicDetailsCommentCard extends StatelessWidget {
  const _ComicDetailsCommentCard({
    required this.sourceId,
    required this.comicId,
    required this.comment,
    required this.loadArtwork,
    this.onOpenReplies,
  });

  final String sourceId;
  final String comicId;
  final ComicComment comment;
  final ComicDetailsCoverLoader loadArtwork;
  final VoidCallback? onOpenReplies;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _ComicDetailsCommentAvatar(
                  sourceId: sourceId,
                  comicId: comicId,
                  uri: comment.avatarUri,
                  loader: loadArtwork,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    comment.userName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (comment.time != null)
                  Text(
                    comment.time!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              comment.content,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            if (onOpenReplies != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onOpenReplies,
                  icon: const Icon(Icons.forum_outlined, size: 16),
                  label: Text('${comment.replyCount} 条回复'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ComicDetailsCommentAvatar extends StatelessWidget {
  const _ComicDetailsCommentAvatar({
    required this.sourceId,
    required this.comicId,
    required this.uri,
    required this.loader,
  });

  final String sourceId;
  final String comicId;
  final Uri? uri;
  final ComicDetailsCoverLoader loader;

  @override
  Widget build(BuildContext context) {
    if (uri == null) {
      return const CircleAvatar(
        radius: 18,
        child: Icon(Icons.person_outline, size: 20),
      );
    }
    return SizedBox.square(
      dimension: 36,
      child: ClipOval(
        child: _ComicDetailsArtwork(
          sourceId: sourceId,
          comicId: comicId,
          uri: uri!,
          loader: loader,
          resourceRole: 'avatar',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

final class _ComicDetailsArtwork extends StatefulWidget {
  const _ComicDetailsArtwork({
    required this.sourceId,
    required this.comicId,
    required this.uri,
    required this.loader,
    this.resourceRole = 'cover',
    this.fit = BoxFit.cover,
    this.onImageSize,
  });

  final String sourceId;
  final String comicId;
  final Uri uri;
  final ComicDetailsCoverLoader loader;
  final String resourceRole;
  final BoxFit fit;
  final ValueChanged<Size>? onImageSize;

  @override
  State<_ComicDetailsArtwork> createState() => _ComicDetailsArtworkState();
}

final class _ComicDetailsArtworkState extends State<_ComicDetailsArtwork> {
  late Future<EncodedResourceSource> _source;

  @override
  void initState() {
    super.initState();
    _source = _load();
  }

  @override
  void didUpdateWidget(covariant _ComicDetailsArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId ||
        oldWidget.comicId != widget.comicId ||
        oldWidget.uri != widget.uri ||
        oldWidget.resourceRole != widget.resourceRole) {
      _source = _load();
    }
  }

  Future<EncodedResourceSource> _load() => widget.loader(
        sourceId: widget.sourceId,
        comicId: widget.comicId,
        coverUri: widget.uri,
        fallbackChapter: null,
        resourceRole: widget.resourceRole,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EncodedResourceSource>(
      future: _source,
      builder: (context, snapshot) {
        final source = snapshot.data;
        if (source != null) {
          return _ComicDetailsDecodedArtwork(
            image: encodedResourceImageProvider(source),
            fit: widget.fit,
            part: _comicPreviewImagePart(widget.uri),
            onImageSize: widget.onImageSize,
            errorBuilder: (_, __, ___) => _CoverPlaceholder(
              seed: '${widget.resourceRole}:${widget.uri}',
            ),
          );
        }
        if (snapshot.hasError) {
          return _CoverPlaceholder(
            seed: '${widget.resourceRole}:${widget.uri}',
          );
        }
        return const ColoredBox(
          color: Color(0x14000000),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}

/// Venera represents a thumbnail crop as `${url}@x=start-end&y=start-end`.
/// The request still uses the base URL, while the host paints only this part
/// of the decoded image. The full URI remains the widget/paint identity, while
/// the artwork gateway shares encoded bytes for every crop of one base URL.
final class _ComicPreviewImagePart {
  const _ComicPreviewImagePart({this.x1, this.y1, this.x2, this.y2});

  final double? x1;
  final double? y1;
  final double? x2;
  final double? y2;

  bool get isEmpty => x1 == null && y1 == null && x2 == null && y2 == null;
}

_ComicPreviewImagePart? _comicPreviewImagePart(Uri uri) {
  final raw = uri.toString();
  final separator = raw.indexOf('@');
  if (separator < 0 || separator == raw.length - 1) return null;

  double? x1;
  double? y1;
  double? x2;
  double? y2;
  for (final parameter in raw.substring(separator + 1).split('&')) {
    final parts = parameter.split('=');
    if (parts.length != 2) continue;
    final range = parts[1].split('-');
    if (range.length != 2) continue;
    final start = double.tryParse(range[0]);
    final end = double.tryParse(range[1]);
    if (start == null || end == null || start < 0 || end <= start) {
      continue;
    }
    switch (parts[0]) {
      case 'x':
        x1 = start;
        x2 = end;
        break;
      case 'y':
        y1 = start;
        y2 = end;
        break;
    }
  }

  final part = _ComicPreviewImagePart(x1: x1, y1: y1, x2: x2, y2: y2);
  return part.isEmpty ? null : part;
}

final class _ComicDetailsDecodedArtwork extends StatefulWidget {
  const _ComicDetailsDecodedArtwork({
    required this.image,
    required this.fit,
    required this.errorBuilder,
    this.part,
    this.onImageSize,
  });

  final ImageProvider<Object> image;
  final BoxFit fit;
  final _ComicPreviewImagePart? part;
  final ValueChanged<Size>? onImageSize;
  final Widget Function(BuildContext, Object, StackTrace?) errorBuilder;

  @override
  State<_ComicDetailsDecodedArtwork> createState() =>
      _ComicDetailsDecodedArtworkState();
}

final class _ComicDetailsDecodedArtworkState
    extends State<_ComicDetailsDecodedArtwork> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _decodedImage;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ComicDetailsDecodedArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        !_samePreviewImagePart(oldWidget.part, widget.part)) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    final oldStream = _stream;
    final oldListener = _listener;
    if (oldStream != null && oldListener != null) {
      oldStream.removeListener(oldListener);
    }

    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final crop = _boundedImagePart(widget.part, info.image);
        final imageWidth = info.image.width.toDouble();
        final imageHeight = info.image.height.toDouble();
        final visibleWidth =
            crop == null ? imageWidth : crop.x2! - crop.x1!;
        final visibleHeight =
            crop == null ? imageHeight : crop.y2! - crop.y1!;
        widget.onImageSize?.call(Size(visibleWidth, visibleHeight));
        setState(() {
          _decodedImage = info.image;
          _error = null;
        });
      },
      onError: (error, stackTrace) {
        if (!mounted) return;
        setState(() {
          _decodedImage = null;
          _error = error;
        });
      },
    );
    _stream = stream;
    _listener = listener;
    _decodedImage = null;
    _error = null;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return widget.errorBuilder(context, error, null);
    }
    final image = _decodedImage;
    if (image == null) {
      if (widget.part != null) {
        return const ColoredBox(color: Color(0x14000000));
      }
      return Image(
        image: widget.image,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: widget.errorBuilder,
      );
    }
    final part = _boundedImagePart(widget.part, image);
    if (part == null) {
      return RawImage(image: image, fit: widget.fit);
    }
    return CustomPaint(
      isComplex: true,
      painter: _ComicDetailsImagePartPainter(
        image: image,
        part: part,
        fit: widget.fit,
      ),
      child: const SizedBox.expand(),
    );
  }
}

bool _samePreviewImagePart(
  _ComicPreviewImagePart? left,
  _ComicPreviewImagePart? right,
) {
  return left?.x1 == right?.x1 &&
      left?.y1 == right?.y1 &&
      left?.x2 == right?.x2 &&
      left?.y2 == right?.y2;
}

_ComicPreviewImagePart? _boundedImagePart(
  _ComicPreviewImagePart? part,
  ui.Image image,
) {
  if (part == null) return null;
  final width = image.width.toDouble();
  final height = image.height.toDouble();
  final x1 = (part.x1 ?? 0).clamp(0, width).toDouble();
  final y1 = (part.y1 ?? 0).clamp(0, height).toDouble();
  final x2 = (part.x2 ?? width).clamp(0, width).toDouble();
  final y2 = (part.y2 ?? height).clamp(0, height).toDouble();
  if (x2 <= x1 || y2 <= y1) return null;
  return _ComicPreviewImagePart(x1: x1, y1: y1, x2: x2, y2: y2);
}

final class _ComicDetailsImagePartPainter extends CustomPainter {
  const _ComicDetailsImagePartPainter({
    required this.image,
    required this.part,
    required this.fit,
  });

  final ui.Image image;
  final _ComicPreviewImagePart part;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final source = Rect.fromLTRB(
      part.x1 ?? 0,
      part.y1 ?? 0,
      part.x2 ?? image.width.toDouble(),
      part.y2 ?? image.height.toDouble(),
    );
    final fitted = applyBoxFit(fit, source.size, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(image, source, destination, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ComicDetailsImagePartPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.part.x1 != part.x1 ||
      oldDelegate.part.y1 != part.y1 ||
      oldDelegate.part.x2 != part.x2 ||
      oldDelegate.part.y2 != part.y2 ||
      oldDelegate.fit != fit;
}
