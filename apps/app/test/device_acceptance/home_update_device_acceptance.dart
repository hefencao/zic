import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:plugin_host_bridge/plugin_host_bridge.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
// Test-only access to the existing durable response store.
// ignore: depend_on_referenced_packages
import 'package:storage/storage.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';

import 'package:zic/app.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/app_pull_to_refresh.dart';
import 'package:zic/app_settings_screen.dart';
import 'package:zic/artwork_placeholder.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_shell.dart';
import 'package:zic/library_backup.dart';
import 'package:zic/local_media_composition.dart';
import 'package:zic/main.dart' as app_entrypoint;
import 'package:zic/misc_page.dart';
import 'package:zic/source_browser.dart';
import 'package:zic/source_resource_gateway.dart';
import 'package:zic/startup_platform.dart';

// Explicit device entrypoint: production Home/details/Reader/storage owners with a
// controlled source and a fresh temporary SQLite database. It never opens the
// user's library, preferences, external plugins or download artifact index.
// Download completion checks use a separate persistent artifact index in that
// temporary root, through the real chapter commands and whole-comic queue.
final _trace = DebugTraceLog();
final _preferences = AppPreferencesController();
final _checks = <Map<String, Object?>>[];
final _homeKey = GlobalKey();
const _sourceId = 'fixture:home-update';
final _signal = DateTime.utc(2026, 8, 8);
final _source = _UpdateSource();
late ImportedLibraryStore _store;
ComicVersionRelationStore get _versions => _store as ComicVersionRelationStore;
late ChapterDownloadService _downloads;
late WholeComicDownloadQueue _queue;
late ResourceCacheCoordinator _cache;
final _startup = HomeStartupTelemetry(clock: const SystemClock(), sink: _trace);
// The explicit device build needs two launches, separated by force-stop.
const _processCold = bool.fromEnvironment('ZIC_HOME_ARTWORK_PROCESS_COLD');
const _sourceUnavailable = bool.fromEnvironment('ZIC_HOME_ARTWORK_SOURCE_UNAVAILABLE');
const _combinedArtwork = bool.fromEnvironment('ZIC_HOME_ARTWORK_COMBINED');

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() =>
    app_entrypoint.zicExternalPluginRuntimeServiceMain();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(
    body: Center(child: Text('准备隔离首页更新验收')),
  )));
  await _frames(2);
  if (_sourceUnavailable) {
    await _sourceUnavailableArtwork();
    return;
  }
  if (_processCold) {
    await _processColdArtwork();
    return;
  }
  var completed = false;
  var resourcesReady = false;
  Directory? root;
  try {
    root = await Directory.systemTemp.createTemp('zic-home-update-');
    _store = await openImportedLibraryStore(root.path);
    _downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => throw StateError('No page transport in fixture'),
    );
    _queue = WholeComicDownloadQueue(downloads: _downloads);
    _cache = ResourceCacheCoordinator();
    resourcesReady = true;
    if (_combinedArtwork) {
      await _combinedArtworkChecks(root);
      completed = true;
      return;
    }
    await _seed();
    await _mount();
    _check('four-cases-only-shelved-update-visible',
      _updates().join(',') == 'shelved-update');
    _check('unshelved-history-remains-independent',
      _card('unshelved-history') != null && !_updates().contains('unshelved-history'));

    final withSignal = await _openDetails('shelved-update');
    _source.description = 'Metadata changed, catalog unchanged';
    await withSignal.reloadLibrary(refreshContent: true);
    final refreshed = (await _store.getSavedComic(_sourceId, 'shelved-update'))!;
    _check('metadata-refresh-preserves-existing-signal',
      refreshed.description == _source.description &&
      refreshed.sourceUpdateAt == _signal);
    await _popDetails();
    _selectNavigation(1);
    await _frames(25);
    final withoutSignal = await _openDetails('shelved-no-update');
    _source.description = 'Another metadata change, still no catalog change';
    await withoutSignal.reloadLibrary(refreshContent: true);
    final unchanged = (await _store.getSavedComic(_sourceId, 'shelved-no-update'))!;
    _check('metadata-refresh-does-not-create-signal',
      unchanged.description == _source.description &&
      unchanged.sourceUpdateAt == null);
    await _popDetails();
    _selectNavigation(0);
    await _frames(25);

    var screen = await _openDetails('old-comic');
    final preference = (await _store.getComicPreference(_sourceId, 'old-comic'))!;
    await screen.onPreferenceChanged(preference.copyWith(inShelf: true));
    var admitted = (await _store.getSavedComic(_sourceId, 'old-comic'))!;
    _check('first-admission-clears-known-chapter-signal',
      admitted.sourceUpdateAt == null);
    _check('first-admission-acknowledges-known-version',
      (await _store.getComicPreference(_sourceId, 'old-comic'))!
        .acknowledgedVersionComicId == 'known-successor');
    _check('admission-preserves-relation-and-progress',
      (await _versions.listAllComicVersionRelations()).length == 1 &&
      (await _store.get(_sourceId, 'old-comic:chapter'))!.progress != null);
    await _popDetails();
    _check('known-version-does-not-reappear-on-home',
      !_updates().contains('old-comic'));

    screen = await _openDetails('old-comic');
    await screen.onPreferenceChanged(preference.copyWith(inShelf: true, liked: true));
    _check('ordinary-preference-edit-preserves-acknowledgement',
      (await _store.getComicPreference(_sourceId, 'old-comic'))!
        .acknowledgedVersionComicId == 'known-successor');
    await screen.reloadLibrary(refreshContent: true);
    _check('metadata-after-admission-does-not-create-signal',
      (await _store.getSavedComic(_sourceId, 'old-comic'))!.sourceUpdateAt == null);
    _source.chapterCounts['old-comic'] = 2;
    await screen.reloadLibrary(refreshContent: true);
    _check('later-source-catalog-change-produces-chapter-signal',
      (await _store.getSavedComic(_sourceId, 'old-comic'))!.sourceUpdateAt != null);
    await _popDetails();
    _check('later-chapter-update-visible-on-home', _updates().contains('old-comic'));

    screen = await _openDetails('old-comic');
    await screen.onPreferenceChanged(preference.copyWith(inShelf: false));
    await screen.onPreferenceChanged(preference.copyWith(inShelf: true));
    admitted = (await _store.getSavedComic(_sourceId, 'old-comic'))!;
    _check('readmission-keeps-unseen-separate-from-notification',
      admitted.sourceUpdateAt == null &&
      admitted.unseenChapterIds.contains('old-comic:chapter-1') &&
      !admitted.unseenChapterIds.contains('old-comic:chapter'));
    await _popDetails();
    await _unmount();
    await _store.close();
    _store = await openImportedLibraryStore(root.path);
    _check('sqlite-reopen-preserves-acknowledgement',
      (await _store.getComicPreference(_sourceId, 'old-comic'))!
        .acknowledgedVersionComicId == 'known-successor');
    final backup = await buildImportedLibraryBackup(_store);
    final backupPreference = (backup['comicPreferences'] as List)
        .cast<Map<String, Object?>>()
        .singleWhere((value) => value['comicId'] == 'old-comic');
    _check('exported-backup-preserves-acknowledgement',
      backupPreference['acknowledgedVersionComicId'] == 'known-successor');
    await _mount();
    _check('known-version-stays-acknowledged-after-reopen',
      !_updates().contains('old-comic'));
    await _unmount();

    final session = HomeLibrarySession(
      library: _store, chapterDownloads: _downloads, wholeComicDownloads: _queue,
      sources: <BrowsableComicSource>[_source], ownsLibrary: false,
      ownsChapterDownloads: false, ownsWholeComicDownloads: false,
      persistSnapshot: false,
      waitForPrimaryFrame: () => WidgetsBinding.instance.endOfFrame,
    );
    try {
      await session.ready;
      await session.upsertVersionRelation(ComicVersionRelation(
        sourceId: _sourceId, predecessorComicId: 'known-successor',
        successorComicId: 'later-successor', discoveredAt: DateTime.now().toUtc(),
      ));
      _check('later-version-keeps-shelf-head-independent',
        session.versionBaselines.shelfHeadFor(_sourceId, 'old-comic') == 'old-comic' &&
        session.versionBaselines.latestKnownHeadFor(_sourceId, 'old-comic') ==
          'later-successor');
    } finally {
      await session.close();
      session.dispose();
    }
    await _mount();
    _check('later-version-visible-without-chapter-signal',
      _updates().contains('old-comic') &&
      (await _store.getSavedComic(_sourceId, 'old-comic'))!.sourceUpdateAt == null);
    screen = await _openDetails('old-comic');
    final currentPreference =
        (await _store.getComicPreference(_sourceId, 'old-comic'))!;
    await screen.onPreferenceChanged(currentPreference.copyWith(liked: true));
    await screen.reloadLibrary(refreshContent: true);
    await _popDetails();
    _check('ordinary-edit-and-metadata-do-not-consume-later-version',
      _updates().contains('old-comic') &&
      (await _store.getComicPreference(_sourceId, 'old-comic'))!
        .acknowledgedVersionComicId == 'known-successor');
    _check('version-notification-does-not-rewrite-chapter-or-relation',
      (await _store.getSavedComic(_sourceId, 'old-comic'))!.sourceUpdateAt == null &&
      (await _versions.listAllComicVersionRelations()).length == 2 &&
      (await _store.get(_sourceId, 'old-comic:chapter'))!.progress != null);
    await _downloadCompletionChecks(root);
    await _artworkChecks(root);
    await _retentionChecks(root);
    completed = true;
  } on Object catch (error, stack) {
    _checks.add(<String, Object?>{
      'step': 'fixture', 'status': 'failed', 'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    if (resourcesReady) {
      await _unmount();
      await shutdownDefaultLocalMediaPipeline();
      await _queue.close();
      await _downloads.close();
      await _cache.close();
      await _store.close();
    }
    if (root != null && await root.exists()) await root.delete(recursive: true);
    await _exportResult(completed: completed, root: root);
  }
}

