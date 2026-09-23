part of 'home_shell.dart';

const _localFolderStaticCoverRevision =
    '$comicArtworkCacheSchemaRevision:local-thumb-512x768-v2';
const _localFolderAnimatedCoverRevision =
    '$comicArtworkCacheSchemaRevision:local-animated-original-v1';
const _localFolderCoverPlaceholderRole = 'cover-placeholder';

extension _HomeShellLocalCover on _HomeShellState {
  bool _localFolderCoverNeedsOriginal(
    ImportedChapterRecord? chapter,
    String sourceValue,
  ) {
    if (chapter == null) return true;
    if (chapter.coverAnimatedHint) return true;
    final format = chapter.coverMediaFormat?.toLowerCase();
    if (format == null || format.isEmpty) return true;
    if (format == 'gif' || format == 'webp') return true;
    for (final page in chapter.pages) {
      if (page.sourceId == sourceValue && page.animatedHint) {
        return true;
      }
    }
    return false;
  }

  String _localFolderCoverRevision(
    ImportedChapterRecord? chapter, {
    required bool preserveAnimation,
  }) {
    final base = preserveAnimation
        ? _localFolderAnimatedCoverRevision
        : _localFolderStaticCoverRevision;
    return chapter == null ? base : '$base:${chapter.sourceRevision}';
  }

  Future<EncodedResourceSource> _loadLocalFolderCoverArtifact({
    required String comicId,
    required String sourceValue,
    required ImportedChapterRecord? chapter,
    required bool awaitPersistenceOnMiss,
    bool forceRefresh = false,
  }) async {
    final preserveAnimation =
        _localFolderCoverNeedsOriginal(chapter, sourceValue);
    final revision = _localFolderCoverRevision(
      chapter,
      preserveAnimation: preserveAnimation,
    );
    if (!forceRefresh) {
      final cached = await readCachedComicImageSource(
        cache: _cacheCoordinator.responses,
        sourceId: 'local-folder',
        comicId: comicId,
        imageIdentity: sourceValue,
        resourceRole: 'cover',
        revision: revision,
        awaitPersistence: true,
        retention: ResourceCacheRetention.retained,
      );
      if (cached != null) {
        return cached;
      }
    }
    return loadCachedComicImageSource(
      cache: _cacheCoordinator.responses,
      sourceId: 'local-folder',
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: 'cover',
      revision: revision,
      awaitPersistence: awaitPersistenceOnMiss,
      forceRefresh: forceRefresh,
      retention: ResourceCacheRetention.retained,
      loader: preserveAnimation
          ? () => readLocalImageSource(sourceValue)
          : () async =>
              await readLocalImageThumbnail(
                sourceValue,
                maxWidth: 512,
                maxHeight: 768,
              ) ??
              await readLocalImageSource(sourceValue),
    );
  }

  Future<EncodedResourceSource?> _loadLocalFolderCoverPlaceholderArtifact({
    required String comicId,
    required String sourceValue,
    required ImportedChapterRecord? chapter,
    required bool awaitPersistenceOnMiss,
    bool forceRefresh = false,
    bool materializeOnMiss = true,
  }) async {
    if (!_localFolderCoverNeedsOriginal(chapter, sourceValue)) {
      return null;
    }
    final revision = _localFolderCoverRevision(
      chapter,
      preserveAnimation: false,
    );
    if (!forceRefresh) {
      final cached = await readCachedComicImageSource(
        cache: _cacheCoordinator.responses,
        sourceId: 'local-folder',
        comicId: comicId,
        imageIdentity: sourceValue,
        resourceRole: _localFolderCoverPlaceholderRole,
        revision: revision,
        awaitPersistence: true,
        retention: ResourceCacheRetention.retained,
      );
      if (cached != null) return cached;
    }
    if (!materializeOnMiss) {
      unawaited(
        (() async {
          try {
            await _loadLocalFolderCoverPlaceholderArtifact(
              comicId: comicId,
              sourceValue: sourceValue,
              chapter: chapter,
              awaitPersistenceOnMiss: false,
              forceRefresh: forceRefresh,
              materializeOnMiss: true,
            );
          } on Object {
            // Legacy records may lazily gain this acceleration artifact, but a
            // derivative failure must never affect the final animated cover.
          }
        })(),
      );
      return null;
    }
    final thumbnail = await readLocalImageThumbnail(
      sourceValue,
      maxWidth: 512,
      maxHeight: 768,
    );
    if (thumbnail == null || thumbnail.isEmpty) return null;
    return loadCachedComicImageSource(
      cache: _cacheCoordinator.responses,
      sourceId: 'local-folder',
      comicId: comicId,
      imageIdentity: sourceValue,
      resourceRole: _localFolderCoverPlaceholderRole,
      revision: revision,
      awaitPersistence: awaitPersistenceOnMiss,
      forceRefresh: forceRefresh,
      retention: ResourceCacheRetention.retained,
      loader: () async => thumbnail,
    );
  }

  Future<EncodedResourceSource?> _loadLocalFolderCardCoverSource(
    LibraryComic comic,
  ) async {
    if (comic.sourceId != 'local-folder') return null;
    final chapter = comic.coverChapter?.chapter;
    final fallbackPage = chapter == null || chapter.pages.isEmpty
        ? null
        : chapter.pages.first.sourceId;
    final sourceValue = comic.coverSourceId ?? chapter?.coverSourceId ?? fallbackPage;
    final uri = sourceValue == null ? null : Uri.tryParse(sourceValue);
    if (sourceValue == null ||
        uri?.scheme.toLowerCase() != 'content' ||
        !_localFolderCoverNeedsOriginal(chapter, sourceValue)) {
      return null;
    }
    // Comic cards are a thumbnail presentation surface. Keep the original
    // animated file as the durable artwork/content authority for details and
    // explicit media viewing, but use the retained static derivative as the
    // card presentation source. This avoids permanently decoding a large
    // looping animation merely because a card is mounted.
    return _loadLocalFolderCoverPlaceholderArtifact(
      comicId: comic.comicId,
      sourceValue: sourceValue,
      chapter: chapter,
      awaitPersistenceOnMiss: false,
      materializeOnMiss: true,
    );
  }

  Future<void> _materializeLocalFolderCover(
    ImportedChapterRecord chapter, {
    bool forceRefresh = false,
  }) async {
    if (chapter.sourceId != 'local-folder') {
      return;
    }
    final sourceValue = chapter.coverSourceId;
    final uri = sourceValue == null ? null : Uri.tryParse(sourceValue);
    if (sourceValue == null || uri?.scheme.toLowerCase() != 'content') {
      return;
    }
    final finalCover = _loadLocalFolderCoverArtifact(
      comicId: chapter.comicId,
      sourceValue: sourceValue,
      chapter: chapter,
      awaitPersistenceOnMiss: true,
      forceRefresh: forceRefresh,
    );
    final placeholder = _loadLocalFolderCoverPlaceholderArtifact(
      comicId: chapter.comicId,
      sourceValue: sourceValue,
      chapter: chapter,
      awaitPersistenceOnMiss: true,
      forceRefresh: forceRefresh,
    );
    await Future.wait<Object?>(<Future<Object?>>[
      finalCover,
      placeholder,
    ]);
  }

}
