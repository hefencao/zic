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

typedef HomeReaderChapterReadMarker = Future<void> Function(
  ImportedLibraryEntry entry,
);

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
/// owns the hydrate -> source-authority refresh -> version-authority wait ->
/// response-capability projection sequence so those concerns cannot reach
/// arbitrary Home widget fields through a `part` extension.
final class HomeReaderChapterComposition {
  HomeReaderChapterComposition({
    required HomeReaderEntryHydrator hydrateEntry,
    required ComicSourceResourceGateway sourceResources,
    required ChapterDownloadTransferRuntimeProvider? Function()
        downloadComposition,
    required bool Function(ImportedChapterRecord chapter)
        requiresSourceLocatorRefresh,
    required HomeReaderRemoteEntryRefresher refreshRemoteEntry,
    required HomeReaderVersionAuthorityPreparer prepareVersionAuthority,
    required HomeReaderChapterReadMarker markChapterRead,
    required TraceSink trace,
    required int Function() monotonicMicros,
  })  : _hydrateEntry = hydrateEntry,
        _sourceResources = sourceResources,
        _downloadComposition = downloadComposition,
        _requiresSourceLocatorRefresh = requiresSourceLocatorRefresh,
        _refreshRemoteEntry = refreshRemoteEntry,
        _prepareVersionAuthority = prepareVersionAuthority,
        _markChapterRead = markChapterRead,
        _trace = trace,
        _monotonicMicros = monotonicMicros;

  final HomeReaderEntryHydrator _hydrateEntry;
  final ComicSourceResourceGateway _sourceResources;
  final ChapterDownloadTransferRuntimeProvider? Function()
      _downloadComposition;
  final bool Function(ImportedChapterRecord chapter)
      _requiresSourceLocatorRefresh;
  final HomeReaderRemoteEntryRefresher _refreshRemoteEntry;
  final HomeReaderVersionAuthorityPreparer _prepareVersionAuthority;
  final HomeReaderChapterReadMarker _markChapterRead;
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
      ),
    );
  }

  Future<HomeReaderPreparedChapter> _prepare(
    Future<ImportedLibraryEntry> Function() loadChapter, {
    required bool refreshRemote,
    int? initialPageIndex,
  }) async {
    final totalWatch = Stopwatch()..start();
    final rawEntry = await loadChapter();
    final loadMs = totalWatch.elapsedMilliseconds;
    final entry = await _hydrateEntry(
      rawEntry,
      awaitCanonicalPhysicalBackfill: false,
    );
    final hydrateMs = totalWatch.elapsedMilliseconds - loadMs;
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
      final rawInitialPageIndex = (initialPageIndex ??
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
    unawaited(_markChapterRead(current));
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
      initialPageIndex: initialPageIndex,
    );
  }
}
