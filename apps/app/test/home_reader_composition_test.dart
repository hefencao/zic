import 'dart:async';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/home_reader_composition.dart';
import 'package:zic/source_resource_gateway.dart';

void main() {
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
}) =>
    ImportedLibraryEntry(
      chapter: ImportedChapterRecord(
        directoryId: '$sourceId:comic',
        displayName: 'Chapter',
        sourceId: sourceId,
        comicId: 'comic',
        chapterId: 'chapter',
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
    );

final class _CollectingTraceSink implements TraceSink {
  final List<TraceEvent> events = <TraceEvent>[];

  @override
  void record(TraceEvent event) => events.add(event);
}
