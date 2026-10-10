part of 'home_shell.dart';

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
  if (sourceId.startsWith('mihon:')) return 'Mihon';
  if (sourceId.startsWith('venera:')) return 'Venera';
  return '内置源';
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
        '复用 ${result.materializedPageArtifacts} 页已验证的旧版离线文件',
      if (result.replacingSource)
        '旧版本记录已替换，未匹配的旧版离线文件仍保留'
      else
        '原来源与离线文件保留',
    ];

final class _SourceMigrationVersionNotice extends StatelessWidget {
  const _SourceMigrationVersionNotice({
    required this.state,
    required this.webUriFor,
    required this.onSelected,
  });

  final Future<details.ComicDetailsVersionState> state;
  final Uri Function(SourceComicVersion) webUriFor;
  final ValueChanged<({SourceComicVersion version, bool viewOnly})> onSelected;

  @override
  Widget build(BuildContext context) => FutureBuilder<details.ComicDetailsVersionState>(
    future: state,
    builder: (context, snapshot) {
      final initial = snapshot.data;
      if (initial == null) {
        return snapshot.hasError ? const Text('同源版本暂时不可用') : const SizedBox.shrink();
      }
      return FutureBuilder<details.ComicDetailsVersionState>(
        initialData: initial,
        future: initial.backgroundRefresh,
        builder: (context, snapshot) {
          final state = snapshot.data ?? initial;
          if (state.isEmpty) return const SizedBox.shrink();
          return ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: Icon(Icons.update, color: Theme.of(context).colorScheme.primary),
            title: Text(state.successors.isNotEmpty ? '发现同源更新' : '存在旧版本'),
            subtitle: Text(<String>[
              if (state.successors.isNotEmpty) '${state.successors.length} 个新版',
              if (state.predecessors.isNotEmpty) '${state.predecessors.length} 个旧版',
            ].join(' · ')),
            children: <Widget>[
              ConfirmedSourceVersionList(
                versions: <SourceComicVersion>[...state.successors, ...state.predecessors],
                webUriFor: webUriFor,
                onSelected: onSelected,
              ),
            ],
          );
        },
      );
    },
  );
}

extension _HomeShellSourceMigration on _HomeShellState {
  Future<void> _recoverCommittedSourceMigrations() {
    final existing = _sourceMigrationRecovery;
    if (existing != null) return existing;
    late final Future<void> recovery;
    recovery = _recoverCommittedSourceMigrationsOnce().whenComplete(() {
      if (identical(_sourceMigrationRecovery, recovery)) {
        _sourceMigrationRecovery = null;
      }
    });
    _sourceMigrationRecovery = recovery;
    return recovery;
  }

