import 'package:domain/domain.dart';

enum ResourceInteractionPhase {
  stable,
  motion,
  transientPreview,
}

/// Coarse resource-control phase projected from Reader interaction state.
///
/// Raw gesture state must not own the logical resource window, but operations
/// with materially different commitment semantics still configure how deeply
/// retained demands are allowed to execute. Keep this intentionally coarse so
/// pointer-rate observation changes do not become scheduler-rate churn.
ResourceInteractionPhase resourceInteractionPhase(Interaction interaction) =>
    switch (interaction) {
      Interaction.dragging ||
      Interaction.scrolling ||
      Interaction.settling => ResourceInteractionPhase.motion,
      Interaction.scrubbing => ResourceInteractionPhase.transientPreview,
      Interaction.idle || Interaction.jumping => ResourceInteractionPhase.stable,
    };

/// Whether Reader motion is actively changing presentation geometry.
bool isPresentationMotionInteraction(Interaction interaction) =>
    resourceInteractionPhase(interaction) == ResourceInteractionPhase.motion;
