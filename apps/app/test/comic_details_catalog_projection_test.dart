import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart' show mihonChapterModelComparisonKey;
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart'
    show HomeProjectionSnapshot, chapterHasHomeProjectionSnapshotPagePlaceholders;
import 'package:zic/comic_details.dart' as details;

const _sourceId = 'mihon:catalog-projection';
const _comicId = 'catalog-projection-comic';

String _chapterId(int sequence, {String memo = 'source-memo'}) =>
    'mihon:chapter:${base64Url.encode(utf8.encode(jsonEncode(<String, Object?>{
      'kind': 'chapter',
      'comicId': 'host-parent-$sequence',
      'sequence': sequence,
      'url': '/chapter/same',
      'name': 'Source chapter',
      'memo': memo,
      'extras': <String, Object?>{'b': 2, 'a': 1},
    })))}';

ImportedLibraryEntry _entry(
  String id, {
  String sourceId = _sourceId,
  String comicId = _comicId,
  bool progress = true,
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'projection-directory',
        displayName: 'Source chapter',
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: 'Projection comic',
        chapterId: id,
        sourceRevision: 'revision-$id',
        sequence: 0,
        importedAt: DateTime(2026, 9, 20),
        pages: <ImportedPageRecord>[
          for (var index = 0; index < 5; index++)
            ImportedPageRecord(
              displayName: 'page-$index.png',
              sourceId: 'memory://$index.png',
              contentKindHint: ContentKindHint.png,
            ),
        ],
      ),
      progress: progress
          ? ReadingProgress(
              sourceId: sourceId,
              comicId: comicId,
              chapterId: id,
              pageIndex: 1,
              subPageOffset: 0,
              readerMode: ReaderMode.paged,
              updatedAt: DateTime(2026, 9, 21),
            )
          : null,
    );

Chapter _chapter(String id) => Chapter(
      chapterId: id,
      comicId: _comicId,
      title: 'Source chapter',
      sequence: 1,
      pageCount: 0,
      sourceRevision: 'revision-$id',
    );

Map<String, String> _projection(
  List<ImportedLibraryEntry> entries,
  List<Chapter> chapters,
) =>
    details.comicDetailsCatalogEntryProjection(
      sourceId: _sourceId,
      comicId: _comicId,
      sourceChapters: chapters,
      entries: entries,
      comparisonKey: mihonChapterModelComparisonKey,
    );

final class _Source extends Fake implements BrowsableComicSource {}

List<ImportedLibraryEntry> _compactEntries(List<ImportedLibraryEntry> entries) =>
    HomeProjectionSnapshot.fromJson(HomeProjectionSnapshot(
      entries: entries,
      savedComics: const <SavedComicRecord>[],
      categories: const <LibraryCategory>[],
      preferences: const <ComicPreference>[],
      readStates: const <ChapterReadState>[],
      sourcePreferences: const <ComicSourcePreference>[],
      versionRelations: const <ComicVersionRelation>[],
    ).toJson()).entries;

final class _Fixture {
  final old = _entry(_chapterId(0));
  final current = _chapter(_chapterId(1));
  final opened = <ImportedLibraryEntry>[];
  final downloaded = <ImportedLibraryEntry>[];
  final read = <ImportedLibraryEntry>[];
  final deleted = <ImportedLibraryEntry>[];
  final ensured = <String>[];

