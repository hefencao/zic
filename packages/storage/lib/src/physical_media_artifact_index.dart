import 'package:domain/domain.dart';

/// Canonical physical-media binding to one immutable artifact object.
///
/// Exact logical DownloadId bindings may come and go independently. This
/// binding is what lets a version-family canonical media coordinate find its
/// completed body directly after restart without walking through another
/// concrete version.
final class PhysicalMediaArtifactRecord {
  const PhysicalMediaArtifactRecord({
    required this.id,
    required this.artifactId,
    required this.accessLocator,
    required this.bytes,
    required this.checksum,
    required this.checksumAlgorithm,
    required this.storageRootId,
    required this.createdUs,
    required this.touchedUs,
  });

  final PhysicalMediaId id;
  final String artifactId;
  final String accessLocator;
  final int bytes;
  final String checksum;
  final String checksumAlgorithm;
  final String storageRootId;
  final int createdUs;
  final int touchedUs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhysicalMediaArtifactRecord &&
          id == other.id &&
          artifactId == other.artifactId &&
          accessLocator == other.accessLocator &&
          bytes == other.bytes &&
          checksum == other.checksum &&
          checksumAlgorithm == other.checksumAlgorithm &&
          storageRootId == other.storageRootId &&
          createdUs == other.createdUs &&
          touchedUs == other.touchedUs;

  @override
  int get hashCode => Object.hash(
        id,
        artifactId,
        accessLocator,
        bytes,
        checksum,
        checksumAlgorithm,
        storageRootId,
        createdUs,
        touchedUs,
      );
}

abstract interface class PhysicalMediaArtifactIndex {
  Future<PhysicalMediaArtifactRecord?> getPhysicalMediaArtifact(
    PhysicalMediaId id,
  );

  /// Null keeps the complete inventory; an empty selection returns no rows.
  Future<List<PhysicalMediaArtifactRecord>> listPhysicalMediaArtifacts({
    Iterable<PhysicalMediaId>? ids,
  });

  /// Binds [id] to an already-existing immutable artifact object.
  ///
  /// Implementations must reject a missing artifact object and must never use
  /// this operation to rewrite the object's bytes/locator/content proof.
  Future<void> putPhysicalMediaArtifactBinding({
    required PhysicalMediaId id,
    required String artifactId,
    required int createdUs,
    required int touchedUs,
  });

  Future<void> touchPhysicalMediaArtifact(
    PhysicalMediaId id,
    int touchedUs,
  );

  Future<void> removePhysicalMediaArtifactBinding(PhysicalMediaId id);
}
