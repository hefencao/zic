import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:downloads/downloads.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:resource_cache/resource_cache.dart';

import 'home_external_source_lifecycle.dart';
import 'home_library_session.dart';
import 'home_service_cache_binding.dart';
import 'home_source_projection.dart';
import 'source_resource_gateway.dart';

/// Owns Home's durable-service generation adoption single-flight.
///
/// [HomeLibrarySession] remains the service authority. This coordinator only
/// sequences a published handoff into that owner, keeps the cache binding on
/// the same adopted generation, and reconnects source/resource projections.
/// It deliberately has no Flutter presentation or navigation dependency.
final class HomeServiceAdoptionCoordinator {
  HomeServiceAdoptionCoordinator({
    required this.session,
    required this.sourceResources,
    required this.sourceProjection,
    required this.externalSources,
    required HomeServiceCacheBinding initialCacheBinding,
    required this.libraryProvider,
    required this.chapterDownloadsProvider,
    required this.downloadCompositionProvider,
    required this.wholeComicDownloadsProvider,
    required this.cacheCoordinatorProvider,
    required this.externalPluginsProvider,
    required this.externalPluginLoaderAvailable,
    required this.persistSnapshotProvider,
    required this.refreshStaleChapter,
    required this.onAdopted,
    required this.reportError,
  }) : _cacheBinding = initialCacheBinding;

  final HomeLibrarySession session;
  final ComicSourceResourceGateway sourceResources;
  final HomeSourceProjection sourceProjection;
  final HomeExternalSourceLifecycle externalSources;
  final ImportedLibraryStore? Function() libraryProvider;
  final ChapterDownloadService? Function() chapterDownloadsProvider;
  final ChapterDownloadTransferRuntimeProvider? Function()
      downloadCompositionProvider;
  final WholeComicDownloadQueue? Function() wholeComicDownloadsProvider;
  final ResourceCacheCoordinator? Function() cacheCoordinatorProvider;
  final ExternalPluginController? Function() externalPluginsProvider;
  final bool Function() externalPluginLoaderAvailable;
  final bool Function() persistSnapshotProvider;
  final Future<ImportedLibraryEntry?> Function(ImportedLibraryEntry entry)
      refreshStaleChapter;
  final void Function() onAdopted;
  final void Function(String stage, Object error) reportError;

  HomeServiceCacheBinding _cacheBinding;
  Future<void>? _adoption;
  bool _closing = false;

  ArtifactCacheManager? get readerArtifactCache =>
      _cacheBinding.readerArtifactCache;

  ResourceCacheCoordinator get cacheCoordinator => _cacheBinding.coordinator;

  Future<void>? get activeAdoption => _adoption;

  bool get closing => _closing;

  bool needsCurrentAdoption() {
    if (_closing) return false;
    final library = libraryProvider();
    final chapterDownloads = chapterDownloadsProvider();
    final wholeComicDownloads = wholeComicDownloadsProvider();
    if (library == null ||
        chapterDownloads == null ||
        wholeComicDownloads == null) {
      return false;
    }
    final downloadComposition = HomeLibrarySession.resolveDownloadComposition(
      chapterDownloads,
      downloadCompositionProvider(),
    );
    final suppliedCache = cacheCoordinatorProvider();
    return !identical(library, session.library) ||
        !identical(chapterDownloads, session.chapterDownloads) ||
        !identical(downloadComposition, session.downloadComposition) ||
        !identical(wholeComicDownloads, session.wholeComicDownloads) ||
        (suppliedCache != null &&
            !identical(suppliedCache, cacheCoordinator));
  }

  void startCurrentAdoption() {
    if (_closing || !needsCurrentAdoption()) return;
    unawaited(adoptCurrent().catchError((Object error) {
      reportError('durable Home service handoff', error);
    }));
  }

