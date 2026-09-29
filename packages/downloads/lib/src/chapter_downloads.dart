import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';

import 'artifact_bytes.dart';
import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_reuse.dart';
import 'artifact_cache_store.dart';
import 'comic_conflict_inspector.dart';
import 'composition_download_transfer_runtime.dart';
import 'download_resource_coordinator.dart';
import 'partial_download_store.dart';
import 'reader_page_identity.dart';

part 'artifact_promotion_recovery.dart';
part 'persistent_download_artifact_store.dart';
part 'persistent_chapter_download_service.dart';
part 'persistent_download_partial_resume.dart';
part 'persistent_download_structured_placement.dart';

enum ChapterDownloadPhase { idle, downloading, complete, failed, cancelled }

final class ChapterDownloadSnapshot {
  const ChapterDownloadSnapshot({
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.chapterId,
    required this.sourceRevision,
    required this.title,
    required this.completedPages,
    required this.totalPages,
    required this.receivedBytes,
    required this.phase,
    this.pinnedPages = 0,
    int? exactCompletedPages,
    this.totalBytes,
    this.pageProgressUnits,
    this.failure,
    this.started = false,
  })  : exactCompletedPages = exactCompletedPages ?? completedPages,
        assert(completedPages >= 0),
        assert(pinnedPages >= 0),
        assert((exactCompletedPages ?? completedPages) >= 0),
        assert((exactCompletedPages ?? completedPages) <= completedPages),
        assert(totalPages > 0),
        assert(completedPages <= totalPages),
        assert(receivedBytes >= 0),
        assert(totalBytes == null || totalBytes >= 0),
        assert(pageProgressUnits == null || pageProgressUnits >= 0);

  factory ChapterDownloadSnapshot.idle(ImportedLibraryEntry entry) =>
      ChapterDownloadSnapshot(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        comicTitle: entry.chapter.comicTitle,
        chapterId: entry.chapter.chapterId,
        sourceRevision: entry.chapter.sourceRevision,
        title: entry.chapter.displayName,
        completedPages: 0,
        totalPages: entry.chapter.pages.length,
        receivedBytes: 0,
        pinnedPages: 0,
        totalBytes: _declaredTotalBytes(entry),
        phase: ChapterDownloadPhase.idle,
      );

  final String sourceId;
  final String comicId;
  final String comicTitle;
  final String chapterId;
  final String sourceRevision;
  final String title;
  final int completedPages;
  final int totalPages;
  final int receivedBytes;
  final int pinnedPages;

  /// Pages complete under the current exact DownloadId. Equivalent bodies
  /// from another version never contribute to this count.
  final int exactCompletedPages;

  /// Pages currently readable only through a verified immutable-artifact
  /// reuse proof rather than a current exact durable binding.
  int get reusablePages => completedPages - exactCompletedPages;

  final int? totalBytes;
  final double? pageProgressUnits;
  final ChapterDownloadPhase phase;
  final String? failure;

  /// True once at least one page task of the run has been admitted to the
  /// transfer layer. Before this, the run is still in its pre-network stage
  /// (index/disk classification, hydration) — the UI's "starting" window
  /// where the spinner control cancels the start attempt.
  final bool started;

  String get identity =>
      chapterDownloadIdentity(sourceId, comicId, chapterId, sourceRevision);

  bool get isActive => phase == ChapterDownloadPhase.downloading;
  bool get isComplete => phase == ChapterDownloadPhase.complete;
  bool get hasDurableBytes => receivedBytes > 0 || isComplete;

  /// Number of auto-cached pages available for this chapter (unpinned / equivalent).
  int get autoCachedPages =>
      (completedPages - pinnedPages).clamp(0, totalPages);

  /// True if this chapter has an active, completed, failed, or cancelled manual
  /// download task, or has pinned pages from a previous download.
  bool get isManualDownload =>
      phase != ChapterDownloadPhase.idle || pinnedPages > 0 || started;

  /// True if this chapter has unpinned auto-cached pages from Reader streaming / equivalent reuse.
  bool get hasAutoCache =>
      !isManualDownload && (autoCachedPages > 0 || hasDurableBytes);

  double get fraction {
    return (completedPageUnits / totalPages).clamp(0, 1).toDouble();
  }

  double get completedPageUnits {
    if (isComplete) {
      return totalPages.toDouble();
    }
    return (pageProgressUnits ?? completedPages.toDouble())
        .clamp(0, totalPages)
        .toDouble();
  }
}

abstract interface class ChapterDownloadService {
  Stream<ChapterDownloadSnapshot> get changes;

  Future<void> download(ImportedLibraryEntry entry);

  Future<void> retry(ImportedLibraryEntry entry);

  Future<void> cancel(ImportedLibraryEntry entry);

  Future<void> delete(ImportedLibraryEntry entry);

  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry);

  /// Bulk projection used by Home without one storage query per chapter/page.
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  );

  /// Discovers offline downloaded chapters in store that are not present in [knownEntries].
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  );

  /// Unified existing-download lookup across live runs and the index.
  Future<DownloadExistenceReport> probeExistingDownloads(
    DownloadExistenceQuery query,
  );

  /// Unified actual-file-state lookup for one chapter (index + disk scan).
  Future<ChapterFileStateReport> inspectChapterFileState(
    ImportedLibraryEntry entry,
  );

  Future<bool> isDownloaded(ImportedLibraryEntry entry);

  /// Pre-claims the target structured directory for a comic to honor explicit
  /// conflict decisions (e.g. save-as-new or overwrite choice).
  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  });

  /// Updates direct predecessor -> current download-head mappings used only by
  /// manual download/export placement. Historical traversal stays upstream.
  void updateVersionBaselines(List<ComicVersionRelation> relations);

  /// Updates source-verified version relations available to immutable artifact
  /// cache reuse. Cache residency is independent from manual download-head
  /// adoption and must not duplicate bytes merely because a version was not
  /// explicitly downloaded.
  void updateCacheVersionRelations(List<ComicVersionRelation> relations);

  /// Retrieves the persisted placement record for the specified comic.
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  });

  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  });

  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry);

  Future<bool> hasReadyPage(ImportedLibraryEntry entry, int pageIndex);

  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex);

  Future<void> close();
}

/// One authoritative download-management projection built from a single
/// artifact-index snapshot. The route consumes this projection; it does not
/// independently enumerate storage.
final class CanonicalChapterCacheSnapshot {
  CanonicalChapterCacheSnapshot({
    required this.familyId,
    required this.canonicalChapterId,
    required this.readyPages,
    required this.partialPages,
    required this.receivedBytes,
    required this.manualReferencedPages,
    required Iterable<String> memberChapterIdentities,
  }) : memberChapterIdentities =
           List<String>.unmodifiable(memberChapterIdentities);

