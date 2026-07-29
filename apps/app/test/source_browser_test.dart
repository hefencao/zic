import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zic/chapter_downloads.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/demo_home.dart';
import 'package:zic/main.dart';
import 'package:zic/source_browser.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

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
      final widget = tester.widget(hitTestable.first);
      if (widget is IconButton && widget.onPressed == null) {
        continue;
      }
      await tester.tap(hitTestable.first);
      await tester.pump();
      return;
    }
  }
  throw TestFailure('Timed out waiting to tap $finder');
}

void main() {
  testWidgets('third page switches and manages enabled comic sources',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final first = _FixtureSource('fixture-a', '源 A');
    final second = _FixtureSource('fixture-b', '源 B');

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[first, second],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    expect(first.browseCalls, 0);
    expect(second.browseCalls, 0);

    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(tester, find.byKey(comicSourcesPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-a', 'fixture-a-comic')),
    );

    expect(first.browseCalls, 1);
    expect(find.byKey(comicSourceManageKey), findsOneWidget);
    expect(find.byKey(comicSourceSwitcherKey), findsOneWidget);

    await tester.tap(find.byKey(comicSourceChoiceKey('fixture-b')));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-b', 'fixture-b-comic')),
    );

    await _tapVisible(tester, find.byKey(comicSourceManageKey));
    await _pumpUntilFound(tester, find.byKey(sourceManagementScreenKey));
    expect(find.byKey(sourceManagementScreenKey), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));

    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pump();
    final stored = await store.listSourcePreferences();
    expect(
      stored.singleWhere((item) => item.sourceId == 'fixture-b').enabled,
      isFalse,
    );

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(comicSourceChoiceKey('fixture-b')), findsNothing);
    expect(find.byKey(comicSourceChoiceKey('fixture-a')), findsOneWidget);
  });

  testWidgets('source network failure exposes selectable copyable details',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = Map<String, Object?>.from(call.arguments as Map);
          clipboardWrites.add(arguments['text']! as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    final failure = Failure(
      code: ErrorCode.network,
      message: 'socket failure for '
          'https://api.mangadex.org/manga?limit=24: Failed host lookup '
          '(No address associated with hostname, errno 7)',
      cause: StateError('Failed host lookup: api.mangadex.org'),
    );
    final source = _FixtureSource(
      'fixture-network',
      '网络故障源',
      browseError: failure,
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(tester, find.byKey(comicSourceErrorKey));

    expect(find.text('无法解析 api.mangadex.org'), findsOneWidget);
    final detailsText = tester.widget<SelectableText>(
      find.byKey(comicSourceErrorDetailsKey),
    );
    expect(
        detailsText.data, contains('https://api.mangadex.org/manga?limit=24'));
    expect(detailsText.data, contains('Cause: Bad state: Failed host lookup'));

    final copy = find.byKey(comicSourceCopyErrorKey);
    await _tapVisible(tester, copy);
    expect(clipboardWrites, hasLength(1));
    expect(clipboardWrites.single, detailsText.data);
  });

  testWidgets('whole comic shelf and chapter download have separate ownership',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource('fixture', '测试源');

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture', 'fixture-comic')),
    );
    await tester
        .tap(find.byKey(sourceComicCardKey('fixture', 'fixture-comic')));
    await _pumpUntilFound(
        tester, find.byKey(details.remoteComicDetailsScreenKey));

    final shelf = find.byKey(details.comicDetailsShelfKey);
    await _tapVisible(tester, shelf);

    expect(await store.getSavedComic('fixture', 'fixture-comic'), isNotNull);
    expect(await store.get('fixture', 'fixture-chapter'), isNull);
    expect(
      (await store.getComicPreference('fixture', 'fixture-comic'))?.inShelf,
      isTrue,
    );

    final download =
        details.comicDetailsDownloadKey('fixture', 'fixture-chapter');
    await _tapVisible(tester, find.byKey(download));
    await _pumpUntilFound(tester, find.textContaining('已下载'));

    final entry = await store.get('fixture', 'fixture-chapter');
    expect(entry, isNotNull);
    expect(entry!.chapter.sourceId, 'fixture');
    expect(entry.chapter.pages.single.stablePageId, 'fixture-page-1');
  });

  testWidgets(
      'central route opens remote then local details for the same source',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-route',
      '集中路由源',
      includeSecondChapter: true,
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-route', 'fixture-route-comic')),
    );
    await tester.tap(
        find.byKey(sourceComicCardKey('fixture-route', 'fixture-route-comic')));
    await _pumpUntilFound(
        tester, find.byKey(details.remoteComicDetailsScreenKey));
    expect(find.byKey(details.localComicDetailsScreenKey), findsNothing);

    final collect = find.byKey(details.comicDetailsCollectedKey);
    await _tapVisible(tester, collect);
    expect(await store.get('fixture-route', 'fixture-route-chapter'), isNull);
    expect(
      (await store.getSavedComic('fixture-route', 'fixture-route-comic'))
          ?.chapters,
      hasLength(2),
    );

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await _tapVisible(
      tester,
      find.byKey(
        sourceComicCardKey('fixture-route', 'fixture-route-comic'),
      ),
    );
    await _pumpUntilFound(
        tester, find.byKey(details.localComicDetailsScreenKey));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(details.remoteComicDetailsScreenKey), findsNothing);
    expect(
        find.byKey(sourceChapterKey('fixture-route', 'fixture-route-chapter')),
        findsOneWidget);
    expect(
      find.byKey(sourceChapterKey('fixture-route', 'fixture-route-chapter-2')),
      findsOneWidget,
    );

    final secondDownload = details.comicDetailsDownloadKey(
      'fixture-route',
      'fixture-route-chapter-2',
    );
    await _tapVisible(tester, find.byKey(secondDownload));
    await _pumpUntilFound(tester, find.textContaining('已下载'));
    expect(await store.get('fixture-route', 'fixture-route-chapter'), isNull);
    expect(
        await store.get('fixture-route', 'fixture-route-chapter-2'), isNotNull);
  });

  testWidgets(
      'pull refresh expands remote catalog without downloading chapters',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-refresh',
      '下拉更新源',
      revealSecondChapterOnRefresh: true,
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(
          sourceComicCardKey('fixture-refresh', 'fixture-refresh-comic')),
    );
    await tester.tap(find
        .byKey(sourceComicCardKey('fixture-refresh', 'fixture-refresh-comic')));
    await _pumpUntilFound(
      tester,
      find.byKey(
          sourceChapterKey('fixture-refresh', 'fixture-refresh-chapter')),
    );
    expect(
      find.byKey(
          sourceChapterKey('fixture-refresh', 'fixture-refresh-chapter-2')),
      findsNothing,
    );

    final detailsScroll = find.byKey(details.remoteComicDetailsScreenKey);
    await tester.drag(detailsScroll, const Offset(0, 520));
    await tester.pump(const Duration(milliseconds: 900));
    await _pumpUntilFound(
      tester,
      find.byKey(
          sourceChapterKey('fixture-refresh', 'fixture-refresh-chapter-2')),
    );

    expect(source.comicLoads, 2);
    expect(await store.get('fixture-refresh', 'fixture-refresh-chapter-2'),
        isNull);
    expect(
      await store.getSavedComic('fixture-refresh', 'fixture-refresh-comic'),
      isNull,
    );
  });

  testWidgets('active chapter download survives details route re-entry',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource('fixture-active', '进行中下载源');
    final pageGate = Completer<void>();
    final pageStarted = Completer<void>();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (entry, pageIndex) async {
        if (!pageStarted.isCompleted) {
          pageStarted.complete();
        }
        await pageGate.future;
        return _tinyPng();
      },
    );
    addTearDown(downloads.close);
    addTearDown(() {
      if (!pageGate.isCompleted) {
        pageGate.complete();
      }
    });

    await tester.pumpWidget(
      App(
        libraryStore: store,
        chapterDownloads: downloads,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(
        sourceComicCardKey('fixture-active', 'fixture-active-comic'),
      ),
    );
    await tester.tap(
      find.byKey(
        sourceComicCardKey('fixture-active', 'fixture-active-comic'),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(details.remoteComicDetailsScreenKey),
    );

    final downloadKey = details.comicDetailsDownloadKey(
      'fixture-active',
      'fixture-active-chapter',
    );
    await _tapVisible(tester, find.byKey(downloadKey));
    for (var frame = 0; frame < 80 && !pageStarted.isCompleted; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(pageStarted.isCompleted, isTrue);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(downloadKey),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    await _tapVisible(
      tester,
      find.byKey(
        sourceComicCardKey('fixture-active', 'fixture-active-comic'),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(details.localComicDetailsScreenKey),
    );
    await _pumpUntilFound(
      tester,
      find.descendant(
        of: find.byKey(downloadKey),
        matching: find.byType(CircularProgressIndicator),
      ),
    );

    pageGate.complete();
    await _pumpUntilFound(
      tester,
      find.descendant(
        of: find.byKey(downloadKey),
        matching: find.byIcon(Icons.download_done),
      ),
    );
  });

  testWidgets('download whole comic persists and downloads every chapter',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-whole',
      '整本下载源',
      includeSecondChapter: true,
    );
    final downloads = MemoryChapterDownloadService(
      pageLoader: (entry, pageIndex) async => _tinyPng(),
    );
    addTearDown(downloads.close);

    await tester.pumpWidget(
      App(
        libraryStore: store,
        chapterDownloads: downloads,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-whole', 'fixture-whole-comic')),
    );
    await tester.tap(
      find.byKey(sourceComicCardKey('fixture-whole', 'fixture-whole-comic')),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsDownloadAllKey),
    );
    await _tapVisible(tester, find.byKey(details.comicDetailsDownloadAllKey));

    ImportedLibraryEntry? first;
    ImportedLibraryEntry? second;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      first = await store.get('fixture-whole', 'fixture-whole-chapter');
      second = await store.get('fixture-whole', 'fixture-whole-chapter-2');
      if (first != null &&
          second != null &&
          await downloads.isDownloaded(first) &&
          await downloads.isDownloaded(second)) {
        break;
      }
    }
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(await downloads.isDownloaded(first!), isTrue);
    expect(await downloads.isDownloaded(second!), isTrue);
  });

  testWidgets('source comic details retries a transient source failure',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-retry',
      '重试源',
      failFirstComicLoad: true,
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-retry', 'fixture-retry-comic')),
    );
    await tester.tap(
        find.byKey(sourceComicCardKey('fixture-retry', 'fixture-retry-comic')));
    await _pumpUntilFound(tester, find.textContaining('漫画详情加载失败'));

    final retry = find.byKey(details.comicDetailsRetryKey);
    await _tapVisible(tester, retry);
    await _pumpUntilFound(
      tester,
      find.byKey(sourceChapterKey('fixture-retry', 'fixture-retry-chapter')),
    );
  });
}

