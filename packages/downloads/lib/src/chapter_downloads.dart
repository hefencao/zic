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
import 'partial_download_store.dart';

enum ChapterDownloadPhase {
  idle,
  downloading,
  complete,
  failed,
  cancelled,
}

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
    this.totalBytes,
    this.pageProgressUnits,
    this.failure,
    this.started = false,
  })  : assert(completedPages >= 0),
        assert(pinnedPages >= 0),
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
  final int? totalBytes;
  final double? pageProgressUnits;
  final ChapterDownloadPhase phase;
  final String? failure;

  /// True once at least one page task of the run has been admitted to the
  /// transfer layer. Before this, the run is still in its pre-network stage
  /// (index/disk classification, hydration) — the UI's "starting" window
  /// where the spinner control cancels the start attempt.
  final bool started;

  String get identity => chapterDownloadIdentity(
        sourceId,
        comicId,
        chapterId,
        sourceRevision,
      );

  bool get isActive => phase == ChapterDownloadPhase.downloading;
  bool get isComplete => phase == ChapterDownloadPhase.complete;
  bool get hasDurableBytes => receivedBytes > 0 || isComplete;

  /// Number of auto-cached pages available for this chapter (unpinned / equivalent).
  int get autoCachedPages => (completedPages - pinnedPages).clamp(0, totalPages);

  /// True if this chapter has an active, completed, failed, or cancelled manual
  /// download task, or has pinned pages from a previous download.
  bool get isManualDownload =>
      phase != ChapterDownloadPhase.idle || pinnedPages > 0 || started;

  /// True if this chapter has unpinned auto-cached pages from Reader streaming / equivalent reuse.
  bool get hasAutoCache => !isManualDownload && (autoCachedPages > 0 || hasDurableBytes);

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
final class ChapterDownloadManagementProjection {
  const ChapterDownloadManagementProjection({
    required this.orphanedEntries,
    required this.snapshots,
  });

  final List<ImportedLibraryEntry> orphanedEntries;
  final List<ChapterDownloadSnapshot> snapshots;
}

/// Optional bulk capability for owners that can discover orphaned chapters
/// and inspect all visible downloads from the same artifact-index snapshot.
abstract interface class ChapterDownloadManagementProjectionReader {
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  );
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
}

abstract interface class ConfigurableChapterResourceAccess {
  void setChapterResourceAccess(ChapterResourceAccess? access);
}