  final VersionFamilyId familyId;
  final CanonicalChapterId canonicalChapterId;
  final int readyPages;
  final int partialPages;
  final int receivedBytes;
  final int manualReferencedPages;
  final List<String> memberChapterIdentities;

  int get cachedPages => readyPages + partialPages;
  int get memberVersionCount => memberChapterIdentities.length;

  String get identity =>
      'canonical-cache:v1${familyId.value.length}:${familyId.value}'
      '${canonicalChapterId.value.length}:${canonicalChapterId.value}';
}

final class ExactChapterCacheSnapshot {
  const ExactChapterCacheSnapshot({
    required this.sourceId,
    required this.comicId,
    required this.comicTitle,
    required this.chapterId,
    required this.sourceRevision,
    required this.title,
    required this.readyPages,
    required this.partialPages,
    required this.receivedBytes,
    this.historicalRevision = false,
  });

  final String sourceId;
  final String comicId;
  final String comicTitle;
  final String chapterId;
  final String sourceRevision;
  final String title;
  final int readyPages;
  final int partialPages;
  final int receivedBytes;

  /// True when this exact cache belongs to an older source revision of a
  /// logical chapter that is still present in the current library projection.
  /// Exact identity remains revision-bound; this flag only qualifies how the
  /// cache may be presented and whether it may become a manual download.
  final bool historicalRevision;

  int get cachedPages => readyPages + partialPages;
  String get identity =>
      chapterDownloadIdentity(sourceId, comicId, chapterId, sourceRevision);
}

final class ChapterCacheManagementProjection {
  ChapterCacheManagementProjection({
    required Iterable<CanonicalChapterCacheSnapshot> canonical,
    required Iterable<ExactChapterCacheSnapshot> exact,
  })  : canonical = List<CanonicalChapterCacheSnapshot>.unmodifiable(canonical),
        exact = List<ExactChapterCacheSnapshot>.unmodifiable(exact);

  final List<CanonicalChapterCacheSnapshot> canonical;
  final List<ExactChapterCacheSnapshot> exact;
}

final class ChapterDownloadManagementProjection {
  const ChapterDownloadManagementProjection({
    required this.orphanedEntries,
    required this.snapshots,
    this.cache,
  });

  final List<ImportedLibraryEntry> orphanedEntries;
  final List<ChapterDownloadSnapshot> snapshots;

  /// Physical cache ownership projected independently from exact download
  /// lifecycle. Null means the backing service cannot provide this authority.
  final ChapterCacheManagementProjection? cache;
}

/// Optional bulk capability for owners that can discover orphaned chapters
/// and inspect all visible downloads from the same artifact-index snapshot.
abstract interface class ChapterDownloadManagementProjectionReader {
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  );
}

/// Narrow read capability for the cache-management surface.
///
/// This intentionally excludes per-chapter [ChapterDownloadSnapshot] rebuilds.
/// A caller that only needs physical Canonical/Exact cache inventory must not
/// pay the all-page download-progress projection cost.
abstract interface class ChapterCacheManagementProjectionReader {
  Future<ChapterCacheManagementProjection> inspectCacheManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  );
}

/// Lightweight invalidation for durable download-management state.
///
/// This is intentionally not a progress stream. Reader auto-cache and other
/// background artifact mutations use it only to say that the next management
/// projection should be re-read. Explicit chapter commands continue publishing
/// their ordinary [ChapterDownloadSnapshot] lifecycle/progress stream.
abstract interface class ChapterDownloadManagementChangeSource {
  Stream<void> get managementProjectionChanges;
}

/// Chapter command lifecycle used by app composition.
///
/// Durable artifact/cache ownership is intentionally a separate capability;
/// commands request image transfers but do not become the cache owner.
/// Flags for the unified existing-download lookup. Every supplied field
/// narrows the match; omitted fields match freely. [url] targets the
/// ehentai-style case where versions of the same comic live under different
/// gallery URLs — page locators record the URL they were downloaded from.
class DownloadExistenceQuery {
  const DownloadExistenceQuery({
    required this.sourceId,
    this.pluginId,
    this.comicId,
    this.chapterId,
    this.url,
  });

  /// Exact source match (e.g. `venera:ehentai`).
  final String sourceId;

  /// Plugin family match — matches any source whose id starts with
  /// `<pluginId>:` (e.g. pluginId `venera` matches `venera:ehentai`).
  final String? pluginId;
  final String? comicId;
  final String? chapterId;

  /// Matches page records whose download locator equals this URL.
  final String? url;
}

/// Result of the unified existing-download lookup.
class DownloadExistenceReport {
  const DownloadExistenceReport({
    required this.liveRunIdentities,
    required this.liveRunStarted,
    required this.indexedReadyPages,
    required this.urlMatchedPages,
  });

  /// Live run identities (any revision) matching the query.
  final List<String> liveRunIdentities;

  /// Whether any live run has admitted a page task (started vs starting).
  final bool liveRunStarted;

  /// Ready index records matching the query (chapter/comic level count).
  final int indexedReadyPages;

  /// Ready records whose locator equals [DownloadExistenceQuery.url].
  final int urlMatchedPages;

  bool get liveRun => liveRunIdentities.isNotEmpty;
}

/// Actual on-disk / index file state for one chapter, combining the index
/// projection with the chapter-folder scan. Feeds the conflict comparison
/// and the existing-file reuse path.
class ChapterFileStateReport {
  const ChapterFileStateReport({
    required this.manifestPages,
    required this.indexReadyPages,
    required this.diskPages,
    required this.diskBytes,
  });

  final int manifestPages;

  /// Pages with a `ready` index record matching the current revision.
  final int indexReadyPages;

  /// Page files found in the chapter folder (independent of the index).
  final int diskPages;
  final int diskBytes;
}

abstract interface class ManagedChapterDownloadService
    implements ChapterDownloadService {}

/// Resolves bytes owned by an active comic source. External plugin page URIs
/// are intentionally opaque and must stay behind the source boundary instead
/// of falling through to [IoTransport].
typedef ChapterResourceLoader = Future<Uint8List> Function(
  String sourceId,
  Uri uri,
);

typedef ChapterResourceTransport = Future<ByteResponse> Function(
  String sourceId,
  Uri uri, {
  ByteRange? range,
  Validators? validators,
});

typedef ChapterResourceControlledLoader = Future<Uint8List> Function(
  String sourceId,
  Uri uri, {
  TaskControl? control,
});

