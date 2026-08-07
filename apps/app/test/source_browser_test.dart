import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/demo_home.dart';
import 'package:zic/main.dart';
import 'package:zic/source_browser.dart';
import 'package:zic/webp_demo.dart';

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

  testWidgets('source-owned sections floating search and bottom pager preserve order',
      (tester) async {
    final native = _FixtureSource(
      'fixture-native',
      '原生源',
      browseItemCount: 30,
      browseSections: const <SourceBrowseSection>[
        SourceBrowseSection(sectionId: 'popular', label: '热门'),
        SourceBrowseSection(sectionId: 'latest', label: '最新'),
      ],
      searchFilters: const <SourceSearchFilterOption>[
        SourceSearchFilterOption(
          filterId: 'status:check',
          label: '已完结',
        ),
        SourceSearchFilterOption(
          filterId: 'sort:select:0',
          label: '排序：热门',
          selected: true,
        ),
        SourceSearchFilterOption(
          filterId: 'sort:select:1',
          label: '排序：最新',
        ),
      ],
    );
    final mihon = _FixtureSource('mihon:fixture-zh', 'Mihon 中文源');
    final venera = _FixtureSource('venera:fixture-en', 'Venera English');
    var activeSourceId = native.sourceId;
    final searches = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ComicSourcesPage(
              sources: <BrowsableComicSource>[native, mihon, venera],
              activeSourceId: activeSourceId,
              onSourceSelected: (sourceId) {
                setState(() => activeSourceId = sourceId);
              },
              searchHistory: const <String>['漫画'],
              onSearchCommitted: searches.add,
              loadCover: (_, __, ___) async =>
                  MemoryEncodedResourceSource(_tinyPng()),
              onOpenComic: (_, __) async {},
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(native.sourceId, '${native.sourceId}-comic-0')),
    );
    expect(find.byKey(comicSourceCategoryKey('popular')), findsOneWidget);
    expect(find.byKey(comicSourceCategoryKey('latest')), findsOneWidget);
    expect(find.byKey(comicSourceCategoryKey('mihon')), findsNothing);
    expect(find.byKey(comicSourceChoiceKey(native.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourceChoiceKey(mihon.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourceChoiceKey(venera.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourcePagerKey), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    expect(find.byKey(comicSourceSearchKey), findsOneWidget);
    expect(find.byKey(comicSourceFilterBarKey), findsOneWidget);
    expect(find.byKey(comicSourceFilterKey('status:check')), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    await _tapVisible(tester, find.byKey(comicSourceFilterKey('status:check')));
    await tester.pump();
    expect(native.lastSelectedFilterIds, contains('status:check'));
    expect(native.lastSelectedFilterIds, contains('sort:select:0'));

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    expect(find.byKey(comicSourceSearchFabKey), findsOneWidget);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await tester.drag(
      find.byKey(comicSourceSearchKey),
      const Offset(0, -80),
    );
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await _tapVisible(tester, find.text('漫画'));
    expect(searches, <String>['漫画']);

    final refresh = tester.state<RefreshIndicatorState>(
      find.byKey(comicSourcePullRefreshKey),
    );
    final browseCallsBeforeRefresh = native.browseCalls;
    await refresh.show();
    await tester.pump();
    expect(native.browseCalls, greaterThan(browseCallsBeforeRefresh));

    await tester.scrollUntilVisible(
      find.byKey(comicSourcePagerKey),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('第 1 页'), findsOneWidget);
    await _tapVisible(tester, find.byKey(comicSourceNextPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(native.sourceId, '${native.sourceId}-comic-24')),
    );
    expect(find.text('第 2 页'), findsOneWidget);

    await _tapVisible(tester, find.byKey(comicSourceCategoryKey('latest')));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(native.sourceId, '${native.sourceId}-comic-0')),
    );
    expect(native.lastBrowseSection, 'latest');
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

  testWidgets('verification failure opens source WebView then retries',
      (tester) async {
    final source = _FixtureSource(
      'mihon:verification',
      '验证源',
      browseError: const Failure(
        code: ErrorCode.sourceVerificationRequired,
        message: 'source-verification-required: Cloudflare verification failed',
        details: <String, Object?>{
          'requestUrl': 'https://18comic.vip/albums?o=mv&page=1',
          'statusCode': 403,
          'clearanceCookiePresent': false,
        },
      ),
    );
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___) async =>
                throw StateError('cover should not load'),
            onOpenComic: (_, __) async {},
            onOpenSourceWebView: (_, url, {required cloudflareVerification}) async {
              expect(url, Uri.parse('https://18comic.vip/albums?o=mv&page=1'));
              expect(cloudflareVerification, isTrue);
              webViewOpens++;
            },
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(comicSourceOpenWebViewKey));
    expect(find.text('漫画源需要完成网页验证'), findsOneWidget);
    await _tapVisible(tester, find.byKey(comicSourceOpenWebViewKey));
    expect(webViewOpens, 1);
    expect(source.browseCalls, greaterThanOrEqualTo(2));

    await _tapVisible(tester, find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 400));
    expect(webViewOpens, 1);
  });

  testWidgets('forced retry falls back to source WebView once',
      (tester) async {
    final source = _FixtureSource(
      'mihon:verification-refresh',
      '强制刷新验证源',
      browseError: const Failure(
        code: ErrorCode.sourceVerificationRequired,
        message: 'source-verification-required: Cloudflare verification failed',
      ),
    );
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___) async =>
                throw StateError('cover should not load'),
            onOpenComic: (_, __) async {},
            onOpenSourceWebView: (_, __, {required cloudflareVerification}) async {
              expect(cloudflareVerification, isTrue);
              webViewOpens++;
            },
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(comicSourceErrorKey));
    await _tapVisible(tester, find.byIcon(Icons.refresh));
    for (var frame = 0; frame < 80 && webViewOpens == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(webViewOpens, 1);
    expect(source.browseCalls, greaterThanOrEqualTo(3));

    // The browser handoff itself may be unable to make the runtime transport
    // acceptable to the site. A later ordinary retry must not automatically
    // reopen the same browser forever; manual verification remains available.
    await _tapVisible(tester, find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 400));
    expect(webViewOpens, 1);

    await _tapVisible(tester, find.byKey(comicSourceOpenWebViewKey));
    expect(webViewOpens, 2);
  });

  testWidgets('clearance rejected by Cloudflare does not auto reopen WebView',
      (tester) async {
    final source = _FixtureSource(
      'mihon:verification-clearance-rejected',
      '已有 clearance 的验证源',
      browseError: const Failure(
        code: ErrorCode.sourceVerificationRequired,
        message: 'source-verification-required: Cloudflare verification required',
        details: <String, Object?>{
          'requestUrl': 'https://18comic.vip/albums?o=mv&page=1',
          'statusCode': 403,
          'clearanceCookiePresent': true,
        },
      ),
    );
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___) async =>
                throw StateError('cover should not load'),
            onOpenComic: (_, __) async {},
            onOpenSourceWebView: (_, url, {required cloudflareVerification}) async {
              expect(url, Uri.parse('https://18comic.vip/albums?o=mv&page=1'));
              expect(cloudflareVerification, isTrue);
              webViewOpens++;
            },
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(comicSourceErrorKey));
    await _tapVisible(tester, find.byIcon(Icons.refresh));
    await tester.pump(const Duration(milliseconds: 400));
    expect(webViewOpens, 0);
    expect(find.textContaining('已携带 cf_clearance'), findsOneWidget);

    await _tapVisible(tester, find.byKey(comicSourceOpenWebViewKey));
    expect(webViewOpens, 1);
  });

  testWidgets('verification retry resolves the replacement runtime source',
      (tester) async {
    final stale = _FixtureSource(
      'mihon:replacement',
      '旧运行时',
      browseError: const Failure(
        code: ErrorCode.sourceVerificationRequired,
        message: 'source-verification-required: verification required',
      ),
    );
    final replacement = _FixtureSource(
      stale.sourceId,
      '新运行时',
    );
    BrowsableComicSource current = stale;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[stale],
            activeSourceId: stale.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___) async =>
                throw StateError('cover should not load'),
            onOpenComic: (_, __) async {},
            onOpenSourceWebView: (_, __, {required cloudflareVerification}) async {
              current = replacement;
            },
            resolveSource: (sourceId) =>
                current.sourceId == sourceId ? current : null,
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(comicSourceErrorKey));
    await _tapVisible(tester, find.byIcon(Icons.refresh));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(replacement.sourceId, replacement._comicId)),
    );

    expect(stale.browseCalls, greaterThanOrEqualTo(2));
    expect(replacement.browseCalls, greaterThanOrEqualTo(1));
    expect(find.byKey(comicSourceErrorKey), findsNothing);
  });

  testWidgets('cover verification failure exposes its source WebView action',
      (tester) async {
    final source = _FixtureSource('mihon:cover-verification', '封面验证源');
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___) async => throw const Failure(
              code: ErrorCode.sourceVerificationRequired,
              message: 'Cloudflare verification failed',
            ),
            onOpenComic: (_, __) async {},
            onOpenSourceWebView: (_, url, {required cloudflareVerification}) async {
              expect(url, source.descriptor.website);
              webViewOpens++;
            },
          ),
        ),
      ),
    );

    final verify = find.byKey(
      sourceComicCoverVerificationKey(source.sourceId, source._comicId),
    );
    await _pumpUntilFound(tester, verify);
    await _tapVisible(tester, verify);
    expect(webViewOpens, 1);
  });

  testWidgets('detail separates source categories tags and shelf categories',
      (tester) async {
    final source = _FixtureSource(
      'mihon:metadata',
      '元数据源',
      comicTags: const <String>[
        'category:Webtoon',
        'genre:Romance',
        'author:重复作者',
        'language:Korean',
      ],
    );
    final category = LibraryCategory(
      categoryId: 'favorites',
      name: '收藏分类',
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 8, 2),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            tags: source._comic.tags,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: <LibraryCategory>[category],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async {
            if (!refreshContent) {
              return library;
            }
            final manifest = await source.loadComic(source._comicId);
            return library.copyWith(
              sourceComic: manifest.comic,
              sourceChapters: manifest.chapters,
            );
          },
          ensureSourceChapter: (_, __, ___) async =>
              throw StateError('chapter should not open'),
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {},
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
          onOpenSourceWebView: ({verificationUri}) async {
            webViewOpens++;
          },
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('来源分类'));
    expect(find.text('Webtoon'), findsOneWidget);
    expect(find.text('标签'), findsOneWidget);
    expect(find.text('Romance'), findsOneWidget);
    expect(find.text('language：Korean'), findsOneWidget);
    expect(find.text('书架分类'), findsOneWidget);
    expect(find.text('收藏分类'), findsOneWidget);
    expect(find.textContaining('重复作者'), findsNothing);
    expect(find.byKey(details.comicDetailsRetryBodyKey), findsNothing);

    await _tapVisible(tester, find.byKey(details.comicDetailsOpenWebViewKey));
    expect(webViewOpens, 1);
  });

  testWidgets('detail continue reading opens the saved chapter', (tester) async {
    final source = _FixtureSource('mihon:continue', '继续阅读源');
    final chapterManifest = await source.loadChapter(source._chapterId);
    final entry = ImportedChapterRecord.remote(
      comic: source._comic,
      manifest: chapterManifest,
    );
    final libraryEntry = ImportedLibraryEntry(chapter: entry);
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[
        ImportedLibraryEntry(
          chapter: libraryEntry.chapter,
          progress: ReadingProgress(
            sourceId: source.sourceId,
            comicId: source._comicId,
            chapterId: source._chapterId,
            pageIndex: 0,
            subPageOffset: 0,
            readerMode: ReaderMode.paged,
            updatedAt: DateTime.utc(2026, 8, 3),
          ),
        ),
      ],
      sourceComic: source._comic,
      sourceChapters: <Chapter>[source._chapter],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    var opened = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            tags: source._comic.tags,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          ensureSourceChapter: (_, __, ___) async => libraryEntry,
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            loadChapter, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {
            opened++;
            expect(refreshRemote, isFalse);
            expect(title, '第 1 话');
            expect((await loadChapter()).chapter.chapterId, source._chapterId);
          },
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsContinueReadingKey),
    );
    expect(find.text('继续'), findsOneWidget);
    expect(find.text('继续阅读'), findsNothing);
    expect(find.byKey(details.comicDetailsReadingHistoryKey), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.widget<AppBar>(find.byType(AppBar)).title, isNull);
    final continueButton = tester.widget<FilledButton>(
      find.byKey(details.comicDetailsContinueReadingKey),
    );
    expect(continueButton.onPressed, isNotNull);
    expect(
      tester.getBottomLeft(
        find.byKey(details.comicDetailsContinueReadingKey),
      ).dy,
      lessThan(
        tester.getTopLeft(find.byKey(details.comicDetailsChapterCountKey)).dy,
      ),
    );
    expect(
      tester.getBottomLeft(find.byKey(details.comicDetailsChapterCountKey)).dy,
      lessThan(
        tester.getTopLeft(find.byKey(details.comicDetailsChapterListKey)).dy,
      ),
    );

    await tester.tap(find.byKey(details.comicDetailsContinueReadingKey));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('detail exposes source preview and comment reply pages',
      (tester) async {
    final source = _FixtureSource(
      'venera:details-features',
      '详情能力源',
      supportsComicPreview: true,
      supportsComicComments: true,
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            tags: source._comic.tags,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async {
            if (!refreshContent) return library;
            final manifest = await source.loadComic(source._comicId);
            return library.copyWith(
              sourceComic: manifest.comic,
              sourceChapters: manifest.chapters,
              sourceManifest: manifest,
            );
          },
          ensureSourceChapter: (_, __, ___) async =>
              throw StateError('chapter should not open'),
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {},
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(details.remoteComicDetailsScreenKey),
    );
    await tester.drag(
      find.byKey(details.remoteComicDetailsScreenKey),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsPreviewKey));
    expect(find.byKey(details.comicDetailsCommentsKey), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.text('评论'), findsOneWidget);

    await _tapVisible(tester, find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(details.comicDetailsCommentsPageKey),
      findsOneWidget,
    );

    await _tapVisible(tester, find.text('1 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('回复'), findsWidgets);
  });

  testWidgets('preview pages expand into rows and open the selected reader page',
      (tester) async {
    final source = _FixtureSource(
      'venera:preview-pages',
      '预览分页源',
      supportsComicPreview: true,
      previewPageCount: 12,
      previewCrops: true,
      previewLandscapeIndexes: const <int>{1},
      catalogPageCount: 3,
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    int? openedPage;

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            tags: source._comic.tags,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => MemoryEncodedResourceSource(
                (await rootBundle.load('assets/demo/pages/001.png'))
                    .buffer
                    .asUint8List(),
              ),
          reloadLibrary: ({required bool refreshContent}) async {
            final manifest = await source.loadComic(source._comicId);
            return library.copyWith(
              sourceComic: manifest.comic,
              sourceChapters: manifest.chapters,
              sourceManifest: manifest,
            );
          },
          ensureSourceChapter: (_, __, ___) async =>
              throw StateError('chapter should not be prepared in this test'),
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {
            openedPage = initialPageIndex;
          },
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(details.remoteComicDetailsScreenKey));
    await tester.drag(
      find.byKey(details.remoteComicDetailsScreenKey),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsPreviewItemKey(0)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(0)),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(find.byKey(details.comicDetailsPreviewItemKey(1)), findsNothing);

    final collapsedItem0Size = tester.getSize(
      find.byKey(details.comicDetailsPreviewItemKey(0)),
    );
    expect(find.text('展开'), findsNothing);
    expect(find.text('收起'), findsNothing);
    await _tapVisible(tester, find.byKey(details.comicDetailsPreviewExpandKey));
    for (var frame = 0; frame < 160 && source.previewTokens.length < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      source.previewTokens,
      <String?>[
        null,
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
      ],
    );
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsPreviewItemKey(2)));
    final previewPager = find.descendant(
      of: find.byKey(details.comicDetailsPreviewKey),
      matching: find.byType(PageView),
    );
    expect(previewPager, findsOneWidget);
    expect(tester.getSize(previewPager).height, lessThanOrEqualTo(540));

    final itemFinders = <Finder>[
      for (var index = 0; index < 3; index++)
        find.byKey(details.comicDetailsPreviewItemKey(index)),
    ];
    final itemSizes = itemFinders.map(tester.getSize).toList(growable: false);
    final itemAreas = itemSizes
        .map((size) => size.width * size.height)
        .toList(growable: false);
    expect(
      itemAreas.reduce((left, right) => left > right ? left : right) /
          itemAreas.reduce((left, right) => left < right ? left : right),
      lessThanOrEqualTo(2.4),
    );
    final itemCenters = itemFinders.map(tester.getCenter).toList(growable: false);
    // Index 1 is landscape, so the actual first row contains exactly two
    // items. Index 2 begins the next portrait row.
    expect(itemCenters[0].dy, closeTo(itemCenters[1].dy, 1));
    expect(itemCenters[2].dy, greaterThan(itemCenters[1].dy));
    expect(itemCenters[0].dx, lessThan(itemCenters[1].dx));
    final previewRect = tester.getRect(previewPager);
    final firstRect = tester.getRect(itemFinders.first);
    final firstRowLastRect = tester.getRect(itemFinders[1]);
    expect(firstRect.left - previewRect.left, lessThanOrEqualTo(16));
    expect(previewRect.right - firstRowLastRect.right, lessThanOrEqualTo(16));
    expect(itemSizes[0], collapsedItem0Size);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(1)),
        matching: find.byType(CustomPaint),
      ),
    );
    await _tapVisible(
      tester,
      find.byKey(details.comicDetailsPreviewItemKey(1)),
    );
    await tester.pump();
    expect(openedPage, 1);

    await _tapVisible(tester, find.byKey(details.comicDetailsPreviewExpandKey));
    await tester.pump();
    expect(previewPager, findsNothing);
    expect(
      tester.getSize(find.byKey(details.comicDetailsPreviewItemKey(0))),
      collapsedItem0Size,
    );
  });

  testWidgets('local details retain source preview and comment sections',
      (tester) async {
    final source = _FixtureSource(
      'venera:local-details-features',
      '本地详情能力源',
      supportsComicPreview: true,
      supportsComicComments: true,
    );
    final chapterManifest = await source.loadChapter(source._chapterId);
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: chapterManifest,
      ),
    );
    final sourceManifest = await source.loadComic(source._comicId);
    final comic = LibraryComic(
      sourceId: source.sourceId,
      comicId: source._comicId,
      title: source._comic.title,
      authors: source._comic.authors,
      tags: source._comic.tags,
      description: source._comic.description,
      coverSourceId: source._comic.coverUri?.toString(),
      readingDirection: source._comic.readingDirection,
      chapters: <ImportedLibraryEntry>[entry],
      sourceChapters: sourceManifest.chapters,
      savedAt: DateTime.utc(2026, 8, 1),
      metadataUpdatedAt: DateTime.utc(2026, 8, 2),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[entry],
      sourceComic: source._comic,
      sourceChapters: sourceManifest.chapters,
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: details.LocalComicDetailsScreen(
          comic: comic,
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: source,
          ensureSourceChapter: (_, __, ___) async => entry,
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {},
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(details.localComicDetailsScreenKey));
    await tester.drag(
      find.byKey(details.localComicDetailsScreenKey),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsCommentsKey));
    expect(find.byKey(details.comicDetailsPreviewKey), findsOneWidget);
  });

  testWidgets('details separates same-source version view and migration',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-version';
    final source = _FixtureSource(
      sourceId,
      '版本源',
      supportsComicVersions: true,
      comicVersions: const <SourceComicVersion>[
        SourceComicVersion(
          sourceId: sourceId,
          comicId: 'fixture-version-new-comic',
          title: '新版标题',
          generation: 2,
        ),
      ],
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
      find.byKey(sourceComicCardKey(sourceId, '$sourceId-comic')),
    );
    await _tapVisible(
      tester,
      find.byKey(sourceComicCardKey(sourceId, '$sourceId-comic')),
    );
    await _pumpUntilFound(tester, find.byKey(details.remoteComicDetailsScreenKey));
    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsVersionSectionKey),
    );
    expect(find.byKey(details.comicDetailsVersionActionKey), findsOneWidget);
    expect(find.byKey(details.comicDetailsVersionViewKey), findsOneWidget);
    expect(find.byKey(details.comicDetailsVersionMigrateKey), findsOneWidget);
    expect(find.text('查看新版本'), findsOneWidget);
    expect(find.text('迁移'), findsOneWidget);
    expect(find.text('有新版本'), findsNothing);
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

  testWidgets('legacy runtime chapter URI refreshes before entering Reader',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-runtime-page',
      '运行时图片源',
      runtimePageUri: true,
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
        sourceComicCardKey(
          'fixture-runtime-page',
          'fixture-runtime-page-comic',
        ),
      ),
    );
    await tester.tap(
      find.byKey(
        sourceComicCardKey(
          'fixture-runtime-page',
          'fixture-runtime-page-comic',
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(details.remoteComicDetailsScreenKey),
    );
    await _tapVisible(
      tester,
      find.byKey(
        sourceChapterKey(
          'fixture-runtime-page',
          'fixture-runtime-page-chapter',
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byType(ImportedImageChapterScreen));
    final screen = tester.widget<ImportedImageChapterScreen>(
      find.byType(ImportedImageChapterScreen),
    );
    final legacyUri =
        'venera-resource://fixture-runtime-page/fixture-runtime-page-chapter';
    final durableUri =
        'venera-resource:fixture-runtime-page/fixture-runtime-page-chapter';
    expect(source.chapterRefreshes, 1);
    expect(screen.byteLoaders, isNot(contains(legacyUri)));
    expect(screen.byteLoaders, contains(durableUri));
    await screen.byteLoaders[durableUri]!();
    expect(
      source.loadedResources.map((uri) => uri.toString()),
      contains(durableUri),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  },
      skip: true); // ZIC-QUARANTINE(Q-001): whole-App legacy runtime route;
  // owner coverage remains active until a deterministic route harness exists.

  testWidgets(
      'persisted legacy Venera chapter refreshes despite local-detail open hint',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-persisted-runtime';
    const comicId = '$sourceId-comic';
    const chapterId = '$sourceId-chapter';
    final source = _FixtureSource(
      sourceId,
      '持久旧定位符源',
      runtimePageUri: true,
    );
    await store.upsertChapter(
      ImportedChapterRecord(
        directoryId: '$sourceId:$comicId',
        displayName: '第 1 话',
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: '持久旧定位符漫画',
        chapterId: chapterId,
        sourceRevision: 'legacy-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.png',
            sourceId:
                'venera-resource://fixture-persisted-runtime/fixture-persisted-runtime-chapter',
            contentKindHint: ContentKindHint.png,
            pageId: 'fixture-persisted-runtime-page-1',
          ),
        ],
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: sourceId,
        comicId: comicId,
        sourceKind: ComicSourceKind.remote,
      ),
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();
    await _tapVisible(tester, find.byKey(comicCoverKey(sourceId, comicId)));
    await _pumpUntilFound(
      tester,
      find.byKey(details.localComicDetailsScreenKey),
    );
    await _tapVisible(
      tester,
      find.byKey(sourceChapterKey(sourceId, chapterId)),
    );
    await _pumpUntilFound(tester, find.byType(ImportedImageChapterScreen));

    final screen = tester.widget<ImportedImageChapterScreen>(
      find.byType(ImportedImageChapterScreen),
    );
    final durableUri = 'venera-resource:$sourceId/$chapterId';
    expect(source.chapterRefreshes, 1);
    expect(screen.byteLoaders, contains(durableUri));
    expect(
      screen.byteLoaders,
      isNot(contains('venera-resource://$sourceId/$chapterId')),
    );
  },
      skip: true); // ZIC-QUARANTINE(Q-002): persisted legacy route test timing;
  // gateway/plugin-host owner coverage remains mandatory.

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
    final savedComic = await store.getSavedComic(
      'fixture-refresh',
      'fixture-refresh-comic',
    );
    expect(savedComic, isNotNull);
    expect(savedComic?.chapters, hasLength(2));
    expect(source.loadedResources, isEmpty);
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

  testWidgets('pending page counts do not preflight chapter bodies',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'mihon:fixture-count',
      'Mihon 页数源',
      catalogPageCount: 0,
    );
    await store.saveSourcePreference(
      ComicSourcePreference.defaults(sourceId: source.sourceId),
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
        sourceComicCardKey(
          'mihon:fixture-count',
          'mihon:fixture-count-comic',
        ),
      ),
    );
    await tester.tap(
      find.byKey(
        sourceComicCardKey(
          'mihon:fixture-count',
          'mihon:fixture-count-comic',
        ),
      ),
    );
    final chapterTile = find.byKey(
      sourceChapterKey(
        'mihon:fixture-count',
        'mihon:fixture-count-chapter',
      ),
    );
    await _pumpUntilFound(
      tester,
      find.descendant(of: chapterTile, matching: find.text('页数待加载')),
    );

    expect(source.chapterLoads, 0);
    expect(find.text('1 章 · 页数待加载'), findsOneWidget);
  });

  testWidgets(
      'pull refresh joins initial load and hides success badge after two seconds',
      (tester) async {
    final loadStarted = Completer<void>();
    final loadGate = Completer<void>();
    final source = _FixtureSource(
      'fixture-refresh-race',
      '刷新竞态源',
      firstComicLoadStarted: loadStarted,
      firstComicLoadGate: loadGate,
    );
    final preference = ComicPreference.defaults(
      sourceId: source.sourceId,
      comicId: source._comicId,
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      readStates: const <String, ChapterReadState>{},
      preference: preference,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => throw StateError('cover not needed'),
          reloadLibrary: ({required bool refreshContent}) async {
            if (!refreshContent) {
              return library;
            }
            final manifest = await source.loadComic(source._comicId);
            return library.copyWith(
              sourceComic: manifest.comic,
              sourceChapters: manifest.chapters,
            );
          },
          ensureSourceChapter: (_, __, ___) async =>
              throw StateError('chapter not needed'),
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {},
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await loadStarted.future;
    final refreshFinder = find.descendant(
      of: find.byKey(details.remoteComicDetailsScreenKey),
      matching: find.byType(RefreshIndicator),
    );
    await _pumpUntilFound(tester, refreshFinder);
    final refresh = tester.state<RefreshIndicatorState>(refreshFinder);
    final joined = refresh.show();
    await tester.pump();
    expect(source.comicLoads, 1);
    loadGate.complete();
    await joined;
    await _pumpUntilFound(
      tester,
      find.descendant(
        of: find.byKey(details.comicDetailsRefreshStateKey),
        matching: find.byIcon(Icons.check),
      ),
    );

    expect(source.comicLoads, 1);
    expect(
      find.descendant(
        of: find.byKey(details.comicDetailsRefreshStateKey),
        matching: find.byIcon(Icons.close),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(details.comicDetailsRefreshStateKey), findsNothing);
  });

  testWidgets('empty source catalog shows WebView recovery instead of a chapter',
      (tester) async {
    final source = _FixtureSource(
      'mihon:fixture-empty',
      '空目录源',
      emptyCatalog: true,
    );
    final preference = ComicPreference.defaults(
      sourceId: source.sourceId,
      comicId: source._comicId,
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      readStates: const <String, ChapterReadState>{},
      preference: preference,
    );
    var webViewOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: details.RemoteComicDetailsScreen(
          source: source,
          summary: SourceComicSummary(
            sourceId: source.sourceId,
            comicId: source._comicId,
            title: source._comic.title,
            authors: source._comic.authors,
            coverUri: source._comic.coverUri,
          ),
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            String resourceRole = 'cover',
          }) async => throw StateError('cover must not load for failed catalog'),
          reloadLibrary: ({required bool refreshContent}) async {
            if (!refreshContent) {
              return library;
            }
            final manifest = await source.loadComic(source._comicId);
            return library.copyWith(
              sourceComic: manifest.comic,
              sourceChapters: manifest.chapters,
            );
          },
          ensureSourceChapter: (_, __, ___) async =>
              throw StateError('chapter must not be synthesized'),
          persistComic: (_, __) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {},
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
          onOpenSourceWebView: ({verificationUri}) async {
            webViewOpens++;
          },
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(details.comicDetailsOpenWebViewKey));
    expect(
      find.byKey(sourceChapterKey(source.sourceId, source._chapterId)),
      findsNothing,
    );
    await _tapVisible(tester, find.byKey(details.comicDetailsOpenWebViewKey));
    expect(webViewOpens, 1);
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

    final retry = find.byKey(details.comicDetailsRetryBodyKey);
    await _tapVisible(tester, retry);
    await _pumpUntilFound(
      tester,
      find.byKey(sourceChapterKey('fixture-retry', 'fixture-retry-chapter')),
    );
  },
      skip: true); // ZIC-QUARANTINE(Q-003): whole-App retry test bootstrap race;
  // replace with a direct RemoteComicDetailsScreen harness before re-enabling.
}

