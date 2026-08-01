import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'package:downloads/downloads.dart';

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
const comicDetailsDownloadAllKey =
    ValueKey<String>('comic-details-download-all');
const comicDetailsRetryKey = ValueKey<String>('comic-details-retry');
const comicDetailsRetryBodyKey =
    ValueKey<String>('comic-details-retry-body');
const comicDetailsPullRefreshKey =
    ValueKey<String>('comic-details-pull-refresh');

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

typedef ComicDetailsCoverLoader = Future<EncodedResourceSource> Function({
  required String sourceId,
  required String comicId,
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

typedef ComicDetailsChapterDownloadInspector =
    Future<ChapterDownloadSnapshot> Function(ImportedLibraryEntry chapter);

typedef ComicDetailsComicDownloader = Future<void> Function(
  Iterable<ImportedLibraryEntry> chapters,
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
    required this.inspectChapterDownload,
    required this.downloadChanges,
    required this.onDownloadComic,
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
  final ComicDetailsChapterDownloadInspector inspectChapterDownload;
  final Stream<ChapterDownloadSnapshot> downloadChanges;
  final ComicDetailsComicDownloader onDownloadComic;
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
  final Set<String> _opening = <String>{};
  final Set<String> _workingDownloads = <String>{};
  final Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  bool _downloadingComic = false;
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};

  @override
  void initState() {
    super.initState();
    _library = widget.initialLibrary;
    _downloadSubscription =
        widget.downloadChanges.listen(_acceptDownloadSnapshot);
    scheduleMicrotask(
      () => unawaited(_loadDownloadStatuses(_library.chapters)),
    );
  }

  @override
  void dispose() {
    unawaited(_downloadSubscription?.cancel());
    super.dispose();
  }

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted ||
        snapshot.sourceId != widget.comic.sourceId ||
        snapshot.comicId != widget.comic.comicId) {
      return;
    }
    setState(() {
      _downloadSnapshots[comicDetailsChapterIdentity(
        snapshot.sourceId,
        snapshot.chapterId,
      )] = snapshot;
    });
  }

  Future<void> _loadDownloadStatuses(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    final snapshots = <String, ChapterDownloadSnapshot>{};
    for (final entry in entries) {
      try {
        final snapshot = await widget.inspectChapterDownload(entry);
        snapshots[comicDetailsChapterIdentity(
          snapshot.sourceId,
          snapshot.chapterId,
        )] = snapshot;
      } on Object {
        // A stale download record must not prevent the details page opening.
      }
    }
    if (mounted && snapshots.isNotEmpty) {
      setState(() => _downloadSnapshots.addAll(snapshots));
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
    final identity = comicDetailsChapterIdentity(
      widget.comic.sourceId,
      chapter.chapterId,
    );
    final inFlight = _ensureInFlight[identity];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _ensureFresh(chapter);
    _ensureInFlight[identity] = future;
    try {
      return await future;
    } finally {
      _ensureInFlight.remove(identity);
    }
  }

  Future<ImportedLibraryEntry> _ensureFresh(Chapter chapter) async {
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
      unawaited(_loadDownloadStatuses(<ImportedLibraryEntry>[entry]));
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
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    if (!_opening.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      final entry = chapter.entry ?? await _ensure(chapter.sourceChapter!);
      if (!_isRead(_library.readStates, entry)) {
        await _setRead(entry, true);
      }
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
        setState(() {
          _opening.remove(identity);
        });
      }
    }
  }

  Future<void> _download(_ChapterViewModel chapter) async {
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    final current = _downloadSnapshots[identity];
    if (_workingDownloads.contains(identity) ||
        current?.isActive == true ||
        current?.isComplete == true) {
      return;
    }
    setState(() => _workingDownloads.add(identity));
    try {
      final entry = chapter.entry ?? await _ensure(chapter.sourceChapter!);
      await widget.onDownloadChapter(entry);
      final snapshot = await widget.inspectChapterDownload(entry);
      if (mounted) {
        _acceptDownloadSnapshot(snapshot);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('章节“${chapter.title}”已下载')),
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
        setState(() {
          _workingDownloads.remove(identity);
        });
      }
    }
  }

  Future<void> _downloadComic() async {
    if (_downloadingComic) {
      return;
    }
    setState(() => _downloadingComic = true);
    try {
      final entries = <ImportedLibraryEntry>[];
      final seen = <String>{};
      for (final chapter in _library.sourceChapters) {
        final entry = await _ensure(chapter);
        if (seen.add(entry.identity)) {
          entries.add(entry);
        }
      }
      for (final entry in _library.chapters) {
        if (seen.add(entry.identity)) {
          entries.add(entry);
        }
      }
      if (entries.isEmpty) {
        throw StateError('没有可下载的章节');
      }
      await widget.onDownloadComic(entries);
      await _loadDownloadStatuses(entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${widget.comic.title}”已加入整本下载队列')),
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
        setState(() => _downloadingComic = false);
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
          opening: _opening.contains(identity),
          downloading: _workingDownloads.contains(identity) ||
              _downloadSnapshots[identity]?.isActive == true,
          downloaded: _downloadSnapshots[identity]?.isComplete == true,
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
          opening: _opening.contains(identity),
          downloading: _workingDownloads.contains(identity) ||
              _downloadSnapshots[identity]?.isActive == true,
          downloaded: _downloadSnapshots[identity]?.isComplete == true,
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
        comicId: comic.comicId,
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
      progressLabel: _readingProgressLabel(_library.chapters),
      downloadingComic: _downloadingComic,
      onDownloadComic:
          comic.sourceId == 'local-folder' ? null : _downloadComic,
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
    required this.inspectChapterDownload,
    required this.downloadChanges,
    required this.onDownloadComic,
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
  final ComicDetailsChapterDownloadInspector inspectChapterDownload;
  final Stream<ChapterDownloadSnapshot> downloadChanges;
  final ComicDetailsComicDownloader onDownloadComic;

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
  final Set<String> _opening = <String>{};
  final Set<String> _workingDownloads = <String>{};
  final Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  bool _downloadingComic = false;
  int _pageCountPreflightGeneration = 0;
  Future<void>? _pageCountPreflightRun;
  final Set<String> _pageCountPreflighting = <String>{};
  final Set<String> _pageCountPreflightFailed = <String>{};
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};

  @override
  void initState() {
    super.initState();
    _library = widget.initialLibrary;
    _downloadSubscription =
        widget.downloadChanges.listen(_acceptDownloadSnapshot);
    scheduleMicrotask(
      () => unawaited(_loadDownloadStatuses(_library.chapters)),
    );
    scheduleMicrotask(() => unawaited(_refresh(announce: false)));
  }

  @override
  void dispose() {
    _pageCountPreflightGeneration++;
    unawaited(_downloadSubscription?.cancel());
    super.dispose();
  }

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted ||
        snapshot.sourceId != widget.source.sourceId ||
        snapshot.comicId != widget.summary.comicId) {
      return;
    }
    setState(() {
      _downloadSnapshots[comicDetailsChapterIdentity(
        snapshot.sourceId,
        snapshot.chapterId,
      )] = snapshot;
    });
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
    final snapshots = <String, ChapterDownloadSnapshot>{};
    for (final entry in entries) {
      try {
        final snapshot = await widget.inspectChapterDownload(entry);
        snapshots[comicDetailsChapterIdentity(
          snapshot.sourceId,
          snapshot.chapterId,
        )] = snapshot;
      } on Object {
        // A stale download record must not prevent the details page opening.
      }
    }
    if (mounted && snapshots.isNotEmpty) {
      setState(() => _downloadSnapshots.addAll(snapshots));
    }
  }

  Future<void> _refresh({
    required bool announce,
    bool forceRefresh = false,
  }) async {
    if (_refreshing) {
      return;
    }
    setState(() {
      _refreshing = true;
      _failure = null;
    });
    try {
      if (forceRefresh) {
        invalidateCachedComic(widget.source, widget.summary.comicId);
      }
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
      _startPageCountPreflight(manifest);
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

  void _startPageCountPreflight(ComicManifest manifest) {
    final generation = ++_pageCountPreflightGeneration;
    _pageCountPreflighting.clear();
    _pageCountPreflightFailed.clear();
    if (!widget.source.sourceId.startsWith('mihon:')) {
      return;
    }
    final pending = manifest.chapters
        .where((chapter) => chapter.pageCount == 0)
        .toList(growable: false);
    if (pending.isEmpty) {
      return;
    }
    setState(() {
      _pageCountPreflighting.addAll(
        pending.map((chapter) => chapter.chapterId),
      );
    });
    _queuePageCountPreflight(pending, generation);
  }

  void _queuePageCountPreflight(
    List<Chapter> chapters,
    int generation,
  ) {
    final previous = _pageCountPreflightRun;
    late final Future<void> run;
    run = Future<void>.sync(() async {
      if (previous != null) {
        await previous;
      }
      if (!mounted || generation != _pageCountPreflightGeneration) {
        return;
      }
      await _preflightPageCounts(chapters, generation);
    });
    _pageCountPreflightRun = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_pageCountPreflightRun, run)) {
          _pageCountPreflightRun = null;
        }
      }),
    );
  }

  Future<void> _preflightPageCounts(
    List<Chapter> chapters,
    int generation,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (generation == _pageCountPreflightGeneration) {
        final index = next++;
        if (index >= chapters.length) return;
        final chapter = chapters[index];
        try {
          final loaded = await widget.source.loadChapter(chapter.chapterId);
          if (generation != _pageCountPreflightGeneration) return;
          _finishPageCountPreflight(
            chapter.chapterId,
            loaded.pages.length,
            generation,
          );
        } on Object {
          if (generation != _pageCountPreflightGeneration) return;
          _finishPageCountPreflight(chapter.chapterId, null, generation);
        }
      }
    }

    final workers = chapters.length < 2 ? chapters.length : 2;
    await Future.wait<void>(
      List<Future<void>>.generate(workers, (_) => worker()),
    );
  }

  void _finishPageCountPreflight(
    String chapterId,
    int? pageCount,
    int generation,
  ) {
    if (!mounted || generation != _pageCountPreflightGeneration) return;
    setState(() {
      _pageCountPreflighting.remove(chapterId);
      if (pageCount == null || pageCount <= 0) {
        _pageCountPreflightFailed.add(chapterId);
        return;
      }
      _pageCountPreflightFailed.remove(chapterId);
      final manifest = _manifest;
      if (manifest == null) return;
      final chapters = <Chapter>[
        for (final chapter in manifest.chapters)
          if (chapter.chapterId == chapterId)
            Chapter(
              chapterId: chapter.chapterId,
              comicId: chapter.comicId,
              title: chapter.title,
              sequence: chapter.sequence,
              pageCount: pageCount,
              sourceRevision: chapter.sourceRevision,
              publishedAt: chapter.publishedAt,
            )
          else
            chapter,
      ];
      _manifest = ComicManifest(comic: manifest.comic, chapters: chapters);
      _library = _library.copyWith(sourceChapters: chapters);
    });
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
    final identity = comicDetailsChapterIdentity(
      widget.source.sourceId,
      chapter.chapterId,
    );
    final inFlight = _ensureInFlight[identity];
    if (inFlight != null) {
      return inFlight;
    }
    final future = _ensureFresh(chapter);
    _ensureInFlight[identity] = future;
    try {
      return await future;
    } finally {
      _ensureInFlight.remove(identity);
    }
  }

  Future<ImportedLibraryEntry> _ensureFresh(Chapter chapter) async {
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
      unawaited(_loadDownloadStatuses(<ImportedLibraryEntry>[entry]));
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
    if (mounted) {
      setState(() => _library = _library.copyWith(readStates: next));
    }
    try {
      await widget.onReadChanged(entry, isRead);
    } on Object {
      if (mounted) {
        setState(() => _library = _library.copyWith(readStates: previous));
      }
      rethrow;
    }
  }

  Future<void> _open(Chapter chapter) async {
    final identity = comicDetailsChapterIdentity(
      widget.source.sourceId,
      chapter.chapterId,
    );
    if (!_opening.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      final entry = await _ensure(chapter);
      if (!_isRead(_library.readStates, entry)) {
        await _setRead(entry, true);
      }
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
        setState(() {
          _opening.remove(identity);
        });
      }
    }
  }

  Future<void> _download(Chapter chapter) async {
    final identity = comicDetailsChapterIdentity(
      widget.source.sourceId,
      chapter.chapterId,
    );
    final current = _downloadSnapshots[identity];
    if (current?.isActive == true ||
        current?.isComplete == true ||
        !_workingDownloads.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      final entry = await _ensure(chapter);
      await widget.onDownloadChapter(entry);
      final snapshot = await widget.inspectChapterDownload(entry);
      if (mounted) {
        _acceptDownloadSnapshot(snapshot);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('章节“${chapter.title}”已下载')),
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
        setState(() {
          _workingDownloads.remove(identity);
        });
      }
    }
  }

  Future<void> _downloadComic() async {
    if (_downloadingComic) {
      return;
    }
    final manifest = _manifest;
    if (manifest == null) {
      return;
    }
    setState(() => _downloadingComic = true);
    try {
      final entries = <ImportedLibraryEntry>[];
      for (final chapter in manifest.chapters) {
        entries.add(await _ensure(chapter));
      }
      if (entries.isEmpty) {
        throw StateError('没有可下载的章节');
      }
      await widget.onDownloadComic(entries);
      await _loadDownloadStatuses(entries);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${_comic.title}”已加入整本下载队列')),
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
        setState(() => _downloadingComic = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null && _manifest == null) {
      return Scaffold(
        key: comicDetailsScreenKey,
        appBar: AppBar(
          title: Text(widget.source.descriptor.name),
          actions: <Widget>[
            IconButton(
              key: comicDetailsRetryKey,
              tooltip: '重试加载漫画详情',
              onPressed: _refreshing
                  ? null
                  : () => unawaited(
                        _refresh(announce: false, forceRefresh: true),
                      ),
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _DetailFailurePanel(
          failure: failure,
          onRetry: () => unawaited(
            _refresh(announce: false, forceRefresh: true),
          ),
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
        comicId: comic.comicId,
        coverUri: comic.coverUri,
        fallbackChapter:
            _library.chapters.isEmpty ? null : _library.chapters.first,
        loader: widget.loadCover,
      ),
      preference: _library.preference,
      categories: widget.categories,
      refreshing: _refreshing,
      descending: _descending,
      onRefresh: () => _refresh(announce: true, forceRefresh: true),
      onPreferenceChanged: _savePreference,
      progressLabel: _readingProgressLabel(_library.chapters),
      downloadingComic: _downloadingComic,
      onDownloadComic: _downloadComic,
      onReverse: () => setState(() => _descending = !_descending),
      chapterCount: ordered.length,
      pageCount: ordered.fold<int>(0, (sum, chapter) => sum + chapter.pageCount),
      pageCountPending: ordered.any((chapter) => chapter.pageCount == 0),
      chapterList: _ComicChapterList(
        chapters: <_ChapterViewModel>[
          for (final chapter in ordered)
            _ChapterViewModel(
              sourceId: widget.source.sourceId,
              title: chapter.title,
              chapterId: chapter.chapterId,
              sequence: chapter.sequence,
              pageCount: chapter.pageCount,
              pageCountLoading:
                  _pageCountPreflighting.contains(chapter.chapterId),
              pageCountFailed:
                  _pageCountPreflightFailed.contains(chapter.chapterId),
              publishedAt: chapter.publishedAt,
              entry: _localEntry(chapter.chapterId),
              isRead: _isReadById(
                _library.readStates,
                widget.source.sourceId,
                chapter.chapterId,
              ),
              canDownload: true,
              opening: _opening.contains(
                comicDetailsChapterIdentity(
                  widget.source.sourceId,
                  chapter.chapterId,
                ),
              ),
              downloading: _workingDownloads.contains(
                    comicDetailsChapterIdentity(
                      widget.source.sourceId,
                      chapter.chapterId,
                    ),
                  ) ||
                  _downloadSnapshots[comicDetailsChapterIdentity(
                        widget.source.sourceId,
                        chapter.chapterId,
                      )]?.isActive ==
                      true,
              downloaded: _downloadSnapshots[comicDetailsChapterIdentity(
                    widget.source.sourceId,
                    chapter.chapterId,
                  )]?.isComplete ==
                  true,
              sourceChapter: chapter,
            ),
        ],
        onOpen: (chapter) => _open(chapter.sourceChapter!),
        onDownload: (chapter) => _download(chapter.sourceChapter!),
        onRestoreUnread: (chapter) async {
          final entry = chapter.entry;
          if (entry != null) {
            await _setRead(entry, false);
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
    required this.progressLabel,
    required this.downloadingComic,
    required this.onDownloadComic,
    required this.onReverse,
    required this.chapterCount,
    required this.pageCount,
    this.pageCountPending = false,
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
  final String? progressLabel;
  final bool downloadingComic;
  final Future<void> Function()? onDownloadComic;
  final VoidCallback onReverse;
  final int chapterCount;
  final int pageCount;
  final bool pageCountPending;
  final Widget chapterList;
  final VoidCallback? onMigrateSource;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: comicDetailsScreenKey,
      appBar: AppBar(
        title: Text(sourceLabel),
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
        key: comicDetailsPullRefreshKey,
        triggerMode: RefreshIndicatorTriggerMode.anywhere,
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
                  progressLabel: progressLabel,
                  downloadingComic: downloadingComic,
                  onDownloadComic: onDownloadComic,
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
                        pageCountPending
                            ? pageCount == 0
                                ? '$chapterCount 章 · 页数待加载'
                                : '$chapterCount 章 · 已知 $pageCount 页'
                            : '$chapterCount 章 · $pageCount 页',
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
    required this.progressLabel,
    required this.downloadingComic,
    required this.onDownloadComic,
  });

  final String title;
  final String sourceLabel;
  final List<String> authors;
  final String? description;
  final Widget cover;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final String? progressLabel;
  final bool downloadingComic;
  final Future<void> Function()? onDownloadComic;

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
                      if (onDownloadComic != null)
                        FilledButton.tonalIcon(
                          key: comicDetailsDownloadAllKey,
                          onPressed: downloadingComic
                              ? null
                              : () => unawaited(onDownloadComic!()),
                          icon: downloadingComic
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.download_for_offline_outlined,
                                ),
                          label: const Text('下载整本'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (progressLabel != null) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              const Icon(Icons.history, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(progressLabel!)),
            ],
          ),
        ],
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
        final pageLabel = chapter.pageCount > 0
            ? '${chapter.pageCount} 页'
            : chapter.pageCountLoading
                ? '正在加载页数'
                : chapter.pageCountFailed
                    ? '页数加载失败'
                    : '页数待加载';
        final subtitle = <String>[
          pageLabel,
          if (chapter.publishedAt != null)
            chapter.publishedAt!.toLocal().toString().split(' ').first,
        ].join(' · ');
        return _ReadSwipeAction(
          key: comicDetailsReadKey(chapter.sourceId, chapter.chapterId),
          enabled: chapter.isRead,
          onTriggered: () => onRestoreUnread(chapter),
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
              onTap: chapter.opening
                  ? null
                  : () => unawaited(onOpen(chapter)),
              trailing: chapter.canDownload
                  ? IconButton(
                      key: comicDetailsDownloadKey(
                        chapter.sourceId,
                        chapter.chapterId,
                      ),
                      tooltip: chapter.downloaded ? '${chapter.title} 已下载' : '下载 ${chapter.title}',
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
    this.pageCountLoading = false,
    this.pageCountFailed = false,
    required this.publishedAt,
    required this.entry,
    required this.isRead,
    required this.canDownload,
    required this.opening,
    required this.downloading,
    required this.downloaded,
    this.sourceChapter,
  });

  final String sourceId;
  final String title;
  final String chapterId;
  final int sequence;
  final int pageCount;
  final bool pageCountLoading;
  final bool pageCountFailed;
  final DateTime? publishedAt;
  final ImportedLibraryEntry? entry;
  final bool isRead;
  final bool canDownload;
  final bool opening;
  final bool downloading;
  final bool downloaded;
  final Chapter? sourceChapter;
}

final class _ReadSwipeAction extends StatefulWidget {
  const _ReadSwipeAction({
    required this.enabled,
    required this.onTriggered,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Future<void> Function() onTriggered;
  final Widget child;

  @override
  State<_ReadSwipeAction> createState() => _ReadSwipeActionState();
}

final class _ReadSwipeActionState extends State<_ReadSwipeAction> {
  double _offset = 0;
  bool _dragging = false;
  bool _triggering = false;

  @override
  void didUpdateWidget(covariant _ReadSwipeAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _offset = 0;
      _dragging = false;
    }
  }

  void _update(DragUpdateDetails details, double maxOffset) {
    if (!widget.enabled || _triggering) {
      return;
    }
    final next = (_offset + details.delta.dx).clamp(0, maxOffset).toDouble();
    if (next == _offset) {
      return;
    }
    setState(() {
      _dragging = true;
      _offset = next;
    });
  }

  Future<void> _end(double threshold) async {
    if (!widget.enabled || _triggering) {
      return;
    }
    final shouldTrigger = _offset >= threshold;
    setState(() {
      _dragging = false;
      _offset = 0;
      _triggering = shouldTrigger;
    });
    if (!shouldTrigger) {
      return;
    }
    try {
      await widget.onTriggered();
    } finally {
      if (mounted) {
        setState(() => _triggering = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final threshold = (constraints.maxWidth * 0.18).clamp(56, 96).toDouble();
        final maxOffset = (constraints.maxWidth * 0.36).clamp(96, 160).toDouble();
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.mark_chat_unread_outlined),
                        SizedBox(width: 8),
                        Text('恢复未读'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: widget.enabled
                  ? (details) => _update(details, maxOffset)
                  : null,
              onHorizontalDragEnd:
                  widget.enabled ? (_) => unawaited(_end(threshold)) : null,
              onHorizontalDragCancel: widget.enabled
                  ? () {
                      setState(() {
                        _dragging = false;
                        _offset = 0;
                      });
                    }
                  : null,
              child: AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(_offset, 0, 0),
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: widget.child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String? _readingProgressLabel(Iterable<ImportedLibraryEntry> entries) {
  ImportedLibraryEntry? latest;
  for (final entry in entries) {
    final progress = entry.progress;
    if (progress == null) {
      continue;
    }
    final current = latest?.progress;
    if (current == null || progress.updatedAt.isAfter(current.updatedAt)) {
      latest = entry;
    }
  }
  final entry = latest;
  final progress = entry?.progress;
  if (entry == null || progress == null) {
    return null;
  }
  return '阅读到 ${entry.chapter.displayName} · 第 ${progress.pageIndex + 1} 页';
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
    required this.comicId,
    required this.coverUri,
    required this.fallbackChapter,
    required this.loader,
  });

  final String sourceId;
  final String comicId;
  final Uri? coverUri;
  final ImportedLibraryEntry? fallbackChapter;
  final ComicDetailsCoverLoader loader;

  @override
  State<_ComicDetailCover> createState() => _ComicDetailCoverState();
}

final class _ComicDetailCoverState extends State<_ComicDetailCover> {
  late Future<EncodedResourceSource> _source;

  @override
  void initState() {
    super.initState();
    _source = _load();
  }

  @override
  void didUpdateWidget(covariant _ComicDetailCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId ||
        oldWidget.comicId != widget.comicId ||
        oldWidget.coverUri != widget.coverUri ||
        oldWidget.fallbackChapter?.chapter.chapterId !=
            widget.fallbackChapter?.chapter.chapterId) {
      _source = _load();
    }
  }

  Future<EncodedResourceSource> _load() =>
      Future<EncodedResourceSource>.sync(
        () => widget.loader(
          sourceId: widget.sourceId,
          comicId: widget.comicId,
          coverUri: widget.coverUri,
          fallbackChapter: widget.fallbackChapter,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EncodedResourceSource>(
      future: _source,
      builder: (context, snapshot) {
        final source = snapshot.data;
        if (source != null) {
          return Image(
            image: encodedResourceImageProvider(source),
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
              key: comicDetailsRetryBodyKey,
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
