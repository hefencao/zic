import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const comicDetailsScreenKey = ValueKey<String>('comic-details-screen');
const localComicDetailsScreenKey =
    ValueKey<String>('local-comic-details-screen');
const remoteComicDetailsScreenKey =
    ValueKey<String>('remote-comic-details-screen');
const comicDetailsReverseKey = ValueKey<String>('comic-details-reverse');
const comicDetailsRefreshKey = ValueKey<String>('comic-details-refresh');
const comicDetailsErrorKey = ValueKey<String>('comic-details-error');
const comicDetailsCopyErrorKey =
    ValueKey<String>('comic-details-copy-error');
const comicDetailsShelfKey = ValueKey<String>('comic-details-shelf');
const comicDetailsCollectedKey =
    ValueKey<String>('comic-details-collected');
const comicDetailsLikedKey = ValueKey<String>('comic-details-liked');
const comicDetailsMigrateKey = ValueKey<String>('comic-details-migrate');

String comicDetailsChapterIdentity(String sourceId, String chapterId) =>
    '$sourceId\u0000$chapterId';

Key comicDetailsChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

Key comicDetailsReadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-read:$sourceId\u0000$chapterId');

Key comicDetailsDownloadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-download:$sourceId\u0000$chapterId');

enum ComicDetailsRouteKind { local, remote }

/// Centralized route decision. A source page reuses the local details page only
/// when the same source and native comic identity already has durable metadata
/// or chapters. Same titles from other sources are not silently merged.
ComicDetailsRouteKind resolveComicDetailsRoute({
  required String sourceId,
  required String comicId,
  required Iterable<LibraryComic> library,
}) {
  for (final comic in library) {
    if (comic.sourceId == sourceId && comic.comicId == comicId) {
      return ComicDetailsRouteKind.local;
    }
  }
  return ComicDetailsRouteKind.remote;
}

final class ComicDetailsLibrarySnapshot {
  ComicDetailsLibrarySnapshot({
    required Iterable<ImportedLibraryEntry> chapters,
    required Map<String, ChapterReadState> readStates,
    required this.preference,
    Iterable<Chapter> sourceChapters = const <Chapter>[],
  })  : chapters = List<ImportedLibraryEntry>.unmodifiable(chapters),
        sourceChapters = List<Chapter>.unmodifiable(sourceChapters),
        readStates = Map<String, ChapterReadState>.unmodifiable(readStates);

  ComicDetailsLibrarySnapshot copyWith({
    Iterable<ImportedLibraryEntry>? chapters,
    Iterable<Chapter>? sourceChapters,
    Map<String, ChapterReadState>? readStates,
    ComicPreference? preference,
  }) =>
      ComicDetailsLibrarySnapshot(
        chapters: chapters ?? this.chapters,
        sourceChapters: sourceChapters ?? this.sourceChapters,
        readStates: readStates ?? this.readStates,
        preference: preference ?? this.preference,
      );

  final List<ImportedLibraryEntry> chapters;
  final List<Chapter> sourceChapters;
  final Map<String, ChapterReadState> readStates;
  final ComicPreference preference;
}

typedef ComicDetailsCoverLoader = Future<Uint8List> Function({
  required String sourceId,
  required Uri? coverUri,
  required ImportedLibraryEntry? fallbackChapter,
});

typedef ComicDetailsLibraryReloader = Future<ComicDetailsLibrarySnapshot>
    Function({required bool refreshContent});

typedef ComicDetailsChapterEnsurer = Future<ImportedLibraryEntry> Function(
  BrowsableComicSource source,
  Comic comic,
  Chapter chapter,
);

typedef ComicDetailsChapterOpener = Future<void> Function(
  ImportedLibraryEntry chapter, {
  required bool refreshRemote,
});

typedef ComicDetailsChapterDownloader = Future<void> Function(
  ImportedLibraryEntry chapter,
);

typedef ComicDetailsChapterDownloadStatus = Future<bool> Function(
  ImportedLibraryEntry chapter,
);

typedef ComicDetailsComicPersister = Future<void> Function(
  ComicManifest manifest,
  bool retained,
);

typedef ComicDetailsMigrationOpener = Future<void> Function(
  LibraryComic comic,
);