Future<void> _exportResult({required bool completed, required Directory? root,
    String phase = 'complete', int? preparedProcessId}) async {
  final result = <String, Object?>{
    'completed': completed, 'phase': phase, 'processId': pid,
    'preparedProcessId': preparedProcessId,
    'boundary': 'Production Home/details/storage owners with a controlled source. '
        'No real-origin or final-display performance claim.',
    'userStoresOpened': false,
    'checks': _checks,
    'comicLoads': _source.comicLoads,
    'trace': _trace.exportEvents.map((event) => event.toJson()).toList(),
    'temporaryRootRemoved': root != null && !await root.exists(),
  };
  await exportDebugTraceFile(
    suggestedName: 'zic-home-update-acceptance-'
        '${DateTime.now().millisecondsSinceEpoch}.json',
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(result))),
    relativeDirectory: 'Debug',
  );
  runApp(MaterialApp(home: Scaffold(body: Center(child: Text(
    phase == 'prepared' ? '隔离缓存已准备，请结束进程后重新启动' :
        completed ? '首页更新隔离验收完成：${_checks.length} 项' : '首页更新隔离验收失败',
  )))));
  await _frames(2);
}

Future<void> _processColdArtwork() async {
  // Only this fixture's directory survives the first launch; the second launch
  // always removes it. No user-library or plugin capability is opened.
  final root = Directory('${Directory.systemTemp.path}/zic-home-artwork-process-cold');
  final marker = File('${root.path}/prepared.json');
  Map<String, Object?>? prepared;
  var resourcesReady = false;
  var completed = false;
  var keepForRestart = false;
  try {
    if (await marker.exists()) {
      prepared = (jsonDecode(await marker.readAsString()) as Map).cast<String, Object?>();
      if (prepared['schema'] != 1) throw StateError('Unknown fixture preparation');
      _checks.addAll((prepared['checks'] as List).map(
        (check) => (check as Map).cast<String, Object?>()));
    } else {
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
    }
    _store = await openImportedLibraryStore(
      prepared == null ? root.path : '${root.path}/artwork-library',
    );
    _downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => throw StateError('No page transport in fixture'),
    );
    _queue = WholeComicDownloadQueue(downloads: _downloads);
    _cache = prepared == null ? ResourceCacheCoordinator() : ResourceCacheCoordinator(
      responses: ResourceCacheManager(byteStore:
        FileResourceCacheByteStore('${root.path}/artwork-cache')),
    );
    resourcesReady = true;
    if (prepared == null) {
      await _artworkChecks(root);
      keepForRestart = true;
    } else {
      _check('artwork-reopens-in-another-process',
        prepared['processId'] is int && prepared['processId'] != pid);
      _source.artworkMode = true;
      final first = await _store.getSavedComic(_sourceId, 'alias-one');
      final second = await _store.getSavedComic(_sourceId, 'alias-two');
      _check('canonical-aliases-survive-process-exit',
        first?.canonicalComicId == 'alias' && second?.canonicalComicId == 'alias');
      await _mount(sources: const <BrowsableComicSource>[]);
      bool frame(String id) => _trace.exportEvents.any((event) =>
        event.kind == TraceEventKind.homeCoverFirstFrame &&
        event.identityHash == 'home-update:$_sourceId\u0000$id');
      await _wait(() => frame('fast-cover') && frame('slow-cover'));
      _check('process-cold-covers-hit-durable-bytes-before-source-activation',
        _cache.responses.stats.persistentHits >= 2 &&
        _source.resourceLoads.isEmpty && _source.comicLoads == 0);
      _check('process-cold-unopened-shelf-starts-no-hidden-loaders',
        _element((element) => element.widget.key == bookshelfPageKey) == null &&
        !_trace.exportEvents.any((event) => event.kind == TraceEventKind.homeCoverRequested &&
          <String>['$_sourceId\u0000alias', '$_sourceId\u0000shelf-only']
            .contains(event.identityHash)));
      _selectNavigation(1);
      await _frames(30);
      _check('process-cold-persisted-aliases-show-one-shelf-card',
        _elements((element) => element.widget is ComicCoverCard &&
          (element.widget as ComicCoverCard).coverIdentity == '$_sourceId\u0000alias')
          .length == 1);
      _check('process-cold-shelf-keeps-source-unactivated',
        _source.resourceLoads.isEmpty && _source.comicLoads == 0);
    }
    completed = true;
  } on Object catch (error, stack) {
    _checks.add(<String, Object?>{
      'step': 'process-cold-fixture', 'status': 'failed', 'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    try {
      if (resourcesReady) {
        await _unmount();
        await _queue.close();
        await _downloads.close();
        await _cache.close();
        await _store.close();
      }
    } on Object catch (error, stack) {
      completed = false;
      _checks.add(<String, Object?>{
        'step': 'process-cold-close', 'status': 'failed', 'error': error.toString(),
        'stack': stack.toString(),
      });
    } finally {
      if (completed && keepForRestart) {
        await marker.writeAsString(jsonEncode(<String, Object?>{
          'schema': 1, 'processId': pid, 'checks': _checks,
        }), flush: true);
      } else if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
    await _exportResult(completed: completed && !keepForRestart, root: root,
      phase: completed && keepForRestart ? 'prepared' : 'complete',
      preparedProcessId: prepared?['processId'] as int?);
  }
}

Future<void> _sourceUnavailableArtwork() async {
  // Two actual processes share only this fixture-owned directory. The source's
  // real Android runtime holds/fails init at loopback; cache owners are unchanged.
  const key = 'home_artwork_unavailable_fixture';
  const pluginId = 'venera:home-artwork-unavailable-fixture';
  const sourceId = 'venera:$key';
  const opaqueSourceId = 'mihon:home-artwork-unavailable-fixture';
  final root = Directory('${Directory.systemTemp.path}/zic-home-artwork-unavailable');
  final marker = File('${root.path}/prepared.json');
  Map<String, Object?>? prepared;
  ExternalPluginController? controller;
  HttpServer? origin;
  final releaseActivation = Completer<void>();
  var originPort = 0;
  var activationRequests = 0;
  var imageRequests = 0;
  var recovering = false;
  var resourcesReady = false;
  var completed = false;
  var keepForRestart = false;
  try {
    if (await marker.exists()) {
      prepared = (jsonDecode(await marker.readAsString()) as Map).cast<String, Object?>();
      if (prepared['schema'] != 1) throw StateError('Unknown fixture preparation');
      _checks.addAll((prepared['checks'] as List).map(
        (check) => (check as Map).cast<String, Object?>()));
    } else {
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
    }
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4,
      prepared?['port'] as int? ?? 0);
    originPort = origin.port;
    final base = 'http://127.0.0.1:$originPort';
    origin.listen((request) async {
      if (request.uri.path == '/activate') {
        activationRequests++;
        if (!recovering) await releaseActivation.future;
        request.response.write(recovering ? 'ready' : 'unavailable');
      } else {
        imageRequests++;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_source.png);
      }
      await request.response.close();
    });
    _store = await openImportedLibraryStore('${root.path}/library');
    _downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => throw StateError('No Reader transport in fixture'),
    );
    _queue = WholeComicDownloadQueue(downloads: _downloads);
    _cache = ResourceCacheCoordinator(responses: ResourceCacheManager(
      byteStore: FileResourceCacheByteStore('${root.path}/artwork-cache')));
    resourcesReady = true;
    if (prepared == null) {
      for (final item in <({String source, String id, String locator})>[
        (source: sourceId, id: 'http-hit', locator: '$base/hit.png'),
        (source: opaqueSourceId, id: 'opaque-hit', locator: 'mihon:resource:fixture-cover'),
        (source: sourceId, id: 'http-miss', locator: '$base/miss.png'),
      ]) {
        await _store.upsertSavedComic(SavedComicRecord(
          sourceId: item.source, comicId: item.id, title: item.id,
          coverSourceId: item.locator, authors: const <String>[],
          readingDirection: ReadingDirection.ltr,
        ));
        await _store.upsertChapter(ImportedChapterRecord(
          directoryId: item.id, displayName: 'History', sourceId: item.source,
          comicId: item.id, comicTitle: item.id, chapterId: '${item.id}:chapter',
          sourceRevision: 'r1', pages: const <ImportedPageRecord>[
            ImportedPageRecord(displayName: 'page', sourceId: 'fixture:page',
              pageId: 'page', contentKindHint: ContentKindHint.png),
          ],
        ));
        await _store.saveProgress(ReadingProgress(
          sourceId: item.source, comicId: item.id, chapterId: '${item.id}:chapter',
          pageIndex: 0, subPageOffset: 0, readerMode: ReaderMode.paged,
          updatedAt: _signal,
        ));
        if (item.id.endsWith('-hit')) {
          await loadCachedComicImageSource(cache: _cache.responses,
            sourceId: item.source, comicId: item.id, imageIdentity: item.locator,
            revision: comicArtworkCacheSchemaRevision, awaitPersistence: true,
            retention: ResourceCacheRetention.retained, loader: () async => _source.png);
        }
      }
      final pluginRoot = await Directory('${root.path}/external_plugins').create();
      final payload = await File('${pluginRoot.path}/fixture.js').writeAsString(
        "class HomeArtworkUnavailableFixture extends ComicSource {name='Fixture';"
        "key='$key';version='1';url='https://fixture.invalid';"
        "async init(){const r=await Network.get('$base/activate',{'cache-time':'no'});"
        "if(r.body!=='ready')throw new Error('fixture activation unavailable')}"
        "explore=[{title:'Fixture',type:'multiPageComicList',load:async(page)=>[]}];}",
        flush: true,
      );
      final plugin = ExternalComicPluginCatalogEntry(
        format: ExternalComicPluginFormat.veneraJavaScript,
        pluginId: pluginId, name: 'Fixture', version: '1',
        entrypoint: Uri.parse('https://fixture.invalid/fixture.js'),
        sources: const <ExternalComicPluginSource>[
          ExternalComicPluginSource(sourceId: sourceId, externalId: key,
            name: 'Fixture', language: 'en'),
        ],
      );
      final inspection = await VeneraJavaScriptInspector(
        payloads: CallbackExternalPluginPayloadLoader((_) async =>
          ExternalPluginPayloadFile(path: payload.path, byteLength: await payload.length())),
      ).inspect(plugin);
      await File('${pluginRoot.path}/installed.json').writeAsString(jsonEncode({
        'version': 1, 'plugins': [{
          'plugin': {'format': plugin.format.name, 'pluginId': pluginId, 'name': 'Fixture',
            'version': '1', 'entrypoint': plugin.entrypoint.toString(), 'sources': [
              {'sourceId': sourceId, 'externalId': key, 'name': 'Fixture', 'language': 'en'},
            ]},
          'payloadPath': payload.path, 'payloadSha256': inspection.payloadSha256,
          'repositoryOrigin': 'https://fixture.invalid', 'sourceKey': key,
          'sourceIds': [sourceId],
        }],
      }), flush: true);
      _check('unavailable-fixture-persists-two-covers-and-trusted-runtime',
        (await (_cache.responses.byteStore! as FileResourceCacheByteStore).inspect())
          .retainedEntries == 2);
      keepForRestart = true;
    } else {
      _check('unavailable-artwork-reopens-in-another-process', prepared['processId'] != pid);
      await waitForFirstFlutterUiDisplayed();
      await attachAndroidPlugin('network_bridge');
      await attachAndroidPlugin('plugin_host_bridge');
      controller = await ExternalPluginController.openDeferred(root.path,
        discoverDeviceMihonExtensions: false, deferRuntimeActivation: true);
      await _mount(sources: const <BrowsableComicSource>[], externalPlugins: controller);
      int events(TraceEventKind kind, String source, String id) =>
        _trace.exportEvents.where((event) => event.kind == kind &&
          event.identityHash == 'home-history:$source\u0000$id').length;
      int frames(String source, String id) => events(TraceEventKind.homeCoverFirstFrame, source, id);
      await _wait(() => activationRequests == 1 && frames(sourceId, 'http-hit') == 1 &&
        frames(opaqueSourceId, 'opaque-hit') == 1, maxFrames: 1800);
      _check('cold-http-and-opaque-durable-hits-paint-while-source-init-waits',
        _cache.responses.stats.persistentHits == 2 && controller.activeSources.isEmpty &&
        imageRequests == 0 && frames(sourceId, 'http-miss') == 0);
      _check('durable-miss-keeps-original-readiness-pending-without-local-file-fallback',
        events(TraceEventKind.homeCoverRequested, sourceId, 'http-miss') == 1 &&
        events(TraceEventKind.homeCoverSourceFailed, sourceId, 'http-miss') == 0);
      releaseActivation.complete();
      await _wait(() => controller!.activationFailures.containsKey(pluginId) &&
        events(TraceEventKind.homeCoverSourceFailed, sourceId, 'http-miss') == 1,
        maxFrames: 1800);
      _check('actual-runtime-init-failure-preserves-painted-durable-covers',
        controller.activeSources.isEmpty && controller.canRetryActivation(pluginId) &&
        frames(sourceId, 'http-hit') == 1 && frames(opaqueSourceId, 'opaque-hit') == 1 &&
        imageRequests == 0);
      final failure = _trace.exportEvents.singleWhere((event) =>
        event.kind == TraceEventKind.homeCoverSourceFailed &&
        event.identityHash == 'home-history:$sourceId\u0000http-miss');
      _check('unavailable-miss-reports-source-readiness-failure',
        failure.payload['errorType'] == 'StateError' &&
        controller.activationFailures[pluginId] is ExternalPluginActivationException &&
        (controller.activationFailures[pluginId]! as ExternalPluginActivationException)
          .denials.contains(ExternalPluginDenial.activationFailed));
      recovering = true;
      await controller.retryActivation(pluginId);
      _check('explicit-runtime-retry-activates-the-original-source',
        activationRequests == 2 && controller.activeSources.length == 1 &&
        !controller.activationFailures.containsKey(pluginId));
      bool missPainted() {
        final card = _element((element) => element.widget is ComicCoverCard &&
          (element.widget as ComicCoverCard).comic.comicId == 'http-miss');
        return card != null && _element((element) => element.widget is RawImage &&
          (element.widget as RawImage).image != null, within: card) != null;
      }
      await _wait(missPainted, maxFrames: 1800);
      _check('explicit-runtime-recovery-loads-only-durable-miss',
        missPainted() && _card('http-miss')!.sourceAvailable &&
        activationRequests == 2 && imageRequests == 1 &&
        !controller.activationFailures.containsKey(pluginId) &&
        controller.activeSources.length == 1 &&
        events(TraceEventKind.homeCoverRequested, sourceId, 'http-miss') == 2 &&
        frames(sourceId, 'http-miss') == 1 &&
        frames(sourceId, 'http-hit') == 1 && frames(opaqueSourceId, 'opaque-hit') == 1 &&
        events(TraceEventKind.homeCoverRequested, sourceId, 'http-hit') == 1 &&
        events(TraceEventKind.homeCoverRequested, opaqueSourceId, 'opaque-hit') == 1);
    }
    completed = true;
  } on Object catch (error, stack) {
    _checks.add({'step': 'source-unavailable-fixture', 'status': 'failed',
      'error': error.toString(), 'stack': stack.toString(),
      'activationRequests': activationRequests, 'imageRequests': imageRequests,
      'activeSources': controller?.activeSources.map((source) => source.sourceId).toList(),
      'missSourceAvailable': _card('http-miss')?.sourceAvailable,
    });
  } finally {
    if (!releaseActivation.isCompleted) releaseActivation.complete();
    try {
      if (resourcesReady) {
        await _unmount();
        await controller?.close();
        await _queue.close();
        await _downloads.close();
        await _cache.close();
        await _store.close();
      }
    } on Object catch (error) {
      completed = false;
      _checks.add({'step': 'source-unavailable-close', 'status': 'failed',
        'error': error.toString()});
    } finally {
      await origin?.close(force: true);
      if (completed && keepForRestart) {
        await marker.writeAsString(jsonEncode({'schema': 1, 'processId': pid,
          'port': originPort, 'checks': _checks}), flush: true);
      } else if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
    await _exportResult(completed: completed && !keepForRestart, root: root,
      phase: completed && keepForRestart ? 'prepared' : 'complete',
      preparedProcessId: prepared?['processId'] as int?);
  }
}

