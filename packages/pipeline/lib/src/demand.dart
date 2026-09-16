import 'package:domain/domain.dart';

import 'role_window.dart';

final class DownloadDemand {
  const DownloadDemand({
    required this.role,
    required this.priority,
    required this.reason,
    required this.expirationRevision,
    this.flowTargetFrames = 0,
    this.decisionId,
  }) : assert(flowTargetFrames >= 0);

  final PageRole role;
  final int priority;
  final String reason;
  final int expirationRevision;

  /// Maximum complete animated WebP frames this speculative transport may
  /// read before backpressuring its existing response body. Zero means
  /// unlimited. This is scheduling metadata, not animation truth.
  final int flowTargetFrames;

  final String? decisionId;

  /// Scheduling identity excludes [expirationRevision]. Expiration is liveness
  /// metadata refreshed by a new accepted plan; it must never turn an otherwise
  /// unchanged resource request into scheduler work.
  bool sameSchedulingAs(DownloadDemand other) =>
      role == other.role &&
      priority == other.priority &&
      reason == other.reason &&
      flowTargetFrames == other.flowTargetFrames &&
      decisionId == other.decisionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadDemand &&
          role == other.role &&
          priority == other.priority &&
          reason == other.reason &&
          expirationRevision == other.expirationRevision &&
          flowTargetFrames == other.flowTargetFrames &&
          decisionId == other.decisionId;

  @override
  int get hashCode => Object.hash(
        role,
        priority,
        reason,
        expirationRevision,
        flowTargetFrames,
        decisionId,
      );
}

final class DecodeDemand {
  const DecodeDemand({
    required this.role,
    required this.priority,
    required this.targetWatermark,
    required this.reason,
    required this.expirationRevision,
    this.decisionId,
  });

  final PageRole role;
  final int priority;
  final int targetWatermark;
  final String reason;
  final int expirationRevision;
  final String? decisionId;

  /// Scheduling identity excludes [expirationRevision]; see [DownloadDemand].
  bool sameSchedulingAs(DecodeDemand other) =>
      role == other.role &&
      priority == other.priority &&
      targetWatermark == other.targetWatermark &&
      reason == other.reason &&
      decisionId == other.decisionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecodeDemand &&
          role == other.role &&
          priority == other.priority &&
          targetWatermark == other.targetWatermark &&
          reason == other.reason &&
          expirationRevision == other.expirationRevision &&
          decisionId == other.decisionId;

  @override
  int get hashCode => Object.hash(
        role,
        priority,
        targetWatermark,
        reason,
        expirationRevision,
        decisionId,
      );
}

final class UploadDemand {
  const UploadDemand({
    required this.role,
    required this.priority,
    required this.reason,
    required this.expirationRevision,
    this.retainOutput = false,
    this.viewportVisible = false,
    this.decisionId,
  });

  final PageRole role;
  final int priority;
  final String reason;
  final int expirationRevision;

  /// Prevents frame-budget eviction while this static output is visible.
  ///
  /// This is deliberately distinct from [role]: continuous vertical reading
  /// can show several pages at once, including pages with a non-primary role.
  final bool retainOutput;

  /// The page intersects the actual viewport in this observation.
  ///
  /// Continuous vertical reading can expose several pages at once whose
  /// scheduling [role] remains next/previous. Presentation staging uses this
  /// fact to keep truly visible work from waiting behind speculative output.
  final bool viewportVisible;
  final String? decisionId;

  /// Scheduling identity excludes [expirationRevision]; see [DownloadDemand].
  bool sameSchedulingAs(UploadDemand other) =>
      role == other.role &&
      priority == other.priority &&
      reason == other.reason &&
      retainOutput == other.retainOutput &&
      viewportVisible == other.viewportVisible &&
      decisionId == other.decisionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UploadDemand &&
          role == other.role &&
          priority == other.priority &&
          reason == other.reason &&
          expirationRevision == other.expirationRevision &&
          retainOutput == other.retainOutput &&
          viewportVisible == other.viewportVisible &&
          decisionId == other.decisionId;