final class LocalComicDetailsScreen extends StatefulWidget {
  const LocalComicDetailsScreen({
    required this.comic,
    required this.initialLibrary,
    required this.categories,
    required this.loadCover,
    required this.reloadLibrary,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    required this.onDownloadChapter,
    required this.isChapterDownloaded,
    this.source,
    this.ensureSourceChapter,
    this.onMigrateSource,
    super.key,
  });

  final LibraryComic comic;
  final ComicDetailsLibrarySnapshot initialLibrary;
  final List<LibraryCategory> categories;
  final ComicDetailsCoverLoader loadCover;
  final ComicDetailsLibraryReloader reloadLibrary;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final ComicDetailsChapterOpener onOpenChapter;
  final ComicDetailsChapterDownloader onDownloadChapter;
  final ComicDetailsChapterDownloadStatus isChapterDownloaded;
  final BrowsableComicSource? source;
  final ComicDetailsChapterEnsurer? ensureSourceChapter;
  final ComicDetailsMigrationOpener? onMigrateSource;

  @override
  State<LocalComicDetailsScreen> createState() =>
      _LocalComicDetailsScreenState();
}

final class _LocalComicDetailsScreenState
    extends State<LocalComicDetailsScreen> {
  late ComicDetailsLibrarySnapshot _library;
  bool _descending = true;
  bool _refreshing = false;
  final Set<String> _workingDownloads = <String>{};
  final Set<String> _downloaded = <String>{};

  @override
  void initState() {
    super.initState();
    _library = widget.initialLibrary;
    scheduleMicrotask(
      () => unawaited(_loadDownloadStatuses(_library.chapters)),
    );
  }

  Future<void> _loadDownloadStatuses(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final downloaded = <String>{};
    for (final entry in entries) {
      if (await widget.isChapterDownloaded(entry)) {
        downloaded.add(
          comicDetailsChapterIdentity(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          ),
        );
      }
    }
    if (mounted && downloaded.isNotEmpty) {
      setState(() => _downloaded.addAll(downloaded));
    }
  }

  Future<void> _refresh({required bool announce}) async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      final next = await widget.reloadLibrary(refreshContent: true);
      if (!mounted) {
        return;
      }
      setState(() => _library = next);
      unawaited(_loadDownloadStatuses(next.chapters));
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('漫画详情已更新')),
        );
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _savePreference(ComicPreference preference) async {
    final previous = _library.preference;
    setState(() => _library = _library.copyWith(preference: preference));
    try {
      await widget.onPreferenceChanged(preference);
    } on Object catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      setState(() => _library = _library.copyWith(preference: previous));
      _showFailureSnackBar(
        context,
        _DetailFailure.capture(error, stackTrace),
      );
    }
  }

  ImportedLibraryEntry? _entryFor(String sourceId, String chapterId) {
    for (final entry in _library.chapters) {
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    return null;
  }

  Future<ImportedLibraryEntry> _ensure(Chapter chapter) async {
    final existing = _entryFor(widget.comic.sourceId, chapter.chapterId);
    if (existing != null) {
      return existing;
    }
    final source = widget.source;
    final ensure = widget.ensureSourceChapter;
    if (source == null || ensure == null) {
      throw StateError('该章节尚未持久化，且对应漫画源当前不可用');
    }
    final comic = Comic(
      comicId: widget.comic.comicId,
      sourceId: widget.comic.sourceId,
      title: widget.comic.title,
      authors: widget.comic.authors,
      coverUri: widget.comic.coverSourceId == null
          ? null
          : Uri.tryParse(widget.comic.coverSourceId!),
      description: widget.comic.description,
      readingDirection: widget.comic.readingDirection,
    );
    final entry = await ensure(source, comic, chapter);
    if (mounted) {
      setState(() {
        _library = _library.copyWith(
          chapters: <ImportedLibraryEntry>[..._library.chapters, entry],
        );
      });
    }
    return entry;
  }

  Future<void> _setRead(ImportedLibraryEntry entry, bool isRead) async {
    final identity = comicDetailsChapterIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
    );
    final previous = _library.readStates;
    final next = <String, ChapterReadState>{
      ...previous,
      identity: ChapterReadState(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
        isRead: isRead,
        updatedAt: DateTime.now().toUtc(),
      ),
    };
    setState(() => _library = _library.copyWith(readStates: next));
    try {
      await widget.onReadChanged(entry, isRead);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        setState(() => _library = _library.copyWith(readStates: previous));
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    }
  }

  Future<void> _open(_ChapterViewModel chapter) async {
    try {
      final entry = chapter.entry ?? await _ensure(chapter.sourceChapter!);
      await widget.onOpenChapter(entry, refreshRemote: false);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    }
  }

  Future<void> _download(_ChapterViewModel chapter) async {
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    if (_workingDownloads.contains(identity) || _downloaded.contains(identity)) {
      return;
    }
    setState(() => _workingDownloads.add(identity));
    try {
      final entry = chapter.entry ?? await _ensure(chapter.sourceChapter!);
      await widget.onDownloadChapter(entry);
      if (mounted) {
        setState(() => _downloaded.add(identity));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${chapter.title}”已下载')),
        );
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _workingDownloads.remove(identity));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = <_ChapterViewModel>[];
    final catalogIdentities = <String>{};
    for (final chapter in _library.sourceChapters) {
      final identity = comicDetailsChapterIdentity(
        widget.comic.sourceId,
        chapter.chapterId,
      );
      catalogIdentities.add(identity);
      final entry = _entryFor(widget.comic.sourceId, chapter.chapterId);
      models.add(
        _ChapterViewModel(
          sourceId: widget.comic.sourceId,
          title: chapter.title,
          chapterId: chapter.chapterId,
          sequence: chapter.sequence,
          pageCount: chapter.pageCount,
          publishedAt: chapter.publishedAt,
          entry: entry,
          sourceChapter: chapter,
          isRead: entry == null ? false : _isRead(_library.readStates, entry),
          canDownload: widget.comic.sourceId != 'local-folder',
          downloading: _workingDownloads.contains(identity),
          downloaded: _downloaded.contains(identity),
        ),
      );
    }
    for (final entry in _library.chapters) {
      final identity = comicDetailsChapterIdentity(
        entry.chapter.sourceId,
        entry.chapter.chapterId,
      );
      if (catalogIdentities.contains(identity)) {
        continue;
      }
      models.add(
        _ChapterViewModel(
          sourceId: entry.chapter.sourceId,
          title: entry.chapter.displayName,
          chapterId: entry.chapter.chapterId,
          sequence: entry.chapter.sequence,
          pageCount: entry.chapter.pages.length,
          publishedAt: entry.chapter.importedAt,
          entry: entry,
          isRead: _isRead(_library.readStates, entry),
          canDownload: entry.chapter.sourceId != 'local-folder',
          downloading: _workingDownloads.contains(identity),
          downloaded: _downloaded.contains(identity),
        ),
      );
    }
    models.sort(_compareChapterModels);
    final ordered = _descending
        ? models.reversed.toList(growable: false)
        : models;
    final comic = widget.comic;
    final catalogPages = _library.sourceChapters.fold<int>(
      0,
      (total, chapter) => total + chapter.pageCount,
    );
    return _ComicDetailsScaffold(
      screenKey: localComicDetailsScreenKey,
      title: comic.title,
      sourceLabel: comic.sourceId == 'local-folder' ? '本地' : comic.sourceId,
      authors: comic.authors,
      description: comic.description,
      cover: _ComicDetailCover(
        sourceId: comic.sourceId,
        coverUri: comic.coverSourceId == null
            ? null
            : Uri.tryParse(comic.coverSourceId!),
        fallbackChapter: comic.coverChapter,
        loader: widget.loadCover,
      ),
      preference: _library.preference,
      categories: widget.categories,
      refreshing: _refreshing,
      descending: _descending,
      onRefresh: () => _refresh(announce: true),
      onPreferenceChanged: _savePreference,
      onReverse: () => setState(() => _descending = !_descending),
      onMigrateSource: widget.onMigrateSource == null
          ? null
          : () => widget.onMigrateSource!(comic),
      chapterCount: ordered.length,
      pageCount: catalogPages == 0 ? comic.totalPages : catalogPages,
      chapterList: _ComicChapterList(
        chapters: ordered,
        onOpen: _open,
        onDownload: _download,
        onRestoreUnread: (chapter) {
          final entry = chapter.entry;
          return entry == null ? Future<void>.value() : _setRead(entry, false);
        },
      ),
    );
  }
}

