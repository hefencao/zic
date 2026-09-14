import 'package:domain/domain.dart';

/// Whether Reader motion is actively changing presentation geometry.
bool isPresentationMotionInteraction(Interaction interaction) =>
    switch (interaction) {
      Interaction.dragging ||
      Interaction.scrolling ||
      Interaction.settling => true,
      Interaction.idle ||
      Interaction.scrubbing ||
      Interaction.jumping => false,
    };
