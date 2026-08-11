part of 'demo_home.dart';

final class _PreparedChapterMigration {
  const _PreparedChapterMigration({
    required this.targetRecord,
    required this.sourceProgress,
    required this.sourceReadState,
    required this.targetProgress,
    required this.targetReadState,
    required this.artifactReuse,
  });
  final ImportedChapterRecord targetRecord;
  final ReadingProgress? sourceProgress;
  final ChapterReadState? sourceReadState;
  final ReadingProgress? targetProgress;
  final ChapterReadState? targetReadState;
  final VerifiedArtifactReusePlan artifactReuse;
}

ComicVersionSource? _sourceVersionCapability(BrowsableComicSource source) {
  final Object candidate = source;
  if (candidate is! ComicVersionSource) return null;
  return candidate as ComicVersionSource;
}

bool _sourceSupportsVersionEntry(BrowsableComicSource source) =>
    _sourceVersionCapability(source)?.supportsComicVersions == true;

String sourceVersionViewIdentity({
  required String sourceId,
  required String currentComicId,
  required String targetComicId,
}) =>
    'source-version-view:$sourceId\u0000$currentComicId\u0000$targetComicId';

String _sourcePluginLabel(String sourceId) {
  if (sourceId.startsWith('mihon:')) return 'Mihon 插件';
  if (sourceId.startsWith('venera:')) return 'Venera 插件';
  return '内置源适配器';
}

final class _SourceMigrationSelection {
  const _SourceMigrationSelection.request({
    required this.source,
    required String comicId,
  })  : comicId = comicId,
        version = null,
        viewOnly = false;

  const _SourceMigrationSelection.version({
    required this.source,
    required SourceComicVersion version,
    required this.viewOnly,
  })  : comicId = null,
        version = version;

  final BrowsableComicSource source;
  final String? comicId;
  final SourceComicVersion? version;
  final bool viewOnly;
}

extension _DemoHomeSourceMigration on _DemoHomeState {
  ComicVersionRelationStore? _comicVersionRelationStore() {
    final candidate = _library;
    if (candidate is! ComicVersionRelationStore) return null;
    return candidate as ComicVersionRelationStore;
  }

  Future<List<SourceComicVersion>> _storedSourceSuccessors({
    required String sourceId,
    required String predecessorComicId,
  }) async {
    final store = _comicVersionRelationStore();
    if (store == null) {
      return const <SourceComicVersion>[];
    }
    final relations = await store.listComicVersionSuccessors(
      sourceId,
      predecessorComicId,
    );
    return <SourceComicVersion>[
      for (var index = 0; index < relations.length; index++)
        if (relations[index].successorComicId.isNotEmpty &&
            relations[index].successorComicId != predecessorComicId)
          SourceComicVersion(
            sourceId: sourceId,
            comicId: relations[index].successorComicId,
            title: '',
            generation: relations.length - index,
          ),
    ];
  }

  Future<List<SourceComicVersion>> _storedSourcePredecessors({
    required String sourceId,
    required String successorComicId,
  }) async {
    final store = _comicVersionRelationStore();
    if (store == null) return const <SourceComicVersion>[];
    final relations = await store.listComicVersionPredecessors(
      sourceId,
      successorComicId,
    );
    return <SourceComicVersion>[
      for (var index = 0; index < relations.length; index++)
        if (relations[index].predecessorComicId.isNotEmpty &&
            relations[index].predecessorComicId != successorComicId)
          SourceComicVersion(
            sourceId: sourceId,
            comicId: relations[index].predecessorComicId,
            title: relations[index].predecessorTitle,
            generation: index + 1,
            isPredecessor: true,
          ),
    ];
  }

