part of 'demo_home.dart';

extension _DemoHomeCatalogIdentity on _DemoHomeState {
  String? _sourceCanonicalComicId(String sourceId, String comicId) {
    final source = _sourceForId(sourceId);
    if (source is! CanonicalComicIdentitySource) {
      return null;
    }
    final canonical =
        (source as CanonicalComicIdentitySource).canonicalComicIdentity(comicId);
    return canonical;
  }

  String? _storedCanonicalComicId(String sourceId, String comicId) {
    for (final saved in _savedComics) {
      if (saved.sourceId == sourceId &&
          saved.comicId == comicId &&
          saved.canonicalComicId != null) {
        return saved.canonicalComicId;
      }
    }
    return null;
  }

  String _canonicalComicId(String sourceId, String comicId) {
    return _sourceCanonicalComicId(sourceId, comicId) ??
        _storedCanonicalComicId(sourceId, comicId) ??
        comicId;
  }

  String? _canonicalComicIdForPersistence(
    String sourceId,
    String comicId, {
    String? fallback,
  }) {
    final sourceCanonical = _sourceCanonicalComicId(sourceId, comicId);
    if (sourceCanonical == null) {
      return fallback;
    }
    return sourceCanonical == comicId ? null : sourceCanonical;
  }

  String _canonicalComicKey(String sourceId, String comicId) {
    return '$sourceId\u0000${_canonicalComicId(sourceId, comicId)}';
  }

  Set<String> _canonicalComicAliases(String sourceId, String comicId) {
    final canonical = _canonicalComicKey(sourceId, comicId);
    final aliases = <String>{comicId};
    for (final saved in _savedComics) {
      if (saved.sourceId == sourceId &&
          _canonicalComicKey(sourceId, saved.comicId) == canonical) {
        aliases.add(saved.comicId);
      }
    }
    for (final entry in _libraryEntries) {
      if (entry.chapter.sourceId == sourceId &&
          _canonicalComicKey(sourceId, entry.chapter.comicId) == canonical) {
        aliases.add(entry.chapter.comicId);
      }
    }
    return aliases;
  }

  List<SavedComicRecord> _savedComicAliasesFor(
    String sourceId,
    String comicId,
  ) {
    final canonical = _canonicalComicKey(sourceId, comicId);
    return _savedComics
        .where(
          (saved) =>
              saved.sourceId == sourceId &&
              _canonicalComicKey(sourceId, saved.comicId) == canonical,
        )
        .toList(growable: false);
  }

  SavedComicRecord? _preferredSavedComicAlias(
    String sourceId,
    String comicId,
  ) {
    final aliases = _savedComicAliasesFor(sourceId, comicId);
    if (aliases.isEmpty) return null;
    return aliases.reduce(
      (left, right) => _compareSavedComicAliasQuality(left, right) >= 0
          ? left
          : right,
    );
  }

  int _compareSavedComicAliasQuality(
    SavedComicRecord left,
    SavedComicRecord right,
  ) {
    final leftReal = _savedRealChapterCount(left);
    final rightReal = _savedRealChapterCount(right);
    var result = leftReal.compareTo(rightReal);
    if (result != 0) return result;
    result = left.chapters.length.compareTo(right.chapters.length);
    if (result != 0) return result;
    result = left.updatedAt.compareTo(right.updatedAt);
    if (result != 0) return result;
    result = right.comicId.length.compareTo(left.comicId.length);
    if (result != 0) return result;
    return right.comicId.compareTo(left.comicId);
  }

  int _savedRealChapterCount(SavedComicRecord comic) => comic.chapters
      .where(
        (chapter) =>
            !isSyntheticMihonChapterIdentity(chapter.chapterId),
      )
      .length;

  int _manifestRealChapterCount(ComicManifest manifest) => manifest.chapters
      .where(
        (chapter) =>
            !isSyntheticMihonChapterIdentity(chapter.chapterId),
      )
      .length;

