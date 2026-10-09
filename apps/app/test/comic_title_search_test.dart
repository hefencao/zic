import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:zic/app.dart';
import 'package:zic/comic_details.dart' as details;
import 'package:zic/home_shell.dart';
import 'package:zic/source_browser.dart';
import 'package:zic/source_migration_compare.dart';

Uint8List _png() => base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Missing $finder');
}

Widget _page(List<_Source> sources, {
  String query = '漫画标题',
  Future<void> Function(BrowsableComicSource, SourceComicSummary)? open,
}) => MaterialApp(home: ComicTitleSearchPage(
  query: query,
  sources: sources,
  loadCover: (_, _, _, {bool forceRefresh = false}) async => MemoryEncodedResourceSource(_png()),
  onOpenComic: open ?? (_, _) async {},
));

void main() {
  testWidgets('migration aggregates editable candidates and keeps exact selection readonly until confirmation',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final origin = _Source('venera:origin', '禁漫天堂');
    final target = _Source('mihon:target', '禁漫天堂');
    final other = _Source('mihon:other', '另一来源');
    const nativeId = 'mihon:manga:eyJ1cmwiOiIvYWxidW0vNDIifQ==';
    const query = 'https://source.invalid/album/42';
    target.handler = (value, offset) async => SourceBrowsePage(
      items: value == query ? [target.summary('目标漫画', id: nativeId)] : [],
      offset: offset, hasMore: false,
    );
    for (final source in [origin, target, other]) {
      await store.saveSourcePreference(ComicSourcePreference.defaults(sourceId: source.sourceId));
    }
    await tester.pumpWidget(App(libraryStore: store,
        comicSources: [origin, target, other], persistHomeProjectionSnapshot: false));
    await _until(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _until(tester, find.byKey(sourceComicCardKey(origin.sourceId, 'book')));
    await tester.tap(find.byKey(sourceComicCardKey(origin.sourceId, 'book')));
    await _until(tester, find.byKey(details.comicDetailsMigrateKey));
    await tester.pump(const Duration(milliseconds: 400));
    final savedBefore = jsonEncode((await store.listSavedComics()).map((c) => c.toJson()).toList());
    final preferencesBefore = jsonEncode((await store.listComicPreferences()).map((p) => p.toJson()).toList());
    await tester.tap(find.byKey(details.comicDetailsMigrateKey));
    await _until(tester, find.byKey(comicTitleSearchPageKey));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byKey(sourceComicCardKey(origin.sourceId, 'book')), findsNothing);
    expect(target.requests, [('漫画标题', 0)]);
    expect(other.requests, [('漫画标题', 0)]);
    await tester.tap(find.widgetWithText(FilterChip, '另一来源 · Mihon 插件'));
    await tester.pump();
    expect(find.byKey(comicTitleSearchGroupKey(other.sourceId)), findsNothing);
    expect(target.requests, hasLength(1), reason: 'changing selected sources keeps other groups');
    await tester.enterText(find.byKey(comicTitleSearchInputKey), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    final candidate = find.byKey(sourceComicCardKey(target.sourceId, nativeId));
    await _until(tester, candidate);
    await tester.ensureVisible(candidate);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(nativeId), findsNothing);
    await tester.tap(candidate);
    await _until(tester, find.byKey(sourceMigrationComparisonDialogKey));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 20));
    expect(target.loadedComicIds, [nativeId]);
    expect(find.byKey(comicTitleSearchPageKey), findsNothing);
    expect(jsonEncode((await store.listSavedComics()).map((c) => c.toJson()).toList()), savedBefore);
    expect(jsonEncode((await store.listComicPreferences()).map((p) => p.toJson()).toList()), preferencesBefore);
    expect(await store.getSavedComic(target.sourceId, nativeId), isNull);
    expect(tester.widget<FilledButton>(find.byKey(sourceMigrationComparisonConfirmKey)).onPressed, isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(details.comicDetailsMigrateKey), findsOneWidget);
    expect(await store.getSavedComic(target.sourceId, nativeId), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('migration advanced native input requires one source and clears on selection change',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final origin = _Source('venera:origin', '原来源');
    final target = _Source('mihon:target', '目标来源');
    for (final source in [origin, target]) {
      await store.saveSourcePreference(ComicSourcePreference.defaults(sourceId: source.sourceId));
    }
    await tester.pumpWidget(App(libraryStore: store,
        comicSources: [origin, target], persistHomeProjectionSnapshot: false));
    await _until(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _until(tester, find.byKey(sourceComicCardKey(origin.sourceId, 'book')));
    await tester.tap(find.byKey(sourceComicCardKey(origin.sourceId, 'book')));
    await _until(tester, find.byKey(details.comicDetailsMigrateKey));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(details.comicDetailsMigrateKey));
    await _until(tester, find.byKey(comicTitleSearchPageKey));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('高级：原生 ID'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '原来源 · Venera 插件'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField), '/album/42');
    await tester.tap(find.widgetWithText(FilterChip, '原来源 · Venera 插件'));
    await tester.pump();
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '目标来源 · Mihon 插件'));
    await tester.pump();
    final field = find.descendant(of: find.byType(TextFormField), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).controller.text, isEmpty);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '使用原生 ID')).onPressed, isNull);
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(details.comicDetailsMigrateKey), findsOneWidget);
    expect(target.loadedComicIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source groups complete independently and rebuild without new requests',
      (tester) async {
    final pending = Completer<SourceBrowsePage>();
    final slow = _Source('mihon:one:a', '慢源', handler: (_, _) => pending.future);
    final fast = _Source('mihon:one:b', '快源');
    final disabled = _Source('disabled', '不可搜索', searchable: false);
    SourceComicSummary? opened;
    Future<void> open(BrowsableComicSource source, SourceComicSummary comic) async {
      expect(identical(source, fast), isTrue);
      opened = comic;
    }
    await tester.pumpWidget(_page([slow, fast, disabled], open: open));
    await _until(tester, find.byKey(sourceComicCardKey(fast.sourceId, 'book')));
    expect(find.byKey(comicTitleSearchGroupKey(slow.sourceId)), findsOneWidget);
    expect(find.byKey(comicTitleSearchGroupKey(fast.sourceId)), findsOneWidget);
    expect(disabled.requests, isEmpty);
    await tester.pumpWidget(_page([slow, fast, disabled], open: open));
    await tester.pump(const Duration(milliseconds: 20));
    expect(slow.requests, [('漫画标题', 0)]);
    expect(fast.requests, [('漫画标题', 0)]);
    await tester.tap(find.byKey(sourceComicCardKey(fast.sourceId, 'book')));
    expect(opened?.comicId, 'book');
    pending.complete(slow.page('慢源结果'));
    await _until(tester, find.text('慢源结果'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one failure stays local and only explicit retry submits again',
      (tester) async {
    final bad = _Source('bad', '失败源',
        handler: (_, _) => Future<SourceBrowsePage>.error(StateError('offline')));
    final fast = _Source('fast', '正常源');
    await tester.pumpWidget(_page([bad, fast]));
    await _until(tester, find.byKey(sourceComicCardKey(fast.sourceId, 'book')));
    final group = find.byKey(comicTitleSearchGroupKey(bad.sourceId));
    final retry = find.descendant(of: group, matching: find.byTooltip('重试'));
    expect(retry, findsOneWidget);
    await tester.pumpWidget(_page([bad, fast]));
    await tester.pump(const Duration(seconds: 1));
    expect(bad.requests, hasLength(1));
    bad.handler = (_, _) async => bad.page('恢复结果');
    await tester.tap(retry);
    await _until(tester, find.text('恢复结果'));
    expect(bad.requests, hasLength(2));
    expect(fast.requests, hasLength(1));
  });

  testWidgets('deferred sources join the current query without restarting existing groups',
      (tester) async {
    final pending = Completer<SourceBrowsePage>();
    final first = _Source('venera:one:a', '已就绪源');
    final arriving = _Source('mihon:one:a', '后激活源',
        handler: (_, _) => pending.future);
    final fast = _Source('mihon:one:b', '后激活快源');
    await tester.pumpWidget(_page([first]));
    await _until(tester, find.byKey(sourceComicCardKey(first.sourceId, 'book')));
    await tester.enterText(find.byKey(comicTitleSearchInputKey), '当前查询');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _until(tester, find.byKey(sourceComicCardKey(first.sourceId, 'book')));
    await tester.pumpWidget(_page([first, arriving, fast]));
    await _until(tester, find.byKey(sourceComicCardKey(fast.sourceId, 'book')));
    expect(first.requests, [('漫画标题', 0), ('当前查询', 0)]);
    expect(arriving.requests, [('当前查询', 0)]);
    expect(fast.requests, [('当前查询', 0)]);
    await tester.pumpWidget(_page([first, fast]));
    pending.complete(arriving.page('已移除源的迟到结果'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('已移除源的迟到结果'), findsNothing);
    expect(find.byKey(comicTitleSearchGroupKey(arriving.sourceId)), findsNothing);
    expect(first.requests, hasLength(2));
    expect(fast.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('old query completion and disposed requests cannot replace a new view',
      (tester) async {
    final old = Completer<SourceBrowsePage>();
    final source = _Source('source', '源');
    source.handler = (query, _) => query == '旧查询'
        ? old.future : Future.value(source.page('新结果'));
    await tester.pumpWidget(_page([source], query: '旧查询'));
    await tester.enterText(find.byKey(comicTitleSearchInputKey), '新查询');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _until(tester, find.text('新结果'));
    old.complete(source.page('旧结果'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('旧结果'), findsNothing);
    expect(source.requests, [('旧查询', 0), ('新查询', 0)]);
    final retired = Completer<SourceBrowsePage>();
    source.handler = (_, _) => retired.future;
    await tester.enterText(find.byKey(comicTitleSearchInputKey), '退出查询');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpWidget(const SizedBox.shrink());
    retired.complete(source.page('迟到结果'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group paging preserves query and source coordinates before canonical projection',
      (tester) async {
    final source = _Source('source', '源');
    source.handler = (_, offset) async => offset == 0
        ? SourceBrowsePage(items: [source.summary('第一页', id: 'book'),
            source.summary('重复别名', id: 'book-alias')],
            offset: 0, hasMore: true, nextOffset: 41)
        : source.page('第二页', offset: offset);
    await tester.pumpWidget(_page([source]));
    await _until(tester, find.text('第一页'));
    expect(find.text('重复别名'), findsNothing);
    await tester.tap(find.byTooltip('下一页'));
    await _until(tester, find.text('第二页'));
    await tester.tap(find.byTooltip('上一页'));
    await _until(tester, find.text('第一页'));
    expect(source.requests, [('漫画标题', 0), ('漫画标题', 41), ('漫画标题', 0)]);
  });

  testWidgets('cold source page consumes metadata search command on first mount',
      (tester) async {
    final source = _Source('fixture-cold-tag', '冷启动来源');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ComicSourcesPage(
      sources: [source],
      activeSourceId: source.sourceId,
      requestedQuery: '  route-tag  ',
      queryRevision: 1,
      onSourceSelected: (_) {},
      loadCover: (_, __, ___, {bool forceRefresh = false}) async => MemoryEncodedResourceSource(_png()),
      onOpenComic: (_, __) async {},
    ))));
    await _until(tester, find.byKey(sourceComicCardKey(source.sourceId, 'book')));
    expect(source.requests, [('route-tag', 0)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title pushes aggregate route, current result returns, nested tag reaches source page',
      (tester) async {
    final store = MemoryImportedLibraryStore();
    await store.open();
    addTearDown(store.close);
    final first = _Source('fixture-a', '源 A');
    final second = _Source('fixture-b', '源 B');
    await tester.pumpWidget(App(libraryStore: store, comicSources: [first, second]));
    await _until(tester, find.byKey(homeUpdatesSectionKey));
    await tester.tap(find.byIcon(Icons.public_outlined));
    await _until(tester, find.byKey(sourceComicCardKey(first.sourceId, 'book')));
    await tester.tap(find.byKey(sourceComicCardKey(first.sourceId, 'book')));
    await _until(tester, find.byKey(details.comicDetailsTitleSearchKey));
    final original = tester.state(find.byType(details.RemoteComicDetailsScreen));
    await tester.tap(find.byKey(details.comicDetailsTitleSearchKey));
    await _until(tester, find.byKey(comicTitleSearchPageKey));
    await tester.pump(const Duration(milliseconds: 400));
    final current = find.descendant(of: find.byKey(comicTitleSearchPageKey),
        matching: find.byKey(sourceComicCardKey(first.sourceId, 'book')));
    await _until(tester, current);
    await tester.tap(current);
    await _until(tester, find.byKey(details.comicDetailsTitleSearchKey));
    await tester.pump(const Duration(milliseconds: 400));
    expect(identical(tester.state(find.byType(details.RemoteComicDetailsScreen)), original), isTrue);
    await tester.tap(find.byKey(details.comicDetailsTitleSearchKey));
    await _until(tester, find.byKey(comicTitleSearchPageKey));
    await tester.pump(const Duration(milliseconds: 400));
    final other = find.descendant(of: find.byKey(comicTitleSearchPageKey),
        matching: find.byKey(sourceComicCardKey(second.sourceId, 'book')));
    await _until(tester, other);
    await tester.ensureVisible(other);
    await tester.tap(other);
    await _until(tester, find.byKey(details.comicDetailsTitleSearchKey));
    await tester.pump(const Duration(milliseconds: 400));
    await _until(tester, find.text('route-tag'));
    await tester.ensureVisible(find.text('route-tag'));
    await tester.tap(find.text('route-tag'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(comicTitleSearchPageKey).evaluate().isEmpty &&
          find.byKey(details.comicDetailsScreenKey).evaluate().isEmpty) break;
    }
    expect(find.byKey(comicTitleSearchPageKey), findsNothing);
    expect(find.byKey(details.comicDetailsScreenKey), findsNothing);
    expect(find.byKey(comicSourcesPageKey), findsOneWidget);
    await _until(tester, find.byKey(sourceComicCardKey(second.sourceId, 'book')));
    expect(second.requests.last.$1, 'route-tag');
    expect(tester.takeException(), isNull);
  });
}

final class _Source implements BrowsableComicSource, CanonicalComicIdentitySource {
  _Source(this.sourceId, this.name, {this.handler, this.searchable = true});
  @override
  final String sourceId;
  final String name;
  final bool searchable;
  Future<SourceBrowsePage> Function(String, int)? handler;
  final List<(String, int)> requests = [];
  final List<String> loadedComicIds = [];
  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
      sourceId: sourceId, name: name, language: 'zh',
      website: Uri.parse('https://source.invalid'), supportsSearch: searchable);
  SourceComicSummary summary(String title, {String id = 'book'}) => SourceComicSummary(
      sourceId: sourceId, comicId: id, title: title, authors: const []);
  SourceBrowsePage page(String title, {int offset = 0}) => SourceBrowsePage(
      items: [summary(title)], offset: offset, hasMore: false);
  @override
  Future<SourceBrowsePage> browse({String query = '', int offset = 0, int limit = 24}) {
    requests.add((query, offset));
    return handler?.call(query, offset) ?? Future.value(page('漫画标题', offset: offset));
  }
  @override
  String canonicalComicIdentity(String id) => id == 'book-alias' ? 'book' : id;
  @override
  Future<ComicManifest> loadComic(String id) async {
    loadedComicIds.add(id);
    return ComicManifest(
      comic: Comic(comicId: id, sourceId: sourceId, title: '漫画标题',
          authors: const [], tags: const ['route-tag'], readingDirection: ReadingDirection.vertical),
      chapters: const []);
  }
  @override
  Future<ChapterManifest> loadChapter(String id) => throw UnsupportedError('not needed');
  @override
  Future<Uint8List> loadResource(Uri uri) async => _png();
}