  Widget build({bool manuallyRead = false, bool cachedCurrent = false,
      String routeComicId = _comicId, bool compactEntries = false}) {
    final stored = <ImportedLibraryEntry>[
      old,
      if (cachedCurrent) _entry(current.chapterId, progress: false),
    ];
    final entries = compactEntries ? _compactEntries(stored) : stored;
    final snapshot = details.ComicDetailsLibrarySnapshot(
      chapters: entries,
      sourceChapters: <Chapter>[current],
      catalogChapterIdsByEntryIdentity:
          _projection(entries, <Chapter>[current]),
      readStates: <String, ChapterReadState>{
        if (cachedCurrent)
          details.comicDetailsChapterIdentity(_sourceId, current.chapterId):
              ChapterReadState(
                sourceId: _sourceId,
                comicId: _comicId,
                chapterId: current.chapterId,
                isRead: false,
                updatedAt: DateTime(2026, 9, 23),
              ),
        if (manuallyRead)
          old.identity: ChapterReadState(
            sourceId: _sourceId,
            comicId: _comicId,
            chapterId: old.chapter.chapterId,
            isRead: true,
            manualOverride: true,
            updatedAt: DateTime(2026, 9, 22),
          ),
      },
      preference: ComicPreference.defaults(
        sourceId: _sourceId,
        comicId: _comicId,
        sourceKind: ComicSourceKind.remote,
      ),
    );
    return MaterialApp(
      home: details.LocalComicDetailsScreen(
        comic: LibraryComic.fromEntries(<ImportedLibraryEntry>[
          routeComicId == _comicId
              ? old
              : _entry(old.chapter.chapterId, comicId: routeComicId),
        ]),
        initialLibrary: snapshot,
        categories: const <LibraryCategory>[],
        loadCover: ({
          required String sourceId,
          required String comicId,
          required Uri? coverUri,
          required ImportedLibraryEntry? fallbackChapter,
          required String resourceRole,
        }) async => MemoryEncodedResourceSource(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
          'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        )),
        reloadLibrary: ({required bool refreshContent}) async => snapshot,
        onPreferenceChanged: (_) async {},
        onReadChanged: (entry, _) async => read.add(entry),
        onOpenChapter: (
          load, {
          required bool refreshRemote,
          required String title,
          int? initialPageIndex,
        }) async {
          opened.add(await load());
          return null;
        },
        onDownloadChapter: (entry) async => downloaded.add(entry),
        onDeleteChapter: (entry, {bool deleteFiles = false}) async {
          expect(deleteFiles, isTrue);
          deleted.add(entry);
        },
        inspectChapterDownload: (entry) async =>
            ChapterDownloadSnapshot.idle(entry),
        downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
        onDownloadComic: (_) async {},
        resolveSource: (_) => _Source(),
        ensureSourceChapter: (_, _, chapter) async {
          ensured.add(chapter.chapterId);
          return _entry(chapter.chapterId, progress: false);
        },
      ),
    );
  }
}

Future<Finder> _mount(WidgetTester tester, _Fixture fixture,
    {bool manuallyRead = false, bool cachedCurrent = false,
    String routeComicId = _comicId, bool compactEntries = false}) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(fixture.build(
    manuallyRead: manuallyRead,
    cachedCurrent: cachedCurrent,
    routeComicId: routeComicId,
    compactEntries: compactEntries,
  ));
  await tester.pumpAndSettle();
  final row = find.byKey(
    details.comicDetailsChapterKey(_sourceId, fixture.current.chapterId),
  );
  await tester.ensureVisible(row);
  return row;
}

