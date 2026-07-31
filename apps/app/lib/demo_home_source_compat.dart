part of 'demo_home.dart';

bool _hasLegacyVeneraLocators(ImportedChapterRecord chapter) =>
    chapter.sourceId.startsWith('venera:') &&
    chapter.pages.any(
      (page) => page.sourceId.startsWith('venera-resource://'),
    );

bool _manifestHasLegacyVeneraLocators(ChapterManifest manifest) =>
    manifest.sourceId.startsWith('venera:') &&
    manifest.pages.any(
      (page) => page.uri.toString().startsWith('venera-resource://'),
    );

Future<ChapterManifest> _loadCompatibleSourceChapter(
  BrowsableComicSource source,
  String chapterId,
) async {
  var manifest = await source.loadChapter(chapterId);
  if (!_manifestHasLegacyVeneraLocators(manifest)) {
    return manifest;
  }
  if (source is RefreshableChapterComicSource) {
    manifest = await source.refreshChapter(chapterId);
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
      ? await state._refreshRemoteEntry(entry)
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
          ? await state._refreshRemoteEntry(entry)
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
