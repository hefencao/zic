import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

ImportedLibraryEntry _entry(String comic, List<String> uris) => ImportedLibraryEntry(
  chapter: ImportedChapterRecord(directoryId: 'venera:$comic', displayName: 'Chapter',
    comicTitle: comic, sourceId: 'venera:test', comicId: comic,
    chapterId: 'chapter', sourceRevision: 'r1', pages: [
      for (var i = 0; i < uris.length; i++) ImportedPageRecord(displayName: '$i.webp',
        sourceId: uris[i], pageId: '$comic-$i', contentKindHint: ContentKindHint.webp),
    ]),
);

Future<void> _waitForCacheAdoption(PersistentChapterDownloadService service) async {
  for (var i = 0; i < 200; i++) {
    if (service.activeDownloadEntries.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('local cache adoption did not exit');
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('scoped-candidates-'));
  tearDown(() async => root.delete(recursive: true));
  final bytes = Uint8List.fromList('RIFF....WEBPscoped-candidate'.codeUnits);

  test('targeted inspection and download retain unpinned cross-comic strong identity', () async {
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace);
    addTearDown(service.close);
    final old = _entry('old', ['https://example.test/s/image-key/old']);
    final target = _entry('new', ['https://example.test/s/image-key/new']);
    final oldId = readerPageDownloadId(old.chapter.toManifest(), old.chapter.toManifest().pages.single);
    await service.storePromotedArtifact(id: oldId, bytes: bytes);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
    // Full inventory/repair may still read these rows. Targeted commands must
    // neither parse unrelated damaged metadata nor depend on its comic ID.
    final path = (service.artifactStore.index as SqliteIndex).path!;
    final db = sql.sqlite3.open(path);
    try {
      for (var i = 0; i < 200; i++) {
        db.execute('INSERT INTO cache_entry '
          '(key, download_json, state, path, bytes, checksum, created_us, touched_us, source_id, comic_id, chapter_id) '
          "VALUES (?, '{}', 'ready', ?, 1, 'unused', 1, 1, 'unrelated', 'unrelated', 'chapter')",
          ['unrelated-$i', '/unrelated/$i']);
      }
    } finally {
      db.close();
    }
    expect(await service.readyPageIndices(target), {0});
    final inspected = (await service.inspectMany([target])).single;
    expect(inspected.reusablePages, 1);
    expect(inspected.exactCompletedPages, 0);
    final projection = trace.events.lastWhere((event) =>
      event.payload['stage'] == 'targeted-projection-built');
    expect(projection.payload['indexedRecords'], 1);
    expect(projection.payload['physicalArtifacts'], lessThanOrEqualTo(1));
    expect(projection.payload['canonicalProjections'], 0);
    var network = 0;
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
      network++;
      return bytes;
    }));
    await service.download(target);
    expect(network, 0);
    expect(await service.readPage(target, 0), bytes);
    expect((await service.inspect(target)).pinnedPages, 1);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
  });

  test('scoped opaque candidates retain proof gaps and relation revocation', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final old = _entry('old', [for (var i = 0; i < 3; i++) 'venera-resource:old-$i']);
    final target = _entry('new', [for (var i = 0; i < 3; i++) 'venera-resource:new-$i']);
    final manifest = old.chapter.toManifest();
    for (final page in manifest.pages) {
      await service.storePromotedArtifact(id: readerPageDownloadId(manifest, page), bytes: bytes);
    }
    await service.artifactStore.index.putExportPageBindings([
      for (var i = 0; i < 3; i++) ExportPageBinding(sourceId: 'venera:test',
        comicId: 'old', chapterId: 'chapter', pageId: 'old-$i', logicalIndex: i,
        exportOrdinal: i + 1),
    ]);
    const relation = ComicVersionRelation(sourceId: 'venera:test',
      predecessorComicId: 'old', successorComicId: 'new', pageMappings: [
        ComicVersionPageMapping(predecessorChapterId: 'chapter',
          successorChapterId: 'chapter', predecessorPageCount: 3,
          successorPageCount: 3, successorOffset: 0,
          predecessorSourceRevision: 'r1', successorSourceRevision: 'r1',
          verifiedIntervals: [
            VerifiedComicVersionPageInterval(predecessorStart: 0,
              predecessorEndExclusive: 1, successorOffset: 0),
            VerifiedComicVersionPageInterval(predecessorStart: 2,
              predecessorEndExclusive: 3, successorOffset: 0),
          ]),
      ]);
    service.updateVersionBaselines([relation]);
    expect(await service.readyPageIndices(target), {0, 2});
    expect((await service.inspectMany([target])).single.reusablePages, 2);
    service.updateVersionBaselines([]);
    expect(await service.readyPageIndices(target), isEmpty);
    expect((await service.inspectMany([target])).single.reusablePages, 0);
  });

  test('targeted physical inventory retains canonical-only bytes and stable partial fallback', () async {
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace);
    addTearDown(service.close);
    final entry = _entry('current', ['https://example.test/s/complete/1',
      'https://example.test/s/unfinished/2']);
    final manifest = entry.chapter.toManifest();
    final exact = readerPageDownloadId(manifest, manifest.pages.first);
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('chapter'),
      sourceId: manifest.sourceId, comicId: manifest.comicId,
      chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision, pageCount: 2,
      intervals: const [CanonicalMediaBindingInterval(exactStart: 0,
        exactEndExclusive: 2, segmentId: CanonicalMediaSegmentId('segment'),
        segmentStart: 0)],
    );
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    await service.storePromotedArtifact(id: exact, bytes: bytes);
    final canonical = PhysicalMediaId.canonical(
      projection.coordinateForPageIndex(0).stableKey);
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: canonical, sourceId: exact), isTrue);
    await service.invalidateArtifact(exact);
    final partialId = verifiedPhysicalMediaId(sourceId: manifest.sourceId,
      page: manifest.pages.last)!;
    final index = service.artifactStore.index as SqliteIndex;
    await index.putPhysicalPartial(PhysicalPartialRecord(id: partialId,
      path: '${root.path}/partial', bytes: 7, checksum: 'partial',
      createdUs: 1, touchedUs: 1));
    for (var i = 0; i < 430; i++) {
      await index.putPhysicalPartial(PhysicalPartialRecord(
        id: PhysicalMediaId.canonical('unrelated-$i'), path: '/unrelated/$i',
        bytes: 999, checksum: 'unused', createdUs: 1, touchedUs: 1));
      await index.putPhysicalMediaProjection(PhysicalMediaProjectionRecord(
        exactKey: 'unrelated-$i', familyKey: 'other', projectionJson: '{}',
        createdUs: 1, touchedUs: 1));
    }
    final snapshot = (await service.inspectMany([entry])).single;
    expect(snapshot.completedPages, 1);
    expect(snapshot.exactCompletedPages, 0);
    expect(snapshot.pinnedPages, 0);
    expect(snapshot.receivedBytes, bytes.length + 7);
    final single = await service.inspect(entry);
    expect(single.receivedBytes, snapshot.receivedBytes);
    final event = trace.events.lastWhere((event) =>
      event.payload['stage'] == 'targeted-projection-built');
    expect(event.payload['indexedRecords'], 0);
    expect(event.payload['physicalArtifacts'], 1);
    expect(event.payload['physicalPartials'], 1);
    expect(event.payload['canonicalProjections'], 1);
    final compact = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final compactSnapshot = (await service.inspectMany([compact])).single;
    expect(compactSnapshot.completedPages, 1);
    expect(compactSnapshot.exactCompletedPages, 0);
    expect(compactSnapshot.pinnedPages, 0);
    expect(compactSnapshot.receivedBytes, bytes.length);
    // Global management still finds unrelated inventory and orphaned families.
    expect(await index.listPhysicalPartials(), hasLength(431));
    expect(await index.listPhysicalMediaProjections(), hasLength(431));
  });

  test('canonical statistics keep literal identity, READY priority and fresh inventory', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final entry = _entry('current', [
      'venera-resource:zero', 'venera-resource:one',
      'https://example.test/s/fallback-key/2',
      'venera-resource:three', 'venera-resource:four',
    ]);
    final compact = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('canonical'),
      sourceId: entry.chapter.sourceId, comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId, sourceRevision: entry.chapter.sourceRevision,
      pageCount: 5, intervals: const [CanonicalMediaBindingInterval(exactStart: 0,
        exactEndExclusive: 5, segmentId: CanonicalMediaSegmentId('segment'),
        segmentStart: 0)],
    );
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    final seed = _entry('seed', ['venera-resource:seed']).chapter.toManifest();
    final seedId = readerPageDownloadId(seed, seed.pages.single);
    await service.storePromotedArtifact(id: seedId, bytes: bytes);
    final index = service.artifactStore.index as SqliteIndex;
    final artifact = (await index.get(seedId.key))!.artifactId;
    final ready = PhysicalMediaId.canonical(projection.coordinateForPageIndex(0).stableKey);
    final alternateCoordinate = projection.coordinateForPageIndex(3);
    final alternateKey = '${alternateCoordinate.stableKey.substring(
      0, alternateCoordinate.stableKey.length - 3)}2:03';
    expect(CanonicalMediaCoordinate.tryParseStableKey(alternateKey), alternateCoordinate);
    final wrongKind = PhysicalMediaId.fromJson({'kind': 'exact',
      'value': projection.coordinateForPageIndex(4).stableKey});
    final stable = verifiedPhysicalMediaId(sourceId: entry.chapter.sourceId,
      page: entry.chapter.toManifest().pages[2])!;
    for (final id in [ready, PhysicalMediaId.canonical(alternateKey), wrongKind, stable]) {
      await index.putPhysicalMediaArtifactBinding(id: id, artifactId: artifact,
        createdUs: 1, touchedUs: 1);
    }
    for (final (id, length) in [(ready, 7), (PhysicalMediaId.canonical(
      projection.coordinateForPageIndex(1).stableKey), 5)]) {
      await index.putPhysicalPartial(PhysicalPartialRecord(id: id,
        path: '${root.path}/partial-$length', bytes: length, checksum: '12345678',
        createdUs: 1, touchedUs: 1));
    }
    final sessions = service.materializedSessionCount;
    final summary = (await service.inspectMany([compact])).single;
    expect(summary.completedPages, 1);
    expect(summary.receivedBytes, bytes.length + 5);
    expect(summary.exactCompletedPages, 0);
    final full = (await service.inspectMany([entry])).single;
    expect(full.completedPages, 2);
    expect(full.receivedBytes, bytes.length * 2 + 5);
    expect(full.pinnedPages, 0);
    // The derived lookup belongs only to this inventory read. Removing READY
    // authority must immediately expose the remaining partial on the next read.
    await index.removePhysicalMediaArtifactBinding(ready);
    final refreshed = (await service.inspectMany([compact])).single;
    expect(refreshed.completedPages, 0);
    expect(refreshed.receivedBytes, 12);
    expect(service.materializedSessionCount, sessions);
  });

  test('management binds each exact chapter shape and checks candidate carriers', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final first = _entry('first', [for (var i = 0; i < 3; i++) 'venera-resource:first-$i']);
    final secondSeed = _entry('second', [
      'https://example.test/s/bbbbbbbbbbbbbbbb/2-1',
      for (var i = 1; i < 4; i++) 'venera-resource:second-$i',
    ]);
    final second = ImportedLibraryEntry(chapter: secondSeed.chapter.copyWith(sourceRevision: 'r2'));
    VersionChapterCanonicalProjection projection(ImportedLibraryEntry entry, int count) =>
        VersionChapterCanonicalProjection(familyId: VersionFamilyId(entry.chapter.comicId),
          canonicalChapterId: const CanonicalChapterId('canonical'),
          sourceId: entry.chapter.sourceId, comicId: entry.chapter.comicId,
          chapterId: entry.chapter.chapterId, sourceRevision: entry.chapter.sourceRevision,
          pageCount: count, intervals: [CanonicalMediaBindingInterval(exactStart: 0,
            exactEndExclusive: count, segmentId: const CanonicalMediaSegmentId('segment'),
            segmentStart: 0)]);
    final firstProjection = projection(first, 3);
    final staleSecondProjection = projection(second, 5);
    await service.artifactStore.persistCanonicalMediaProjections([
      firstProjection, staleSecondProjection,
    ]);
    final firstManifest = first.chapter.toManifest();
    final exact = readerPageDownloadId(firstManifest, firstManifest.pages.first);
    await service.storePromotedArtifact(id: exact, bytes: bytes);
    final index = service.artifactStore.index as SqliteIndex;
    await index.put((await index.get(exact.key))!.copyWith(pinned: true));
    await service.artifactStore.storePartialDownload(
      id: readerPageDownloadId(firstManifest, firstManifest.pages[1]),
      entry: PartialDownloadEntry(length: 7, totalLength: 20, validators: const Validators(),
        open: ({required int start}) async* { yield Uint8List.sublistView(bytes, start, 7); }),
    );
    final staleId = DownloadId(content: ContentId(sourceId: first.chapter.sourceId,
        comicId: first.chapter.comicId, chapterId: first.chapter.chapterId,
        pageId: firstManifest.pages[2].pageId), sourceRevision: 'r1',
      canonicalUri: Uri.parse('venera-resource:stale-carrier'), pageIndexHint: 0);
    await service.storePromotedArtifact(id: staleId, bytes: bytes);
    for (final projected in [firstProjection, staleSecondProjection]) {
      expect(await service.artifactCacheManager.bindPhysicalArtifact(
        physicalId: PhysicalMediaId.canonical(projected.coordinateForPageIndex(
          identical(projected, firstProjection) ? 0 : 2).stableKey),
        sourceId: exact), isTrue);
    }
    await index.putPhysicalPartial(PhysicalPartialRecord(id: PhysicalMediaId.canonical(
      firstProjection.coordinateForPageIndex(2).stableKey), path: '${root.path}/partial',
      bytes: 5, checksum: '12345678', createdUs: 1, touchedUs: 1));
    final secondManifest = second.chapter.toManifest();
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: verifiedPhysicalMediaId(sourceId: second.chapter.sourceId,
        page: secondManifest.pages.first)!, sourceId: exact), isTrue);
    final sessionsBeforeInspection = service.materializedSessionCount;
    for (final requested in [[first, second], [second, first]]) {
      final snapshots = await service.inspectMany(requested);
      final firstSnapshot = snapshots.singleWhere((s) => s.comicId == 'first');
      final secondSnapshot = snapshots.singleWhere((s) => s.comicId == 'second');
      expect(firstSnapshot.completedPages, 1);
      expect(firstSnapshot.exactCompletedPages, 1);
      expect(firstSnapshot.pinnedPages, 1);
      expect(firstSnapshot.receivedBytes, bytes.length + 7 + 5);
      expect(secondSnapshot.completedPages, 1,
        reason: 'stale pageCount cannot bind projected bytes; stable URI fallback still works');
      expect(secondSnapshot.exactCompletedPages, 0);
      expect(secondSnapshot.pinnedPages, 0);
      expect(secondSnapshot.receivedBytes, bytes.length);
      final cache = await service.inspectCacheManagement(requested);
      final canonical = cache.canonical.singleWhere((r) => r.familyId == firstProjection.familyId);
      expect(canonical.readyPages, 0);
      expect(canonical.partialPages, 1);
      expect(canonical.receivedBytes, 5,
        reason: 'historical inventory without a live range cannot create a download reference');
      expect(cache.exact.any((r) => r.comicId == 'first'), isFalse);
      final adopted = await service.inspect(first);
      expect(adopted.completedPages, 1,
        reason: 'same pageId with a stale carrier cannot become current READY');
      expect(adopted.pinnedPages, 1);
      expect(adopted.receivedBytes, bytes.length + 7 + 5);
      expect(cache.exact.any((r) => r.comicId == 'second'), isFalse,
        reason: 'stable aliases of a downloaded body remain retained');
      expect(cache.canonical.any((r) => r.familyId == staleSecondProjection.familyId), isFalse,
        reason: 'retained historical bodies belong on the manual download tab');
    }
    expect(service.materializedSessionCount, sessionsBeforeInspection);
  });

  test('cache deletion rechecks new pins and fences a retired owner', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final first = _entry('delete-selection', ['venera-resource:first']);
    final unrelated = _entry('unrelated', ['venera-resource:other']);
    final firstId = readerPageDownloadId(first.chapter.toManifest(),
        first.chapter.toManifest().pages.single);
    final otherId = readerPageDownloadId(unrelated.chapter.toManifest(),
        unrelated.chapter.toManifest().pages.single);
    await service.storePromotedArtifact(id: firstId, bytes: bytes);
    await service.storePromotedArtifact(id: otherId, bytes: bytes);
    final cache = await service.inspectCacheManagement([first, unrelated]);
    final target = cache.exact.singleWhere((row) => row.comicId == first.chapter.comicId).deleteTarget!;
    final artifact = (await service.artifactStore.openArtifactStream(firstId))!;
    final reader = (await artifact.openBoundRangeReader!())!;
    try {
      final busy = await service.clearChapterCache(target);
      expect(busy.releasedBytes, 0);
      expect(busy.skippedBusy, 1);
      expect(await reader.readRange(0, bytes.length), bytes);
      expect(await service.artifactStore.index.get(otherId.key), isNotNull);
    } finally {
      await reader.close();
    }
    await service.artifactStore.pinExactRecords([firstId]);
    final protected = await service.clearChapterCache(target);
    expect(protected.releasedBytes, 0);
    expect(await service.artifactStore.index.get(firstId.key), isNotNull);
    expect(await service.artifactStore.index.get(otherId.key), isNotNull);
    final next = await service.inspectCacheManagement([first, unrelated]);
    expect(next.exact.single.comicId, unrelated.chapter.comicId);
    await service.clearChapterCache(next.exact.single.deleteTarget!);
    expect(await service.artifactStore.index.get(otherId.key), isNull);
    expect(await service.artifactStore.index.get(firstId.key), isNotNull);

    final alternateRoot = await Directory.systemTemp.createTemp('cache-delete-other-owner-');
    try {
      final alternate = await PersistentChapterDownloadService.open(alternateRoot.path);
      try {
        expect(() => alternate.clearChapterCache(target), throwsStateError);
      } finally {
        await alternate.close();
      }
    } finally {
      await alternateRoot.delete(recursive: true);
    }
  });

  test('cache row deletion removes an exact partial without a library snapshot', () async {
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final entry = _entry('partial-delete', ['venera-resource:partial']);
    final id = readerPageDownloadId(entry.chapter.toManifest(), entry.chapter.toManifest().pages.single);
    await service.artifactStore.storePartialDownload(id: id,
      entry: PartialDownloadEntry(length: 7, totalLength: 20,
        validators: const Validators(), open: ({required int start}) async* {
          yield Uint8List.sublistView(bytes, start, 7);
        }));
    final cache = await service.inspectCacheManagement([entry]);
    expect(cache.exact.single.partialPages, 1);
    final report = await service.clearChapterCache(cache.exact.single.deleteTarget!);
    expect(report.releasedBytes, 7);
    expect(await service.artifactStore.index.get(id.key), isNull);
    expect((await service.inspectCacheManagement([entry])).exact, isEmpty);
  });

  test('manual chapter adopts cached pages without fetching gaps or retaining another revision', () async {
    final entry = _entry('adopt', [for (var i = 0; i < 3; i++) 'venera-resource:adopt-$i']);
    final old = ImportedLibraryEntry(chapter: entry.chapter.copyWith(sourceRevision: 'old'));
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path,
      traceSink: trace, summaryChapterLookup: (_, __) async => entry);
    addTearDown(service.close);
    var fetches = 0;
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
      fetches++;
      throw StateError('cache adoption must not fetch a missing page');
    }));
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    final oldManifest = old.chapter.toManifest();
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages.first);
    await service.storePromotedArtifact(id: ids[0], bytes: bytes);
    await service.artifactStore.pinExactRecords([ids[0]]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    await service.storePromotedArtifact(id: oldId, bytes: bytes);
    final cached = (await service.artifactStore.index.get(ids[1].key))!;
    final before = await service.inspect(entry);
    expect(before.isManualDownload, isTrue);
    expect(before.autoCachedPages, 0,
      reason: 'a committed page awaiting local export already belongs to the task');
    final cache = await service.inspectCacheManagement([entry, old]);
    expect(cache.exact.map((row) => row.sourceRevision), ['old']);
    await _waitForCacheAdoption(service);
    final adopted = (await service.artifactStore.index.get(ids[1].key))!;
    expect(adopted.pinned, isTrue);
    expect(adopted.path, isNot(cached.path));
    expect(await File(adopted.path).readAsBytes(), bytes);
    expect(await service.artifactStore.index.get(ids[2].key), isNull);
    expect((await service.artifactStore.index.get(oldId.key))!.pinned, isFalse);
    final partial = await service.inspect(entry);
    expect(partial.completedPages, 2);
    expect(partial.pinnedPages, 2);
    expect(partial.isComplete, isFalse);

    // A subsequent Reader commit is adopted by the owner invalidation timer,
    // without a cache-tab visit or an explicit retry of the missing page.
    await service.storePromotedArtifact(id: ids[2], bytes: bytes);
    for (var i = 0; i < 100; i++) {
      if ((await service.artifactStore.index.get(ids[2].key))?.pinned == true &&
          service.activeDownloadEntries.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final complete = await service.inspect(entry);
    expect(complete.pinnedPages, 3);
    expect(complete.isComplete, isTrue);
    expect(fetches, 0);
    expect(trace.events.where((e) => e.payload['stage'] == 'page-network'), isEmpty);
    final index = service.artifactStore.index as SqliteIndex;
    expect(await index.readRetainedPhysicalCacheKeys(), isEmpty);
    final cleared = await service.clearArtifacts();
    expect(cleared.releasedBytes, bytes.length,
      reason: 'only the unrelated old revision remains automatic cache');
    for (final id in ids) {
      expect((await index.get(id.key))!.pinned, isTrue);
    }
  });

  test('download head adopts canonical cache without reviving its pinned predecessor', () async {
    final old = _entry('old-head', ['venera-resource:old-0', 'venera-resource:old-1']);
    final head = _entry('current-head', [for (var i = 0; i < 3; i++) 'venera-resource:head-$i']);
    final entries = [old.copyWith(chapter: old.chapter.copyWith(
      comicTitle: 'Same family', chapterId: 'old-chapter')),
      head.copyWith(chapter: head.chapter.copyWith(comicTitle: 'Same family', chapterId: 'head-chapter'))];
    final lookups = <String>[];
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace,
      summaryChapterLookup: (_, chapter) async {
        lookups.add(chapter);
        return entries.where((entry) => entry.chapter.chapterId == chapter).firstOrNull;
      });
    addTearDown(service.close);
    var fetches = 0;
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
      fetches++;
      throw StateError('head adoption must not fetch gaps');
    }));
    const relation = ComicVersionRelation(sourceId: 'venera:test',
      predecessorComicId: 'old-head', successorComicId: 'current-head', pageMappings: [
        ComicVersionPageMapping(predecessorChapterId: 'old-chapter', successorChapterId: 'head-chapter',
          predecessorPageCount: 2, successorPageCount: 3, successorOffset: 0,
          predecessorSourceRevision: 'r1', successorSourceRevision: 'r1', verifiedIntervals: [
            VerifiedComicVersionPageInterval(predecessorStart: 0, predecessorEndExclusive: 2,
              successorOffset: 0),
          ]),
      ]);
    service.updateVersionBaselines(resolveComicVersionBaselines(relations: [relation],
      manualDownloadComics: [for (final entry in entries) ComicVersionIdentity(
        sourceId: entry.chapter.sourceId, comicId: entry.chapter.comicId)]).downloadHeadRelations);
    service.updateCacheVersionRelations([relation]);
    final pageIds = <List<DownloadId>>[];
    final projections = <VersionChapterCanonicalProjection>[];
    for (final entry in entries) {
      final manifest = entry.chapter.toManifest();
      pageIds.add([for (final page in manifest.pages) readerPageDownloadId(manifest, page)]);
      final projection = VersionChapterCanonicalProjection(familyId: const VersionFamilyId('head-family'),
        canonicalChapterId: const CanonicalChapterId('chapter'), sourceId: manifest.sourceId,
        comicId: manifest.comicId, chapterId: manifest.chapter.chapterId,
        sourceRevision: manifest.chapter.sourceRevision, pageCount: manifest.pages.length,
        intervals: const [CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 2,
          segmentId: CanonicalMediaSegmentId('shared'), segmentStart: 0)]);
      projections.add(projection);
      await service.artifactStore.persistCanonicalMediaProjection(projection);
      await service.storePromotedArtifact(id: pageIds.last[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([pageIds.last[0]]);
    }
    final index = service.artifactStore.index as SqliteIndex;
    await service.storePromotedArtifact(id: pageIds.first[1], bytes: bytes);
    await index.retainDownloadCache(sourceId: 'venera:test', comicId: 'old-head',
      chapterId: 'old-chapter', sourceRevision: 'r1');
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: PhysicalMediaId.canonical(projections.first.coordinateForPageIndex(1).stableKey),
      sourceId: pageIds.first[1]), isTrue);
    await service.artifactStore.writeComicFolderManifest(entries.last);
    final compact = [for (final entry in entries) ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()))];
    await service.inspectCacheManagement(compact);
    await _waitForCacheAdoption(service);
    expect(lookups, isNot(contains('old-chapter')),
      reason: 'historical retention must not hydrate a superseded execution owner');
    expect((await index.get(pageIds.first[0].key))!.pinned, isTrue);
    expect((await index.get(pageIds.first[1].key))!.pinned, isFalse);
    expect(await service.readPage(entries.first, 1), bytes);
    expect(await index.hasDownloadCacheIntent(const CacheBindingScope(sourceId: 'venera:test',
      comicId: 'old-head', chapterId: 'old-chapter', sourceRevision: 'r1')), isTrue);
    expect((await index.get(pageIds.last[1].key))!.pinned, isTrue);
    expect(await index.get(pageIds.last[2].key), isNull);
    final manifestFile = File('${service.artifactStore.layout.root}/Same family/$comicManifestFileName');
    expect((jsonDecode(await manifestFile.readAsString()) as Map)['comicId'], 'current-head');
    expect(trace.events.where((e) => e.payload['stage'] == 'chapter-run-start')
      .map((e) => e.payload['comicId']), ['current-head']);
    expect(fetches, 0);
  });

  for (final pendingLookup in [false, true]) {
    test('head change fences ${pendingLookup ? 'pending lookup' : 'active local export'}', () async {
      final old = _entry('previous-head', ['venera-resource:old-0', 'venera-resource:old-1']);
      final entered = Completer<void>();
      final release = Completer<void>();
      final reads = ArtifactCacheReadScheduler();
      final writes = StorageWriteScheduler(localReadScheduler: reads);
      final service = await PersistentChapterDownloadService.open(root.path,
        localReadScheduler: reads, storageWriteScheduler: writes,
        summaryChapterLookup: (_, __) async {
          if (!entered.isCompleted) entered.complete();
          if (pendingLookup) await release.future;
          return old;
        });
      addTearDown(service.close);
      final manifest = old.chapter.toManifest();
      final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
      await service.storePromotedArtifact(id: ids[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([ids[0]]);
      await service.storePromotedArtifact(id: ids[1], bytes: bytes);
      final lease = pendingLookup ? null : await writes.acquireQuantum();
      addTearDown(() => lease?.release());
      final active = pendingLookup ? null : service.downloadExecutionChanges.firstWhere((_) =>
        service.activeDownloadEntries.isNotEmpty);
      final reading = service.inspectCacheManagement(pendingLookup ? const [] : [old]);
      if (pendingLookup) {
        await entered.future;
      } else {
        await active;
      }
      // These are the resolver's direct relations to the newly adopted manual
      // head, not discovery-only history and not cache reuse authority.
      service.updateVersionBaselines(const [ComicVersionRelation(sourceId: 'venera:test',
        predecessorComicId: 'previous-head', successorComicId: 'new-manual-head')]);
      release.complete();
      lease?.release();
      await reading;
      await _waitForCacheAdoption(service);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final index = service.artifactStore.index as SqliteIndex;
      expect((await index.get(ids[0].key))!.pinned, isTrue);
      expect((await index.get(ids[1].key))!.pinned, isFalse);
      expect(service.activeDownloadEntries, isEmpty);
      if (pendingLookup) {
        expect(await index.hasDownloadCacheIntent(CacheBindingScope(sourceId: manifest.sourceId,
          comicId: manifest.comicId, chapterId: manifest.chapter.chapterId,
          sourceRevision: manifest.chapter.sourceRevision)), isFalse);
      }
    });
  }

  for (final discoveredOnly in [false, true]) {
    test('adoption preserves ${discoveredOnly ? 'current manual head over discovery' : 'unmapped exact chapter'}', () async {
      final entry = _entry('kept-head', ['venera-resource:kept-0', 'venera-resource:kept-1']);
      final service = await PersistentChapterDownloadService.open(root.path);
      addTearDown(service.close);
      const relation = ComicVersionRelation(sourceId: 'venera:test',
        predecessorComicId: 'kept-head', successorComicId: 'newer', pageMappings: [
          ComicVersionPageMapping(predecessorChapterId: 'other-chapter', successorChapterId: 'new-chapter',
            predecessorPageCount: 2, successorPageCount: 3, successorOffset: 0),
        ]);
      final baseline = resolveComicVersionBaselines(relations: [relation], manualDownloadComics: [
        const ComicVersionIdentity(sourceId: 'venera:test', comicId: 'kept-head'),
        if (!discoveredOnly) const ComicVersionIdentity(sourceId: 'venera:test', comicId: 'newer'),
      ]);
      service.updateVersionBaselines(baseline.downloadHeadRelations);
      final manifest = entry.chapter.toManifest();
      final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
      await service.storePromotedArtifact(id: ids[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([ids[0]]);
      await service.storePromotedArtifact(id: ids[1], bytes: bytes);
      await service.inspectCacheManagement([entry]);
      await _waitForCacheAdoption(service);
      expect((await service.inspect(entry)).pinnedPages, 2);
      expect((await (service.artifactStore.index as SqliteIndex).readDownloadCacheOwnershipScopes())
        .map((scope) => scope.comicId), isNot(contains('newer')));
    });
  }

  for (final activeProof in [false, true]) {
    test('canonical adoption requires live proof=$activeProof and no sibling references', () async {
      final entry = _entry('canonical-adopt', [
        for (var i = 0; i < 3; i++) 'venera-resource:canonical-adopt-$i',
      ]);
      final sibling = _entry('unopened', [
        for (var i = 0; i < 3; i++) 'venera-resource:unopened-$i',
      ]);
      final service = await PersistentChapterDownloadService.open(root.path);
      addTearDown(service.close);
      var fetches = 0;
      service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
        fetches++;
        throw StateError('no network during local canonical adoption');
      }));
      VersionChapterCanonicalProjection projection(ImportedLibraryEntry target) =>
        VersionChapterCanonicalProjection(familyId: const VersionFamilyId('adopt-family'),
          canonicalChapterId: const CanonicalChapterId('chapter'),
          sourceId: target.chapter.sourceId, comicId: target.chapter.comicId,
          chapterId: target.chapter.chapterId, sourceRevision: target.chapter.sourceRevision,
          pageCount: 3, intervals: const [CanonicalMediaBindingInterval(exactStart: 0,
            exactEndExclusive: 3, segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 0)]);
      final currentProjection = projection(entry);
      await service.artifactStore.persistCanonicalMediaProjections([
        currentProjection, projection(sibling),
      ]);
      final manifest = entry.chapter.toManifest();
      final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
      await service.storePromotedArtifact(id: ids[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([ids[0]]);
      await service.storePromotedArtifact(id: ids[1], bytes: bytes);
      final ready = PhysicalMediaId.canonical(currentProjection.coordinateForPageIndex(1).stableKey);
      expect(await service.artifactCacheManager.bindPhysicalArtifact(
        physicalId: ready, sourceId: ids[1]), isTrue);
      await service.invalidateArtifact(ids[1]);
      final partial = PhysicalMediaId.canonical(currentProjection.coordinateForPageIndex(2).stableKey);
      final index = service.artifactStore.index as SqliteIndex;
      final partialPath = '${root.path}/canonical.partial';
      await File(partialPath).writeAsBytes(bytes.sublist(0, 7));
      await index.putPhysicalPartial(PhysicalPartialRecord(id: partial,
        path: partialPath, bytes: 7, checksum: '12345678', createdUs: 1, touchedUs: 1));
      if (activeProof) {
        service.updateCacheVersionRelations([ComicVersionRelation(
          sourceId: entry.chapter.sourceId, predecessorComicId: entry.chapter.comicId,
          successorComicId: sibling.chapter.comicId, pageMappings: [ComicVersionPageMapping(
            predecessorChapterId: entry.chapter.chapterId, successorChapterId: sibling.chapter.chapterId,
            predecessorPageCount: 3, successorPageCount: 3, successorOffset: 0,
            predecessorSourceRevision: entry.chapter.sourceRevision,
            successorSourceRevision: sibling.chapter.sourceRevision,
            verifiedIntervals: const [VerifiedComicVersionPageInterval(predecessorStart: 0,
              predecessorEndExclusive: 3, successorOffset: 0)],
          )],
        )]);
      }
      final cache = await service.inspectCacheManagement([entry, sibling]);
      await _waitForCacheAdoption(service);
      expect(cache.exact, isEmpty);
      if (activeProof) {
        expect(cache.canonical, isEmpty);
        expect((await index.get(ids[1].key))!.pinned, isTrue);
        expect(await File((await index.get(ids[1].key))!.path).readAsBytes(), bytes);
      } else {
        expect(cache.canonical.single.readyPages, 1);
        expect(cache.canonical.single.partialPages, 1);
        expect(await index.get(ids[1].key), isNull);
      }
      expect(await index.get(ids[2].key), isNull,
        reason: 'resident partial bytes cannot become a completed page');
      expect((await index.readRetainedPhysicalCacheKeys()).contains(partial.key), activeProof);
      expect((await service.inspect(entry)).pinnedPages, activeProof ? 2 : 1);
      expect((await service.inspect(entry)).completedPages, 2);
      expect((await service.inspect(sibling)).pinnedPages, 0);
      for (final page in sibling.chapter.toManifest().pages) {
        expect(await index.get(readerPageDownloadId(sibling.chapter.toManifest(), page).key), isNull);
      }
      await service.clearArtifacts();
      expect(await File(partialPath).exists(), activeProof);
      expect(fetches, 0);
    });
  }

  test('local adoption cannot restore a complete phase while a page is missing', () async {
    final entry = _entry('adoption-phase', [for (var i = 0; i < 3; i++) 'venera-resource:phase-$i']);
    final service = await PersistentChapterDownloadService.open(root.path);
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    for (final id in ids) {
      await service.storePromotedArtifact(id: id, bytes: bytes);
    }
    await service.download(entry);
    expect((await service.inspect(entry)).isComplete, isTrue);
    await service.invalidateArtifact(ids[1]);
    await service.invalidateArtifact(ids[2]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    await service.inspectCacheManagement([entry]);
    await _waitForCacheAdoption(service);
    final snapshot = await service.inspect(entry);
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.completedPages, 2);
    expect(snapshot.pinnedPages, 2);
    expect(snapshot.autoCachedPages, 0);
  });

  test('delete while adoption lookup is pending cannot resurrect download ownership', () async {
    final entry = _entry('delete-adoption', ['venera-resource:0', 'venera-resource:1']);
    final entered = Completer<void>();
    final release = Completer<void>();
    final service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: (_, __) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return entry;
      });
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    await service.storePromotedArtifact(id: ids[0], bytes: bytes);
    await service.artifactStore.pinExactRecords([ids[0]]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    final pending = service.inspectCacheManagement(const []);
    await entered.future;
    await service.delete(entry);
    release.complete();
    await pending;
    final index = service.artifactStore.index as SqliteIndex;
    expect(await index.readDownloadCacheOwnershipScopes(), isEmpty);
    expect(await index.readDownloadCacheAdoptionScopes(), isEmpty);
    for (final id in ids) { expect(await index.get(id.key), isNull); }
  });

  test('close drains a pending local adoption lookup before closing storage', () async {
    final entry = _entry('close-adoption', ['venera-resource:0', 'venera-resource:1']);
    final entered = Completer<void>();
    final release = Completer<void>();
    final service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: (_, __) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return entry;
      });
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    await service.storePromotedArtifact(id: ids[0], bytes: bytes);
    await service.artifactStore.pinExactRecords([ids[0]]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    // The timer exercises the same owner path without a manager read that
    // would itself require the service to remain open after adoption exits.
    await entered.future;
    var closed = false;
    final closing = service.close().then((_) { closed = true; });
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    release.complete();
    await closing;
    expect(closed, isTrue);
  });

  for (final (cancel, headChanged) in [(false, false), (true, false), (false, true), (true, true)]) {
    test('explicit download waits for local adoption: cancel=$cancel, headChanged=$headChanged', () async {
      final entry = _entry('join-adoption', [for (var i = 0; i < 3; i++) 'venera-resource:join-$i']);
      final reads = ArtifactCacheReadScheduler();
      final writes = StorageWriteScheduler(localReadScheduler: reads);
      final service = await PersistentChapterDownloadService.open(root.path,
        localReadScheduler: reads, storageWriteScheduler: writes);
      addTearDown(service.close);
      var fetches = 0;
      service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
        fetches++;
        return bytes;
      }));
      final manifest = entry.chapter.toManifest();
      final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
      await service.storePromotedArtifact(id: ids[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([ids[0]]);
      await service.storePromotedArtifact(id: ids[1], bytes: bytes);
      final lease = await writes.acquireQuantum();
      addTearDown(lease.release);
      final active = service.downloadExecutionChanges.firstWhere((_) =>
        service.activeDownloadEntries.isNotEmpty);
      final adopting = service.inspectCacheManagement([entry]);
      await active;
      final explicit = service.download(entry);
      if (headChanged) {
        service.updateVersionBaselines([ComicVersionRelation(sourceId: entry.chapter.sourceId,
          predecessorComicId: entry.chapter.comicId, successorComicId: 'new-manual-head')]);
      }
      final stopping = cancel ? service.cancel(entry) : Future<void>.value();
      lease.release();
      await Future.wait([adopting, explicit, stopping]);
      final snapshot = await service.inspect(entry);
      expect(fetches, cancel ? 0 : 1);
      expect(snapshot.isComplete, !cancel);
      expect(snapshot.autoCachedPages, 0);
      if (cancel) {
        expect(snapshot.phase, ChapterDownloadPhase.cancelled);
        expect(await service.artifactStore.index.get(ids[2].key), isNull);
      } else {
        expect(snapshot.pinnedPages, 3);
      }
    });
  }

  test('cache inventory returns while local download export is waiting for storage', () async {
    final entry = _entry('nonblocking-adoption', ['venera-resource:0', 'venera-resource:1']);
    final reads = ArtifactCacheReadScheduler();
    final writes = StorageWriteScheduler(localReadScheduler: reads);
    final service = await PersistentChapterDownloadService.open(root.path,
      localReadScheduler: reads, storageWriteScheduler: writes);
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    await service.storePromotedArtifact(id: ids[0], bytes: bytes);
    await service.artifactStore.pinExactRecords([ids[0]]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    final lease = await writes.acquireQuantum();
    addTearDown(lease.release);
    final cache = await service.inspectCacheManagement([entry])
        .timeout(const Duration(seconds: 2));
    expect(cache.exact, isEmpty,
      reason: 'download intent owns the bytes before structured export finishes');
    expect(service.activeDownloadEntries, hasLength(1));
    expect((await service.artifactStore.index.get(ids[1].key))!.pinned, isFalse);
    lease.release();
    await _waitForCacheAdoption(service);
    expect((await service.inspect(entry)).pinnedPages, 2);
  });

  test('failed local adoption does not spin or overwrite an invalid destination', () async {
    final entry = _entry('failed-adoption', ['venera-resource:0', 'venera-resource:1']);
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace,
      summaryChapterLookup: (_, __) async => entry);
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
    await service.storePromotedArtifact(id: ids[0], bytes: bytes);
    await service.artifactStore.pinExactRecords([ids[0]]);
    await service.storePromotedArtifact(id: ids[1], bytes: bytes);
    final destination = Directory('${service.artifactStore.layout.root}/${entry.chapter.comicTitle}');
    await destination.create(recursive: true);
    final invalid = File('${destination.path}/$comicManifestFileName');
    await invalid.writeAsString('invalid existing manifest');
    for (var i = 0; i < 3; i++) {
      await service.inspectCacheManagement([entry]);
      await _waitForCacheAdoption(service);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(trace.events.where((e) => e.payload['stage'] == 'chapter-run-start'), hasLength(1));
    expect((await service.inspect(entry)).phase, ChapterDownloadPhase.failed);
    expect(await invalid.readAsString(), 'invalid existing manifest');
    expect((await service.artifactStore.index.get(ids[1].key))!.pinned, isFalse);
    await invalid.delete();
    await service.download(entry);
    expect((await service.inspect(entry)).pinnedPages, 2,
      reason: 'an explicit command may retry after the destination is repaired');
  });

  test('admitted physical-only chapters drain in the background and adopt a completed partial', () async {
    final entries = [for (var i = 0; i < 2; i++)
      _entry('queued-$i', [for (var p = 0; p < 3; p++) 'venera-resource:queued-$i-$p'])];
    for (var i = 0; i < entries.length; i++) {
      entries[i] = entries[i].copyWith(chapter:
        entries[i].chapter.copyWith(chapterId: 'chapter-$i'));
    }
    final reads = ArtifactCacheReadScheduler();
    final writes = StorageWriteScheduler(localReadScheduler: reads);
    final service = await PersistentChapterDownloadService.open(root.path,
      localReadScheduler: reads, storageWriteScheduler: writes,
      summaryChapterLookup: (_, chapter) async =>
        entries.where((entry) => entry.chapter.chapterId == chapter).firstOrNull);
    addTearDown(service.close);
    var fetches = 0;
    service.setChapterResourceAccess(ChapterResourceAccess(loadBytes: (_, __) async {
      fetches++;
      throw StateError('local adoption must not fetch gaps');
    }));
    final pageIds = <List<DownloadId>>[];
    final projections = <VersionChapterCanonicalProjection>[];
    for (final entry in entries) {
      final manifest = entry.chapter.toManifest();
      final ids = [for (final page in manifest.pages) readerPageDownloadId(manifest, page)];
      pageIds.add(ids);
      final projection = VersionChapterCanonicalProjection(familyId: VersionFamilyId(manifest.comicId),
        canonicalChapterId: const CanonicalChapterId('chapter'), sourceId: manifest.sourceId,
        comicId: manifest.comicId, chapterId: manifest.chapter.chapterId,
        sourceRevision: manifest.chapter.sourceRevision, pageCount: 3,
        intervals: const [CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 3,
          segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 0)]);
      projections.add(projection);
      await service.artifactStore.persistCanonicalMediaProjection(projection);
      service.transferRuntime.replaceCanonicalMediaAuthorityScope(manifest.comicId, [
        CanonicalMediaChapterAuthority(manifest: manifest, projection: projection,
          activeProjectionRanges: const [CanonicalMediaActiveRange(start: 0, endExclusive: 3)]),
      ]);
      await service.storePromotedArtifact(id: ids[0], bytes: bytes);
      await service.artifactStore.pinExactRecords([ids[0]]);
      await service.storePromotedArtifact(id: ids[1], bytes: bytes);
      expect(await service.artifactCacheManager.bindPhysicalArtifact(
        physicalId: PhysicalMediaId.canonical(projection.coordinateForPageIndex(1).stableKey),
        sourceId: ids[1]), isTrue);
      await service.invalidateArtifact(ids[1]);
    }
    final index = service.artifactStore.index as SqliteIndex;
    final partial = PhysicalMediaId.canonical(projections.last.coordinateForPageIndex(2).stableKey);
    final path = '${root.path}/queued.partial';
    await File(path).writeAsBytes(bytes.sublist(0, 7));
    await index.putPhysicalPartial(PhysicalPartialRecord(id: partial,
      path: path, bytes: 7, checksum: '12345678', createdUs: 1, touchedUs: 1));
    final lease = await writes.acquireQuantum();
    addTearDown(lease.release);
    final cache = await service.inspectCacheManagement(entries).timeout(const Duration(seconds: 2));
    expect(cache.canonical, isEmpty);
    expect(service.activeDownloadEntries, hasLength(1));
    lease.release();
    for (var i = 0; i < 300; i++) {
      if ((await index.get(pageIds.last[1].key))?.pinned == true &&
          (await index.get(pageIds.first[1].key))?.pinned == true &&
          service.activeDownloadEntries.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (final ids in pageIds) {
      expect((await index.get(ids[1].key))!.pinned, isTrue);
      expect(await index.get(ids[2].key), isNull);
    }
    expect(await index.isPhysicalCacheRetained(partial.key), isTrue);
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: partial, sourceId: pageIds.last[1]), isTrue);
    for (var i = 0; i < 300; i++) {
      if ((await index.get(pageIds.last[2].key))?.pinned == true &&
          service.activeDownloadEntries.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await service.inspect(entries.last)).pinnedPages, 3);
    expect(fetches, 0);
    expect(await index.isPhysicalCacheRetained(partial.key), isFalse);
  });

  test('an exact downloaded READY page does not repeatedly adopt a redundant canonical partial', () async {
    final entry = _entry('redundant-partial', ['venera-resource:0']);
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace);
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final id = readerPageDownloadId(manifest, manifest.pages.single);
    await service.storePromotedArtifact(id: id, bytes: bytes);
    await service.artifactStore.pinExactRecords([id]);
    final projection = VersionChapterCanonicalProjection(familyId: const VersionFamilyId('redundant'),
      canonicalChapterId: const CanonicalChapterId('chapter'), sourceId: manifest.sourceId,
      comicId: manifest.comicId, chapterId: manifest.chapter.chapterId,
      sourceRevision: manifest.chapter.sourceRevision, pageCount: 1,
      intervals: const [CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 1,
        segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 0)]);
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    service.transferRuntime.replaceCanonicalMediaAuthorityScope('redundant-partial-test', [
      CanonicalMediaChapterAuthority(manifest: manifest, projection: projection,
        activeProjectionRanges: const [CanonicalMediaActiveRange(start: 0, endExclusive: 1)]),
    ]);
    final partial = PhysicalMediaId.canonical(projection.coordinateForPageIndex(0).stableKey);
    final path = '${root.path}/redundant.partial';
    await File(path).writeAsBytes(bytes.sublist(0, 7));
    final index = service.artifactStore.index as SqliteIndex;
    await index.putPhysicalPartial(PhysicalPartialRecord(id: partial,
      path: path, bytes: 7, checksum: '12345678', createdUs: 1, touchedUs: 1));
    for (var i = 0; i < 3; i++) {
      final cache = await service.inspectCacheManagement([entry]);
      expect(cache.canonical.single.partialPages, 1);
      expect(service.activeDownloadEntries, isEmpty);
    }
    expect(trace.events.where((e) => e.payload['stage'] == 'chapter-run-start'), isEmpty);
    expect(await index.readRetainedPhysicalCacheKeys(), isEmpty);
    await service.clearArtifacts();
    expect(await File(path).exists(), isFalse);
    expect((await index.get(id.key))!.pinned, isTrue);
  });

  test('manual snapshots never classify committed or reusable pages as automatic cache', () {
    for (final phase in ChapterDownloadPhase.values) {
      for (final pinned in [0, 1]) {
        final snapshot = ChapterDownloadSnapshot(sourceId: 's', comicId: 'c',
          comicTitle: 'Comic', chapterId: 'ch', sourceRevision: 'r', title: 'Chapter',
          completedPages: 2, exactCompletedPages: 1, totalPages: 3, receivedBytes: 10,
          pinnedPages: pinned, phase: phase);
        expect(snapshot.autoCachedPages,
          snapshot.isManualDownload ? 0 : 2);
      }
    }
  });

  test('count-only download and cache management do not expand uncached slots', () async {
    final trace = MemoryTraceSink();
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace,
      summaryChapterLookup: (_, __) async => throw StateError('empty summary must not hydrate'));
    addTearDown(service.close);
    final json = _entry('empty', ['venera-resource:unused']).chapter.toSummaryJson()
      ..['pageCount'] = 50000;
    final entry = ImportedLibraryEntry(chapter: ImportedChapterRecord.fromSummaryJson(json));
    final snapshot = (await service.inspectMany([entry])).single;
    expect(snapshot.totalPages, 50000);
    expect(snapshot.completedPages, 0);
    expect(snapshot.receivedBytes, 0);
    expect(snapshot.totalBytes, isNull);
    final event = trace.events.lastWhere((event) =>
      event.payload['stage'] == 'targeted-projection-built');
    expect(event.payload['projectedPageSlots'], 0);
    final management = await service.inspectDownloadManagement([entry]);
    expect(management.snapshots.single.totalPages, 50000);
    expect(management.cache!.canonical, isEmpty);
    expect(management.cache!.exact, isEmpty);
    expect(trace.events.lastWhere((event) =>
      event.payload['stage'] == 'management-projection-built')
      .payload['projectedPageSlots'], 0);
    expect(service.materializedSessionCount, 0);
  });

  test('summary URI identities retain exact READY pins and partial bytes', () async {
    final entry = _entry('current', [for (var i = 0; i < 4; i++) 'venera-resource:page-$i']);
    final summary = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final legacy = ImportedLibraryEntry(chapter: summary.chapter.copyWith(
      pages: [for (var i = 0; i < 4; i++) summary.chapter.pages[i]]));
    var service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: (_, __) async => null);
    addTearDown(() => service.close());
    final manifest = legacy.chapter.toManifest();
    final id = readerPageDownloadId(manifest, manifest.pages.last);
    await service.storePromotedArtifact(id: id, bytes: bytes);
    final index = service.artifactStore.index as SqliteIndex;
    await index.put((await index.get(id.key))!.copyWith(pinned: true));
    await service.close();
    service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: (_, __) async => null);
    // Missing full chapter authority leaves the last URI at temporary slot 0.
    // Its URI identity, rather than that temporary position, owns the record.
    final ready = (await service.inspectMany([summary])).single;
    expect(ready.completedPages, 1);
    expect(ready.exactCompletedPages, 1);
    expect(ready.pinnedPages, 1);
    expect(ready.receivedBytes, bytes.length);
    expect(service.transferRuntime.registry.sessions, isEmpty);
    await service.invalidateArtifact(id);
    await service.artifactStore.storePartialDownload(id: id,
      entry: PartialDownloadEntry(length: 7, totalLength: 20, validators: const Validators(),
        open: ({required int start}) async* { yield Uint8List.sublistView(bytes, start, 7); }));
    final partial = (await service.inspectMany([summary])).single;
    expect(partial.completedPages, 0);
    expect(partial.pinnedPages, 0);
    expect(partial.receivedBytes, 7);
    expect(service.transferRuntime.registry.sessions, isEmpty);
  });

  test('summary preserves disjoint legacy bytes without promoting unverified placeholders', () async {
    final entry = _entry('current', [for (var i = 0; i < 3; i++) 'venera-resource:page-$i']);
    final summary = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: (sourceId, chapterId) async => entry);
    addTearDown(service.close);
    final manifest = entry.chapter.toManifest();
    final exact = readerPageDownloadId(manifest, manifest.pages.last);
    await service.storePromotedArtifact(id: exact, bytes: bytes);
    final placeholders = summary.chapter.toManifest();
    final legacy = readerPageDownloadId(placeholders, placeholders.pages.first);
    await service.artifactStore.index.put(CacheRec(id: legacy,
      state: CacheState.ready, path: '${root.path}/legacy', bytes: 7,
      checksum: '', createdUs: 1, touchedUs: 1));
    final sessions = service.materializedSessionCount;
    final snapshot = (await service.inspectMany([summary])).single;
    // A historical unverified row can report retained bytes, but cannot
    // become READY proof or push a real page into its arbitrary sorted slot.
    expect(snapshot.receivedBytes, bytes.length + 7);
    expect(snapshot.completedPages, 1);
    expect(snapshot.exactCompletedPages, 1);
    expect(snapshot.totalPages, 3);
    expect(snapshot.pageProgressUnits, 2);
    expect(service.materializedSessionCount, sessions);
    expect((await service.artifactStore.index.get(legacy.key))!.checksum, isEmpty);
  });

  test('summary statistics observe sessions created after their inventory snapshot', () async {
    final entry = _entry('current', [for (var i = 0; i < 500; i++) 'venera-resource:page-$i']);
    final summary = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final legacy = ImportedLibraryEntry(chapter: summary.chapter.copyWith(
      pages: [for (var i = 0; i < 500; i++) summary.chapter.pages[i]]));
    late PersistentChapterDownloadService service;
    final sessionCreated = Completer<void>();
    Future<ImportedLibraryEntry?> lookup(String sourceId, String chapterId) async {
      Timer.run(() async {
        final placeholders = legacy.chapter.toManifest();
        final session = service.transferRuntime.registry.get(
          readerPageDownloadId(placeholders, placeholders.pages.last));
        await session.failWithoutWriter(const Failure(code: ErrorCode.network,
          message: 'late session failure'));
        sessionCreated.complete();
      });
      return entry;
    }
    service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: lookup);
    addTearDown(() => service.close());
    final manifest = entry.chapter.toManifest();
    await service.storePromotedArtifact(id: readerPageDownloadId(manifest,
      manifest.pages.first), bytes: bytes);
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('canonical'),
      sourceId: entry.chapter.sourceId, comicId: entry.chapter.comicId,
      chapterId: entry.chapter.chapterId, sourceRevision: entry.chapter.sourceRevision,
      pageCount: 500, intervals: const [CanonicalMediaBindingInterval(exactStart: 0,
        exactEndExclusive: 500, segmentId: CanonicalMediaSegmentId('segment'),
        segmentStart: 0)],
    );
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    await (service.artifactStore.index as SqliteIndex).putPhysicalPartial(
      PhysicalPartialRecord(id: PhysicalMediaId.canonical(
        projection.coordinateForPageIndex(499).stableKey), path: '${root.path}/partial',
        bytes: 7, checksum: '12345678', createdUs: 1, touchedUs: 1));
    await service.close();
    service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: lookup);
    expect(service.transferRuntime.registry.sessions, isEmpty);
    final actual = (await service.inspectMany([summary])).single;
    await sessionCreated.future;
    expect(actual.exactCompletedPages, 1);
    expect(actual.phase, ChapterDownloadPhase.failed);
    expect(actual.failure, contains('late session failure'));
    // The live failed session's zero committed bytes take precedence over the
    // physical partial, even though it was absent from the inventory snapshot.
    expect(actual.receivedBytes, bytes.length);
    expect(service.transferRuntime.registry.sessions, hasLength(1));
  });

  test('sparse exact rows and canonical slots count each logical page once', () async {
    final entry = _entry('current', [for (var i = 0; i < 3; i++) 'venera-resource:page-$i']);
    var authoritative = entry;
    var lookups = 0;
    Future<ImportedLibraryEntry?> lookup(String sourceId, String chapterId) async {
      expect(sourceId, entry.chapter.sourceId);
      expect(chapterId, entry.chapter.chapterId);
      lookups++;
      return authoritative;
    }
    var service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: lookup);
    addTearDown(() => service.close());
    final manifest = entry.chapter.toManifest();
    final id = readerPageDownloadId(manifest, manifest.pages.last);
    await service.storePromotedArtifact(id: id, bytes: bytes);
    final index = service.artifactStore.index as SqliteIndex;
    await index.put((await index.get(id.key))!.copyWith(pinned: true));
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('canonical'),
      sourceId: 'venera:test', comicId: 'current', chapterId: 'chapter',
      sourceRevision: 'r1', pageCount: 3, intervals: const [
        CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 3,
          segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 0),
      ]);
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: PhysicalMediaId.canonical(projection.coordinateForPageIndex(2).stableKey),
      sourceId: id), isTrue);
    await service.close();
    service = await PersistentChapterDownloadService.open(root.path,
      summaryChapterLookup: lookup);
    expect((await service.artifactStore.index.get(id.key))!.id.pageIndexHint, isNull);
    final summary = ImportedLibraryEntry(chapter:
      ImportedChapterRecord.fromSummaryJson(entry.chapter.toSummaryJson()));
    final legacy = ImportedLibraryEntry(chapter: summary.chapter.copyWith(
      pages: [for (var i = 0; i < 3; i++) summary.chapter.pages[i]]));
    Future<void> compare(int completed) async {
      final expected = (await service.inspectMany([entry])).single;
      for (final compact in [summary, legacy]) {
        final actual = (await service.inspectMany([compact])).single;
        expect(actual.completedPages, completed);
        expect(actual.completedPages, expected.completedPages);
        expect(actual.exactCompletedPages, 1);
        expect(actual.pinnedPages, 1);
        expect(actual.receivedBytes, completed * bytes.length);
        expect(actual.receivedBytes, expected.receivedBytes);
      }
    }
    await compare(1);
    // Identical bytes at another coordinate are another logical page. Body
    // identity cannot substitute for the exact page-to-index authority.
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: PhysicalMediaId.canonical(projection.coordinateForPageIndex(0).stableKey),
      sourceId: id), isTrue);
    await compare(2);
    expect(lookups, 4);
    authoritative = _entry('current', ['venera-resource:page-0', 'venera-resource:page-1',
      'venera-resource:changed-page-2']);
    final refreshed = (await service.inspectMany([summary])).single;
    expect(refreshed.completedPages, 2);
    expect(refreshed.exactCompletedPages, 0);
    expect(refreshed.pinnedPages, 0);
    final refreshedManifest = authoritative.chapter.toManifest();
    final refreshedId = readerPageDownloadId(refreshedManifest, refreshedManifest.pages.last);
    await service.storePromotedArtifact(id: refreshedId,
      bytes: Uint8List.fromList([...bytes, 0]));
    final currentLocator = (await service.inspectMany([summary])).single;
    expect(currentLocator.completedPages, 2);
    expect(currentLocator.exactCompletedPages, 1);
    expect(currentLocator.pinnedPages, 0);
    expect(currentLocator.receivedBytes, 2 * bytes.length + 1);
    await service.close();
    service = await PersistentChapterDownloadService.open(root.path);
    await expectLater(service.inspectMany([summary]), throwsStateError);
  });

  test('sparse summaries preserve exact pins, canonical gaps, proof reuse and live aliases', () async {
    final trace = MemoryTraceSink();
    final seed = _entry('current', ['venera-resource:exact-0', 'venera-resource:exact-1']);
    final current = _entry('current', ['venera-resource:exact-0', 'venera-resource:exact-1',
      for (var i = 2; i < 7; i++) 'venera-resource:unloaded-$i']);
    final service = await PersistentChapterDownloadService.open(root.path, traceSink: trace,
      summaryChapterLookup: (_, __) async => current);
    addTearDown(service.close);
    final summary = ImportedLibraryEntry(chapter: ImportedChapterRecord.fromSummaryJson(
      seed.chapter.toSummaryJson()..['pageCount'] = 7));
    final legacy = ImportedLibraryEntry(chapter: summary.chapter.copyWith(
      pages: [for (var i = 0; i < 7; i++) summary.chapter.pages[i]]));
    final manifest = seed.chapter.toManifest();
    final index = service.artifactStore.index as SqliteIndex;
    for (final page in manifest.pages) {
      await service.storePromotedArtifact(id: readerPageDownloadId(manifest, page), bytes: bytes);
    }
    final pinnedId = readerPageDownloadId(manifest, manifest.pages.first);
    await index.put((await index.get(pinnedId.key))!.copyWith(pinned: true));
    final old = _entry('old', ['venera-resource:old-0']);
    final oldManifest = old.chapter.toManifest();
    final oldId = readerPageDownloadId(oldManifest, oldManifest.pages.single);
    await service.storePromotedArtifact(id: oldId, bytes: bytes);
    await index.putExportPageBindings([const ExportPageBinding(sourceId: 'venera:test',
      comicId: 'old', chapterId: 'chapter', pageId: 'old-0', logicalIndex: 0, exportOrdinal: 1)]);
    const relation = ComicVersionRelation(sourceId: 'venera:test',
      predecessorComicId: 'old', successorComicId: 'current', pageMappings: [
        ComicVersionPageMapping(predecessorChapterId: 'chapter', successorChapterId: 'chapter',
          predecessorPageCount: 1, successorPageCount: 7, successorOffset: 4,
          predecessorSourceRevision: 'r1', successorSourceRevision: 'r1',
          verifiedIntervals: [VerifiedComicVersionPageInterval(predecessorStart: 0,
            predecessorEndExclusive: 1, successorOffset: 4)]),
      ]);
    service.updateVersionBaselines([relation]);
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('canonical'),
      sourceId: 'venera:test', comicId: 'current', chapterId: 'chapter',
      sourceRevision: 'r1', pageCount: 7, intervals: const [
        CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 2,
          segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 10),
        CanonicalMediaBindingInterval(exactStart: 3, exactEndExclusive: 7,
          segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 20),
      ],
    );
    await service.artifactStore.persistCanonicalMediaProjection(projection);
    expect(await service.artifactCacheManager.bindPhysicalArtifact(
      physicalId: PhysicalMediaId.canonical(projection.coordinateForPageIndex(5).stableKey),
      sourceId: oldId), isTrue);
    for (final (page, length) in [(3, 9), (6, 7)]) {
      await index.putPhysicalPartial(PhysicalPartialRecord(
        id: PhysicalMediaId.canonical(projection.coordinateForPageIndex(page).stableKey),
        path: '${root.path}/partial-$page', bytes: length, checksum: '12345678',
        createdUs: 1, touchedUs: 1));
    }
    await index.putPhysicalPartial(PhysicalPartialRecord(
      id: PhysicalMediaId.canonical(CanonicalMediaCoordinate(
        familyId: projection.familyId, chapterId: projection.canonicalChapterId,
        segmentId: const CanonicalMediaSegmentId('segment'), offset: 99).stableKey),
      path: '${root.path}/outside', bytes: 999, checksum: '12345678',
      createdUs: 1, touchedUs: 1));
    final placeholders = legacy.chapter.toManifest();
    final registry = service.transferRuntime.registry;
    final anchor = registry.get(readerPageDownloadId(oldManifest,
      oldManifest.pages.single));
    registry.aliasPhysical(id: readerPageDownloadId(placeholders, placeholders.pages[6]),
      target: anchor.id);
    final run = anchor.beginRun();
    addTearDown(() => anchor.endRun(run));
    final failed = registry.get(readerPageDownloadId(placeholders, placeholders.pages[2]));
    await failed.failWithoutWriter(const Failure(code: ErrorCode.network, message: 'fixture failure'));

    Future<void> compare({required int completed}) async {
      final expected = (await service.inspectMany([legacy])).single;
      final actual = (await service.inspectMany([summary])).single;
      expect(actual.completedPages, completed);
      expect(actual.completedPages, expected.completedPages);
      expect(actual.exactCompletedPages, 2);
      expect(actual.pinnedPages, 1);
      expect(actual.receivedBytes, expected.receivedBytes);
      expect(actual.receivedBytes, completed * bytes.length + 9);
      expect(actual.totalBytes, expected.totalBytes);
      expect(actual.pageProgressUnits, expected.pageProgressUnits);
      expect(actual.phase, ChapterDownloadPhase.failed);
      expect(actual.failure, expected.failure);
      final event = trace.events.lastWhere((event) =>
        event.payload['stage'] == 'targeted-projection-built');
      expect(event.payload['projectedPageSlots'], completed == 4 ? 7 : 6);
    }
    await compare(completed: 4);
    service.updateVersionBaselines([]);
    await compare(completed: 3);
    final changedCount = ImportedLibraryEntry(chapter: ImportedChapterRecord.fromSummaryJson(
      summary.chapter.toSummaryJson()..['pageCount'] = 8));
    final unbound = (await service.inspectMany([changedCount])).single;
    expect(unbound.completedPages, 2);
    expect(unbound.receivedBytes, 2 * bytes.length);
    final changedRevision = ImportedLibraryEntry(chapter: summary.chapter.copyWith(sourceRevision: 'r2'));
    final unrelated = (await service.inspectMany([changedRevision])).single;
    expect(unrelated.completedPages, 0);
    expect(unrelated.receivedBytes, 0);
    expect(unrelated.phase, ChapterDownloadPhase.idle);
  });
}