typedef ChapterPageLoader = Future<Uint8List> Function(
  ImportedLibraryEntry entry,
  int pageIndex,
);

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
  final Map<String, List<Uint8List?>> _chapters =
      <String, List<Uint8List?>>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  final Map<DownloadId, Uint8List> _readerArtifacts =
      <DownloadId, Uint8List>{};
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
      totalBytes: _declaredTotalBytes(entry) ??
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
      pinnedPages:
          isPinned ? completedPages : 0,
      totalBytes: _declaredTotalBytes(entry) ??
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
  }) async =>
      ComicConflictReport(
        candidates: const <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName:
            buildComicDirectoryName(comicTitle: comicTitle),
      );

  final Map<String, DownloadPlacement> _placements = <String, DownloadPlacement>{};

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
  }) async =>
      _placements['$sourceId\u0000$comicId'];

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
      indexedReadyPages +=
          entry.value.where((page) => page != null).length;
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
    final bytes = pages
            ?.whereType<Uint8List>()
            .fold<int>(0, (sum, page) => sum + page.lengthInBytes) ??
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
  Future<bool> hasReadyPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    _requireOpen();
    final pages = _chapters[_identity(entry)];
    if (pages == null || pageIndex < 0 || pageIndex >= pages.length) {
      return false;
    }
    return pages[pageIndex] != null;
  }

  @override
  Future<Uint8List> readPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
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
          yield Uint8List.sublistView(bytes, offset, chunkEnd).asUnmodifiableView();
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
      entries: _chapters.values.fold<int>(
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
    return _trimMemoryCache(
      beforeBytes: _memoryCacheBytes,
      targetBytes: 0,
    );
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


/// Durable storage owner for promoted image artifacts and cold partials.
///
/// This object never opens a source/network transfer. It owns only the
/// persistent SQLite/file representation used by [ArtifactCacheManager] and
/// [PartialDownloadStore]. Explicit chapter commands and Reader consumers
/// share a separate [CompositionDownloadTransferRuntime].
final class PersistentDownloadArtifactStore
    implements
        ArtifactCacheBackend,
        PartialDownloadStore,
        ArtifactCacheMaintenance {
  PersistentDownloadArtifactStore._({
    required DownloadRegistry registry,
    required SqliteIndex index,
    required CacheOps cacheOps,
    required ArtifactBytes bytes,
    this.safTreeIo,
    required this.safTreeUri,
    TraceSink? traceSink,
    MonoClock? clock,
  })  : _registry = registry,
        _index = index,
        _cacheOps = cacheOps,
        _bytes = bytes,
        _traceSink = traceSink ?? const NoopTraceSink(),
        _clock = clock ?? const SystemClock();

  final TraceSink _traceSink;
  final MonoClock _clock;

  List<ComicVersionRelation> _downloadHeadRelations =
      const <ComicVersionRelation>[];
  List<ComicVersionRelation> _cacheVersionRelations =
      const <ComicVersionRelation>[];

  void updateVersionBaselines(List<ComicVersionRelation> relations) {
    _downloadHeadRelations = List<ComicVersionRelation>.unmodifiable(relations);
  }

  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {
    _cacheVersionRelations = List<ComicVersionRelation>.unmodifiable(relations);
  }

  static Future<PersistentDownloadArtifactStore> open(
    String root, {
    String? directory,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    ArtifactBytes? bytes,
    SafTreeIo? safMirror,
    String? safTreeUri,
    TraceSink? traceSink,
    MonoClock? clock,
  }) async {
    final layout = CacheLayout(
      directory ?? defaultChapterDownloadDirectory(root),
    );
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final resolvedClock = clock ?? const SystemClock();
    final registry = DownloadRegistry(
      layout: layout,
      clock: resolvedClock,
      index: index,
      layoutResolver: layoutResolver,
    );
    final resolvedBytes = bytes ??
        (safMirror == null
            ? const LocalArtifactBytes()
            : CompositeArtifactBytes(
                local: const LocalArtifactBytes(),
                saf: SafArtifactBytes(safMirror, treeUri: safTreeUri),
              ));
    late final PersistentDownloadArtifactStore resolved;
    resolved = PersistentDownloadArtifactStore._(
      registry: registry,
      index: index,
      cacheOps: CacheOps(
        index: index,
        registry: registry,
        clock: resolvedClock,
        evictRecordWithSnapshot: (id, expected) =>
            resolved._evictCacheRecord(id, expected: expected),
      ),
      bytes: resolvedBytes,
      safTreeIo: safMirror,
      safTreeUri: safTreeUri,
      traceSink: traceSink,
      clock: resolvedClock,
    );
    return resolved;
  }

  /// The SAF tree finals mirror into; null keeps everything local.
  final String? safTreeUri;

  String get storageRootId => safTreeUri ?? layout.root;

  void setSafTree(String treeUri) {
    if (safTreeUri != null && safTreeUri != treeUri) {
      throw StateError('SAF tree identity cannot change on an open store');
    }
  }

  final DownloadRegistry _registry;
  final SqliteIndex _index;
  final CacheOps _cacheOps;
  final ArtifactBytes _bytes;

  /// When set, freshly promoted finals are mirrored into the SAF tree and
  /// their index records switch to `saf:` paths; the local staging copy is
  /// removed afterwards. Reading follows the record path scheme.
  final SafTreeIo? safTreeIo;
  final Map<DownloadId, Future<void>> _artifactWrites =
      <DownloadId, Future<void>>{};
  final Map<DownloadId, ({int length, String checksum})>
      _artifactWriteProofs = <DownloadId, ({int length, String checksum})>{};
  final Map<DownloadId, Future<void>> _artifactMutationTails =
      <DownloadId, Future<void>>{};
  final Map<String, Future<void>> _structuredWriteTails =
      <String, Future<void>>{};
  final Map<String, String> _structuredDirectoriesByOwner = <String, String>{};
  final Map<String, String> _structuredOwnersByDirectory = <String, String>{};
  final Map<String, DownloadPlacement> _claimedPlacementsByOwner =
      <String, DownloadPlacement>{};
  final Set<String> _sessionPlacementClaims = <String>{};
  bool _placementClaimsLoaded = false;
  final Map<String, Future<void>> _placementWrites = <String, Future<void>>{};
  bool _closed = false;

  int get materializedSessionCount => _registry.sessions.length;

  CacheLayout get layout => _registry.layout;

  CacheLayout layoutFor(DownloadId id) => _registry.layoutFor(id);

  CacheLayout layoutForSource(String sourceId) =>
      _registry.layoutForSource(sourceId);

  CacheLayout _layoutForEntryPage(ImportedLibraryEntry entry, int pageIndex) {
    final page = entry.chapter.pages[pageIndex.clamp(0, entry.chapter.pages.length - 1)];
    return layoutFor(
      DownloadId(
        content: ContentId(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
          chapterId: entry.chapter.chapterId,
          pageId: page.stablePageId,
        ),
        sourceRevision: entry.chapter.sourceRevision,
        canonicalUri: page.uri,
      ),
    );
  }

  String storageRootIdFor(ImportedLibraryEntry entry) => safTreeUri != null
      ? safTreeUri!
      : entry.chapter.pages.isEmpty
          ? layoutForSource(entry.chapter.sourceId).root
          : _layoutForEntryPage(entry, 0).root;

  CacheIndex get index => _index;

  Future<Map<String, CacheRec>> indexedRecords() async => <String, CacheRec>{
        for (final record in await _index.list()) record.key: record,
      };

  /// Mirrors a freshly promoted local final into the configured SAF tree and
  /// rewrites the index record to its `saf:` path, removing the local staging
  /// copy. Failures keep the local copy authoritative so downloads never
  /// lose bytes to a transient SAF error.
  /// Returns the distinct chapter IDs currently downloaded for [comicId] from [sourceId].
  bool _isVerifiedReadyRecord(CacheRec record) =>
      record.state == CacheState.ready &&
      record.bytes > 0 &&
      RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(record.checksum.trim()) &&
      record.checksumAlgorithm.trim().toLowerCase() == 'crc32';

  String _storageRootIdForPath(String path, {DownloadId? id}) {
    final parsed = parseSafRecordPath(path);
    if (parsed != null) return parsed.treeUri;
    final candidate = id == null ? layout.root : layoutFor(id).root;
    return path == candidate || path.startsWith('$candidate/')
        ? candidate
        : layout.root;
  }

  Future<List<String>> downloadedChapterIds({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    final chapters = <String>{};
    final records = await indexedRecords();
    for (final record in records.values) {
      final content = record.id.content;
      if (content.sourceId == sourceId &&
          content.comicId == comicId &&
          _isVerifiedReadyRecord(record)) {
        chapters.add(content.chapterId);
      }
    }
    return chapters.toList(growable: false);
  }

  /// When a comic with a single chapter directly at root transitions to having
  /// multiple chapters, migrates existing root-level page files of previous
  /// chapters into their dedicated chapter subdirectories.
  Future<void> migrateSingleChapterToSubdirectory({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? conflictSourceSuffix,
    required String previousChapterId,
    required String previousChapterTitle,
    int previousSequence = 1,
    String? comicDirectoryName,
    CacheLayout? rootLayout,
  }) async {
    _requireOpen();
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ??
          buildComicDirectoryName(
            comicTitle: comicTitle,
            conflictSourceSuffix: conflictSourceSuffix,
          ),
    );
    final rootId = safTreeUri ??
        (rootLayout ?? layoutForSource(sourceId)).root;
    await _serializeStructuredWrite(
      'structured-migration:$rootId/$comicDir',
      () => _withStructuredDirectoryLock(
        rootId,
        comicDir,
        () => _migrateSingleChapterToSubdirectory(
          sourceId: sourceId,
          comicId: comicId,
          comicTitle: comicTitle,
          conflictSourceSuffix: conflictSourceSuffix,
          previousChapterId: previousChapterId,
          previousChapterTitle: previousChapterTitle,
          previousSequence: previousSequence,
          comicDirectoryName: comicDir,
          rootLayout: rootLayout,
        ),
      ),
    );
  }

  Future<void> _migrateSingleChapterToSubdirectory({
    required String sourceId,
    required String comicId,
    required String comicTitle,
    String? conflictSourceSuffix,
    required String previousChapterId,
    required String previousChapterTitle,
    int previousSequence = 1,
    String? comicDirectoryName,
    CacheLayout? rootLayout,
  }) async {
    _requireOpen();
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ??
          buildComicDirectoryName(
            comicTitle: comicTitle,
            conflictSourceSuffix: conflictSourceSuffix,
          ),
    );
    final previousManifest = await _readComicFolderManifest(
      comicDir,
      rootLayout: rootLayout,
    );
    final mappedChapterDir =
        previousManifest?.chapterDirectories[previousChapterId];
    final chapterDir = mappedChapterDir != null && mappedChapterDir.isNotEmpty
        ? _requireManifestDirectoryName(mappedChapterDir)
        : buildChapterDirectoryName(
            previousChapterTitle,
            fallbackIndex: previousSequence,
          );
    final candidates = <({
      CacheRec record,
      String destinationPath,
      File? destinationFile,
      String? sourceRelative,
      String? destinationRelative,
      bool destinationExisted,
    })>[];

    for (final record in await _index.list()) {
      final content = record.id.content;
      if (content.sourceId != sourceId ||
          content.comicId != comicId ||
          content.chapterId != previousChapterId ||
          !_isVerifiedReadyRecord(record)) {
        continue;
      }

      final parsed = parseSafRecordPath(record.path);
      if (parsed != null &&
          safIo != null &&
          treeUri != null &&
          parsed.treeUri == treeUri) {
        final segments = parsed.relativePath.split('/');
        if (segments.length != 2 || segments[0] != comicDir) continue;
        final newRel = '$comicDir/$chapterDir/${segments[1]}';
        candidates.add((
          record: record,
          destinationPath: encodeSafRecordPath(
            treeUri: treeUri,
            relativePath: newRel,
          ),
          destinationFile: null,
          sourceRelative: parsed.relativePath,
          destinationRelative: newRel,
          destinationExisted: await safIo.exists(newRel),
        ));
        continue;
      }

      if (record.path.isEmpty) continue;
      final sourceFile = File(record.path);
      final expectedParent = '${(rootLayout ?? layout).root}/$comicDir';
      if (!await sourceFile.exists() ||
          sourceFile.parent.path != expectedParent) {
        continue;
      }
      final destinationFile = File(
        '${sourceFile.parent.path}/$chapterDir/${sourceFile.uri.pathSegments.last}',
      );
      candidates.add((
        record: record,
        destinationPath: destinationFile.path,
        destinationFile: destinationFile,
        sourceRelative: null,
        destinationRelative: null,
        destinationExisted: await destinationFile.exists(),
      ));
    }

    // Validate every source and pre-existing destination before moving any
    // bytes. A metadata-only ready record is not sufficient for migration;
    // otherwise a same-length corruption could be moved while retaining its
    // old checksum proof.
    for (final candidate in candidates) {
      final sourceProof = await _artifactProof(candidate.record.path);
      if (!_proofMatchesRecord(sourceProof, candidate.record)) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message:
              'structured migration source failed content verification: '
              '${candidate.record.path}',
        );
      }
      if (candidate.destinationExisted) {
        final destinationProof =
            await _artifactProof(candidate.destinationPath);
        if (!_proofMatchesRecord(destinationProof, candidate.record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination conflicts with source: '
                '${candidate.destinationPath}',
          );
        }
      }
    }

    for (final candidate in candidates) {
      final record = candidate.record;
      final destinationPath = candidate.destinationPath;
      final destinationRelative = candidate.destinationRelative;
      if (destinationRelative != null &&
          safIo != null &&
          treeUri != null &&
          candidate.sourceRelative != null) {
        var createdDestination = false;
        if (!candidate.destinationExisted) {
          await writeBytesToSaf(
            safIo,
            destinationRelative,
            await _readArtifactBytes(record.path),
          );
          createdDestination = true;
          final destinationProof = await _artifactProof(destinationPath);
          if (!_proofMatchesRecord(destinationProof, record)) {
            if (createdDestination) {
              await safIo.delete(destinationRelative);
            }
            throw Failure(
              code: ErrorCode.artifactCorruption,
              message:
                  'structured migration destination failed content '
                  'verification: $destinationPath',
            );
          }
        }
        try {
          await _index.put(record.copyWith(path: destinationPath));
        } catch (_) {
          if (createdDestination) {
            try {
              await safIo.delete(destinationRelative);
            } catch (_) {}
          }
          rethrow;
        }
        await safIo.delete(candidate.sourceRelative!);
        continue;
      }

      final destinationFile = candidate.destinationFile;
      if (destinationFile == null) continue;
      final sourceFile = File(record.path);
      var moved = false;
      if (!candidate.destinationExisted) {
        await destinationFile.parent.create(recursive: true);
        await sourceFile.rename(destinationFile.path);
        moved = true;
        final movedProof = await _artifactProof(destinationFile.path);
        if (!_proofMatchesRecord(movedProof, record)) {
          try {
            await destinationFile.rename(sourceFile.path);
          } catch (_) {}
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination changed during move: '
                '${destinationFile.path}',
          );
        }
      } else {
        final destinationProof = await _artifactProof(destinationFile.path);
        if (!_proofMatchesRecord(destinationProof, record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration destination changed before move: '
                '${destinationFile.path}',
          );
        }
        final sourceProof = await _artifactProof(sourceFile.path);
        if (!_proofMatchesRecord(sourceProof, record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration source changed before move: '
                '${sourceFile.path}',
          );
        }
      }

      try {
        await _index.put(record.copyWith(path: destinationFile.path));
      } catch (_) {
        if (moved &&
            await destinationFile.exists() &&
            !await sourceFile.exists()) {
          try {
            await destinationFile.rename(sourceFile.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (!moved) {
        final sourceProof = await _artifactProof(sourceFile.path);
        if (!_proofMatchesRecord(sourceProof, record)) {
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'structured migration source changed before cleanup: '
                '${sourceFile.path}',
          );
        }
        await sourceFile.delete();
      }
    }
  }

  /// Inspects candidate comic directories and existing files prior to download.
  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async {
    _requireOpen();
    final preds = <String>{
      ...?knownPredecessorComicIds,
      for (final rel in _downloadHeadRelations)
        if (rel.sourceId == sourceId && rel.successorComicId == comicId)
          rel.predecessorComicId,
    };
    final succs = <String>{
      ...?knownSuccessorComicIds,
      for (final rel in _downloadHeadRelations)
        if (rel.sourceId == sourceId && rel.predecessorComicId == comicId)
          rel.successorComicId,
    };
    final knownOwners = <String, ({String sourceId, String comicId})>{};
    final relatedComicIds = <String>{
      comicId,
      ...preds,
      ...succs,
    };
    for (final relComicId in relatedComicIds) {
      final p = await _index.getPlacement(sourceId: sourceId, comicId: relComicId);
      if (p != null && p.relativeDirectory.isNotEmpty) {
        knownOwners[p.relativeDirectory] = (sourceId: sourceId, comicId: relComicId);
      }
    }
    final records = await _index.list();
    for (final rec in records) {
      final dir = _extractComicDirNameFromRecordPath(rec.path);
      if (dir != null && dir.isNotEmpty) {
        knownOwners.putIfAbsent(
          dir,
          () => (sourceId: rec.id.content.sourceId, comicId: rec.id.content.comicId),
        );
      }
    }
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    if (safIo != null && treeUri != null) {
      return inspectSafComicConflicts(
        safIo: safIo,
        safTreeUri: treeUri,
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
        knownPredecessorComicIds: preds.isNotEmpty ? preds : null,
        knownSuccessorComicIds: succs.isNotEmpty ? succs : null,
        knownDirectoryOwners: knownOwners,
      );
    }
    final rootDir = _registry.layoutForSource(sourceId).root;
    return inspectPosixComicConflicts(
      rootDirectory: rootDir,
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      comicId: comicId,
      comicTitle: comicTitle,
      knownPredecessorComicIds: preds.isNotEmpty ? preds : null,
      knownSuccessorComicIds: succs.isNotEmpty ? succs : null,
      knownDirectoryOwners: knownOwners,
    );
  }

  /// Scans the target comic folder (and chapter subfolder) on disk (or in SAF)
  /// and returns a map of existing page numbers (1-based) to their paths and byte sizes.
  Future<Map<int, ({String path, int bytes})>> scanExistingPages({
    required String comicTitle,
    required String chapterTitle,
    int sequence = 1,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
    CancelToken? cancelToken,
    DownloadId? layoutId,
  }) async {
    _requireOpen();
    final result = <int, ({String path, int bytes})>{};
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? buildComicDirectoryName(comicTitle: comicTitle),
    );
    final chapterDir = _requireSafeComicDirectoryName(
      chapterDirectoryName ??
          buildChapterDirectoryName(
            chapterTitle,
            fallbackIndex: sequence,
          ),
    );
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;

    if (safIo != null && treeUri != null) {
      final targetRelPath = isSingleChapter ? comicDir : '$comicDir/$chapterDir';
      final entries = await safIo.list(targetRelPath);
      for (final entry in entries) {
        cancelToken?.throwIfCancelled();
        if (entry.isDirectory) continue;
        final pageNum = parsePageIndexFromFileName(entry.name);
        if (pageNum != null && entry.length > 0) {
          final relPath = '$targetRelPath/${entry.name}';
          final handle = await safIo.open(relPath, mode: SafWriteMode.read);
          if (handle != null) {
            try {
              final header = await safIo.read(handle, 32);
              if (sniffImageExtensionFromBytes(header) != 'bin') {
                final recPath = encodeSafRecordPath(
                  treeUri: treeUri,
                  relativePath: relPath,
                );
                result[pageNum] = (path: recPath, bytes: entry.length);
              }
            } catch (_) {
              // Ignore unreadable entries
            } finally {
              await safIo.close(handle);
            }
          }
        }
      }
      return result;
    }

    final rootDir = (layoutId == null
            ? _registry.layout
            : _registry.layoutFor(layoutId))
        .root;
    final targetPath = isSingleChapter
        ? '$rootDir/$comicDir'
        : '$rootDir/$comicDir/$chapterDir';
    _rejectLocalPathLinks(targetPath);
    final targetDir = Directory(targetPath);
    if (!await targetDir.exists()) {
      return result;
    }

    try {
      await for (final entity in targetDir.list(followLinks: false)) {
        cancelToken?.throwIfCancelled();
        if (entity is File) {
          final fileName = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last
              : entity.path.split('/').last;
          final pageNum = parsePageIndexFromFileName(fileName);
          if (pageNum != null) {
            final len = await entity.length();
            if (len > 0) {
              final ext = await sniffImageExtension(entity);
              if (ext != 'bin') {
                result[pageNum] = (path: entity.path, bytes: len);
              }
            }
          }
        }
      }
    } catch (e) {
      if (e is Failure && e.code == ErrorCode.cancelled) rethrow;
    }

    return result;
  }

  /// Registers an already-present page file into the index without a
  /// network download. Returns the record so callers can update an in-memory
  /// index projection without a full re-scan.
  Future<CacheRec> adoptExistingPageRecord({
    required DownloadId id,
    required String path,
    required int bytes,
    required String checksum,
    String? artifactId,
    String? storageRootId,
  }) => _serializeArtifactMutation(
        id,
        () => _serializeStructuredWrite(
          path,
          () => _adoptExistingPageRecord(
            id: id,
            path: path,
            bytes: bytes,
            checksum: checksum,
            artifactId: artifactId,
            storageRootId: storageRootId,
          ),
        ),
      );

  Future<CacheRec> _adoptExistingPageRecord({
    required DownloadId id,
    required String path,
    required int bytes,
    required String checksum,
    String? artifactId,
    String? storageRootId,
  }) async {
    _requireOpen();
    final normalizedChecksum = checksum.trim().toLowerCase();
    if (bytes <= 0 ||
        !RegExp(r'^[0-9a-f]{8}$').hasMatch(normalizedChecksum)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'cannot adopt an artifact without content proof',
      );
    }
    final proof = await _artifactProof(path);
    if (proof.bytes != bytes || proof.checksum != normalizedChecksum) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact changed before adoption: $path',
      );
    }
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final rec = CacheRec(
      id: id,
      state: CacheState.ready,
      path: path,
      bytes: bytes,
      checksum: normalizedChecksum,
      createdUs: nowUs,
      touchedUs: nowUs,
      pinned: true,
      artifactId: artifactId ?? '',
      storageRootId: storageRootId ?? _storageRootIdForPath(path, id: id),
    );
    await _index.put(rec);
    return rec;
  }

  Future<void> forgetUnverifiedReadyRecord(CacheRec record) =>
      _serializeArtifactMutation(record.id, () async {
        _requireOpen();
        final current = await _index.get(record.key);
        if (current == null || !_sameIndexedRecord(record, current)) return;
        if (record.state == CacheState.ready &&
            !_isVerifiedReadyRecord(record)) {
          await _index.remove(record.key);
        }
      });

  /// Mirrors a freshly promoted local final into the configured SAF tree or
  /// structured POSIX comic folder and rewrites the index record to its path.
  Future<void> mirrorPromotedToSafIfConfigured(
    DownloadId id, {
    ImportedLibraryEntry? entry,
    int? pageIndex,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) => _serializeArtifactMutation(
        id,
        () => _mirrorPromotedToSafIfConfigured(
          id,
          entry: entry,
          pageIndex: pageIndex,
          isSingleChapter: isSingleChapter,
          comicDirectoryName: comicDirectoryName,
          chapterDirectoryName: chapterDirectoryName,
        ),
      );

  Future<void> _mirrorPromotedToSafIfConfigured(
    DownloadId id, {
    ImportedLibraryEntry? entry,
    int? pageIndex,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) async {
    final rec = (await _index.get(id.key));
    if (rec == null || parseSafRecordPath(rec.path) != null) return;
    final local = File(rec.path);
    if (rec.bytes <= 0 || !await local.exists()) return;
    final ext = await sniffImageExtension(local);
    if (entry != null && pageIndex != null && ext == 'bin') {
      final obviousText = await isHtmlOrTextFile(local);
      try {
        await local.delete();
      } on Object {}
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: obviousText
            ? 'downloaded page payload is HTML or non-image text: ${local.path}'
            : 'downloaded page payload has no supported image signature: ${local.path}',
      );
    }
    final token = _registry.layout.tokenFor(id);

    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;

    if (safIo != null && treeUri != null) {
      final String relativePath;
      if (entry != null && pageIndex != null) {
        final comicDir = _requireSafeComicDirectoryName(
          comicDirectoryName ??
              buildComicDirectoryName(
                comicTitle: entry.chapter.comicTitle,
              ),
        );
        final pageFileName = buildPageFileName(
          pageIndex: pageIndex,
          extension: ext,
        );
        if (isSingleChapter) {
          relativePath = '$comicDir/$pageFileName';
        } else {
          final chapterDir = _requireSafeComicDirectoryName(
            chapterDirectoryName ??
                buildChapterDirectoryName(
                  entry.chapter.displayName,
                  fallbackIndex: entry.chapter.sequence,
                ),
          );
          relativePath = '$comicDir/$chapterDir/$pageFileName';
        }

      } else {
        relativePath = 'final/$token.$ext';
      }

      final recordPath = encodeSafRecordPath(
        treeUri: treeUri,
        relativePath: relativePath,
      );
      await _serializeStructuredWrite(recordPath, () async {
        final siblings = (await _index.list()).where(
          (candidate) =>
              _isVerifiedReadyRecord(candidate) &&
              candidate.key != id.key &&
              candidate.path == recordPath,
        );
        final safExists = await safIo.exists(relativePath);
        if (safExists) {
          final proof = await _artifactProof(recordPath);
          if (_proofMatchesRecord(proof, rec)) {
            await _adoptExistingPageRecord(
              id: id,
              path: recordPath,
              bytes: rec.bytes,
              checksum: rec.checksum,
              artifactId: rec.artifactId,
              storageRootId: entry == null
                  ? safTreeUri
                  : storageRootIdFor(entry),
            );
            try {
              await local.delete();
            } on FileSystemException {
              // The shared structured final is already authoritative.
            }
            return;
          }
        }
        final placement = entry == null
            ? null
            : await resolveDownloadPlacement(entry);
        if (siblings.isNotEmpty || safExists) {
          if (placement?.mode != DownloadPlacementMode.overwrite &&
              placement?.mode != DownloadPlacementMode.incremental) {
            throw Failure(
              code: ErrorCode.policy,
              message: 'structured download destination contains different bytes: '
                  '$relativePath',
            );
          }
          if (siblings.any(
            (candidate) => !_bindingMayBeReplaced(candidate, id, placement),
          )) {
            throw Failure(
              code: ErrorCode.policy,
              message: 'structured target is still referenced by another owner: '
                  '$relativePath',
            );
          }
        }
        await copyFileIntoSaf(safIo, local, relativePath);
        final proof = await _artifactProof(recordPath);
        if (!_proofMatchesRecord(proof, rec)) {
          await _bytes.delete(recordPath);
          throw Failure(
            code: ErrorCode.artifactCorruption,
            message: 'structured target failed verification: $relativePath',
          );
        }
        final committed = rec.copyWith(
          path: recordPath,
          pinned: true,
          storageRootId: entry == null
              ? safTreeUri!
              : storageRootIdFor(entry),
        );
        if (placement?.mode == DownloadPlacementMode.overwrite) {
          await _index.replacePathBindings(
            record: committed,
            path: recordPath,
          );
        } else {
          await _index.put(committed);
        }
        try {
          await local.delete();
        } on FileSystemException {
          // The staging copy is redundant once the SAF bytes are authoritative;
          // a failed unlink only costs disk space until the next trim.
        }
      });
    } else if (entry != null && pageIndex != null) {
      final rootDir = _layoutForEntryPage(entry, pageIndex - 1).root;
      final comicDir = _requireSafeComicDirectoryName(
        comicDirectoryName ??
            buildComicDirectoryName(
              comicTitle: entry.chapter.comicTitle,
            ),
      );
      final pageFileName = buildPageFileName(
        pageIndex: pageIndex,
        extension: ext,
      );
      final String relativePath;
      if (isSingleChapter) {
        relativePath = '$comicDir/$pageFileName';
      } else {
        final chapterDir = _requireSafeComicDirectoryName(
          chapterDirectoryName ??
              buildChapterDirectoryName(
                entry.chapter.displayName,
                fallbackIndex: entry.chapter.sequence,
              ),
        );
        relativePath = '$comicDir/$chapterDir/$pageFileName';
      }
      final destFile = File('$rootDir/$relativePath');
      _rejectLocalPathLinks(destFile.path);
      if (destFile.path != local.path) {
        await _serializeStructuredWrite(destFile.path, () async {
          final siblings = (await _index.list()).where(
            (candidate) =>
                _isVerifiedReadyRecord(candidate) &&
                candidate.key != id.key &&
                candidate.path == destFile.path,
          );
          final destExists = await destFile.exists();
          if (destExists) {
            final proof = await _artifactProof(destFile.path);
            if (_proofMatchesRecord(proof, rec)) {
              await _adoptExistingPageRecord(
                id: id,
                path: destFile.path,
                bytes: rec.bytes,
                checksum: rec.checksum,
                artifactId: rec.artifactId,
                storageRootId: storageRootIdFor(entry),
              );
              try {
                await local.delete();
              } on FileSystemException {
                // The shared structured final is already authoritative.
              }
              return;
            }
          }
          final placement = await resolveDownloadPlacement(entry);
          if (siblings.isNotEmpty || destExists) {
            if (placement.mode != DownloadPlacementMode.overwrite &&
                placement.mode != DownloadPlacementMode.incremental) {
              throw Failure(
                code: ErrorCode.policy,
                message: 'structured download destination contains different bytes: '
                    '${destFile.path}',
              );
            }
            if (siblings.any(
              (candidate) => !_bindingMayBeReplaced(candidate, id, placement),
            )) {
              throw Failure(
                code: ErrorCode.policy,
                message: 'structured target is still referenced by another owner: '
                    '${destFile.path}',
              );
            }
          }
          if (!await destFile.parent.exists()) {
            await destFile.parent.create(recursive: true);
          }
          await local.rename(destFile.path);
          final committed = rec.copyWith(
            path: destFile.path,
            pinned: true,
            storageRootId: storageRootIdFor(entry),
          );
          try {
            if (placement.mode == DownloadPlacementMode.overwrite) {
              await _index.replacePathBindings(
                record: committed,
                path: destFile.path,
              );
            } else {
              await _index.put(committed);
            }
          } catch (_) {
            // Keep the original staging/index authority when the logical
            // binding commit fails. Without this rollback the destination
            // file is unindexed and the next scanner pass can delete it.
            if (await destFile.exists() && !await local.exists()) {
              try {
                await destFile.rename(local.path);
              } catch (_) {}
            }
            rethrow;
          }
        });
      }
    }
  }

  /// Materializes a sibling page file to this task's destination directory if
  /// the task uses a separate structured folder (e.g. createNew mode).
  Future<String> materializeSiblingToDestinationIfSeparate({
    required CacheRec siblingRecord,
    required ImportedLibraryEntry entry,
    required int pageNumber,
    bool isSingleChapter = false,
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) async {
    if (!_isVerifiedReadyRecord(siblingRecord)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'sibling artifact has no durable content proof',
      );
    }
    final placement = await resolveDownloadPlacement(entry);
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? placement.relativeDirectory,
    );
    final siblingPath = siblingRecord.path;
    final ext = await _sniffArtifactExtension(siblingPath);
    final pageFileName = buildPageFileName(
      pageIndex: pageNumber,
      extension: ext,
    );
    final safIo = safTreeIo;
    final treeUri = this.safTreeUri;
    final String relativePath;
    if (isSingleChapter) {
      relativePath = '$comicDir/$pageFileName';
    } else {
      final chapterDir = _requireSafeComicDirectoryName(
        chapterDirectoryName ??
            buildChapterDirectoryName(
              entry.chapter.displayName,
              fallbackIndex: entry.chapter.sequence,
            ),
      );
      relativePath = '$comicDir/$chapterDir/$pageFileName';
    }
    final targetPath = safIo != null && treeUri != null
        ? encodeSafRecordPath(
            treeUri: treeUri,
            relativePath: relativePath,
          )
        : '${_layoutForEntryPage(entry, pageNumber - 1).root}/$relativePath';
    if (targetPath == siblingPath) return siblingPath;
    if (safIo == null || treeUri == null) {
      _rejectLocalPathLinks(targetPath);
    }

    await _serializeStructuredWrite(targetPath, () async {
      if (await _bytes.exists(targetPath)) {
        final targetProof = await _artifactProof(targetPath);
        if (_proofMatchesRecord(targetProof, siblingRecord)) return;
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'materialized target contains different bytes: $targetPath',
        );
      }
      if (safIo != null && treeUri != null) {
        await _copyArtifactToSaf(
          siblingRecord,
          targetPath: targetPath,
          relativePath: relativePath,
        );
      } else {
        await _copyArtifactToLocal(siblingRecord, targetPath);
      }
      final targetProof = await _artifactProof(targetPath);
      if (!_proofMatchesRecord(targetProof, siblingRecord)) {
        await _bytes.delete(targetPath);
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'materialized target failed content verification: $targetPath',
        );
      }
    });
    return targetPath;
  }

  Future<String> _sniffArtifactExtension(String path) async {
    await for (final chunk in _bytes.readChunks(
      path,
      start: 0,
      endExclusive: 32,
    )) {
      final extension = sniffImageExtensionFromBytes(chunk);
      if (extension != 'bin') return extension;
      break;
    }
    return 'jpg';
  }

  Future<({int bytes, String checksum})> _artifactProof(String path) async {
    if (parseSafRecordPath(path) == null) {
      _rejectLocalPathLinks(path);
    }
    if (!await _bytes.exists(path)) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact file is missing: $path',
      );
    }
    final crc = Crc32();
    var bytes = 0;
    await for (final chunk in _bytes.readChunks(path, start: 0)) {
      crc.add(chunk);
      bytes += chunk.lengthInBytes;
    }
    return (bytes: bytes, checksum: crc.hex);
  }

  Future<Uint8List> _readArtifactBytes(String path) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _bytes.readChunks(path, start: 0)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  bool _proofMatchesRecord(
    ({int bytes, String checksum}) proof,
    CacheRec record,
  ) =>
      _isVerifiedReadyRecord(record) &&
      proof.bytes == record.bytes &&
      proof.checksum == record.checksum.trim().toLowerCase();

  Future<void> _copyArtifactToLocal(CacheRec source, String targetPath) async {
    _rejectLocalPathLinks(targetPath);
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$targetPath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = temporary.openWrite();
    final crc = Crc32();
    var bytes = 0;
    try {
      await for (final chunk in _bytes.readChunks(source.path, start: 0)) {
        sink.add(chunk);
        crc.add(chunk);
        bytes += chunk.lengthInBytes;
      }
      await sink.flush();
      await sink.close();
      if (bytes != source.bytes || crc.hex != source.checksum) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'sibling artifact changed during materialization: ${source.path}',
        );
      }
      await temporary.rename(targetPath);
    } on Object {
      try {
        await sink.close();
      } on Object {}
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  Future<void> _copyArtifactToSaf(
    CacheRec source, {
    required String targetPath,
    required String relativePath,
  }) async {
    final io = safTreeIo!;
    final treeUri = safTreeUri!;
    final temporaryPath =
        '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
    final temporaryRecordPath = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: temporaryPath,
    );
    final handle = await io.open(
      temporaryPath,
      mode: SafWriteMode.writeTruncate,
    );
    if (handle == null) {
      throw StateError('SAF tree refused create for $temporaryPath');
    }
    final crc = Crc32();
    var bytes = 0;
    try {
      await for (final chunk in _bytes.readChunks(source.path, start: 0)) {
        await io.write(handle, chunk);
        crc.add(chunk);
        bytes += chunk.lengthInBytes;
      }
    } finally {
      await io.close(handle);
    }
    try {
      if (bytes != source.bytes || crc.hex != source.checksum) {
        throw Failure(
          code: ErrorCode.artifactCorruption,
          message: 'sibling artifact changed during materialization: ${source.path}',
        );
      }
      final proof = await _artifactProof(temporaryRecordPath);
      if (!_proofMatchesRecord(proof, source)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'SAF temporary artifact failed content verification',
        );
      }
      await commitSafTemporary(io, temporaryPath, relativePath);
    } finally {
      if (await io.exists(temporaryPath)) {
        await io.delete(temporaryPath);
      }
    }
  }

  bool _bindingMayBeReplaced(
    CacheRec candidate,
    DownloadId id,
    DownloadPlacement? placement,
  ) {
    final candidateOwner =
        '${candidate.id.content.sourceId}\u0000${candidate.id.content.comicId}';
    final currentOwner = '${id.content.sourceId}\u0000${id.content.comicId}';
    return candidateOwner == currentOwner ||
        (placement?.mode == DownloadPlacementMode.overwrite &&
            placement?.observedOwnerKey == candidateOwner);
  }

  Future<T> _serializeArtifactMutation<T>(
    DownloadId id,
    Future<T> Function() operation,
  ) {
    final previous = _artifactMutationTails[id] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _artifactMutationTails[id] = tail;
    return current.whenComplete(() {
      if (identical(_artifactMutationTails[id], tail)) {
        _artifactMutationTails.remove(id);
      }
    });
  }

  Future<T> _serializeStructuredWrite<T>(
    String path,
    Future<T> Function() operation,
  ) {
    final previous = _structuredWriteTails[path] ?? Future<void>.value();
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    late final Future<void> tail;
    tail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _structuredWriteTails[path] = tail;
    return current.whenComplete(() {
      if (identical(_structuredWriteTails[path], tail)) {
        _structuredWriteTails.remove(path);
      }
    });
  }

  Future<T> _withStructuredManifestLock<T>(
    ImportedLibraryEntry entry,
    String comicDirectoryName,
    Future<T> Function() operation,
  ) async {
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) return operation();
    final root = entry.chapter.pages.isEmpty
        ? layout.root
        : _layoutForEntryPage(entry, 0).root;
    final lock = File('$root/$comicDirectoryName/.zic.lock');
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  Future<T> _withStructuredPlacementAllocationLock<T>(
    String rootId,
    Future<T> Function() operation,
  ) async {
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) return operation();
    final lock = File('$rootId${Platform.pathSeparator}.zic-placement.lock');
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  String? _extractComicDirNameFromRecordPath(
    String path, {
    DownloadId? id,
    String? storageRootId,
  }) {
    if (path.startsWith('saf:')) {
      final parsed = parseSafRecordPath(path);
      if (parsed == null ||
          (safTreeUri != null && parsed.treeUri != safTreeUri)) {
        return null;
      }
      final segments = parsed.relativePath.split('/');
      if (segments.isNotEmpty &&
          segments.first.isNotEmpty &&
          !segments.first.startsWith('.') &&
          segments.first != 'final' &&
          segments.first != 'partial') {
        return segments.first;
      }
      return null;
    }
    final root = storageRootId != null &&
            storageRootId.isNotEmpty &&
            storageRootId != 'default'
        ? storageRootId
        : id == null
            ? layout.root
            : layoutFor(id).root;
    if (path.startsWith('$root/')) {
      final rel = path.substring(root.length + 1);
      final segments = rel.split('/');
      if (segments.isNotEmpty &&
          segments.first.isNotEmpty &&
          !segments.first.startsWith('.') &&
          segments.first != 'final' &&
          segments.first != 'partial') {
        return segments.first;
      }
    }
    return null;
  }

  String _structuredDirectoryKey(String rootId, String directory) =>
      '$rootId\u0000$directory';

  void _rememberPlacementClaim(DownloadPlacement placement) {
    final directory = placement.relativeDirectory.trim();
    if (!_isSafeComicDirectoryName(directory)) return;
    final rootId = placement.storageRootId == 'default'
        ? layout.root
        : placement.storageRootId;
    final key = _structuredDirectoryKey(rootId, directory);
    final previous = _structuredOwnersByDirectory[key];
    if (previous == null || previous == placement.ownerKey) {
      _structuredOwnersByDirectory[key] = placement.ownerKey;
    } else {
      _structuredOwnersByDirectory[key] = '\u0000conflicting-placement';
    }
  }

  Future<void> _refreshPersistedPlacementClaims() async {
    final pendingWrites = _placementWrites.values.toList(growable: false);
    if (pendingWrites.isNotEmpty) {
      await Future.wait<void>(pendingWrites);
    }
    // Rebuild rather than only adding rows. Placements can be removed after a
    // chapter/comic delete, and retaining the old in-memory directory claim
    // would make a later owner look like a collision until process restart.
    _claimedPlacementsByOwner.clear();
    _structuredDirectoriesByOwner.clear();
    _structuredOwnersByDirectory.clear();
    for (final placement in await _index.listPlacements()) {
      final owner = placement.ownerKey;
      final directory = placement.relativeDirectory.trim();
      if (!_isSafeComicDirectoryName(directory)) continue;
      _claimedPlacementsByOwner[owner] = placement;
      _structuredDirectoriesByOwner[owner] = directory;
      _rememberPlacementClaim(placement);
    }
  }

  Future<void> _loadPersistedPlacementClaims() async {
    if (_placementClaimsLoaded) return;
    await _refreshPersistedPlacementClaims();
    _placementClaimsLoaded = true;
  }

  Future<T> _withStructuredDirectoryLock<T>(
    String rootId,
    String directory,
    Future<T> Function() operation,
  ) async {
    if (safTreeIo != null && safTreeUri != null) return operation();
    final lock = File(
      '$rootId${Platform.pathSeparator}$directory${Platform.pathSeparator}.zic.lock',
    );
    _rejectLocalPathLinks(lock.path);
    await lock.parent.create(recursive: true);
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        return await operation();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  Future<DownloadPlacement> resolveDownloadPlacement(
    ImportedLibraryEntry entry, {
    DownloadPlacement? requestedPlacement,
  }) async {
    _requireOpen();
    await _loadPersistedPlacementClaims();
    final owner = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    final currentRootId = storageRootIdFor(entry);
    final isSessionClaim = _sessionPlacementClaims.contains(owner);
    final activeClaim = _claimedPlacementsByOwner[owner];

    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:${entry.chapter.sourceId}',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'resolve-placement-start',
          'comicId': entry.chapter.comicId,
          'comicTitle': entry.chapter.comicTitle,
          'requestedPlacement': requestedPlacement?.relativeDirectory,
          'activeClaim': activeClaim?.relativeDirectory,
          'isSessionClaim': isSessionClaim,
        },
      ),
    );

    if (requestedPlacement != null) {
      final placement = requestedPlacement.copyWith(
        storageRootId: currentRootId,
        relativeDirectory: _requireSafeComicDirectoryName(
          requestedPlacement.relativeDirectory,
        ),
      );
      await _persistPlacement(placement);
      _claimedPlacementsByOwner[owner] = placement;
      _structuredDirectoriesByOwner[owner] = placement.relativeDirectory;
      _structuredOwnersByDirectory[
        _structuredDirectoryKey(currentRootId, placement.relativeDirectory)
      ] = owner;
      return placement;
    }

    if (activeClaim != null) {
      final directory = _requireSafeComicDirectoryName(
        activeClaim.relativeDirectory,
      );
      var effectiveClaim = activeClaim;
      if (effectiveClaim.pageOrder == ComicPageOrder.auto) {
        final diskManifest = await _readComicFolderManifest(
          directory,
          rootLayout: entry.chapter.pages.isEmpty
              ? layoutForSource(entry.chapter.sourceId)
              : _layoutForEntryPage(entry, 0),
        );
        if (diskManifest?.pageOrder != null &&
            diskManifest!.pageOrder != ComicPageOrder.auto) {
          effectiveClaim = effectiveClaim.copyWith(
            pageOrder: diskManifest.pageOrder,
          );
        }
      }
      final bindingChanged = activeClaim.storageRootId != currentRootId ||
          directory != activeClaim.relativeDirectory ||
          effectiveClaim.pageOrder != activeClaim.pageOrder;
      final normalized = bindingChanged
          ? effectiveClaim.copyWith(
              relativeDirectory: directory,
              storageRootId: currentRootId,
              generation: activeClaim.generation + 1,
              updatedAt: DateTime.now().toUtc(),
            )
          : effectiveClaim;
      if (bindingChanged) {
        await _persistPlacement(normalized);
      }
      _claimedPlacementsByOwner[owner] = normalized;
      _structuredDirectoriesByOwner[owner] = normalized.relativeDirectory;
      _structuredOwnersByDirectory[
        _structuredDirectoryKey(currentRootId, normalized.relativeDirectory)
      ] = owner;
      return normalized;
    }

    final allRecords = await _index.list();
    final hasRecords = allRecords.any((r) =>
        r.id.content.sourceId == entry.chapter.sourceId &&
        r.id.content.comicId == entry.chapter.comicId &&
        r.bytes > 0);

    if (hasRecords) {
      final legacyDirectories = <String>{};
      for (final record in allRecords) {
        final content = record.id.content;
        if (content.sourceId != entry.chapter.sourceId ||
            content.comicId != entry.chapter.comicId) {
          continue;
        }
        final directory = _extractComicDirNameFromRecordPath(
          record.path,
          id: record.id,
          storageRootId: record.storageRootId,
        );
        if (directory != null) legacyDirectories.add(directory);
      }
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: 'chapter-placement:${entry.chapter.sourceId}',
          kind: TraceEventKind.downloadState,
          identityHash: owner,
          payload: <String, Object?>{
            'stage': 'resolve-placement-legacy-check',
            'comicId': entry.chapter.comicId,
            'hasRecords': hasRecords,
            'legacyDirectories': legacyDirectories.toList(),
          },
        ),
      );
      if (legacyDirectories.length == 1) {
        final directory = legacyDirectories.single;
        final root = entry.chapter.pages.isEmpty
            ? layout.root
            : _layoutForEntryPage(entry, 0).root;
        final isSaf = safTreeIo != null && safTreeUri != null;
        final dirExists = isSaf
            ? await safTreeIo!.exists(directory)
            : await Directory('$root/$directory').exists();
        if (dirExists) {
          final diskManifest = await _readComicFolderManifest(
            directory,
            rootLayout: entry.chapter.pages.isEmpty
                ? layoutForSource(entry.chapter.sourceId)
                : _layoutForEntryPage(entry, 0),
          );
          final effectivePageOrder = diskManifest?.pageOrder != null &&
                  diskManifest!.pageOrder != ComicPageOrder.auto
              ? diskManifest.pageOrder
              : ComicPageOrder.auto;
          final migrated = DownloadPlacement(
            placementId: owner,
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            mode: DownloadPlacementMode.incremental,
            relativeDirectory: _requireSafeComicDirectoryName(directory),
            storageRootId: currentRootId,
            pageOrder: effectivePageOrder,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await _persistPlacement(migrated);
          _claimedPlacementsByOwner[owner] = migrated;
          _structuredDirectoriesByOwner[owner] = directory;
          _structuredOwnersByDirectory[
            _structuredDirectoryKey(currentRootId, directory)
          ] = owner;
          return migrated;
        }
      }
    }

    final base = buildComicDirectoryName(
      comicTitle: entry.chapter.comicTitle,
    );

    return _withStructuredPlacementAllocationLock(
      currentRootId,
      () => _serializeStructuredWrite('comic-directory:$base', () async {
        var candidate = base;
        var sequence = 1;
      while (true) {
        final reservedOwner = _structuredOwnersByDirectory[
          _structuredDirectoryKey(currentRootId, candidate)
        ];
        final diskManifest = await _readComicFolderManifest(
          candidate,
          rootLayout: entry.chapter.pages.isEmpty
              ? layoutForSource(entry.chapter.sourceId)
              : _layoutForEntryPage(entry, 0),
        );
        final manifestOwner = diskManifest == null
            ? null
            : '${diskManifest.sourceId}\u0000${diskManifest.comicId}';
        var claimedOwner = reservedOwner ?? manifestOwner;
        if (claimedOwner != null && claimedOwner != owner) {
          final root = entry.chapter.pages.isEmpty
              ? layout.root
              : _layoutForEntryPage(entry, 0).root;
          final isSaf = safTreeIo != null && safTreeUri != null;
          final dirExists = isSaf
              ? await safTreeIo!.exists(candidate)
              : await Directory('$root/$candidate').exists();
          if (!dirExists) {
            final isSessionClaim = _sessionPlacementClaims.contains(claimedOwner);
            if (!isSessionClaim) {
              claimedOwner = null;
            }
          } else {
            var hasRealImages = false;
            if (isSaf) {
              final files = await safTreeIo!.list(candidate);
              hasRealImages = files.any((f) =>
                  !f.isDirectory &&
                  !f.name.endsWith('.zic.lock') &&
                  !f.name.endsWith(comicManifestFileName) &&
                  f.length > 0);
            } else {
              final dir = Directory('$root/$candidate');
              final entities = await dir.list(followLinks: false).toList();
              for (final e in entities) {
                if (e is File &&
                    !e.path.endsWith('.zic.lock') &&
                    !e.path.endsWith(comicManifestFileName)) {
                  if (await e.length() > 0) {
                    hasRealImages = true;
                    break;
                  }
                }
              }
            }
            if (!hasRealImages) {
              final isSessionClaim = _sessionPlacementClaims.contains(claimedOwner);
              if (!isSessionClaim) {
                claimedOwner = null;
              }
            }
          }
          if (claimedOwner == null) {
            _structuredOwnersByDirectory.remove(
              _structuredDirectoryKey(currentRootId, candidate),
            );
            if (reservedOwner != null) {
              _claimedPlacementsByOwner.remove(reservedOwner);
              final parts = reservedOwner.split('\u0000');
              if (parts.length == 2) {
                await _index.removePlacement(
                  sourceId: parts[0],
                  comicId: parts[1],
                );
              }
            }
          }
        }
        final accepted = claimedOwner == null || claimedOwner == owner;
        _traceSink.record(
          traceEvent(
            clock: _clock,
            sessionId: 'chapter-placement:${entry.chapter.sourceId}',
            kind: TraceEventKind.downloadState,
            identityHash: owner,
            payload: <String, Object?>{
              'stage': 'candidate-inspection',
              'comicId': entry.chapter.comicId,
              'comicTitle': entry.chapter.comicTitle,
              'candidate': candidate,
              'sequence': sequence,
              'reservedOwner': reservedOwner,
              'manifestOwner': manifestOwner,
              'claimedOwner': claimedOwner,
              'accepted': accepted,
            },
          ),
        );
        if (accepted) {
          final effectivePageOrder = diskManifest?.pageOrder != null &&
                  diskManifest!.pageOrder != ComicPageOrder.auto
              ? diskManifest.pageOrder
              : ComicPageOrder.auto;
          final placement = DownloadPlacement(
            placementId: owner,
            sourceId: entry.chapter.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            mode: DownloadPlacementMode.createNew,
            relativeDirectory: candidate,
            storageRootId: currentRootId,
            pageOrder: effectivePageOrder,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          await _persistPlacement(placement);
          _sessionPlacementClaims.add(owner);
          _claimedPlacementsByOwner[owner] = placement;
          _structuredDirectoriesByOwner[owner] = candidate;
          _structuredOwnersByDirectory[
            _structuredDirectoryKey(currentRootId, candidate)
          ] = owner;
          return placement;
        }
        sequence++;
        final suffix = _structuredComicOwnerSuffix(entry);
        candidate = buildComicDirectoryName(
          comicTitle: entry.chapter.comicTitle,
          conflictSourceSuffix:
              sequence == 2 ? suffix : '$suffix ${sequence - 1}',
        );
      }
      }),
    );
  }

  Future<String> resolveStructuredComicDirectory(
    ImportedLibraryEntry entry,
  ) async {
    final placement = await resolveDownloadPlacement(entry);
    return placement.relativeDirectory;
  }

  bool _mappingIsPureFrontPrepend(ComicVersionPageMapping mapping) =>
      mapping.successorOffset > 0 &&
      mapping.successorPageCount ==
          mapping.predecessorPageCount + mapping.successorOffset;

  List<({
    ComicVersionRelation relation,
    ComicVersionPageMapping mapping,
  })> _downloadBaselinePredecessorMappings(ImportedLibraryEntry entry) {
    final chapter = entry.chapter;
    final matches = <({
      ComicVersionRelation relation,
      ComicVersionPageMapping mapping,
    })>[];
    for (final relation in _downloadHeadRelations) {
      if (relation.sourceId != chapter.sourceId ||
          relation.successorComicId != chapter.comicId) {
        continue;
      }
      for (final mapping in relation.pageMappings) {
        if (mapping.successorChapterId == chapter.chapterId &&
            mapping.successorPageCount == chapter.pages.length) {
          matches.add((relation: relation, mapping: mapping));
        }
      }
    }
    matches.sort((left, right) {
      final pages = right.mapping.predecessorPageCount.compareTo(
        left.mapping.predecessorPageCount,
      );
      if (pages != 0) return pages;
      return left.relation.predecessorComicId.compareTo(
        right.relation.predecessorComicId,
      );
    });
    return matches;
  }

  bool _hasVerifiedFrontPrependEvidence(ImportedLibraryEntry entry) =>
      _downloadBaselinePredecessorMappings(entry).any(
        (candidate) => _mappingIsPureFrontPrepend(candidate.mapping),
      );

  Future<DownloadPlacement> freezeExportPageOrder(
    ImportedLibraryEntry entry,
    DownloadPlacement placement, {
    required bool isSingleChapter,
  }) async {
    if (placement.pageOrder != ComicPageOrder.auto) return placement;
    final resolved = isSingleChapter && _hasVerifiedFrontPrependEvidence(entry)
        ? ComicPageOrder.chronological
        : ComicPageOrder.origin;
    return resolveDownloadPlacement(
      entry,
      requestedPlacement: placement.copyWith(
        pageOrder: resolved,
        generation: placement.generation + 1,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  bool _recordBelongsToExportPlacement(
    CacheRec record,
    DownloadPlacement placement,
  ) {
    final parsed = parseSafRecordPath(record.path);
    if (parsed != null) {
      return parsed.relativePath == placement.relativeDirectory ||
          parsed.relativePath.startsWith('${placement.relativeDirectory}/');
    }
    final root = placement.storageRootId == 'default'
        ? layoutFor(record.id).root
        : placement.storageRootId;
    final prefix = '$root/${placement.relativeDirectory}';
    return record.path == prefix || record.path.startsWith('$prefix/');
  }

  Future<Map<int, int>> _inheritedChronologicalOrdinals(
    ImportedLibraryEntry entry,
  ) async {
    final chapter = entry.chapter;
    var best = const <int, int>{};
    for (final candidate in _downloadBaselinePredecessorMappings(entry)) {
      final mapping = candidate.mapping;
      if (!_mappingIsPureFrontPrepend(mapping)) continue;
      final predecessorComicId = candidate.relation.predecessorComicId;
      final placement = await _index.getPlacement(
        sourceId: chapter.sourceId,
        comicId: predecessorComicId,
      );
      if (placement?.pageOrder != ComicPageOrder.chronological) continue;
      final bindings = await _index.listExportPageBindings(
        sourceId: chapter.sourceId,
        comicId: predecessorComicId,
        chapterId: mapping.predecessorChapterId,
      );
      if (bindings.length != mapping.predecessorPageCount) continue;
      final byIndex = <int, int>{
        for (final binding in bindings)
          binding.logicalIndex: binding.exportOrdinal,
      };
      if (byIndex.length != mapping.predecessorPageCount ||
          !Iterable<int>.generate(mapping.predecessorPageCount)
              .every(byIndex.containsKey)) {
        continue;
      }
      final inherited = <int, int>{};
      for (var currentIndex = 0;
          currentIndex < chapter.pages.length;
          currentIndex++) {
        final predecessorIndex = currentIndex - mapping.successorOffset;
        final ordinal = byIndex[predecessorIndex];
        if (ordinal != null) inherited[currentIndex] = ordinal;
      }
      if (inherited.length > best.length) best = inherited;
    }
    return best;
  }

  Future<Map<String, int>> ensureExportPageOrdinals(
    ImportedLibraryEntry entry,
    DownloadPlacement placement,
  ) async {
    if (placement.pageOrder == ComicPageOrder.auto) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'export page order must be frozen before page materialization',
      );
    }
    final chapter = entry.chapter;
    final pages = chapter.pages;
    final pageIndexById = <String, int>{
      for (var index = 0; index < pages.length; index++)
        pages[index].stablePageId: index,
    };
    final durable = await _index.listExportPageBindings(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapterId,
    );
    final bindingsByPage = <String, ExportPageBinding>{
      for (final binding in durable) binding.pageId: binding,
    };

    // Compatibility migration: if structured files predate export bindings,
    // preserve their already-visible ordinals instead of renumbering them.
    final indexed = await _index.list();
    for (final record in indexed) {
      if (record.id.content.sourceId != chapter.sourceId ||
          record.id.content.comicId != chapter.comicId ||
          record.id.content.chapterId != chapter.chapterId ||
          !_recordBelongsToExportPlacement(record, placement)) {
        continue;
      }
      final logicalIndex = pageIndexById[record.id.content.pageId];
      if (logicalIndex == null ||
          bindingsByPage.containsKey(record.id.content.pageId)) {
        continue;
      }
      final ordinal = parsePageIndexFromFileName(record.path);
      if (ordinal == null || ordinal <= 0) continue;
      bindingsByPage[record.id.content.pageId] = ExportPageBinding(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageId: record.id.content.pageId,
        logicalIndex: logicalIndex,
        exportOrdinal: ordinal,
        placementGeneration: placement.generation,
      );
    }

    if (placement.pageOrder == ComicPageOrder.chronological &&
        bindingsByPage.values.every(
          (binding) => !pageIndexById.containsKey(binding.pageId),
        )) {
      final inherited = await _inheritedChronologicalOrdinals(entry);
      for (final inheritedEntry in inherited.entries) {
        final pageId = pages[inheritedEntry.key].stablePageId;
        bindingsByPage.putIfAbsent(
          pageId,
          () => ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pageId,
            logicalIndex: inheritedEntry.key,
            exportOrdinal: inheritedEntry.value,
            placementGeneration: placement.generation,
          ),
        );
      }
    }

    final usedOrdinals = <int>{
      for (final binding in bindingsByPage.values) binding.exportOrdinal,
    };
    final currentBindings = <int, ExportPageBinding>{};
    for (var index = 0; index < pages.length; index++) {
      final binding = bindingsByPage[pages[index].stablePageId];
      if (binding != null) currentBindings[index] = binding;
    }

    if (placement.pageOrder == ComicPageOrder.origin) {
      for (var index = 0; index < pages.length; index++) {
        final expectedOrdinal = index + 1;
        final existing = currentBindings[index];
        if (existing != null && existing.exportOrdinal != expectedOrdinal) {
          throw Failure(
            code: ErrorCode.policy,
            message: 'origin export layout changed and requires explicit relayout',
            details: <String, Object?>{
              'pageId': pages[index].stablePageId,
              'existingOrdinal': existing.exportOrdinal,
              'expectedOrdinal': expectedOrdinal,
            },
          );
        }
        if (existing == null && usedOrdinals.contains(expectedOrdinal)) {
          throw Failure(
            code: ErrorCode.policy,
            message: 'origin export ordinal is occupied by a stale page binding',
            details: <String, Object?>{'exportOrdinal': expectedOrdinal},
          );
        }
        currentBindings[index] = ExportPageBinding(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          chapterId: chapter.chapterId,
          pageId: pages[index].stablePageId,
          logicalIndex: index,
          exportOrdinal: expectedOrdinal,
          placementGeneration: placement.generation,
        );
        usedOrdinals.add(expectedOrdinal);
      }
    } else {
      final orderedExistingIndexes = currentBindings.keys.toList()..sort();
      for (var cursor = 1; cursor < orderedExistingIndexes.length; cursor++) {
        final previous = currentBindings[orderedExistingIndexes[cursor - 1]]!;
        final next = currentBindings[orderedExistingIndexes[cursor]]!;
        if (previous.exportOrdinal <= next.exportOrdinal) {
          throw const Failure(
            code: ErrorCode.policy,
            message: 'chronological export bindings are not reverse-monotonic',
          );
        }
      }
      if (currentBindings.isEmpty) {
        var ordinal = 1;
        for (var index = pages.length - 1; index >= 0; index--) {
          currentBindings[index] = ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pages[index].stablePageId,
            logicalIndex: index,
            exportOrdinal: ordinal++,
            placementGeneration: placement.generation,
          );
        }
      } else {
        final firstExisting = currentBindings.keys.reduce(
          (left, right) => left < right ? left : right,
        );
        for (var index = firstExisting; index < pages.length; index++) {
          if (!currentBindings.containsKey(index)) {
            throw Failure(
              code: ErrorCode.policy,
              message: 'chronological export changed outside a front-prepend prefix',
              details: <String, Object?>{'logicalIndex': index},
            );
          }
        }
        var nextOrdinal = usedOrdinals.isEmpty
            ? 1
            : usedOrdinals.reduce((left, right) => left > right ? left : right) + 1;
        for (var index = firstExisting - 1; index >= 0; index--) {
          final existing = currentBindings[index];
          if (existing != null) continue;
          currentBindings[index] = ExportPageBinding(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            chapterId: chapter.chapterId,
            pageId: pages[index].stablePageId,
            logicalIndex: index,
            exportOrdinal: nextOrdinal++,
            placementGeneration: placement.generation,
          );
        }
      }
      // Refresh logical indexes after a front-prepend without changing ordinal.
      for (var index = 0; index < pages.length; index++) {
        final binding = currentBindings[index]!;
        currentBindings[index] = ExportPageBinding(
          sourceId: binding.sourceId,
          comicId: binding.comicId,
          chapterId: binding.chapterId,
          pageId: binding.pageId,
          logicalIndex: index,
          exportOrdinal: binding.exportOrdinal,
          placementGeneration: placement.generation,
        );
      }
    }

    await _index.putExportPageBindings(currentBindings.values);
    return <String, int>{
      for (final entry in currentBindings.entries)
        pages[entry.key].stablePageId: entry.value.exportOrdinal,
    };
  }

  /// Resolves a chapter export directory without allowing two chapters with
  /// the same cleaned title to share page filenames. Existing manifests and
  /// physical directories are considered together so this remains stable
  /// across restarts and across old v1 manifests.
  Future<String> resolveStructuredChapterDirectory(
    ImportedLibraryEntry entry, {
    required String comicDirectoryName,
  }) async {
    final base = buildChapterDirectoryName(
      entry.chapter.displayName,
      fallbackIndex: entry.chapter.sequence,
    );
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    final manifest = await _readComicFolderManifest(
      comicDirectoryName,
      rootLayout: rootLayout,
    );
    if (manifest?.chapters.contains(entry.chapter.chapterId) == true) {
      final mapped = manifest?.chapterDirectories[entry.chapter.chapterId];
      return mapped == null || mapped.isEmpty
          ? base
          : _requireManifestDirectoryName(mapped);
    }
    final used = <String>{
      ...?manifest?.chapterDirectories.values,
    };
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      for (final item in await safIo.list(comicDirectoryName)) {
        if (item.isDirectory) used.add(item.name);
      }
    } else {
      final directory = Directory('${rootLayout.root}/$comicDirectoryName');
      if (await directory.exists()) {
        await for (final item in directory.list(followLinks: false)) {
          if (item is Directory) {
            used.add(item.path.substring(directory.path.length + 1));
          }
        }
      }
    }
    if (!used.contains(base)) return base;
    final suffix = sanitizePathSegment(
      entry.chapter.chapterId,
      fallback: 'chapter',
      maxLength: 24,
    );
    var candidate = '$base ($suffix)';
    var sequence = 2;
    while (used.contains(candidate)) {
      candidate = '$base ($suffix $sequence)';
      sequence++;
    }
    return candidate;
  }

  Future<void> claimStructuredComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
    ComicPageOrder pageOrder = ComicPageOrder.auto,
  }) async {
    await _loadPersistedPlacementClaims();
    final clean = _requireSafeComicDirectoryName(directoryName);
    final owner = '$sourceId\u0000$comicId';
    final rootId = safTreeUri ?? layoutForSource(sourceId).root;
    await _withStructuredDirectoryLock<void>(rootId, clean, () async {
      await _refreshPersistedPlacementClaims();
      final claimedOwner = _structuredOwnersByDirectory[
        _structuredDirectoryKey(rootId, clean)
      ];
      final replacesObservedOwner = mode == DownloadPlacementMode.overwrite &&
          observedOwnerKey != null &&
          observedOwnerKey == claimedOwner;
      final displacedPlacement = replacesObservedOwner
          ? _claimedPlacementsByOwner[claimedOwner]
          : null;
      if (claimedOwner != null &&
          claimedOwner != owner &&
          !replacesObservedOwner) {
        throw Failure(
          code: ErrorCode.policy,
          message: 'download placement directory is already claimed',
          details: <String, Object?>{
            'directory': clean,
            'existingOwner': claimedOwner,
            'requestOwner': owner,
          },
        );
      }
      _traceSink.record(
        traceEvent(
          clock: _clock,
          sessionId: 'chapter-placement:$sourceId',
          kind: TraceEventKind.downloadState,
          identityHash: owner,
          payload: <String, Object?>{
            'stage': 'claim-comic-directory',
            'comicId': comicId,
            'comicTitle': comicTitle,
            'directoryName': clean,
            'mode': mode.name,
            'observedOwnerKey': observedOwnerKey,
          },
        ),
      );
      if (displacedPlacement != null) {
        _claimedPlacementsByOwner.remove(displacedPlacement.ownerKey);
        _structuredDirectoriesByOwner.remove(displacedPlacement.ownerKey);
      }
      _structuredDirectoriesByOwner[owner] = clean;
      _structuredOwnersByDirectory[
        _structuredDirectoryKey(rootId, clean)
      ] = owner;
      final previousOwnerPlacement = _claimedPlacementsByOwner[owner];
      final effectivePageOrder = pageOrder != ComicPageOrder.auto
          ? pageOrder
          : (previousOwnerPlacement?.pageOrder ?? ComicPageOrder.auto);
      final placement = DownloadPlacement(
        placementId: owner,
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: comicTitle ?? clean,
        mode: mode,
        relativeDirectory: clean,
        storageRootId: rootId,
        observedOwnerKey: observedOwnerKey,
        generation: (previousOwnerPlacement?.generation ?? -1) + 1,
        pageOrder: effectivePageOrder,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      _claimedPlacementsByOwner[owner] = placement;
      await _persistPlacement(placement);
      if (displacedPlacement != null) {
        await _index.removePlacement(
          sourceId: displacedPlacement.sourceId,
          comicId: displacedPlacement.comicId,
        );
      }
    });
  }

  Future<void> removeStructuredPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final owner = '$sourceId\u0000$comicId';
    await _index.removePlacement(sourceId: sourceId, comicId: comicId);
    final placement = _claimedPlacementsByOwner.remove(owner);
    _structuredDirectoriesByOwner.remove(owner);
    _sessionPlacementClaims.remove(owner);
    if (placement != null) {
      final rootId = placement.storageRootId == 'default'
          ? layout.root
          : placement.storageRootId;
      _structuredOwnersByDirectory.remove(
        _structuredDirectoryKey(rootId, placement.relativeDirectory),
      );
    }
    _structuredOwnersByDirectory.removeWhere((_, o) => o == owner);
    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:$sourceId',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'remove-structured-placement',
          'sourceId': sourceId,
          'comicId': comicId,
          'removedDirectory': placement?.relativeDirectory,
        },
      ),
    );
  }

  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    final owner = '$sourceId\u0000$comicId';
    await _placementWrites[owner];
    final mem = _claimedPlacementsByOwner[owner];
    final sqlite = await _index.getPlacement(sourceId: sourceId, comicId: comicId);
    final result = mem ?? sqlite;
    _traceSink.record(
      traceEvent(
        clock: _clock,
        sessionId: 'chapter-placement:$sourceId',
        kind: TraceEventKind.downloadState,
        identityHash: owner,
        payload: <String, Object?>{
          'stage': 'get-download-placement-detail',
          'sourceId': sourceId,
          'comicId': comicId,
          'hasMemoryClaim': mem != null,
          'memoryDirectory': mem?.relativeDirectory,
          'hasSqlitePlacement': sqlite != null,
          'sqliteDirectory': sqlite?.relativeDirectory,
          'resultDirectory': result?.relativeDirectory,
          'resultMode': result?.mode.name,
        },
      ),
    );
    return result;
  }

  Future<void> verifyStructuredDestinationOwner(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
  }) async {
    final placement = await resolveDownloadPlacement(entry);
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? placement.relativeDirectory,
    );
    final existing = await _readComicFolderManifest(
      comicDir,
      rootLayout: entry.chapter.pages.isEmpty
          ? layout
          : _layoutForEntryPage(entry, 0),
    );
    if (existing != null &&
        (existing.sourceId != entry.chapter.sourceId ||
            existing.comicId != entry.chapter.comicId)) {
      if (placement.mode == DownloadPlacementMode.overwrite &&
          placement.observedOwnerKey != null &&
          placement.observedOwnerKey ==
              '${existing.sourceId}\u0000${existing.comicId}') {
        // Explicitly authorized overwrite by user placement contract
        return;
      }
      throw Failure(
        code: ErrorCode.policy,
        message: 'download placement directory conflict: $comicDir is owned by '
            '${existing.sourceId}:${existing.comicId}',
        details: <String, Object?>{
          'directory': comicDir,
          'existingOwner': '${existing.sourceId}\u0000${existing.comicId}',
          'requestOwner':
              '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}',
        },
      );
    }
  }

  Future<void> writeComicFolderManifest(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
    String? chapterDirectoryName,
  }) async {
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? await resolveStructuredComicDirectory(entry),
    );
    final safeChapterDirectoryName = chapterDirectoryName == null
        ? null
        : _requireSafeComicDirectoryName(chapterDirectoryName);
    final manifestPath = '$comicDir/$comicManifestFileName';
    await _serializeStructuredWrite(
      manifestPath,
      () => _withStructuredManifestLock(entry, comicDir, () async {
      await verifyStructuredDestinationOwner(
        entry,
        comicDirectoryName: comicDir,
      );
      final chapters = (await downloadedChapterIds(
        sourceId: entry.chapter.sourceId,
        comicId: entry.chapter.comicId,
      )).toSet()
        ..add(entry.chapter.chapterId);
      final orderedChapters = chapters.toList(growable: true)..sort();
      final rootLayout = entry.chapter.pages.isEmpty
          ? layout
          : _layoutForEntryPage(entry, 0);
      final previous = await _readComicFolderManifest(
        comicDir,
        rootLayout: rootLayout,
      );
      final isSameComic = previous != null &&
          previous.sourceId == entry.chapter.sourceId &&
          previous.comicId == entry.chapter.comicId;
      final directories = <String, String>{
        if (isSameComic) ...previous.chapterDirectories,
      };
      final titles = <String, String>{
        if (isSameComic) ...previous.chapterTitles,
      };
      final sequences = <String, int>{
        if (isSameComic) ...previous.chapterSequences,
      };
      titles[entry.chapter.chapterId] = entry.chapter.displayName;
      sequences[entry.chapter.chapterId] = entry.chapter.sequence;
      if (orderedChapters.length > 1) {
        final usedDirectories = <String>{};
        for (final chapterId in orderedChapters) {
          final title = titles[chapterId] ?? chapterId;
          final sequence = sequences[chapterId] ?? 1;
          var candidate = directories[chapterId]?.isNotEmpty == true
              ? directories[chapterId]!
              : (chapterId == entry.chapter.chapterId &&
                      chapterDirectoryName != null
                  ? safeChapterDirectoryName!
                  : buildChapterDirectoryName(
                      title,
                      fallbackIndex: sequence,
                    ));
          if (!usedDirectories.add(candidate)) {
            final suffix = sanitizePathSegment(
              chapterId,
              fallback: 'chapter',
              maxLength: 24,
            );
            var serial = 2;
            final base = candidate;
            candidate = '$base ($suffix)';
            while (!usedDirectories.add(candidate)) {
              candidate = '$base ($suffix $serial)';
              serial++;
            }
          }
          directories[chapterId] = candidate;
        }
      } else {
        // A one-chapter comic is intentionally flat. Keep title/sequence
        // metadata so a later multi-chapter transition can migrate it.
        directories.remove(entry.chapter.chapterId);
      }
      final placement = await resolveDownloadPlacement(entry);
      final draft = ComicFolderManifest(
        comicTitle: entry.chapter.comicTitle,
        comicId: entry.chapter.comicId,
        sourceId: entry.chapter.sourceId,
        chapters: orderedChapters,
        chapterDirectories: directories,
        chapterTitles: titles,
        chapterSequences: sequences,
        generation: (isSameComic ? previous.generation : placement.generation) + 1,
        pageOrder: placement.pageOrder,
        updatedAt: DateTime.now(),
      );
      final manifest = ComicFolderManifest(
        format: draft.format,
        sourceId: draft.sourceId,
        sourceDisplayName: draft.sourceDisplayName,
        comicId: draft.comicId,
        comicTitle: draft.comicTitle,
        chapters: draft.chapters,
        chapterDirectories: draft.chapterDirectories,
        chapterTitles: draft.chapterTitles,
        chapterSequences: draft.chapterSequences,
        generation: draft.generation,
        fingerprint: draft.computedFingerprint,
        pageOrder: draft.pageOrder,
        updatedAt: draft.updatedAt,
      );
      final safIo = safTreeIo;
      if (safIo != null && safTreeUri != null) {
        await writeBytesToSaf(
          safIo,
          manifestPath,
          Uint8List.fromList(utf8.encode(manifest.encode())),
        );
        final committedPlacement = placement.copyWith(
          generation: manifest.generation,
          fingerprint: manifest.fingerprint,
        );
        await _persistPlacement(committedPlacement);
        _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
        return;
      }
      final root = entry.chapter.pages.isEmpty
          ? layout.root
          : _layoutForEntryPage(entry, 0).root;
      final file = File('$root/$manifestPath');
      await file.parent.create(recursive: true);
      final temporary = File(
        '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await temporary.writeAsString(manifest.encode(), flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
      final committedPlacement = placement.copyWith(
        generation: manifest.generation,
        fingerprint: manifest.fingerprint,
      );
      await _persistPlacement(committedPlacement);
      _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
      }),
    );
  }

  Future<void> cleanupStructuredChapterExport(
    ImportedLibraryEntry entry, {
    required String comicDirectoryName,
    String? chapterDirectoryName,
    required bool isSingleChapter,
  }) async {
    final safeComicDirectoryName =
        _requireSafeComicDirectoryName(comicDirectoryName);
    final safeChapterDirectoryName = chapterDirectoryName == null
        ? null
        : _requireSafeComicDirectoryName(chapterDirectoryName);
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    final prefix = isSingleChapter
        ? '$safeComicDirectoryName/'
        : '$safeComicDirectoryName/$safeChapterDirectoryName/';
    final manifest = await _readComicFolderManifest(
      safeComicDirectoryName,
      rootLayout: rootLayout,
    );
    final isOwner = manifest != null &&
        manifest.sourceId == entry.chapter.sourceId &&
        manifest.comicId == entry.chapter.comicId;
    if (manifest != null && !isOwner) {
      return;
    }
    final referenced = (await _index.list()).any((record) {
      if (record.state != CacheState.ready && record.state != CacheState.partial) {
        return false;
      }
      final parsed = parseSafRecordPath(record.path);
      if (parsed != null) {
        return safTreeUri == parsed.treeUri &&
            (parsed.relativePath == safeComicDirectoryName ||
                parsed.relativePath.startsWith(prefix));
      }
      final root = '${rootLayout.root}/';
      return record.path == '${root}$safeComicDirectoryName' ||
          record.path.startsWith('$root$prefix');
    });
    if (referenced) return;
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      await safIo.delete(
        isSingleChapter
            ? safeComicDirectoryName
            : '$safeComicDirectoryName/$safeChapterDirectoryName',
      );
      return;
    }
    final target = Directory(
      isSingleChapter
          ? '${rootLayout.root}/$safeComicDirectoryName'
          : '${rootLayout.root}/$safeComicDirectoryName/$safeChapterDirectoryName',
    );
    if (await target.exists()) await target.delete(recursive: true);
  }

  Future<void> removeChapterFromComicFolderManifest(
    ImportedLibraryEntry entry, {
    String? comicDirectoryName,
  }) async {
    final comicDir = _requireSafeComicDirectoryName(
      comicDirectoryName ?? await resolveStructuredComicDirectory(entry),
    );
    final rootLayout = entry.chapter.pages.isEmpty
        ? layout
        : _layoutForEntryPage(entry, 0);
    await _serializeStructuredWrite(
      '$comicDir/$comicManifestFileName',
      () => _withStructuredManifestLock(entry, comicDir, () async {
      final existing = await _readComicFolderManifest(
        comicDir,
        rootLayout: rootLayout,
      );
      if (existing == null ||
          existing.sourceId != entry.chapter.sourceId ||
          existing.comicId != entry.chapter.comicId) {
        // Never delete or rewrite a manifest owned by another comic/source,
        // even if a stale placement points this entry at the same directory.
        return;
      }
      final remaining = (await _index.list())
          .where((record) {
            final content = record.id.content;
            return content.sourceId == entry.chapter.sourceId &&
                content.comicId == entry.chapter.comicId &&
                record.bytes > 0 &&
                (record.state == CacheState.ready ||
                    record.state == CacheState.partial);
          })
          .map((record) => record.id.content.chapterId)
          .toSet();
      final chapters = existing.chapters
          .where(remaining.contains)
          .toList(growable: false);
      if (chapters.isEmpty) {
        final safIo = safTreeIo;
        if (safIo != null && safTreeUri != null) {
          await safIo.delete('$comicDir/$comicManifestFileName');
          await safIo.delete(comicDir);
        } else {
          final file = File(
            '${rootLayout.root}/$comicDir/$comicManifestFileName',
          );
          if (await file.exists()) await file.delete();
          final dir = Directory('${rootLayout.root}/$comicDir');
          if (await dir.exists()) {
            final entities = await dir.list(followLinks: false).toList();
            final nonLock = entities.where((e) => !e.path.endsWith('.zic.lock')).toList();
            if (nonLock.isEmpty) {
              await dir.delete(recursive: true);
            }
          }
        }
        final owner = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
        await _index.removePlacement(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
        );
        _claimedPlacementsByOwner.remove(owner);
        _structuredDirectoriesByOwner.remove(owner);
        _structuredOwnersByDirectory.remove(
          _structuredDirectoryKey(storageRootIdFor(entry), comicDir),
        );
        return;
      }
      final directories = <String, String>{
        for (final id in chapters)
          if (existing.chapterDirectories[id] != null)
            id: existing.chapterDirectories[id]!,
      };
      final titles = <String, String>{
        for (final id in chapters)
          if (existing.chapterTitles[id] != null) id: existing.chapterTitles[id]!,
      };
      final sequences = <String, int>{
        for (final id in chapters)
          if (existing.chapterSequences[id] != null)
            id: existing.chapterSequences[id]!,
      };
      final draft = ComicFolderManifest(
        format: existing.format,
        sourceId: existing.sourceId,
        sourceDisplayName: existing.sourceDisplayName,
        comicId: existing.comicId,
        comicTitle: existing.comicTitle,
        chapters: chapters,
        chapterDirectories: directories,
        chapterTitles: titles,
        chapterSequences: sequences,
        generation: existing.generation + 1,
        updatedAt: DateTime.now(),
      );
      final next = ComicFolderManifest(
        format: draft.format,
        sourceId: draft.sourceId,
        sourceDisplayName: draft.sourceDisplayName,
        comicId: draft.comicId,
        comicTitle: draft.comicTitle,
        chapters: draft.chapters,
        chapterDirectories: draft.chapterDirectories,
        chapterTitles: draft.chapterTitles,
        chapterSequences: draft.chapterSequences,
        generation: draft.generation,
        fingerprint: draft.computedFingerprint,
        updatedAt: draft.updatedAt,
      );
      final bytes = Uint8List.fromList(utf8.encode(next.encode()));
      final safIo = safTreeIo;
      if (safIo != null && safTreeUri != null) {
        await writeBytesToSaf(safIo, '$comicDir/$comicManifestFileName', bytes);
      } else {
        final file = File(
          '${rootLayout.root}/$comicDir/$comicManifestFileName',
        );
        await file.parent.create(recursive: true);
        final temporary = File(
          '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await temporary.writeAsString(next.encode(), flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      final placement = await resolveDownloadPlacement(entry);
      final committedPlacement = placement.copyWith(
        generation: next.generation,
        fingerprint: next.fingerprint,
      );
      await _persistPlacement(committedPlacement);
      _claimedPlacementsByOwner[placement.ownerKey] = committedPlacement;
      }),
    );
  }

  void _rejectLocalPathLinks(String path) {
    var current = File(path).absolute.path;
    final root = Directory(layout.root).absolute.path;
    while (true) {
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'structured download path contains a symbolic link',
        );
      }
      if (current == root) break;
      final parent = Directory(current).parent.path;
      if (parent == current) break;
      current = parent;
    }
  }

  Future<ComicFolderManifest?> _readComicFolderManifest(
    String comicDir, {
    CacheLayout? rootLayout,
  }) async {
    final manifestPath = '$comicDir/$comicManifestFileName';
    final safIo = safTreeIo;
    if (safIo != null && safTreeUri != null) {
      if (!await safIo.exists(manifestPath)) return null;
      final handle = await safIo.open(manifestPath, mode: SafWriteMode.read);
      if (handle == null) return null;
      try {
        final length = await safIo.length(handle) ?? 0;
        if (length <= 0) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest is empty',
          );
        }
        final bytes = await safIo.read(handle, length);
        final manifest = ComicFolderManifest.decode(utf8.decode(bytes));
        if (manifest == null) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest is invalid',
          );
        }
        if (!manifest.fingerprintValid) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'comic folder manifest fingerprint mismatch',
          );
        }
        _validateComicFolderManifest(manifest);
        return manifest;
      } finally {
        await safIo.close(handle);
      }
    }
    final file = File(
      '${(rootLayout ?? _registry.layout).root}/$comicDir/$comicManifestFileName',
    );
    _rejectLocalPathLinks(file.path);
    if (!await file.exists()) return null;
    final manifest = ComicFolderManifest.decode(await file.readAsString());
    if (manifest == null) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest is invalid',
      );
    }
    if (!manifest.fingerprintValid) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest fingerprint mismatch',
      );
    }
    _validateComicFolderManifest(manifest);
    return manifest;
  }

  void _validateComicFolderManifest(ComicFolderManifest manifest) {
    if (manifest.format != comicManifestFormatV1 ||
        manifest.sourceId.trim().isEmpty ||
        manifest.comicId.trim().isEmpty ||
        manifest.generation < 0) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest has invalid ownership metadata',
      );
    }
    for (final directory in manifest.chapterDirectories.values) {
      if (!_isSafeComicDirectoryName(directory)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'comic folder manifest contains an unsafe directory name',
        );
      }
    }
  }

  Future<void> _persistPlacement(DownloadPlacement placement) {
    final owner = placement.ownerKey;
    _sessionPlacementClaims.add(owner);
    final previous = _placementWrites[owner] ?? Future<void>.value();
    final current = previous.then<void>(
      (_) async {
        final existing = await _index.getPlacement(
          sourceId: placement.sourceId,
          comicId: placement.comicId,
        );
        final toWrite = existing != null && existing.generation >= placement.generation
            ? placement.copyWith(generation: existing.generation + 1)
            : placement;
        await _index.putPlacement(toWrite);
      },
      onError: (Object _, StackTrace __) async {
        final existing = await _index.getPlacement(
          sourceId: placement.sourceId,
          comicId: placement.comicId,
        );
        final toWrite = existing != null && existing.generation >= placement.generation
            ? placement.copyWith(generation: existing.generation + 1)
            : placement;
        await _index.putPlacement(toWrite);
      },
    );
    late final Future<void> tail;
    tail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _placementWrites[owner] = tail;
    return current.whenComplete(() {
      if (identical(_placementWrites[owner], tail)) {
        _placementWrites.remove(owner);
      }
    });
  }

  bool _isSafeComicDirectoryName(String value) {
    final clean = value.trim();
    return clean.isNotEmpty &&
        clean != '.' &&
        clean != '..' &&
        !clean.startsWith('.') &&
        !clean.contains('/') &&
        !clean.contains('\\');
  }

  String _requireSafeComicDirectoryName(String value) {
    final clean = value.trim();
    if (!_isSafeComicDirectoryName(clean)) {
      throw ArgumentError.value(
        value,
        'directoryName',
        'must be one safe relative directory name',
      );
    }
    return clean;
  }

  String _requireManifestDirectoryName(String value) {
    final clean = value.trim();
    if (!_isSafeComicDirectoryName(clean)) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'comic folder manifest contains an unsafe directory name',
      );
    }
    return clean;
  }

  String _structuredComicOwnerSuffix(ImportedLibraryEntry entry) {
    final source = sanitizePathSegment(
      entry.chapter.sourceId,
      fallback: 'source',
      maxLength: 40,
    );
    var hash = 0x811c9dc5;
    final identity = '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}';
    for (final unit in identity.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$source-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// Marks every indexed record of one chapter as explicitly downloaded so
  /// capacity trims and cache clears can no longer evict it. Returns the
  /// number of records newly pinned.
  Future<int> pinChapterRecords({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) async {
    _requireOpen();
    var pinnedCount = 0;
    for (final record in await _index.list()) {
      final content = record.id.content;
      final matches = content.sourceId == sourceId &&
          content.comicId == comicId &&
          content.chapterId == chapterId;
      if (matches && !record.pinned) {
        await _index.put(record.copyWith(pinned: true));
        pinnedCount++;
      }
    }
    return pinnedCount;
  }

  DownloadSession sessionFor(DownloadId id) => _registry.get(id);
  DownloadSession? findSession(DownloadId id) => _registry.find(id);

  Future<void> evict(DownloadId id) =>
      _serializeArtifactMutation(id, () => _evictUnserialized(id));

  Future<void> _evictUnserialized(DownloadId id) async {
    var session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        session = _registry.find(id);
        if (session == null || (!session.activeRun && !session.hasWriter)) {
          break;
        }
      }
    }
    if (session != null && (session.activeRun || session.hasWriter)) {
      try {
        await session.reset();
      } on Object {
        // ignore error if reset cannot complete cleanly
      }
    }
    final record = await _index.get(id.key);
    if (record != null) {
      final deletedPhysical = await _invalidateIndexedArtifact(
        id,
        record: record,
      );
      if (deletedPhysical && _registry.find(id) != null) {
        await _registry.evict(id);
      }
    } else if (session != null &&
        !session.activeRun &&
        !session.hasWriter &&
        session.state != DownloadState.disposed) {
      final finalPath = session.artifact.finalPath;
      final shared = await _index.isPathOrArtifactReferenced(
        path: finalPath,
        artifactId: '',
        excludingKey: id.key,
      );
      if (shared) {
        await session.resetIfIdle(removeCacheRecord: false);
      } else {
        await _registry.evict(id);
      }
    }
  }

  Future<Uint8List> readPromoted(DownloadId id) async {
    final entry = await openArtifactStream(id);
    if (entry == null) {
      throw StateError('requested page is not downloaded');
    }
    final readAll = entry.readAll;
    if (readAll != null) return readAll();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) =>
      _serializeArtifactMutation(id, () => _openArtifactStream(id));

  Future<ArtifactCacheStreamEntry?> _openArtifactStream(DownloadId id) async {
    _requireOpen();
    if (_artifactWrites.containsKey(id)) return null;
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return null;
    ArtifactReadFailure? lastReadFailure;
    Future<ArtifactCacheStreamEntry?> tryOpenExact(DownloadId candidate) async {
      try {
        return await _openArtifactStreamExact(candidate);
      } on ArtifactReadFailure catch (error) {
        lastReadFailure ??= error;
        return null;
      }
    }

    final exact = await tryOpenExact(id);
    if (exact != null) return exact;

    final allRecords = await _index.list();
    for (final cand in allRecords) {
      if (!_isVerifiedReadyRecord(cand)) continue;
      if (cand.id.canonicalUri == id.canonicalUri) {
        final stream = await tryOpenExact(cand.id);
        if (stream != null) return stream;
      }
    }

    final idVerified = verifiedRecordIdentities(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '',
        bytes: 0,
        checksum: '',
        createdUs: 0,
        touchedUs: 0,
      ),
    ).toSet();
    if (idVerified.isNotEmpty) {
      for (final cand in allRecords) {
        if (!_isVerifiedReadyRecord(cand)) continue;
        if (cand.id.content.sourceId == id.content.sourceId &&
            verifiedRecordIdentities(cand).any(idVerified.contains)) {
          final stream = await tryOpenExact(cand.id);
          if (stream != null) return stream;
        }
      }
    }

    for (final rel in _cacheVersionRelations) {
      final isSucc = rel.successorComicId == id.content.comicId;
      final isPred = rel.predecessorComicId == id.content.comicId;
      if (!isSucc && !isPred) continue;
      for (final mapping in rel.pageMappings) {
        final targetChapter =
            isSucc ? mapping.successorChapterId : mapping.predecessorChapterId;
        if (targetChapter != id.content.chapterId) continue;
        final otherChapter =
            isSucc ? mapping.predecessorChapterId : mapping.successorChapterId;
        final otherComic =
            isSucc ? rel.predecessorComicId : rel.successorComicId;
        for (final cand in allRecords) {
          if (!_isVerifiedReadyRecord(cand)) continue;
          if (cand.id.content.sourceId == id.content.sourceId &&
              cand.id.content.comicId == otherComic &&
              cand.id.content.chapterId == otherChapter) {
            if (cand.id.content.pageId == id.content.pageId ||
                cand.id.canonicalUri == id.canonicalUri) {
              final stream = await tryOpenExact(cand.id);
              if (stream != null) return stream;
            }
          }
        }
      }
    }
    if (lastReadFailure != null) {
      throw lastReadFailure!;
    }
    return null;
  }

  ArtifactReadFailure _enrichArtifactReadFailure(
    CacheRec record,
    ArtifactReadFailure failure,
  ) =>
      failure.replicaId == null
          ? failure.withReplicaId(record.effectiveArtifactId)
          : failure;

  Future<bool> _artifactRecordExists(CacheRec record) async {
    try {
      return await _bytes.exists(record.path);
    } on ArtifactReadFailure catch (error) {
      throw _enrichArtifactReadFailure(record, error);
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: record.path,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  Future<int> _artifactRecordLength(CacheRec record) async {
    try {
      return await _bytes.length(record.path);
    } on ArtifactReadFailure catch (error) {
      throw _enrichArtifactReadFailure(record, error);
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: record.path,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        cause: error,
      );
    }
  }

  Stream<Uint8List> _readArtifactRecord(
    CacheRec record, {
    required int start,
    int? endExclusive,
  }) async* {
    var emitted = 0;
    try {
      await for (final chunk in _bytes.readChunks(
        record.path,
        start: start,
        endExclusive: endExclusive,
      )) {
        emitted += chunk.length;
        yield chunk;
      }
    } on ArtifactReadFailure catch (error) {
      throw _enrichArtifactReadFailure(record, error);
    } on Object catch (error) {
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        accessLocator: record.path,
        replicaId: record.effectiveArtifactId,
        failedOffset: start + emitted,
        bytesEmitted: emitted,
        cause: error,
      );
    }
  }

  Future<ArtifactCacheStreamEntry?> _openArtifactStreamExact(DownloadId id) async {
    final record = await _index.get(id.key);
    if (record == null ||
        !_isVerifiedReadyRecord(record) ||
        record.id != id) {
      return null;
    }
    final file = record.path;
    final parsed = parseSafRecordPath(file);
    if (!_recordBelongsToCurrentRoot(id, record)) {
      // A root switch must not invalidate a binding that belongs to another
      // still-recoverable store. Reconcile it only when that root is selected.
      return null;
    }
    if (parsed != null && safTreeUri != null && parsed.treeUri != safTreeUri) {
      // The index may outlive a user-selected SAF tree. Do not invalidate a
      // row belonging to another grant; it can still be reconciled if that
      // tree is selected again.
      return null;
    }
    if (record.bytes <= 0) {
      await _invalidateIndexedArtifact(id, record: record);
      return null;
    }
    final exists = await _artifactRecordExists(record);
    if (!exists) {
      await _invalidateIndexedArtifact(id, record: record);
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.missing,
        accessLocator: file,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: record.bytes,
        observedLength: 0,
      );
    }
    final length = await _artifactRecordLength(record);
    if (length <= 0 || length != record.bytes) {
      await _invalidateIndexedArtifact(id, record: record);
      throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.lengthChanged,
        accessLocator: file,
        replicaId: record.effectiveArtifactId,
        failedOffset: 0,
        bytesEmitted: 0,
        expectedLength: record.bytes,
        observedLength: length,
      );
    }
    if (record.checksumAlgorithm.toLowerCase() != 'crc32') {
      await _invalidateIndexedArtifact(id, record: record);
      return null;
    }
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.touch(id.key, touchedUs);
    return ArtifactCacheStreamEntry(
      length: length,
      open: ({required int start, int? endExclusive}) => _readArtifactRecord(
        record,
        start: start,
        endExclusive: endExclusive,
      ),
      readAll: () => _readArtifactAllVerified(
        file,
        length,
        record.checksum.trim().toLowerCase(),
      ),
      readAllControlled: ({required control}) =>
          _readArtifactAllControlled(
            file,
            length,
            record.checksum.trim().toLowerCase(),
            control,
          ),
    );
  }

  Future<Uint8List> _readArtifactAllVerified(
    String file,
    int length,
    String expectedChecksum,
  ) async {
    final builder = BytesBuilder(copy: false);
    final crc = Crc32();
    await for (final chunk
        in _bytes.readChunks(file, start: 0, endExclusive: length)) {
      builder.add(chunk);
      crc.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.lengthInBytes != length || crc.hex != expectedChecksum) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact cache body changed while reading $file',
      );
    }
    return bytes;
  }

  Future<Uint8List> _readArtifactAllControlled(
    String file,
    int length,
    String expectedChecksum,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    final iterator = StreamIterator<List<int>>(
      _bytes.readChunks(file, start: 0, endExclusive: length),
    );
    final builder = BytesBuilder(copy: false);
    final crc = Crc32();
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      while (await _moveNextArtifactChunk(iterator, control)) {
        control.throwIfCancelled();
        builder.add(iterator.current);
        crc.add(iterator.current);
      }
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStack = stackTrace;
    }
    try {
      await iterator.cancel();
    } catch (error, stackTrace) {
      if (primaryError == null) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    final bytes = builder.takeBytes();
    if (bytes.lengthInBytes != length || crc.hex != expectedChecksum) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'artifact cache body changed while reading $file',
      );
    }
    return bytes;
  }

  Future<bool> _moveNextArtifactChunk(
    StreamIterator<List<int>> iterator,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    try {
      return await Future.any<bool>(<Future<bool>>[
        iterator.moveNext(),
        control.whenCancelled.then<bool>((_) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'artifact cache read was cancelled',
          );
        }),
      ]);
    } catch (error, stackTrace) {
      if (control.cancelled) control.throwIfCancelled();
      throw Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _recordBelongsToCurrentRoot(DownloadId id, CacheRec record) {
    final parsed = parseSafRecordPath(record.path);
    if (parsed != null) {
      return safTreeUri != null && parsed.treeUri == safTreeUri;
    }
    if (record.storageRootId == 'default' || record.storageRootId.isEmpty) {
      return true;
    }
    final root = layoutFor(id).root;
    return record.storageRootId == root &&
        (record.path == root || record.path.startsWith('$root/'));
  }

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) =>
      _serializeArtifactMutation(id, () => _openPartialDownload(id));

  Future<PartialDownloadEntry?> _openPartialDownload(DownloadId id) async {
    _requireOpen();
    if (_artifactWrites.containsKey(id)) return null;
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return null;

    // Durable partial/artifact lookup is an index/file concern. Do not
    // materialize a synthetic DownloadSession merely to discover whether cold
    // bytes exist. The composition physical session remains the only Reader
    // transfer owner.
    final record = await _index.get(id.key);
    if (record != null &&
        _isVerifiedReadyRecord(record) &&
        record.id == id &&
        record.bytes > 0) {
      final stream = await _openArtifactStream(id);
      if (stream != null) {
        final validators = Validators(etag: '"${stream.length}-${id.key}"');
        return PartialDownloadEntry(
          length: stream.length,
          validators: validators,
          totalLength: stream.length,
          open: ({required int start}) => stream.open(
            start: start,
            endExclusive: stream.length,
          ),
        );
      }
    }
    if (record == null ||
        record.state != CacheState.partial ||
        record.id != id ||
        record.bytes <= 0) {
      return null;
    }
    final parsed = parseSafRecordPath(record.path);
    if (!_recordBelongsToCurrentRoot(id, record)) return null;
    if (parsed != null) {
      if (safTreeUri == null || parsed.treeUri != safTreeUri) return null;
      final length = await _bytes.length(record.path);
      if (length <= 0 || length != record.bytes) {
        await _invalidateIndexedArtifact(id, record: record);
        await safTreeIo?.delete('${parsed.relativePath}.meta');
        return null;
      }
      final resume = await _readSafPartialResumeState(record.path, id);
      if (resume.explicitDifferentOwner) {
        // Metadata proves the bytes are foreign, but it does not authorize
        // deleting them. Drop only this logical binding and leave the
        // unowned bytes for the actual owner or an explicit cleanup action.
        await _forgetIndexedBinding(id, record: record);
        return null;
      }
      final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
      await _index.touch(id.key, touchedUs);
      return PartialDownloadEntry(
        length: length,
        validators: resume.validators,
        totalLength: resume.totalLength,
        open: ({required int start}) => _bytes.readChunks(
          record.path,
          start: start,
          endExclusive: length,
        ),
      );
    }

    final file = File(record.path);
    if (!await file.exists()) {
      await _invalidateIndexedArtifact(id, record: record);
      return null;
    }
    final length = await file.length();
    if (length <= 0 || length != record.bytes) {
      await _invalidateIndexedArtifact(id, record: record);
      final metadata = File('${record.path}.meta');
      if (await metadata.exists()) await metadata.delete();
      return null;
    }

    final resume = await _readIndexedPartialResumeState(record.path, id);
    if (resume.explicitDifferentOwner) {
      // Metadata proves the bytes are foreign, but it does not authorize
      // deleting them. Drop only this logical binding and leave the
      // unowned bytes for the actual owner or an explicit cleanup action.
      await _forgetIndexedBinding(id, record: record);
      return null;
    }
    final touchedUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await _index.touch(id.key, touchedUs);
    return PartialDownloadEntry(
      length: length,
      validators: resume.validators,
      totalLength: resume.totalLength,
      open: ({required int start}) => _readIndexedChunks(
        record.path,
        length: length,
        start: start,
      ),
    );
  }

  Future<_IndexedPartialResumeState> _readSafPartialResumeState(
    String path,
    DownloadId id,
  ) async {
    final parsed = parseSafRecordPath(path);
    if (parsed == null || safTreeIo == null || safTreeUri == null) {
      return const _IndexedPartialResumeState();
    }
    final metadataPath = '${parsed.relativePath}.meta';
    if (!await safTreeIo!.exists(metadataPath)) {
      return const _IndexedPartialResumeState();
    }
    final handle = await safTreeIo!.open(metadataPath, mode: SafWriteMode.read);
    if (handle == null) return const _IndexedPartialResumeState();
    try {
      final length = await safTreeIo!.length(handle) ?? 0;
      if (length <= 0) return const _IndexedPartialResumeState();
      final bytes = await safTreeIo!.read(handle, length);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return const _IndexedPartialResumeState();
      final meta = Map<String, Object?>.from(decoded);
      final key = meta['downloadKey'];
      if (key is String && key != id.key) {
        return const _IndexedPartialResumeState(explicitDifferentOwner: true);
      }
      final rawDownload = meta['download'];
      if (rawDownload is Map) {
        try {
          if (DownloadId.fromJson(Map<String, Object?>.from(rawDownload)) != id) {
            return const _IndexedPartialResumeState(
              explicitDifferentOwner: true,
            );
          }
        } on Object {
          return const _IndexedPartialResumeState();
        }
      }
      final rawValidators = meta['validators'];
      final rawLength = meta['totalLength'];
      if (rawValidators is! Map ||
          (rawLength != null && rawLength is! int)) {
        return const _IndexedPartialResumeState();
      }
      var validators = Validators.fromJson(
        Map<String, Object?>.from(rawValidators),
      );
      final rawRequestUri = meta['validatorRequestUri'];
      final requestUri = rawRequestUri is String
          ? Uri.tryParse(rawRequestUri)
          : null;
      if (validators.canResume && requestUri != id.canonicalUri) {
        validators = const Validators();
      }
      return _IndexedPartialResumeState(
        validators: validators,
        totalLength: rawLength as int?,
      );
    } on Object {
      return const _IndexedPartialResumeState();
    } finally {
      await safTreeIo!.close(handle);
    }
  }

  Future<void> _storePartialDownloadInSaf(
    DownloadId id,
    PartialDownloadEntry entry,
  ) async {
    final io = safTreeIo!;
    final treeUri = safTreeUri!;
    final relativePath = 'partial/${layoutFor(id).tokenFor(id)}.part';
    final recordPath = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: relativePath,
    );
    final previous = await _index.get(id.key);
    if (previous != null && _isVerifiedReadyRecord(previous)) return;
    await _serializeStructuredWrite(recordPath, () async {
      final existingResume = await _readSafPartialResumeState(recordPath, id);
      if (existingResume.explicitDifferentOwner) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'SAF partial artifact metadata belongs to another download',
        );
      }
      final temporaryPath =
          '$relativePath.zic-tmp-${DateTime.now().microsecondsSinceEpoch}';
      final handle = await io.open(
        temporaryPath,
        mode: SafWriteMode.writeTruncate,
      );
      if (handle == null) {
        throw StateError('SAF tree refused create for $temporaryPath');
      }
      var written = 0;
      try {
        await for (final chunk in entry.open(start: 0)) {
          if (chunk.isEmpty) continue;
          await io.write(handle, chunk is Uint8List
              ? chunk
              : Uint8List.fromList(chunk));
          written += chunk.length;
        }
      } finally {
        await io.close(handle);
      }
      try {
        if (written != entry.length) {
          throw StateError(
            'partial artifact length changed while storing ${id.key}: '
            '$written/${entry.length}',
          );
        }
        final beforeCommitResume =
            await _readSafPartialResumeState(recordPath, id);
        if (beforeCommitResume.explicitDifferentOwner) {
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message:
                'SAF partial artifact owner changed before commit',
          );
        }
        await commitSafTemporary(io, temporaryPath, relativePath);
      } finally {
        if (await io.exists(temporaryPath)) {
          await io.delete(temporaryPath);
        }
      }
      final now = DateTime.now().toUtc().microsecondsSinceEpoch;
      final record = CacheRec(
        id: id,
        state: CacheState.partial,
        path: recordPath,
        bytes: written,
        checksum: '',
        createdUs: previous?.createdUs ?? now,
        touchedUs: now,
        pinned: false,
        storageRootId: treeUri,
      );
      // Metadata is an optimization for validator-bound resume. A provider
      // failure here must not discard the newly committed media prefix.
      try {
        await writeBytesToSaf(
          io,
          '$relativePath.meta',
          Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'downloadKey': id.key,
                'download': id.toJson(),
                'validators': entry.validators.toJson(),
                'totalLength': entry.totalLength,
                'validatorRequestUri': id.canonicalUri.toString(),
              }),
            ),
          ),
        );
      } on Object {
        // The indexed partial remains resumable without validators.
      }
      await _index.put(record);
      if (previous != null && previous.path != recordPath) {
        final previousStillReferenced =
            await _index.isPathOrArtifactReferenced(
          path: previous.path,
          artifactId: previous.effectiveArtifactId,
          excludingKey: id.key,
        );
        final previousSaf = parseSafRecordPath(previous.path);
        if (!previousStillReferenced && previousSaf == null) {
          await _bytes.delete(previous.path);
          final previousMeta = File('${previous.path}.meta');
          if (await previousMeta.exists()) await previousMeta.delete();
        }
      }
    });
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) => _serializeArtifactMutation(
        id,
        () => _storePartialDownload(
          id: id,
          entry: entry,
        ),
      );

  Future<void> _storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {
    _requireOpen();
    if (entry.length <= 0) return;
    if (safTreeIo != null && safTreeUri != null) {
      await _storePartialDownloadInSaf(id, entry);
      return;
    }
    final session = _registry.get(id);
    if (session.activeRun || session.hasWriter) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    await session.restore(verifyPromotedChecksum: false);
    if (session.state == DownloadState.promoted ||
        session.artifact.committedLength >= entry.length) {
      return;
    }
    await session.bindResponse(
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
    final writer = session.acquireWriter();
    var offset = session.artifact.committedLength;
    try {
      await for (final chunk in entry.open(start: offset)) {
        if (chunk.isEmpty) continue;
        await session.append(writer, offset, chunk);
        offset += chunk.length;
      }
      if (offset != entry.length) {
        throw StateError(
          'partial artifact length changed while storing ${id.key}: '
          '$offset/${entry.length}',
        );
      }
    } on Object catch (error) {
      await session.fail(writer, error);
      rethrow;
    }
    await session.pause(writer);
  }

  @override
  Future<void> invalidatePartialDownload(DownloadId id) =>
      _serializeArtifactMutation(id, () => _invalidatePartialDownload(id));

  Future<void> _invalidatePartialDownload(DownloadId id) async {
    _requireOpen();
    var session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    if (session != null && session.state != DownloadState.promoted) {
      // Reset through the session lifecycle, not directly through Artifact:
      // the session must advance its epoch and clear Reader ingress
      // projections before the physical partial is invalidated. A direct
      // Artifact.reset() leaves those projections advertising bytes that no
      // longer exist and permits a stale append/replay completion to publish
      // into the cleared generation.
      await session.reset(removeCacheRecord: false);
    }
    session = _registry.find(id);
    if (session != null && (session.activeRun || session.hasWriter)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'partial download store destination is busy',
      );
    }
    final record = await _index.get(id.key);
    if (record?.state == CacheState.partial) {
      await _invalidateIndexedArtifact(id, record: record);
    }
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) {
    _requireOpen();
    if (bytes.isEmpty) {
      throw StateError('cannot cache an empty Reader artifact');
    }
    final ownedBytes = Uint8List.fromList(bytes);
    final checksum = Crc32()..add(ownedBytes);
    final checksumHex = checksum.hex;
    final active = _artifactWrites[id];
    if (active != null) {
      final proof = _artifactWriteProofs[id];
      if (proof == null ||
          proof.length != ownedBytes.lengthInBytes ||
          proof.checksum != checksumHex) {
        return Future<void>.error(const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'concurrent artifact writes contain different content',
        ));
      }
      return active;
    }
    final run = _serializeArtifactMutation(
      id,
      () => _storePromotedArtifact(id, ownedBytes, checksumHex: checksumHex),
    );
    _artifactWrites[id] = run;
    _artifactWriteProofs[id] = (
      length: ownedBytes.lengthInBytes,
      checksum: checksumHex,
    );
    return run.whenComplete(() {
      if (identical(_artifactWrites[id], run)) {
        _artifactWrites.remove(id);
        _artifactWriteProofs.remove(id);
      }
    });
  }

  Future<void> _storePromotedArtifact(
    DownloadId id,
    Uint8List bytes, {
    String? checksumHex,
  }) async {
    final session = _registry.get(id);
    if (session.activeRun || session.hasWriter) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'artifact cache destination is busy',
      );
    }
    await session.restore();
    final effectiveChecksum = checksumHex ?? (Crc32()..add(bytes)).hex;
    if (session.state == DownloadState.promoted) {
      if (session.committedLength != bytes.lengthInBytes ||
          session.artifact.checksum != effectiveChecksum) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact already contains different content',
        );
      }
      return;
    }
    if (session.committedLength > 0) {
      await session.reset(removeCacheRecord: false);
    }
    final runLease = session.beginRun();
    try {
      final writer = session.acquireWriter(expectedRun: runLease);
      try {
        await session.append(writer, 0, bytes);
        await session.seal(
          writer,
          expectedLength: bytes.lengthInBytes,
          expectedChecksum: effectiveChecksum,
        );
      } catch (error) {
        if (session.hasWriter) {
          try {
            await session.fail(writer, error);
          } catch (_) {}
        }
        rethrow;
      }
      await session.promote(expectedRun: runLease);
    } finally {
      session.endRun(runLease);
    }
    final placement = await _index.getPlacement(
      sourceId: id.content.sourceId,
      comicId: id.content.comicId,
    );
    if (placement != null) {
      final rec = await _index.get(id.key);
      if (rec != null && !rec.pinned) {
        await _index.put(rec.copyWith(pinned: true));
      }
    }
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) => _serializeArtifactMutation(
        id,
        () async {
          _requireOpen();
          final record = await _index.get(id.key);
          final deletedPhysical = await _invalidateIndexedArtifact(
            id,
            record: record,
          );
          if (deletedPhysical && _registry.find(id) != null) {
            await _registry.evict(id);
          }
        },
      );

  Future<int> _evictCacheRecord(
    DownloadId id, {
    CacheRec? expected,
  }) =>
      _serializeArtifactMutation(
        id,
        () async {
          final record = await _index.get(id.key);
          if (record == null ||
              (expected != null && !_sameIndexedRecord(expected, record))) {
            return 0;
          }
          final released = record.bytes;
          final deletedPhysical = await _invalidateIndexedArtifact(
            id,
            record: record,
          );
          if (deletedPhysical && _registry.find(id) != null) {
            // The physical reference check has already completed successfully;
            // now clear the session's Artifact state as well. Never do this
            // for a shared path because registry.evict deletes blindly.
            await _registry.evict(id);
          }
          return released;
        },
      );

  Future<bool> _invalidateIndexedArtifact(
    DownloadId id, {
    CacheRec? record,
  }) async {
    final snapshot = await _index.get(id.key);
    if (snapshot == null) return false;
    if (record != null && !_sameIndexedRecord(record, snapshot)) {
      // Cache trim and invalidation callers may be acting on a snapshot. Never
      // remove a newer binding that reused the same logical key.
      return false;
    }
    if (!_recordBelongsToCurrentRoot(id, snapshot)) {
      // A store opened after a root change may still contain historical
      // bindings. The current owner must not remove bytes belonging to that
      // other root; reconciliation occurs only when that root is selected.
      return false;
    }
    // Physical paths can be shared by multiple logical records. Coordinate
    // invalidation with adoption, structured materialization, and mirroring on
    // the physical path; otherwise a new binding can be installed after the
    // reference scan below but before the bytes are deleted. Treat the current
    // row as the expected snapshot even when the caller did not supply one so
    // a rebind while waiting can only make this operation a no-op.
    return _serializeStructuredWrite(
      snapshot.path,
      () => _invalidateIndexedArtifactLocked(id, record: snapshot),
    );
  }

  Future<bool> _invalidateIndexedArtifactLocked(
    DownloadId id, {
    required CacheRec record,
  }) async {
    final initial = await _index.get(id.key);
    if (initial == null) return false;
    if (!_sameIndexedRecord(record, initial)) {
      // Cache trim and invalidation callers may be acting on a snapshot. Never
      // remove a newer binding that reused the same logical key.
      return false;
    }
    final active = _registry.find(id);
    if (active != null && (active.activeRun || active.hasWriter)) return false;

    Future<bool> removeBindingAndPhysical({required bool sessionWasReset}) async {
      final current = initial;
      await _index.remove(id.key);
      if (await _index.get(id.key) != null) return false;
      final isReferencedByOther = await _index.isPathOrArtifactReferenced(
        path: current.path,
        artifactId: current.effectiveArtifactId,
        excludingKey: id.key,
      );
      if (await _index.get(id.key) != null) return false;
      final activeAfterRemoval = _registry.find(id);
      if (activeAfterRemoval != null &&
          (activeAfterRemoval.activeRun ||
              activeAfterRemoval.hasWriter ||
              activeAfterRemoval.demanded)) {
        // A session may have become active after the initial guard while the
        // index mutation was awaiting storage. Do not delete its bytes merely
        // because the row disappeared during that race.
        return false;
      }
      if (!sessionWasReset &&
          activeAfterRemoval != null &&
          activeAfterRemoval.state != DownloadState.disposed &&
          _recordPathMatchesSession(current, activeAfterRemoval)) {
        // A new session appeared for the same binding after the initial
        // snapshot. It owns the current lifecycle now; leave the physical
        // bytes untouched rather than resetting it after its row was removed.
        return false;
      }
      if (isReferencedByOther) return false;
      await _bytes.delete(current.path);
      await _deleteArtifactSidecar(current.path);
      return true;
    }

    if (active != null &&
        active.state != DownloadState.disposed &&
        !active.demanded &&
        _recordPathMatchesSession(initial, active)) {
      // Hold _resetting through the logical-row removal, reference check, and
      // physical delete. A plain resetIfIdle() releases that boundary before
      // the next await and permits a new demand to race this deletion.
      final removed = await active.resetIfIdleAndRun<bool>(
        removeCacheRecord: false,
        operation: () => removeBindingAndPhysical(sessionWasReset: true),
      );
      return removed ?? false;
    }
    return removeBindingAndPhysical(sessionWasReset: false);
  }

  bool _recordPathMatchesSession(CacheRec record, DownloadSession session) =>
      record.path == session.artifact.partialPath ||
      record.path == session.artifact.finalPath;

  Future<void> _forgetIndexedBinding(
    DownloadId id, {
    required CacheRec record,
  }) async {
    final current = await _index.get(id.key);
    if (current == null || !_sameIndexedRecord(record, current)) return;
    await _index.remove(id.key);
  }

  Future<void> _deleteArtifactSidecar(String path) async {
    final parsed = parseSafRecordPath(path);
    if (parsed != null) {
      if (safTreeIo == null || safTreeUri != parsed.treeUri) return;
      await safTreeIo!.delete('${parsed.relativePath}.meta');
      return;
    }
    final metadata = File('$path.meta');
    if (await metadata.exists()) await metadata.delete();
  }

  bool _sameIndexedRecord(CacheRec first, CacheRec second) =>
      first.id == second.id &&
      first.state == second.state &&
      first.path == second.path &&
      first.bytes == second.bytes &&
      first.checksum.trim().toLowerCase() ==
          second.checksum.trim().toLowerCase() &&
      first.createdUs == second.createdUs &&
      first.touchedUs == second.touchedUs &&
      first.pinned == second.pinned &&
      first.checksumAlgorithm.trim().toLowerCase() ==
          second.checksumAlgorithm.trim().toLowerCase() &&
      first.effectiveArtifactId == second.effectiveArtifactId &&
      first.storageRootId == second.storageRootId;

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async {
    _requireOpen();
    final records = await _index.list();
    return ArtifactCacheUsage(
      bytes: records.fold<int>(0, (sum, record) => sum + record.bytes),
      entries: records.length,
    );
  }

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    _requireOpen();
    final before = await _index.totalBytes();
    final report = await _cacheOps.trim(
      CacheLimits(maxBytes: maxBytes, targetBytes: targetBytes),
    );
    return ArtifactCacheReport(
      beforeBytes: before,
      releasedBytes: report.releasedBytes,
      remainingBytes: report.remainingBytes,
      evictedEntries: report.evicted,
      skippedBusy: report.skippedBusy,
    );
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    _requireOpen();
    final before = await _index.totalBytes();
    final report = await _cacheOps.clear();
    return ArtifactCacheReport(
      beforeBytes: before,
      releasedBytes: report.releasedBytes,
      remainingBytes: report.remainingBytes,
      evictedEntries: report.evicted,
      skippedBusy: report.skippedBusy,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Public methods reject new work after _closed, but operations that were
    // already admitted can still enqueue a per-id/path tail while their
    // current callback is awaiting I/O. Drain every tail before disposing the
    // registry/index; otherwise a late cache mutation can touch a closed
    // SQLite handle or close an artifact while its body reader is still open.
    while (true) {
      final pending = <Future<void>>{
        ..._artifactWrites.values,
        ..._artifactMutationTails.values,
        ..._structuredWriteTails.values,
        ..._placementWrites.values,
      };
      if (pending.isEmpty) break;
      for (final operation in pending) {
        try {
          await operation;
        } on Object {
          // The caller that initiated the operation already owns its failure;
          // close still has to establish the lifecycle barrier.
        }
      }
    }
    await _registry.dispose();
    await _index.close();
  }

  void _requireOpen() {
    if (_closed) throw StateError('persistent download artifact store is closed');
  }
}