  @override
  int get hashCode =>
      Object.hash(
        role,
        priority,
        reason,
        expirationRevision,
        retainOutput,
        viewportVisible,
        decisionId,
      );
}

final class DemandPlan {
  DemandPlan({
    required this.revision,
    required Map<DownloadId, DownloadDemand> downloads,
    required Map<DecodeId, DecodeDemand> decodes,
    required Map<DecodeId, UploadDemand> uploads,
    required Set<ResourceId> keep,
  })  : downloads = Map<DownloadId, DownloadDemand>.unmodifiable(downloads),
        decodes = Map<DecodeId, DecodeDemand>.unmodifiable(decodes),
        uploads = Map<DecodeId, UploadDemand>.unmodifiable(uploads),
        keep = Set<ResourceId>.unmodifiable(keep);

  factory DemandPlan.empty({int revision = 0}) => DemandPlan(
        revision: revision,
        downloads: const <DownloadId, DownloadDemand>{},
        decodes: const <DecodeId, DecodeDemand>{},
        uploads: const <DecodeId, UploadDemand>{},
        keep: const <ResourceId>{},
      );

  final int revision;
  final Map<DownloadId, DownloadDemand> downloads;
  final Map<DecodeId, DecodeDemand> decodes;
  final Map<DecodeId, UploadDemand> uploads;
  final Set<ResourceId> keep;
}

final class MapDiff<K, V> {
  MapDiff({
    required Map<K, V> added,
    required Map<K, V> changed,
    required Set<K> removed,
  })  : added = Map<K, V>.unmodifiable(added),
        changed = Map<K, V>.unmodifiable(changed),
        removed = Set<K>.unmodifiable(removed);

  final Map<K, V> added;
  final Map<K, V> changed;
  final Set<K> removed;

  bool get isEmpty => added.isEmpty && changed.isEmpty && removed.isEmpty;
}

final class DemandDiff {
  const DemandDiff({
    required this.downloads,
    required this.decodes,
    required this.uploads,
    required this.keepAdded,
    required this.keepRemoved,
  });

  factory DemandDiff.between(DemandPlan previous, DemandPlan next) {
    return DemandDiff(
      downloads: _diffMaps(
        previous.downloads,
        next.downloads,
        sameScheduling: (a, b) => a.sameSchedulingAs(b),
      ),
      decodes: _diffMaps(
        previous.decodes,
        next.decodes,
        sameScheduling: (a, b) => a.sameSchedulingAs(b),
      ),
      uploads: _diffMaps(
        previous.uploads,
        next.uploads,
        sameScheduling: (a, b) => a.sameSchedulingAs(b),
      ),
      keepAdded: next.keep.difference(previous.keep),
      keepRemoved: previous.keep.difference(next.keep),
    );
  }

  final MapDiff<DownloadId, DownloadDemand> downloads;
  final MapDiff<DecodeId, DecodeDemand> decodes;
  final MapDiff<DecodeId, UploadDemand> uploads;
  final Set<ResourceId> keepAdded;
  final Set<ResourceId> keepRemoved;

  bool get isEmpty =>
      downloads.isEmpty &&
      decodes.isEmpty &&
      uploads.isEmpty &&
      keepAdded.isEmpty &&
      keepRemoved.isEmpty;
}

MapDiff<K, V> _diffMaps<K, V>(
  Map<K, V> previous,
  Map<K, V> next, {
  required bool Function(V previous, V next) sameScheduling,
}) {
  final added = <K, V>{};
  final changed = <K, V>{};
  final removed = <K>{};

  for (final entry in next.entries) {
    if (!previous.containsKey(entry.key)) {
      added[entry.key] = entry.value;
    } else {
      final before = previous[entry.key] as V;
      if (!sameScheduling(before, entry.value)) {
        changed[entry.key] = entry.value;
      }
    }
  }
  for (final key in previous.keys) {
    if (!next.containsKey(key)) {
      removed.add(key);
    }
  }
  return MapDiff<K, V>(added: added, changed: changed, removed: removed);
}
