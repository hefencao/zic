part of 'chapter_downloads.dart';

/// Rebuilds only a demanded exact page from an existing ZIC file inventory.
/// A directory name locates a candidate; owner/revision/page/CRC prove reuse.
final class _DownloadedChapterRecovery {
  _DownloadedChapterRecovery(this.store);
  final PersistentDownloadArtifactStore store;
  final Map<String, ImportedLibraryEntry> _chapters = {};
  final Map<String, Future<({String directory, ComicFolderManifest manifest})?>> _folders = {};

  void remember(ImportedLibraryEntry entry) {
    final chapter = entry.chapter;
    if (isLocalLibrarySource(chapter.sourceId) || chapter.isSummary || chapter.pages.isEmpty ||
        chapterHasHomeProjectionSnapshotPagePlaceholders(chapter)) return;
    final key = canonicalMediaExactChapterKey(sourceId: chapter.sourceId, comicId: chapter.comicId,
      chapterId: chapter.chapterId, sourceRevision: chapter.sourceRevision);
    final previous = _chapters.remove(key);
    if (previous != null && !identical(previous.chapter, chapter)) _folders.remove(key);
    _chapters[key] = entry;
    while (_chapters.length > 16) {
      final oldest = _chapters.keys.first;
      _chapters.remove(oldest);
      _folders.remove(oldest);
    }
  }

  void invalidate(String sourceId, String comicId) {
    for (final entry in _chapters.entries) {
      if (entry.value.chapter.sourceId == sourceId && entry.value.chapter.comicId == comicId) {
        _folders.remove(entry.key);
      }
    }
  }

  void forget(ImportedLibraryEntry entry) {
    final chapter = entry.chapter;
    final key = canonicalMediaExactChapterKey(sourceId: chapter.sourceId, comicId: chapter.comicId,
      chapterId: chapter.chapterId, sourceRevision: chapter.sourceRevision);
    _chapters.remove(key);
    _folders.remove(key);
  }

  Future<bool> prepare(ImportedLibraryEntry entry) async {
    final chapter = entry.chapter;
    final key = canonicalMediaExactChapterKey(sourceId: chapter.sourceId, comicId: chapter.comicId,
      chapterId: chapter.chapterId, sourceRevision: chapter.sourceRevision);
    if (!_chapters.containsKey(key)) return false;
    return await (_folders[key] ??= _folder(entry)) != null;
  }

  Future<({String directory, ComicFolderManifest manifest})?> _folder(ImportedLibraryEntry entry) async {
    final chapter = entry.chapter;
    final claim = store._claimedPlacementsByOwner['${chapter.sourceId}\u0000${chapter.comicId}'] ??
        await store._index.getPlacement(sourceId: chapter.sourceId, comicId: chapter.comicId);
    final root = store._layoutForEntryPage(entry, 0);
    final directories = claim == null || claim.storageRootId != store.storageRootIdFor(entry) ? {
      buildComicDirectoryName(comicTitle: chapter.comicTitle),
      buildComicDirectoryName(comicTitle: chapter.comicTitle,
        conflictSourceSuffix: store._structuredComicOwnerSuffix(entry)),
    } : {claim.relativeDirectory};
    for (final directory in directories) {
      if (!store._isSafeComicDirectoryName(directory)) continue;
      final ComicFolderManifest? manifest;
      try {
        manifest = await store._readComicFolderManifest(directory, rootLayout: root);
      } on Failure catch (error) {
        if (error.code != ErrorCode.artifactCorruption) rethrow;
        continue; // Invalid metadata never authorizes bytes or an overwrite.
      }
      if (manifest == null || manifest.sourceId != chapter.sourceId || manifest.comicId != chapter.comicId) continue;
      if (manifest.chapterFiles.containsKey(chapter.chapterId)) return (directory: directory, manifest: manifest);
    }
    return null;
  }

  Future<CacheRec?> recover(DownloadId id, {TaskControl? control}) async {
    control?.throwIfCancelled();
    final key = canonicalMediaExactChapterKeyForDownload(id);
    final entry = _chapters[key];
    if (entry == null) return null;
    final lookup = _folders[key] ??= _folder(entry);
    final folder = await lookup;
    control?.throwIfCancelled();
    if (folder == null || store._closed) return null;
    final chapter = entry.chapter;
    final manifest = folder.manifest;
    final inventory = manifest.chapterFiles[chapter.chapterId]!;
    if (inventory.sourceRevision != chapter.sourceRevision || inventory.pageCount != chapter.pages.length) return null;
    final files = inventory.pages.where((page) => page.pageId == id.content.pageId);
    if (files.length != 1) return null;
    final file = files.single;
    if (file.logicalIndex < 0 || file.logicalIndex >= chapter.pages.length ||
        file.checksumAlgorithm != 'crc32') return null;
    final current = chapter.toManifest();
    final currentId = readerPageDownloadId(current, current.pages[file.logicalIndex]);
    if (currentId != id) return null;
    final subdirectory = manifest.chapterDirectories[chapter.chapterId];
    if (subdirectory == null && manifest.chapters.length != 1) return null;
    final relative = '${folder.directory}/${subdirectory == null ? '' : '$subdirectory/'}${file.fileName}';
    final path = store.safTreeIo != null && store.safTreeUri != null
        ? encodeSafRecordPath(treeUri: store.safTreeUri!, relativePath: relative)
        : '${store._layoutForEntryPage(entry, file.logicalIndex).root}/$relative';
    // The caller holds the exact-artifact serializer. Never acquire the
    // manifest serializer here: export migration can hold it while joining an
    // artifact mutation. Invalidation fences a metadata change during proof.
    try {
      return await store._serializeStructuredWrite(path, () async {
        final proof = await store._artifactProof(path, control: control);
        if (proof.bytes != file.bytes || proof.checksum != file.checksum ||
            !identical(_folders[key], lookup) || store._closed) return null;
        final record = await store._adoptProvenPageRecord(id: id, path: path,
          bytes: file.bytes, checksum: file.checksum, storageRootId: store.storageRootIdFor(entry));
        store._notifyManagementProjectionChanged();
        return record;
      });
    } on Failure catch (error) {
      if (error.code == ErrorCode.artifactCorruption) return null;
      rethrow;
    }
  }
}
