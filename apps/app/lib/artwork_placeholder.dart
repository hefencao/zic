import 'dart:async';

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

/// Rebuilds a Flutter image stream after a transient decoder/cache failure.
///
/// Encoded artwork bytes may already be valid and resident while the engine's
/// image stream fails during lifecycle churn. A plain [Image.errorBuilder]
/// leaves that widget permanently on its placeholder until the whole App is
/// recreated. This wrapper evicts only the failed provider, retries with a new
/// stream, and retries again when the App resumes. It does not own encoded
/// bytes and does not create a competing artwork cache.
final class ArtworkRetryController {
  ArtworkRetryController({
    this.delays = const <Duration>[
      Duration(milliseconds: 240),
      Duration(milliseconds: 720),
      Duration(milliseconds: 1600),
    ],
  });

  final List<Duration> delays;
  Timer? _timer;
  int _attempt = 0;

  bool get hasPendingRetry => _timer?.isActive ?? false;

  void reset() {
    _timer?.cancel();
    _attempt = 0;
  }

  void schedule(VoidCallback retry) {
    if (hasPendingRetry || _attempt >= delays.length) return;
    final delay = delays[_attempt++];
    _timer = Timer(delay, retry);
  }

  void retryNow(VoidCallback retry, {bool resetBudget = false}) {
    _timer?.cancel();
    if (resetBudget) _attempt = 0;
    retry();
  }

  void dispose() => _timer?.cancel();
}

final class RecoverableArtworkImage extends StatefulWidget {
  const RecoverableArtworkImage({
    required this.image,
    required this.seed,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
    this.gaplessPlayback = true,
    this.cacheWidth,
    this.onFrameReady,
    this.onDecodeFailure,
    super.key,
  });

  final ImageProvider<Object> image;
  final String seed;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final int? cacheWidth;
  final VoidCallback? onFrameReady;
  final VoidCallback? onDecodeFailure;

  @override
  State<RecoverableArtworkImage> createState() =>
      _RecoverableArtworkImageState();
}

final class _RecoverableArtworkImageState
    extends State<RecoverableArtworkImage> with WidgetsBindingObserver {
  static const _retryDelays = <Duration>[
    Duration(milliseconds: 180),
    Duration(milliseconds: 480),
    Duration(milliseconds: 1200),
  ];

  Timer? _retryTimer;
  int _generation = 0;
  int _retryIndex = 0;
  bool _failed = false;
  bool _frameReported = false;

  ImageProvider<Object> get _effectiveProvider => widget.cacheWidth == null
      ? widget.image
      : ResizeImage.resizeIfNeeded(widget.cacheWidth, null, widget.image);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant RecoverableArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.cacheWidth != widget.cacheWidth) {
      _retryTimer?.cancel();
      _generation++;
      _retryIndex = 0;
      _failed = false;
      _frameReported = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _failed) {
      _retry(resetBudget: true);
    }
  }

  void _handleFailure() {
    if (_failed) return;
    _failed = true;
    widget.onDecodeFailure?.call();
    unawaited(_effectiveProvider.evict());
    if (_retryIndex >= _retryDelays.length) return;
    final delay = _retryDelays[_retryIndex++];
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _retry);
  }

  void _retry({bool resetBudget = false}) {
    if (!mounted) return;
    if (resetBudget) _retryIndex = 0;
    _retryTimer?.cancel();
    unawaited(_effectiveProvider.evict());
    setState(() {
      _generation++;
      _failed = false;
      _frameReported = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      key: ValueKey<int>(_generation),
      image: _effectiveProvider,
      fit: widget.fit,
      gaplessPlayback: widget.gaplessPlayback,
      filterQuality: widget.filterQuality,
      errorBuilder: (_, __, ___) {
        _handleFailure();
        return SoftArtworkPlaceholder(seed: widget.seed);
      },
      frameBuilder: (context, child, frame, synchronous) {
        final ready = frame != null || synchronous;
        if (ready && !_frameReported) {
          _frameReported = true;
          _failed = false;
          widget.onFrameReady?.call();
        }
        return child;
      },
    );
  }
}
