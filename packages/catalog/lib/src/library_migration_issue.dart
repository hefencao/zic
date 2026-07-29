final class LibraryMigrationIssue {
  const LibraryMigrationIssue({
    required this.issueId,
    required this.schemaFrom,
    required this.entityKind,
    required this.legacyKey,
    required this.resolvedSourceId,
    required this.details,
    required this.createdAt,
  });

  final int issueId;
  final int schemaFrom;
  final String entityKind;
  final String legacyKey;
  final String? resolvedSourceId;
  final Map<String, Object?> details;
  final DateTime createdAt;
}
