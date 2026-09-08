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
  return candidate;
}

bool _sourceSupportsVersionEntry(BrowsableComicSource source) =>
    _sourceVersionCapability(source)?.supportsComicVersions == true;

String? _sourceVersionRelationDate(DateTime? value) {
  if (value == null) return null;
  final local = value.toLocal();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
}

const Duration _versionPageMappingRevalidationInterval = Duration(minutes: 10);

bool _versionPageMappingIsFresh(
  ComicVersionPageMapping mapping,
  DateTime now,
) {
  final verifiedAt = mapping.verifiedAt;
  if (verifiedAt == null) return false;
  final age = now.difference(verifiedAt.toUtc());
  return !age.isNegative && age <= _versionPageMappingRevalidationInterval;
}

bool _versionPageMappingsAreFresh(
  ComicVersionRelation relation,
  DateTime now,
) {
  if (relation.pageMappings.isEmpty) return false;
  for (final mapping in relation.pageMappings) {
    if (!_versionPageMappingIsFresh(mapping, now)) {
      return false;
    }
  }
  return true;
}

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
    required String fallbackTitle,
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
            title: relations[index].predecessorTitle.trim().isEmpty
                ? fallbackTitle
                : relations[index].predecessorTitle.trim(),
            generation: relations.length - index,
            date: _sourceVersionRelationDate(relations[index].discoveredAt),
          ),
    ];
  }

  Future<List<SourceComicVersion>> _storedSourcePredecessors({
    required String sourceId,
    required String successorComicId,
    required String fallbackTitle,
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
            title: relations[index].predecessorTitle.trim().isEmpty
                ? '旧版：$fallbackTitle'
                : relations[index].predecessorTitle.trim(),
            generation: index + 1,
            date: _sourceVersionRelationDate(relations[index].discoveredAt),
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


  List<ComicVersionRelation> _sourceVersionRelationsForComic(
    String sourceId,
    String comicId,
  ) =>
      _versionRelations
          .where(
            (relation) =>
                relation.sourceId == sourceId &&
                (relation.predecessorComicId == comicId ||
                    relation.successorComicId == comicId),
          )
          .toList(growable: false);

  ImportedLibraryEntry? _exactChapterEntry(
    String sourceId,
    String chapterId,
  ) {
    for (final entry in _libraryEntries) {
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    return null;
  }

  List<ComicVersionPageMapping> _replaceVersionPageMapping(
    List<ComicVersionPageMapping> existing,
    ComicVersionPageMapping mapping,
  ) {
    final next = existing.toList(growable: true);
    final index = next.indexWhere(
      (current) =>
          current.predecessorChapterId == mapping.predecessorChapterId &&
          current.successorChapterId == mapping.successorChapterId,
    );
    if (index < 0) {
      next.add(mapping);
    } else {
      next[index] = mapping;
    }
    return List<ComicVersionPageMapping>.unmodifiable(next);
  }

  Future<ImportedLibraryEntry> _loadVersionChapterEntry(
    BrowsableComicSource source,
    Comic comic,
    Chapter chapter,
  ) async {
    final existing = _exactChapterEntry(source.sourceId, chapter.chapterId);
    if (existing != null &&
        existing.chapter.pages.isNotEmpty &&
        !_hasLegacyVeneraLocators(existing.chapter)) {
      return _librarySession.hydrateEntry(existing);
    }
    final manifest = await source.loadChapter(chapter.chapterId);
    if (manifest.sourceId != source.sourceId ||
        manifest.comicId != chapter.comicId ||
        manifest.chapter.chapterId != chapter.chapterId) {
      throw StateError('同源版本章节返回了不匹配的身份');
    }
    return _librarySession.upsertChapter(
      ImportedChapterRecord.remote(
        comic: comic,
        manifest: manifest,
      ),
    );
  }

  Future<void> _warmVersionRelationPageMappings(
    BrowsableComicSource source,
    ComicVersionRelation relation,
  ) async {
    final revalidationNow = DateTime.now().toUtc();
    if (_versionPageMappingsAreFresh(relation, revalidationNow)) {
      return;
    }
    final predecessorComic = await source.loadComic(relation.predecessorComicId);
    final successorComic = await source.loadComic(relation.successorComicId);
    if (predecessorComic.comic.sourceId != source.sourceId ||
        successorComic.comic.sourceId != source.sourceId ||
        predecessorComic.comic.comicId != relation.predecessorComicId ||
        successorComic.comic.comicId != relation.successorComicId) {
      throw StateError('同源版本漫画返回了不匹配的身份');
    }
    var updatedRelation = relation;
    var verifiedMappings = 0;
    for (final predecessorChapter in predecessorComic.chapters) {
      Chapter? successorChapter;
      for (final candidate in successorComic.chapters) {
        if (candidate.sequence == predecessorChapter.sequence) {
          successorChapter = candidate;
          break;
        }
      }
      final matchedSuccessorChapter = successorChapter;
      if (matchedSuccessorChapter == null) continue;
      final existing = updatedRelation.pageMappings.where(
        (mapping) =>
            mapping.predecessorChapterId == predecessorChapter.chapterId &&
            mapping.successorChapterId == matchedSuccessorChapter.chapterId,
      );
      ComicVersionPageMapping? currentMapping;
      for (final mapping in existing) {
        if (mapping.predecessorPageCount == predecessorChapter.pageCount &&
            mapping.successorPageCount == matchedSuccessorChapter.pageCount) {
          currentMapping = mapping;
          break;
        }
      }
      if (currentMapping != null &&
          currentMapping.verifiedPredecessorPageIndexes.isNotEmpty &&
          _versionPageMappingIsFresh(currentMapping, revalidationNow)) {
        verifiedMappings++;
        continue;
      }
      final predecessorEntry = await _loadVersionChapterEntry(
        source,
        predecessorComic.comic,
        predecessorChapter,
      );
      final successorEntry = await _loadVersionChapterEntry(
        source,
        successorComic.comic,
        matchedSuccessorChapter,
      );
      final predecessorManifest = predecessorEntry.chapter.toManifest();
      final successorManifest = successorEntry.chapter.toManifest();
      final offsetProof =
          await VerifiedArtifactReusePlan.matchResolvedRelatedOffset(
        sourceChapter: predecessorManifest,
        targetChapter: successorManifest,
        resolveIdentity: (page) => _sourceResources.verifiedPageReuseIdentity(
          sourceId: source.sourceId,
          locator: page.uri,
        ),
      );
      if (offsetProof == null || offsetProof.verifiedSourceIndexes.isEmpty) {
        continue;
      }
      verifiedMappings++;
      final mapping = ComicVersionPageMapping(
        predecessorChapterId: predecessorManifest.chapter.chapterId,
        successorChapterId: successorManifest.chapter.chapterId,
        predecessorPageCount: predecessorManifest.pages.length,
        successorPageCount: successorManifest.pages.length,
        successorOffset: offsetProof.targetOffsetFromSource,
        verifiedPredecessorPageIndexes: offsetProof.verifiedSourceIndexes,
        verifiedAt: DateTime.now().toUtc(),
      );
      updatedRelation = ComicVersionRelation(
        sourceId: relation.sourceId,
        predecessorComicId: relation.predecessorComicId,
        successorComicId: relation.successorComicId,
        predecessorTitle: relation.predecessorTitle,
        discoveredAt: relation.discoveredAt,
        pageMappings: _replaceVersionPageMapping(
          updatedRelation.pageMappings,
          mapping,
        ),
      );
      await _librarySession.upsertVersionRelationDerivedState(updatedRelation);
    }
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-version-reuse:${source.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
        payload: <String, Object?>{
          'stage': 'version-page-mapping-warmed',
          'verifiedMappings': verifiedMappings,
          'persistedMappings': updatedRelation.pageMappings.length,
          'materializedEquivalenceEdges': 0,
        },
      ),
    );
  }

  void _scheduleVersionReuseWarmup(
    BrowsableComicSource source,
    String comicId, {
    bool refreshVersions = true,
    bool deferUntilAfterFrame = true,
  }) {
    if (deferUntilAfterFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scheduleVersionReuseWarmup(
              source,
              comicId,
              refreshVersions: refreshVersions,
              deferUntilAfterFrame: false,
            );
          }
        });
      });
      return;
    }
    final key = '${source.sourceId}\u0000$comicId';
    if (_versionReuseWarmups.containsKey(key)) return;
    late Future<void> future;
    future = Future<void>(() async {
      final versionSource = _sourceVersionCapability(source);
      if (refreshVersions &&
          versionSource != null &&
          versionSource.supportsComicVersions) {
        try {
          final versions = await versionSource.findComicVersions(comicId);
          await _rememberSourceSuccessors(
            source: source,
            predecessorComicId: comicId,
            predecessorTitle:
                _exactLibraryComicForSourceIdentity(source.sourceId, comicId)
                        ?.title ??
                    comicId,
            successors: versions.where((item) => !item.isPredecessor),
          );
        } on Object {
          // Persisted relations remain usable when source refresh is offline.
        }
      }
      final relations = _sourceVersionRelationsForComic(source.sourceId, comicId);
      for (final relation in relations) {
        try {
          await _warmVersionRelationPageMappings(source, relation);
        } on Object catch (error) {
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.elapsedMicroseconds,
              sessionId: 'source-version-reuse:${source.sourceId}',
              kind: TraceEventKind.taskFailed,
              identityHash:
                  '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
              payload: <String, Object?>{
                'stage': 'version-page-mapping-warm-failed',
                'errorType': error.runtimeType.toString(),
              },
            ),
          );
        }
      }
    });
    _versionReuseWarmups[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_versionReuseWarmups[key], future)) {
          _versionReuseWarmups.remove(key);
        }
      }),
    );
  }

  Future<int> _restoreSourceVersionArtifactEquivalences(
    ImportedLibraryEntry current,
  ) async {
    final chapterKey =
        '${current.chapter.sourceId}\u0000${current.chapter.comicId}'
        '\u0000${current.chapter.chapterId}\u0000${current.chapter.sourceRevision}';
    final artifactCache = _readerArtifactCache;
    if (artifactCache == null) return 0;
    final relations = _sourceVersionRelationsForComic(
      current.chapter.sourceId,
      current.chapter.comicId,
    );
    final relationFingerprintParts = <String>[];
    for (final relation in relations) {
      final currentIsSuccessor =
          relation.successorComicId == current.chapter.comicId;
      final currentIsPredecessor =
          relation.predecessorComicId == current.chapter.comicId;
      if (!currentIsSuccessor && !currentIsPredecessor) continue;
      for (final mapping in relation.pageMappings) {
        final targetChapterId = currentIsSuccessor
            ? mapping.successorChapterId
            : mapping.predecessorChapterId;
        if (targetChapterId != current.chapter.chapterId) continue;
        relationFingerprintParts.add(
          '${relation.predecessorComicId}\u0000${relation.successorComicId}'
          '\u0000${mapping.predecessorChapterId}'
          '\u0000${mapping.successorChapterId}'
          '\u0000${mapping.predecessorPageCount}'
          '\u0000${mapping.successorPageCount}'
          '\u0000${mapping.successorOffset}'
          '\u0000${mapping.verifiedPredecessorPageIndexes.join(',')}'
          '\u0000${mapping.verifiedAt?.microsecondsSinceEpoch ?? 0}',
        );
      }
    }
    relationFingerprintParts.sort();
    final relationFingerprint = relationFingerprintParts.join('\u0001');
    final resolverKey = 'version-reuse:$chapterKey';
    final fingerprintUnchanged =
        _restoredVersionChapterFingerprints[chapterKey] == relationFingerprint;
    if (fingerprintUnchanged &&
        (relationFingerprintParts.isEmpty ||
            artifactCache.hasEquivalentResolver(resolverKey))) {
      return 0;
    }

    final targetManifest = current.chapter.toManifest();
    final resolver = VerifiedArtifactReuseResolver(
      targetChapter: targetManifest,
    );
    final cachedManifests = <String, ChapterManifest>{};
    var skippedMissingSourceManifests = 0;
    for (final relation in relations) {
      final currentIsSuccessor =
          relation.successorComicId == current.chapter.comicId;
      final currentIsPredecessor =
          relation.predecessorComicId == current.chapter.comicId;
      if (!currentIsSuccessor && !currentIsPredecessor) continue;
      for (final mapping in relation.pageMappings) {
        final targetChapterId = currentIsSuccessor
            ? mapping.successorChapterId
            : mapping.predecessorChapterId;
        if (targetChapterId != current.chapter.chapterId) continue;
        final sourceChapterId = currentIsSuccessor
            ? mapping.predecessorChapterId
            : mapping.successorChapterId;
        var sourceManifest = cachedManifests[sourceChapterId];
        if (sourceManifest == null) {
          final sourceEntryHint = _exactChapterEntry(
            current.chapter.sourceId,
            sourceChapterId,
          ) ?? await _library.get(current.chapter.sourceId, sourceChapterId);
          if (sourceEntryHint == null) {
            skippedMissingSourceManifests++;
            continue;
          }
          final sourceEntry = await _librarySession.hydrateEntry(sourceEntryHint);
          sourceManifest = sourceEntry.chapter.toManifest();
          cachedManifests[sourceChapterId] = sourceManifest;
        }
        if (currentIsSuccessor &&
            (mapping.successorPageCount != current.chapter.pages.length ||
                mapping.predecessorPageCount != sourceManifest.pages.length)) {
          continue;
        }
        if (currentIsPredecessor &&
            (mapping.predecessorPageCount != current.chapter.pages.length ||
                mapping.successorPageCount != sourceManifest.pages.length)) {
          continue;
        }
        resolver.addVerifiedOffset(
          sourceChapter: sourceManifest,
          targetOffsetFromSource: currentIsSuccessor
              ? mapping.successorOffset
              : -mapping.successorOffset,
          verifiedSourceIndexes: currentIsSuccessor
              ? mapping.verifiedPredecessorPageIndexes
              : mapping.verifiedPredecessorPageIndexes.map(
                  (predecessorIndex) =>
                      predecessorIndex + mapping.successorOffset,
                ),
        );
      }
    }
    if (resolver.relationCount > 0) {
      artifactCache.registerEquivalentResolver(
        key: resolverKey,
        resolver: resolver.resolve,
      );
    } else {
      artifactCache.removeEquivalentResolver(resolverKey);
    }
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-version-reuse:${current.chapter.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${current.chapter.sourceId}\u0000${current.chapter.chapterId}',
        payload: <String, Object?>{
          'stage': 'version-artifact-equivalence-restored',
          'lazyRelations': resolver.relationCount,
          'eligibleEquivalentPages': resolver.eligiblePageCount,
          'materializedEquivalenceEdges': 0,
          'skippedMissingSourceManifests': skippedMissingSourceManifests,
        },
      ),
    );
    _restoredVersionChapterFingerprints[chapterKey] = relationFingerprint;
    return resolver.eligiblePageCount;
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
      fallbackTitle: title,
    );
    final storedPredecessors = await _storedSourcePredecessors(
      sourceId: source.sourceId,
      successorComicId: currentComicId,
      fallbackTitle: title,
    );

    List<SourceComicVersion> merge(
      Iterable<SourceComicVersion> values, {
      required bool predecessor,
    }) {
      final indexes = <String, int>{};
      final currentCanonical = _canonicalComicKey(
        source.sourceId,
        currentComicId,
      );
      final result = <SourceComicVersion>[];
      for (final item in values) {
        if (item.isPredecessor != predecessor ||
            item.sourceId != source.sourceId ||
            item.comicId.isEmpty ||
            item.comicId == currentComicId ||
            _canonicalComicKey(source.sourceId, item.comicId) ==
                currentCanonical) {
          continue;
        }
        final existingIndex = indexes[item.comicId];
        if (existingIndex != null) {
          final existing = result[existingIndex];
          result[existingIndex] = SourceComicVersion(
            sourceId: existing.sourceId,
            comicId: existing.comicId,
            title: existing.title.trim().isEmpty
                ? item.title.trim()
                : existing.title.trim(),
            generation: existing.generation,
            date: existing.date?.trim().isNotEmpty == true
                ? existing.date!.trim()
                : item.date?.trim(),
            isPredecessor: predecessor,
          );
          continue;
        }
        indexes[item.comicId] = result.length;
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

    details.ComicDetailsVersionState stateFor(
      Iterable<SourceComicVersion> discovered, {
      Future<details.ComicDetailsVersionState>? backgroundRefresh,
    }
    ) =>
        details.ComicDetailsVersionState(
          successors: merge(
            <SourceComicVersion>[...discovered, ...storedSuccessors],
            predecessor: false,
          ),
          predecessors: merge(
            <SourceComicVersion>[...discovered, ...storedPredecessors],
            predecessor: true,
          ),
          backgroundRefresh: backgroundRefresh,
        );

    Future<List<SourceComicVersion>> refreshVersions() async {
      final discovered = await versionSource.findComicVersions(currentComicId);
      await _rememberSourceSuccessors(
        source: source,
        predecessorComicId: currentComicId,
        predecessorTitle: title,
        successors: discovered.where((item) => !item.isPredecessor),
      );
      return discovered;
    }

    if (storedSuccessors.isNotEmpty || storedPredecessors.isNotEmpty) {
      final backgroundRefresh = Future<void>(() {}).then((_) async {
        try {
          return stateFor(await refreshVersions());
        } on Object {
          // A confirmed durable relation remains usable while offline.
          return stateFor(const <SourceComicVersion>[]);
        }
      });
      _scheduleVersionReuseWarmup(
        source,
        currentComicId,
        refreshVersions: false,
      );
      return stateFor(
        const <SourceComicVersion>[],
        backgroundRefresh: backgroundRefresh,
      );
    }

    var discovered = const <SourceComicVersion>[];
    try {
      discovered = await refreshVersions();
    } on Object {
      if (storedPredecessors.isEmpty) rethrow;
    }
    _scheduleVersionReuseWarmup(
      source,
      currentComicId,
      refreshVersions: false,
    );
    return stateFor(discovered);
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
              SnackBar(content: Text('读取同源更新失败，将打开当前版本：$error')),
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
        final sourceEntry = await _librarySession.hydrateEntry(match.source);
        final sourceChapter = sourceEntry.chapter.toManifest();
        var artifactReuse = VerifiedArtifactReusePlan.match(
          oldChapter: sourceChapter,
          newChapter: targetManifest,
        );
        if (replacingSource && artifactReuse.mappings.isEmpty) {
          try {
            artifactReuse =
                await VerifiedArtifactReusePlan.matchResolvedRelated(
              sourceChapter: sourceChapter,
              targetChapter: targetManifest,
              resolveIdentity: (page) =>
                  _sourceResources.verifiedPageReuseIdentity(
                sourceId: request.source.sourceId,
                locator: page.uri,
              ),
            );
          } on Object {
            // Migration remains valid when optional media reuse proof fails.
          }
        }
        prepared.add(
          _PreparedChapterMigration(
            targetRecord: targetRecord,
            sourceProgress: sourceEntry.progress,
            sourceReadState: _chapterReadStates[chapterLibraryIdentity(
              sourceEntry.chapter.sourceId,
              sourceEntry.chapter.chapterId,
            )],
            targetProgress: targetEntry?.progress,
            targetReadState: targetReadStates[chapterLibraryIdentity(
              targetRecord.sourceId,
              targetRecord.chapterId,
            )],
            artifactReuse: artifactReuse,
          ),
        );
      }

      var materializedPageArtifacts = 0;
      final artifactCache = _readerArtifactCache;
      if (artifactCache != null) {
        for (final item in prepared) {
          materializedPageArtifacts +=
              await item.artifactReuse.materializeTargetArtifacts(
            artifactCache,
          );
        }
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
      var registeredPageEquivalences = 0;
      for (final item in prepared) {
        final targetRecord = item.targetRecord;
        await _librarySession.upsertChapter(targetRecord);
        migratedChapters++;
        if (artifactCache != null) {
          registeredPageEquivalences +=
              item.artifactReuse.registerEquivalences(artifactCache);
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
          if (registeredPageEquivalences > 0)
            '登记 $registeredPageEquivalences 页已验证媒体等价关系',
          if (materializedPageArtifacts > 0)
            '复用 $materializedPageArtifacts 页旧版离线文件到新 key',
          if (replacingSource)
            '旧版本记录已替换，未匹配的旧版离线文件仍保留'
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
