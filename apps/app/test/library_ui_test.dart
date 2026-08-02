import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/demo_home.dart';
import 'package:zic/download_manager.dart';
import 'package:zic/library_diagnostics.dart';
import 'package:zic/main.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

Widget _localDetailsScreen({
  required LibraryComic comic,
  required ComicPreference preference,
  required Map<String, ChapterReadState> readStates,
  required Future<void> Function(ComicPreference preference)
      onPreferenceChanged,
  required Future<void> Function(ImportedLibraryEntry chapter, bool isRead)
      onReadChanged,
  required Future<void> Function(ImportedLibraryEntry chapter) onOpenChapter,
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
    }) async =>
        MemoryEncodedResourceSource(_tinyPng()),
    reloadLibrary: ({required bool refreshContent}) async => snapshot,
    onPreferenceChanged: onPreferenceChanged,
    onReadChanged: onReadChanged,
    onOpenChapter: (
      loadChapter, {
      required bool refreshRemote,
      required String title,
    }) async =>
        onOpenChapter(await loadChapter()),
    onDownloadChapter: (_) async {},
    inspectChapterDownload: (chapter) async =>
        ChapterDownloadSnapshot.idle(chapter),
    downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
    onDownloadComic: (_) async {},
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

    await tester.pumpWidget(App(libraryStore: store));
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));

    expect(find.byKey(homeUpdatesSectionKey), findsOneWidget);
    expect(find.byKey(homeHistorySectionKey), findsOneWidget);
    final homeCover = find
        .byKey(importedChapterEntryKey(chapter.sourceId, chapter.chapterId));
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
    expect(homeCoverSize.width, ComicCoverCard.cardWidth);
    expect(homeCoverSize.height, ComicCoverCard.cardExtent);
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
    expect(tester.widget<ComicCoverCard>(first).selected, isTrue);
    expect(tester.widget<ComicCoverCard>(second).selected, isFalse);

    await tester.tap(second);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<ComicCoverCard>(first).selected, isTrue);
    expect(tester.widget<ComicCoverCard>(second).selected, isTrue);
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
    expect(find.text('暂无下载任务或离线章节'), findsOneWidget);
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
    await _tapVisible(tester, find.byKey(homeDiagnosticsKey));
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
    expect(read, isTrue);
    expect(opened, isTrue);

    await tester.drag(
      find.byKey(chapterReadKey(chapter.sourceId, chapter.chapterId)),
      const Offset(320, 0),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(read, isFalse);
  });

  testWidgets('real Mihon catalog hides a stale synthetic gallery chapter',
      (tester) async {
    final syntheticPayload = base64Url
        .encode(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'kind': 'chapter',
              'comicId': 'mihon:manga:fixture',
              'synthetic': true,
            }),
          ),
        )
        .replaceAll('=', '');
    final stale = ImportedChapterRecord(
      directoryId: 'mihon:source:mihon:manga:fixture',
      displayName: '正文',
      sourceId: 'mihon:source',
      comicId: 'mihon:manga:fixture',
      comicTitle: '远程漫画',
      chapterId: 'mihon:chapter:$syntheticPayload',
      sourceRevision: 'synthetic',
      importedAt: DateTime.utc(2026, 8, 1),
      pages: const <ImportedPageRecord>[
        ImportedPageRecord(
          displayName: '001.jpg',
          sourceId: 'https://cdn.invalid/stale.jpg',
          contentKindHint: ContentKindHint.jpeg,
        ),
      ],
    );
    const real = Chapter(
      chapterId: 'mihon:chapter:real',
      comicId: 'mihon:manga:fixture',
      title: '第一话',
      sequence: 0,
      pageCount: 0,
      sourceRevision: '/photo/1',
    );
    final reconciled = reconcileComicDetailsChapterEntries(
      entries: <ImportedLibraryEntry>[
        ImportedLibraryEntry(chapter: stale),
      ],
      sourceChapters: const <Chapter>[real],
      isCompatibilityFallback: (chapterId) => chapterId == stale.chapterId,
    );
    final comic = LibraryComic(
      sourceId: 'mihon:source',
      comicId: 'mihon:manga:fixture',
      title: '远程漫画',
      authors: const <String>[],
      tags: const <String>[],
      description: null,
      coverSourceId: null,
      readingDirection: ReadingDirection.vertical,
      chapters: reconciled,
      sourceChapters: const <Chapter>[real],
      savedAt: DateTime.utc(2026, 8, 1),
      metadataUpdatedAt: DateTime.utc(2026, 8, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: _localDetailsScreen(
          comic: comic,
          preference: ComicPreference.defaults(
            sourceId: comic.sourceId,
            comicId: comic.comicId,
          ),
          readStates: const <String, ChapterReadState>{},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (_) async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正文'), findsNothing);
    expect(find.text('第一话'), findsOneWidget);
    expect(find.text('1 章 · 页数待加载'), findsOneWidget);
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

    expect(find.text('聚合漫画'), findsOneWidget);
    expect(find.text('第 1 话'), findsOneWidget);
    expect(find.text('第 2 话'), findsOneWidget);
    expect(find.text('2 章 · 2 页'), findsOneWidget);

    await tester.tap(find.byKey(chapterReadKey('local-folder', 'chapter-2')));
    await tester.pump();
    expect(openedChapterId, 'chapter-2');
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
