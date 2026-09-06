import 'package:sessions/sessions.dart';

/// Application-composition owner for cross-consumer download resources.
///
/// Phase one owns the process-wide network lane used by both Reader transfer
/// demands and explicit download commands. Local-read/write/migration capacity
/// will move behind this boundary in later storage refactor phases; they remain
/// separate physical resources and must not be folded into this lane.
final class DownloadResourceCoordinator {
  DownloadResourceCoordinator({NetLane? networkLane})
      : networkLane = networkLane ??
            NetLane(
              maxActive: 5,
              reservedHighPrioritySlots: 1,
              highPriorityThreshold: 1000,
              preemptionThreshold: 40,
              preemptionCandidateGrace: const Duration(milliseconds: 100),
            );

  final NetLane networkLane;
}
