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

bool _manifestHasLegacyVeneraLocators(ChapterManifest manifest) =>
    manifest.pages.any(
      (page) => isLegacyVeneraRuntimeLocator(page.uri.toString()),
    );

Future<ChapterManifest> _loadCompatibleSourceChapter(
  BrowsableComicSource source,
  String chapterId, {
  bool forceRefresh = false,
}) async {
  final RefreshableChapterComicSource? refreshable =
      source is RefreshableChapterComicSource
          ? source as RefreshableChapterComicSource
          : null;
  final refreshedImmediately = forceRefresh && refreshable != null;
  var manifest = refreshedImmediately
      ? await refreshable.refreshChapter(chapterId)
      : await source.loadChapter(chapterId);
  if (!_manifestHasLegacyVeneraLocators(manifest)) {
    return manifest;
  }
  if (refreshable != null && !refreshedImmediately) {
    manifest = await refreshable.refreshChapter(chapterId);
  }
  if (_manifestHasLegacyVeneraLocators(manifest)) {
    throw StateError(
      'Venera 章节仍返回仅当前运行时有效的资源定位符，请重新加载漫画源',
    );
  }
  return manifest;
}

extension _DemoHomeSourceResourceActions on _DemoHomeState {
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
  ) {
    final pages = entry.chapter.pages;
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    final page = pages[pageIndex];
    final source = _sourceForId(entry.chapter.sourceId);
    final uri = Uri.tryParse(page.sourceId);
    if (source != null && uri != null) {
      return _loadSourcePageBytes(entry.chapter.sourceId, uri);
    }
    return readLocalImageSource(page.sourceId);
  }

  Future<ChapterDownloadSnapshot> _inspectChapterDownload(
    ImportedLibraryEntry entry,
  ) async {
    return _chapterDownloads.inspect(await _librarySession.hydrateEntry(entry));
  }

  Future<Iterable<ChapterDownloadSnapshot>> _inspectChapterDownloads(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final hydrated = await Future.wait<ImportedLibraryEntry>(
      entries.map(_librarySession.hydrateEntry),
    );
    return _chapterDownloads.inspectMany(hydrated);
  }

  Future<void> _downloadChapter(ImportedLibraryEntry entry) async {
    final hydrated = await _librarySession.hydrateEntry(entry);
    final current = _hasLegacyVeneraLocators(hydrated.chapter)
        ? await _refreshRemoteEntry(
            hydrated,
            forceSourceRefresh: true,
          )
        : hydrated;
    await _chapterDownloads.download(current);
    final snapshot = await _chapterDownloads.inspect(current);
    _acceptDownloadSnapshot(snapshot);
    if (snapshot.isComplete) {
      _recordChapterDownloadCompletion(
        current.chapter.sourceId,
        current.chapter.comicId,
      );
    }
  }

  Future<void> _deleteChapter(ImportedLibraryEntry entry) async {
    // Detail routes may start from a compact Home snapshot. Deletion needs the
    // authoritative page list so ChapterDownloadService can evict every page
    // artifact instead of only removing the library row.
    final hydrated = await _librarySession.hydrateEntry(entry);
    await _chapterDownloads.delete(hydrated);
    await _librarySession.removeChapter(
      hydrated.chapter.sourceId,
      hydrated.chapter.chapterId,
    );
  }

  Future<void> _downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final chapters = <ImportedLibraryEntry>[];
    for (final entry in entries) {
      final hydrated = await _librarySession.hydrateEntry(entry);
      chapters.add(
        _hasLegacyVeneraLocators(hydrated.chapter)
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
    if (comicIdentity != comicLibraryIdentity(first.sourceId, first.comicId)) {
      throw StateError('整本下载身份与章节所有者不一致');
    }
    await _ensurePlatformEnvironment();
    await _wholeComicDownloads.enqueue(
      sourceId: first.sourceId,
      comicId: first.comicId,
      comicTitle: first.comicTitle,
      chapters: chapters,
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
    if (_sourceSupportsVersionEntry(source)) {
      _scheduleVersionReuseWarmup(
        source,
        comic.comicId,
        deferUntilAfterFrame: true,
      );
    }
    final local = resolveCanonicalAlias
        ? _libraryComicForSourceIdentity(source.sourceId, comic.comicId)
        : _exactLibraryComicForSourceIdentity(
            source.sourceId,
            comic.comicId,
          );
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
    final source = _sourceForId(comic.sourceId);
    if (source != null && _sourceSupportsVersionEntry(source)) {
      _scheduleVersionReuseWarmup(
        source,
        comic.comicId,
        deferUntilAfterFrame: true,
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => details.LocalComicDetailsScreen(
          comic: comic,
          initialLibrary: _detailsSnapshotForComic(
            comic.sourceId,
            comic.comicId,
          ),
          categories: _categories,
          loadCover: _loadCoverSource,
          reloadLibrary: ({required bool refreshContent}) =>
              _reloadDetailsSnapshot(
            comic.sourceId,
            comic.comicId,
            refreshContent: refreshContent,
          ),
          source: source,
          ensureSourceChapter: source == null ? null : _ensureSourceChapter,
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
          downloadChanges: _chapterDownloads.changes,
          onDownloadComic: (entries) => _downloadComicEntries(
            comicLibraryIdentity(comic.sourceId, comic.comicId),
            entries,
          ),
          onOpenSourceWebView: source == null
              ? null
              : ({Uri? verificationUri}) {
                  final active = _sourceForId(source.sourceId) ?? source;
                  return _openSourceWebView(
                    active,
                    verificationUri ?? _sourceComicWebUri(active, comic.comicId),
                    cloudflareVerification: true,
                  );
                },
          onOpenSourceSettings:
              source != null && sourceSupportsSettings(source)
                  ? () => _openComicSourceSettings(source)
                  : null,
          onSearchMetadata: source == null
              ? null
              : (query) => _searchSourceMetadata(source, query),
          onMigrateSource: source == null || comic.sourceId == 'local-folder'
              ? null
              : () => _openSourceMigration(comic),
          loadVersionState: source == null ||
                  !_sourceSupportsVersionEntry(source)
              ? null
              : () {
                  final active = _sourceForId(source.sourceId) ?? source;
                  return _loadSourceVersionState(
                    active,
                    comic.title,
                    comic.comicId,
                  );
                },
          onViewVersion: source == null ||
                  !_sourceSupportsVersionEntry(source)
              ? null
              : (version) {
                  final active = _sourceForId(source.sourceId) ?? source;
                  return _viewSourceVersion(active, comic.comicId, version);
                },
          onMigrateVersion: source == null ||
                  !_sourceSupportsVersionEntry(source)
              ? null
              : (version) => _migrateSourceVersion(comic, version),
          previewMaxItemsPerRow:
              widget.preferences.detailsPreviewMaxItemsPerRow,
          traceSink: widget.debugTrace,
        ),
      ),
    );
  }

}
