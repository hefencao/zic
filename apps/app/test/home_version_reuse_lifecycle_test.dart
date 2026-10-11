import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:zic/home_library_session.dart';
import 'package:zic/home_shell.dart';
import 'package:zic/home_version_reuse_lifecycle.dart';

void main() {
  test('source-declared predecessors complete version history without media changes',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = _lifecycle(session);
    addTearDown(() async {
      await lifecycle.close();
      await session.close();
      session.dispose();
    });
    await session.ready;
    final existing = ComicVersionRelation(
      sourceId: 'fixture',
      predecessorComicId: 'old-comic',
      successorComicId: 'new-comic',
      predecessorTitle: 'Old comic',
      discoveredAt: DateTime.utc(2026, 1, 1),
      pageMappings: <ComicVersionPageMapping>[
        ComicVersionPageMapping(
          predecessorChapterId: 'old-chapter',
          successorChapterId: 'new-chapter',
          predecessorPageCount: 1,
          successorPageCount: 1,
          successorOffset: 0,
          predecessorSourceRevision: 'old-r1',
          successorSourceRevision: 'new-r1',
          verifiedPredecessorPageIndexes: const <int>[0],
          verifiedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    await session.upsertVersionRelation(existing);
    await session.upsertVersionRelation(ComicVersionRelation(
      sourceId: 'fixture',
      predecessorComicId: 'old-comic',
      successorComicId: 'middle-comic',
      predecessorTitle: 'Old comic',
      discoveredAt: DateTime.utc(2026, 1, 1),
    ));
    expect(session.versionBaselines.latestKnownHeadFor('fixture', 'old-comic'),
        isNull, reason: 'An incomplete fork must not guess a latest head');
    final source = _DeclaredVersionSource(const <SourceComicVersion>[
      SourceComicVersion(sourceId: 'fixture', comicId: 'old-comic',
          title: 'Old comic', generation: 1, isPredecessor: true),
      SourceComicVersion(sourceId: 'fixture', comicId: 'middle-comic',
          title: 'Middle comic', generation: 2, isPredecessor: true),
      SourceComicVersion(sourceId: 'foreign', comicId: 'foreign-comic',
          title: 'Foreign comic', generation: 3, isPredecessor: true),
      SourceComicVersion(sourceId: 'fixture', comicId: 'new-comic',
          title: 'Self', generation: 4, isPredecessor: true),
      SourceComicVersion(sourceId: 'fixture', comicId: '',
          title: 'Empty identity', generation: 5, isPredecessor: true),
    ]);

    final state = await lifecycle.loadVersionState(source, 'Newest', 'new-comic');
    await state.backgroundRefresh;
    final predecessors =
        await library.listComicVersionPredecessors('fixture', 'new-comic');
    expect(predecessors.map((item) => item.predecessorComicId),
        unorderedEquals(<String>['old-comic', 'middle-comic']));
    expect(session.versionBaselines.latestKnownHeadFor('fixture', 'old-comic'),
        'new-comic');
    final preserved = predecessors.singleWhere((item) =>
        item.predecessorComicId == 'old-comic');
    expect(preserved.discoveredAt, existing.discoveredAt);
    expect(preserved.predecessorTitle, existing.predecessorTitle);
    expect(preserved.pageMappings.map((item) => item.toJson()).toList(),
        existing.pageMappings.map((item) => item.toJson()).toList(),
        reason: 'Discovery preserves the original media proof');
    expect((await library.listAllComicVersionRelations()).length, 3,
        reason: 'Foreign, self and empty identities cannot establish edges');
    expect(session.entries, isEmpty,
        reason: 'Version history is independent of chapter/page authority');

    source.offline = true;
    final offline = await lifecycle.loadVersionState(source, 'Newest', 'new-comic');
    expect(offline.predecessors.map((item) => item.comicId),
        unorderedEquals(<String>['old-comic', 'middle-comic']));
    final fallback = await offline.backgroundRefresh!;
    expect(fallback.predecessors.map((item) => item.comicId),
        unorderedEquals(<String>['old-comic', 'middle-comic']));
  });

  for (final cancel in <bool>[false, true]) {
    test('large version discovery permits events and cancellation ($cancel)',
        () async {
      final library = MemoryImportedLibraryStore();
      final downloads = MemoryChapterDownloadService(
        pageLoader: (_, _) async => Uint8List(1),
      );
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: library,
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: true,
        ownsWholeComicDownloads: true,
      );
      final lifecycle = _lifecycle(session);
      addTearDown(() async {
        await lifecycle.close();
        await session.close();
        session.dispose();
      });
      await session.ready;
      final versions = List<SourceComicVersion>.generate(512, (index) =>
          SourceComicVersion(
            sourceId: 'fixture', comicId: 'old-$index',
            title: 'Old $index', generation: index, isPredecessor: true,
          ));
      final source = _DeclaredVersionSource(versions);
      final control = _TestTaskControl();
      final eventTurn = Completer<void>();
      var persistedAtEvent = -1;
      source.onFind = () => Timer.run(() {
        persistedAtEvent = session.versionRelations.length;
        if (cancel) control.cancel();
        eventTurn.complete();
      });
      HomeVersionState? state;
      Object? failure;
      try {
        state = await lifecycle.loadVersionState(
          source, 'Newest', 'new-comic', control: control,
        );
      } on Object catch (error) {
        failure = error;
      }
      await eventTurn.future;
      expect(persistedAtEvent, lessThan(versions.length),
          reason: 'Source discovery must not starve queued UI/cancel events');
      final persisted = await library.listAllComicVersionRelations();
      if (cancel) {
        expect(failure, isA<Failure>().having(
            (error) => error.code, 'code', ErrorCode.cancelled));
        expect(persisted.length, persistedAtEvent,
            reason: 'Cancellation stops further commits, not completed writes');
      } else {
        expect(failure, isNull);
        expect(state!.predecessors.length, versions.length);
        expect(persisted.map((item) => item.predecessorComicId),
            unorderedEquals(versions.map((item) => item.comicId)));
      }
    });
  }

  for (final scenario in <({bool needsRefresh, bool cancelOnHydrate})>[
    (needsRefresh: false, cancelOnHydrate: false),
    (needsRefresh: true, cancelOnHydrate: false),
    (needsRefresh: true, cancelOnHydrate: true),
  ]) {
    final needsRefresh = scenario.needsRefresh;
    test(
        'version warmup hydrates compact chapter before locator check '
        '(legacy locator: $needsRefresh, '
        'cancel on hydrate: ${scenario.cancelOnHydrate})', () async {
      final library = _BlockingVersionRelationStore(compactEntries: true);
      await library.open();
      final focus = _entry();
      final target = _entry(
        comicId: 'new-comic',
        chapterId: 'new-chapter',
        pageId: 'new-page',
        pageUri: needsRefresh
            ? 'venera-resource://expired-runtime/page'
            : 'https://example.invalid/page.webp',
      );
      final freshTarget = _entry(
        comicId: 'new-comic',
        chapterId: 'new-chapter',
        pageId: 'new-page',
      );
      final progress = ReadingProgress(
        sourceId: 'fixture',
        comicId: 'new-comic',
        chapterId: 'new-chapter',
        pageIndex: 0,
        subPageOffset: 0.4,
        readerMode: ReaderMode.continuous,
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      await library._inner.upsertChapter(focus.chapter);
      await library._inner.upsertChapter(target.chapter);
      await library._inner.saveProgress(progress);
      await library.saveComicVersionRelation(
        ComicVersionRelation(
          sourceId: 'fixture',
          predecessorComicId: 'old-comic',
          successorComicId: 'new-comic',
          predecessorTitle: 'Old comic',
        ),
      );
      final downloads = MemoryChapterDownloadService(
        pageLoader: (_, _) async => Uint8List(1),
      );
      final queue = WholeComicDownloadQueue(downloads: downloads);
      final session = HomeLibrarySession(
        library: library,
        chapterDownloads: downloads,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: true,
        ownsWholeComicDownloads: true,
      );
      final lifecycle = _lifecycle(
        session,
        requiresSourceLocatorRefresh: chapterRequiresSourceLocatorRefresh,
      );
      addTearDown(() async {
        await lifecycle.close();
        await session.close();
        session.dispose();
      });
      await session.ready;
      expect(session.error, isNull);
      expect(
        session.entries.every((entry) =>
            chapterHasHomeProjectionSnapshotPagePlaceholders(entry.chapter)),
        isTrue,
      );
      final source = _ChapterVersionSource(freshTarget);
      final control = _TestTaskControl();
      if (scenario.cancelOnHydrate) {
        library.onGet = (_, chapterId) {
          if (chapterId == 'new-chapter') control.cancel();
        };
      }

      final warming = lifecycle.prepareWarmup(
        source,
        focus,
        targetComicId: 'new-comic',
        control: scenario.cancelOnHydrate ? control : null,
      );
      if (scenario.cancelOnHydrate) {
        await expectLater(
          warming,
          throwsA(isA<Failure>().having(
            (error) => error.code, 'code', ErrorCode.cancelled)),
        );
      } else {
        await warming;
      }

      expect(source.comicLoads, 1);
      expect(source.chapterLoads,
          needsRefresh && !scenario.cancelOnHydrate ? 1 : 0);
      final persisted = await library._inner.get('fixture', 'new-chapter');
      expect(persisted!.progress!.toJson(), progress.toJson());
      if (needsRefresh && !scenario.cancelOnHydrate) {
        expect(persisted.chapter.pages.single.sourceId,
            freshTarget.chapter.pages.single.sourceId);
        expect(persisted.chapter.importedAt, isNot(target.chapter.importedAt));
      } else {
        expect(persisted.chapter.toJson(), target.chapter.toJson());
      }
    });
  }

  for (final scenario in <({bool compact, bool cancelOnHydrate,
      bool missingFocus})>[
    (compact: true, cancelOnHydrate: false, missingFocus: false),
    (compact: true, cancelOnHydrate: true, missingFocus: false),
    (compact: true, cancelOnHydrate: false, missingFocus: true),
    (compact: false, cancelOnHydrate: false, missingFocus: false),
  ]) {
    test('version proof consumes actual focus before source work '
        '(compact: ${scenario.compact}, cancel: ${scenario.cancelOnHydrate}, '
        'missing: ${scenario.missingFocus})', () async {
      final root = await Directory.systemTemp.createTemp('version-proof-focus-');
      final composition = await PersistentDownloadComposition.open(
        root.path,
        transferNet: DownloadResourceCoordinator().networkLane,
      );
      final library = _BlockingVersionRelationStore(compactEntries: true);
      await library.open();
      final old = _entry(pageUri: 'https://example.invalid/old.webp');
      final target = _entry(comicId: 'new-comic', chapterId: 'new-chapter',
          pageId: 'new-page', pageUri: 'https://example.invalid/new.webp');
      await library.upsertChapter(old.chapter);
      await library.upsertChapter(target.chapter);
      await library.saveComicVersionRelation(ComicVersionRelation(
        sourceId: 'fixture', predecessorComicId: 'old-comic',
        successorComicId: 'new-comic',
      ));
      final queue = WholeComicDownloadQueue(
        downloads: composition.chapterDownloads,
      );
      final session = HomeLibrarySession(
        library: library,
        chapterDownloads: composition.chapterDownloads,
        downloadComposition: composition,
        wholeComicDownloads: queue,
        sources: const <BrowsableComicSource>[],
        ownsLibrary: true,
        ownsChapterDownloads: false,
        ownsWholeComicDownloads: true,
      );
      final probes = <Uri>[];
      final trace = MemoryTraceSink();
      final lifecycle = _lifecycle(session, trace: trace,
          verifiedPageReuseIdentity: ({required sourceId, required locator,
            control}) async {
        control?.throwIfCancelled();
        probes.add(locator);
        if (locator.scheme != 'https') {
          throw const Failure(code: ErrorCode.invalidState,
              message: 'A compact Home page cannot prove media identity');
        }
        return 'same-verified-body';
      });
      addTearDown(() async {
        await lifecycle.close();
        await session.close();
        session.dispose();
        await composition.close();
        await root.delete(recursive: true);
      });
      await session.ready;
      final compactFocus = session.entries.singleWhere(
        (entry) => entry.chapter.comicId == 'old-comic',
      );
      if (!scenario.compact) await session.hydrateEntry(compactFocus);
      final focus = scenario.compact ? compactFocus :
          _entry(pageUri: 'https://example.invalid/refreshed-old.webp');
      expect(chapterHasHomeProjectionSnapshotPagePlaceholders(focus.chapter),
          scenario.compact);
      final manifest = old.chapter.toManifest();
      final physical = composition.transferRuntime.sessionFor(
        readerPageDownloadId(manifest, manifest.pages.single),
      );
      await physical.restore();
      final writer = physical.acquireWriter();
      await physical.append(writer, 0, <int>[1]);
      await physical.pause(writer);
      final epoch = physical.epoch;
      final control = _TestTaskControl();
      if (scenario.cancelOnHydrate) {
        library.onGet = (_, chapterId) {
          if (chapterId == old.chapter.chapterId) control.cancel();
        };
      }
      if (scenario.missingFocus) {
        await library._inner.removeChapter('fixture', old.chapter.chapterId);
      }
      final source = _ChapterVersionSource(target);
      final warming = lifecycle.prepareWarmup(source, focus,
          targetComicId: 'new-comic', control: control);
      if (scenario.cancelOnHydrate) {
        await expectLater(warming, throwsA(isA<Failure>().having(
          (error) => error.code, 'code', ErrorCode.cancelled)));
      } else {
        await warming;
      }
      final stopped = scenario.cancelOnHydrate || scenario.missingFocus;
      expect(source.comicLoads, stopped ? 0 : 1);
      expect(source.chapterLoads, 0);
      expect(probes, stopped ? isEmpty : unorderedEquals(<Uri>[
        scenario.compact ? manifest.pages.single.uri :
            focus.chapter.toManifest().pages.single.uri,
        target.chapter.toManifest().pages.single.uri,
      ]));
      final relations = await library.listAllComicVersionRelations();
      expect(relations.single.pageMappings.length, stopped ? 0 : 1);
      if (!stopped) {
        expect(relations.single.pageMappings.single.effectiveVerifiedIntervals
            .single.length, 1);
      }
      expect(trace.events.where((event) =>
          event.payload['stage'] == 'version-page-mapping-warm-failed'), isEmpty);
      expect(physical.epoch, epoch);
      expect(physical.committedLength, 1);
    });
  }

  test('in-flight relation read retries after library generation adoption',
      () async {
    final firstLibrary = _BlockingVersionRelationStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = _lifecycle(session);
    await session.ready;
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'stale-successor',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final secondLibrary = MemoryImportedLibraryStore();
    await secondLibrary.open();
    await secondLibrary.saveComicVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'current-successor',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 2),
      ),
    );
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      if (!firstLibrary.releaseSuccessorRead.isCompleted) {
        firstLibrary.releaseSuccessorRead.complete();
      }
      await lifecycle.close();
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });

    final stateFuture = lifecycle.loadVersionState(
      _VersionSource(),
      'Old comic',
      'old-comic',
    );
    await firstLibrary.successorReadStarted.future;

    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    firstLibrary.releaseSuccessorRead.complete();

    final state = await stateFuture;
    expect(
      state.successors.map((item) => item.comicId),
      contains('current-successor'),
    );
    expect(
      state.successors.map((item) => item.comicId),
      isNot(contains('stale-successor')),
    );
    await state.backgroundRefresh;
  });

  test('version lifecycle follows the session library generation', () async {
    final firstLibrary = MemoryImportedLibraryStore();
    final firstDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final firstQueue = WholeComicDownloadQueue(downloads: firstDownloads);
    final session = HomeLibrarySession(
      library: firstLibrary,
      chapterDownloads: firstDownloads,
      wholeComicDownloads: firstQueue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = HomeVersionReuseLifecycle(
      session: session,
      loadRemoteEntrySnapshot: (entry, {control}) async => entry,
      verifiedPageReuseIdentity: ({
        required sourceId,
        required locator,
        control,
      }) async =>
          null,
      requiresSourceLocatorRefresh: (_) => false,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) =>
          false,
      cancelQueuedMetadataTask: (_) => false,
      cancelMetadataTask: (_) => false,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 0,
    );
    await session.ready;

    final secondLibrary = MemoryImportedLibraryStore();
    final secondDownloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final secondQueue = WholeComicDownloadQueue(downloads: secondDownloads);
    addTearDown(() async {
      await lifecycle.close();
      await session.close();
      session.dispose();
      await secondQueue.close();
      await secondDownloads.close();
      await secondLibrary.close();
    });
    await session.adoptServices(
      library: secondLibrary,
      chapterDownloads: secondDownloads,
      wholeComicDownloads: secondQueue,
      sources: const <BrowsableComicSource>[],
      persistSnapshot: false,
    );
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'new-comic',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 1),
      ),
    );

    final state = await lifecycle.loadVersionState(
      _VersionSource(),
      'Old comic',
      'old-comic',
    );

    expect(state.successors.map((item) => item.comicId), contains('new-comic'));
    expect(state.predecessors, isEmpty);
    await state.backgroundRefresh;
  });

  test(
      'version-view preparation is lifecycle-owned until route release',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = _lifecycle(session);
    await session.ready;
    await session.upsertChapter(_entry().chapter);
    addTearDown(() async {
      await lifecycle.close();
      await session.close();
      session.dispose();
    });

    final source = _VersionSource();
    final first = lifecycle.startViewPreparation(
      source,
      'old-comic',
      'new-comic',
    );
    final joined = lifecycle.startViewPreparation(
      source,
      'different-origin',
      'new-comic',
    );
    final target = _entry(
      comicId: 'new-comic',
      chapterId: 'new-chapter',
      pageId: 'new-page',
    );

    expect(identical(joined, first), isTrue);
    expect(first.originComicId, 'old-comic');
    expect(identical(lifecycle.viewPreparationFor(target), first), isTrue);
    await first.future;
    expect(identical(lifecycle.viewPreparationFor(target), first), isTrue);

    expect(
      lifecycle.finishViewPreparation('fixture', 'new-comic', first),
      isTrue,
    );
    expect(lifecycle.viewPreparationFor(target), isNull);
    expect(
      lifecycle.finishViewPreparation('fixture', 'new-comic', first),
      isFalse,
    );
  });

  test('close cancels queued Reader metadata refresh before it can start',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    String? scheduledKey;
    String? cancelledKey;
    final lifecycle = HomeVersionReuseLifecycle(
      session: session,
      loadRemoteEntrySnapshot: (entry, {control}) async => entry,
      verifiedPageReuseIdentity: ({
        required sourceId,
        required locator,
        control,
      }) async =>
          null,
      requiresSourceLocatorRefresh: (_) => false,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) {
        scheduledKey = key;
        return true;
      },
      cancelQueuedMetadataTask: (key) {
        cancelledKey = key;
        return true;
      },
      cancelMetadataTask: (_) => false,
      trace: const NoopTraceSink(),
      monotonicMicros: () => 0,
    );
    await session.ready;
    addTearDown(() async {
      await lifecycle.close();
      await session.close();
      session.dispose();
    });

    lifecycle.scheduleReaderMetadataVersionRefresh(
      _VersionSource(),
      _entry(),
    );
    expect(scheduledKey, isNotNull);

    await lifecycle.close();

    expect(cancelledKey, scheduledKey);
  });

  test('close waits for version-state background refresh already admitted',
      () async {
    final library = MemoryImportedLibraryStore();
    final downloads = MemoryChapterDownloadService(
      pageLoader: (_, _) async => Uint8List(1),
    );
    final queue = WholeComicDownloadQueue(downloads: downloads);
    final session = HomeLibrarySession(
      library: library,
      chapterDownloads: downloads,
      wholeComicDownloads: queue,
      sources: const <BrowsableComicSource>[],
      ownsLibrary: true,
      ownsChapterDownloads: true,
      ownsWholeComicDownloads: true,
    );
    final lifecycle = _lifecycle(session);
    await session.ready;
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'old-comic',
        successorComicId: 'stored-successor',
        predecessorTitle: 'Old comic',
        discoveredAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await session.upsertVersionRelation(
      ComicVersionRelation(
        sourceId: 'fixture',
        predecessorComicId: 'stored-predecessor',
        successorComicId: 'old-comic',
        predecessorTitle: 'Earlier comic',
        discoveredAt: DateTime.utc(2025, 12, 1),
      ),
    );
    final source = _BlockingVersionSource();
    addTearDown(() async {
      if (!source.releaseFind.isCompleted) {
        source.releaseFind.complete();
      }
      await lifecycle.close();
      await session.close();
      session.dispose();
    });

    final state = await lifecycle.loadVersionState(
      source,
      'Old comic',
      'old-comic',
    );
    expect(state.backgroundRefresh, isNotNull);
    expect(state.successors.single.date, isNull,
        reason: 'relation discovery time is not a source version update date');
    expect(state.predecessors.single.date, isNull,
        reason: 'predecessor discovery time is not a source version update date');
    await source.findStarted.future;

    var closeCompleted = false;
    final closing = lifecycle.close().then((_) => closeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);

    source.releaseFind.complete();
    await closing;
    expect(closeCompleted, isTrue);
  });
}

