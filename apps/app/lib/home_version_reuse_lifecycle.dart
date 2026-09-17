import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';

import 'home_library_session.dart';

typedef HomeVersionRemoteEntryLoader = Future<ImportedLibraryEntry> Function(
  ImportedLibraryEntry entry, {
  TaskControl? control,
});

typedef HomeVersionVerifiedPageIdentityResolver = Future<String?> Function({
  required String sourceId,
  required Uri locator,
  TaskControl? control,
});

typedef HomeVersionMetadataTaskScheduler = bool Function({
  required String key,
  required int priority,
  required Future<void> Function(TaskControl control) task,
});

final class HomeVersionState {
  const HomeVersionState({
    this.successors = const <SourceComicVersion>[],
    this.predecessors = const <SourceComicVersion>[],
    this.backgroundRefresh,
  });

  final List<SourceComicVersion> successors;
  final List<SourceComicVersion> predecessors;
  final Future<HomeVersionState>? backgroundRefresh;

  bool get isEmpty => successors.isEmpty && predecessors.isEmpty;
}

/// Owns source-version relation discovery, page-reuse warmup and Reader
/// background version refresh without acquiring Widget/navigation authority.
///
/// All durable/library state is read through [session] on each operation, so a
/// service handoff does not require rebuilding this lifecycle. The only
/// composition capabilities injected from Home are source-owned fresh metadata
/// loading and verified page identity resolution.
final class HomeVersionReuseLifecycle {
  HomeVersionReuseLifecycle({
    required this.session,
    required this.loadRemoteEntrySnapshot,
    required this.verifiedPageReuseIdentity,
    required this.requiresSourceLocatorRefresh,
    required this.scheduleMetadataTask,
    required this.trace,
    required this.monotonicMicros,
  });

  static const int readerMetadataVersionRefreshPriority = 100;

  final HomeLibrarySession session;
  final HomeVersionRemoteEntryLoader loadRemoteEntrySnapshot;
  final HomeVersionVerifiedPageIdentityResolver verifiedPageReuseIdentity;
  final bool Function(ImportedChapterRecord chapter)
      requiresSourceLocatorRefresh;
  final HomeVersionMetadataTaskScheduler scheduleMetadataTask;
  final TraceSink trace;
  final int Function() monotonicMicros;

  final Map<String, Future<void>> _warmups = <String, Future<void>>{};
  final Map<String, Future<void>> _readerRefreshes = <String, Future<void>>{};

  ComicVersionRelationStore? _relationStore() {
    final candidate = session.library;
    if (candidate is! ComicVersionRelationStore) return null;
    return candidate as ComicVersionRelationStore;
  }

  Future<List<SourceComicVersion>> _storedSuccessors({
    required String sourceId,
    required String predecessorComicId,
    required String fallbackTitle,
  }) async {
    final store = _relationStore();
    if (store == null) return const <SourceComicVersion>[];
    final relations = await store.listComicVersionSuccessors(
      sourceId,
      predecessorComicId,
    );
    return <SourceComicVersion>[
      for (var index = 0; index < relations.length; index++)
        if (relations[index].successorComicId.isNotEmpty &&
            relations[index].successorComicId != predecessorComicId)
          SourceComicVersion(
            sourceId: sourceId,
            comicId: relations[index].successorComicId,
            title: relations[index].predecessorTitle.trim().isEmpty
                ? fallbackTitle
                : relations[index].predecessorTitle.trim(),
            generation: relations.length - index,
            date: _relationDate(relations[index].discoveredAt),
          ),
    ];
  }

