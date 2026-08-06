part of 'demo_home.dart';

typedef _PreparedImportedChapter = ({
  ImportedLibraryEntry entry,
  Map<String, LocalImageFileBytesLoader> byteLoaders,
  Map<String, ExternalPluginResourceResponseLoader> responseLoaders,
  int? initialPageIndex,
});

extension _DemoHomeReaderRouteComposition on _DemoHomeState {
  Widget _buildImportedChapterScreen(_PreparedImportedChapter prepared) {
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
    final pageIndex = prepared.initialPageIndex;
    final maxPageIndex = current.chapter.pages.isEmpty
        ? 0
        : current.chapter.pages.length - 1;
    final initialProgress = pageIndex == null
        ? current.progress
        : ReadingProgress(
            sourceId: current.chapter.sourceId,
            comicId: current.chapter.comicId,
            chapterId: current.chapter.chapterId,
            pageIndex: pageIndex.clamp(0, maxPageIndex).toInt(),
            subPageOffset: 0,
            readerMode: current.progress?.readerMode ??
                widget.preferences.defaultReaderMode,
            updatedAt: DateTime.now().toUtc(),
          );
    return ImportedImageChapterScreen(
      record: current.chapter,
      byteLoaders: prepared.byteLoaders,
      responseLoaders: prepared.responseLoaders,
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
      onProgressChanged: _saveReaderProgress,
      initiallyImmersive: widget.preferences.readerStartsImmersive,
      initialReaderSettings: widget.preferences.readerSessionSettingsFor(
        current.chapter.sourceId,
        current.chapter.comicId,
      ),
      onReaderSettingsChanged: (settings) =>
          widget.preferences.saveReaderSessionSettings(
        current.chapter.sourceId,
        current.chapter.comicId,
        settings,
      ),
      traceSink: widget.debugTrace,
      onDownloadRequested: () => _downloadChapter(current),
      pipelineFactory:
          defaultLocalMediaPipelineFactory.withArtifactCacheManager(
        _readerArtifactCache,
      ),
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
  }
}