typedef ChapterResourceControlledTransport = Future<ByteResponse> Function(
  String sourceId,
  Uri uri, {
  ByteRange? range,
  Validators? validators,
  TaskControl? control,
});

typedef ChapterResourceOpenBound = bool Function(String sourceId, Uri uri);
typedef ChapterResourceGenerationRefresh = Future<void> Function(
  String sourceId,
  Uri uri, {
  TaskControl? control,
});
typedef ChapterVerifiedPageReuseObserver =
    void Function(ChapterManifest manifest, PageAsset page, String identity);

/// Atomic source-resource binding used by application composition.
///
/// The complete-byte loader remains a compatibility fallback for sources that
/// require a runtime transform. The streaming transport is authoritative when
/// both capabilities are present. Binding them together prevents composition
/// from exposing a half-updated loader/transport pair to an active download.
final class ChapterResourceAccess {
  ChapterResourceAccess({
    this.loadBytes,
    this.loadBytesControlled,
    this.openResponse,
    this.openControlledResponse,
    this.selfBoundsOpen,
    this.refreshResourceGeneration,
    this.onVerifiedPageReuseIdentity,
  }) {
    if (loadBytes == null &&
        loadBytesControlled == null &&
        openResponse == null &&
        openControlledResponse == null) {
      throw ArgumentError('chapter resource access must expose a loader');
    }
  }

  final ChapterResourceLoader? loadBytes;
  final ChapterResourceControlledLoader? loadBytesControlled;
  final ChapterResourceTransport? openResponse;
  final ChapterResourceControlledTransport? openControlledResponse;
  final ChapterResourceOpenBound? selfBoundsOpen;
  final ChapterResourceGenerationRefresh? refreshResourceGeneration;
  final ChapterVerifiedPageReuseObserver? onVerifiedPageReuseIdentity;
}

abstract interface class ConfigurableChapterResourceAccess {
  void setChapterResourceAccess(ChapterResourceAccess? access);
}

typedef ChapterPageLoader =
    Future<Uint8List> Function(ImportedLibraryEntry entry, int pageIndex);

