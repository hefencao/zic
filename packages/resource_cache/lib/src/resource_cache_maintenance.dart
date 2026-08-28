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
    this.transientPersistentResponseTargetWeight = 24 * 1024 * 1024,
    this.artifactMaxWeight = 512 * 1024 * 1024,
    this.artifactTargetWeight = 384 * 1024 * 1024,
  })  : assert(responseTargetWeight >= 0),
        assert(transientPersistentResponseTargetWeight >= 0),
        assert(artifactMaxWeight >= 0),
        assert(artifactTargetWeight >= 0),
        assert(artifactTargetWeight <= artifactMaxWeight);

  /// Builds a policy from one user-facing cache capacity in bytes.
  ///
  /// The persistent artifact tier receives the full capacity and trims down
  /// to 75% of it, mirroring the default 512 MiB / 384 MiB ratio. Response
  /// targets stay at their small fixed defaults: the user limit governs the
  /// dominant page-artifact tier, not reusable source responses.
  factory ResourceCacheMaintenancePolicy.forArtifactLimitBytes(int maxBytes) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
    return ResourceCacheMaintenancePolicy(
      artifactMaxWeight: maxBytes,
      artifactTargetWeight: maxBytes * 3 ~/ 4,
    );
  }

  final int responseTargetWeight;
  /// Target for transient durable response bytes only. Retained artwork is not
  /// capacity-trimmed and remains governed by explicit invalidation/clear.
  final int transientPersistentResponseTargetWeight;
  final int artifactMaxWeight;
  final int artifactTargetWeight;
}

final class ResourceCacheUsage {
  const ResourceCacheUsage({
    required this.responses,
    this.persistentResponses,
    this.artifacts,
  });

  final ResourceCacheStats responses;
  final ResourceCacheByteStoreUsage? persistentResponses;
  final ArtifactCacheUsage? artifacts;

  int get totalBytes =>
      responses.weight +
      (persistentResponses?.bytes ?? 0) +
      (artifacts?.bytes ?? 0);
  int get totalEntries =>
      responses.entries +
      (persistentResponses?.entries ?? 0) +
      (artifacts?.entries ?? 0);
}

final class ResourceCacheMaintenanceReport {
  const ResourceCacheMaintenanceReport({
    required this.responseReleasedBytes,
    required this.persistentResponseReleasedBytes,
    required this.responses,
    this.persistentResponses,
    this.artifacts,
  });

  final int responseReleasedBytes;
  final int persistentResponseReleasedBytes;
  final ResourceCacheStats responses;
  final ResourceCacheByteStoreUsage? persistentResponses;
  final ArtifactCacheReport? artifacts;

  int get totalReleasedBytes =>
      responseReleasedBytes +
      persistentResponseReleasedBytes +
      (artifacts?.releasedBytes ?? 0);
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
    ResourceCacheMaintenancePolicy? maintenancePolicy,
  })  : responses = responses ?? ResourceCacheManager(),
        _maintenancePolicy =
            maintenancePolicy ?? ResourceCacheMaintenancePolicy();

  final ResourceCacheManager responses;
  final ArtifactCacheMaintenance? artifacts;
  ResourceCacheMaintenancePolicy _maintenancePolicy;

  /// Current trim policy. Updates take effect on the next [trim] run; they do
  /// not evict eagerly.
  ResourceCacheMaintenancePolicy get maintenancePolicy => _maintenancePolicy;

  /// Replaces the trim policy, for example when the user changes the cache
  /// capacity setting. The next [trim] enforces the new limits.
  void updateMaintenancePolicy(ResourceCacheMaintenancePolicy policy) {
    _maintenancePolicy = policy;
  }

  Future<ResourceCacheUsage> inspect() async {
    final artifactMaintenance = artifacts;
    return ResourceCacheUsage(
      responses: responses.stats,
      persistentResponses: await responses.inspectPersistentBytes(),
      artifacts: artifactMaintenance == null
          ? null
          : await artifactMaintenance.inspectArtifacts(),
    );
  }

  Future<ResourceCacheMaintenanceReport> trim() async {
    final beforeResponses = responses.stats.weight;
    responses.trimTo(targetWeight: maintenancePolicy.responseTargetWeight);
    final persistentReport = await responses.trimPersistentBytesTo(
      targetBytes: maintenancePolicy.transientPersistentResponseTargetWeight,
    );
    final artifactMaintenance = artifacts;
    final artifactReport = artifactMaintenance == null
        ? null
        : await artifactMaintenance.trimArtifacts(
            maxBytes: maintenancePolicy.artifactMaxWeight,
            targetBytes: maintenancePolicy.artifactTargetWeight,
          );
    final persistentUsage = persistentReport == null
        ? null
        : await responses.inspectPersistentBytes();
    return ResourceCacheMaintenanceReport(
      responseReleasedBytes: beforeResponses - responses.stats.weight,
      persistentResponseReleasedBytes: persistentReport?.releasedBytes ?? 0,
      responses: responses.stats,
      persistentResponses: persistentUsage,
      artifacts: artifactReport,
    );
  }

  Future<ResourceCacheMaintenanceReport> clear() async {
    final responseReleasedBytes = responses.stats.weight;
    final persistentBefore = await responses.inspectPersistentBytes();
    responses.clear();
    await responses.drainPersistence();
    final artifactMaintenance = artifacts;
    final artifactReport = artifactMaintenance == null
        ? null
        : await artifactMaintenance.clearArtifacts();
    return ResourceCacheMaintenanceReport(
      responseReleasedBytes: responseReleasedBytes,
      persistentResponseReleasedBytes: persistentBefore?.bytes ?? 0,
      responses: responses.stats,
      persistentResponses: persistentBefore == null
          ? null
          : const ResourceCacheByteStoreUsage(bytes: 0, entries: 0),
      artifacts: artifactReport,
    );
  }

  Future<void> close() => responses.close();
}
