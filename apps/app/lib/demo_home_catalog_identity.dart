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
    final leftReal = _savedChapterCount(left);
    final rightReal = _savedChapterCount(right);
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

  int _savedChapterCount(SavedComicRecord comic) => comic.chapters.length;

  int _manifestChapterCount(ComicManifest manifest) =>
      manifest.chapters.length;

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

  LibraryComic? _exactLibraryComicForSourceIdentity(
    String sourceId,
    String comicId,
  ) {
    for (final comic in aggregateImportedLibrary(
      _libraryEntries,
      savedComics: _savedComics,
    )) {
      if (comic.sourceId == sourceId && comic.comicId == comicId) {
        return comic;
      }
    }
    return null;
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
        : preferredLibraryComicAlias(aliases);
  }

  void _rejectCatalogRegression({
    required SavedComicRecord? existing,
    required ComicManifest incoming,
  }) {
    if (existing == null) return;
    final previousChapterCount = _savedChapterCount(existing);
    final incomingChapterCount = _manifestChapterCount(incoming);
    final lostCatalog = previousChapterCount > 0 && incomingChapterCount == 0;
    final collapsedToSingleChapter =
        previousChapterCount > 1 && incomingChapterCount <= 1;
    if (!lostCatalog && !collapsedToSingleChapter) return;
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
          'reason': lostCatalog
              ? 'lost-catalog'
              : 'collapsed-to-single-chapter',
          'comicIdLength': incoming.comic.comicId.length,
          'existingComicIdLength': existing.comicId.length,
          'aliasCount': _canonicalComicAliases(
            incoming.comic.sourceId,
            incoming.comic.comicId,
          ).length,
          'previousChapterCount': previousChapterCount,
          'incomingChapterCount': incomingChapterCount,
        },
      ),
    );
    throw StateError(
      '漫画源曾返回多个章节，本次目录退化为${incomingChapterCount == 0 ? '空目录' : '单章节'}；'
      '已保留原目录，请重新完成站点验证后刷新。',
    );
  }

  bool _manifestContentChanged(
    SavedComicRecord? existing,
    ComicManifest incoming,
  ) {
    if (existing == null) return true;
    final comic = incoming.comic;
    if (existing.title != comic.title ||
        !_sameStrings(existing.authors, comic.authors) ||
        !_sameStrings(existing.tags, comic.tags) ||
        existing.description != comic.description ||
        existing.coverSourceId != comic.coverUri?.toString() ||
        existing.readingDirection != comic.readingDirection) {
      return true;
    }
    final chapters = incoming.chapters.toList(growable: false)
      ..sort(_compareManifestChapters);
    if (existing.chapters.length != chapters.length) return true;
    for (var index = 0; index < chapters.length; index++) {
      final saved = existing.chapters[index];
      final current = chapters[index];
      if (saved.chapterId != current.chapterId ||
          saved.title != current.title ||
          saved.sequence != current.sequence ||
          saved.pageCount != current.pageCount ||
          saved.sourceRevision != current.sourceRevision ||
          saved.publishedAt != current.publishedAt) {
        return true;
      }
    }
    return false;
  }

  bool _sameStrings(Iterable<String> left, Iterable<String> right) {
    final a = left.toList(growable: false);
    final b = right.toList(growable: false);
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  int _compareManifestChapters(Chapter left, Chapter right) {
    final sequence = left.sequence.compareTo(right.sequence);
    if (sequence != 0) return sequence;
    return left.chapterId.compareTo(right.chapterId);
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
    final changed = _manifestContentChanged(existing, manifest);
    await _library.upsertSavedComic(
      SavedComicRecord.fromManifest(
        manifest,
        canonicalComicId: _canonicalComicIdForPersistence(
          manifest.comic.sourceId,
          manifest.comic.comicId,
          fallback: existing?.canonicalComicId,
        ),
        savedAt: existing?.savedAt,
        updatedAt: changed ? DateTime.now().toUtc() : existing?.updatedAt,
      ),
    );
  }

}
