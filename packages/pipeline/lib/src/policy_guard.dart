import 'package:domain/domain.dart';

import 'demand.dart';
import 'role_window.dart';

final class PolicyGuard {
  const PolicyGuard({this.maxDownloadDemands = 7, this.maxFrameWatermark = 8});

  final int maxDownloadDemands;
  final int maxFrameWatermark;

  DemandPlan enforce(DemandPlan plan) {
    final currentDownloads = plan.downloads.entries
        .where((entry) => entry.value.role == PageRole.current)
        .toList(growable: false);
    final currentDecodes = plan.decodes.entries
        .where((entry) => entry.value.role == PageRole.current)
        .toList(growable: false);
    final currentUploads = plan.uploads.entries
        .where((entry) => entry.value.role == PageRole.current)
        .toList(growable: false);

    if (currentDownloads.length != 1 ||
        currentDecodes.length != 1 ||
        currentUploads.length != 1) {
      throw StateError('a plan must contain exactly one current demand per lane');
    }

    final sortedDownloads = plan.downloads.entries.toList(growable: false)
      ..sort((a, b) => b.value.priority.compareTo(a.value.priority));
    final guardedDownloads = <DownloadId, DownloadDemand>{
      for (final entry in sortedDownloads.take(maxDownloadDemands))
        entry.key: entry.value,
    };
    for (final entry in currentDownloads) {
      guardedDownloads[entry.key] = entry.value;
    }

    final guardedDecodes = <DecodeId, DecodeDemand>{};
    for (final entry in plan.decodes.entries) {
      guardedDecodes[entry.key] = DecodeDemand(
        role: entry.value.role,
        priority: entry.value.priority,
        targetWatermark: entry.value.targetWatermark
            .clamp(1, maxFrameWatermark)
            .toInt(),
        reason: entry.value.reason,
        expirationRevision: entry.value.expirationRevision,
        decisionId: entry.value.decisionId,
      );
    }

    final guardedDownloadKeys = guardedDownloads.keys
        .map((identity) => identity.key)
        .toSet();
    final guardedDecodeKeys = guardedDecodes.keys
        .map((identity) => identity.key)
        .toSet();
    final guardedKeep = plan.keep.where((identity) {
      return switch (identity.kind) {
        ResourceKind.download => guardedDownloadKeys.contains(identity.key),
        ResourceKind.decode => guardedDecodeKeys.contains(identity.key),
      };
    }).toSet();

    return DemandPlan(
      revision: plan.revision,
      downloads: guardedDownloads,
      decodes: guardedDecodes,
      uploads: plan.uploads,
      keep: guardedKeep,
    );
  }
}
