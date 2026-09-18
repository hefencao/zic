import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:domain/domain.dart';

import 'home_library_session.dart';

typedef HomeMigrationDurableLibraryBoundary = Future<void> Function();

typedef HomeMigrationPreferenceSaver = Future<void> Function(
  ComicPreference preference,
);

typedef HomeMigrationCanonicalComicIdResolver = String? Function(
  String sourceId,
  String comicId, {
  String? fallback,
});

typedef HomeMigrationErrorReporter = void Function(
  String stage,
  Object error,
);

typedef HomeMigrationVerifiedPageReuseIdentity = Future<String?> Function({
  required String sourceId,
  required Uri locator,
});

final class HomeSourceMigrationResult {
  const HomeSourceMigrationResult({
    required this.replacingSource,
    required this.materializedPageArtifacts,
    required this.migratedChapters,
    required this.migratedProgress,
    required this.migratedReadStates,
    required this.preservedTargetStates,
    required this.registeredPageEquivalences,
  });

  final bool replacingSource;
  final int materializedPageArtifacts;
  final int migratedChapters;
  final int migratedProgress;
  final int migratedReadStates;
  final int preservedTargetStates;
  final int registeredPageEquivalences;
}

final class HomeSourceMigrationTransaction {
  HomeSourceMigrationTransaction({
    required this.session,
    required this.ensureDurableLibrary,
    required this.artifactCache,
    required this.verifiedPageReuseIdentity,
    required this.savePreference,
    required this.canonicalComicIdForPersistence,
    required this.reportError,
  });

  final HomeLibrarySession session;
  final HomeMigrationDurableLibraryBoundary ensureDurableLibrary;
  final ArtifactCacheManager? Function() artifactCache;
  final HomeMigrationVerifiedPageReuseIdentity verifiedPageReuseIdentity;
  final HomeMigrationPreferenceSaver savePreference;
  final HomeMigrationCanonicalComicIdResolver canonicalComicIdForPersistence;
  final HomeMigrationErrorReporter reportError;

  Future<bool>? _recovery;

  ImportedLibraryStore get _library => session.library;

  SourceMigrationJournalStore? _journalStore() {
    final candidate = _library;
    if (candidate is! SourceMigrationJournalStore) return null;
    return candidate as SourceMigrationJournalStore;
  }

  Future<void> _commitCleanup(SourceMigrationJournalRecord journal) async {
    if (!journal.replacingSource) return;
    final sourcePreference = await _library.getComicPreference(
      journal.sourceSourceId,
      journal.sourceComicId,
    );
    if (sourcePreference != null) {
      final neutral = ComicPreference(
        sourceId: sourcePreference.sourceId,
        comicId: sourcePreference.comicId,
        sourceKind: sourcePreference.sourceKind,
        inShelf: false,
        liked: false,
        collected: false,
        categoryIds: const <String>{},
        customOrder: sourcePreference.customOrder,
        updatedAt: DateTime.now().toUtc(),
      );
      await _library.saveComicPreference(neutral);
      session.replacePreference(neutral);
    }
    final entries = await _library.list();
    for (final entry in entries) {
      if (entry.chapter.sourceId != journal.sourceSourceId ||
          entry.chapter.comicId != journal.sourceComicId) {
        continue;
      }
      await session.removeChapter(
        entry.chapter.sourceId,
        entry.chapter.chapterId,
      );
    }
    await session.removeSavedComic(
      journal.sourceSourceId,
      journal.sourceComicId,
    );
  }

  Future<bool> recoverCommitted() {
    final existing = _recovery;
    if (existing != null) return existing;
    late final Future<bool> recovery;
    recovery = _recoverCommittedOnce().whenComplete(() {
      if (identical(_recovery, recovery)) {
        _recovery = null;
      }
    });
    _recovery = recovery;
    return recovery;
  }