Future<void> _downloadCompletionChecks(Directory root) async {
  await _unmount();
  final previousDownloads = _downloads;
  final previousQueue = _queue;
  const id = 'download-badges';
  final source = _UpdateSource()..chapterCounts[id] = 3;
  for (var index = 0; index < 3; index++) {
    source.downloadGates['badge/$index.png'] = Completer<void>();
  }
  source.downloadGates['badge/0.png']!.complete();
  final manifest = source.manifest(id);
  await _store.upsertSavedComic(SavedComicRecord.fromManifest(manifest));
  await _store.saveComicPreference(ComicPreference.defaults(
    sourceId: _sourceId, comicId: id, sourceKind: ComicSourceKind.remote,
  ).copyWith(inShelf: true));
  final entries = <ImportedLibraryEntry>[];
  for (var index = 0; index < manifest.chapters.length; index++) {
    final chapter = manifest.chapters[index];
    await _store.upsertChapter(ImportedChapterRecord(
      directoryId: chapter.chapterId, displayName: chapter.title,
      sourceId: _sourceId, comicId: id, comicTitle: id,
      chapterId: chapter.chapterId, sourceRevision: 'r1',
      pages: <ImportedPageRecord>[
        ImportedPageRecord(displayName: 'page', sourceId: 'venera-resource:badge/$index.png',
          pageId: '${chapter.chapterId}:page-0', contentKindHint: ContentKindHint.png),
      ],
    ));
    entries.add((await _store.get(_sourceId, chapter.chapterId))!);
  }
  final path = '${root.path}/badge-downloads';
  Future<PersistentChapterDownloadService> openDownloads() async {
    final service = await PersistentChapterDownloadService.open(path, traceSink: _trace);
    service.setChapterResourceAccess(ChapterResourceAccess(
      loadBytes: (_, uri) => source.loadResource(uri),
    ));
    return service;
  }
  var downloads = await openDownloads();
  WholeComicDownloadQueue? queue;
  try {
    await downloads.download(entries[0]);
    await downloads.close();
    downloads = await openDownloads();
    _downloads = downloads;
    _queue = queue = WholeComicDownloadQueue(downloads: downloads);
    await _mount(sources: <BrowsableComicSource>[source]);
    _selectNavigation(1);
    await _frames(25);
    _check('existing-durable-chapter-has-no-completion-badge',
      await downloads.isDownloaded(entries[0]) &&
      (await downloads.readPage(entries[0], 0)).length == source.png.length &&
      _card(id) != null && _card(id)!.downloadProgress == null);

    var screen = await _openDetails(id);
    final single = screen.onDownloadChapter(entries[1]);
    await _popDetails();
    await _wait(() => source.resourceLoads['badge/1.png'] == 1);
    _check('pending-chapter-command-has-only-active-progress',
      _card(id)?.downloadProgress?.kind == ComicDownloadProgressKind.active);
    source.downloadGates['badge/1.png']!.complete();
    await single;
    await _wait(() => _card(id)?.downloadProgress?.kind ==
      ComicDownloadProgressKind.chapterComplete);
    _check('completed-chapter-command-paints-only-hollow-check',
      _completionIcon(id, Icons.check_circle_outline, Colors.white) &&
      !_completionIcon(id, Icons.check_circle, Colors.green));
    await _openDetails(id);
    await _popDetails();
    _check('details-entry-clears-chapter-completion-badge',
      _card(id)!.downloadProgress == null);

    screen = await _openDetails(id);
    await screen.onDownloadComic(entries);
    await _popDetails();
    await _wait(() => source.resourceLoads['badge/2.png'] == 1);
    _check('pending-whole-comic-command-has-only-active-progress',
      queue.snapshot.jobFor(_sourceId, id)?.phase == WholeComicQueuePhase.running &&
      _card(id)?.downloadProgress?.kind == ComicDownloadProgressKind.active &&
      !_completionIcon(id, Icons.check_circle, Colors.green));
    source.downloadGates['badge/2.png']!.complete();
    await _wait(() => queue!.snapshot.jobFor(_sourceId, id)?.phase ==
      WholeComicQueuePhase.complete && _card(id)?.downloadProgress?.kind ==
      ComicDownloadProgressKind.comicComplete);
    _check('completed-whole-comic-queue-paints-only-green-solid-check',
      _completionIcon(id, Icons.check_circle, Colors.green) &&
      !_completionIcon(id, Icons.check_circle_outline, Colors.white) &&
      source.resourceLoads.length == 3 &&
      source.resourceLoads.values.every((count) => count == 1) &&
      (await downloads.inspectMany(entries)).every((snapshot) => snapshot.isComplete));
    await _openDetails(id);
    await _popDetails();
    _check('details-entry-clears-whole-comic-completion-badge',
      _card(id)!.downloadProgress == null &&
      queue.snapshot.jobFor(_sourceId, id)?.phase == WholeComicQueuePhase.complete);
  } finally {
    for (final gate in source.downloadGates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await _unmount();
    await queue?.close();
    await downloads.close();
    _downloads = previousDownloads;
    _queue = previousQueue;
  }
}

Future<void> _combinedArtworkChecks(Directory root) async {
  const canonical = 'https://fixture.invalid/comic/42';
  String raw(int revision) => 'mihon:manga:${base64UrlEncode(utf8.encode(
    jsonEncode({'url': canonical, 'title': 'Snapshot $revision'})))}';
  final source = _CombinedArtworkSource()..artworkMode = true;
  final handoff = HomeServiceHandoff();
  final previous = _store;
  ImportedLibraryStore? next;
  final resume = _ArtworkResumeProbe();
  Future<void> seed(ImportedLibraryStore store, int revision) async {
    final comicId = raw(revision);
    await store.upsertSavedComic(SavedComicRecord.fromManifest(
      source.manifest(comicId), canonicalComicId: canonical,
      sourceUpdateAt: _signal,
    ).copyWith(coverSourceId: 'https://fixture.invalid/cover.png?token=$revision'));
    await store.saveComicPreference(ComicPreference.defaults(
      sourceId: source.sourceId, comicId: comicId, sourceKind: ComicSourceKind.remote,
    ).copyWith(inShelf: true));
    for (var index = 0; index < 2; index++) {
      await store.upsertChapter(ImportedChapterRecord(
        directoryId: '$comicId:$index', displayName: 'Chapter $index',
        sourceId: source.sourceId, comicId: comicId, comicTitle: 'Snapshot $revision',
        chapterId: '$comicId:chapter-$index', sequence: index, sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(displayName: 'page', sourceId: 'fixture:page',
            pageId: 'page', contentKindHint: ContentKindHint.png),
        ],
      ));
    }
    await store.saveProgress(ReadingProgress(sourceId: source.sourceId,
      comicId: comicId, chapterId: '$comicId:chapter-${revision - 1}',
      pageIndex: 0, subPageOffset: 0, readerMode: ReaderMode.paged,
      updatedAt: _signal.add(Duration(days: revision))));
  }
  void publish(ImportedLibraryStore store) => handoff.updateServices(
    libraryStore: store, chapterDownloads: _downloads, downloadComposition: null,
    wholeComicDownloads: _queue, cacheCoordinator: _cache, externalPlugins: null,
    externalPluginLoader: null, platformEnvironmentLoader: null,
    ensureCoreServices: null, storageRoot: root.path,
    persistHomeProjectionSnapshot: false,
  );
  Map<String, Element> artwork() {
    final cards = _elements((element) => element.widget is ComicCoverCard &&
      (element.widget as ComicCoverCard).coverIdentity == '${source.sourceId}\u0000$canonical');
    final images = <String, Element>{};
    for (final card in cards) {
      final image = _element((element) => element.widget is StableArtworkImage, within: card);
      if (image != null) {
        images[(card.widget as ComicCoverCard).telemetryIdentity ??
          (card.widget as ComicCoverCard).coverIdentity] = image;
      }
    }
    return images;
  }
  try {
    await seed(previous, 1);
    publish(previous);
    await _mount(sources: <BrowsableComicSource>[source], serviceHandoff: handoff);
    await _wait(() => artwork().length == 2);
    _selectNavigation(1);
    await _wait(() => artwork().length == 3);
    _selectNavigation(0);
    await _wait(() => _trace.exportEvents.where((event) =>
      event.kind == TraceEventKind.homeCoverFirstFrame &&
      event.identityHash?.endsWith('\u0000$canonical') == true).length == 3);
    final owners = artwork();
    final homeOwner = _homeKey.currentState;
    _check('one-canonical-comic-is-painted-in-updates-shelf-and-history',
      owners.length == 3 && _updates().length == 1 &&
      source.resourceLoads.values.fold<int>(0, (sum, value) => sum + value) == 1);
    next = await openImportedLibraryStore('${root.path}/combined-next-library');
    await seed(next, 2);
    _store = next;
    publish(next);
    // Inactive navigation pages keep their last child until selected again.
    await _wait(() => _elements((element) => element.widget is ComicCoverCard &&
      (element.widget as ComicCoverCard).comic.comicId == raw(2)).length == 2);
    _selectNavigation(1);
    await _wait(() => _elements((element) => element.widget is ComicCoverCard &&
      (element.widget as ComicCoverCard).comic.comicId == raw(2)).length == 3);
    _selectNavigation(0);
    await _frames(25);
    bool sameOwners() {
      final current = artwork();
      return current.length == owners.length && owners.entries.every((entry) =>
        identical(entry.value, current[entry.key]));
    }
    _check('raw-mihon-alias-resume-and-enrichment-preserve-canonical-artwork-owners',
      identical(homeOwner, _homeKey.currentState) && sameOwners() &&
      _elements((element) => element.widget is ComicCoverCard &&
        (element.widget as ComicCoverCard).comic.resumeChapter?.chapter.chapterId ==
          '${raw(2)}:chapter-1').length == 3 &&
      source.resourceLoads.values.fold<int>(0, (sum, value) => sum + value) == 1);
    WidgetsBinding.instance.addObserver(resume);
    ScaffoldMessenger.of(_homeKey.currentContext!).showSnackBar(const SnackBar(
      content: Text('组合封面验收：请切后台后返回'), duration: Duration(minutes: 2),
    ));
    await resume.returned.future.timeout(const Duration(seconds: 90));
    await _frames(25);
    _check('actual-background-resume-keeps-all-three-artwork-owners',
      resume.paused && identical(homeOwner, _homeKey.currentState) && sameOwners() &&
      source.resourceLoads.values.fold<int>(0, (sum, value) => sum + value) == 1);
  } finally {
    WidgetsBinding.instance.removeObserver(resume);
    await _unmount();
    handoff.dispose();
    if (!identical(previous, _store)) await previous.close();
    // The main fixture owns _store and its shared cache/download owners.
    if (next != null && !identical(next, _store)) await next.close();
  }
}

