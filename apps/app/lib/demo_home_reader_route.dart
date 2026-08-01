part of 'demo_home.dart';

typedef _PreparedImportedChapter = ({
  ImportedLibraryEntry entry,
  Map<String, LocalImageFileBytesLoader> byteLoaders,
  Map<String, ExternalPluginResourceResponseLoader> responseLoaders,
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
    return ImportedImageChapterScreen(
      record: current.chapter,
      byteLoaders: prepared.byteLoaders,
      responseLoaders: prepared.responseLoaders,
      initialProgress: current.progress ??
          ReadingProgress(
            sourceId: current.chapter.sourceId,
            comicId: current.chapter.comicId,
            chapterId: current.chapter.chapterId,
            pageIndex: 0,
            subPageOffset: 0,
            readerMode: widget.preferences.defaultReaderMode,
            updatedAt: DateTime.now().toUtc(),
          ),
      onProgressChanged: _library.saveProgress,
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
      pipelineFactory: defaultLocalMediaPipelineFactory.withArtifactCache(
        _chapterDownloads is ArtifactCacheStore
            ? _chapterDownloads as ArtifactCacheStore
            : null,
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
