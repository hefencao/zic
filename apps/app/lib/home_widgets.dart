import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'artwork_placeholder.dart';

enum ComicDownloadProgressKind { active, offline }

final class ComicDownloadProgress {
  const ComicDownloadProgress.active({
    required this.label,
    required double completedPageUnits,
    required this.totalPages,
  })  : kind = ComicDownloadProgressKind.active,
        completedPageUnits = completedPageUnits,
        offlineChapters = 0,
        assert(completedPageUnits >= 0),
        assert(totalPages > 0);

  const ComicDownloadProgress.offline({
    required this.label,
    required this.offlineChapters,
  })  : kind = ComicDownloadProgressKind.offline,
        completedPageUnits = 0,
        totalPages = 0,
        assert(offlineChapters > 0);

  final ComicDownloadProgressKind kind;
  final String label;
  final double completedPageUnits;
  final int totalPages;
  final int offlineChapters;

  bool get isActive => kind == ComicDownloadProgressKind.active;

  int get completedPages => completedPageUnits.floor();

  double get fraction => isActive
      ? (completedPageUnits / totalPages).clamp(0, 1).toDouble()
      : 1;
}

String _coverRequestIdentity(LibraryComic comic) => comic.identity;

final class ComicCoverCard extends StatelessWidget {
  const ComicCoverCard({
    required this.comic,
    required this.preference,
    required this.coverSource,
    required this.onTap,
    this.recoveryCoverSource,
    this.onLongPress,
    this.downloadProgress,
    this.startupTelemetry,
    this.selected = false,
    super.key,
  });

