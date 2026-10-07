import 'dart:async';
import 'dart:convert';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_host/plugin_host.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/home_reader_composition.dart';
import 'package:zic/source_resource_gateway.dart';

void main() {
  test('Reader comic projection does not query unrelated source authority', () {
    final current = _entry(
      sourceId: 'reader-focus',
      pageSource: 'memory:page.jpeg',
    );
    final saved = <SavedComicRecord>[
      SavedComicRecord(
        sourceId: 'reader-focus',
        comicId: 'comic',
        title: 'Focused comic',
        chapters: const <SavedChapterRecord>[
          SavedChapterRecord(
            chapterId: 'chapter',
            title: 'Current',
            sequence: 1,
            pageCount: 1,
            sourceRevision: 'r1',
          ),
          SavedChapterRecord(
            chapterId: 'next',
            title: 'Next',
            sequence: 2,
            pageCount: 1,
            sourceRevision: 'r1',
          ),
        ],
      ),
      SavedComicRecord(
        sourceId: 'unrelated-source',
        comicId: 'comic',
        title: 'Unrelated comic',
      ),
    ];
    final queriedSources = <String>[];
    final comic = homeReaderComicForChapter(
      current: current,
      entries: <ImportedLibraryEntry>[current],
      savedComics: saved,
      canonicalIdentity: (sourceId, comicId) {
        queriedSources.add(sourceId);
        return '$sourceId\u0000$comicId';
      },
    );
    expect(comic!.title, 'Focused comic');
    expect(comic.chapters.single, same(current));
    expect(comic.sourceChapters.map((chapter) => chapter.chapterId),
        <String>['chapter', 'next']);
    expect(queriedSources, isNot(contains('unrelated-source')),
        reason: 'Reader adjacency needs only its current source/comic family');
  });

  test('Reader comic projection preserves catalog aliases and entry identity', () {
    final progress = ReadingProgress(
      sourceId: 'reader-focus',
      comicId: 'comic',
      chapterId: 'chapter',
      pageIndex: 0,
      subPageOffset: .5,
      readerMode: ReaderMode.continuous,
      updatedAt: DateTime.utc(2026, 10, 3),
    );
    final current = _entry(
      sourceId: 'reader-focus',
      pageSource: 'memory:page.jpeg',
      progress: progress,
    );
    final second = _entry(
      sourceId: 'reader-focus',
      pageSource: 'memory:second.jpeg',
      chapterId: 'second',
    );
    final saved = <SavedComicRecord>[
      SavedComicRecord(
        sourceId: 'reader-focus',
        comicId: 'comic',
        title: 'Authoritative comic',
        authors: const <String>['Author'],
        tags: const <String>['Tag'],
        description: 'Description',
        chapters: const <SavedChapterRecord>[
          SavedChapterRecord(
            chapterId: 'chapter', title: 'Current', sequence: 1,
            pageCount: 1, sourceRevision: 'r1',
          ),
          SavedChapterRecord(
            chapterId: 'second', title: 'Next', sequence: 2,
            pageCount: 1, sourceRevision: 'r1',
          ),
        ],
      ),
      SavedComicRecord(
        sourceId: 'reader-focus', comicId: 'older-alias', title: 'Weak alias',
      ),
      SavedComicRecord(
        sourceId: 'reader-focus', comicId: 'other-comic', title: 'Unrelated',
      ),
    ];
    String canonical(String sourceId, String comicId) =>
        '$sourceId\u0000${comicId == 'older-alias' ? 'comic' : comicId}';
    final entries = <ImportedLibraryEntry>[current, second];
    final baseline = collapseCanonicalLibraryComics(
      aggregateImportedLibrary(entries, savedComics: saved),
      canonicalIdentity: canonical,
    ).singleWhere((comic) => comic.comicId == 'comic');
    final calls = <String, int>{};
    final projected = homeReaderComicForChapter(
      current: current, entries: entries, savedComics: saved,
      canonicalIdentity: (sourceId, comicId) {
        calls.update(comicId, (count) => count + 1, ifAbsent: () => 1);
        return canonical(sourceId, comicId);
      },
    )!;
    expect(projected.identity, baseline.identity);
    expect(projected.title, baseline.title);
    expect(projected.authors, baseline.authors);
    expect(projected.tags, baseline.tags);
    expect(projected.description, baseline.description);
    expect(projected.chapters, baseline.chapters);
    expect(projected.chapters.firstWhere(
        (entry) => entry.chapter.chapterId == 'chapter'), same(current));
    expect(current.progress, same(progress));
    expect(projected.sourceChapters.map((chapter) => chapter.chapterId),
        baseline.sourceChapters.map((chapter) => chapter.chapterId));
    expect(calls, <String, int>{'comic': 1, 'older-alias': 1, 'other-comic': 1});
  });

  test('Reader comic projection reads fresh authority and catalog per call', () {
    final current = _entry(
      sourceId: 'reader-focus', pageSource: 'memory:page.jpeg',
    );
    final saved = <SavedComicRecord>[
      SavedComicRecord(
        sourceId: 'reader-focus', comicId: 'comic', title: 'Current catalog',
      ),
    ];
    var generation = 0;
    final observed = <int>[];
    LibraryComic project() => homeReaderComicForChapter(
          current: current, entries: <ImportedLibraryEntry>[current],
          savedComics: saved,
          canonicalIdentity: (sourceId, comicId) {
            observed.add(generation);
            return '$sourceId\u0000$generation\u0000$comicId';
          },
        )!;
    expect(project().sourceChapters, isEmpty);
    generation++;
    saved[0] = saved[0].copyWith(chapters: const <SavedChapterRecord>[
      SavedChapterRecord(
        chapterId: 'next', title: 'New next', sequence: 2,
        pageCount: 1, sourceRevision: 'r2',
      ),
    ]);
    expect(project().sourceChapters.single.chapterId, 'next');
    expect(observed, <int>[0, 1]);
  });

  test('adjacent preparation evicts failures so a later retry can succeed',
      () async {
    final cache = <String, Future<String?>>{};
    var attempts = 0;

    Future<String?> prepare() async {
      attempts++;
      if (attempts == 1) throw StateError('transient plugin failure');
      return 'ready';
    }

    await expectLater(
      homeReaderCoalesceSuccessfulAdjacentPreparation(
        cache: cache,
        key: 'next',
        prepare: prepare,
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(cache, isEmpty);

    final retried = await homeReaderCoalesceSuccessfulAdjacentPreparation(
      cache: cache,
      key: 'next',
      prepare: prepare,
    );
    expect(retried, 'ready');
    expect(attempts, 2);
  });

  test('logical chapter order is sequence-ascending independent of source order',
      () {
    final sourceOrder = <({int sequence, String id})>[
      (sequence: 5, id: 'chapter-6'),
      (sequence: 4, id: 'chapter-5'),
      (sequence: 3, id: 'chapter-4'),
      (sequence: 2, id: 'chapter-3'),
      (sequence: 1, id: 'chapter-2'),
      (sequence: 0, id: 'chapter-1'),
    ];

    final logical = homeReaderLogicalChapterOrder(
      sourceOrder,
      sequenceOf: (chapter) => chapter.sequence,
    );

    expect(
      logical.map((chapter) => chapter.id).toList(growable: false),
      <String>[
        'chapter-1',
        'chapter-2',
        'chapter-3',
        'chapter-4',
        'chapter-5',
        'chapter-6',
      ],
    );
  });

  test('logical chapter order preserves source order for equal sequences', () {
    final sourceOrder = <({int sequence, String id})>[
      (sequence: 1, id: 'first'),
      (sequence: 1, id: 'second'),
      (sequence: 0, id: 'earlier'),
    ];

    final logical = homeReaderLogicalChapterOrder(
      sourceOrder,
      sequenceOf: (chapter) => chapter.sequence,
    );

    expect(
      logical.map((chapter) => chapter.id).toList(growable: false),
      <String>['earlier', 'first', 'second'],
    );
  });

  test('logical chapter order projects each source key once per invocation', () {
    final sourceOrder = List<int>.generate(27, (index) => index);
    final reads = List<int>.filled(sourceOrder.length, 0);
    var newestFirst = true;

    List<int> project() => homeReaderLogicalChapterOrder(
          sourceOrder,
          sequenceOf: (chapter) {
            reads[chapter]++;
            return newestFirst ? -chapter : chapter;
          },
        );

    expect(project(), sourceOrder.reversed.toList());
    expect(reads, everyElement(1));
    newestFirst = false;
    expect(project(), sourceOrder);
    expect(reads, everyElement(2));
  });

  test('current Mihon chapter keeps catalog position after host ordinal changes',
      () {
    String id(String url, int ordinal, {String memo = 'same'}) =>
        'mihon:chapter:${base64Url.encode(utf8.encode(jsonEncode({
          'kind': 'chapter', 'comicId': 'host-parent-$ordinal',
          'url': url, 'name': 'source chapter', 'sequence': ordinal,
          'memo': {'request': memo},
        })))}';
    final current = id('/chapter/2', 0);
    final catalog = <String>[
      id('/chapter/1', 2), id('/chapter/2', 1), id('/chapter/3', 0),
    ];
    int indexOf(String value, List<String> chapters) => homeReaderChapterIndex(
          chapters,
          chapterId: value,
          chapterIdOf: (id) => id,
          comparisonKeyOf: mihonChapterModelComparisonKey,
        );
    expect(indexOf(current, catalog), 1);
    expect(catalog[0], id('/chapter/1', 2));
    expect(catalog[2], id('/chapter/3', 0));
    expect(indexOf(id('/chapter/2', 0, memo: 'different'), catalog), -1);
    final ambiguous = <String>[id('/chapter/2', 1), id('/chapter/2', 2)];
    expect(indexOf(current, ambiguous), -1);
    expect(indexOf(ambiguous[1], ambiguous), 1);
    expect(indexOf('mihon:chapter:invalid', catalog), -1);
  });

  test('Mihon chapter traversal keeps direction for persisted and fresh metadata',
      () {
    String chapterId(int sourceOrdinal) => 'mihon:chapter:${base64Url.encode(
          utf8.encode(jsonEncode(<String, Object?>{
            'kind': 'chapter',
            'url': '/chapter/${6 - sourceOrdinal}',
            'sequence': sourceOrdinal,
          })),
        )}';
    for (final legacy in <bool>[true, false]) {
      final catalog = List<({String id, int sequence, int chapterNumber})>.generate(
        6,
        (index) => (
          id: chapterId(index),
          sequence: legacy ? index : 5 - index,
          chapterNumber: 6 - index,
        ),
      );
      final logical = homeReaderLogicalChapterOrder(
        catalog,
        sequenceOf: (chapter) => sourceLogicalChapterOrderKey(
          chapterId: chapter.id,
          sequence: chapter.sequence,
        ),
      );
      final current = logical.indexWhere((chapter) => chapter.chapterNumber == 5);
      expect(logical[current - 1].chapterNumber, 4);
      expect(logical[current + 1].chapterNumber, 6);
      expect(logical.map((chapter) => chapter.chapterNumber), <int>[1, 2, 3, 4, 5, 6]);
      expect(logical[current].id, catalog[1].id);
    }
    expect(
      sourceLogicalChapterOrderKey(chapterId: 'venera:chapter:opaque', sequence: 5),
      5,
    );
    expect(sourceLogicalChapterOrderKey(chapterId: 'mihon:chapter:invalid', sequence: 5), 5);
  });

  test('adjacent preload fills only the residual 7/3 encoded window', () {
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 10,
        rawPageIndex: 4,
        inverted: false,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 0, next: 2, displayedIndex: 4),
    );
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 10,
        rawPageIndex: 8,
        inverted: false,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 0, next: 6, displayedIndex: 8),
    );
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 10,
        rawPageIndex: 0,
        inverted: false,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 3, next: 0, displayedIndex: 0),
    );
  });

  test('adjacent preload residual follows inverted reading order', () {
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 10,
        rawPageIndex: 8,
        inverted: true,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 2, next: 0, displayedIndex: 1),
    );
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 10,
        rawPageIndex: 1,
        inverted: true,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 0, next: 6, displayedIndex: 8),
    );
    expect(
      homeReaderAdjacentPreloadResidual(
        pageCount: 1,
        rawPageIndex: 0,
        inverted: true,
        forwardEncodedPages: 7,
        backwardEncodedPages: 3,
      ),
      (previous: 3, next: 7, displayedIndex: 0),
    );
  });

  test('cold Reader preparation waits for durable service adoption before binding',
      () async {
    final entry = _entry(sourceId: 'local-folder', pageSource: '/page.jpg');
    final services = Completer<void>();
    final order = <String>[];
    var adopted = false;
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () async {
        order.add('services');
        await services.future;
        adopted = true;
      },
      hydrateEntry: (candidate, {required awaitCanonicalPhysicalBackfill}) async {
        order.add('hydrate:$adopted');
        return candidate;
      },
      sourceResources: gateway,
      downloadComposition: () {
        order.add('binding:$adopted');
        return null;
      },
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async =>
          candidate,
      prepareVersionAuthority: (_) async {
        order.add('authority:$adopted');
        return 0;
      },
      trace: const NoopTraceSink(),
      monotonicMicros: () => 1,
    );
    addTearDown(() async {
      if (!services.isCompleted) services.complete();
      await composition.close();
      gateway.close();
    });
    final preparation = composition.prepare(() async {
      order.add('load:$adopted');
      return entry;
    }, refreshRemote: false);
    await Future<void>.delayed(Duration.zero);
    expect(order, <String>['services'],
        reason: 'bootstrap owners must not escape into Reader capabilities');
    var closed = false;
    final closing = composition.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    services.complete();
    final prepared = await preparation;
    await closing;
    expect(prepared.entry, same(entry));
    expect(order, <String>[
      'services', 'load:true', 'hydrate:true', 'authority:true', 'binding:true',
    ]);
  });

  test('failed Reader service handoff does not fall back to bootstrap owners',
      () async {
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    final failure = StateError('durable services unavailable');
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () => Future<void>.error(failure),
      hydrateEntry: (candidate, {required awaitCanonicalPhysicalBackfill}) async =>
          candidate,
      sourceResources: gateway,
      downloadComposition: () => null,
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async =>
          candidate,
      prepareVersionAuthority: (_) async => 0,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 1,
    );
    addTearDown(() async {
      await composition.close();
      gateway.close();
    });
    var loaded = false;
    await expectLater(composition.prepare(() async {
      loaded = true;
      return _entry(sourceId: 'local-folder', pageSource: '/page.jpg');
    }, refreshRemote: false), throwsA(same(failure)));
    expect(loaded, isFalse);
  });

  for (final refreshRequired in <bool>[false, true]) {
    test('chapter edges use the final page table after '
        '${refreshRequired ? 'source refresh' : 'hydration'}', () async {
      final full = _entry(
        sourceId: 'fixture',
        pageSource: 'https://example.invalid/page-1.jpg',
      );
      final resolved = full.copyWith(
        chapter: full.chapter.copyWith(
          pages: <ImportedPageRecord>[
            for (var index = 0; index < 4; index++)
              ImportedPageRecord(
                displayName: 'Page $index',
                sourceId: 'https://example.invalid/page-$index.jpg',
                pageId: 'page-$index',
                contentKindHint: ContentKindHint.jpeg,
              ),
          ],
        ),
      );
      final compact = _entry(
        sourceId: 'fixture',
        pageSource: 'snapshot://fixture/page',
      );
      final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
      addTearDown(gateway.close);
      final composition = HomeReaderChapterComposition(
        ensureDurableServices: () async {},
        hydrateEntry: (candidate,
                {required awaitCanonicalPhysicalBackfill}) async =>
            refreshRequired ? compact : resolved,
        sourceResources: gateway,
        downloadComposition: () => null,
        requiresSourceLocatorRefresh: (chapter) => chapter.pages
            .any((page) => page.sourceId.startsWith('snapshot://')),
        refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async =>
            resolved,
        prepareVersionAuthority: (_) async => 0,
        trace: _CollectingTraceSink(),
        monotonicMicros: () => 1234,
      );
      addTearDown(composition.close);
      for (final edge in HomeReaderChapterEntry.values) {
        final prepared = await composition.prepare(
          () async => compact,
          refreshRemote: false,
          initialChapterEntry: edge,
        );
        expect(prepared.entry.chapter.pages, hasLength(4));
        expect(prepared.initialPageIndex,
            edge == HomeReaderChapterEntry.firstPage ? 0 : 3);
      }
    });
  }

  test('reader composition prepares local chapter without transport authority', () async {
    final entry = _entry(
      sourceId: 'local-folder',
      pageSource: '/library/page-1.jpg',
    );
    var hydrateCalls = 0;
    var refreshCalls = 0;
    var authorityCalls = 0;
    final trace = _CollectingTraceSink();
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    addTearDown(gateway.close);
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () async {},
      hydrateEntry: (candidate, {required awaitCanonicalPhysicalBackfill}) async {
        hydrateCalls++;
        expect(awaitCanonicalPhysicalBackfill, isFalse);
        return candidate;
      },
      sourceResources: gateway,
      downloadComposition: () => null,
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async {
        refreshCalls++;
        return candidate;
      },
      prepareVersionAuthority: (candidate) async {
        authorityCalls++;
        return 0;
      },
      trace: trace,
      monotonicMicros: () => 1234,
    );
    addTearDown(composition.close);

    final prepared = await composition.prepare(
      () async => entry,
      refreshRemote: false,
      initialPageIndex: 0,
    );
    await Future<void>.delayed(Duration.zero);

    expect(prepared.entry, same(entry));
    expect(prepared.byteLoaders, isEmpty);
    expect(prepared.responseSources, isEmpty);
    expect(prepared.initialPageIndex, 0);
    expect(hydrateCalls, 1);
    expect(refreshCalls, 0);
    expect(authorityCalls, 1);
    expect(trace.events, hasLength(1));
    expect(trace.events.single.payload['stage'], 'reader-prepare-complete');
    expect(trace.events.single.monotonicMicros, 1234);
  });

  test('reader composition forces source refresh before projecting remote response', () async {
    final stale = _entry(
      sourceId: 'fixture-source',
      pageSource: 'snapshot://placeholder',
    );
    final refreshed = _entry(
      sourceId: 'fixture-source',
      pageSource: 'https://example.invalid/page-1.jpg',
    );
    var forcedRefresh = false;
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    addTearDown(gateway.close);
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () async {},
      hydrateEntry: (candidate, {required awaitCanonicalPhysicalBackfill}) async =>
          candidate,
      sourceResources: gateway,
      downloadComposition: () => null,
      requiresSourceLocatorRefresh: (chapter) =>
          chapter.pages.any((page) => page.sourceId.startsWith('snapshot://')),
      refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async {
        forcedRefresh = forceSourceRefresh;
        return refreshed;
      },
      prepareVersionAuthority: (_) async => 2,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 1,
    );
    addTearDown(composition.close);

    final prepared = await composition.prepare(
      () async => stale,
      refreshRemote: false,
    );

    expect(forcedRefresh, isTrue);
    expect(prepared.entry, same(refreshed));
    expect(prepared.byteLoaders, isEmpty);
    expect(prepared.responseSources.keys, <String>[
      'https://example.invalid/page-1.jpg',
    ]);
  });

  test('reader composition close drains admitted preparation and fences new work',
      () async {
    final entry = _entry(
      sourceId: 'local-folder',
      pageSource: '/library/page-1.jpg',
    );
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<void>();
    final gateway = ComicSourceResourceGateway(sourceForId: (_) => null);
    final composition = HomeReaderChapterComposition(
      ensureDurableServices: () async {},
      hydrateEntry: (candidate, {required awaitCanonicalPhysicalBackfill}) async =>
          candidate,
      sourceResources: gateway,
      downloadComposition: () => null,
      requiresSourceLocatorRefresh: (_) => false,
      refreshRemoteEntry: (candidate, {required forceSourceRefresh}) async =>
          candidate,
      prepareVersionAuthority: (_) async => 0,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 1,
    );
    addTearDown(() async {
      if (!releaseLoad.isCompleted) releaseLoad.complete();
      await composition.close();
      gateway.close();
    });

    final preparation = composition.prepare(
      () async {
        loadStarted.complete();
        await releaseLoad.future;
        return entry;
      },
      refreshRemote: false,
    );
    await loadStarted.future;

    var closeCompleted = false;
    final closing = composition.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);

    releaseLoad.complete();
    await preparation;
    await closing;
    expect(closeCompleted, isTrue);

    await expectLater(
      composition.prepare(
        () async => entry,
        refreshRemote: false,
      ),
      throwsA(isA<StateError>()),
    );
  });
}

ImportedLibraryEntry _entry({
  required String sourceId,
  required String pageSource,
  String comicId = 'comic',
  String chapterId = 'chapter',
  ReadingProgress? progress,
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: '$sourceId:$comicId',
        displayName: 'Chapter',
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
        sourceRevision: 'r1',
        pages: <ImportedPageRecord>[
          ImportedPageRecord(
            displayName: 'Page 1',
            sourceId: pageSource,
            contentKindHint: ContentKindHint.jpeg,
            pageId: 'page-1',
          ),
        ],
      ),
      progress: progress,
    );

final class _CollectingTraceSink implements TraceSink {
  final List<TraceEvent> events = <TraceEvent>[];

  @override
  void record(TraceEvent event) => events.add(event);
}
