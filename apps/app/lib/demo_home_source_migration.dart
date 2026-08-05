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

String _sourcePluginLabel(String sourceId) {
  if (sourceId.startsWith('mihon:')) return 'Mihon 插件';
  if (sourceId.startsWith('venera:')) return 'Venera 插件';
  return '内置源适配器';
}

ComicVersionSource? _sourceVersionCapability(BrowsableComicSource source) {
  final Object candidate = source;
  return candidate is ComicVersionSource ? candidate : null;
}

bool _sourceSupportsVersionEntry(BrowsableComicSource source) {
  final versionSource = _sourceVersionCapability(source);
  return versionSource?.supportsComicVersions == true ||
      source.descriptor.supportsSearch;
}

List<Widget> _sourceVersionChoiceGroups(
  BuildContext context,
  List<SourceComicVersion> candidates,
) {
  final successors = candidates
      .where((item) => !item.isPredecessor)
      .toList(growable: false);
  final predecessors = candidates
      .where((item) => item.isPredecessor)
      .toList(growable: false);

  Widget tile(SourceComicVersion item) {
    final relation = item.isPredecessor ? '旧版' : '新版';
    final title = item.title.trim().isEmpty
        ? '$relation ${item.generation}'
        : '$relation ${item.generation} · ${item.title}';
    return ListTile(
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (item.date?.isNotEmpty == true) item.date!,
          item.comicId,
        ].join('\n'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: FilledButton.tonal(
        onPressed: () => Navigator.pop(context, item),
        child: const Text('迁移'),
      ),
      onTap: () => Navigator.pop(context, item),
    );
  }

  Widget groupLabel(String label) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );

  return <Widget>[
    if (successors.isNotEmpty) ...<Widget>[
      groupLabel('新版'),
      for (final item in successors) tile(item),
    ],
    if (predecessors.isNotEmpty) ...<Widget>[
      groupLabel('旧版'),
      for (final item in predecessors) tile(item),
    ],
  ];
}

extension _DemoHomeSourceMigration on _DemoHomeState {
  ComicVersionRelationStore? _comicVersionRelationStore() {
    final candidate = _library;
    return candidate is ComicVersionRelationStore
        ? candidate as ComicVersionRelationStore
        : null;
  }

