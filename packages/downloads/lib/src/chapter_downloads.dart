import 'dart:async';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

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
    this.totalBytes,
    this.failure,
  })  : assert(completedPages >= 0),
        assert(totalPages > 0),
        assert(completedPages <= totalPages),
        assert(receivedBytes >= 0),
        assert(totalBytes == null || totalBytes >= 0);

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
  final int? totalBytes;
  final ChapterDownloadPhase phase;
  final String? failure;

  String get identity => chapterDownloadIdentity(
        sourceId,
        chapterId,
        sourceRevision,
      );

  bool get isActive => phase == ChapterDownloadPhase.downloading;
  bool get isComplete => phase == ChapterDownloadPhase.complete;
  bool get hasDurableBytes => receivedBytes > 0 || isComplete;

  double get fraction {
    final byteTotal = totalBytes;
    if (byteTotal != null && byteTotal > 0) {
      return (receivedBytes / byteTotal).clamp(0, 1).toDouble();
    }
    return (completedPages / totalPages).clamp(0, 1).toDouble();
  }

  double get completedPageUnits {
    if (isComplete) {
      return totalPages.toDouble();
    }
    return (fraction * totalPages).clamp(0, totalPages).toDouble();
  }
}

abstract interface class ChapterDownloadService {
  Stream<ChapterDownloadSnapshot> get changes;

  Future<void> download(ImportedLibraryEntry entry);

  Future<void> retry(ImportedLibraryEntry entry);

  Future<void> cancel(ImportedLibraryEntry entry);

