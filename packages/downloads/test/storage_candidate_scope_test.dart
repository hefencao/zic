import 'dart:async';
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
      expect(canonical.readyPages, 1);
      expect(canonical.partialPages, 1);
      expect(canonical.receivedBytes, bytes.length + 5);
      expect(canonical.manualReferencedPages, 1);
      final exactRemainder = cache.exact.singleWhere((r) => r.comicId == 'first');
      expect(exactRemainder.readyPages, 0,
        reason: 'same pageId with a stale carrier cannot become current READY');
      expect(exactRemainder.partialPages, 1);
      expect(exactRemainder.receivedBytes, 7);
      expect(cache.exact.singleWhere((r) => r.comicId == 'second').readyPages, 1);
      expect(cache.canonical.any((r) => r.familyId == staleSecondProjection.familyId), isTrue,
        reason: 'historical physical inventory stays visible independently of chapter shape');
    }
    expect(service.materializedSessionCount, sessionsBeforeInspection);
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
