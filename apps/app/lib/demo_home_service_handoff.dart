part of 'demo_home.dart';

extension _DemoHomeServiceHandoff on _DemoHomeState {
  void _handleServiceHandoffChanged() {
    if (!mounted) {
      return;
    }
    final library = _incomingLibraryStore;
    final chapterDownloads = _incomingChapterDownloads;
    final wholeComicDownloads = _incomingWholeComicDownloads;
    if (library != null &&
        chapterDownloads != null &&
        wholeComicDownloads != null &&
        (!identical(library, _library) ||
            !identical(chapterDownloads, _chapterDownloads) ||
            !identical(wholeComicDownloads, _wholeComicDownloads))) {
      unawaited(_adoptDurableServices());
    }
    final plugins = _incomingExternalPlugins;
    if (plugins != null &&
        !identical(_externalSources.activeController, plugins)) {
      _externalSources.adoptController(plugins);
    } else if (_externalPluginLoader != null) {
      // The loader may arrive before the controller object itself. Wake exact
      // waiters; the lifecycle owner still activates only their source owner.
      _externalSources.signalLoaderAvailable();
    }
  }

  Future<void> _adoptDurableServices() {
    final existing = _durableAdoption;
    if (existing != null) return existing;
    late final Future<void> adoption;
    adoption = _adoptDurableServicesOnce().whenComplete(() {
      if (identical(_durableAdoption, adoption)) {
        _durableAdoption = null;
      }
    });
    _durableAdoption = adoption;
    return adoption;
  }

  Future<void> _adoptDurableServicesOnce() async {
    final library = _incomingLibraryStore;
    final chapterDownloads = _incomingChapterDownloads;
    final wholeComicDownloads = _incomingWholeComicDownloads;
    if (library == null ||
        chapterDownloads == null ||
        wholeComicDownloads == null) {
      return;
    }
    // A download-only rebuild (directory switch) keeps the library store
    // instance, so the gate must accept an unchanged library as long as any
    // owned service instance changed.
    final libraryChanged = !identical(library, _library);
    final downloadsChanged =
        !identical(chapterDownloads, _chapterDownloads) ||
            !identical(wholeComicDownloads, _wholeComicDownloads);
    if (!libraryChanged && !downloadsChanged) {
      return;
    }
    final previousChapterDownloads = _chapterDownloads;
    final previousCacheCoordinator = _cacheCoordinator;
    final previousOwnsCacheCoordinator = _ownsCacheCoordinator;
    final downloadComposition = _incomingDownloadComposition ??
        (chapterDownloads is ChapterDownloadTransferRuntimeProvider
            ? chapterDownloads as ChapterDownloadTransferRuntimeProvider
            : null);
    final readerArtifactCache = downloadComposition?.artifactCacheManager ??
        (chapterDownloads is ArtifactCacheBackend
            ? ArtifactCacheManager(backend: chapterDownloads as ArtifactCacheBackend)
            : null);
    final suppliedCache = _incomingCacheCoordinator;
    final cacheCoordinator = suppliedCache ??
        ResourceCacheCoordinator(
          artifacts: downloadComposition?.artifactStore ??
              (chapterDownloads is ArtifactCacheMaintenance
                  ? chapterDownloads as ArtifactCacheMaintenance
                  : null),
        );
    final externalPlugins =
        _incomingExternalPlugins ?? _externalSources.activeController;
    final sources = _buildCachedSources(
      cacheCoordinator,
      externalPlugins: externalPlugins,
    );

    try {
      await _librarySession.adoptServices(
        library: library,
        chapterDownloads: chapterDownloads,
        wholeComicDownloads: wholeComicDownloads,
        sources: sources,
        persistSnapshot: _persistHomeProjectionSnapshot,
      );
    } on Object catch (error) {
      debugPrint('durable Home service handoff failed: $error');
      // Session adoption is all-or-nothing: on failure every binding still
      // points at the previous composition, so there is nothing to roll back.
      return;
    }
    // Swap Home's bindings only after the session adopted, so Home and the
    // session can never disagree about which composition is authoritative.
    _sourceResources.unbindFrom(previousChapterDownloads);
    _sourceResources.bindTo(chapterDownloads);
    _library = library;
    _chapterDownloads = chapterDownloads;
    _downloadComposition = downloadComposition;
    _scheduleLocalReadBackendPrewarm();
    _readerArtifactCache = readerArtifactCache;
    _syncCachedCarrierTrustMode();
    _wholeComicDownloads = wholeComicDownloads;
    _cacheCoordinator = cacheCoordinator;
    _ownsCacheCoordinator = suppliedCache == null;
    _sources = sources;
    unawaited(_recoverCommittedSourceMigrations());
    if (previousOwnsCacheCoordinator &&
        !identical(previousCacheCoordinator, _cacheCoordinator) &&
        !identical(
          previousCacheCoordinator.responses,
          _cacheCoordinator.responses,
        )) {
      await previousCacheCoordinator.close();
    }
    // Snapshot cover requests may already be waiting for the deferred plugin
    // loader. Release that handoff gate only; each request retains its exact
    // source identity and owns the decision to activate that one runtime.
    if (_externalSources.activeController != null ||
        _externalPluginLoader != null) {
      _externalSources.signalLoaderAvailable();
    }
  }
  void _scheduleLocalReadBackendPrewarm() {
    final target = _downloadComposition;
    if (target == null || identical(target, _localReadBackendPrewarmTarget)) {
      return;
    }
    _localReadBackendPrewarmTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_downloadComposition, target)) return;
      final startedAtMicros = _traceClock.elapsedMicroseconds;
      unawaited(
        target.prewarmLocalReadBackend().then<void>((warmed) {
          if (!mounted) return;
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.elapsedMicroseconds,
              sessionId: 'home-storage-prewarm',
              kind: TraceEventKind.artifactSource,
              payload: <String, Object?>{
                'stage': 'local-read-backend-prewarm',
                'warmed': warmed,
                'durationMicros':
                    _traceClock.elapsedMicroseconds - startedAtMicros,
              },
            ),
          );
        }).catchError((Object error, StackTrace _) {
          // Acceleration only; the real Reader path retains normal authority.
        }),
      );
    });
  }

}
