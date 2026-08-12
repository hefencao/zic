part of 'demo_home.dart';

typedef _PreparedImportedChapter = ({
  ImportedLibraryEntry entry,
  Map<String, LocalImageFileBytesLoader> byteLoaders,
  Map<String, ExternalPluginControlledResourceResponseLoader> responseLoaders,
  int? initialPageIndex,
});

final class _ReaderComicVersionNoticeGate extends StatefulWidget {
  const _ReaderComicVersionNoticeGate({
    required this.sourceId,
    required this.comicId,
    required this.preferences,
    required this.loadSuccessor,
    required this.child,
  });

  final String sourceId;
  final String comicId;
  final AppPreferencesController preferences;
  final Future<ComicVersionRelation?> Function() loadSuccessor;
  final Widget child;

  @override
  State<_ReaderComicVersionNoticeGate> createState() =>
      _ReaderComicVersionNoticeGateState();
}

final class _ReaderComicVersionNoticeGateState
    extends State<_ReaderComicVersionNoticeGate> {
  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final relation = await widget.loadSuccessor();
    if (!mounted || relation == null) return;
    if (widget.preferences.hasAcknowledgedComicVersionNotice(
      widget.sourceId,
      widget.comicId,
      relation.successorComicId,
    )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      widget.preferences.acknowledgeComicVersionNotice(
        widget.sourceId,
        widget.comicId,
        relation.successorComicId,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('发现同源新版本，可在漫画详情页查看更新'),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

extension _DemoHomeReaderRouteComposition on _DemoHomeState {
  Widget _buildImportedChapterScreen(
    _PreparedImportedChapter prepared, {
    required Future<void> Function(ReadingProgress) onProgressChanged,
  }) {
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
    final screen = ImportedImageChapterScreen(
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
      onProgressChanged: onProgressChanged,
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
      pipelineFactory: defaultLocalMediaPipelineFactory
          .withArtifactCacheManager(_readerArtifactCache)
          .withPartialDownloadStore(
            _downloadComposition?.artifactStore ??
                (_chapterDownloads is PartialDownloadStore
                    ? _chapterDownloads as PartialDownloadStore
                    : null),
          )
          .withTransferRuntime(
            _downloadComposition?.transferRuntime,
          )
          .withUserAgentProvider(() => widget.preferences.networkUserAgent),
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
    return _ReaderComicVersionNoticeGate(
      sourceId: current.chapter.sourceId,
      comicId: current.chapter.comicId,
      preferences: widget.preferences,
      loadSuccessor: () async {
        final store = _comicVersionRelationStore();
        if (store == null) return null;
        final relations = await store.listComicVersionSuccessors(
          current.chapter.sourceId,
          current.chapter.comicId,
        );
        return relations.isEmpty ? null : relations.first;
      },
      child: screen,
    );
  }
}
