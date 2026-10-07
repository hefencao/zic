import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:local_media_ui/local_media_ui.dart';
import 'package:telemetry/telemetry.dart';

import 'source_resource_gateway.dart';

typedef HomeReaderEntryHydrator = Future<ImportedLibraryEntry> Function(
  ImportedLibraryEntry entry, {
  required bool awaitCanonicalPhysicalBackfill,
});

typedef HomeReaderRemoteEntryRefresher = Future<ImportedLibraryEntry> Function(
  ImportedLibraryEntry entry, {
  required bool forceSourceRefresh,
});

typedef HomeReaderVersionAuthorityPreparer = Future<int> Function(
  ImportedLibraryEntry entry,
);

enum HomeReaderChapterEntry { firstPage, lastPage }

/// Projects the current comic family without materializing unrelated catalogs.
/// Canonical authority is read afresh per query; its memo lives only here.
LibraryComic? homeReaderComicForChapter({
  required ImportedLibraryEntry current,
  required Iterable<ImportedLibraryEntry> entries,
  required Iterable<SavedComicRecord> savedComics,
  required String Function(String sourceId, String comicId) canonicalIdentity,
}) {
  final sourceId = current.chapter.sourceId;
  final comicId = current.chapter.comicId;
  final sourceEntries = entries
      .where((entry) => entry.chapter.sourceId == sourceId)
      .toList(growable: false);
  final sourceComics = savedComics
      .where((comic) => comic.sourceId == sourceId)
      .toList(growable: false);
  if (!sourceEntries.any((entry) => entry.chapter.comicId == comicId) &&
      !sourceComics.any((comic) => comic.comicId == comicId)) {
    return null;
  }
  final canonicalByRawId = <String, String>{};
  String canonical(String id) => canonicalByRawId.putIfAbsent(
        id,
        () => canonicalIdentity(sourceId, id),
      );
  final target = canonical(comicId);
  final comics = collapseCanonicalLibraryComics(
    aggregateImportedLibrary(
      sourceEntries.where(
        (entry) => canonical(entry.chapter.comicId) == target,
      ),
      savedComics: sourceComics.where(
        (comic) => canonical(comic.comicId) == target,
      ),
    ),
    canonicalIdentity: (_, id) => canonical(id),
  );
  for (final comic in comics) {
    if (comic.sourceId == current.chapter.sourceId &&
        comic.comicId == current.chapter.comicId) {
      return comic;
    }
  }
  return null;
}

Future<T?> homeReaderCoalesceSuccessfulAdjacentPreparation<T>({
  required Map<String, Future<T?>> cache,
  required String key,
  required Future<T?> Function() prepare,
}) {
  final existing = cache[key];
  if (existing != null) return existing;
  late final Future<T?> preparation;
  preparation = prepare();
  cache[key] = preparation;
  unawaited(
    preparation.then<void>(
      (prepared) {
        if (prepared == null && identical(cache[key], preparation)) {
          cache.remove(key);
        }
      },
      onError: (Object _, StackTrace __) {
        if (identical(cache[key], preparation)) {
          cache.remove(key);
        }
      },
    ),
  );
  return preparation;
}

int homeReaderChapterIndex<T>(
  List<T> chapters, {
  required String chapterId,
  required String Function(T chapter) chapterIdOf,
  required String? Function(String chapterId) comparisonKeyOf,
}) {
  final exact = chapters.indexWhere((chapter) => chapterIdOf(chapter) == chapterId);
  if (exact >= 0) return exact;
  final key = comparisonKeyOf(chapterId);
  if (key == null) return -1;
  var match = -1;
  for (var index = 0; index < chapters.length; index++) {
    if (comparisonKeyOf(chapterIdOf(chapters[index])) != key) continue;
    if (match >= 0) return -1;
    match = index;
  }
  return match;
}

List<T> homeReaderLogicalChapterOrder<T>(
  Iterable<T> chapters, {
  required int Function(T chapter) sequenceOf,
}) {
  final indexed = <({T chapter, int sequence, int sourceOrder})>[];
  var sourceOrder = 0;
  for (final chapter in chapters) {
    indexed.add((
      chapter: chapter,
      sequence: sequenceOf(chapter),
      sourceOrder: sourceOrder++,
    ));
  }
  indexed.sort((left, right) {
    final bySequence = left.sequence.compareTo(right.sequence);
    if (bySequence != 0) return bySequence;
    return left.sourceOrder.compareTo(right.sourceOrder);
  });
  return <T>[for (final item in indexed) item.chapter];
}

({int previous, int next, int displayedIndex}) homeReaderAdjacentPreloadResidual({
  required int pageCount,
  required int rawPageIndex,
  required bool inverted,
  required int forwardEncodedPages,
  required int backwardEncodedPages,
}) {
  if (pageCount <= 0) return (previous: 0, next: 0, displayedIndex: 0);
  final raw = rawPageIndex.clamp(0, pageCount - 1).toInt();
  final displayedIndex = inverted ? pageCount - 1 - raw : raw;
  return (
    previous: (backwardEncodedPages - displayedIndex)
        .clamp(0, backwardEncodedPages)
        .toInt(),
    next: (forwardEncodedPages - (pageCount - 1 - displayedIndex))
        .clamp(0, forwardEncodedPages)
        .toInt(),
    displayedIndex: displayedIndex,
  );
}

