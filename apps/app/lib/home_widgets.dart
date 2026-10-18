import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';

import 'artwork_placeholder.dart';

enum ComicDownloadProgressKind { active, chapterComplete, comicComplete }

final class ComicDownloadProgress {
  const ComicDownloadProgress.active({
    required this.label,
    required double completedPageUnits,
    required this.totalPages,
  })  : kind = ComicDownloadProgressKind.active,
        completedPageUnits = completedPageUnits,
        assert(completedPageUnits >= 0),
        assert(totalPages > 0);

  const ComicDownloadProgress.chapterComplete({
    this.label = '单章节下载完成',
  })  : kind = ComicDownloadProgressKind.chapterComplete,
        completedPageUnits = 0,
        totalPages = 0;

  const ComicDownloadProgress.comicComplete({
    this.label = '整本下载完成',
  })  : kind = ComicDownloadProgressKind.comicComplete,
        completedPageUnits = 0,
        totalPages = 0;

  final ComicDownloadProgressKind kind;
  final String label;
  final double completedPageUnits;
  final int totalPages;

  bool get isActive => kind == ComicDownloadProgressKind.active;

  int get completedPages => completedPageUnits.floor();

  double get fraction => isActive
      ? (completedPageUnits / totalPages).clamp(0, 1).toDouble()
      : 1;
}

