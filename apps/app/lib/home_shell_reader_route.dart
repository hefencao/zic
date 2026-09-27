part of 'home_shell.dart';

typedef _PreparedImportedChapter = HomeReaderPreparedChapter;

final class _ReaderAdjacentChapterRef {
  const _ReaderAdjacentChapterRef({
    required this.chapterId,
    required this.sequence,
    this.entry,
  });

  final String chapterId;
  final int sequence;
  final ImportedLibraryEntry? entry;
}

typedef _ReaderPageGenerationRecovery = Future<bool> Function(
  int rawPageIndex,
  Object error, {
  required bool userInitiated,
});

int? readerFreshPageIndexForRecovery(
  ImportedChapterRecord previous,
  ImportedChapterRecord refreshed,
  int previousIndex,
) {
  if (previousIndex < 0 || previousIndex >= previous.pages.length ||
      refreshed.pages.isEmpty) {
    return null;
  }
  final previousPage = previous.pages[previousIndex];
  final pageId = previousPage.pageId;
  if (pageId != null) {
    for (var index = 0; index < refreshed.pages.length; index++) {
      if (refreshed.pages[index].pageId == pageId) return index;
    }
    return null;
  }
  for (var index = 0; index < refreshed.pages.length; index++) {
    if (refreshed.pages[index].sourceId == previousPage.sourceId) return index;
  }
  return previousIndex.clamp(0, refreshed.pages.length - 1).toInt();
}

bool readerPageAuthorityChanged(
  ImportedChapterRecord previous,
  ImportedChapterRecord refreshed,
  int previousIndex,
) {
  final refreshedIndex = readerFreshPageIndexForRecovery(
    previous,
    refreshed,
    previousIndex,
  );
  if (refreshedIndex == null) return false;
  final previousPage = previous.pages[previousIndex];
  final refreshedPage = refreshed.pages[refreshedIndex];
  return previousPage.sourceId != refreshedPage.sourceId ||
      previousPage.contentKindHint != refreshedPage.contentKindHint ||
      previousPage.byteLength != refreshedPage.byteLength ||
      previousPage.animatedHint != refreshedPage.animatedHint;
}

ImportedChapterRecord? readerChapterWithFreshPageAuthorities(
  ImportedChapterRecord previous,
  ImportedChapterRecord refreshed,
  int failedPageIndex,
) {
  if (previous.sourceId != refreshed.sourceId ||
      previous.comicId != refreshed.comicId ||
      previous.chapterId != refreshed.chapterId ||
      previous.sourceRevision != refreshed.sourceRevision) {
    return null;
  }
  final failedFreshIndex = readerFreshPageIndexForRecovery(
    previous,
    refreshed,
    failedPageIndex,
  );
  if (failedFreshIndex == null ||
      !readerPageAuthorityChanged(previous, refreshed, failedPageIndex)) {
    return null;
  }

  // A fresh source generation is chapter-scoped even though only the current
  // page is allowed to trigger it. Persisting just that page mixes carriers
  // from two generations under one sourceRevision; sibling pages can then hit
  // terminal failures that the shared Pipeline correctly remembers. Rebind
  // every old logical page to its matching carrier from this one fresh list,
  // while preserving the old structural page set/order. Any ambiguous or
  // missing explicit page identity fails the whole carrier refresh closed.
  final pages = <ImportedPageRecord>[];
  final usedFreshIndexes = <int>{};
  for (var index = 0; index < previous.pages.length; index++) {
    final freshIndex = readerFreshPageIndexForRecovery(
      previous,
      refreshed,
      index,
    );
    if (freshIndex == null || !usedFreshIndexes.add(freshIndex)) return null;
    pages.add(refreshed.pages[freshIndex]);
  }
  return previous.copyWith(
    pages: List<ImportedPageRecord>.unmodifiable(pages),
  );
}

final class _ReaderComicVersionNoticeGate extends StatefulWidget {
  const _ReaderComicVersionNoticeGate({
    required this.sourceId,
    required this.comicId,
    required this.preferences,
    required this.loadLatestComicId,
    required this.child,
  });

  final String sourceId;
  final String comicId;
  final AppPreferencesController preferences;
  final Future<String?> Function() loadLatestComicId;
  final Widget child;

  @override
  State<_ReaderComicVersionNoticeGate> createState() =>
      _ReaderComicVersionNoticeGateState();
}

