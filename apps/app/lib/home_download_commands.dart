import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';

import 'home_library_session.dart';

typedef HomeChapterRefresh = Future<ImportedLibraryEntry> Function(
  ImportedLibraryEntry entry, {
  required bool forceSourceRefresh,
});

typedef HomeStaleChapterRefresh = Future<ImportedLibraryEntry?> Function(
  ImportedLibraryEntry entry,
);

final class HomeWholeComicDownloadStart {
  const HomeWholeComicDownloadStart({
    required this.sourceId,
    required this.comicId,
  });

  final String sourceId;
  final String comicId;
}

/// Owns Home's service-side download command sequencing.
///
/// The current service generation is always read through [HomeLibrarySession];
/// this object never caches chapter-download or whole-comic service instances.
/// UI conflict dialogs, navigation and completion badges stay in DemoHome.
final class HomeDownloadCommands {
  HomeDownloadCommands({
    required this.session,
    required this.ensureDurableServices,
    required this.ensurePlatformEnvironment,
    required this.requiresSourceLocatorRefresh,
    required this.refreshRemoteEntry,
    required this.refreshStaleChapter,
  });

  final HomeLibrarySession session;
  final Future<void> Function() ensureDurableServices;
  final Future<void> Function() ensurePlatformEnvironment;
  final bool Function(ImportedChapterRecord chapter)
      requiresSourceLocatorRefresh;
  final HomeChapterRefresh refreshRemoteEntry;
  final HomeStaleChapterRefresh refreshStaleChapter;

  Future<ChapterDownloadSnapshot> inspectChapter(
    ImportedLibraryEntry entry,
  ) async {
    final hydrated = await session.hydrateEntry(entry);
    return session.chapterDownloads.inspect(hydrated);
  }

  Future<List<ChapterDownloadSnapshot>> inspectChapters(
    Iterable<ImportedLibraryEntry> entries,
  ) =>
      session.chapterDownloads.inspectMany(entries);

  Future<DownloadExistenceReport> probeExisting({
    required String sourceId,
    required String comicId,
    String? chapterId,
  }) =>
      session.chapterDownloads.probeExistingDownloads(
        DownloadExistenceQuery(
          sourceId: sourceId,
          comicId: comicId,
          chapterId: chapterId,
        ),
      );

  Future<ComicConflictReport> inspectComicConflicts({
    required String sourceId,
    String? sourceDisplayName,
    required String comicId,
    required String comicTitle,
    Set<String>? knownPredecessorComicIds,
    Set<String>? knownSuccessorComicIds,
  }) async {
    final downloads = session.chapterDownloads;
    final probe = await downloads.probeExistingDownloads(
      DownloadExistenceQuery(sourceId: sourceId, comicId: comicId),
    );
    if (probe.liveRun) {
      return const ComicConflictReport(
        candidates: <ComicFolderCandidate>[],
        hasDirectExactMatch: false,
        hasTitleConflicts: false,
        recommendedDirectoryName: '',
      );
    }
    return downloads.inspectComicConflicts(
      sourceId: sourceId,
      sourceDisplayName: sourceDisplayName,
      comicId: comicId,
      comicTitle: comicTitle,
      knownPredecessorComicIds: knownPredecessorComicIds,
      knownSuccessorComicIds: knownSuccessorComicIds,
    );
  }

  Future<void> claimComicDirectory({
    required String sourceId,
    required String comicId,
    required String directoryName,
    String? comicTitle,
    DownloadPlacementMode mode = DownloadPlacementMode.createNew,
    String? observedOwnerKey,
  }) =>
      session.chapterDownloads.claimComicDirectory(
        sourceId: sourceId,
        comicId: comicId,
        directoryName: directoryName,
        comicTitle: comicTitle,
        mode: mode,
        observedOwnerKey: observedOwnerKey,
      );

  Future<DownloadPlacement?> getDownloadPlacement({
    required String sourceId,
    required String comicId,
  }) =>
      session.chapterDownloads.getDownloadPlacement(
        sourceId: sourceId,
        comicId: comicId,
      );

  WholeComicQueueJobSnapshot? cachedWholeComicJob(
    String sourceId,
    String comicId,
  ) {
    for (final job in session.wholeComicQueueSnapshot.jobs) {
      if (job.sourceId == sourceId && job.comicId == comicId) {
        return job;
      }
    }
    return null;
  }