final class _ArtworkResumeProbe extends WidgetsBindingObserver {
  final returned = Completer<void>();
  bool paused = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) paused = true;
    if (paused && state == AppLifecycleState.resumed && !returned.isCompleted) {
      returned.complete();
    }
  }
}

final class _CombinedArtworkSource extends _UpdateSource
    implements CanonicalComicIdentitySource {
  @override
  String get sourceId => 'mihon:home-combined-artwork-fixture';
  @override
  String canonicalComicIdentity(String comicId) => 'https://fixture.invalid/comic/42';
}

bool _completionIcon(String id, IconData data, Color color) {
  final card = _element((element) => element.widget is ComicCoverCard &&
    (element.widget as ComicCoverCard).comic.comicId == id);
  return card != null && _elements((element) => element.widget is Icon &&
    (element.widget as Icon).icon == data && (element.widget as Icon).color == color,
    within: card).length == 1;
}

Future<void> _artworkChecks(Directory root) async {
  await _unmount();
  await _store.close();
  await _cache.close();
  final libraryPath = '${root.path}/artwork-library';
  final cachePath = '${root.path}/artwork-cache';
  _store = await openImportedLibraryStore(libraryPath);
  final held = _HeldArtworkStore(FileResourceCacheByteStore(cachePath));
  _cache = ResourceCacheCoordinator(responses: ResourceCacheManager(byteStore: held));
  _source.artworkMode = true;
  for (final id in <String>['fast-cover', 'slow-cover', 'shelf-only', 'alias-one', 'alias-two']) {
    await _store.upsertSavedComic(SavedComicRecord.fromManifest(
      _source.manifest(id), canonicalComicId: id.startsWith('alias-') ? 'alias' : null,
      sourceUpdateAt: id.endsWith('-cover') ? _signal : null,
    ));
    await _store.saveComicPreference(ComicPreference.defaults(
      sourceId: _sourceId, comicId: id, sourceKind: ComicSourceKind.remote,
    ).copyWith(inShelf: true));
  }
  int frames(String id) => _trace.exportEvents.where((event) =>
      event.kind == TraceEventKind.homeCoverFirstFrame &&
      event.identityHash == 'home-update:$_sourceId\u0000$id').length;
  try {
    await _mount();
    await _wait(() => held.started.isCompleted && frames('fast-cover') == 1);
    _check('fast-cover-paints-before-slow-source-or-durable-write',
      !_source.slowCover.isCompleted && !held.release.isCompleted &&
      held.writesCompleted == 0 && frames('slow-cover') == 0);
    _check('unopened-shelf-does-not-start-hidden-cover-loaders',
      _element((element) => element.widget.key == bookshelfPageKey) == null &&
      !_source.resourceLoads.containsKey('shelf-only') &&
      !_source.resourceLoads.containsKey('alias'));
    _source.slowCover.complete(_source.png);
    await _wait(() => frames('slow-cover') == 1);
    _check('slow-cover-paints-while-first-persistence-still-held',
      !held.release.isCompleted && held.writesCompleted == 0);
  } finally {
    if (!held.release.isCompleted) held.release.complete();
    if (!_source.slowCover.isCompleted) _source.slowCover.complete(_source.png);
  }
  await _cache.responses.drainPersistence();
  _check('both-covers-persist-through-original-file-store', held.writesCompleted == 2);
  await _unmount();
  await _cache.close();
  await _store.close();
  _store = await openImportedLibraryStore(libraryPath);
  for (final id in <String>['fast-cover', 'slow-cover']) {
    final saved = (await _store.getSavedComic(_sourceId, id))!;
    await _store.upsertSavedComic(saved.copyWith(
      coverSourceId: 'fixture:$id?token=changed',
    ));
  }
  _cache = ResourceCacheCoordinator(responses: ResourceCacheManager(
    byteStore: FileResourceCacheByteStore(cachePath),
  ));
  final calls = Map<String, int>.from(_source.resourceLoads);
  // These owners reopen in the same process; process-cold alias acceptance
  // remains separate from this source-free App remount.
  await _mount(sources: const <BrowsableComicSource>[]);
  await _wait(() => frames('fast-cover') == 2 && frames('slow-cover') == 2);
  _check('cold-token-change-hits-durable-cover-without-live-source',
    _cache.responses.stats.persistentHits >= 2 &&
    _source.resourceLoads.toString() == calls.toString());
  _check('cold-unopened-shelf-remains-unmounted',
    _element((element) => element.widget.key == bookshelfPageKey) == null);
  _selectNavigation(1);
  await _frames(30);
  final aliases = _elements((element) => element.widget is ComicCoverCard &&
      (element.widget as ComicCoverCard).coverIdentity == '$_sourceId\u0000alias');
  _check('persisted-canonical-aliases-show-one-cold-shelf-card', aliases.length == 1);
  _check('cold-shelf-does-not-call-unactivated-source',
    _source.resourceLoads.toString() == calls.toString());
  await _unmount();
  final artifacts = await PersistentDownloadArtifactStore.open('${root.path}/proof-cache');
  try {
    final cache = ArtifactCacheManager(backend: artifacts);
    DownloadId id(String comic) => DownloadId(
      content: ContentId(sourceId: _sourceId, comicId: comic, chapterId: 'chapter', pageId: 'page'),
      sourceRevision: 'fixture-r1', canonicalUri: Uri.parse('fixture:$comic/page.png'),
    );
    final original = id('original');
    final proven = id('proven');
    await cache.storePromotedArtifact(id: original, bytes: _source.png);
    cache.linkEquivalent(first: original, second: proven);
    _check('verified-artifact-equivalence-keeps-real-physical-identity',
      (await cache.lookup(proven))?.storageId == original &&
      await cache.lookupAuthoritative(proven) == null);
    _check('unproven-page-does-not-inherit-artwork-or-equivalent-artifact',
      await cache.lookup(id('unproven')) == null && cache.equivalenceCount == 1);
  } finally {
    await artifacts.close();
  }
}

