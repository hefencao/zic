import 'package:sessions/sessions.dart';

import 'artifact_cache_read_scheduler.dart';

/// Application-composition owner for cross-consumer download resources.
///
/// Owns the process-wide network lane and persistent-artifact local-read lane
/// used by both Reader transfer demands and explicit download commands. Storage
/// write/migration capacity will move behind this boundary in later refactor
/// phases; separate physical resources must not be folded into one semaphore.
final class DownloadResourceCoordinator {
  DownloadResourceCoordinator({
    NetLane? networkLane,
    ArtifactCacheReadScheduler? localReadScheduler,
  })  : localReadScheduler = localReadScheduler ?? ArtifactCacheReadScheduler(),
        networkLane = networkLane ??
            NetLane(
              maxActive: 5,
              reservedHighPrioritySlots: 1,
              highPriorityThreshold: 1000,
              preemptionThreshold: 40,
              preemptionCandidateGrace: const Duration(milliseconds: 100),
            );

  final NetLane networkLane;
  final ArtifactCacheReadScheduler localReadScheduler;
}