final class _FixtureSource
    implements
        BrowsableComicSource,
        ComicVersionSource,
        RefreshableChapterComicSource,
        ComicPreviewSource,
        ComicCommentSource,
        SectionedBrowsableComicSource,
        FilterableBrowsableComicSource {
  _FixtureSource(
    this.sourceId,
    this.name, {
    this.failFirstComicLoad = false,
    this.browseError,
    this.includeSecondChapter = false,
    this.revealSecondChapterOnRefresh = false,
    this.runtimePageUri = false,
    this.catalogPageCount = 1,
    this.browseItemCount = 1,
    this.emptyCatalog = false,
    this.comicTags = const <String>[],
    this.firstComicLoadStarted,
    this.firstComicLoadGate,
    this.supportsComicVersions = false,
    this.comicVersions = const <SourceComicVersion>[],
    this.supportsComicPreview = false,
    this.previewPageCount = 1,
    this.previewCrops = false,
    this.previewLandscapeIndexes = const <int>{},
    this.supportsComicComments = false,
    this.browseSections = const <SourceBrowseSection>[],
    this.searchFilters = const <SourceSearchFilterOption>[],
  });

  @override
  final String sourceId;
  final String name;
  final bool failFirstComicLoad;
  final Object? browseError;
  final bool includeSecondChapter;
  final bool revealSecondChapterOnRefresh;
  final bool runtimePageUri;
  final int catalogPageCount;
  final int browseItemCount;
  final bool emptyCatalog;
  final List<String> comicTags;
  final Completer<void>? firstComicLoadStarted;
  final Completer<void>? firstComicLoadGate;
  final bool supportsComicVersions;
  final List<SourceComicVersion> comicVersions;
  @override
  final bool supportsComicPreview;
  final int previewPageCount;
  final bool previewCrops;
  final Set<int> previewLandscapeIndexes;
  @override
  final bool supportsComicComments;
  final List<SourceBrowseSection> browseSections;
  final List<SourceSearchFilterOption> searchFilters;
  String? lastBrowseSection;
  Set<String> lastSelectedFilterIds = const <String>{};
  int _comicLoads = 0;
  int _chapterLoads = 0;
  int _chapterRefreshes = 0;
  int browseCalls = 0;
  final List<Uri> loadedResources = <Uri>[];
  final List<String?> previewTokens = <String?>[];

  int get comicLoads => _comicLoads;
  int get chapterLoads => _chapterLoads;
  int get chapterRefreshes => _chapterRefreshes;

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
        tags: comicTags,
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
        pageCount: catalogPageCount,
        sourceRevision: 'fixture-r$sequence',
      );

  Chapter _resolvedChapterAt(int sequence) => Chapter(
        chapterId: sequence == 1 ? _chapterId : _secondChapterId,
        comicId: _comicId,
        title: '第 $sequence 话',
        sequence: sequence,
        pageCount: 1,
        sourceRevision: 'fixture-r$sequence',
      );

  @override
  Future<List<SourceBrowseSection>> loadBrowseSections() async => browseSections;

  @override
  Future<SourceBrowsePage> browseSection(
    String sectionId, {
    String query = '',
    int offset = 0,
    int limit = 24,
  }) {
    lastBrowseSection = sectionId;
    return browse(query: query, offset: offset, limit: limit);
  }

  @override
  Future<List<SourceSearchFilterOption>> loadSearchFilters() async =>
      searchFilters;

  @override
  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    Set<String> selectedFilterIds = const <String>{},
  }) {
    lastBrowseSection = sectionId;
    lastSelectedFilterIds = Set<String>.unmodifiable(selectedFilterIds);
    return browse(query: query, offset: offset, limit: limit);
  }

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
    final all = <SourceComicSummary>[
      for (var index = 0; index < browseItemCount; index++)
        SourceComicSummary(
          sourceId: sourceId,
          comicId: browseItemCount == 1 ? _comicId : '$sourceId-comic-$index',
          title: browseItemCount == 1 ? _comic.title : '$name 漫画 $index',
          authors: _comic.authors,
          tags: _comic.tags,
          coverUri: _comic.coverUri,
        ),
    ];
    final matching = query.isEmpty
        ? all
        : all.where((summary) => summary.title.contains(query)).toList();
    final start = offset.clamp(0, matching.length).toInt();
    final end = (start + limit).clamp(start, matching.length).toInt();
    return SourceBrowsePage(
      items: matching.sublist(start, end),
      offset: start,
      hasMore: end < matching.length,
    );
  }

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    expect(comicId, _comicId);
    return comicVersions;
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    expect(comicId, _comicId);
    final loadIndex = _comicLoads++;
    if (loadIndex == 0) {
      final started = firstComicLoadStarted;
      if (started != null && !started.isCompleted) {
        started.complete();
      }
      await firstComicLoadGate?.future;
    }
    if (failFirstComicLoad && loadIndex == 0) {
      throw StateError('transient source failure');
    }
    final showSecond =
        includeSecondChapter || (revealSecondChapterOnRefresh && loadIndex > 0);
    return ComicManifest(
      comic: _comic,
      chapters: emptyCatalog
          ? const <Chapter>[]
          : <Chapter>[
              _chapter,
              if (showSecond) _secondChapter,
            ],
      preview: supportsComicPreview && previewPageCount == 1
          ? ComicPreviewPage(
              items: <ComicPreviewAsset>[
                _previewAsset(0),
              ],
              nextToken: previewPageCount > 1 ? '1' : null,
            )
          : null,
      comments: supportsComicComments
          ? ComicCommentPage(
              page: 1,
              maxPage: 1,
              items: const <ComicComment>[
                ComicComment(
                  id: 'fixture-comment',
                  userName: '读者',
                  content: '评论内容',
                  replyCount: 1,
                ),
              ],
            )
          : null,
    );
  }

  @override
  Future<ComicPreviewPage> loadComicPreview(
    String comicId, {
    String? nextToken,
  }) async {
    expect(comicId, _comicId);
    previewTokens.add(nextToken);
    final start = int.tryParse(nextToken ?? '0') ?? 0;
    final end = (start + 1).clamp(0, previewPageCount).toInt();
    return ComicPreviewPage(
      items: <ComicPreviewAsset>[
        for (var index = start; index < end; index++)
          _previewAsset(index),
      ],
      nextToken: end < previewPageCount ? '$end' : null,
    );
  }

  Uri _previewUri(int index) => Uri.parse(
        'https://example.invalid/$sourceId/preview-$index.png'
        '${previewCrops ? (index.isEven ? '@x=0-200&y=0-200' : '@x=200-400&y=200-400') : ''}',
      );

  ComicPreviewAsset _previewAsset(int index) {
    final landscape = previewLandscapeIndexes.contains(index);
    return ComicPreviewAsset(
      uri: _previewUri(index),
      width: landscape ? 1600 : 1200,
      height: landscape ? 900 : 1600,
    );
  }

  @override
  Future<ComicCommentPage> loadComicComments(
    String comicId, {
    String? subId,
    required int page,
    String? replyTo,
  }) async => ComicCommentPage(
        page: page,
        maxPage: page,
        items: const <ComicComment>[],
      );

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    expect(chapterId, anyOf(_chapterId, _secondChapterId));
    _chapterLoads++;
    return _chapterManifest(chapterId, durableRuntimeLocator: false);
  }

  @override
  Future<ChapterManifest> refreshChapter(String chapterId) async {
    expect(chapterId, anyOf(_chapterId, _secondChapterId));
    _chapterRefreshes++;
    return _chapterManifest(chapterId, durableRuntimeLocator: true);
  }

  ChapterManifest _chapterManifest(
    String chapterId, {
    required bool durableRuntimeLocator,
  }) {
    final chapter = chapterId == _chapterId
        ? _resolvedChapterAt(1)
        : _resolvedChapterAt(2);
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
          uri: runtimePageUri
              ? Uri.parse(
                  durableRuntimeLocator
                      ? 'venera-resource:$sourceId/$chapterId'
                      : 'venera-resource://$sourceId/$chapterId',
                )
              : Uri.https(
                  'example.invalid',
                  '/$sourceId/$chapterId/page-1.png',
                ),
          contentKindHint: ContentKindHint.png,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    loadedResources.add(uri);
    return _tinyPng();
  }
}