  Future<void> delete(ImportedLibraryEntry entry);

  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry);

  Future<bool> isDownloaded(ImportedLibraryEntry entry);

  Future<Uint8List> readPage(ImportedLibraryEntry entry, int pageIndex);

  Future<void> close();
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
    implements ChapterDownloadService, ArtifactCacheMaintenance {
  MemoryChapterDownloadService({required ChapterPageLoader pageLoader})
      : _pageLoader = pageLoader;

  final ChapterPageLoader _pageLoader;
  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final Map<String, List<Uint8List?>> _chapters =
      <String, List<Uint8List?>>{};
  final Map<String, ChapterDownloadSnapshot> _snapshots =
      <String, ChapterDownloadSnapshot>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Set<String> _cancelled = <String>{};
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
    _cancelled.remove(identity);
    final pages = _chapters.putIfAbsent(
      identity,
      () => List<Uint8List?>.filled(
        entry.chapter.pages.length,
        null,
        growable: false,
      ),
    );
    var completedPages = _storedPageCount(pages);
    var receivedBytes = _storedPageBytes(pages);
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
        totalBytes: _declaredTotalBytes(entry),
        phase: ChapterDownloadPhase.downloading,
      ),
    );
    try {
      for (var index = 0; index < entry.chapter.pages.length; index++) {
        if (pages[index] != null) {
          continue;
        }
        if (_cancelled.contains(identity)) {
          _emitCancelled(entry, completedPages, receivedBytes);
          return;
        }
        final bytes = Uint8List.fromList(await _pageLoader(entry, index));
        if (_cancelled.contains(identity)) {
          _emitCancelled(entry, completedPages, receivedBytes);
          return;
        }
        pages[index] = bytes;
        completedPages++;
        receivedBytes += bytes.length;
        if (completedPages < entry.chapter.pages.length) {
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
              totalBytes: _declaredTotalBytes(entry),
              phase: ChapterDownloadPhase.downloading,
            ),
          );
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
          totalBytes: _declaredTotalBytes(entry) ?? receivedBytes,
          phase: ChapterDownloadPhase.complete,
        ),
      );
    } on Object catch (error) {
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
        totalBytes: _declaredTotalBytes(entry),
        phase: ChapterDownloadPhase.cancelled,
      ),
    );
  }

  @override
  Future<void> retry(ImportedLibraryEntry entry) => download(entry);

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    _requireOpen();
    final identity = _identity(entry);
    _cancelled.add(identity);
    final active = _runs[identity];
    if (active != null) {
      try {
        await active;
      } on Object {
        // The task already published its authoritative failed/cancelled state.
      }
    }
    final current = _snapshots[identity];
    if (current != null && current.phase == ChapterDownloadPhase.downloading) {
      _emitCancelled(entry, current.completedPages, current.receivedBytes);
    }
  }

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {
    _requireOpen();
    await cancel(entry);
    final identity = _identity(entry);
    _chapters.remove(identity);
    _cancelled.remove(identity);
    _emit(ChapterDownloadSnapshot.idle(entry));
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
      totalBytes: _declaredTotalBytes(entry) ??
          (completedPages == entry.chapter.pages.length ? receivedBytes : null),
      phase: completedPages == entry.chapter.pages.length
          ? ChapterDownloadPhase.complete
          : ChapterDownloadPhase.idle,
    );
    _snapshots[identity] = snapshot;
    return snapshot;
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async =>
      (await inspect(entry)).isComplete;

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
  Future<ArtifactCacheUsage> inspectArtifacts() async {
    _requireOpen();
    return ArtifactCacheUsage(
      bytes: _memoryCacheBytes,
      entries: _chapters.values.fold<int>(
        0,
        (sum, pages) => sum + _storedPageCount(pages),
      ),
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
      if (_runs.containsKey(identity)) {
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
    return ArtifactCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes - remaining,
      remainingBytes: remaining,
      evictedEntries: evicted,
      skippedBusy: skippedBusy,
    );
  }

  int get _memoryCacheBytes => _chapters.values.fold<int>(
        0,
        (sum, pages) => sum + _storedPageBytes(pages),
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
    _snapshots.clear();
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

final class PersistentChapterDownloadService
    implements ChapterDownloadService, ArtifactCacheMaintenance {
  PersistentChapterDownloadService._({
    required DownloadRegistry registry,
    required SqliteIndex index,
    required IoTransport transport,
    required CacheOps cacheOps,
  })  : _registry = registry,
        _index = index,
        _transport = transport,
        _cacheOps = cacheOps;

  static Future<PersistentChapterDownloadService> open(String root) async {
    final layout = CacheLayout('$root/offline_chapters');
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final clock = SystemClock();
    final registry = DownloadRegistry(
      layout: layout,
      clock: clock,
      index: index,
    );
    await registry.restoreIndexed();
    return PersistentChapterDownloadService._(
      registry: registry,
      index: index,
      cacheOps: CacheOps(index: index, registry: registry, clock: clock),
      transport: IoTransport(
        http: HttpTransport(userAgent: 'zic/0.31.0'),
      ),
    );
  }

  final DownloadRegistry _registry;
  final SqliteIndex _index;
  final IoTransport _transport;
  final CacheOps _cacheOps;
  final StreamController<ChapterDownloadSnapshot> _changes =
      StreamController<ChapterDownloadSnapshot>.broadcast(sync: true);
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Map<String, Future<void>> _runs = <String, Future<void>>{};
  final Set<String> _cancelled = <String>{};
  final Map<String, ChapterDownloadPhase> _terminalPhases =
      <String, ChapterDownloadPhase>{};
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
      _tokens.remove(identity);
    });
  }

  Future<void> _runDownload(ImportedLibraryEntry entry) async {
    final identity = _identity(entry);
    final token = CancelToken();
    _tokens[identity] = token;
    _cancelled.remove(identity);
    _terminalPhases.remove(identity);
    await _emitInspection(entry, phase: ChapterDownloadPhase.downloading);
    try {
      final manifest = entry.chapter.toManifest();
      for (final page in manifest.pages) {
        token.throwIfCancelled();
        final session = _registry.get(_downloadId(manifest, page));
        await session.restore();
        if (session.state == DownloadState.promoted) {
          await _emitInspection(
            entry,
            phase: ChapterDownloadPhase.downloading,
          );
          continue;
        }
        void listener(DownloadSnapshot _) {
          unawaited(_emitInspection(entry));
        }

        session.addSnapshotListener(listener);
        try {
          await DownloadJob(transport: _transport, session: session).run(
            expectedChecksum: page.checksum,
            cancel: token,
          );
        } finally {
          session.removeSnapshotListener(listener);
        }
      }
      _terminalPhases[identity] = ChapterDownloadPhase.complete;
      await _emitInspection(entry, phase: ChapterDownloadPhase.complete);
    } on Failure catch (error) {
      if (error.code == ErrorCode.cancelled || token.cancelled) {
        _cancelled.add(identity);
        _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
        await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
        return;
      }
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    } on Object catch (error) {
      _terminalPhases[identity] = ChapterDownloadPhase.failed;
      await _emitInspection(
        entry,
        phase: ChapterDownloadPhase.failed,
        failure: error.toString(),
      );
      rethrow;
    }
  }

  @override
  Future<void> retry(ImportedLibraryEntry entry) => download(entry);

  @override
  Future<void> cancel(ImportedLibraryEntry entry) async {
    _requireOpen();
    final identity = _identity(entry);
    _cancelled.add(identity);
    _tokens[identity]?.cancel();
    final active = _runs[identity];
    if (active != null) {
      try {
        await active;
      } on Object {
        // The authoritative state is emitted by the task itself.
      }
    } else {
      _terminalPhases[identity] = ChapterDownloadPhase.cancelled;
      await _emitInspection(entry, phase: ChapterDownloadPhase.cancelled);
    }
  }

  @override
  Future<void> delete(ImportedLibraryEntry entry) async {
    _requireOpen();
    await cancel(entry);
    final manifest = entry.chapter.toManifest();
    for (final page in manifest.pages) {
      final id = _downloadId(manifest, page);
      final session = _registry.find(id);
      if (session != null && (session.activeRun || session.hasWriter)) {
        throw StateError('下载任务仍在写入，无法删除离线文件');
      }
      await _registry.evict(id);
    }
    final identity = _identity(entry);
    _cancelled.remove(identity);
    _terminalPhases.remove(identity);
    _emit(ChapterDownloadSnapshot.idle(entry));
  }

  @override
  Future<ChapterDownloadSnapshot> inspect(ImportedLibraryEntry entry) {
    _requireOpen();
    return _buildSnapshot(entry);
  }

  Future<ChapterDownloadSnapshot> _buildSnapshot(
    ImportedLibraryEntry entry, {
    ChapterDownloadPhase? phase,
    String? failure,
  }) async {
    final manifest = entry.chapter.toManifest();
    var completedPages = 0;
    var receivedBytes = 0;
    var totalBytes = 0;
    var knowsTotalBytes = true;
    String? sessionFailure;
    var hasFailedSession = false;
    for (var index = 0; index < manifest.pages.length; index++) {
      final page = manifest.pages[index];
      final session = _registry.get(_downloadId(manifest, page));
      if (!session.activeRun && !session.hasWriter) {
        await session.restore();
      }
      final snapshot = session.snapshot;
      receivedBytes += snapshot.committedLength;
      if (snapshot.state == DownloadState.promoted) {
        completedPages++;
      }
      final knownLength = snapshot.totalLength ??
          entry.chapter.pages[index].byteLength;
      if (knownLength == null) {
        knowsTotalBytes = false;
      } else {
        totalBytes += knownLength;
      }
      if (snapshot.state == DownloadState.failed) {
        hasFailedSession = true;
        sessionFailure ??= snapshot.failure?.toString();
      }
    }
    final identity = _identity(entry);
    final resolvedPhase = phase ??
        _terminalPhases[identity] ??
        (_runs.containsKey(identity)
            ? ChapterDownloadPhase.downloading
            : completedPages == manifest.pages.length
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
      totalPages: manifest.pages.length,
      receivedBytes: receivedBytes,
      totalBytes: knowsTotalBytes ? totalBytes : null,
      phase: resolvedPhase,
      failure: failure ?? sessionFailure,
    );
  }

  Future<void> _emitInspection(
    ImportedLibraryEntry entry, {
    ChapterDownloadPhase? phase,
    String? failure,
  }) async {
    _emit(
      await _buildSnapshot(
        entry,
        phase: phase,
        failure: failure,
      ),
    );
  }

  @override
  Future<bool> isDownloaded(ImportedLibraryEntry entry) async =>
      (await inspect(entry)).isComplete;

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
    final session = _registry.get(
      _downloadId(manifest, manifest.pages[pageIndex]),
    );
    await session.restore();
    if (session.state != DownloadState.promoted) {
      throw StateError('requested page is not downloaded');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in session.artifact.readChunks()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

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
    _forgetDerivedCompletePhases();
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
    _forgetDerivedCompletePhases();
    return ArtifactCacheReport(
      beforeBytes: before,
      releasedBytes: report.releasedBytes,
      remainingBytes: report.remainingBytes,
      evictedEntries: report.evicted,
      skippedBusy: report.skippedBusy,
    );
  }

  void _forgetDerivedCompletePhases() {
    _terminalPhases.removeWhere(
      (_, phase) => phase == ChapterDownloadPhase.complete,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
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
    await _registry.dispose();
    await _index.close();
    _transport.close(force: true);
    await _changes.close();
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

String chapterDownloadIdentity(
  String sourceId,
  String chapterId,
  String sourceRevision,
) =>
    '$sourceId\u0000$chapterId\u0000$sourceRevision';

String _identity(ImportedLibraryEntry entry) => chapterDownloadIdentity(
      entry.chapter.sourceId,
      entry.chapter.chapterId,
      entry.chapter.sourceRevision,
    );

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
