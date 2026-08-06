import 'dart:async';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'package:downloads/downloads.dart';
import 'artwork_placeholder.dart';
import 'dialog_actions.dart';

part 'comic_details_interactions.dart';
part 'comic_details_extras.dart';

const comicDetailsScreenKey = ValueKey<String>('comic-details-screen');
const localComicDetailsScreenKey =
    ValueKey<String>('local-comic-details-screen');
const remoteComicDetailsScreenKey =
    ValueKey<String>('remote-comic-details-screen');
const comicDetailsReverseKey = ValueKey<String>('comic-details-reverse');
const comicDetailsErrorKey = ValueKey<String>('comic-details-error');
const comicDetailsCopyErrorKey =
    ValueKey<String>('comic-details-copy-error');
const comicDetailsShelfKey = ValueKey<String>('comic-details-shelf');
const comicDetailsCollectedKey =
    ValueKey<String>('comic-details-collected');
const comicDetailsLikedKey = ValueKey<String>('comic-details-liked');
const comicDetailsMigrateKey = ValueKey<String>('comic-details-migrate');
const comicDetailsVersionsKey = ValueKey<String>('comic-details-versions');
const comicDetailsContinueReadingKey =
    ValueKey<String>('comic-details-continue-reading');
const comicDetailsReadingHistoryKey =
    ValueKey<String>('comic-details-reading-history');
const comicDetailsChapterCountKey =
    ValueKey<String>('comic-details-chapter-count');
const comicDetailsChapterListKey =
    ValueKey<String>('comic-details-chapter-list');
const comicDetailsDownloadAllKey =
    ValueKey<String>('comic-details-download-all');
const comicDetailsOpenWebViewKey =
    ValueKey<String>('comic-details-open-webview');
const comicDetailsSourceSettingsKey =
    ValueKey<String>('comic-details-source-settings');
const comicDetailsRefreshStateKey =
    ValueKey<String>('comic-details-refresh-state');
const comicDetailsRetryBodyKey =
    ValueKey<String>('comic-details-retry-body');
const comicDetailsPullRefreshKey =
    ValueKey<String>('comic-details-pull-refresh');
const comicDetailsPreviewKey = ValueKey<String>('comic-details-preview');
const comicDetailsCommentsKey = ValueKey<String>('comic-details-comments');
const comicDetailsCommentsPageKey =
    ValueKey<String>('comic-details-comments-page');

Key comicDetailsPreviewItemKey(int index) =>
    ValueKey<String>('comic-details-preview-item:$index');

String comicDetailsChapterIdentity(String sourceId, String chapterId) =>
    '$sourceId\u0000$chapterId';

Key comicDetailsChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

Key comicDetailsReadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-read:$sourceId\u0000$chapterId');

Key comicDetailsDownloadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-download:$sourceId\u0000$chapterId');

final class ComicDetailsLibrarySnapshot {
  ComicDetailsLibrarySnapshot({
    required Iterable<ImportedLibraryEntry> chapters,
    required Map<String, ChapterReadState> readStates,
    required this.preference,
    this.sourceComic,
    this.sourceManifest,
    Iterable<Chapter> sourceChapters = const <Chapter>[],
  })  : chapters = List<ImportedLibraryEntry>.unmodifiable(chapters),
        sourceChapters = List<Chapter>.unmodifiable(sourceChapters),
        readStates = Map<String, ChapterReadState>.unmodifiable(readStates);

  ComicDetailsLibrarySnapshot copyWith({
    Iterable<ImportedLibraryEntry>? chapters,
    Iterable<Chapter>? sourceChapters,
    Map<String, ChapterReadState>? readStates,
    ComicPreference? preference,
    Comic? sourceComic,
    ComicManifest? sourceManifest,
  }) =>
      ComicDetailsLibrarySnapshot(
        chapters: chapters ?? this.chapters,
        sourceChapters: sourceChapters ?? this.sourceChapters,
        readStates: readStates ?? this.readStates,
        preference: preference ?? this.preference,
        sourceComic: sourceComic ?? this.sourceComic,
        sourceManifest: sourceManifest ?? this.sourceManifest,
      );

  final List<ImportedLibraryEntry> chapters;
  final List<Chapter> sourceChapters;
  final Map<String, ChapterReadState> readStates;
  final ComicPreference preference;
  final Comic? sourceComic;
  final ComicManifest? sourceManifest;
}

typedef ComicDetailsCoverLoader = Future<EncodedResourceSource> Function({
  required String sourceId,
  required String comicId,
  required Uri? coverUri,
  required ImportedLibraryEntry? fallbackChapter,
  String resourceRole,
});

typedef ComicDetailsLibraryReloader = Future<ComicDetailsLibrarySnapshot>
    Function({required bool refreshContent});

typedef ComicDetailsPreviewLoader = Future<ComicPreviewPage> Function(
  String? nextToken,
);

