part of 'demo_home.dart';

bool _isLegacyVeneraLocator(String value) =>
    value.startsWith('venera-resource://');

bool _hasLegacyVeneraLocators(ImportedChapterRecord chapter) =>
    chapter.pages.any(
      (page) => _isLegacyVeneraLocator(page.sourceId),
    );

bool _manifestHasLegacyVeneraLocators(ChapterManifest manifest) =>
    manifest.pages.any(
      (page) => _isLegacyVeneraLocator(page.uri.toString()),
    );

Future<Uint8List> _loadCompatibleSourceResource(
  _DemoHomeState state,
  String sourceId,
  Uri uri,
) {
  if (_isLegacyVeneraLocator(uri.toString())) {
    throw StateError('已阻止读取失效的 Venera 运行时资源定位符：$uri');
  }
  final source = state._sourceForId(sourceId);
  if (source == null) {
    throw StateError('漫画源 $sourceId 当前不可用，无法加载 $uri');
  }
  return source.loadResource(uri);
}

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

Future<void> _downloadCompatibleChapter(
  _DemoHomeState state,
  ImportedLibraryEntry entry,
) async {
  final current = _hasLegacyVeneraLocators(entry.chapter)
      ? await state._refreshRemoteEntry(
          entry,
          forceSourceRefresh: true,
        )
      : entry;
  await state._chapterDownloads.download(current);
  state._acceptDownloadSnapshot(
    await state._chapterDownloads.inspect(current),
  );
}

Future<void> _downloadCompatibleComicEntries(
  _DemoHomeState state,
  String comicIdentity,
  Iterable<ImportedLibraryEntry> entries,
) async {
  final chapters = <ImportedLibraryEntry>[];
  for (final entry in entries) {
    chapters.add(
      _hasLegacyVeneraLocators(entry.chapter)
          ? await state._refreshRemoteEntry(
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
  await state._wholeComicDownloads.enqueue(
    sourceId: first.sourceId,
    comicId: first.comicId,
    comicTitle: first.comicTitle,
    chapters: chapters,
  );
  state._librarySession.refreshWholeComicSnapshot();
}