Future<void> _retentionChecks(Directory root) async {
  await _unmount();
  await _cache.close();
  await _store.close();
  final libraryPath = '${root.path}/retention-library';
  final cachePath = '${root.path}/retention-cache';
  _store = await openImportedLibraryStore(libraryPath);
  final bytes = FileResourceCacheByteStore(cachePath,
    transientMaxEntries: 2, transientMaxBytes: _source.png.length * 2);
  _cache = ResourceCacheCoordinator(responses: ResourceCacheManager(byteStore: bytes));
  _source.retentionBrowse = true;
  const early = 'retention-cover';
  const late = 'retention-late';
  ResourceCacheKey key(String id) {
    final identity = ComicResourceCacheIdentity(sourceId: _sourceId, comicId: id);
    return ResourceCacheKey(kind: ResourceCacheKind.imageBytes,
      identity: identity.response('cover'), namespace: identity.namespace,
      revision: comicArtworkCacheSchemaRevision);
  }
  Future<void> openDetails(String id) async {
    (_element((element) => element.widget.key == sourceComicCardKey(_sourceId, id))!
      .widget as InkWell).onTap!();
    await _wait(() => _element((element) =>
      element.widget is details.RemoteComicDetailsScreen) != null);
    await _frames(25);
    await _cache.responses.drainPersistence();
  }
  Future<void> shelve() async {
    final action = _element((element) => element.widget.key == details.comicDetailsShelfKey)!;
    (_element((element) => element.widget is IconButton, within: action)!
      .widget as IconButton).onPressed!();
    await _frames(25);
    await _popDetails();
  }

  await _mount();
  _selectNavigation(2);
  await _wait(() => _source.resourceLoads[early] == 1 &&
    _source.resourceLoads[late] == 1);
  await _frames(25);
  await _cache.responses.drainPersistence();
  _check('browse-writes-only-transient-canonical-covers',
    (await bytes.inspect()).transientEntries == 2 &&
    (await bytes.inspect()).retainedEntries == 0);
  final originalPayloads = await _artworkPayloads(cachePath);
  await openDetails(early);
  _check('details-promotes-existing-payload-without-rewrite-or-download',
    _source.resourceLoads[early] == 1 &&
    originalPayloads.toString() == (await _artworkPayloads(cachePath)).toString() &&
    (await bytes.inspect()).retainedEntries == 1);
  final refresh = _element((element) =>
    element.widget.key == details.comicDetailsPullRefreshKey)!.widget as AppPullToRefresh;
  _source.description = 'Retention metadata refresh';
  _check('details-metadata-refresh-keeps-retained-artwork', await refresh.onRefresh());
  await _frames(25);
  _source.chapterCounts[early] = 2;
  final chapterRefresh = _element((element) =>
    element.widget.key == details.comicDetailsPullRefreshKey)!.widget as AppPullToRefresh;
  _check('chapter-refresh-completes-with-retained-artwork', await chapterRefresh.onRefresh());
  await _frames(25);
  _check('metadata-and-chapter-refresh-do-not-rewrite-cover',
    _source.resourceLoads[early] == 1 &&
    originalPayloads.toString() == (await _artworkPayloads(cachePath)).toString() &&
    (await bytes.read(key(early)))?.expiresAt == null);
  _preferences.setReaderStartsImmersive(false);
  (_element((element) => element.widget.key ==
    details.comicDetailsChapterKey(_sourceId, '$early:chapter'))!
      .widget as ListTile).onTap!();
  await _wait(() => _element((element) => element.widget is ReaderRuntimeScreen) != null &&
    _trace.exportEvents.any((event) => event.kind == TraceEventKind.firstFrameReady &&
      event.payload['pageIndex'] == 0));
  _check('real-reader-starts-on-source-page',
    _source.resourceLoads['$early/page-0.png'] == 1);
  final slider = _element((element) => element.widget.key == readerPageSliderKey)!
      .widget as Slider;
  slider.onChangeStart!(2);
  slider.onChanged!(2);
  slider.onChangeEnd!(2);
  await _wait(() => _trace.exportEvents.any((event) =>
    event.kind == TraceEventKind.firstFrameReady && event.payload['pageIndex'] == 2) &&
    (_element((element) => element.widget.key == readerPageSliderKey)!
      .widget as Slider).value == 2);
  _check('real-slider-target-produces-first-frame',
    _source.resourceLoads['$early/page-2.png'] == 1);
  final reader = _element((element) => element.widget is ReaderRuntimeScreen)!;
  await Navigator.of(reader).maybePop();
  await _wait(() => _element((element) => element.widget is ReaderRuntimeScreen) == null);
  await _frames(25);
  await _cache.responses.drainPersistence();
  _check('reader-pop-durably-saves-progress-without-rewriting-cover',
    (await _store.get(_sourceId, '$early:chapter'))?.progress?.pageIndex == 2 &&
    _source.resourceLoads[early] == 1 &&
    originalPayloads.toString() == (await _artworkPayloads(cachePath)).toString() &&
    (await bytes.read(key(early)))?.expiresAt == null);
  await shelve();
  _check('refreshed-catalog-is-persisted-with-cover',
    (await _store.getSavedComic(_sourceId, early))?.chapters.length == 2);
  _selectNavigation(0);
  final historyKey = ValueKey<String>('home-history:$_sourceId\u0000$early');
  await _wait(() {
    final history = _element((element) => element.widget.key == historyKey);
    return history != null && _element((element) => element.widget is RawImage &&
      (element.widget as RawImage).image != null, within: history) != null;
  });
  _check('actual-history-cover-keeps-canonical-file-and-no-source-reload',
    _card(early)?.coverIdentity == '$_sourceId\u0000$early' &&
    _source.resourceLoads[early] == 1 &&
    originalPayloads.toString() == (await _artworkPayloads(cachePath)).toString());
  await _openDetails(early);
  await _cache.responses.drainPersistence();
  _check('history-details-return-keeps-progress-and-canonical-cover',
    (await _store.get(_sourceId, '$early:chapter'))?.progress?.pageIndex == 2 &&
    _source.resourceLoads[early] == 1 &&
    originalPayloads.toString() == (await _artworkPayloads(cachePath)).toString());
  await _popDetails();
  _selectNavigation(2);
  await _frames(25);

  (_element((element) => element.widget.key == comicSourceNextPageKey)!
    .widget as IconButton).onPressed!();
  await _frames(25);
  final browser = _element((element) => element.widget is ComicSourcesPage)!;
  final scroll = (_element((element) => element.widget is Scrollable &&
    (element.widget as Scrollable).axisDirection == AxisDirection.down,
    within: browser)! as StatefulElement).state as ScrollableState;
  for (var index = 0; index <= 10; index++) {
    scroll.position.jumpTo(scroll.position.maxScrollExtent * index / 10);
    await _frames(10);
  }
  await _cache.responses.drainPersistence();
  _check('browse-pressure-really-loads-twenty-four-transient-covers',
    _source.resourceLoads.keys.where((id) => id.startsWith('pressure-')).length == 24 &&
    (await bytes.inspect()).transientEntries == 2);
  _check('auto-trim-keeps-retained-cover-but-evicts-late-durable-copy',
    await bytes.read(key(late)) == null &&
    _cache.responses.peek<Uint8List>(key(late)) != null &&
    (await bytes.inspect()).retainedEntries == 1);
  (_element((element) => element.widget.key == comicSourcePreviousPageKey)!
    .widget as IconButton).onPressed!();
  await _frames(25);
  await openDetails(late);
  _check('late-details-promotion-restores-missing-file-without-source-reload',
    _source.resourceLoads[late] == 1 &&
    (await bytes.read(key(late)))?.bytes.length == _source.png.length &&
    (await bytes.inspect()).retainedEntries == 2);
  final detail = _element((element) => element.widget is details.RemoteComicDetailsScreen)!;
  _check('promoted-cover-produces-a-real-details-frame',
    _element((element) => element.widget is RawImage &&
      (element.widget as RawImage).image != null, within: detail) != null);
  await shelve();

  final before = (await bytes.inspect());
  await _cache.trim();
  await _cache.responses.trimPersistentBytesTo(targetBytes: 0);
  final after = await bytes.inspect();
  _check('manual-trim-preserves-retained-statistics', after.transientEntries == 0 &&
    after.retainedEntries == before.retainedEntries &&
    after.retainedBytes == before.retainedBytes);
  final manifest = jsonDecode(await File('$cachePath/response-manifest-v1.json').readAsString())
      as Map<String, Object?>;
  final records = (manifest['records'] as List).cast<Map<String, Object?>>();
  _check('each-cover-has-one-canonical-key-file-and-schema-revision',
    records.length == 2 && (await _artworkPayloads(cachePath)).length == 2 &&
    <String>[early, late].every((id) => records.where((record) =>
      record['identity'] == key(id).identity && record['namespace'] == key(id).namespace &&
      record['revision'] == comicArtworkCacheSchemaRevision).length == 1));
  await _unmount();
  await _cache.close();
  await _store.close();
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  _store = await openImportedLibraryStore(libraryPath);
  _cache = ResourceCacheCoordinator(responses: ResourceCacheManager(
    byteStore: FileResourceCacheByteStore(cachePath),
  ));
  final calls = Map<String, int>.from(_source.resourceLoads);
  await _mount(sources: const <BrowsableComicSource>[]);
  _selectNavigation(1);
  await _wait(() {
    final shelf = _element((element) => element.widget.key == bookshelfPageKey);
    return shelf != null && _elements((element) => element.widget is RawImage &&
      (element.widget as RawImage).image != null, within: shelf).length == 2;
  });
  _check('trimmed-covers-cold-hit-and-paint-before-source-activation',
    _cache.responses.stats.persistentHits >= 2 &&
    _source.resourceLoads.toString() == calls.toString());
  final coldBytes = _cache.responses.byteStore! as FileResourceCacheByteStore;
  final siblingBefore = await coldBytes.read(key(late));
  final payloadsBeforeRefresh = await _artworkPayloads(cachePath);
  final gateway = ComicSourceResourceGateway(sourceForId: (id) =>
    id == _sourceId ? _source : null);
  try {
    final refreshed = await gateway.loadArtworkSource(cache: _cache.responses,
      sourceId: _sourceId, comicId: early, uri: Uri.parse('fixture:$early'),
      forceRefresh: true, awaitPersistence: true,
      retention: ResourceCacheRetention.retained);
    _check('exact-artwork-refresh-reloads-only-requested-cover',
      (await readEncodedResourceBytes(refreshed)).length == _source.png.length &&
      _source.resourceLoads[early] == calls[early]! + 1 &&
      _source.resourceLoads[late] == calls[late] &&
      payloadsBeforeRefresh.keys.join(',') ==
        (await _artworkPayloads(cachePath)).keys.join(',') &&
      (await coldBytes.read(key(early)))?.expiresAt == null &&
      (await coldBytes.read(key(late)))?.bytes.toString() == siblingBefore?.bytes.toString());
  } finally {
    gateway.close();
  }
  (_element((element) => element.widget.key == bookshelfManageKey)!
    .widget as TextButton).onPressed!();
  await _frames(10);
  (_element((element) => element.widget.key == comicDeleteKey(_sourceId, early))!
    .widget as IconButton).onPressed!();
  await _wait(() => _element((element) => element.widget is AlertDialog) != null);
  final deletionDialog = _element((element) => element.widget is AlertDialog)!;
  (_element((element) => element.widget is FilledButton,
    within: deletionDialog)!.widget as FilledButton).onPressed!();
  await _wait(() {
    final shelf = _element((element) => element.widget.key == bookshelfPageKey);
    return shelf != null && _card(early, within: shelf) == null;
  });
  await _cache.responses.drainPersistence();
  _selectNavigation(0);
  await _frames(25);
  _check('whole-comic-delete-removes-only-that-retained-artwork',
    _card(early, within: _element((element) => element.widget.key == homePageKey)) == null &&
    await _store.getSavedComic(_sourceId, early) == null &&
    await coldBytes.read(key(early)) == null &&
    await coldBytes.read(key(late)) != null &&
    (await coldBytes.inspect()).retainedEntries == 1);
  _selectNavigation(3);
  await _frames(25);
  (_element((element) => element.widget.key == miscSettingsEntryKey)!
    .widget as ListTile).onTap!();
  await _wait(() => _element((element) => element.widget.key == settingsDataEntryKey) != null);
  final dataEntry = _element((element) => element.widget.key == settingsDataEntryKey)!;
  (_element((element) => element.widget is ListTile,
    within: dataEntry)!.widget as ListTile).onTap!();
  await _wait(() => _element((element) => element.widget is DataSettingsScreen) != null);
  await _frames(25);
  (_element((element) => element.widget.key == dataCacheClearKey)!
    .widget as ListTile).onTap!();
  await _wait(() => _element((element) => element.widget is AlertDialog) != null);
  final clearDialog = _element((element) => element.widget is AlertDialog)!;
  (_element((element) => element.widget is FilledButton,
    within: clearDialog)!.widget as FilledButton).onPressed!();
  await _wait(() => _cache.responses.stats.entries == 0);
  await _cache.responses.drainPersistence();
  _check('settings-user-clear-removes-retained-artwork',
    (await coldBytes.inspect()).retainedEntries == 0 &&
    await coldBytes.read(key(late)) == null &&
    (await _artworkPayloads(cachePath)).isEmpty);
}