/// Prepared, immutable input handed from App composition to the Reader route.
///
/// This contains no navigation or widget state. Transport/session ownership
/// remains in the injected composition owners; Reader receives only the
/// response capabilities for this exact prepared chapter generation.
final class HomeReaderPreparedChapter {
  const HomeReaderPreparedChapter({
    required this.entry,
    required this.byteLoaders,
    required this.responseSources,
    required this.initialPageIndex,
  });

  final ImportedLibraryEntry entry;
  final Map<String, LocalImageFileBytesLoader> byteLoaders;
  final Map<String, LocalImageResponseSource> responseSources;
  final int? initialPageIndex;
}

/// App-composition owner for the Reader chapter preparation chain.
///
/// The Home widget owns navigation and presentation only. This collaborator
/// owns the durable-service handoff -> hydrate -> source-authority refresh ->
/// version-authority wait ->
/// response-capability projection sequence so those concerns cannot reach
/// arbitrary Home widget fields through a `part` extension.
final class HomeReaderChapterComposition {
  HomeReaderChapterComposition({
    required Future<void> Function() ensureDurableServices,
    required HomeReaderEntryHydrator hydrateEntry,
    required ComicSourceResourceGateway sourceResources,
    required ChapterDownloadTransferRuntimeProvider? Function()
        downloadComposition,
    required bool Function(ImportedChapterRecord chapter)
        requiresSourceLocatorRefresh,
    required HomeReaderRemoteEntryRefresher refreshRemoteEntry,
    required HomeReaderVersionAuthorityPreparer prepareVersionAuthority,
    required TraceSink trace,
    required int Function() monotonicMicros,
  })  : _ensureDurableServices = ensureDurableServices,
        _hydrateEntry = hydrateEntry,
        _sourceResources = sourceResources,
        _downloadComposition = downloadComposition,
        _requiresSourceLocatorRefresh = requiresSourceLocatorRefresh,
        _refreshRemoteEntry = refreshRemoteEntry,
        _prepareVersionAuthority = prepareVersionAuthority,
        _trace = trace,
        _monotonicMicros = monotonicMicros;

  final Future<void> Function() _ensureDurableServices;
  final HomeReaderEntryHydrator _hydrateEntry;
  final ComicSourceResourceGateway _sourceResources;
  final ChapterDownloadTransferRuntimeProvider? Function()
      _downloadComposition;
  final bool Function(ImportedChapterRecord chapter)
      _requiresSourceLocatorRefresh;
  final HomeReaderRemoteEntryRefresher _refreshRemoteEntry;
  final HomeReaderVersionAuthorityPreparer _prepareVersionAuthority;
  final TraceSink _trace;
  final int Function() _monotonicMicros;
  final Set<Future<dynamic>> _activePreparations = <Future<dynamic>>{};
  bool _closed = false;
  Future<void>? _closing;

