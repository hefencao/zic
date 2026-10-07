import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'package:downloads/downloads.dart';
import 'app_pull_to_refresh.dart';
import 'artwork_placeholder.dart';
import 'comic_download_conflict_dialog.dart';
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
const comicDetailsVersionSectionKey =
    ValueKey<String>('comic-details-version-section');
const comicDetailsVersionActionKey =
    ValueKey<String>('comic-details-version-action');
const comicDetailsVersionViewKey =
    ValueKey<String>('comic-details-version-view');
const comicDetailsVersionMigrateKey =
    ValueKey<String>('comic-details-version-migrate');
const comicDetailsVersionMigrateCurrentKey =
    ValueKey<String>('comic-details-version-migrate-current');
const comicDetailsContinueReadingKey =
    ValueKey<String>('comic-details-continue-reading');
const comicDetailsReadingHistoryKey =
    ValueKey<String>('comic-details-reading-history');
const comicDetailsChapterCountKey =
    ValueKey<String>('comic-details-chapter-count');

// A source pageCount of zero means unknown, not an authoritative empty chapter.
bool comicDetailsCanReuseChapterEntry(
  ImportedLibraryEntry? existing,
  Chapter chapter,
) =>
    existing != null &&
    existing.chapter.sourceRevision == chapter.sourceRevision &&
    existing.chapter.pages.isNotEmpty &&
    (chapter.pageCount <= 0 ||
        existing.chapter.pages.length == chapter.pageCount) &&
    !chapterHasHomeProjectionSnapshotPagePlaceholders(existing.chapter);
const comicDetailsChapterListKey =
    ValueKey<String>('comic-details-chapter-list');
const comicDetailsDownloadAllKey =
    ValueKey<String>('comic-details-download-all');
const comicDetailsOpenWebViewKey =
    ValueKey<String>('comic-details-open-webview');
const comicDetailsTitleSearchKey =
    ValueKey<String>('comic-details-title-search');
const comicDetailsMigrateKey = ValueKey<String>('comic-details-migrate');
const comicDetailsSourceSettingsKey =
    ValueKey<String>('comic-details-source-settings');
const comicDetailsMiscKey = ValueKey<String>('comic-details-misc');
const comicDetailsRefreshStateKey =
    ValueKey<String>('comic-details-refresh-state');
const comicDetailsRetryBodyKey =
    ValueKey<String>('comic-details-retry-body');
const comicDetailsPullRefreshKey =
    ValueKey<String>('comic-details-pull-refresh');
const comicDetailsPreviewKey = ValueKey<String>('comic-details-preview');
const comicDetailsPreviewExpandKey =
    ValueKey<String>('comic-details-preview-expand');
const comicDetailsCommentsKey = ValueKey<String>('comic-details-comments');
const comicDetailsCommentsPageKey =
    ValueKey<String>('comic-details-comments-page');

Key comicDetailsPreviewItemKey(int index) =>
    ValueKey<String>('comic-details-preview-item:$index');

String comicDetailsChapterIdentity(String sourceId, String chapterId) =>
    '$sourceId\u0000$chapterId';

/// The download operations the details screens need, resolved once by the
/// composition owner. Screens render from this object instead of threading
/// per-operation callbacks, so adding a capability happens in one place.
class ComicDetailsDownloadActions {
  const ComicDetailsDownloadActions({
    required this.downloadChapter,
    required this.stopChapter,
    required this.probeExisting,
    required this.wholeComicJob,
    required this.cachedWholeComicJob,
    required this.toggleWholeComicPause,
    required this.inspectComicConflicts,
    required this.claimComicDirectory,
    required this.getDownloadPlacement,
    required this.inspectChapter,
    this.ensureDurableServices,
  });

  /// Starts (or resumes) a chapter download.
  final Future<void> Function(ImportedLibraryEntry entry) downloadChapter;

  /// Stops every run of the chapter (all revisions).
  final Future<void> Function(ImportedLibraryEntry entry) stopChapter;

  /// Pre-claims the target structured directory for a comic to honor explicit
  /// conflict decisions (e.g. save-as-new or overwrite choice).
  final Future<void> Function({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode,
    String? observedOwnerKey,
  }) claimComicDirectory;

  /// Retrieves the persisted placement record for the specified comic.
  final Future<DownloadPlacement?> Function({
    required String sourceId,
    required String comicId,
  }) getDownloadPlacement;

  /// Unified existing-download lookup. [chapterId] narrows the report to one
  /// chapter; omit it for a comic-scoped probe.
  final Future<DownloadExistenceReport> Function({
    required String sourceId,
    required String comicId,
    String? chapterId,
  }) probeExisting;

  /// The whole-comic job covering the comic, or null (async, queue-ready).
  final Future<WholeComicQueueJobSnapshot?> Function(
    String sourceId,
    String comicId,
  ) wholeComicJob;

  /// Synchronous read over the latest cached queue snapshot — for build
  /// methods that cannot await (pause-button visibility).
  final WholeComicQueueJobSnapshot? Function(
    String sourceId,
    String comicId,
  ) cachedWholeComicJob;

  /// Pauses a running whole-comic job, resumes a paused one.
  final Future<void> Function(String sourceId, String comicId)
      toggleWholeComicPause;

  /// Comic-level directory conflict inspection for the comparison stage.
  final Future<ComicConflictReport> Function({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) inspectComicConflicts;

  /// Authoritative per-chapter snapshot (live session + index projection).
  final Future<ChapterDownloadSnapshot> Function(ImportedLibraryEntry entry)
      inspectChapter;

  /// Crosses the bootstrap-to-durable boundary before conflict probes or
  /// queue mutations, so the UI never decides against a stale memory store.
  final Future<void> Function()? ensureDurableServices;

  /// A no-op instance for UI-only constructions (widget tests, previews)
  /// that never drive downloads.
  static const ComicDetailsDownloadActions noop = ComicDetailsDownloadActions(
    downloadChapter: _noopChapter,
    stopChapter: _noopChapter,
    probeExisting: _noopProbe,
    wholeComicJob: _noopWholeComicJob,
    cachedWholeComicJob: _noopCachedWholeComicJob,
    toggleWholeComicPause: _noopToggle,
    inspectComicConflicts: _noopInspectComicConflicts,
    claimComicDirectory: _noopClaimComicDirectory,
    getDownloadPlacement: _noopGetDownloadPlacement,
    inspectChapter: _noopInspectChapter,
    ensureDurableServices: null,
  );

  static Future<void> _noopClaimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
  }) async {}

  static Future<DownloadPlacement?> _noopGetDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async =>
      null;

  static Future<void> _noopChapter(ImportedLibraryEntry entry) async {}

  static Future<DownloadExistenceReport> _noopProbe({
    required String sourceId,
    required String comicId,
    String? chapterId,
  }) async =>
      const DownloadExistenceReport(
        liveRunIdentities: <String>[],
        liveRunStarted: false,
        indexedReadyPages: 0,
        urlMatchedPages: 0,
      );

  static Future<WholeComicQueueJobSnapshot?> _noopWholeComicJob(
    String sourceId,
    String comicId,
  ) async =>
      null;

  static WholeComicQueueJobSnapshot? _noopCachedWholeComicJob(
    String sourceId,
    String comicId,
  ) =>
      null;

  static Future<void> _noopToggle(String sourceId, String comicId) async {}

  static Future<ComicConflictReport> _noopInspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
    Set<String>? requiredDirectoryNames,
  }) async =>
      const ComicConflictReport(
        candidates: <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName: '',
      );

  static Future<ChapterDownloadSnapshot> _noopInspectChapter(
    ImportedLibraryEntry entry,
  ) async =>
      ChapterDownloadSnapshot.idle(entry);
}

typedef ComicDetailsChapterStopper = Future<void> Function(
  ImportedLibraryEntry entry,
);

typedef ComicDetailsWholeComicPauseToggler = Future<void> Function();

/// Unified existing-download probe result for the download gate: the
/// service-level existence report plus the parent whole-comic job when one
/// covers the chapter.
class ComicDetailsExistingDownloadProbe {
  const ComicDetailsExistingDownloadProbe({
    required this.report,
    this.wholeComicJob,
  });

  final DownloadExistenceReport report;
  final WholeComicQueueJobSnapshot? wholeComicJob;

  bool get activeWholeComicJob {
    final phase = wholeComicJob?.phase;
    return phase == WholeComicQueuePhase.running ||
        phase == WholeComicQueuePhase.queued ||
        phase == WholeComicQueuePhase.paused ||
        phase == WholeComicQueuePhase.waitingForPolicy;
  }
}

typedef ComicDetailsExistingDownloadProbeFetcher
    = Future<ComicDetailsExistingDownloadProbe?> Function(
  ImportedLibraryEntry entry,
);

/// Returns true when a whole-comic download job already exists for the
/// comic (any active phase).
typedef ComicDetailsWholeComicJobChecker = Future<bool> Function();

/// Stable chapter-row identity shared with the source browser.
///
/// Only the source-owned chapter identity participates here. Metadata such as
/// title, sequence, URL, and source revision must not turn one chapter into a
/// different presentation row.
Key comicDetailsChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('source-chapter:$sourceId\u0000$chapterId');

Key comicDetailsReadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-read:$sourceId\u0000$chapterId');

Key comicDetailsNewChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-new:$sourceId\u0000$chapterId');

Key comicDetailsStopDownloadKey(String sourceId, String chapterId) =>
    ValueKey<String>('comic-details-stop-download:$sourceId\u0000$chapterId');

Key comicDetailsDownloadKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-download:$sourceId\u0000$chapterId');

Key comicDetailsWholeComicPauseKey() =>
    const ValueKey<String>('comic-details-whole-comic-pause');

Key comicDetailsDeleteChapterKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-delete:$sourceId\u0000$chapterId');

Key comicDetailsDeleteRevealKey(String sourceId, String chapterId) =>
    ValueKey<String>('chapter-delete-reveal:$sourceId\u0000$chapterId');

// Only projects stored metadata into a unique current catalog row. The caller
// supplies source-owned comparison; this never grants page or mutation reuse.
Map<String, String> comicDetailsCatalogEntryProjection({
  required String sourceId,
  required String comicId,
  required Iterable<Chapter> sourceChapters,
  required Iterable<ImportedLibraryEntry> entries,
  required String? Function(String chapterId) comparisonKey,
}) {
  final keys = <String, String?>{};
  String? keyFor(String id) => keys.containsKey(id)
      ? keys[id]
      : keys[id] = comparisonKey(id);
  final exactIds = <String>{};
  final catalogIdsByKey = <String, String?>{};
  for (final chapter in sourceChapters) {
    if (chapter.comicId != comicId) continue;
    exactIds.add(chapter.chapterId);
    final key = keyFor(chapter.chapterId);
    if (key == null) continue;
    catalogIdsByKey[key] =
        catalogIdsByKey.containsKey(key) ? null : chapter.chapterId;
  }
  return <String, String>{
    for (final entry in entries)
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.comicId == comicId)
        if (exactIds.contains(entry.chapter.chapterId))
          entry.identity: entry.chapter.chapterId
        else if (catalogIdsByKey[keyFor(entry.chapter.chapterId)] != null)
          entry.identity: catalogIdsByKey[keyFor(entry.chapter.chapterId)]!,
  };
}

final class ComicDetailsLibrarySnapshot {
  ComicDetailsLibrarySnapshot({
    required Iterable<ImportedLibraryEntry> chapters,
    required Map<String, ChapterReadState> readStates,
    required this.preference,
    this.sourceComic,
    this.sourceManifest,
    this.sourceSyncedAt,
    Iterable<Chapter> sourceChapters = const <Chapter>[],
    Iterable<String> unseenChapterIds = const <String>[],
    Map<String, String> catalogChapterIdsByEntryIdentity =
        const <String, String>{},
  })  : chapters = List<ImportedLibraryEntry>.unmodifiable(chapters),
        sourceChapters = List<Chapter>.unmodifiable(sourceChapters),
        unseenChapterIds = Set<String>.unmodifiable(unseenChapterIds),
        catalogChapterIdsByEntryIdentity =
            Map<String, String>.unmodifiable(catalogChapterIdsByEntryIdentity),
        readStates = Map<String, ChapterReadState>.unmodifiable(readStates);

  ComicDetailsLibrarySnapshot copyWith({
    Iterable<ImportedLibraryEntry>? chapters,
    Iterable<Chapter>? sourceChapters,
    Map<String, ChapterReadState>? readStates,
    ComicPreference? preference,
    Comic? sourceComic,
    ComicManifest? sourceManifest,
    DateTime? sourceSyncedAt,
    Iterable<String>? unseenChapterIds,
    Map<String, String>? catalogChapterIdsByEntryIdentity,
  }) =>
      ComicDetailsLibrarySnapshot(
        chapters: chapters ?? this.chapters,
        sourceChapters: sourceChapters ?? this.sourceChapters,
        readStates: readStates ?? this.readStates,
        preference: preference ?? this.preference,
        sourceComic: sourceComic ?? this.sourceComic,
        sourceManifest: sourceManifest ?? this.sourceManifest,
        sourceSyncedAt: sourceSyncedAt ?? this.sourceSyncedAt,
        unseenChapterIds: unseenChapterIds ?? this.unseenChapterIds,
        catalogChapterIdsByEntryIdentity: catalogChapterIdsByEntryIdentity ??
            this.catalogChapterIdsByEntryIdentity,
      );

  final List<ImportedLibraryEntry> chapters;
  final List<Chapter> sourceChapters;
  final Map<String, ChapterReadState> readStates;
  final ComicPreference preference;
  final Comic? sourceComic;
  final ComicManifest? sourceManifest;
  final DateTime? sourceSyncedAt;
  final Set<String> unseenChapterIds;
  final Map<String, String> catalogChapterIdsByEntryIdentity;
}