  Future<bool> _persistKnownCanonicalComicIds() async {
    await _ensureLibraryReady();
    var changed = false;
    for (final saved in _savedComics) {
      final sourceCanonical = _sourceCanonicalComicId(
        saved.sourceId,
        saved.comicId,
      );
      if (sourceCanonical == null) {
        continue;
      }
      final canonical =
          sourceCanonical == saved.comicId ? null : sourceCanonical;
      if (canonical == saved.canonicalComicId) {
        continue;
      }
      await _library.upsertSavedComic(
        saved.copyWith(
          canonicalComicId: canonical,
          clearCanonicalComicId: canonical == null,
        ),
      );
      changed = true;
    }
    return changed;
  }

  LibraryComic? _libraryComicForSourceIdentity(
    String sourceId,
    String comicId,
  ) {
    final canonical = _canonicalComicKey(sourceId, comicId);
    final aliases = _libraryComics
        .where(
          (comic) =>
              comic.sourceId == sourceId &&
              _canonicalComicKey(sourceId, comic.comicId) == canonical,
        )
        .toList(growable: false);
    return aliases.isEmpty
        ? null
        : preferredLibraryComicAlias(
            aliases,
            isCompatibilityChapter: isSyntheticMihonChapterIdentity,
          );
  }

  void _rejectCatalogRegression({
    required SavedComicRecord? existing,
    required ComicManifest incoming,
  }) {
    if (existing == null) return;
    final previousRealCount = _savedRealChapterCount(existing);
    final incomingRealCount = _manifestRealChapterCount(incoming);
    final lostRealCatalog = previousRealCount > 0 && incomingRealCount == 0;
    final collapsedToSingleChapter =
        previousRealCount > 1 && incomingRealCount <= 1;
    if (!lostRealCatalog && !collapsedToSingleChapter) return;
    final canonical = _canonicalComicKey(
      incoming.comic.sourceId,
      incoming.comic.comicId,
    );
    widget.debugTrace.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'source-catalog:${incoming.comic.sourceId}',
        kind: TraceEventKind.taskFailed,
        identityHash: _comicIdentityTraceHash(
          incoming.comic.sourceId,
          incoming.comic.comicId,
          canonical: canonical,
        ),
        payload: <String, Object?>{
          'stage': 'chapter-catalog-regression-rejected',
          'reason': lostRealCatalog
              ? 'lost-real-catalog'
              : 'collapsed-to-single-chapter',
          'comicIdLength': incoming.comic.comicId.length,
          'existingComicIdLength': existing.comicId.length,
          'aliasCount': _canonicalComicAliases(
            incoming.comic.sourceId,
            incoming.comic.comicId,
          ).length,
          'previousChapterCount': existing.chapters.length,
          'previousRealChapterCount': previousRealCount,
          'incomingChapterCount': incoming.chapters.length,
          'incomingRealChapterCount': incomingRealCount,
          'incomingSyntheticCount': incoming.chapters
              .where(
                (chapter) => isSyntheticMihonChapterIdentity(
                  chapter.chapterId,
                ),
              )
              .length,
        },
      ),
    );
    throw StateError(
      '漫画源曾返回多个真实章节，本次目录退化为${incomingRealCount == 0 ? '空目录或兼容单章节' : '单章节'}；'
      '已保留原目录，请重新完成站点验证后刷新。',
    );
  }

  Future<void> _persistRemoteComic(
    ComicManifest manifest,
    bool retained,
  ) async {
    await _ensureLibraryReady();
    if (!retained) {
      await _library.removeSavedComic(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      return;
    }
    final existing = _preferredSavedComicAlias(
          manifest.comic.sourceId,
          manifest.comic.comicId,
        ) ??
        await _library.getSavedComic(
          manifest.comic.sourceId,
          manifest.comic.comicId,
        );
    _rejectCatalogRegression(existing: existing, incoming: manifest);
    await _library.upsertSavedComic(
      SavedComicRecord.fromManifest(
        manifest,
        canonicalComicId: _canonicalComicIdForPersistence(
          manifest.comic.sourceId,
          manifest.comic.comicId,
          fallback: existing?.canonicalComicId,
        ),
        savedAt: existing?.savedAt,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

}
