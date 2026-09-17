part of 'demo_home.dart';

ComicVersionSource? _sourceVersionCapability(BrowsableComicSource source) {
  final Object candidate = source;
  if (candidate is! ComicVersionSource) return null;
  return candidate;
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

List<String> _sourceMigrationResultSummaryMessages(
  HomeSourceMigrationResult result,
) =>
    <String>[
      '漫画偏好已合并',
      if (result.migratedChapters > 0)
        '迁移 ${result.migratedChapters} 个已验证章节',
      if (result.migratedProgress > 0)
        '${result.migratedProgress} 个阅读位置',
      if (result.migratedReadStates > 0)
        '${result.migratedReadStates} 个已读状态',
      if (result.preservedTargetStates > 0)
        '保留 ${result.preservedTargetStates} 项目标源已有状态',
      if (result.registeredPageEquivalences > 0)
        '登记 ${result.registeredPageEquivalences} 页已验证媒体等价关系',
      if (result.materializedPageArtifacts > 0)
        '复用 ${result.materializedPageArtifacts} 页旧版离线文件到新 key',
      if (result.replacingSource)
        '旧版本记录已替换，未匹配的旧版离线文件仍保留'
      else
        '原来源与离线文件保留',
    ];

extension _DemoHomeSourceMigration on _DemoHomeState {
  Future<void> _recoverCommittedSourceMigrations() async {
    final changed = await _sourceMigrationTransaction.recoverCommitted();
    if (changed && mounted) {
      await _reloadLibrary();
    }
  }

  DateTime? _projectedConfirmedSourceUpdateAt(
    String sourceId,
    String comicId,
  ) {
    final family = _librarySession.versionBaselines.familyFor(
      sourceId,
      comicId,
    );
    if (family == null ||
        family.shelfHeadComicId != comicId ||
        family.latestKnownComicId == null ||
        family.latestKnownComicId == family.shelfHeadComicId) {
      return null;
    }
    return family.latestKnownDiscoveredAt ??
        DateTime.fromMicrosecondsSinceEpoch(1, isUtc: true);
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


  Future<void> _prepareVersionReuseWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
    TaskControl? control,
  }) =>
      _versionReuseLifecycle.prepareWarmup(
        source,
        focus,
        targetComicId: targetComicId,
        control: control,
      );

  void _scheduleReaderMetadataVersionRefresh(
    BrowsableComicSource source,
    ImportedLibraryEntry focus,
  ) =>
      _versionReuseLifecycle.scheduleReaderMetadataVersionRefresh(
        source,
        focus,
      );

  Future<int> _prepareReaderVersionAuthority(
    ImportedLibraryEntry current,
  ) async {
    final viewReusePreparation = _versionViewReusePreparationFor(current);
    final versionSource = _sourceForId(current.chapter.sourceId);
    if (viewReusePreparation != null) {
      await viewReusePreparation.future;
      if (versionSource != null) {
        await _prepareVersionReuseWarmup(
          versionSource,
          current,
          targetComicId: viewReusePreparation.originComicId,
        );
      }
    }
    return _ensureSourceVersionReuseAuthority(current);
  }

  Future<int> _ensureSourceVersionReuseAuthority(
    ImportedLibraryEntry current,
  ) =>
      _versionReuseLifecycle.ensureAuthority(current);

  details.ComicDetailsVersionState _detailsVersionState(
    HomeVersionState state,
  ) =>
      details.ComicDetailsVersionState(
        successors: state.successors,
        predecessors: state.predecessors,
        backgroundRefresh:
            state.backgroundRefresh?.then(_detailsVersionState),
      );

  Future<details.ComicDetailsVersionState> _loadSourceVersionState(
    BrowsableComicSource source,
    String title,
    String currentComicId, {
    TaskControl? control,
  }) async =>
      _detailsVersionState(
        await _versionReuseLifecycle.loadVersionState(
          source,
          title,
          currentComicId,
          control: control,
        ),
      );

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
      var latest = _librarySession.versionBaselines.latestKnownHeadFor(
        active.sourceId,
        summary.comicId,
      );
      if (latest == null || latest == summary.comicId) {
        try {
          await _loadSourceVersionState(
            active,
            summary.title,
            summary.comicId,
          );
          latest = _librarySession.versionBaselines.latestKnownHeadFor(
            active.sourceId,
            summary.comicId,
          );
        } on Object catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              copyableDiagnosticSnackBar('读取同源更新失败，将打开当前版本：$error'),
            );
          }
        }
      }
      if (latest != null && latest != summary.comicId && mounted) {
        await _viewSourceVersion(
          active,
          summary.comicId,
          SourceComicVersion(
            sourceId: active.sourceId,
            comicId: latest,
            title: summary.title,
            generation: 0,
          ),
        );
        return;
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
          copyableDiagnosticSnackBar('读取同源版本失败：$error'),
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
          copyableDiagnosticSnackBar('搜索目标漫画失败：$error'),
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
          copyableDiagnosticSnackBar('准备漫画迁移失败：$error'),
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


  String _versionViewReusePreparationKey(
    String sourceId,
    String comicId,
  ) =>
      '$sourceId\u0000$comicId';

  ({String originComicId, Future<void> future})
      _startVersionViewReusePreparation(
    BrowsableComicSource source,
    String currentComicId,
    String targetComicId,
  ) {
    final key = _versionViewReusePreparationKey(source.sourceId, targetComicId);
    final existing = _versionViewReusePreparations[key];
    if (existing != null) return existing;
    final current = _exactLibraryComicForSourceIdentity(
      source.sourceId,
      currentComicId,
    );
    final future = current != null && current.chapters.length == 1
        ? _prepareVersionReuseWarmup(
            source,
            current.chapters.single,
            targetComicId: targetComicId,
          )
        : Future<void>.value();
    final preparation = (
      originComicId: currentComicId,
      future: future,
    );
    _versionViewReusePreparations[key] = preparation;
    return preparation;
  }

  ({String originComicId, Future<void> future})?
      _versionViewReusePreparationFor(ImportedLibraryEntry entry) =>
          _versionViewReusePreparations[
            _versionViewReusePreparationKey(
              entry.chapter.sourceId,
              entry.chapter.comicId,
            )
          ];

  Future<void> _viewSourceVersion(
    BrowsableComicSource source,
    String currentComicId,
    SourceComicVersion version,
  ) async {
    if (version.sourceId != source.sourceId || version.comicId.isEmpty) return;
    final key = _versionViewReusePreparationKey(
      source.sourceId,
      version.comicId,
    );
    final preparation = _startVersionViewReusePreparation(
      source,
      currentComicId,
      version.comicId,
    );
    try {
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
    } finally {
      if (identical(_versionViewReusePreparations[key], preparation)) {
        _versionViewReusePreparations.remove(key);
      }
    }
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
    final shouldResolveCanonicalAlias = resolveCanonicalAlias &&
        !_sourceSupportsVersionEntry(source);
    final existing = shouldResolveCanonicalAlias
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
      final migrationId = sourceMigrationJournalId(
        sourceSourceId: comic.sourceId,
        sourceComicId: comic.comicId,
        targetSourceId: request.source.sourceId,
        targetComicId: request.id,
      );
      if (await _sourceMigrationTransaction.resumeCommitted(migrationId)) {
        await _reloadLibrary();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已完成上次中断的漫画源迁移清理')),
          );
        }
        return;
      }

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
      if (!mounted) return;
      final sourceDescriptor = _sourceForId(comic.sourceId)?.descriptor;
      final confirmed = await showSourceMigrationComparison(
        context: context,
        plan: plan,
        sourceName: sourceDescriptor?.name ?? comic.sourceId,
        targetName: request.source.descriptor.name,
        replaceSource: replacingSource,
        loadSourceCover:
            comic.coverSourceId == null && comic.coverChapter == null
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
      if (!confirmed) return;

      final result = await _sourceMigrationTransaction.executeConfirmed(
        sourceComic: comic,
        targetSource: request.source,
        targetManifest: manifest,
        plan: plan,
        replacingSource: replacingSource,
        sourcePreference: _preferenceForComic(comic),
        targetCustomOrder: _nextCustomOrder,
      );
      await _reloadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _sourceMigrationResultSummaryMessages(result).join(' · '),
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(copyableDiagnosticSnackBar('漫画源迁移失败：$error'));
      }
    }
  }
}
