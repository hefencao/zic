import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';

/// Immutable cache-side binding for one Home service generation.
///
/// Download/library/queue authority lives in HomeLibrarySession. This binding
/// owns only the cache objects derived from that generation and records whether
/// Home itself must close the ResourceCacheCoordinator.
final class HomeServiceCacheBinding {
  HomeServiceCacheBinding._({
    required this.coordinator,
    required this.readerArtifactCache,
    required this.ownsCoordinator,
  });

  factory HomeServiceCacheBinding.create({
    required ChapterDownloadService chapterDownloads,
    required ChapterDownloadTransferRuntimeProvider? downloadComposition,
    ResourceCacheCoordinator? suppliedCoordinator,
  }) {
    final readerArtifactCache = downloadComposition?.artifactCacheManager ??
        (chapterDownloads is ArtifactCacheBackend
            ? ArtifactCacheManager(
                backend: chapterDownloads as ArtifactCacheBackend,
              )
            : null);
    final ownsCoordinator = suppliedCoordinator == null;
    final coordinator = suppliedCoordinator ??
        ResourceCacheCoordinator(
          artifacts: downloadComposition?.artifactStore ??
              (chapterDownloads is ArtifactCacheMaintenance
                  ? chapterDownloads as ArtifactCacheMaintenance
                  : null),
        );
    return HomeServiceCacheBinding._(
      coordinator: coordinator,
      readerArtifactCache: readerArtifactCache,
      ownsCoordinator: ownsCoordinator,
    );
  }

  final ResourceCacheCoordinator coordinator;
  final ArtifactCacheManager? readerArtifactCache;
  final bool ownsCoordinator;

  Future<void> closeIfOwned() async {
    if (ownsCoordinator) {
      await coordinator.close();
    }
  }

  Future<void> closeIfSupersededBy(HomeServiceCacheBinding next) async {
    if (!ownsCoordinator || identical(coordinator, next.coordinator)) {
      return;
    }
    if (identical(coordinator.responses, next.coordinator.responses)) {
      return;
    }
    await coordinator.close();
  }
}
