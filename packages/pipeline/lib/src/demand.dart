import 'package:domain/domain.dart';

import 'role_window.dart';

final class DownloadDemand {
  const DownloadDemand({
    required this.role,
    required this.priority,
    required this.reason,
    required this.expirationRevision,
    this.flowTargetFrames = 0,
    this.retainFlowResponse = false,
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

  /// Keep the same consumer-paced response warm after bounded frame credit is
  /// reached. This is only for immediately adjacent roles that are likely to
  /// become foreground next; it does not change the frame target itself.
  final bool retainFlowResponse;

  final String? decisionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadDemand &&
          role == other.role &&
          priority == other.priority &&
          reason == other.reason &&
          expirationRevision == other.expirationRevision &&
          flowTargetFrames == other.flowTargetFrames &&
          retainFlowResponse == other.retainFlowResponse &&
          decisionId == other.decisionId;

  @override
  int get hashCode => Object.hash(
        role,
        priority,
        reason,
        expirationRevision,
        flowTargetFrames,
        retainFlowResponse,
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
    this.decisionId,
  });

  final PageRole role;
  final int priority;
  final String reason;
  final int expirationRevision;
  final String? decisionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UploadDemand &&
          role == other.role &&
          priority == other.priority &&
          reason == other.reason &&
          expirationRevision == other.expirationRevision &&
          decisionId == other.decisionId;

  @override
  int get hashCode =>
      Object.hash(role, priority, reason, expirationRevision, decisionId);
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
      downloads: _diffMaps(previous.downloads, next.downloads),
      decodes: _diffMaps(previous.decodes, next.decodes),
      uploads: _diffMaps(previous.uploads, next.uploads),
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

MapDiff<K, V> _diffMaps<K, V>(Map<K, V> previous, Map<K, V> next) {
  final added = <K, V>{};
  final changed = <K, V>{};
  final removed = <K>{};

  for (final entry in next.entries) {
    if (!previous.containsKey(entry.key)) {
      added[entry.key] = entry.value;
    } else if (previous[entry.key] != entry.value) {
      changed[entry.key] = entry.value;
    }
  }
  for (final key in previous.keys) {
    if (!next.containsKey(key)) {
      removed.add(key);
    }
  }
  return MapDiff<K, V>(added: added, changed: changed, removed: removed);
}
