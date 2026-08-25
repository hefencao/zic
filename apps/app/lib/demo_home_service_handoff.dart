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
    if (plugins != null && !identical(_activeExternalPlugins, plugins)) {
      _activeExternalPlugins = plugins;
      _watchExternalPluginSources(plugins);
      unawaited(_ensureExternalSourcesPublished());
    } else if (plugins == null && _externalPluginLoader != null) {
      // The loader may arrive without a core-service adoption on an install
      // whose only durable state is the external-plugin manifest.
      unawaited(_ensureExternalSourcesPublished());
    }
  }

  Future<void> _adoptDurableServices() async {
    final library = _incomingLibraryStore;
    final chapterDownloads = _incomingChapterDownloads;
    final wholeComicDownloads = _incomingWholeComicDownloads;
    if (library == null ||
        chapterDownloads == null ||
        wholeComicDownloads == null ||
        identical(library, _library)) {
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
    _activeExternalPlugins = _incomingExternalPlugins;
    final sources = _buildCachedSources(
      cacheCoordinator,
      externalPlugins: _activeExternalPlugins,
    );

    _sourceResources.unbindFrom(previousChapterDownloads);
    _sourceResources.bindTo(chapterDownloads);
    _library = library;
    _chapterDownloads = chapterDownloads;
    _downloadComposition = downloadComposition;
    _readerArtifactCache = readerArtifactCache;
    _wholeComicDownloads = wholeComicDownloads;
    _cacheCoordinator = cacheCoordinator;
    _ownsCacheCoordinator = suppliedCache == null;
    _sources = sources;
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
      return;
    }
    if (previousOwnsCacheCoordinator &&
        !identical(previousCacheCoordinator, _cacheCoordinator) &&
        !identical(
          previousCacheCoordinator.responses,
          _cacheCoordinator.responses,
        )) {
      await previousCacheCoordinator.close();
    }
    // Snapshot covers can be built before the deferred plugin host exists.
    // Start the host after the durable service handoff so those failed cover
    // widgets observe sourceAvailable=true and retry automatically.
    unawaited(_ensureExternalSourcesPublished());
  }
}
