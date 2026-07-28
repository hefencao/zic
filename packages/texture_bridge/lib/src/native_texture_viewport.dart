import 'package:flutter/material.dart';

/// Displays an external texture without allowing the parent viewport to
/// distort its source aspect ratio.
///
/// [Texture] itself expands to the constraints it receives. Centering an
/// [AspectRatio] first gives the texture a contain-style paint box while the
/// native producer can continue using physical decode dimensions internally.
final class NativeTextureViewport extends StatelessWidget {
  const NativeTextureViewport({
    required this.textureId,
    required this.sourceWidth,
    required this.sourceHeight,
    this.filterQuality = FilterQuality.low,
    this.viewportKey,
    super.key,
  })  : assert(sourceWidth > 0),
        assert(sourceHeight > 0);

  final int textureId;
  final int sourceWidth;
  final int sourceHeight;
  final FilterQuality filterQuality;
  final Key? viewportKey;

  double get aspectRatio => sourceWidth / sourceHeight;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        key: viewportKey,
        aspectRatio: aspectRatio,
        child: Texture(
          textureId: textureId,
          filterQuality: filterQuality,
        ),
      ),
    );
  }
}