Future<Map<String, String>> _artworkPayloads(String path) async {
  final directory = Directory(path);
  if (!await directory.exists()) return <String, String>{};
  final files = await directory.list(recursive: true)
      .where((file) => file.path.endsWith('.bin')).toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  return <String, String>{for (final file in files)
    file.path: '${(await file.stat()).size}/${(await file.stat()).modified.microsecondsSinceEpoch}'};
}

// Only the fixture's durable write seam is held; reads, retain and actual
// filesystem work delegate to the production store, without changing its owner.
final class _HeldArtworkStore implements ResourceCacheByteStore {
  _HeldArtworkStore(this.store);
  final FileResourceCacheByteStore store;
  final started = Completer<void>();
  final release = Completer<void>();
  int writesCompleted = 0;
  @override
  Future<void> write({required ResourceCacheKey key, required Uint8List bytes,
      required DateTime? expiresAt,
      ResourceCacheRetention retention = ResourceCacheRetention.transient}) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    await store.write(key: key, bytes: bytes, expiresAt: expiresAt, retention: retention);
    writesCompleted++;
  }
  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) => store.read(key);
  @override
  Future<bool> retain(ResourceCacheKey key) => store.retain(key);
  @override
  Future<void> remove(ResourceCacheKey key) => store.remove(key);
  @override
  Future<void> removeWhere(bool Function(ResourceCacheKey) predicate) => store.removeWhere(predicate);
  @override
  Future<void> clear() => store.clear();
  @override
  Future<void> close() => store.close();
}

