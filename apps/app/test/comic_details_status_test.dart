import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/comic_details.dart' as details;

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int frames = 80,
}) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  testWidgets('description visibility rejects placeholders without losing real Unicode content', (tester) async {
    final cases = <String?, bool>{
      null: false,
      ' \n\t\u200b ': false,
      '… --- 。！': false,
      '<p>&nbsp;<br />&#160;&#xA0;</p>': false,
      '<!-- no content --><p> </p>': false,
      '&#32;&#x200b;&#x2026;': false,
      '暂无简介。': false,
      '暫無簡介': false,
      '<p>暂无简介</p>': false,
      'No description available.': false,
      'N/A': false,
      'null': false,
      '短篇': true,
      '作品介绍：冒险从这里开始。': true,
      'No description of the forest could prepare her.': true,
      '日本語のあらすじ': true,
      '한글 소개': true,
      '<p>A real synopsis &amp; more.</p>': true,
      '&#20320;&#22909;': true,
      '&#x110000;': true,
      '第一话 01': true,
    };
    var index = 0;
    for (final sample in cases.entries) {
      final preference = ComicPreference.defaults(sourceId: 'local', comicId: 'synopsis');
      final snapshot = details.ComicDetailsLibrarySnapshot(
        chapters: const <ImportedLibraryEntry>[],
        readStates: const <String, ChapterReadState>{},
        preference: preference,
      );
      await tester.pumpWidget(MaterialApp(home: details.LocalComicDetailsScreen(
        key: ValueKey<int>(index++),
        comic: LibraryComic(
          sourceId: 'local', comicId: 'synopsis', title: 'Description fixture',
          authors: const <String>[], tags: const <String>[], description: sample.key,
          coverSourceId: null, readingDirection: ReadingDirection.ltr,
          chapters: const <ImportedLibraryEntry>[], sourceChapters: const <Chapter>[],
          savedAt: DateTime(2026, 10, 27), metadataUpdatedAt: DateTime(2026, 10, 27),
        ),
        initialLibrary: snapshot,
        categories: const <LibraryCategory>[],
        loadCover: ({required String sourceId, required String comicId,
          required Uri? coverUri, required ImportedLibraryEntry? fallbackChapter,
          required String resourceRole}) async => MemoryEncodedResourceSource(_tinyPng()),
        reloadLibrary: ({required bool refreshContent}) async => snapshot,
        onPreferenceChanged: (_) async => fail('visibility must not mutate preferences'),
        onReadChanged: (_, __) async {},
        onOpenChapter: (_, {required bool refreshRemote, required String title,
          int? initialPageIndex}) async => null,
        onDownloadChapter: (_) async {},
        inspectChapterDownload: (entry) async => ChapterDownloadSnapshot.idle(entry),
        downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
        onDownloadComic: (_) async {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('简介'), sample.value ? findsOneWidget : findsNothing,
          reason: 'description: ${sample.key}');
      if (sample.value) expect(find.text(sample.key!.trim()), findsOneWidget);
      if (sample.key == null) {
        await tester.longPress(find.byKey(details.comicDetailsShelfKey));
        await tester.pumpAndSettle();
        expect(find.text('暂无书架分类，请先在书架中新建分类'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      }
    }
  });

  testWidgets(
    'long chapter catalogs keep offscreen rows unmounted across Reader return',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const sourceId = 'fixture-long-catalog';
      const comicId = 'fixture-long-comic';
      final entries = <ImportedLibraryEntry>[
        for (var index = 0; index < 500; index++)
          ImportedLibraryEntry(
            chapter: ImportedChapterRecord(
              directoryId: 'long-catalog',
              displayName: 'Chapter $index',
              sourceId: sourceId,
              comicId: comicId,
              comicTitle: 'Long catalog',
              chapterId: 'chapter-$index',
              sourceRevision: 'revision-$index',
              sequence: index,
              importedAt: DateTime(2026, 10, 7),
              pages: <ImportedPageRecord>[
                for (var page = 0; page < 5; page++)
                  ImportedPageRecord(
                    displayName: 'page-$page.png',
                    sourceId: 'memory://$index/$page.png',
                    contentKindHint: ContentKindHint.png,
                  ),
              ],
            ),
          ),
      ];
      final snapshot = details.ComicDetailsLibrarySnapshot(
        chapters: entries,
        readStates: const <String, ChapterReadState>{},
        preference: ComicPreference.defaults(
          sourceId: sourceId,
          comicId: comicId,
          sourceKind: ComicSourceKind.remote,
        ),
      );
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: details.LocalComicDetailsScreen(
            comic: LibraryComic.fromEntries(entries),
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
            onPreferenceChanged: (_) async {},
            onReadChanged: (_, __) async {},
            onOpenChapter: (
              loadChapter, {
              required bool refreshRemote,
              required String title,
              int? initialPageIndex,
            }) async {
              final entry = await loadChapter();
              opened.add(entry.chapter.chapterId);
              return ReadingProgress(
                sourceId: sourceId,
                comicId: comicId,
                chapterId: entry.chapter.chapterId,
                pageIndex: 1,
                subPageOffset: 0,
                readerMode: ReaderMode.paged,
                updatedAt: DateTime(2026, 10, 7, 12),
              );
            },
            onDownloadChapter: (_) async {},
            inspectChapterDownload: (entry) async =>
                ChapterDownloadSnapshot.idle(entry),
            downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
            onDownloadComic: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      int mountedRows() => tester.widgetList<ListTile>(find.byType(ListTile))
          .where((tile) => tile.key is ValueKey<String> &&
              (tile.key! as ValueKey<String>).value.startsWith('source-chapter:'))
          .length;
      expect(mountedRows(), inExclusiveRange(0, 40));
      final latest = find.byKey(
        details.comicDetailsChapterKey(sourceId, 'chapter-499'),
      );
      final oldest = find.byKey(
        details.comicDetailsChapterKey(sourceId, 'chapter-0'),
      );
      expect(latest, findsOneWidget);
      expect(oldest, findsNothing);
      await tester.ensureVisible(latest);
      await tester.tap(latest);
      await tester.pumpAndSettle();
      expect(opened, <String>['chapter-499']);
      expect(find.descendant(of: latest, matching: find.text('第2页')),
          findsOneWidget);
      expect(mountedRows(), inExclusiveRange(0, 40));
      final scrollable = find.descendant(
        of: find.byKey(details.localComicDetailsScreenKey),
        matching: find.byType(Scrollable),
      ).first;
      await tester.scrollUntilVisible(oldest, 1000,
          scrollable: scrollable, maxScrolls: 60);
      await tester.tap(oldest);
      await tester.pumpAndSettle();
      expect(opened, <String>['chapter-499', 'chapter-0']);
      expect(find.descendant(of: oldest, matching: find.text('第2页')),
          findsOneWidget);
      expect(mountedRows(), inExclusiveRange(0, 40));
      expect(latest, findsNothing);
    },
  );

  testWidgets(
    'chapter rows show partial progress new marker and source or sync time',
    (tester) async {
      const sourceId = 'fixture-status';
      const comicId = 'fixture-status-comic';
      const newChapterId = 'fixture-status-new';
      const syncedChapterId = 'fixture-status-synced';
      final sourceUpdatedAt = DateTime(2026, 9, 17, 8, 30);
      final syncedAt = DateTime(2026, 9, 18, 10, 30);

      List<ImportedPageRecord> pages(String chapterId, int count) =>
          <ImportedPageRecord>[
            for (var index = 0; index < count; index++)
              ImportedPageRecord(
                displayName: 'page-$index.png',
                sourceId: 'memory://$chapterId/$index',
                contentKindHint: ContentKindHint.png,
              ),
          ];

      ImportedChapterRecord record({
        required String chapterId,
        required String title,
        DateTime? sourceUpdatedAt,
        DateTime? importedAt,
      }) =>
          ImportedChapterRecord(
            directoryId: 'fixture-status-dir',
            displayName: title,
            sourceId: sourceId,
            comicId: comicId,
            comicTitle: '状态漫画',
            chapterId: chapterId,
            sourceRevision: 'rev-$chapterId',
            sequence: chapterId == newChapterId ? 1 : 2,
            sourceUpdatedAt: sourceUpdatedAt,
            importedAt: importedAt ?? syncedAt,
            pages: pages(chapterId, 5),
          );

      final partialRecord = record(
        chapterId: newChapterId,
        title: '新章节',
        sourceUpdatedAt: sourceUpdatedAt,
      );
      final syncOnlyRecord = record(
        chapterId: syncedChapterId,
        title: '同步章节',
      );
      final partialEntry = ImportedLibraryEntry(
        chapter: partialRecord,
        progress: ReadingProgress(
          sourceId: sourceId,
          comicId: comicId,
          chapterId: newChapterId,
          pageIndex: 1,
          subPageOffset: 0,
          readerMode: ReaderMode.paged,
          updatedAt: DateTime(2026, 9, 19, 11),
        ),
      );
      final syncOnlyEntry = ImportedLibraryEntry(chapter: syncOnlyRecord);
      final oldAutoReadState = ChapterReadState(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: newChapterId,
        isRead: true,
        updatedAt: DateTime(2026, 9, 19, 10),
      );
      final sourceChapters = <Chapter>[
        Chapter(
          chapterId: newChapterId,
          comicId: comicId,
          title: '新章节',
          sequence: 1,
          pageCount: 5,
          sourceRevision: 'rev-$newChapterId',
          updatedAt: sourceUpdatedAt,
        ),
        Chapter(
          chapterId: syncedChapterId,
          comicId: comicId,
          title: '同步章节',
          sequence: 2,
          pageCount: 5,
          sourceRevision: 'rev-$syncedChapterId',
        ),
      ];
      final viewed = <String>[];

      Widget buildDetails(
        ImportedLibraryEntry firstEntry, {
        Key? key,
      }) {
        final entries = <ImportedLibraryEntry>[firstEntry, syncOnlyEntry];
        final comic = LibraryComic.fromEntries(entries);
        final snapshot = details.ComicDetailsLibrarySnapshot(
          chapters: entries,
          sourceChapters: sourceChapters,
          readStates: <String, ChapterReadState>{
            details.comicDetailsChapterIdentity(sourceId, newChapterId):
                oldAutoReadState,
          },
          unseenChapterIds: const <String>{newChapterId},
          preference: ComicPreference.defaults(
            sourceId: sourceId,
            comicId: comicId,
            sourceKind: ComicSourceKind.remote,
          ),
        );
        return MaterialApp(
          home: details.LocalComicDetailsScreen(
            key: key,
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
            onPreferenceChanged: (_) async {},
            onReadChanged: (_, __) async {},
            onChapterViewed: (_, __, chapterId) async {
              viewed.add(chapterId);
            },
            onOpenChapter: (
              _, {
              required bool refreshRemote,
              required String title,
              int? initialPageIndex,
            }) async =>
                null,
            onDownloadChapter: (_) async {},
            inspectChapterDownload: (entry) async =>
                ChapterDownloadSnapshot.idle(entry),
            downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
            onDownloadComic: (_) async {},
          ),
        );
      }

      await tester.pumpWidget(buildDetails(partialEntry));
      final newTile = find.byKey(
        details.comicDetailsChapterKey(sourceId, newChapterId),
      );
      final syncTile = find.byKey(
        details.comicDetailsChapterKey(sourceId, syncedChapterId),
      );
      await _pumpUntilFound(tester, newTile);
      expect(
        find.descendant(
          of: newTile,
          matching: find.text('第2页'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.text('09-17 08:30'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.byIcon(Icons.public_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.byIcon(Icons.history),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.text('5页'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: syncTile,
          matching: find.text('09-18 10:30'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: syncTile,
          matching: find.byIcon(Icons.sync),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.byKey(
            details.comicDetailsNewChapterKey(sourceId, newChapterId),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.byIcon(Icons.check_circle_outline),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: newTile,
          matching: find.byIcon(Icons.radio_button_unchecked),
        ),
        findsNothing,
      );
      final partialOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: newTile,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(partialOpacity.opacity, 1);

      await tester.tap(newTile);
      await tester.pump();
      expect(viewed, <String>[newChapterId]);
      expect(
        find.byKey(
          details.comicDetailsNewChapterKey(sourceId, newChapterId),
        ),
        findsNothing,
      );

      final completedEntry = ImportedLibraryEntry(
        chapter: partialRecord,
        progress: partialEntry.progress!.copyWith(pageIndex: 3),
      );
      await tester.pumpWidget(
        buildDetails(
          completedEntry,
          key: const ValueKey<String>('completed-status-details'),
        ),
      );
      await _pumpUntilFound(tester, newTile);
      expect(
        find.descendant(
          of: newTile,
          matching: find.byIcon(Icons.history),
        ),
        findsNothing,
      );
      final completedOpacity = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: newTile,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(completedOpacity.opacity, 0.42);
    },
  );
}