abstract interface class ChapterDownloadTransferRuntimeProvider {
  PersistentDownloadArtifactStore get artifactStore;
  ArtifactCacheManager get artifactCacheManager;
  CompositionDownloadTransferRuntime get transferRuntime;
}

final class PersistentDownloadComposition
    implements ChapterDownloadTransferRuntimeProvider {
  PersistentDownloadComposition._({
    required this.artifactStore,
    required this.artifactCacheManager,
    required this.transferRuntime,
    required this.chapterDownloads,
  });

  static Future<PersistentDownloadComposition> open(
    String root, {
    String? directory,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    String Function()? userAgentProvider,
    NetLane? transferNet,
    ArtifactCacheReadScheduler? localReadScheduler,
    SafTreeIo? safTreeIo,
    String? safTreeUri,
    Duration pageStallTimeout =
        PersistentChapterDownloadService.defaultPageStallTimeout,
    TraceSink? traceSink,
  }) async {
    final authorities = await _openPersistentDownloadAuthorities(
      root,
      directory: directory,
      layoutResolver: layoutResolver,
      transferNet: transferNet,
      localReadScheduler: localReadScheduler,
      safTreeIo: safTreeIo,
      safTreeUri: safTreeUri,
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

typedef _PersistentDownloadAuthorities = ({
  PersistentDownloadArtifactStore artifactStore,
  ArtifactCacheManager artifactCacheManager,
  CompositionDownloadTransferRuntime transferRuntime,
});

Future<_PersistentDownloadAuthorities> _openPersistentDownloadAuthorities(
  String root, {
  String? directory,
  CacheLayout? Function(DownloadId id)? layoutResolver,
  NetLane? transferNet,
  ArtifactCacheReadScheduler? localReadScheduler,
  SafTreeIo? safTreeIo,
  String? safTreeUri,
  Duration stallTimeout = PersistentChapterDownloadService.defaultPageStallTimeout,
  TraceSink? traceSink,
}) async {
  final store = await PersistentDownloadArtifactStore.open(
    root,
    directory: directory,
    layoutResolver: layoutResolver,
    safMirror: safTreeIo,
    safTreeUri: safTreeUri,
    traceSink: traceSink,
  );
  if (safTreeUri != null) {
    store.setSafTree(safTreeUri);
  }
  final cache = ArtifactCacheManager(backend: store);
  final runtime = CompositionDownloadTransferRuntime(
    artifactCacheManager: cache,
    partialDownloadStore: store,
    net: transferNet ??
        NetLane(
          maxActive: 5,
          reservedHighPrioritySlots: 1,
          highPriorityThreshold: 1000,
          preemptionThreshold: 40,
        ),
    localReadScheduler: localReadScheduler,
    readStallTimeout: stallTimeout,
  );
  return (
    artifactStore: store,
    artifactCacheManager: cache,
    transferRuntime: runtime,
  );
}

final class PersistentChapterDownloadService
    implements
        ManagedChapterDownloadService,
        ChapterDownloadManagementProjectionReader,
        ArtifactCacheMaintenance,
        ArtifactCacheBackend,
        PartialDownloadStore,
        ConfigurableChapterResourceAccess,
        ChapterDownloadTransferRuntimeProvider {
  /// Stall window for one page's promotion. Re-armed by every non-terminal
  /// progress snapshot, so only a fully silent transfer trips it; total
  /// give-up budget = window × (1 + [_maxPromotionStallReclaims]).
  static const Duration defaultPageStallTimeout = Duration(seconds: 6);

  /// Bounded number of session resets used to reclaim a stalled physical run
  /// before the stall failure fails the chapter command.
  static const int _maxPromotionStallReclaims = 2;

  /// Number of page transfers a chapter command may have admitted at once.
  /// This is deliberately no larger than the per-bucket NetLane limit and
  /// keeps decoded/encoded ingress bounded while still avoiding page-wide
  /// serialization.
  static const int _chapterNetworkWindow = 2;

  static const String _promotionStallMessage =
      'physical transfer promotion stalled: no progress within the stall window';

  PersistentChapterDownloadService._({
    required this.artifactStore,
    required this.artifactCacheManager,
    required this.transferRuntime,
    required IoTransport transport,
    required bool ownsTransferComposition,
    Duration pageStallTimeout = defaultPageStallTimeout,
    TraceSink? traceSink,
  })  : _transport = transport,
        _ownsTransferComposition = ownsTransferComposition,
        _pageStallTimeout = pageStallTimeout,
        _traceSink = traceSink ?? const NoopTraceSink();

  static Future<PersistentChapterDownloadService> open(
    String root, {
    String? directory,
    CacheLayout? Function(DownloadId id)? layoutResolver,
    String Function()? userAgentProvider,
    NetLane? transferNet,
    ArtifactCacheReadScheduler? localReadScheduler,
    SafTreeIo? safTreeIo,
    String? safTreeUri,
    Duration pageStallTimeout = defaultPageStallTimeout,
    TraceSink? traceSink,
  }) async {
    final authorities = await _openPersistentDownloadAuthorities(
      root,
      directory: directory,
      layoutResolver: layoutResolver,
      transferNet: transferNet,
      localReadScheduler: localReadScheduler,
      safTreeIo: safTreeIo,
      safTreeUri: safTreeUri,
      stallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
    return PersistentChapterDownloadService._(
      artifactStore: authorities.artifactStore,
      artifactCacheManager: authorities.artifactCacheManager,
      transferRuntime: authorities.transferRuntime,
      transport: IoTransport(
        http: HttpTransport(userAgentProvider: userAgentProvider),
      ),
      ownsTransferComposition: true,
      pageStallTimeout: pageStallTimeout,
      traceSink: traceSink,
    );
  }

  @override
  final PersistentDownloadArtifactStore artifactStore;
  @override
  final ArtifactCacheManager artifactCacheManager;
  @override
  final CompositionDownloadTransferRuntime transferRuntime;
  final IoTransport _transport;
  final bool _ownsTransferComposition;
  final Duration _pageStallTimeout;
  final TraceSink _traceSink;
  final MonoClock _traceClock = const SystemClock();
  bool _ownedTransferCompositionDisposed = false;
  ChapterResourceAccess? _resourceAccess;
  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Map<String, DownloadTransferConsumer> _commandConsumers =
      <String, DownloadTransferConsumer>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _deletedIdentities = <String>{};
  final Map<String, ChapterDownloadPhase> _terminalPhases =
      <String, ChapterDownloadPhase>{};

  /// Identities whose run has admitted at least one page task to the
  /// transfer layer — the snapshot `started` flag the UI's starting/started
  /// control split is built on.
  final Set<String> _startedRuns = <String>{};

  /// Disk-scan results per chapter identity — scanned once per task
  /// lifetime, invalidated by delete. Downloaded pages get index records
  /// immediately, so only external file changes can stale this cache.
  final Map<String, Map<int, ({String path, int bytes})>> _existingPagesCache =
      <String, Map<int, ({String path, int bytes})>>{};
  bool _closed = false;

  /// Sessions are materialized only for exact pages touched after startup.
  /// This metric is intentionally read-only so diagnostics can verify that
  /// opening a large offline library does not eagerly restore every artifact.
  int get materializedSessionCount => artifactStore.materializedSessionCount;

  @override
  Stream<ChapterDownloadSnapshot> get changes => _changes.stream;

  @override
  void setChapterResourceAccess(ChapterResourceAccess? access) {
    _requireOpen();
    _resourceAccess = access;
  }

  @override
  void updateVersionBaselines(List<ComicVersionRelation> relations) {
    artifactStore.updateVersionBaselines(relations);
  }

  @override
  void updateCacheVersionRelations(List<ComicVersionRelation> relations) {
    artifactStore.updateCacheVersionRelations(relations);
  }

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
    _requireOpen();
    final owner = '$sourceId\u0000$comicId';
    _recordCommandTrace(
      owner,
      'claim-comic-directory',
      <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'comicTitle': comicTitle,
        'directoryName': directoryName,
        'mode': mode.name,
        'observedOwnerKey': observedOwnerKey,
      },
    );
    if (mode == DownloadPlacementMode.overwrite &&
        observedOwnerKey != null &&
        observedOwnerKey.contains('\u0000')) {
      final parts = observedOwnerKey.split('\u0000');
      if (parts.length == 2) {
        final displacedComicPrefix = '${parts[0]}\u0000${parts[1]}\u0000';
        for (final identity in List.of(_tokens.keys)) {
          if (identity.startsWith(displacedComicPrefix)) {
            _cancelled.add(identity);
            _tokens[identity]?.cancel();
          }
        }
      }
    }
    return artifactStore.claimStructuredComicDirectory(
      sourceId: sourceId,
      comicId: comicId,
      comicTitle: comicTitle,
      directoryName: directoryName,
      mode: mode,
      observedOwnerKey: observedOwnerKey,
      pageOrder: pageOrder,
    );
  }

  @override
  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) async {
    _requireOpen();
    final placement = await artifactStore.getDownloadPlacement(
      sourceId: sourceId,
      comicId: comicId,
    );
    final owner = '$sourceId\u0000$comicId';
    _recordCommandTrace(
      owner,
      'get-download-placement',
      <String, Object?>{
        'sourceId': sourceId,
        'comicId': comicId,
        'directoryName': placement?.relativeDirectory,
        'mode': placement?.mode.name,
      },
    );
    return placement;
  }

  @override
  Future<void> retry(ImportedLibraryEntry entry) async {
    _requireOpen();
    await cancel(entry);
    return download(entry);
  }

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
      _tokens.remove(identity);
      _startedRuns.remove(identity);
      _deletedIdentities.remove(identity);
    });
  }

  /// Lifecycle-edge diagnostic trail only — never progress ticks.
  void _recordCommandTrace(
    String identityHash,
    String stage,
    Map<String, Object?> payload,
  ) {
    try {
      _traceSink.record(
        traceEvent(
          clock: _traceClock,
          sessionId: 'chapter-command',
          kind: TraceEventKind.downloadState,
          identityHash: identityHash,
          payload: <String, Object?>{'stage': stage, ...payload},
        ),
      );
    } on Object {
      // Tracing must never fail the download.
    }
  }

  Future<void> _runDownload(ImportedLibraryEntry entry) async {
    final identity = _identity(entry);
    _deletedIdentities.remove(identity);
    final token = CancelToken();
    _tokens[identity] = token;
    _cancelled.remove(identity);
    _terminalPhases.remove(identity);
    _startedRuns.remove(identity);
    _recordCommandTrace(identity, 'chapter-run-start', <String, Object?>{
      'pages': entry.chapter.pages.length,
      'comicId': entry.chapter.comicId,
      'chapterId': entry.chapter.chapterId,
    });
    final indexedRecords = await artifactStore.indexedRecords();
    await _emitInspection(
      entry,
      phase: ChapterDownloadPhase.downloading,
      indexedRecords: indexedRecords,
    );
    final progress = _ChapterProgressPublisher(
      () => _emitInspection(
        entry,
        phase: ChapterDownloadPhase.downloading,
        indexedRecords: indexedRecords,
      ),
    );
    final manifest = entry.chapter.toManifest();
    token.throwIfCancelled();
    final structuredComicDirectory =
        await artifactStore.resolveStructuredComicDirectory(entry);
    _recordCommandTrace(identity, 'structured-directory-resolved', <String, Object?>{
      'comicTitle': entry.chapter.comicTitle,
      'structuredComicDirectory': structuredComicDirectory,
    });
    await artifactStore.verifyStructuredDestinationOwner(
      entry,
      comicDirectoryName: structuredComicDirectory,
    );
    token.throwIfCancelled();
    final transports = <Uri, Transport>{
      for (final page in manifest.pages) page.uri: _transportForPage(manifest, page),
    };
    final consumer = transferRuntime.attachConsumer(
      scopeId: 'chapter-command:$identity',
      transportFor: (uri) => transports[uri] ?? _transport,
      consumerTraceSink: _traceSink,
      retry: const RetryPolicy(),
      downloadBucketFor: (_) => 'chapter:${manifest.sourceId}',
      downloadBucketLimitFor: (_) => 2,
    );
    _commandConsumers[identity] = consumer;
    var revision = 0;
    try {
      final existingChapters = await artifactStore.downloadedChapterIds(
        sourceId: manifest.sourceId,
        comicId: entry.chapter.comicId,
      );
      final hasOtherDownloadedChapters = existingChapters.isNotEmpty &&
          !existingChapters.contains(entry.chapter.chapterId);
      final isHighConfidenceMultiChapter = entry.chapter.sequence > 1 ||
          hasOtherDownloadedChapters ||
          existingChapters.length > 1;
      final isSingleChapter = !isHighConfidenceMultiChapter;

      if (existingChapters.isNotEmpty &&
          !existingChapters.contains(entry.chapter.chapterId)) {
        for (final prevId in existingChapters) {
          await artifactStore.migrateSingleChapterToSubdirectory(
            sourceId: manifest.sourceId,
            comicId: entry.chapter.comicId,
            comicTitle: entry.chapter.comicTitle,
            previousChapterId: prevId,
            previousChapterTitle: '第 1 话',
            comicDirectoryName: structuredComicDirectory,
            rootLayout: manifest.pages.isEmpty
                ? null
                : artifactStore.layoutFor(
                    _downloadId(manifest, manifest.pages.first),
                  ),
          );
        }
      }

      token.throwIfCancelled();
      final chapterDirectoryName = isSingleChapter
          ? null
          : await artifactStore.resolveStructuredChapterDirectory(
              entry,
              comicDirectoryName: structuredComicDirectory,
            );

      final baselinePredecessors =
          artifactStore._downloadBaselinePredecessorMappings(entry);

      var placement = await artifactStore.resolveDownloadPlacement(entry);
      placement = await artifactStore.freezeExportPageOrder(
        entry,
        placement,
        isSingleChapter: isSingleChapter,
      );
      final exportOrdinals = await artifactStore.ensureExportPageOrdinals(
        entry,
        placement,
      );
      await artifactStore.writeComicFolderManifest(
        entry,
        comicDirectoryName: structuredComicDirectory,
        chapterDirectoryName: chapterDirectoryName,
      );

      final pendingPages = <Future<void>>[];
      final pendingDemands = <DownloadId, TransferDemand>{};
      Future<void> drainPendingPages() async {
        if (pendingPages.isEmpty) return;
        Object? failure;
        StackTrace? failureStack;
        try {
          await Future.wait<void>(
            List<Future<void>>.of(pendingPages),
            eagerError: false,
          );
        } on Object catch (error, stackTrace) {
          failure = error;
          failureStack = stackTrace;
        } finally {
          pendingPages.clear();
          pendingDemands.clear();
          consumer.replaceDemands(
            identity,
            ++revision,
            const <DownloadId, TransferDemand>{},
          );
        }
        if (failure != null) {
          Error.throwWithStackTrace(failure, failureStack!);
        }
      }

      for (var pageIndex = 0; pageIndex < manifest.pages.length; pageIndex++) {
        final page = manifest.pages[pageIndex];
        final logicalPageId = entry.chapter.pages[pageIndex].stablePageId;
        final targetPageNumber = exportOrdinals[logicalPageId];
        if (targetPageNumber == null) {
          throw Failure(
            code: ErrorCode.invalidState,
            message: 'missing frozen export ordinal for $logicalPageId',
          );
        }
        token.throwIfCancelled();
        final id = _downloadId(manifest, page);
        var record = indexedRecords[id.key];
        if (record != null &&
            record.state == CacheState.ready &&
            (record.bytes <= 0 ||
                record.checksum.trim().isEmpty ||
                record.checksumAlgorithm.trim().toLowerCase() != 'crc32')) {
          await artifactStore.forgetUnverifiedReadyRecord(record);
          indexedRecords.remove(id.key);
          record = null;
        }
        var recordReady = record != null &&
            artifactStore._isVerifiedReadyRecord(record);

        if (recordReady) {
          final active = transferRuntime.registry.find(id);
          final isBusy = active != null &&
              (active.activeRun || active.hasWriter);
          final isAlreadyStructured = record.pinned &&
              (!record.path.contains('/final/') ||
                  parseSafRecordPath(record.path) != null);
          if (!isBusy && isAlreadyStructured) {
            // A successful structured commit already proved the destination
            // bytes before pinning the record. Do not reopen and rehash every
            // downloaded page merely to retry the chapter command; normal
            // page reads still perform authoritative content verification.
            continue;
          }
          if (!isBusy) {
            final durable = await artifactStore.openArtifactStream(id);
            if (durable == null) {
              indexedRecords.remove(id.key);
              record = null;
              recordReady = false;
            } else {
              await artifactStore.mirrorPromotedToSafIfConfigured(
                id,
                entry: entry,
                pageIndex: targetPageNumber,
                isSingleChapter: isSingleChapter,
                comicDirectoryName: structuredComicDirectory,
                chapterDirectoryName: chapterDirectoryName,
              );
              final rec = await artifactStore._index.get(id.key);
              if (rec != null) {
                indexedRecords[id.key] = rec;
              }
              progress.schedule();
              continue;
            }
          }
        }

        // Classify from the one run-start index snapshot. Network pages are
        // then admitted as a bounded batch, so the scheduler can overlap
        // transfers without allowing an unbounded chapter fan-out.
        CacheRec? siblingRecord;
        for (final candidate in indexedRecords.values) {
          if (!artifactStore._isVerifiedReadyRecord(candidate)) {
            continue;
          }
          if (candidate.id.content.sourceId == entry.chapter.sourceId &&
              candidate.id.content.comicId == entry.chapter.comicId &&
              candidate.id.content.chapterId == entry.chapter.chapterId &&
              candidate.id.content.pageId == page.pageId &&
              candidate.id.key != id.key) {
            siblingRecord = candidate;
            break;
          }
        }
        if (siblingRecord == null) {
          for (final baseline in baselinePredecessors) {
            final mapping = baseline.mapping;
            if (mapping.successorOffset < 0 ||
                pageIndex < mapping.successorOffset) {
              continue;
            }
            final predecessorIndex = pageIndex - mapping.successorOffset;
            if (predecessorIndex >= mapping.predecessorPageCount) continue;
            for (final candidate in indexedRecords.values) {
              if (!artifactStore._isVerifiedReadyRecord(candidate)) continue;
              if (candidate.id.content.sourceId == entry.chapter.sourceId &&
                  candidate.id.content.comicId ==
                      baseline.relation.predecessorComicId &&
                  candidate.id.content.chapterId ==
                      mapping.predecessorChapterId) {
                final parsedNum = parsePageIndexFromFileName(candidate.path);
                if (parsedNum == null) continue;
                final matchesReverse =
                    parsedNum == (mapping.predecessorPageCount - predecessorIndex);
                final matchesNormal = parsedNum == (predecessorIndex + 1);
                if (matchesReverse || matchesNormal) {
                  siblingRecord = candidate;
                  break;
                }
              }
            }
            if (siblingRecord != null) break;
          }
        }
        if (siblingRecord == null) {
          final pageVerifiedIds = verifiedPageIdentities(page).toSet();
          if (pageVerifiedIds.isNotEmpty) {
            for (final candidate in indexedRecords.values) {
              if (!artifactStore._isVerifiedReadyRecord(candidate) ||
                  candidate.id.key == id.key) {
                continue;
              }
              if (verifiedRecordIdentities(candidate).any(pageVerifiedIds.contains)) {
                siblingRecord = candidate;
                break;
              }
            }
          }
        }
        if (siblingRecord != null) {
          final destPath =
              await artifactStore.materializeSiblingToDestinationIfSeparate(
            siblingRecord: siblingRecord,
            entry: entry,
            pageNumber: targetPageNumber,
            isSingleChapter: isSingleChapter,
            comicDirectoryName: structuredComicDirectory,
            chapterDirectoryName: chapterDirectoryName,
          );
          final adopted = await artifactStore.adoptExistingPageRecord(
            id: id,
            path: destPath,
            bytes: siblingRecord.bytes,
            checksum: siblingRecord.checksum,
            artifactId: destPath == siblingRecord.path
                ? siblingRecord.artifactId
                : null,
            storageRootId: artifactStore.storageRootIdFor(entry),
          );
          indexedRecords[id.key] = adopted;
          _recordCommandTrace(identity, 'page-adopt-sibling', <String, Object?>{
            'page': pageIndex,
            'targetPageNumber': targetPageNumber,
            'bytes': siblingRecord.bytes,
            if (siblingRecord.id.content.comicId != entry.chapter.comicId)
              'baselineComicId': siblingRecord.id.content.comicId,
          });
          progress.schedule();
          continue;
        }
        _startedRuns.add(identity);
        _recordCommandTrace(identity, 'page-network', <String, Object?>{
          'page': pageIndex,
          'targetPageNumber': targetPageNumber,
        });
        final expectedChecksum =
            page.checksumAlgorithm?.toLowerCase() == 'crc32'
                ? page.checksum
                : null;
        pendingDemands[id] = TransferDemand(
          priority: 120,
          reason: 'chapter-download-command',
          expectedChecksum: expectedChecksum,
          completionIntent: TransferCompletionIntent.required,
        );
        consumer.replaceDemands(
          identity,
          ++revision,
          Map<DownloadId, TransferDemand>.of(pendingDemands),
        );
        // Acquire the physical session only after the claim has passed through
        // the composition resolver. Creating an exact session first would
        // permanently defeat verified transfer-key aliasing for this command.
        final session = transferRuntime.registry.get(id);
        if (session.state == DownloadState.failed) {
          await session.reset();
        }
        consumer.refreshScheduling();
        pendingPages.add(
          _completeNetworkPage(
            entry: entry,
            id: id,
            pageIndex: targetPageNumber - 1,
            isSingleChapter: isSingleChapter,
            comicDirectoryName: structuredComicDirectory,
            chapterDirectoryName: chapterDirectoryName,
            session: session,
            token: token,
            progress: progress,
            consumer: consumer,
          ).then((rec) {
            if (rec != null) {
              indexedRecords[id.key] = rec;
            }
          }),
        );
        if (pendingPages.length >= _chapterNetworkWindow) {
          await drainPendingPages();
        }
      }
      await drainPendingPages();
      consumer.replaceDemands(
        identity,
        ++revision,
        const <DownloadId, TransferDemand>{},
      );
      await progress.flush();
      progress.close();
      token.throwIfCancelled();
      if (_deletedIdentities.contains(identity)) return;
      await artifactStore.pinChapterRecords(
        sourceId: manifest.sourceId,
        comicId: entry.chapter.comicId,
        chapterId: entry.chapter.chapterId,
      );
      token.throwIfCancelled();
      if (_deletedIdentities.contains(identity)) return;
      await artifactStore.writeComicFolderManifest(
        entry,
        comicDirectoryName: structuredComicDirectory,
        chapterDirectoryName: chapterDirectoryName,
      );
      if (_deletedIdentities.contains(identity)) return;
      _terminalPhases[identity] = ChapterDownloadPhase.complete;
      _startedRuns.add(identity);
      _recordCommandTrace(identity, 'chapter-run-complete', const <String, Object?>{});
      await _emitInspection(entry, phase: ChapterDownloadPhase.complete);
    } on Failure catch (error) {
      await progress.flush();
      progress.close();
      if (_deletedIdentities.contains(identity)) return;
      if (error.code == ErrorCode.cancelled || token.cancelled) {
        _cancelled.add(identity);
        _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
        _recordCommandTrace(identity, 'chapter-run-cancelled', const <String, Object?>{});
        await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
        return;
      }
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      _recordCommandTrace(identity, 'chapter-run-failed', <String, Object?>{
        'error': error.toString(),
      });
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    } on Object catch (error) {
      await progress.flush();
      progress.close();
      if (_deletedIdentities.contains(identity)) return;
      if (token.cancelled) {
        _cancelled.add(identity);
        _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
        _recordCommandTrace(identity, 'chapter-run-cancelled', const <String, Object?>{});
        await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
        return;
      }
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      _recordCommandTrace(identity, 'chapter-run-failed', <String, Object?>{
        'error': error.toString(),
      });
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    } finally {
      progress.close();
      if (identical(_commandConsumers[identity], consumer)) {
        _commandConsumers.remove(identity);
      }
      await consumer.dispose();
    }
  }

  Future<CacheRec?> _completeNetworkPage({
    required ImportedLibraryEntry entry,
    required DownloadId id,
    required int pageIndex,
    required bool isSingleChapter,
    required String comicDirectoryName,
    required String? chapterDirectoryName,
    required DownloadSession session,
    required CancelToken token,
    required _ChapterProgressPublisher progress,
    required DownloadTransferConsumer consumer,
  }) async {
    final snapshot = await _waitForPagePromotion(
      session,
      token: token,
      progress: progress,
      consumer: consumer,
    );
    token.throwIfCancelled();
    if (snapshot.state != DownloadState.promoted) {
      final failure = snapshot.failure;
      if (failure is Failure) throw failure;
      throw Failure(
        code: ErrorCode.network,
        message: 'physical transfer did not promote ${id.key}',
      );
    }
    await transferRuntime.persistPromoted(id);
    await artifactStore.mirrorPromotedToSafIfConfigured(
      id,
      entry: entry,
      pageIndex: pageIndex + 1,
      isSingleChapter: isSingleChapter,
      comicDirectoryName: comicDirectoryName,
      chapterDirectoryName: chapterDirectoryName,
    );
    if (await artifactStore.openArtifactStream(id) == null) {
      throw StateError(
        'chapter command completed physical transfer without durable artifact: '
        '${id.key}',
      );
    }
    return artifactStore._index.get(id.key);
  }

  /// Waits for [session] to reach a terminal state. The stall timer is
  /// re-armed by every non-terminal snapshot; a fully silent window resets
  /// the session so a fresh task can be admitted, and after
  /// [_maxPromotionStallReclaims] reclaims the failure propagates.
  Future<DownloadSnapshot> _waitForPagePromotion(
    DownloadSession session, {
    required CancelToken token,
    required _ChapterProgressPublisher progress,
    required DownloadTransferConsumer consumer,
  }) async {
    void record(String stage, Map<String, Object?> payload) =>
        _recordCommandTrace(session.id.key, stage, payload);

    var round = Completer<DownloadSnapshot>();
    Timer? stallTimer;
    void armStall() {
      final completer = round;
      final baseline = session.snapshot;
      stallTimer?.cancel();
      stallTimer = Timer(_pageStallTimeout, () {
        if (completer.isCompleted) {
          return;
        }
        final current = session.snapshot;
        final transportProgressed =
            current.networkAttemptSequence == baseline.networkAttemptSequence &&
                current.networkCursorLength > baseline.networkCursorLength;
        final artifactProgressed =
            current.committedLength > baseline.committedLength;
        final lowerAttemptOwnsStall = current.activeRun &&
            transferRuntime.readStallTimeout > Duration.zero &&
            (current.state == DownloadState.queued ||
                current.networkAttemptActive);
        if (transportProgressed ||
            artifactProgressed ||
            lowerAttemptOwnsStall) {
          armStall();
          return;
        }
        completer.completeError(const Failure(
          code: ErrorCode.network,
          message: _promotionStallMessage,
        ));
      });
    }

    void listener(DownloadSnapshot snapshot) {
      progress.schedule();
      final completer = round;
      if (completer.isCompleted) {
        return;
      }
      if (snapshot.state == DownloadState.promoted ||
          snapshot.state == DownloadState.failed ||
          snapshot.state == DownloadState.disposed) {
        completer.complete(snapshot);
        return;
      }
      armStall();
    }

    session.addSnapshotListener(listener);
    if (session.snapshot.state == DownloadState.promoted ||
        session.snapshot.state == DownloadState.failed ||
        session.snapshot.state == DownloadState.disposed) {
      if (!round.isCompleted) {
        round.complete(session.snapshot);
      }
    } else {
      armStall();
    }
    try {
      var stallReclaims = 0;
      while (true) {
        try {
          return await Future.any<DownloadSnapshot>(<Future<DownloadSnapshot>>[
            round.future,
            token.whenCancelled.then<DownloadSnapshot>((_) =>
                throw const Failure(
                  code: ErrorCode.cancelled,
                  message: 'download cancelled',
                )),
          ]);
        } on Failure catch (error) {
          if (error.code != ErrorCode.network ||
              error.message != _promotionStallMessage ||
              ++stallReclaims > _maxPromotionStallReclaims) {
            if (error.message == _promotionStallMessage) {
              record('page-promotion-stall-gave-up', <String, Object?>{
                'reclaims': stallReclaims - 1,
                'state': session.state.name,
                'committedLength': session.committedLength,
                'activeRun': session.activeRun,
                'hasWriter': session.hasWriter,
              });
            }
            rethrow;
          }
          // Reset drops the stale writer/epoch so a fresh task can be
          // admitted after the stall.
          record('page-promotion-stall-reclaim', <String, Object?>{
            'attempt': stallReclaims,
            'state': session.state.name,
            'committedLength': session.committedLength,
            'activeRun': session.activeRun,
            'hasWriter': session.hasWriter,
          });
          await session.reset();
          consumer.refreshScheduling();
          round = Completer<DownloadSnapshot>();
          record('page-promotion-reclaim-rewait', <String, Object?>{
            'attempt': stallReclaims,
            'state': session.state.name,
          });
          if (session.snapshot.state == DownloadState.promoted ||
              session.snapshot.state == DownloadState.failed ||
              session.snapshot.state == DownloadState.disposed) {
            if (!round.isCompleted) {
              round.complete(session.snapshot);
            }
          } else {
            armStall();
          }
        }
      }
    } finally {
      stallTimer?.cancel();
      session.removeSnapshotListener(listener);
    }
  }

  Transport _transportForPage(ChapterManifest manifest, PageAsset page) {
    if (!_isSourceOwnedResource(manifest.sourceId, page.uri)) {
      return _transport;
    }
    final access = _resourceAccess;
    final stream = access?.openResponse;
    final controlledStream = access?.openControlledResponse;
    final loader = access?.loadBytes;
    final controlledLoader = access?.loadBytesControlled;
    if (stream == null &&
        controlledStream == null &&
        loader == null &&
        controlledLoader == null) {
      return _transport;
    }
    return LoaderTransport(<Uri, LoaderTransportSource>{
      page.uri: LoaderTransportSource(
        revision: '${manifest.chapter.sourceRevision}:${page.pageId}',
        openResponse: stream == null
            ? null
            : ({ByteRange? range, Validators? validators}) => stream(
                  manifest.sourceId,
                  page.uri,
                  range: range,
                  validators: validators,
                ),
        openControlledResponse: controlledStream == null
            ? null
            : ({ByteRange? range, Validators? validators, TaskControl? control}) =>
                controlledStream(
                  manifest.sourceId,
                  page.uri,
                  range: range,
                  validators: validators,
                  control: control,
                ),
        loadBytesControlled: controlledLoader == null
            ? null
            : ({TaskControl? control}) => controlledLoader(
                  manifest.sourceId,
                  page.uri,
                  control: control,
                ),
        loadBytes: loader == null
            ? null
            : () => loader(manifest.sourceId, page.uri),
      ),
    });
  }

  bool _isSourceOwnedResource(String sourceId, Uri uri) {
    if (sourceId.startsWith('mihon:') || sourceId.startsWith('venera:')) {
      return true;
    }
    return uri.scheme == 'mihon' || uri.scheme == 'venera-resource';
  }


  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    _requireOpen();
    // Exact chapter prefix: source+comic+chapter, every revision.
    final chapterPrefix = _chapterDownloadPrefix(entry);
    final matchedTokens = <String>[];
    for (final identity in List.of(_tokens.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      matchedTokens.add(identity);
      _cancelled.add(identity);
      _tokens[identity]?.cancel();
    }
    for (final identity in List.of(_commandConsumers.keys)) {
      if (!identity.startsWith(chapterPrefix)) continue;
      final consumer = _commandConsumers.remove(identity);
      await consumer?.dispose();
    }
    final activeRuns = List.of(
      _runs.keys.where((id) => id.startsWith(chapterPrefix)),
    );
    _recordCommandTrace(
      _identity(entry),
      'chapter-run-cancel-requested',
      <String, Object?>{
        'matchedRuns': activeRuns.length,
        'matchedTokens': matchedTokens.length,
        'requestedComicId': entry.chapter.comicId,
        'requestedChapterId': entry.chapter.chapterId,
      },
    );
    if (activeRuns.isEmpty) {
      _terminalPhases[_identity(entry)] = ChapterDownloadPhase.cancelled;
      await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
      return;
    }
    for (final active in activeRuns) {
      try {
        // The run observes the token at its next checkpoint; a bounded wait
        // keeps a run stuck in pre-network IO from hanging the stop tap —
        // the run still exits and emits its cancelled state on its own.
        await _runs[active]?.timeout(const Duration(seconds: 10));
      } on Object {
        // The authoritative state is emitted by the task itself.
      }
    }
  }

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {
    _requireOpen();
    final wasSingleChapter = await _isSingleChapterFor(entry);
    final chapterPrefix = _chapterDownloadPrefix(entry);
    _deletedIdentities.addAll(
      _runs.keys.where((id) => id.startsWith(chapterPrefix)),
    );
    final identity = _identity(entry);
    _deletedIdentities.add(identity);
    await cancel(entry);
    final manifest = entry.chapter.toManifest();
    for (final page in manifest.pages) {
      final id = _downloadId(manifest, page);
      var session = transferRuntime.registry.find(id);
      if (session != null && (session.activeRun || session.hasWriter)) {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          session = transferRuntime.registry.find(id);
          if (session == null || (!session.activeRun && !session.hasWriter)) {
            break;
          }
        }
      }
      if (session != null && (session.activeRun || session.hasWriter)) {
        try {
          await session.reset();
        } on Object {
          // ignore error if reset cannot complete cleanly
        }
      }
      // The persistent artifact owner decides whether the physical session
      // can be retired after its path/reference check. Retire only the
      // transfer-runtime object afterwards; its blind registry eviction would
      // otherwise delete a shared final path the durable owner deliberately
      // kept.
      await artifactStore.evict(id);
      // The backend eviction removes durable bytes, but the composition cache
      // owns an independent hot copy. Invalidate it as part of the same exact
      // logical delete so a subsequent Reader lookup cannot resurrect the
      // deleted page from memory.
      await artifactCacheManager.invalidate(id);
      await transferRuntime.retirePhysicalAfterDelete(id);
    }
    // The export cleanup is a DeletePlan operation: it consults the index
    // after removing this exact logical version and never deletes a shared
    // structured path still referenced by another revision.
    try {
      final comicDirName =
          await artifactStore.resolveStructuredComicDirectory(entry);
      final chapterDirName = wasSingleChapter
          ? null
          : await artifactStore.resolveStructuredChapterDirectory(
              entry,
              comicDirectoryName: comicDirName,
            );
      await artifactStore.cleanupStructuredChapterExport(
        entry,
        comicDirectoryName: comicDirName,
        chapterDirectoryName: chapterDirName,
        isSingleChapter: wasSingleChapter,
      );
      await artifactStore.removeChapterFromComicFolderManifest(
        entry,
        comicDirectoryName: comicDirName,
      );
      final remainingAll = (await artifactStore.indexedRecords()).values.any(
        (record) {
          final content = record.id.content;
          return content.sourceId == entry.chapter.sourceId &&
              content.comicId == entry.chapter.comicId &&
              record.bytes > 0 &&
              (record.state == CacheState.ready ||
                  record.state == CacheState.partial);
        },
      );
      if (!remainingAll) {
        await artifactStore.removeStructuredPlacement(
          sourceId: entry.chapter.sourceId,
          comicId: entry.chapter.comicId,
        );
      }
    } catch (_) {
      // Non-critical directory cleanup error
    }
    _startedRuns.removeWhere((id) => id.startsWith(chapterPrefix) || id == identity);
    _cancelled.removeWhere((id) => id.startsWith(chapterPrefix) || id == identity);
    _terminalPhases.removeWhere((k, _) => k.startsWith(chapterPrefix) || k == identity);
    _existingPagesCache.removeWhere((k, _) => k.startsWith(chapterPrefix) || k == identity);
    _emit(ChapterDownloadSnapshot.idle(entry));
  }

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) {
    _requireOpen();
    return _buildSnapshot(entry);
  }

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
    final liveRunStarted = liveRunIdentities.any(_startedRuns.contains);
    final records = await artifactStore.indexedRecords();
    var indexedReadyPages = 0;
    var urlMatchedPages = 0;
    for (final record in records.values) {
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      if (content.sourceId != query.sourceId) {
        final pluginId = query.pluginId;
        if (pluginId == null || !content.sourceId.startsWith('$pluginId:')) {
          continue;
        }
      }
      if (query.comicId != null && content.comicId != query.comicId) {
        continue;
      }
      if (query.chapterId != null &&
          content.chapterId != query.chapterId) {
        continue;
      }
      indexedReadyPages++;
      if (query.url != null &&
          record.id.canonicalUri.toString() == query.url) {
        urlMatchedPages++;
      }
    }
    return DownloadExistenceReport(
      liveRunIdentities: List.unmodifiable(liveRunIdentities),
      liveRunStarted: liveRunStarted,
      indexedReadyPages: indexedReadyPages,
      urlMatchedPages: urlMatchedPages,
    );
  }

  @override
  Future<ChapterFileStateReport> inspectChapterFileState(
    ImportedLibraryEntry entry,
  ) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    final records = await artifactStore.indexedRecords();
    var indexReadyPages = 0;
    for (final page in manifest.pages) {
      final record = records[_downloadId(manifest, page).key];
      if (record != null &&
          artifactStore._isVerifiedReadyRecord(record)) {
        indexReadyPages++;
      }
    }
    final comicDirectoryName =
        await artifactStore.resolveStructuredComicDirectory(entry);
    final disk = _existingPagesCache[_identity(entry)] ??
        await artifactStore.scanExistingPages(
          comicTitle: entry.chapter.comicTitle,
          chapterTitle: entry.chapter.displayName,
          sequence: entry.chapter.sequence,
          isSingleChapter: await _isSingleChapterFor(entry),
          comicDirectoryName: comicDirectoryName,
          layoutId: manifest.pages.isEmpty
              ? null
              : _downloadId(manifest, manifest.pages.first),
        );
    var diskBytes = 0;
    for (final page in disk.values) {
      diskBytes += page.bytes;
    }
    return ChapterFileStateReport(
      manifestPages: manifest.pages.length,
      indexReadyPages: indexReadyPages,
      diskPages: disk.length,
      diskBytes: diskBytes,
    );
  }

  Future<bool> _isSingleChapterFor(ImportedLibraryEntry entry) async {
    final existingChapters = await artifactStore.downloadedChapterIds(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
    );
    final hasOtherDownloadedChapters = existingChapters.isNotEmpty &&
        !existingChapters.contains(entry.chapter.chapterId);
    return !(entry.chapter.sequence > 1 ||
        hasOtherDownloadedChapters ||
        existingChapters.length > 1);
  }

  @override
  Future<List<ImportedLibraryEntry>> discoverOrphanedEntries(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    _requireOpen();
    final records = await artifactStore.indexedRecords();
    return _discoverOrphanedEntriesFromRecords(knownEntries, records);
  }

  @override
  Future<List<ChapterDownloadSnapshot>> inspectMany(
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    _requireOpen();
    final requested = entries.toList(growable: false);
    if (requested.isEmpty) {
      return const <ChapterDownloadSnapshot>[];
    }
    return _inspectManyFromRecords(
      requested,
      await artifactStore.indexedRecords(),
    );
  }

  @override
  Future<ChapterDownloadManagementProjection> inspectDownloadManagement(
    Iterable<ImportedLibraryEntry> knownEntries,
  ) async {
    _requireOpen();
    final known = knownEntries.toList(growable: false);
    final indexed = await artifactStore.indexedRecords();
    final orphaned = _discoverOrphanedEntriesFromRecords(
      known,
      indexed,
      compactEntriesAreKnown: true,
    );
    return ChapterDownloadManagementProjection(
      orphanedEntries: orphaned,
      snapshots: await _inspectManyFromRecords(
        <ImportedLibraryEntry>[...known, ...orphaned],
        indexed,
      ),
    );
  }

  List<ImportedLibraryEntry> _discoverOrphanedEntriesFromRecords(
    Iterable<ImportedLibraryEntry> knownEntries,
    Map<String, CacheRec> records, {
    bool compactEntriesAreKnown = false,
  }) {
    final knownChapterKeys = <String>{
      for (final entry in knownEntries)
        if (compactEntriesAreKnown || !_isCompactProjectionEntry(entry))
          '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000${entry.chapter.chapterId}\u0000${entry.chapter.sourceRevision}',
    };
    final orphanedGroups = <String, List<CacheRec>>{};
    for (final record in records.values) {
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      final chapterKey =
          '${content.sourceId}\u0000${content.comicId}\u0000${content.chapterId}\u0000${record.id.sourceRevision}';
      if (knownChapterKeys.contains(chapterKey)) {
        continue;
      }
      orphanedGroups
          .putIfAbsent(chapterKey, () => <CacheRec>[])
          .add(record);
    }

    final orphaned = <ImportedLibraryEntry>[];
    for (final group in orphanedGroups.values) {
      if (group.isEmpty) {
        continue;
      }
      final firstRecord = group.first;
      final content = firstRecord.id.content;
      final revision = firstRecord.id.sourceRevision;
      orphaned.add(
        ImportedLibraryEntry(
          chapter: ImportedChapterRecord(
            directoryId: 'orphaned:${content.comicId}:$revision',
            displayName: content.chapterId,
            sourceId: content.sourceId,
            comicId: content.comicId,
            comicTitle: content.comicId,
            chapterId: content.chapterId,
            sourceRevision: revision,
            pages: <ImportedPageRecord>[
              for (final record in group)
                ImportedPageRecord(
                  displayName: record.id.content.pageId,
                  sourceId: record.id.canonicalUri.toString(),
                  pageId: record.id.content.pageId,
                  contentKindHint: ContentKindHint.unknown,
                  byteLength: record.bytes,
                ),
            ],
          ),
        ),
      );
    }
    return List<ImportedLibraryEntry>.unmodifiable(orphaned);
  }

  Future<List<ChapterDownloadSnapshot>> _inspectManyFromRecords(
    Iterable<ImportedLibraryEntry> entries,
    Map<String, CacheRec> indexed,
  ) async {
    final recordsByChapter = <String, List<CacheRec>>{};
    final recordsByVerifiedIdentity = <String, CacheRec>{};
    for (final record in indexed.values) {
      if (!artifactStore._isVerifiedReadyRecord(record)) {
        continue;
      }
      final content = record.id.content;
      final chapterKey =
          '${content.sourceId}\u0000${content.comicId}\u0000${content.chapterId}\u0000${record.id.sourceRevision}';
      recordsByChapter
          .putIfAbsent(chapterKey, () => <CacheRec>[])
          .add(record);
      for (final verifiedId in verifiedRecordIdentities(record)) {
        recordsByVerifiedIdentity.putIfAbsent(verifiedId, () => record);
      }
    }
    final snapshots = <ChapterDownloadSnapshot>[];
    for (final entry in entries) {
      final chapterKey =
          '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000${entry.chapter.chapterId}\u0000${entry.chapter.sourceRevision}';
      snapshots.add(
        await _buildSnapshot(
          entry,
          indexedRecords: indexed,
          chapterRecords: recordsByChapter[chapterKey],
          recordsByVerifiedIdentity: recordsByVerifiedIdentity,
        ),
      );
    }
    return List<ChapterDownloadSnapshot>.unmodifiable(snapshots);
  }

  Future<ChapterDownloadSnapshot> _buildSnapshot(
    ImportedLibraryEntry entry, {
    ChapterDownloadPhase? phase,
    String? failure,
    Map<String, CacheRec>? indexedRecords,
    Iterable<CacheRec>? chapterRecords,
    Map<String, CacheRec>? recordsByVerifiedIdentity,
  }) async {
    final manifest = entry.chapter.toManifest();
    final records = indexedRecords ??
        (chapterRecords == null
            ? await artifactStore.indexedRecords()
            : const <String, CacheRec>{});
    // The per-page alias must be deterministic (last-wins used to flip
    // progress between superseded revisions): entry-revision records win,
    // then the newest createdUs.
    CacheRec preferRecord(CacheRec current, CacheRec candidate) {
      final candidateMatchesRevision =
          candidate.id.sourceRevision == entry.chapter.sourceRevision;
      final currentMatchesRevision =
          current.id.sourceRevision == entry.chapter.sourceRevision;
      if (candidateMatchesRevision != currentMatchesRevision) {
        return candidateMatchesRevision ? candidate : current;
      }
      return candidate.createdUs > current.createdUs ? candidate : current;
    }

    final recordsByPage = <String, CacheRec>{};
    final resolvedVerifiedIdentities =
        recordsByVerifiedIdentity ?? <String, CacheRec>{};
    final targetRecords = chapterRecords ?? records.values;
    for (final rec in targetRecords) {
      if (!artifactStore._isVerifiedReadyRecord(rec)) {
        continue;
      }
      if (rec.id.content.sourceId == entry.chapter.sourceId &&
          rec.id.content.comicId == entry.chapter.comicId &&
          rec.id.content.chapterId == entry.chapter.chapterId) {
        final pageId = rec.id.content.pageId;
        final existing = recordsByPage[pageId];
        recordsByPage[pageId] =
            existing == null ? rec : preferRecord(existing, rec);
      }
      if (recordsByVerifiedIdentity == null) {
        for (final verifiedId in verifiedRecordIdentities(rec)) {
          resolvedVerifiedIdentities.putIfAbsent(verifiedId, () => rec);
        }
      }
    }
    var exactCompletedPages = 0;
    var completedPages = 0;
    var pinnedPages = 0;
    var receivedBytes = 0;
    var totalBytes = 0;
    var knowsTotalBytes = true;
    var pageProgressUnits = 0.0;
    String? sessionFailure;
    var hasFailedSession = false;
    final effectivePages = _isCompactProjectionEntry(entry)
        ? _effectiveCompactPages(
            manifest.pages,
            recordsByPage.values,
            chapterId: entry.chapter.chapterId,
          )
        : manifest.pages;
    for (var index = 0; index < effectivePages.length; index++) {
      final page = effectivePages[index];
      final id = _downloadId(manifest, page);
      final sessionSnapshot = transferRuntime.registry.find(id)?.snapshot;
      final snapshot = sessionSnapshot != null &&
              (sessionSnapshot.state != DownloadState.idle ||
                  sessionSnapshot.activeRun ||
                  sessionSnapshot.hasWriter)
          ? sessionSnapshot
          : null;
      CacheRec? verifiedEquivalent;
      for (final pageVerifiedId in verifiedPageIdentities(page)) {
        verifiedEquivalent = resolvedVerifiedIdentities[pageVerifiedId];
        if (verifiedEquivalent != null) break;
      }
      final exactIndexed = records[id.key] ?? recordsByPage[page.pageId];
      final indexed = exactIndexed ?? verifiedEquivalent;
      final committedLength = snapshot?.committedLength ?? indexed?.bytes ?? 0;
      receivedBytes += committedLength;
      final exactPromoted = snapshot?.state == DownloadState.promoted ||
          (exactIndexed != null &&
              artifactStore._isVerifiedReadyRecord(exactIndexed));
      final promoted = exactPromoted ||
          (indexed != null && artifactStore._isVerifiedReadyRecord(indexed));
      final isExactPinned = exactIndexed != null &&
          artifactStore._isVerifiedReadyRecord(exactIndexed) &&
          (exactIndexed.pinned ||
              (!exactIndexed.path.contains('/final/') ||
                  parseSafRecordPath(exactIndexed.path) != null));
      if (isExactPinned) {
        pinnedPages++;
      }
      if (exactPromoted) {
        exactCompletedPages++;
      }
      if (promoted) {
        completedPages++;
        pageProgressUnits += 1;
      }
      final knownLength = snapshot?.totalLength ??
          (index < entry.chapter.pages.length
              ? entry.chapter.pages[index].byteLength
              : null) ??
          indexed?.bytes;
      if (knownLength == null) {
        knowsTotalBytes = false;
      } else {
        totalBytes += knownLength;
        if (!promoted && knownLength > 0 && committedLength > 0) {
          pageProgressUnits +=
              (committedLength / knownLength).clamp(0, 1).toDouble();
        }
      }
      if (snapshot?.state == DownloadState.failed) {
        hasFailedSession = true;
        sessionFailure ??= snapshot?.failure?.toString();
      }
    }
    final identity = _identity(entry);
    final hasActiveRun = _runs.containsKey(identity) ||
        _runs.keys.any((k) => k.startsWith(_chapterDownloadPrefix(entry)));
    final runStarted = _startedRuns.contains(identity) ||
        _startedRunsKeysAnyPrefix(entry);
    final isExplicitlyTracked =
        pinnedPages > 0 || runStarted || _terminalPhases.containsKey(identity);
    final resolvedPhase = phase ??
        _terminalPhases[identity] ??
        (hasActiveRun
            ? ChapterDownloadPhase.downloading
            : (exactCompletedPages == effectivePages.length &&
                    effectivePages.isNotEmpty &&
                    !_deletedIdentities.contains(identity) &&
                    isExplicitlyTracked)
                ? ChapterDownloadPhase.complete
                : _cancelled.contains(identity)
                    ? ChapterDownloadPhase.cancelled
                    : hasFailedSession
                        ? ChapterDownloadPhase.failed
                        : ChapterDownloadPhase.idle);
    return ChapterDownloadSnapshot(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      title: entry.chapter.displayName,
      completedPages: completedPages,
      totalPages: effectivePages.length,
      receivedBytes: receivedBytes,
      pinnedPages: pinnedPages,
      totalBytes: knowsTotalBytes ? totalBytes : null,
      pageProgressUnits: pageProgressUnits,
      phase: resolvedPhase,
      failure: failure ?? sessionFailure,
      started: runStarted,
    );
  }

  /// Any revision of this chapter already admitted a page task.
  bool _startedRunsKeysAnyPrefix(ImportedLibraryEntry entry) {
    final prefix = _chapterDownloadPrefix(entry);
    return _startedRuns.any((identity) => identity.startsWith(prefix));
  }

  Future<void> _emitInspection(
    ImportedLibraryEntry entry, {
    ChapterDownloadPhase? phase,
    String? failure,
    Map<String, CacheRec>? indexedRecords,
  }) async {
    if (_deletedIdentities.contains(_identity(entry))) return;
    _emit(
      await _buildSnapshot(
        entry,
        phase: phase,
        failure: failure,
        indexedRecords: indexedRecords,
      ),
    );
  }

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
  }) =>
      artifactStore.inspectComicConflicts(
        sourceId: sourceId,
        sourceDisplayName: sourceDisplayName,
        comicId: comicId,
        comicTitle: comicTitle,
        knownPredecessorComicIds: knownPredecessorComicIds,
        knownSuccessorComicIds: knownSuccessorComicIds,
      );

  @override
  Future<Set<int>> readyPageIndices(ImportedLibraryEntry entry) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    final total = manifest.pages.length;
    if (total == 0) return const <int>{};
    final indexedRecords = await artifactStore.indexedRecords();
    final ready = <int>{};
    final missing = <int>[];
    for (var i = 0; i < total; i++) {
      final page = manifest.pages[i];
      final id = _downloadId(manifest, page);
      final rec = indexedRecords[id.key];
      if (rec != null && artifactStore._isVerifiedReadyRecord(rec)) {
        ready.add(i);
      } else {
        missing.add(i);
      }
    }
    if (missing.isEmpty) {
      return ready;
    }
    final recordsByPage = <String, CacheRec>{};
    final recordsByVerifiedIdentity = <String, CacheRec>{};
    for (final rec in indexedRecords.values) {
      if (!artifactStore._isVerifiedReadyRecord(rec)) continue;
      if (rec.id.content.sourceId == entry.chapter.sourceId &&
          rec.id.content.comicId == entry.chapter.comicId &&
          rec.id.content.chapterId == entry.chapter.chapterId) {
        recordsByPage[rec.id.content.pageId] = rec;
      }
      for (final verifiedId in verifiedRecordIdentities(rec)) {
        recordsByVerifiedIdentity.putIfAbsent(verifiedId, () => rec);
      }
    }
    for (final i in missing) {
      final page = manifest.pages[i];
      final id = _downloadId(manifest, page);
      final exactIndexed = indexedRecords[id.key] ?? recordsByPage[page.pageId];
      if (exactIndexed != null && artifactStore._isVerifiedReadyRecord(exactIndexed)) {
        ready.add(i);
        continue;
      }
      for (final pageVerifiedId in verifiedPageIdentities(page)) {
        final verifiedEquivalent = recordsByVerifiedIdentity[pageVerifiedId];
        if (verifiedEquivalent != null && artifactStore._isVerifiedReadyRecord(verifiedEquivalent)) {
          ready.add(i);
          break;
        }
      }
    }
    return ready;
  }

  @override
  Future<bool> hasReadyPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    if (pageIndex < 0 || pageIndex >= manifest.pages.length) return false;
    final page = manifest.pages[pageIndex];
    final id = _downloadId(manifest, page);
    final direct = await artifactStore.openArtifactStream(id);
    return direct != null;
  }

  @override
  Future<Uint8List> readPage(
    ImportedLibraryEntry entry,
    int pageIndex,
  ) async {
    _requireOpen();
    final manifest = entry.chapter.toManifest();
    if (pageIndex < 0 || pageIndex >= manifest.pages.length) {
      throw RangeError.index(pageIndex, manifest.pages, 'pageIndex');
    }
    final page = manifest.pages[pageIndex];
    final id = _downloadId(manifest, page);
    return artifactStore.readPromoted(id);
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) =>
      artifactStore.openArtifactStream(id);

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) =>
      artifactStore.openPartialDownload(id);

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) =>
      artifactStore.storePartialDownload(id: id, entry: entry);

  @override
  Future<void> invalidatePartialDownload(DownloadId id) =>
      artifactStore.invalidatePartialDownload(id);

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) =>
      artifactStore.storePromotedArtifact(id: id, bytes: bytes);

  @override
  Future<void> invalidateArtifact(DownloadId id) =>
      artifactStore.invalidateArtifact(id);

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() =>
      artifactStore.inspectArtifacts();

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    final report = await artifactStore.trimArtifacts(
      maxBytes: maxBytes,
      targetBytes: targetBytes,
    );
    _forgetDerivedCompletePhases();
    return report;
  }

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    final report = await artifactStore.clearArtifacts();
    _forgetDerivedCompletePhases();
    return report;
  }

  void _forgetDerivedCompletePhases() {
    _terminalPhases.removeWhere(
      (_, phase) => phase == ChapterDownloadPhase.complete,
    );
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _resourceAccess = null;
      for (final token in _tokens.values) {
        token.cancel();
      }
      for (final run in _runs.values.toList(growable: false)) {
        try {
          await run;
        } on Object {
          // Closing discards task failures after cancellation.
        }
      }
      for (final consumer
          in _commandConsumers.values.toList(growable: false)) {
        await consumer.dispose();
      }
      _commandConsumers.clear();
      _deletedIdentities.clear();
      _transport.close(force: true);
      await _changes.close();
    }
    if (_ownsTransferComposition && !_ownedTransferCompositionDisposed) {
      if (transferRuntime.hasConsumers) {
        throw StateError(
          'cannot close owned download composition with active transfer consumers',
        );
      }
      await transferRuntime.dispose();
      await artifactStore.close();
      _ownedTransferCompositionDisposed = true;
    }
  }

  void _emit(ChapterDownloadSnapshot snapshot) {
    if (!_changes.isClosed) {
      _changes.add(snapshot);
    }
  }

  DownloadId _downloadId(ChapterManifest manifest, PageAsset page) =>
      DownloadId(
        content: ContentId(
          sourceId: manifest.sourceId,
          comicId: manifest.comicId,
          chapterId: page.chapterId,
          pageId: page.pageId,
        ),
        sourceRevision: manifest.chapter.sourceRevision,
        canonicalUri: page.uri,
      );

  void _requireOpen() {
    if (_closed) {
      throw StateError('chapter download service is closed');
    }
  }
}