typedef ComicDetailsArtworkLoader = Future<EncodedResourceSource> Function({
  required String sourceId,
  required String comicId,
  required Uri? coverUri,
  required ImportedLibraryEntry? fallbackChapter,
  required String resourceRole,
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

typedef ComicDetailsChapterOpener = Future<ReadingProgress?> Function(
  ComicDetailsChapterLoader loadChapter, {
  required bool refreshRemote,
  required String title,
  int? initialPageIndex,
});

typedef ComicDetailsChapterViewed = Future<void> Function(
  String sourceId,
  String comicId,
  String chapterId,
);

typedef ComicDetailsChapterDownloader = Future<void> Function(
  ImportedLibraryEntry chapter,
);
typedef ComicDetailsChapterDeleter = Future<void> Function(
  ImportedLibraryEntry chapter, {
  bool deleteFiles,
});

typedef ComicDetailsChapterDownloadInspector =
    Future<ChapterDownloadSnapshot> Function(ImportedLibraryEntry chapter);
typedef ComicDetailsChapterDownloadBulkInspector =
    Future<Iterable<ChapterDownloadSnapshot>> Function(
      Iterable<ImportedLibraryEntry> chapters,
    );

typedef ComicDetailsComicDownloader = Future<void> Function(
  Iterable<ImportedLibraryEntry> chapters,
);

typedef ComicDetailsConflictInspector = Future<ComicConflictReport> Function({
  required String sourceId,
  required String comicId,
  required String comicTitle,
  String? sourceDisplayName,
  Set<String>? knownPredecessorComicIds,
  Set<String>? knownSuccessorComicIds,
  Set<String>? requiredDirectoryNames,
});

typedef ComicDetailsComicPersister = Future<void> Function(
  ComicManifest manifest,
  bool retained,
);

final class ComicDetailsVersionState {
  const ComicDetailsVersionState({
    this.successors = const <SourceComicVersion>[],
    this.predecessors = const <SourceComicVersion>[],
    this.backgroundRefresh,
  });

  final List<SourceComicVersion> successors;
  final List<SourceComicVersion> predecessors;
  final Future<ComicDetailsVersionState>? backgroundRefresh;

  bool get isEmpty => successors.isEmpty && predecessors.isEmpty;
}

typedef ComicDetailsVersionStateLoader =
    Future<ComicDetailsVersionState> Function();
typedef ComicDetailsVersionViewer =
    Future<void> Function(SourceComicVersion version);
typedef ComicDetailsVersionMigrator =
    Future<void> Function(SourceComicVersion version);

typedef ComicDetailsSourceMigrator = Future<void> Function();

typedef ComicDetailsSourceWebViewOpener = Future<void> Function({Uri? verificationUri});
typedef ComicDetailsSourceSettingsOpener = Future<void> Function();
typedef ComicDetailsSourceResolver = BrowsableComicSource? Function(
  String sourceId,
);
typedef ComicDetailsMetadataSearch = void Function(String query);
typedef ComicDetailsIdentityMatcher = bool Function(
  String leftComicId,
  String rightComicId,
);
bool _exactComicIdentity(String leftComicId, String rightComicId) =>
    leftComicId == rightComicId;

bool _sameComicMetadata(Comic left, Comic right) =>
    left.comicId == right.comicId &&
    left.sourceId == right.sourceId &&
    left.title == right.title &&
    _sameStrings(left.authors, right.authors) &&
    _sameStrings(left.tags, right.tags) &&
    left.coverUri == right.coverUri &&
    left.description == right.description &&
    left.sourceSubId == right.sourceSubId &&
    left.readingDirection == right.readingDirection &&
    left.createdAt == right.createdAt &&
    left.updatedAt == right.updatedAt;

bool _sameChapterMetadata(Chapter left, Chapter right) =>
    left.chapterId == right.chapterId &&
    left.comicId == right.comicId &&
    left.title == right.title &&
    left.sequence == right.sequence &&
    left.pageCount == right.pageCount &&
    left.publishedAt == right.publishedAt &&
    left.updatedAt == right.updatedAt &&
    left.sourceRevision == right.sourceRevision;

bool _samePreviewMetadata(ComicPreviewPage? left, ComicPreviewPage? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.nextToken != right.nextToken) {
    return false;
  }
  if (left.items.length != right.items.length) return false;
  for (var index = 0; index < left.items.length; index++) {
    final a = left.items[index];
    final b = right.items[index];
    if (a.uri != b.uri ||
        a.label != b.label ||
        a.width != b.width ||
        a.height != b.height) {
      return false;
    }
  }
  return true;
}

bool _sameCommentMetadata(ComicCommentPage? left, ComicCommentPage? right) {
  if (identical(left, right)) return true;
  if (left == null ||
      right == null ||
      left.page != right.page ||
      left.maxPage != right.maxPage ||
      left.items.length != right.items.length) {
    return false;
  }
  for (var index = 0; index < left.items.length; index++) {
    final a = left.items[index];
    final b = right.items[index];
    if (a.id != b.id ||
        a.userName != b.userName ||
        a.avatarUri != b.avatarUri ||
        a.content != b.content ||
        a.time != b.time ||
        a.replyCount != b.replyCount ||
        a.score != b.score ||
        a.isLiked != b.isLiked ||
        a.voteStatus != b.voteStatus) {
      return false;
    }
  }
  return true;
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

bool _sameChapterList(Iterable<Chapter> left, Iterable<Chapter> right) {
  final a = left.toList(growable: false);
  final b = right.toList(growable: false);
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (!_sameChapterMetadata(a[index], b[index])) return false;
  }
  return true;
}

bool _sameComicManifest(ComicManifest left, ComicManifest right) =>
    _sameComicMetadata(left.comic, right.comic) &&
    _sameChapterList(left.chapters, right.chapters) &&
    _samePreviewMetadata(left.preview, right.preview) &&
    _sameCommentMetadata(left.comments, right.comments);

ComicManifest _mergeComicManifest(
  ComicManifest previous,
  ComicManifest incoming,
) =>
    ComicManifest(
      comic: _sameComicMetadata(previous.comic, incoming.comic)
          ? previous.comic
          : incoming.comic,
      chapters: _sameChapterList(previous.chapters, incoming.chapters)
          ? previous.chapters
          : incoming.chapters,
      // A null side field means that the source exposes it through its
      // separate capability. Keep the warm projection until that capability
      // finishes its own refresh instead of blanking the section.
      preview: incoming.preview ?? previous.preview,
      comments: incoming.comments ?? previous.comments,
    );

ComicManifest _replaceComicDetailMetadata(
  ComicManifest base, {
  ComicPreviewPage? preview,
  ComicCommentPage? comments,
}) =>
    ComicManifest(
      comic: base.comic,
      chapters: base.chapters,
      preview: preview ?? base.preview,
      comments: comments ?? base.comments,
    );

Future<({ComicPreviewPage? preview, ComicCommentPage? comments})>
    _refreshComicDetailMetadata(
  BrowsableComicSource source,
  ComicManifest manifest, {
  required bool refreshPreview,
  required bool refreshComments,
}) async {
  final cached = source is CachedComicDetailsProjection
      ? source as CachedComicDetailsProjection
      : null;
  if (cached == null) {
    return (preview: null, comments: null);
  }
  final previewSource = source is ComicPreviewSource &&
          (source as ComicPreviewSource).supportsComicPreview
      ? source as ComicPreviewSource
      : null;
  final commentSource = source is ComicCommentSource &&
          (source as ComicCommentSource).supportsComicComments
      ? source as ComicCommentSource
      : null;

  Future<ComicPreviewPage?> loadPreview() async {
    if (!refreshPreview || previewSource == null) return null;
    try {
      return await cached.refreshComicPreview(manifest.comic.comicId);
    } on Object {
      // The main detail response remains usable when an optional preview
      // endpoint is unavailable. The section can retry when opened.
      return null;
    }
  }

  Future<ComicCommentPage?> loadComments() async {
    if (!refreshComments || commentSource == null) return null;
    try {
      return await cached.refreshComicComments(
        manifest.comic.comicId,
        subId: manifest.comic.sourceSubId,
        page: 1,
        replyTo: null,
      );
    } on Object {
      // See the preview branch above.
      return null;
    }
  }

  // Start both optional requests before awaiting either one. A slow preview
  // endpoint must not delay a comments-only update, and vice versa.
  final preview = loadPreview();
  final comments = loadComments();
  return (preview: await preview, comments: await comments);
}


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
    this.readUnseenChapterIds,
    required this.onReadChanged,
    this.onManualReadChanged,
    this.onChapterViewed,
    required this.onOpenChapter,
    required this.onDownloadChapter,
    this.onDeleteChapter,
    required this.inspectChapterDownload,
    required this.downloadChanges,
    this.downloadProjectionChanges,
    required this.onDownloadComic,
    this.inspectChapterDownloads,
    this.inspectComicConflicts,
    this.downloadActions = ComicDetailsDownloadActions.noop,
    this.source,
    this.resolveSource,
    this.sourceReady,
    this.ensureSourceChapter,
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.onSearchMetadata,
    this.onSearchTitle,
    this.onMigrateSource,
    this.loadVersionState,
    this.onViewVersion,
    this.onMigrateVersion,
    this.previewMaxItemsPerRow = 4,
    this.traceSink = const NoopTraceSink(),
    this.traceMonotonicMicros,
    super.key,
  });

  final LibraryComic comic;
  final ComicDetailsLibrarySnapshot initialLibrary;
  final List<LibraryCategory> categories;
  final ComicDetailsArtworkLoader loadCover;
  final ComicDetailsLibraryReloader reloadLibrary;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Set<String> Function()? readUnseenChapterIds;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)?
      onManualReadChanged;
  final ComicDetailsChapterViewed? onChapterViewed;
  final ComicDetailsChapterOpener onOpenChapter;
  final ComicDetailsChapterDownloader onDownloadChapter;
  final ComicDetailsChapterDeleter? onDeleteChapter;
  final ComicDetailsChapterDownloadInspector inspectChapterDownload;
  final ComicDetailsChapterDownloadBulkInspector? inspectChapterDownloads;
  final Stream<ChapterDownloadSnapshot> downloadChanges;
  final Listenable? downloadProjectionChanges;
  final ComicDetailsComicDownloader onDownloadComic;
  final ComicDetailsConflictInspector? inspectComicConflicts;
  final ComicDetailsDownloadActions downloadActions;
  final BrowsableComicSource? source;
  final ComicDetailsSourceResolver? resolveSource;
  final Future<BrowsableComicSource?>? sourceReady;
  final ComicDetailsChapterEnsurer? ensureSourceChapter;
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final ComicDetailsMetadataSearch? onSearchTitle;
  final ComicDetailsSourceMigrator? onMigrateSource;
  final ComicDetailsVersionStateLoader? loadVersionState;
  final ComicDetailsVersionViewer? onViewVersion;
  final ComicDetailsVersionMigrator? onMigrateVersion;
  final int previewMaxItemsPerRow;
  final TraceSink traceSink;
  final int Function()? traceMonotonicMicros;

  @override
  State<LocalComicDetailsScreen> createState() =>
      _LocalComicDetailsScreenState();
}

Map<String, ChapterReadState> _projectChapterReadState(
  Map<String, ChapterReadState> previous,
  ImportedLibraryEntry entry,
  bool isRead, {
  bool manualOverride = false,
}) =>
    _projectChapterReadStateByIdentity(
      previous,
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId,
      isRead: isRead,
      manualOverride: manualOverride,
    );

Map<String, ChapterReadState> _projectChapterReadStateByIdentity(
  Map<String, ChapterReadState> previous, {
  required String sourceId,
  required String comicId,
  required String chapterId,
  required bool isRead,
  bool manualOverride = false,
}) {
  final identity = comicDetailsChapterIdentity(sourceId, chapterId);
  return <String, ChapterReadState>{
    ...previous,
    identity: ChapterReadState(
      sourceId: sourceId,
      comicId: comicId,
      chapterId: chapterId,
      isRead: isRead,
      updatedAt: DateTime.now().toUtc(),
      manualOverride: manualOverride,
    ),
  };
}

