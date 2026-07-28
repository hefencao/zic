import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const comicDetailsScreenKey = ValueKey<String>('comic-details-screen');
const comicDetailsReverseKey = ValueKey<String>('comic-details-reverse');
const comicDetailsRefreshKey = ValueKey<String>('comic-details-refresh');
const comicDetailsSourceFilterKey =
    ValueKey<String>('comic-details-source-filter');
const comicDetailsErrorKey = ValueKey<String>('comic-details-error');
const comicDetailsCopyErrorKey =
    ValueKey<String>('comic-details-copy-error');

String comicDetailsChapterIdentity(String sourceId, String chapterId) =>
    '$sourceId\u0000$chapterId';

Key comicDetailsChapterKey(String sourceId, String chapterId, bool composite) =>
    ValueKey<String>(
      'source-chapter:${composite ? '$sourceId:' : ''}$chapterId',
    );

Key comicDetailsReadKey(String sourceId, String chapterId, bool composite) =>
    ValueKey<String>(
      'chapter-read:${composite ? '$sourceId:' : ''}$chapterId',
    );

final class ComicDetailsSourceBinding {
  const ComicDetailsSourceBinding({
    required this.source,
    required this.comicId,
    this.summary,
  });

  final BrowsableComicSource source;
  final String comicId;
  final SourceComicSummary? summary;

  String get sourceId => source.sourceId;

  Comic initialComic() {
    final value = summary;
    return Comic(
      comicId: comicId,
      sourceId: sourceId,
      title: value?.title ?? comicId,
      authors: value?.authors ?? const <String>[],
      coverUri: value?.coverUri,
      description: value?.description,
      readingDirection: ReadingDirection.ltr,
    );
  }
}

final class ComicDetailsLibrarySnapshot {
  ComicDetailsLibrarySnapshot({
    required Iterable<ImportedLibraryEntry> chapters,
    required Map<String, ChapterReadState> readStates,
    required this.preference,
  })  : chapters = List<ImportedLibraryEntry>.unmodifiable(chapters),
        readStates = Map<String, ChapterReadState>.unmodifiable(readStates);

  final List<ImportedLibraryEntry> chapters;
  final Map<String, ChapterReadState> readStates;
  final ComicPreference preference;
}

typedef ComicDetailsCoverLoader = Future<Uint8List> Function({
  required String sourceId,
  required Uri? coverUri,
  required ImportedLibraryEntry? fallbackChapter,
});

typedef ComicDetailsLibraryReloader = Future<ComicDetailsLibrarySnapshot>
    Function({required bool refreshContent});

typedef ComicDetailsChapterEnsurer = Future<ImportedLibraryEntry> Function(
  BrowsableComicSource source,
  Comic comic,
  Chapter chapter,
);

typedef ComicDetailsChapterOpener = Future<void> Function(
  ImportedLibraryEntry chapter, {
  required bool refreshRemote,
});

final class UnifiedComicDetailsScreen extends StatefulWidget {
  const UnifiedComicDetailsScreen({
    required this.initialLibrary,
    required this.sources,
    required this.categories,
    required this.loadCover,
    required this.reloadLibrary,
    required this.ensureSourceChapter,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    this.initialSourceId,
    super.key,
  });

  final ComicDetailsLibrarySnapshot initialLibrary;
  final List<ComicDetailsSourceBinding> sources;
  final List<LibraryCategory> categories;
  final String? initialSourceId;
  final ComicDetailsCoverLoader loadCover;
  final ComicDetailsLibraryReloader reloadLibrary;
  final ComicDetailsChapterEnsurer ensureSourceChapter;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final ComicDetailsChapterOpener onOpenChapter;

  @override
  State<UnifiedComicDetailsScreen> createState() =>
      _UnifiedComicDetailsScreenState();
}

