import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/demo_home.dart';
import 'package:zic/main.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

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
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
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
    final homeCover = find.byKey(importedChapterEntryKey(chapter.chapterId));
    expect(homeCover, findsOneWidget);
    final homeCoverSize = tester.getSize(homeCover);

    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();

    expect(find.byKey(bookshelfPageKey), findsOneWidget);
    expect(find.byKey(bookshelfSourceFilterKey), findsOneWidget);
    expect(find.byKey(bookshelfSortKey), findsOneWidget);
    expect(find.byKey(bookshelfViewKey), findsOneWidget);
    final shelfCover = find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId));
    expect(shelfCover, findsOneWidget);
    expect(tester.getSize(shelfCover), homeCoverSize);
    expect(homeCoverSize.width, ComicCoverCard.cardWidth);
    expect(homeCoverSize.height, ComicCoverCard.cardExtent);
  });

  testWidgets('same native comic id from different sources keeps separate UI selection',
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
      ComicPreference.defaults(comicId: comicId).copyWith(inShelf: true),
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
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 320));

    expect(tester.widget<ComicCoverCard>(first).selected, isTrue);
    expect(tester.widget<ComicCoverCard>(second).selected, isFalse);
  });

  testWidgets('custom sort keeps gallery view and long-press drag order',
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

    await tester.tap(find.byKey(bookshelfSortKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.text('自定义排序'));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.byKey(bookshelfManageKey));
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byType(LongPressDraggable<String>), findsNWidgets(2));
    expect(find.byType(GridView), findsOneWidget);

    final firstCover = find.byKey(comicCoverKey(first.sourceId, first.comicId));
    final secondCover = find.byKey(comicCoverKey(second.sourceId, second.comicId));
    final gesture = await tester.startGesture(tester.getCenter(firstCover));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveTo(tester.getCenter(secondCover));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 320));

    final firstPreference = await store.getComicPreference(first.comicId);
    final secondPreference = await store.getComicPreference(second.comicId);
    expect(firstPreference, isNotNull);
    expect(secondPreference, isNotNull);
    expect(firstPreference!.customOrder, greaterThan(secondPreference!.customOrder));

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
    expect(find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId)), findsNothing);

    await tester.tap(find.byKey(bookshelfAddComicToCategoryKey));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump(const Duration(milliseconds: 320));

    final categories = await store.listCategories();
    final preference = await store.getComicPreference(chapter.comicId);
    expect(categories, hasLength(1));
    expect(preference?.categoryIds, contains(categories.single.categoryId));
    expect(find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId)), findsOneWidget);
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
    await tester.tap(find.byKey(comicCoverKey(chapter.sourceId, chapter.comicId)));
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byKey(bookshelfManagementBarKey), findsOneWidget);
    expect(find.byTooltip('移动到其他分类'), findsOneWidget);
    expect(find.byTooltip('复制漫画信息'), findsOneWidget);
    expect(find.byKey(comicDeleteKey(chapter.sourceId, chapter.comicId)), findsOneWidget);
    expect(find.byKey(comicDetailsScreenKey), findsNothing);

    await tester.tap(find.byTooltip('移动到其他分类'));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.text('移动到 分类二'));
    await tester.pump(const Duration(milliseconds: 320));

    final preference = await store.getComicPreference(chapter.comicId);
    expect(preference?.categoryIds, contains(secondCategoryId));
    expect(preference?.categoryIds, isNot(contains(firstCategoryId)));
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
                comicId: chapter.comicId,
                sourceKind: ComicSourceKind.remote,
              ),
              coverBytes: () async => _tinyPng(),
              downloadProgress: const ComicDownloadProgress(
                completedPages: 4,
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

    expect(find.text('40%\n4/10 页'), findsOneWidget);
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
        home: ComicDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[entry]),
          preference: ComicPreference.defaults(comicId: chapter.comicId),
          categories: const <LibraryCategory>[],
          readStates: const <String, ChapterReadState>{},
          coverBytes: () async => _tinyPng(),
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

    await tester.tap(find.byKey(chapterReadKey(chapter.chapterId)));
    await tester.pump();
    expect(read, isTrue);
    expect(opened, isTrue);

    await tester.drag(
      find.byKey(chapterReadKey(chapter.chapterId)),
      const Offset(320, 0),
    );
    await tester.pump(const Duration(milliseconds: 320));
    expect(read, isFalse);
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
        home: ComicDetailsScreen(
          comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[
            ImportedLibraryEntry(chapter: second),
            ImportedLibraryEntry(chapter: first),
          ]),
          preference: ComicPreference.defaults(comicId: first.comicId),
          categories: const <LibraryCategory>[],
          readStates: const <String, ChapterReadState>{},
          coverBytes: () async => _tinyPng(),
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

    await tester.tap(find.byKey(chapterReadKey('chapter-2')));
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
