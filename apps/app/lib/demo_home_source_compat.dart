part of 'demo_home.dart';


Uri _sourceComicWebUri(
  BrowsableComicSource source,
  String comicId,
) {
  final Object candidate = source;
  final ComicWebUriSource? webSource =
      candidate is ComicWebUriSource ? candidate : null;
  return webSource?.resolveComicWebUri(comicId) ?? source.descriptor.website;
}

ComicWebViewRequest _sourceWebViewRequest(
  BrowsableComicSource source,
  Uri url,
) {
  final Object candidate = source;
  final ComicWebViewRequestSource? requestSource =
      candidate is ComicWebViewRequestSource ? candidate : null;
  return requestSource?.webViewRequest(url) ?? ComicWebViewRequest(url: url);
}

bool _hasLegacyVeneraLocators(ImportedChapterRecord chapter) =>
    chapter.pages.any(
      (page) => isLegacyVeneraRuntimeLocator(page.sourceId),
    );

bool chapterRequiresSourceLocatorRefresh(ImportedChapterRecord chapter) =>
    _hasLegacyVeneraLocators(chapter) ||
    chapterHasHomeProjectionSnapshotPagePlaceholders(chapter);

bool _manifestHasLegacyVeneraLocators(ChapterManifest manifest) =>
    manifest.pages.any(
      (page) => isLegacyVeneraRuntimeLocator(page.uri.toString()),
    );

Future<ChapterManifest> _loadCompatibleSourceChapter(
  BrowsableComicSource source,
  String chapterId, {
  bool forceRefresh = false,
  TaskControl? control,
}) async {
  control?.throwIfCancelled();
  final controlledRefreshable =
      source is ControlledRefreshableChapterComicSource
          ? source as ControlledRefreshableChapterComicSource
          : null;
  final RefreshableChapterComicSource? refreshable =
      source is RefreshableChapterComicSource
          ? source as RefreshableChapterComicSource
          : null;
  final controlledChapter = source is ControlledComicSource
      ? source as ControlledComicSource
      : null;
  final refreshedImmediately =
      forceRefresh && (controlledRefreshable != null || refreshable != null);
  var manifest = refreshedImmediately
      ? controlledRefreshable != null
          ? await controlledRefreshable.refreshChapterControlled(
              chapterId,
              control: control,
            )
          : await refreshable!.refreshChapter(chapterId)
      : controlledChapter != null
          ? await controlledChapter.loadChapterControlled(
              chapterId,
              control: control,
            )
          : await source.loadChapter(chapterId);
  control?.throwIfCancelled();
  if (!_manifestHasLegacyVeneraLocators(manifest)) {
    return manifest;
  }
  if ((controlledRefreshable != null || refreshable != null) &&
      !refreshedImmediately) {
    manifest = controlledRefreshable != null
        ? await controlledRefreshable.refreshChapterControlled(
            chapterId,
            control: control,
          )
        : await refreshable!.refreshChapter(chapterId);
    control?.throwIfCancelled();
  }
  if (_manifestHasLegacyVeneraLocators(manifest)) {
    throw StateError(
      'Venera 章节仍返回仅当前运行时有效的资源定位符，请重新加载漫画源',
    );
  }
  return manifest;
}