typedef ComicDetailsPreviewOpener = Future<void> Function(int pageIndex);

typedef ComicDetailsCommentsLoader = Future<ComicCommentPage> Function({
  required int page,
  String? replyTo,
});

typedef ComicDetailsChapterEnsurer = Future<ImportedLibraryEntry> Function(
  BrowsableComicSource source,
  Comic comic,
  Chapter chapter,
);

typedef ComicDetailsChapterLoader = Future<ImportedLibraryEntry> Function();

typedef ComicDetailsChapterOpener = Future<void> Function(
  ComicDetailsChapterLoader loadChapter, {
  required bool refreshRemote,
  required String title,
  int? initialPageIndex,
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
typedef ComicDetailsVersionsOpener = Future<void> Function();

typedef ComicDetailsSourceWebViewOpener = Future<void> Function();
typedef ComicDetailsSourceSettingsOpener = Future<void> Function();
typedef ComicDetailsMetadataSearch = void Function(String query);
typedef ComicDetailsIdentityMatcher = bool Function(
  String leftComicId,
  String rightComicId,
);

bool _exactComicIdentity(String leftComicId, String rightComicId) =>
    leftComicId == rightComicId;


void _ignoreRefreshResult(Future<bool> refresh) {
  unawaited(refresh.then<void>((_) {}));
}


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
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.onSearchMetadata,
    this.onMigrateSource,
    this.onOpenVersions,
    this.traceSink = const NoopTraceSink(),
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
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final ComicDetailsMigrationOpener? onMigrateSource;
  final ComicDetailsVersionsOpener? onOpenVersions;
  final TraceSink traceSink;

  @override
  State<LocalComicDetailsScreen> createState() =>
      _LocalComicDetailsScreenState();
}

final class _LocalComicDetailsScreenState
    extends State<LocalComicDetailsScreen> {
  late ComicDetailsLibrarySnapshot _library;
  bool _descending = true;
  bool _refreshing = false;
  Future<bool>? _refreshInFlight;
  final Set<String> _opening = <String>{};
  final Set<String> _workingDownloads = <String>{};
  final Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  bool _downloadingComic = false;
  _DetailFailure? _failure;
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};
  final Stopwatch _traceClock = Stopwatch()..start();

  void _recordRefreshTrace(
    TraceEventKind kind,
    String stage, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'comic-details:${widget.comic.sourceId}',
        kind: kind,
        payload: <String, Object?>{
          'stage': stage,
          'comicIdLength': widget.comic.comicId.length,
          ...payload,
        },
      ),
    );
  }

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

  ComicPreviewSource? get _previewSource {
    final Object? candidate = widget.source;
    return candidate is ComicPreviewSource ? candidate : null;
  }

  ComicCommentSource? get _commentSource {
    final Object? candidate = widget.source;
    return candidate is ComicCommentSource ? candidate : null;
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

  Future<bool> _refresh({required bool announce}) {
    final active = _refreshInFlight;
    if (active != null) {
      _recordRefreshTrace(
        TraceEventKind.retryScheduled,
        'local-refresh-joined',
      );
      return active;
    }
    final result = Completer<bool>();
    late final Future<bool> tracked;
    tracked = result.future.whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    Future<bool>.sync(() => _performRefresh(announce: announce)).then(
      result.complete,
      onError: result.completeError,
    );
    return tracked;
  }

  Future<bool> _performRefresh({required bool announce}) async {
    final startedMicros = _traceClock.elapsedMicroseconds;
    _recordRefreshTrace(
      TraceEventKind.retryScheduled,
      'local-refresh-start',
    );
    setState(() {
      _refreshing = true;
      _failure = null;
    });
    var succeeded = false;
    try {
      final next = await widget.reloadLibrary(refreshContent: true);
      if (!mounted) {
        return false;
      }
      setState(() => _library = next);
      unawaited(_loadDownloadStatuses(next.chapters));
      succeeded = true;
      _recordRefreshTrace(
        TraceEventKind.sourceReady,
        'local-refresh-complete',
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'chapterCount': next.sourceChapters.length,
        },
      );
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('漫画详情已更新')),
        );
      }
    } on Object catch (error, stackTrace) {
      _recordRefreshTrace(
        TraceEventKind.taskFailed,
        'local-refresh-failed',
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
        },
      );
      if (mounted) {
        final failure = _DetailFailure.capture(error, stackTrace);
        setState(() => _failure = failure);
        _showFailureSnackBar(
          context,
          failure,
          onOpenSourceWebView: failure.requiresSourceVerification &&
                  widget.onOpenSourceWebView != null
              ? () => unawaited(_recoverSourceAccess())
              : null,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
    return succeeded;
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
      _showLocalFailure(error, stackTrace);
    }
  }

  ImportedLibraryEntry? _entryFor(String sourceId, Chapter chapter) =>
      _chapterEntryFor(
        _library.chapters,
        sourceId: sourceId,
        comicId: widget.comic.comicId,
        chapter: chapter,
      );

  Future<ImportedLibraryEntry> _ensure(Chapter chapter) async {
    final existing = _entryFor(widget.comic.sourceId, chapter);
    if (existing != null &&
        existing.chapter.sourceRevision == chapter.sourceRevision) {
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
      tags: widget.comic.tags,
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
          chapters: _replaceChapterEntry(_library.chapters, entry),
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
        _showLocalFailure(error, stackTrace);
      }
    }
  }

  Future<void> _open(
    _ChapterViewModel chapter, {
    int? initialPageIndex,
  }) =>
      _openChapter(
        sourceId: chapter.sourceId,
        chapterId: chapter.chapterId,
        title: chapter.title,
        sourceChapter: chapter.sourceChapter,
        existing: chapter.entry,
        initialPageIndex: initialPageIndex,
      );

  Future<void> _openChapter({
    required String sourceId,
    required String chapterId,
    required String title,
    Chapter? sourceChapter,
    ImportedLibraryEntry? existing,
    int? initialPageIndex,
  }) async {
    final identity = comicDetailsChapterIdentity(
      sourceId,
      chapterId,
    );
    if (!_opening.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      await widget.onOpenChapter(
        () async {
          final entry = existing ??
              (sourceChapter == null
                  ? throw StateError('该章节没有可用的本地记录')
                  : await _ensure(sourceChapter));
          if (!_isRead(_library.readStates, entry) && mounted) {
            await _setRead(entry, true);
          }
          return entry;
        },
        refreshRemote: false,
        title: title,
        initialPageIndex: initialPageIndex,
      );
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showLocalFailure(error, stackTrace);
      }
    } finally {
      if (mounted) {
        setState(() {
          _opening.remove(identity);
        });
      }
    }
  }

  Future<void> _continueReading() async {
    final entry = _latestReadingEntry(_library.chapters);
    if (entry == null) {
      return;
    }
    await _openChapter(
      sourceId: entry.chapter.sourceId,
      chapterId: entry.chapter.chapterId,
      title: entry.chapter.displayName,
      existing: entry,
    );
  }

  Future<void> _openPreviewPage(int pageIndex) async {
    final chapters = _library.sourceChapters.toList(growable: false)
      ..sort(_compareChapters);
    if (chapters.isEmpty) return;
    var remaining = pageIndex < 0 ? 0 : pageIndex;
    for (final chapter in chapters) {
      final count = _knownPageCount(chapter, _entryFor(widget.comic.sourceId, chapter));
      if (count <= 0 || remaining < count) {
        await _openChapter(
          sourceId: widget.comic.sourceId,
          chapterId: chapter.chapterId,
          title: chapter.title,
          sourceChapter: chapter,
          existing: _entryFor(widget.comic.sourceId, chapter),
          initialPageIndex: remaining,
        );
        return;
      }
      remaining -= count;
    }
    final chapter = chapters.last;
    final count = _knownPageCount(
      chapter,
      _entryFor(widget.comic.sourceId, chapter),
    );
    await _openChapter(
      sourceId: widget.comic.sourceId,
      chapterId: chapter.chapterId,
      title: chapter.title,
      sourceChapter: chapter,
      existing: _entryFor(widget.comic.sourceId, chapter),
      initialPageIndex: count > 0 ? count - 1 : remaining,
    );
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
        _showLocalFailure(error, stackTrace);
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
        _showLocalFailure(error, stackTrace);
      }
    } finally {
      if (mounted) {
        setState(() => _downloadingComic = false);
      }
    }
  }

  void _showLocalFailure(Object error, StackTrace stackTrace) {
    final failure = _DetailFailure.capture(error, stackTrace);
    _showFailureSnackBar(
      context,
      failure,
      onOpenSourceWebView: failure.requiresSourceVerification &&
              widget.onOpenSourceWebView != null
          ? () => unawaited(_recoverSourceAccess())
          : null,
    );
  }

  Future<void> _recoverSourceAccess() async {
    final open = widget.onOpenSourceWebView;
    if (open == null) return;
    try {
      await open();
      if (mounted) {
        await _refresh(announce: false);
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showLocalFailure(error, stackTrace);
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
      final entry = _entryFor(widget.comic.sourceId, chapter);
      models.add(
        _ChapterViewModel(
          sourceId: widget.comic.sourceId,
          title: chapter.title,
          chapterId: chapter.chapterId,
          sequence: chapter.sequence,
          pageCount: _knownPageCount(chapter, entry),
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
    final catalogPages = models.fold<int>(
      0,
      (total, chapter) => total + chapter.pageCount,
    );
    final pageCountPending = models.any((chapter) => chapter.pageCount == 0);
    final sourceLabel = _comicSourceLabel(widget.source, comic.sourceId);
    final detailsManifest = _library.sourceManifest;
    final previewSource = _previewSource;
    final commentSource = _commentSource;
    final ComicDetailsPreviewLoader? previewLoader =
        previewSource != null && previewSource.supportsComicPreview
            ? (String? nextToken) => previewSource.loadComicPreview(
                  comic.comicId,
                  nextToken: nextToken,
                )
            : null;
    final ComicDetailsCommentsLoader? commentsLoader =
        commentSource != null && commentSource.supportsComicComments
            ? ({required int page, String? replyTo}) =>
                commentSource.loadComicComments(
                  comic.comicId,
                  subId: _library.sourceComic?.sourceSubId,
                  page: page,
                  replyTo: replyTo,
                )
            : null;
    final failure = _failure;
    final onMigrateSource = widget.onMigrateSource == null
        ? null
        : () => widget.onMigrateSource!(comic);
    if (failure != null && ordered.isEmpty) {
      return _ComicDetailsFailureScaffold(
        title: comic.title,
        sourceId: comic.sourceId,
        sourceLabel: sourceLabel,
        failure: failure,
        refreshing: _refreshing,
        onRetry: () => _ignoreRefreshResult(_refresh(announce: false)),
        onOpenSourceWebView: widget.onOpenSourceWebView == null
            ? null
            : _recoverSourceAccess,
        onOpenSourceSettings: widget.onOpenSourceSettings,
        onMigrateSource: onMigrateSource,
      );
    }
    return _ComicDetailsScaffold(
      screenKey: localComicDetailsScreenKey,
      title: comic.title,
      sourceId: comic.sourceId,
      sourceLabel: sourceLabel,
      authors: comic.authors,
      tags: comic.tags,
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
      descending: _descending,
      onRefresh: () => _refresh(announce: true),
      onOpenSourceWebView: widget.onOpenSourceWebView,
      onOpenSourceSettings: widget.onOpenSourceSettings,
      onSearchMetadata: widget.onSearchMetadata,
      onPreferenceChanged: _savePreference,
      progressLabel: _readingProgressLabel(_library.chapters),
      onContinueReading: _latestReadingEntry(_library.chapters) == null
          ? null
          : _continueReading,
      downloadingComic: _downloadingComic,
      onDownloadComic:
          comic.sourceId == 'local-folder' ? null : _downloadComic,
      onReverse: () => setState(() => _descending = !_descending),
      onMigrateSource: onMigrateSource,
      onOpenVersions: widget.onOpenVersions,
      chapterCount: ordered.length,
      pageCount: catalogPages,
      pageCountPending: pageCountPending,
      chapterList: _ComicChapterList(
        chapters: ordered,
        onOpen: _open,
        onDownload: _download,
        onRestoreUnread: (chapter) {
          final entry = chapter.entry;
          return entry == null ? Future<void>.value() : _setRead(entry, false);
        },
      ),
      previewSection: detailsManifest?.preview != null ||
              previewLoader != null
          ? _ComicDetailsPreviewSection(
              sourceId: comic.sourceId,
              comicId: comic.comicId,
              title: comic.title,
              initialPage: detailsManifest?.preview,
              loader: previewLoader,
              loadArtwork: widget.loadCover,
              onOpenPage: _openPreviewPage,
            )
          : null,
      commentsSection: detailsManifest?.comments != null ||
              commentsLoader != null
          ? _ComicDetailsCommentsSection(
              sourceId: comic.sourceId,
              comicId: comic.comicId,
              sourceSubId: _library.sourceComic?.sourceSubId,
              title: comic.title,
              initialPage: detailsManifest?.comments,
              loader: commentsLoader,
              loadArtwork: widget.loadCover,
            )
          : null,
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
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.onSearchMetadata,
    this.onMigrateSource,
    this.onOpenVersions,
    this.sameComicIdentity = _exactComicIdentity,
    this.traceSink = const NoopTraceSink(),
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
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final ComicDetailsVersionsOpener? onMigrateSource;
  final ComicDetailsVersionsOpener? onOpenVersions;
  final ComicDetailsIdentityMatcher sameComicIdentity;
  final TraceSink traceSink;

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
  Future<bool>? _refreshInFlight;
  bool _descending = true;
  final Set<String> _opening = <String>{};
  final Set<String> _workingDownloads = <String>{};
  final Map<String, ChapterDownloadSnapshot> _downloadSnapshots =
      <String, ChapterDownloadSnapshot>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  bool _downloadingComic = false;
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};
  final Stopwatch _traceClock = Stopwatch()..start();

  void _recordRefreshTrace(
    TraceEventKind kind,
    String stage, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceClock.elapsedMicroseconds,
        sessionId: 'comic-details:${widget.source.sourceId}',
        kind: kind,
        payload: <String, Object?>{
          'stage': stage,
          'comicIdLength': widget.summary.comicId.length,
          ...payload,
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _library = widget.initialLibrary;
    _downloadSubscription =
        widget.downloadChanges.listen(_acceptDownloadSnapshot);
    scheduleMicrotask(
      () => unawaited(_loadDownloadStatuses(_library.chapters)),
    );
    scheduleMicrotask(() => _ignoreRefreshResult(_refresh(announce: false)));
  }

  @override
  void dispose() {
    unawaited(_downloadSubscription?.cancel());
    super.dispose();
  }

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    if (!mounted ||
        snapshot.sourceId != widget.source.sourceId ||
        !widget.sameComicIdentity(
          snapshot.comicId,
          widget.summary.comicId,
        )) {
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
        tags: widget.summary.tags,
        coverUri: widget.summary.coverUri,
        description: widget.summary.description,
        readingDirection: ReadingDirection.ltr,
      );

  ComicPreviewSource? get _previewSource {
    final Object candidate = widget.source;
    return candidate is ComicPreviewSource ? candidate : null;
  }

  ComicCommentSource? get _commentSource {
    final Object candidate = widget.source;
    return candidate is ComicCommentSource ? candidate : null;
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

  Future<bool> _refresh({
    required bool announce,
    bool forceRefresh = false,
  }) {
    final active = _refreshInFlight;
    if (active != null) {
      _recordRefreshTrace(
        TraceEventKind.retryScheduled,
        'remote-refresh-joined',
        payload: <String, Object?>{'forceRefresh': forceRefresh},
      );
      return active;
    }
    final result = Completer<bool>();
    late final Future<bool> tracked;
    tracked = result.future.whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    Future<bool>.sync(
      () => _performRefresh(
        announce: announce,
        forceRefresh: forceRefresh,
      ),
    ).then(
      result.complete,
      onError: result.completeError,
    );
    return tracked;
  }

  Future<bool> _performRefresh({
    required bool announce,
    bool forceRefresh = false,
  }) async {
    final startedMicros = _traceClock.elapsedMicroseconds;
    _recordRefreshTrace(
      TraceEventKind.retryScheduled,
      'remote-refresh-start',
      payload: <String, Object?>{'forceRefresh': forceRefresh},
    );
    setState(() {
      _refreshing = true;
      _failure = null;
    });
    var succeeded = false;
    try {
      if (forceRefresh) {
        final identities = <String>{widget.summary.comicId};
        final manifestComic = _manifest?.comic.comicId;
        if (manifestComic != null) identities.add(manifestComic);
        final libraryComic = _library.sourceComic?.comicId;
        if (libraryComic != null) identities.add(libraryComic);
        for (final comicId in identities) {
          invalidateCachedComic(widget.source, comicId);
        }
      }
      final library = await widget.reloadLibrary(refreshContent: true);
      final sourceManifest = library.sourceManifest;
      final comic = sourceManifest?.comic ?? library.sourceComic;
      final sourceChapters =
          sourceManifest?.chapters ?? library.sourceChapters;
      if (comic == null ||
          comic.sourceId != widget.source.sourceId ||
          !widget.sameComicIdentity(
            comic.comicId,
            widget.summary.comicId,
          ) ||
          sourceChapters.any(
            (chapter) => !widget.sameComicIdentity(
              chapter.comicId,
              widget.summary.comicId,
            ),
          )) {
        throw StateError('漫画源详情组合刷新未返回匹配的漫画和章节身份');
      }
      if (sourceChapters.isEmpty) {
        throw StateError(
          '漫画源未返回可确认的章节目录；这不代表单章节漫画。'
          '请打开 WebView 完成站点验证后重试。',
        );
      }
      final manifest = sourceManifest ??
          ComicManifest(
            comic: comic,
            chapters: sourceChapters,
          );
      if (!mounted) {
        return false;
      }
      setState(() {
        _manifest = manifest;
        _library = library;
      });
      succeeded = true;
      _recordRefreshTrace(
        TraceEventKind.sourceReady,
        'remote-refresh-complete',
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'chapterCount': manifest.chapters.length,
        },
      );
      unawaited(_loadDownloadStatuses(library.chapters));
      if (announce) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已更新 ${manifest.chapters.length} 个章节')),
        );
      }
    } on Object catch (error, stackTrace) {
      _recordRefreshTrace(
        TraceEventKind.taskFailed,
        'remote-refresh-failed',
        payload: <String, Object?>{
          'durationMicros': _traceClock.elapsedMicroseconds - startedMicros,
          'errorType': error.runtimeType.toString(),
          if (error is Failure) 'errorCode': error.code.name,
        },
      );
      if (mounted) {
        final failure = _DetailFailure.capture(error, stackTrace);
        setState(() => _failure = failure);
        if (_manifest != null) {
          _showFailureSnackBar(
            context,
            failure,
            onOpenSourceWebView: failure.requiresSourceVerification &&
                    widget.onOpenSourceWebView != null
                ? () => unawaited(_recoverSourceAccess())
                : null,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
    return succeeded;
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

  ImportedLibraryEntry? _localEntry(Chapter chapter) => _chapterEntryFor(
        _library.chapters,
        sourceId: widget.source.sourceId,
        comicId: chapter.comicId,
        chapter: chapter,
      );

  Future<ImportedLibraryEntry> _ensure(Chapter chapter) async {
    final existing = _localEntry(chapter);
    if (existing != null &&
        existing.chapter.sourceRevision == chapter.sourceRevision) {
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
          chapters: _replaceChapterEntry(_library.chapters, entry),
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

  Future<void> _open(Chapter chapter, {int? initialPageIndex}) =>
      _openChapter(chapter, initialPageIndex: initialPageIndex);

  Future<void> _openChapter(
    Chapter chapter, {
    ImportedLibraryEntry? existing,
    int? initialPageIndex,
  }) async {
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
      await widget.onOpenChapter(
        () async {
          final entry = existing ?? await _ensure(chapter);
          if (!_isRead(_library.readStates, entry) && mounted) {
            await _setRead(entry, true);
          }
          return entry;
        },
        refreshRemote: false,
        title: chapter.title,
        initialPageIndex: initialPageIndex,
      );
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showRemoteFailure(error, stackTrace);
      }
    } finally {
      if (mounted) {
        setState(() {
          _opening.remove(identity);
        });
      }
    }
  }

  Future<void> _continueReading() async {
    final entry = _latestReadingEntry(_library.chapters);
    if (entry == null) {
      return;
    }
    final chapter = _manifest?.chapters.cast<Chapter?>().firstWhere(
          (candidate) => candidate!.chapterId == entry.chapter.chapterId,
          orElse: () => null,
        );
    await _openChapter(
      chapter ??
          Chapter(
            chapterId: entry.chapter.chapterId,
            comicId: entry.chapter.comicId,
            title: entry.chapter.displayName,
            sequence: entry.chapter.sequence,
            pageCount: entry.chapter.pages.length,
            sourceRevision: entry.chapter.sourceRevision,
            publishedAt: entry.chapter.importedAt,
          ),
      existing: entry,
    );
  }

  Future<void> _openPreviewPage(int pageIndex) async {
    final sourceManifest = _manifest ?? _library.sourceManifest;
    final chapters = (sourceManifest?.chapters ?? const <Chapter>[]).toList(
      growable: false,
    )..sort(_compareChapters);
    if (chapters.isEmpty) return;
    var remaining = pageIndex < 0 ? 0 : pageIndex;
    for (final chapter in chapters) {
      final count = _knownPageCount(chapter, _localEntry(chapter));
      if (count <= 0 || remaining < count) {
        await _openChapter(
          chapter,
          existing: _localEntry(chapter),
          initialPageIndex: remaining,
        );
        return;
      }
      remaining -= count;
    }
    final chapter = chapters.last;
    final count = _knownPageCount(chapter, _localEntry(chapter));
    await _openChapter(
      chapter,
      existing: _localEntry(chapter),
      initialPageIndex: count > 0 ? count - 1 : remaining,
    );
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
        _showRemoteFailure(error, stackTrace);
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
        _showRemoteFailure(error, stackTrace);
      }
    } finally {
      if (mounted) {
        setState(() => _downloadingComic = false);
      }
    }
  }

  void _showRemoteFailure(Object error, StackTrace stackTrace) {
    final failure = _DetailFailure.capture(error, stackTrace);
    _showFailureSnackBar(
      context,
      failure,
      onOpenSourceWebView: failure.requiresSourceVerification &&
              widget.onOpenSourceWebView != null
          ? () => unawaited(_recoverSourceAccess())
          : null,
    );
  }

  Future<void> _recoverSourceAccess() async {
    final open = widget.onOpenSourceWebView;
    if (open == null) return;
    try {
      await open();
      if (mounted) {
        await _refresh(announce: false, forceRefresh: true);
      }
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showFailureSnackBar(
          context,
          _DetailFailure.capture(error, stackTrace),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null && _manifest == null) {
      return _ComicDetailsFailureScaffold(
        title: widget.summary.title,
        sourceId: widget.source.sourceId,
        sourceLabel: widget.source.descriptor.name,
        failure: failure,
        refreshing: _refreshing,
        onRetry: () => _ignoreRefreshResult(
          _refresh(announce: false, forceRefresh: true),
        ),
        onOpenSourceWebView: widget.onOpenSourceWebView == null
            ? null
            : _recoverSourceAccess,
        onOpenSourceSettings: widget.onOpenSourceSettings,
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
    final detailsManifest = _library.sourceManifest ?? manifest;
    final previewSource = _previewSource;
    final commentSource = _commentSource;
    final ComicDetailsPreviewLoader? previewLoader =
        previewSource != null && previewSource.supportsComicPreview
            ? (String? nextToken) => previewSource.loadComicPreview(
                  comic.comicId,
                  nextToken: nextToken,
                )
            : null;
    final ComicDetailsCommentsLoader? commentsLoader =
        commentSource != null && commentSource.supportsComicComments
            ? ({required int page, String? replyTo}) =>
                commentSource.loadComicComments(
                  comic.comicId,
                  subId: comic.sourceSubId,
                  page: page,
                  replyTo: replyTo,
                )
            : null;
    final knownPageCount = ordered.fold<int>(
      0,
      (sum, chapter) =>
          sum + _knownPageCount(chapter, _localEntry(chapter)),
    );
    final pageCountPending = ordered.any(
      (chapter) => _knownPageCount(
        chapter,
        _localEntry(chapter),
      ) == 0,
    );
    return _ComicDetailsScaffold(
      screenKey: remoteComicDetailsScreenKey,
      title: comic.title,
      sourceId: widget.source.sourceId,
      sourceLabel: _comicSourceLabel(widget.source, widget.source.sourceId),
      authors: comic.authors,
      tags: comic.tags,
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
      descending: _descending,
      onRefresh: () => _refresh(announce: true, forceRefresh: true),
      onOpenSourceWebView: widget.onOpenSourceWebView,
      onOpenSourceSettings: widget.onOpenSourceSettings,
      onSearchMetadata: widget.onSearchMetadata,
      onMigrateSource: widget.onMigrateSource,
      onOpenVersions: widget.onOpenVersions,
      onPreferenceChanged: _savePreference,
      progressLabel: _readingProgressLabel(_library.chapters),
      onContinueReading: _latestReadingEntry(_library.chapters) == null
          ? null
          : _continueReading,
      downloadingComic: _downloadingComic,
      onDownloadComic: _downloadComic,
      onReverse: () => setState(() => _descending = !_descending),
      chapterCount: ordered.length,
      pageCount: knownPageCount,
      pageCountPending: pageCountPending,
      chapterList: _ComicChapterList(
        chapters: <_ChapterViewModel>[
          for (final chapter in ordered)
            _ChapterViewModel(
              sourceId: widget.source.sourceId,
              title: chapter.title,
              chapterId: chapter.chapterId,
              sequence: chapter.sequence,
              pageCount: _knownPageCount(
                chapter,
                _localEntry(chapter),
              ),
              publishedAt: chapter.publishedAt,
              entry: _localEntry(chapter),
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
      previewSection: detailsManifest?.preview != null ||
              previewLoader != null
          ? _ComicDetailsPreviewSection(
              sourceId: widget.source.sourceId,
              comicId: comic.comicId,
              title: comic.title,
              initialPage: detailsManifest?.preview,
              loader: previewLoader,
              loadArtwork: widget.loadCover,
              onOpenPage: _openPreviewPage,
            )
          : null,
      commentsSection: detailsManifest?.comments != null ||
              commentsLoader != null
          ? _ComicDetailsCommentsSection(
              sourceId: widget.source.sourceId,
              comicId: comic.comicId,
              sourceSubId: comic.sourceSubId,
              title: comic.title,
              initialPage: detailsManifest?.comments,
              loader: commentsLoader,
              loadArtwork: widget.loadCover,
            )
          : null,
    );
  }
}

final class _ComicDetailsHeader extends StatelessWidget {
  const _ComicDetailsHeader({
    required this.title,
    required this.sourceLabel,
    required this.authors,
    required this.tags,
    required this.description,
    required this.cover,
    required this.preference,
    required this.categories,
    required this.onPreferenceChanged,
    this.onSearchMetadata,
    required this.downloadingComic,
    required this.onDownloadComic,
  });

  final String title;
  final String sourceLabel;
  final List<String> authors;
  final List<String> tags;
  final String? description;
  final Widget cover;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final bool downloadingComic;
  final Future<void> Function()? onDownloadComic;

  @override
  Widget build(BuildContext context) {
    final sourceMetadata = _groupSourceMetadata(tags);
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
                        _PreferenceButton(
                          key: comicDetailsDownloadAllKey,
                          icon: Icons.download_for_offline_outlined,
                          label: '下载整本',
                          selected: false,
                          loading: downloadingComic,
                          onPressed: downloadingComic
                              ? null
                              : () => unawaited(onDownloadComic!()),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('简介', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          description?.trim().isNotEmpty == true
              ? description!.trim()
              : '暂无简介',
        ),
        if (sourceMetadata.categories.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _ExpandableTagRow(
            label: '来源分类',
            tags: sourceMetadata.categories,
            onSearch: onSearchMetadata,
          ),
        ],
        if (sourceMetadata.tags.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _ExpandableTagRow(
            label: '标签',
            tags: sourceMetadata.tags,
            onSearch: onSearchMetadata,
          ),
        ],
        if (categories.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text('书架分类', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
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

List<ImportedLibraryEntry> _replaceChapterEntry(
  Iterable<ImportedLibraryEntry> entries,
  ImportedLibraryEntry replacement,
) =>
    <ImportedLibraryEntry>[
      for (final entry in entries)
        if (entry.chapter.sourceId != replacement.chapter.sourceId ||
            entry.chapter.comicId != replacement.chapter.comicId ||
            entry.chapter.chapterId != replacement.chapter.chapterId)
          entry,
      replacement,
    ];

ImportedLibraryEntry? _chapterEntryFor(
  Iterable<ImportedLibraryEntry> entries, {
  required String sourceId,
  required String comicId,
  required Chapter chapter,
}) {
  for (final entry in entries) {
    if (entry.chapter.sourceId == sourceId &&
        entry.chapter.comicId == comicId &&
        entry.chapter.chapterId == chapter.chapterId) {
      return entry;
    }
  }
  final revision = chapter.sourceRevision.trim();
  if (revision.isEmpty) {
    return null;
  }
  ImportedLibraryEntry? match;
  for (final entry in entries) {
    if (entry.chapter.sourceId != sourceId ||
        entry.chapter.comicId != comicId ||
        entry.chapter.sourceRevision != revision) {
      continue;
    }
    if (match != null) {
      return null;
    }
    match = entry;
  }
  return match;
}

int _knownPageCount(Chapter chapter, ImportedLibraryEntry? entry) {
  if (chapter.pageCount > 0) {
    return chapter.pageCount;
  }
  return entry?.chapter.pages.length ?? 0;
}

String _comicSourceLabel(
  BrowsableComicSource? source,
  String sourceId,
) {
  if (sourceId == 'local-folder') {
    return '本地';
  }
  final raw = source?.descriptor.name.trim() ?? '';
  final numeric = RegExp(r'^(?:mihon:)?-?\d+$');
  if (raw.isNotEmpty && raw != sourceId && !numeric.hasMatch(raw)) {
    return raw;
  }
  final host = source?.descriptor.website.host.trim() ?? '';
  if (host.isNotEmpty && host != 'invalid.local') {
    return host;
  }
  return sourceId.startsWith('mihon:') ? 'Mihon' : sourceId;
}

final class _PreferenceButton extends StatelessWidget {
  const _PreferenceButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.loading = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: label,
      isSelected: selected,
      onPressed: onPressed,
      icon: loading
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
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
            errorBuilder: (_, __, ___) => _CoverPlaceholder(
              seed: widget.coverUri?.toString() ?? widget.comicId,
            ),
          );
        }
        if (snapshot.hasError) {
          return _CoverPlaceholder(
            seed: widget.coverUri?.toString() ?? widget.comicId,
          );
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
  const _CoverPlaceholder({this.seed = ''});

  final String seed;

  @override
  Widget build(BuildContext context) {
    return SoftArtworkPlaceholder(
      seed: seed,
    );
  }
}

final class _DetailFailure {
  const _DetailFailure({
    required this.summary,
    required this.details,
    this.requiresSourceVerification = false,
  });

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
      requiresSourceVerification: error is Failure &&
          error.code == ErrorCode.sourceVerificationRequired,
    );
  }

  final String summary;
  final String details;
  final bool requiresSourceVerification;
}

final class _DetailFailurePanel extends StatelessWidget {
  const _DetailFailurePanel({
    required this.failure,
    required this.onRetry,
  });

  final _DetailFailure failure;
  final VoidCallback? onRetry;

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

Map<String, ChapterReadState> _projectChapterReadState(
  Map<String, ChapterReadState> current,
  ImportedLibraryEntry entry,
  bool isRead,
) {
  final identity = comicDetailsChapterIdentity(
    entry.chapter.sourceId,
    entry.chapter.chapterId,
  );
  return <String, ChapterReadState>{
    ...current,
    identity: ChapterReadState(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId,
      isRead: isRead,
      updatedAt: DateTime.now().toUtc(),
    ),
  };
}

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

void _showFailureSnackBar(
  BuildContext context,
  _DetailFailure failure, {
  VoidCallback? onOpenSourceWebView,
}) {
  final canVerify = failure.requiresSourceVerification &&
      onOpenSourceWebView != null;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(failure.summary, maxLines: 3),
      action: SnackBarAction(
        label: canVerify ? 'WebView' : '复制',
        onPressed: canVerify
            ? onOpenSourceWebView
            : () => unawaited(_copyFailure(context, failure)),
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
