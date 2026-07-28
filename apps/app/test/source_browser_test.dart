import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
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
      find.byKey(sourceComicCardKey('fixture-a-comic')),
    );

    expect(first.browseCalls, 1);
    expect(find.byKey(comicSourceManageKey), findsOneWidget);
    expect(find.byKey(comicSourceSwitcherKey), findsOneWidget);

    await tester.tap(find.byKey(comicSourceChoiceKey('fixture-b')));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceComicCardKey('fixture-b-comic')),
    );

    await tester.tap(find.byKey(comicSourceManageKey));
    await tester.pumpAndSettle();
    expect(find.text('漫画源管理'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));

    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pump();
    final stored = await store.listSourcePreferences();
    expect(
      stored.singleWhere((item) => item.sourceId == 'fixture-b').enabled,
      isFalse,
    );

    await tester.pageBack();
    await tester.pumpAndSettle();
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
    final details = tester.widget<SelectableText>(
      find.byKey(comicSourceErrorDetailsKey),
    );
    expect(details.data, contains('https://api.mangadex.org/manga?limit=24'));
    expect(details.data, contains('Cause: Bad state: Failed host lookup'));

    await tester.tap(find.byKey(comicSourceCopyErrorKey));
    await tester.pump();
    expect(clipboardWrites, hasLength(1));
    expect(clipboardWrites.single, details.data);
  });

  testWidgets('source chapter enters the durable library model', (tester) async {
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
      find.byKey(sourceComicCardKey('fixture-comic')),
    );

    await tester.tap(find.byKey(sourceComicCardKey('fixture-comic')));
    await _pumpUntilFound(tester, find.byKey(sourceChapterKey('fixture-chapter')));
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pumpAndSettle();

    final entry = await store.get('fixture-chapter');
    expect(entry, isNotNull);
    expect(entry!.chapter.sourceId, 'fixture');
    expect(entry.chapter.pages.single.stablePageId, 'fixture-page-1');
    expect(
      (await store.getComicPreference('fixture-comic'))?.sourceKind,
      ComicSourceKind.remote,
    );
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
      find.byKey(sourceComicCardKey('fixture-retry-comic')),
    );
    await tester.tap(find.byKey(sourceComicCardKey('fixture-retry-comic')));
    await _pumpUntilFound(tester, find.textContaining('漫画详情加载失败'));

    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await _pumpUntilFound(
      tester,
      find.byKey(sourceChapterKey('fixture-retry-chapter')),
    );
  });
}

final class _FixtureSource implements BrowsableComicSource {
  _FixtureSource(
    this.sourceId,
    this.name, {
    this.failFirstComicLoad = false,
    this.browseError,
  });

  @override
  final String sourceId;
  final String name;
  final bool failFirstComicLoad;
  final Object? browseError;
  int _comicLoads = 0;
  int browseCalls = 0;

  String get _comicId => '$sourceId-comic';
  String get _chapterId => '$sourceId-chapter';

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

  Chapter get _chapter => Chapter(
        chapterId: _chapterId,
        comicId: _comicId,
        title: '第 1 话',
        sequence: 1,
        pageCount: 1,
        sourceRevision: 'fixture-r1',
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
    if (failFirstComicLoad && _comicLoads++ == 0) {
      throw StateError('transient source failure');
    }
    return ComicManifest(comic: _comic, chapters: <Chapter>[_chapter]);
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    expect(chapterId, _chapterId);
    return ChapterManifest(
      sourceId: sourceId,
      comicId: _comicId,
      chapter: _chapter,
      pages: <PageAsset>[
        PageAsset(
          pageId: '$sourceId-page-1',
          chapterId: _chapterId,
          index: 0,
          uri: Uri.https('example.invalid', '/$sourceId/page-1.png'),
          contentKindHint: ContentKindHint.png,
        ),
      ],
      readingDirection: ReadingDirection.ltr,
    );
  }

  @override
  Future<Uint8List> loadResource(Uri uri) async => _tinyPng();
}
