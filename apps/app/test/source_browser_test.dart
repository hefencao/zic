import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:downloads/downloads.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/app_preferences.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/home_shell.dart';
import 'package:zic/debug_trace.dart';
import 'package:zic/app.dart';
import 'package:zic/source_browser.dart';
import 'package:zic/source_resource_gateway.dart';
import 'package:zic/webp_demo.dart';

Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
      'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

ChapterDownloadSnapshot _downloadSnapshot(
  ImportedLibraryEntry entry,
  ChapterDownloadPhase phase,
) =>
    ChapterDownloadSnapshot(
      sourceId: entry.chapter.sourceId,
      comicId: entry.chapter.comicId,
      comicTitle: entry.chapter.comicTitle,
      chapterId: entry.chapter.chapterId,
      sourceRevision: entry.chapter.sourceRevision,
      title: entry.chapter.displayName,
      completedPages:
          phase == ChapterDownloadPhase.complete ? entry.chapter.pages.length : 0,
      totalPages: entry.chapter.pages.length,
      receivedBytes: phase == ChapterDownloadPhase.complete ? 1 : 0,
      phase: phase,
      started: phase != ChapterDownloadPhase.idle,
    );

Future<Uint8List> _generatePng({int width = 500, int height = 500}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF00FF00),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
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
  await tester.ensureVisible(finder.first);
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
  test('chapter presentation keys remain source/chapter scoped', () {
    const sourceId = 'fixture-key-source';
    const chapterId = 'fixture-key-chapter';
    expect(
      sourceChapterKey(sourceId, chapterId),
      details.comicDetailsChapterKey(sourceId, chapterId),
    );
    expect(
      sourceChapterKey(sourceId, chapterId),
      const ValueKey<String>(
        'source-chapter:fixture-key-source\u0000fixture-key-chapter',
      ),
    );
    expect(
      sourceChapterKey(sourceId, chapterId),
      isNot(sourceChapterKey(sourceId, 'fixture-key-chapter-2')),
    );
    expect(
      sourceChapterKey(sourceId, chapterId),
      isNot(sourceChapterKey('fixture-key-source-2', chapterId)),
    );
  });

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

  testWidgets('source management follows external source generation while open',
      (tester) async {
    final builtIn = _FixtureSource('fixture-built-in', '内置源');
    final firstExternal = _FixtureSource('venera:first-live', '外部源一');
    final secondExternal = _FixtureSource('venera:second-live', '外部源二');
    final thirdExternal = _FixtureSource('venera:third-live', '外部源三');
    // The route seed still contains the first generation, while the resolver
    // has already advanced before State subscribes to the live change signal.
    var externalSources = <BrowsableComicSource>[secondExternal];
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);

    await tester.pumpWidget(
      MaterialApp(
        home: SourceManagementScreen(
          sources: <BrowsableComicSource>[builtIn, firstExternal],
          preferences: const <String, ComicSourcePreference>{},
          onPreferenceChanged: (_) async {},
          initialExternalSourceIds: <String>{firstExternal.sourceId},
          readExternalSources: () => externalSources,
          externalSourceChanges: changes.stream,
        ),
      ),
    );

    expect(
      find.byKey(ValueKey<String>('source-manager:${builtIn.sourceId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('source-manager:${firstExternal.sourceId}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('source-manager:${secondExternal.sourceId}')),
      findsOneWidget,
    );

    externalSources = <BrowsableComicSource>[thirdExternal];
    changes.add(null);
    await tester.pump();

    expect(
      find.byKey(ValueKey<String>('source-manager:${builtIn.sourceId}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('source-manager:${secondExternal.sourceId}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('source-manager:${thirdExternal.sourceId}')),
      findsOneWidget,
    );
  });

  testWidgets('source management persists bidirectional webtoon confidence',
      (tester) async {
    final source = _FixtureSource('mihon:webtoon-confidence', '条漫来源');
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SourceManagementScreen(
          sources: <BrowsableComicSource>[source],
          preferences: const <String, ComicSourcePreference>{},
          onPreferenceChanged: (_) async {},
          appPreferences: preferences,
        ),
      ),
    );

    await tester.tap(find.byKey(sourceSettingsEntryKey(source.sourceId)));
    await tester.pumpAndSettle();
    expect(find.text('源设置 · 条漫来源'), findsOneWidget);
    await tester.tap(find.text('条漫置信'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(0.2);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      preferences.sourceAdaptiveWebtoonConfidenceFor(source.sourceId),
      0.2,
    );
  });

  testWidgets('source cards project shelf membership without owning it',
      (tester) async {
    final source = _FixtureSource('fixture-shelf', '书架标记源');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
            isInShelf: (_, __) => true,
          ),
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, source._comicId)),
    );
    expect(
      find.byKey(sourceComicShelfDimKey(source.sourceId, source._comicId)),
      findsOneWidget,
    );
    expect(
      find.byKey(sourceComicShelfMarkerKey(source.sourceId, source._comicId)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.library_books), findsOneWidget);
  });

  testWidgets('source card update marker is projected separately from shelf',
      (tester) async {
    final source = _FixtureSource('fixture-update', '更新标记源');
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
            isInShelf: (_, __) => true,
            hasUpdate: (_, __) => true,
            onOpenUpdate: (_, __) async {
              opened = true;
            },
          ),
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicUpdateMarkerKey(source.sourceId, source._comicId)),
    );
    expect(find.byIcon(Icons.priority_high), findsOneWidget);
    await tester.tap(
      find.byKey(sourceComicUpdateMarkerKey(source.sourceId, source._comicId)),
    );
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('empty source filter schema does not invent a filter category',
      (tester) async {
    final source = _FixtureSource(
      'fixture-filter-empty',
      '无筛选源',
      browseSections: const <SourceBrowseSection>[
        SourceBrowseSection(sectionId: 'popular', label: '热门'),
        SourceBrowseSection(sectionId: 'latest', label: '最新'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(comicSourceCategoryKey('latest')));
    expect(find.byKey(comicSourceFilterActionKey), findsNothing);
  });

  testWidgets('filter draft survives sheet metrics and dropdown rebuilds',
      (tester) async {
    final source = _FixtureSource(
      'fixture-filter-draft',
      '筛选草稿源',
      searchFilters: const <SourceSearchFilterNode>[
        SourceSearchFilterNode(
          filterId: 'group',
          kind: SourceSearchFilterKind.group,
          label: '分组',
          children: <SourceSearchFilterNode>[
            SourceSearchFilterNode(
              filterId: 'group.check',
              kind: SourceSearchFilterKind.checkBox,
              label: '选项',
              value: false,
            ),
          ],
        ),
        SourceSearchFilterNode(
          filterId: 'type',
          kind: SourceSearchFilterKind.select,
          label: '类型',
          options: <String>['全部', '同人'],
          value: 0,
        ),
      ],
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byKey(comicSourceFilterActionKey));
    await _tapVisible(tester, find.byKey(comicSourceFilterActionKey));
    await _tapVisible(tester, find.byKey(comicSourceFilterKey('group.check')));
    expect(
      tester.widget<CheckboxListTile>(
        find.byKey(comicSourceFilterKey('group.check')),
      ).value,
      isTrue,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(
        find.byKey(comicSourceFilterKey('group.check')),
      ).value,
      isTrue,
    );
    await _tapVisible(tester, find.byKey(comicSourceFilterKey('type')));
    await _tapVisible(tester, find.text('同人').last);
    await _tapVisible(tester, find.text('应用'));
    await tester.pumpAndSettle();
    expect(source.lastFilterState, <String, Object?>{
      'group.check': true,
      'type': 1,
    });
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
      searchFilters: const <SourceSearchFilterNode>[
        SourceSearchFilterNode(
          filterId: 'status',
          kind: SourceSearchFilterKind.checkBox,
          label: '已完结',
          value: false,
        ),
        SourceSearchFilterNode(
          filterId: 'type',
          kind: SourceSearchFilterKind.select,
          label: '类型',
          options: <String>['全部', '其他', '同人'],
          value: 0,
        ),
        SourceSearchFilterNode(
          filterId: 'sort',
          kind: SourceSearchFilterKind.sort,
          label: '排序',
          options: <String>['热门', '最新'],
          value: <String, Object?>{'index': 0, 'ascending': true},
        ),
        SourceSearchFilterNode(
          filterId: 'scope',
          kind: SourceSearchFilterKind.text,
          label: '搜索范围',
          value: '',
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
            resizeToAvoidBottomInset: false,
            body: ComicSourcesPage(
              sources: <BrowsableComicSource>[native, mihon, venera],
              activeSourceId: activeSourceId,
              onSourceSelected: (sourceId) {
                setState(() => activeSourceId = sourceId);
              },
              searchHistory: const <String>['漫画'],
              onSearchCommitted: searches.add,
              loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
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
    expect(find.byKey(comicSourceFilterActionKey), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(comicSourceCategoryKey('latest'))).dx,
      lessThan(tester.getTopLeft(find.byKey(comicSourceCategoryKey('popular'))).dx),
    );
    expect(
      tester.widget<ChoiceChip>(
        find.byKey(comicSourceCategoryKey('latest')),
      ).selected,
      isTrue,
    );
    expect(native.lastBrowseSection, 'latest');
    expect(find.byKey(comicSourceCategoryKey('mihon')), findsNothing);
    expect(find.byKey(comicSourceChoiceKey(native.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourceChoiceKey(mihon.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourceChoiceKey(venera.sourceId)), findsOneWidget);
    expect(find.byKey(comicSourcePagerKey), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceFilterActionKey));
    await tester.pump();
    expect(find.byKey(comicSourceFilterSheetKey), findsOneWidget);
    expect(find.byKey(comicSourceFilterBarKey), findsOneWidget);
    expect(find.byKey(comicSourceFilterKey('status')), findsOneWidget);

    // Applying without edits is a real filter browse using the source defaults.
    final filteredCallsBeforeDefault = native.filteredBrowseCalls;
    await _tapVisible(tester, find.text('应用'));
    await tester.pump();
    expect(native.filteredBrowseCalls, filteredCallsBeforeDefault + 1);
    expect(native.lastFilterState, isEmpty);
    expect(
      tester.widget<ChoiceChip>(find.byKey(comicSourceFilterActionKey)).selected,
      isTrue,
    );
    expect(
      tester.widget<ChoiceChip>(
        find.byKey(comicSourceCategoryKey('latest')),
      ).selected,
      isFalse,
    );

    // A source section is a different view; selecting it exits filter focus.
    await _tapVisible(tester, find.byKey(comicSourceCategoryKey('popular')));
    await tester.pump();
    expect(
      tester.widget<ChoiceChip>(find.byKey(comicSourceFilterActionKey)).selected,
      isFalse,
    );

    await _tapVisible(tester, find.byKey(comicSourceFilterActionKey));
    await tester.pump();
    await _tapVisible(tester, find.byKey(comicSourceFilterKey('status')));
    await _tapVisible(tester, find.text('应用'));
    await tester.pumpAndSettle();
    expect(native.lastFilterState['status'], isTrue);
    expect(native.lastFilterState.containsKey('sort'), isFalse);
    expect(native.lastBrowseSection, isNull);
    expect(
      tester.widget<ChoiceChip>(find.byKey(comicSourceFilterActionKey)).selected,
      isTrue,
    );
    expect(
      tester.widget<ChoiceChip>(
        find.byKey(comicSourceCategoryKey('popular')),
      ).selected,
      isFalse,
    );

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    expect(find.byKey(comicSourceSearchKey), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.byKey(comicSourceFilterBarKey), findsNothing);

    // Android can consume the first back event to hide the IME before the
    // route sees it. Release focus at the start of that inset animation while
    // keeping the panel available for the following back event.
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pump();
    final searchFocus = tester.widget<SearchBar>(
      find.byKey(comicSourceSearchKey),
    ).focusNode!;
    expect(searchFocus.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(searchFocus.hasFocus, isFalse);
    expect(find.byKey(comicSourceSearchKey), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.pump();
    expect(searchFocus.hasFocus, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    expect(find.byKey(comicSourceSearchFabKey), findsOneWidget);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await tester.drag(
      find.byKey(comicSourcePullRefreshKey),
      const Offset(0, -80),
    );
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await _tapVisible(tester, find.text('漫画'));
    expect(searches, <String>['漫画']);
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    expect(native.browseQueries.last, '漫画');

    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(
        of: find.byKey(comicSourcePullRefreshKey),
        matching: find.byType(RefreshIndicator),
      ),
    );
    final browseCallsBeforeRefresh = native.browseCalls;
    unawaited(refresh.show());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(native.browseCalls, greaterThan(browseCallsBeforeRefresh));
    expect(native.browseQueries.last, isEmpty);

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

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await _tapVisible(tester, find.byKey(comicSourceSearchLockKey));
    expect(find.byIcon(Icons.lock), findsOneWidget);
    await tester.enterText(find.byKey(comicSourceSearchKey), '漫画');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    final lockedSearch = tester.widget<SearchBar>(
      find.byKey(comicSourceSearchKey),
    );
    expect(lockedSearch.controller?.text, '漫画');
    expect(native.browseQueries.last, '漫画');
  });

  for (final (cached, retireBeforeFailure) in <(bool, bool)>[
    (false, false), (true, false), (false, true), (true, true),
  ]) {
    testWidgets('source switch first frame uses target '
        '${cached ? 'cache' : 'loading'} before '
        '${retireBeforeFailure ? 'retired' : 'current'} target failure',
        (tester) async {
      final original = _FixtureSource('mihon:fixture-original', 'Original');
      final gate = Completer<void>();
      final rawTarget = _FixtureSource('venera:fixture-target', 'Target',
        browseGate: gate,
        browseError: const Failure(code: ErrorCode.network,
          message: 'target offline'),
      );
      final cache = ResourceCacheManager();
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await tester.pump();
        final closing = cache.close();
        await tester.pump();
        await closing;
      });
      final seed = CachedBrowsableComicSource(
        source: _FixtureSource(rawTarget.sourceId, 'Target'), cache: cache,
      );
      await seed.browse(query: cached ? '' : 'another-request');
      final target = CachedBrowsableComicSource(source: rawTarget, cache: cache);
      expect(target.peekBrowsePage(), cached ? isNotNull : isNull);
      var activeSourceId = original.sourceId;
      late StateSetter update;
      final trace = DebugTraceLog();
      await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return Scaffold(body: ComicSourcesPage(
            sources: <BrowsableComicSource>[original, target],
            activeSourceId: activeSourceId, onSourceSelected: (_) {},
            traceSink: trace,
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ));
        },
      )));
      final originalCard = find.byKey(sourceComicCardKey(
        original.sourceId, '${original.sourceId}-comic'));
      final targetCard = find.byKey(sourceComicCardKey(
        target.sourceId, '${target.sourceId}-comic'));
      await _pumpUntilFound(tester, originalCard);
      update(() => activeSourceId = target.sourceId);
      await tester.pump();
      expect(originalCard, findsNothing);
      expect(targetCard, cached ? findsOneWidget : findsNothing);
      expect(find.byKey(comicSourceLoadingKey),
        cached ? findsNothing : findsOneWidget);
      if (retireBeforeFailure) {
        update(() => activeSourceId = original.sourceId);
        await _pumpUntilFound(tester, originalCard);
      }
      gate.complete();
      await tester.pumpAndSettle();
      expect(originalCard, retireBeforeFailure ? findsOneWidget : findsNothing);
      expect(targetCard,
        cached && !retireBeforeFailure ? findsOneWidget : findsNothing);
      expect(trace.events.any((event) =>
        event.payload['stage'] == 'browse-failed' &&
        event.sessionId == 'source-browser:${target.sourceId}'),
        !retireBeforeFailure);
      if (retireBeforeFailure) {
        expect(find.byKey(comicSourceErrorKey), findsNothing);
      }
      // A failed forced refresh invalidates the response cache; subsequent
      // switches must show target loading/error rather than retain old cards.
      expect(target.peekBrowsePage(), isNull);
      update(() => activeSourceId = original.sourceId);
      await tester.pumpAndSettle();
      expect(originalCard, findsOneWidget);
      expect(targetCard, findsNothing);
      for (var round = 0; round < 2; round++) {
        update(() => activeSourceId = target.sourceId);
        await tester.pump();
        expect(originalCard, findsNothing);
        expect(targetCard, findsNothing);
        expect(find.byKey(comicSourceLoadingKey), findsOneWidget);
        await tester.pumpAndSettle();
        expect(originalCard, findsNothing);
        expect(targetCard, findsNothing);
        expect(find.byKey(comicSourceErrorKey), findsOneWidget);
        update(() => activeSourceId = original.sourceId);
        await tester.pumpAndSettle();
        expect(originalCard, findsOneWidget);
        expect(targetCard, findsNothing);
        expect(find.byKey(comicSourceErrorKey), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final cacheDefaultSection in <bool>[false, true]) {
    testWidgets('target section discovery retires an unresolved browse cache '
        '${cacheDefaultSection ? 'with' : 'without'} exact default cache',
        (tester) async {
      final original = _FixtureSource('mihon:fixture-section-original', 'Old');
      const sections = <SourceBrowseSection>[
        SourceBrowseSection(sectionId: 'popular', label: '热门'),
        SourceBrowseSection(sectionId: 'latest', label: '最新'),
      ];
      final gate = Completer<void>();
      final cache = ResourceCacheManager();
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await tester.pump();
        final closing = cache.close();
        await tester.pump();
        await closing;
      });
      final rawTarget = _FixtureSource('venera:fixture-sections', 'Target',
        browseSections: sections, browseGate: gate,
        browseError: const Failure(code: ErrorCode.network, message: 'offline'),
      );
      final seedSource = _FixtureSource(rawTarget.sourceId, 'Target',
        browseSections: sections)..browseComicIdOverride = 'unresolved-comic';
      final seed = CachedBrowsableComicSource(source: seedSource, cache: cache);
      await seed.browse();
      if (cacheDefaultSection) {
        seedSource.browseComicIdOverride = 'latest-comic';
        await seed.browseSection('latest');
      }
      final target = CachedBrowsableComicSource(source: rawTarget, cache: cache);
      var activeSourceId = original.sourceId;
      late StateSetter update;
      await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return Scaffold(body: ComicSourcesPage(
            sources: <BrowsableComicSource>[original, target],
            activeSourceId: activeSourceId, onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ));
        },
      )));
      final originalCard = find.byKey(sourceComicCardKey(
        original.sourceId, original._comicId));
      final unresolved = find.byKey(sourceComicCardKey(
        target.sourceId, 'unresolved-comic'));
      final latest = find.byKey(sourceComicCardKey(target.sourceId, 'latest-comic'));
      await _pumpUntilFound(tester, originalCard);
      update(() => activeSourceId = target.sourceId);
      await tester.pump();
      expect(originalCard, findsNothing);
      await tester.pump();
      expect(rawTarget.lastBrowseSection, 'latest');
      expect(unresolved, findsNothing);
      expect(latest, cacheDefaultSection ? findsOneWidget : findsNothing);
      expect(find.byKey(comicSourceLoadingKey),
        cacheDefaultSection ? findsNothing : findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(unresolved, findsNothing);
      expect(latest, cacheDefaultSection ? findsOneWidget : findsNothing);
      expect(find.byKey(comicSourceErrorKey),
        cacheDefaultSection ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unrelated source activation preserves pending browse',
      (tester) async {
    final gate = Completer<void>();
    final cache = ResourceCacheManager();
    try {
      final underlying = _FixtureSource(
        'fixture-pending-browse',
        '当前源',
        browseGate: gate,
      );
      final active = CachedBrowsableComicSource(
        source: underlying,
        cache: cache,
      );
      final other = _FixtureSource('fixture-activation-other', '新增源');
      final third = _FixtureSource('fixture-activation-third', '第三源');
      var sources = <BrowsableComicSource>[active];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: ComicSourcesPage(
                  sources: sources,
                  activeSourceId: active.sourceId,
                  onSourceSelected: (_) {},
                  loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                      MemoryEncodedResourceSource(_tinyPng()),
                  onOpenComic: (_, __) async {},
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      expect(underlying.browseCalls, 1);
      update(() => sources = <BrowsableComicSource>[active, other]);
      await tester.pump();
      update(() => sources = <BrowsableComicSource>[active, other, third]);
      await tester.pump();
      final pendingBrowseCalls = underlying.browseCalls;
      gate.complete();
      await _pumpUntilFound(
        tester,
        find.byKey(sourceComicCardKey(active.sourceId, underlying._comicId)),
      );
      expect(find.byKey(comicSourceLoadingKey), findsNothing);
      expect(pendingBrowseCalls, 1);
      expect(underlying.browseCalls, 1);
      expect(other.browseCalls, 0);
      expect(third.browseCalls, 0);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await tester.pump();
      final closing = cache.close();
      await tester.pump();
      await closing;
    }
  });

  testWidgets('unrelated source changes preserve browse section and page',
      (tester) async {
    final source = _FixtureSource(
      'fixture-browse-list-change',
      '当前分页源',
      browseItemCount: 60,
      browseSections: const <SourceBrowseSection>[
        SourceBrowseSection(sectionId: 'latest', label: '最新'),
        SourceBrowseSection(sectionId: 'popular', label: '热门'),
      ],
    );
    final other = _FixtureSource('fixture-browse-unrelated', '其它源');
    var sources = <BrowsableComicSource>[source];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: ComicSourcesPage(
                sources: sources,
                activeSourceId: source.sourceId,
                onSourceSelected: (_) {},
                loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                    MemoryEncodedResourceSource(_tinyPng()),
                onOpenComic: (_, __) async {},
              ),
            );
          },
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-0')),
    );
    await _tapVisible(tester, find.byKey(comicSourceCategoryKey('popular')));
    await tester.scrollUntilVisible(
      find.byKey(comicSourcePagerKey),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await _tapVisible(tester, find.byKey(comicSourceNextPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-24')),
    );
    final calls = source.browseCalls;
    for (final next in <List<BrowsableComicSource>>[
      <BrowsableComicSource>[source, other],
      <BrowsableComicSource>[other, source],
      <BrowsableComicSource>[source],
    ]) {
      update(() => sources = next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-24')),
        findsOneWidget,
      );
      expect(source.lastBrowseSection, 'popular');
      expect(source.browseCalls, calls);
      expect(other.browseCalls, 0);
    }
  });

  testWidgets('source roster changes exit aggregate search through normal browse',
      (tester) async {
    final source = _FixtureSource('fixture-roster-aggregate', '当前源');
    final other = _FixtureSource('fixture-roster-other', '其它源');
    final third = _FixtureSource('fixture-roster-third', '新增源');
    var sources = <BrowsableComicSource>[source, other];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Scaffold(
              body: ComicSourcesPage(
                sources: sources,
                activeSourceId: source.sourceId,
                onSourceSelected: (_) {},
                loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                    MemoryEncodedResourceSource(_tinyPng()),
                onOpenComic: (_, __) async {},
              ),
            );
          },
        ),
      ),
    );
    final card = find.byKey(sourceComicCardKey(source.sourceId, source._comicId));
    await _pumpUntilFound(tester, card);
    final calls = source.browseCalls;
    await tester.longPress(find.byKey(comicSourceSearchFabKey));
    await tester.pump();
    expect(find.byKey(comicSourceAggregateResultsKey), findsOneWidget);
    update(() => sources = <BrowsableComicSource>[source, other, third]);
    await _pumpUntilFound(tester, card);
    expect(find.byKey(comicSourceAggregateResultsKey), findsNothing);
    expect(source.browseCalls, calls + 1);
    expect(other.browseCalls, 0);
    expect(third.browseCalls, 0);
  });

  testWidgets('native browse pages use source-owned next coordinates',
      (tester) async {
    final source = _FixtureSource(
      'fixture-native-coordinate',
      '每页二十项',
      browseItemCount: 50,
      nativeBrowsePageSize: 20,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-0')),
    );
    await tester.scrollUntilVisible(
      find.byKey(comicSourcePagerKey),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await _tapVisible(tester, find.byKey(comicSourceNextPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-20')),
    );
    expect(source.browseOffsets, <int>[0, 24]);
    await tester.scrollUntilVisible(
      find.byKey(comicSourcePagerKey),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('第 2 页'), findsOneWidget);
    await _tapVisible(tester, find.byKey(comicSourcePreviousPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic-0')),
    );
    expect(source.browseOffsets, <int>[0, 24, 0]);
  });

  testWidgets('empty native browse page can advance to its next coordinate',
      (tester) async {
    final source = _FixtureSource(
      'fixture-empty-native-page',
      '空原生页',
      browsePageOverrides: <int, SourceBrowsePage>{
        0: SourceBrowsePage(
          items: const <SourceComicSummary>[],
          offset: 0,
          hasMore: true,
          nextOffset: 24,
        ),
        24: SourceBrowsePage(
          items: const <SourceComicSummary>[
            SourceComicSummary(
              sourceId: 'fixture-empty-native-page',
              comicId: 'after-empty',
              title: '空页后的漫画',
              authors: <String>[],
            ),
          ],
          offset: 24,
          hasMore: false,
        ),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.byKey(comicSourceEmptyKey));
    await tester.scrollUntilVisible(
      find.byKey(comicSourcePagerKey),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await _tapVisible(tester, find.byKey(comicSourceNextPageKey));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, 'after-empty')),
    );
    expect(source.browseOffsets, <int>[0, 24]);
    expect(find.text('第 2 页'), findsOneWidget);
  });

  testWidgets('floating search history drag collapses without browsing',
      (tester) async {
    final source = _FixtureSource('fixture-history-drag', '历史拖动源');
    final searches = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            searchHistory: <String>[
              for (var i = 0; i < 20; i++) '历史查询 $i',
            ],
            onSearchCommitted: searches.add,
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                MemoryEncodedResourceSource(_tinyPng()),
            onSourceSelected: (_) {},
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, '${source.sourceId}-comic')),
    );
    final browseCalls = source.browseCalls;
    for (final dy in <double>[-100, 100]) {
      await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
      final historyScroll = find.descendant(
        of: find.byKey(comicSourceSearchHistoryKey),
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(historyScroll, Offset(0, dy));
      await tester.pumpAndSettle();
      expect(find.byKey(comicSourceSearchKey), findsNothing);
      expect(find.byKey(comicSourceSearchFabKey), findsOneWidget);
    }
    expect(searches, isEmpty);
    expect(source.browseCalls, browseCalls);
  });

  testWidgets('search long press opens aggregate results and exits collapsed',
      (tester) async {
    final native = _FixtureSource('fixture-aggregate', '聚合源');
    final other = _FixtureSource('fixture-other', '其他源');
    var activeSourceId = native.sourceId;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: ComicSourcesPage(
              sources: <BrowsableComicSource>[native, other],
              activeSourceId: activeSourceId,
              onSourceSelected: (sourceId) {
                setState(() => activeSourceId = sourceId);
              },
              loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
                  MemoryEncodedResourceSource(_tinyPng()),
              onOpenComic: (_, __) async {},
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(
        sourceComicCardKey(native.sourceId, native._comicId),
      ),
    );
    await tester.longPress(find.byKey(comicSourceSearchFabKey));
    await tester.pump();
    expect(find.byKey(comicSourceAggregateResultsKey), findsOneWidget);
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    expect(find.byKey(comicSourceAggregateSearchKey), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    await tester.enterText(find.byKey(comicSourceSearchKey), '聚合源');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byKey(comicSourceSearchKey), findsNothing);
    await _pumpUntilFound(
      tester,
      find.byKey(
        ValueKey<String>(
          'aggregate-source-comic:${native.sourceId}\u0000${native._comicId}',
        ),
      ),
    );
    await tester.longPress(find.byKey(comicSourceSearchFabKey));
    await tester.pump();
    expect(
      find.byKey(
        ValueKey<String>(
          'aggregate-source-comic:${native.sourceId}\u0000${native._comicId}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('请输入关键词开始聚合搜索'), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceChoiceKey(other.sourceId)));
    await _pumpUntilFound(
      tester,
      find.byKey(
        sourceComicCardKey(other.sourceId, other._comicId),
      ),
    );
    await tester.longPress(find.byKey(comicSourceSearchFabKey));
    await tester.pump();
    expect(
      find.byKey(
        ValueKey<String>(
          'aggregate-source-comic:${native.sourceId}\u0000${native._comicId}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('请输入关键词开始聚合搜索'), findsNothing);

    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    expect(find.byKey(comicSourceAggregateSearchKey), findsNothing);
    expect(find.byKey(comicSourceSearchLockKey), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    final aggregateOption = tester.widget<FilterChip>(
      find.byKey(comicSourceAggregateSearchKey),
    );
    expect(aggregateOption.selected, isFalse);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await _tapVisible(tester, find.byKey(comicSourceSearchFabKey));
    expect(find.byKey(comicSourceSearchKey), findsOneWidget);
    expect(find.byKey(comicSourceAggregateSearchKey), findsNothing);
  });

  testWidgets(
      'browse metadata refresh preserves canonical cover presentation owner',
      (tester) async {
    final source = _FixtureSource(
      'mihon:canonical-owner',
      'Canonical Owner',
      canonicalComicIdentityOverride: 'stable-comic',
    );
    var queryRevision = 0;
    var coverLoads = 0;
    final initialCover = Completer<EncodedResourceSource>();
    final trace = MemoryTraceSink();
    String? openedComicId;
    late StateSetter updateHost;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return Scaffold(
              body: ComicSourcesPage(
                sources: <BrowsableComicSource>[source],
                activeSourceId: source.sourceId,
                onSourceSelected: (_) {},
                queryRevision: queryRevision,
                requestedQuery: '',
                traceSink: trace,
                loadCover: (_, __, ___, {bool forceRefresh = false}) async {
                  coverLoads++;
                  if (coverLoads == 1) return initialCover.future;
                  return MemoryEncodedResourceSource(_tinyPng());
                },
                onOpenComic: (_, comic) async {
                  openedComicId = comic.comicId;
                },
              ),
            );
          },
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey(source.sourceId, 'stable-comic')),
    );
    expect(coverLoads, 1);
    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(of: find.byKey(comicSourcePullRefreshKey),
        matching: find.byType(RefreshIndicator)),
    );
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(coverLoads, 1, reason: 'Catalog refresh keeps the pending artwork Future');
    initialCover.complete(MemoryEncodedResourceSource(_tinyPng()));
    await tester.pumpAndSettle();

    final owner = find.byKey(
      const ValueKey<String>(
        'source-comic-owner:mihon:canonical-owner\u0000stable-comic',
      ),
    );
    final image = find.descendant(of: owner, matching: find.byType(Image));
    await _pumpUntilFound(tester, image);
    await tester.runAsync(() => precacheImage(
      tester.widget<Image>(image).image, tester.element(image)));
    await tester.pumpAndSettle();
    final originalElement = tester.element(owner);
    final originalImageState = tester.state(image);
    source.browseComicIdOverride = '${source.sourceId}-raw-alias';
    updateHost(() => queryRevision++);
    await tester.pumpAndSettle();

    expect(coverLoads, 1);
    await _pumpUntilFound(tester, image);
    expect(tester.element(owner), same(originalElement));
    expect(tester.state(image), same(originalImageState));
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(coverLoads, 1, reason: 'Catalog refresh keeps healthy artwork');
    expect(tester.state(image), same(originalImageState));
    expect(trace.events.where((event) =>
      event.payload['stage'] == 'cover-load-start'), hasLength(1));
    expect(trace.events.where((event) =>
      event.payload['stage'] == 'cover-first-frame'), hasLength(1));
    await tester.tap(find.byKey(sourceComicCardKey(source.sourceId, 'stable-comic')));
    await tester.pump();
    expect(openedComicId, source.browseComicIdOverride);
  });

  for (final explicitNextOffset in <int?>[null, 24]) {
    testWidgets(
        'canonical browse aliases keep one card and raw paging stride '
        '${explicitNextOffset ?? "fallback"}', (tester) async {
      final rawItemCount = explicitNextOffset == null ? 25 : 2;
      final nextOffset = explicitNextOffset ?? rawItemCount;
      const sourceId = 'fixture-canonical-page';
      SourceComicSummary summary(String rawId) => SourceComicSummary(
            sourceId: sourceId,
            comicId: rawId,
            title: rawId,
            authors: const <String>[],
            coverUri: Uri.parse('fixture:canonical-cover'),
          );
      final source = _FixtureSource(
        sourceId,
        'Canonical Page',
        canonicalComicIdentityOverride: 'stable-comic',
        browsePageOverrides: <int, SourceBrowsePage>{
          0: SourceBrowsePage(
            items: <SourceComicSummary>[
              summary('raw-first'),
              for (var index = 1; index < rawItemCount; index++)
                summary('raw-alias-$index'),
            ],
            offset: 0,
            hasMore: true,
            nextOffset: explicitNextOffset,
          ),
          nextOffset: SourceBrowsePage(
            items: <SourceComicSummary>[summary('raw-next-page')],
            offset: nextOffset,
            hasMore: false,
          ),
        },
      );
      var coverLoads = 0;
      String? openedComicId;
      final other = _FixtureSource('fixture-canonical-page-other', 'Other');
      var activeSourceId = sourceId;
      late StateSetter update;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (context, setState) {
          update = setState;
          return Scaffold(body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source, other],
            activeSourceId: activeSourceId,
            onSourceSelected: (_) {},
            loadCover: (_, __, ___, {bool forceRefresh = false}) async {
              coverLoads++;
              return MemoryEncodedResourceSource(_tinyPng());
            },
            onOpenComic: (_, comic) async { openedComicId = comic.comicId; },
          ));
        }),
      ));
      final card = find.byKey(sourceComicCardKey(sourceId, 'stable-comic'));
      await _pumpUntilFound(tester, card);
      expect(source.browseOffsets, <int>[0]);
      expect(coverLoads, 1);
      expect(card, findsOneWidget);
      expect(find.text('raw-alias-1'), findsNothing);
      await tester.tap(card);
      expect(openedComicId, 'raw-first');
      await _tapVisible(tester, find.byKey(comicSourceNextPageKey));
      await _pumpUntilFound(tester, find.text('raw-next-page'));
      expect(source.browseOffsets, <int>[0, nextOffset]);
      expect(card, findsOneWidget);
      expect(coverLoads, 1);
      await _tapVisible(tester, card);
      expect(openedComicId, 'raw-next-page');
      update(() => activeSourceId = other.sourceId);
      await tester.pumpAndSettle();
      update(() => activeSourceId = sourceId);
      await tester.pumpAndSettle();
      expect(find.text('raw-next-page'), findsOneWidget);
      await _tapVisible(tester, find.byKey(comicSourcePreviousPageKey));
      await tester.pumpAndSettle();
      expect(source.browseOffsets, <int>[0, nextOffset, nextOffset, 0]);
      expect(find.text('raw-first'), findsOneWidget);
    });
  }

  testWidgets('canonical cached browse aliases compare the same projection',
      (tester) async {
    const sourceId = 'fixture-cached-canonical-page';
    final cache = ResourceCacheManager();
    addTearDown(() async {
      final closing = cache.close();
      await tester.pump();
      await closing;
    });
    final underlying = _FixtureSource(
      sourceId,
      'Cached Canonical Page',
      browseItemCount: 2,
      canonicalComicIdentityOverride: 'stable-comic',
    );
    final source = CachedBrowsableComicSource(source: underlying, cache: cache);
    final other = _FixtureSource('fixture-cached-canonical-other', 'Other');
    var activeSourceId = sourceId;
    final trace = MemoryTraceSink();
    var revision = 0;
    var coverLoads = 0;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return Scaffold(body: ComicSourcesPage(
          sources: <BrowsableComicSource>[source, other],
          activeSourceId: activeSourceId,
          onSourceSelected: (_) {},
          queryRevision: revision,
          traceSink: trace,
          loadCover: (_, __, ___, {bool forceRefresh = false}) async {
            coverLoads++;
            return MemoryEncodedResourceSource(_tinyPng());
          },
          onOpenComic: (_, __) async {},
        ));
      }),
    ));
    final card = find.byKey(sourceComicCardKey(sourceId, 'stable-comic'));
    await _pumpUntilFound(tester, card);
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    final image = find.descendant(of: card, matching: find.byType(Image));
    final element = tester.element(card);
    final imageState = tester.state(image);
    update(() => revision++);
    await tester.pumpAndSettle();
    final starts = trace.events.where(
      (event) => event.payload['stage'] == 'browse-start',
    ).toList();
    final completes = trace.events.where(
      (event) => event.payload['stage'] == 'browse-complete',
    ).toList();
    expect(starts.last.payload['cacheHit'], isTrue);
    expect(starts.last.payload['cacheChanged'], isFalse);
    expect(completes.last.payload['changed'], isFalse);
    expect(completes.last.payload['itemCount'], 2);
    expect(completes.last.payload['projectedItemCount'], 1);
    expect(underlying.browseCalls, 2);
    expect(card, findsOneWidget);
    expect(tester.element(card), same(element));
    expect(tester.state(image), same(imageState));
    expect(coverLoads, 1);
    update(() => activeSourceId = other.sourceId);
    await tester.pumpAndSettle();
    update(() => activeSourceId = sourceId);
    await tester.pumpAndSettle();
    final restoredStart = trace.events.lastWhere(
      (event) => event.payload['stage'] == 'browse-start',
    );
    expect(restoredStart.payload['cacheHit'], isTrue);
    expect(restoredStart.payload['cacheChanged'], isFalse);
    expect(card, findsOneWidget);
  });

  testWidgets('failed source cover stays terminal across sliver remount until refresh',
      (tester) async {
    final source = _FixtureSource(
      'fixture-terminal-cover',
      '终止封面源',
      browseItemCount: 30,
    );
    final comicId = '${source.sourceId}-comic-0';
    var failedCoverLoads = 0;
    var recovered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComicSourcesPage(
            sources: <BrowsableComicSource>[source],
            activeSourceId: source.sourceId,
            onSourceSelected: (_) {},
            loadCover: (_, comic, __, {bool forceRefresh = false}) async {
              if (comic.comicId == comicId) {
                failedCoverLoads++;
                if (!recovered) {
                  throw Failure(
                    code: ErrorCode.source,
                    message: 'terminal cover fixture',
                  );
                }
              }
              return MemoryEncodedResourceSource(_tinyPng());
            },
            onOpenComic: (_, __) async {},
          ),
        ),
      ),
    );
    final card = find.byKey(sourceComicCardKey(source.sourceId, comicId));
    await _pumpUntilFound(tester, card);
    await tester.pumpAndSettle();
    expect(failedCoverLoads, 1);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ).first,
    ).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(failedCoverLoads, 1);

    recovered = true;
    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(
        of: find.byKey(comicSourcePullRefreshKey),
        matching: find.byType(RefreshIndicator),
      ),
    );
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(failedCoverLoads, 2);
    expect(find.descendant(of: card, matching: find.byType(Image)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit source refresh replaces only corrupt cached artwork',
      (tester) async {
    const sourceId = 'fixture-corrupt-cover';
    final brokenUri = Uri.parse('fixture:broken-cover');
    final healthyUri = Uri.parse('fixture:healthy-cover');
    final source = _FixtureSource(sourceId, '损坏封面源',
      browsePageOverrides: <int, SourceBrowsePage>{
        0: SourceBrowsePage(offset: 0, hasMore: false, items: <SourceComicSummary>[
          for (final id in <String>['broken', 'healthy']) SourceComicSummary(
            sourceId: sourceId, comicId: id, title: id,
            authors: const <String>[],
            coverUri: id == 'broken' ? brokenUri : healthyUri,
          ),
        ]),
      },
    );
    final cache = ResourceCacheManager();
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => source);
    addTearDown(gateway.close);
    addTearDown(() async {
      final closing = cache.close();
      await tester.pump();
      await closing;
    });
    for (final id in <String>['broken', 'healthy']) {
      await loadCachedComicImageSource(
        cache: cache, sourceId: sourceId, comicId: id,
        imageIdentity: (id == 'broken' ? brokenUri : healthyUri).toString(),
        revision: comicArtworkCacheSchemaRevision,
        loader: () async => id == 'broken'
            ? Uint8List.sublistView(_tinyPng(), 0, 24) : _tinyPng(),
      );
    }
    final trace = MemoryTraceSink();
    final coverLoads = <String, int>{};
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: ComicSourcesPage(
        sources: <BrowsableComicSource>[source], activeSourceId: sourceId,
        onSourceSelected: (_) {}, traceSink: trace,
        loadCover: (_, comic, uri, {bool forceRefresh = false}) {
          coverLoads.update(comic.comicId, (count) => count + 1, ifAbsent: () => 1);
          return gateway.loadArtworkSource(
            cache: cache, sourceId: sourceId, comicId: comic.comicId, uri: uri,
            forceRefresh: forceRefresh,
          );
        },
        onOpenComic: (_, __) async {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(trace.events.where((event) =>
      event.payload['stage'] == 'cover-decode-failed'), hasLength(1));
    expect(source.loadedResources, isEmpty);
    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(of: find.byKey(comicSourcePullRefreshKey),
        matching: find.byType(RefreshIndicator)),
    );
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(source.loadedResources, <Uri>[brokenUri]);
    expect(coverLoads, <String, int>{'broken': 2, 'healthy': 1});
    final repaired = await readCachedComicImageSource(
      cache: cache, sourceId: sourceId, comicId: 'broken',
      imageIdentity: brokenUri.toString(),
      revision: comicArtworkCacheSchemaRevision,
    );
    expect((repaired! as MemoryEncodedResourceSource).bytes, _tinyPng());
    expect(cache.stats.entries, 2);
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(source.loadedResources, <Uri>[brokenUri]);
    expect(coverLoads, <String, int>{'broken': 2, 'healthy': 1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh of another source preserves a terminal cover Future',
      (tester) async {
    final failed = _FixtureSource('fixture-failed-cover', '失败封面源');
    final other = _FixtureSource('fixture-other-cover', '其它封面源');
    var activeSourceId = failed.sourceId;
    final calls = <String, int>{};
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (_, setState) {
        update = setState;
        return Scaffold(body: ComicSourcesPage(
          sources: <BrowsableComicSource>[failed, other],
          activeSourceId: activeSourceId, onSourceSelected: (_) {},
          loadCover: (source, _, _, {bool forceRefresh = false}) async {
            calls.update(source.sourceId, (count) => count + 1, ifAbsent: () => 1);
            if (source.sourceId == failed.sourceId) {
              throw Failure(code: ErrorCode.source, message: 'terminal cover');
            }
            return MemoryEncodedResourceSource(_tinyPng());
          },
          onOpenComic: (_, _) async {},
        ));
      },
    )));
    await tester.pumpAndSettle();
    expect(calls[failed.sourceId], 1);
    update(() => activeSourceId = other.sourceId);
    await tester.pumpAndSettle();
    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(of: find.byKey(comicSourcePullRefreshKey),
        matching: find.byType(RefreshIndicator)),
    );
    unawaited(refresh.show());
    await tester.pumpAndSettle();
    expect(calls[other.sourceId], 1);
    update(() => activeSourceId = failed.sourceId);
    await tester.pumpAndSettle();
    expect(calls[failed.sourceId], 1);
    expect(tester.takeException(), isNull);
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
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
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
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
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
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
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
            loadCover: (_, __, ___, {bool forceRefresh = false}) async =>
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
            loadCover: (_, __, ___, {bool forceRefresh = false}) async => throw const Failure(
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
      chapterUpdatedAt: DateTime(2026, 9, 17, 8, 30),
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
      sourceChapters: <Chapter>[source._chapter],
      sourceComic: source._comic,
      sourceSyncedAt: DateTime(2026, 9, 18, 9),
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
            required String resourceRole,
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
          }) async => null,
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
    expect(find.text('标签'), findsNothing);
    expect(find.text('Romance'), findsOneWidget);
    expect(find.text('language：Korean'), findsOneWidget);
    expect(find.text('书架分类'), findsOneWidget);
    expect(find.text('收藏分类'), findsOneWidget);
    expect(find.textContaining('重复作者'), findsNothing);
    expect(find.byKey(details.comicDetailsRetryBodyKey), findsNothing);

    final chapterRow = find.byKey(
      details.comicDetailsChapterKey(source.sourceId, source._chapterId),
    );
    await tester.scrollUntilVisible(
      chapterRow,
      360,
      scrollable: find
          .descendant(
            of: find.byKey(details.remoteComicDetailsScreenKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: chapterRow,
        matching: find.text('09-17 08:30'),
      ),
      findsOneWidget,
    );

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
            required String resourceRole,
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
            return null;
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
        tester.getTopLeft(find.byKey(details.comicDetailsChapterKey(
          source.sourceId,
          source._chapterId,
        ))).dy,
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
            required String resourceRole,
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
          }) async => null,
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
      const Offset(0, -600),
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
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
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
            required String resourceRole,
          }) async =>
              MemoryEncodedResourceSource(await _generatePng()),
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
            return null;
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
      const Offset(0, -600),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsPreviewItemKey(0)));
    for (var frame = 0; frame < 60; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(0)),
        matching: find.byType(CustomPaint),
      ).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(
      find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(0)),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(find.byKey(details.comicDetailsPreviewItemKey(1)), findsNothing);
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

    for (var frame = 0; frame < 60; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(1)),
        matching: find.byType(CustomPaint),
      ).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(
      find.descendant(
        of: find.byKey(details.comicDetailsPreviewItemKey(1)),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    await _tapVisible(
      tester,
      find.byKey(details.comicDetailsPreviewItemKey(1)),
    );
    await tester.pump();
    expect(openedPage, 1);

    final expandedItem0Size = tester.getSize(
      find.byKey(details.comicDetailsPreviewItemKey(0)),
    );
    await tester.ensureVisible(find.byKey(details.comicDetailsPreviewExpandKey));
    await tester.tap(find.byKey(details.comicDetailsPreviewExpandKey));
    await tester.pump();
    expect(previewPager, findsNothing);
    expect(
      tester.getSize(find.byKey(details.comicDetailsPreviewItemKey(0))),
      expandedItem0Size,
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
            required String resourceRole,
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
          }) async => null,
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(tester, find.byKey(details.localComicDetailsScreenKey));
    await _pumpUntilFound(tester, find.byKey(details.comicDetailsPreviewKey));
    expect(
      find.byKey(details.comicDetailsCommentsKey, skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(details.comicDetailsPreviewKey), findsOneWidget);
  });

  testWidgets('comment HTML emoji uses the artwork loader', (tester) async {
    final source = _FixtureSource(
      'fixture-comment-emoji',
      '评论表情源',
    );
    final comic = Comic(
      comicId: source._comicId,
      sourceId: source.sourceId,
      title: source._comic.title,
      authors: source._comic.authors,
      tags: source._comic.tags,
      readingDirection: source._comic.readingDirection,
    );
    const emojiUrl =
        'https://www.cdnhjk.net/media/emoji/0922c375da40e6b69002bd89b858572f424dcfca.png';
    final manifest = ComicManifest(
      comic: comic,
      chapters: const <Chapter>[],
      comments: ComicCommentPage(
        page: 1,
        maxPage: 1,
        items: const <ComicComment>[
          ComicComment(
            userName: '读者',
            content: '<img styIe="width:18px;height:18px" '
                'src="[https://www.cdnhjk.net/media/emoji/0922c375da40e6b69002bd89b858572f424dcfca]'
                '(https://www.cdnhjk.net/media/emoji/0922c375da40e6b69002bd89b858572f424dcfca.png)'
                '[.png](https://www.cdnhjk.net/media/emoji/0922c375da40e6b69002bd89b858572f424dcfca.png)" '
                'alt=“臉紅“ />',
          ),
        ],
      ),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceComic: comic,
      sourceChapters: const <Chapter>[],
      sourceManifest: manifest,
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    final libraryComic = LibraryComic(
      sourceId: source.sourceId,
      comicId: source._comicId,
      title: comic.title,
      authors: comic.authors,
      tags: comic.tags,
      description: comic.description,
      coverSourceId: null,
      readingDirection: comic.readingDirection,
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: const <Chapter>[],
      savedAt: DateTime.utc(2026, 8, 1),
      metadataUpdatedAt: DateTime.utc(2026, 8, 2),
    );
    Uri? loadedEmoji;

    await tester.pumpWidget(
      MaterialApp(
        home: details.LocalComicDetailsScreen(
          comic: libraryComic,
          initialLibrary: library,
          categories: const <LibraryCategory>[],
          loadCover: ({
            required String sourceId,
            required String comicId,
            required Uri? coverUri,
            required ImportedLibraryEntry? fallbackChapter,
            required String resourceRole,
          }) async {
            if (resourceRole == 'comment-emoji') loadedEmoji = coverUri;
            return MemoryEncodedResourceSource(_tinyPng());
          },
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: source,
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async => null,
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
      find.byKey(details.comicDetailsCommentsKey),
    );
    await tester.pumpAndSettle();
    expect(loadedEmoji, Uri.parse(emojiUrl));
    expect(find.textContaining('<img'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.fit == BoxFit.contain,
      ),
      findsOneWidget,
    );
  });

  test('compact Home snapshot chapter cannot satisfy details authority', () {
    const chapter = Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'chapter',
      sequence: 1,
      pageCount: 1,
      sourceRevision: 'r1',
    );
    final compact = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: 'fixture',
        displayName: 'chapter',
        sourceId: 'venera:jm',
        comicId: 'comic',
        chapterId: 'chapter',
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: 'page-1',
            sourceId: 'zic-home-snapshot-page:0',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final usable = ImportedLibraryEntry(
      chapter: compact.chapter.copyWith(
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: 'page-1',
            sourceId: 'https://cdn.example/page-1.jpg',
            contentKindHint: ContentKindHint.jpeg,
          ),
        ],
      ),
    );

    const unknownCountChapter = Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'chapter',
      sequence: 1,
      pageCount: 0,
      sourceRevision: 'r1',
    );
    const mismatchedCountChapter = Chapter(
      chapterId: 'chapter',
      comicId: 'comic',
      title: 'chapter',
      sequence: 1,
      pageCount: 2,
      sourceRevision: 'r1',
    );

    expect(details.comicDetailsCanReuseChapterEntry(compact, chapter), isFalse);
    expect(details.comicDetailsCanReuseChapterEntry(usable, chapter), isTrue);
    expect(
      details.comicDetailsCanReuseChapterEntry(usable, unknownCountChapter),
      isTrue,
      reason: 'unknown source page count must not reject hydrated local pages',
    );
    expect(
      details.comicDetailsCanReuseChapterEntry(usable, mismatchedCountChapter),
      isFalse,
      reason: 'a changed known page count requires a fresh chapter manifest',
    );
  });

  testWidgets(
      'compact metadata displays stored count without mixing trace clocks',
      (tester) async {
    const sourceId = 'fixture-compact-details';
    const comicId = 'fixture-compact-details-comic';
    const chapterId = 'fixture-compact-details-chapter';
    const chapter = Chapter(
      chapterId: chapterId,
      comicId: comicId,
      title: '第 1 话',
      sequence: 1,
      pageCount: 0,
      sourceRevision: 'compact-r1',
    );
    final compact = ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: '$sourceId:$comicId',
        displayName: '第 1 话',
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: '紧凑详情漫画',
        chapterId: chapterId,
        sourceRevision: 'compact-r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: 'snapshot-page',
            sourceId: 'zic-home-snapshot-page:0',
            contentKindHint: ContentKindHint.unknown,
          ),
        ],
      ),
    );
    final comic = LibraryComic(
      sourceId: sourceId,
      comicId: comicId,
      title: '紧凑详情漫画',
      authors: const <String>[],
      tags: const <String>[],
      description: null,
      coverSourceId: null,
      readingDirection: ReadingDirection.ltr,
      chapters: <ImportedLibraryEntry>[compact],
      sourceChapters: const <Chapter>[chapter],
      savedAt: DateTime.utc(2026, 9, 16),
      metadataUpdatedAt: DateTime.utc(2026, 9, 16),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[compact],
      sourceChapters: const <Chapter>[chapter],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: sourceId,
        comicId: comicId,
      ),
    );
    expect(details.comicDetailsCanReuseChapterEntry(compact, chapter), isFalse);
    final trace = DebugTraceLog(maxEvents: 100, maxExportEvents: 200);
    addTearDown(trace.dispose);
    var nowMicros = 5000000;
    int traceNow() => nowMicros += 100;

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
            required String resourceRole,
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async => throw StateError('fixture-open-failure'),
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (entry) async =>
              ChapterDownloadSnapshot.idle(entry),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
          traceSink: trace,
          traceMonotonicMicros: traceNow,
        ),
      ),
    );

    final chapterTile = find.byKey(
      details.comicDetailsChapterKey(sourceId, chapterId),
    );
    await _pumpUntilFound(tester, chapterTile);
    expect(
      find.descendant(of: chapterTile, matching: find.text('待加载')),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterTile, matching: find.text('1页')),
      findsOneWidget,
      reason: 'stored count is metadata and does not authorize page reuse',
    );

    await tester.tap(chapterTile);
    await tester.pump();
    final firstFrame = trace.events.firstWhere(
      (event) => event.payload['stage'] == 'details-first-frame',
    );
    final failure = trace.events.firstWhere(
      (event) => event.payload['stage'] == 'comic-details-failure',
    );
    expect(firstFrame.monotonicMicros, greaterThanOrEqualTo(5000000));
    expect(failure.monotonicMicros, greaterThan(firstFrame.monotonicMicros));
  });

  testWidgets('local details retries an unpersisted chapter against the live source resolver', (tester) async {
    final source = _FixtureSource('fixture-live-source', '动态源');
    final manifest = await source.loadComic(source._comicId);
    final chapter = manifest.chapters.first;
    final comic = LibraryComic(
      sourceId: source.sourceId,
      comicId: source._comicId,
      title: source._comic.title,
      authors: source._comic.authors,
      tags: source._comic.tags,
      description: source._comic.description,
      coverSourceId: source._comic.coverUri?.toString(),
      readingDirection: source._comic.readingDirection,
      chapters: const <ImportedLibraryEntry>[],
      sourceChapters: <Chapter>[chapter],
      savedAt: DateTime.utc(2026, 9, 9),
      metadataUpdatedAt: DateTime.utc(2026, 9, 9),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: const <ImportedLibraryEntry>[],
      sourceComic: source._comic,
      sourceChapters: <Chapter>[chapter],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    BrowsableComicSource? availableSource;
    details.ComicDetailsChapterLoader? capturedLoader;
    var ensureCalls = 0;

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
            required String resourceRole,
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: null,
          resolveSource: (_) => availableSource,
          ensureSourceChapter: (resolved, resolvedComic, resolvedChapter) async {
            ensureCalls++;
            expect(identical(resolved, source), isTrue);
            return ImportedLibraryEntry(
              chapter: ImportedChapterRecord.remote(
                comic: resolvedComic,
                manifest: await source.loadChapter(resolvedChapter.chapterId),
              ),
            );
          },
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            loader, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {
            capturedLoader = loader;
            return null;
          },
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (entry) async =>
              ChapterDownloadSnapshot.idle(entry),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsChapterKey(source.sourceId, chapter.chapterId)),
    );
    await tester.tap(
      find.byKey(details.comicDetailsChapterKey(source.sourceId, chapter.chapterId)),
    );
    await tester.pump();
    expect(capturedLoader, isNotNull);

    await expectLater(capturedLoader!(), throwsA(isA<StateError>()));
    expect(ensureCalls, 0);
    availableSource = source;
    final recovered = await capturedLoader!();
    expect(recovered.chapter.chapterId, chapter.chapterId);
    expect(ensureCalls, 1);
  });

  testWidgets('local details refreshes a stale revision before Reader open', (tester) async {
    final source = _FixtureSource(
      'fixture-stale-details',
      '详情旧章节源',
      catalogPageCount: 0,
    );
    final manifest = await source.loadComic(source._comicId);
    final chapter = manifest.chapters.first;
    final freshEntry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: await source.loadChapter(chapter.chapterId),
      ),
    );
    final staleEntry = ImportedLibraryEntry(
      chapter: freshEntry.chapter.copyWith(sourceRevision: 'stale-r0'),
    );
    final comic = LibraryComic(
      sourceId: source.sourceId,
      comicId: source._comicId,
      title: source._comic.title,
      authors: source._comic.authors,
      tags: source._comic.tags,
      description: source._comic.description,
      coverSourceId: source._comic.coverUri?.toString(),
      readingDirection: source._comic.readingDirection,
      chapters: <ImportedLibraryEntry>[staleEntry],
      sourceChapters: <Chapter>[chapter],
      savedAt: DateTime.utc(2026, 9, 9),
      metadataUpdatedAt: DateTime.utc(2026, 9, 9),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[staleEntry],
      sourceComic: source._comic,
      sourceChapters: <Chapter>[chapter],
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    details.ComicDetailsChapterLoader? capturedLoader;
    var ensureCalls = 0;

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
            required String resourceRole,
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: source,
          resolveSource: (_) => source,
          ensureSourceChapter: (resolved, resolvedComic, resolvedChapter) async {
            ensureCalls++;
            return freshEntry;
          },
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            loader, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async {
            capturedLoader = loader;
            return null;
          },
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (entry) async =>
              ChapterDownloadSnapshot.idle(entry),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsChapterKey(source.sourceId, chapter.chapterId)),
    );
    final chapterTile = find.byKey(
      details.comicDetailsChapterKey(source.sourceId, chapter.chapterId),
    );
    expect(
      find.descendant(of: chapterTile, matching: find.text('1页')),
      findsOneWidget,
      reason: 'historical page list may project count without becoming Reader authority',
    );
    await tester.tap(chapterTile);
    await tester.pump();
    expect(capturedLoader, isNotNull);

    final opened = await capturedLoader!();
    expect(opened.chapter.sourceRevision, chapter.sourceRevision);
    expect(ensureCalls, 1);
  });

  testWidgets('details paints before bulk download status inspection completes',
      (tester) async {
    final source = _FixtureSource(
      'fixture-detail-first-frame',
      '详情首帧源',
      includeSecondChapter: true,
    );
    final firstEntry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: await source.loadChapter(source._chapterId),
      ),
    );
    final secondEntry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: await source.loadChapter(source._secondChapterId),
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
      chapters: <ImportedLibraryEntry>[firstEntry, secondEntry],
      sourceChapters: sourceManifest.chapters,
      savedAt: DateTime.utc(2026, 8, 1),
      metadataUpdatedAt: DateTime.utc(2026, 8, 2),
    );
    final library = details.ComicDetailsLibrarySnapshot(
      chapters: <ImportedLibraryEntry>[firstEntry, secondEntry],
      sourceComic: source._comic,
      sourceChapters: sourceManifest.chapters,
      readStates: const <String, ChapterReadState>{},
      preference: ComicPreference.defaults(
        sourceId: source.sourceId,
        comicId: source._comicId,
      ),
    );
    final releaseInspection = Completer<void>();
    var bulkInspectionStarted = false;

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
            required String resourceRole,
          }) async => MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: source,
          ensureSourceChapter: (_, __, ___) async => firstEntry,
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, __) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async => null,
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          inspectChapterDownloads: (chapters) async {
            bulkInspectionStarted = true;
            await releaseInspection.future;
            return chapters.map(ChapterDownloadSnapshot.idle).toList();
          },
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    expect(bulkInspectionStarted, isTrue);
    expect(find.byKey(details.localComicDetailsScreenKey), findsOneWidget);
    expect(find.byKey(details.comicDetailsChapterListKey), findsOneWidget);
    expect(find.text('第 2 话'), findsOneWidget);

    releaseInspection.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'local details follows current download projection across generation changes',
      (tester) async {
    final source = _FixtureSource(
      'fixture-local-download-generation',
      '本地详情下载代际源',
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: await source.loadChapter(source._chapterId),
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
      savedAt: DateTime.utc(2026, 9, 18),
      metadataUpdatedAt: DateTime.utc(2026, 9, 18),
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
    final projectionChanges = ChangeNotifier();
    addTearDown(projectionChanges.dispose);
    final staleStream = StreamController<ChapterDownloadSnapshot>.broadcast();
    addTearDown(staleStream.close);
    var current =
        _downloadSnapshot(entry, ChapterDownloadPhase.idle);
    var inspectCalls = 0;
    var blockNextInspection = false;
    var staleInspection = Completer<List<ChapterDownloadSnapshot>>();

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
            required String resourceRole,
          }) async =>
              MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          source: source,
          ensureSourceChapter: (_, _, _) async => entry,
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, _) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async =>
              null,
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (_) async => current,
          inspectChapterDownloads: (_) async {
            inspectCalls++;
            if (blockNextInspection) {
              blockNextInspection = false;
              return staleInspection.future;
            }
            return <ChapterDownloadSnapshot>[current];
          },
          downloadChanges: staleStream.stream,
          downloadProjectionChanges: projectionChanges,
          onDownloadComic: (_) async {},
        ),
      ),
    );

    final stopKey =
        details.comicDetailsStopDownloadKey(source.sourceId, source._chapterId);
    final downloadKey =
        details.comicDetailsDownloadKey(source.sourceId, source._chapterId);
    await _pumpUntilFound(tester, find.byKey(downloadKey));
    for (var frame = 0; frame < 30 && inspectCalls < 1; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(inspectCalls, greaterThanOrEqualTo(1));

    current = _downloadSnapshot(entry, ChapterDownloadPhase.downloading);
    projectionChanges.notifyListeners();
    for (var frame = 0; frame < 30 && inspectCalls < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(inspectCalls, greaterThanOrEqualTo(2));
    await _pumpUntilFound(tester, find.byKey(stopKey));

    staleStream.add(_downloadSnapshot(entry, ChapterDownloadPhase.complete));
    await tester.pump();
    expect(find.byKey(stopKey), findsOneWidget);

    blockNextInspection = true;
    staleInspection = Completer<List<ChapterDownloadSnapshot>>();
    projectionChanges.notifyListeners();
    for (var frame = 0; frame < 30 && inspectCalls < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(inspectCalls, greaterThanOrEqualTo(3));

    current = _downloadSnapshot(entry, ChapterDownloadPhase.idle);
    projectionChanges.notifyListeners();
    staleInspection.complete(<ChapterDownloadSnapshot>[
      _downloadSnapshot(entry, ChapterDownloadPhase.downloading),
    ]);
    for (var frame = 0; frame < 40 && inspectCalls < 4; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(inspectCalls, greaterThanOrEqualTo(4));
    expect(find.byKey(stopKey), findsNothing);
    expect(find.byKey(downloadKey), findsOneWidget);
  });

  testWidgets(
      'remote details follows current download projection instead of the route-open stream',
      (tester) async {
    final source = _FixtureSource(
      'fixture-remote-download-generation',
      '远程详情下载代际源',
    );
    final entry = ImportedLibraryEntry(
      chapter: ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: await source.loadChapter(source._chapterId),
      ),
    );
    final sourceManifest = await source.loadComic(source._comicId);
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
    final projectionChanges = ChangeNotifier();
    addTearDown(projectionChanges.dispose);
    final staleStream = StreamController<ChapterDownloadSnapshot>.broadcast();
    addTearDown(staleStream.close);
    var current = _downloadSnapshot(entry, ChapterDownloadPhase.idle);

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
            required String resourceRole,
          }) async =>
              MemoryEncodedResourceSource(_tinyPng()),
          reloadLibrary: ({required bool refreshContent}) async => library,
          ensureSourceChapter: (_, _, _) async => entry,
          persistComic: (_, _) async {},
          onPreferenceChanged: (_) async {},
          onReadChanged: (_, _) async {},
          onOpenChapter: (
            _, {
            required bool refreshRemote,
            required String title,
            int? initialPageIndex,
          }) async =>
              null,
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (_) async => current,
          inspectChapterDownloads: (_) async =>
              <ChapterDownloadSnapshot>[current],
          downloadChanges: staleStream.stream,
          downloadProjectionChanges: projectionChanges,
          onDownloadComic: (_) async {},
        ),
      ),
    );

    final stopKey =
        details.comicDetailsStopDownloadKey(source.sourceId, source._chapterId);
    final downloadKey =
        details.comicDetailsDownloadKey(source.sourceId, source._chapterId);
    await _pumpUntilFound(tester, find.byKey(downloadKey));

    current = _downloadSnapshot(entry, ChapterDownloadPhase.downloading);
    projectionChanges.notifyListeners();
    await _pumpUntilFound(tester, find.byKey(stopKey));

    staleStream.add(_downloadSnapshot(entry, ChapterDownloadPhase.complete));
    await tester.pump();
    expect(find.byKey(stopKey), findsOneWidget);

    current = _downloadSnapshot(entry, ChapterDownloadPhase.idle);
    projectionChanges.notifyListeners();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(stopKey).evaluate().isEmpty) {
        break;
      }
    }
    expect(find.byKey(stopKey), findsNothing);
    expect(find.byKey(downloadKey), findsOneWidget);
  });

  testWidgets(
      'persisted details paint before deferred external source activation',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'venera:deferred-details-fixture';
    const comicId = 'deferred-details-comic';
    const chapterId = 'deferred-details-chapter';
    await store.upsertChapter(
      ImportedChapterRecord(
        directoryId: '$sourceId:$comicId',
        displayName: '第 1 话',
        sourceId: sourceId,
        comicId: comicId,
        comicTitle: '延迟来源详情漫画',
        chapterId: chapterId,
        sourceRevision: 'r1',
        pages: const <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: '1.png',
            sourceId: 'https://example.invalid/deferred-details/page-1.png',
            pageId: 'deferred-details-page-1',
            contentKindHint: ContentKindHint.png,
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
    final trace = DebugTraceLog(maxEvents: 200, maxExportEvents: 400);
    addTearDown(trace.dispose);

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: const <BrowsableComicSource>[],
        externalPluginLoader: () async => null,
        debugTrace: trace,
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();
    final cover = find.byKey(comicCoverKey(sourceId, comicId));
    await tester.ensureVisible(cover);
    await tester.longPress(cover);
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(details.localComicDetailsScreenKey),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (trace.events.any(
        (event) => event.payload['stage'] == 'deferred-source-ready',
      )) {
        break;
      }
    }

    int stageIndex(String stage) => trace.events.indexWhere(
          (event) => event.payload['stage'] == stage,
        );
    final routePush = stageIndex('route-push');
    final firstFrame = stageIndex('details-first-frame');
    final sourceReady = stageIndex('deferred-source-ready');
    expect(routePush, greaterThanOrEqualTo(0));
    expect(firstFrame, greaterThan(routePush));
    expect(sourceReady, greaterThan(firstFrame));
    expect(
      trace.events[routePush].monotonicMicros,
      lessThan(trace.events[firstFrame].monotonicMicros),
    );
    expect(
      trace.events[firstFrame].monotonicMicros,
      lessThan(trace.events[sourceReady].monotonicMicros),
    );
    expect(
      trace.events[sourceReady].payload['available'],
      isFalse,
      reason: 'details must remain usable when deferred source activation fails',
    );
  });

  testWidgets('details separates same-source version view and migration',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-version';
    final versionLoadStarted = Completer<void>();
    final versionLoadGate = Completer<void>();
    final source = _FixtureSource(
      sourceId,
      '版本源',
      supportsComicVersions: true,
      versionLoadStarted: versionLoadStarted,
      versionLoadGate: versionLoadGate,
      comicVersions: const <SourceComicVersion>[
        SourceComicVersion(
          sourceId: sourceId,
          comicId: 'fixture-version-new-comic',
          title: '新版标题',
          generation: 2,
          date: '2026-08-24',
        ),
      ],
    );
    await store.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: sourceId,
        predecessorComicId: '$sourceId-comic',
        successorComicId: 'fixture-version-new-comic',
        predecessorTitle: '版本源 漫画',
        discoveredAt: DateTime.utc(2026, 8, 25),
      ),
    );
    await store.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: sourceId,
        predecessorComicId: 'fixture-version-old-comic',
        successorComicId: '$sourceId-comic',
        predecessorTitle: '旧版标题',
        discoveredAt: DateTime.utc(2026, 8, 20),
      ),
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
    expect(find.byKey(details.comicDetailsMigrateKey), findsOneWidget);
    expect(find.byKey(details.comicDetailsVersionActionKey), findsOneWidget);
    expect(versionLoadStarted.isCompleted, isTrue);
    expect(source.versionLoadCalls, 1,
        reason: 'details version discovery must have one owner');
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byKey(details.comicDetailsVersionViewKey), findsNothing);
    expect(find.byKey(details.comicDetailsVersionMigrateKey), findsNothing);
    await _tapVisible(
      tester,
      find.byKey(details.comicDetailsVersionActionKey),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(details.comicDetailsVersionViewKey),
    );
    expect(find.byKey(details.comicDetailsVersionMigrateKey), findsOneWidget);
    expect(find.text('新版本'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('版本源 漫画'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('更新日期：'), findsNothing,
        reason: 'relation discovery is not the source version date');
    expect(find.text('fixture-version-new-comic'), findsNothing);
    expect(find.textContaining('版本 2'), findsNothing);
    await tester.tap(find.byIcon(Icons.flip));
    await tester.pump();
    expect(find.text('旧版本'), findsOneWidget);
    expect(find.text('旧版标题'), findsOneWidget);
    expect(find.textContaining('更新日期：'), findsNothing,
        reason: 'stored predecessor source dates are unknown too');
    expect(
      tester
          .widget<IconButton>(
            find.byKey(details.comicDetailsVersionMigrateCurrentKey),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text('有新版本'), findsNothing);
    versionLoadGate.complete();
    await tester.tap(find.byIcon(Icons.flip));
    await _pumpUntilFound(tester, find.text('新版标题'));
    expect(find.text('更新日期：2026-08-24'), findsOneWidget);
    expect(find.text('更新日期：2026-08-25'), findsNothing);
    expect(find.text('fixture-version-new-comic'), findsNothing);
    expect(
      (await store.listComicVersionSuccessors(sourceId, '$sourceId-comic'))
          .single.discoveredAt,
      DateTime.utc(2026, 8, 25),
    );
    expect(
      (await store.listComicVersionPredecessors(sourceId, '$sourceId-comic'))
          .single.discoveredAt,
      DateTime.utc(2026, 8, 20),
    );
  });

  testWidgets('whole comic shelf and chapter download have separate ownership',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource('fixture', '测试源', runtimePageUri: true);

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

    final shelved = await store.getSavedComic('fixture', 'fixture-comic');
    expect(shelved, isNotNull);
    expect(shelved!.unseenChapterIds, const <String>{'fixture-chapter'});
    expect(await store.get('fixture', 'fixture-chapter'), isNull);
    expect(
      (await store.getComicPreference('fixture', 'fixture-comic'))?.inShelf,
      isTrue,
    );
    expect(
      find.byKey(
        details.comicDetailsNewChapterKey('fixture', 'fixture-chapter'),
      ),
      findsOneWidget,
    );

    final download =
        details.comicDetailsDownloadKey('fixture', 'fixture-chapter');
    await _tapVisible(tester, find.byKey(download));
    await _pumpUntilFound(tester, find.byIcon(Icons.download_done));

    final entry = await store.get('fixture', 'fixture-chapter');
    expect(entry, isNotNull);
    expect(entry!.chapter.sourceId, 'fixture');
    expect(entry.chapter.pages.single.stablePageId, 'fixture-page-1');
  });

  testWidgets('direct shelf Reader defers source versions until first presentation',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-reader-version-check';
    final versionLoadStarted = Completer<void>();
    final versionLoadGate = Completer<void>();
    final source = _FixtureSource(
      sourceId,
      'Reader版本检查源',
      supportsComicVersions: true,
      versionLoadStarted: versionLoadStarted,
      versionLoadGate: versionLoadGate,
    );
    final manifest = await source.loadChapter(source._chapterId);
    await store.upsertChapter(
      ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: manifest,
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: sourceId,
        comicId: source._comicId,
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
    await _tapVisible(
      tester,
      find.byKey(comicCoverKey(sourceId, source._comicId)),
    );
    await _pumpUntilFound(tester, find.byType(ImportedImageChapterScreen));
    final readerScreen = tester.widget<ImportedImageChapterScreen>(
      find.byType(ImportedImageChapterScreen),
    );

    expect(versionLoadStarted.isCompleted, isFalse);
    expect(source.versionLoadCalls, 0);
    expect(readerScreen.onFirstPresentationFrame, isNotNull);
    versionLoadGate.complete();

    // PipelineReaderSession intentionally retains a detached session for two
    // minutes. Tear the Reader down and advance that retention clock after
    // proving metadata/version discovery has not started before presentation.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('Reader session updates defer covered Home rebuild until route exit',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-reader-home-rebuild';
    final source = _FixtureSource(sourceId, 'Reader后台Home刷新源');
    final manifest = await source.loadChapter(source._chapterId);
    await store.upsertChapter(
      ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: manifest,
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: sourceId,
        comicId: source._comicId,
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
    await _tapVisible(
      tester,
      find.byKey(comicCoverKey(sourceId, source._comicId)),
    );
    await _pumpUntilFound(tester, find.byType(ImportedImageChapterScreen));
    expect(find.byType(NavigationBar), findsOneWidget);
    final coveredHomeNavigation = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    final reader = tester.widget<ImportedImageChapterScreen>(
      find.byType(ImportedImageChapterScreen),
    );

    await Future<void>.sync(() => reader.onFavoriteChanged!(true));
    await tester.pump();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)),
      same(coveredHomeNavigation),
      reason: 'Home presentation must not rebuild under an active Reader route',
    );
    expect(
      (await store.getComicPreference(sourceId, source._comicId))?.collected,
      isTrue,
      reason: 'only Home presentation rebuild is deferred; persistence continues',
    );

    Navigator.of(tester.element(find.byType(ImportedImageChapterScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ImportedImageChapterScreen), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)),
      isNot(same(coveredHomeNavigation)),
      reason: 'Reader exit must publish one catch-up Home rebuild',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets(
      'Reader metadata refresh retries one foreground runtime preemption',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    const sourceId = 'fixture-reader-metadata-preempt';
    final trace = DebugTraceLog(maxEvents: 200, maxExportEvents: 400);
    addTearDown(trace.dispose);
    final source = _FixtureSource(
      sourceId,
      'Reader后台刷新源',
      supportsComicVersions: true,
      rotateChapterLocator: true,
      chapterLoadErrors: const <Object>[
        Failure(
          code: ErrorCode.cancelled,
          message: 'foreground page plan preempted metadata request',
          details: <String, Object?>{
            'runtimeErrorCode': 'runtime-request-cancelled',
          },
        ),
      ],
    );
    final manifest = source._chapterManifest(
      source._chapterId,
      durableRuntimeLocator: false,
    );
    await store.upsertChapter(
      ImportedChapterRecord.remote(
        comic: source._comic,
        manifest: manifest,
      ),
    );
    await store.saveComicPreference(
      ComicPreference.defaults(
        sourceId: sourceId,
        comicId: source._comicId,
        sourceKind: ComicSourceKind.remote,
      ),
    );

    await tester.pumpWidget(
      App(
        libraryStore: store,
        comicSources: <BrowsableComicSource>[source],
        debugTrace: trace,
      ),
    );
    await _pumpUntilFound(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.collections_bookmark_outlined));
    await tester.pump();
    await _tapVisible(
      tester,
      find.byKey(comicCoverKey(sourceId, source._comicId)),
    );
    await _pumpUntilFound(tester, find.byType(ImportedImageChapterScreen));
    final readerScreen = tester.widget<ImportedImageChapterScreen>(
      find.byType(ImportedImageChapterScreen),
    );

    readerScreen.onFirstPresentationFrame!();
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (trace.events.any(
        (event) =>
            event.payload['stage'] ==
            'reader-metadata-version-refresh-complete',
      )) {
        break;
      }
    }

    expect(source.chapterLoads, 2);
    expect(source.versionLoadCalls, 1);
    expect(source.controlledChapterPriorities, <int>[100, 100]);
    final persistedAfterMetadata = await store.get(sourceId, source._chapterId);
    expect(
      persistedAfterMetadata?.chapter.pages.single.sourceId,
      contains('/generation-0/page-1.png'),
      reason:
          'post-first-frame metadata/version refresh may observe a fresh carrier '
          'but must not replace the persisted Reader page transport authority',
    );
    expect(source.controlledVersionPriorities, <int>[100]);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.taskFailed &&
            event.payload['stage'] == 'reader-metadata-refresh-failed',
      ),
      isEmpty,
    );
    final preempted = trace.events.singleWhere(
      (event) => event.payload['stage'] == 'reader-metadata-refresh-preempted',
    );
    expect(preempted.kind, TraceEventKind.artifactSource);
    expect(preempted.payload['errorCode'], ErrorCode.cancelled.name);
    expect(
      preempted.payload['runtimeErrorCode'],
      'runtime-request-cancelled',
    );
    final completed = trace.events.singleWhere(
      (event) =>
          event.payload['stage'] == 'reader-metadata-version-refresh-complete',
    );
    expect(completed.payload['metadataSnapshotLoaded'], isTrue);
    expect(completed.payload['chapterPersisted'], isFalse);
    expect(completed.payload['pageCarrierPersisted'], isFalse);
    expect(completed.payload['metadataPreempted'], isTrue);
    expect(completed.payload['metadataRetryAttempted'], isTrue);
    expect(completed.payload['versionChecked'], isTrue);
    expect(completed.payload['schedulerPriority'], 100);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
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
    await _pumpUntilFound(tester, find.byIcon(Icons.download_done));
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
    expect(
      find.byKey(
          sourceChapterKey('fixture-refresh', 'fixture-refresh-chapter')),
      findsOneWidget,
    );
    expect(
      find.byKey(
          sourceChapterKey('fixture-refresh', 'fixture-refresh-chapter-2')),
      findsOneWidget,
    );
    expect(await store.get('fixture-refresh', 'fixture-refresh-chapter-2'),
        isNull);
    final savedComic = await store.getSavedComic(
      'fixture-refresh',
      'fixture-refresh-comic',
    );
    expect(savedComic, isNotNull);
    expect(savedComic?.chapters, hasLength(2));
    expect(
      savedComic?.unseenChapterIds,
      const <String>{'fixture-refresh-chapter-2'},
    );
    expect(
      find.byKey(
        details.comicDetailsNewChapterKey(
          'fixture-refresh',
          'fixture-refresh-chapter-2',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        details.comicDetailsNewChapterKey(
          'fixture-refresh',
          'fixture-refresh-chapter',
        ),
      ),
      findsNothing,
      reason: 'the first catalog load establishes the baseline',
    );
    expect(source.loadedResources, isEmpty);

    await _tapVisible(
      tester,
      find.byKey(
        sourceChapterKey(
          'fixture-refresh',
          'fixture-refresh-chapter-2',
        ),
      ),
    );
    SavedComicRecord? viewedSavedComic;
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      viewedSavedComic = await store.getSavedComic(
        'fixture-refresh',
        'fixture-refresh-comic',
      );
      if (viewedSavedComic?.unseenChapterIds.isEmpty == true) break;
    }
    expect(viewedSavedComic?.unseenChapterIds, isEmpty);

    // Opening the chapter proves the persisted unseen marker is consumed by
    // the real details -> Reader path. Retained Reader sessions intentionally
    // own a two-minute expiry timer, so drain that contract before teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('active chapter download survives details route re-entry',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final source = _FixtureSource(
      'fixture-active',
      '进行中下载源',
      runtimePageUri: true,
    );
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
    final stopDownloadKey = details.comicDetailsStopDownloadKey(
      'fixture-active',
      'fixture-active-chapter',
    );
    await _pumpUntilFound(tester, find.byKey(downloadKey));
    await _tapVisible(tester, find.byKey(downloadKey));
    for (var frame = 0; frame < 80 && !pageStarted.isCompleted; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(pageStarted.isCompleted, isTrue);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(stopDownloadKey),
        matching: find.byIcon(Icons.stop_circle_outlined),
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
        of: find.byKey(stopDownloadKey),
        matching: find.byIcon(Icons.stop_circle_outlined),
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
      runtimePageUri: true,
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
      find.byKey(details.remoteComicDetailsScreenKey),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(
        details.comicDetailsChapterKey('fixture-whole', 'fixture-whole-chapter'),
      ),
    );
    await _tapVisible(
      tester,
      find.descendant(
        of: find.byKey(details.comicDetailsDownloadAllKey),
        matching: find.byType(IconButton),
      ),
    );

    ImportedLibraryEntry? first;
    ImportedLibraryEntry? second;
    for (var frame = 0; frame < 240; frame++) {
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
      find.descendant(of: chapterTile, matching: find.text('待加载')),
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
            required String resourceRole,
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
          }) async => null,
          onDownloadChapter: (_) async {},
          inspectChapterDownload: (chapter) async =>
              ChapterDownloadSnapshot.idle(chapter),
          downloadChanges: const Stream<ChapterDownloadSnapshot>.empty(),
          onDownloadComic: (_) async {},
        ),
      ),
    );

    await loadStarted.future;
    final refresh = tester.state<RefreshIndicatorState>(
      find.descendant(
        of: find.byKey(details.remoteComicDetailsScreenKey),
        matching: find.byType(RefreshIndicator),
      ),
    );
    unawaited(refresh.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    loadGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.descendant(
        of: find.byKey(details.comicDetailsRefreshStateKey),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
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
            required String resourceRole,
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
          }) async => null,
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
        ControlledComicSource,
        CanonicalComicIdentitySource,
        ComicVersionSource,
        ControlledComicVersionSource,
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
    this.rotateChapterLocator = false,
    this.catalogPageCount = 1,
    this.chapterUpdatedAt,
    this.browseItemCount = 1,
    this.browseGate,
    this.nativeBrowsePageSize,
    this.browsePageOverrides,
    this.emptyCatalog = false,
    this.comicTags = const <String>[],
    this.firstComicLoadStarted,
    this.firstComicLoadGate,
    this.supportsComicVersions = false,
    this.versionLoadStarted,
    this.versionLoadGate,
    this.comicVersions = const <SourceComicVersion>[],
    this.chapterLoadErrors = const <Object>[],
    this.supportsComicPreview = false,
    this.previewPageCount = 1,
    this.previewCrops = false,
    this.previewLandscapeIndexes = const <int>{},
    this.supportsComicComments = false,
    this.browseSections = const <SourceBrowseSection>[],
    this.searchFilters = const <SourceSearchFilterNode>[],
    this.canonicalComicIdentityOverride,
  });

  @override
  final String sourceId;
  final String name;
  final bool failFirstComicLoad;
  final Object? browseError;
  final bool includeSecondChapter;
  final bool revealSecondChapterOnRefresh;
  final bool runtimePageUri;
  final bool rotateChapterLocator;
  final int catalogPageCount;
  final DateTime? chapterUpdatedAt;
  final int browseItemCount;
  final Completer<void>? browseGate;
  final int? nativeBrowsePageSize;
  final Map<int, SourceBrowsePage>? browsePageOverrides;
  final bool emptyCatalog;
  final List<String> comicTags;
  final Completer<void>? firstComicLoadStarted;
  final Completer<void>? firstComicLoadGate;
  @override
  final bool supportsComicVersions;
  final Completer<void>? versionLoadStarted;
  final Completer<void>? versionLoadGate;
  final List<SourceComicVersion> comicVersions;
  final List<Object> chapterLoadErrors;
  @override
  final bool supportsComicPreview;
  final int previewPageCount;
  final bool previewCrops;
  final Set<int> previewLandscapeIndexes;
  @override
  final bool supportsComicComments;
  final List<SourceBrowseSection> browseSections;
  final List<SourceSearchFilterNode> searchFilters;
  final String? canonicalComicIdentityOverride;
  String? browseComicIdOverride;
  String? lastBrowseSection;
  SourceSearchFilterState lastFilterState = const <String, Object?>{};
  int _comicLoads = 0;
  int _chapterLoads = 0;
  int _chapterRefreshes = 0;
  int versionLoadCalls = 0;
  int browseCalls = 0;
  final List<String> browseQueries = <String>[];
  final List<int> browseOffsets = <int>[];
  int filteredBrowseCalls = 0;
  final List<Uri> loadedResources = <Uri>[];
  final List<String?> previewTokens = <String?>[];
  final List<int> controlledComicPriorities = <int>[];
  final List<int> controlledChapterPriorities = <int>[];
  final List<int> controlledVersionPriorities = <int>[];

  int get comicLoads => _comicLoads;
  int get chapterLoads => _chapterLoads;
  int get chapterRefreshes => _chapterRefreshes;

  String get _comicId => '$sourceId-comic';
  String get _chapterId => '$sourceId-chapter';
  String get _secondChapterId => '$sourceId-chapter-2';

  @override
  String canonicalComicIdentity(String comicId) =>
      canonicalComicIdentityOverride ?? comicId;

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
        coverUri: runtimePageUri
            ? Uri.parse('venera-resource:$sourceId/cover.png')
            : Uri.https('example.invalid', '/$sourceId/cover.png'),
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
        updatedAt: chapterUpdatedAt,
      );

  Chapter _resolvedChapterAt(int sequence) => Chapter(
        chapterId: sequence == 1 ? _chapterId : _secondChapterId,
        comicId: _comicId,
        title: '第 $sequence 话',
        sequence: sequence,
        pageCount: 1,
        sourceRevision: 'fixture-r$sequence',
        updatedAt: chapterUpdatedAt,
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
  Future<List<SourceSearchFilterNode>> loadSearchFilters() async =>
      searchFilters;

  @override
  Future<SourceBrowsePage> browseWithFilters({
    String? sectionId,
    String query = '',
    int offset = 0,
    int limit = 24,
    SourceSearchFilterState filterState = const <String, Object?>{},
  }) {
    filteredBrowseCalls++;
    lastBrowseSection = sectionId;
    lastFilterState = Map<String, Object?>.unmodifiable(filterState);
    return browse(query: query, offset: offset, limit: limit);
  }

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async {
    browseCalls++;
    browseQueries.add(query);
    browseOffsets.add(offset);
    final gate = browseGate;
    if (gate != null) await gate.future;
    final error = browseError;
    if (error != null) {
      throw error;
    }
    final pageOverride = browsePageOverrides?[offset];
    if (pageOverride != null) return pageOverride;
    final all = <SourceComicSummary>[
      for (var index = 0; index < browseItemCount; index++)
        SourceComicSummary(
          sourceId: sourceId,
          comicId: browseItemCount == 1
              ? (browseComicIdOverride ?? _comicId)
              : '$sourceId-comic-$index',
          title: browseItemCount == 1 ? _comic.title : '$name 漫画 $index',
          authors: _comic.authors,
          tags: _comic.tags,
          coverUri: _comic.coverUri,
        ),
    ];
    final matching = query.isEmpty
        ? all
        : all.where((summary) => summary.title.contains(query)).toList();
    final nativeSize = nativeBrowsePageSize;
    final start = (nativeSize == null ? offset : (offset ~/ limit) * nativeSize)
        .clamp(0, matching.length).toInt();
    final end = (start + (nativeSize ?? limit))
        .clamp(start, matching.length).toInt();
    return SourceBrowsePage(
      items: matching.sublist(start, end),
      offset: nativeSize == null ? start : offset,
      hasMore: end < matching.length,
      nextOffset: nativeSize != null && end < matching.length
          ? offset + limit
          : null,
    );
  }

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    versionLoadCalls++;
    expectSync(comicId, _comicId);
    final started = versionLoadStarted;
    if (started != null && !started.isCompleted) started.complete();
    await versionLoadGate?.future;
    return comicVersions;
  }

  @override
  Future<List<SourceComicVersion>> findComicVersionsControlled(
    String comicId, {
    TaskControl? control,
  }) {
    if (control != null) controlledVersionPriorities.add(control.priority);
    return findComicVersions(comicId);
  }

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    expectSync(comicId, _comicId);
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
  Future<ComicManifest> loadComicControlled(
    String comicId, {
    TaskControl? control,
  }) {
    if (control != null) controlledComicPriorities.add(control.priority);
    return loadComic(comicId);
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
    expectSync(chapterId, anyOf(_chapterId, _secondChapterId));
    final loadIndex = _chapterLoads++;
    if (loadIndex < chapterLoadErrors.length) {
      throw chapterLoadErrors[loadIndex];
    }
    return _chapterManifest(chapterId, durableRuntimeLocator: false);
  }

  @override
  Future<ChapterManifest> loadChapterControlled(
    String chapterId, {
    TaskControl? control,
  }) {
    if (control != null) controlledChapterPriorities.add(control.priority);
    return loadChapter(chapterId);
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
                  '/$sourceId/$chapterId/'
                  '${rotateChapterLocator ? 'generation-$_chapterLoads/' : ''}'
                  'page-1.png',
                ),
          contentKindHint: ContentKindHint.png,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async {
    if (!uri.path.endsWith('/cover.png')) {
      loadedResources.add(uri);
    }
    return _tinyPng();
  }
}