  Future<List<SourceComicVersion>> _storedSourcePredecessors({
    required String sourceId,
    required String successorComicId,
  }) async {
    final store = _comicVersionRelationStore();
    if (store == null) {
      return const <SourceComicVersion>[];
    }
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
            title: relations[index].predecessorTitle.isEmpty
                ? '旧版'
                : relations[index].predecessorTitle,
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
      await store.saveComicVersionRelation(
        ComicVersionRelation(
          sourceId: source.sourceId,
          predecessorComicId: predecessorComicId,
          successorComicId: successor.comicId,
          predecessorTitle: predecessorTitle,
        ),
      );
    }
  }

  Future<({BrowsableComicSource source, String id})?>
      _selectSourceMigrationTarget(
    LibraryComic comic,
    List<BrowsableComicSource> targets,
  ) async {
    var target = targets.first;
    final currentSource = _sourceForId(comic.sourceId);
    final controller = TextEditingController();
    final choice = await showDialog<
        ({BrowsableComicSource source, String? id, bool search})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final sameSource = target.sourceId == comic.sourceId;
          return AlertDialog(
            title: Text(sameSource ? '迁移到同源版本' : '迁移到其他漫画源'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                Text(
                  '当前插件：${_sourcePluginLabel(comic.sourceId)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '当前来源：${currentSource?.descriptor.name ?? comic.sourceId}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: target.sourceId,
                  decoration: InputDecoration(
                    labelText: sameSource ? '目标版本来源' : '目标漫画源',
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final source in targets)
                      DropdownMenuItem<String>(
                        value: source.sourceId,
                        child: Text(source.descriptor.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
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
                    labelText: sameSource ? '目标版本 ID（可选）' : '目标漫画 ID（可选）',
                    helperText: sameSource
                        ? '搜索当前来源中的同名版本；也可手动填写插件原生 ID'
                        : '通常直接搜索同名作品；仅在搜索不到时手动填写原生 ID',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                Text(
                  sameSource
                      ? '只复制整部漫画偏好和可验证阅读状态；确认后替换旧版本记录，离线字节仍由下载管理单独处理。'
                      : '只复制整部漫画偏好和可验证阅读状态；不复制来源 URL、离线字节，也不删除原来源。',
                ),
                ],
              ),
            ),
            actions: <Widget>[
              AppDialogActions(
                onClose: () => Navigator.pop(context),
                actions: <Widget>[
                TextButton.icon(
                  onPressed: (sameSource
                          ? _sourceSupportsVersionEntry(target)
                          : target.descriptor.supportsSearch)
                      ? () => Navigator.pop(
                            context,
                            (source: target, id: null, search: true),
                          )
                      : null,
                  icon: const Icon(Icons.search),
                  label: Text(sameSource ? '搜索同源版本' : '搜索同名作品'),
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
                            ),
                          ),
                  child: const Text('使用漫画 ID'),
                ),
                ],
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (choice == null || !mounted) {
      return null;
    }
    final manualId = choice.id;
    if (!choice.search && manualId != null) {
      return (source: choice.source, id: manualId);
    }

    if (choice.source.sourceId == comic.sourceId && choice.search) {
      try {
        final version = await _selectSourceVersion(
          choice.source,
          comic.title,
          comic.comicId,
        );
        return version == null
            ? null
            : (source: choice.source, id: version.comicId);
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取同源版本失败：$error')),
          );
        }
        return null;
      }
    }

    try {
      final page = await choice.source.browse(
        query: comic.title,
        limit: 12,
      );
      if (!mounted) {
        return null;
      }
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                        [
                          if (item.authors.isNotEmpty)
                            item.authors.join('、'),
                          item.comicId,
                        ].join('\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context),
              actions: const <Widget>[],
            ),
          ],
        ),
      );
      if (candidate == null) {
        return null;
      }
      if (candidate.sourceId != choice.source.sourceId) {
        throw StateError('目标漫画源搜索返回了不匹配的来源身份');
      }
      return (source: choice.source, id: candidate.comicId);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('搜索目标漫画失败：$error')),
        );
      }
      return null;
    }
  }

  Future<SourceComicVersion?> _selectSourceVersion(
    BrowsableComicSource source,
    String title,
    String currentComicId,
  ) async {
    final versionSource = _sourceVersionCapability(source);
    final List<SourceComicVersion> candidates;
    if (versionSource?.supportsComicVersions == true) {
      final predecessors = await _storedSourcePredecessors(
        sourceId: source.sourceId,
        successorComicId: currentComicId,
      );
      var successors = const <SourceComicVersion>[];
      try {
        successors = await versionSource!.findComicVersions(currentComicId);
        await _rememberSourceSuccessors(
          source: source,
          predecessorComicId: currentComicId,
          predecessorTitle: title,
          successors: successors,
        );
      } on Object {
        if (predecessors.isEmpty) {
          rethrow;
        }
      }
      final merged = <SourceComicVersion>[];
      final identities = <String>{};
      for (final item in <SourceComicVersion>[...successors, ...predecessors]) {
        if (item.sourceId != source.sourceId ||
            item.comicId.isEmpty ||
            item.comicId == currentComicId ||
            !identities.add(item.comicId)) {
          continue;
        }
        merged.add(item);
      }
      candidates = List<SourceComicVersion>.unmodifiable(merged);
    } else {
      final page = await source.browse(query: title, limit: 24);
      candidates = <SourceComicVersion>[
        for (var index = 0; index < page.items.length; index++)
          if (page.items[index].sourceId == source.sourceId &&
              page.items[index].comicId != '' &&
              page.items[index].comicId != currentComicId)
            SourceComicVersion(
              sourceId: source.sourceId,
              comicId: page.items[index].comicId,
              title: page.items[index].title,
              generation: index + 1,
            ),
      ];
    }
    if (!mounted) {
      return null;
    }
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${source.descriptor.name} 未找到同源版本关系')),
      );
      return null;
    }
    return showDialog<SourceComicVersion>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('选择 ${source.descriptor.name} 的同源版本'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '当前插件：${_sourcePluginLabel(source.sourceId)}\n'
                  '当前来源：${source.descriptor.name}',
                ),
                const SizedBox(height: 8),
                ..._sourceVersionChoiceGroups(context, candidates),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          AppDialogActions(
            onClose: () => Navigator.pop(context),
            actions: const <Widget>[],
          ),
        ],
      ),
    );
  }

  Future<void> _openSourceVersions(LibraryComic comic) async {
    final source = _sourceForId(comic.sourceId);
    if (source == null || !_sourceSupportsVersionEntry(source)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前漫画源不支持同源版本')),
      );
      return;
    }
    try {
      final candidate = await _selectSourceVersion(
        source,
        comic.title,
        comic.comicId,
      );
      if (candidate == null || !mounted) {
        return;
      }
      if (candidate.comicId == comic.comicId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择的版本与当前漫画相同')),
        );
        return;
      }
      await _applySourceMigration(
        comic,
        (source: source, id: candidate.comicId),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取同源版本失败：$error')),
        );
      }
    }
  }

  Future<LibraryComic> _materializeSourceComic(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) async {
    final existing = _libraryComicForSourceIdentity(
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

  Future<void> _openSourceMigrationForSummary(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) async {
    try {
      final comic = await _materializeSourceComic(source, summary);
      if (mounted) {
        await _openSourceMigration(comic);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('准备漫画迁移失败：$error')),
        );
      }
    }
  }

  Future<void> _openSourceVersionsForSummary(
    BrowsableComicSource source,
    SourceComicSummary summary,
  ) async {
    try {
      if (!_sourceSupportsVersionEntry(source)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前漫画源不支持同源版本')),
        );
        return;
      }
      final candidate = await _selectSourceVersion(
        source,
        summary.title,
        summary.comicId,
      );
      if (candidate == null || !mounted) {
        return;
      }
      if (candidate.comicId == summary.comicId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择的版本与当前漫画相同')),
        );
        return;
      }
      final comic = await _materializeSourceComic(source, summary);
      await _applySourceMigration(
        comic,
        (source: source, id: candidate.comicId),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取同源版本失败：$error')),
        );
      }
    }
  }

  Future<void> _openSourceMigration(LibraryComic comic) async {
    final targets = _enabledSources.toList(growable: false);
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有已启用漫画源可用于迁移')),
      );
      return;
    }
    final request = await _selectSourceMigrationTarget(
      comic,
      targets,
    );
    if (request == null || !mounted) {
      return;
    }
    await _applySourceMigration(comic, request);
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

      await _library.upsertSavedComic(
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
      await _library.saveComicPreference(mergedPreference);

      var migratedChapters = 0;
      var migratedProgress = 0;
      var migratedReadStates = 0;
      var preservedTargetStates = 0;
      var reusedPageArtifacts = 0;
      for (final item in prepared) {
        final targetRecord = item.targetRecord;
        await _library.upsertChapter(targetRecord);
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
          await _library.saveProgress(
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
        for (final entry in comic.chapters) {
          await _library.removeChapter(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          );
        }
        await _library.removeSavedComic(comic.sourceId, comic.comicId);
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
