part of 'demo_home.dart';


Uri _sourceComicWebUri(
  BrowsableComicSource source,
  SourceComicSummary comic,
) {
  if (source is ComicWebUriSource) {
    return (source as ComicWebUriSource).resolveComicWebUri(comic.comicId) ??
        source.descriptor.website;
  }
  return source.descriptor.website;
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
}