final class ComicCoverCard extends StatelessWidget {
  const ComicCoverCard({
    required this.comic,
    required this.preference,
    required this.coverSource,
    required this.coverIdentity,
    required this.onTap,
    this.coverPlaceholderSource,
    this.sourceAvailable = true,
    this.telemetryIdentity,
    this.interactionKey,
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
  final Future<EncodedResourceSource?> Function()? coverPlaceholderSource;
  final String coverIdentity;
  final bool sourceAvailable;
  final String? telemetryIdentity;
  final Key? interactionKey;
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
          child: AspectRatio(
            aspectRatio: coverAspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _CoverImage(
                  cacheIdentity: coverIdentity,
                  telemetryIdentity: telemetryIdentity ?? coverIdentity,
                  sourceAvailable: sourceAvailable,
                  loader: coverSource,
                  placeholderLoader: coverPlaceholderSource,
                  startupTelemetry: startupTelemetry,
                ),
                // Navigation identity may change while canonical artwork stays.
                InkWell(
                  key: interactionKey,
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
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
              ],
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
    required this.telemetryIdentity,
    required this.sourceAvailable,
    required this.loader,
    this.placeholderLoader,
    this.startupTelemetry,
  });

  final String cacheIdentity;
  final String telemetryIdentity;
  final bool sourceAvailable;
  final Future<EncodedResourceSource> Function() loader;
  final Future<EncodedResourceSource?> Function()? placeholderLoader;
  final HomeStartupTelemetry? startupTelemetry;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

final class _CoverImageState extends State<_CoverImage> {
  late Future<EncodedResourceSource> _source;
  Future<EncodedResourceSource?>? _placeholderSource;
  bool _reportedFirstFrame = false;
  bool _placeholderPresented = false;
  bool _placeholderTransitionScheduled = false;
  bool _finalFrameReported = false;
  bool _sourceFailed = false;
  int _loadGeneration = 0;
  HomeStartupTelemetry? _loadTelemetry;
  String? _loadTelemetryIdentity;

  @override
  void initState() {
    super.initState();
    _source = _loadSource();
    _placeholderSource = _loadPlaceholderSource();
  }

  Future<EncodedResourceSource?>? _loadPlaceholderSource() {
    final loader = widget.placeholderLoader;
    if (loader == null) return null;
    return () async {
      try {
        final source = await loader();
        if (source != null) {
          widget.startupTelemetry?.coverSourceReady(
            widget.telemetryIdentity,
            source: source.origin.name,
            byteLength: source.lengthInBytes,
            presentationStage: 'placeholder',
          );
        }
        return source;
      } on Object {
        // This is a presentation acceleration only. The authoritative cover
        // source continues independently and owns visible failure semantics.
        return null;
      }
    }();
  }

  Future<EncodedResourceSource> _loadSource() async {
    final generation = ++_loadGeneration;
    final sourceAvailableAtStart = widget.sourceAvailable;
    final telemetry = widget.startupTelemetry;
    final telemetryIdentity = widget.telemetryIdentity;
    _sourceFailed = false;
    _loadTelemetry = telemetry;
    _loadTelemetryIdentity = telemetryIdentity;
    telemetry?.coverRequested(telemetryIdentity);
    try {
      final source = await widget.loader();
      telemetry?.coverSourceReady(
        telemetryIdentity,
        source: source.origin.name,
        byteLength: source.lengthInBytes,
        presentationStage: 'final',
      );
      return source;
    } on Object catch (error) {
      if (generation == _loadGeneration) {
        _sourceFailed = true;
      }
      telemetry?.coverSourceFailed(
        telemetryIdentity,
        errorType: error.runtimeType.toString(),
        sourceAvailable: sourceAvailableAtStart,
      );
      rethrow;
    }
  }

  void _reportFirstFrame() {
    if (_reportedFirstFrame) return;
    _reportedFirstFrame = true;
    final identity = _loadTelemetryIdentity;
    if (identity != null) {
      _loadTelemetry?.coverFirstFrame(identity);
    }
  }

  void _reportPlaceholderFrame() {
    _reportFirstFrame();
    if (_placeholderPresented || _placeholderTransitionScheduled) return;
    _placeholderTransitionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _placeholderPresented = true;
        _placeholderTransitionScheduled = false;
      });
    });
  }

  void _reportFinalFrame() {
    _finalFrameReported = true;
    _reportFirstFrame();
  }

  void _reportDecodeFailure() {
    final identity = _loadTelemetryIdentity;
    if (identity != null) {
      _loadTelemetry?.coverDecodeFailed(identity);
    }
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cacheChanged = oldWidget.cacheIdentity != widget.cacheIdentity;
    final sourceBecameAvailable =
        !oldWidget.sourceAvailable && widget.sourceAvailable;
    if (cacheChanged || (_sourceFailed && sourceBecameAvailable)) {
      _reportedFirstFrame = false;
      _placeholderPresented = false;
      _placeholderTransitionScheduled = false;
      _finalFrameReported = false;
      _source = _loadSource();
      if (cacheChanged) {
        _placeholderSource = _loadPlaceholderSource();
      }
    }
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
        Widget artwork(
          EncodedResourceSource source, {
          required VoidCallback onFrameReady,
        }) =>
            StableArtworkImage(
              source: source,
              seed: widget.cacheIdentity,
              cacheWidth: cacheWidth,
              fit: BoxFit.cover,
              onFrameReady: onFrameReady,
              onDecodeFailure: _reportDecodeFailure,
            );
        return FutureBuilder<EncodedResourceSource>(
          future: _source,
          builder: (context, snapshot) {
            final source = snapshot.data;
            final placeholderSource = _placeholderSource;
            if (placeholderSource == null) {
              return source == null
                  ? SoftArtworkPlaceholder(seed: widget.cacheIdentity)
                  : artwork(source, onFrameReady: _reportFinalFrame);
            }
            return FutureBuilder<EncodedResourceSource?>(
              future: placeholderSource,
              builder: (context, placeholderSnapshot) {
                final placeholder = placeholderSnapshot.data;
                if (placeholder != null &&
                    !_placeholderPresented &&
                    !_finalFrameReported) {
                  return artwork(
                    placeholder,
                    onFrameReady: _reportPlaceholderFrame,
                  );
                }
                if (source != null) {
                  return artwork(source, onFrameReady: _reportFinalFrame);
                }
                return placeholder == null
                    ? SoftArtworkPlaceholder(seed: widget.cacheIdentity)
                    : artwork(
                        placeholder,
                        onFrameReady: _reportPlaceholderFrame,
                      );
              },
            );
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
      final wholeComic =
          progress.kind == ComicDownloadProgressKind.comicComplete;
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
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  wholeComic ? Icons.check_circle : Icons.check_circle_outline,
                  size: 16,
                  color: wholeComic ? Colors.green : Colors.white,
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
    required this.coverIdentity,
    required this.downloadProgress,
    this.coverPlaceholderSource,
    required this.selected,
    required this.onTap,
    this.sourceAvailable = true,
    this.startupTelemetry,
    this.onLongPress,
    this.trailing,
    this.interactionKey,
    this.telemetryIdentity,
    this.subtitle,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<EncodedResourceSource> Function() coverSource;
  final Future<EncodedResourceSource?> Function()? coverPlaceholderSource;
  final String coverIdentity;
  final bool sourceAvailable;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;
  final VoidCallback onTap;
  final HomeStartupTelemetry? startupTelemetry;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Key? interactionKey;
  final String? telemetryIdentity;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle ?? (comic.hasMultipleChapters
        ? '${comic.chapters.length} 章 · ${comic.totalPages} 页'
        : '${comic.totalPages} 页');
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        key: interactionKey,
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
                    cacheIdentity: coverIdentity,
                    telemetryIdentity: telemetryIdentity ?? coverIdentity,
                    sourceAvailable: sourceAvailable,
                    loader: coverSource,
                    placeholderLoader: coverPlaceholderSource,
                    startupTelemetry: startupTelemetry,
                  ),
                  if (downloadProgress != null)
                    _DownloadWatermark(progress: downloadProgress!),
                ],
              ),
            ),
          ),
        ),
        title: Text(comic.title, maxLines: this.subtitle == null ? null : 2,
          overflow: this.subtitle == null ? null : TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: this.subtitle == null ? null : 2,
          overflow: this.subtitle == null ? null : TextOverflow.ellipsis),
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
  const HomeSectionTitle({required this.title, this.subtitle, this.trailing, super.key});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (subtitle != null)
          Flexible(child: Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)),
        ?trailing,
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
