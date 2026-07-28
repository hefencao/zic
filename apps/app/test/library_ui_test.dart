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
    expect(find.byKey(importedChapterEntryKey(chapter.chapterId)),
        findsOneWidget);

    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();

    expect(find.byKey(bookshelfPageKey), findsOneWidget);
    expect(find.byKey(bookshelfSourceFilterKey), findsOneWidget);
    expect(find.byKey(bookshelfSortKey), findsOneWidget);
    expect(find.byKey(comicCoverKey(chapter.comicId)), findsOneWidget);
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
              entry: entry,
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
          entry: entry,
          preference: ComicPreference.defaults(comicId: chapter.comicId),
          categories: const <LibraryCategory>[],
          readState: null,
          coverBytes: () async => _tinyPng(),
          onPreferenceChanged: (value) async => saved = value,
          onReadChanged: (value) async => read = value,
          onOpenChapter: () async => opened = true,
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
    await tester.pumpAndSettle();
    expect(read, isFalse);
  });
}
