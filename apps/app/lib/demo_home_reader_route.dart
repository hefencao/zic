part of 'demo_home.dart';

typedef _PreparedImportedChapter = ({
  ImportedLibraryEntry entry,
  Map<String, LocalImageFileBytesLoader> byteLoaders,
  Map<String, LocalImageResponseSource> responseSources,
  int? initialPageIndex,
});

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
      pipelineFactory: defaultLocalMediaPipelineFactory
          .withArtifactCacheManager(_readerArtifactCache)
          .withPartialDownloadStore(
            _downloadComposition?.artifactStore ??
                (_chapterDownloads is PartialDownloadStore
                    ? _chapterDownloads as PartialDownloadStore
                    : null),
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
    Future<void> onProgressChanged(ReadingProgress progress) {
      latestProgress = progress;
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

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeferredReaderRoute<_PreparedImportedChapter>(
          title: title,
          load: () => _prepareImportedChapter(
            loadChapter,
            refreshRemote: refreshRemote,
            initialPageIndex: initialPageIndex,
          ),
          builder: (_, prepared) => this._buildImportedChapterScreen(
            prepared,
            onProgressChanged: onProgressChanged,
          ),
        ),
      ),
    );
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
  }

  Future<_PreparedImportedChapter> _prepareImportedChapter(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required bool refreshRemote,
    int? initialPageIndex,
  }) async {
    final totalWatch = Stopwatch()..start();
    final rawEntry = await loadChapter();
    final loadMs = totalWatch.elapsedMilliseconds;
    final entry = await _librarySession.hydrateEntry(rawEntry);
    final hydrateMs = totalWatch.elapsedMilliseconds - loadMs;
    final legacyVenera = _hasLegacyVeneraLocators(entry.chapter);
    final remoteWatch = Stopwatch()..start();
    final current = legacyVenera
        ? await _refreshRemoteEntry(entry, forceSourceRefresh: true)
        : refreshRemote
            ? await _refreshRemoteEntry(entry)
            : entry;
    final remoteMs = remoteWatch.elapsedMilliseconds;
    if (_hasLegacyVeneraLocators(current.chapter)) {
      throw StateError(
        'Venera 章节仍包含已失效的运行时资源定位符，已阻止进入 Reader',
      );
    }
    final restoreWatch = Stopwatch()..start();
    final restoredCount =
        await _restoreSourceVersionArtifactEquivalences(current);
    final restoreMs = restoreWatch.elapsedMilliseconds;
    final versionSource = _sourceForId(current.chapter.sourceId);
    if (versionSource != null) {
      _scheduleVersionReuseWarmup(versionSource, current.chapter.comicId);
    }
    // Persistent remote bytes are owned by ArtifactCacheTransport. Do not
    // pre-probe the chapter index or register a full-page readPage() loader:
    // that capability bypasses the streaming artifact response path and makes
    // large SAF/POSIX foreground pages wait for complete Uint8List materialization.
    final byteLoaders = <String, LocalImageFileBytesLoader>{};
    const byteProbeMs = 0;
    final responseSources = current.chapter.sourceId == 'local-folder'
        ? const <String, LocalImageResponseSource>{}
        : <String, LocalImageResponseSource>{
            for (final page in current.chapter.pages)
              if (!byteLoaders.containsKey(page.sourceId))
                page.sourceId: LocalImageResponseSource(
                  openControlledResponse:
                      _sourceResources.pageControlledResponseLoaderFor(
                    current.chapter.sourceId,
                    Uri.parse(page.sourceId),
                  ),
                  selfBoundedOpen: _sourceResources.pageOpenSelfBoundedFor(
                    current.chapter.sourceId,
                    Uri.parse(page.sourceId),
                  ),
                ),
          };
    unawaited(_markChapterReadForNavigation(current));
    final totalMs = totalWatch.elapsedMilliseconds;
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: <String, Object?>{
          'stage': 'reader-prepare-complete',
          'sourceId': current.chapter.sourceId,
          'comicId': current.chapter.comicId,
          'chapterId': current.chapter.chapterId,
          'refreshRemote': refreshRemote,
          'totalPages': current.chapter.pages.length,
          'localByteLoaders': byteLoaders.length,
          'networkResponseLoaders': responseSources.length,
          'loadChapterMs': loadMs,
          'hydrateMs': hydrateMs,
          'remoteRefreshMs': remoteMs,
          'versionReuseRegistrationMs': restoreMs,
          'registeredEquivalentCoveragePages': restoredCount,
          'byteProbeMs': byteProbeMs,
          'totalPrepareMs': totalMs,
        },
      ),
    );
    return (
      entry: current,
      byteLoaders: byteLoaders,
      responseSources: responseSources,
      initialPageIndex: initialPageIndex,
    );
  }
}