final class _FixtureSource implements BrowsableComicSource {
  _FixtureSource(
    this.sourceId,
    this.name, {
    this.failFirstComicLoad = false,
    this.browseError,
    this.includeSecondChapter = false,
    this.revealSecondChapterOnRefresh = false,
  });

  @override
  final String sourceId;
  final String name;
  final bool failFirstComicLoad;
  final Object? browseError;
  final bool includeSecondChapter;
  final bool revealSecondChapterOnRefresh;
  int _comicLoads = 0;
  int browseCalls = 0;

  int get comicLoads => _comicLoads;

  String get _comicId => '$sourceId-comic';
  String get _chapterId => '$sourceId-chapter';
  String get _secondChapterId => '$sourceId-chapter-2';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: name,
        language: 'Test',
        website: Uri.https('example.invalid', '/$sourceId'),
      );

  Comic get _comic => Comic(
        comicId: _comicId,
        sourceId: sourceId,
        title: '$name 漫画',
        authors: const <String>['测试作者'],
        coverUri: Uri.https('example.invalid', '/$sourceId/cover.png'),
        readingDirection: ReadingDirection.ltr,
      );

  Chapter get _chapter => _chapterAt(1);

  Chapter get _secondChapter => _chapterAt(2);

  Chapter _chapterAt(int sequence) => Chapter(
        chapterId: sequence == 1 ? _chapterId : _secondChapterId,
        comicId: _comicId,
        title: '第 $sequence 话',
        sequence: sequence,
        pageCount: 1,
        sourceRevision: 'fixture-r$sequence',
      );

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async {
    browseCalls++;
    final error = browseError;
    if (error != null) {
      throw error;
    }
    final summary = SourceComicSummary(
      sourceId: sourceId,
      comicId: _comicId,
      title: _comic.title,
      authors: _comic.authors,
      coverUri: _comic.coverUri,
    );
    return SourceBrowsePage(
      items: query.isEmpty || summary.title.contains(query)
          ? <SourceComicSummary>[summary]
          : const <SourceComicSummary>[],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    expect(comicId, _comicId);
    final loadIndex = _comicLoads++;
    if (failFirstComicLoad && loadIndex == 0) {
      throw StateError('transient source failure');
    }
    final showSecond =
        includeSecondChapter || (revealSecondChapterOnRefresh && loadIndex > 0);
    return ComicManifest(
      comic: _comic,
      chapters: <Chapter>[
        _chapter,
        if (showSecond) _secondChapter,
      ],
    );
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    expect(chapterId, anyOf(_chapterId, _secondChapterId));
    final chapter = chapterId == _chapterId ? _chapter : _secondChapter;
    return ChapterManifest(
      sourceId: sourceId,
      comicId: _comicId,
      chapter: chapter,
      pages: <PageAsset>[
        PageAsset(
          pageId:
              chapterId == _chapterId ? '$sourceId-page-1' : '$sourceId-page-2',
          chapterId: chapterId,
          index: 0,
          uri: Uri.https('example.invalid', '/$sourceId/$chapterId/page-1.png'),
          contentKindHint: ContentKindHint.png,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async => _tinyPng();
}
