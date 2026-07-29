final class LibraryMigrationIssue {
  const LibraryMigrationIssue({
    required this.issueId,
    required this.schemaFrom,
    required this.entityKind,
    required this.legacyKey,
    required this.resolvedSourceId,
    required this.details,
    required this.createdAt,
    this.acknowledgedAt,
  });

  final int issueId;
  final int schemaFrom;
  final String entityKind;
  final String legacyKey;
  final String? resolvedSourceId;
  final Map<String, Object?> details;
  final DateTime createdAt;
  final DateTime? acknowledgedAt;

  bool get acknowledged => acknowledgedAt != null;

  LibraryMigrationIssue copyWith({DateTime? acknowledgedAt}) =>
      LibraryMigrationIssue(
        issueId: issueId,
        schemaFrom: schemaFrom,
        entityKind: entityKind,
        legacyKey: legacyKey,
        resolvedSourceId: resolvedSourceId,
        details: details,
        createdAt: createdAt,
        acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'issueId': issueId,
        'schemaFrom': schemaFrom,
        'entityKind': entityKind,
        'legacyKey': legacyKey,
        'resolvedSourceId': resolvedSourceId,
        'details': details,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'acknowledgedAt': acknowledgedAt?.toUtc().toIso8601String(),
      };
}