/// Deterministic in-memory implementation used when the application has no
/// durable platform store (for example widget tests). It owns each completed
/// page before publishing that page's progress, preserves partial pages across
/// cancellation/failure, and exposes the same task lifecycle as the artifact
/// implementation.
final class MemoryChapterDownloadService
    implements
        ManagedChapterDownloadService,
        ArtifactCacheMaintenance,
        ArtifactCacheBackend {
  MemoryChapterDownloadService({required ChapterPageLoader pageLoader})
      : _pageLoader = pageLoader;

  final ChapterPageLoader _pageLoader;
  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final Map<String, List<Uint8List?>> _chapters = <String, List<Uint8List?>>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  final Map<DownloadId, Uint8List> _readerArtifacts = <DownloadId, Uint8List>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _deletedIdentities = <String>{};
  final Set<String> _pinnedIdentities = <String>{};
  bool _closed = false;

  @override
  Stream<ChapterDownloadSnapshot> get changes => _changes.stream;

  @override
  Future<void> download(ImportedLibraryEntry entry) {
    _requireOpen();
    final identity = _identity(entry);
    final active = _runs[identity];
    if (active != null) {
      return active;
    }
    final run = _runDownload(entry);
    _runs[identity] = run;
    return run.whenComplete(() {
      _runs.remove(identity);
    });
  }

  Future<void> _runDownload(ImportedLibraryEntry entry) async {
    final identity = _identity(entry);
    _deletedIdentities.remove(identity);
    // The memory backend is a fallback/read-through tier; it has no durable
    // ownership record, so retain explicit manual-download intent in memory
    // for the full task lifetime, including cancelled/failed partials.
    _pinnedIdentities.add(identity);
    _cancelled.remove(identity);
    final existing = _chapters[identity];
    final List<Uint8List?> pages;
    if (existing == null) {
      pages = List<Uint8List?>.filled(entry.chapter.pages.length, null);
      _chapters[identity] = pages;
    } else if (existing.length < entry.chapter.pages.length) {
      pages = List<Uint8List?>.from(existing)
        ..addAll(
          List<Uint8List?>.filled(
            entry.chapter.pages.length - existing.length,
            null,
          ),
        );
      _chapters[identity] = pages;
    } else {
      pages = existing;
    }
    var completedPages = _storedPageCount(pages);
    var receivedBytes = _storedPageBytes(pages);
    var started = false;
    ChapterDownloadSnapshot downloadingSnapshot() => ChapterDownloadSnapshot(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          comicTitle: entry.chapter.comicTitle,
          chapterId: entry.chapter.chapterId,
          sourceRevision: entry.chapter.sourceRevision,
          title: entry.chapter.displayName,
          completedPages: completedPages,
          totalPages: entry.chapter.pages.length,
          receivedBytes: receivedBytes,
          pinnedPages: completedPages,
          totalBytes: _declaredTotalBytes(entry),
          phase: ChapterDownloadPhase.downloading,
          started: started,
        );
    _emit(downloadingSnapshot());
    try {
      for (var index = 0; index < entry.chapter.pages.length; index++) {
        if (pages[index] != null) {
          continue;
        }
        if (_cancelled.contains(identity)) {
          if (!_deletedIdentities.contains(identity)) {
            _emitCancelled(entry, completedPages, receivedBytes);
          }
          return;
        }
        started = true;
        _emit(downloadingSnapshot());
        final bytes = Uint8List.fromList(await _pageLoader(entry, index));
        if (_cancelled.contains(identity)) {
          if (!_deletedIdentities.contains(identity)) {
            _emitCancelled(entry, completedPages, receivedBytes);
          }
          return;
        }
        pages[index] = bytes;
        completedPages++;
        receivedBytes += bytes.length;
        if (completedPages < entry.chapter.pages.length) {
          _emit(downloadingSnapshot());
        }
      }
      _emit(
        ChapterDownloadSnapshot(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          comicTitle: entry.chapter.comicTitle,
          chapterId: entry.chapter.chapterId,
          sourceRevision: entry.chapter.sourceRevision,
          title: entry.chapter.displayName,
          completedPages: completedPages,
          totalPages: entry.chapter.pages.length,
          receivedBytes: receivedBytes,
          pinnedPages: completedPages,
          totalBytes: _declaredTotalBytes(entry) ?? receivedBytes,
          phase: ChapterDownloadPhase.complete,
          started: true,
        ),
      );
    } on Object catch (error) {
      if (_deletedIdentities.contains(identity)) return;
      _emit(
        ChapterDownloadSnapshot(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          comicTitle: entry.chapter.comicTitle,
          chapterId: entry.chapter.chapterId,
          sourceRevision: entry.chapter.sourceRevision,
          title: entry.chapter.displayName,
          completedPages: completedPages,
          totalPages: entry.chapter.pages.length,
          receivedBytes: receivedBytes,
          pinnedPages: completedPages,
          totalBytes: _declaredTotalBytes(entry),
          phase: ChapterDownloadPhase.failed,
          failure: error.toString(),
        ),
      );
      rethrow;
    }
  }

  void _emitCancelled(
    ImportedLibraryEntry entry,
    int completedPages,
    int receivedBytes,
  ) {
    _emit(
      ChapterDownloadSnapshot(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
        comicTitle: entry.chapter.comicTitle,
        chapterId: entry.chapter.chapterId,
        sourceRevision: entry.chapter.sourceRevision,
        title: entry.chapter.displayName,
        completedPages: completedPages,
        totalPages: entry.chapter.pages.length,
        receivedBytes: receivedBytes,
        pinnedPages: completedPages,
        totalBytes: _declaredTotalBytes(entry),
        phase: ChapterDownloadPhase.cancelled,
      ),
    );
  }

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {
    _requireOpen();
    await cancel(entry);
    return download(entry);
  }

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    _requireOpen();
    // Fire-and-forget on purpose: the memory run cannot be interrupted
    // mid-loader, and awaiting it would block cancellation on a hung page
    // load. Chapter-wide intent: the live run may use a different revision
    // identity than the caller's entry.
    final chapterPrefix = _chapterDownloadPrefix(entry);
    for (final identity in List.of(_runs.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      _cancelled.add(identity);
    }
    final identity = _identity(entry);
    _cancelled.add(identity);
    final current = _snapshots[identity];
    if (current != null && current.phase == ChapterDownloadPhase.downloading) {
      _emitCancelled(entry, current.completedPages, current.receivedBytes);
    }
  }

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {
    _requireOpen();
    final chapterPrefix = _chapterDownloadPrefix(entry);
    final hasActiveRun = _runs.keys.any(
      (identity) => identity.startsWith(chapterPrefix),
    );
    final identity = _identity(entry);
    _deletedIdentities.add(identity);
    await cancel(entry);
    _chapters.remove(identity);
    _pinnedIdentities.remove(identity);
    // Keep the cancellation marker until a fire-and-forget loader observes it;
    // clearing it here lets a late page completion repopulate a chapter that
    // was already deleted. A future download start clears its own marker.
    if (!hasActiveRun) _cancelled.remove(identity);
    final comicPrefix =
        '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000';
    if (!_chapters.keys.any((candidate) => candidate.startsWith(comicPrefix))) {
      _placements.remove(
        '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}',
      );
    }
    _emit(ChapterDownloadSnapshot.idle(entry));
  }

  /// Seeds memory pages and snapshot state for testing auto-cached or partial chapters.
  void seedPages(
    ImportedLibraryEntry entry,
    List<Uint8List?> pages, {
    int pinnedPages = 0,
    ChapterDownloadPhase phase = ChapterDownloadPhase.idle,
  }) {
    _requireOpen();
    final identity = _identity(entry);
    _chapters[identity] = List<Uint8List?>.from(pages);
    if (pinnedPages > 0) {
      _pinnedIdentities.add(identity);
    } else {
      _pinnedIdentities.remove(identity);
    }
    final completedPages = _storedPageCount(pages);
    final receivedBytes = _storedPageBytes(pages);
    final snapshot = ChapterDownloadSnapshot(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      title: entry.chapter.displayName,
      completedPages: completedPages,
      totalPages: entry.chapter.pages.length,
      receivedBytes: receivedBytes,
      pinnedPages: pinnedPages,
      totalBytes:
          _declaredTotalBytes(entry) ??
          (completedPages == entry.chapter.pages.length ? receivedBytes : null),
      phase: phase,
    );
    _snapshots[identity] = snapshot;
  }

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) async {
    _requireOpen();
    final identity = _identity(entry);
    final current = _snapshots[identity];
    if (current != null) {
      return current;
    }
    final pages = _chapters[identity];
    if (pages == null || pages.length != entry.chapter.pages.length) {
      return ChapterDownloadSnapshot.idle(entry);
    }
    final completedPages = _storedPageCount(pages);
    final receivedBytes = _storedPageBytes(pages);
    final isPinned = _pinnedIdentities.contains(identity);
    final snapshot = ChapterDownloadSnapshot(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      title: entry.chapter.displayName,
      completedPages: completedPages,
      totalPages: entry.chapter.pages.length,
      receivedBytes: receivedBytes,
      pinnedPages: isPinned ? completedPages : 0,
      totalBytes:
          _declaredTotalBytes(entry) ??
          (completedPages == entry.chapter.pages.length ? receivedBytes : null),
      phase: completedPages == entry.chapter.pages.length && isPinned
          ? ChapterDownloadPhase.complete
          : ChapterDownloadPhase.idle,
    );
    _snapshots[identity] = snapshot;
    return snapshot;
  }

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    _requireOpen();
    final snapshots = <ChapterDownloadSnapshot>[];
    for (final entry in entries) {
      snapshots.add(await inspect(entry));
    }
    return List<ChapterDownloadSnapshot>.unmodifiable(snapshots);
  }

  @override
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async => const <ImportedLibraryEntry>[];

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async =>
      (await inspect(entry)).isComplete;

  @override
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async => ComicConflictReport(
        candidates: const <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
    recommendedDirectoryName: buildComicDirectoryName(comicTitle: comicTitle),
      );

  final Map<String, DownloadPlacement> _placements =
      <String, DownloadPlacement>{};

  @override
  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) async {
    final owner = '$sourceId\u0000$comicId';
    if (mode == DownloadPlacementMode.overwrite && observedOwnerKey != null) {
      _placements.removeWhere(
        (key, placement) =>
            key == observedOwnerKey &&
            placement.relativeDirectory == directoryName,
      );
    }
    _placements[owner] = DownloadPlacement(
      placementId: owner,
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: comicTitle ?? directoryName,
      mode: mode,
      relativeDirectory: directoryName,
      observedOwnerKey: observedOwnerKey,
      pageOrder: pageOrder,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void updateVersionBaselines(List<ComicVersionRelation> relations) {}

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {}

  @override
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async => _placements['$sourceId\u0000$comicId'];

  @override
  Future<DownloadExistenceReport> probeExistingDownloads(
    DownloadExistenceQuery query,
  ) async {
    _requireOpen();
    bool identityMatches(String identity) {
      final segments = identity.split('\u0000');
      if (segments.length < 3) return false;
      final sourceId = segments[0];
      final comicId = segments[1];
      final chapterId = segments[2];
      if (sourceId != query.sourceId) {
        final pluginId = query.pluginId;
        if (pluginId == null || !sourceId.startsWith('$pluginId:')) {
          return false;
        }
      }
      if (query.comicId != null && comicId != query.comicId) {
        return false;
      }
      if (query.chapterId != null && chapterId != query.chapterId) {
        return false;
      }
      return true;
    }

    final liveRunIdentities = List.of(_runs.keys.where(identityMatches));
    var indexedReadyPages = 0;
    for (final entry in _chapters.entries) {
      if (!identityMatches(entry.key)) continue;
      indexedReadyPages += entry.value.where((page) => page != null).length;
    }
    return DownloadExistenceReport(
      liveRunIdentities: List.unmodifiable(liveRunIdentities),
      liveRunStarted: liveRunIdentities.isNotEmpty,
      indexedReadyPages: indexedReadyPages,
      urlMatchedPages: 0,
    );
  }

  @override
  Future<ChapterFileStateReport> inspectChapterFileState(
    ImportedLibraryEntry entry,
  ) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    final readyPages = pages?.where((page) => page != null).length ?? 0;
    final bytes =
        pages?.whereType<Uint8List>().fold<int>(
          0,
          (sum, page) => sum + page.lengthInBytes,
        ) ??
        0;
    return ChapterFileStateReport(
      manifestPages: entry.chapter.pages.length,
      indexReadyPages: readyPages,
      diskPages: readyPages,
      diskBytes: bytes,
    );
  }

  @override
  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    if (pages == null) return const <int>{};
    final ready = <int>{};
    for (var i = 0; i < pages.length; i++) {
      if (pages[i] != null) ready.add(i);
    }
    return ready;
  }

  @override
  Future<bool> hasReadyPage(ImportedLibraryEntry entry, int pageIndex) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    if (pages == null || pageIndex < 0 || pageIndex >= pages.length) {
      return false;
    }
    return pages[pageIndex] != null;
  }

  @override
  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    if (pages == null) {
      throw StateError('requested chapter is not downloaded');
    }
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    final page = pages[pageIndex];
    if (page == null) {
      throw StateError('requested page is not downloaded');
    }
    return Uint8List.fromList(page);
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    _requireOpen();
    final bytes = _readerArtifacts[id];
    if (bytes == null) return null;
    if (bytes.isEmpty) {
      _readerArtifacts.remove(id);
      return null;
    }
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = (endExclusive ?? bytes.lengthInBytes)
            .clamp(start, bytes.lengthInBytes)
            .toInt();
        const chunkSize = promotedArtifactReadChunkBytes;
        for (var offset = start; offset < end; offset += chunkSize) {
          final chunkEnd = (offset + chunkSize).clamp(offset, end).toInt();
          yield Uint8List.sublistView(
            bytes,
            offset,
            chunkEnd,
          ).asUnmodifiableView();
        }
      },
      readAll: () async => bytes.asUnmodifiableView(),
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    _requireOpen();
    if (bytes.isEmpty) {
      throw StateError('cannot cache an empty Reader artifact');
    }
    _readerArtifacts.putIfAbsent(id, () => Uint8List.fromList(bytes));
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    _requireOpen();
    _readerArtifacts.remove(id);
  }

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async {
    _requireOpen();
    return ArtifactCacheUsage(
      bytes: _memoryCacheBytes,
      entries:
          _chapters.values.fold<int>(
            0,
            (sum, pages) => sum + _storedPageCount(pages),
          ) +
          _readerArtifacts.length,
    );
  }

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    _requireOpen();
    if (maxBytes < 0 || targetBytes < 0 || targetBytes > maxBytes) {
      throw ArgumentError('invalid resource cache limits');
    }
    final before = _memoryCacheBytes;
    if (before <= maxBytes) {
      return ArtifactCacheReport(
        beforeBytes: before,
        releasedBytes: 0,
        remainingBytes: before,
        evictedEntries: 0,
        skippedBusy: 0,
      );
    }
    return _trimMemoryCache(beforeBytes: before, targetBytes: targetBytes);
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    _requireOpen();
    return _trimMemoryCache(beforeBytes: _memoryCacheBytes, targetBytes: 0);
  }

  ArtifactCacheReport _trimMemoryCache({
    required int beforeBytes,
    required int targetBytes,
  }) {
    var remaining = beforeBytes;
    var evicted = 0;
    var skippedBusy = 0;
    for (final identity in _chapters.keys.toList(growable: false)) {
      if (remaining <= targetBytes) {
        break;
      }
      final pages = _chapters[identity];
      if (pages == null) {
        continue;
      }
      if (_runs.containsKey(identity) || _pinnedIdentities.contains(identity)) {
        skippedBusy += _storedPageCount(pages);
        continue;
      }
      var changed = false;
      for (var index = 0; index < pages.length; index++) {
        if (remaining <= targetBytes) {
          break;
        }
        final page = pages[index];
        if (page == null) {
          continue;
        }
        pages[index] = null;
        remaining -= page.lengthInBytes;
        evicted++;
        changed = true;
      }
      if (changed) {
        _snapshots.remove(identity);
      }
      if (pages.every((page) => page == null)) {
        _chapters.remove(identity);
      }
    }
    for (final id in _readerArtifacts.keys.toList(growable: false)) {
      if (remaining <= targetBytes) {
        break;
      }
      final page = _readerArtifacts.remove(id);
      if (page != null) {
        remaining -= page.lengthInBytes;
        evicted++;
      }
    }
    return ArtifactCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes - remaining,
      remainingBytes: remaining,
      evictedEntries: evicted,
      skippedBusy: skippedBusy,
    );
  }

  int get _memoryCacheBytes =>
      _chapters.values.fold<int>(
        0,
        (sum, pages) => sum + _storedPageBytes(pages),
      ) +
      _readerArtifacts.values.fold<int>(
        0,
        (sum, page) => sum + page.lengthInBytes,
      );

  int _storedPageCount(List<Uint8List?> pages) =>
      pages.whereType<Uint8List>().length;

  int _storedPageBytes(List<Uint8List?> pages) => pages
      .whereType<Uint8List>()
      .fold<int>(0, (sum, page) => sum + page.lengthInBytes);

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _cancelled.addAll(_runs.keys);
    for (final run in _runs.values.toList(growable: false)) {
      try {
        await run;
      } on Object {
        // Closing discards task failures after cancellation.
      }
    }
    _chapters.clear();
    _readerArtifacts.clear();
    _snapshots.clear();
    _pinnedIdentities.clear();
    _deletedIdentities.clear();
    _placements.clear();
    await _changes.close();
  }

  void _emit(ChapterDownloadSnapshot snapshot) {
    _snapshots[snapshot.identity] = snapshot;
    if (!_changes.isClosed) {
      _changes.add(snapshot);
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('chapter download service is closed');
    }
  }
}