  Future<void> _recoverCommittedSourceMigrationsOnce() async {
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
    final preference =
        _preferences[comicLibraryIdentity(sourceId, comicId)];
    if (preference?.acknowledgedVersionComicId == family.latestKnownComicId) {
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

  Future<_SourceMigrationSelection?> _selectSourceMigrationTarget(
    LibraryComic comic, {
    Future<details.ComicDetailsVersionState>? versionState,
  }) async {
    final current = _sourceForId(comic.sourceId);
    final versions = versionState ?? (current != null && _sourceSupportsVersionEntry(current)
        ? _loadSourceVersionState(current, comic.title, comic.comicId) : null);
    var selectedTarget = false;
    final route = MaterialPageRoute<_SourceMigrationSelection>(
      builder: (context) => StreamBuilder<void>(
        stream: _externalSources.sourceProjectionChanges,
        builder: (context, _) {
          final currentSource = _sourceForId(comic.sourceId);
          void choose(_SourceMigrationSelection selection) {
            if (selectedTarget || !context.mounted ||
                ModalRoute.of(context)?.isCurrent != true) return;
            selectedTarget = true;
            Navigator.pop(context, selection);
          }
          return ComicTitleSearchPage(
            title: '迁移漫画源',
            inputLabel: '搜索标题或链接',
            query: comic.title,
            sources: _enabledSources,
            onPrepareSources: () => unawaited(_externalSources.ensureSourcesPublished()),
            resolveSource: _sourceForId,
            loadCover: _loadSourceBrowseCover,
            onOpenSourceWebView: _openSourceWebView,
            isComicVisible: (source, candidate) =>
                source.sourceId != comic.sourceId || candidate.comicId != comic.comicId,
            onOpenComic: (source, candidate) async {
              if (candidate.sourceId != source.sourceId) {
                ScaffoldMessenger.of(context).showSnackBar(
                  copyableDiagnosticSnackBar('目标漫画源搜索返回了不匹配的来源身份'),
                );
                return;
              }
              choose(_SourceMigrationSelection.request(
                source: source, comicId: candidate.comicId,
              ));
            },
            onSelectNativeId: (source, id) async {
              if (source.sourceId == comic.sourceId && id == comic.comicId) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('这是当前漫画，请选择其他目标')),
                );
                return;
              }
              choose(_SourceMigrationSelection.request(source: source, comicId: id));
            },
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('当前漫画：${comic.title}',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('当前来源：${currentSource?.descriptor.name ?? comic.sourceId} · ${_sourcePluginLabel(comic.sourceId)}'),
                  if (currentSource != null && versions != null)
                    _SourceMigrationVersionNotice(
                      state: versions,
                      webUriFor: (version) => _sourceComicWebUri(currentSource, version.comicId),
                      onSelected: (selection) => choose(_SourceMigrationSelection.version(
                        source: currentSource,
                        version: selection.version,
                        viewOnly: selection.viewOnly,
                      )),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    final selection = await Navigator.of(context).push<_SourceMigrationSelection>(route);
    await route.completed;
    return selection;
  }

  Future<void> _openSourceMigrationForSummary(
    BrowsableComicSource source,
    SourceComicSummary summary, {
    Future<details.ComicDetailsVersionState>? versionState,
  }) async {
    try {
      final comic = await _materializeSourceComic(
        source,
        summary,
        resolveCanonicalAlias: false,
      );
      if (mounted) await _openSourceMigration(comic, versionState: versionState);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          copyableDiagnosticSnackBar('准备漫画迁移失败：$error'),
        );
      }
    }
  }

  Future<void> _openSourceMigration(LibraryComic comic, {
    Future<details.ComicDetailsVersionState>? versionState,
  }) async {
    final targets = _enabledSources.toList(growable: false);
    final currentSource = _sourceForId(comic.sourceId);
    if (targets.isEmpty &&
        (currentSource == null || !_sourceSupportsVersionEntry(currentSource))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有已启用漫画源可用于迁移')),
        );
      }
      return;
    }
    final selection = await _selectSourceMigrationTarget(comic, versionState: versionState);
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


  HomeVersionViewPreparation _startVersionViewReusePreparation(
    BrowsableComicSource source,
    String currentComicId,
    String targetComicId,
  ) =>
      _versionReuseLifecycle.startViewPreparation(
        source,
        currentComicId,
        targetComicId,
      );

  HomeVersionViewPreparation? _versionViewReusePreparationFor(
    ImportedLibraryEntry entry,
  ) =>
      _versionReuseLifecycle.viewPreparationFor(entry);

  Future<void> _viewSourceVersion(
    BrowsableComicSource source,
    String currentComicId,
    SourceComicVersion version,
  ) async {
    if (version.sourceId != source.sourceId || version.comicId.isEmpty) return;
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
      _versionReuseLifecycle.finishViewPreparation(
        source.sourceId,
        version.comicId,
        preparation,
      );
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
      final source = _sourceForId(comic.sourceId);
      final confirmed = await showSourceMigrationComparison(
        context: context,
        plan: plan,
        sourceName: source?.descriptor.name ?? comic.sourceId,
        targetName: request.source.descriptor.name,
        replaceSource: replacingSource,
        sourceWebUri: source == null
            ? null
            : _sourceComicWebUri(source, comic.comicId),
        targetWebUri: _sourceComicWebUri(request.source, request.id),
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
