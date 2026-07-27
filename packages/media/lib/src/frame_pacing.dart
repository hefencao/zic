/// Computes the remaining display time after the next frame has been prepared.
///
/// Decoding and upload work must not be added on top of the encoded frame
/// duration. If preparation overruns the duration, the next frame is due now.
abstract final class FramePacing {
  static Duration remaining({
    required Duration frameDuration,
    required Duration preparationElapsed,
  }) {
    if (frameDuration.isNegative) {
      throw ArgumentError.value(
        frameDuration,
        'frameDuration',
        'must not be negative',
      );
    }
    if (preparationElapsed.isNegative) {
      throw ArgumentError.value(
        preparationElapsed,
        'preparationElapsed',
        'must not be negative',
      );
    }
    final value = frameDuration - preparationElapsed;
    return value > Duration.zero ? value : Duration.zero;
  }
}