void main() {
  test('projection requires a unique complete model in the same source/comic', () {
    final old = _entry(_chapterId(0));
    final current = _chapter(_chapterId(1));
    final changedMemo = _entry(_chapterId(2, memo: 'different-source-memo'));
    final foreignSource = _entry(_chapterId(3), sourceId: 'foreign-source');
    final foreignComic = _entry(_chapterId(4), comicId: 'foreign-comic');
    final malformed = _entry('mihon:chapter:malformed');
    final entries = <ImportedLibraryEntry>[
      old, changedMemo, foreignSource, foreignComic, malformed,
    ];
    expect(_projection(entries, <Chapter>[current]),
        <String, String>{old.identity: current.chapterId});
    expect(_projection(entries, <Chapter>[current, _chapter(_chapterId(5))]),
        isEmpty);
    expect(_projection(entries, <Chapter>[current, _chapter(old.chapter.chapterId)]),
        <String, String>{old.identity: old.chapter.chapterId});
    expect(details.comicDetailsCanReuseChapterEntry(old, current), isFalse);
    expect(old.chapter.chapterId, _chapterId(0));
    expect(old.progress!.chapterId, _chapterId(0));
  });

  testWidgets('changed host identity projects one row with stored metadata',
      (tester) async {
    final fixture = _Fixture();
    final row = await _mount(tester, fixture);
    expect(find.byKey(details.comicDetailsChapterKey(
        _sourceId, fixture.old.chapter.chapterId)), findsNothing);
    expect(find.descendant(of: row, matching: find.text('5页')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('第2页')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('09-20 00:00')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(details.comicDetailsChapterCountKey),
        matching: find.text('1 章 · 5 页')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(fixture.ensured, <String>[fixture.current.chapterId]);
    expect(fixture.opened.single.chapter.chapterId, fixture.current.chapterId);
    expect(find.byKey(details.comicDetailsChapterKey(
        _sourceId, fixture.old.chapter.chapterId)), findsNothing);
    expect(fixture.old.progress!.chapterId, _chapterId(0));
  });

  for (final cachedCurrent in <bool>[false, true]) {
    testWidgets('catalog scope survives a different route alias, cached=$cachedCurrent',
        (tester) async {
      final fixture = _Fixture();
      final row = await _mount(tester, fixture,
          routeComicId: 'older-route-alias', cachedCurrent: cachedCurrent);
      expect(find.byKey(details.comicDetailsChapterKey(
          _sourceId, fixture.old.chapter.chapterId)), findsNothing);
      expect(find.descendant(of: row, matching: find.text('5页')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('第2页')), findsOneWidget);
      expect(find.descendant(of: find.byKey(details.comicDetailsChapterCountKey),
          matching: find.text('1 章 · 5 页')), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(fixture.ensured,
          cachedCurrent ? isEmpty : <String>[fixture.current.chapterId]);
      expect(fixture.opened.single.chapter.comicId, _comicId);
      expect(fixture.opened.single.chapter.chapterId, fixture.current.chapterId);
      expect(fixture.old.chapter.comicId, _comicId);
    });
  }

  testWidgets('compact Home metadata retains count without granting page reuse',
      (tester) async {
    final fixture = _Fixture();
    final compact = _compactEntries(<ImportedLibraryEntry>[
      _entry(fixture.current.chapterId, progress: false),
    ]).single;
    expect(chapterHasHomeProjectionSnapshotPagePlaceholders(compact.chapter),
        isTrue);
    expect(compact.chapter.pages.length, 5);
    expect(details.comicDetailsCanReuseChapterEntry(compact, fixture.current),
        isFalse);
    final row = await _mount(tester, fixture,
        cachedCurrent: true, compactEntries: true);
    expect(find.descendant(of: row, matching: find.text('5页')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('第2页')), findsOneWidget);
    expect(find.descendant(of: find.byKey(details.comicDetailsChapterCountKey),
        matching: find.text('1 章 · 5 页')), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(fixture.ensured, <String>[fixture.current.chapterId]);
    expect(fixture.opened.single.chapter.chapterId, fixture.current.chapterId);
    expect(chapterHasHomeProjectionSnapshotPagePlaceholders(
        fixture.opened.single.chapter), isFalse);
  });

  testWidgets('stored manual read is displayed without changing continue identity',
      (tester) async {
    final fixture = _Fixture();
    final row = await _mount(tester, fixture,
        manuallyRead: true, cachedCurrent: true);
    final opacity = tester.widget<AnimatedOpacity>(find.ancestor(
      of: row, matching: find.byType(AnimatedOpacity),
    ).first);
    expect(opacity.opacity, 0.42);
    await tester.drag(row, const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(fixture.read.single.chapter.chapterId, fixture.current.chapterId);
    expect(tester.widget<AnimatedOpacity>(find.ancestor(
      of: row, matching: find.byType(AnimatedOpacity),
    ).first).opacity, 1,
        reason: 'a current manual choice must override historical manual read');
    final resume = find.byKey(details.comicDetailsContinueReadingKey);
    await tester.ensureVisible(resume);
    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(fixture.ensured, isEmpty);
    expect(identical(fixture.opened.single, fixture.old), isTrue);
  });

  for (final action in <String>['download', 'read', 'delete']) {
    testWidgets('display matching keeps $action on the current identity',
        (tester) async {
      final fixture = _Fixture();
      final row = await _mount(tester, fixture);
      switch (action) {
        case 'download':
          await tester.tap(find.byKey(details.comicDetailsDownloadKey(
            _sourceId, fixture.current.chapterId,
          )));
          break;
        case 'read':
          await tester.drag(row, const Offset(150, 0));
          break;
        case 'delete':
          await tester.drag(row, const Offset(-100, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(details.comicDetailsDeleteRevealKey(
            _sourceId, fixture.current.chapterId,
          )));
          break;
      }
      await tester.pumpAndSettle();
      final entries = switch (action) {
        'download' => fixture.downloaded,
        'read' => fixture.read,
        _ => fixture.deleted,
      };
      expect(fixture.ensured, <String>[fixture.current.chapterId]);
      expect(entries.single.chapter.chapterId, fixture.current.chapterId);
      expect(fixture.old.chapter.chapterId, _chapterId(0));
    });
  }
}