HomeVersionReuseLifecycle _lifecycle(
  HomeLibrarySession session, {
  bool Function(ImportedChapterRecord)? requiresSourceLocatorRefresh,
  HomeVersionVerifiedPageIdentityResolver? verifiedPageReuseIdentity,
  TraceSink? trace,
}) =>
    HomeVersionReuseLifecycle(
      session: session,
      loadRemoteEntrySnapshot: (entry, {control}) async => entry,
      verifiedPageReuseIdentity: verifiedPageReuseIdentity ?? ({
        required sourceId,
        required locator,
        control,
      }) async =>
          null,
      requiresSourceLocatorRefresh:
          requiresSourceLocatorRefresh ?? (_) => false,
      scheduleMetadataTask: ({
        required key,
        required priority,
        required task,
      }) =>
          false,
      cancelQueuedMetadataTask: (_) => false,
      cancelMetadataTask: (_) => false,
      trace: trace ?? const NoopTraceSink(),
      monotonicMicros: () => 0,
    );

ImportedLibraryEntry _entry({
  String comicId = 'old-comic',
  String chapterId = 'fixture-chapter',
  String pageId = 'fixture-page',
  String pageUri = 'https://example.invalid/page.webp',
}) {
  const sourceId = 'fixture';
  final comic = Comic(
    comicId: comicId,
    sourceId: sourceId,
    title: 'Old comic',
    authors: const <String>[],
    readingDirection: ReadingDirection.ltr,
  );
  final chapter = Chapter(
    chapterId: chapterId,
    comicId: comicId,
    title: 'Fixture chapter',
    sequence: 1,
    pageCount: 1,
    sourceRevision: 'r1',
  );
  return ImportedLibraryEntry(
    chapter: ImportedChapterRecord.remote(
      comic: comic,
      manifest: ChapterManifest(
        sourceId: sourceId,
        comicId: comicId,
        chapter: chapter,
        readingDirection: ReadingDirection.ltr,
        pages: <PageAsset>[
          PageAsset(
            pageId: pageId,
            chapterId: chapterId,
            index: 0,
            uri: Uri.parse(pageUri),
            contentKindHint: ContentKindHint.webp,
          ),
        ],
      ),
    ),
  );
}