final class _ReaderComicVersionNoticeGateState
    extends State<_ReaderComicVersionNoticeGate> {
  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final latestComicId = await widget.loadLatestComicId();
    if (!mounted || latestComicId == null) return;
    if (widget.preferences.hasAcknowledgedComicVersionNotice(
      widget.sourceId,
      widget.comicId,
      latestComicId,
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      widget.preferences.acknowledgeComicVersionNotice(
        widget.sourceId,
        widget.comicId,
        latestComicId,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('发现同源新版本，可在漫画详情页查看更新'),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

extension _HomeShellReaderRouteComposition on _HomeShellState {
  PipelineReaderSessionFactory _readerPipelineFactory() =>
      defaultLocalMediaPipelineFactory
          .withArtifactCacheManager(_readerArtifactCache)
          .withPartialDownloadStore(
            _downloadComposition?.artifactStore,
          )
          .withTransferRuntime(
            _downloadComposition?.transferRuntime,
          )
          .withUserAgentProvider(() => widget.preferences.networkUserAgent);

  List<_ReaderAdjacentChapterRef> _readerChapterSequence(
    ImportedLibraryEntry current,
  ) {
    LibraryComic? comic;
    for (final candidate in _libraryComics) {
      if (candidate.sourceId == current.chapter.sourceId &&
          candidate.comicId == current.chapter.comicId) {
        comic = candidate;
        break;
      }
    }
    final byChapterId = <String, ImportedLibraryEntry>{
      if (comic != null)
        for (final entry in comic.chapters) entry.chapter.chapterId: entry,
    };
    final refs = <_ReaderAdjacentChapterRef>[];
    if (comic != null && comic.sourceChapters.isNotEmpty) {
      for (final chapter in comic.sourceChapters) {
        refs.add(
          _ReaderAdjacentChapterRef(
            chapterId: chapter.chapterId,
            sequence: chapter.sequence,
            entry: byChapterId[chapter.chapterId],
          ),
        );
      }
    } else if (comic != null) {
      for (final entry in comic.chapters) {
        refs.add(
          _ReaderAdjacentChapterRef(
            chapterId: entry.chapter.chapterId,
            sequence: entry.chapter.sequence,
            entry: entry,
          ),
        );
      }
    }
    if (!refs.any((ref) => ref.chapterId == current.chapter.chapterId)) {
      refs.add(
        _ReaderAdjacentChapterRef(
          chapterId: current.chapter.chapterId,
          sequence: current.chapter.sequence,
          entry: current,
        ),
      );
    }
    return homeReaderLogicalChapterOrder(
      refs,
      sequenceOf: (ref) => ref.sequence,
    );
  }

  _ReaderAdjacentChapterRef? _readerAdjacentChapter(
    ImportedLibraryEntry current,
    ReaderChapterBoundary boundary,
  ) {
    final sequence = _readerChapterSequence(current);
    final index = sequence.indexWhere(
      (ref) => ref.chapterId == current.chapter.chapterId,
    );
    if (index < 0) return null;
    final adjacentIndex =
        boundary == ReaderChapterBoundary.previous ? index - 1 : index + 1;
    if (adjacentIndex < 0 || adjacentIndex >= sequence.length) return null;
    return sequence[adjacentIndex];
  }

  Future<ImportedLibraryEntry?> _loadReaderAdjacentEntry(
    ImportedLibraryEntry current,
    ReaderChapterBoundary boundary,
  ) async {
    final adjacent = _readerAdjacentChapter(current, boundary);
    if (adjacent == null) return null;
    final existing = adjacent.entry;
    if (existing != null) return existing;
    if (current.chapter.sourceId == 'local-folder') return null;

    await _externalSources.waitForSource(current.chapter.sourceId);
    final source = _sourceForId(current.chapter.sourceId);
    if (source == null) return null;
    final manifest = await _loadCompatibleSourceChapter(
      source,
      adjacent.chapterId,
    );
    final comic = Comic(
      comicId: current.chapter.comicId,
      sourceId: current.chapter.sourceId,
      title: current.chapter.comicTitle,
      authors: current.chapter.comicAuthors,
      tags: current.chapter.comicTags,
      coverUri: current.chapter.coverSourceId == null
          ? null
          : Uri.tryParse(current.chapter.coverSourceId!),
      description: current.chapter.comicDescription,
      readingDirection: current.chapter.readingDirection,
    );
    return ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: comic,
        manifest: manifest,
      ),
    );
  }

  Widget _buildImportedChapterScreen(
    _PreparedImportedChapter prepared, {
    required Future<void> Function(ReadingProgress) onProgressChanged,
    _ReaderPageGenerationRecovery? onPageGenerationRecovery,
    ReaderChapterBoundaryCallback? onChapterBoundaryRequested,
  }) {
    final current = prepared.entry;
    final preference = _preferences[
          comicLibraryIdentity(
            current.chapter.sourceId,
            current.chapter.comicId,
          )
        ] ??
        ComicPreference.defaults(
          sourceId: current.chapter.sourceId,
          comicId: current.chapter.comicId,
        );
    final initialSettings = widget.preferences.readerSessionSettingsFor(
      current.chapter.sourceId,
      current.chapter.comicId,
    );
    final shouldInvert = initialSettings.effectiveInvertPageOrder;
    final totalPages = current.chapter.pages.length;
    final recordForReader = shouldInvert && totalPages > 1
        ? current.chapter.copyWith(
            pages: current.chapter.pages.reversed.toList(growable: false),
          )
        : current.chapter;

    int mapIndexForReader(int raw) =>
        shouldInvert && totalPages > 1
            ? (totalPages - 1 - raw).clamp(0, totalPages - 1)
            : raw;
    int mapIndexForStorage(int displayed) =>
        shouldInvert && totalPages > 1
            ? (totalPages - 1 - displayed).clamp(0, totalPages - 1)
            : displayed;

    final pageIndex = prepared.initialPageIndex;
    final maxPageIndex = current.chapter.pages.isEmpty
        ? 0
        : current.chapter.pages.length - 1;
    final initialProgress = pageIndex == null
        ? (current.progress == null
            ? null
            : current.progress!.copyWith(
                pageIndex: mapIndexForReader(current.progress!.pageIndex),
              ))
        : ReadingProgress(
            sourceId: current.chapter.sourceId,
            comicId: current.chapter.comicId,
            chapterId: current.chapter.chapterId,
            pageIndex: mapIndexForReader(pageIndex.clamp(0, maxPageIndex).toInt()),
            subPageOffset: 0,
            readerMode: current.progress?.readerMode ??
                widget.preferences.defaultReaderMode,
            updatedAt: DateTime.now().toUtc(),
          );
    final versionSource = _sourceForId(current.chapter.sourceId);
    final comicWebUri = versionSource == null
        ? null
        : _sourceComicWebUri(
            versionSource,
            current.chapter.comicId,
          );
    final screen = ImportedImageChapterScreen(
      record: recordForReader,
      adaptiveMetadata: versionSource == null
          ? null
          : AdaptiveReaderMetadata(
              sourceKey: recordForReader.sourceId,
              comicId: recordForReader.comicId,
              title: recordForReader.comicTitle,
              authors: recordForReader.comicAuthors,
              tags: recordForReader.comicTags,
              sourceName: versionSource.descriptor.name,
              sourceUrl: versionSource.descriptor.website.toString(),
              sourceType: versionSource.descriptor.adaptiveReaderType?.name,
            ),
      byteLoaders: prepared.byteLoaders,
      responseSources: prepared.responseSources,
      initialProgress: initialProgress ??
          ReadingProgress(
            sourceId: current.chapter.sourceId,
            comicId: current.chapter.comicId,
            chapterId: current.chapter.chapterId,
            pageIndex: 0,
            subPageOffset: 0,
            readerMode: widget.preferences.defaultReaderMode,
            updatedAt: DateTime.now().toUtc(),
          ),
      onProgressChanged: (p) => onProgressChanged(
        p.copyWith(pageIndex: mapIndexForStorage(p.pageIndex)),
      ),
      onProgressFlush: _flushReaderProgressCheckpoints,
      initiallyImmersive: widget.preferences.readerStartsImmersive,
      initialReaderSettings: initialSettings,
      onReaderSettingsChanged: (settings) =>
          widget.preferences.saveReaderSessionSettings(
        current.chapter.sourceId,
        current.chapter.comicId,
        settings,
      ),
      onReaderModeSettingsChanged: (mode, settings) =>
          widget.preferences.setReaderModeSettings(mode, settings),
      onOpenGlobalReadingSettings: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ReadingSettingsScreen(
              preferences: widget.preferences,
            ),
          ),
        );
        return widget.preferences.readerSessionSettingsFor(
          current.chapter.sourceId,
          current.chapter.comicId,
        );
      },
      onOpenSourceWebView: versionSource == null || comicWebUri == null
          ? null
          : () => _openSourceWebView(versionSource, comicWebUri),
      onOpenExternalBrowser: comicWebUri == null
          ? null
          : () async {
              await attachAndroidPlugin('network_bridge');
              await widget.networkBridge.openExternalBrowser(comicWebUri);
            },
      traceSink: widget.debugTrace,
      onDownloadRequested: () => _downloadChapter(current),
      onFirstPresentationFrame: versionSource == null
          ? null
          : () => _scheduleReaderMetadataVersionRefresh(versionSource, current),
      onPagePresentationRecovery: onPageGenerationRecovery == null
          ? null
          : (asset, error, {required userInitiated}) =>
              onPageGenerationRecovery(
                mapIndexForStorage(asset.index),
                error,
                userInitiated: userInitiated,
              ),
      canReadPreviousChapter:
          _readerAdjacentChapter(current, ReaderChapterBoundary.previous) !=
              null,
      canReadNextChapter:
          _readerAdjacentChapter(current, ReaderChapterBoundary.next) != null,
      onChapterBoundaryRequested: onChapterBoundaryRequested,
      pipelineFactory: _readerPipelineFactory(),
      initialFavorite: preference.collected,
      onFavoriteChanged: (favorite) {
        final currentPreference = _preferences[
              comicLibraryIdentity(
                current.chapter.sourceId,
                current.chapter.comicId,
              )
            ] ??
            ComicPreference.defaults(
              sourceId: current.chapter.sourceId,
              comicId: current.chapter.comicId,
            );
        return _savePreference(
          currentPreference.copyWith(collected: favorite),
        );
      },
    );
    return _ReaderComicVersionNoticeGate(
      sourceId: current.chapter.sourceId,
      comicId: current.chapter.comicId,
      preferences: widget.preferences,
      loadLatestComicId: () async {
        final latest = _librarySession.versionBaselines.latestKnownHeadFor(
          current.chapter.sourceId,
          current.chapter.comicId,
        );
        return latest == null || latest == current.chapter.comicId
            ? null
            : latest;
      },
      child: screen,
    );
  }

  Future<ReadingProgress?> _openImportedChapterLoader(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required String title,
    bool refreshRemote = true,
    int? initialPageIndex,
  }) async {
    if (!mounted) return null;
    ReadingProgress? latestProgress;
    var currentRawPageIndex = initialPageIndex;
    VoidCallback? onReaderPageChanged;
    Future<void> onProgressChanged(ReadingProgress progress) {
      latestProgress = progress;
      currentRawPageIndex = progress.pageIndex;
      onReaderPageChanged?.call();
      return _enqueueReaderProgress(progress);
    }
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.nowMicros(),
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: <String, Object?>{
          'stage': 'loader-push-start',
          'title': title,
          'refreshRemote': refreshRemote,
          'initialPageIndex': initialPageIndex,
        },
      ),
    );
    // Decode workers are process-lifetime Reader infrastructure, but warming
    // them during Home startup used to compete with first raster/cover work.
    // Reader entry already has an asynchronous chapter-preparation window, so
    // overlap the one-time worker startup with that work instead of charging
    // the first decoded frame. Prewarm remains acceleration-only: chapter
    // preparation never waits for it, and the normal decode/presentation path
    // retains authority to join/retry/report the capability if it is still
    // starting or the speculative warmup fails.
    final mediaPrewarm = prewarmDefaultLocalMediaPipeline();
    unawaited(
      mediaPrewarm.catchError((Object error, StackTrace _) {
        debugPrint('Reader media prewarm unavailable: $error');
      }),
    );

    final replacementPrepared =
        ValueNotifier<_PreparedImportedChapter?>(null);
    final automaticGenerationRecoveries = <String>{};
    _PreparedImportedChapter? currentPrepared;
    ({String pageKey, Future<bool> future})? activeGenerationRecovery;
    final adjacentPreparations =
        <String, Future<_PreparedImportedChapter?>>{};
    final adjacentPreloadLeases =
        <ReaderChapterBoundary, CompositionChapterPreloadLease>{};
    final adjacentPreloadChapterKeys = <ReaderChapterBoundary, String>{};
    ({_PreparedImportedChapter prepared, int rawPageIndex})?
        pendingAdjacentPreload;
    Future<void>? adjacentPreloadDrain;
    var routeActive = false;

    String adjacentKey(
      ImportedLibraryEntry current,
      ReaderChapterBoundary boundary,
    ) =>
        '${current.chapter.chapterId}:${current.chapter.sourceRevision}:${boundary.name}';

    Future<_PreparedImportedChapter?> prepareAdjacent(
      _PreparedImportedChapter current,
      ReaderChapterBoundary boundary,
    ) =>
        homeReaderCoalesceSuccessfulAdjacentPreparation(
          cache: adjacentPreparations,
          key: adjacentKey(current.entry, boundary),
          prepare: () async {
            final entry =
                await _loadReaderAdjacentEntry(current.entry, boundary);
            if (entry == null) return null;
            final settings = widget.preferences.readerSessionSettingsFor(
              entry.chapter.sourceId,
              entry.chapter.comicId,
            );
            final inverted = settings.effectiveInvertPageOrder;
            final lastPage = entry.chapter.pages.length - 1;
            final initial = boundary == ReaderChapterBoundary.previous
                ? inverted
                    ? 0
                    : lastPage
                : inverted
                    ? lastPage
                    : 0;
            return _readerChapterComposition.prepare(
              () async => entry,
              refreshRemote: false,
              initialPageIndex: initial,
            );
          },
        );

    Future<void> closeAdjacentPreload(
      ReaderChapterBoundary boundary,
    ) async {
      adjacentPreloadChapterKeys.remove(boundary);
      final lease = adjacentPreloadLeases.remove(boundary);
      if (lease != null) await lease.close();
    }

    Future<void> closeAdjacentPreloads() async {
      for (final boundary in ReaderChapterBoundary.values) {
        await closeAdjacentPreload(boundary);
      }
    }

    Future<void> applyAdjacentPreload(
      _PreparedImportedChapter prepared,
      int rawPageIndex,
    ) async {
      if (!routeActive || !identical(currentPrepared, prepared)) return;
      final runtime = _downloadComposition?.transferRuntime;
      if (runtime == null) {
        await closeAdjacentPreloads();
        return;
      }
      final current = prepared.entry;
      final pageCount = current.chapter.pages.length;
      if (pageCount <= 0) {
        await closeAdjacentPreloads();
        return;
      }
      final currentSettings = widget.preferences.readerSessionSettingsFor(
        current.chapter.sourceId,
        current.chapter.comicId,
      );
      final inverted = currentSettings.effectiveInvertPageOrder;
      final raw = rawPageIndex.clamp(0, pageCount - 1).toInt();
      final window = ReaderPipelineProfile.stable.windowResolver;
      final residual = homeReaderAdjacentPreloadResidual(
        pageCount: pageCount,
        rawPageIndex: raw,
        inverted: inverted,
        forwardEncodedPages: window.forwardEncodedPages,
        backwardEncodedPages: window.backwardEncodedPages,
      );
      final displayedIndex = residual.displayedIndex;
      final desiredCounts = <ReaderChapterBoundary, int>{
        ReaderChapterBoundary.previous: residual.previous,
        ReaderChapterBoundary.next: residual.next,
      };

      for (final boundary in ReaderChapterBoundary.values) {
        final requestedCount = desiredCounts[boundary] ?? 0;
        if (requestedCount <= 0) {
          await closeAdjacentPreload(boundary);
          continue;
        }
        _PreparedImportedChapter? adjacent;
        try {
          adjacent = await prepareAdjacent(prepared, boundary);
        } on Object catch (error) {
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.nowMicros(),
              sessionId: 'reader-entry',
              kind: TraceEventKind.taskFailed,
              payload: <String, Object?>{
                'stage': 'cross-chapter-preload-prepare-failed',
                'boundary': boundary.name,
                'chapterId': current.chapter.chapterId,
                'error': error.toString(),
              },
            ),
          );
          continue;
        }
        if (!routeActive ||
            !identical(currentPrepared, prepared) ||
            adjacent == null) {
          return;
        }
        final manifest = adjacent.entry.chapter.toManifest();
        final adjacentPageCount = manifest.pages.length;
        final preloadCount = requestedCount
            .clamp(0, adjacentPageCount)
            .toInt();
        final adjacentSettings = widget.preferences.readerSessionSettingsFor(
          adjacent.entry.chapter.sourceId,
          adjacent.entry.chapter.comicId,
        );
        final adjacentInverted = adjacentSettings.effectiveInvertPageOrder;
        final pages = boundary == ReaderChapterBoundary.previous
            ? adjacentInverted
                ? manifest.pages.take(preloadCount).toList(growable: false)
                : manifest.pages
                    .skip(adjacentPageCount - preloadCount)
                    .toList(growable: false)
            : adjacentInverted
                ? manifest.pages
                    .skip(adjacentPageCount - preloadCount)
                    .toList(growable: false)
                : manifest.pages.take(preloadCount).toList(growable: false);
        if (pages.isEmpty) {
          await closeAdjacentPreload(boundary);
          continue;
        }

        final chapterKey = '${manifest.sourceId}:${manifest.comicId}:'
            '${manifest.chapter.chapterId}:${manifest.chapter.sourceRevision}';
        final existing = adjacentPreloadLeases[boundary];
        if (existing != null &&
            adjacentPreloadChapterKeys[boundary] == chapterKey) {
          existing.replacePages(pages);
        } else {
          await closeAdjacentPreload(boundary);
          if (!routeActive || !identical(currentPrepared, prepared)) return;
          final loaderTransport = importedImageChapterLoaderTransport(
            record: adjacent.entry.chapter,
            byteLoaders: adjacent.byteLoaders,
            responseSources: adjacent.responseSources,
          );
          final profile = ReaderPipelineProfile.stable;
          adjacentPreloadLeases[boundary] = runtime.preloadChapterPages(
            scopeId: 'reader-adjacent:${boundary.name}:$chapterKey',
            chapter: manifest,
            pages: pages,
            fallbackFor: (_) => loaderTransport,
            traceSink: widget.debugTrace,
            downloadBucketFor: profile.downloadBucket,
            downloadBucketLimitFor: profile.downloadBucketLimit,
          );
          adjacentPreloadChapterKeys[boundary] = chapterKey;
        }
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.nowMicros(),
            sessionId: 'reader-entry',
            kind: TraceEventKind.readerObservation,
            payload: <String, Object?>{
              'stage': 'cross-chapter-preload-synced',
              'boundary': boundary.name,
              'fromChapterId': current.chapter.chapterId,
              'chapterId': adjacent.entry.chapter.chapterId,
              'pages': pages.length,
              'rawPageIndex': raw,
              'displayedPageIndex': displayedIndex,
              'priority': 500,
            },
          ),
        );
      }
    }

    Future<void> drainAdjacentPreload() async {
      while (routeActive) {
        final request = pendingAdjacentPreload;
        if (request == null) return;
        pendingAdjacentPreload = null;
        await applyAdjacentPreload(request.prepared, request.rawPageIndex);
      }
    }

    void scheduleAdjacentPreload(
      _PreparedImportedChapter prepared,
      int rawPageIndex,
    ) {
      if (!routeActive) return;
      pendingAdjacentPreload = (
        prepared: prepared,
        rawPageIndex: rawPageIndex,
      );
      if (adjacentPreloadDrain != null) return;
      late final Future<void> drain;
      drain = drainAdjacentPreload().whenComplete(() {
        if (!identical(adjacentPreloadDrain, drain)) return;
        adjacentPreloadDrain = null;
        final pending = pendingAdjacentPreload;
        if (routeActive && pending != null) {
          scheduleAdjacentPreload(pending.prepared, pending.rawPageIndex);
        }
      });
      adjacentPreloadDrain = drain;
      unawaited(drain);
    }

    onReaderPageChanged = () {
      final prepared = currentPrepared;
      final rawPageIndex = currentRawPageIndex;
      if (prepared == null || rawPageIndex == null) return;
      scheduleAdjacentPreload(prepared, rawPageIndex);
    };

    Future<void> requestChapterBoundary(
      ReaderChapterBoundary boundary,
    ) async {
      final previous = currentPrepared;
      if (!routeActive || previous == null) return;
      final adjacentRef = _readerAdjacentChapter(previous.entry, boundary);
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.nowMicros(),
          sessionId: 'reader-entry',
          kind: TraceEventKind.readerObservation,
          payload: <String, Object?>{
            'stage': 'chapter-boundary-request-start',
            'boundary': boundary.name,
            'fromChapterId': previous.entry.chapter.chapterId,
            'fromSequence': previous.entry.chapter.sequence,
            'targetChapterId': adjacentRef?.chapterId,
            'targetSequence': adjacentRef?.sequence,
          },
        ),
      );
      try {
        final preparedAdjacent = await prepareAdjacent(previous, boundary);
        if (!routeActive) return;
        if (preparedAdjacent == null) {
          throw StateError(
            boundary == ReaderChapterBoundary.next
                ? '下一章暂时不可用'
                : '上一章暂时不可用',
          );
        }
        try {
          await _flushReaderProgressCheckpoints();
        } on Object catch (error) {
          debugPrint('reader chapter-boundary progress flush failed: $error');
        }
        final persistedEntry =
            await _librarySession.upsertChapter(preparedAdjacent.entry.chapter);
        if (!routeActive) return;
        final replacement = HomeReaderPreparedChapter(
          entry: persistedEntry,
          byteLoaders: preparedAdjacent.byteLoaders,
          responseSources: preparedAdjacent.responseSources,
          initialPageIndex: preparedAdjacent.initialPageIndex,
        );
        currentPrepared = replacement;
        currentRawPageIndex = replacement.initialPageIndex ??
            replacement.entry.progress?.pageIndex ??
            0;
        replacementPrepared.value = replacement;
        scheduleAdjacentPreload(replacement, currentRawPageIndex!);
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.nowMicros(),
            sessionId: 'reader-entry',
            kind: TraceEventKind.readerObservation,
            payload: <String, Object?>{
              'stage': 'chapter-boundary-request-complete',
              'boundary': boundary.name,
              'fromChapterId': previous.entry.chapter.chapterId,
              'fromSequence': previous.entry.chapter.sequence,
              'chapterId': replacement.entry.chapter.chapterId,
              'sequence': replacement.entry.chapter.sequence,
              'initialPageIndex': currentRawPageIndex,
            },
          ),
        );
      } on Object catch (error) {
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.nowMicros(),
            sessionId: 'reader-entry',
            kind: TraceEventKind.taskFailed,
            payload: <String, Object?>{
              'stage': 'chapter-boundary-request-failed',
              'boundary': boundary.name,
              'fromChapterId': previous.entry.chapter.chapterId,
              'fromSequence': previous.entry.chapter.sequence,
              'targetChapterId': adjacentRef?.chapterId,
              'targetSequence': adjacentRef?.sequence,
              'error': error.toString(),
            },
          ),
        );
        if (routeActive) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                boundary == ReaderChapterBoundary.next
                    ? '加载下一章失败，可继续上滑重试'
                    : '加载上一章失败，可继续下拉重试',
              ),
            ),
          );
        }
      }
    }

    Future<bool> recoverPageGeneration(
      int rawPageIndex,
      Object error, {
      required bool userInitiated,
    }) async {
      if (!sourceResourceGenerationRefreshEligible(error)) return false;
      final previous = currentPrepared;
      if (previous == null ||
          rawPageIndex < 0 ||
          rawPageIndex >= previous.entry.chapter.pages.length) {
        return false;
      }
      if (!userInitiated && currentRawPageIndex != rawPageIndex) return false;
      final previousPage = previous.entry.chapter.pages[rawPageIndex];
      final pageKey = previousPage.pageId ?? 'index:$rawPageIndex';
      final active = activeGenerationRecovery;
      if (active != null) {
        return active.pageKey == pageKey ? active.future : false;
      }
      if (!userInitiated && !automaticGenerationRecoveries.add(pageKey)) {
        return false;
      }
      late final Future<bool> recovery;
      recovery = () async {
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.nowMicros(),
            sessionId: 'reader-entry',
            kind: TraceEventKind.readerObservation,
            payload: <String, Object?>{
              'stage': 'source-page-authority-refresh-start',
              'pageIndex': rawPageIndex,
              'userInitiated': userInitiated,
              'sourceSemanticAcceptedPlans':
                  (error as Failure).details['sourceSemanticAcceptedPlans'],
              'sourceSemanticRecoveryUnavailable':
                  error.details['sourceSemanticRecoveryUnavailable'],
            },
          ),
        );
        late final ImportedLibraryEntry replacementEntry;
        try {
          final refreshedSnapshot = await _loadRemoteEntrySnapshot(
            previous.entry,
            forceSourceRefresh: true,
          );
          if (_hasLegacyVeneraLocators(refreshedSnapshot.chapter)) {
            throw StateError(
              'Venera 章节刷新后仍包含已失效的运行时资源定位符',
            );
          }
          final replacementChapter = readerChapterWithFreshPageAuthorities(
            previous.entry.chapter,
            refreshedSnapshot.chapter,
            rawPageIndex,
          );
          if (replacementChapter == null) {
            widget.debugTrace.record(
              TraceEvent(
                monotonicMicros: _traceClock.nowMicros(),
                sessionId: 'reader-entry',
                kind: TraceEventKind.artifactSource,
                payload: <String, Object?>{
                  'stage': 'source-page-authority-refresh-no-change',
                  'pageIndex': rawPageIndex,
                },
              ),
            );
            return false;
          }
          replacementEntry =
              await _librarySession.upsertChapter(replacementChapter);
        } on Object catch (refreshError) {
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.nowMicros(),
              sessionId: 'reader-entry',
              kind: TraceEventKind.taskFailed,
              payload: <String, Object?>{
                'stage': 'source-page-authority-refresh-failed',
                'pageIndex': rawPageIndex,
                'error': refreshError.toString(),
              },
            ),
          );
          return false;
        }
        final readerManifest = replacementEntry.chapter.toManifest();
        final byteLoaders = <String, LocalImageFileBytesLoader>{};
        final replacement = HomeReaderPreparedChapter(
          entry: replacementEntry,
          byteLoaders: byteLoaders,
          responseSources: _readerChapterComposition.responseSourcesFor(
            readerManifest,
            byteLoaders,
          ),
          initialPageIndex: rawPageIndex,
        );
        if (!routeActive) return false;
        currentPrepared = replacement;
        currentRawPageIndex = rawPageIndex;
        replacementPrepared.value = replacement;
        scheduleAdjacentPreload(replacement, rawPageIndex);
        await WidgetsBinding.instance.endOfFrame;
        final replaced = routeActive;
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.nowMicros(),
            sessionId: 'reader-entry',
            kind: TraceEventKind.artifactSource,
            payload: <String, Object?>{
              'stage': replaced
                  ? 'source-page-authority-replaced'
                  : 'source-page-authority-replace-unavailable',
              'pageIndex': rawPageIndex,
              'replacementPageIndex': rawPageIndex,
            },
          ),
        );
        return replaced;
      }();
      activeGenerationRecovery = (pageKey: pageKey, future: recovery);
      try {
        return await recovery;
      } finally {
        if (identical(activeGenerationRecovery?.future, recovery)) {
          activeGenerationRecovery = null;
        }
      }
    }

    final route = MaterialPageRoute<void>(
      builder: (_) => DeferredReaderRoute<_PreparedImportedChapter>(
        title: title,
        traceSink: widget.debugTrace,
        traceSessionId: 'reader-entry',
        load: () async {
          final prepared = await _readerChapterComposition.prepare(
            loadChapter,
            refreshRemote: refreshRemote,
            initialPageIndex: initialPageIndex,
          );
          currentPrepared = prepared;
          currentRawPageIndex = prepared.initialPageIndex ??
              prepared.entry.progress?.pageIndex ??
              0;
          scheduleAdjacentPreload(prepared, currentRawPageIndex!);
          return prepared;
        },
        builder: (_, prepared) =>
            ValueListenableBuilder<_PreparedImportedChapter?>(
          valueListenable: replacementPrepared,
          builder: (_, replacement, _) => _buildImportedChapterScreen(
            replacement ?? prepared,
            onProgressChanged: onProgressChanged,
            onPageGenerationRecovery: recoverPageGeneration,
            onChapterBoundaryRequested: requestChapterBoundary,
          ),
        ),
      ),
    );

    _routeAdmission.beginReaderRoute();
    routeActive = true;
    try {
      await Navigator.of(context).push(route);
      try {
        await _flushReaderProgressCheckpoints();
      } on Object catch (error) {
        debugPrint('reader post-pop progress flush failed: $error');
      }
      var progress = latestProgress;
      final prepared = currentPrepared;
      if (prepared != null) {
        try {
          final refreshed = await _librarySession.hydrateEntry(
            prepared.entry,
            awaitCanonicalPhysicalBackfill: false,
          );
          final persisted = refreshed.progress;
          if (persisted != null &&
              (progress == null ||
                  persisted.updatedAt.isAfter(progress.updatedAt))) {
            progress = persisted;
          }
        } on Object catch (error) {
          // Route-local progress is still a valid fallback. This narrow
          // post-pop refresh exists only to ensure the mutable durable
          // progress owner immediately outranks a cached hydrated manifest.
          debugPrint('reader post-pop progress refresh failed: $error');
        }
      }
      if (progress != null) {
        _librarySession.replaceProgress(progress);
      }
      return progress;
    } finally {
      routeActive = false;
      pendingAdjacentPreload = null;
      final preloadDrain = adjacentPreloadDrain;
      if (preloadDrain != null) await preloadDrain;
      await closeAdjacentPreloads();
      replacementPrepared.dispose();
      final readerRouteClosed = _routeAdmission.endReaderRoute();
      if (readerRouteClosed && mounted) {
        _setState(() {});
      }
    }
  }

}
