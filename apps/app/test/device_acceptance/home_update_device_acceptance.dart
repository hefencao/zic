import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'package:zic/app.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/debug_trace.dart';
import 'package:zic/debug_trace_export.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_shell.dart';
import 'package:zic/library_backup.dart';

// Explicit device entrypoint: production Home/details/storage owners with a
// controlled source and a fresh temporary SQLite database. It never opens the
// user's library, preferences, external plugins or download artifact index.
final _trace = DebugTraceLog();
final _preferences = AppPreferencesController();
final _checks = <Map<String, Object?>>[];
final _homeKey = GlobalKey();
const _sourceId = 'fixture:home-update';
final _signal = DateTime.utc(2026, 8, 8);
final _source = _UpdateSource();
late ImportedLibraryStore _store;
ComicVersionRelationStore get _versions => _store as ComicVersionRelationStore;
late MemoryChapterDownloadService _downloads;
late WholeComicDownloadQueue _queue;
late ResourceCacheCoordinator _cache;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(
    body: Center(child: Text('准备隔离首页更新验收')),
  )));
  await _frames(2);
  var completed = false;
  Directory? root;
  try {
    root = await Directory.systemTemp.createTemp('zic-home-update-');
    _store = await openImportedLibraryStore(root.path);
    _downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => throw StateError('No page transport in fixture'),
    );
    _queue = WholeComicDownloadQueue(downloads: _downloads);
    _cache = ResourceCacheCoordinator();
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
    completed = true;
    await _unmount();
    await _queue.close();
    await _downloads.close();
    await _cache.close();
    await _store.close();
  } on Object catch (error, stack) {
    _checks.add(<String, Object?>{
      'step': 'fixture', 'status': 'failed', 'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    final result = <String, Object?>{
      'completed': completed,
      'boundary': 'Production Home/details callbacks and SQLite reopen/backup; '
          'isolated controlled source, not a real-origin or performance acceptance.',
      'userStoresOpened': false,
      'checks': _checks,
      'comicLoads': _source.comicLoads,
      'trace': _trace.exportEvents.map((event) => event.toJson()).toList(),
      'temporaryRoot': root?.path,
    };
    await exportDebugTraceFile(
      suggestedName: 'zic-home-update-acceptance-'
          '${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(result))),
      relativeDirectory: 'Debug',
    );
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text(
      completed ? '首页更新隔离验收完成：${_checks.length} 项' : '首页更新隔离验收失败',
    )))));
    await _frames(2);
  }
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

Future<void> _mount() async {
  runApp(App(
    libraryStore: _store, chapterDownloads: _downloads, wholeComicDownloads: _queue,
    comicSources: <BrowsableComicSource>[_source], cacheCoordinator: _cache,
    persistHomeProjectionSnapshot: false, persistMissingPreferences: false,
    homeKey: _homeKey, preferences: _preferences, debugTrace: _trace,
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

Future<void> _wait(bool Function() predicate) async {
  for (var index = 0; index < 240; index++) {
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

ComicCoverCard? _card(String id) => _element((element) =>
    element.widget is ComicCoverCard &&
    (element.widget as ComicCoverCard).comic.comicId == id)?.widget as ComicCoverCard?;

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
  final element = _element((element) => element.widget is details.LocalComicDetailsScreen)!;
  Navigator.of(element).pop();
  await _frames(25);
}

void _selectNavigation(int index) => (_element((element) =>
    element.widget is NavigationBar)!.widget as NavigationBar)
  .onDestinationSelected!(index);

final class _UpdateSource implements BrowsableComicSource {
  String description = 'Baseline metadata';
  final chapterCounts = <String, int>{};
  int comicLoads = 0;
  @override
  String get sourceId => _sourceId;
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
    sourceId: _sourceId, name: '隔离首页更新源', language: 'Test',
    website: Uri.https('fixture.invalid', '/'),
  );
  ComicManifest manifest(String id) => ComicManifest(
    comic: Comic(sourceId: sourceId, comicId: id, title: id,
      authors: const <String>[], readingDirection: ReadingDirection.ltr,
      description: description),
    chapters: <Chapter>[
      for (var index = 0; index < (chapterCounts[id] ?? 1); index++) Chapter(
        chapterId: index == 0 ? '$id:chapter' : '$id:chapter-$index',
        comicId: id, title: 'Chapter $index', sequence: index, pageCount: 1,
        sourceRevision: 'r1',
      ),
    ],
  );
  @override
  Future<SourceBrowsePage> browse({String query = '', int offset = 0,
      int limit = 24}) async => SourceBrowsePage(items: const [],
        offset: offset, hasMore: false);
  @override
  Future<ComicManifest> loadComic(String comicId) async {
    comicLoads++;
    return manifest(comicId);
  }
  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw StateError('No Reader source in fixture');
  @override
  Future<Uint8List> loadResource(Uri uri) =>
      throw StateError('No resource transport in fixture');
}