  Future<T> _trackPreparation<T>(Future<T> preparation) {
    _activePreparations.add(preparation);
    unawaited(
      preparation.then<void>(
        (_) => _activePreparations.remove(preparation),
        onError: (Object _, StackTrace _) {
          _activePreparations.remove(preparation);
        },
      ),
    );
    return preparation;
  }

  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    if (_closed) return Future<void>.value();
    _closed = true;
    late final Future<void> closing;
    closing = _close();
    _closing = closing;
    return closing;
  }

  Future<void> _close() async {
    while (_activePreparations.isNotEmpty) {
      final pending = _activePreparations.toList(growable: false);
      for (final preparation in pending) {
        try {
          await preparation;
        } on Object {
          // The DeferredReaderRoute owns presentation of preparation errors.
          // Teardown only joins admitted work before its dependencies close.
        }
      }
    }
  }

  Map<String, LocalImageResponseSource> responseSourcesFor(
    ChapterManifest readerManifest,
    Map<String, LocalImageFileBytesLoader> byteLoaders,
  ) =>
      readerManifest.sourceId == 'local-folder'
          ? const <String, LocalImageResponseSource>{}
          : <String, LocalImageResponseSource>{
              for (final page in readerManifest.pages)
                if (!byteLoaders.containsKey(page.uri.toString()))
                  page.uri.toString(): LocalImageResponseSource(
                    openControlledResponse: _sourceResources
                        .observedPageControlledResponseLoaderFor(
                      readerManifest,
                      page,
                    ),
                    selfBoundedOpen: _sourceResources.pageOpenSelfBoundedFor(
                      readerManifest.sourceId,
                      page.uri,
                    ),
                  ),
            };

  Future<HomeReaderPreparedChapter> prepare(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required bool refreshRemote,
    int? initialPageIndex,
    HomeReaderChapterEntry? initialChapterEntry,
  }) {
    if (_closed) {
      return Future<HomeReaderPreparedChapter>.error(
        StateError('Home Reader chapter composition is closed'),
      );
    }
    return _trackPreparation(
      _prepare(
        loadChapter,
        refreshRemote: refreshRemote,
        initialPageIndex: initialPageIndex,
        initialChapterEntry: initialChapterEntry,
      ),
    );
  }

  Future<HomeReaderPreparedChapter> _prepare(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required bool refreshRemote,
    int? initialPageIndex,
    HomeReaderChapterEntry? initialChapterEntry,
  }) async {
    final totalWatch = Stopwatch()..start();
    // The route may paint immediately, but its capabilities must not capture
    // bootstrap owners which Home retires as soon as durable services arrive.
    // This joins composition readiness, not NetLane admission or plugin startup.
    await _ensureDurableServices();
    final serviceHandoffMs = totalWatch.elapsedMilliseconds;
    final rawEntry = await loadChapter();
    final loadMs = totalWatch.elapsedMilliseconds - serviceHandoffMs;
    final entry = await _hydrateEntry(
      rawEntry,
      awaitCanonicalPhysicalBackfill: false,
    );
    final hydrateMs =
        totalWatch.elapsedMilliseconds - serviceHandoffMs - loadMs;
    final sourceLocatorRefreshRequired =
        _requiresSourceLocatorRefresh(entry.chapter);
    final remoteWatch = Stopwatch()..start();
    final current = sourceLocatorRefreshRequired
        ? await _refreshRemoteEntry(entry, forceSourceRefresh: true)
        : refreshRemote
            ? await _refreshRemoteEntry(entry, forceSourceRefresh: false)
            : entry;
    final remoteMs = remoteWatch.elapsedMilliseconds;
    if (_requiresSourceLocatorRefresh(current.chapter)) {
      throw StateError(
        '章节仍包含不可用于 Reader 的启动快照/运行时资源定位符',
      );
    }

    // A boundary command names an edge, not an index in a compact/old entry.
    // Resolve it only after hydration and any required source refresh.
    final resolvedInitialPageIndex = switch (initialChapterEntry) {
      HomeReaderChapterEntry.firstPage => 0,
      HomeReaderChapterEntry.lastPage => current.chapter.pages.isEmpty
          ? 0
          : current.chapter.pages.length - 1,
      null => initialPageIndex,
    };

    final authorityWatch = Stopwatch()..start();
    final authorityMappingCount = await _prepareVersionAuthority(current);
    final authorityMs = authorityWatch.elapsedMilliseconds;

    // Persistent remote bytes are owned by ArtifactCacheTransport. Do not
    // install a whole-page byte loader here: it would bypass the streaming
    // response/session path and re-couple Reader presentation to App I/O.
    final byteLoaders = <String, LocalImageFileBytesLoader>{};
    const byteProbeMs = 0;
    final readerManifest = current.chapter.toManifest();
    final localAuthorityPrewarm = _downloadComposition()?.transferRuntime;
    var localAuthorityPrewarmStarted = false;
    if (localAuthorityPrewarm != null && readerManifest.pages.isNotEmpty) {
      final rawInitialPageIndex = (resolvedInitialPageIndex ??
              current.progress?.pageIndex ??
              0)
          .clamp(0, readerManifest.pages.length - 1)
          .toInt();
      final page = readerManifest.pages[rawInitialPageIndex];
      localAuthorityPrewarmStarted = true;
      unawaited(
        localAuthorityPrewarm
            .prewarmLocalArtifact(readerPageDownloadId(readerManifest, page))
            .catchError((Object _, StackTrace __) => false),
      );
    }
    final responseSources = responseSourcesFor(readerManifest, byteLoaders);
    final totalMs = totalWatch.elapsedMilliseconds;
    _trace.record(
      TraceEvent(
        monotonicMicros: _monotonicMicros(),
        sessionId: 'reader-entry',
        kind: TraceEventKind.readerObservation,
        payload: <String, Object?>{
          'stage': 'reader-prepare-complete',
          'sourceId': current.chapter.sourceId,
          'comicId': current.chapter.comicId,
          'chapterId': current.chapter.chapterId,
          'refreshRemote': refreshRemote,
          'sourceLocatorRefreshRequired': sourceLocatorRefreshRequired,
          'totalPages': current.chapter.pages.length,
          'localByteLoaders': byteLoaders.length,
          'networkResponseLoaders': responseSources.length,
          'serviceHandoffMs': serviceHandoffMs,
          'loadChapterMs': loadMs,
          'hydrateMs': hydrateMs,
          'remoteRefreshMs': remoteMs,
          'versionReuseAuthorityMs': authorityMs,
          'verifiedAuthorityMappings': authorityMappingCount,
          'localAuthorityPrewarmStarted': localAuthorityPrewarmStarted,
          'byteProbeMs': byteProbeMs,
          'totalPrepareMs': totalMs,
        },
      ),
    );
    return HomeReaderPreparedChapter(
      entry: current,
      byteLoaders: byteLoaders,
      responseSources: responseSources,
      initialPageIndex: resolvedInitialPageIndex,
    );
  }
}