Future<void> _seed() async {
  for (final fixture in <({String id, bool shelf, bool signal})>[
    (id: 'unshelved-history', shelf: false, signal: false),
    (id: 'unshelved-update', shelf: false, signal: true),
    (id: 'shelved-no-update', shelf: true, signal: false),
    (id: 'shelved-update', shelf: true, signal: true),
    (id: 'old-comic', shelf: false, signal: true),
  ]) {
    await _store.upsertSavedComic(SavedComicRecord.fromManifest(
      _source.manifest(fixture.id), sourceUpdateAt: fixture.signal ? _signal : null,
    ));
    await _store.saveComicPreference(ComicPreference.defaults(
      sourceId: _sourceId, comicId: fixture.id, sourceKind: ComicSourceKind.remote,
    ).copyWith(inShelf: fixture.shelf));
  }
  for (final id in <String>['unshelved-history', 'old-comic']) {
    await _store.upsertChapter(ImportedChapterRecord(
      directoryId: id, displayName: 'History chapter', sourceId: _sourceId,
      comicId: id, comicTitle: id, chapterId: '$id:chapter', sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(displayName: 'page', sourceId: 'fixture:page.png',
          pageId: 'page', contentKindHint: ContentKindHint.png),
      ],
    ));
    await _store.saveProgress(ReadingProgress(
      sourceId: _sourceId, comicId: id, chapterId: '$id:chapter', pageIndex: 0,
      subPageOffset: 0, readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 8, 9),
    ));
  }
  await _versions.saveComicVersionRelation(ComicVersionRelation(
    sourceId: _sourceId, predecessorComicId: 'old-comic',
    successorComicId: 'known-successor', discoveredAt: _signal,
  ));
}