final class RemoteComicDetailsScreen extends StatefulWidget {
  const RemoteComicDetailsScreen({
    required this.source,
    required this.summary,
    required this.initialLibrary,
    required this.categories,
    required this.loadCover,
    required this.reloadLibrary,
    required this.ensureSourceChapter,
    required this.persistComic,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    required this.onDownloadChapter,
    required this.isChapterDownloaded,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary summary;
  final ComicDetailsLibrarySnapshot initialLibrary;
  final List<LibraryCategory> categories;
  final ComicDetailsCoverLoader loadCover;
  final ComicDetailsLibraryReloader reloadLibrary;
  final ComicDetailsChapterEnsurer ensureSourceChapter;
  final ComicDetailsComicPersister persistComic;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final ComicDetailsChapterOpener onOpenChapter;
  final ComicDetailsChapterDownloader onDownloadChapter;
  final ComicDetailsChapterDownloadStatus isChapterDownloaded;

  @override
  State<RemoteComicDetailsScreen> createState() =>
      _RemoteComicDetailsScreenState();
}

final class _RemoteComicDetailsScreenState
    extends State<RemoteComicDetailsScreen> {
  late ComicDetailsLibrarySnapshot _library;
  ComicManifest? _manifest;
  _DetailFailure? _failure;
  bool _refreshing = false;
  bool _descending = true;
  final Set<String> _working = <String>{};
  final Set<String> _downloaded = <String>{};

  @override
  void initState() {
    super.initState();
    _library = widget.initialLibrary;
    scheduleMicrotask(
      () => unawaited(_loadDownloadStatuses(_library.chapters)),
    );
    scheduleMicrotask(() => unawaited(_refresh(announce: false)));
  }

  Comic get _comic => _manifest?.comic ?? Comic(
        comicId: widget.summary.comicId,
        sourceId: widget.source.sourceId,
        title: widget.summary.title,
        authors: widget.summary.authors,
        coverUri: widget.summary.coverUri,
        description: widget.summary.description,
        readingDirection: ReadingDirection.ltr,
      );

  Future<void> _loadDownloadStatuses(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final downloaded = <String>{};
    for (final entry in entries) {
      if (await widget.isChapterDownloaded(entry)) {
        downloaded.add(
          comicDetailsChapterIdentity(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          ),
        );
      }
    }
    if (mounted && downloaded.isNotEmpty) {
      setState(() => _downloaded.addAll(downloaded));
    }
  }

  Future<void> _refresh({required bool announce}) async {
    if (_refreshing) {
      return;
    }
    setState(() {
      _refreshing = true;
      _failure = null;
    });
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        widget.source.loadComic(widget.summary.comicId),
        widget.reloadLibrary(refreshContent: false),
      ]);
      final manifest = results[0] as ComicManifest;
      final library = results[1] as ComicDetailsLibrarySnapshot;
      if (manifest.comic.sourceId != widget.source.sourceId ||
          manifest.comic.comicId != widget.summary.comicId ||
          manifest.chapters.any(
            (chapter) => chapter.comicId != widget.summary.comicId,
          )) {
        throw StateError('漫画源详情返回了不匹配的漫画或章节身份');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _manifest = manifest;
        _library = library.copyWith(sourceChapters: manifest.chapters);
      });
      unawaited(_loadDownloadStatuses(library.chapters));
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已更新 ${manifest.chapters.length} 个章节')),
        );
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        setState(() => _failure = _DetailFailure.capture(error, stackTrace));
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _savePreference(ComicPreference preference) async {
    final previous = _library.preference;
    setState(() {
      _library = _library.copyWith(preference: preference);
    });
    try {
      final manifest = _manifest;
      if (manifest == null) {
        throw StateError('漫画目录尚未加载完成');
      }
      await widget.persistComic(manifest, _retainsWholeComic(preference));
      await widget.onPreferenceChanged(preference);
    } on Object catch (error, stackTrace) {
      final manifest = _manifest;
      if (manifest != null) {
        try {
          await widget.persistComic(manifest, _retainsWholeComic(previous));
        } on Object {
          // Keep the original failure as the user-visible cause. Reloading the
          // library on the next route entry reconciles any partial write.
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _library = _library.copyWith(preference: previous);
      });
      _showFailureSnackBar(
        context,
        _DetailFailure.capture(error, stackTrace),
      );
    }
  }

  ImportedLibraryEntry? _localEntry(String chapterId) {
    for (final entry in _library.chapters) {
      if (entry.chapter.sourceId == widget.source.sourceId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    return null;
  }

  Future<ImportedLibraryEntry> _ensure(Chapter chapter) async {
    final existing = _localEntry(chapter.chapterId);
    if (existing != null) {
      return existing;
    }
    final manifest = _manifest;
    if (manifest != null) {
      await widget.persistComic(manifest, true);
    }
    final entry = await widget.ensureSourceChapter(
      widget.source,
      _comic,
      chapter,
    );
    if (mounted) {
      setState(() {
        _library = _library.copyWith(
          chapters: <ImportedLibraryEntry>[..._library.chapters, entry],
        );
      });
    }
    return entry;
  }

  Future<void> _open(Chapter chapter) async {
    final identity = comicDetailsChapterIdentity(
      widget.source.sourceId,
      chapter.chapterId,
    );
    if (!_working.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      final entry = await _ensure(chapter);
      await widget.onOpenChapter(entry, refreshRemote: false);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _working.remove(identity));
      }
    }
  }

  Future<void> _download(Chapter chapter) async {
    final identity = comicDetailsChapterIdentity(
      widget.source.sourceId,
      chapter.chapterId,
    );
    if (!_working.add(identity) || _downloaded.contains(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      final entry = await _ensure(chapter);
      await widget.onDownloadChapter(entry);
      if (mounted) {
        setState(() => _downloaded.add(identity));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${chapter.title}”已下载')),
        );
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _working.remove(identity));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null && _manifest == null) {
      return Scaffold(
        key: comicDetailsScreenKey,
        appBar: AppBar(title: Text(widget.summary.title)),
        body: _DetailFailurePanel(
          failure: failure,
          onRetry: () => unawaited(_refresh(announce: false)),
        ),
      );
    }
    final manifest = _manifest;
    final chapters = manifest?.chapters.toList(growable: false) ??
        const <Chapter>[];
    final sortedChapters = chapters.toList(growable: false)
      ..sort(_compareChapters);
    final ordered = _descending
        ? sortedChapters.reversed.toList(growable: false)
        : sortedChapters;
    final comic = _comic;
    return _ComicDetailsScaffold(
      screenKey: remoteComicDetailsScreenKey,
      title: comic.title,
      sourceLabel: widget.source.descriptor.name,
      authors: comic.authors,
      description: comic.description,
      cover: _ComicDetailCover(
        sourceId: widget.source.sourceId,
        coverUri: comic.coverUri,
        fallbackChapter:
            _library.chapters.isEmpty ? null : _library.chapters.first,
        loader: widget.loadCover,
      ),
      preference: _library.preference,
      categories: widget.categories,
      refreshing: _refreshing,
      descending: _descending,
      onRefresh: () => _refresh(announce: true),
      onPreferenceChanged: _savePreference,
      onReverse: () => setState(() => _descending = !_descending),
      chapterCount: ordered.length,
      pageCount: ordered.fold<int>(0, (sum, chapter) => sum + chapter.pageCount),
      chapterList: _ComicChapterList(
        chapters: <_ChapterViewModel>[
          for (final chapter in ordered)
            _ChapterViewModel(
              sourceId: widget.source.sourceId,
              title: chapter.title,
              chapterId: chapter.chapterId,
              sequence: chapter.sequence,
              pageCount: chapter.pageCount,
              publishedAt: chapter.publishedAt,
              entry: _localEntry(chapter.chapterId),
              isRead: _isReadById(
                _library.readStates,
                widget.source.sourceId,
                chapter.chapterId,
              ),
              canDownload: true,
              downloading: _working.contains(
                comicDetailsChapterIdentity(
                  widget.source.sourceId,
                  chapter.chapterId,
                ),
              ),
              downloaded: _downloaded.contains(
                comicDetailsChapterIdentity(
                  widget.source.sourceId,
                  chapter.chapterId,
                ),
              ),
              sourceChapter: chapter,
            ),
        ],
        onOpen: (chapter) => _open(chapter.sourceChapter!),
        onDownload: (chapter) => _download(chapter.sourceChapter!),
        onRestoreUnread: (chapter) async {
          final entry = chapter.entry;
          if (entry != null) {
            await widget.onReadChanged(entry, false);
          }
        },
      ),
    );
  }
}