  Future<List<SourceComicVersion>> _storedPredecessors({
    required String sourceId,
    required String successorComicId,
    required String fallbackTitle,
  }) async {
    final store = _relationStore();
    if (store == null) return const <SourceComicVersion>[];
    final relations = await store.listComicVersionPredecessors(
      sourceId,
      successorComicId,
    );
    return <SourceComicVersion>[
      for (var index = 0; index < relations.length; index++)
        if (relations[index].predecessorComicId.isNotEmpty &&
            relations[index].predecessorComicId != successorComicId)
          SourceComicVersion(
            sourceId: sourceId,
            comicId: relations[index].predecessorComicId,
            title: relations[index].predecessorTitle.trim().isEmpty
                ? fallbackTitle
                : relations[index].predecessorTitle.trim(),
            generation: index + 1,
            date: _relationDate(relations[index].discoveredAt),
            isPredecessor: true,
          ),
    ];
  }

  Future<void> _rememberSuccessors({
    required BrowsableComicSource source,
    required String predecessorComicId,
    required String predecessorTitle,
    required Iterable<SourceComicVersion> successors,
  }) async {
    if (_relationStore() == null) return;
    for (final successor in successors) {
      if (successor.isPredecessor ||
          successor.sourceId != source.sourceId ||
          successor.comicId.isEmpty ||
          successor.comicId == predecessorComicId) {
        continue;
      }
      await session.upsertVersionRelation(
        ComicVersionRelation(
          sourceId: source.sourceId,
          predecessorComicId: predecessorComicId,
          successorComicId: successor.comicId,
          predecessorTitle: predecessorTitle,
          discoveredAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  List<ComicVersionRelation> _relationsForComic(
    String sourceId,
    String comicId,
  ) =>
      session.versionRelations
          .where(
            (relation) =>
                relation.sourceId == sourceId &&
                (relation.predecessorComicId == comicId ||
                    relation.successorComicId == comicId),
          )
          .toList(growable: false);

  ImportedLibraryEntry? _exactChapterEntry(
    String sourceId,
    String chapterId,
  ) {
    for (final entry in session.entries) {
      if (entry.chapter.sourceId == sourceId &&
          entry.chapter.chapterId == chapterId) {
        return entry;
      }
    }
    return null;
  }

  List<ComicVersionPageMapping> _replacePageMapping(
    List<ComicVersionPageMapping> existing,
    ComicVersionPageMapping mapping,
  ) {
    final next = existing.toList(growable: true);
    final index = next.indexWhere(
      (current) =>
          current.predecessorChapterId == mapping.predecessorChapterId &&
          current.successorChapterId == mapping.successorChapterId,
    );
    if (index < 0) {
      next.add(mapping);
    } else {
      next[index] = mapping;
    }
    return List<ComicVersionPageMapping>.unmodifiable(next);
  }

  Future<ImportedLibraryEntry> _loadVersionChapterEntry(
    BrowsableComicSource source,
    Comic comic,
    Chapter chapter, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final existing = _exactChapterEntry(source.sourceId, chapter.chapterId);
    if (existing != null &&
        existing.chapter.pages.isNotEmpty &&
        !requiresSourceLocatorRefresh(existing.chapter)) {
      return session.hydrateEntry(existing);
    }
    final controlled = source is ControlledComicSource
        ? source as ControlledComicSource
        : null;
    final manifest = controlled != null
        ? await controlled.loadChapterControlled(
            chapter.chapterId,
            control: control,
          )
        : await source.loadChapter(chapter.chapterId);
    control?.throwIfCancelled();
    if (manifest.sourceId != source.sourceId ||
        manifest.comicId != chapter.comicId ||
        manifest.chapter.chapterId != chapter.chapterId) {
      throw StateError('同源版本章节返回了不匹配的身份');
    }
    return session.upsertChapter(
      ImportedChapterRecord.remote(
        comic: comic,
        manifest: manifest,
      ),
    );
  }

  Future<bool> _chapterHasReusableSourceState(
    ChapterManifest chapter,
  ) async {
    final provider = session.downloadComposition;
    if (provider == null || chapter.pages.isEmpty) return false;
    if (await provider.artifactStore.hasReusableChapterState(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapter.chapterId,
      sourceRevision: chapter.chapter.sourceRevision,
    )) {
      return true;
    }
    return provider.transferRuntime.hasReusablePhysicalStateForChapter(chapter);
  }

  Future<void> _warmRelationPageMappings(
    BrowsableComicSource source,
    ComicVersionRelation relation,
    ImportedLibraryEntry focus, {
    bool upgradeLegacyIntervalProof = false,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final focusIsPredecessor =
        relation.predecessorComicId == focus.chapter.comicId;
    final focusIsSuccessor =
        relation.successorComicId == focus.chapter.comicId;
    if (!focusIsPredecessor && !focusIsSuccessor) return;

    for (final mapping in relation.pageMappings) {
      final focusedChapterId = focusIsPredecessor
          ? mapping.predecessorChapterId
          : mapping.successorChapterId;
      final focusedRevision = focusIsPredecessor
          ? mapping.predecessorSourceRevision
          : mapping.successorSourceRevision;
      final focusedPageCount = focusIsPredecessor
          ? mapping.predecessorPageCount
          : mapping.successorPageCount;
      final proofAlreadyUsable = upgradeLegacyIntervalProof
          ? !VerifiedArtifactReusePlan.needsIntervalProbe(mapping)
          : mapping.verifiedPredecessorPageIndexes.isNotEmpty;
      if (focusedChapterId == focus.chapter.chapterId &&
          focusedRevision == focus.chapter.sourceRevision &&
          focusedPageCount == focus.chapter.pages.length &&
          proofAlreadyUsable &&
          !upgradeLegacyIntervalProof) {
        return;
      }
    }

    final relatedComicId = focusIsPredecessor
        ? relation.successorComicId
        : relation.predecessorComicId;
    final controlled = source is ControlledComicSource
        ? source as ControlledComicSource
        : null;
    final relatedComic = controlled != null
        ? await controlled.loadComicControlled(
            relatedComicId,
            control: control,
          )
        : await source.loadComic(relatedComicId);
    control?.throwIfCancelled();
    if (relatedComic.comic.sourceId != source.sourceId ||
        relatedComic.comic.comicId != relatedComicId) {
      throw StateError('同源版本漫画返回了不匹配的身份');
    }
    Chapter? relatedChapter;
    for (final candidate in relatedComic.chapters) {
      if (candidate.sequence == focus.chapter.sequence) {
        relatedChapter = candidate;
        break;
      }
    }
    if (relatedChapter == null) return;

    final predecessorChapter = focusIsPredecessor
        ? focus.chapter.toManifest().chapter
        : relatedChapter;
    final successorChapter = focusIsSuccessor
        ? focus.chapter.toManifest().chapter
        : relatedChapter;
    ComicVersionPageMapping? currentMapping;
    for (final mapping in relation.pageMappings) {
      if (mapping.predecessorChapterId == predecessorChapter.chapterId &&
          mapping.successorChapterId == successorChapter.chapterId &&
          mapping.predecessorPageCount == predecessorChapter.pageCount &&
          mapping.successorPageCount == successorChapter.pageCount) {
        currentMapping = mapping;
        break;
      }
    }
    final currentProofAlreadyUsable =
        currentMapping != null &&
        (upgradeLegacyIntervalProof
            ? !VerifiedArtifactReusePlan.needsIntervalProbe(currentMapping)
            : currentMapping.verifiedPredecessorPageIndexes.isNotEmpty);
    if (currentMapping != null &&
        currentMapping.predecessorSourceRevision ==
            predecessorChapter.sourceRevision &&
        currentMapping.successorSourceRevision ==
            successorChapter.sourceRevision &&
        currentProofAlreadyUsable &&
        !upgradeLegacyIntervalProof) {
      return;
    }

    final relatedEntry = await _loadVersionChapterEntry(
      source,
      relatedComic.comic,
      relatedChapter,
      control: control,
    );
    control?.throwIfCancelled();
    final focusManifest = focus.chapter.toManifest();
    final relatedManifest = relatedEntry.chapter.toManifest();
    final predecessorManifest =
        focusIsPredecessor ? focusManifest : relatedManifest;
    final successorManifest = focusIsSuccessor ? focusManifest : relatedManifest;
    if (currentMapping != null &&
        currentMapping.predecessorSourceRevision ==
            predecessorManifest.chapter.sourceRevision &&
        currentMapping.successorSourceRevision ==
            successorManifest.chapter.sourceRevision &&
        currentProofAlreadyUsable) {
      return;
    }
    final predecessorReusable =
        await _chapterHasReusableSourceState(predecessorManifest);
    final successorReusable =
        await _chapterHasReusableSourceState(successorManifest);
    if (!predecessorReusable && !successorReusable) return;
    final intervalProof =
        await VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(
      sourceChapter: predecessorManifest,
      targetChapter: successorManifest,
      resolveIdentity: (page) => verifiedPageReuseIdentity(
        sourceId: source.sourceId,
        locator: page.uri,
        control: control,
      ),
    );
    if (intervalProof == null || intervalProof.verifiedIntervals.isEmpty) {
      return;
    }
    final whole = intervalProof.verifiedIntervals.length == 1
        ? intervalProof.verifiedIntervals.single
        : null;
    final structuralOffset = whole != null &&
            whole.predecessorStart == 0 &&
            whole.predecessorEndExclusive == predecessorManifest.pages.length
        ? whole.successorOffset
        : 0;
    final mapping = ComicVersionPageMapping(
      predecessorChapterId: predecessorManifest.chapter.chapterId,
      successorChapterId: successorManifest.chapter.chapterId,
      predecessorPageCount: predecessorManifest.pages.length,
      successorPageCount: successorManifest.pages.length,
      successorOffset: structuralOffset,
      predecessorSourceRevision: predecessorManifest.chapter.sourceRevision,
      successorSourceRevision: successorManifest.chapter.sourceRevision,
      verifiedPredecessorPageIndexes: intervalProof.verifiedSourceIndexes,
      verifiedIntervals: intervalProof.verifiedIntervals,
      intervalProbeVersion: VerifiedArtifactReusePlan.intervalProbeVersion,
      verifiedAt: DateTime.now().toUtc(),
    );
    final updatedRelation = ComicVersionRelation(
      sourceId: relation.sourceId,
      predecessorComicId: relation.predecessorComicId,
      successorComicId: relation.successorComicId,
      predecessorTitle: relation.predecessorTitle,
      discoveredAt: relation.discoveredAt,
      pageMappings: _replacePageMapping(relation.pageMappings, mapping),
    );
    await session.upsertVersionRelationDerivedState(updatedRelation);
    trace.record(
      TraceEvent(
        monotonicMicros: monotonicMicros(),
        sessionId: 'source-version-reuse:${source.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
        payload: <String, Object?>{
          'stage': 'version-page-mapping-warmed',
          'focusChapterId': focus.chapter.chapterId,
          'verifiedPages': mapping.verifiedPredecessorPageIndexes.length,
          'verifiedIntervals': mapping.verifiedIntervals.length,
          'verifiedCoveragePages': mapping.verifiedIntervals.fold<int>(
            0,
            (total, interval) => total + interval.length,
          ),
          'probeCount': intervalProof.probeCount,
          'verificationMode': 'bounded-affine-probe',
          'persistedMappings': updatedRelation.pageMappings.length,
          'materializedEquivalenceEdges': 0,
        },
      ),
    );
  }

  String _warmupKey(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
  }) =>
      '${source.sourceId}\u0000${focus.chapter.comicId}'
      '\u0000${focus.chapter.chapterId}\u0000${focus.chapter.sourceRevision}'
      '\u0000${targetComicId ?? ''}';

  Future<void> prepareWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
    TaskControl? control,
  }) {
    control?.throwIfCancelled();
    if (control != null) {
      return _runWarmup(
        source,
        focus,
        targetComicId: targetComicId,
        control: control,
      );
    }
    final key = _warmupKey(source, focus, targetComicId: targetComicId);
    final existing = _warmups[key];
    if (existing != null) return existing;
    late Future<void> future;
    future = _runWarmup(source, focus, targetComicId: targetComicId);
    _warmups[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_warmups[key], future)) {
          _warmups.remove(key);
        }
      }),
    );
    return future;
  }

  Future<void> _runWarmup(
    BrowsableComicSource source,
    ImportedLibraryEntry focus, {
    String? targetComicId,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final relations = _relationsForComic(
      source.sourceId,
      focus.chapter.comicId,
    );
    for (final relation in relations) {
      control?.throwIfCancelled();
      final relatedComicId =
          relation.predecessorComicId == focus.chapter.comicId
              ? relation.successorComicId
              : relation.predecessorComicId;
      if (targetComicId != null && relatedComicId != targetComicId) {
        continue;
      }
      try {
        await _warmRelationPageMappings(
          source,
          relation,
          focus,
          upgradeLegacyIntervalProof: targetComicId != null,
          control: control,
        );
      } on Object catch (error) {
        if (control?.cancelled == true) rethrow;
        trace.record(
          TraceEvent(
            monotonicMicros: monotonicMicros(),
            sessionId: 'source-version-reuse:${source.sourceId}',
            kind: TraceEventKind.taskFailed,
            identityHash:
                '${source.sourceId}\u0000${relation.predecessorComicId}\u0000${relation.successorComicId}',
            payload: <String, Object?>{
              'stage': 'version-page-mapping-warm-failed',
              'focusChapterId': focus.chapter.chapterId,
              'errorType': error.runtimeType.toString(),
            },
          ),
        );
      }
    }
    control?.throwIfCancelled();
    await ensureAuthority(focus);
  }

  void scheduleReaderMetadataVersionRefresh(
    BrowsableComicSource source,
    ImportedLibraryEntry focus,
  ) {
    final key = _warmupKey(source, focus);
    if (_readerRefreshes.containsKey(key)) return;
    final completer = Completer<void>();
    final future = completer.future;
    _readerRefreshes[key] = future;
    final laneKey = 'reader-metadata-version-refresh:'
        '${identityHashCode(completer)}:$key';
    final submitted = scheduleMetadataTask(
      key: laneKey,
      priority: readerMetadataVersionRefreshPriority,
      task: (control) async {
        try {
          await _runReaderMetadataVersionRefresh(source, focus, control);
        } finally {
          if (!completer.isCompleted) completer.complete();
        }
      },
    );
    if (!submitted && !completer.isCompleted) {
      completer.complete();
    }
    unawaited(
      future.whenComplete(() {
        if (identical(_readerRefreshes[key], future)) {
          _readerRefreshes.remove(key);
        }
      }),
    );
  }

  Future<void> _runReaderMetadataVersionRefresh(
    BrowsableComicSource source,
    ImportedLibraryEntry focus,
    TaskControl control,
  ) async {
    control.throwIfCancelled();
    var refreshed = focus;
    final metadataFuture = loadRemoteEntrySnapshot(focus, control: control);
    final versionFuture = loadVersionState(
      source,
      focus.chapter.comicTitle,
      focus.chapter.comicId,
      control: control,
    );
    var metadataSnapshotLoaded = false;
    var metadataPreempted = false;
    var metadataRetryAttempted = false;
    var versionChecked = false;
    bool isRuntimeRequestPreemption(Object error) =>
        error is Failure &&
        error.code == ErrorCode.cancelled &&
        error.details['runtimeErrorCode'] == 'runtime-request-cancelled';
    Map<String, Object?> errorPayload(Object error) => <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'errorMessage': error is Failure ? error.message : error.toString(),
          if (error is Failure) ...<String, Object?>{
            'errorCode': error.code.name,
            if (error.details['runtimeErrorCode'] case final String code)
              'runtimeErrorCode': code,
          },
        };
    try {
      refreshed = await metadataFuture;
      metadataSnapshotLoaded = true;
    } on Object catch (error) {
      final preempted = isRuntimeRequestPreemption(error);
      metadataPreempted = preempted;
      trace.record(
        TraceEvent(
          monotonicMicros: monotonicMicros(),
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: preempted || control.cancelled
              ? TraceEventKind.artifactSource
              : TraceEventKind.taskFailed,
          identityHash: focus.chapter.chapterId,
          payload: <String, Object?>{
            'stage': control.cancelled
                ? 'reader-metadata-refresh-scheduler-preempted'
                : preempted
                    ? 'reader-metadata-refresh-preempted'
                    : 'reader-metadata-refresh-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    try {
      final state = await versionFuture;
      final background = state.backgroundRefresh;
      if (background != null) await background;
      versionChecked = true;
    } on Object catch (error) {
      trace.record(
        TraceEvent(
          monotonicMicros: monotonicMicros(),
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: control.cancelled
              ? TraceEventKind.artifactSource
              : TraceEventKind.taskFailed,
          identityHash: focus.chapter.comicId,
          payload: <String, Object?>{
            'stage': control.cancelled
                ? 'reader-version-check-scheduler-preempted'
                : 'reader-version-check-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    if (control.cancelled) return;
    if (metadataPreempted) {
      metadataRetryAttempted = true;
      try {
        refreshed = await loadRemoteEntrySnapshot(focus, control: control);
        metadataSnapshotLoaded = true;
      } on Object catch (error) {
        final preemptedAgain = isRuntimeRequestPreemption(error);
        trace.record(
          TraceEvent(
            monotonicMicros: monotonicMicros(),
            sessionId: 'reader-version-refresh:${source.sourceId}',
            kind: preemptedAgain || control.cancelled
                ? TraceEventKind.artifactSource
                : TraceEventKind.taskFailed,
            identityHash: focus.chapter.chapterId,
            payload: <String, Object?>{
              'stage': control.cancelled
                  ? 'reader-metadata-refresh-scheduler-preempted-again'
                  : preemptedAgain
                      ? 'reader-metadata-refresh-preempted-again'
                      : 'reader-metadata-refresh-retry-failed',
              ...errorPayload(error),
            },
          ),
        );
      }
    }
    if (control.cancelled) return;
    try {
      await prepareWarmup(source, refreshed, control: control);
    } on Object catch (error) {
      if (control.cancelled) return;
      trace.record(
        TraceEvent(
          monotonicMicros: monotonicMicros(),
          sessionId: 'reader-version-refresh:${source.sourceId}',
          kind: TraceEventKind.taskFailed,
          identityHash: refreshed.chapter.chapterId,
          payload: <String, Object?>{
            'stage': 'reader-version-reuse-warmup-failed',
            ...errorPayload(error),
          },
        ),
      );
    }
    if (control.cancelled) return;
    trace.record(
      TraceEvent(
        monotonicMicros: monotonicMicros(),
        sessionId: 'reader-version-refresh:${source.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash: refreshed.chapter.chapterId,
        payload: <String, Object?>{
          'stage': 'reader-metadata-version-refresh-complete',
          'metadataSnapshotLoaded': metadataSnapshotLoaded,
          'chapterPersisted': false,
          'pageCarrierPersisted': false,
          'metadataPreempted': metadataPreempted,
          'metadataRetryAttempted': metadataRetryAttempted,
          'versionChecked': versionChecked,
          'schedulerPriority': control.priority,
          'sourceRevision': refreshed.chapter.sourceRevision,
        },
      ),
    );
  }

  Future<int> ensureAuthority(ImportedLibraryEntry current) async {
    await session.ensureCanonicalMediaForEntry(current);
    final relations = _relationsForComic(
      current.chapter.sourceId,
      current.chapter.comicId,
    );
    final targetManifest = current.chapter.toManifest();
    final materializedRelatedChapters = <String>{};
    var acceptedMappings = 0;
    var skippedMissingSourceManifests = 0;
    for (final relation in relations) {
      final currentIsSuccessor =
          relation.successorComicId == current.chapter.comicId;
      final currentIsPredecessor =
          relation.predecessorComicId == current.chapter.comicId;
      if (!currentIsSuccessor && !currentIsPredecessor) continue;
      for (final mapping in relation.pageMappings) {
        final targetChapterId = currentIsSuccessor
            ? mapping.successorChapterId
            : mapping.predecessorChapterId;
        if (targetChapterId != current.chapter.chapterId) continue;
        final intervals = mapping.effectiveVerifiedIntervals;
        final predecessorRevision = mapping.predecessorSourceRevision;
        final successorRevision = mapping.successorSourceRevision;
        if (intervals.isEmpty ||
            predecessorRevision == null ||
            successorRevision == null) {
          continue;
        }
        final targetExpectedRevision = currentIsSuccessor
            ? successorRevision
            : predecessorRevision;
        final targetExpectedCount = currentIsSuccessor
            ? mapping.successorPageCount
            : mapping.predecessorPageCount;
        if (targetExpectedRevision != targetManifest.chapter.sourceRevision ||
            targetExpectedCount != targetManifest.pages.length) {
          continue;
        }
        final relatedComicId = currentIsSuccessor
            ? relation.predecessorComicId
            : relation.successorComicId;
        final relatedChapterId = currentIsSuccessor
            ? mapping.predecessorChapterId
            : mapping.successorChapterId;
        final relatedExpectedRevision = currentIsSuccessor
            ? predecessorRevision
            : successorRevision;
        final relatedExpectedCount = currentIsSuccessor
            ? mapping.predecessorPageCount
            : mapping.successorPageCount;
        final relatedEntry = session.versionAuthorityEntry(
          sourceId: current.chapter.sourceId,
          comicId: relatedComicId,
          chapterId: relatedChapterId,
        );
        if (relatedEntry == null) {
          skippedMissingSourceManifests++;
          continue;
        }
        if (relatedEntry.chapter.sourceRevision != relatedExpectedRevision ||
            relatedEntry.chapter.pages.length != relatedExpectedCount) {
          continue;
        }
        materializedRelatedChapters.add(relatedEntry.identity);
        acceptedMappings++;
      }
    }
    trace.record(
      TraceEvent(
        monotonicMicros: monotonicMicros(),
        sessionId: 'source-version-reuse:${current.chapter.sourceId}',
        kind: TraceEventKind.artifactSource,
        identityHash:
            '${current.chapter.sourceId}\u0000${current.chapter.chapterId}',
        payload: <String, Object?>{
          'stage': 'version-reuse-authority-ready',
          'acceptedMappings': acceptedMappings,
          'hydratedSourceChapters': materializedRelatedChapters.length,
          'skippedMissingSourceManifests': skippedMissingSourceManifests,
          'materializedEquivalenceEdges': 0,
          'restoreMode': 'canonical-media-direct',
        },
      ),
    );
    return acceptedMappings;
  }

  Future<HomeVersionState> loadVersionState(
    BrowsableComicSource source,
    String title,
    String currentComicId, {
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    final versionSource = source is ComicVersionSource
        ? source as ComicVersionSource
        : null;
    if (versionSource == null || !versionSource.supportsComicVersions) {
      return const HomeVersionState();
    }
    final storedSuccessors = await _storedSuccessors(
      sourceId: source.sourceId,
      predecessorComicId: currentComicId,
      fallbackTitle: title,
    );
    final storedPredecessors = await _storedPredecessors(
      sourceId: source.sourceId,
      successorComicId: currentComicId,
      fallbackTitle: title,
    );

    List<SourceComicVersion> merge(
      Iterable<SourceComicVersion> values, {
      required bool predecessor,
    }) {
      final indexes = <String, int>{};
      final currentCanonical = _canonicalComicKey(source, currentComicId);
      final result = <SourceComicVersion>[];
      for (final item in values) {
        if (item.isPredecessor != predecessor ||
            item.sourceId != source.sourceId ||
            item.comicId.isEmpty ||
            item.comicId == currentComicId ||
            _canonicalComicKey(source, item.comicId) == currentCanonical) {
          continue;
        }
        final existingIndex = indexes[item.comicId];
        if (existingIndex != null) {
          final existing = result[existingIndex];
          result[existingIndex] = SourceComicVersion(
            sourceId: existing.sourceId,
            comicId: existing.comicId,
            title: existing.title.trim().isEmpty
                ? item.title.trim()
                : existing.title.trim(),
            generation: existing.generation,
            date: existing.date?.trim().isNotEmpty == true
                ? existing.date!.trim()
                : item.date?.trim(),
            isPredecessor: predecessor,
          );
          continue;
        }
        indexes[item.comicId] = result.length;
        result.add(item);
      }
      result.sort((left, right) {
        final generation = predecessor
            ? left.generation.compareTo(right.generation)
            : right.generation.compareTo(left.generation);
        if (generation != 0) return generation;
        return left.comicId.compareTo(right.comicId);
      });
      return List<SourceComicVersion>.unmodifiable(result);
    }

    HomeVersionState stateFor(
      Iterable<SourceComicVersion> discovered, {
      Future<HomeVersionState>? backgroundRefresh,
    }) =>
        HomeVersionState(
          successors: merge(
            <SourceComicVersion>[...discovered, ...storedSuccessors],
            predecessor: false,
          ),
          predecessors: merge(
            <SourceComicVersion>[...discovered, ...storedPredecessors],
            predecessor: true,
          ),
          backgroundRefresh: backgroundRefresh,
        );

    Future<List<SourceComicVersion>> refreshVersions() async {
      control?.throwIfCancelled();
      final controlled = source is ControlledComicVersionSource
          ? source as ControlledComicVersionSource
          : null;
      final discovered = controlled != null
          ? await controlled.findComicVersionsControlled(
              currentComicId,
              control: control,
            )
          : await versionSource.findComicVersions(currentComicId);
      control?.throwIfCancelled();
      await _rememberSuccessors(
        source: source,
        predecessorComicId: currentComicId,
        predecessorTitle: title,
        successors: discovered.where((item) => !item.isPredecessor),
      );
      final current = _exactLibraryComicForSourceIdentity(
        source.sourceId,
        currentComicId,
      );
      if (control == null && current != null && current.chapters.length == 1) {
        unawaited(prepareWarmup(source, current.chapters.single));
      }
      return discovered;
    }

    if (storedSuccessors.isNotEmpty || storedPredecessors.isNotEmpty) {
      final backgroundRefresh = Future<void>(() {}).then((_) async {
        try {
          return stateFor(await refreshVersions());
        } on Object {
          if (control?.cancelled == true) rethrow;
          return stateFor(const <SourceComicVersion>[]);
        }
      });
      return stateFor(
        const <SourceComicVersion>[],
        backgroundRefresh: backgroundRefresh,
      );
    }

    var discovered = const <SourceComicVersion>[];
    try {
      discovered = await refreshVersions();
    } on Object {
      if (control?.cancelled == true) rethrow;
      if (storedPredecessors.isEmpty) rethrow;
    }
    return stateFor(discovered);
  }

  LibraryComic? _exactLibraryComicForSourceIdentity(
    String sourceId,
    String comicId,
  ) {
    for (final comic in aggregateImportedLibrary(
      session.entries,
      savedComics: session.savedComics,
    )) {
      if (comic.sourceId == sourceId && comic.comicId == comicId) {
        return comic;
      }
    }
    return null;
  }

  String _canonicalComicKey(
    BrowsableComicSource source,
    String comicId,
  ) {
    String? canonical;
    if (source is CanonicalComicIdentitySource) {
      canonical = (source as CanonicalComicIdentitySource)
          .canonicalComicIdentity(comicId);
    }
    if (canonical == null) {
      for (final saved in session.savedComics) {
        if (saved.sourceId == source.sourceId &&
            saved.comicId == comicId &&
            saved.canonicalComicId != null) {
          canonical = saved.canonicalComicId;
          break;
        }
      }
    }
    return '${source.sourceId}\u0000${canonical ?? comicId}';
  }

  static String? _relationDate(DateTime? value) {
    if (value == null) return null;
    final local = value.toLocal();
    String twoDigits(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
  }
}
