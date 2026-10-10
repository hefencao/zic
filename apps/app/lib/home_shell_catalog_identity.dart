part of 'home_shell.dart';

// This projection lives for one synchronous query/build only. A later query
// reads the current source and library again, including offline identities.
final class _HomeCatalogIdentityQuery {
  _HomeCatalogIdentityQuery({
    required this.entries,
    required this.savedComics,
    required this.sourceForId,
  });

  final List<ImportedLibraryEntry> entries;
  final List<SavedComicRecord> savedComics;
  final BrowsableComicSource? Function(String sourceId) sourceForId;
  final Map<String, String> _canonicalIds = <String, String>{};
  final Map<String, BrowsableComicSource?> _sources =
      <String, BrowsableComicSource?>{};
  late final Map<String, String> _storedIds = _indexStoredIds();
  final Map<String, Map<String, Set<String>>> _aliasesBySource =
      <String, Map<String, Set<String>>>{};

  Map<String, String> _indexStoredIds() {
    final ids = <String, String>{};
    for (final saved in savedComics) {
      final canonical = saved.canonicalComicId;
      if (canonical != null) {
        ids.putIfAbsent('${saved.sourceId}\u0000${saved.comicId}',
            () => canonical);
      }
    }
    return ids;
  }

  String keyFor(String sourceId, String comicId) {
    final rawKey = '$sourceId\u0000$comicId';
    final canonical = _canonicalIds.putIfAbsent(rawKey, () {
      final source = _sources.putIfAbsent(sourceId, () => sourceForId(sourceId));
      return source is CanonicalComicIdentitySource
          ? (source as CanonicalComicIdentitySource).canonicalComicIdentity(comicId)
          : _storedIds[rawKey] ?? comicId;
    });
    return '$sourceId\u0000$canonical';
  }

  Map<String, Set<String>> _indexAliases(String sourceId) {
    final aliases = <String, Set<String>>{};
    final examined = <String>{};
    void add(String comicId) {
      if (!examined.add(comicId)) return;
      aliases.putIfAbsent(keyFor(sourceId, comicId), () => <String>{})
          .add(comicId);
    }
    for (final saved in savedComics) {
      if (saved.sourceId == sourceId) add(saved.comicId);
    }
    for (final entry in entries) {
      if (entry.chapter.sourceId == sourceId) add(entry.chapter.comicId);
    }
    return aliases;
  }

  Set<String> aliasesFor(String sourceId, String comicId) {
    final canonical = keyFor(sourceId, comicId);
    final aliases = _aliasesBySource.putIfAbsent(
      sourceId, () => _indexAliases(sourceId),
    );
    return <String>{comicId, ...?aliases[canonical]};
  }
}

extension _HomeShellCatalogIdentity on _HomeShellState {
  _HomeCatalogIdentityQuery _catalogIdentityQuery() =>
      _HomeCatalogIdentityQuery(
        entries: _libraryEntries,
        savedComics: _savedComics,
        sourceForId: _sourceForId,
      );

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
    // A single live card query needs only its matching aliases. Building a
    // reverse index here would allocate the whole catalog again per card.
    final examined = <String>{comicId};
    for (final saved in _savedComics) {
      if (saved.sourceId == sourceId &&
          examined.add(saved.comicId) &&
          _canonicalComicKey(sourceId, saved.comicId) == canonical) {
        aliases.add(saved.comicId);
      }
    }
    for (final entry in _libraryEntries) {
      if (entry.chapter.sourceId == sourceId &&
          examined.add(entry.chapter.comicId) &&
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
    final query = _catalogIdentityQuery();
    final canonical = query.keyFor(sourceId, comicId);
    return _savedComics
        .where(
          (saved) =>
              saved.sourceId == sourceId &&
              query.keyFor(sourceId, saved.comicId) == canonical,
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
        monotonicMicros: _traceClock.nowMicros(),
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

  bool _manifestChapterCatalogDiffers(
    SavedComicRecord? existing,
    ComicManifest incoming,
  ) {
    if (existing == null) return true;
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
          saved.publishedAt != current.publishedAt ||
          saved.updatedAt != current.updatedAt) {
        return true;
      }
    }
    return false;
  }

  bool _manifestChapterCatalogChanged(
    SavedComicRecord? existing,
    ComicManifest incoming,
  ) {
    // No previous chapter catalog means this load establishes the baseline;
    // it is not a source update by itself.
    return existing != null &&
        existing.chapters.isNotEmpty &&
        _manifestChapterCatalogDiffers(existing, incoming);
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
    return _manifestChapterCatalogDiffers(existing, incoming);
  }

  Set<String> _unseenChapterIdsForManifest(
    SavedComicRecord? existing,
    ComicManifest incoming,
  ) {
    if (existing == null || existing.chapters.isEmpty) {
      return const <String>{};
    }
    final incomingIds =
        incoming.chapters.map((chapter) => chapter.chapterId).toSet();
    final previousIds =
        existing.chapters.map((chapter) => chapter.chapterId).toSet();
    return <String>{
      ...existing.unseenChapterIds.where(incomingIds.contains),
      ...incomingIds.where((chapterId) => !previousIds.contains(chapterId)),
    };
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
      await _librarySession.removeSavedComic(
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
        unseenChapterIds: _unseenChapterIdsForManifest(existing, manifest),
      ),
    );
  }

}
