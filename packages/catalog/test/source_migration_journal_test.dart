import 'package:catalog/catalog.dart';
import 'package:test/test.dart';

void main() {
  test(
    'memory source migration journal is idempotent and source-exclusive',
    () async {
      final store = MemoryImportedLibraryStore();
      await store.open();
      addTearDown(store.close);
      final createdAt = DateTime.utc(2026, 9, 9);
      final record = SourceMigrationJournalRecord(
        migrationId: sourceMigrationJournalId(
          sourceSourceId: 'source-a',
          sourceComicId: 'comic-old',
          targetSourceId: 'source-b',
          targetComicId: 'comic-new',
        ),
        sourceSourceId: 'source-a',
        sourceComicId: 'comic-old',
        targetSourceId: 'source-b',
        targetComicId: 'comic-new',
        replacingSource: true,
        preparedFingerprint: 'confirmed-v1',
        phase: SourceMigrationPhase.prepared,
        createdAt: createdAt,
        updatedAt: createdAt,
      );

      expect(await store.beginSourceMigrationJournal(record), same(record));
      expect(await store.beginSourceMigrationJournal(record), same(record));
      final conflict = SourceMigrationJournalRecord(
        migrationId: sourceMigrationJournalId(
          sourceSourceId: 'source-a',
          sourceComicId: 'comic-old',
          targetSourceId: 'source-c',
          targetComicId: 'comic-other',
        ),
        sourceSourceId: 'source-a',
        sourceComicId: 'comic-old',
        targetSourceId: 'source-c',
        targetComicId: 'comic-other',
        replacingSource: true,
        preparedFingerprint: 'confirmed-v2',
        phase: SourceMigrationPhase.prepared,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      await expectLater(
        store.beginSourceMigrationJournal(conflict),
        throwsStateError,
      );

      final artifactsReady = await store.advanceSourceMigrationJournal(
        record.migrationId,
        phase: SourceMigrationPhase.artifactsReady,
        updatedAt: createdAt.add(const Duration(seconds: 1)),
      );
      expect(artifactsReady.phase, SourceMigrationPhase.artifactsReady);
      expect(
        (await store.listPendingSourceMigrations()).single.phase,
        SourceMigrationPhase.artifactsReady,
      );
      await expectLater(
        store.advanceSourceMigrationJournal(
          record.migrationId,
          phase: SourceMigrationPhase.cleanupPending,
          updatedAt: createdAt.add(const Duration(seconds: 2)),
        ),
        throwsStateError,
      );
    },
  );

  // Regression for process death at each cross-owner phase boundary. The
  // journal, not an in-memory flag, decides which side effect may repeat.
  test(
    'source migration runner resumes only the incomplete durable phase',
    () async {
      final store = MemoryImportedLibraryStore();
      await store.open();
      addTearDown(store.close);
      final createdAt = DateTime.utc(2026, 9, 9, 2);
      final record = SourceMigrationJournalRecord(
        migrationId: sourceMigrationJournalId(
          sourceSourceId: 'source-a',
          sourceComicId: 'old',
          targetSourceId: 'source-b',
          targetComicId: 'new',
        ),
        sourceSourceId: 'source-a',
        sourceComicId: 'old',
        targetSourceId: 'source-b',
        targetComicId: 'new',
        replacingSource: true,
        preparedFingerprint: 'fingerprint',
        phase: SourceMigrationPhase.prepared,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      var artifacts = 0;
      var metadata = 0;
      var cleanup = 0;

      await expectLater(
        runSourceMigrationJournal(
          store: store,
          record: record,
          materializeArtifacts: () async {
            artifacts++;
            throw StateError('simulated artifact crash');
          },
          commitMetadata: () async => metadata++,
          commitCleanup: () async => cleanup++,
        ),
        throwsStateError,
      );
      expect(artifacts, 1);
      expect(metadata, 0);
      expect(cleanup, 0);
      expect(
        (await store.getSourceMigrationJournal(record.migrationId))?.phase,
        SourceMigrationPhase.prepared,
      );

      await expectLater(
        runSourceMigrationJournal(
          store: store,
          record: record,
          materializeArtifacts: () async => artifacts++,
          commitMetadata: () async {
            metadata++;
            throw StateError('simulated metadata crash');
          },
          commitCleanup: () async => cleanup++,
        ),
        throwsStateError,
      );
      expect(artifacts, 2);
      expect(metadata, 1);
      expect(cleanup, 0);
      expect(
        (await store.getSourceMigrationJournal(record.migrationId))?.phase,
        SourceMigrationPhase.artifactsReady,
      );

      await expectLater(
        runSourceMigrationJournal(
          store: store,
          record: record,
          materializeArtifacts: () async => artifacts++,
          commitMetadata: () async => metadata++,
          commitCleanup: () async {
            cleanup++;
            throw StateError('simulated cleanup crash');
          },
        ),
        throwsStateError,
      );
      expect(artifacts, 2, reason: 'durable artifacts must not repeat');
      expect(
        metadata,
        2,
        reason: 'failed metadata phase is idempotently retried',
      );
      expect(cleanup, 1);
      expect(
        (await store.getSourceMigrationJournal(record.migrationId))?.phase,
        SourceMigrationPhase.cleanupPending,
      );

      final done = await runSourceMigrationJournal(
        store: store,
        record: record,
        materializeArtifacts: () async => artifacts++,
        commitMetadata: () async => metadata++,
        commitCleanup: () async => cleanup++,
      );
      expect(done.phase, SourceMigrationPhase.done);
      expect(artifacts, 2);
      expect(metadata, 2);
      expect(
        cleanup,
        2,
        reason: 'only unfinished cleanup repeats after restart',
      );
    },
  );
}