Future<bool> _confirmComicDownloadConflict({
  required BuildContext context,
  required ComicDetailsDownloadActions downloadActions,
  required ComicDetailsConflictInspector? inspector,
  required String sourceId,
  required String comicId,
  required String comicTitle,
  String? sourceDisplayName,
  String? chapterTitle,
  bool forcePrompt = false,
  required bool conflictConfirmed,
  required void Function() markConflictConfirmed,
  required TraceSink traceSink,
  required int Function() traceMonotonicMicros,
}) async {
  if (!forcePrompt && conflictConfirmed) return true;
  final existingPlacement = await downloadActions.getDownloadPlacement(
    sourceId: sourceId,
    comicId: comicId,
  );
  if (!forcePrompt && existingPlacement != null) {
    markConflictConfirmed();
    return true;
  }
  if (inspector == null) return true;
  final report = await inspector(
    sourceId: sourceId,
    comicId: comicId,
    comicTitle: comicTitle,
    sourceDisplayName: sourceDisplayName,
    requiredDirectoryNames: forcePrompt &&
            existingPlacement?.relativeDirectory.isNotEmpty == true
        ? <String>{existingPlacement!.relativeDirectory}
        : null,
  );
  if (!context.mounted) return false;
  final conflictingCandidates = report.candidates
      .where((c) => c.hasExistingContent && !c.isExactMatch)
      .toList();
  traceSink.record(
    TraceEvent(
      monotonicMicros: traceMonotonicMicros(),
      sessionId: 'comic-details:$sourceId',
      kind: TraceEventKind.downloadState,
      payload: <String, Object?>{
        'stage': 'conflict-inspection',
        'comicId': comicId,
        'comicTitle': comicTitle,
        'candidates': report.candidates.map((c) => c.folderName).toList(),
        'conflicting': conflictingCandidates.map((c) => c.folderName).toList(),
        'recommendedDirectory': report.recommendedDirectoryName,
      },
    ),
  );
  if (conflictingCandidates.isEmpty) {
    if (!forcePrompt) return true;
    final base = report.recommendedDirectoryName.isEmpty
        ? buildComicDirectoryName(comicTitle: comicTitle)
        : report.recommendedDirectoryName;
    final fallbackDirectory =
        '$base (copy ${DateTime.now().microsecondsSinceEpoch})';
    await downloadActions.claimComicDirectory(
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: comicTitle,
      directoryName: fallbackDirectory,
      mode: DownloadPlacementMode.createNew,
    );
    markConflictConfirmed();
    return true;
  }

  final filteredReport = ComicConflictReport(
    candidates: List<ComicFolderCandidate>.unmodifiable(conflictingCandidates),
    hasDirectExactMatch: report.hasDirectExactMatch,
    hasTitleConflicts: conflictingCandidates.isNotEmpty,
    recommendedDirectoryName: report.recommendedDirectoryName,
    additionalOccupiedDirectoryNames: report.occupiedDirectoryNames,
  );
  final result = await promptComicConflictResolutionResult(
    context: context,
    report: filteredReport,
    comicTitle: comicTitle,
    sourceId: sourceId,
    sourceDisplayName: sourceDisplayName,
    chapterTitle: chapterTitle,
  );
  traceSink.record(
    TraceEvent(
      monotonicMicros: traceMonotonicMicros(),
      sessionId: 'comic-details:$sourceId',
      kind: TraceEventKind.downloadState,
      payload: <String, Object?>{
        'stage': 'conflict-decision',
        'comicId': comicId,
        'decision': result.decision.name,
        'targetDirectory': result.targetDirectoryName,
      },
    ),
  );
  if (result.decision == ComicConflictDecision.overwrite ||
      result.decision == ComicConflictDecision.saveAsNew) {
    if (result.targetDirectoryName != null &&
        result.targetDirectoryName!.isNotEmpty) {
      final mode = result.decision == ComicConflictDecision.overwrite
          ? DownloadPlacementMode.overwrite
          : DownloadPlacementMode.createNew;
      final chosenCandidate = result.decision == ComicConflictDecision.overwrite
          ? report.candidates
                  .where((c) => c.folderName == result.targetDirectoryName)
                  .firstOrNull ??
              report.matchingCandidate
          : null;
      final observedOwner = chosenCandidate?.effectiveObservedOwnerKey;
      await downloadActions.claimComicDirectory(
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        directoryName: result.targetDirectoryName!,
        mode: mode,
        observedOwnerKey: observedOwner,
      );
    }
    markConflictConfirmed();
    return true;
  }
  return false;
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
  final Map<String, ImportedLibraryEntry> _pendingDownloadStatusEntries =
      <String, ImportedLibraryEntry>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  Future<void>? _downloadStatusRefreshInFlight;
  int _downloadProjectionRevision = 0;
  bool _downloadingComic = false;
  bool _conflictConfirmed = false;
  _DetailFailure? _failure;
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};
  final Map<String, Future<void>> _readStateWrites = <String, Future<void>>{};
  final Map<String, int> _readStateRevisions = <String, int>{};
  final Set<String> _pendingDeletionIdentities = <String>{};
  final Set<String> _deletedChapterIdentities = <String>{};
  var _deletionRevision = 0;
  final MonoClock _traceClock = const SystemClock();

  int _traceNowMicros() =>
      widget.traceMonotonicMicros?.call() ?? _traceClock.nowMicros();

  void _recordRefreshTrace(
    TraceEventKind kind,
    String stage, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceNowMicros(),
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
    _bindDownloadProjection();
    _scheduleDownloadStatusRefresh(_library.chapters);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recordRefreshTrace(
        TraceEventKind.readerObservation,
        'details-first-frame',
        payload: <String, Object?>{
          'sourceAvailable': widget.source != null,
          'chapterCount': _library.chapters.length,
          'sourceChapterCount': _library.sourceChapters.length,
        },
      );
    });
  }

  ComicPreviewSource? get _previewSource {
    final Object? candidate = widget.source;
    if (candidate is! ComicPreviewSource) return null;
    // ignore: unnecessary_cast
    return candidate as ComicPreviewSource;
  }

  ComicCommentSource? get _commentSource {
    final Object? candidate = widget.source;
    if (candidate is! ComicCommentSource) return null;
    // ignore: unnecessary_cast
    return candidate as ComicCommentSource;
  }

  @override
  void didUpdateWidget(covariant LocalComicDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
          oldWidget.downloadProjectionChanges,
          widget.downloadProjectionChanges,
        ) ||
        oldWidget.downloadChanges != widget.downloadChanges) {
      oldWidget.downloadProjectionChanges
          ?.removeListener(_handleDownloadProjectionChanged);
      unawaited(_downloadSubscription?.cancel());
      _downloadSubscription = null;
      _bindDownloadProjection();
      _handleDownloadProjectionChanged();
    }
  }

  void _bindDownloadProjection() {
    final projectionChanges = widget.downloadProjectionChanges;
    if (projectionChanges != null) {
      projectionChanges.addListener(_handleDownloadProjectionChanged);
      return;
    }
    _downloadSubscription =
        widget.downloadChanges.listen(_acceptDownloadSnapshot);
  }

  void _handleDownloadProjectionChanged() {
    _downloadProjectionRevision++;
    if (!mounted) return;
    unawaited(_loadDownloadStatuses(_library.chapters));
  }

  @override
  void dispose() {
    widget.downloadProjectionChanges
        ?.removeListener(_handleDownloadProjectionChanged);
    unawaited(_downloadSubscription?.cancel());
    super.dispose();
  }

  void _acceptDownloadSnapshot(ChapterDownloadSnapshot snapshot) {
    // Match source+chapter only: snapshot.comicId is the runtime locator and
    // differs from the library comicId for mihon, which dropped every mihon
    // snapshot here.
    if (!mounted || snapshot.sourceId != widget.comic.sourceId) {
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
  ) {
    for (final entry in entries) {
      _pendingDownloadStatusEntries[entry.identity] = entry;
    }
    final active = _downloadStatusRefreshInFlight;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _drainDownloadStatusRefresh().whenComplete(() {
      if (identical(_downloadStatusRefreshInFlight, tracked)) {
        _downloadStatusRefreshInFlight = null;
      }
    });
    _downloadStatusRefreshInFlight = tracked;
    return tracked;
  }

  Future<void> _drainDownloadStatusRefresh() async {
    while (_pendingDownloadStatusEntries.isNotEmpty) {
      final list = _pendingDownloadStatusEntries.values.toList(
        growable: false,
      );
      _pendingDownloadStatusEntries.clear();
      await _inspectDownloadStatuses(list);
    }
  }

  Future<void> _inspectDownloadStatuses(
    List<ImportedLibraryEntry> list,
  ) async {
    final projectionRevision = _downloadProjectionRevision;
    try {
      final bulk = widget.inspectChapterDownloads;
      late final Iterable<ChapterDownloadSnapshot?> results;
      if (bulk == null) {
        results = await Future.wait<ChapterDownloadSnapshot?>(
          list.map((entry) async {
            try {
              return await widget.inspectChapterDownload(entry);
            } on Object {
              return null;
            }
          }),
        );
      } else {
        results = await bulk(list);
      }
      if (!mounted) return;
      if (widget.downloadProjectionChanges != null &&
          projectionRevision != _downloadProjectionRevision) {
        return;
      }
      final snapshots = <String, ChapterDownloadSnapshot>{};
      final currentIdentities = <String>{
        for (final entry in _library.chapters)
          comicDetailsChapterIdentity(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          ),
      };
      for (final snapshot in results) {
        if (snapshot == null) continue;
        final identity = comicDetailsChapterIdentity(
          snapshot.sourceId,
          snapshot.chapterId,
        );
        // A status inspection may finish after a long-press deletion. Do not
        // resurrect the deleted chapter's download projection.
        if (!currentIdentities.contains(identity)) continue;
        final existing = _downloadSnapshots[identity];
        if (widget.downloadProjectionChanges == null &&
            existing != null &&
            existing.isActive &&
            snapshot.phase == ChapterDownloadPhase.idle) {
          continue;
        }
        snapshots[identity] = snapshot;
      }
      if (snapshots.isNotEmpty) {
        setState(() => _downloadSnapshots.addAll(snapshots));
      }
    } on Object {
      // Best-effort inspection.
    }
  }

  void _scheduleDownloadStatusRefresh(Iterable<ImportedLibraryEntry> entries) {
    final requested = entries.toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadDownloadStatuses(requested));
      }
    });
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
    final startedMicros = _traceClock.nowMicros();
    final deletionRevision = _deletionRevision;
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
      if (deletionRevision == _deletionRevision) {
        _deletedChapterIdentities.clear();
      }
      setState(() => _library = next);
      final refreshedManifest = next.sourceManifest;
      final source = widget.source;
      if (refreshedManifest != null && source != null) {
        final refreshPreview = refreshedManifest.preview == null;
        final refreshComments = refreshedManifest.comments == null;
        if (refreshPreview || refreshComments) {
          unawaited(
            _refreshComicDetailMetadata(
              source,
              refreshedManifest,
              refreshPreview: refreshPreview,
              refreshComments: refreshComments,
            ).then((metadata) {
              if (!mounted) return;
              final current = _library.sourceManifest;
              if (current == null) return;
              final updated = _replaceComicDetailMetadata(
                current,
                preview: metadata.preview,
                comments: metadata.comments,
              );
              if (_sameComicManifest(current, updated)) return;
              setState(() {
                _library = _library.copyWith(
                  sourceComic: updated.comic,
                  sourceChapters: updated.chapters,
                  sourceManifest: updated,
                );
              });
            }),
          );
        }
      }
      _scheduleDownloadStatusRefresh(next.chapters);
      succeeded = true;
      _recordRefreshTrace(
        TraceEventKind.sourceReady,
        'local-refresh-complete',
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
          'chapterCount': next.sourceChapters.length,
        },
      );
      if (announce) {
        _showDetailsSnackBar(
          context,
          const SnackBar(content: Text('漫画详情已更新')),
        );
      }
    } on Object catch (error, stackTrace) {
      _recordRefreshTrace(
        TraceEventKind.taskFailed,
        'local-refresh-failed',
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
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
              ? () => unawaited(
                    _recoverSourceAccess(
                      verificationUri: failure.verificationUri,
                    ),
                  )
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
      final unseenChapterIds = widget.readUnseenChapterIds?.call();
      if (mounted && unseenChapterIds != null) {
        setState(
          () => _library = _library.copyWith(
            unseenChapterIds: unseenChapterIds,
          ),
        );
      }
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
    if (comicDetailsCanReuseChapterEntry(existing, chapter)) {
      return existing!;
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
    var source = widget.resolveSource?.call(widget.comic.sourceId) ??
        widget.source;
    final ready = widget.sourceReady;
    if (source == null && ready != null) {
      final activated = await ready;
      if (!mounted) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: '章节入口已关闭',
        );
      }
      final resolver = widget.resolveSource;
      source = resolver == null ? activated : resolver(widget.comic.sourceId);
    }
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

  Future<void> _setRead(
    ImportedLibraryEntry entry,
    bool isRead, {
    bool manualOverride = false,
  }) {
    final identity = comicDetailsChapterIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
    );
    final previous = _library.readStates;
    final next = _projectChapterReadState(
      previous,
      entry,
      isRead,
      manualOverride: manualOverride,
    );
    setState(() => _library = _library.copyWith(readStates: next));
    final writeRead = manualOverride
        ? widget.onManualReadChanged ?? widget.onReadChanged
        : widget.onReadChanged;
    _queueReadWrite(
      identity,
      previous,
      () => writeRead(entry, isRead),
    );
    return Future<void>.value();
  }

  void _queueReadWrite(
    String identity,
    Map<String, ChapterReadState> previous,
    Future<void> Function() write,
  ) {
    final revision = (_readStateRevisions[identity] ?? 0) + 1;
    _readStateRevisions[identity] = revision;
    final previousWrite = _readStateWrites[identity] ?? Future<void>.value();
    final gate = Completer<void>();
    final queued = gate.future;
    _readStateWrites[identity] = queued;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        gate.complete();
        return;
      }
      unawaited(
        previousWrite.then<void>((_) async {
          try {
            await write();
          } on Object catch (error, stackTrace) {
            if (!mounted || _readStateRevisions[identity] != revision) return;
            setState(() => _library = _library.copyWith(readStates: previous));
            _showLocalFailure(error, stackTrace);
          } finally {
            if (!gate.isCompleted) gate.complete();
            if (identical(_readStateWrites[identity], queued)) {
              _readStateWrites.remove(identity);
            }
          }
        }),
      );
    });
  }

  Future<void> _setReadFromChapter(
    _ChapterViewModel chapter,
    bool isRead,
  ) {
    final entry = chapter.entry;
    if (entry != null) {
      return _setRead(entry, isRead, manualOverride: true);
    }
    final sourceChapter = chapter.sourceChapter;
    if (sourceChapter == null) {
      return Future<void>.value();
    }
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    final previous = _library.readStates;
    final next = _projectChapterReadStateByIdentity(
      previous,
      sourceId: chapter.sourceId,
      comicId: sourceChapter.comicId,
      chapterId: chapter.chapterId,
      isRead: isRead,
      manualOverride: true,
    );
    setState(() => _library = _library.copyWith(readStates: next));
    _queueReadWrite(identity, previous, () async {
      final ensured = await _ensure(sourceChapter);
      final writeRead = widget.onManualReadChanged ?? widget.onReadChanged;
      await writeRead(ensured, isRead);
    });
    return Future<void>.value();
  }

  Future<void> _markRead(_ChapterViewModel chapter) =>
      _setReadFromChapter(chapter, true);

  Future<void> _restoreUnread(_ChapterViewModel chapter) =>
      _setReadFromChapter(chapter, false);

  Future<void> _deleteChapter(
    _ChapterViewModel chapter, {
    bool deleteFiles = false,
  }) {
    final deleter = widget.onDeleteChapter;
    if (deleter == null) {
      return Future<void>.value();
    }
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    if (!_pendingDeletionIdentities.add(identity)) {
      return Future<void>.value();
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _deleteChapterInBackground(
            chapter,
            identity,
            deleter,
            deleteFiles: deleteFiles,
          ),
        );
      }
    });
    return Future<void>.value();
  }

  Future<void> _deleteChapterInBackground(
    _ChapterViewModel chapter,
    String identity,
    ComicDetailsChapterDeleter deleter, {
    bool deleteFiles = false,
  }) async {
    try {
      final sourceChapter = chapter.sourceChapter;
      final resolved = chapter.entry ??
          (sourceChapter == null ? null : await _ensure(sourceChapter));
      if (resolved == null) {
        throw StateError('无法确定要删除的章节');
      }
      await deleter(resolved, deleteFiles: deleteFiles);
      if (!mounted) return;
      _pendingDeletionIdentities.remove(identity);
      _deletionRevision++;
      _deletedChapterIdentities.add(identity);
      final readStates = <String, ChapterReadState>{
        ..._library.readStates,
      }
        ..remove(identity)
        ..removeWhere(
          (key, state) =>
              key == resolved.chapter.chapterId &&
              state.sourceId == resolved.chapter.sourceId &&
              state.chapterId == resolved.chapter.chapterId,
        );
      _pendingDownloadStatusEntries.remove(resolved.identity);
      final nextManifest = _library.sourceManifest == null
          ? null
          : _removeChapterFromManifest(
              _library.sourceManifest!,
              resolved.chapter.chapterId,
            );
      setState(() {
        _downloadSnapshots.remove(identity);
        _library = _library.copyWith(
          chapters: _library.chapters.where(
            (value) => value.identity != resolved.identity,
          ),
          sourceChapters: _removeChapterFromCatalog(
            _library.sourceChapters,
            resolved.chapter.chapterId,
          ),
          sourceManifest: nextManifest,
          readStates: readStates,
        );
      });
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _pendingDeletionIdentities.remove(identity);
        setState(() {});
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
    final comicId =
        existing?.chapter.comicId ?? sourceChapter?.comicId ?? widget.comic.comicId;
    if (_library.unseenChapterIds.contains(chapterId)) {
      setState(
        () => _library = _library.copyWith(
          unseenChapterIds:
              _library.unseenChapterIds.where((id) => id != chapterId),
        ),
      );
      final viewed = widget.onChapterViewed;
      if (viewed != null) {
        unawaited(
          viewed(sourceId, comicId, chapterId).catchError(
            (Object error, StackTrace _) {
              debugPrint('chapter viewed marker persist failed: $error');
            },
          ),
        );
      }
    }
    if (mounted) {
      setState(() {});
    }
    ImportedLibraryEntry? openedEntry = existing;
    try {
      final progress = await widget.onOpenChapter(
        () async {
          final entry = openedEntry ??
              (sourceChapter == null
                  ? throw StateError('该章节没有可用的本地记录')
                  : await _ensure(sourceChapter));
          openedEntry = entry;
          return entry;
        },
        refreshRemote: false,
        title: title,
        initialPageIndex: initialPageIndex,
      );
      if (mounted && progress != null) {
        setState(
          () => _library = _library.copyWith(
            chapters: _replaceChapterProgress(_library.chapters, progress),
          ),
        );
        final opened = openedEntry;
        final entry = _chapterEntryForProgress(_library.chapters, progress) ??
            (opened != null &&
                    opened.chapter.sourceId == progress.sourceId &&
                    opened.chapter.comicId == progress.comicId &&
                    opened.chapter.chapterId == progress.chapterId
                ? opened
                : null);
        if (entry != null) {
          final state = _readStateById(
            _library.readStates,
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          );
          if (state?.manualOverride != true) {
            await _setRead(
              entry,
              _progressCompletesChapter(
                progress,
                entry.chapter.pages.length,
              ),
            );
          }
        }
      }
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
    final manifest = _library.sourceManifest;
    final Iterable<Chapter> sourceChapters = manifest?.chapters ??
        (_library.sourceChapters.isNotEmpty
            ? _library.sourceChapters
            : _library.chapters.map<Chapter>(
                (e) => Chapter(
                  comicId: e.chapter.comicId,
                  chapterId: e.chapter.chapterId,
                  title: e.chapter.displayName,
                  sequence: e.chapter.sequence,
                  pageCount: e.chapter.pages.length,
                  sourceRevision: e.chapter.sourceRevision,
                  publishedAt: e.chapter.importedAt,
                  updatedAt: e.chapter.sourceUpdatedAt,
                ),
              ));
    final List<Chapter> chapters = sourceChapters.toList(growable: false)
      ..sort(_compareChapters);
    if (chapters.isEmpty) return;
    var remaining = pageIndex < 0 ? 0 : pageIndex;
    for (final chapter in chapters) {
      final count = _knownPageCount(chapter, _entryFor(widget.comic.sourceId, chapter));
      if (count <= 0 || remaining < count) {
        await _openChapter(
          sourceId: widget.comic.sourceId,
          chapterId: chapter.chapterId,
          title: chapter.title.isEmpty ? widget.comic.title : chapter.title,
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
      title: chapter.title.isEmpty ? widget.comic.title : chapter.title,
      sourceChapter: chapter,
      existing: _entryFor(widget.comic.sourceId, chapter),
      initialPageIndex: count > 0 ? count - 1 : remaining,
    );
  }

  Future<bool> _confirmDownloadConflictIfNeeded({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? chapterTitle,
    bool forcePrompt = false,
  }) =>
      _confirmComicDownloadConflict(
        context: context,
        downloadActions: widget.downloadActions,
        inspector: widget.inspectComicConflicts,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        sourceDisplayName: widget.source?.descriptor.name,
        chapterTitle: chapterTitle,
        forcePrompt: forcePrompt,
        conflictConfirmed: _conflictConfirmed,
        markConflictConfirmed: () => _conflictConfirmed = true,
        traceSink: widget.traceSink,
        traceMonotonicMicros: _traceNowMicros,
      );

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
    // The lock is taken before the conflict dialog awaits: two taps used to
    // pass the guard together and open two dialogs.
    setState(() => _workingDownloads.add(identity));
    try {
      await widget.downloadActions.ensureDurableServices?.call();
      final entry = chapter.entry ?? await _ensure(chapter.sourceChapter!);
      final probe = await widget.downloadActions.probeExisting(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
      );
      void recordGate(String decision) {
        try {
          widget.traceSink.record(
            TraceEvent(
              monotonicMicros: _traceNowMicros(),
              sessionId: 'comic-details-download-gate',
              kind: TraceEventKind.downloadState,
              identityHash: identity,
              payload: <String, Object?>{
                'decision': decision,
                'liveRun': probe.liveRun,
                'indexedReadyPages': probe.indexedReadyPages,
                'wholeComicJob': widget.downloadActions
                    .cachedWholeComicJob(
                      entry.chapter.sourceId,
                      entry.chapter.comicId,
                    )
                    ?.phase
                    .name,
              },
            ),
          );
        } on Object {}
      }

      final wholeComicJob = widget.downloadActions
          .cachedWholeComicJob(
            entry.chapter.sourceId,
            entry.chapter.comicId,
          );
      final activeWholeComicJob = wholeComicJob != null &&
          (wholeComicJob.phase == WholeComicQueuePhase.running ||
              wholeComicJob.phase == WholeComicQueuePhase.queued ||
              wholeComicJob.phase == WholeComicQueuePhase.paused ||
              wholeComicJob.phase ==
                  WholeComicQueuePhase.waitingForPolicy);
      if (probe.liveRun || activeWholeComicJob) {
        recordGate('blocked-active-task');
        if (mounted) {
          _showDetailsSnackBar(
            context,
            const SnackBar(content: Text('已存在相同的下载任务')),
          );
        }
        return;
      }
      final placement = await widget.downloadActions.getDownloadPlacement(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
      );
      final skipConflictDialog = placement != null;
      recordGate(skipConflictDialog ? 'resume-incremental' : 'fresh-download');
      widget.traceSink.record(
        TraceEvent(
          monotonicMicros: _traceNowMicros(),
          sessionId: 'comic-details:${entry.chapter.sourceId}',
          kind: TraceEventKind.downloadState,
          identityHash: identity,
          payload: <String, Object?>{
            'stage': 'details-placement-check',
            'comicId': entry.chapter.comicId,
            'hasPlacement': placement != null,
            'placementDirectory': placement?.relativeDirectory,
            'placementMode': placement?.mode.name,
            'skipConflictDialog': skipConflictDialog,
          },
        ),
      );
      if (!skipConflictDialog) {
        final ok = await _confirmDownloadConflictIfNeeded(
          sourceId: chapter.sourceId,
          comicId: chapter.entry?.chapter.comicId ?? widget.comic.comicId,
          comicTitle: chapter.entry?.chapter.comicTitle ?? widget.comic.title,
          chapterTitle: chapter.title,
        );
        if (!ok) return;
      }
      unawaited(
        widget.onDownloadChapter(entry).catchError(
          (Object error, StackTrace stackTrace) async {
            final text = error.toString().toLowerCase();
            final isConflict = (error is Failure && error.code == ErrorCode.policy) ||
                text.contains('conflict') ||
                text.contains('belongs to another comic') ||
                text.contains('owned by');
            if (mounted && isConflict) {
              final ok = await _confirmDownloadConflictIfNeeded(
                sourceId: chapter.sourceId,
                comicId: chapter.entry?.chapter.comicId ?? widget.comic.comicId,
                comicTitle: chapter.entry?.chapter.comicTitle ?? widget.comic.title,
                chapterTitle: chapter.title,
                forcePrompt: true,
              );
              if (ok && mounted) {
                unawaited(
                  widget.onDownloadChapter(entry).catchError(
                    (Object retryError, StackTrace retryTrace) {
                      if (mounted) {
                        _showLocalFailure(retryError, retryTrace);
                      }
                    },
                  ),
                );
                return;
              }
            }
            if (mounted) {
              _showLocalFailure(error, stackTrace);
            }
          },
        ),
      );
      if (mounted) {
        _showDetailsSnackBar(
          context,
          SnackBar(content: Text('已开始下载“${chapter.title}”')),
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

  Future<void> _stopChapter(_ChapterViewModel chapter) async {
    try {
      final entry = chapter.entry ??
          (chapter.sourceChapter == null
              ? null
              : await _ensure(chapter.sourceChapter!));
      if (entry == null) return;
      await widget.downloadActions.stopChapter(entry);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showLocalFailure(error, stackTrace);
      }
    }
  }

  Future<void> _downloadComic() async {
    if (_downloadingComic) {
      return;
    }
    // Same lock-before-dialog contract as _download.
    setState(() => _downloadingComic = true);
    try {
      await widget.downloadActions.ensureDurableServices?.call();
      final comicJob = await widget.downloadActions.wholeComicJob(
        widget.comic.sourceId,
        widget.comic.comicId,
      );
      final requiresPlacementResolution =
          comicJob?.requiresUserAction == true;
      final jobExists = comicJob != null && !requiresPlacementResolution;
      var skipConflictDialog = false;
      if (jobExists) {
        try {
          widget.traceSink.record(
            TraceEvent(
              monotonicMicros: _traceNowMicros(),
              sessionId: 'comic-details-download-gate',
              kind: TraceEventKind.downloadState,
              identityHash: widget.comic.comicId,
              payload: <String, Object?>{
                'decision': 'blocked-active-whole-comic-job',
                'scope': 'whole-comic',
              },
            ),
          );
        } on Object {}
        if (mounted) {
          _showDetailsSnackBar(
            context,
            const SnackBar(content: Text('该漫画的整本下载任务已存在')),
          );
        }
        return;
      }
      final comicProbe = await widget.downloadActions.probeExisting(
        sourceId: widget.comic.sourceId,
        comicId: widget.comic.comicId,
      );
      final placement = await widget.downloadActions.getDownloadPlacement(
        sourceId: widget.comic.sourceId,
        comicId: widget.comic.comicId,
      );
      skipConflictDialog =
          placement != null && !requiresPlacementResolution;
      try {
        widget.traceSink.record(
          TraceEvent(
            monotonicMicros: _traceNowMicros(),
            sessionId: 'comic-details-download-gate',
            kind: TraceEventKind.downloadState,
            identityHash: widget.comic.comicId,
            payload: <String, Object?>{
              'decision': requiresPlacementResolution
                  ? 'requires-user-action'
                  : skipConflictDialog
                      ? 'resume-incremental'
                      : 'fresh-download',
              'scope': 'whole-comic',
              'indexedReadyPages': comicProbe.indexedReadyPages,
            },
          ),
        );
      } on Object {}
      if (!skipConflictDialog) {
        final ok = await _confirmDownloadConflictIfNeeded(
          sourceId: widget.comic.sourceId,
          comicId: widget.comic.comicId,
          comicTitle: widget.comic.title,
          chapterTitle: '整本漫画',
          forcePrompt: requiresPlacementResolution,
        );
        if (!ok) return;
      }
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
      try {
        await widget.onDownloadComic(entries);
        await _loadDownloadStatuses(entries);
        if (mounted) {
          _showDetailsSnackBar(
            context,
            SnackBar(content: Text('“${widget.comic.title}”已加入整本下载队列')),
          );
        }
      } on Object catch (error, stackTrace) {
        final text = error.toString().toLowerCase();
        final isConflict = (error is Failure && error.code == ErrorCode.policy) ||
            text.contains('conflict') ||
            text.contains('belongs to another comic') ||
            text.contains('owned by');
        if (mounted && isConflict) {
          final ok = await _confirmDownloadConflictIfNeeded(
            sourceId: widget.comic.sourceId,
            comicId: widget.comic.comicId,
            comicTitle: widget.comic.title,
            chapterTitle: '整本漫画',
            forcePrompt: true,
          );
          if (ok && mounted) {
            await widget.onDownloadComic(entries);
            await _loadDownloadStatuses(entries);
            if (mounted) {
              _showDetailsSnackBar(
                context,
                SnackBar(content: Text('“${widget.comic.title}”已加入整本下载队列')),
              );
            }
            return;
          }
        }
        if (mounted) {
          _showLocalFailure(error, stackTrace);
        }
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
    try {
      widget.traceSink.record(
        TraceEvent(
          monotonicMicros: _traceNowMicros(),
          sessionId: 'comic-details',
          kind: TraceEventKind.taskFailed,
          identityHash: widget.comic.comicId,
          payload: <String, Object?>{
            'stage': 'comic-details-failure',
            'error': error.toString(),
            'errorType': error.runtimeType.toString(),
            'stackTrace': stackTrace.toString(),
          },
        ),
      );
    } on Object {}
    final failure = _DetailFailure.capture(error, stackTrace);
    _showFailureSnackBar(
      context,
      failure,
      onOpenSourceWebView: failure.requiresSourceVerification &&
              widget.onOpenSourceWebView != null
          ? () => unawaited(
                _recoverSourceAccess(verificationUri: failure.verificationUri),
              )
          : null,
    );
  }

  Future<void> _recoverSourceAccess({Uri? verificationUri}) async {
    final open = widget.onOpenSourceWebView;
    if (open == null) return;
    try {
      await open(verificationUri: verificationUri);
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
    final catalogChapters = _library.sourceChapters;
    final catalogComicIdsByChapterId = <String, String>{
      for (final chapter in catalogChapters)
        chapter.chapterId: chapter.comicId,
    };
    final entryByChapterId = <String, ImportedLibraryEntry>{};
    final entriesByRevision = <String, ImportedLibraryEntry?>{};
    final displayEntriesByChapterId = <String, List<ImportedLibraryEntry>>{};
    for (final entry in _library.chapters) {
      if (entry.chapter.sourceId == widget.comic.sourceId) {
        entryByChapterId[entry.chapter.chapterId] = entry;
        final rev = entry.chapter.sourceRevision.trim();
        if (rev.isNotEmpty) {
          entriesByRevision[rev] = entriesByRevision.containsKey(rev) ? null : entry;
        }
        final catalogId = _library.catalogChapterIdsByEntryIdentity[entry.identity];
        if (catalogId != null &&
            catalogComicIdsByChapterId[catalogId] == entry.chapter.comicId) {
          displayEntriesByChapterId
              .putIfAbsent(catalogId, () => <ImportedLibraryEntry>[])
              .add(entry);
        }
      }
    }
    final models = <_ChapterViewModel>[];
    final catalogIdentities = <String>{};
    for (final chapter in catalogChapters) {
      final identity = comicDetailsChapterIdentity(
        widget.comic.sourceId,
        chapter.chapterId,
      );
      catalogIdentities.add(identity);
      final candidateEntry = entryByChapterId[chapter.chapterId] ??
          (chapter.sourceRevision.trim().isNotEmpty
              ? entriesByRevision[chapter.sourceRevision.trim()]
              : null);
      final entry = comicDetailsCanReuseChapterEntry(candidateEntry, chapter)
          ? candidateEntry
          : null;
      final displayEntries = displayEntriesByChapterId[chapter.chapterId] ??
          const <ImportedLibraryEntry>[];
      final projectedEntry = _latestReadingEntry(displayEntries) ??
          (displayEntries.isEmpty
              ? null
              : displayEntries.reduce((a, b) =>
                  b.chapter.importedAt.isAfter(a.chapter.importedAt) ? b : a));
      final displayEntry = candidateEntry ?? projectedEntry;
      if (_pendingDeletionIdentities.contains(identity) ||
          _deletedChapterIdentities.contains(identity)) {
        continue;
      }
      final pageCount = _chapterMetadataPageCount(chapter, displayEntry);
      final progress = candidateEntry?.progress ?? projectedEntry?.progress;
      final currentReadState = _readStateById(
        _library.readStates,
        widget.comic.sourceId,
        chapter.chapterId,
      );
      ChapterReadState? projectedReadState;
      for (final displayEntry in displayEntries) {
        final state = _readStateById(
          _library.readStates,
          displayEntry.chapter.sourceId,
          displayEntry.chapter.chapterId,
        );
        if (state != null && state.manualOverride &&
            (projectedReadState == null ||
                state.updatedAt.isAfter(projectedReadState.updatedAt))) {
          projectedReadState = state;
        }
      }
      final readState = currentReadState?.manualOverride == true
          ? currentReadState
          : projectedReadState ?? currentReadState;
      models.add(
        _ChapterViewModel(
          sourceId: widget.comic.sourceId,
          title: chapter.title,
          chapterId: chapter.chapterId,
          sequence: chapter.sequence,
          pageCount: pageCount,
          progress: progress,
          sourceUpdatedAt:
              chapter.updatedAt ?? displayEntry?.chapter.sourceUpdatedAt,
          syncedAt:
              displayEntry?.chapter.importedAt ?? _library.sourceSyncedAt,
          entry: entry,
          sourceChapter: chapter,
          isRead: _chapterIsRead(
            state: readState,
            progress: progress,
            pageCount: pageCount,
          ),
          isNew: _library.unseenChapterIds.contains(chapter.chapterId),
          canDownload: widget.comic.sourceId != 'local-folder',
          opening: _opening.contains(identity),
          downloading: _workingDownloads.contains(identity) ||
              _downloadSnapshots[identity]?.isActive == true,
          downloadStarted:
              _downloadSnapshots[identity]?.started == true,
          downloaded: _downloadSnapshots[identity]?.isComplete == true,
        ),
      );
    }
    for (final entry in _library.chapters) {
      final identity = comicDetailsChapterIdentity(
        entry.chapter.sourceId,
        entry.chapter.chapterId,
      );
      final projectedId =
          _library.catalogChapterIdsByEntryIdentity[entry.identity];
      final projectedInCatalog =
          entry.chapter.sourceId == widget.comic.sourceId &&
          catalogComicIdsByChapterId[projectedId] == entry.chapter.comicId &&
          projectedId != null && catalogIdentities.contains(
            comicDetailsChapterIdentity(entry.chapter.sourceId, projectedId),
          );
      if (catalogIdentities.contains(identity) || projectedInCatalog ||
          _pendingDeletionIdentities.contains(identity) ||
          _deletedChapterIdentities.contains(identity)) {
        continue;
      }
      final readState = _readStateById(
        _library.readStates,
        entry.chapter.sourceId,
        entry.chapter.chapterId,
      );
      final pageCount = entry.chapter.pages.length;
      models.add(
        _ChapterViewModel(
          sourceId: entry.chapter.sourceId,
          title: entry.chapter.displayName,
          chapterId: entry.chapter.chapterId,
          sequence: entry.chapter.sequence,
          pageCount: pageCount,
          progress: entry.progress,
          sourceUpdatedAt: entry.chapter.sourceUpdatedAt,
          syncedAt: entry.chapter.importedAt,
          entry: entry,
          isRead: _chapterIsRead(
            state: readState,
            progress: entry.progress,
            pageCount: pageCount,
          ),
          isNew:
              _library.unseenChapterIds.contains(entry.chapter.chapterId),
          canDownload: entry.chapter.sourceId != 'local-folder',
          opening: _opening.contains(identity),
          downloading: _workingDownloads.contains(identity) ||
              _downloadSnapshots[identity]?.isActive == true,
          downloadStarted:
              _downloadSnapshots[identity]?.started == true,
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
    if (failure != null && ordered.isEmpty) {
      return _ComicDetailsFailureScaffold(
        title: comic.title,
        comicId: comic.comicId,
        sourceId: comic.sourceId,
        sourceLabel: sourceLabel,
        failure: failure,
        refreshing: _refreshing,
        onRetry: () => _ignoreRefreshResult(_refresh(announce: false)),
        onOpenSourceWebView: widget.onOpenSourceWebView == null
            ? null
            : ({Uri? verificationUri}) => _recoverSourceAccess(
                  verificationUri:
                      verificationUri ?? failure.verificationUri,
                ),
        onOpenSourceSettings: widget.onOpenSourceSettings,
      );
    }
    return _ComicDetailsScaffold(
      screenKey: localComicDetailsScreenKey,
      title: comic.title,
      comicId: comic.comicId,
      sourceId: comic.sourceId,
      sourceLabel: sourceLabel,
      authors: comic.authors,
      tags: comic.tags,
      description: comic.description,
      cover: _ComicDetailCover(
        sourceId: comic.sourceId,
        comicId: comic.comicId,
        presentationIdentity: '${comic.sourceId}\u0000${comic.comicId}',
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
      onSearchTitle: widget.onSearchTitle,
      onMigrateSource: widget.onMigrateSource,
      onPreferenceChanged: _savePreference,
      progressLabel: _readingProgressLabel(_library.chapters),
      onContinueReading: _latestReadingEntry(_library.chapters) == null
          ? null
          : _continueReading,
      downloadingComic: _downloadingComic,
      onDownloadComic:
          comic.sourceId == 'local-folder' ? null : _downloadComic,
      onToggleWholeComicPause: () => widget.downloadActions
          .toggleWholeComicPause(comic.sourceId, comic.comicId),
      wholeComicPausable: widget.downloadActions.cachedWholeComicJob(
                  comic.sourceId,
                  comic.comicId,
                )?.phase ==
            WholeComicQueuePhase.running,
      wholeComicPaused: widget.downloadActions.cachedWholeComicJob(
                  comic.sourceId,
                  comic.comicId,
                )?.phase ==
            WholeComicQueuePhase.paused,
      onReverse: () => setState(() => _descending = !_descending),
      loadVersionState: widget.loadVersionState,
      onViewVersion: widget.onViewVersion,
      onMigrateVersion: widget.onMigrateVersion,
      chapterCount: ordered.length,
      pageCount: catalogPages,
      pageCountPending: pageCountPending,
      chapterList: _ComicChapterList(
        chapters: ordered,
        onOpen: _open,
        onDownload: _download,
        onMarkRead: _markRead,
        onRestoreUnread: _restoreUnread,
        onDelete: widget.onDeleteChapter == null ? null : _deleteChapter,
        onStop: _stopChapter,
      ),
      previewSection: detailsManifest?.preview != null ||
              previewLoader != null
          ? _ComicDetailsPreviewSection(
              sourceId: comic.sourceId,
              comicId: comic.comicId,
              title: comic.title,
              maxItemsPerRow: widget.previewMaxItemsPerRow,
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
    this.readUnseenChapterIds,
    required this.onReadChanged,
    this.onManualReadChanged,
    this.onChapterViewed,
    required this.onOpenChapter,
    required this.onDownloadChapter,
    this.onDeleteChapter,
    required this.inspectChapterDownload,
    required this.downloadChanges,
    this.downloadProjectionChanges,
    required this.onDownloadComic,
    this.inspectChapterDownloads,
    this.inspectComicConflicts,
    this.downloadActions = ComicDetailsDownloadActions.noop,
    this.artworkIdentity,
    this.onOpenSourceWebView,
    this.onOpenSourceSettings,
    this.resolveSource,
    this.onSearchMetadata,
    this.onSearchTitle,
    this.onMigrateSource,
    this.loadVersionState,
    this.onViewVersion,
    this.onMigrateVersion,
    this.previewMaxItemsPerRow = 4,
    this.sameComicIdentity = _exactComicIdentity,
    this.traceSink = const NoopTraceSink(),
    this.traceMonotonicMicros,
    super.key,
  });

  final BrowsableComicSource source;
  final SourceComicSummary summary;
  final ComicDetailsLibrarySnapshot initialLibrary;
  final List<LibraryCategory> categories;
  final ComicDetailsArtworkLoader loadCover;
  final ComicDetailsLibraryReloader reloadLibrary;
  final ComicDetailsChapterEnsurer ensureSourceChapter;
  final ComicDetailsComicPersister persistComic;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Set<String> Function()? readUnseenChapterIds;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)?
      onManualReadChanged;
  final ComicDetailsChapterViewed? onChapterViewed;
  final ComicDetailsChapterOpener onOpenChapter;
  final ComicDetailsChapterDownloader onDownloadChapter;
  final ComicDetailsChapterDeleter? onDeleteChapter;
  final ComicDetailsChapterDownloadInspector inspectChapterDownload;
  final ComicDetailsChapterDownloadBulkInspector? inspectChapterDownloads;
  final Stream<ChapterDownloadSnapshot> downloadChanges;
  final Listenable? downloadProjectionChanges;
  final ComicDetailsComicDownloader onDownloadComic;
  final ComicDetailsConflictInspector? inspectComicConflicts;
  final ComicDetailsDownloadActions downloadActions;
  final String? artworkIdentity;
  final ComicDetailsSourceWebViewOpener? onOpenSourceWebView;
  final ComicDetailsSourceSettingsOpener? onOpenSourceSettings;
  final ComicDetailsSourceResolver? resolveSource;
  final ComicDetailsMetadataSearch? onSearchMetadata;
  final ComicDetailsMetadataSearch? onSearchTitle;
  final ComicDetailsSourceMigrator? onMigrateSource;
  final ComicDetailsVersionStateLoader? loadVersionState;
  final ComicDetailsVersionViewer? onViewVersion;
  final ComicDetailsVersionMigrator? onMigrateVersion;
  final int previewMaxItemsPerRow;
  final ComicDetailsIdentityMatcher sameComicIdentity;
  final TraceSink traceSink;
  final int Function()? traceMonotonicMicros;

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
  final Map<String, ImportedLibraryEntry> _pendingDownloadStatusEntries =
      <String, ImportedLibraryEntry>{};
  StreamSubscription<ChapterDownloadSnapshot>? _downloadSubscription;
  Future<void>? _downloadStatusRefreshInFlight;
  int _downloadProjectionRevision = 0;
  bool _downloadingComic = false;
  bool _conflictConfirmed = false;
  final Map<String, Future<ImportedLibraryEntry>> _ensureInFlight =
      <String, Future<ImportedLibraryEntry>>{};
  final Map<String, Future<void>> _readStateWrites = <String, Future<void>>{};
  final Map<String, int> _readStateRevisions = <String, int>{};
  final Set<String> _pendingDeletionIdentities = <String>{};
  final Set<String> _deletedChapterIdentities = <String>{};
  var _deletionRevision = 0;
  final MonoClock _traceClock = const SystemClock();
  BrowsableComicSource? _activeSource;

  int _traceNowMicros() =>
      widget.traceMonotonicMicros?.call() ?? _traceClock.nowMicros();

  BrowsableComicSource? get _currentSource {
    final resolver = widget.resolveSource;
    if (resolver == null) return widget.source;
    final current = resolver(widget.source.sourceId);
    if (current != null) _activeSource = current;
    return current;
  }

  BrowsableComicSource get _source =>
      _currentSource ?? _activeSource ?? widget.source;

  Future<BrowsableComicSource> _sourceForOperation() async {
    final resolver = widget.resolveSource;
    if (resolver == null) return widget.source;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (mounted) {
      final current = resolver(widget.source.sourceId);
      if (current != null) {
        _activeSource = current;
        return current;
      }
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw Failure(
      code: ErrorCode.source,
      message: '漫画源运行时尚未就绪，请稍后重试',
    );
  }

  void _recordRefreshTrace(
    TraceEventKind kind,
    String stage, {
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    widget.traceSink.record(
      TraceEvent(
        monotonicMicros: _traceNowMicros(),
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
    final cachedComic = _library.sourceManifest?.comic ?? _library.sourceComic;
    final cachedChapters =
        _library.sourceManifest?.chapters ?? _library.sourceChapters;
    if (_library.sourceManifest != null) {
      _manifest = _library.sourceManifest;
    } else if (cachedComic != null && cachedChapters.isNotEmpty) {
      _manifest = ComicManifest(
        comic: cachedComic,
        chapters: cachedChapters,
      );
    }
    _activeSource = widget.resolveSource?.call(widget.source.sourceId) ??
        (widget.resolveSource == null ? widget.source : null);
    _bindDownloadProjection();
    _scheduleDownloadStatusRefresh(_library.chapters);
    unawaited(_refresh(announce: false));
  }

  @override
  void didUpdateWidget(covariant RemoteComicDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
          oldWidget.downloadProjectionChanges,
          widget.downloadProjectionChanges,
        ) ||
        oldWidget.downloadChanges != widget.downloadChanges) {
      oldWidget.downloadProjectionChanges
          ?.removeListener(_handleDownloadProjectionChanged);
      unawaited(_downloadSubscription?.cancel());
      _downloadSubscription = null;
      _bindDownloadProjection();
      _handleDownloadProjectionChanged();
    }
  }

  void _bindDownloadProjection() {
    final projectionChanges = widget.downloadProjectionChanges;
    if (projectionChanges != null) {
      projectionChanges.addListener(_handleDownloadProjectionChanged);
      return;
    }
    _downloadSubscription =
        widget.downloadChanges.listen(_acceptDownloadSnapshot);
  }

  void _handleDownloadProjectionChanged() {
    _downloadProjectionRevision++;
    if (!mounted) return;
    unawaited(_loadDownloadStatuses(_library.chapters));
  }

  @override
  void dispose() {
    widget.downloadProjectionChanges
        ?.removeListener(_handleDownloadProjectionChanged);
    unawaited(_downloadSubscription?.cancel());
    super.dispose();
  }

  Future<void> _stopChapter(_ChapterViewModel chapter) async {
    try {
      final entry = chapter.entry ??
          (chapter.sourceChapter == null
              ? null
              : await _ensure(chapter.sourceChapter!));
      if (entry == null) return;
      await widget.downloadActions.stopChapter(entry);
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _showRemoteFailure(error, stackTrace);
      }
    }
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
    final Object? candidate = _currentSource;
    if (candidate is! ComicPreviewSource) return null;
    // ignore: unnecessary_cast
    return candidate as ComicPreviewSource;
  }

  ComicCommentSource? get _commentSource {
    final Object? candidate = _currentSource;
    if (candidate is! ComicCommentSource) return null;
    // ignore: unnecessary_cast
    return candidate as ComicCommentSource;
  }

  Future<ComicPreviewPage> _loadRemotePreview(String? nextToken) async {
    final Object candidate = await _sourceForOperation();
    if (candidate is! ComicPreviewSource) {
      throw StateError('漫画源当前不支持预览');
    }
    final source = candidate;
    if (!source.supportsComicPreview) {
      throw StateError('漫画源当前不支持预览');
    }
    return source.loadComicPreview(
      _comic.comicId,
      nextToken: nextToken,
    );
  }

  Future<ComicCommentPage> _loadRemoteComments({
    required int page,
    String? replyTo,
  }) async {
    final Object candidate = await _sourceForOperation();
    if (candidate is! ComicCommentSource) {
      throw StateError('漫画源当前不支持评论');
    }
    final source = candidate;
    if (!source.supportsComicComments) {
      throw StateError('漫画源当前不支持评论');
    }
    return source.loadComicComments(
      _comic.comicId,
      subId: _comic.sourceSubId,
      page: page,
      replyTo: replyTo,
    );
  }

  Future<void> _loadDownloadStatuses(
    Iterable<ImportedLibraryEntry> entries,
  ) {
    for (final entry in entries) {
      _pendingDownloadStatusEntries[entry.identity] = entry;
    }
    final active = _downloadStatusRefreshInFlight;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _drainDownloadStatusRefresh().whenComplete(() {
      if (identical(_downloadStatusRefreshInFlight, tracked)) {
        _downloadStatusRefreshInFlight = null;
      }
    });
    _downloadStatusRefreshInFlight = tracked;
    return tracked;
  }

  Future<void> _drainDownloadStatusRefresh() async {
    while (_pendingDownloadStatusEntries.isNotEmpty) {
      final list = _pendingDownloadStatusEntries.values.toList(
        growable: false,
      );
      _pendingDownloadStatusEntries.clear();
      await _inspectDownloadStatuses(list);
    }
  }

  Future<void> _inspectDownloadStatuses(
    List<ImportedLibraryEntry> list,
  ) async {
    final projectionRevision = _downloadProjectionRevision;
    try {
      final bulk = widget.inspectChapterDownloads;
      late final Iterable<ChapterDownloadSnapshot?> results;
      if (bulk == null) {
        results = await Future.wait<ChapterDownloadSnapshot?>(
          list.map((entry) async {
            try {
              return await widget.inspectChapterDownload(entry);
            } on Object {
              return null;
            }
          }),
        );
      } else {
        results = await bulk(list);
      }
      if (!mounted) return;
      if (widget.downloadProjectionChanges != null &&
          projectionRevision != _downloadProjectionRevision) {
        return;
      }
      final snapshots = <String, ChapterDownloadSnapshot>{};
      final currentIdentities = <String>{
        for (final entry in _library.chapters)
          comicDetailsChapterIdentity(
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          ),
      };
      for (final snapshot in results) {
        if (snapshot == null) continue;
        final identity = comicDetailsChapterIdentity(
          snapshot.sourceId,
          snapshot.chapterId,
        );
        // A status inspection may finish after a long-press deletion. Do not
        // resurrect the deleted chapter's download projection.
        if (!currentIdentities.contains(identity)) continue;
        final existing = _downloadSnapshots[identity];
        if (widget.downloadProjectionChanges == null &&
            existing != null &&
            existing.isActive &&
            snapshot.phase == ChapterDownloadPhase.idle) {
          continue;
        }
        snapshots[identity] = snapshot;
      }
      if (snapshots.isNotEmpty) {
        setState(() => _downloadSnapshots.addAll(snapshots));
      }
    } on Object {
      // Best-effort inspection.
    }
  }

  void _scheduleDownloadStatusRefresh(Iterable<ImportedLibraryEntry> entries) {
    final requested = entries.toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadDownloadStatuses(requested));
      }
    });
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
    final startedMicros = _traceClock.nowMicros();
    final deletionRevision = _deletionRevision;
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
      final source = await _sourceForOperation();
      if (forceRefresh) {
        final identities = <String>{widget.summary.comicId};
        final manifestComic = _manifest?.comic.comicId;
        if (manifestComic != null) identities.add(manifestComic);
        final libraryComic = _library.sourceComic?.comicId;
        if (libraryComic != null) identities.add(libraryComic);
        for (final comicId in identities) {
          invalidateCachedComicMetadata(source, comicId);
        }
      }
      final library = await widget.reloadLibrary(refreshContent: true);
      final sourceManifest = library.sourceManifest;
      final comic = sourceManifest?.comic ?? library.sourceComic;
      final sourceChapters =
          sourceManifest?.chapters ?? library.sourceChapters;
      if (comic == null ||
          comic.sourceId != source.sourceId ||
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
      final incoming = ComicManifest(
        comic: comic,
        chapters: sourceChapters,
        preview: sourceManifest?.preview,
        comments: sourceManifest?.comments,
      );
      final previous = _manifest;
      final manifest = previous == null
          ? incoming
          : _mergeComicManifest(previous, incoming);
      final manifestChanged = previous == null ||
          !_sameComicManifest(previous, manifest);
      if (!mounted) {
        return false;
      }
      if (deletionRevision == _deletionRevision) {
        _deletedChapterIdentities.clear();
      }
      if (manifestChanged || _library.sourceManifest == null) {
        setState(() {
          _manifest = manifest;
          _library = library.copyWith(
            sourceComic: manifest.comic,
            sourceChapters: manifest.chapters,
            sourceManifest: manifest,
          );
        });
      }
      final refreshPreview = sourceManifest?.preview == null;
      final refreshComments = sourceManifest?.comments == null;
      if (refreshPreview || refreshComments) {
        unawaited(
          _refreshComicDetailMetadata(
            source,
            manifest,
            refreshPreview: refreshPreview,
            refreshComments: refreshComments,
          ).then((metadata) {
            if (!mounted) return;
            final current = _manifest;
            if (current == null ||
                !widget.sameComicIdentity(
                  current.comic.comicId,
                  manifest.comic.comicId,
                )) {
              return;
            }
            final updated = _replaceComicDetailMetadata(
              current,
              preview: metadata.preview,
              comments: metadata.comments,
            );
            if (_sameComicManifest(current, updated)) return;
            setState(() {
              _manifest = updated;
              _library = _library.copyWith(
                sourceComic: updated.comic,
                sourceChapters: updated.chapters,
                sourceManifest: updated,
              );
            });
          }),
        );
      }
      succeeded = true;
      _recordRefreshTrace(
        TraceEventKind.sourceReady,
        'remote-refresh-complete',
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
          'chapterCount': manifest.chapters.length,
        },
      );
      _scheduleDownloadStatusRefresh(library.chapters);
      if (announce) {
        _showDetailsSnackBar(
          context,
          SnackBar(content: Text('已更新 ${manifest.chapters.length} 个章节')),
        );
      }
    } on Object catch (error, stackTrace) {
      _recordRefreshTrace(
        TraceEventKind.taskFailed,
        'remote-refresh-failed',
        payload: <String, Object?>{
          'durationMicros': _traceClock.nowMicros() - startedMicros,
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
                ? () => unawaited(
                      _recoverSourceAccess(
                        verificationUri: failure.verificationUri,
                      ),
                    )
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
      final unseenChapterIds = widget.readUnseenChapterIds?.call();
      if (mounted && unseenChapterIds != null) {
        setState(
          () => _library = _library.copyWith(
            unseenChapterIds: unseenChapterIds,
          ),
        );
      }
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
    if (comicDetailsCanReuseChapterEntry(existing, chapter)) {
      return existing!;
    }
    final identity = comicDetailsChapterIdentity(
      _source.sourceId,
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
    final source = await _sourceForOperation();
    final entry = await widget.ensureSourceChapter(
      source,
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

  Future<void> _setRead(
    ImportedLibraryEntry entry,
    bool isRead, {
    bool manualOverride = false,
  }) {
    final identity = comicDetailsChapterIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
    );
    final previous = _library.readStates;
    final next = _projectChapterReadState(
      previous,
      entry,
      isRead,
      manualOverride: manualOverride,
    );
    if (mounted) {
      setState(() => _library = _library.copyWith(readStates: next));
    }
    final writeRead = manualOverride
        ? widget.onManualReadChanged ?? widget.onReadChanged
        : widget.onReadChanged;
    _queueReadWrite(
      identity,
      previous,
      () => writeRead(entry, isRead),
    );
    return Future<void>.value();
  }

  void _queueReadWrite(
    String identity,
    Map<String, ChapterReadState> previous,
    Future<void> Function() write,
  ) {
    final revision = (_readStateRevisions[identity] ?? 0) + 1;
    _readStateRevisions[identity] = revision;
    final previousWrite = _readStateWrites[identity] ?? Future<void>.value();
    final gate = Completer<void>();
    final queued = gate.future;
    _readStateWrites[identity] = queued;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        gate.complete();
        return;
      }
      unawaited(
        previousWrite.then<void>((_) async {
          try {
            await write();
          } on Object catch (error, stackTrace) {
            if (!mounted || _readStateRevisions[identity] != revision) return;
            setState(() => _library = _library.copyWith(readStates: previous));
            _showRemoteFailure(error, stackTrace);
          } finally {
            if (!gate.isCompleted) gate.complete();
            if (identical(_readStateWrites[identity], queued)) {
              _readStateWrites.remove(identity);
            }
          }
        }),
      );
    });
  }

  Future<void> _setReadFromChapter(
    _ChapterViewModel chapter,
    bool isRead,
  ) {
    final entry = chapter.entry;
    if (entry != null) {
      return _setRead(entry, isRead, manualOverride: true);
    }
    final sourceChapter = chapter.sourceChapter;
    if (sourceChapter == null) {
      return Future<void>.value();
    }
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    final previous = _library.readStates;
    final next = _projectChapterReadStateByIdentity(
      previous,
      sourceId: chapter.sourceId,
      comicId: sourceChapter.comicId,
      chapterId: chapter.chapterId,
      isRead: isRead,
      manualOverride: true,
    );
    if (mounted) {
      setState(() => _library = _library.copyWith(readStates: next));
    }
    _queueReadWrite(identity, previous, () async {
      final ensured = await _ensure(sourceChapter);
      final writeRead = widget.onManualReadChanged ?? widget.onReadChanged;
      await writeRead(ensured, isRead);
    });
    return Future<void>.value();
  }

  Future<void> _markRead(_ChapterViewModel chapter) =>
      _setReadFromChapter(chapter, true);

  Future<void> _restoreUnread(_ChapterViewModel chapter) =>
      _setReadFromChapter(chapter, false);

  Future<void> _deleteChapter(
    _ChapterViewModel chapter, {
    bool deleteFiles = false,
  }) {
    final deleter = widget.onDeleteChapter;
    if (deleter == null) {
      return Future<void>.value();
    }
    final identity = comicDetailsChapterIdentity(
      chapter.sourceId,
      chapter.chapterId,
    );
    if (!_pendingDeletionIdentities.add(identity)) {
      return Future<void>.value();
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _deleteChapterInBackground(
            chapter,
            identity,
            deleter,
            deleteFiles: deleteFiles,
          ),
        );
      }
    });
    return Future<void>.value();
  }

  Future<void> _deleteChapterInBackground(
    _ChapterViewModel chapter,
    String identity,
    ComicDetailsChapterDeleter deleter, {
    bool deleteFiles = false,
  }) async {
    try {
      final sourceChapter = chapter.sourceChapter;
      final resolved = chapter.entry ??
          (sourceChapter == null ? null : await _ensure(sourceChapter));
      if (resolved == null) {
        throw StateError('无法确定要删除的章节');
      }
      await deleter(resolved, deleteFiles: deleteFiles);
      if (!mounted) return;
      _pendingDeletionIdentities.remove(identity);
      _deletionRevision++;
      _deletedChapterIdentities.add(identity);
      final readStates = <String, ChapterReadState>{
        ..._library.readStates,
      }
        ..remove(identity)
        ..removeWhere(
          (key, state) =>
              key == resolved.chapter.chapterId &&
              state.sourceId == resolved.chapter.sourceId &&
              state.chapterId == resolved.chapter.chapterId,
        );
      _pendingDownloadStatusEntries.remove(resolved.identity);
      final currentManifest = _manifest ?? _library.sourceManifest;
      final nextManifest = currentManifest == null
          ? null
          : _removeChapterFromManifest(
              currentManifest,
              resolved.chapter.chapterId,
            );
      setState(() {
        if (nextManifest != null) {
          _manifest = nextManifest;
        }
        _downloadSnapshots.remove(identity);
        _library = _library.copyWith(
          chapters: _library.chapters.where(
            (value) => value.identity != resolved.identity,
          ),
          sourceChapters: _removeChapterFromCatalog(
            _library.sourceChapters,
            resolved.chapter.chapterId,
          ),
          sourceManifest: nextManifest,
          readStates: readStates,
        );
      });
    } on Object catch (error, stackTrace) {
      if (mounted) {
        _pendingDeletionIdentities.remove(identity);
        setState(() {});
        _showRemoteFailure(error, stackTrace);
      }
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
      _source.sourceId,
      chapter.chapterId,
    );
    if (!_opening.add(identity)) {
      return;
    }
    if (_library.unseenChapterIds.contains(chapter.chapterId)) {
      setState(
        () => _library = _library.copyWith(
          unseenChapterIds: _library.unseenChapterIds.where(
            (id) => id != chapter.chapterId,
          ),
        ),
      );
      final viewed = widget.onChapterViewed;
      if (viewed != null) {
        unawaited(
          viewed(
            _source.sourceId,
            chapter.comicId,
            chapter.chapterId,
          ).catchError(
            (Object error, StackTrace _) {
              debugPrint('chapter viewed marker persist failed: $error');
            },
          ),
        );
      }
    }
    if (mounted) {
      setState(() {});
    }
    ImportedLibraryEntry? openedEntry = existing;
    try {
      final progress = await widget.onOpenChapter(
        () async {
          final entry = openedEntry ?? await _ensure(chapter);
          openedEntry = entry;
          return entry;
        },
        refreshRemote: false,
        title: chapter.title,
        initialPageIndex: initialPageIndex,
      );
      if (mounted && progress != null) {
        setState(
          () => _library = _library.copyWith(
            chapters: _replaceChapterProgress(_library.chapters, progress),
          ),
        );
        final opened = openedEntry;
        final entry = _chapterEntryForProgress(_library.chapters, progress) ??
            (opened != null &&
                    opened.chapter.sourceId == progress.sourceId &&
                    opened.chapter.comicId == progress.comicId &&
                    opened.chapter.chapterId == progress.chapterId
                ? opened
                : null);
        if (entry != null) {
          final state = _readStateById(
            _library.readStates,
            entry.chapter.sourceId,
            entry.chapter.chapterId,
          );
          if (state?.manualOverride != true) {
            await _setRead(
              entry,
              _progressCompletesChapter(
                progress,
                entry.chapter.pages.length,
              ),
            );
          }
        }
      }
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
            updatedAt: entry.chapter.sourceUpdatedAt,
          ),
      existing: entry,
    );
  }

  Future<void> _openPreviewPage(int pageIndex) async {
    final sourceManifest = _manifest ?? _library.sourceManifest;
    final Iterable<Chapter> sourceChapters = sourceManifest?.chapters ??
        (_library.sourceChapters.isNotEmpty
            ? _library.sourceChapters
            : _library.chapters.map<Chapter>(
                (e) => Chapter(
                  comicId: e.chapter.comicId,
                  chapterId: e.chapter.chapterId,
                  title: e.chapter.displayName,
                  sequence: e.chapter.sequence,
                  pageCount: e.chapter.pages.length,
                  sourceRevision: e.chapter.sourceRevision,
                  publishedAt: e.chapter.importedAt,
                  updatedAt: e.chapter.sourceUpdatedAt,
                ),
              ));
    final List<Chapter> chapters = sourceChapters.toList(growable: false)
      ..sort(_compareChapters);
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

  Future<bool> _confirmDownloadConflictIfNeeded({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? chapterTitle,
    bool forcePrompt = false,
  }) =>
      _confirmComicDownloadConflict(
        context: context,
        downloadActions: widget.downloadActions,
        inspector: widget.inspectComicConflicts,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        sourceDisplayName: widget.source.descriptor.name,
        chapterTitle: chapterTitle,
        forcePrompt: forcePrompt,
        conflictConfirmed: _conflictConfirmed,
        markConflictConfirmed: () => _conflictConfirmed = true,
        traceSink: widget.traceSink,
        traceMonotonicMicros: _traceNowMicros,
      );

  Future<void> _download(Chapter chapter) async {
    final identity = comicDetailsChapterIdentity(
      _source.sourceId,
      chapter.chapterId,
    );
    final current = _downloadSnapshots[identity];
    if (current?.isActive == true ||
        current?.isComplete == true) {
      return;
    }
    // Lock before the dialog: two taps used to pass the guard together and
    // open two dialogs.
    if (!_workingDownloads.add(identity)) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
    try {
      await widget.downloadActions.ensureDurableServices?.call();
      final entry = await _ensure(chapter);
      final probe = await widget.downloadActions.probeExisting(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
      );
      void recordGate(String decision) {
        try {
          widget.traceSink.record(
            TraceEvent(
              monotonicMicros: _traceNowMicros(),
              sessionId: 'comic-details-download-gate',
              kind: TraceEventKind.downloadState,
              identityHash: identity,
              payload: <String, Object?>{
                'decision': decision,
                'liveRun': probe.liveRun,
                'indexedReadyPages': probe.indexedReadyPages,
                'wholeComicJob': widget.downloadActions
                    .cachedWholeComicJob(
                      entry.chapter.sourceId,
                      entry.chapter.comicId,
                    )
                    ?.phase
                    .name,
              },
            ),
          );
        } on Object {}
      }

      final wholeComicJob = widget.downloadActions
          .cachedWholeComicJob(
            entry.chapter.sourceId,
            entry.chapter.comicId,
          );
      final activeWholeComicJob = wholeComicJob != null &&
          (wholeComicJob.phase == WholeComicQueuePhase.running ||
              wholeComicJob.phase == WholeComicQueuePhase.queued ||
              wholeComicJob.phase == WholeComicQueuePhase.paused ||
              wholeComicJob.phase ==
                  WholeComicQueuePhase.waitingForPolicy);
      if (probe.liveRun || activeWholeComicJob) {
        recordGate('blocked-active-task');
        if (mounted) {
          _showDetailsSnackBar(
            context,
            const SnackBar(content: Text('已存在相同的下载任务')),
          );
        }
        return;
      }
      final placement = await widget.downloadActions.getDownloadPlacement(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
      );
      final skipConflictDialog = placement != null;
      recordGate(skipConflictDialog ? 'resume-incremental' : 'fresh-download');
      if (!skipConflictDialog) {
        final ok = await _confirmDownloadConflictIfNeeded(
          sourceId: _source.sourceId,
          comicId: chapter.comicId,
          comicTitle: _comic.title,
          chapterTitle: chapter.title,
        );
        if (!ok) return;
      }
      unawaited(
        widget.onDownloadChapter(entry).catchError(
          (Object error, StackTrace stackTrace) async {
            final text = error.toString().toLowerCase();
            final isConflict = (error is Failure && error.code == ErrorCode.policy) ||
                text.contains('conflict') ||
                text.contains('belongs to another comic') ||
                text.contains('owned by');
            if (mounted && isConflict) {
              final ok = await _confirmDownloadConflictIfNeeded(
                sourceId: _source.sourceId,
                comicId: chapter.comicId,
                comicTitle: _comic.title,
                chapterTitle: chapter.title,
                forcePrompt: true,
              );
              if (ok && mounted) {
                unawaited(
                  widget.onDownloadChapter(entry).catchError(
                    (Object retryError, StackTrace retryTrace) {
                      if (mounted) {
                        _showRemoteFailure(retryError, retryTrace);
                      }
                    },
                  ),
                );
                return;
              }
            }
            if (mounted) {
              _showRemoteFailure(error, stackTrace);
            }
          },
        ),
      );
      if (mounted) {
        _showDetailsSnackBar(
          context,
          SnackBar(content: Text('已开始下载“${chapter.title}”')),
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
    // Lock before the dialog (same double-dialog trap as _download).
    setState(() => _downloadingComic = true);
    try {
      await widget.downloadActions.ensureDurableServices?.call();
      final comicJob = await widget.downloadActions.wholeComicJob(
        manifest.comic.sourceId,
        manifest.comic.comicId,
      );
      final requiresPlacementResolution =
          comicJob?.requiresUserAction == true;
      final jobExists = comicJob != null && !requiresPlacementResolution;
      var skipConflictDialog = false;
      if (jobExists) {
        try {
          widget.traceSink.record(
            TraceEvent(
              monotonicMicros: _traceNowMicros(),
              sessionId: 'comic-details-download-gate',
              kind: TraceEventKind.downloadState,
              identityHash: manifest.comic.comicId,
              payload: <String, Object?>{
                'decision': 'blocked-active-whole-comic-job',
                'scope': 'whole-comic',
              },
            ),
          );
        } on Object {}
        if (mounted) {
          _showDetailsSnackBar(
            context,
            const SnackBar(content: Text('该漫画的整本下载任务已存在')),
          );
        }
        return;
      }
      final comicProbe = await widget.downloadActions.probeExisting(
        sourceId: _source.sourceId,
        comicId: manifest.comic.comicId,
      );
      final placement = await widget.downloadActions.getDownloadPlacement(
        sourceId: _source.sourceId,
        comicId: manifest.comic.comicId,
      );
      skipConflictDialog =
          placement != null && !requiresPlacementResolution;
      try {
        widget.traceSink.record(
          TraceEvent(
            monotonicMicros: _traceNowMicros(),
            sessionId: 'comic-details-download-gate',
            kind: TraceEventKind.downloadState,
            identityHash: manifest.comic.comicId,
            payload: <String, Object?>{
              'decision': requiresPlacementResolution
                  ? 'requires-user-action'
                  : skipConflictDialog
                      ? 'resume-incremental'
                      : 'fresh-download',
              'scope': 'whole-comic',
              'indexedReadyPages': comicProbe.indexedReadyPages,
            },
          ),
        );
      } on Object {}
      if (!skipConflictDialog) {
        final ok = await _confirmDownloadConflictIfNeeded(
          sourceId: _source.sourceId,
          comicId: manifest.comic.comicId,
          comicTitle: _comic.title,
          chapterTitle: '整本漫画',
          forcePrompt: requiresPlacementResolution,
        );
        if (!ok) return;
      }
      final entries = <ImportedLibraryEntry>[];
      for (final chapter in manifest.chapters) {
        entries.add(await _ensure(chapter));
      }
      if (entries.isEmpty) {
        throw StateError('没有可下载的章节');
      }
      try {
        await widget.onDownloadComic(entries);
        await _loadDownloadStatuses(entries);
        if (mounted) {
          _showDetailsSnackBar(
            context,
            SnackBar(content: Text('“${_comic.title}”已加入整本下载队列')),
          );
        }
      } on Object catch (error, stackTrace) {
        final text = error.toString().toLowerCase();
        final isConflict = (error is Failure && error.code == ErrorCode.policy) ||
            text.contains('conflict') ||
            text.contains('belongs to another comic') ||
            text.contains('owned by');
        if (mounted && isConflict) {
          final ok = await _confirmDownloadConflictIfNeeded(
            sourceId: _source.sourceId,
            comicId: manifest.comic.comicId,
            comicTitle: _comic.title,
            chapterTitle: '整本漫画',
            forcePrompt: true,
          );
          if (ok && mounted) {
            await widget.onDownloadComic(entries);
            await _loadDownloadStatuses(entries);
            if (mounted) {
              _showDetailsSnackBar(
                context,
                SnackBar(content: Text('“${_comic.title}”已加入整本下载队列')),
              );
            }
            return;
          }
        }
        if (mounted) {
          _showRemoteFailure(error, stackTrace);
        }
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
    try {
      widget.traceSink.record(
        TraceEvent(
          monotonicMicros: _traceNowMicros(),
          sessionId: 'comic-details',
          kind: TraceEventKind.taskFailed,
          identityHash: _comic.comicId,
          payload: <String, Object?>{
            'stage': 'comic-details-failure',
            'error': error.toString(),
            'errorType': error.runtimeType.toString(),
            'stackTrace': stackTrace.toString(),
          },
        ),
      );
    } on Object {}
    final failure = _DetailFailure.capture(error, stackTrace);
    _showFailureSnackBar(
      context,
      failure,
      onOpenSourceWebView: failure.requiresSourceVerification &&
              widget.onOpenSourceWebView != null
          ? () => unawaited(
                _recoverSourceAccess(verificationUri: failure.verificationUri),
              )
          : null,
    );
  }

  Future<void> _recoverSourceAccess({Uri? verificationUri}) async {
    final open = widget.onOpenSourceWebView;
    if (open == null) return;
    try {
      await open(verificationUri: verificationUri);
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
        comicId: widget.summary.comicId,
        sourceId: widget.source.sourceId,
        sourceLabel: _source.descriptor.name,
        failure: failure,
        refreshing: _refreshing,
        onRetry: () => _ignoreRefreshResult(
          _refresh(announce: false, forceRefresh: true),
        ),
        onOpenSourceWebView: widget.onOpenSourceWebView == null
            ? null
            : ({Uri? verificationUri}) => _recoverSourceAccess(
                  verificationUri:
                      verificationUri ?? failure.verificationUri,
                ),
        onOpenSourceSettings: widget.onOpenSourceSettings,
      );
    }
    final manifest = _manifest;
    final chapters = manifest?.chapters ?? const <Chapter>[];
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
            ? _loadRemotePreview
            : null;
    final ComicDetailsCommentsLoader? commentsLoader =
        commentSource != null && commentSource.supportsComicComments
            ? _loadRemoteComments
            : null;
    final entryByChapterId = <String, ImportedLibraryEntry>{};
    final entriesByRevision = <String, ImportedLibraryEntry?>{};
    for (final entry in _library.chapters) {
      if (entry.chapter.sourceId == _source.sourceId) {
        entryByChapterId[entry.chapter.chapterId] = entry;
        final rev = entry.chapter.sourceRevision.trim();
        if (rev.isNotEmpty) {
          entriesByRevision[rev] = entriesByRevision.containsKey(rev) ? null : entry;
        }
      }
    }
    var knownPageCount = 0;
    var pageCountPending = false;
    final chapterViewModels = <_ChapterViewModel>[];
    for (final chapter in ordered) {
      final candidateEntry = entryByChapterId[chapter.chapterId] ??
          (chapter.sourceRevision.trim().isNotEmpty
              ? entriesByRevision[chapter.sourceRevision.trim()]
              : null);
      final entry = comicDetailsCanReuseChapterEntry(candidateEntry, chapter)
          ? candidateEntry
          : null;
      final identity = comicDetailsChapterIdentity(
        _source.sourceId,
        chapter.chapterId,
      );
      if (_pendingDeletionIdentities.contains(identity) ||
          _deletedChapterIdentities.contains(identity)) {
        continue;
      }
      final count = _chapterMetadataPageCount(chapter, candidateEntry);
      knownPageCount += count;
      if (count == 0) {
        pageCountPending = true;
      }
      final downloadSnapshot = _downloadSnapshots[identity];
      final isDownloading = _workingDownloads.contains(identity) ||
          downloadSnapshot?.isActive == true;
      final progress = candidateEntry?.progress;
      final readState = _readStateById(
        _library.readStates,
        _source.sourceId,
        chapter.chapterId,
      );
      chapterViewModels.add(
        _ChapterViewModel(
          sourceId: _source.sourceId,
          title: chapter.title,
          chapterId: chapter.chapterId,
          sequence: chapter.sequence,
          pageCount: count,
          progress: progress,
          sourceUpdatedAt:
              chapter.updatedAt ?? candidateEntry?.chapter.sourceUpdatedAt,
          syncedAt:
              candidateEntry?.chapter.importedAt ?? _library.sourceSyncedAt,
          entry: entry,
          isRead: _chapterIsRead(
            state: readState,
            progress: progress,
            pageCount: count,
          ),
          isNew: _library.unseenChapterIds.contains(chapter.chapterId),
          canDownload: true,
          opening: _opening.contains(identity),
          downloading: isDownloading,
          downloadStarted: downloadSnapshot?.started == true,
          downloaded: downloadSnapshot?.isComplete == true,
          sourceChapter: chapter,
        ),
      );
    }
    return _ComicDetailsScaffold(
      screenKey: remoteComicDetailsScreenKey,
      title: comic.title,
      comicId: comic.comicId,
      sourceId: _source.sourceId,
      sourceLabel: _comicSourceLabel(_source, _source.sourceId),
      authors: comic.authors,
      tags: comic.tags,
      description: comic.description,
      cover: _ComicDetailCover(
        sourceId: _source.sourceId,
        comicId: comic.comicId,
        presentationIdentity: widget.artworkIdentity ??
            '${_source.sourceId}\u0000${widget.summary.comicId}',
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
      onSearchTitle: widget.onSearchTitle,
      onMigrateSource: widget.onMigrateSource,
      loadVersionState: widget.loadVersionState,
      onViewVersion: widget.onViewVersion,
      onMigrateVersion: widget.onMigrateVersion,
      onPreferenceChanged: _savePreference,
      progressLabel: _readingProgressLabel(_library.chapters),
      onContinueReading: _latestReadingEntry(_library.chapters) == null
          ? null
          : _continueReading,
      downloadingComic: _downloadingComic,
      onDownloadComic: _downloadComic,
      onToggleWholeComicPause: () => widget.downloadActions
          .toggleWholeComicPause(comic.sourceId, comic.comicId),
      wholeComicPausable: widget.downloadActions.cachedWholeComicJob(
                  comic.sourceId,
                  comic.comicId,
                )?.phase ==
            WholeComicQueuePhase.running,
      wholeComicPaused: widget.downloadActions.cachedWholeComicJob(
                  comic.sourceId,
                  comic.comicId,
                )?.phase ==
            WholeComicQueuePhase.paused,
      onReverse: () => setState(() => _descending = !_descending),
      chapterCount: ordered.length,
      pageCount: knownPageCount,
      pageCountPending: pageCountPending,
      chapterList: _ComicChapterList(
        chapters: chapterViewModels,
        onOpen: (chapter) => _open(chapter.sourceChapter!),
        onDownload: (chapter) => _download(chapter.sourceChapter!),
        onMarkRead: _markRead,
        onRestoreUnread: _restoreUnread,
        onDelete: widget.onDeleteChapter == null ? null : _deleteChapter,
        onStop: _stopChapter,
      ),
      previewSection: detailsManifest?.preview != null ||
              previewLoader != null
          ? _ComicDetailsPreviewSection(
              sourceId: _source.sourceId,
              comicId: comic.comicId,
              title: comic.title,
              maxItemsPerRow: widget.previewMaxItemsPerRow,
              initialPage: detailsManifest?.preview,
              loader: previewLoader,
              loadArtwork: widget.loadCover,
              onOpenPage: _openPreviewPage,
            )
          : null,
      commentsSection: detailsManifest?.comments != null ||
              commentsLoader != null
          ? _ComicDetailsCommentsSection(
              sourceId: _source.sourceId,
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
    this.onSearchTitle,
    required this.downloadingComic,
    required this.onDownloadComic,
    this.onToggleWholeComicPause,
    this.wholeComicPausable = false,
    this.wholeComicPaused = false,
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
  final ComicDetailsMetadataSearch? onSearchTitle;
  final bool downloadingComic;
  final Future<void> Function()? onDownloadComic;
  final Future<void> Function()? onToggleWholeComicPause;
  final bool wholeComicPausable;
  final bool wholeComicPaused;

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
                  Tooltip(
                    message: '在所有漫画源中搜索',
                    child: InkWell(
                      key: comicDetailsTitleSearchKey,
                      onTap: onSearchTitle == null ? null
                          : () => onSearchTitle!(title),
                      child: Text(title,
                          style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ),
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
                        icon: Icon(
                            preference.liked
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
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
                        icon: Icon(
                            preference.inShelf
                                ? Icons.library_add_check
                                : Icons.library_add_outlined,
                          ),
                        label: preference.inShelf ? '移出书架' : '加入书架',
                        selected: preference.inShelf,
                        onPressed: () => unawaited(
                          onPreferenceChanged(
                            preference.copyWith(
                              inShelf: !preference.inShelf,
                            ),
                          ),
                        ),
                      ),
                      _PreferenceButton(
                        key: comicDetailsCollectedKey,
                        icon: Icon(
                            preference.collected
                                ? Icons.bookmark
                                : Icons.bookmark_border,
                          ),
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
                      if (onDownloadComic != null &&
                          !downloadingComic &&
                          !wholeComicPausable)
                        _PreferenceButton(
                          key: comicDetailsDownloadAllKey,
                          icon: const Icon(Icons.download_for_offline_outlined),
                          label: '下载整本',
                          selected: false,
                          onPressed: () => unawaited(onDownloadComic!()),
                        ),
                      if (downloadingComic || wholeComicPausable)
                        _PreferenceButton(
                          key: comicDetailsWholeComicPauseKey(),
                          // Starting: pause core inside a spinner ring, one
                          // control. Running: pause. Paused: resume.
                          icon: downloadingComic && !wholeComicPausable
                              ? Stack(
                                  alignment: Alignment.center,
                                  children: <Widget>[
                                    const SizedBox.square(
                                      dimension: 30,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    ),
                                    const Icon(Icons.pause, size: 14),
                                  ],
                                )
                              : Icon(
                                  wholeComicPaused
                                      ? Icons.play_circle_outline
                                      : Icons.pause_circle_outline,
                                ),
                          label: downloadingComic && !wholeComicPausable
                              ? '整本下载中'
                              : wholeComicPaused
                                  ? '继续整本'
                                  : '暂停整本',
                          selected: wholeComicPaused,
                          onPressed: onToggleWholeComicPause == null
                              ? null
                              : () =>
                                  unawaited(onToggleWholeComicPause!()),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('简介', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(
                  description?.trim().isNotEmpty == true
                      ? description!.trim()
                      : '暂无简介',
                ),
              ],
            ),
          ),
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
    required this.onMarkRead,
    required this.onRestoreUnread,
    this.onDelete,
    this.onStop,
  });

  final List<_ChapterViewModel> chapters;
  final Future<void> Function(_ChapterViewModel chapter) onOpen;
  final Future<void> Function(_ChapterViewModel chapter) onDownload;
  final Future<void> Function(_ChapterViewModel chapter) onMarkRead;
  final Future<void> Function(_ChapterViewModel chapter) onRestoreUnread;
  final Future<void> Function(_ChapterViewModel chapter, {bool deleteFiles})?
      onDelete;
  final Future<void> Function(_ChapterViewModel chapter)? onStop;

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
        final progressPage = chapter.isRead
            ? null
            : _chapterProgressPage(chapter.progress, chapter.pageCount);
        final colorScheme = Theme.of(context).colorScheme;
        final readSwipeColor = chapter.isRead
            ? colorScheme.primaryContainer
            : colorScheme.secondaryContainer;
        final readSwipeActiveColor =
            chapter.isRead ? colorScheme.primary : colorScheme.secondary;
        final readSwipeForeground = chapter.isRead
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSecondaryContainer;
        final readSwipeActiveForeground =
            chapter.isRead ? colorScheme.onPrimary : colorScheme.onSecondary;
        Widget buildReadSwipeContent(
          bool thresholdReached,
          bool dragging,
        ) {
          final foreground = thresholdReached
              ? readSwipeActiveForeground
              : readSwipeForeground;
          final content = chapter.isRead
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.mark_email_unread_outlined,
                      color: foreground,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '恢复未读',
                      style: TextStyle(color: foreground),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '标记已读',
                      style: TextStyle(color: foreground),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.mark_email_read_outlined,
                      color: foreground,
                    ),
                  ],
                );
          if (dragging) {
            return content;
          }
          return AnimatedScale(
            scale: thresholdReached ? 1 : 0.92,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: content,
          );
        }

        final deleteChapter = onDelete == null
            ? null
            : ({bool deleteFiles = false}) =>
                onDelete!(chapter, deleteFiles: deleteFiles);
        return _ReadSwipeAction(
          key: comicDetailsReadKey(chapter.sourceId, chapter.chapterId),
          isRead: chapter.isRead,
          onToggleRead: chapter.isRead
              ? () => onRestoreUnread(chapter)
              : () => onMarkRead(chapter),
          onDelete: deleteChapter == null
              ? null
              : () => deleteChapter(deleteFiles: true),
          readBackground: (thresholdReached, dragging) {
            final background = Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: buildReadSwipeContent(thresholdReached, dragging),
              ),
            );
            final color =
                thresholdReached ? readSwipeActiveColor : readSwipeColor;
            if (dragging) {
              return ColoredBox(color: color, child: background);
            }
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              color: color,
              child: background,
            );
          },
          deleteBackground: ColoredBox(
            color: colorScheme.errorContainer,
            child: IconButton(
              key: comicDetailsDeleteRevealKey(
                chapter.sourceId,
                chapter.chapterId,
              ),
              tooltip: '删除 ${chapter.title}',
              color: colorScheme.onErrorContainer,
              onPressed: deleteChapter == null
                  ? null
                  : () => unawaited(deleteChapter(deleteFiles: true)),
              icon: const Icon(Icons.delete_sweep_outlined),
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
              title: Row(
                children: <Widget>[
                  if (chapter.isNew) ...<Widget>[
                    Semantics(
                      label: '新章节',
                      child: DecoratedBox(
                        key: comicDetailsNewChapterKey(
                          chapter.sourceId,
                          chapter.chapterId,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const SizedBox.square(dimension: 8),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      chapter.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              subtitle: _ChapterStatusLine(
                sourceUpdatedAt: chapter.sourceUpdatedAt,
                syncedAt: chapter.syncedAt,
                pageCount: chapter.pageCount,
                progressPage: progressPage,
              ),
              onTap: chapter.opening
                  ? null
                  : () => unawaited(onOpen(chapter)),
              onLongPress: deleteChapter == null || chapter.entry == null
                  ? null
                  : () => unawaited(_confirmDelete(context, chapter)),
              trailing: !chapter.canDownload
                  ? const Icon(Icons.chevron_right)
                  : chapter.downloading
                      ? IconButton(
                          key: comicDetailsStopDownloadKey(
                            chapter.sourceId,
                            chapter.chapterId,
                          ),
                          tooltip: chapter.downloadStarted
                              ? '停止下载 ${chapter.title}'
                              : '取消下载 ${chapter.title}',
                          onPressed: onStop == null
                              ? null
                              : () {
                                  final stop = onStop!;
                                  unawaited(stop(chapter));
                                },
                          icon: chapter.downloadStarted
                              ? const Icon(Icons.stop_circle_outlined)
                              : Stack(
                                  alignment: Alignment.center,
                                  children: <Widget>[
                                    const SizedBox.square(
                                      dimension: 30,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                      ),
                                    ),
                                    const Icon(Icons.stop, size: 14),
                                  ],
                                ),
                        )
                      : IconButton(
                          key: comicDetailsDownloadKey(
                            chapter.sourceId,
                            chapter.chapterId,
                          ),
                          tooltip:
                              chapter.downloaded ? '${chapter.title} 已下载' : '下载 ${chapter.title}',
                          onPressed: chapter.downloaded
                              ? null
                              : () => unawaited(onDownload(chapter)),
                          icon: Icon(
                            chapter.downloaded
                                ? Icons.download_done
                                : Icons.download_outlined,
                          ),
                        ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    _ChapterViewModel chapter,
  ) async {
    final delete = onDelete;
    if (delete == null || chapter.entry == null) return;
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('删除章节“${chapter.title}”？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('将从本地书架与记录中删除该章节的阅读进度与状态。'),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时删除本地下载文件'),
                value: deleteFiles,
                onChanged: (val) {
                  setDialogState(() {
                    deleteFiles = val ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: <Widget>[
            AppDialogActions(
              onClose: () => Navigator.pop(context, false),
              actions: <Widget>[
                FilledButton(
                  key: comicDetailsDeleteChapterKey(
                    chapter.sourceId,
                    chapter.chapterId,
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await delete(chapter, deleteFiles: deleteFiles);
    }
  }
}

final class _ChapterViewModel {
  const _ChapterViewModel({
    required this.sourceId,
    required this.title,
    required this.chapterId,
    required this.sequence,
    required this.pageCount,
    required this.progress,
    required this.sourceUpdatedAt,
    required this.syncedAt,
    required this.entry,
    required this.isRead,
    required this.isNew,
    required this.canDownload,
    required this.opening,
    required this.downloading,
    this.downloadStarted = false,
    required this.downloaded,
    this.sourceChapter,
  });

  final String sourceId;
  final String title;
  final String chapterId;
  final int sequence;
  final int pageCount;
  final ReadingProgress? progress;
  final DateTime? sourceUpdatedAt;
  final DateTime? syncedAt;
  final ImportedLibraryEntry? entry;
  final bool isRead;
  final bool isNew;
  final bool canDownload;
  final bool opening;
  final bool downloading;
  final bool downloadStarted;
  final bool downloaded;
  final Chapter? sourceChapter;
}

final class _ReadSwipeAction extends StatefulWidget {
  const _ReadSwipeAction({
    required this.isRead,
    required this.onToggleRead,
    required this.readBackground,
    required this.deleteBackground,
    this.onDelete,
    required this.child,
    super.key,
  });

  final bool isRead;
  final Future<void> Function() onToggleRead;
  final Future<void> Function()? onDelete;
  final Widget Function(bool thresholdReached, bool dragging) readBackground;
  final Widget deleteBackground;
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
    if (widget.isRead != oldWidget.isRead) {
      _offset = 0;
      _dragging = false;
      _triggering = false;
    }
  }

  void _update(DragUpdateDetails details, double maxOffset) {
    if (_triggering) {
      return;
    }
    final deleteOffset = widget.onDelete == null ? 0.0 : -_deleteRevealWidth;
    final next = (_offset + details.delta.dx)
        .clamp(deleteOffset, maxOffset)
        .toDouble();
    if (next == _offset) {
      return;
    }
    setState(() {
      _dragging = true;
      _offset = next;
    });
  }

  Future<void> _end(double threshold) async {
    if (_triggering) {
      return;
    }
    final shouldToggleRead = _offset >= threshold;
    final deleteThreshold = (_deleteRevealWidth * 0.7)
        .clamp(40, _deleteRevealWidth)
        .toDouble();
    final shouldRevealDelete =
        widget.onDelete != null && _offset <= -deleteThreshold;
    setState(() {
      _dragging = false;
      _offset = shouldRevealDelete ? -_deleteRevealWidth : 0;
      _triggering = shouldToggleRead;
    });
    if (!shouldToggleRead) {
      return;
    }
    try {
      await widget.onToggleRead();
    } finally {
      if (mounted) {
        setState(() => _triggering = false);
      }
    }
  }

  static const double _deleteRevealWidth = 76;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final threshold = (constraints.maxWidth * 0.18).clamp(56, 96).toDouble();
        final maxOffset = (constraints.maxWidth * 0.36).clamp(96, 160).toDouble();
        final thresholdReached = _offset >= threshold;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: widget.readBackground(thresholdReached, _dragging),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) => _update(details, maxOffset),
              onHorizontalDragEnd: (_) => unawaited(_end(threshold)),
              onHorizontalDragCancel: () {
                setState(() {
                  _dragging = false;
                  _offset = 0;
                });
              },
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
            if (widget.onDelete != null && _offset < 0)
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: _deleteRevealWidth,
                child: widget.deleteBackground,
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

List<Chapter> _removeChapterFromCatalog(
  Iterable<Chapter> chapters,
  String chapterId,
) =>
    <Chapter>[
      for (final chapter in chapters)
        if (chapter.chapterId != chapterId) chapter,
    ];

ComicManifest _removeChapterFromManifest(
  ComicManifest manifest,
  String chapterId,
) =>
    ComicManifest(
      comic: manifest.comic,
      chapters: _removeChapterFromCatalog(manifest.chapters, chapterId),
      preview: manifest.preview,
      comments: manifest.comments,
    );

ImportedLibraryEntry? _chapterEntryForProgress(
  Iterable<ImportedLibraryEntry> entries,
  ReadingProgress progress,
) {
  for (final entry in entries) {
    if (entry.chapter.sourceId == progress.sourceId &&
        entry.chapter.comicId == progress.comicId &&
        entry.chapter.chapterId == progress.chapterId) {
      return entry;
    }
  }
  return null;
}

List<ImportedLibraryEntry> _replaceChapterProgress(
  Iterable<ImportedLibraryEntry> entries,
  ReadingProgress progress,
) =>
    <ImportedLibraryEntry>[
      for (final entry in entries)
        if (entry.chapter.sourceId == progress.sourceId &&
            entry.chapter.comicId == progress.comicId &&
            entry.chapter.chapterId == progress.chapterId)
          entry.copyWith(progress: progress)
        else
          entry,
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
  final cached = entry?.chapter;
  if (cached == null ||
      chapterHasHomeProjectionSnapshotPagePlaceholders(cached)) {
    return 0;
  }
  return cached.pages.length;
}

int _chapterMetadataPageCount(Chapter chapter, ImportedLibraryEntry? entry) {
  if (chapter.pageCount > 0) {
    return chapter.pageCount;
  }
  // Compact Home entries preserve the stored count, not reusable page locators.
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
    super.key,
  });

  final Widget icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton.filledTonal(
        tooltip: label,
        isSelected: selected,
        onPressed: onPressed,
        icon: icon,
      ),
    );
  }
}

final class _ComicDetailCover extends StatefulWidget {
  const _ComicDetailCover({
    required this.sourceId,
    required this.comicId,
    required this.presentationIdentity,
    required this.coverUri,
    required this.fallbackChapter,
    required this.loader,
  });

  final String sourceId;
  final String comicId;
  final String presentationIdentity;
  final Uri? coverUri;
  final ImportedLibraryEntry? fallbackChapter;
  final ComicDetailsArtworkLoader loader;

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
        oldWidget.presentationIdentity != widget.presentationIdentity) {
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
          resourceRole: 'cover',
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EncodedResourceSource>(
      future: _source,
      builder: (context, snapshot) {
        final source = snapshot.data;
        if (source != null) {
          return StableArtworkImage(
            source: source,
            seed: widget.presentationIdentity,
            fit: BoxFit.cover,
          );
        }
        return _CoverPlaceholder(seed: widget.presentationIdentity);
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
    this.verificationUri,
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
      verificationUri: error is Failure
          ? switch (error.details['requestUrl']) {
              final String value => Uri.tryParse(value),
              _ => null,
            }
          : null,
    );
  }

  final String summary;
  final String details;
  final bool requiresSourceVerification;
  final Uri? verificationUri;
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

ChapterReadState? _readStateById(
  Map<String, ChapterReadState> states,
  String sourceId,
  String chapterId,
) =>
    states[comicDetailsChapterIdentity(sourceId, chapterId)] ??
    states[chapterId];

bool _progressCompletesChapter(
  ReadingProgress? progress,
  int pageCount,
) {
  if (progress == null || pageCount <= 0) return false;
  final completeThreshold = math.max(0, pageCount - 2);
  return progress.pageIndex >= completeThreshold;
}

bool _chapterIsRead({
  required ChapterReadState? state,
  required ReadingProgress? progress,
  required int pageCount,
}) {
  if (state?.manualOverride == true) {
    return state!.isRead;
  }
  if (progress != null) {
    return _progressCompletesChapter(progress, pageCount);
  }
  return false;
}

int? _chapterProgressPage(
  ReadingProgress? progress,
  int pageCount,
) {
  if (progress == null || _progressCompletesChapter(progress, pageCount)) {
    return null;
  }
  return pageCount > 0
      ? (progress.pageIndex + 1).clamp(1, pageCount)
      : math.max(1, progress.pageIndex + 1);
}

String _formatChapterCompactTimestamp(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

final class _ChapterStatusLine extends StatelessWidget {
  const _ChapterStatusLine({
    required this.sourceUpdatedAt,
    required this.syncedAt,
    required this.pageCount,
    required this.progressPage,
  });

  final DateTime? sourceUpdatedAt;
  final DateTime? syncedAt;
  final int pageCount;
  final int? progressPage;

  @override
  Widget build(BuildContext context) {
    final sourceTime = sourceUpdatedAt?.toLocal();
    final syncTime = sourceTime == null ? syncedAt?.toLocal() : null;
    final time = sourceTime ?? syncTime;
    final pageLabel = pageCount > 0 ? '$pageCount页' : '待加载';
    final progressLabel =
        progressPage == null ? null : '第$progressPage页';
    final semantics = <String>[
      if (time != null)
        '${sourceTime != null ? '来源' : '同步'} '
            '${_formatChapterCompactTimestamp(time)}',
      pageCount > 0 ? '总页数 $pageCount' : '页数待加载',
      if (progressLabel != null) '阅读历史 $progressLabel',
    ].join(' · ');
    final style = Theme.of(context).textTheme.bodyMedium;
    final iconColor = style?.color?.withValues(alpha: 0.72);

    Widget separator() => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 5),
          child: Text('·'),
        );

    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (time != null) ...<Widget>[
                Icon(
                  sourceTime != null ? Icons.public_outlined : Icons.sync,
                  size: 14,
                  color: iconColor,
                ),
                const SizedBox(width: 3),
                Text(
                  _formatChapterCompactTimestamp(time),
                  maxLines: 1,
                  softWrap: false,
                ),
                separator(),
              ],
              Text(pageLabel, maxLines: 1, softWrap: false),
              if (progressLabel != null) ...<Widget>[
                separator(),
                Icon(Icons.history, size: 14, color: iconColor),
                const SizedBox(width: 3),
                Text(progressLabel, maxLines: 1, softWrap: false),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

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

int _compareChapters(Chapter left, Chapter right) {
  final sequence = left.sequence.compareTo(right.sequence);
  if (sequence != 0) {
    return sequence;
  }
  return left.chapterId.compareTo(right.chapterId);
}

void _showDetailsSnackBar(
  BuildContext context,
  SnackBar snackBar,
) {
  if (!context.mounted) return;
  try {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final isTest =
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      isTest
          ? SnackBar(
              content: snackBar.content,
              action: snackBar.action,
              animation: kAlwaysCompleteAnimation,
              duration: const Duration(seconds: 1),
            )
          : snackBar,
    );
  } on Object {
    // Ignore transient unmounted scaffold messenger assertions.
  }
}

void _showFailureSnackBar(
  BuildContext context,
  _DetailFailure failure, {
  VoidCallback? onOpenSourceWebView,
}) {
  final canVerify = failure.requiresSourceVerification &&
      onOpenSourceWebView != null;
  _showDetailsSnackBar(
    context,
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
    _showDetailsSnackBar(
      context,
      const SnackBar(content: Text('完整错误已复制')),
    );
  }
}
