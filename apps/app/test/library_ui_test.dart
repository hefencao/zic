import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/artwork_placeholder.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/home_shell.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/download_manager.dart';
import 'package:zic/library_diagnostics.dart';
import 'package:zic/app.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/operation_hint.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

final class _CountingCanonicalSource
    implements BrowsableComicSource, CanonicalComicIdentitySource {
  @override
  String get sourceId => 'canonical-alias-fixture';

  int identityReads = 0;
  bool collapseAliases = true;

  @override
  String canonicalComicIdentity(String comicId) {
    identityReads++;
    return collapseAliases ? 'canonical-comic' : comicId;
  }

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Canonical alias fixture',
        language: 'all',
        website: Uri.https('example.invalid', '/'),
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async => SourceBrowsePage(items: const [], offset: offset, hasMore: false);

  @override
  Future<ComicManifest> loadComic(String comicId) => throw UnimplementedError();

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> loadResource(Uri uri) async => _tinyPng();
}

final class _UpdateSignalSource implements BrowsableComicSource {
  @override
  String get sourceId => 'remote:update-signal';

  String description = 'Baseline metadata';
  int comicLoads = 0;
  int chapterCount = 1;

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId, name: 'Update signal fixture', language: 'en',
        website: Uri.https('example.invalid', '/'),
      );

  ComicManifest manifest(String comicId) => ComicManifest(
        comic: Comic(
          sourceId: sourceId, comicId: comicId, title: comicId,
          authors: const <String>[], readingDirection: ReadingDirection.ltr,
          description: description,
        ),
        chapters: <Chapter>[
          for (var index = 0; index < chapterCount; index++)
            Chapter(
              chapterId: index == 0 ? '$comicId:chapter' : '$comicId:chapter-$index',
              comicId: comicId, title: 'Chapter $index',
              sequence: index, pageCount: 1, sourceRevision: 'r1',
            ),
        ],
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '', int offset = 0, int limit = 24,
  }) async => SourceBrowsePage(items: const [], offset: offset, hasMore: false);

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    comicLoads++;
    return manifest(comicId);
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw UnsupportedError('Update signal acceptance does not open Reader');

  @override
  Future<Uint8List> loadResource(Uri uri) async => _tinyPng();
}

LibraryMigrationIssue _migrationIssue(int issueId, String legacyKey) =>
    LibraryMigrationIssue(
      issueId: issueId,
      schemaFrom: 4,
      entityKind: 'comic_preference',
      legacyKey: legacyKey,
      resolvedSourceId: 'source-a',
      details: const <String, Object?>{
        'reason': 'multiple candidate sources',
        'action': 'most recent source retained',
      },
      createdAt: DateTime.utc(2026, 7, 29),
    );

final class _BlockingMigrationIssueStore implements ImportedLibraryStore {
  _BlockingMigrationIssueStore({
    required this.delegate,
    required this.releaseList,
  });

