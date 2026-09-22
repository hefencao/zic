part of 'demo_home.dart';

extension _DemoHomeServiceHandoff on _DemoHomeState {
  void _handleServiceHandoffChanged() {
    if (!mounted) {
      return;
    }
    if (_needsDurableServiceAdoption()) {
      _startDurableServiceAdoption();
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

  bool _needsDurableServiceAdoption() {
    final library = _incomingLibraryStore;
    final chapterDownloads = _incomingChapterDownloads;
    final wholeComicDownloads = _incomingWholeComicDownloads;
    if (library == null ||
        chapterDownloads == null ||
        wholeComicDownloads == null) {
      return false;
    }
    final downloadComposition = HomeLibrarySession.resolveDownloadComposition(
      chapterDownloads,
      _incomingDownloadComposition,
    );
    final suppliedCache = _incomingCacheCoordinator;
    return !identical(library, _library) ||
        !identical(chapterDownloads, _chapterDownloads) ||
        !identical(downloadComposition, _downloadComposition) ||
        !identical(wholeComicDownloads, _wholeComicDownloads) ||
        (suppliedCache != null &&
            !identical(suppliedCache, _cacheCoordinator));
  }

  void _startDurableServiceAdoption() {
    unawaited(_adoptDurableServices().catchError((Object error) {
      debugPrint('durable Home service handoff failed: $error');
    }));
  }

  Future<void> _adoptDurableServices() {
    final existing = _durableAdoption;
    if (existing != null) return existing;
    final library = _incomingLibraryStore;
    final downloads = _incomingChapterDownloads;
    final composition = _incomingDownloadComposition;
    final queue = _incomingWholeComicDownloads;
    final cache = _incomingCacheCoordinator;
    var succeeded = false;
    late final Future<void> adoption;
    adoption = _adoptDurableServicesOnce().then((_) {
      succeeded = true;
    }).whenComplete(() {
      if (identical(_durableAdoption, adoption)) {
        _durableAdoption = null;
        final superseded = !identical(library, _incomingLibraryStore) ||
            !identical(downloads, _incomingChapterDownloads) ||
            !identical(composition, _incomingDownloadComposition) ||
            !identical(queue, _incomingWholeComicDownloads) ||
            !identical(cache, _incomingCacheCoordinator);
        // Retry a newer handoff, not the same failed owner in a busy loop.
        // An explicit caller can retry the current generation after failure.
        if (mounted && (succeeded || superseded) &&
            _needsDurableServiceAdoption()) {
          _startDurableServiceAdoption();
        }
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
    if (!_needsDurableServiceAdoption()) {
      return;
    }
    final previousChapterDownloads = _chapterDownloads;
    final previousServiceCache = _serviceCache;
    final downloadComposition = HomeLibrarySession.resolveDownloadComposition(
      chapterDownloads,
      _incomingDownloadComposition,
    );
    final suppliedCache = _incomingCacheCoordinator;
    final candidateServiceCache = HomeServiceCacheBinding.create(
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      suppliedCoordinator: suppliedCache,
    );
    final cacheCoordinator = candidateServiceCache.coordinator;
    final externalPlugins =
        _incomingExternalPlugins ?? _externalSources.activeController;
    final activeExternalSources =
        externalPlugins?.activeSources ?? const <BrowsableComicSource>[];
    final sources = _sourceProjection.composeForServices(
      cacheCoordinator,
      externalSources: activeExternalSources,
    );

    wholeComicDownloads.refreshStaleChapter = _refreshStaleQueueChapter;
    Object? adoptionError;
    StackTrace? adoptionStack;
    try {
      await _librarySession.adoptServices(
        library: library,
        chapterDownloads: chapterDownloads,
        downloadComposition: downloadComposition,
        wholeComicDownloads: wholeComicDownloads,
        sources: sources,
        persistSnapshot: _persistHomeProjectionSnapshot,
      );
    } on Object catch (error, stack) {
      adoptionError = error;
      adoptionStack = stack;
    }
    final sessionAdopted =
        identical(_librarySession.library, library) &&
        identical(_librarySession.chapterDownloads, chapterDownloads) &&
        identical(_librarySession.downloadComposition, downloadComposition) &&
        identical(_librarySession.wholeComicDownloads, wholeComicDownloads);
    if (!sessionAdopted) {
      await candidateServiceCache.closeIfOwned();
      if (adoptionError != null) {
        Error.throwWithStackTrace(adoptionError, adoptionStack!);
      }
      throw StateError('Home service authority was not adopted');
    }
    if (adoptionError != null) {
      // HomeLibrarySession swaps service authority before reconciliation. If a
      // later step throws, keep Home aligned with that already-adopted owner
      // instead of returning to stale parallel bindings.
      debugPrint(
        'durable Home service handoff reconciled after adoption error: '
        '$adoptionError',
      );
    }
    _sourceResources.unbindFrom(previousChapterDownloads);
    _sourceResources.bindTo(_chapterDownloads);
    _serviceCache = candidateServiceCache;
    _scheduleLocalReadBackendPrewarm();
    _syncCachedCarrierTrustMode();
    _sourceProjection.adoptServiceProjection(
      sources,
      cache: cacheCoordinator,
      externalSources: activeExternalSources,
    );
    unawaited(_recoverCommittedSourceMigrations());
    await previousServiceCache.closeIfSupersededBy(candidateServiceCache);
    // Snapshot cover requests may already be waiting for the deferred plugin
    // loader. Release that handoff gate only; each request retains its exact
    // source identity and owns the decision to activate that one runtime.
    if (_externalSources.activeController != null ||
        _externalPluginLoader != null) {
      _externalSources.signalLoaderAvailable();
    }
    if (adoptionError != null) {
      Error.throwWithStackTrace(adoptionError, adoptionStack!);
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
      final startedAtMicros = _traceClock.nowMicros();
      unawaited(
        target.prewarmLocalReadBackend().then<void>((warmed) {
          if (!mounted) return;
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.nowMicros(),
              sessionId: 'home-storage-prewarm',
              kind: TraceEventKind.artifactSource,
              payload: <String, Object?>{
                'stage': 'local-read-backend-prewarm',
                'warmed': warmed,
                'durationMicros':
                    _traceClock.nowMicros() - startedAtMicros,
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
