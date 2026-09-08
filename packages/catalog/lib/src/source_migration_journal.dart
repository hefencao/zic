enum SourceMigrationPhase {
  prepared,
  artifactsReady,
  metadataCommitted,
  cleanupPending,
  done,
}

String sourceMigrationJournalId({
  required String sourceSourceId,
  required String sourceComicId,
  required String targetSourceId,
  required String targetComicId,
}) =>
    '$sourceSourceId\u0000$sourceComicId\u0000$targetSourceId\u0000$targetComicId';

final class SourceMigrationJournalRecord {
  const SourceMigrationJournalRecord({
    required this.migrationId,
    required this.sourceSourceId,
    required this.sourceComicId,
    required this.targetSourceId,
    required this.targetComicId,
    required this.replacingSource,
    required this.preparedFingerprint,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
  });

  final String migrationId;
  final String sourceSourceId;
  final String sourceComicId;
  final String targetSourceId;
  final String targetComicId;
  final bool replacingSource;

  /// Stable fingerprint of the user-confirmed target/chapter preparation.
  /// It is checked only before [SourceMigrationPhase.metadataCommitted]. Once
  /// target metadata commits, recovery never reinterprets the target source;
  /// it only completes cleanup of the old authority.
  final String preparedFingerprint;
  final SourceMigrationPhase phase;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get targetMetadataCommitted =>
      phase.index >= SourceMigrationPhase.metadataCommitted.index;
}

/// Durable coordinator for source-comic migration.
///
/// The journal is deliberately metadata-only. Artifact bytes remain owned by
/// the artifact store and library entities remain owned by ImportedLibraryStore;
/// this coordinator only makes their cross-store ordering recoverable.
abstract interface class SourceMigrationJournalStore {
  Future<SourceMigrationJournalRecord?> getSourceMigrationJournal(
    String migrationId,
  );

  Future<List<SourceMigrationJournalRecord>> listPendingSourceMigrations();

  /// Creates [record] if absent. Repeating the same begin is idempotent.
  /// Implementations must reject another unfinished target for the same source
  /// comic so two migrations cannot concurrently clean up one authority.
  Future<SourceMigrationJournalRecord> beginSourceMigrationJournal(
    SourceMigrationJournalRecord record,
  );

  /// Advances monotonically by one phase. Repeating an already-applied phase
  /// is idempotent; backwards or skipped transitions are rejected.
  Future<SourceMigrationJournalRecord> advanceSourceMigrationJournal(
    String migrationId, {
    required SourceMigrationPhase phase,
    required DateTime updatedAt,
  });

  Future<void> removeSourceMigrationJournal(String migrationId);
}

/// Runs one recoverable source migration across independently durable owners.
///
/// Each callback must be idempotent within its phase. A callback failure leaves
/// the journal at the previous durable phase, so a later run repeats only that
/// phase. Cleanup is entered durably before [commitCleanup] runs: once target
/// metadata is committed, recovery never rolls the target authority back.
Future<SourceMigrationJournalRecord> runSourceMigrationJournal({
  required SourceMigrationJournalStore store,
  required SourceMigrationJournalRecord record,
  required Future<void> Function() materializeArtifacts,
  required Future<void> Function() commitMetadata,
  required Future<void> Function() commitCleanup,
}) async {
  var current = await store.beginSourceMigrationJournal(record);
  if (current.phase == SourceMigrationPhase.prepared) {
    await materializeArtifacts();
    current = await store.advanceSourceMigrationJournal(
      current.migrationId,
      phase: SourceMigrationPhase.artifactsReady,
      updatedAt: DateTime.now().toUtc(),
    );
  }
  if (current.phase == SourceMigrationPhase.artifactsReady) {
    await commitMetadata();
    current = await store.advanceSourceMigrationJournal(
      current.migrationId,
      phase: SourceMigrationPhase.metadataCommitted,
      updatedAt: DateTime.now().toUtc(),
    );
  }
  if (current.phase == SourceMigrationPhase.metadataCommitted) {
    current = await store.advanceSourceMigrationJournal(
      current.migrationId,
      phase: SourceMigrationPhase.cleanupPending,
      updatedAt: DateTime.now().toUtc(),
    );
  }
  if (current.phase == SourceMigrationPhase.cleanupPending) {
    await commitCleanup();
    current = await store.advanceSourceMigrationJournal(
      current.migrationId,
      phase: SourceMigrationPhase.done,
      updatedAt: DateTime.now().toUtc(),
    );
  }
  return current;
}
