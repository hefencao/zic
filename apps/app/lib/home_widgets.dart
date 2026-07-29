import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:flutter/material.dart';

import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'comic_details.dart' as details;

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

String _coverRequestIdentity(LibraryComic comic) {
  final sourceValue = comic.coverSourceId ??
      comic.coverChapter?.chapter.coverSourceId ??
      (comic.sourceId != 'local-folder' ||
              comic.chapters.isEmpty ||
              comic.chapters.first.chapter.pages.isEmpty
          ? null
          : comic.chapters.first.chapter.pages.first.sourceId);
  return '${comic.identity}\u0000${sourceValue ?? ''}';
}

final class ComicCoverCard extends StatelessWidget {
  const ComicCoverCard({
    required this.comic,
    required this.preference,
    required this.coverSource,
    required this.onTap,
    this.onLongPress,
    this.downloadProgress,
    this.selected = false,
    super.key,
  });

  static const double coverAspectRatio = 3 / 4;
  static const double cardWidth = 132;
  static const double cardExtent = 180;

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<EncodedResourceSource> Function() coverSource;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ComicDownloadProgress? downloadProgress;
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
  });

  final String cacheIdentity;
  final Future<EncodedResourceSource> Function() loader;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

final class _CoverImageState extends State<_CoverImage> {
  late Future<EncodedResourceSource> _source;

  @override
  void initState() {
    super.initState();
    _source = Future<EncodedResourceSource>.sync(widget.loader);
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheIdentity != widget.cacheIdentity) {
      _source = Future<EncodedResourceSource>.sync(widget.loader);
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
        return FutureBuilder<EncodedResourceSource>(
          future: _source,
          builder: (context, snapshot) {
            final source = snapshot.data;
            if (source != null) {
              final provider = encodedResourceImageProvider(source);
              return Image(
                image: ResizeImage.resizeIfNeeded(
                  cacheWidth,
                  null,
                  provider,
                ),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                frameBuilder: (context, child, frame, synchronous) =>
                    AnimatedOpacity(
                  opacity: frame != null || synchronous ? 1 : 0,
                  duration: const Duration(milliseconds: 90),
                  child: child,
                ),
              );
            }
            if (snapshot.hasError) {
              return const ColoredBox(
                color: Color(0xff20232a),
                child: Icon(Icons.broken_image_outlined, size: 38),
              );
            }
            return const ColoredBox(
              color: Color(0xff20232a),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
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

final class ComicDetailsScreen extends StatefulWidget {
  const ComicDetailsScreen({
    required this.comic,
    required this.preference,
    required this.categories,
    required this.readStates,
    required this.coverBytes,
    required this.onPreferenceChanged,
    required this.onReadChanged,
    required this.onOpenChapter,
    this.onDownloadChapter,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final List<LibraryCategory> categories;
  final Map<String, ChapterReadState> readStates;
  final Future<Uint8List> Function() coverBytes;
  final Future<void> Function(ComicPreference preference) onPreferenceChanged;
  final Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged;
  final Future<void> Function(ImportedLibraryEntry chapter) onOpenChapter;
  final Future<void> Function(ImportedLibraryEntry chapter)? onDownloadChapter;

  @override
  State<ComicDetailsScreen> createState() => _ComicDetailsScreenState();
}

final class _ComicDetailsScreenState extends State<ComicDetailsScreen> {
  late ComicPreference _preference;
  late Map<String, ChapterReadState> _readStates;

  @override
  void initState() {
    super.initState();
    _preference = widget.preference;
    _readStates = Map<String, ChapterReadState>.from(widget.readStates);
  }

  details.ComicDetailsLibrarySnapshot _snapshot() {
    return details.ComicDetailsLibrarySnapshot(
      chapters: widget.comic.chapters,
      sourceChapters: widget.comic.sourceChapters,
      readStates: _readStates,
      preference: _preference,
    );
  }

  @override
  Widget build(BuildContext context) {
    return details.LocalComicDetailsScreen(
      comic: widget.comic,
      initialLibrary: _snapshot(),
      categories: widget.categories,
      loadCover: ({
        required String sourceId,
        required String comicId,
        required Uri? coverUri,
        required ImportedLibraryEntry? fallbackChapter,
      }) =>
          widget.coverBytes(),
      reloadLibrary: ({required bool refreshContent}) async => _snapshot(),
      onPreferenceChanged: (preference) async {
        _preference = preference;
        await widget.onPreferenceChanged(preference);
      },
      onReadChanged: (chapter, isRead) async {
        final state = ChapterReadState(
          sourceId: chapter.chapter.sourceId,
          comicId: chapter.chapter.comicId,
          chapterId: chapter.chapter.chapterId,
          isRead: isRead,
          updatedAt: DateTime.now().toUtc(),
        );
        _readStates = <String, ChapterReadState>{
          ..._readStates,
          state.identity: state,
        };
        await widget.onReadChanged(chapter, isRead);
      },
      onOpenChapter: (chapter, {required bool refreshRemote}) =>
          widget.onOpenChapter(chapter),
      onDownloadChapter: widget.onDownloadChapter ?? (_) async {},
      inspectChapterDownload: (chapter) async =>
          ChapterDownloadSnapshot.idle(chapter),
      downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
      onDownloadComic: (chapters) async {
        final download = widget.onDownloadChapter;
        if (download == null) {
          return;
        }
        for (final chapter in chapters) {
          await download(chapter);
        }
      },
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
    required this.downloadProgress,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    super.key,
  });

  final LibraryComic comic;
  final ComicPreference preference;
  final Future<EncodedResourceSource> Function() coverSource;
  final ComicDownloadProgress? downloadProgress;
  final bool selected;
  final VoidCallback onTap;
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
