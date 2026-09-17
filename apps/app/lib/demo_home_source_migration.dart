part of 'demo_home.dart';

const int _readerMetadataVersionRefreshPriority = 100;

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
  Future<void> _recoverCommittedSourceMigrations() async {
    final changed = await _sourceMigrationTransaction.recoverCommitted();
    if (changed && mounted) {
      await _reloadLibrary();
    }
  }

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
    Chapter chapter, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final existing = _exactChapterEntry(source.sourceId, chapter.chapterId);
    if (existing != null &&
        existing.chapter.pages.isNotEmpty &&
        !_hasLegacyVeneraLocators(existing.chapter)) {
      return _librarySession.hydrateEntry(existing);
    }
    final controlled = source is ControlledComicSource
        ? source as ControlledComicSource
        : null;
    final manifest = controlled != null
        ? await controlled.loadChapterControlled(
            chapter.chapterId,
            control: control,
          )
        : await source.loadChapter(chapter.chapterId);
    control?.throwIfCancelled();
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

  Future<bool> _chapterHasReusableVersionSourceState(
    ChapterManifest chapter,
  ) async {
    final provider = _chapterDownloads is ChapterDownloadTransferRuntimeProvider
        ? _chapterDownloads as ChapterDownloadTransferRuntimeProvider
        : null;
    if (provider == null || chapter.pages.isEmpty) return false;
    if (await provider.artifactStore.hasReusableChapterState(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapter.chapterId,
      sourceRevision: chapter.chapter.sourceRevision,
    )) {
      return true;
    }
    return provider.transferRuntime.hasReusablePhysicalStateForChapter(chapter);
  }

  Future<void> _warmVersionRelationPageMappings(
    BrowsableComicSource source,
    ComicVersionRelation relation,
    ImportedLibraryEntry focus, {
    bool upgradeLegacyIntervalProof = false,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final focusIsPredecessor =
        relation.predecessorComicId == focus.chapter.comicId;
    final focusIsSuccessor =
        relation.successorComicId == focus.chapter.comicId;
    if (!focusIsPredecessor && !focusIsSuccessor) return;

    for (final mapping in relation.pageMappings) {
      final focusedChapterId = focusIsPredecessor
          ? mapping.predecessorChapterId
          : mapping.successorChapterId;
      final focusedRevision = focusIsPredecessor
          ? mapping.predecessorSourceRevision
          : mapping.successorSourceRevision;
      final focusedPageCount = focusIsPredecessor
          ? mapping.predecessorPageCount
          : mapping.successorPageCount;
      final proofAlreadyUsable = upgradeLegacyIntervalProof
          ? !VerifiedArtifactReusePlan.needsIntervalProbe(mapping)
          : mapping.verifiedPredecessorPageIndexes.isNotEmpty;
      if (focusedChapterId == focus.chapter.chapterId &&
          focusedRevision == focus.chapter.sourceRevision &&
          focusedPageCount == focus.chapter.pages.length &&
          proofAlreadyUsable &&
          !upgradeLegacyIntervalProof) {
        return;
      }
    }

    final relatedComicId = focusIsPredecessor
        ? relation.successorComicId
        : relation.predecessorComicId;
    final controlled = source is ControlledComicSource
        ? source as ControlledComicSource
        : null;
    final relatedComic = controlled != null
        ? await controlled.loadComicControlled(
            relatedComicId,
            control: control,
          )
        : await source.loadComic(relatedComicId);
    control?.throwIfCancelled();
    if (relatedComic.comic.sourceId != source.sourceId ||
        relatedComic.comic.comicId != relatedComicId) {
      throw StateError('同源版本漫画返回了不匹配的身份');
    }
    Chapter? relatedChapter;
    for (final candidate in relatedComic.chapters) {
      if (candidate.sequence == focus.chapter.sequence) {
        relatedChapter = candidate;
        break;
      }
    }
    if (relatedChapter == null) return;

    final predecessorChapter = focusIsPredecessor
        ? focus.chapter.toManifest().chapter
        : relatedChapter;
    final successorChapter = focusIsSuccessor
        ? focus.chapter.toManifest().chapter
        : relatedChapter;
    ComicVersionPageMapping? currentMapping;
    for (final mapping in relation.pageMappings) {
      if (mapping.predecessorChapterId == predecessorChapter.chapterId &&
          mapping.successorChapterId == successorChapter.chapterId &&
          mapping.predecessorPageCount == predecessorChapter.pageCount &&
          mapping.successorPageCount == successorChapter.pageCount) {
        currentMapping = mapping;
        break;
      }
    }
    final currentProofAlreadyUsable =
        currentMapping != null &&
        (upgradeLegacyIntervalProof
            ? !VerifiedArtifactReusePlan.needsIntervalProbe(currentMapping)
            : currentMapping.verifiedPredecessorPageIndexes.isNotEmpty);
    if (currentMapping != null &&
        currentMapping.predecessorSourceRevision ==
            predecessorChapter.sourceRevision &&
        currentMapping.successorSourceRevision ==
            successorChapter.sourceRevision &&
        currentProofAlreadyUsable &&
        !upgradeLegacyIntervalProof) {
      return;
    }

    final relatedEntry = await _loadVersionChapterEntry(
      source,
      relatedComic.comic,
      relatedChapter,
      control: control,
    );
    control?.throwIfCancelled();
    final focusManifest = focus.chapter.toManifest();
    final relatedManifest = relatedEntry.chapter.toManifest();
    final predecessorManifest =
        focusIsPredecessor ? focusManifest : relatedManifest;
    final successorManifest = focusIsSuccessor ? focusManifest : relatedManifest;
    if (currentMapping != null &&
        currentMapping.predecessorSourceRevision ==
            predecessorManifest.chapter.sourceRevision &&
        currentMapping.successorSourceRevision ==
            successorManifest.chapter.sourceRevision &&
        currentProofAlreadyUsable) {
      // Explicit version view must materialize both endpoints so Home can
      // publish an existing verified interval into the canonical ledger, but
      // an already-current bounded proof must not be re-probed from source.
      return;
    }
    final predecessorReusable =
        await _chapterHasReusableVersionSourceState(predecessorManifest);
    final successorReusable =
        await _chapterHasReusableVersionSourceState(successorManifest);
    if (!predecessorReusable && !successorReusable) return;
    final intervalProof =
        await VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(
      sourceChapter: predecessorManifest,
      targetChapter: successorManifest,
      resolveIdentity: (page) => _sourceResources.verifiedPageReuseIdentity(
        sourceId: source.sourceId,
        locator: page.uri,
        control: control,
      ),
    );
    if (intervalProof == null || intervalProof.verifiedIntervals.isEmpty) {
      return;
    }
    final whole = intervalProof.verifiedIntervals.length == 1
        ? intervalProof.verifiedIntervals.single
        : null;
    final structuralOffset = whole != null &&
            whole.predecessorStart == 0 &&
            whole.predecessorEndExclusive == predecessorManifest.pages.length
        ? whole.successorOffset
        : 0;
    final mapping = ComicVersionPageMapping(
      predecessorChapterId: predecessorManifest.chapter.chapterId,
      successorChapterId: successorManifest.chapter.chapterId,
      predecessorPageCount: predecessorManifest.pages.length,
      successorPageCount: successorManifest.pages.length,
      successorOffset: structuralOffset,
      predecessorSourceRevision: predecessorManifest.chapter.sourceRevision,
      successorSourceRevision: successorManifest.chapter.sourceRevision,
      verifiedPredecessorPageIndexes: intervalProof.verifiedSourceIndexes,
      verifiedIntervals: intervalProof.verifiedIntervals,
      intervalProbeVersion: VerifiedArtifactReusePlan.intervalProbeVersion,
      verifiedAt: DateTime.now().toUtc(),
    );
    final updatedRelation = ComicVersionRelation(
      sourceId: relation.sourceId,
      predecessorComicId: relation.predecessorComicId,
      successorComicId: relation.successorComicId,
      predecessorTitle: relation.predecessorTitle,
      discoveredAt: relation.discoveredAt,
      pageMappings: _replaceVersionPageMapping(
        relation.pageMappings,
        mapping,
      ),
    );
    await _librarySession.upsertVersionRelationDerivedState(updatedRelation);
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-version-reuse:${source.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
        payload: <String, Object?>{
          'stage': 'version-page-mapping-warmed',
          'focusChapterId': focus.chapter.chapterId,
          'verifiedPages': mapping.verifiedPredecessorPageIndexes.length,
          'verifiedIntervals': mapping.verifiedIntervals.length,
          'verifiedCoveragePages': mapping.verifiedIntervals.fold<int>(
            0,
            (total, interval) => total + interval.length,
          ),
          'probeCount': intervalProof.probeCount,
          'verificationMode': 'bounded-affine-probe',
          'persistedMappings': updatedRelation.pageMappings.length,
          'materializedEquivalenceEdges': 0,
        },
      ),
    );
  }

  String _versionReuseWarmupKey(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
  }) =>
      '${source.sourceId}\u0000${focus.chapter.comicId}'
      '\u0000${focus.chapter.chapterId}\u0000${focus.chapter.sourceRevision}'
      '\u0000${targetComicId ?? ''}';

  Future<void> _prepareVersionReuseWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
    TaskControl? control,
  }) {
    control?.throwIfCancelled();
    if (control != null) {
      // A scheduler-owned Reader refresh must never join an uncontrolled
      // generic warmup Future: doing so would lose cancellation/priority at
      // the source/runtime boundary. Generic callers keep coalescing below.
      return _runVersionReuseWarmup(
        source,
        focus,
        targetComicId: targetComicId,
        control: control,
      );
    }
    final key = _versionReuseWarmupKey(
      source,
      focus,
      targetComicId: targetComicId,
    );
    final existing = _versionReuseWarmups[key];
    if (existing != null) return existing;
    late Future<void> future;
    future = _runVersionReuseWarmup(
      source,
      focus,
      targetComicId: targetComicId,
    );
    _versionReuseWarmups[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_versionReuseWarmups[key], future)) {
          _versionReuseWarmups.remove(key);
        }
      }),
    );
    return future;
  }

  Future<void> _runVersionReuseWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final relations = _sourceVersionRelationsForComic(
      source.sourceId,
      focus.chapter.comicId,
    );
    for (final relation in relations) {
      control?.throwIfCancelled();
      final relatedComicId =
          relation.predecessorComicId == focus.chapter.comicId
              ? relation.successorComicId
              : relation.predecessorComicId;
      if (targetComicId != null && relatedComicId != targetComicId) {
        continue;
      }
      try {
        await _warmVersionRelationPageMappings(
          source,
          relation,
          focus,
          upgradeLegacyIntervalProof: targetComicId != null,
          control: control,
        );
      } on Object catch (error) {
        if (control?.cancelled == true) rethrow;
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
            sessionId: 'source-version-reuse:${source.sourceId}',
            kind: TraceEventKind.taskFailed,
            identityHash:
                '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
            payload: <String, Object?>{
              'stage': 'version-page-mapping-warm-failed',
              'focusChapterId': focus.chapter.chapterId,
              'errorType': error.runtimeType.toString(),
            },
          ),
        );
      }
    }
    control?.throwIfCancelled();
    await _ensureSourceVersionReuseAuthority(focus);
  }

  void _scheduleVersionReuseWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    bool deferUntilAfterFrame = true,
  }) {
    if (deferUntilAfterFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scheduleVersionReuseWarmup(
              source,
              focus,
              deferUntilAfterFrame: false,
            );
          }
        });
      });
      return;
    }
    unawaited(_prepareVersionReuseWarmup(source, focus));
  }

  void _scheduleReaderMetadataVersionRefresh(
    BrowsableComicSource source,
    ImportedLibraryEntry focus,
  ) {
    final key = _versionReuseWarmupKey(source, focus);
    if (_readerVersionRefreshes.containsKey(key)) return;
    final completer = Completer<void>();
    final future = completer.future;
    _readerVersionRefreshes[key] = future;
    final laneKey = 'reader-metadata-version-refresh:'
        '${identityHashCode(completer)}:$key';
    final submitted = defaultDownloadResourceCoordinator.networkLane.submit(
      key: laneKey,
      priority: _readerMetadataVersionRefreshPriority,
      task: (control) async {
        try {
          await _runReaderMetadataVersionRefresh(
            source,
            focus,
            control,
          );
        } finally {
          if (!completer.isCompleted) completer.complete();
        }
      },
    );
    if (!submitted && !completer.isCompleted) {
      completer.complete();
    }
    unawaited(
      future.whenComplete(() {
        if (identical(_readerVersionRefreshes[key], future)) {
          _readerVersionRefreshes.remove(key);
        }
      }),
    );
  }

  Future<void> _runReaderMetadataVersionRefresh(
    BrowsableComicSource source,
    ImportedLibraryEntry focus,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    var refreshed = focus;
    final metadataFuture = _loadRemoteEntrySnapshot(
      focus,
      control: control,
    );
    final versionFuture = _loadSourceVersionState(
      source,
      focus.chapter.comicTitle,
      focus.chapter.comicId,
      control: control,
    );
    var metadataSnapshotLoaded = false;
    var metadataPreempted = false;
    var metadataRetryAttempted = false;
    var versionChecked = false;
    bool isRuntimeRequestPreemption(Object error) =>
        error is Failure &&
        error.code == ErrorCode.cancelled &&
        error.details['runtimeErrorCode'] == 'runtime-request-cancelled';
    Map<String, Object?> errorPayload(Object error) => <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'errorMessage': error is Failure ? error.message : error.toString(),
          if (error is Failure) ...<String, Object?>{
            'errorCode': error.code.name,
            if (error.details['runtimeErrorCode'] case final String code)
              'runtimeErrorCode': code,
          },
        };
    try {
      refreshed = await metadataFuture;
      metadataSnapshotLoaded = true;
    } on Object catch (error) {
      final preempted = isRuntimeRequestPreemption(error);
      metadataPreempted = preempted;
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: preempted || control.cancelled
              ? TraceEventKind.artifactSource
              : TraceEventKind.taskFailed,
          identityHash: focus.chapter.chapterId,
          payload: <String, Object?>{
            'stage': control.cancelled
                ? 'reader-metadata-refresh-scheduler-preempted'
                : preempted
                    ? 'reader-metadata-refresh-preempted'
                    : 'reader-metadata-refresh-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    try {
      final state = await versionFuture;
      final background = state.backgroundRefresh;
      if (background != null) await background;
      versionChecked = true;
    } on Object catch (error) {
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: control.cancelled
              ? TraceEventKind.artifactSource
              : TraceEventKind.taskFailed,
          identityHash: focus.chapter.comicId,
          payload: <String, Object?>{
            'stage': control.cancelled
                ? 'reader-version-check-scheduler-preempted'
                : 'reader-version-check-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    if (control.cancelled) return;
    if (metadataPreempted) {
      // Runtime-level foreground pressure may preempt this low-rank source
      // request before NetLane itself needs to reclaim the task. Retry once;
      // the same scheduler token keeps the retry behind any queued page plan.
      metadataRetryAttempted = true;
      try {
        refreshed = await _loadRemoteEntrySnapshot(
          focus,
          control: control,
        );
        metadataSnapshotLoaded = true;
      } on Object catch (error) {
        final preemptedAgain = isRuntimeRequestPreemption(error);
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
            sessionId: 'reader-version-refresh:${source.sourceId}',
            kind: preemptedAgain || control.cancelled
                ? TraceEventKind.artifactSource
                : TraceEventKind.taskFailed,
            identityHash: focus.chapter.chapterId,
            payload: <String, Object?>{
              'stage': control.cancelled
                  ? 'reader-metadata-refresh-scheduler-preempted-again'
                  : preemptedAgain
                      ? 'reader-metadata-refresh-preempted-again'
                      : 'reader-metadata-refresh-retry-failed',
              ...errorPayload(error),
            },
          ),
        );
      }
    }
    if (control.cancelled) return;
    try {
      await _prepareVersionReuseWarmup(
        source,
        refreshed,
        control: control,
      );
    } on Object catch (error) {
      if (control.cancelled) return;
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: TraceEventKind.taskFailed,
          identityHash: refreshed.chapter.chapterId,
          payload: <String, Object?>{
            'stage': 'reader-version-reuse-warmup-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    if (control.cancelled) return;
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'reader-version-refresh:${source.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash: refreshed.chapter.chapterId,
        payload: <String, Object?>{
          'stage': 'reader-metadata-version-refresh-complete',
          'metadataSnapshotLoaded': metadataSnapshotLoaded,
          'chapterPersisted': false,
          'pageCarrierPersisted': false,
          'metadataPreempted': metadataPreempted,
          'metadataRetryAttempted': metadataRetryAttempted,
          'versionChecked': versionChecked,
          'schedulerPriority': control.priority,
          'sourceRevision': refreshed.chapter.sourceRevision,
        },
      ),
    );
  }


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
  ) async {
    // Reader entry may catch up only already-materialized direct canonical
    // endpoints. It must not hydrate unopened version history or compose paths.
    await _librarySession.ensureCanonicalMediaForEntry(current);
    final chapterKey =
        '${current.chapter.sourceId}\u0000${current.chapter.comicId}'
        '\u0000${current.chapter.chapterId}\u0000${current.chapter.sourceRevision}';
    final relations = _librarySession.versionRelations
        .where(
          (relation) =>
              relation.sourceId == current.chapter.sourceId &&
              (relation.predecessorComicId == current.chapter.comicId ||
                  relation.successorComicId == current.chapter.comicId),
        )
        .toList(growable: false);
    final relationFingerprintParts = <String>[];
    final targetManifest = current.chapter.toManifest();
    final materializedRelatedChapters = <String>{};
    var acceptedMappings = 0;
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
        relationFingerprintParts.add(
          '${relation.predecessorComicId}\u0000${relation.successorComicId}'
          '\u0000${mapping.predecessorChapterId}'
          '\u0000${mapping.successorChapterId}'
          '\u0000${mapping.predecessorPageCount}'
          '\u0000${mapping.successorPageCount}'
          '\u0000${mapping.predecessorSourceRevision ?? ''}'
          '\u0000${mapping.successorSourceRevision ?? ''}'
          '\u0000${mapping.effectiveVerifiedIntervals.map((interval) => '${interval.predecessorStart}:${interval.predecessorEndExclusive}:${interval.successorOffset}').join(',')}'
          '\u0000${mapping.intervalProbeVersion}'
          '\u0000${mapping.verifiedAt?.microsecondsSinceEpoch ?? 0}',
        );
        final intervals = mapping.effectiveVerifiedIntervals;
        final predecessorRevision = mapping.predecessorSourceRevision;
        final successorRevision = mapping.successorSourceRevision;
        if (intervals.isEmpty ||
            predecessorRevision == null ||
            successorRevision == null) {
          continue;
        }
        final targetExpectedRevision = currentIsSuccessor
            ? successorRevision
            : predecessorRevision;
        final targetExpectedCount = currentIsSuccessor
            ? mapping.successorPageCount
            : mapping.predecessorPageCount;
        if (targetExpectedRevision != targetManifest.chapter.sourceRevision ||
            targetExpectedCount != targetManifest.pages.length) {
          continue;
        }
        final relatedComicId = currentIsSuccessor
            ? relation.predecessorComicId
            : relation.successorComicId;
        final relatedChapterId = currentIsSuccessor
            ? mapping.predecessorChapterId
            : mapping.successorChapterId;
        final relatedExpectedRevision = currentIsSuccessor
            ? predecessorRevision
            : successorRevision;
        final relatedExpectedCount = currentIsSuccessor
            ? mapping.predecessorPageCount
            : mapping.successorPageCount;
        final relatedEntry = _librarySession.versionAuthorityEntry(
          sourceId: current.chapter.sourceId,
          comicId: relatedComicId,
          chapterId: relatedChapterId,
        );
        if (relatedEntry == null) {
          skippedMissingSourceManifests++;
          continue;
        }
        if (relatedEntry.chapter.sourceRevision != relatedExpectedRevision ||
            relatedEntry.chapter.pages.length != relatedExpectedCount) {
          continue;
        }
        materializedRelatedChapters.add(relatedEntry.identity);
        acceptedMappings++;
      }
    }
    relationFingerprintParts.sort();
    final relationFingerprint = relationFingerprintParts.join('\u0001');
    final previous = _versionReuseAuthorityStates[chapterKey];
    if (previous?.fingerprint == relationFingerprint &&
        previous?.acceptedMappings == acceptedMappings) {
      return previous!.acceptedMappings;
    }

    _versionReuseAuthorityStates[chapterKey] = (
      fingerprint: relationFingerprint,
      acceptedMappings: acceptedMappings,
    );
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-version-reuse:${current.chapter.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${current.chapter.sourceId}\u0000${current.chapter.chapterId}',
        payload: <String, Object?>{
          'stage': 'version-reuse-authority-ready',
          'acceptedMappings': acceptedMappings,
          'hydratedSourceChapters': materializedRelatedChapters.length,
          'skippedMissingSourceManifests': skippedMissingSourceManifests,
          'materializedEquivalenceEdges': 0,
          'restoreMode': 'canonical-media-direct',
        },
      ),
    );
    return acceptedMappings;
  }

  Future<details.ComicDetailsVersionState> _loadSourceVersionState(
    BrowsableComicSource source,
    String title,
    String currentComicId, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
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
      control?.throwIfCancelled();
      final controlled = source is ControlledComicVersionSource
          ? source as ControlledComicVersionSource
          : null;
      final discovered = controlled != null
          ? await controlled.findComicVersionsControlled(
              currentComicId,
              control: control,
            )
          : await versionSource.findComicVersions(currentComicId);
      control?.throwIfCancelled();
      await _rememberSourceSuccessors(
        source: source,
        predecessorComicId: currentComicId,
        predecessorTitle: title,
        successors: discovered.where((item) => !item.isPredecessor),
      );
      final current = _exactLibraryComicForSourceIdentity(
        source.sourceId,
        currentComicId,
      );
      if (control == null && current != null && current.chapters.length == 1) {
        _scheduleVersionReuseWarmup(
          source,
          current.chapters.single,
          deferUntilAfterFrame: false,
        );
      }
      return discovered;
    }

    if (storedSuccessors.isNotEmpty || storedPredecessors.isNotEmpty) {
      final backgroundRefresh = Future<void>(() {}).then((_) async {
        try {
          return stateFor(await refreshVersions());
        } on Object {
          if (control?.cancelled == true) rethrow;
          // A confirmed durable relation remains usable while offline.
          return stateFor(const <SourceComicVersion>[]);
        }
      });
      return stateFor(
        const <SourceComicVersion>[],
        backgroundRefresh: backgroundRefresh,
      );
    }

    var discovered = const <SourceComicVersion>[];
    try {
      discovered = await refreshVersions();
    } on Object {
      if (control?.cancelled == true) rethrow;
      if (storedPredecessors.isEmpty) rethrow;
    }
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
          SnackBar(content: Text(result.summaryMessages().join(' · '))),
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
