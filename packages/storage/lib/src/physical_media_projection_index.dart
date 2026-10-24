/// Durable compact control-plane projection from one exact version chapter
/// into a canonical physical-media family.
///
/// [projectionJson] is owned by the downloads/catalog layer. Storage keeps it
/// opaque so the cache database does not depend on version-graph semantics.
/// One record represents an exact chapter projection and may cover thousands
/// of pages with only a handful of interval bindings.
final class PhysicalMediaProjectionRecord {
  const PhysicalMediaProjectionRecord({
    required this.exactKey,
    required this.familyKey,
    required this.projectionJson,
    required this.createdUs,
    required this.touchedUs,
  });

  final String exactKey;
  final String familyKey;
  final String projectionJson;
  final int createdUs;
  final int touchedUs;

  PhysicalMediaProjectionRecord copyWith({
    String? familyKey,
    String? projectionJson,
    int? createdUs,
    int? touchedUs,
  }) =>
      PhysicalMediaProjectionRecord(
        exactKey: exactKey,
        familyKey: familyKey ?? this.familyKey,
        projectionJson: projectionJson ?? this.projectionJson,
        createdUs: createdUs ?? this.createdUs,
        touchedUs: touchedUs ?? this.touchedUs,
      );
}

abstract interface class PhysicalMediaProjectionIndex {
  Future<PhysicalMediaProjectionRecord?> getPhysicalMediaProjection(
    String exactKey,
  );

  /// Null keeps all families. Exact keys only select metadata, never grant
  /// canonical media equivalence or change existing relation/revision checks.
  Future<List<PhysicalMediaProjectionRecord>> listPhysicalMediaProjections({
    Iterable<String>? exactKeys,
  });

  Future<void> putPhysicalMediaProjection(PhysicalMediaProjectionRecord record);

  /// Atomically commits one logical canonical-projection update. Callers use
  /// this for the predecessor/successor rows produced by one verified mapping
  /// so a crash cannot publish only one side of the family relation.
  Future<void> putPhysicalMediaProjections(
    Iterable<PhysicalMediaProjectionRecord> records,
  );

  Future<void> removePhysicalMediaProjection(String exactKey);
}