final class _BlockingVersionRelationStore
    implements ImportedLibraryStore, ComicVersionRelationStore {
  _BlockingVersionRelationStore({this.compactEntries = false});

  final bool compactEntries;
  void Function(String sourceId, String chapterId)? onGet;
  final MemoryImportedLibraryStore _inner = MemoryImportedLibraryStore();
  final Completer<void> successorReadStarted = Completer<void>();
  final Completer<void> releaseSuccessorRead = Completer<void>();

  @override
  Future<void> open() => _inner.open();

  @override
  Future<List<ImportedLibraryEntry>> list() async {
    final entries = await _inner.list();
    if (!compactEntries) return entries;
    return HomeProjectionSnapshot.fromJson(
      HomeProjectionSnapshot(
        entries: entries,
        savedComics: const <SavedComicRecord>[],
        categories: const <LibraryCategory>[],
        preferences: const <ComicPreference>[],
        readStates: const <ChapterReadState>[],
        sourcePreferences: const <ComicSourcePreference>[],
        versionRelations: const <ComicVersionRelation>[],
      ).toJson(),
    ).entries;
  }

  @override
  Future<ImportedLibraryEntry?> get(String sourceId, String chapterId) {
    onGet?.call(sourceId, chapterId);
    return _inner.get(sourceId, chapterId);
  }

  @override
  Future<void> upsertChapter(ImportedChapterRecord chapter) =>
      _inner.upsertChapter(chapter);

  @override
  Future<List<SavedComicRecord>> listSavedComics() => _inner.listSavedComics();

  @override
  Future<List<LibraryCategory>> listCategories() => _inner.listCategories();

  @override
  Future<List<ComicPreference>> listComicPreferences() =>
      _inner.listComicPreferences();

  @override
  Future<void> saveComicPreference(ComicPreference preference) =>
      _inner.saveComicPreference(preference);

  @override
  Future<List<ComicSourcePreference>> listSourcePreferences() =>
      _inner.listSourcePreferences();

  @override
  Future<List<ChapterReadState>> listAllChapterReadStates() =>
      _inner.listAllChapterReadStates();

  @override
  Future<List<ComicVersionRelation>> listAllComicVersionRelations() =>
      _inner.listAllComicVersionRelations();

  @override
  Future<List<ComicVersionRelation>> listComicVersionPredecessors(
    String sourceId,
    String successorComicId,
  ) =>
      _inner.listComicVersionPredecessors(sourceId, successorComicId);

  @override
  Future<List<ComicVersionRelation>> listComicVersionSuccessors(
    String sourceId,
    String predecessorComicId,
  ) async {
    final result = await _inner.listComicVersionSuccessors(
      sourceId,
      predecessorComicId,
    );
    if (!successorReadStarted.isCompleted) {
      successorReadStarted.complete();
    }
    await releaseSuccessorRead.future;
    return result;
  }

  @override
  Future<void> saveComicVersionRelation(ComicVersionRelation relation) =>
      _inner.saveComicVersionRelation(relation);

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VersionSource implements BrowsableComicSource, ComicVersionSource {
  @override
  String get sourceId => 'fixture';

  @override
  ComicSourceDescriptor get descriptor => ComicSourceDescriptor(
        sourceId: sourceId,
        name: 'Fixture',
        language: 'en',
        website: Uri.parse('https://example.invalid'),
      );

  @override
  bool get supportsComicVersions => true;

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async =>
      const <SourceComicVersion>[];

  @override
  Future<SourceBrowsePage> browse({
    String query = '',
    int offset = 0,
    int limit = 24,
  }) async =>
      SourceBrowsePage(
        items: const <SourceComicSummary>[],
        offset: offset,
        hasMore: false,
      );

  @override
  Future<ComicManifest> loadComic(String comicId) =>
      throw StateError('not used by this fixture');

  @override
  Future<ChapterManifest> loadChapter(String chapterId) =>
      throw StateError('not used by this fixture');

  @override
  Future<Uint8List> loadResource(Uri uri) =>
      throw StateError('not used by this fixture');
}

final class _DeclaredVersionSource extends _VersionSource {
  _DeclaredVersionSource(this.versions);

  final List<SourceComicVersion> versions;
  bool offline = false;
  void Function()? onFind;

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    expect(comicId, 'new-comic');
    if (offline) throw StateError('source is offline');
    onFind?.call();
    return versions;
  }
}