final class _IndexedPartialResumeState {
  const _IndexedPartialResumeState({
    this.validators = const Validators(),
    this.totalLength,
    this.explicitDifferentOwner = false,
  });

  final Validators validators;
  final int? totalLength;
  final bool explicitDifferentOwner;
}

Future<_IndexedPartialResumeState> _readIndexedPartialResumeState(
  String partialPath,
  DownloadId id,
) async {
  final file = File('$partialPath.meta');
  if (!await file.exists()) return const _IndexedPartialResumeState();
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on Object {
    // Resume metadata is acceleration evidence, not authority over the
    // committed media prefix. Preserve indexed bytes and fall back to
    // validatorless continuation when metadata is malformed.
    return const _IndexedPartialResumeState();
  }
  if (decoded is! Map) return const _IndexedPartialResumeState();
  final meta = Map<String, Object?>.from(decoded);

  var matches = meta['downloadKey'] == id.key;
  var explicitDifferentOwner = false;
  final key = meta['downloadKey'];
  if (key is String && key != id.key) {
    explicitDifferentOwner = true;
  }
  final rawDownload = meta['download'];
  if (!matches && rawDownload is Map) {
    try {
      final metadataId = DownloadId.fromJson(
        Map<String, Object?>.from(rawDownload),
      );
      matches = metadataId == id;
      explicitDifferentOwner = metadataId != id;
    } on Object {
      // Malformed identity metadata is not proof that the indexed media bytes
      // belong to another object. Keep the prefix but drop resume knowledge.
    }
  }
  if (explicitDifferentOwner) {
    return const _IndexedPartialResumeState(explicitDifferentOwner: true);
  }
  if (!matches) return const _IndexedPartialResumeState();

  final rawValidators = meta['validators'];
  final rawLength = meta['totalLength'];
  if (rawValidators is! Map || (rawLength != null && rawLength is! int)) {
    return const _IndexedPartialResumeState();
  }
  try {
    var validators = Validators.fromJson(
      Map<String, Object?>.from(rawValidators),
    );
    final rawValidatorRequestUri = meta['validatorRequestUri'];
    final validatorRequestUri = rawValidatorRequestUri is String
        ? Uri.tryParse(rawValidatorRequestUri)
        : null;
    if (validators.canResume && validatorRequestUri != id.canonicalUri) {
      validators = const Validators();
    }
    return _IndexedPartialResumeState(
      validators: validators,
      totalLength: rawLength as int?,
    );
  } on Object {
    return const _IndexedPartialResumeState();
  }
}