  Future<WholeComicQueueJobSnapshot?> wholeComicJob(
    String sourceId,
    String comicId,
  ) async {
    await session.wholeComicDownloads.ready;
    return cachedWholeComicJob(sourceId, comicId);
  }

  Future<void> toggleWholeComicPause(
    String sourceId,
    String comicId,
  ) async {
    final job = cachedWholeComicJob(sourceId, comicId);
    if (job == null) return;
    if (job.phase == WholeComicQueuePhase.running) {
      await session.wholeComicDownloads.pause(job.jobId);
      return;
    }
    if (job.phase == WholeComicQueuePhase.paused) {
      await session.wholeComicDownloads.resume(job.jobId);
    }
  }

  Future<void> stopChapter(ImportedLibraryEntry entry) async {
    await session.chapterDownloads.cancel(entry);
    await session.refreshDownloadSnapshots(session.entries);
  }

  Future<ChapterDownloadSnapshot> downloadChapter(
    ImportedLibraryEntry entry,
  ) async {
    await ensureDurableServices();
    final hydrated = await session.hydrateEntry(entry);
    var current = requiresSourceLocatorRefresh(hydrated.chapter)
        ? await refreshRemoteEntry(
            hydrated,
            forceSourceRefresh: true,
          )
        : hydrated;
    final downloads = session.chapterDownloads;
    try {
      // Conflict confirmation may claim placement asynchronously. Read it back
      // before artifact writes so a failed cross-process CAS is observed here.
      await downloads.getDownloadPlacement(
        sourceId: current.chapter.sourceId,
        comicId: current.chapter.comicId,
      );
      await downloads.download(current);
    } on Object catch (error) {
      final message = error.toString();
      if (message.contains('must use a runtime token') ||
          message.contains('token expired')) {
        final refreshed = await refreshStaleChapter(current);
        if (refreshed == null) rethrow;
        current = refreshed;
        await session.chapterDownloads.retry(current);
      } else {
        rethrow;
      }
    }
    final snapshot = await session.chapterDownloads.inspect(current);
    session.acceptDownloadSnapshot(snapshot);
    return snapshot;
  }

  Future<void> deleteChapter(
    ImportedLibraryEntry entry, {
    bool deleteFiles = false,
  }) async {
    final hydrated = await session.hydrateEntry(entry);
    if (deleteFiles) {
      await session.chapterDownloads.delete(hydrated);
    }
    await session.removeChapter(
      hydrated.chapter.sourceId,
      hydrated.chapter.chapterId,
    );
  }

  Future<HomeWholeComicDownloadStart> downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) async {
    await ensureDurableServices();
    final chapters = <ImportedLibraryEntry>[];
    for (final entry in entries) {
      final hydrated = await session.hydrateEntry(entry);
      chapters.add(
        requiresSourceLocatorRefresh(hydrated.chapter)
            ? await refreshRemoteEntry(
                hydrated,
                forceSourceRefresh: true,
              )
            : hydrated,
      );
    }
    if (chapters.isEmpty) {
      throw StateError('没有可下载的章节');
    }
    final first = chapters.first.chapter;
    final existingJob = cachedWholeComicJob(first.sourceId, first.comicId);
    if (existingJob != null &&
        (existingJob.phase == WholeComicQueuePhase.running ||
            existingJob.phase == WholeComicQueuePhase.queued ||
            existingJob.phase == WholeComicQueuePhase.paused ||
            existingJob.phase == WholeComicQueuePhase.waitingForPolicy)) {
      throw StateError('该漫画的整本下载任务已在队列中');
    }
    if (comicIdentity != comicLibraryIdentity(first.sourceId, first.comicId)) {
      throw StateError('整本下载身份与章节所有者不一致');
    }
    await ensurePlatformEnvironment();
    final placement = await session.chapterDownloads.getDownloadPlacement(
      sourceId: first.sourceId,
      comicId: first.comicId,
    );
    await session.wholeComicDownloads.enqueue(
      sourceId: first.sourceId,
      comicId: first.comicId,
      comicTitle: first.comicTitle,
      chapters: chapters,
      placementDirectory: placement?.relativeDirectory,
      placementMode: placement?.mode,
      observedOwnerKey: placement?.observedOwnerKey,
      pageOrder: placement?.pageOrder ?? ComicPageOrder.auto,
    );
    session.refreshWholeComicSnapshot();
    return HomeWholeComicDownloadStart(
      sourceId: first.sourceId,
      comicId: first.comicId,
    );
  }
}