Future<void> _mount({List<BrowsableComicSource>? sources,
    ExternalPluginController? externalPlugins, HomeServiceHandoff? serviceHandoff}) async {
  runApp(App(
    libraryStore: serviceHandoff == null ? _store : null,
    chapterDownloads: _downloads, wholeComicDownloads: _queue,
    comicSources: sources ?? <BrowsableComicSource>[_source], cacheCoordinator: _cache,
    persistHomeProjectionSnapshot: false, persistMissingPreferences: false,
    homeKey: _homeKey, preferences: _preferences, debugTrace: _trace,
    startupTelemetry: _startup,
    externalPlugins: externalPlugins,
    serviceHandoff: serviceHandoff,
  ));
  await _wait(() => _element((element) =>
    element.widget.key == homeUpdatesSectionKey) != null);
  await _frames(25);
}

Future<void> _unmount() async {
  runApp(const MaterialApp(home: SizedBox()));
  await _frames(25);
}

Future<void> _frames(int count) async {
  for (var index = 0; index < count; index++) {
    await WidgetsBinding.instance.endOfFrame;
  }
}

Future<void> _wait(bool Function() predicate, {int maxFrames = 240}) async {
  for (var index = 0; index < maxFrames; index++) {
    if (predicate()) return;
    await _frames(1);
  }
  throw StateError('Fixture UI did not settle');
}

void _check(String step, bool passed) {
  _checks.add(<String, Object?>{'step': step, 'status': passed ? 'passed' : 'failed'});
  if (!passed) throw StateError(step);
}

List<Element> _elements(bool Function(Element element) predicate, {Element? within}) {
  final found = <Element>[];
  void visit(Element element) {
    if (predicate(element)) found.add(element);
    element.visitChildren(visit);
  }
  visit(within ?? WidgetsBinding.instance.rootElement!);
  return found;
}

Element? _element(bool Function(Element element) predicate, {Element? within}) {
  final found = _elements(predicate, within: within);
  return found.isEmpty ? null : found.first;
}

ComicCoverCard? _card(String id, {Element? within}) => _element((element) =>
    element.widget is ComicCoverCard &&
    (element.widget as ComicCoverCard).comic.comicId == id,
    within: within)?.widget as ComicCoverCard?;

List<String> _updates() => _elements((element) =>
    element.widget.key is ValueKey<String> &&
    (element.widget.key! as ValueKey<String>).value.startsWith('home-update:'))
  .map((element) => (_element((child) => child.widget is ComicCoverCard,
      within: element)!.widget as ComicCoverCard).comic.comicId).toList();

Future<details.LocalComicDetailsScreen> _openDetails(String id) async {
  final card = _card(id);
  if (card == null || card.onLongPress == null) throw StateError('Missing card $id');
  card.onLongPress!();
  await _wait(() => _element((element) =>
      element.widget is details.LocalComicDetailsScreen) != null);
  await _frames(25);
  return _element((element) => element.widget is details.LocalComicDetailsScreen)!
      .widget as details.LocalComicDetailsScreen;
}

Future<void> _popDetails() async {
  final element = _element((element) => element.widget is details.LocalComicDetailsScreen ||
      element.widget is details.RemoteComicDetailsScreen)!;
  Navigator.of(element).pop();
  await _frames(25);
}

void _selectNavigation(int index) => (_element((element) =>
    element.widget is NavigationBar)!.widget as NavigationBar)
  .onDestinationSelected!(index);

final class _UpdateSource implements BrowsableComicSource {
  String description = 'Baseline metadata';
  final chapterCounts = <String, int>{};
  bool artworkMode = false;
  bool retentionBrowse = false;
  final resourceLoads = <String, int>{};
  final downloadGates = <String, Completer<void>>{};
  final slowCover = Completer<Uint8List>();
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  int comicLoads = 0;
  @override
  String get sourceId => _sourceId;
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
    sourceId: sourceId, name: '隔离首页更新源', language: 'Test',
    website: Uri.https('fixture.invalid', '/'),
  );
  ComicManifest manifest(String id) => ComicManifest(
    comic: Comic(sourceId: sourceId, comicId: id, title: id,
      authors: const <String>[], readingDirection: ReadingDirection.ltr,
      description: description,
      coverUri: artworkMode ? Uri.parse('fixture:${id.startsWith('alias-') ? 'alias' : id}') : null),
    chapters: <Chapter>[
      for (var index = 0; index < (chapterCounts[id] ?? 1); index++) Chapter(
        chapterId: index == 0 ? '$id:chapter' : '$id:chapter-$index',
        comicId: id, title: 'Chapter $index', sequence: index,
        pageCount: id.startsWith('retention-') ? 3 : 1,
        sourceRevision: 'r1',
      ),
    ],
  );
  @override
  Future<SourceBrowsePage> browse({String query = '', int offset = 0,
      int limit = 24}) async => SourceBrowsePage(
    items: <SourceComicSummary>[
      if (retentionBrowse) for (final id in offset == 0
          ? <String>['retention-cover', 'retention-late']
          : <String>[for (var index = 0; index < 24; index++) 'pressure-$index'])
        SourceComicSummary(sourceId: sourceId, comicId: id, title: id,
          authors: const <String>[], coverUri: Uri.parse('fixture:$id')),
    ],
    offset: offset, hasMore: retentionBrowse && offset == 0,
    nextOffset: retentionBrowse && offset == 0 ? 24 : null,
  );
  @override
  Future<ComicManifest> loadComic(String comicId) async {
    comicLoads++;
    return manifest(comicId);
  }
  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    if (!retentionBrowse || !chapterId.startsWith('retention-')) {
      throw StateError('No Reader source in update fixture');
    }
    final comicId = chapterId.split(':').first;
    final chapter = manifest(comicId).chapters.singleWhere((chapter) =>
      chapter.chapterId == chapterId);
    return ChapterManifest(sourceId: sourceId, comicId: comicId, chapter: chapter,
      readingDirection: ReadingDirection.ltr,
      pages: <PageAsset>[
        for (var index = 0; index < chapter.pageCount; index++) PageAsset(
          pageId: '$chapterId:page-$index', chapterId: chapterId, index: index,
          uri: Uri.parse('fixture:$comicId/page-$index.png'), width: 1, height: 1,
          byteLength: png.length, contentKindHint: ContentKindHint.png,
        ),
      ],
    );
  }
  @override
  Future<Uint8List> loadResource(Uri uri) async {
    final gate = downloadGates[uri.path];
    if (gate != null) {
      resourceLoads.update(uri.path, (count) => count + 1, ifAbsent: () => 1);
      await gate.future;
      return png;
    }
    if (!artworkMode) throw StateError('No resource transport in update fixture');
    resourceLoads.update(uri.path, (count) => count + 1, ifAbsent: () => 1);
    return uri.path == 'slow-cover' ? slowCover.future : png;
  }
}