extension _DemoHomeSourceResourceActions on _DemoHomeState {
  Future<ImportedLibraryEntry> _loadRemoteEntrySnapshot(
    ImportedLibraryEntry entry, {
    bool forceSourceRefresh = false,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (entry.chapter.sourceId == 'local-folder') {
      return entry;
    }
    await _waitForExternalSource(entry.chapter.sourceId);
    final source = _sourceForId(entry.chapter.sourceId);
    if (source == null) {
      throw StateError('漫画源 ${entry.chapter.sourceId} 当前不可用');
    }
    final manifest = await _loadCompatibleSourceChapter(
      source,
      entry.chapter.chapterId,
      forceRefresh: forceSourceRefresh,
      control: control,
    );
    control?.throwIfCancelled();
    final comic = Comic(
      comicId: entry.chapter.comicId,
      sourceId: entry.chapter.sourceId,
      title: entry.chapter.comicTitle,
      authors: entry.chapter.comicAuthors,
      tags: entry.chapter.comicTags,
      coverUri: entry.chapter.coverSourceId == null
          ? null
          : Uri.tryParse(entry.chapter.coverSourceId!),
      description: entry.chapter.comicDescription,
      readingDirection: entry.chapter.readingDirection,
    );
    final refreshed = ImportedChapterRecord.remote(
      comic: comic,
      manifest: manifest,
      importedAt: entry.chapter.importedAt,
    );
    control?.throwIfCancelled();
    return entry.copyWith(chapter: refreshed);
  }

  Future<void> _openSourceWebView(
    BrowsableComicSource source,
    Uri url, {
    bool cloudflareVerification = false,
  }) async {
    await attachAndroidPlugin('network_bridge');
    final request = _sourceWebViewRequest(source, url);
    final effectiveUserAgent = request.userAgent?.trim().isNotEmpty == true
        ? request.userAgent!.trim()
        : widget.preferences.networkUserAgent;
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-browser:${source.sourceId}',
        kind: TraceEventKind.retryScheduled,
        payload: <String, Object?>{
          'stage': 'source-verification-browser-open',
          'host': request.url.host,
          'cloudflareVerification': cloudflareVerification,
          'userAgentLength': effectiveUserAgent.length,
          'userAgentFromSource': request.userAgent?.trim().isNotEmpty == true,
        },
      ),
    );
    await widget.networkBridge.openBrowser(
      request.url,
      userAgent: effectiveUserAgent,
      cloudflareVerification: cloudflareVerification,
    );
    final snapshot = await widget.networkBridge.readBrowserSnapshot(request.url);
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-browser:${source.sourceId}',
        kind: snapshot == null
            ? TraceEventKind.taskFailed
            : TraceEventKind.sourceReady,
        payload: <String, Object?>{
          'stage': 'source-verification-browser-result',
          'host': request.url.host,
          'snapshotPresent': snapshot != null,
          'snapshotHost': snapshot?.currentUrl.host ?? '',
          'cookieNames': snapshot?.cookies.keys.toList(growable: false) ??
              const <String>[],
          'cookieCount': snapshot?.cookies.length ?? 0,
          'cfClearancePresent':
              snapshot?.cookies.containsKey('cf_clearance') ?? false,
          'userAgentLength': snapshot?.userAgent?.length ?? 0,
          'userAgentMatched': snapshot != null &&
              (cloudflareVerification ||
                  snapshot.userAgent == effectiveUserAgent),
        },
      ),
    );
    if (snapshot != null &&
        (source.sourceId.startsWith('mihon:') ||
            source.sourceId.startsWith('venera:'))) {
      // Venera exposes confirmWebLogin on the already-active runtime; replacing
      // that runtime after every browser round-trip is both redundant and can
      // make the source disappear. Mihon browser/Cloudflare handoff keeps its
      // existing restart behavior for now and is intentionally not changed in
      // this iteration.
      if (source.sourceId.startsWith('mihon:')) {
        final controller = _activeExternalPlugins;
        if (controller != null) {
          await controller.restartMihonSourceForBrowserHandoff(source.sourceId);
          await _replaceExternalSources();
        }
      }
      final active = _sourceForId(source.sourceId) ?? source;
      final Object? candidate = active;
      if (candidate is AuthenticatableComicSource) {
        final accountSource = candidate;
        try {
          await accountSource.confirmWebLogin(
            currentUrl: snapshot.currentUrl.toString(),
            title: snapshot.title,
            cookies: snapshot.cookies,
            localStorage: snapshot.localStorage,
          );
        } on Object {
          // Mihon runtimes do not expose account operations; their existing
          // browser/Cloudflare handoff imports the snapshot separately.
        }
      }
    }
  }

  Future<Uint8List> _loadSourcePageBytes(String sourceId, Uri uri) =>
      _sourceResources.loadPageBytes(sourceId, uri);

  Future<Uint8List> _loadChapterPageBytes(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    final pages = entry.chapter.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    final page = pages[pageIndex];
    if (entry.chapter.sourceId != 'local-folder') {
      await _waitForExternalSource(entry.chapter.sourceId);
    }
    final source = _sourceForId(entry.chapter.sourceId);
    final uri = Uri.tryParse(page.sourceId);
    if (source != null && uri != null) {
      return _loadSourcePageBytes(entry.chapter.sourceId, uri);
    }
    if (entry.chapter.sourceId == 'local-folder') {
      return readLocalImageSource(page.sourceId);
    }
    throw StateError('漫画源 ${entry.chapter.sourceId} 当前不可用，无法加载页面 $pageIndex');
  }

  Future<ChapterDownloadSnapshot> _inspectChapterDownload(
    ImportedLibraryEntry entry,
  ) async {
    return _chapterDownloads.inspect(await _librarySession.hydrateEntry(entry));
  }

  Future<Iterable<ChapterDownloadSnapshot>> _inspectChapterDownloads(
    Iterable<ImportedLibraryEntry> entries,
  ) =>
      _chapterDownloads.inspectMany(entries);

  Future<ComicConflictReport> _inspectComicConflictsForDetails({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async {
    // The comparison consumes the unified queries: a live run for this comic
    // short-circuits the dialog (the guard blocks the download anyway), and
    // the report is computed only when no active task covers it.
    final probe = await _chapterDownloads.probeExistingDownloads(
      DownloadExistenceQuery(sourceId: sourceId, comicId: comicId),
    );
    if (probe.liveRun) {
      return const ComicConflictReport(
        candidates: <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName: '',
      );
    }
    return _chapterDownloads.inspectComicConflicts(
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      comicId: comicId,
      comicTitle: comicTitle,
      knownPredecessorComicIds: knownPredecessorComicIds,
      knownSuccessorComicIds: knownSuccessorComicIds,
    );
  }

  details.ComicDetailsDownloadActions get _detailsDownloadActions =>
      details.ComicDetailsDownloadActions(
        downloadChapter: _downloadChapter,
        stopChapter: _stopChapterDownload,
        probeExisting: ({required sourceId, required comicId, chapterId}) =>
            _chapterDownloads.probeExistingDownloads(
          DownloadExistenceQuery(
            sourceId: sourceId,
            comicId: comicId,
            chapterId: chapterId,
          ),
        ),
        wholeComicJob: (sourceId, comicId) async {
          await _wholeComicDownloads.ready;
          return _wholeComicQueueSnapshot.jobs
              .where(
                (job) =>
                    job.sourceId == sourceId && job.comicId == comicId,
              )
              .firstOrNull;
        },
        cachedWholeComicJob: (sourceId, comicId) =>
            _wholeComicQueueSnapshot.jobs
                .where(
                  (job) =>
                      job.sourceId == sourceId && job.comicId == comicId,
                )
                .firstOrNull,
        toggleWholeComicPause: _toggleWholeComicPause,
        inspectComicConflicts: _inspectComicConflictsForDetails,
        claimComicDirectory: ({
          required sourceId,
          required comicId,
          required directoryName,
          comicTitle,
          mode = DownloadPlacementMode.createNew,
          observedOwnerKey,
        }) =>
            _chapterDownloads.claimComicDirectory(
              sourceId: sourceId,
              comicId: comicId,
              directoryName: directoryName,
              comicTitle: comicTitle,
              mode: mode,
              observedOwnerKey: observedOwnerKey,
            ),
        getDownloadPlacement: ({required sourceId, required comicId}) =>
            _chapterDownloads.getDownloadPlacement(
              sourceId: sourceId,
              comicId: comicId,
            ),
        inspectChapter: (entry) => _chapterDownloads.inspect(entry),
        ensureDurableServices: () async {
          await _serviceHandoff?.ensureCoreServices?.call();
          await _adoptDurableServices();
        },
      );

  Future<void> _stopChapterDownload(ImportedLibraryEntry entry) async {
    await _chapterDownloads.cancel(entry);
    await _refreshDownloadSnapshots(_libraryEntries);
  }

  Future<void> _toggleWholeComicPause(
    String sourceId,
    String comicId,
  ) async {
    for (final job in _wholeComicQueueSnapshot.jobs) {
      if (job.sourceId != sourceId || job.comicId != comicId) continue;
      if (job.phase == WholeComicQueuePhase.running) {
        await _wholeComicDownloads.pause(job.jobId);
        return;
      }
      if (job.phase == WholeComicQueuePhase.paused) {
        await _wholeComicDownloads.resume(job.jobId);
        return;
      }
    }
  }

  Future<void> _downloadChapter(ImportedLibraryEntry entry) async {
    await _serviceHandoff?.ensureCoreServices?.call();
    await _adoptDurableServices();
    final hydrated = await _librarySession.hydrateEntry(entry);
    var current = chapterRequiresSourceLocatorRefresh(hydrated.chapter)
        ? await _refreshRemoteEntry(
            hydrated,
            forceSourceRefresh: true,
          )
        : hydrated;
    try {
      // A conflict dialog claims placement synchronously for legacy UI
      // callbacks, but its SQLite commit is asynchronous. Awaiting the
      // readback here closes the claim-to-download race (including a failed
      // cross-process CAS) before any artifact is written.
      await _chapterDownloads.getDownloadPlacement(
        sourceId: current.chapter.sourceId,
        comicId: current.chapter.comicId,
      );
      await _chapterDownloads.download(current);
    } on Object catch (error) {
      // Stale persisted page URIs fail inside the plugin runtime; only
      // message matching crosses that boundary. A bare 'token' substring
      // used to match unrelated failures and silently refresh-redownload.
      final message = error.toString();
      if (message.contains('must use a runtime token') ||
          message.contains('token expired')) {
        final refreshed = await _refreshStaleQueueChapter(current);
        if (refreshed != null) {
          current = refreshed;
          await _chapterDownloads.retry(current);
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    final snapshot = await _chapterDownloads.inspect(current);
    _acceptDownloadSnapshot(snapshot);
    if (snapshot.isComplete) {
      _recordChapterDownloadCompletion(
        current.chapter.sourceId,
        current.chapter.comicId,
      );
    }
  }

  Future<void> _deleteChapter(
    ImportedLibraryEntry entry, {
    bool deleteFiles = false,
  }) async {
    final hydrated = await _librarySession.hydrateEntry(entry);
    if (deleteFiles) {
      await _chapterDownloads.delete(hydrated);
    }
    await _librarySession.removeChapter(
      hydrated.chapter.sourceId,
      hydrated.chapter.chapterId,
    );
  }

  Future<void> _downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    await _serviceHandoff?.ensureCoreServices?.call();
    await _adoptDurableServices();
    final chapters = <ImportedLibraryEntry>[];
    for (final entry in entries) {
      final hydrated = await _librarySession.hydrateEntry(entry);
      chapters.add(
        chapterRequiresSourceLocatorRefresh(hydrated.chapter)
            ? await _refreshRemoteEntry(
                hydrated,
                forceSourceRefresh: true,
              )
            : hydrated,
      );
    }
    if (chapters.isEmpty) {
      throw StateError('没有可下载的章节');
    }
    final first = chapters.first.chapter;
    final existingJob = _wholeComicQueueSnapshot.jobs.where(
      (job) =>
          job.sourceId == first.sourceId && job.comicId == first.comicId,
    ).firstOrNull;
    if (existingJob != null &&
        (existingJob.phase == WholeComicQueuePhase.running ||
            existingJob.phase == WholeComicQueuePhase.queued ||
            existingJob.phase == WholeComicQueuePhase.paused ||
            existingJob.phase == WholeComicQueuePhase.waitingForPolicy)) {
      throw StateError('该漫画的整本下载任务已在队列中');
    }
    if (comicIdentity != comicLibraryIdentity(first.sourceId, first.comicId)) {
      throw StateError('整本下载身份与章节所有者不一致');
    }
    await _ensurePlatformEnvironment();
    final placement = await _chapterDownloads.getDownloadPlacement(
      sourceId: first.sourceId,
      comicId: first.comicId,
    );
    await _wholeComicDownloads.enqueue(
      sourceId: first.sourceId,
      comicId: first.comicId,
      comicTitle: first.comicTitle,
      chapters: chapters,
      placementDirectory: placement?.relativeDirectory,
      placementMode: placement?.mode,
      observedOwnerKey: placement?.observedOwnerKey,
      pageOrder: placement?.pageOrder ?? ComicPageOrder.auto,
    );
    _trackWholeComicDownloadCompletion(first.sourceId, first.comicId);
    _librarySession.refreshWholeComicSnapshot();
  }

  Future<void> _openComicSourceSettings(
    BrowsableComicSource source,
  ) async {
    await openComicSourceSettings(
      context,
      source: source,
      networkBridge: widget.networkBridge,
      onExternalSourcesChanged: _replaceExternalSources,
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

  void _searchSourceMetadata(
    BrowsableComicSource source,
    String query,
  ) {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return;
    }
    Navigator.of(context).pop();
    _setState(() {
      _activeSourceId = source.sourceId;
      _sourcePageVisited = true;
      _sourceSearchQuery = normalized;
      _sourceSearchRevision++;
      _navigationIndex = 2;
    });
  }


  Future<void> _openSourceComic(
    BrowsableComicSource source,
    SourceComicSummary comic, {
    bool resolveCanonicalAlias = true,
    String? openingIdentity,
  }) async {
    final identity = openingIdentity ??
        comicLibraryIdentity(source.sourceId, comic.comicId);
    if (!_openingComicIdentities.add(identity)) return;
    _clearDownloadCompletionBadge(source.sourceId, comic.comicId);
    final shouldResolveCanonicalAlias = resolveCanonicalAlias &&
        !_sourceSupportsVersionEntry(source);
    final local = shouldResolveCanonicalAlias
        ? _libraryComicForSourceIdentity(source.sourceId, comic.comicId)
        : _exactLibraryComicForSourceIdentity(
            source.sourceId,
            comic.comicId,
          );
    try {
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'source-catalog:${source.sourceId}',
          kind: TraceEventKind.sourceReady,
          identityHash: comic.comicId,
          payload: <String, Object?>{
            'stage': 'open-source-comic-entry',
            'sourceId': source.sourceId,
            'requestedComicId': comic.comicId,
            'comicTitle': comic.title,
            'resolveCanonicalAlias': resolveCanonicalAlias,
            'supportsVersionEntry': _sourceSupportsVersionEntry(source),
            'shouldResolveCanonicalAlias': shouldResolveCanonicalAlias,
            'localMatched': local != null,
            'localComicId': local?.comicId,
          },
        ),
      );
    } on Object {}
    if (local != null) {
      if (local.comicId != comic.comicId) {
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
            sessionId: 'source-catalog:${source.sourceId}',
            kind: TraceEventKind.sourceReady,
            identityHash: _comicIdentityTraceHash(
              source.sourceId,
              comic.comicId,
              canonical: _canonicalComicKey(
                source.sourceId,
                comic.comicId,
              ),
            ),
            payload: <String, Object?>{
              'stage': 'comic-identity-alias-resolved',
              'requestedIdLength': comic.comicId.length,
              'selectedIdLength': local.comicId.length,
              'selectedChapterCount': local.sourceChapters.length,
              'aliasCount': _canonicalComicAliases(
                source.sourceId,
                comic.comicId,
              ).length,
            },
          ),
        );
      }
      try {
        // The outer source route already owns this identity. Re-entering
        // _openComicDetails would acquire the same lock a second time and
        // silently drop every subsequent open after the comic was persisted.
        await _pushComicDetails(local);
      } finally {
        _openingComicIdentities.remove(identity);
      }
      return;
    }
    final preference = _mergedPreferenceFor(
      source.sourceId,
      comic.comicId,
      fallbackPreference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: comic.comicId,
        sourceKind: ComicSourceKind.remote,
        customOrder: _nextCustomOrder,
      ).copyWith(inShelf: false),
      fallbackSourceKind: ComicSourceKind.remote,
      fallbackInShelf: false,
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SourceComicDetailsScreen(
            initialLibrary: _detailsSnapshotForComic(
              source.sourceId,
              comic.comicId,
              preference: preference,
              resolveCanonicalAlias: resolveCanonicalAlias,
            ),
            source: source,
            resolveSource: _sourceForId,
            summary: comic,
            categories: _categories,
            loadCover: _loadCoverSource,
            reloadLibrary: ({required bool refreshContent}) =>
                _reloadDetailsSnapshot(
              source.sourceId,
              comic.comicId,
              refreshContent: refreshContent,
              fallbackPreference: preference,
              resolveCanonicalAlias: resolveCanonicalAlias,
            ),
            ensureSourceChapter: _ensureSourceChapter,
            downloadActions: _detailsDownloadActions,
            persistComic: _persistRemoteComic,
            onPreferenceChanged: _savePreference,
            onReadChanged: _setChapterRead,
            onOpenChapter: (
              loadChapter, {
              required bool refreshRemote,
              required String title,
              int? initialPageIndex,
            }) =>
                _openImportedChapterLoader(
              loadChapter,
              title: title,
              refreshRemote: refreshRemote,
              initialPageIndex: initialPageIndex,
            ),
            onDownloadChapter: _downloadChapter,
            onDeleteChapter: _deleteChapter,
            inspectChapterDownload: _inspectChapterDownload,
            inspectChapterDownloads: _inspectChapterDownloads,
            inspectComicConflicts: _inspectComicConflictsForDetails,
            downloadChanges: _chapterDownloads.changes,
            onDownloadComic: (entries) =>
                _downloadComicEntries(identity, entries),
            artworkIdentity: _canonicalComicKey(
              source.sourceId,
              comic.comicId,
            ),
            onOpenSourceWebView: ({Uri? verificationUri}) {
              final active = _sourceForId(source.sourceId) ?? source;
              return _openSourceWebView(
                active,
                verificationUri ?? _sourceComicWebUri(active, comic.comicId),
                cloudflareVerification: true,
              );
            },
            onOpenSourceSettings: sourceSupportsSettings(source)
                ? () {
                    final active = _sourceForId(source.sourceId) ?? source;
                    return _openComicSourceSettings(active);
                  }
                : null,
            onSearchMetadata: (query) {
              final active = _sourceForId(source.sourceId) ?? source;
              _searchSourceMetadata(active, query);
            },
            onMigrateSource: () {
              final active = _sourceForId(source.sourceId) ?? source;
              return _openSourceMigrationForSummary(active, comic);
            },
            loadVersionState: _sourceSupportsVersionEntry(source)
                ? () {
                    final active = _sourceForId(source.sourceId) ?? source;
                    return _loadSourceVersionState(
                      active,
                      comic.title,
                      comic.comicId,
                    );
                  }
                : null,
            onViewVersion: _sourceSupportsVersionEntry(source)
                ? (version) {
                    final active = _sourceForId(source.sourceId) ?? source;
                    return _viewSourceVersion(
                      active,
                      comic.comicId,
                      version,
                    );
                  }
                : null,
            onMigrateVersion: _sourceSupportsVersionEntry(source)
                ? (version) async {
                    final active = _sourceForId(source.sourceId) ?? source;
                    final materialized = await _materializeSourceComic(
                      active,
                      comic,
                      resolveCanonicalAlias: false,
                    );
                    await _migrateSourceVersion(materialized, version);
                  }
                : null,
            sameComicIdentity: resolveCanonicalAlias
                ? (left, right) =>
                    _canonicalComicKey(source.sourceId, left) ==
                    _canonicalComicKey(source.sourceId, right)
                : (left, right) => left == right,
            previewMaxItemsPerRow:
                widget.preferences.detailsPreviewMaxItemsPerRow,
            traceSink: widget.debugTrace,
          ),
        ),
      );
    } finally {
      _openingComicIdentities.remove(identity);
    }
  }


  Future<void> _pushComicDetails(LibraryComic comic) async {
    _clearDownloadCompletionBadge(comic.sourceId, comic.comicId);
    final routeStartedAtMicros = _traceClock.elapsedMicroseconds;
    final initialSource = _sourceForId(comic.sourceId);
    final shouldActivateSource = initialSource == null &&
        _isDeferredExternalSourceId(comic.sourceId);
    final sourceReadyCompleter = shouldActivateSource
        ? Completer<BrowsableComicSource?>()
        : null;
    final sourceReady = sourceReadyCompleter?.future ??
        Future<BrowsableComicSource?>.value(initialSource);
    final initialLibrary = _detailsSnapshotForComic(
      comic.sourceId,
      comic.comicId,
    );
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: routeStartedAtMicros,
        sessionId: 'comic-details-entry',
        kind: TraceEventKind.readerObservation,
        payload: <String, Object?>{
          'stage': 'route-push',
          'sourceId': comic.sourceId,
          'sourceReady': initialSource != null,
          'sourceActivationDeferred': shouldActivateSource,
        },
      ),
    );
    var routeActive = true;
    final route = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FutureBuilder<BrowsableComicSource?>(
          future: sourceReady,
          initialData: initialSource,
          builder: (_, sourceSnapshot) {
            final resolvedSource = sourceSnapshot.data ??
                _sourceForId(comic.sourceId);
            return details.LocalComicDetailsScreen(
              key: ValueKey<String>(
                'local-comic-details:${comic.sourceId}:${comic.comicId}',
              ),
              comic: comic,
              initialLibrary: initialLibrary,
              categories: _categories,
              loadCover: _loadCoverSource,
              reloadLibrary: ({required bool refreshContent}) =>
                  _reloadDetailsSnapshot(
                comic.sourceId,
                comic.comicId,
                refreshContent: refreshContent,
              ),
              source: resolvedSource,
              resolveSource: _sourceForId,
              ensureSourceChapter: _ensureSourceChapter,
              downloadActions: _detailsDownloadActions,
              onPreferenceChanged: (preference) async {
                await _savePreference(preference);
                final retained = preference.inShelf ||
                    preference.liked ||
                    preference.collected ||
                    preference.categoryIds.isNotEmpty ||
                    _libraryEntries.any(
                      (entry) =>
                          entry.chapter.sourceId == comic.sourceId &&
                          entry.chapter.comicId == comic.comicId,
                    );
                if (!retained) {
                  await _librarySession.removeSavedComic(
                    comic.sourceId,
                    comic.comicId,
                  );
                }
              },
              onReadChanged: _setChapterRead,
              onOpenChapter: (
                loadChapter, {
                required bool refreshRemote,
                required String title,
                int? initialPageIndex,
              }) =>
                  _openImportedChapterLoader(
                loadChapter,
                title: title,
                refreshRemote: refreshRemote,
                initialPageIndex: initialPageIndex,
              ),
              onDownloadChapter: _downloadChapter,
              onDeleteChapter: _deleteChapter,
              inspectChapterDownload: _inspectChapterDownload,
              inspectChapterDownloads: _inspectChapterDownloads,
              inspectComicConflicts: _inspectComicConflictsForDetails,
              downloadChanges: _chapterDownloads.changes,
              onDownloadComic: (entries) => _downloadComicEntries(
                comicLibraryIdentity(comic.sourceId, comic.comicId),
                entries,
              ),
              onOpenSourceWebView: resolvedSource == null
                  ? null
                  : ({Uri? verificationUri}) {
                      final active = _sourceForId(resolvedSource.sourceId) ??
                          resolvedSource;
                      return _openSourceWebView(
                        active,
                        verificationUri ??
                            _sourceComicWebUri(active, comic.comicId),
                        cloudflareVerification: true,
                      );
                    },
              onOpenSourceSettings: resolvedSource != null &&
                      sourceSupportsSettings(resolvedSource)
                  ? () => _openComicSourceSettings(resolvedSource)
                  : null,
              onSearchMetadata: resolvedSource == null
                  ? null
                  : (query) => _searchSourceMetadata(resolvedSource, query),
              onMigrateSource: resolvedSource == null ||
                      comic.sourceId == 'local-folder'
                  ? null
                  : () => _openSourceMigration(comic),
              loadVersionState: resolvedSource == null ||
                      !_sourceSupportsVersionEntry(resolvedSource)
                  ? null
                  : () {
                      final active =
                          _sourceForId(resolvedSource.sourceId) ?? resolvedSource;
                      return _loadSourceVersionState(
                        active,
                        comic.title,
                        comic.comicId,
                      );
                    },
              onViewVersion: resolvedSource == null ||
                      !_sourceSupportsVersionEntry(resolvedSource)
                  ? null
                  : (version) {
                      final active =
                          _sourceForId(resolvedSource.sourceId) ?? resolvedSource;
                      return _viewSourceVersion(
                        active,
                        comic.comicId,
                        version,
                      );
                    },
              onMigrateVersion: resolvedSource == null ||
                      !_sourceSupportsVersionEntry(resolvedSource)
                  ? null
                  : (version) => _migrateSourceVersion(comic, version),
              previewMaxItemsPerRow:
                  widget.preferences.detailsPreviewMaxItemsPerRow,
              traceSink: widget.debugTrace,
              traceMonotonicMicros: () => _traceClock.elapsedMicroseconds,
            );
          },
        ),
      ),
    );
    final sourceCompleter = sourceReadyCompleter;
    if (sourceCompleter != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !routeActive || sourceCompleter.isCompleted) {
          if (!sourceCompleter.isCompleted) sourceCompleter.complete(null);
          return;
        }
        unawaited(
          Future<void>(() async {
            try {
              await _waitForExternalSource(comic.sourceId);
              if (!mounted || !routeActive) {
                if (!sourceCompleter.isCompleted) sourceCompleter.complete(null);
                return;
              }
              final source = _sourceForId(comic.sourceId);
              widget.debugTrace.record(
                TraceEvent(
                  monotonicMicros: _traceClock.elapsedMicroseconds,
                  sessionId: 'comic-details-entry',
                  kind: TraceEventKind.sourceReady,
                  payload: <String, Object?>{
                    'stage': 'deferred-source-ready',
                    'sourceId': comic.sourceId,
                    'available': source != null,
                    'durationMicros':
                        _traceClock.elapsedMicroseconds - routeStartedAtMicros,
                  },
                ),
              );
              if (!sourceCompleter.isCompleted) sourceCompleter.complete(source);
            } on Object catch (error) {
              if (mounted) {
                try {
                  widget.debugTrace.record(
                    TraceEvent(
                      monotonicMicros: _traceClock.elapsedMicroseconds,
                      sessionId: 'comic-details-entry',
                      kind: TraceEventKind.taskFailed,
                      payload: <String, Object?>{
                        'stage': 'deferred-source-failed',
                        'sourceId': comic.sourceId,
                        'errorType': error.runtimeType.toString(),
                      },
                    ),
                  );
                } on Object {
                  // Diagnostics must never affect source activation.
                }
              }
              if (!sourceCompleter.isCompleted) sourceCompleter.complete(null);
            }
          }),
        );
      });
    }
    await route;
    routeActive = false;
    if (sourceCompleter != null && !sourceCompleter.isCompleted) {
      sourceCompleter.complete(null);
    }
  }

  Future<void> _openDownloadManager() async {
    if (_downloadManagerRouteOpen) {
      return;
    }
    _downloadManagerRouteOpen = true;
    try {
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'download-manager',
          kind: TraceEventKind.downloadState,
          payload: const <String, Object?>{
            'stage': 'route-open-start',
          },
        ),
      );
    } on Object {
      // Diagnostics must never affect navigation.
    }
    DownloadManagerProjection readProjection() => DownloadManagerProjection(
          entries: _librarySession.downloadManagerEntries,
          snapshots: List<ChapterDownloadSnapshot>.unmodifiable(
            _downloadSnapshots.values,
          ),
          wholeComicSnapshot: _wholeComicQueueSnapshot,
          cacheProjection: _librarySession.downloadCacheProjection,
          versionBaselines: _librarySession.versionBaselines,
        );
    final initialProjection = readProjection();
    try {
      widget.debugTrace.record(
        TraceEvent(
          monotonicMicros: _traceClock.elapsedMicroseconds,
          sessionId: 'download-manager',
          kind: TraceEventKind.downloadState,
          payload: <String, Object?>{
            'stage': 'route-open-projection-ready',
            'entries': initialProjection.entries.length,
            'snapshots': initialProjection.snapshots.length,
            'wholeComicJobs': initialProjection.wholeComicSnapshot.jobs.length,
          },
        ),
      );
    } on Object {
      // Diagnostics must never affect navigation.
    }
    final route = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadManagerScreen(
          entries: initialProjection.entries,
          downloads: _chapterDownloads,
          wholeComicDownloads: _wholeComicDownloads,
          initialSnapshots: initialProjection.snapshots,
          initialWholeComicSnapshot: initialProjection.wholeComicSnapshot,
          initialCacheProjection: initialProjection.cacheProjection,
          versionBaselines: initialProjection.versionBaselines,
          cacheCoordinator: _cacheCoordinator,
          hydrateEntry: _librarySession.hydrateEntry,
          projectionChanges: _librarySession.downloadProjectionChanges,
          readProjection: readProjection,
          refreshProjection: () =>
              _librarySession.refreshDownloadSnapshots(_libraryEntries),
          resolveServices: () async {
            await _serviceHandoff?.ensureCoreServices?.call();
            await _adoptDurableServices();
            return DownloadManagerServices(
              downloads: _chapterDownloads,
              wholeComicDownloads: _wholeComicDownloads,
              cacheCoordinator: _cacheCoordinator,
            );
          },
          traceSink: widget.debugTrace,
        ),
      ),
    );
    unawaited(
      route.then((_) {
        _downloadManagerRouteOpen = false;
        try {
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.elapsedMicroseconds,
              sessionId: 'download-manager',
              kind: TraceEventKind.downloadState,
              payload: const <String, Object?>{
                'stage': 'route-closed',
              },
            ),
          );
        } on Object {
          // Diagnostics must never affect navigation.
        }
      }),
    );
  }

  Future<void> _openShelfComicDirectly(LibraryComic comic) async {
    final isMultiChapter =
        comic.hasMultipleChapters || comic.sourceChapters.length > 1;
    final resume = comic.resumeChapter;
    final targetChapter = resume ??
        (comic.chapters.length == 1 && comic.chapters.single.chapter.pages.isNotEmpty
            ? comic.chapters.single
            : null);
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: <String, Object?>{
          'stage': 'shelf-comic-tap',
          'sourceId': comic.sourceId,
          'comicId': comic.comicId,
          'title': comic.title,
          'isMultiChapter': isMultiChapter,
          'hasResume': resume != null,
          'resumeChapterId': resume?.chapter.chapterId,
          'chaptersCount': comic.chapters.length,
          'sourceChaptersCount': comic.sourceChapters.length,
          'routeChoice': isMultiChapter
              ? 'multi-chapter-details'
              : (targetChapter != null
                  ? (resume != null ? 'resume-local' : 'single-chapter-local')
                  : 'single-chapter-remote'),
        },
      ),
    );
    if (isMultiChapter) {
      await _pushComicDetails(comic);
      return;
    }
    if (targetChapter != null) {
      await _openImportedChapter(targetChapter);
      return;
    }
    if (comic.sourceChapters.length == 1) {
      if (comic.sourceId != 'local-folder') {
        await _waitForExternalSource(comic.sourceId);
      }
      final source = _sourceForId(comic.sourceId);
      if (source != null) {
        final chapter = comic.sourceChapters.single;
        await _openImportedChapterLoader(
          () async {
            final manifest = await _loadCompatibleSourceChapter(
              source,
              chapter.chapterId,
            );
            final comicModel = Comic(
              comicId: comic.comicId,
              sourceId: comic.sourceId,
              title: comic.title,
              authors: comic.authors,
              tags: comic.tags,
              coverUri: comic.coverSourceId == null
                  ? null
                  : Uri.tryParse(comic.coverSourceId!),
              description: comic.description,
              readingDirection: comic.readingDirection,
            );
            final imported = ImportedChapterRecord.remote(
              comic: comicModel,
              manifest: manifest,
              importedAt: DateTime.now().toUtc(),
            );
            return _librarySession.upsertChapter(imported);
          },
          title: chapter.title.isEmpty
              ? comic.title
              : chapter.title,
        );
        return;
      }
    }
    await _pushComicDetails(comic);
  }
}