final class _ComicDetailsScaffold extends StatelessWidget {
  const _ComicDetailsScaffold({
    required this.screenKey,
    required this.title,
    required this.sourceLabel,
    required this.authors,
    required this.description,
    required this.cover,
    required this.preference,
    required this.categories,
    required this.refreshing,
    required this.descending,
    required this.onRefresh,
    required this.onPreferenceChanged,
    required this.onReverse,
    required this.chapterCount,
    required this.pageCount,
    required this.chapterList,
    this.onMigrateSource,
  });

  final Key screenKey;
  final String title;
  final String sourceLabel;
  final List<String> authors;
  final String? description;
  final Widget cover;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final bool refreshing;
  final bool descending;
  final Future<void> Function() onRefresh;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final VoidCallback onReverse;
  final int chapterCount;
  final int pageCount;
  final Widget chapterList;
  final VoidCallback? onMigrateSource;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(
        title: Text(title),
        actions: <Widget>[
          if (onMigrateSource != null)
            IconButton(
              key: comicDetailsMigrateKey,
              tooltip: '迁移漫画源',
              onPressed: onMigrateSource,
              icon: const Icon(Icons.swap_horiz),
            ),
          IconButton(
            key: comicDetailsRefreshKey,
            tooltip: '更新详情',
            onPressed: refreshing ? null : () => unawaited(onRefresh()),
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: CustomScrollView(
          key: screenKey,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              sliver: SliverToBoxAdapter(
                child: _ComicDetailsHeader(
                  title: title,
                  sourceLabel: sourceLabel,
                  authors: authors,
                  description: description,
                  cover: cover,
                  preference: preference,
                  categories: categories,
                  onPreferenceChanged: onPreferenceChanged,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '$chapterCount 章 · $pageCount 页',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      key: comicDetailsReverseKey,
                      tooltip: descending ? '切换正序' : '切换倒序',
                      onPressed: onReverse,
                      icon: Icon(
                        descending
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(child: chapterList),
            const SliverPadding(padding: EdgeInsets.only(bottom: 36)),
          ],
        ),
      ),
    );
  }
}

final class _ComicDetailsHeader extends StatelessWidget {
  const _ComicDetailsHeader({
    required this.title,
    required this.sourceLabel,
    required this.authors,
    required this.description,
    required this.cover,
    required this.preference,
    required this.categories,
    required this.onPreferenceChanged,
  });

  final String title;
  final String sourceLabel;
  final List<String> authors;
  final String? description;
  final Widget cover;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(width: 120, height: 160, child: cover),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(sourceLabel),
                  if (authors.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(authors.join('、')),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _PreferenceButton(
                        key: comicDetailsLikedKey,
                        icon: preference.liked
                            ? Icons.favorite
                            : Icons.favorite_border,
                        label: preference.liked ? '取消喜欢' : '喜欢',
                        selected: preference.liked,
                        onPressed: () => unawaited(
                          onPreferenceChanged(
                            preference.copyWith(liked: !preference.liked),
                          ),
                        ),
                      ),
                      _PreferenceButton(
                        key: comicDetailsShelfKey,
                        icon: preference.inShelf
                            ? Icons.library_add_check
                            : Icons.library_add_outlined,
                        label: preference.inShelf ? '移出书架' : '加入书架',
                        selected: preference.inShelf,
                        onPressed: () => unawaited(
                          onPreferenceChanged(
                            preference.copyWith(inShelf: !preference.inShelf),
                          ),
                        ),
                      ),
                      _PreferenceButton(
                        key: comicDetailsCollectedKey,
                        icon: preference.collected
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                        label: preference.collected ? '取消收藏' : '收藏',
                        selected: preference.collected,
                        onPressed: () => unawaited(
                          onPreferenceChanged(
                            preference.copyWith(
                              collected: !preference.collected,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (description != null && description!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Text(description!.trim()),
        ],
        if (categories.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final category in categories)
                FilterChip(
                  label: Text(category.name),
                  showCheckmark: false,
                  selected: preference.categoryIds.contains(category.categoryId),
                  onSelected: (selected) {
                    final ids = preference.categoryIds.toSet();
                    if (selected) {
                      ids.add(category.categoryId);
                    } else {
                      ids.remove(category.categoryId);
                    }
                    unawaited(
                      onPreferenceChanged(
                        preference.copyWith(categoryIds: ids),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _ComicChapterList extends StatelessWidget {
  const _ComicChapterList({
    required this.chapters,
    required this.onOpen,
    required this.onDownload,
    required this.onRestoreUnread,
  });

  final List<_ChapterViewModel> chapters;
  final Future<void> Function(_ChapterViewModel chapter) onOpen;
  final Future<void> Function(_ChapterViewModel chapter) onDownload;
  final Future<void> Function(_ChapterViewModel chapter) onRestoreUnread;

  @override
  Widget build(BuildContext context) {
    if (chapters.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('暂无章节')),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: chapters.length,
      itemBuilder: (context, index) {
        final chapter = chapters[index];
        final subtitle = <String>[
          '${chapter.pageCount} 页',
          if (chapter.publishedAt != null)
            chapter.publishedAt!.toLocal().toString().split(' ').first,
        ].join(' · ');
        return Dismissible(
          key: comicDetailsReadKey(
            chapter.sourceId,
            chapter.chapterId,
          ),
          direction: chapter.isRead
              ? DismissDirection.startToEnd
              : DismissDirection.none,
          dismissThresholds: const <DismissDirection, double>{
            DismissDirection.startToEnd: 0.18,
          },
          confirmDismiss: (_) async {
            await onRestoreUnread(chapter);
            return false;
          },
          background: Container(
            color: Theme.of(context).colorScheme.primaryContainer,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: const Row(
              children: <Widget>[
                Icon(Icons.mark_chat_unread_outlined),
                SizedBox(width: 8),
                Text('恢复未读'),
              ],
            ),
          ),
          child: AnimatedOpacity(
            opacity: chapter.isRead ? 0.42 : 1,
            duration: const Duration(milliseconds: 180),
            child: ListTile(
              key: comicDetailsChapterKey(
                chapter.sourceId,
                chapter.chapterId,
              ),
              leading: Icon(
                chapter.isRead
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
              ),
              title: Text(chapter.title),
              subtitle: Text(subtitle),
              onTap: chapter.downloading
                  ? null
                  : () => unawaited(onOpen(chapter)),
              trailing: chapter.canDownload
                  ? IconButton(
                      key: comicDetailsDownloadKey(
                        chapter.sourceId,
                        chapter.chapterId,
                      ),
                      tooltip: chapter.downloaded ? '章节已下载' : '下载章节',
                      onPressed: chapter.downloading || chapter.downloaded
                          ? null
                          : () => unawaited(onDownload(chapter)),
                      icon: chapter.downloading
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              chapter.downloaded
                                  ? Icons.download_done
                                  : Icons.download_outlined,
                            ),
                    )
                  : const Icon(Icons.chevron_right),
            ),
          ),
        );
      },
    );
  }
}

final class _ChapterViewModel {
  const _ChapterViewModel({
    required this.sourceId,
    required this.title,
    required this.chapterId,
    required this.sequence,
    required this.pageCount,
    required this.publishedAt,
    required this.entry,
    required this.isRead,
    required this.canDownload,
    required this.downloading,
    required this.downloaded,
    this.sourceChapter,
  });

  final String sourceId;
  final String title;
  final String chapterId;
  final int sequence;
  final int pageCount;
  final DateTime? publishedAt;
  final ImportedLibraryEntry? entry;
  final bool isRead;
  final bool canDownload;
  final bool downloading;
  final bool downloaded;
  final Chapter? sourceChapter;
}

final class _PreferenceButton extends StatelessWidget {
  const _PreferenceButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: label,
      isSelected: selected,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

final class _ComicDetailCover extends StatefulWidget {
  const _ComicDetailCover({
    required this.sourceId,
    required this.coverUri,
    required this.fallbackChapter,
    required this.loader,
  });

  final String sourceId;
  final Uri? coverUri;
  final ImportedLibraryEntry? fallbackChapter;
  final ComicDetailsCoverLoader loader;

  @override
  State<_ComicDetailCover> createState() => _ComicDetailCoverState();
}

final class _ComicDetailCoverState extends State<_ComicDetailCover> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _ComicDetailCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId ||
        oldWidget.coverUri != widget.coverUri ||
        oldWidget.fallbackChapter?.chapter.chapterId !=
            widget.fallbackChapter?.chapter.chapterId) {
      _bytes = _load();
    }
  }

  Future<Uint8List> _load() => widget.loader(
        sourceId: widget.sourceId,
        coverUri: widget.coverUri,
        fallbackChapter: widget.fallbackChapter,
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const _CoverPlaceholder(),
          );
        }
        if (snapshot.hasError) {
          return const _CoverPlaceholder();
        }
        return const ColoredBox(
          color: Color(0x14000000),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }
}

final class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.image_not_supported_outlined)),
    );
  }
}

final class _DetailFailure {
  const _DetailFailure({required this.summary, required this.details});

  factory _DetailFailure.capture(Object error, StackTrace stackTrace) {
    final lines = <String>[error.toString()];
    if (error is Failure && error.cause != null) {
      lines.add('Cause: ${error.cause}');
    }
    final stack = stackTrace.toString().trim();
    if (stack.isNotEmpty) {
      lines.add(stack);
    }
    return _DetailFailure(
      summary: error is Failure ? error.message : error.toString(),
      details: lines.join('\n\n'),
    );
  }

  final String summary;
  final String details;
}

final class _DetailFailurePanel extends StatelessWidget {
  const _DetailFailurePanel({
    required this.failure,
    required this.onRetry,
  });

  final _DetailFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: comicDetailsErrorKey,
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        const Icon(Icons.cloud_off_outlined, size: 40),
        const SizedBox(height: 12),
        Text(
          '漫画详情加载失败',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(failure.summary, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        SelectableText(failure.details),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            OutlinedButton.icon(
              key: comicDetailsCopyErrorKey,
              onPressed: () => unawaited(_copyFailure(context, failure)),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制完整错误'),
            ),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ],
    );
  }
}


bool _retainsWholeComic(ComicPreference preference) =>
    preference.inShelf ||
    preference.liked ||
    preference.collected ||
    preference.categoryIds.isNotEmpty;

bool _isRead(
  Map<String, ChapterReadState> states,
  ImportedLibraryEntry entry,
) =>
    _isReadById(
      states,
      entry.chapter.sourceId,
      entry.chapter.chapterId,
    );

bool _isReadById(
  Map<String, ChapterReadState> states,
  String sourceId,
  String chapterId,
) =>
    (states[comicDetailsChapterIdentity(sourceId, chapterId)] ??
            states[chapterId])
        ?.isRead ??
    false;

int _compareChapterModels(
  _ChapterViewModel left,
  _ChapterViewModel right,
) {
  final sequence = left.sequence.compareTo(right.sequence);
  if (sequence != 0) {
    return sequence;
  }
  return left.chapterId.compareTo(right.chapterId);
}

int _compareLibraryEntries(
  ImportedLibraryEntry left,
  ImportedLibraryEntry right,
) {
  final sequence = left.chapter.sequence.compareTo(right.chapter.sequence);
  if (sequence != 0) {
    return sequence;
  }
  return left.chapter.chapterId.compareTo(right.chapter.chapterId);
}

int _compareChapters(Chapter left, Chapter right) {
  final sequence = left.sequence.compareTo(right.sequence);
  if (sequence != 0) {
    return sequence;
  }
  return left.chapterId.compareTo(right.chapterId);
}

void _showFailureSnackBar(BuildContext context, _DetailFailure failure) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(failure.summary, maxLines: 3),
      action: SnackBarAction(
        label: '复制',
        onPressed: () => unawaited(_copyFailure(context, failure)),
      ),
    ),
  );
}

Future<void> _copyFailure(
  BuildContext context,
  _DetailFailure failure,
) async {
  await Clipboard.setData(ClipboardData(text: failure.details));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('完整错误已复制')),
    );
  }
}