abstract interface class ChapterDownloadTransferRuntimeProvider {
  PersistentDownloadArtifactStore get artifactStore;
  ArtifactCacheManager get artifactCacheManager;
  CompositionDownloadTransferRuntime get transferRuntime;
  Future<bool> prewarmLocalReadBackend();
}

final class PersistentDownloadComposition
    implements ChapterDownloadTransferRuntimeProvider {
  PersistentDownloadComposition._({
    required this.artifactStore,
    required this.artifactCacheManager,
    required this.transferRuntime,
    required this.chapterDownloads,
  });

  @override
  Future<bool> prewarmLocalReadBackend() =>
      artifactStore.prewarmLocalReadBackend();

  static Future<PersistentDownloadComposition> open(
    String root, {
    String? directory,
    String? indexPath,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    String Function()? userAgentProvider,
    required NetLane transferNet,
    ArtifactCacheReadScheduler? localReadScheduler,
    StorageWriteScheduler? storageWriteScheduler,
    SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
    SafTreeIo? safTreeIo,
    String? safTreeUri,
    ArtifactPresentationFileLeaseFactory? presentationFileLeaseFactory,
    Duration pageStallTimeout =
        PersistentChapterDownloadService.defaultPageStallTimeout,
    TraceSink? traceSink,
  }) async {
    final authorities = await _openPersistentDownloadAuthorities(
      root,
      directory: directory,
      indexPath: indexPath,
      layoutResolver: layoutResolver,
      transferNet: transferNet,
      localReadScheduler: localReadScheduler,
      storageWriteScheduler: storageWriteScheduler,
      speculativeEncodedReadBudget: speculativeEncodedReadBudget,
      safTreeIo: safTreeIo,
      safTreeUri: safTreeUri,
      presentationFileLeaseFactory: presentationFileLeaseFactory,
      stallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
    final chapterDownloads = PersistentChapterDownloadService._(
      artifactStore: authorities.artifactStore,
      artifactCacheManager: authorities.artifactCacheManager,
      transferRuntime: authorities.transferRuntime,
      transport: IoTransport(
        http: HttpTransport(userAgentProvider: userAgentProvider),
      ),
      ownsTransferComposition: false,
      pageStallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
    return PersistentDownloadComposition._(
      artifactStore: authorities.artifactStore,
      artifactCacheManager: authorities.artifactCacheManager,
      transferRuntime: authorities.transferRuntime,
      chapterDownloads: chapterDownloads,
    );
  }

  @override
  final PersistentDownloadArtifactStore artifactStore;
  @override
  final ArtifactCacheManager artifactCacheManager;
  @override
  final CompositionDownloadTransferRuntime transferRuntime;
  final PersistentChapterDownloadService chapterDownloads;
  bool _closed = false;

  Future<({int replicas, int placements})>
      migrateStructuredDirectRootAndClose({
    required String sourceRoot,
    required String destinationRoot,
    TaskControl? control,
  }) async {
    if (_closed) {
      throw StateError('persistent download composition is already closed');
    }
    await chapterDownloads.close();
    if (transferRuntime.hasConsumers) {
      throw StateError(
        'cannot migrate persistent download root with active transfer consumers',
      );
    }
    await transferRuntime.dispose();
    try {
      return await artifactStore.migrateStructuredDirectRoot(
        sourceRoot: sourceRoot,
        destinationRoot: destinationRoot,
        control: control,
      );
    } finally {
      await artifactStore.close();
      _closed = true;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await chapterDownloads.close();
    if (transferRuntime.hasConsumers) {
      throw StateError(
        'cannot close persistent download composition with active transfer consumers',
      );
    }
    await transferRuntime.dispose();
    await artifactStore.close();
    _closed = true;
  }
}

Future<({int replicas, int placements})>
    migratePersistentDownloadStructuredDirectRoot({
  required String root,
  required String sourceRoot,
  required String destinationRoot,
  required String indexPath,
  CacheLayout? Function(DownloadId id)? layoutResolver,
  StorageWriteScheduler? storageWriteScheduler,
  TraceSink? traceSink,
}) async {
  final store = await PersistentDownloadArtifactStore.open(
    root,
    directory: sourceRoot,
    indexPath: indexPath,
    layoutResolver: layoutResolver,
    storageWriteScheduler: storageWriteScheduler,
    traceSink: traceSink,
  );
  try {
    return await store.migrateStructuredDirectRoot(
      sourceRoot: sourceRoot,
      destinationRoot: destinationRoot,
    );
  } finally {
    await store.close();
  }
}

typedef _PersistentDownloadAuthorities = ({
  PersistentDownloadArtifactStore artifactStore,
  ArtifactCacheManager artifactCacheManager,
  CompositionDownloadTransferRuntime transferRuntime,
});

Future<_PersistentDownloadAuthorities> _openPersistentDownloadAuthorities(
  String root, {
  String? directory,
  String? indexPath,
  CacheLayout? Function(DownloadId id)? layoutResolver,
  NetLane? transferNet,
  ArtifactCacheReadScheduler? localReadScheduler,
  StorageWriteScheduler? storageWriteScheduler,
  SpeculativeEncodedReadBudget? speculativeEncodedReadBudget,
  SafTreeIo? safTreeIo,
  String? safTreeUri,
  ArtifactPresentationFileLeaseFactory? presentationFileLeaseFactory,
  Duration stallTimeout =
      PersistentChapterDownloadService.defaultPageStallTimeout,
  TraceSink? traceSink,
}) async {
  final store = await PersistentDownloadArtifactStore.open(
    root,
    directory: directory,
    indexPath: indexPath,
    layoutResolver: layoutResolver,
    storageWriteScheduler: storageWriteScheduler,
    safMirror: safTreeIo,
    safTreeUri: safTreeUri,
    presentationFileLeaseFactory: presentationFileLeaseFactory,
    traceSink: traceSink,
  );
  if (safTreeUri != null) {
    store.setSafTree(safTreeUri);
  }
  final cache = ArtifactCacheManager(backend: store);
  final runtime = CompositionDownloadTransferRuntime(
    artifactCacheManager: cache,
    partialDownloadStore: store,
    transferWorkspace: EphemeralCacheWorkspace.recoverableTransfer(root),
    net:
        transferNet ??
        NetLane(
          maxActive: 5,
          reservedHighPrioritySlots: 1,
          highPriorityThreshold: 1000,
          preemptionThreshold: 40,
        ),
    localReadScheduler: localReadScheduler,
    speculativeEncodedReadBudget: speculativeEncodedReadBudget,
    readStallTimeout: stallTimeout,
  );
  return (
    artifactStore: store,
    artifactCacheManager: cache,
    transferRuntime: runtime,
  );
}

final class _CanonicalCachePageState {
  const _CanonicalCachePageState({
    required this.ready,
    required this.bytes,
    required this.manualReferenced,
  });

  final bool ready;
  final int bytes;
  final bool manualReferenced;

  _CanonicalCachePageState merge({
    required bool ready,
    required int bytes,
    required bool manualReferenced,
  }) =>
      _CanonicalCachePageState(
        ready: this.ready || ready,
        bytes: this.bytes > bytes ? this.bytes : bytes,
        manualReferenced: this.manualReferenced || manualReferenced,
      );
}

final class _CanonicalChapterCacheSnapshotBuilder {
  _CanonicalChapterCacheSnapshotBuilder({
    required this.familyId,
    required this.canonicalChapterId,
  });

  final VersionFamilyId familyId;
  final CanonicalChapterId canonicalChapterId;
  final Set<String> _members = <String>{};
  final Map<PhysicalMediaId, _CanonicalCachePageState> _pages =
      <PhysicalMediaId, _CanonicalCachePageState>{};

  void addMember(String identity) => _members.add(identity);

  void addPage({
    required PhysicalMediaId physicalId,
    required bool ready,
    required int bytes,
    required bool manualReferenced,
  }) {
    final current = _pages[physicalId];
    _pages[physicalId] = current == null
        ? _CanonicalCachePageState(
            ready: ready,
            bytes: bytes,
            manualReferenced: manualReferenced,
          )
        : current.merge(
            ready: ready,
            bytes: bytes,
            manualReferenced: manualReferenced,
          );
  }

  int get cachedPages => _pages.length;

  CanonicalChapterCacheSnapshot build() {
    var readyPages = 0;
    var partialPages = 0;
    var receivedBytes = 0;
    var manualReferencedPages = 0;
    for (final page in _pages.values) {
      if (page.ready) {
        readyPages++;
      } else {
        partialPages++;
      }
      receivedBytes += page.bytes;
      if (page.manualReferenced) manualReferencedPages++;
    }
    final members = _members.toList(growable: false)..sort();
    return CanonicalChapterCacheSnapshot(
      familyId: familyId,
      canonicalChapterId: canonicalChapterId,
      readyPages: readyPages,
      partialPages: partialPages,
      receivedBytes: receivedBytes,
      manualReferencedPages: manualReferencedPages,
      memberChapterIdentities: members,
    );
  }
}

final class _ExactChapterCacheSnapshotBuilder {
  _ExactChapterCacheSnapshotBuilder(
    ImportedLibraryEntry entry, {
    ImportedChapterRecord? displayMetadata,
  })  : sourceId = entry.chapter.sourceId,
        comicId = entry.chapter.comicId,
        comicTitle = displayMetadata?.comicTitle ??
            (entry.chapter.directoryId.startsWith('orphaned:')
                ? '未关联漫画'
                : entry.chapter.comicTitle),
        chapterId = entry.chapter.chapterId,
        sourceRevision = entry.chapter.sourceRevision,
        title = displayMetadata?.displayName ??
            (entry.chapter.directoryId.startsWith('orphaned:')
                ? '未关联章节缓存'
                : entry.chapter.displayName),
        historicalRevision = displayMetadata != null &&
            displayMetadata.sourceRevision != entry.chapter.sourceRevision;

  final String sourceId;
  final String comicId;
  final String comicTitle;
  final String chapterId;
  final String sourceRevision;
  final String title;
  final bool historicalRevision;
  int readyPages = 0;
  int partialPages = 0;
  int receivedBytes = 0;

  String get identity =>
      chapterDownloadIdentity(sourceId, comicId, chapterId, sourceRevision);
  int get cachedPages => readyPages + partialPages;

  void addPage({required bool ready, required int bytes}) {
    if (ready) {
      readyPages++;
    } else {
      partialPages++;
    }
    receivedBytes += bytes;
  }

  ExactChapterCacheSnapshot build() => ExactChapterCacheSnapshot(
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle,
        chapterId: chapterId,
        sourceRevision: sourceRevision,
        title: title,
        readyPages: readyPages,
        partialPages: partialPages,
        receivedBytes: receivedBytes,
        historicalRevision: historicalRevision,
      );
}

String _canonicalCacheGroupKey(
  VersionFamilyId familyId,
  CanonicalChapterId chapterId,
) =>
    '${familyId.value.length}:${familyId.value}'
    '${chapterId.value.length}:${chapterId.value}';

final class _DownloadManagementPhysicalState {
  _DownloadManagementPhysicalState({
    required Iterable<PhysicalMediaArtifactRecord> artifacts,
    required Iterable<PhysicalPartialRecord> partials,
    required Iterable<VersionChapterCanonicalProjection> projections,
    required Map<String, List<CanonicalMediaActiveRange>> activeProjectionRanges,
  })  : artifacts = <PhysicalMediaId, PhysicalMediaArtifactRecord>{
          for (final record in artifacts) record.id: record,
        },
        partials = <PhysicalMediaId, PhysicalPartialRecord>{
          for (final record in partials) record.id: record,
        },
        projections = <String, VersionChapterCanonicalProjection>{
          for (final projection in projections)
            projection.exactKey: projection,
        },
        activeProjectionRanges = <String, List<CanonicalMediaActiveRange>>{
          for (final entry in activeProjectionRanges.entries)
            entry.key: List<CanonicalMediaActiveRange>.unmodifiable(entry.value),
        };

  final Map<PhysicalMediaId, PhysicalMediaArtifactRecord> artifacts;
  final Map<PhysicalMediaId, PhysicalPartialRecord> partials;
  final Map<String, VersionChapterCanonicalProjection> projections;
  final Map<String, List<CanonicalMediaActiveRange>> activeProjectionRanges;

  /// Builds cache-management rows from durable physical inventory first.
  ///
  /// A canonical artifact may legitimately outlive every exact READY row and
  /// every currently visible library version. Requiring an ImportedLibraryEntry
  /// to discover it makes Download Manager silently lose old shared cache and
  /// forces management refresh to expand every historical chapter page.
  Map<String, _CanonicalChapterCacheSnapshotBuilder>
      canonicalInventoryBuilders() {
    final builders = <String, _CanonicalChapterCacheSnapshotBuilder>{};
    for (final projection in projections.values) {
      final key = _canonicalCacheGroupKey(
        projection.familyId,
        projection.canonicalChapterId,
      );
      final builder = builders.putIfAbsent(
        key,
        () => _CanonicalChapterCacheSnapshotBuilder(
          familyId: projection.familyId,
          canonicalChapterId: projection.canonicalChapterId,
        ),
      );
      builder.addMember(
        chapterDownloadIdentity(
          projection.sourceId,
          projection.comicId,
          projection.chapterId,
          projection.sourceRevision,
        ),
      );
    }

    void addPhysical(
      PhysicalMediaId id, {
      required bool ready,
      required int bytes,
    }) {
      if (id.kind != PhysicalMediaIdKind.canonical) return;
      final coordinate = CanonicalMediaCoordinate.tryParseStableKey(id.value);
      if (coordinate == null) return;
      final builder = builders[
        _canonicalCacheGroupKey(coordinate.familyId, coordinate.chapterId)
      ];
      if (builder == null) return;
      builder.addPage(
        physicalId: id,
        ready: ready,
        bytes: bytes,
        manualReferenced: false,
      );
    }

    for (final record in artifacts.values) {
      addPhysical(record.id, ready: true, bytes: record.bytes);
    }
    for (final record in partials.values) {
      if (artifacts.containsKey(record.id)) continue;
      addPhysical(record.id, ready: false, bytes: record.bytes);
    }
    return builders;
  }

  VersionChapterCanonicalProjection? projectionFor(
    ImportedLibraryEntry entry,
  ) {
    final exactKey = canonicalMediaExactChapterKey(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
    );
    final projection = projections[exactKey];
    if (projection == null || projection.pageCount != entry.chapter.pages.length) {
      return null;
    }
    return projection;
  }

  bool isProjectionActive({
    required ImportedLibraryEntry entry,
    required int pageIndex,
  }) {
    final projection = projectionFor(entry);
    if (projection == null) return false;
    final ranges = activeProjectionRanges[projection.exactKey];
    if (ranges == null) return false;
    return ranges.any((range) => range.contains(pageIndex));
  }

  CanonicalMediaCoordinate? canonicalCoordinateFor({
    required ImportedLibraryEntry entry,
    required int pageIndex,
  }) => projectionFor(entry)?.coordinateForPageIndexOrNull(pageIndex);

  ({PhysicalMediaArtifactRecord? artifact, PhysicalPartialRecord? partial})?
      pageState({
    required ImportedLibraryEntry entry,
    required PageAsset page,
    required int pageIndex,
  }) {
    final projected = _projectedPhysicalId(entry, pageIndex);
    if (projected != null) {
      final artifact = artifacts[projected];
      final partial = artifact == null ? partials[projected] : null;
      if (artifact != null || partial != null) {
        return (artifact: artifact, partial: partial);
      }
    }
    final stable = verifiedPhysicalMediaId(
      sourceId: entry.chapter.sourceId,
      page: page,
    );
    if (stable == null) return null;
    final artifact = artifacts[stable];
    final partial = artifact == null ? partials[stable] : null;
    if (artifact == null && partial == null) return null;
    return (artifact: artifact, partial: partial);
  }

  PhysicalMediaId? _projectedPhysicalId(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) {
    final coordinate = canonicalCoordinateFor(
      entry: entry,
      pageIndex: pageIndex,
    );
    return coordinate == null
        ? null
        : PhysicalMediaId.canonical(coordinate.stableKey);
  }
}

bool _isMonotonicCanonicalProjectionExpansion(
  VersionChapterCanonicalProjection previous,
  VersionChapterCanonicalProjection next,
) {
  if (previous.familyId != next.familyId ||
      previous.canonicalChapterId != next.canonicalChapterId ||
      previous.sourceId != next.sourceId ||
      previous.comicId != next.comicId ||
      previous.chapterId != next.chapterId ||
      previous.sourceRevision != next.sourceRevision ||
      previous.pageCount != next.pageCount) {
    return false;
  }
  var nextIndex = 0;
  for (final oldBinding in previous.intervals) {
    var cursor = oldBinding.exactStart;
    while (cursor < oldBinding.exactEndExclusive) {
      while (nextIndex < next.intervals.length &&
          next.intervals[nextIndex].exactEndExclusive <= cursor) {
        nextIndex++;
      }
      if (nextIndex >= next.intervals.length) return false;
      final newBinding = next.intervals[nextIndex];
      if (newBinding.exactStart > cursor ||
          newBinding.segmentId != oldBinding.segmentId) {
        return false;
      }
      final oldOffset =
          oldBinding.segmentStart + cursor - oldBinding.exactStart;
      final newOffset =
          newBinding.segmentStart + cursor - newBinding.exactStart;
      if (oldOffset != newOffset) return false;
      final end = newBinding.exactEndExclusive < oldBinding.exactEndExclusive
          ? newBinding.exactEndExclusive
          : oldBinding.exactEndExclusive;
      cursor = end;
    }
  }
  return true;
}

String _identity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

bool _isCompactProjectionEntry(ImportedLibraryEntry entry) =>
    chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter);

List<PageAsset> _effectiveCompactPages(
  List<PageAsset> placeholders,
  Iterable<CacheRec> records, {
  required String chapterId,
}) {
  final ordered = records.toList(growable: false)
    ..sort((left, right) {
      final page = left.id.content.pageId.compareTo(right.id.content.pageId);
      return page != 0 ? page : left.createdUs.compareTo(right.createdUs);
    });
  final materializedCount = ordered.length < placeholders.length
      ? ordered.length
      : placeholders.length;
  return <PageAsset>[
    for (var index = 0; index < materializedCount; index++)
      PageAsset(
        pageId: ordered[index].id.content.pageId,
        chapterId: chapterId,
        index: index,
        uri: ordered[index].id.canonicalUri,
        byteLength: ordered[index].bytes,
        checksum: ordered[index].checksum,
      ),
    ...placeholders.skip(materializedCount),
  ];
}

int? _declaredTotalBytes(ImportedLibraryEntry entry) {
  var total = 0;
  for (final page in entry.chapter.pages) {
    final length = page.byteLength;
    if (length == null) {
      return null;
    }
    total += length;
  }
  return total;
}

/// Coalesces chunk-driven chapter projections and preserves emission order.
///
/// DownloadSession remains authoritative; this publisher merely prevents one
/// asynchronous index scan per network chunk and guarantees that a stale
/// `downloading` projection cannot arrive after the terminal snapshot.
