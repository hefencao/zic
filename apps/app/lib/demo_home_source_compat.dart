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
    Uri url,
  ) async {
    final request = _sourceWebViewRequest(source, url);
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-browser:${source.sourceId}',
        kind: TraceEventKind.retryScheduled,
        payload: <String, Object?>{
          'stage': 'source-verification-browser-open',
          'host': request.url.host,
          'userAgentLength': request.userAgent?.length ?? 0,
        },
      ),
    );
    await widget.networkBridge.openBrowser(
      request.url,
      userAgent: request.userAgent,
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
              (request.userAgent == null ||
                  snapshot.userAgent == request.userAgent),
        },
      ),
    );
  }

  Future<Uint8List> _loadSourceResourceBytes(String sourceId, Uri uri) =>
      _sourceResources.loadBytes(sourceId, uri);

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
      return _loadSourceResourceBytes(entry.chapter.sourceId, uri);
    }
    return readLocalImageSource(page.sourceId);
  }

  Future<void> _downloadChapter(ImportedLibraryEntry entry) async {
    final current = _hasLegacyVeneraLocators(entry.chapter)
        ? await _refreshRemoteEntry(
            entry,
            forceSourceRefresh: true,
          )
        : entry;
    await _chapterDownloads.download(current);
    _acceptDownloadSnapshot(await _chapterDownloads.inspect(current));
  }

  Future<void> _downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final chapters = <ImportedLibraryEntry>[];
    for (final entry in entries) {
      chapters.add(
        _hasLegacyVeneraLocators(entry.chapter)
            ? await _refreshRemoteEntry(
                entry,
                forceSourceRefresh: true,
              )
            : entry,
      );
    }
    if (chapters.isEmpty) {
      throw StateError('没有可下载的章节');
    }
    final first = chapters.first.chapter;
    if (comicIdentity != comicLibraryIdentity(first.sourceId, first.comicId)) {
      throw StateError('整本下载身份与章节所有者不一致');
    }
    await _wholeComicDownloads.enqueue(
      sourceId: first.sourceId,
      comicId: first.comicId,
      comicTitle: first.comicTitle,
      chapters: chapters,
    );
    _librarySession.refreshWholeComicSnapshot();
  }

  Future<void> _openComicSourceSettings(
    BrowsableComicSource source,
  ) async {
    await openComicSourceSettings(
      context,
      source: source,
      networkBridge: widget.networkBridge,
      externalPlugins: widget.externalPlugins,
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
    setState(() {
      _activeSourceId = source.sourceId;
      _sourcePageVisited = true;
      _sourceSearchQuery = normalized;
      _sourceSearchRevision++;
      _navigationIndex = 2;
    });
  }


  Future<void> _openSourceComic(
    BrowsableComicSource source,
    SourceComicSummary comic,
  ) async {
    final local = _libraryComicForSourceIdentity(
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
      await _openComicDetails(local);
      return;
    }
    final identity = comicLibraryIdentity(source.sourceId, comic.comicId);
    if (!_openingComicIdentities.add(identity)) {
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
            ),
            source: source,
            summary: comic,
            categories: _categories,
            loadCover: _loadCoverSource,
            reloadLibrary: ({required bool refreshContent}) =>
                _reloadDetailsSnapshot(
              source.sourceId,
              comic.comicId,
              refreshContent: refreshContent,
              fallbackPreference: preference,
            ),
            ensureSourceChapter: _ensureSourceChapter,
            persistComic: _persistRemoteComic,
            onPreferenceChanged: _savePreference,
            onReadChanged: _setChapterRead,
            onOpenChapter: (
              loadChapter, {
              required bool refreshRemote,
              required String title,
            }) =>
                _openImportedChapterLoader(
              loadChapter,
              title: title,
              refreshRemote: refreshRemote,
            ),
            onDownloadChapter: _downloadChapter,
            inspectChapterDownload: _chapterDownloads.inspect,
            downloadChanges: _chapterDownloads.changes,
            onDownloadComic: (entries) =>
                _downloadComicEntries(identity, entries),
            onOpenSourceWebView: () => _openSourceWebView(
                  source,
                  _sourceComicWebUri(source, comic.comicId),
                ),
            onOpenSourceSettings: sourceSupportsSettings(source)
                ? () => _openComicSourceSettings(source)
                : null,
            onSearchMetadata: (query) =>
                _searchSourceMetadata(source, query),
            sameComicIdentity: (left, right) =>
                _canonicalComicKey(source.sourceId, left) ==
                _canonicalComicKey(source.sourceId, right),
            traceSink: widget.debugTrace,
          ),
        ),
      );
      if (mounted) {
        await _reloadLibrary();
      }
    } finally {
      _openingComicIdentities.remove(identity);
    }
  }


  Future<void> _pushComicDetails(LibraryComic comic) async {
    final source = _sourceForId(comic.sourceId);
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
              await _library.removeSavedComic(comic.sourceId, comic.comicId);
            }
          },
          onReadChanged: _setChapterRead,
          onOpenChapter: (
            loadChapter, {
            required bool refreshRemote,
            required String title,
          }) =>
              _openImportedChapterLoader(
            loadChapter,
            title: title,
            refreshRemote: refreshRemote,
          ),
          onDownloadChapter: _downloadChapter,
          inspectChapterDownload: _chapterDownloads.inspect,
          downloadChanges: _chapterDownloads.changes,
          onDownloadComic: (entries) => _downloadComicEntries(
            comicLibraryIdentity(comic.sourceId, comic.comicId),
            entries,
          ),
          onOpenSourceWebView: source == null
              ? null
              : () => _openSourceWebView(
                    source,
                    _sourceComicWebUri(source, comic.comicId),
                  ),
          onOpenSourceSettings:
              source != null && sourceSupportsSettings(source)
                  ? () => _openComicSourceSettings(source)
                  : null,
          onSearchMetadata: source == null
              ? null
              : (query) => _searchSourceMetadata(source, query),
          traceSink: widget.debugTrace,
          onMigrateSource: comic.sourceId == 'local-folder'
              ? null
              : _openSourceMigration,
        ),
      ),
    );
    if (mounted) {
      await _reloadLibrary();
    }
  }

}