final class _TestTaskControl implements TaskControl {
  final Completer<void> _cancellation = Completer<void>();

  void cancel() => _cancellation.complete();

  @override
  bool get cancelled => _cancellation.isCompleted;

  @override
  Future<void> get whenCancelled => _cancellation.future;

  @override
  int get priority => 1;
}

final class _ChapterVersionSource extends _VersionSource {
  _ChapterVersionSource(this.target);

  final ImportedLibraryEntry target;
  int comicLoads = 0;
  int chapterLoads = 0;

  @override
  Future<ComicManifest> loadComic(String comicId) async {
    comicLoads++;
    expect(comicId, target.chapter.comicId);
    return ComicManifest(
      comic: Comic(
        comicId: target.chapter.comicId,
        sourceId: target.chapter.sourceId,
        title: target.chapter.comicTitle,
        authors: target.chapter.comicAuthors,
        readingDirection: target.chapter.readingDirection,
      ),
      chapters: <Chapter>[target.chapter.toManifest().chapter],
    );
  }

  @override
  Future<ChapterManifest> loadChapter(String chapterId) async {
    chapterLoads++;
    expect(chapterId, target.chapter.chapterId);
    return target.chapter.toManifest();
  }
}

final class _BlockingVersionSource extends _VersionSource {
  final Completer<void> findStarted = Completer<void>();
  final Completer<void> releaseFind = Completer<void>();

  @override
  Future<List<SourceComicVersion>> findComicVersions(String comicId) async {
    if (!findStarted.isCompleted) findStarted.complete();
    await releaseFind.future;
    return const <SourceComicVersion>[];
  }
}
