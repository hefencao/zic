part of 'demo_home.dart';

typedef _PreparedImportedChapter = HomeReaderPreparedChapter;

typedef _ReaderPageGenerationRecovery = Future<bool> Function(
  int rawPageIndex,
  Object error, {
  required bool userInitiated,
});

bool readerSourceGenerationRefreshEligible(Object error) {
  if (error is! Failure || error.code != ErrorCode.source) return false;
  final details = error.details;
  return details['sourceMediaSemanticRejected'] == true &&
      details['sourceSemanticRetryExhausted'] == true &&
      details['sourceSemanticRecoveryUnavailable'] == true &&
      details['sourceSemanticAcceptedPlans'] == 0;
}

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

ImportedChapterRecord? readerChapterWithFreshPageAuthority(
  ImportedChapterRecord previous,
  ImportedChapterRecord refreshed,
  int previousIndex,
) {
  if (previous.sourceId != refreshed.sourceId ||
      previous.comicId != refreshed.comicId ||
      previous.chapterId != refreshed.chapterId ||
      previous.sourceRevision != refreshed.sourceRevision) {
    return null;
  }
  final refreshedIndex = readerFreshPageIndexForRecovery(
    previous,
    refreshed,
    previousIndex,
  );
  if (refreshedIndex == null ||
      !readerPageAuthorityChanged(previous, refreshed, previousIndex)) {
    return null;
  }
  final pages = previous.pages.toList(growable: false);
  pages[previousIndex] = refreshed.pages[refreshedIndex];
  return previous.copyWith(pages: pages);
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

extension _DemoHomeReaderRouteComposition on _DemoHomeState {
  Widget _buildImportedChapterScreen(
    _PreparedImportedChapter prepared, {
    required Future<void> Function(ReadingProgress) onProgressChanged,
    _ReaderPageGenerationRecovery? onPageGenerationRecovery,
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
    final screen = ImportedImageChapterScreen(
      record: recordForReader,
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
      pipelineFactory: defaultLocalMediaPipelineFactory
          .withArtifactCacheManager(_readerArtifactCache)
          .withPartialDownloadStore(
            _downloadComposition?.artifactStore,
          )
          .withTransferRuntime(
            _downloadComposition?.transferRuntime,
          )
          .withUserAgentProvider(() => widget.preferences.networkUserAgent),
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
    Future<void> onProgressChanged(ReadingProgress progress) {
      latestProgress = progress;
      currentRawPageIndex = progress.pageIndex;
      return _enqueueReaderProgress(progress);
    }
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
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
    var routeActive = false;

    Future<bool> recoverPageGeneration(
      int rawPageIndex,
      Object error, {
      required bool userInitiated,
    }) async {
      if (!readerSourceGenerationRefreshEligible(error)) return false;
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
            monotonicMicros: _traceClock.elapsedMicroseconds,
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
          final replacementChapter = readerChapterWithFreshPageAuthority(
            previous.entry.chapter,
            refreshedSnapshot.chapter,
            rawPageIndex,
          );
          if (replacementChapter == null) {
            widget.debugTrace.record(
              TraceEvent(
                monotonicMicros: _traceClock.elapsedMicroseconds,
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
              monotonicMicros: _traceClock.elapsedMicroseconds,
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
        await WidgetsBinding.instance.endOfFrame;
        final replaced = routeActive;
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
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
          return prepared;
        },
        builder: (_, prepared) =>
            ValueListenableBuilder<_PreparedImportedChapter?>(
          valueListenable: replacementPrepared,
          builder: (_, replacement, _) => _buildImportedChapterScreen(
            replacement ?? prepared,
            onProgressChanged: onProgressChanged,
            onPageGenerationRecovery: recoverPageGeneration,
          ),
        ),
      ),
    );

    _beginReaderRoute();
    routeActive = true;
    try {
      await Navigator.of(context).push(route);
      try {
        await _flushReaderProgressCheckpoints();
      } on Object catch (error) {
        debugPrint('reader post-pop progress flush failed: $error');
      }
      final progress = latestProgress;
      if (progress != null) {
        _librarySession.replaceProgress(progress);
      }
      return progress;
    } finally {
      routeActive = false;
      replacementPrepared.dispose();
      _endReaderRoute();
    }
  }

}