  Future<bool> _recoverCommittedOnce() async {
    await ensureDurableLibrary();
    final store = _journalStore();
    if (store == null) return false;
    var changed = false;
    for (final journal in await store.listPendingSourceMigrations()) {
      if (!journal.targetMetadataCommitted) continue;
      try {
        final done = await runSourceMigrationJournal(
          store: store,
          record: journal,
          materializeArtifacts: () async {},
          commitMetadata: () async {},
          commitCleanup: () => _commitCleanup(journal),
        );
        if (done.phase == SourceMigrationPhase.done) {
          await store.removeSourceMigrationJournal(journal.migrationId);
          changed = true;
        }
      } on Object catch (error) {
        // Recovery is best-effort at startup/handoff. The durable journal stays
        // authoritative and will be retried on the next recovery boundary.
        reportError(
          'source migration cleanup recovery failed ${journal.migrationId}',
          error,
        );
      }
    }
    return changed;
  }

  Future<bool> resumeCommitted(String migrationId) async {
    await ensureDurableLibrary();
    final store = _journalStore();
    if (store == null) return false;
    final journal = await store.getSourceMigrationJournal(migrationId);
    if (journal?.targetMetadataCommitted != true) return false;
    final done = await runSourceMigrationJournal(
      store: store,
      record: journal!,
      materializeArtifacts: () async {},
      commitMetadata: () async {},
      commitCleanup: () => _commitCleanup(journal),
    );
    if (done.phase == SourceMigrationPhase.done) {
      await store.removeSourceMigrationJournal(migrationId);
    }
    return true;
  }