Stream<List<int>> _readIndexedChunks(
  String path, {
  required int length,
  required int start,
  int? endExclusive,
}) async* {
  if (start < 0 || (endExclusive != null && endExclusive < start)) {
    throw RangeError('invalid indexed artifact range $start..$endExclusive');
  }
  if (start >= length) return;
  final limit = (endExclusive ?? length).clamp(start, length).toInt();
  final reader = await File(path).open();
  try {
    await reader.setPosition(start);
    var offset = start;
    while (offset < limit) {
      final readSize = (limit - offset)
          .clamp(1, promotedArtifactReadChunkBytes)
          .toInt();
      final chunk = await reader.read(readSize);
      if (chunk.isEmpty) break;
      offset += chunk.length;
      yield chunk;
    }
    if (offset != limit) {
      throw StateError('indexed artifact ended at $offset/$limit');
    }
  } finally {
    await reader.close();
  }
}

String _chapterDownloadPrefix(ImportedLibraryEntry entry) =>
    '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000'
    '${entry.chapter.chapterId}\u0000';

String chapterDownloadIdentity(
  String sourceId,
  String comicId,
  String chapterId,
  String sourceRevision,
) =>
    '$sourceId\u0000$comicId\u0000$chapterId\u0000$sourceRevision';

String _identity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.comicId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