  Future<void> adoptCurrent() {
    if (_closing) {
      return Future<void>.error(
        StateError('Home service adoption is closing'),
      );
    }
    final existing = _adoption;
    if (existing != null) return existing;

    final library = libraryProvider();
    final downloads = chapterDownloadsProvider();
    final composition = downloadCompositionProvider();
    final queue = wholeComicDownloadsProvider();
    final cache = cacheCoordinatorProvider();
    var succeeded = false;
    late final Future<void> adoption;
    adoption = _adoptCurrentOnce().then((_) {
      succeeded = true;
    }).whenComplete(() {
      if (!identical(_adoption, adoption)) return;
      _adoption = null;
      final superseded = !identical(library, libraryProvider()) ||
          !identical(downloads, chapterDownloadsProvider()) ||
          !identical(composition, downloadCompositionProvider()) ||
          !identical(queue, wholeComicDownloadsProvider()) ||
          !identical(cache, cacheCoordinatorProvider());
      if (!_closing &&
          (succeeded || superseded) &&
          needsCurrentAdoption()) {
        startCurrentAdoption();
      }
    });
    _adoption = adoption;
    return adoption;
  }

  Future<void> _adoptCurrentOnce() async {
    final library = libraryProvider();
    final chapterDownloads = chapterDownloadsProvider();
    final wholeComicDownloads = wholeComicDownloadsProvider();
    if (library == null ||
        chapterDownloads == null ||
        wholeComicDownloads == null ||
        !needsCurrentAdoption()) {
      return;
    }

    final previousChapterDownloads = session.chapterDownloads;
    final previousCacheBinding = _cacheBinding;
    final downloadComposition = HomeLibrarySession.resolveDownloadComposition(
      chapterDownloads,
      downloadCompositionProvider(),
    );
    final candidateCacheBinding = HomeServiceCacheBinding.create(
      chapterDownloads: chapterDownloads,
      downloadComposition: downloadComposition,
      suppliedCoordinator: cacheCoordinatorProvider(),
    );
    final nextCacheCoordinator = candidateCacheBinding.coordinator;
    final externalPlugins =
        externalPluginsProvider() ?? externalSources.activeController;
    final activeExternalSources =
        externalPlugins?.activeSources ?? const <BrowsableComicSource>[];
    final sources = sourceProjection.composeForServices(
      nextCacheCoordinator,
      externalSources: activeExternalSources,
    );

    wholeComicDownloads.refreshStaleChapter = refreshStaleChapter;
    Object? adoptionError;
    StackTrace? adoptionStack;
    try {
      await session.adoptServices(
        library: library,
        chapterDownloads: chapterDownloads,
        downloadComposition: downloadComposition,
        wholeComicDownloads: wholeComicDownloads,
        sources: sources,
        persistSnapshot: persistSnapshotProvider(),
      );
    } on Object catch (error, stack) {
      adoptionError = error;
      adoptionStack = stack;
    }

    final sessionAdopted =
        identical(session.library, library) &&
        identical(session.chapterDownloads, chapterDownloads) &&
        identical(session.downloadComposition, downloadComposition) &&
        identical(session.wholeComicDownloads, wholeComicDownloads);
    if (!sessionAdopted) {
      await candidateCacheBinding.closeIfOwned();
      if (adoptionError != null) {
        Error.throwWithStackTrace(adoptionError, adoptionStack!);
      }
      throw StateError('Home service authority was not adopted');
    }
    if (adoptionError != null) {
      reportError(
        'durable Home service handoff reconciled after adoption error',
        adoptionError,
      );
    }

    sourceResources.unbindFrom(previousChapterDownloads);
    sourceResources.bindTo(session.chapterDownloads);
    _cacheBinding = candidateCacheBinding;
    sourceProjection.adoptServiceProjection(
      sources,
      cache: nextCacheCoordinator,
      externalSources: activeExternalSources,
    );
    onAdopted();
    await previousCacheBinding.closeIfSupersededBy(candidateCacheBinding);

    if (externalSources.activeController != null ||
        externalPluginLoaderAvailable()) {
      externalSources.signalLoaderAvailable();
    }
    if (adoptionError != null) {
      Error.throwWithStackTrace(adoptionError, adoptionStack!);
    }
  }

  void beginClose() {
    _closing = true;
  }

  Future<void> closeCacheIfOwned() => _cacheBinding.closeIfOwned();
}