  Future<void> _rememberSourceSuccessors({
    required BrowsableComicSource source,
    required String predecessorComicId,
    required String predecessorTitle,
    required Iterable<SourceComicVersion> successors,
  }) async {
    final store = _comicVersionRelationStore();
    if (store == null) {
      return;
    }
    for (final successor in successors) {
      if (successor.isPredecessor ||
          successor.sourceId != source.sourceId ||
          successor.comicId.isEmpty ||
          successor.comicId == predecessorComicId) {
        continue;
      }
      await _librarySession.upsertVersionRelation(
        ComicVersionRelation(
          sourceId: source.sourceId,
          predecessorComicId: predecessorComicId,
          successorComicId: successor.comicId,
          predecessorTitle: predecessorTitle,
          discoveredAt: DateTime.now().toUtc(),
        ),
      );
    }
    // The relation itself is the durable version-update fact. Do not mirror it
    // into SavedComicRecord.sourceUpdateAt: that field remains chapter/catalog
    // update state, while Home/source presentation reads version relations from
    // HomeLibrarySession's synchronous projection.
  }

  DateTime? _projectedConfirmedSourceUpdateAt(
    String sourceId,
    String comicId,
  ) {
    final aliases = _canonicalComicAliases(sourceId, comicId);
    DateTime? latest;
    for (final relation in _versionRelations) {
      if (relation.sourceId != sourceId ||
          !aliases.contains(relation.predecessorComicId) ||
          relation.successorComicId.isEmpty ||
          aliases.contains(relation.successorComicId)) {
        continue;
      }
      final discoveredAt = relation.discoveredAt;
      if (discoveredAt != null &&
          (latest == null || discoveredAt.isAfter(latest))) {
        latest = discoveredAt;
      } else if (discoveredAt == null && latest == null) {
        latest = DateTime.fromMicrosecondsSinceEpoch(1, isUtc: true);
      }
    }
    return latest;
  }

  DateTime? _sourceUpdateAtForComic(LibraryComic comic) {
    final versionUpdateAt = _projectedConfirmedSourceUpdateAt(
      comic.sourceId,
      comic.comicId,
    );
    final catalogUpdateAt = comic.sourceUpdateAt;
    if (versionUpdateAt == null) return catalogUpdateAt;
    if (catalogUpdateAt == null || versionUpdateAt.isAfter(catalogUpdateAt)) {
      return versionUpdateAt;
    }
    return catalogUpdateAt;
  }