final class _UnifiedComicDetailsScreenState
    extends State<UnifiedComicDetailsScreen> {
  late List<ImportedLibraryEntry> _libraryChapters;
  late ComicPreference _preference;
  late Map<String, bool> _readStates;
  final Map<String, ComicManifest> _manifests = <String, ComicManifest>{};
  final Map<String, _DetailFailure> _failures = <String, _DetailFailure>{};
  final Set<String> _workingChapters = <String>{};
  bool _descending = true;
  bool _refreshing = false;
  String? _selectedSourceId;
  int _coverRevision = 0;

  Map<String, ComicDetailsSourceBinding> get _sourceBindings =>
      <String, ComicDetailsSourceBinding>{
        for (final binding in widget.sources) binding.sourceId: binding,
      };

  @override
  void initState() {
    super.initState();
    _applyLibrarySnapshot(widget.initialLibrary);
    final sourceIds = _allSourceIds;
    final requested = widget.initialSourceId;
    if (requested != null && sourceIds.contains(requested)) {
      _selectedSourceId = requested;
    } else if (sourceIds.length == 1) {
      _selectedSourceId = sourceIds.single;
    } else {
      _selectedSourceId = null;
    }
    if (widget.sources.isNotEmpty) {
      scheduleMicrotask(() => unawaited(_refresh(announce: false)));
    }
  }

  void _applyLibrarySnapshot(ComicDetailsLibrarySnapshot snapshot) {
    _libraryChapters = snapshot.chapters.toList(growable: false);
    _preference = snapshot.preference;
    _readStates = <String, bool>{
      for (final entry in snapshot.chapters)
        comicDetailsChapterIdentity(
          entry.chapter.sourceId,
          entry.chapter.chapterId,
        ): (snapshot.readStates[
                  comicDetailsChapterIdentity(
                    entry.chapter.sourceId,
                    entry.chapter.chapterId,
                  )
                ] ??
                snapshot.readStates[entry.chapter.chapterId])
            ?.isRead ??
            false,
    };
  }

  List<String> get _allSourceIds {
    final values = <String>[];
    final seen = <String>{};
    for (final binding in widget.sources) {
      if (seen.add(binding.sourceId)) {
        values.add(binding.sourceId);
      }
    }
    for (final entry in _libraryChapters) {
      if (seen.add(entry.chapter.sourceId)) {
        values.add(entry.chapter.sourceId);
      }
    }
    return values;
  }

  List<String> get _refreshSourceIds {
    final selected = _selectedSourceId;
    if (selected != null) {
      return _sourceBindings.containsKey(selected)
          ? <String>[selected]
          : const <String>[];
    }
    return widget.sources.map((binding) => binding.sourceId).toList(
          growable: false,
        );
  }

  Future<void> _refresh({required bool announce}) async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    final sourceIdsToRefresh = _refreshSourceIds;
    final failures = <String, _DetailFailure>{};
    var refreshedSources = 0;
    for (final sourceId in sourceIdsToRefresh) {
      final binding = _sourceBindings[sourceId];
      if (binding == null) {
        continue;
      }
      try {
        final manifest = await binding.source.loadComic(binding.comicId);
        if (manifest.comic.sourceId != binding.sourceId ||
            manifest.comic.comicId != binding.comicId ||
            manifest.chapters.any(
              (chapter) => chapter.comicId != binding.comicId,
            )) {
          throw StateError('漫画源详情返回了不匹配的漫画或章节身份');
        }
        _manifests[sourceId] = manifest;
        refreshedSources++;
      } on Object catch (error, stackTrace) {
        failures[sourceId] = _DetailFailure.capture(error, stackTrace);
      }
    }

    ComicDetailsLibrarySnapshot? library;
    _DetailFailure? libraryFailure;
    try {
      library = await widget.reloadLibrary(refreshContent: announce);
    } on Object catch (error, stackTrace) {
      libraryFailure = _DetailFailure.capture(error, stackTrace);
    }
    if (!mounted) {
      return;
    }
    final refreshedLibrary = library;
    final refreshedLibraryFailure = libraryFailure;
    setState(() {
      if (refreshedLibrary != null) {
        _applyLibrarySnapshot(refreshedLibrary);
      }
      _failures
        ..removeWhere((sourceId, _) => sourceIdsToRefresh.contains(sourceId))
        ..addAll(failures);
      if (refreshedLibraryFailure != null) {
        _failures['library'] = refreshedLibraryFailure;
      } else {
        _failures.remove('library');
      }
      _coverRevision++;
      _refreshing = false;
    });

    if (!announce) {
      return;
    }
    if (failures.isNotEmpty || libraryFailure != null) {
      final failure = libraryFailure ?? failures.values.first;
      _showFailureSnackBar(context, failure!);
      return;
    }
    final count = _projectedChapters.length;
    final label = refreshedSources == 0 ? '详情已更新' : '已更新 $count 个章节';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(label)),
    );
  }

  String _sourceLabel(String sourceId) {
    if (sourceId == 'local-folder') {
      return '本地';
    }
    return _sourceBindings[sourceId]?.source.descriptor.name ?? sourceId;
  }

  String get _primarySourceId {
    final selected = _selectedSourceId;
    if (selected != null) {
      return selected;
    }
    final withProgress = _libraryChapters
        .where((entry) => entry.progress != null)
        .toList(growable: false)
      ..sort((left, right) => right.progress!.updatedAt.compareTo(
            left.progress!.updatedAt,
          ));
    if (withProgress.isNotEmpty) {
      return withProgress.first.chapter.sourceId;
    }
    if (_libraryChapters.isNotEmpty) {
      return _libraryChapters.first.chapter.sourceId;
    }
    return _allSourceIds.first;
  }

  Comic get _primaryComic {
    final sourceId = _primarySourceId;
    final manifest = _manifests[sourceId];
    final binding = _sourceBindings[sourceId];
    if (manifest != null) {
      return _mergeComic(manifest.comic, binding?.initialComic());
    }
    if (binding != null) {
      return binding.initialComic();
    }
    final entries = _libraryChapters
        .where((entry) => entry.chapter.sourceId == sourceId)
        .toList(growable: false);
    final entry = entries.isNotEmpty ? entries.first : _libraryChapters.first;
    return _comicFromStored(entry.chapter);
  }

  String? get _primaryDescription {
    final comic = _primaryComic;
    final description = comic.description?.trim();
    if (description != null && description.isNotEmpty) {
      return description;
    }
    final summary = _sourceBindings[_primarySourceId]?.summary?.description;
    if (summary != null && summary.trim().isNotEmpty) {
      return summary.trim();
    }
    for (final entry in _libraryChapters) {
      if (entry.chapter.sourceId == _primarySourceId) {
        final value = entry.chapter.comicDescription?.trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
    return null;
  }

  ImportedLibraryEntry? get _primaryCoverFallback {
    for (final entry in _libraryChapters) {
      if (entry.chapter.sourceId == _primarySourceId) {
        return entry;
      }
    }
    return _libraryChapters.isEmpty ? null : _libraryChapters.first;
  }

  List<_DetailChapter> get _projectedChapters {
    final sourceIds = _selectedSourceId == null
        ? _allSourceIds
        : <String>[_selectedSourceId!];
    final result = <_DetailChapter>[];
    for (final sourceId in sourceIds) {
      final localEntries = <String, ImportedLibraryEntry>{
        for (final entry in _libraryChapters)
          if (entry.chapter.sourceId == sourceId)
            entry.chapter.chapterId: entry,
      };
      final manifest = _manifests[sourceId];
      if (manifest != null) {
        for (final chapter in manifest.chapters) {
          result.add(
            _DetailChapter(
              sourceId: sourceId,
              chapter: chapter,
              libraryEntry: localEntries.remove(chapter.chapterId),
              upstreamAvailable: true,
            ),
          );
        }
      }
      for (final entry in localEntries.values) {
        result.add(
          _DetailChapter(
            sourceId: sourceId,
            chapter: _chapterFromStored(entry.chapter),
            libraryEntry: entry,
            upstreamAvailable: manifest == null,
          ),
        );
      }
    }
    result.sort(_compareDetailChapters);
    return _descending ? result.reversed.toList(growable: false) : result;
  }

  Future<void> _updatePreference(ComicPreference next) async {
    final previous = _preference;
    setState(() => _preference = next);
    try {
      await widget.onPreferenceChanged(next);
    } on Object catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      setState(() => _preference = previous);
      _showFailureSnackBar(
        context,
        _DetailFailure.capture(error, stackTrace),
      );
    }
  }

  Future<ImportedLibraryEntry> _ensureChapter(
    _DetailChapter chapter,
  ) async {
    final existing = chapter.libraryEntry;
    if (existing != null) {
      return existing;
    }
    final binding = _sourceBindings[chapter.sourceId];
    if (binding == null) {
      throw StateError('漫画源 ${chapter.sourceId} 当前不可用');
    }
    final comic = _mergeComic(
      _manifests[chapter.sourceId]?.comic ?? binding.initialComic(),
      binding.initialComic(),
    );
    final entry = await widget.ensureSourceChapter(
      binding.source,
      comic,
      chapter.chapter,
    );
    final next = <ImportedLibraryEntry>[
      for (final value in _libraryChapters)
        if (value.chapter.sourceId != entry.chapter.sourceId ||
            value.chapter.chapterId != entry.chapter.chapterId)
          value,
      entry,
    ];
    if (mounted) {
      setState(() => _libraryChapters = next);
    }
    if (!_preference.inShelf) {
      await _updatePreference(_preference.copyWith(inShelf: true));
    }
    return entry;
  }

  Future<void> _runChapter(
    _DetailChapter chapter, {
    required bool open,
  }) async {
    final workKey = '${chapter.sourceId}:${chapter.chapter.chapterId}';
    if (!_workingChapters.add(workKey)) {
      return;
    }
    setState(() {});
    try {
      final wasImported = chapter.libraryEntry != null;
      final entry = await _ensureChapter(chapter);
      if (!open) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已将“${chapter.chapter.title}”加入书架')),
          );
        }
        return;
      }
      await _markRead(entry, true);
      await widget.onOpenChapter(
        entry,
        refreshRemote: wasImported,
      );
      final snapshot = await widget.reloadLibrary(refreshContent: false);
      if (mounted) {
        setState(() => _applyLibrarySnapshot(snapshot));
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _workingChapters.remove(workKey));
      }
    }
  }

  Future<void> _markRead(
    ImportedLibraryEntry chapter,
    bool value,
  ) async {
    final chapterId = chapter.chapter.chapterId;
    final identity = comicDetailsChapterIdentity(
      chapter.chapter.sourceId,
      chapterId,
    );
    if (_readStates[identity] == value) {
      return;
    }
    final previous = _readStates[identity] ?? false;
    setState(() => _readStates = <String, bool>{
          ..._readStates,
          identity: value,
        });
    try {
      await widget.onReadChanged(chapter, value);
    } on Object catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      setState(() => _readStates = <String, bool>{
            ..._readStates,
            identity: previous,
          });
      _showFailureSnackBar(
        context,
        _DetailFailure.capture(error, stackTrace),
      );
    }
  }

  Future<void> _toggleShelf() async {
    if (_preference.inShelf) {
      await _updatePreference(_preference.copyWith(inShelf: false));
      return;
    }
    final imported =
        _projectedChapters.any((chapter) => chapter.libraryEntry != null);
    if (!imported) {
      final candidates = _projectedChapters;
      if (candidates.isEmpty) {
        return;
      }
      try {
        await _ensureChapter(candidates.first);
      } on Object catch (error, stackTrace) {
        if (mounted) {
          _showFailureSnackBar(
            context,
            _DetailFailure.capture(error, stackTrace),
          );
        }
        return;
      }
    }
    if (!_preference.inShelf) {
      await _updatePreference(_preference.copyWith(inShelf: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourceIds = _allSourceIds;
    final chapters = _projectedChapters;
    final comic = _primaryComic;
    final description = _primaryDescription;
    final compositeKeys = sourceIds.length > 1;
    final selectedFailure = _selectedSourceId == null
        ? (_failures.isEmpty ? null : _failures.values.first)
        : _failures[_selectedSourceId!];
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(
        title: const Text('漫画详情'),
        actions: <Widget>[
          IconButton(
            key: comicDetailsRefreshKey,
            tooltip: '更新详情',
            onPressed: _refreshing
                ? null
                : () => unawaited(_refresh(announce: true)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(announce: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 128,
                      height: 180,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _ComicDetailCover(
                          key: ValueKey<String>(
                            'detail-cover:${_primarySourceId}:${comic.coverUri}:$_coverRevision',
                          ),
                          sourceId: _primarySourceId,
                          coverUri: comic.coverUri,
                          fallbackChapter: _primaryCoverFallback,
                          loader: widget.loadCover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            comic.title,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (comic.authors.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            Text(comic.authors.join('、')),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            '${chapters.length} 章 · '
                            '${chapters.fold<int>(0, (total, item) => total + item.chapter.pageCount)} 页',
                          ),
                          if (description != null) ...<Widget>[
                            const SizedBox(height: 10),
                            Text(
                              description,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _PreferenceButton(
                                icon: _preference.liked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                label: '喜欢',
                                selected: _preference.liked,
                                onPressed: () => unawaited(
                                  _updatePreference(
                                    _preference.copyWith(
                                      liked: !_preference.liked,
                                    ),
                                  ),
                                ),
                              ),
                              _PreferenceButton(
                                icon: _preference.inShelf
                                    ? Icons.collections_bookmark
                                    : Icons.collections_bookmark_outlined,
                                label: '书架',
                                selected: _preference.inShelf,
                                onPressed: chapters.isEmpty
                                    ? null
                                    : () => unawaited(_toggleShelf()),
                              ),
                              _PreferenceButton(
                                icon: _preference.collected
                                    ? Icons.bookmark
                                    : Icons.bookmark_border,
                                label: '收藏',
                                selected: _preference.collected,
                                onPressed: () => unawaited(
                                  _updatePreference(
                                    _preference.copyWith(
                                      collected: !_preference.collected,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (sourceIds.length > 1)
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  key: comicDetailsSourceFilterKey,
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      ChoiceChip(
                        label: const Text('全部来源'),
                        selected: _selectedSourceId == null,
                        showCheckmark: false,
                        onSelected: (_) => setState(() {
                          _selectedSourceId = null;
                        }),
                      ),
                      for (final sourceId in sourceIds) ...<Widget>[
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(_sourceLabel(sourceId)),
                          selected: _selectedSourceId == sourceId,
                          showCheckmark: false,
                          onSelected: (_) => setState(() {
                            _selectedSourceId = sourceId;
                          }),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (widget.categories.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final category in widget.categories)
                        FilterChip(
                          label: Text(category.name),
                          selected: _preference.categoryIds.contains(
                            category.categoryId,
                          ),
                          onSelected: (_) {
                            final ids = _preference.categoryIds.toSet();
                            if (!ids.add(category.categoryId)) {
                              ids.remove(category.categoryId);
                            }
                            unawaited(
                              _updatePreference(
                                _preference.copyWith(categoryIds: ids),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            if (_refreshing)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            SliverToBoxAdapter(
              child: ListTile(
                title: const Text('漫画章节'),
                subtitle: Text(
                  compositeKeys
                      ? '按来源保留章节身份；已阅读章节可向右拖动恢复未读'
                      : '已阅读章节会黯淡；向右拖动可恢复未读',
                ),
                trailing: IconButton(
                  key: comicDetailsReverseKey,
                  tooltip: _descending ? '切换正序' : '切换倒序',
                  onPressed: () => setState(() => _descending = !_descending),
                  icon: Icon(_descending ? Icons.south : Icons.north),
                ),
              ),
            ),
            if (chapters.isEmpty && selectedFailure != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _DetailFailurePanel(
                  failure: selectedFailure,
                  onRetry: () => unawaited(_refresh(announce: false)),
                ),
              )
            else if (chapters.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    _refreshing ? '正在更新章节…' : '当前没有可读章节',
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final chapter = chapters[index];
                    final entry = chapter.libraryEntry;
                    final chapterId = chapter.chapter.chapterId;
                    final read = entry != null &&
                        (_readStates[comicDetailsChapterIdentity(
                              chapter.sourceId,
                              chapterId,
                            )] ??
                            false);
                    final workKey = '${chapter.sourceId}:$chapterId';
                    final working = _workingChapters.contains(workKey);
                    final subtitle = <String>[
                      if (compositeKeys) _sourceLabel(chapter.sourceId),
                      '${chapter.chapter.pageCount} 页',
                      if (chapter.chapter.publishedAt != null)
                        chapter.chapter.publishedAt!
                            .toLocal()
                            .toString()
                            .split(' ')
                            .first,
                      if (entry != null && !chapter.upstreamAvailable)
                        '本地保留',
                    ].join(' · ');
                    return Dismissible(
                      key: comicDetailsReadKey(
                        chapter.sourceId,
                        chapterId,
                        compositeKeys,
                      ),
                      direction: read
                          ? DismissDirection.startToEnd
                          : DismissDirection.none,
                      dismissThresholds: const <DismissDirection, double>{
                        DismissDirection.startToEnd: 0.18,
                      },
                      confirmDismiss: (_) async {
                        await _markRead(entry!, false);
                        return false;
                      },
                      background: Container(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: const Row(
                          children: <Widget>[
                            Icon(Icons.mark_chat_unread_outlined),
                            SizedBox(width: 8),
                            Text('恢复未读'),
                          ],
                        ),
                      ),
                      child: AnimatedOpacity(
                        opacity: read ? 0.42 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: ListTile(
                          key: comicDetailsChapterKey(
                            chapter.sourceId,
                            chapterId,
                            compositeKeys,
                          ),
                          leading: Icon(
                            read
                                ? Icons.check_circle_outline
                                : entry == null
                                    ? Icons.cloud_outlined
                                    : Icons.radio_button_unchecked,
                          ),
                          title: Text(chapter.chapter.title),
                          subtitle: Text(subtitle),
                          onTap: working
                              ? null
                              : () => unawaited(
                                    _runChapter(chapter, open: true),
                                  ),
                          trailing: working
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : entry == null
                                  ? IconButton(
                                      tooltip: '加入书架',
                                      onPressed: () => unawaited(
                                        _runChapter(chapter, open: false),
                                      ),
                                      icon: const Icon(
                                        Icons.bookmark_add_outlined,
                                      ),
                                    )
                                  : const Icon(Icons.chevron_right),
                        ),
                      ),
                    );
                  },
                  childCount: chapters.length,
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ),
      ),
    );
  }
}

final class _DetailChapter {
  const _DetailChapter({
    required this.sourceId,
    required this.chapter,
    required this.libraryEntry,
    required this.upstreamAvailable,
  });

  final String sourceId;
  final Chapter chapter;
  final ImportedLibraryEntry? libraryEntry;
  final bool upstreamAvailable;
}

int _compareDetailChapters(_DetailChapter left, _DetailChapter right) {
  final sequence = left.chapter.sequence.compareTo(right.chapter.sequence);
  if (sequence != 0) {
    return sequence;
  }
  final publishedLeft = left.chapter.publishedAt;
  final publishedRight = right.chapter.publishedAt;
  if (publishedLeft != null && publishedRight != null) {
    final published = publishedLeft.compareTo(publishedRight);
    if (published != 0) {
      return published;
    }
  } else if (publishedLeft != null) {
    return 1;
  } else if (publishedRight != null) {
    return -1;
  }
  final source = left.sourceId.compareTo(right.sourceId);
  if (source != 0) {
    return source;
  }
  return left.chapter.chapterId.compareTo(right.chapter.chapterId);
}

Comic _comicFromStored(ImportedChapterRecord chapter) {
  return Comic(
    comicId: chapter.comicId,
    sourceId: chapter.sourceId,
    title: chapter.comicTitle,
    authors: chapter.comicAuthors,
    coverUri: chapter.coverSourceId == null
        ? null
        : Uri.tryParse(chapter.coverSourceId!),
    description: chapter.comicDescription,
    readingDirection: chapter.readingDirection,
  );
}

Comic _mergeComic(Comic primary, Comic? fallback) {
  if (fallback == null) {
    return primary;
  }
  return Comic(
    comicId: primary.comicId,
    sourceId: primary.sourceId,
    title: primary.title,
    authors: primary.authors.isEmpty ? fallback.authors : primary.authors,
    coverUri: primary.coverUri ?? fallback.coverUri,
    description: primary.description ?? fallback.description,
    readingDirection: primary.readingDirection,
    createdAt: primary.createdAt ?? fallback.createdAt,
    updatedAt: primary.updatedAt ?? fallback.updatedAt,
  );
}

Chapter _chapterFromStored(ImportedChapterRecord chapter) {
  return Chapter(
    chapterId: chapter.chapterId,
    comicId: chapter.comicId,
    title: chapter.displayName,
    sequence: chapter.sequence,
    pageCount: chapter.pages.length,
    sourceRevision: chapter.sourceRevision,
  );
}

final class _PreferenceButton extends StatelessWidget {
  const _PreferenceButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: label,
      isSelected: selected,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

final class _ComicDetailCover extends StatefulWidget {
  const _ComicDetailCover({
    required this.sourceId,
    required this.coverUri,
    required this.fallbackChapter,
    required this.loader,
    super.key,
  });

  final String sourceId;
  final Uri? coverUri;
  final ImportedLibraryEntry? fallbackChapter;
  final ComicDetailsCoverLoader loader;

  @override
  State<_ComicDetailCover> createState() => _ComicDetailCoverState();
}

final class _ComicDetailCoverState extends State<_ComicDetailCover> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _ComicDetailCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId ||
        oldWidget.coverUri != widget.coverUri ||
        oldWidget.fallbackChapter?.chapter.chapterId !=
            widget.fallbackChapter?.chapter.chapterId) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() => widget.loader(
        sourceId: widget.sourceId,
        coverUri: widget.coverUri,
        fallbackChapter: widget.fallbackChapter,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
          );
        }
        if (snapshot.hasError) {
          return const _CoverPlaceholder();
        }
        return const ColoredBox(
          color: Color(0x14000000),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}

final class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.image_not_supported_outlined)),
    );
  }
}

final class _DetailFailure {
  const _DetailFailure({required this.summary, required this.details});

  factory _DetailFailure.capture(Object error, StackTrace stackTrace) {
    final lines = <String>[error.toString()];
    if (error is Failure && error.cause != null) {
      lines.add('Cause: ${error.cause}');
    }
    final stack = stackTrace.toString().trim();
    if (stack.isNotEmpty) {
      lines.add(stack);
    }
    return _DetailFailure(
      summary: error is Failure ? error.message : error.toString(),
      details: lines.join('\n\n'),
    );
  }

  final String summary;
  final String details;
}

final class _DetailFailurePanel extends StatelessWidget {
  const _DetailFailurePanel({
    required this.failure,
    required this.onRetry,
  });

  final _DetailFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: comicDetailsErrorKey,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.cloud_off_outlined, size: 40),
          const SizedBox(height: 12),
          Text(
            '漫画详情加载失败',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            failure.summary,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 112,
            child: SingleChildScrollView(
              child: SelectableText(failure.details),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            children: <Widget>[
              OutlinedButton.icon(
                key: comicDetailsCopyErrorKey,
                onPressed: () => unawaited(_copyFailure(context, failure)),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制完整错误'),
              ),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

void _showFailureSnackBar(BuildContext context, _DetailFailure failure) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        failure.summary,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      action: SnackBarAction(
        label: '复制',
        onPressed: () => unawaited(_copyFailure(context, failure)),
      ),
    ),
  );
}

Future<void> _copyFailure(
  BuildContext context,
  _DetailFailure failure,
) async {
  await Clipboard.setData(ClipboardData(text: failure.details));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('完整错误已复制')),
    );
  }
}
