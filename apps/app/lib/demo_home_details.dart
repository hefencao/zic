part of 'demo_home.dart';

extension _DemoHomeDetailsActions on _DemoHomeState {
  details.ComicDetailsLibrarySnapshot _detailsSnapshotForComic(
    String sourceId,
    String comicId, {
    ComicPreference? preference,
    bool resolveCanonicalAlias = true,
  }) {
    final preferred = resolveCanonicalAlias
        ? _libraryComicForSourceIdentity(sourceId, comicId)
        : null;
    final effectiveComicId = preferred?.comicId ?? comicId;
    final saved = _savedComics.where(
      (item) =>
          item.sourceId == sourceId && item.comicId == effectiveComicId,
    );
    final sourceChapters = saved.isEmpty
        ? const <Chapter>[]
        : saved.first.chapters
            .map((chapter) => chapter.toChapter(effectiveComicId))
            .toList(growable: false);
    final source = _sourceForId(sourceId);
    final cachedDetails = source is CachedComicDetailsProjection
        ? source as CachedComicDetailsProjection
        : null;
    final cachedManifest = cachedDetails?.peekComic(effectiveComicId);
    final chapters = _libraryEntries
        .where(
          (entry) =>
              entry.chapter.sourceId == sourceId &&
              entry.chapter.comicId == effectiveComicId,
        )
        .toList(growable: false);
    return details.ComicDetailsLibrarySnapshot(
      chapters: chapters,
      sourceChapters: cachedManifest?.chapters ?? sourceChapters,
      sourceComic: cachedManifest?.comic ??
          (saved.isEmpty ? null : saved.first.toComic()),
      sourceManifest: cachedManifest,
      readStates: <String, ChapterReadState>{
        for (final chapter in chapters)
          if (_chapterReadStates.containsKey(chapter.identity))
            details.comicDetailsChapterIdentity(
              chapter.chapter.sourceId,
              chapter.chapter.chapterId,
            ): _chapterReadStates[chapter.identity]!,
      },
      preference: _mergedPreferenceFor(
        sourceId,
        effectiveComicId,
        fallbackPreference: preference,
        fallbackSourceKind: preference?.sourceKind,
        fallbackInShelf:
            preference?.inShelf ?? sourceId == 'local-folder',
      ),
    );
  }

  Future<details.ComicDetailsLibrarySnapshot> _reloadDetailsSnapshot(
    String sourceId,
    String comicId, {
    required bool refreshContent,
    ComicPreference? fallbackPreference,
    bool resolveCanonicalAlias = true,
  }) async {
    final preferred = resolveCanonicalAlias
        ? _libraryComicForSourceIdentity(sourceId, comicId)
        : null;
    final effectiveComicId = preferred?.comicId ?? comicId;
    ComicManifest? sourceManifest;
    if (refreshContent) {
      if (sourceId == 'local-folder') {
        final entries = _libraryEntries
            .where(
              (entry) =>
                  entry.chapter.sourceId == sourceId &&
                  entry.chapter.comicId == effectiveComicId,
            )
            .toList(growable: false);
        for (final entry in entries) {
          final folder = await widget.folderRefresher(entry.chapter);
          final refreshed = imageFolderChapterRecord(folder).copyWith(
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            comicAuthors: entry.chapter.comicAuthors,
            comicTags: entry.chapter.comicTags,
            comicDescription: entry.chapter.comicDescription,
            sequence: entry.chapter.sequence,
            importedAt: entry.chapter.importedAt,
          );
          await this._materializeLocalFolderCover(
            refreshed,
            forceRefresh: true,
          );
          await _librarySession.upsertChapter(refreshed);
        }
      } else {
        final source = _sourceForId(sourceId);
        if (source == null) {
          throw StateError('漫画源 $sourceId 当前不可用');
        }
        final cachedDetails = source is CachedComicDetailsProjection
            ? source as CachedComicDetailsProjection
            : null;
        final manifest = cachedDetails == null
            ? await source.loadComic(effectiveComicId)
            : await cachedDetails.refreshComic(effectiveComicId);
        sourceManifest = manifest;
        final existing = resolveCanonicalAlias
            ? _preferredSavedComicAlias(sourceId, effectiveComicId) ??
                await _library.getSavedComic(sourceId, effectiveComicId)
            : await _library.getSavedComic(sourceId, effectiveComicId);
        widget.debugTrace.record(
          TraceEvent(
            monotonicMicros: _traceClock.elapsedMicroseconds,
            sessionId: 'source-catalog:$sourceId',
            kind: TraceEventKind.sourceReady,
            identityHash: _comicIdentityTraceHash(
              sourceId,
              effectiveComicId,
              canonical: _canonicalComicKey(sourceId, effectiveComicId),
            ),
            payload: <String, Object?>{
              'stage': 'chapter-catalog-refresh-result',
              'comicIdLength': effectiveComicId.length,
              'requestedComicIdLength': comicId.length,
              'aliasCount': _canonicalComicAliases(
                sourceId,
                effectiveComicId,
              ).length,
              'previousChapterCount':
                  existing == null ? 0 : _savedChapterCount(existing),
              'chapterCount': manifest.chapters.length,
            },
          ),
        );
        _rejectCatalogRegression(existing: existing, incoming: manifest);
        final now = DateTime.now().toUtc();
        final changed = _manifestContentChanged(existing, manifest);
        final chapterCatalogChanged =
            _manifestChapterCatalogChanged(existing, manifest);
        await _librarySession.upsertSavedComic(
          SavedComicRecord.fromManifest(
            manifest,
            canonicalComicId: _canonicalComicIdForPersistence(
              manifest.comic.sourceId,
              manifest.comic.comicId,
              fallback: existing?.canonicalComicId,
            ),
            savedAt: existing?.savedAt,
            updatedAt: changed ? now : existing?.updatedAt,
            sourceUpdateAt:
                chapterCatalogChanged ? now : existing?.sourceUpdateAt,
          ),
        );
      }
    }
    final snapshot = _detailsSnapshotForComic(
      sourceId,
      effectiveComicId,
      preference: fallbackPreference,
      resolveCanonicalAlias: resolveCanonicalAlias,
    );
    return sourceManifest == null
        ? snapshot
        : snapshot.copyWith(sourceManifest: sourceManifest);
  }
}
