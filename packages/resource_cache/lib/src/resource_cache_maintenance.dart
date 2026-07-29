import 'resource_cache.dart';

final class ArtifactCacheUsage {
  const ArtifactCacheUsage({
    required this.bytes,
    required this.entries,
  })  : assert(bytes >= 0),
        assert(entries >= 0);

  final int bytes;
  final int entries;
}

final class ArtifactCacheReport {
  const ArtifactCacheReport({
    required this.beforeBytes,
    required this.releasedBytes,
    required this.remainingBytes,
    required this.evictedEntries,
    required this.skippedBusy,
  });

  final int beforeBytes;
  final int releasedBytes;
  final int remainingBytes;
  final int evictedEntries;
  final int skippedBusy;
}

/// Persistent encoded page-artifact tier. Implementations may use artifacts,
/// files or a database, but must operate on independent resource records rather
/// than treating a whole chapter as one cache unit.
abstract interface class ArtifactCacheMaintenance {
  Future<ArtifactCacheUsage> inspectArtifacts();

  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  });

  Future<ArtifactCacheReport> clearArtifacts();
}

final class ResourceCacheMaintenancePolicy {
  const ResourceCacheMaintenancePolicy({
    this.responseTargetWeight = 24 * 1024 * 1024,
    this.artifactMaxWeight = 512 * 1024 * 1024,
    this.artifactTargetWeight = 384 * 1024 * 1024,
  })  : assert(responseTargetWeight >= 0),
        assert(artifactMaxWeight >= 0),
        assert(artifactTargetWeight >= 0),
        assert(artifactTargetWeight <= artifactMaxWeight);

  final int responseTargetWeight;
  final int artifactMaxWeight;
  final int artifactTargetWeight;
}

final class ResourceCacheUsage {
  const ResourceCacheUsage({
    required this.responses,
    this.artifacts,
  });

  final ResourceCacheStats responses;
  final ArtifactCacheUsage? artifacts;

  int get totalBytes => responses.weight + (artifacts?.bytes ?? 0);
  int get totalEntries => responses.entries + (artifacts?.entries ?? 0);
}

final class ResourceCacheMaintenanceReport {
  const ResourceCacheMaintenanceReport({
    required this.responseReleasedBytes,
    required this.responses,
    this.artifacts,
  });

  final int responseReleasedBytes;
  final ResourceCacheStats responses;
  final ArtifactCacheReport? artifacts;

  int get totalReleasedBytes =>
      responseReleasedBytes + (artifacts?.releasedBytes ?? 0);
}

/// One cache-policy coordination point spanning reusable source responses and
/// the existing encoded page-artifact tier.
///
/// The coordinator owns response-cache and maintenance policy. It does not
/// become a second owner of page files: [artifacts] remains an adapter to
/// Pipeline/DownloadSession-owned records and delegates physical trim/clear to
/// their existing registry and CacheOps implementation.
final class ResourceCacheCoordinator {
  ResourceCacheCoordinator({
    ResourceCacheManager? responses,
    this.artifacts,
    this.maintenancePolicy = const ResourceCacheMaintenancePolicy(),
  }) : responses = responses ?? ResourceCacheManager();

  final ResourceCacheManager responses;
  final ArtifactCacheMaintenance? artifacts;
  final ResourceCacheMaintenancePolicy maintenancePolicy;

  Future<ResourceCacheUsage> inspect() async {
    final artifactMaintenance = artifacts;
    return ResourceCacheUsage(
      responses: responses.stats,
      artifacts: artifactMaintenance == null
          ? null
          : await artifactMaintenance.inspectArtifacts(),
    );
  }

  Future<ResourceCacheMaintenanceReport> trim() async {
    final beforeResponses = responses.stats.weight;
    responses.trimTo(targetWeight: maintenancePolicy.responseTargetWeight);
    final artifactMaintenance = artifacts;
    final artifactReport = artifactMaintenance == null
        ? null
        : await artifactMaintenance.trimArtifacts(
            maxBytes: maintenancePolicy.artifactMaxWeight,
            targetBytes: maintenancePolicy.artifactTargetWeight,
          );
    return ResourceCacheMaintenanceReport(
      responseReleasedBytes: beforeResponses - responses.stats.weight,
      responses: responses.stats,
      artifacts: artifactReport,
    );
  }

  Future<ResourceCacheMaintenanceReport> clear() async {
    final responseReleasedBytes = responses.stats.weight;
    responses.clear();
    final artifactMaintenance = artifacts;
    final artifactReport = artifactMaintenance == null
        ? null
        : await artifactMaintenance.clearArtifacts();
    return ResourceCacheMaintenanceReport(
      responseReleasedBytes: responseReleasedBytes,
      responses: responses.stats,
      artifacts: artifactReport,
    );
  }

  Future<void> close() => responses.close();
}
