import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';

import 'home_library_session.dart';
import 'download_command_lifetimes.dart';

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
/// UI conflict dialogs, navigation and completion badges stay in HomeShell.
final class HomeDownloadCommands {
  HomeDownloadCommands({
    required this.session,
    required this.ensureDurableServices,
    required this.ensurePlatformEnvironment,
    required this.requiresSourceLocatorRefresh,
    required this.refreshRemoteEntry,
    required this.refreshStaleChapter,
    DownloadCommandLifetimes? commandLifetimes,
  }) : commandLifetimes = commandLifetimes ?? DownloadCommandLifetimes.instance;

  final HomeLibrarySession session;
  final Future<void> Function() ensureDurableServices;
  final Future<void> Function() ensurePlatformEnvironment;
  final bool Function(ImportedChapterRecord chapter)
      requiresSourceLocatorRefresh;
  final HomeChapterRefresh refreshRemoteEntry;
  final HomeStaleChapterRefresh refreshStaleChapter;
  final DownloadCommandLifetimes commandLifetimes;

  final Map<String, ({ChapterDownloadService downloads, ImportedLibraryEntry entry})>
      _activeFileAudits =
      <String, ({ChapterDownloadService downloads, ImportedLibraryEntry entry})>{};

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
    Set<String>? requiredDirectoryNames,
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
      requiredDirectoryNames: requiredDirectoryNames,
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
      await resumeWholeComicJob(job.jobId);
    }
  }

  Future<void> pauseWholeComicJob(String jobId) =>
      _runWholeComicMutation((queue) => queue.pause(jobId));

  Future<void> resumeWholeComicJob(String jobId) =>
      _runWholeComicStart((queue) => queue.resume(jobId));

  Future<void> cancelWholeComicJob(String jobId) =>
      _runWholeComicMutation((queue) => queue.cancel(jobId));

  Future<void> retryWholeComicJob(String jobId) =>
      _runWholeComicStart((queue) => queue.retry(jobId));

  Future<void> _runWholeComicStart(
    Future<void> Function(WholeComicDownloadQueue queue) mutation,
  ) => commandLifetimes.run((command) async {
    await ensureDurableServices();
    final queue = session.wholeComicDownloads;
    await queue.ready;
    command.check();
    await mutation(queue);
    // An enqueue/resume may have awaited queue persistence while Stop arrived.
    try {
      command.check();
    } on Failure {
      await Future.wait([for (final job in queue.snapshot.jobs.where((job) => job.canPause))
        queue.pause(job.jobId)]);
      rethrow;
    }
    session.refreshWholeComicSnapshot();
  });

  Future<void> removeWholeComicJob(String jobId) =>
      _runWholeComicMutation((queue) => queue.remove(jobId));

  Future<void> updateWholeComicPolicy(WholeComicQueuePolicy policy) =>
      _runWholeComicMutation((queue) => queue.updatePolicy(policy));

  Future<void> _runWholeComicMutation(
    Future<void> Function(WholeComicDownloadQueue queue) mutation,
  ) async {
    await ensureDurableServices();
    final queue = session.wholeComicDownloads;
    await queue.ready;
    await mutation(queue);
    session.refreshWholeComicSnapshot();
  }

  Future<ChapterFileAuditReport> auditChapterFiles(
    ImportedLibraryEntry entry,
  ) async {
    await ensureDurableServices();
    final hydrated = await session.hydrateEntry(entry);
    final downloads = session.chapterDownloads;
    final identity = chapterDownloadIdentity(
      hydrated.chapter.sourceId,
      hydrated.chapter.comicId,
      hydrated.chapter.chapterId,
      hydrated.chapter.sourceRevision,
    );
    _activeFileAudits[identity] = (downloads: downloads, entry: hydrated);
    try {
      final report = await downloads.auditChapterFiles(hydrated);
      final snapshot = await downloads.inspect(hydrated);
      session.acceptDownloadSnapshot(snapshot);
      return report;
    } finally {
      final current = _activeFileAudits[identity];
      if (current != null && identical(current.downloads, downloads)) {
        _activeFileAudits.remove(identity);
      }
    }
  }

  Future<void> cancelChapterFileAudit(ImportedLibraryEntry entry) async {
    final prefix =
        '${entry.chapter.sourceId}\u0000${entry.chapter.comicId}\u0000'
        '${entry.chapter.chapterId}\u0000';
    final active = _activeFileAudits.entries
        .where((candidate) => candidate.key.startsWith(prefix))
        .map((candidate) => candidate.value)
        .toList(growable: false);
    if (active.isNotEmpty) {
      for (final owner in active) {
        await owner.downloads.cancelChapterFileAudit(owner.entry);
      }
      return;
    }
    await ensureDurableServices();
    await session.chapterDownloads.cancelChapterFileAudit(entry);
  }

  Future<ChapterDownloadSnapshot> stopChapter(
    ImportedLibraryEntry entry,
  ) async {
    await ensureDurableServices();
    final hydrated = await session.hydrateEntry(entry);
    final downloads = session.chapterDownloads;
    await downloads.cancel(hydrated);
    final snapshot = await downloads.inspect(hydrated);
    session.acceptDownloadSnapshot(snapshot);
    return snapshot;
  }

  Future<ChapterDownloadSnapshot> downloadChapter(
    ImportedLibraryEntry entry,
  ) =>
      _runChapterTransfer(entry, retry: false);

  Future<ChapterDownloadSnapshot> retryChapter(
    ImportedLibraryEntry entry,
  ) =>
      _runChapterTransfer(entry, retry: true);

  Future<ImportedLibraryEntry> downloadChapterForTranslation(ImportedLibraryEntry entry) async {
    late ImportedLibraryEntry resolved;
    await _runChapterTransfer(entry, retry: false, onResolved: (current) => resolved = current);
    return resolved;
  }

  Future<ChapterDownloadSnapshot> _runChapterTransfer(
    ImportedLibraryEntry entry, {
    required bool retry,
    void Function(ImportedLibraryEntry)? onResolved,
  }) => commandLifetimes.run((command) => _executeChapterTransfer(entry,
      retry: retry, onResolved: onResolved, command: command));

  Future<ChapterDownloadSnapshot> _executeChapterTransfer(
    ImportedLibraryEntry entry, {
    required bool retry,
    required DownloadCommandLifetime command,
    void Function(ImportedLibraryEntry)? onResolved,
  }) async {
    await ensureDurableServices();
    command.check();
    final hydrated = await session.hydrateEntry(entry);
    command.check();
    var current = requiresSourceLocatorRefresh(hydrated.chapter)
        ? await refreshRemoteEntry(
            hydrated,
            forceSourceRefresh: true,
          )
        : hydrated;
    command.check();
    var downloads = session.chapterDownloads;
    try {
      // Conflict confirmation may claim placement asynchronously. Read it back
      // before artifact writes so a failed cross-process CAS is observed here.
      await downloads.getDownloadPlacement(
        sourceId: current.chapter.sourceId,
        comicId: current.chapter.comicId,
      );
      command.check();
      if (retry) {
        await downloads.retry(current);
      } else {
        await downloads.download(current);
      }
    } on Object catch (error) {
      command.check();
      final message = error.toString();
      final terminalSourceGeneration =
          sourceResourceGenerationRefreshEligible(error);
      if (terminalSourceGeneration ||
          message.contains('must use a runtime token') ||
          message.contains('token expired')) {
        final refreshed = await refreshStaleChapter(current);
        command.check();
        if (refreshed == null) rethrow;
        current = refreshed;
        downloads = session.chapterDownloads;
        await downloads.retry(current);
      } else {
        rethrow;
      }
    }
    final snapshot = await session.chapterDownloads.inspect(current);
    session.acceptDownloadSnapshot(snapshot);
    onResolved?.call(current);
    return snapshot;
  }

  Future<void> deleteChapter(
    ImportedLibraryEntry entry, {
    bool deleteFiles = false,
  }) async {
    final hydrated = deleteFiles
        ? await _deleteChapterFiles(entry)
        : await session.hydrateEntry(entry);
    await session.removeChapter(
      hydrated.chapter.sourceId,
      hydrated.chapter.chapterId,
    );
  }

  Future<ChapterDeleteImpactProjection> inspectDeleteImpact(
    ImportedLibraryEntry entry,
  ) async {
    await ensureDurableServices();
    final hydrated = await session.hydrateEntry(entry);
    final downloads = session.chapterDownloads;
    final reader = downloads is ChapterDeleteImpactProjectionReader
        ? downloads as ChapterDeleteImpactProjectionReader
        : null;
    if (reader == null) {
      throw StateError('download service does not expose delete impact');
    }
    return reader.inspectDeleteImpact(hydrated);
  }

  Future<ChapterDownloadSnapshot> deleteChapterFiles(
    ImportedLibraryEntry entry,
  ) async {
    final hydrated = await _deleteChapterFiles(entry);
    final snapshot = await session.chapterDownloads.inspect(hydrated);
    session.acceptDownloadSnapshot(snapshot);
    return snapshot;
  }

  Future<ImportedLibraryEntry> _deleteChapterFiles(
    ImportedLibraryEntry entry,
  ) async {
    await ensureDurableServices();
    final hydrated = await session.hydrateEntry(entry);
    await session.chapterDownloads.delete(hydrated);
    return hydrated;
  }

  Future<HomeWholeComicDownloadStart> downloadComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
  ) => commandLifetimes.run((command) => _enqueueComicEntries(comicIdentity, entries, command));

  Future<HomeWholeComicDownloadStart> _enqueueComicEntries(
    String comicIdentity,
    Iterable<ImportedLibraryEntry> entries,
    DownloadCommandLifetime command,
  ) async {
    await ensureDurableServices();
    command.check();
    final chapters = <ImportedLibraryEntry>[];
    for (final entry in entries) {
      final hydrated = await session.hydrateEntry(entry);
      command.check();
      chapters.add(
        requiresSourceLocatorRefresh(hydrated.chapter)
            ? await refreshRemoteEntry(
                hydrated,
                forceSourceRefresh: true,
              )
            : hydrated,
      );
      command.check();
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
    command.check();
    final placement = await session.chapterDownloads.getDownloadPlacement(
      sourceId: first.sourceId,
      comicId: first.comicId,
    );
    command.check();
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
    try {
      command.check();
    } on Failure {
      final queue = session.wholeComicDownloads;
      for (final job in queue.snapshot.jobs) {
        if (job.sourceId == first.sourceId && job.comicId == first.comicId && job.canPause) {
          await queue.pause(job.jobId);
        }
      }
      rethrow;
    }
    session.refreshWholeComicSnapshot();
    return HomeWholeComicDownloadStart(
      sourceId: first.sourceId,
      comicId: first.comicId,
    );
  }
}
