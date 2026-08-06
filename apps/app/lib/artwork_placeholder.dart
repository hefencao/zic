import 'package:flutter/material.dart';

/// Returns a stable pseudo-random pastel color for an unavailable artwork.
///
/// The seed keeps a failed image from changing color on every rebuild, while
/// still giving different comics/pages different placeholders. Low saturation
/// and high lightness keep the fallback quiet instead of drawing attention to
/// the load failure.
Color softArtworkColor(
  String seed, {
  Brightness brightness = Brightness.light,
}) {
  var hash = 0x811c9dc5;
  for (final codeUnit in seed.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  final hue = (hash % 360).toDouble();
  final saturation = 0.18 + ((hash ~/ 360) % 14) / 100;
  final lightness = brightness == Brightness.dark
      ? 0.32 + ((hash ~/ 5040) % 8) / 100
      : 0.76 + ((hash ~/ 5040) % 8) / 100;
  return HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
}

final class SoftArtworkPlaceholder extends StatelessWidget {
  const SoftArtworkPlaceholder({
    this.seed = '',
    this.borderRadius,
    super.key,
  });

  final String seed;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: softArtworkColor(
          seed,
          brightness: Theme.of(context).brightness,
        ),
        borderRadius: borderRadius,
      ),
    );
  }
}