  Future<HomeSourceMigrationResult> executeConfirmed({
    required LibraryComic sourceComic,
    required BrowsableComicSource targetSource,
    required ComicManifest targetManifest,
    required ComicSourceMigrationPlan plan,
    required bool replacingSource,
    required ComicPreference sourcePreference,
    required int targetCustomOrder,
  }) async {
    await recoverCommitted();
    final targetReadStates = <String, ChapterReadState>{
      for (final state in await _library.listChapterReadStates(
        targetManifest.comic.sourceId,
        targetManifest.comic.comicId,
      ))
        state.identity: state,
    };
    final prepared = <_PreparedChapterMigration>[];
    for (final match in plan.chapterMatches) {
      if (match.confidence != ChapterMigrationConfidence.exact) {
        continue;
      }
      final targetChapter = await targetSource.loadChapter(
        match.target.chapterId,
      );
      if (targetChapter.sourceId != targetManifest.comic.sourceId ||
          targetChapter.comicId != targetManifest.comic.comicId ||
          targetChapter.chapter.chapterId != match.target.chapterId) {
        throw StateError('目标漫画源返回了不匹配的章节详情身份');
      }
      final targetRecord = ImportedChapterRecord.remote(
        comic: targetManifest.comic,
        manifest: targetChapter,
      );
      final targetEntry = await _library.get(
        targetRecord.sourceId,
        targetRecord.chapterId,
      );
      final sourceEntry = await session.hydrateEntry(match.source);
      final sourceChapter = sourceEntry.chapter.toManifest();
      var artifactReuse = VerifiedArtifactReusePlan.match(
        oldChapter: sourceChapter,
        newChapter: targetChapter,
      );
      if (replacingSource && artifactReuse.mappings.isEmpty) {
        try {
          artifactReuse = await VerifiedArtifactReusePlan.matchResolvedRelated(
            sourceChapter: sourceChapter,
            targetChapter: targetChapter,
            resolveIdentity: (page) => verifiedPageReuseIdentity(
              sourceId: targetSource.sourceId,
              locator: page.uri,
            ),
          );
        } on Object {
          // Optional media reuse proof must never invalidate a metadata
          // migration that already passed chapter identity verification.
        }
      }
      prepared.add(
        _PreparedChapterMigration(
          targetRecord: targetRecord,
          sourceProgress: sourceEntry.progress,
          sourceReadState: session.readStates[chapterLibraryIdentity(
            sourceEntry.chapter.sourceId,
            sourceEntry.chapter.chapterId,
          )],
          targetProgress: targetEntry?.progress,
          targetReadState: targetReadStates[chapterLibraryIdentity(
            targetRecord.sourceId,
            targetRecord.chapterId,
          )],
          artifactReuse: artifactReuse,
        ),
      );
    }

    final migrationId = sourceMigrationJournalId(
      sourceSourceId: sourceComic.sourceId,
      sourceComicId: sourceComic.comicId,
      targetSourceId: targetManifest.comic.sourceId,
      targetComicId: targetManifest.comic.comicId,
    );
    final preparedFingerprint = _preparedFingerprint(
      targetManifest,
      prepared,
    );
    final journalNow = DateTime.now().toUtc();
    var journal = SourceMigrationJournalRecord(
      migrationId: migrationId,
      sourceSourceId: sourceComic.sourceId,
      sourceComicId: sourceComic.comicId,
      targetSourceId: targetManifest.comic.sourceId,
      targetComicId: targetManifest.comic.comicId,
      replacingSource: replacingSource,
      preparedFingerprint: preparedFingerprint,
      phase: SourceMigrationPhase.prepared,
      createdAt: journalNow,
      updatedAt: journalNow,
    );
    final journalStore = _journalStore();
    if (journalStore != null) {
      for (final pending in await journalStore.listPendingSourceMigrations()) {
        if (pending.sourceSourceId != sourceComic.sourceId ||
            pending.sourceComicId != sourceComic.comicId) {
          continue;
        }
        if (pending.targetMetadataCommitted) {
          throw StateError('旧漫画源仍有已提交迁移等待清理');
        }
        if (pending.migrationId != migrationId ||
            pending.preparedFingerprint != preparedFingerprint) {
          await journalStore.removeSourceMigrationJournal(pending.migrationId);
        } else {
          journal = SourceMigrationJournalRecord(
            migrationId: pending.migrationId,
            sourceSourceId: pending.sourceSourceId,
            sourceComicId: pending.sourceComicId,
            targetSourceId: pending.targetSourceId,
            targetComicId: pending.targetComicId,
            replacingSource: pending.replacingSource,
            preparedFingerprint: pending.preparedFingerprint,
            phase: pending.phase,
            createdAt: pending.createdAt,
            updatedAt: pending.updatedAt,
          );
        }
      }
    }

    var materializedPageArtifacts = 0;
    var migratedChapters = 0;
    var migratedProgress = 0;
    var migratedReadStates = 0;
    var preservedTargetStates = 0;
    var registeredPageEquivalences = 0;
    final cache = artifactCache();

    Future<void> materializeArtifacts() async {
      if (cache == null) return;
      for (final item in prepared) {
        materializedPageArtifacts +=
            await item.artifactReuse.materializeTargetArtifacts(cache);
      }
    }

    Future<void> commitMetadata() async {
      final migrationTime = DateTime.now().toUtc();
      final existingSaved = await _library.getSavedComic(
        targetManifest.comic.sourceId,
        targetManifest.comic.comicId,
      );
      final existingPreference = await _library.getComicPreference(
        targetManifest.comic.sourceId,
        targetManifest.comic.comicId,
      );
      final mergedPreference = plan.mergePreference(
        sourcePreference,
        existingTarget: existingPreference,
        targetCustomOrder: targetCustomOrder,
        updatedAt: migrationTime,
      );

      await session.upsertSavedComic(
        SavedComicRecord.fromManifest(
          targetManifest,
          canonicalComicId: canonicalComicIdForPersistence(
            targetManifest.comic.sourceId,
            targetManifest.comic.comicId,
            fallback: existingSaved?.canonicalComicId,
          ),
          savedAt: existingSaved?.savedAt,
          updatedAt: migrationTime,
        ),
      );
      await savePreference(mergedPreference);

      for (final item in prepared) {
        final targetRecord = item.targetRecord;
        await session.upsertChapter(targetRecord);
        migratedChapters++;
        if (cache != null) {
          registeredPageEquivalences +=
              item.artifactReuse.registerEquivalences(cache);
        }

        final sourceProgress = item.sourceProgress;
        if (item.targetProgress != null) {
          preservedTargetStates++;
        } else if (sourceProgress != null) {
          final pageIndex = sourceProgress.pageIndex
              .clamp(0, targetRecord.pages.length - 1)
              .toInt();
          await session.persistProgress(
            ReadingProgress(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              pageIndex: pageIndex,
              subPageOffset: pageIndex == sourceProgress.pageIndex
                  ? sourceProgress.subPageOffset
                  : 0,
              readerMode: sourceProgress.readerMode,
              updatedAt: migrationTime,
            ),
          );
          migratedProgress++;
        }

        final sourceRead = item.sourceReadState;
        if (item.targetReadState != null) {
          preservedTargetStates++;
        } else if (sourceRead != null) {
          await _library.saveChapterReadState(
            ChapterReadState(
              sourceId: targetRecord.sourceId,
              comicId: targetRecord.comicId,
              chapterId: targetRecord.chapterId,
              isRead: sourceRead.isRead,
              updatedAt: migrationTime,
            ),
          );
          migratedReadStates++;
        }
      }
    }

    Future<void> commitCleanup() => _commitCleanup(journal);

    if (journalStore != null) {
      final done = await runSourceMigrationJournal(
        store: journalStore,
        record: journal,
        materializeArtifacts: materializeArtifacts,
        commitMetadata: commitMetadata,
        commitCleanup: commitCleanup,
      );
      if (done.phase == SourceMigrationPhase.done) {
        await journalStore.removeSourceMigrationJournal(migrationId);
      }
    } else {
      await materializeArtifacts();
      await commitMetadata();
      await commitCleanup();
    }

    return HomeSourceMigrationResult(
      replacingSource: replacingSource,
      materializedPageArtifacts: materializedPageArtifacts,
      migratedChapters: migratedChapters,
      migratedProgress: migratedProgress,
      migratedReadStates: migratedReadStates,
      preservedTargetStates: preservedTargetStates,
      registeredPageEquivalences: registeredPageEquivalences,
    );
  }
}