bool _isCompactProjectionEntry(ImportedLibraryEntry entry) =>
    entry.chapter.pages.isNotEmpty &&
    entry.chapter.pages.every(
      (page) => page.sourceId.startsWith('zic-home-snapshot-page:'),
    );

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
final class _ChapterProgressPublisher {
  _ChapterProgressPublisher(this._publish);

  static const Duration _minimumInterval = Duration(milliseconds: 80);

  final Future<void> Function() _publish;
  Future<void>? _active;
  bool _dirty = false;
  bool _force = false;
  bool _closed = false;
  DateTime? _lastPublished;

  void schedule() {
    if (_closed) return;
    _dirty = true;
    _active ??= _drain();
  }

  Future<void> flush() async {
    if (_closed) return;
    _force = true;
    schedule();
    while (true) {
      final active = _active;
      if (active == null) return;
      await active;
    }
  }

  Future<void> _drain() async {
    try {
      while (_dirty && !_closed) {
        _dirty = false;
        final force = _force;
        _force = false;
        final last = _lastPublished;
        if (!force && last != null) {
          final remaining = _minimumInterval - DateTime.now().difference(last);
          if (remaining > Duration.zero) {
            await Future<void>.delayed(remaining);
          }
        }
        if (_closed) return;
        try {
          await _publish();
        } on Object {
          // Progress is a projection. A transient index/UI read must not fail
          // the authoritative DownloadSession writer or discard valid bytes.
        }
        _lastPublished = DateTime.now();
      }
    } finally {
      _active = null;
      if (_dirty && !_closed) {
        schedule();
      }
    }
  }

  void close() {
    _closed = true;
    _dirty = false;
  }
}