  static const double coverAspectRatio = 3 / 4;
  static const double cardWidth = 132;
  static const double cardExtent = 180;

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<EncodedResourceSource> Function() coverSource;
  final Future<EncodedResourceSource> Function()? recoveryCoverSource;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ComicDownloadProgress? downloadProgress;
  final HomeStartupTelemetry? startupTelemetry;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      selected: selected,
      label: '${comic.title}，来源 ${comic.sourceId}',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: AspectRatio(
              aspectRatio: coverAspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _CoverImage(
                    cacheIdentity: _coverRequestIdentity(comic),
                    loader: coverSource,
                    recoveryLoader: recoveryCoverSource,
                    startupTelemetry: startupTelemetry,
                  ),
                  if (downloadProgress != null)
                    _DownloadWatermark(progress: downloadProgress!),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: _CoverTitleGradient(),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      comic.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.12,
                        fontWeight: FontWeight.w700,
                        shadows: <Shadow>[
                          Shadow(blurRadius: 3, color: Colors.black),
                        ],
                      ),
                    ),
                  ),
                  if (preference.liked || preference.collected)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(
                            preference.collected
                                ? Icons.bookmark
                                : Icons.favorite,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _CoverTitleGradient extends StatelessWidget {
  const _CoverTitleGradient();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: 78,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.transparent,
                Colors.black.withValues(alpha: 0.78),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _CoverImage extends StatefulWidget {
  const _CoverImage({
    required this.cacheIdentity,
    required this.loader,
    this.recoveryLoader,
    this.startupTelemetry,
  });

  final String cacheIdentity;
  final Future<EncodedResourceSource> Function() loader;
  final Future<EncodedResourceSource> Function()? recoveryLoader;
  final HomeStartupTelemetry? startupTelemetry;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

final class _CoverImageState extends State<_CoverImage>
    with WidgetsBindingObserver {
  late Future<EncodedResourceSource> _source;
  bool _reportedFirstFrame = false;
  bool _loadFailed = false;
  bool _recoveringEncodedSource = false;
  bool _encodedRecoveryAttempted = false;
  int _decodeRecoveryGeneration = 0;
  static const _firstFrameTimeout = Duration(milliseconds: 2500);

  final ArtworkRetryController _retry = ArtworkRetryController();
  Timer? _firstFrameWatchdog;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLoad();
  }

  void _startLoad({
    bool resetRetryBudget = false,
    bool preserveFailurePlaceholder = false,
  }) {
    if (resetRetryBudget) _retry.reset();
    _reportedFirstFrame = false;
    if (!preserveFailurePlaceholder) _loadFailed = false;
    widget.startupTelemetry?.coverRequested(widget.cacheIdentity);
    _source = _loadSource();
  }

  Future<EncodedResourceSource> _loadSource() async {
    try {
      final source = await widget.loader();
      widget.startupTelemetry?.coverSourceReady(
        widget.cacheIdentity,
        source: source.origin.name,
        byteLength: source.lengthInBytes,
      );
      _scheduleFirstFrameWatchdog();
      return source;
    } on Object {
      _loadFailed = true;
      _retry.schedule(_restartLoad);
      rethrow;
    }
  }

  void _scheduleFirstFrameWatchdog() {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = Timer(_firstFrameTimeout, () {
      if (!mounted || _reportedFirstFrame) return;
      _loadFailed = true;
      final recoveryLoader = widget.recoveryLoader;
      if (recoveryLoader != null) {
        unawaited(_recoverEncodedSource());
      } else {
        _restartLoadWithReset();
      }
    });
  }

  void _reportFirstFrame() {
    if (_reportedFirstFrame) {
      return;
    }
    _firstFrameWatchdog?.cancel();
    _reportedFirstFrame = true;
    _loadFailed = false;
    _encodedRecoveryAttempted = false;
    _retry.reset();
    widget.startupTelemetry?.coverFirstFrame(widget.cacheIdentity);
  }

  void _restartLoad() {
    if (!mounted) return;
    _firstFrameWatchdog?.cancel();
    setState(() => _startLoad(preserveFailurePlaceholder: true));
  }

  Future<void> _recoverEncodedSource() async {
    final recoveryLoader = widget.recoveryLoader;
    if (recoveryLoader == null ||
        _recoveringEncodedSource ||
        _encodedRecoveryAttempted) {
      return;
    }
    _recoveringEncodedSource = true;
    _encodedRecoveryAttempted = true;
    widget.startupTelemetry?.coverRequested(widget.cacheIdentity);
    try {
      final source = await recoveryLoader();
      widget.startupTelemetry?.coverSourceReady(
        widget.cacheIdentity,
        source: source.origin.name,
        byteLength: source.lengthInBytes,
      );
      if (!mounted) return;
      setState(() {
        _source = Future<EncodedResourceSource>.value(source);
        _reportedFirstFrame = false;
        _loadFailed = true;
        _decodeRecoveryGeneration++;
      });
      _scheduleFirstFrameWatchdog();
    } on Object {
      _loadFailed = true;
    } finally {
      _recoveringEncodedSource = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _loadFailed) {
      _encodedRecoveryAttempted = false;
      _retry.retryNow(
        () => _restartLoadWithReset(),
        resetBudget: true,
      );
    }
  }

  void _restartLoadWithReset() {
    if (!mounted) return;
    setState(() => _startLoad(resetRetryBudget: true));
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheIdentity != widget.cacheIdentity) {
      _encodedRecoveryAttempted = false;
      _startLoad(resetRetryBudget: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _firstFrameWatchdog?.cancel();
    _retry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : ComicCoverCard.cardWidth;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth = (logicalWidth * devicePixelRatio)
            .ceil()
            .clamp(64, 512)
            .toInt();
        return FutureBuilder<EncodedResourceSource>(
          future: _source,
          builder: (context, snapshot) {
            final source = snapshot.data;
            if (source != null) {
              final provider = encodedResourceImageProvider(source);
              return RecoverableArtworkImage(
                key: ValueKey<String>(
                  '${widget.cacheIdentity}:$_decodeRecoveryGeneration',
                ),
                image: provider,
                seed: widget.cacheIdentity,
                cacheWidth: cacheWidth,
                fit: BoxFit.cover,
                onFrameReady: _reportFirstFrame,
                onDecodeFailure: () {
                  _loadFailed = true;
                },
                onRecoveryExhausted: () => unawaited(
                  _recoverEncodedSource(),
                ),
              );
            }
            if (snapshot.hasError) {
              return SoftArtworkPlaceholder(
                seed: widget.cacheIdentity,
              );
            }
            return SoftArtworkPlaceholder(seed: widget.cacheIdentity);
          },
        );
      },
    );
  }
}

final class _DownloadWatermark extends StatelessWidget {
  const _DownloadWatermark({required this.progress});

  final ComicDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    if (!progress.isActive) {
      return Semantics(
        label: progress.label,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(
                  Icons.download_done,
                  size: 15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
    }
    final percent = (progress.fraction * 100).round();
    return Semantics(
      label: '${progress.label}，$percent%，'
          '${progress.completedPages}/${progress.totalPages} 页',
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: progress.fraction,
              widthFactor: 1,
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.44),
              ),
            ),
          ),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.68),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  '${progress.label}\n$percent% · '
                  '${progress.completedPages}/${progress.totalPages} 页',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class CoverActionSurface extends StatelessWidget {
  const CoverActionSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.68),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconTheme(
        data: const IconThemeData(color: Colors.white, size: 20),
        child: SizedBox.square(dimension: 40, child: Center(child: child)),
      ),
    );
  }
}

final class ShelfListTile extends StatelessWidget {
  const ShelfListTile({
    required this.comic,
    required this.preference,
    required this.coverSource,
    this.recoveryCoverSource,
    required this.downloadProgress,
    required this.selected,
    required this.onTap,
    this.startupTelemetry,
    this.onLongPress,
    this.trailing,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<EncodedResourceSource> Function() coverSource;
  final Future<EncodedResourceSource> Function()? recoveryCoverSource;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;
  final VoidCallback onTap;
  final HomeStartupTelemetry? startupTelemetry;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final subtitle = comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页';
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: SizedBox(
          width: 48,
          child: AspectRatio(
            aspectRatio: ComicCoverCard.coverAspectRatio,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _CoverImage(
                    cacheIdentity: _coverRequestIdentity(comic),
                    loader: coverSource,
                    recoveryLoader: recoveryCoverSource,
                    startupTelemetry: startupTelemetry,
                  ),
                  if (downloadProgress != null)
                    _DownloadWatermark(progress: downloadProgress!),
                ],
              ),
            ),
          ),
        ),
        title: Text(comic.title),
        subtitle: Text(subtitle),
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: trailing ??
            (selected
                ? Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null),
      ),
    );
  }
}

final class HomeSectionTitle extends StatelessWidget {
  const HomeSectionTitle({required this.title, this.subtitle, super.key});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (subtitle != null)
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

final class HomeActionCard extends StatelessWidget {
  const HomeActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, size: 34),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: trailing ?? const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
