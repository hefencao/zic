import 'dart:async';

import 'package:flutter/material.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

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

/// Displays one stable artwork image stream for the current encoded source.
///
/// Presentation does not own retry policy or encoded bytes. Network/cache
/// recovery belongs to ComicSourceResourceGateway/ResourceCacheManager and an
/// explicit source refresh may provide a new [source]. The ImageProvider is
/// created once for that immutable encoded source instead of being recreated on
/// every parent rebuild. A decode failure therefore
/// stays on one stable placeholder instead of starting presentation-owned retry,
/// lifecycle, eviction or force-refresh loops.
/// Equal providers keep the Image State; a different provider retires its old
/// error while the new immutable source is waiting for its first frame.
final class StableArtworkImage extends StatefulWidget {
  const StableArtworkImage({
    required this.source,
    required this.seed,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.deferDuringFastScroll = true,
    this.cacheWidth,
    this.onFrameReady,
    this.onDecodeFailure,
    super.key,
  });

  final EncodedResourceSource source;
  final String seed;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  // Mounted cover thumbnails may decode their already-loaded source while
  // scrolling; the normal ImageCache still owns sharing and memory limits.
  final bool deferDuringFastScroll;
  final int? cacheWidth;
  final VoidCallback? onFrameReady;
  final VoidCallback? onDecodeFailure;

  @override
  State<StableArtworkImage> createState() => _StableArtworkImageState();
}

final class _StableArtworkImageState extends State<StableArtworkImage> {
  late ImageProvider<Object> _provider;
  ImageProvider<Object>? _decodingProvider;
  bool _frameReported = false;
  bool _failureReported = false;

  @override
  void initState() {
    super.initState();
    _provider = encodedResourceImageProvider(widget.source);
  }

  ImageProvider<Object> get _effectiveProvider => widget.cacheWidth == null
      ? _provider
      : ResizeImage.resizeIfNeeded(widget.cacheWidth, null, _provider);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _decodeLoadedSource();
  }

  void _decodeLoadedSource() {
    if (widget.deferDuringFastScroll) return;
    final provider = _effectiveProvider;
    if (_decodingProvider == provider) return;
    _decodingProvider = provider;
    // Image's ScrollAwareImageProvider otherwise defers even resident encoded
    // bytes until velocity drops. Prime only this mounted, sized image stream;
    // Image joins the same cache entry and owns error/frame presentation.
    unawaited(precacheImage(provider, context, onError: (_, __) {}));
  }

  @override
  void didUpdateWidget(covariant StableArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _provider = encodedResourceImageProvider(widget.source);
      _frameReported = false;
      _failureReported = false;
    } else if (oldWidget.cacheWidth != widget.cacheWidth) {
      _frameReported = false;
    }
    _decodeLoadedSource();
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      // A new provider must not report the previous Image State's decode error
      // while its first frame is pending. Equal providers keep the same State.
      key: ValueKey<ImageProvider<Object>>(_provider),
      image: _effectiveProvider,
      fit: widget.fit,
      gaplessPlayback: widget.gaplessPlayback,
      filterQuality: widget.filterQuality,
      errorBuilder: (_, __, ___) {
        if (!_failureReported) {
          _failureReported = true;
          widget.onDecodeFailure?.call();
        }
        return SoftArtworkPlaceholder(seed: widget.seed);
      },
      frameBuilder: (context, child, frame, synchronous) {
        final ready = frame != null || synchronous;
        if (ready && !_frameReported) {
          _frameReported = true;
          _failureReported = false;
          widget.onFrameReady?.call();
        }
        return ready ? child : SoftArtworkPlaceholder(seed: widget.seed);
      },
    );
  }
}