  final ImportedLibraryStore delegate;
  final Completer<void> releaseList;

  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) async {
    await releaseList.future;
    return delegate.listMigrationIssues(
      includeAcknowledged: includeAcknowledged,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BlockingAcknowledgeMigrationIssueStore
    implements ImportedLibraryStore {
  _BlockingAcknowledgeMigrationIssueStore({
    required this.delegate,
    required this.releaseAcknowledge,
    required this.acknowledgeStarted,
  });

  final ImportedLibraryStore delegate;
  final Completer<void> releaseAcknowledge;
  final Completer<void> acknowledgeStarted;

  @override
  Future<List<LibraryMigrationIssue>> listMigrationIssues({
    bool includeAcknowledged = false,
  }) =>
      delegate.listMigrationIssues(
        includeAcknowledged: includeAcknowledged,
      );

  @override
  Future<void> acknowledgeMigrationIssues(
    Iterable<int> issueIds, {
    required DateTime acknowledgedAt,
  }) async {
    if (!acknowledgeStarted.isCompleted) {
      acknowledgeStarted.complete();
    }
    await releaseAcknowledge.future;
    await delegate.acknowledgeMigrationIssues(
      issueIds,
      acknowledgedAt: acknowledgedAt,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _localDetailsScreen({
  required LibraryComic comic,
  required ComicPreference preference,
  required Map<String, ChapterReadState> readStates,
  required Future<void> Function(ComicPreference preference)
      onPreferenceChanged,
  required Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged,
  required Future<void> Function(ImportedLibraryEntry chapter) onOpenChapter,
  details.ComicDetailsChapterDownloader? onDownloadChapter,
  details.ComicDetailsChapterDeleter? onDeleteChapter,
  details.ComicDetailsDownloadActions downloadActions =
      details.ComicDetailsDownloadActions.noop,
  details.ComicDetailsComicDownloader? onDownloadComic,
  details.ComicDetailsConflictInspector? inspectComicConflicts,
}) {
  final snapshot = details.ComicDetailsLibrarySnapshot(
    chapters: comic.chapters,
    sourceChapters: comic.sourceChapters,
    readStates: readStates,
    preference: preference,
  );
  return details.LocalComicDetailsScreen(
    comic: comic,
    initialLibrary: snapshot,
    categories: const <LibraryCategory>[],
    loadCover: ({
      required String sourceId,
      required String comicId,
      required Uri? coverUri,
      required ImportedLibraryEntry? fallbackChapter,
      required String resourceRole,
    }) async =>
        MemoryEncodedResourceSource(_tinyPng()),
    reloadLibrary: ({required bool refreshContent}) async => snapshot,
    onPreferenceChanged: onPreferenceChanged,
    onReadChanged: onReadChanged,
    onOpenChapter: (
      loadChapter, {
      required bool refreshRemote,
      required String title,
      int? initialPageIndex,
    }) async {
      await onOpenChapter(await loadChapter());
      return null;
    },
    onDownloadChapter:
        onDownloadChapter ?? details.ComicDetailsDownloadActions.noop.downloadChapter,
    onDeleteChapter: onDeleteChapter,
    inspectChapterDownload: (chapter) async =>
        ChapterDownloadSnapshot.idle(chapter),
    downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
    onDownloadComic: onDownloadComic ?? (_) async {},
    inspectComicConflicts: inspectComicConflicts,
    downloadActions: downloadActions,
  );
}

ImportedChapterRecord _chapter({String name = '本地漫画'}) {
  return ImportedChapterRecord.folder(
    directoryId: '/library/$name',
    displayName: name,
    importedAt: DateTime.utc(2026, 7, 28),
    pages: const <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '001.png',
        sourceId: '/library/001.png',
        contentKindHint: ContentKindHint.png,
        mediaFormat: 'png',
        byteLength: 68,
      ),
    ],
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> _tapVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    if (finder.evaluate().isNotEmpty) {
      break;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (finder.evaluate().isEmpty) {
    throw TestFailure('Timed out waiting to find $finder');
  }
  await tester.ensureVisible(finder);
  for (var frame = 0; frame < maxFrames; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    final hitTestable = finder.hitTestable();
    if (hitTestable.evaluate().isNotEmpty) {
      await tester.tap(hitTestable.first);
      await tester.pump();
      return;
    }
  }
  throw TestFailure('Timed out waiting to tap $finder');
}

void main() {
  testWidgets('canonical alias lookup work does not grow with chapter count',
      (tester) async {
    Future<int> measure(int chapterCount, {bool verifyLiveIdentity = false}) async {
      final source = _CountingCanonicalSource();
      final store = MemoryImportedLibraryStore();
      final preferences = AppPreferencesController();
      await store.open();
      for (final comicId in <String>['alias-old', 'alias-new']) {
        await store.upsertSavedComic(
          SavedComicRecord(
            sourceId: source.sourceId,
            comicId: comicId,
            canonicalComicId: 'canonical-comic',
            title: comicId,
            coverSourceId: 'https://example.invalid/$comicId.png',
            savedAt: DateTime.utc(2026, 7, 28),
            updatedAt: DateTime.utc(2026, 7, 28),
            sourceUpdateAt: DateTime.utc(2026, 7, 29),
          ),
        );
        await store.saveComicPreference(
          ComicPreference.defaults(
            sourceId: source.sourceId,
            comicId: comicId,
            sourceKind: ComicSourceKind.remote,
          ).copyWith(
            inShelf: comicId == 'alias-old',
            liked: comicId == 'alias-old',
            collected: comicId == 'alias-new',
            categoryIds: <String>{comicId},
            customOrder: comicId == 'alias-old' ? 4 : 2,
          ),
        );
        for (var index = 0; index < chapterCount; index++) {
          await store.upsertChapter(
            ImportedChapterRecord(
              directoryId: '$comicId/$index',
              displayName: 'Chapter $index',
              sourceId: source.sourceId,
              comicId: comicId,
              chapterId: '$comicId/$index',
              sourceRevision: 'fixture-v1',
              comicTitle: comicId,
              sequence: index,
              importedAt: DateTime.utc(2026, 7, 28),
              pages: const <ImportedPageRecord>[
                ImportedPageRecord(
                  displayName: '001.png',
                  sourceId: 'https://example.invalid/page.png',
                  contentKindHint: ContentKindHint.png,
                  mediaFormat: 'png',
                  byteLength: 68,
                ),
              ],
            ),
          );
        }
      }
      await tester.pumpWidget(
        App(
          libraryStore: store,
          comicSources: <BrowsableComicSource>[source],
          preferences: preferences,
          persistHomeProjectionSnapshot: false,
        ),
      );
      await _pumpUntilFound(tester, find.byType(ComicCoverCard));
      await tester.pump(const Duration(milliseconds: 320));
      source.identityReads = 0;
      preferences.setDebugModeEnabled(!preferences.debugModeEnabled);
      await tester.pump();
      final reads = source.identityReads;
      expect(reads, greaterThan(0));
      final card = tester.widget<ComicCoverCard>(find.byType(ComicCoverCard));
      expect(card.preference.inShelf, isTrue);
      expect(card.preference.liked, isTrue);
      expect(card.preference.collected, isTrue);
      expect(card.preference.categoryIds, <String>{'alias-old', 'alias-new'});
      expect(card.preference.customOrder, 2);
      if (verifyLiveIdentity) {
        source.collapseAliases = false;
        preferences.setDebugModeEnabled(!preferences.debugModeEnabled);
        await tester.pump();
        // The active source still outranks the saved offline identity. Only
        // the old alias is in the shelf; its preference must stop inheriting
        // collection/category flags from the now-independent new alias.
        final independent =
            tester.widget<ComicCoverCard>(find.byType(ComicCoverCard));
        expect(independent.comic.comicId, 'alias-old');
        expect(independent.preference.liked, isTrue);
        expect(independent.preference.collected, isFalse);
        expect(independent.preference.categoryIds, <String>{'alias-old'});
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await store.close();
      preferences.dispose();
      return reads;
    }

    final shortCatalogReads = await measure(1);
    final longCatalogReads = await measure(60, verifyLiveIdentity: true);
    expect(
      longCatalogReads,
      lessThanOrEqualTo(shortCatalogReads + 8),
      reason: 'Unchanged comic aliases must not be resolved once per chapter',
    );
  });

  testWidgets('home update filtering bounds alias work across the catalog',
      (tester) async {
    Future<int> measure(int unchangedCount, {bool allUpdated = false}) async {
      final source = _CountingCanonicalSource()..collapseAliases = false;
      final store = MemoryImportedLibraryStore();
      final preferences = AppPreferencesController();
      await store.open();
      final comicIds = <String>[
        'updated-on',
        'updated-off',
        for (var index = 0; index < unchangedCount; index++) 'unchanged-$index',
      ];
      for (final comicId in comicIds) {
        await store.upsertSavedComic(
          SavedComicRecord(
            sourceId: source.sourceId,
            comicId: comicId,
            title: comicId,
            coverSourceId: 'https://example.invalid/$comicId.png',
            savedAt: DateTime.utc(2026, 7, 28),
            updatedAt: DateTime.utc(2026, 7, 28),
            sourceUpdateAt: allUpdated || comicId.startsWith('updated-')
                ? DateTime.utc(2026, 7, 29)
                : null,
          ),
        );
        await store.saveComicPreference(
          ComicPreference.defaults(
            sourceId: source.sourceId,
            comicId: comicId,
            sourceKind: ComicSourceKind.remote,
          ).copyWith(inShelf: comicId != 'updated-off'),
        );
      }
      await tester.pumpWidget(
        App(
          libraryStore: store,
          comicSources: <BrowsableComicSource>[source],
          preferences: preferences,
          persistHomeProjectionSnapshot: false,
        ),
      );
      await _pumpUntilFound(tester, find.byType(ComicCoverCard));
      await tester.pump(const Duration(milliseconds: 320));
      source.identityReads = 0;
      preferences.setDebugModeEnabled(!preferences.debugModeEnabled);
      await tester.pump();
      final reads = source.identityReads;
      final cards = tester.widgetList<ComicCoverCard>(find.byType(ComicCoverCard));
      expect(cards, isNotEmpty);
      expect(cards.every((card) => card.preference.inShelf), isTrue);
      expect(cards.any((card) => card.comic.comicId == 'updated-off'), isFalse);
      if (!allUpdated) expect(cards.single.comic.comicId, 'updated-on');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await store.close();
      preferences.dispose();
      return reads;
    }

    final smallReads = await measure(8);
    final largeReads = await measure(32);
    expect(smallReads, greaterThan(0));
    expect(
      largeReads,
      lessThanOrEqualTo(smallReads * 5),
      reason: 'Unchanged comics must not multiply preference alias work: '
          '$smallReads -> $largeReads',
    );
    final smallUpdatedReads = await measure(8, allUpdated: true);
    final largeUpdatedReads = await measure(32, allUpdated: true);
    expect(
      largeUpdatedReads,
      lessThanOrEqualTo(smallUpdatedReads * 5),
      reason: 'Each updated comic must not repeat a whole catalog alias scan: '
          '$smallUpdatedReads -> $largeUpdatedReads',
    );
  });

  testWidgets('home shares one catalog projection across empty sections',
      (tester) async {
    const comicCount = 12;
    final source = _CountingCanonicalSource()..collapseAliases = false;
    final store = MemoryImportedLibraryStore();
    final preferences = AppPreferencesController();
    await store.open();
    addTearDown(store.close);
    addTearDown(preferences.dispose);
    for (var index = 0; index < comicCount; index++) {
      await store.upsertSavedComic(
        SavedComicRecord(
          sourceId: source.sourceId,
          comicId: 'unchanged-$index',
          title: 'unchanged-$index',
          savedAt: DateTime.utc(2026, 7, 28),
          updatedAt: DateTime.utc(2026, 7, 28),
        ),
      );
    }
    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
        preferences: preferences,
        persistHomeProjectionSnapshot: false,
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.pump(const Duration(milliseconds: 320));
    source.identityReads = 0;
    preferences.setDebugModeEnabled(!preferences.debugModeEnabled);
    await tester.pump();
    expect(find.byKey(homeUpdatesSectionKey), findsOneWidget);
    expect(find.byKey(homeHistorySectionKey), findsOneWidget);
    expect(find.byType(ComicCoverCard), findsNothing);
    expect(source.identityReads, greaterThan(0));
    expect(
      source.identityReads,
      lessThanOrEqualTo(comicCount),
      reason: 'Sections without cards must not duplicate the catalog query',
    );
  });

  testWidgets('long reading history stays lazy across layouts and narrow windows', (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    for (var index = 0; index < 80; index++) {
      final chapter = _chapter(name: 'History $index');
      await store.upsertChapter(chapter);
      await store.saveProgress(ReadingProgress(
        sourceId: chapter.sourceId, comicId: chapter.comicId, chapterId: chapter.chapterId,
        pageIndex: 0, subPageOffset: 0, readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 10, 18).subtract(Duration(minutes: index)),
      ));
    }
    await tester.pumpWidget(App(libraryStore: store, preferences: preferences,
      persistHomeProjectionSnapshot: false));
    await _pumpUntilFound(tester, find.byType(ComicCoverCard));
    final first = _chapter(name: 'History 0');
    final firstEntry = find.byKey(historyChapterEntryKey(first.sourceId, first.chapterId));
    expect(firstEntry, findsOneWidget);
    expect(find.byType(ComicCoverCard).evaluate().length, lessThan(80),
      reason: 'vertical history must not mount every cover on startup');
    preferences.setHomeHistoryLayout(HomeHistoryLayout.list);
    await tester.pump();
    expect(firstEntry, findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(80));
    expect(find.text('History 0 · 第 1 / 1 页'), findsOneWidget);
    final tile = tester.widget<ListTile>(firstEntry);
    expect(tile.onTap, isNotNull);
    expect(tile.onLongPress, isNotNull);
    preferences.setHomeHistoryLayout(HomeHistoryLayout.carousel);
    await tester.pump();
    final carousel = tester.widget<GridView>(find.byKey(const PageStorageKey('home-history-carousel')));
    expect(carousel.scrollDirection, Axis.horizontal);
    expect((carousel.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, 2);
    expect(firstEntry, findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    preferences.setHomeHistoryColumns(6);
    preferences.setHomeHistoryLayout(HomeHistoryLayout.grid);
    await tester.pump();
    final grid = tester.widget<SliverGrid>(find.byKey(const ValueKey('home-history-grid')));
    expect((grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, 3);
    expect(preferences.homeHistoryColumns, 6,
      reason: 'a narrow window must not overwrite the saved column preference');
    expect(firstEntry, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home and bookshelf share the persisted local library',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final chapter = _chapter();
    await store.upsertChapter(chapter);
    await store.saveProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      ),
    );

    final preferences = AppPreferencesController()
      ..setHomeHistoryLayout(HomeHistoryLayout.carousel)
      ..setHomeHistoryRows(1);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(App(libraryStore: store, preferences: preferences));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));

    expect(find.byKey(homeUpdatesSectionKey), findsOneWidget);
    expect(find.byKey(homeHistorySectionKey), findsOneWidget);
    final homeCover = find
        .byKey(historyChapterEntryKey(chapter.sourceId, chapter.chapterId));
    expect(homeCover, findsOneWidget);
    final homeCoverSize = tester.getSize(homeCover);

    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();

    expect(find.byKey(bookshelfPageKey), findsOneWidget);
    expect(find.byKey(bookshelfSourceFilterKey), findsOneWidget);
    expect(find.byKey(bookshelfSortKey), findsOneWidget);
    expect(find.byKey(bookshelfViewKey), findsOneWidget);
    expect(find.byKey(downloadManagerEntryKey), findsOneWidget);
    final shelfCover =
        find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId));
    expect(shelfCover, findsOneWidget);
    expect(tester.getSize(shelfCover), homeCoverSize);
    final card = find.byType(ComicCoverCard).first;
    expect(tester.getSize(card).width, ComicCoverCard.cardWidth);
    expect(tester.getSize(card).height, ComicCoverCard.cardExtent);
  });

  testWidgets(
      'home updates require both shelf membership and a source update signal',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final updateAt = DateTime.utc(2026, 8, 8, 7);
    for (final fixture in <({String id, bool inShelf, DateTime? updateAt})>[
      (id: 'unshelved-history', inShelf: false, updateAt: null),
      (id: 'unshelved-update', inShelf: false, updateAt: updateAt),
      (id: 'shelved-no-update', inShelf: true, updateAt: null),
      (id: 'shelved-update', inShelf: true, updateAt: updateAt),
    ]) {
      await store.upsertSavedComic(
        SavedComicRecord(
          sourceId: 'remote:update-test',
          comicId: fixture.id,
          title: fixture.id,
          savedAt: DateTime.utc(2026, 8, 1),
          updatedAt: DateTime.utc(2026, 8, 1),
          sourceUpdateAt: fixture.updateAt,
        ),
      );
      await store.saveComicPreference(
        ComicPreference.defaults(
          sourceId: 'remote:update-test',
          comicId: fixture.id,
          sourceKind: ComicSourceKind.remote,
        ).copyWith(inShelf: fixture.inShelf),
      );
    }

    final history = ImportedChapterRecord(
      directoryId: 'history-only', displayName: 'History chapter',
      sourceId: 'remote:update-test', comicId: 'unshelved-history',
      comicTitle: 'unshelved-history', chapterId: 'history-chapter',
      sourceRevision: 'r1', pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'page', sourceId: 'memory:history.png', pageId: 'page',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(history);
    await store.saveProgress(ReadingProgress(
      sourceId: history.sourceId, comicId: history.comicId,
      chapterId: history.chapterId, pageIndex: 0, subPageOffset: 0,
      readerMode: ReaderMode.paged, updatedAt: DateTime.utc(2026, 10, 3),
    ));

    await tester.pumpWidget(
      App(libraryStore: store, comicSources: const <BrowsableComicSource>[]),
    );
    await _pumpUntilFound(tester, find.byType(ComicCoverCard));

    final updates = find.byWidgetPredicate((widget) =>
        widget is SizedBox && widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('home-update:'));
    final historyCards = find.byWidgetPredicate((widget) =>
        widget is SizedBox && widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('home-history:'));
    expect(updates, findsOneWidget);
    expect(historyCards, findsOneWidget);
    expect(find.descendant(of: updates, matching: find.text('shelved-update')),
        findsOneWidget);
    expect(find.descendant(of: historyCards,
        matching: find.text('unshelved-history')), findsOneWidget);
    expect(find.descendant(of: updates,
        matching: find.text('unshelved-history')), findsNothing);
    expect(find.byType(ComicCoverCard), findsNWidgets(2));
    expect(find.text('shelved-update'), findsOneWidget);
    expect(find.text('unshelved-update'), findsNothing);
    expect(find.text('shelved-no-update'), findsNothing);
  });

  testWidgets('details metadata-only refresh preserves the Home update signal',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _UpdateSignalSource();
    final signal = DateTime.utc(2026, 8, 8);
    for (final id in <String>['with-signal', 'without-signal']) {
      await store.upsertSavedComic(SavedComicRecord.fromManifest(
        source.manifest(id), sourceUpdateAt: id == 'with-signal' ? signal : null,
      ));
      await store.saveComicPreference(ComicPreference.defaults(
        sourceId: source.sourceId, comicId: id,
        sourceKind: ComicSourceKind.remote,
      ).copyWith(inShelf: true));
    }
    await tester.pumpWidget(App(
      libraryStore: store, comicSources: <BrowsableComicSource>[source],
    ));
    await _pumpUntilFound(tester, find.text('with-signal'));
    await tester.longPress(find.text('with-signal'));
    await _pumpUntilFound(tester, find.byType(details.LocalComicDetailsScreen));
    final screen = tester.widget<details.LocalComicDetailsScreen>(
        find.byType(details.LocalComicDetailsScreen));
    final before = source.comicLoads;
    source.description = 'New metadata, unchanged chapter catalog';
    await screen.reloadLibrary(refreshContent: true);
    expect(source.comicLoads, before + 1);
    final saved = (await store.getSavedComic(source.sourceId, 'with-signal'))!;
    expect(saved.description, source.description);
    expect(saved.sourceUpdateAt, signal);
    Navigator.of(tester.element(find.byType(details.LocalComicDetailsScreen)))
        .pop();
    await tester.pumpAndSettle();
    final updates = find.byWidgetPredicate((widget) =>
        widget is SizedBox && widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('home-update:'));
    expect(updates, findsOneWidget);
    expect(find.descendant(of: updates, matching: find.text('with-signal')),
        findsOneWidget);
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('without-signal'));
    await _pumpUntilFound(tester, find.byType(details.LocalComicDetailsScreen));
    final baselineScreen = tester.widget<details.LocalComicDetailsScreen>(
        find.byType(details.LocalComicDetailsScreen));
    source.description = 'Another metadata update, still the same catalog';
    await baselineScreen.reloadLibrary(refreshContent: true);
    final baseline = (await store.getSavedComic(source.sourceId,
        'without-signal'))!;
    expect(baseline.description, source.description);
    expect(baseline.sourceUpdateAt, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('first shelf admission acknowledges already discovered updates',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _UpdateSignalSource();
    final manifest = source.manifest('old-comic');
    final saved = SavedComicRecord.fromManifest(
      manifest, sourceUpdateAt: DateTime.utc(2026, 8, 8),
    );
    await store.upsertSavedComic(saved);
    await store.saveComicPreference(ComicPreference.defaults(
      sourceId: source.sourceId, comicId: 'old-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(inShelf: false));
    final chapter = ImportedChapterRecord(
      directoryId: 'before-shelf', displayName: 'History chapter',
      sourceId: source.sourceId, comicId: 'old-comic', comicTitle: 'old-comic',
      chapterId: 'old-comic:chapter', sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: 'page', sourceId: 'memory:page.png', pageId: 'page',
          contentKindHint: ContentKindHint.png,
        ),
      ],
    );
    await store.upsertChapter(chapter);
    await store.saveProgress(ReadingProgress(
      sourceId: source.sourceId, comicId: 'old-comic', chapterId: chapter.chapterId,
      pageIndex: 0, subPageOffset: 0, readerMode: ReaderMode.paged,
      updatedAt: DateTime.utc(2026, 8, 9),
    ));
    await store.saveComicVersionRelation(ComicVersionRelation(
      sourceId: source.sourceId, predecessorComicId: 'old-comic',
      successorComicId: 'known-successor', discoveredAt: DateTime.utc(2026, 8, 8),
    ));
    await tester.pumpWidget(App(
      libraryStore: store, comicSources: <BrowsableComicSource>[source],
    ));
    await _pumpUntilFound(tester, find.text('old-comic'));
    final updates = find.byWidgetPredicate((widget) =>
        widget is SizedBox && widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('home-update:'));
    expect(updates, findsNothing);
    await tester.ensureVisible(find.text('old-comic'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('old-comic'));
    await _pumpUntilFound(tester, find.byType(details.LocalComicDetailsScreen));
    final screen = tester.widget<details.LocalComicDetailsScreen>(
        find.byType(details.LocalComicDetailsScreen));
    await screen.onPreferenceChanged(ComicPreference.defaults(
      sourceId: source.sourceId, comicId: 'old-comic',
      sourceKind: ComicSourceKind.remote,
    ).copyWith(inShelf: true));
    expect((await store.getSavedComic(source.sourceId, 'old-comic'))!
        .sourceUpdateAt, isNull);
    expect(await store.listAllComicVersionRelations(), hasLength(1),
        reason: 'Acknowledging an update must preserve relation provenance');
    Navigator.of(tester.element(find.byType(details.LocalComicDetailsScreen)))
        .pop();
    await tester.pumpAndSettle();
    expect(updates, findsNothing,
        reason: 'A successor discovered before admission is not a new update');
    expect((await store.getComicPreference(source.sourceId, 'old-comic'))!
        .acknowledgedVersionComicId, 'known-successor');

    await tester.longPress(find.text('old-comic'));
    await _pumpUntilFound(tester, find.byType(details.LocalComicDetailsScreen));
    final admitted = tester.widget<details.LocalComicDetailsScreen>(
        find.byType(details.LocalComicDetailsScreen));
    final preference = ComicPreference.defaults(
      sourceId: source.sourceId, comicId: 'old-comic',
      sourceKind: ComicSourceKind.remote,
    );
    await admitted.onPreferenceChanged(preference.copyWith(liked: true));
    expect((await store.getComicPreference(source.sourceId, 'old-comic'))!
        .acknowledgedVersionComicId, 'known-successor',
        reason: 'An ordinary preference edit cannot replace the acknowledgement');
    source.chapterCount = 2;
    await admitted.reloadLibrary(refreshContent: true);
    final afterChapter = (await store.getSavedComic(source.sourceId,
        'old-comic'))!;
    expect(afterChapter.sourceUpdateAt, isNotNull);
    Navigator.of(tester.element(find.byType(details.LocalComicDetailsScreen)))
        .pop();
    await tester.pumpAndSettle();
    expect(updates, findsOneWidget,
        reason: 'A real chapter catalog change after admission is new');

    await tester.longPress(find.descendant(of: updates,
        matching: find.text('old-comic')));
    await _pumpUntilFound(tester, find.byType(details.LocalComicDetailsScreen));
    final readmission = tester.widget<details.LocalComicDetailsScreen>(
        find.byType(details.LocalComicDetailsScreen));
    await readmission.onPreferenceChanged(preference.copyWith(inShelf: false));
    await readmission.onPreferenceChanged(preference);
    final acknowledged = (await store.getSavedComic(source.sourceId,
        'old-comic'))!;
    expect(acknowledged.sourceUpdateAt, isNull);
    expect(acknowledged.unseenChapterIds, contains('old-comic:chapter-1'));
    expect(acknowledged.unseenChapterIds, isNot(contains('old-comic:chapter')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await tester.runAsync(() async {
      final downloads = MemoryChapterDownloadService(
        pageLoader: (_, __) async => Uint8List(1),
      );
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: store, chapterDownloads: downloads, wholeComicDownloads: queue,
        sources: <BrowsableComicSource>[source], ownsLibrary: false,
        ownsChapterDownloads: true, ownsWholeComicDownloads: true,
        persistSnapshot: false, waitForPrimaryFrame: () async {},
      );
      await session.ready;
      await session.upsertVersionRelation(ComicVersionRelation(
        sourceId: source.sourceId, predecessorComicId: 'known-successor',
        successorComicId: 'later-successor', discoveredAt: DateTime.now().toUtc(),
      ));
      expect(session.versionBaselines.shelfHeadFor(source.sourceId, 'old-comic'),
          'old-comic');
      expect(session.versionBaselines.latestKnownHeadFor(source.sourceId,
          'old-comic'), 'later-successor');
      await session.close();
      session.dispose();
    });
    await tester.pumpWidget(App(
      libraryStore: store, comicSources: <BrowsableComicSource>[source],
    ));
    await _pumpUntilFound(tester, updates);
    expect(updates, findsOneWidget,
        reason: 'A later successor remains visible after a restart');
    expect((await store.getSavedComic(source.sourceId, 'old-comic'))!
        .sourceUpdateAt, isNull,
        reason: 'This update is from version evidence, not a chapter signal');
    expect((await store.listAllComicVersionRelations()), hasLength(2));
    expect((await store.get(source.sourceId, chapter.chapterId))!
        .progress, isNotNull);
  });

  testWidgets('inactive bookshelf does not start cover loads', (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final chapter = _chapter(name: '延迟构建漫画');
    await store.upsertChapter(chapter);
    await store.saveProgress(
      ReadingProgress(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapterId,
        pageIndex: 0,
        subPageOffset: 0,
        readerMode: ReaderMode.paged,
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      ),
    );
    final trace = MemoryTraceSink();

    await tester.pumpWidget(
      App(
        libraryStore: store,
        startupTelemetry: HomeStartupTelemetry(
          clock: const SystemClock(),
          sink: trace,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));

    int coverRequests() => trace.events
        .where((event) => event.kind == TraceEventKind.homeCoverRequested)
        .length;

    expect(coverRequests(), 1);
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();
    expect(coverRequests(), 2);
  });

  testWidgets(
      'cached remote cover does not require a source or plugin on home',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    await store.upsertSavedComic(
      SavedComicRecord(
        sourceId: 'remote:test',
        comicId: 'cached-comic',
        title: '缓存远程漫画',
        coverSourceId: 'https://example.invalid/cached-cover.png',
        savedAt: DateTime.utc(2026, 7, 28),
        updatedAt: DateTime.utc(2026, 7, 28),
        sourceUpdateAt: DateTime.utc(2026, 7, 28),
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: 'remote:test',
        comicId: 'cached-comic',
        sourceKind: ComicSourceKind.remote,
      ).copyWith(inShelf: true),
    );

    final cache = ResourceCacheCoordinator();
    final identity = ComicResourceCacheIdentity(
      sourceId: 'remote:test',
      comicId: 'cached-comic',
    );
    await cache.responses.getOrLoadEncodedImage(
      key: ResourceCacheKey(
        kind: ResourceCacheKind.imageBytes,
        identity: identity.response('cover'),
        namespace: identity.namespace,
        revision: 'artwork-v2',
      ),
      loader: () async => _tinyPng(),
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: const <BrowsableComicSource>[],
        cacheCoordinator: cache,
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await _pumpUntilFound(tester, find.byType(Image));

    expect(find.byType(ComicCoverCard), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await cache.close();
  });

  testWidgets(
      'persisted source identity aliases collapse before plugin activation',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'mihon:fixture';
    const canonicalComicId = 'https://example.invalid/comic/42';
    for (final comicId in <String>['old-opaque-id', 'new-opaque-id']) {
      await store.upsertSavedComic(
        SavedComicRecord(
          sourceId: sourceId,
          comicId: comicId,
          canonicalComicId: canonicalComicId,
          title: '同名漫画',
          coverSourceId: 'https://example.invalid/$comicId.png',
          savedAt: DateTime.utc(2026, 7, 28),
          updatedAt: DateTime.utc(2026, 7, 28),
        ),
      );
      await store.saveComicPreference(
        ComicPreference.defaults(sourceId: sourceId, comicId: comicId)
            .copyWith(inShelf: true),
      );
    }

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: const <BrowsableComicSource>[],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byType(ComicCoverCard), findsOneWidget);
    expect(
      find.byKey(comicCoverKey(sourceId, 'new-opaque-id')),
      findsOneWidget,
    );
    expect(await store.listSavedComics(), hasLength(2));
  });

  testWidgets(
      'same native comic id from different sources keeps separate UI selection',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const comicId = 'shared-native-id';
    await store.upsertSavedComic(
      SavedComicRecord(
        sourceId: 'source-a',
        comicId: comicId,
        title: '来源 A 漫画',
        savedAt: DateTime.utc(2026, 7, 28),
        updatedAt: DateTime.utc(2026, 7, 28),
      ),
    );
    await store.upsertSavedComic(
      SavedComicRecord(
        sourceId: 'source-b',
        comicId: comicId,
        title: '来源 B 漫画',
        savedAt: DateTime.utc(2026, 7, 28),
        updatedAt: DateTime.utc(2026, 7, 28, 1),
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(sourceId: 'source-a', comicId: comicId)
          .copyWith(inShelf: true),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(sourceId: 'source-b', comicId: comicId)
          .copyWith(inShelf: true),
    );

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump(const Duration(milliseconds: 320));

    final first = find.byKey(comicCoverKey('source-a', comicId));
    final second = find.byKey(comicCoverKey('source-b', comicId));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);

    await tester.tap(find.byKey(bookshelfManageKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.longPress(first);
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byKey(bookshelfBatchBarKey), findsOneWidget);
    expect(
      tester
          .widget<ComicCoverCard>(
            find.ancestor(of: first, matching: find.byType(ComicCoverCard)),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ComicCoverCard>(
            find.ancestor(of: second, matching: find.byType(ComicCoverCard)),
          )
          .selected,
      isFalse,
    );

    await tester.tap(second);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester
          .widget<ComicCoverCard>(
            find.ancestor(of: first, matching: find.byType(ComicCoverCard)),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ComicCoverCard>(
            find.ancestor(of: second, matching: find.byType(ComicCoverCard)),
          )
          .selected,
      isTrue,
    );
    expect(find.text('已选择 2 部'), findsOneWidget);
  });

  testWidgets('download manager entry opens the task surface', (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await _tapVisible(tester, find.byKey(downloadManagerEntryKey));
    await _pumpUntilFound(tester, find.byKey(downloadManagerScreenKey));

    expect(find.byKey(downloadManagerScreenKey), findsOneWidget);
    expect(find.text('暂无手动下载任务'), findsOneWidget);
  });

  testWidgets('custom sort keeps gallery view and drag-handle order',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final first = _chapter(name: '甲漫画');
    final second = _chapter(name: '乙漫画');
    await store.upsertChapter(first);
    await store.upsertChapter(second);

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump(const Duration(milliseconds: 320));

    await _tapVisible(tester, find.byKey(bookshelfSortKey));
    await _pumpUntilFound(tester, find.byKey(bookshelfSortCustomKey));
    await tester.pump(const Duration(milliseconds: 250));
    await _tapVisible(tester, find.byKey(bookshelfSortCustomKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.byKey(bookshelfManageKey));
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byKey(comicReorderKey(first.sourceId, first.comicId)),
        findsOneWidget);
    expect(find.byKey(comicReorderKey(second.sourceId, second.comicId)),
        findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);

    final firstHandle =
        find.byKey(comicReorderKey(first.sourceId, first.comicId));
    final secondCover =
        find.byKey(comicCoverKey(second.sourceId, second.comicId));
    final initialFirstPreference =
        await store.getComicPreference(first.sourceId, first.comicId);
    final initialSecondPreference =
        await store.getComicPreference(second.sourceId, second.comicId);
    expect(initialFirstPreference, isNotNull);
    expect(initialSecondPreference, isNotNull);
    final initialOrder = initialFirstPreference!.customOrder
        .compareTo(initialSecondPreference!.customOrder);
    expect(initialOrder, isNot(0));

    final draggable = tester.widget<Draggable<String>>(firstHandle);
    final secondTarget = tester.widget<DragTarget<String>>(
      find.ancestor(
        of: secondCover,
        matching: find.byType(DragTarget<String>),
      ),
    );
    expect(
      secondTarget.onWillAcceptWithDetails!(
        DragTargetDetails<String>(
          data: draggable.data!,
          offset: tester.getCenter(secondCover),
        ),
      ),
      isTrue,
    );
    secondTarget.onAcceptWithDetails!(
      DragTargetDetails<String>(
        data: draggable.data!,
        offset: tester.getCenter(secondCover),
      ),
    );

    ComicPreference? firstPreference;
    ComicPreference? secondPreference;
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      firstPreference =
          await store.getComicPreference(first.sourceId, first.comicId);
      secondPreference =
          await store.getComicPreference(second.sourceId, second.comicId);
      if (firstPreference != null &&
          secondPreference != null &&
          firstPreference.customOrder.compareTo(secondPreference.customOrder) ==
              -initialOrder) {
        break;
      }
    }
    expect(firstPreference, isNotNull);
    expect(secondPreference, isNotNull);
    expect(
      firstPreference!.customOrder.compareTo(secondPreference!.customOrder),
      -initialOrder,
    );

    await tester.tap(find.byKey(bookshelfViewKey));
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byTooltip('切换画廊视图'), findsOneWidget);
  });

  testWidgets('plugin filters combine by source and retain selection through category swipes', (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final preferences = AppPreferencesController()..setShelfShowAllCategory(false)
      ..setShelfPluginFilterExpanded(true);
    addTearDown(preferences.dispose);
    const categoryId = 'filter-category';
    await store.upsertCategory(LibraryCategory(categoryId: categoryId, name: '筛选分类',
      sortOrder: 0, createdAt: DateTime.utc(2026, 10, 18)));
    for (final id in ['a', 'b', 'c']) {
      await store.upsertSavedComic(SavedComicRecord(sourceId: 'offline:$id', comicId: id,
        title: 'Shelf $id', savedAt: DateTime.utc(2026, 10, 18), updatedAt: DateTime.utc(2026, 10, 18)));
      await store.saveComicPreference(ComicPreference.defaults(sourceId: 'offline:$id', comicId: id,
        sourceKind: ComicSourceKind.remote).copyWith(inShelf: true,
          categoryIds: id == 'b' ? const {} : {categoryId}));
    }
    await tester.pumpWidget(App(libraryStore: store, preferences: preferences));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pumpAndSettle();
    final a = find.byKey(comicCoverKey('offline:a', 'a'));
    final b = find.byKey(comicCoverKey('offline:b', 'b'));
    final c = find.byKey(comicCoverKey('offline:c', 'c'));
    expect(find.byKey(bookshelfAllCategoryKey), findsNothing);
    expect(a, findsOneWidget);
    expect(b, findsNothing);
    expect(c, findsOneWidget);
    preferences.setShelfShowAllCategory(true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(bookshelfAllCategoryKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(bookshelfPluginChoiceKey('source:offline:a')));
    await tester.pumpAndSettle();
    expect(a, findsOneWidget);
    expect(b, findsNothing);
    await tester.longPress(find.byKey(bookshelfPluginChoiceKey('source:offline:b')));
    await tester.pumpAndSettle();
    expect(preferences.shelfPluginSourceIds, {'offline:a', 'offline:b'});
    expect(b, findsOneWidget);
    expect(c, findsNothing);
    await tester.longPress(find.byKey(bookshelfPluginChoiceKey('source:offline:b')));
    await tester.pumpAndSettle();
    expect(preferences.shelfPluginSourceIds, {'offline:a'});
    expect(b, findsNothing);
    await tester.longPress(find.byKey(bookshelfPluginChoiceKey('source:offline:b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(bookshelfPluginChoiceKey('source:offline:a')));
    await tester.pumpAndSettle();
    expect(preferences.shelfPluginSourceIds, {'offline:a'},
      reason: 'A regular tap remains single selection after long-press toggles');
    await tester.longPress(find.byKey(bookshelfPluginChoiceKey('source:offline:b')));
    await tester.pumpAndSettle();
    expect(find.text('完成多选'), findsNothing);
    await tester.tap(find.text('筛选分类'));
    await tester.pumpAndSettle();
    expect(preferences.shelfCategoryId, categoryId);
    expect(a, findsOneWidget);
    expect(b, findsNothing);
    await tester.tap(find.byKey(bookshelfManageKey));
    await tester.pumpAndSettle();
    await tester.longPress(a);
    await tester.pumpAndSettle();
    expect(find.byKey(bookshelfBatchBarKey), findsOneWidget);
    await tester.drag(find.byKey(bookshelfCategoryBarKey), const Offset(0, 90));
    await tester.pumpAndSettle();
    expect(find.byKey(bookshelfPluginBarKey), findsNothing);
    expect(find.byKey(bookshelfBatchBarKey), findsOneWidget);
    await tester.drag(find.byKey(bookshelfCategoryBarKey), const Offset(-90, 0));
    await tester.pumpAndSettle();
    expect(preferences.shelfPluginFilterExpanded, isFalse);
    await tester.drag(find.byKey(bookshelfCategoryBarKey), const Offset(0, -90));
    await tester.pumpAndSettle();
    expect(find.byKey(bookshelfPluginBarKey), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(bookshelfPluginBarKey)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(bookshelfCategoryBarKey)).dy));
    preferences.setShelfPluginFilterExpanded(false);
    await tester.pumpAndSettle();
    expect(find.byKey(bookshelfPluginBarKey), findsNothing);
    expect(find.byKey(bookshelfBatchBarKey), findsOneWidget);
    expect(preferences.shelfPluginSourceIds, {'offline:a', 'offline:b'});
    preferences.setShelfShowAllCategory(false);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('筛选分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('暂无分类'), findsOneWidget);
    expect(preferences.shelfCategoryId, isNull);
    expect(find.byKey(bookshelfAllCategoryKey), findsNothing);
    expect(a, findsOneWidget);
    expect(b, findsOneWidget);
    expect(await store.listSavedComics(), hasLength(3));
    await tester.tap(find.byKey(bookshelfSourceFilterKey));
    await tester.pumpAndSettle();
    expect(preferences.shelfSourceFilter, ShelfSourceFilter.local);
    expect(preferences.shelfPluginSourceIds, isEmpty);
    await tester.tap(find.byKey(bookshelfSourceFilterKey));
    await tester.pumpAndSettle();
    expect(preferences.shelfSourceFilter, ShelfSourceFilter.remote);
    expect(c, findsOneWidget);
    await tester.tap(find.byKey(bookshelfSourceFilterKey));
    await tester.pumpAndSettle();
    expect(preferences.shelfSourceFilter, ShelfSourceFilter.all);
  });

  testWidgets('first shelf hint waits for loaded preferences and is acknowledged by the gesture', (tester) async {
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);
    Map<String, Object?>? saved;
    await tester.pumpWidget(App(preferences: preferences));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(operationHintDismissKey), findsNothing);
    await preferences.attach(read: () async => null, write: (value) async { saved = value; });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(operationHintArrowKey), findsOneWidget);
    expect(preferences.hasSeenOperationHint(bookshelfPluginGestureHintId), isFalse);
    await tester.dragFrom(tester.getCenter(find.byKey(bookshelfCategoryBarKey)), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(find.byKey(operationHintDismissKey), findsNothing);
    expect(preferences.shelfPluginFilterExpanded, isTrue);
    expect(preferences.hasSeenOperationHint(bookshelfPluginGestureHintId), isTrue);
    await preferences.flush();
    final restored = AppPreferencesController();
    addTearDown(restored.dispose);
    await restored.attach(read: () async => saved, write: (_) async {});
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(App(preferences: restored));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pumpAndSettle();
    expect(find.byKey(operationHintDismissKey), findsNothing);
    expect(restored.shelfPluginFilterExpanded, isTrue);
  });

  testWidgets('category can add comics from the current category view',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final chapter = _chapter(name: '待分类漫画');
    await store.upsertChapter(chapter);

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump(const Duration(milliseconds: 320));

    await tester.tap(find.byKey(bookshelfAddCategoryKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.enterText(find.byType(TextField), '测试分类');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump(const Duration(milliseconds: 320));

    await tester.tap(find.text('测试分类'));
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.byKey(bookshelfAddComicToCategoryKey), findsOneWidget);
    expect(find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId)),
        findsNothing);

    await tester.tap(find.byKey(bookshelfAddComicToCategoryKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump(const Duration(milliseconds: 320));

    final categories = await store.listCategories();
    final preference =
        await store.getComicPreference(chapter.sourceId, chapter.comicId);
    expect(categories, hasLength(1));
    expect(preference?.categoryIds, contains(categories.single.categoryId));
    expect(find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId)),
        findsOneWidget);
  });

  testWidgets('management selection exposes move actions and isolates delete',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final chapter = _chapter(name: '管理漫画');
    await store.upsertChapter(chapter);
    final now = DateTime.utc(2026, 7, 28);
    const firstCategoryId = 'category-first';
    const secondCategoryId = 'category-second';
    await store.upsertCategory(
      LibraryCategory(
        categoryId: firstCategoryId,
        name: '分类一',
        sortOrder: 0,
        createdAt: now,
      ),
    );
    await store.upsertCategory(
      LibraryCategory(
        categoryId: secondCategoryId,
        name: '分类二',
        sortOrder: 1,
        createdAt: now,
      ),
    );

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.byKey(bookshelfManageKey));
    await tester.pump(const Duration(milliseconds: 320));

    final cover = find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId));
    expect(find.byKey(comicDeleteKey(chapter.sourceId, chapter.comicId)),
        findsOneWidget);
    expect(find.byKey(comicMoveKey(chapter.sourceId, chapter.comicId)),
        findsOneWidget);
    expect(find.byKey(bookshelfBatchBarKey), findsNothing);
    expect(find.byKey(comicDetailsScreenKey), findsNothing);

    await tester.tap(cover);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(bookshelfBatchBarKey), findsNothing);

    await _tapVisible(
      tester,
      find.byKey(comicMoveKey(chapter.sourceId, chapter.comicId)),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(bookshelfMoveToCategoryKey(secondCategoryId)),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await _tapVisible(
      tester,
      find.byKey(bookshelfMoveToCategoryKey(secondCategoryId)),
    );
    await tester.pump(const Duration(milliseconds: 320));

    final preference = await store.getComicPreference(
      chapter.sourceId,
      chapter.comicId,
    );
    expect(preference?.categoryIds, contains(secondCategoryId));
    expect(preference?.categoryIds, isNot(contains(firstCategoryId)));

    await tester.longPress(cover);
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.byKey(bookshelfBatchBarKey), findsOneWidget);
    expect(find.byKey(bookshelfBatchMoveKey), findsOneWidget);
    expect(find.byKey(bookshelfBatchDeleteKey), findsOneWidget);
    expect(find.byKey(comicMoveKey(chapter.sourceId, chapter.comicId)),
        findsNothing);
    expect(find.byKey(comicDeleteKey(chapter.sourceId, chapter.comicId)),
        findsNothing);
  });

  testWidgets(
      'library diagnostics acknowledges without deleting migration issues',
      (tester) async {
    final issue = LibraryMigrationIssue(
      issueId: 7,
      schemaFrom: 4,
      entityKind: 'comic_preference',
      legacyKey: 'legacy-comic',
      resolvedSourceId: 'source-a',
      details: const <String, Object?>{
        'reason': 'multiple candidate sources',
        'action': 'most recent source retained',
      },
      createdAt: DateTime.utc(2026, 7, 29),
    );
    final store = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[issue],
    );
    await store.open();
    addTearDown(store.close);

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.longPress(find.byKey(homeDiagnosticsKey));
    await tester.pump(const Duration(milliseconds: 320));
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsEntryKey));
    await tester.scrollUntilVisible(
      find.byKey(libraryDiagnosticsEntryKey),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await _tapVisible(tester, find.byKey(libraryDiagnosticsEntryKey));
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsScreenKey));
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsIssueKey(7)));

    expect(find.textContaining('comic_preference'), findsOneWidget);
    expect(find.byKey(libraryDiagnosticsCopyKey), findsOneWidget);
    await _tapVisible(
      tester,
      find.byKey(libraryDiagnosticsAcknowledgeKey(7)),
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(libraryDiagnosticsIssueKey(7)).evaluate().isEmpty) {
        break;
      }
    }

    expect(await store.listMigrationIssues(), isEmpty);
    final retained = await store.listMigrationIssues(includeAcknowledged: true);
    expect(retained, hasLength(1));
    expect(retained.single.acknowledged, isTrue);
  });

  testWidgets(
      'library diagnostics follows the current library generation for read and acknowledge',
      (tester) async {
    final firstIssue = _migrationIssue(11, 'first-generation');
    final secondIssue = _migrationIssue(12, 'second-generation');
    final firstStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[firstIssue],
    );
    final secondStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[secondIssue],
    );
    await firstStore.open();
    await secondStore.open();
    addTearDown(firstStore.close);
    addTearDown(secondStore.close);
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    ImportedLibraryStore currentStore = firstStore;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryDiagnosticsScreen(
          readStore: () => currentStore,
          storeChanges: changes,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsIssueKey(11)));

    currentStore = secondStore;
    changes.notifyListeners();
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsIssueKey(12)));
    expect(find.byKey(libraryDiagnosticsIssueKey(11)), findsNothing);

    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _tapVisible(tester, find.byKey(libraryDiagnosticsCopyKey));
    await tester.pump();
    expect(copiedText, contains('second-generation'));
    expect(copiedText, isNot(contains('first-generation')));

    await _tapVisible(
      tester,
      find.byKey(libraryDiagnosticsAcknowledgeKey(12)),
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(libraryDiagnosticsIssueKey(12)).evaluate().isEmpty) {
        break;
      }
    }

    expect(await firstStore.listMigrationIssues(), hasLength(1));
    expect(await secondStore.listMigrationIssues(), isEmpty);
    final retainedSecond =
        await secondStore.listMigrationIssues(includeAcknowledged: true);
    expect(retainedSecond.single.acknowledged, isTrue);
  });

  testWidgets(
      'library diagnostics discards an in-flight stale generation read',
      (tester) async {
    final firstStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[
        _migrationIssue(21, 'blocked-generation'),
      ],
    );
    final secondStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[
        _migrationIssue(22, 'current-generation'),
      ],
    );
    await firstStore.open();
    await secondStore.open();
    addTearDown(firstStore.close);
    addTearDown(secondStore.close);
    final releaseList = Completer<void>();
    final blockedStore = _BlockingMigrationIssueStore(
      delegate: firstStore,
      releaseList: releaseList,
    );
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    ImportedLibraryStore currentStore = blockedStore;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryDiagnosticsScreen(
          readStore: () => currentStore,
          storeChanges: changes,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(libraryDiagnosticsIssueKey(21)), findsNothing);

    currentStore = secondStore;
    changes.notifyListeners();
    releaseList.complete();
    await _pumpUntilFound(tester, find.byKey(libraryDiagnosticsIssueKey(22)));

    expect(find.byKey(libraryDiagnosticsIssueKey(21)), findsNothing);
    expect(find.byKey(libraryDiagnosticsIssueKey(22)), findsOneWidget);
  });

  testWidgets(
      'library diagnostics never replays stale issue ids into a new generation',
      (tester) async {
    final firstStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[
        _migrationIssue(31, 'stale-ack-target'),
      ],
    );
    final secondStore = MemoryImportedLibraryStore(
      migrationIssues: <LibraryMigrationIssue>[
        _migrationIssue(31, 'unrelated-current-collision'),
      ],
    );
    await firstStore.open();
    await secondStore.open();
    addTearDown(firstStore.close);
    addTearDown(secondStore.close);
    final releaseAcknowledge = Completer<void>();
    final acknowledgeStarted = Completer<void>();
    final blockedStore = _BlockingAcknowledgeMigrationIssueStore(
      delegate: firstStore,
      releaseAcknowledge: releaseAcknowledge,
      acknowledgeStarted: acknowledgeStarted,
    );
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    ImportedLibraryStore currentStore = blockedStore;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryDiagnosticsScreen(
          readStore: () => currentStore,
          storeChanges: changes,
        ),
      ),
    );
    await _pumpUntilFound(tester, find.textContaining('stale-ack-target'));

    await _tapVisible(
      tester,
      find.byKey(libraryDiagnosticsAcknowledgeKey(31)),
    );
    await tester.pump();
    expect(acknowledgeStarted.isCompleted, isTrue);

    currentStore = secondStore;
    changes.notifyListeners();
    await _pumpUntilFound(
      tester,
      find.textContaining('unrelated-current-collision'),
    );
    releaseAcknowledge.complete();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final firstRetained =
        await firstStore.listMigrationIssues(includeAcknowledged: true);
    expect(firstRetained.single.acknowledged, isTrue);
    final secondPending = await secondStore.listMigrationIssues();
    expect(secondPending, hasLength(1));
    expect(secondPending.single.legacyKey, 'unrelated-current-collision');
    expect(secondPending.single.acknowledged, isFalse);
  });

  testWidgets('cover download overlay reports waterline and page progress',
      (tester) async {
    final chapter = _chapter(name: '远程漫画');
    final entry = ImportedLibraryEntry(chapter: chapter);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 260,
            child: ComicCoverCard(
              comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
              preference: ComicPreference.defaults(
                sourceId: chapter.sourceId,
                comicId: chapter.comicId,
                sourceKind: ComicSourceKind.remote,
              ),
              coverSource: () async => MemoryEncodedResourceSource(_tinyPng()),
              coverIdentity: chapter.comicId,
              downloadProgress: const ComicDownloadProgress.active(
                label: '第 4 话',
                completedPageUnits: 4,
                totalPages: 10,
              ),
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('第 4 话\n40% · 4/10 页'), findsOneWidget);
    expect(find.text('远程漫画'), findsOneWidget);
    expect(find.textContaining('上次'), findsNothing);
  });

  testWidgets('download completion badges distinguish chapter and whole comic',
      (tester) async {
    final chapter = _chapter(name: '下载完成漫画');
    final comic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
    );
    final preference = ComicPreference.defaults(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      sourceKind: ComicSourceKind.remote,
    );

    Widget build(ComicDownloadProgress progress) => MaterialApp(
          home: Scaffold(
            body: ComicCoverCard(
              comic: comic,
              preference: preference,
              coverSource: () async => MemoryEncodedResourceSource(_tinyPng()),
              coverIdentity: chapter.comicId,
              downloadProgress: progress,
              onTap: () {},
            ),
          ),
        );

    await tester.pumpWidget(build(
      const ComicDownloadProgress.chapterComplete(),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);

    await tester.pumpWidget(build(
      const ComicDownloadProgress.comicComplete(),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(Icons.check_circle));
    expect(icon.color, Colors.green);
  });

  testWidgets('cover reloads a failed source only when the source becomes available',
      (tester) async {
    final chapter = _chapter(name: '延后来源漫画');
    final comic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
    );
    var available = false;
    var sourceAvailable = false;
    var loadCount = 0;

    Widget buildCard() => MaterialApp(
          home: Scaffold(
            body: ComicCoverCard(
              key: const ValueKey<String>('retry-cover'),
              comic: comic,
              preference: ComicPreference.defaults(
                sourceId: chapter.sourceId,
                comicId: chapter.comicId,
                sourceKind: ComicSourceKind.remote,
              ),
              coverIdentity: 'source/comic/retry-cover',
              sourceAvailable: sourceAvailable,
              coverSource: () async {
                loadCount++;
                if (!available) {
                  throw StateError('source is still activating');
                }
                return MemoryEncodedResourceSource(_tinyPng());
              },
              onTap: () {},
            ),
          ),
        );

    await tester.pumpWidget(buildCard());
    await tester.pump();
    await tester.pump();
    expect(loadCount, 1);

    available = true;
    await tester.pumpWidget(buildCard());
    await tester.pump();
    await tester.pump();
    expect(loadCount, 1);

    sourceAvailable = true;
    await tester.pumpWidget(buildCard());
    await tester.pump();
    await tester.pump();
    expect(loadCount, 2);
  });

  testWidgets('canonical cover survives changing navigation keys while pending and painted',
      (tester) async {
    final chapter = _chapter(name: '稳定封面');
    final comic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
    );
    final source = Completer<EncodedResourceSource>();
    var loads = 0;
    var tapped = 0;
    var longPressed = 0;
    Widget card(int navigation) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 150,
          child: ComicCoverCard(
            key: const ValueKey<String>('canonical-card'),
            interactionKey: ValueKey<String>('raw-chapter-$navigation'),
            comic: comic,
            preference: ComicPreference.defaults(
              sourceId: chapter.sourceId, comicId: chapter.comicId,
            ),
            coverIdentity: 'source/canonical-comic',
            coverSource: () {
              loads++;
              return source.future;
            },
            onTap: () => tapped = navigation,
            onLongPress: () => longPressed = navigation,
          ),
        ),
      ),
    );
    await tester.pumpWidget(card(1));
    await tester.pump();
    await tester.pumpWidget(card(2));
    await tester.pump();
    expect(loads, 1, reason: 'A new navigation target must preserve pending artwork');
    expect(find.byKey(const ValueKey<String>('raw-chapter-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('raw-chapter-2')));
    expect(tapped, 2);
    source.complete(MemoryEncodedResourceSource(_tinyPng()));
    await tester.pumpAndSettle();
    final image = tester.element(find.byType(StableArtworkImage));
    final decodedImage = tester.state(find.byType(Image));
    await tester.pumpWidget(card(3));
    await tester.pumpAndSettle();
    expect(loads, 1, reason: 'A new raw alias or resume chapter must preserve painted artwork');
    expect(tester.element(find.byType(StableArtworkImage)), same(image));
    expect(tester.state(find.byType(Image)), same(decodedImage));
    expect(find.byKey(const ValueKey<String>('raw-chapter-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('raw-chapter-3')));
    await tester.longPress(find.byKey(const ValueKey<String>('raw-chapter-3')));
    expect(tapped, 3);
    expect(longPressed, 3);
  });

  testWidgets('pending cover keeps the telemetry owner across rebuilds',
      (tester) async {
    final chapter = _chapter(name: '慢封面诊断');
    final comic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
    );
    final source = Completer<EncodedResourceSource>();
    final trace = MemoryTraceSink();
    final telemetry = HomeStartupTelemetry(
      clock: const SystemClock(),
      sink: trace,
    );

    Widget card(HomeStartupTelemetry? owner) => MaterialApp(
          home: Scaffold(
            body: ComicCoverCard(
              key: const ValueKey<String>('telemetry-cover'),
              comic: comic,
              preference: ComicPreference.defaults(
                sourceId: chapter.sourceId,
                comicId: chapter.comicId,
                sourceKind: ComicSourceKind.remote,
              ),
              coverSource: () => source.future,
              coverIdentity: 'source/comic/telemetry-cover',
              telemetryIdentity: 'home-history:telemetry-cover',
              startupTelemetry: owner,
              onTap: () {},
            ),
          ),
        );

    await tester.pumpWidget(card(telemetry));
    await tester.pump();
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.homeCoverRequested,
      ),
      hasLength(1),
    );

    // Home may stop assigning startup telemetry ownership on unrelated
    // projection rebuilds while the original cover Future is still pending.
    await tester.pumpWidget(card(null));
    await tester.pump();
    source.complete(MemoryEncodedResourceSource(_tinyPng()));
    await tester.pumpAndSettle();

    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.homeCoverSourceReady,
      ),
      hasLength(1),
    );
  });

  testWidgets('cover placeholder renders before final animated artwork',
      (tester) async {
    final chapter = _chapter(name: '双阶段封面');
    final comic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: chapter)],
    );
    final finalSource = Completer<EncodedResourceSource>();
    final trace = MemoryTraceSink();
    final telemetry = HomeStartupTelemetry(
      clock: const SystemClock(),
      sink: trace,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 150,
            child: ComicCoverCard(
              comic: comic,
              preference: ComicPreference.defaults(
                sourceId: chapter.sourceId,
                comicId: chapter.comicId,
                sourceKind: ComicSourceKind.remote,
              ),
              coverSource: () => finalSource.future,
              coverPlaceholderSource: () async =>
                  MemoryEncodedResourceSource(_tinyPng()),
              coverIdentity: 'dual-stage-cover',
              telemetryIdentity: 'home-history:dual-stage-cover',
              startupTelemetry: telemetry,
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(finalSource.isCompleted, isFalse);
    final readyBeforeFinal = trace.events
        .where((event) => event.kind == TraceEventKind.homeCoverSourceReady)
        .toList(growable: false);
    expect(readyBeforeFinal, hasLength(1));
    expect(readyBeforeFinal.single.payload['presentationStage'], 'placeholder');

    finalSource.complete(MemoryEncodedResourceSource(_tinyPng()));
    await tester.pumpAndSettle();

    final readyAfterFinal = trace.events
        .where((event) => event.kind == TraceEventKind.homeCoverSourceReady)
        .toList(growable: false);
    expect(readyAfterFinal, hasLength(2));
    expect(readyAfterFinal.last.payload['presentationStage'], 'final');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('home cover cards render independently from a slow cover',
      (tester) async {
    final fastChapter = _chapter(name: '快速封面');
    final slowChapter = _chapter(name: '慢速封面');
    final fastComic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: fastChapter)],
    );
    final slowComic = LibraryComic.fromEntries(
      <ImportedLibraryEntry>[ImportedLibraryEntry(chapter: slowChapter)],
    );
    final slowSource = Completer<EncodedResourceSource>();
    var fastLoads = 0;

    ComicPreference preference(ImportedChapterRecord chapter) =>
        ComicPreference.defaults(
          sourceId: chapter.sourceId,
          comicId: chapter.comicId,
          sourceKind: ComicSourceKind.remote,
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 220,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 150,
                  child: ComicCoverCard(
                    comic: fastComic,
                    preference: preference(fastChapter),
                    coverSource: () async {
                      fastLoads++;
                      return MemoryEncodedResourceSource(_tinyPng());
                    },
                    coverIdentity: fastChapter.comicId,
                    onTap: () {},
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: ComicCoverCard(
                    comic: slowComic,
                    preference: preference(slowChapter),
                    coverSource: () => slowSource.future,
                    coverIdentity: slowChapter.comicId,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(fastLoads, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is ComicCoverCard && w.comic == slowComic,
        ),
        matching: find.byType(SoftArtworkPlaceholder),
      ),
      findsOneWidget,
    );

    slowSource.complete(MemoryEncodedResourceSource(_tinyPng()));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('details persists preference and chapter read transitions',
      (tester) async {
    final chapter = _chapter();
    final entry = ImportedLibraryEntry(chapter: chapter);
    ComicPreference? saved;
    bool? read;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (value) async => saved = value,
          onReadChanged: (_, value) async => read = value,
          onOpenChapter: (_) async => opened = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('喜欢'));
    await tester.pump();
    expect(saved?.liked, isTrue);

    await tester
        .tap(find.byKey(chapterReadKey(chapter.sourceId, chapter.chapterId)));
    await tester.pump();
    expect(read, isNull);
    expect(opened, isTrue);

    await tester.drag(
      find.byKey(chapterReadKey(chapter.sourceId, chapter.chapterId)),
      const Offset(320, 0),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(read, isTrue);

    await tester.drag(
      find.byKey(chapterReadKey(chapter.sourceId, chapter.chapterId)),
      const Offset(320, 0),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(read, isFalse);
  });

  testWidgets('long pressing a cached chapter confirms and deletes it',
      (tester) async {
    final chapter = _chapter();
    final entry = ImportedLibraryEntry(chapter: chapter);
    ImportedLibraryEntry? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (_) async {},
          onDeleteChapter: (value, {deleteFiles = false}) async => deleted = value,
        ),
      ),
    );
    await tester.pump();

    await tester.longPress(
      find.byKey(details.comicDetailsChapterKey(
        chapter.sourceId,
        chapter.chapterId,
      )),
    );
    await tester.pump();
    expect(find.byKey(details.comicDetailsDeleteChapterKey(
      chapter.sourceId,
      chapter.chapterId,
    )), findsOneWidget);

    await tester.tap(find.byKey(details.comicDetailsDeleteChapterKey(
      chapter.sourceId,
      chapter.chapterId,
    )));
    await tester.pump();
    expect(deleted, same(entry));
    expect(
      find.byKey(details.comicDetailsChapterKey(
        chapter.sourceId,
        chapter.chapterId,
      )),
      findsNothing,
    );
  });

  testWidgets('left swiping reveals a delete action', (tester) async {
    final chapter = _chapter();
    final entry = ImportedLibraryEntry(chapter: chapter);
    ImportedLibraryEntry? deleted;
    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (_) async {},
          onDeleteChapter: (value, {deleteFiles = false}) async => deleted = value,
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<ListTile>(
        find.byKey(details.comicDetailsChapterKey(
          chapter.sourceId,
          chapter.chapterId,
        )),
      ).onLongPress,
      isNotNull,
    );

    await tester.drag(
      find.byKey(chapterReadKey(chapter.sourceId, chapter.chapterId)),
      const Offset(-160, 0),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(
      tester.widget<IconButton>(
        find.byKey(details.comicDetailsDeleteRevealKey(
          chapter.sourceId,
          chapter.chapterId,
        )),
      ).onPressed,
      isNotNull,
    );
    expect(
      find.byKey(details.comicDetailsDeleteRevealKey(
        chapter.sourceId,
        chapter.chapterId,
      )),
      findsOneWidget,
    );
    expect(deleted, isNull);

    await tester.tap(find.byKey(details.comicDetailsDeleteRevealKey(
      chapter.sourceId,
      chapter.chapterId,
    )));
    await tester.pump();
    expect(deleted, same(entry));
  });

  testWidgets('details groups chapters and opens the selected chapter',
      (tester) async {
    final first = _groupedChapter(
      chapterId: 'chapter-1',
      title: '第 1 话',
      sequence: 1,
    );
    final second = _groupedChapter(
      chapterId: 'chapter-2',
      title: '第 2 话',
      sequence: 2,
    );
    String? openedChapterId;
    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[
            ImportedLibraryEntry(chapter: second),
            ImportedLibraryEntry(chapter: first),
          ]),
          preference: ComicPreference.defaults(
            sourceId: first.sourceId,
            comicId: first.comicId,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (entry) async {
            openedChapterId = entry.chapter.chapterId;
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(details.localComicDetailsScreenKey), findsOneWidget);
    expect(find.text('聚合漫画'), findsWidgets);
    expect(find.text('第 1 话'), findsOneWidget);
    expect(find.text('第 2 话'), findsOneWidget);
    expect(find.text('2 章 · 2 页'), findsOneWidget);

    await tester.tap(find.byKey(chapterReadKey('local-folder', 'chapter-2')));
    await tester.pump();
    expect(openedChapterId, 'chapter-2');
  });

  testWidgets('details crosses the durable boundary before download reads or writes',
      (tester) async {
    final chapter = ImportedChapterRecord(
      directoryId: 'remote:durable-comic',
      displayName: 'Durable boundary',
      sourceId: 'remote:durable',
      comicId: 'durable-comic',
      comicTitle: 'Durable boundary',
      chapterId: 'durable-chapter',
      sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'https://example.test/durable/001.webp',
          pageId: 'p1',
          contentKindHint: ContentKindHint.webp,
        ),
      ],
    );
    final entry = ImportedLibraryEntry(chapter: chapter);
    final calls = <String>[];
    var durable = false;
    final now = DateTime.utc(2026, 8, 31);
    final placement = DownloadPlacement(
      placementId: '${chapter.sourceId}\u0000${chapter.comicId}',
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      comicTitle: chapter.comicTitle,
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'Durable boundary',
      createdAt: now,
      updatedAt: now,
    );

    Future<void> startDownload(ImportedLibraryEntry _) async {
      expect(durable, isTrue);
      calls.add('download');
    }

    final actions = details.ComicDetailsDownloadActions(
      downloadChapter: startDownload,
      stopChapter: (_) async {},
      probeExisting: ({required sourceId, required comicId, chapterId}) async {
        expect(durable, isTrue);
        calls.add('probe');
        return const DownloadExistenceReport(
          liveRunIdentities: <String>[],
          liveRunStarted: false,
          indexedReadyPages: 0,
          urlMatchedPages: 0,
        );
      },
      wholeComicJob: (_, __) async => null,
      cachedWholeComicJob: (_, __) => null,
      toggleWholeComicPause: (_, __) async {},
      inspectComicConflicts: ({
        required sourceId,
        sourceDisplayName,
        required comicId,
        required comicTitle,
        knownPredecessorComicIds,
        knownSuccessorComicIds,
        requiredDirectoryNames,
      }) async {
        throw StateError('persisted placement should skip conflict inspection');
      },
      claimComicDirectory: ({
        required sourceId,
        required comicId,
        required directoryName,
        comicTitle,
        mode = DownloadPlacementMode.createNew,
        observedOwnerKey,
      }) async {
        throw StateError('persisted placement should not be replaced');
      },
      getDownloadPlacement: ({required sourceId, required comicId}) async {
        expect(durable, isTrue);
        calls.add('placement');
        return placement;
      },
      inspectChapter: (_) async => ChapterDownloadSnapshot.idle(entry),
      ensureDurableServices: () async {
        calls.add('ensure');
        durable = true;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            sourceKind: ComicSourceKind.remote,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (_) async {},
          onDownloadChapter: startDownload,
          downloadActions: actions,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(
      tester,
      find.byKey(
        details.comicDetailsDownloadKey(
          chapter.sourceId,
          chapter.chapterId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, <String>['ensure', 'probe', 'placement', 'download']);
  });

  testWidgets('details reopens placement dialog for typed whole-comic conflict',
      (tester) async {
    final chapter = ImportedChapterRecord(
      directoryId: 'remote:governance-comic',
      displayName: '第 1 话',
      sourceId: 'remote:governance',
      comicId: 'governance-comic',
      comicTitle: '治理漫画',
      chapterId: 'governance-chapter',
      sourceRevision: 'r1',
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.webp',
          sourceId: 'https://example.test/001.webp',
          pageId: 'p1',
          contentKindHint: ContentKindHint.webp,
        ),
      ],
    );
    final entry = ImportedLibraryEntry(chapter: chapter);
    final now = DateTime.utc(2026, 8, 30);
    final job = WholeComicQueueJobSnapshot(
      jobId: 'remote:governance\u0000governance-comic',
      sourceId: 'remote:governance',
      comicId: 'governance-comic',
      comicTitle: '治理漫画',
      phase: WholeComicQueuePhase.requiresUserAction,
      completedChapters: 0,
      totalChapters: 1,
      completedPageUnits: 0,
      totalPages: 1,
      activeChapterTitles: const <String>[],
      createdAt: now,
      updatedAt: now,
      failure: 'download placement directory conflict',
      userAction: const WholeComicQueueUserAction(
        kind: WholeComicQueueUserActionKind.resolveDownloadPlacement,
        message: 'download placement directory conflict',
        chapterId: 'governance-chapter',
        chapterTitle: '第 1 话',
        directory: '自定义下载槽',
        existingOwnerKey: 'old-source\u0000old-comic',
        requestOwnerKey: 'remote:governance\u0000governance-comic',
      ),
    );
    final oldPlacement = DownloadPlacement(
      placementId: job.jobId,
      sourceId: job.sourceId,
      comicId: job.comicId,
      comicTitle: job.comicTitle,
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: '自定义下载槽',
      createdAt: now,
      updatedAt: now,
    );
    final candidate = ComicFolderCandidate(
      directoryPath: '/downloads/自定义下载槽',
      folderName: '自定义下载槽',
      manifest: ComicFolderManifest(
        sourceId: 'old-source',
        comicId: 'old-comic',
        comicTitle: '另一部漫画',
        updatedAt: now,
      ),
      observedOwnerKey: 'old-source\u0000old-comic',
      isExactMatch: false,
      isTitleMatch: true,
      chapterCount: 1,
      existingPageFilesCount: 1,
    );
    final exactCandidate = ComicFolderCandidate(
      directoryPath: '/downloads/治理漫画',
      folderName: '治理漫画',
      manifest: ComicFolderManifest(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        comicTitle: chapter.comicTitle,
        updatedAt: now,
      ),
      isExactMatch: true,
      isTitleMatch: false,
      chapterCount: 1,
      existingPageFilesCount: 1,
    );
    final report = ComicConflictReport(
      candidates: <ComicFolderCandidate>[exactCandidate, candidate],
      hasDirectExactMatch: true,
      hasTitleConflicts: true,
      recommendedDirectoryName: '治理漫画',
    );
    var queued = false;
    String? claimedDirectory;
    DownloadPlacementMode? claimedMode;
    String? claimedObservedOwner;
    Future<ComicConflictReport> inspectConflicts({
      required String sourceId,
      String? sourceDisplayName,
      required String comicId,
      required String comicTitle,
      Set<String>? knownPredecessorComicIds,
      Set<String>? knownSuccessorComicIds,
      Set<String>? requiredDirectoryNames,
    }) async {
      expect(requiredDirectoryNames, <String>{'自定义下载槽'});
      return report;
    }
    final actions = details.ComicDetailsDownloadActions(
      downloadChapter: (_) async {},
      stopChapter: (_) async {},
      probeExisting: ({required sourceId, required comicId, chapterId}) async =>
          const DownloadExistenceReport(
        liveRunIdentities: <String>[],
        liveRunStarted: false,
        indexedReadyPages: 1,
        urlMatchedPages: 0,
      ),
      wholeComicJob: (_, __) async => job,
      cachedWholeComicJob: (_, __) => job,
      toggleWholeComicPause: (_, __) async {},
      inspectComicConflicts: inspectConflicts,
      claimComicDirectory: ({
        required sourceId,
        required comicId,
        required directoryName,
        comicTitle,
        mode = DownloadPlacementMode.createNew,
        observedOwnerKey,
      }) async {
        claimedDirectory = directoryName;
        claimedMode = mode;
        claimedObservedOwner = observedOwnerKey;
      },
      getDownloadPlacement: ({required sourceId, required comicId}) async =>
          oldPlacement,
      inspectChapter: (_) async => ChapterDownloadSnapshot.idle(entry),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(
            sourceId: chapter.sourceId,
            comicId: chapter.comicId,
            sourceKind: ComicSourceKind.remote,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (_) async {},
          downloadActions: actions,
          inspectComicConflicts: inspectConflicts,
          onDownloadComic: (_) async {
            queued = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byKey(details.comicDetailsDownloadAllKey));
    await _pumpUntilFound(tester, find.text('下载任务处理'));

    expect(find.text('下载任务处理'), findsOneWidget);
    await _tapVisible(tester, find.text('新建任务（可展开对比）'));
    await tester.pump(const Duration(milliseconds: 300));
    final saveBtn = find.text('另存为新目录并新建任务');
    await _tapVisible(tester, saveBtn);
    await tester.pumpAndSettle();
    expect(queued, isTrue);
    expect(claimedDirectory, '治理漫画 (copy 2)');
    expect(claimedMode, DownloadPlacementMode.createNew);
    expect(claimedObservedOwner, isNull);
  });
}

ImportedChapterRecord _groupedChapter({
  required String chapterId,
  required String title,
  required int sequence,
}) {
  return ImportedChapterRecord(
    directoryId: '/library/$chapterId',
    displayName: title,
    sourceId: 'local-folder',
    comicId: 'comic-grouped',
    comicTitle: '聚合漫画',
    chapterId: chapterId,
    sourceRevision: 'revision-$chapterId',
    sequence: sequence,
    importedAt: DateTime.utc(2026, 7, 28, sequence),
    pages: <ImportedPageRecord>[
      ImportedPageRecord(
        displayName: '$chapterId.png',
        sourceId: '/library/$chapterId.png',
        contentKindHint: ContentKindHint.png,
        mediaFormat: 'png',
        byteLength: 68,
      ),
    ],
  );
}