final class _PreparedChapterMigration {
  const _PreparedChapterMigration({
    required this.targetRecord,
    required this.sourceProgress,
    required this.sourceReadState,
    required this.targetProgress,
    required this.targetReadState,
    required this.artifactReuse,
  });

  final ImportedChapterRecord targetRecord;
  final ReadingProgress? sourceProgress;
  final ChapterReadState? sourceReadState;
  final ReadingProgress? targetProgress;
  final ChapterReadState? targetReadState;
  final VerifiedArtifactReusePlan artifactReuse;
}

String _preparedFingerprint(
  ComicManifest manifest,
  Iterable<_PreparedChapterMigration> prepared,
) {
  var hash = 0xcbf29ce484222325;
  void add(String value) {
    final framed = '${value.length}:$value;';
    for (final unit in framed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
  }

  final comic = manifest.comic;
  add(comic.sourceId);
  add(comic.comicId);
  add(comic.title);
  add(comic.readingDirection.name);
  add(comic.coverUri?.toString() ?? '');
  add(comic.description ?? '');
  for (final author in comic.authors) {
    add('author:$author');
  }
  for (final tag in comic.tags) {
    add('tag:$tag');
  }
  for (final chapter in manifest.chapters) {
    add('chapter:${chapter.chapterId}');
    add(chapter.title);
    add('${chapter.sequence}');
    add('${chapter.pageCount}');
    add(chapter.sourceRevision);
  }
  final items = prepared.toList(growable: false)
    ..sort(
      (left, right) =>
          left.targetRecord.chapterId.compareTo(right.targetRecord.chapterId),
    );
  for (final item in items) {
    final record = item.targetRecord;
    add('prepared:${record.sourceId}:${record.comicId}:${record.chapterId}');
    add(record.sourceRevision);
    for (final page in record.pages) {
      add(page.stablePageId);
      add(page.sourceId);
      add('${page.byteLength ?? -1}');
    }
    final reuse = item.artifactReuse.mappings.entries.toList(growable: false)
      ..sort((left, right) => left.key.key.compareTo(right.key.key));
    for (final mapping in reuse) {
      add('reuse:${mapping.key.key}<=${mapping.value.key}');
    }
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
