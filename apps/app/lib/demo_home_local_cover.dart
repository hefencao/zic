part of 'demo_home.dart';

const _localFolderStaticCoverRevision =
    '$comicArtworkCacheSchemaRevision:local-thumb-512x768-v2';
const _localFolderAnimatedCoverRevision =
    '$comicArtworkCacheSchemaRevision:local-animated-original-v1';

extension _DemoHomeLocalCover on _DemoHomeState {
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
    await _loadLocalFolderCoverArtifact(
      comicId: chapter.comicId,
      sourceValue: sourceValue,
      chapter: chapter,
      awaitPersistenceOnMiss: true,
      forceRefresh: forceRefresh,
    );
  }

}