  Future<bool> _hasConfirmedSourceSuccessor(
    String sourceId,
    String comicId,
  ) async {
    if (_projectedConfirmedSourceUpdateAt(sourceId, comicId) != null) {
      return true;
    }
    final store = _comicVersionRelationStore();
    if (store == null) return false;
    for (final alias in _canonicalComicAliases(sourceId, comicId)) {
      final relations = await store.listComicVersionSuccessors(
        sourceId,
        alias,
      );
      if (relations.any(
        (relation) => relation.successorComicId.isNotEmpty &&
            relation.successorComicId != alias,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<int> _prepareSourceVersionArtifactReuse(
    ImportedLibraryEntry current,
  ) async {
    final artifactCache = _readerArtifactCache;
    final store = _comicVersionRelationStore();
    if (artifactCache == null ||
        store == null ||
        _sourceForId(current.chapter.sourceId) == null) {
      return 0;
    }
    final predecessorRelations = await store.listComicVersionPredecessors(
      current.chapter.sourceId,
      current.chapter.comicId,
    );
    final successorRelations = await store.listComicVersionSuccessors(
      current.chapter.sourceId,
      current.chapter.comicId,
    );
    final relatedComicIds = <String>{
      for (final relation in predecessorRelations)
        if (relation.predecessorComicId.isNotEmpty &&
            relation.predecessorComicId != current.chapter.comicId)
          relation.predecessorComicId,
      for (final relation in successorRelations)
        if (relation.successorComicId.isNotEmpty &&
            relation.successorComicId != current.chapter.comicId)
          relation.successorComicId,
    };
    if (relatedComicIds.isEmpty) return 0;

    var reused = 0;
    var candidateChapters = 0;
    for (final relatedComicId in relatedComicIds) {
      final sourceEntries = _libraryEntries.where(
        (entry) =>
            entry.chapter.sourceId == current.chapter.sourceId &&
            entry.chapter.comicId == relatedComicId &&
            entry.chapter.sequence == current.chapter.sequence,
      );
      for (final sourceEntry in sourceEntries) {
        candidateChapters++;
        final plan = await VerifiedArtifactReusePlan.matchResolvedRelated(
          sourceChapter: sourceEntry.chapter.toManifest(),
          targetChapter: current.chapter.toManifest(),
          resolveIdentity: (page) =>
              _sourceResources.verifiedPageReuseIdentity(
            sourceId: current.chapter.sourceId,
            locator: page.uri,
          ),
        );
        reused += await plan.applyExisting(artifactCache);
      }
    }
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-version-reuse:${current.chapter.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash: '${current.chapter.sourceId}\u0000${current.chapter.chapterId}',
        payload: <String, Object?>{
          'stage': 'version-artifact-alias-prepared',
          'relationCount': relatedComicIds.length,
          'predecessorRelations': predecessorRelations.length,
          'successorRelations': successorRelations.length,
          'candidateChapters': candidateChapters,
          'reusedPages': reused,
        },
      ),
    );
    return reused;
  }

  Future<details.ComicDetailsVersionState> _loadSourceVersionState(
    BrowsableComicSource source,
    String title,
    String currentComicId,
  ) async {
    final versionSource = _sourceVersionCapability(source);
    if (versionSource == null || !versionSource.supportsComicVersions) {
      return const details.ComicDetailsVersionState();
    }
    final storedSuccessors = await _storedSourceSuccessors(
      sourceId: source.sourceId,
      predecessorComicId: currentComicId,
    );
    final storedPredecessors = await _storedSourcePredecessors(
      sourceId: source.sourceId,
      successorComicId: currentComicId,
    );
    var discovered = const <SourceComicVersion>[];
    try {
      discovered = await versionSource.findComicVersions(currentComicId);
      await _rememberSourceSuccessors(
        source: source,
        predecessorComicId: currentComicId,
        predecessorTitle: title,
        successors: discovered.where((item) => !item.isPredecessor),
      );
    } on Object {
      if (storedSuccessors.isEmpty && storedPredecessors.isEmpty) rethrow;
    }

    List<SourceComicVersion> merge(
      Iterable<SourceComicVersion> values, {
      required bool predecessor,
    }) {
      final identities = <String>{};
      final result = <SourceComicVersion>[];
      for (final item in values) {
        if (item.isPredecessor != predecessor ||
            item.sourceId != source.sourceId ||
            item.comicId.isEmpty ||
            item.comicId == currentComicId ||
            !identities.add(item.comicId)) {
          continue;
        }
        result.add(item);
      }
      result.sort((left, right) {
        final generation = predecessor
            ? left.generation.compareTo(right.generation)
            : right.generation.compareTo(left.generation);
        if (generation != 0) return generation;
        return left.comicId.compareTo(right.comicId);
      });
      return List<SourceComicVersion>.unmodifiable(result);
    }

    return details.ComicDetailsVersionState(
      successors: merge(
        <SourceComicVersion>[...discovered, ...storedSuccessors],
        predecessor: false,
      ),
      predecessors: merge(
        <SourceComicVersion>[...discovered, ...storedPredecessors],
        predecessor: true,
      ),
    );
  }

  bool _sourceComicHasUpdate(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) {
    final inShelf = _mergedPreferenceFor(
      source.sourceId,
      summary.comicId,
      fallbackSourceKind: ComicSourceKind.remote,
      fallbackInShelf: false,
    ).inShelf;
    if (!inShelf) return false;
    if (_projectedConfirmedSourceUpdateAt(
          source.sourceId,
          summary.comicId,
        ) !=
        null) {
      return true;
    }
    return _savedComicAliasesFor(source.sourceId, summary.comicId)
        .any((saved) => saved.sourceUpdateAt != null);
  }

  Future<void> _openSourceUpdateForSummary(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) async {
    final active = _sourceForId(source.sourceId) ?? source;
    if (_sourceSupportsVersionEntry(active)) {
      try {
        final state = await _loadSourceVersionState(
          active,
          summary.title,
          summary.comicId,
        );
        if (state.successors.isNotEmpty && mounted) {
          await _viewSourceVersion(
            active,
            summary.comicId,
            state.successors.first,
          );
          return;
        }
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取同源更新失败，将打开当前版本：$error')),
          );
        }
      }
    }
    if (mounted) {
      await _openSourceComic(active, summary);
    }
  }

  Future<_SourceMigrationSelection?> _selectConfirmedSourceVersion(
    LibraryComic comic,
    BrowsableComicSource source,
  ) async {
    try {
      final state = await _loadSourceVersionState(
        source,
        comic.title,
        comic.comicId,
      );
      if (!mounted) return null;
      final versions = <SourceComicVersion>[
        ...state.successors,
        ...state.predecessors,
      ];
      if (versions.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前来源没有已确认的同源版本关系')),
        );
        return null;
      }
      return showDialog<_SourceMigrationSelection>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('同源版本 · ${source.descriptor.name}'),
          content: SizedBox(
            width: 560,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final version in versions)
                  ListTile(
                    title: Text(
                      version.title.trim().isEmpty
                          ? version.comicId
                          : version.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      <String>[
                        version.isPredecessor ? '旧版' : '新版',
                        if (version.date != null && version.date!.isNotEmpty)
                          version.date!,
                        version.comicId,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.pop(
                            context,
                            _SourceMigrationSelection.version(
                              source: source,
                              version: version,
                              viewOnly: true,
                            ),
                          ),
                          child: const Text('查看'),
                        ),
                        FilledButton.tonal(
                          onPressed: () => Navigator.pop(
                            context,
                            _SourceMigrationSelection.version(
                              source: source,
                              version: version,
                              viewOnly: false,
                            ),
                          ),
                          child: Text(
                            version.isPredecessor ? '迁移旧版状态' : '迁移到此版本',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取同源版本失败：$error')),
        );
      }
      return null;
    }
  }

  Future<_SourceMigrationSelection?> _selectSourceMigrationTarget(
    LibraryComic comic,
    List<BrowsableComicSource> targets,
  ) async {
    var target = targets.firstWhere(
      (source) => source.sourceId == comic.sourceId,
      orElse: () => targets.first,
    );
    final currentSource = _sourceForId(comic.sourceId);
    final controller = TextEditingController();
    final choice = await showDialog<
        ({BrowsableComicSource source, String? id, bool search, bool versions})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final sameSource = target.sourceId == comic.sourceId;
          return AlertDialog(
            title: const Text('迁移漫画源'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('当前插件：${_sourcePluginLabel(comic.sourceId)}'),
                  const SizedBox(height: 4),
                  Text(
                    '当前来源：${currentSource?.descriptor.name ?? comic.sourceId}',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: target.sourceId,
                    decoration: const InputDecoration(labelText: '目标漫画源'),
                    items: <DropdownMenuItem<String>>[
                      for (final source in targets)
                        DropdownMenuItem<String>(
                          value: source.sourceId,
                          child: Text(source.descriptor.name),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        target = targets.firstWhere(
                          (source) => source.sourceId == value,
                        );
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      labelText:
                          sameSource ? '目标版本 ID（可选）' : '目标漫画 ID（可选）',
                      helperText: sameSource
                          ? '同源版本优先使用来源确认关系；也可明确填写插件原生 ID'
                          : '通常搜索同名作品；仅在搜索不到时手动填写原生 ID',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sameSource
                        ? '同源版本关系只接受插件/已存关系确认；迁移仍会先显示章节、偏好和阅读状态对比。'
                        : '跨来源候选可通过标题搜索发现，但只有你明确选择后才进入迁移对比；不会自动认定为同一作品。',
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (sameSource && _sourceSupportsVersionEntry(target))
                TextButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    (source: target, id: null, search: false, versions: true),
                  ),
                  icon: const Icon(Icons.compare_arrows),
                  label: const Text('已确认同源版本'),
                )
              else if (!sameSource && target.descriptor.supportsSearch)
                TextButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    (source: target, id: null, search: true, versions: false),
                  ),
                  icon: const Icon(Icons.search),
                  label: const Text('搜索同名作品'),
                ),
              FilledButton(
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(
                          context,
                          (
                            source: target,
                            id: controller.text.trim(),
                            search: false,
                            versions: false,
                          ),
                        ),
                child: const Text('使用漫画 ID'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (choice == null || !mounted) return null;

    if (choice.versions) {
      return _selectConfirmedSourceVersion(comic, choice.source);
    }
    if (!choice.search && choice.id != null) {
      return _SourceMigrationSelection.request(
        source: choice.source,
        comicId: choice.id!,
      );
    }

    try {
      final page = await choice.source.browse(query: comic.title, limit: 12);
      if (!mounted) return null;
      if (page.items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${choice.source.descriptor.name} 未找到“${comic.title}”；可重试并手动填写漫画 ID',
            ),
          ),
        );
        return null;
      }
      final candidate = await showDialog<SourceComicSummary>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('选择 ${choice.source.descriptor.name} 中的目标作品'),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final item in page.items)
                  ListTile(
                    onTap: () => Navigator.pop(context, item),
                    title: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      <String>[
                        if (item.authors.isNotEmpty) item.authors.join('、'),
                        item.comicId,
                      ].join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (candidate == null) return null;
      if (candidate.sourceId != choice.source.sourceId) {
        throw StateError('目标漫画源搜索返回了不匹配的来源身份');
      }
      return _SourceMigrationSelection.request(
        source: choice.source,
        comicId: candidate.comicId,
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索目标漫画失败：$error')),
        );
      }
      return null;
    }
  }

  Future<void> _openSourceMigrationForSummary(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) async {
    try {
      final comic = await _materializeSourceComic(
        source,
        summary,
        resolveCanonicalAlias: false,
      );
      if (mounted) await _openSourceMigration(comic);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('准备漫画迁移失败：$error')),
        );
      }
    }
  }

  Future<void> _openSourceMigration(LibraryComic comic) async {
    final targets = _enabledSources.toList(growable: false);
    if (targets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有已启用漫画源可用于迁移')),
        );
      }
      return;
    }
    final selection = await _selectSourceMigrationTarget(comic, targets);
    if (selection == null || !mounted) return;
    final version = selection.version;
    if (version != null) {
      if (selection.viewOnly) {
        await _viewSourceVersion(selection.source, comic.comicId, version);
      } else {
        await _migrateSourceVersion(comic, version);
      }
      return;
    }
    final comicId = selection.comicId;
    if (comicId == null || comicId.isEmpty) return;
    await _applySourceMigration(
      comic,
      (source: selection.source, id: comicId),
    );
  }


  Future<void> _viewSourceVersion(
    BrowsableComicSource source,
    String currentComicId,
    SourceComicVersion version,
  ) async {
    if (version.sourceId != source.sourceId || version.comicId.isEmpty) return;
    await _openSourceComic(
      source,
      SourceComicSummary(
        sourceId: source.sourceId,
        comicId: version.comicId,
        title: version.title.trim().isEmpty ? version.comicId : version.title,
        authors: const <String>[],
      ),
      resolveCanonicalAlias: false,
      openingIdentity: sourceVersionViewIdentity(
        sourceId: source.sourceId,
        currentComicId: currentComicId,
        targetComicId: version.comicId,
      ),
    );
  }

  Future<void> _migrateSourceVersion(
    LibraryComic current,
    SourceComicVersion version,
  ) async {
    final source = _sourceForId(current.sourceId);
    if (source == null || version.sourceId != source.sourceId) return;
    if (!version.isPredecessor) {
      await _applySourceMigration(
        current,
        (source: source, id: version.comicId),
      );
      return;
    }
    final predecessor = await _materializeSourceComic(
      source,
      SourceComicSummary(
        sourceId: source.sourceId,
        comicId: version.comicId,
        title: version.title.trim().isEmpty ? version.comicId : version.title,
        authors: const <String>[],
      ),
      resolveCanonicalAlias: false,
    );
    await _applySourceMigration(
      predecessor,
      (source: source, id: current.comicId),
    );
  }

  Future<LibraryComic> _materializeSourceComic(
    BrowsableComicSource source,
    SourceComicSummary summary, {
    bool resolveCanonicalAlias = true,
  }) async {
    final existing = resolveCanonicalAlias
        ? _libraryComicForSourceIdentity(source.sourceId, summary.comicId)
        : _exactLibraryComicForSourceIdentity(
            source.sourceId,
            summary.comicId,
          );
    if (existing != null) {
      return existing;
    }
    final manifest = await source.loadComic(summary.comicId);
    if (manifest.comic.sourceId != source.sourceId ||
        manifest.comic.comicId != summary.comicId ||
        manifest.chapters.any((chapter) => chapter.comicId != summary.comicId)) {
      throw StateError('当前漫画源返回了不匹配的漫画或章节身份');
    }
    final entries = _libraryEntries
        .where(
          (entry) =>
              entry.chapter.sourceId == source.sourceId &&
              entry.chapter.comicId == summary.comicId,
        )
        .toList(growable: false);
    final now = DateTime.now().toUtc();
    return LibraryComic(
      sourceId: manifest.comic.sourceId,
      comicId: manifest.comic.comicId,
      title: manifest.comic.title,
      authors: manifest.comic.authors,
      tags: manifest.comic.tags,
      description: manifest.comic.description,
      coverSourceId: manifest.comic.coverUri?.toString(),
      readingDirection: manifest.comic.readingDirection,
      chapters: entries,
      sourceChapters: manifest.chapters,
      savedAt: now,
      metadataUpdatedAt: manifest.comic.updatedAt ?? now,
    );
  }

  Future<void> _applySourceMigration(
    LibraryComic comic,
    ({BrowsableComicSource source, String id}) request,
  ) async {
    try {
      final replacingSource =
          request.source.sourceId == comic.sourceId &&
          request.id != comic.comicId;
      final manifest = await request.source.loadComic(request.id);
      if (manifest.comic.sourceId != request.source.sourceId ||
          manifest.comic.comicId != request.id ||
          manifest.chapters.any((chapter) => chapter.comicId != request.id)) {
        throw StateError('目标漫画源返回了不匹配的漫画或章节身份');
      }
      final plan = ComicSourceMigrationPlan.build(
        source: comic,
        target: manifest,
      );
      final sourceDescriptor = _sourceForId(comic.sourceId)?.descriptor;
      final confirmed = await showSourceMigrationComparison(
        context: context,
        plan: plan,
        sourceName: sourceDescriptor?.name ?? comic.sourceId,
        targetName: request.source.descriptor.name,
        replaceSource: replacingSource,
        loadSourceCover: comic.coverSourceId == null && comic.coverChapter == null
            ? null
            : _migrationCoverLoaderForComic(comic),
        loadTargetCover: manifest.comic.coverUri == null
            ? null
            : () => _sourceResources.loadArtworkBytes(
                  cache: _cacheCoordinator.responses,
                  sourceId: request.source.sourceId,
                  comicId: manifest.comic.comicId,
                  cacheComicId: _canonicalComicId(
                    request.source.sourceId,
                    manifest.comic.comicId,
                  ),
                  uri: manifest.comic.coverUri!,
                ),
      );
      if (!confirmed) {
        return;
      }

      // Resolve and validate every target chapter before the first durable
      // write. A late source identity error must not leave a half-created
      // target comic or preference behind.
      final targetReadStates = <String, ChapterReadState>{
        for (final state in await _library.listChapterReadStates(
          manifest.comic.sourceId,
          manifest.comic.comicId,
        ))
          state.identity: state,
      };
      final prepared = <_PreparedChapterMigration>[];
      for (final match in plan.chapterMatches) {
        if (match.confidence != ChapterMigrationConfidence.exact) {
          continue;
        }
        final targetManifest =
            await request.source.loadChapter(match.target.chapterId);
        if (targetManifest.sourceId != manifest.comic.sourceId ||
            targetManifest.comicId != manifest.comic.comicId ||
            targetManifest.chapter.chapterId != match.target.chapterId) {
          throw StateError('目标漫画源返回了不匹配的章节详情身份');
        }
        final targetRecord = ImportedChapterRecord.remote(
          comic: manifest.comic,
          manifest: targetManifest,
        );
        final targetEntry = await _library.get(
          targetRecord.sourceId,
          targetRecord.chapterId,
        );
        prepared.add(
          _PreparedChapterMigration(
            targetRecord: targetRecord,
            sourceProgress: match.source.progress,
            sourceReadState: _chapterReadStates[chapterLibraryIdentity(
              match.source.chapter.sourceId,
              match.source.chapter.chapterId,
            )],
            targetProgress: targetEntry?.progress,
            targetReadState: targetReadStates[chapterLibraryIdentity(
              targetRecord.sourceId,
              targetRecord.chapterId,
            )],
            artifactReuse: VerifiedArtifactReusePlan.match(
              oldChapter: match.source.chapter.toManifest(),
              newChapter: targetManifest,
            ),
          ),
        );
      }

      final migrationTime = DateTime.now().toUtc();
      final existingSaved = await _library.getSavedComic(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      final existingPreference = await _library.getComicPreference(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      final mergedPreference = plan.mergePreference(
        _preferenceForComic(comic),
        existingTarget: existingPreference,
        targetCustomOrder: _nextCustomOrder,
        updatedAt: migrationTime,
      );

      await _librarySession.upsertSavedComic(
        SavedComicRecord.fromManifest(
          manifest,
          canonicalComicId: _canonicalComicIdForPersistence(
            manifest.comic.sourceId,
            manifest.comic.comicId,
            fallback: existingSaved?.canonicalComicId,
          ),
          savedAt: existingSaved?.savedAt,
          updatedAt: migrationTime,
        ),
      );
      await _savePreference(mergedPreference);

      var migratedChapters = 0;
      var migratedProgress = 0;
      var migratedReadStates = 0;
      var preservedTargetStates = 0;
      var reusedPageArtifacts = 0;
      for (final item in prepared) {
        final targetRecord = item.targetRecord;
        await _librarySession.upsertChapter(targetRecord);
        migratedChapters++;
        final artifactCache = _readerArtifactCache;
        if (artifactCache != null) {
          reusedPageArtifacts +=
              await item.artifactReuse.applyExisting(artifactCache);
        }

        final sourceProgress = item.sourceProgress;
        if (item.targetProgress != null) {
          preservedTargetStates++;
        } else if (sourceProgress != null) {
          final pageIndex = sourceProgress.pageIndex
              .clamp(0, targetRecord.pages.length - 1)
              .toInt();
          await _librarySession.persistProgress(
            ReadingProgress(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              pageIndex: pageIndex,
              subPageOffset: pageIndex == sourceProgress.pageIndex
                  ? sourceProgress.subPageOffset
                  : 0,
              readerMode: sourceProgress.readerMode,
              updatedAt: migrationTime,
            ),
          );
          migratedProgress++;
        }

        final sourceRead = item.sourceReadState;
        if (item.targetReadState != null) {
          preservedTargetStates++;
        } else if (sourceRead != null) {
          await _library.saveChapterReadState(
            ChapterReadState(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              isRead: sourceRead.isRead,
              updatedAt: migrationTime,
            ),
          );
          migratedReadStates++;
        }
      }
      if (replacingSource) {
        final sourcePreference = _preferenceForComic(comic);
        final neutralSourcePreference = ComicPreference(
          sourceId: sourcePreference.sourceId,
          comicId: sourcePreference.comicId,
          sourceKind: sourcePreference.sourceKind,
          inShelf: false,
          liked: false,
          collected: false,
          categoryIds: const <String>{},
          customOrder: sourcePreference.customOrder,
          updatedAt: migrationTime,
        );
        await _library.saveComicPreference(neutralSourcePreference);
        _librarySession.replacePreference(neutralSourcePreference);
        for (final entry in comic.chapters) {
          await _librarySession.removeChapter(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          );
        }
        await _librarySession.removeSavedComic(comic.sourceId, comic.comicId);
      }
      await _reloadLibrary();
      if (mounted) {
        final messages = <String>[
          '漫画偏好已合并',
          if (migratedChapters > 0) '迁移 $migratedChapters 个已验证章节',
          if (migratedProgress > 0) '$migratedProgress 个阅读位置',
          if (migratedReadStates > 0) '$migratedReadStates 个已读状态',
          if (preservedTargetStates > 0)
            '保留 $preservedTargetStates 项目标源已有状态',
          if (reusedPageArtifacts > 0)
            '复用 $reusedPageArtifacts 页已验证缓存',
          if (replacingSource)
            '旧版本记录已替换，离线文件需在下载管理中单独清理'
          else
            '原来源与离线文件保留',
        ];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(messages.join(' · '))),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('漫画源迁移失败：$error')),
        );
      }
    }
  }
}
