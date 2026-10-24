import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('E-Hentai version URLs reuse only matching unique image keys', () async {
    final oldChapter = _chapter(
      comicId: 'https://e-hentai.org/g/1/old/',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/1-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'https://e-hentai.org/g/2/new/',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
        'https://e-hentai.org/s/cccccccccccccccc/2-2',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.first);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.first);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final cache = ArtifactCacheManager(backend: backend);

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.mappings, <DownloadId, DownloadId>{newId: oldId});
    expect(plan.registerEquivalences(cache), 1);
    expect((await cache.readForeground(newId))?.bytes, <int>[1, 2, 3]);
  });

  test('equivalence registration is independent of current artifact existence',
      () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/1-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
        'https://e-hentai.org/s/bbbbbbbbbbbbbbbb/2-2',
      ],
    );
    final oldFirst = readerPageDownloadId(oldChapter, oldChapter.pages.first);
    final newFirst = readerPageDownloadId(newChapter, newChapter.pages.first);
    final newSecond = readerPageDownloadId(newChapter, newChapter.pages.last);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{
        oldFirst: Uint8List.fromList(<int>[7, 7, 7]),
      }),
    );
    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.registerEquivalences(cache), 2);
    expect((await cache.readForeground(newFirst))?.bytes, <int>[7, 7, 7]);
    expect(await cache.readForeground(newSecond), isNull);
  });

  test('version migration materializes verified artifacts under target keys',
      () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.single);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.single);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldId: Uint8List.fromList(<int>[4, 5, 6]),
    });
    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(
      await plan.materializeTargetArtifacts(
        ArtifactCacheManager(backend: backend),
      ),
      1,
    );

    final reopened = ArtifactCacheManager(backend: backend);
    expect((await reopened.readForeground(newId))?.bytes, <int>[4, 5, 6]);
    expect(await reopened.lookupAuthoritative(oldId), isNotNull);
  });

  test('persistent migration binds verified artifact without body copy and survives reopen',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-zero-copy-version-migration-',
    );
    addTearDown(() => root.delete(recursive: true));
    final recordingBytes = _RecordingArtifactBytes();
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: recordingBytes,
    );
    addTearDown(store.close);
    final cache = ArtifactCacheManager(backend: store);
    final oldChapter = _chapter(
      comicId: 'persistent-old',
      revision: 'old',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newChapter = _chapter(
      comicId: 'persistent-new',
      revision: 'new',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final oldId = readerPageDownloadId(oldChapter, oldChapter.pages.single);
    final newId = readerPageDownloadId(newChapter, newChapter.pages.single);
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    await cache.storePromotedArtifact(id: oldId, bytes: bytes);
    var source = await store.index.get(oldId.key);
    expect(source, isNotNull);
    await store.index.put(source!.copyWith(pinned: true));
    source = await store.index.get(oldId.key);
    recordingBytes.resetReadCounters();

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );
    expect(await plan.materializeTargetArtifacts(cache), 1);

    final target = await store.index.get(newId.key);
    expect(target, isNotNull);
    expect(source!.pinned, isTrue);
    expect(target!.pinned, isFalse,
        reason: 'target cache reuse must not inherit source offline retention');
    expect(target.effectiveArtifactId, source.effectiveArtifactId);
    expect(target.path, source.path);
    expect(
      await store.artifactReplicasFor(newId),
      hasLength(1),
      reason: 'target exact identity must not create a second body replica',
    );
    expect(recordingBytes.existsCalls, greaterThan(0));
    expect(recordingBytes.lengthCalls, greaterThan(0));
    expect(recordingBytes.readChunkCalls, 0,
        reason: 'migration preflight may stat but must not read the body');
    expect(recordingBytes.readBytes, 0);

    await store.close();
    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(reopened.close);
    final reopenedCache = ArtifactCacheManager(backend: reopened);
    final lookup = await reopenedCache.lookupAuthoritative(newId);
    expect(lookup, isNotNull);
    expect(lookup!.storageId, newId,
        reason: 'the target is now its own exact durable logical authority');
    expect((await reopenedCache.readForeground(newId))?.bytes, bytes);

    final replacement = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x18, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c,
    ]);
    await reopenedCache.storePromotedArtifact(id: newId, bytes: replacement);
    final reboundSource = await reopened.index.get(oldId.key);
    final reboundTarget = await reopened.index.get(newId.key);
    expect(reboundSource, isNotNull);
    expect(reboundTarget, isNotNull);
    expect(reboundTarget!.effectiveArtifactId,
        isNot(reboundSource!.effectiveArtifactId),
        reason: 'a later exact target write must detach from shared authority');
    expect((await reopenedCache.readForeground(oldId))?.bytes, bytes);
    expect((await reopenedCache.readForeground(newId))?.bytes, replacement);
  });

  test(
    'physical artifact binding survives exact carrier removal and cold reopen',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-physical-artifact-reopen-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'physical-source-a',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u00003',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52,
        0x49,
        0x46,
        0x46,
        0x18,
        0x00,
        0x00,
        0x00,
        0x57,
        0x45,
        0x42,
        0x50,
        0x56,
        0x50,
        0x38,
        0x20,
      ]);

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(
          physicalId: physical,
          sourceId: exact,
        ),
        isTrue,
      );
      final physicalEntry = await cache.openPhysicalArtifact(physical);
      expect(physicalEntry, isNotNull);
      expect(await physicalEntry!.readAll!(), bytes);

      await store.index.remove(exact.key);
      expect(await store.index.get(exact.key), isNull);
      await store.close();

      final reopened = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(reopened.close);
      final reopenedCache = ArtifactCacheManager(backend: reopened);
      final reopenedPhysical =
          await reopenedCache.openPhysicalArtifact(physical);
      expect(reopenedPhysical, isNotNull);
      expect(await reopenedPhysical!.readAll!(), bytes);
    },
  );

  test(
    'physical READY binding retires an older physical partial',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-physical-ready-retires-partial-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'physical-ready-retires-partial',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/abababababababab/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000041',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      ]);

      await store.storePhysicalPartialDownload(
        physicalId: physical,
        providerHint: exact,
        preferDirectStaging: true,
        entry: PartialDownloadEntry(
          length: bytes.lengthInBytes,
          totalLength: bytes.lengthInBytes * 2,
          validators: const Validators(),
          open: ({required int start}) =>
              Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
        ),
      );
      final partialIndex = store.index as PhysicalPartialIndex;
      final oldPartial = await partialIndex.getPhysicalPartial(physical);
      expect(oldPartial, isNotNull);
      expect(await File(oldPartial!.path).exists(), isTrue);

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(
          physicalId: physical,
          sourceId: exact,
        ),
        isTrue,
      );

      for (var attempt = 0; attempt < 100; attempt++) {
        if (await partialIndex.getPhysicalPartial(physical) == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await partialIndex.getPhysicalPartial(physical), isNull);
      expect(await File(oldPartial.path).exists(), isFalse);
      expect(await cache.openPhysicalArtifact(physical), isNotNull);
    },
  );

  test(
    'opening physical READY retires a historical stale partial row',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-physical-ready-stale-partial-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'physical-ready-stale-partial',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/cdcdcdcdcdcdcdcd/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000042',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      ]);

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(
          physicalId: physical,
          sourceId: exact,
        ),
        isTrue,
      );
      final exactRecord = await store.index.get(exact.key);
      expect(exactRecord, isNotNull);
      final staleArtifact = store.layout.artifactForPhysical(physical);
      await File(staleArtifact.partialPath).parent.create(recursive: true);
      await File(staleArtifact.partialPath).writeAsBytes(bytes);
      final partialIndex = store.index as PhysicalPartialIndex;
      await partialIndex.putPhysicalPartial(
        PhysicalPartialRecord(
          id: physical,
          path: staleArtifact.partialPath,
          bytes: bytes.lengthInBytes,
          checksum: exactRecord!.checksum,
          createdUs: 1,
          touchedUs: 2,
          storageRootId: store.layout.root,
        ),
      );

      final ready = await cache.openPhysicalArtifact(physical);
      expect(ready, isNotNull);
      expect(await ready!.readAll!(), bytes);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (await partialIndex.getPhysicalPartial(physical) == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await partialIndex.getPhysicalPartial(physical), isNull);
      expect(await File(staleArtifact.partialPath).exists(), isFalse);
      expect(await cache.openPhysicalArtifact(physical), isNotNull);
    },
  );

  test(
    'physical partial read defers READY overlap cleanup to persistent maintenance',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-ready-partial-read-defers-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final readScheduler = ArtifactCacheReadScheduler();
      final writeScheduler = StorageWriteScheduler(
        localReadScheduler: readScheduler,
      );
      final store = await PersistentDownloadArtifactStore.open(
        root.path,
        storageWriteScheduler: writeScheduler,
      );
      addTearDown(store.close);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'ready-partial-read-defers-cleanup',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/fefefefefefefefe/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000045',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      ]);

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      final exactRecord = await store.index.get(exact.key);
      expect(exactRecord, isNotNull);
      final artifactIndex = store.index as PhysicalMediaArtifactIndex;
      await artifactIndex.putPhysicalMediaArtifactBinding(
        id: physical,
        artifactId: exactRecord!.effectiveArtifactId,
        createdUs: 1,
        touchedUs: 1,
      );

      final stale = store.layout.artifactForPhysical(physical);
      await File(stale.partialPath).parent.create(recursive: true);
      await File(stale.partialPath).writeAsBytes(bytes);
      final partialIndex = store.index as PhysicalPartialIndex;
      await partialIndex.putPhysicalPartial(
        PhysicalPartialRecord(
          id: physical,
          path: stale.partialPath,
          bytes: bytes.lengthInBytes,
          checksum: exactRecord.checksum,
          createdUs: 1,
          touchedUs: 2,
          storageRootId: store.layout.root,
        ),
      );
      final blocker = await writeScheduler.acquireQuantum();

      final opened = await store.openPhysicalPartialDownload(
        physicalId: physical,
        requestId: exact,
      );
      expect(opened, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(await partialIndex.getPhysicalPartial(physical), isNotNull);
      expect(await File(stale.partialPath).exists(), isTrue);
      expect(writeScheduler.pendingCount, 1,
          reason: 'read path must delegate cleanup through storage maintenance');

      blocker.release();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (await partialIndex.getPhysicalPartial(physical) == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await partialIndex.getPhysicalPartial(physical), isNull);
      expect(await File(stale.partialPath).exists(), isFalse);
      expect(await cache.openPhysicalArtifact(physical), isNotNull);
    },
  );

  test(
    'cold store open sweeps historical READY plus physical-partial overlap',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-physical-ready-cold-overlap-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'physical-ready-cold-overlap',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/efefefefefefefef/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000043',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
        0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
      ]);

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(
          physicalId: physical,
          sourceId: exact,
        ),
        isTrue,
      );
      final exactRecord = await store.index.get(exact.key);
      expect(exactRecord, isNotNull);
      final dbPath = store.layout.dbPath;
      final staleArtifact = store.layout.artifactForPhysical(physical);
      await store.close();

      await File(staleArtifact.partialPath).parent.create(recursive: true);
      await File(staleArtifact.partialPath).writeAsBytes(bytes);
      final seeded = SqliteIndex(dbPath);
      await seeded.open();
      await seeded.putPhysicalPartial(
        PhysicalPartialRecord(
          id: physical,
          path: staleArtifact.partialPath,
          bytes: bytes.lengthInBytes,
          checksum: exactRecord!.checksum,
          createdUs: 1,
          touchedUs: 2,
          storageRootId: root.path,
        ),
      );
      expect(await seeded.getPhysicalMediaArtifact(physical), isNotNull);
      await seeded.close();

      final reopened = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(reopened.close);
      final partialIndex = reopened.index as PhysicalPartialIndex;
      for (var attempt = 0; attempt < 100; attempt++) {
        if (await partialIndex.getPhysicalPartial(physical) == null) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(await partialIndex.getPhysicalPartial(physical), isNull);
      expect(await File(staleArtifact.partialPath).exists(), isFalse);
      expect(
        await (reopened.index as PhysicalMediaArtifactIndex)
            .getPhysicalMediaArtifact(physical),
        isNotNull,
      );
    },
  );

  test(
    'READY dominates same-key physical partial in usage trim and clear',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-ready-dominates-partial-maintenance-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      final cache = ArtifactCacheManager(backend: store);
      final chapter = _chapter(
        comicId: 'ready-dominates-partial-maintenance',
        revision: 'a',
        urls: const <String>['https://e-hentai.org/s/edededededededed/1-1'],
      );
      final exact = readerPageDownloadId(chapter, chapter.pages.single);
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000044',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(64, (index) => index),
      );

      await cache.storePromotedArtifact(id: exact, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(
          physicalId: physical,
          sourceId: exact,
        ),
        isTrue,
      );
      final baseline = await store.inspectArtifacts();
      expect(baseline.bytes, bytes.lengthInBytes);
      expect(baseline.entries, 2);

      final exactRecord = await store.index.get(exact.key);
      expect(exactRecord, isNotNull);
      final stale = store.layout.artifactForPhysical(physical);
      await File(stale.partialPath).parent.create(recursive: true);
      await File(stale.partialPath).writeAsBytes(bytes);
      final partialIndex = store.index as PhysicalPartialIndex;
      await partialIndex.putPhysicalPartial(
        PhysicalPartialRecord(
          id: physical,
          path: stale.partialPath,
          bytes: bytes.lengthInBytes,
          checksum: exactRecord!.checksum,
          createdUs: 1,
          touchedUs: 2,
          storageRootId: store.layout.root,
        ),
      );

      final overlapped = await store.inspectArtifacts();
      expect(overlapped.bytes, baseline.bytes);
      expect(overlapped.entries, baseline.entries);

      final trim = await store.trimArtifacts(
        maxBytes: baseline.bytes,
        targetBytes: 0,
      );
      expect(trim.beforeBytes, baseline.bytes);
      expect(trim.releasedBytes, 0);
      expect(trim.evictedEntries, 0);
      expect(await partialIndex.getPhysicalPartial(physical), isNotNull);
      expect(await File(stale.partialPath).exists(), isTrue);
      expect(await cache.openPhysicalArtifact(physical), isNotNull);

      final clear = await store.clearArtifacts();
      expect(clear.beforeBytes, baseline.bytes);
      expect(clear.releasedBytes, baseline.bytes);
      expect(clear.remainingBytes, 0);
      expect(clear.evictedEntries, 1);
      expect(await partialIndex.getPhysicalPartial(physical), isNull);
      expect(await File(stale.partialPath).exists(), isFalse);
      expect(await cache.openPhysicalArtifact(physical), isNull);
    },
  );

  test('physical-only immutable artifact participates in cache clear',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-physical-artifact-maintenance-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final cache = ArtifactCacheManager(backend: store);
    final chapter = _chapter(
      comicId: 'physical-maintenance-clear',
      revision: 'a',
      urls: const <String>['https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1'],
    );
    final exact = readerPageDownloadId(chapter, chapter.pages.single);
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000037',
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    await cache.storePromotedArtifact(id: exact, bytes: bytes);
    expect(
      await cache.bindPhysicalArtifact(
        physicalId: physical,
        sourceId: exact,
      ),
      isTrue,
    );
    await store.index.remove(exact.key);

    final usage = await store.inspectArtifacts();
    expect(usage.bytes, bytes.lengthInBytes);
    expect(usage.entries, 1);
    final report = await store.clearArtifacts();
    expect(report.releasedBytes, bytes.lengthInBytes);
    expect(report.remainingBytes, 0);
    expect(report.evictedEntries, 1);
    expect(await cache.openPhysicalArtifact(physical), isNull);
  });

  test('physical clear persists cleanup debt when replica delete fails',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-physical-artifact-cleanup-debt-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final failingBytes = _FailDeleteOnceArtifactBytes();
    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: failingBytes,
    );
    final cache = ArtifactCacheManager(backend: store);
    final chapter = _chapter(
      comicId: 'physical-maintenance-cleanup-debt',
      revision: 'a',
      urls: const <String>['https://e-hentai.org/s/dddddddddddddddd/1-1'],
    );
    final exact = readerPageDownloadId(chapter, chapter.pages.single);
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000040',
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    await cache.storePromotedArtifact(id: exact, bytes: bytes);
    final exactRecord = await store.index.get(exact.key);
    expect(exactRecord, isNotNull);
    final oldBody = File(exactRecord!.path);
    expect(
      await cache.bindPhysicalArtifact(
        physicalId: physical,
        sourceId: exact,
      ),
      isTrue,
    );
    await store.index.remove(exact.key);
    failingBytes.failDeletePath = oldBody.path;

    final report = await store.clearArtifacts();
    expect(report.releasedBytes, bytes.lengthInBytes);
    expect(report.remainingBytes, 0);
    expect(await cache.openPhysicalArtifact(physical), isNull);
    expect(await oldBody.exists(), isTrue,
        reason: 'failed post-retirement unlink must be durable cleanup debt');
    final debtIndex = SqliteIndex(store.layout.dbPath);
    await debtIndex.open();
    final debt = (await debtIndex.listStorageCleanupDebts()).single;
    expect(debt.kind, StorageCleanupDebtKind.obsoleteSealedSource);
    expect(debt.accessLocator, oldBody.path);
    expect(debt.expectedBytes, bytes.lengthInBytes);
    await debtIndex.close();
    await store.close();

    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    await reopened.close();
    expect(await oldBody.exists(), isFalse);
    final checked = SqliteIndex(store.layout.dbPath);
    await checked.open();
    expect(await checked.listStorageCleanupDebts(), isEmpty);
    await checked.close();
  });

  test('physical-only immutable artifact participates in capacity trim',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-physical-artifact-trim-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final cache = ArtifactCacheManager(backend: store);
    final chapter = _chapter(
      comicId: 'physical-maintenance-trim',
      revision: 'a',
      urls: const <String>['https://e-hentai.org/s/bbbbbbbbbbbbbbbb/1-1'],
    );
    final exact = readerPageDownloadId(chapter, chapter.pages.single);
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000038',
    );
    final bytes = Uint8List.fromList(List<int>.generate(64, (index) => index));
    await cache.storePromotedArtifact(id: exact, bytes: bytes);
    expect(
      await cache.bindPhysicalArtifact(
        physicalId: physical,
        sourceId: exact,
      ),
      isTrue,
    );
    await store.index.remove(exact.key);

    final report = await store.trimArtifacts(maxBytes: 32, targetBytes: 0);
    expect(report.beforeBytes, bytes.lengthInBytes);
    expect(report.releasedBytes, bytes.lengthInBytes);
    expect(report.remainingBytes, 0);
    expect(report.evictedEntries, 1);
    expect(await cache.openPhysicalArtifact(physical), isNull);
  });

  test('clear keeps canonical physical owner when pinned exact survives',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-pinned-canonical-maintenance-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final cache = ArtifactCacheManager(backend: store);
    final chapter = _chapter(
      comicId: 'physical-maintenance-pinned',
      revision: 'a',
      urls: const <String>['https://e-hentai.org/s/cccccccccccccccc/1-1'],
    );
    final exact = readerPageDownloadId(chapter, chapter.pages.single);
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000039',
    );
    final bytes = Uint8List.fromList(List<int>.filled(48, 9));
    await cache.storePromotedArtifact(id: exact, bytes: bytes);
    final record = await store.index.get(exact.key);
    expect(record, isNotNull);
    await store.index.put(record!.copyWith(pinned: true));
    expect(
      await cache.bindPhysicalArtifact(
        physicalId: physical,
        sourceId: exact,
      ),
      isTrue,
    );

    final usage = await store.inspectArtifacts();
    expect(usage.bytes, bytes.lengthInBytes,
        reason: 'canonical binding must not double-count one immutable body');
    expect(usage.entries, 2);
    final report = await store.clearArtifacts();
    expect(report.releasedBytes, 0);
    expect(report.remainingBytes, bytes.lengthInBytes);
    expect(report.evictedEntries, 0);
    expect(await store.index.get(exact.key), isNotNull);
    expect(await cache.openPhysicalArtifact(physical), isNotNull);
  });

  test('checksum reuse includes algorithm and normalizes digest case', () {
    final oldChapter = _chapter(
      comicId: 'old-checksum',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/old-page'],
      checksums: const <String?>['AaBbCcDd'],
      checksumAlgorithms: const <String?>['MD5'],
    );
    final sameAlgorithm = _chapter(
      comicId: 'new-checksum',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['aabbccdd'],
      checksumAlgorithms: const <String?>['md5'],
    );
    final differentAlgorithm = _chapter(
      comicId: 'new-checksum-sha',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['aabbccdd'],
      checksumAlgorithms: const <String?>['sha1'],
    );

    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: sameAlgorithm,
      ).mappings,
      hasLength(1),
    );
    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: differentAlgorithm,
      ).mappings,
      isEmpty,
    );
    expect(
      verifiedPageIdentity(oldChapter.pages.single),
      'checksum:md5:aabbccdd',
    );
  });

  test('untyped checksums never create reuse aliases', () {
    final oldChapter = _chapter(
      comicId: 'old-untyped-checksum',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/old-page'],
      checksums: const <String?>['same-token'],
    );
    final newChapter = _chapter(
      comicId: 'new-untyped-checksum',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/new-page'],
      checksums: const <String?>['same-token'],
    );

    expect(
      VerifiedArtifactReusePlan.match(
        oldChapter: oldChapter,
        newChapter: newChapter,
      ).mappings,
      isEmpty,
    );
  });

  test('page index or title similarity alone never creates reuse aliases', () {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>['https://cdn.invalid/version-old/page-1.jpg'],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>['https://cdn.invalid/version-new/page-1.jpg'],
    );

    final plan = VerifiedArtifactReusePlan.match(
      oldChapter: oldChapter,
      newChapter: newChapter,
    );

    expect(plan.mappings, isEmpty);
  });

  test('resolved anchor identities prepare temporary offset aliases', () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'venera-resource:old-0',
        'venera-resource:old-1',
        'venera-resource:old-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:new-0',
        'venera-resource:new-1',
        'venera-resource:new-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:old-0': 'eh:a',
      'venera-resource:old-1': 'eh:b',
      'venera-resource:old-2': 'eh:c',
      'venera-resource:new-0': 'eh:a',
      'venera-resource:new-1': 'eh:b',
      'venera-resource:new-2': 'eh:c',
    };

    final plan = await VerifiedArtifactReusePlan.matchResolvedOffset(
      oldChapter: oldChapter,
      newChapter: newChapter,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(plan.mappings, hasLength(3));
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[1])],
      readerPageDownloadId(oldChapter, oldChapter.pages[0]),
    );
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[2])],
      readerPageDownloadId(oldChapter, oldChapter.pages[1]),
      reason: 'accepted affine offset aliases the whole VibeVenera overlap',
    );
    expect(
      plan.mappings[readerPageDownloadId(newChapter, newChapter.pages[3])],
      readerPageDownloadId(oldChapter, oldChapter.pages[2]),
    );
  });

  test('resolved related reuse is bidirectional across an inserted page',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:newer-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:older-0': 'eh:a',
      'venera-resource:older-1': 'eh:b',
      'venera-resource:older-2': 'eh:c',
      'venera-resource:newer-0': 'eh:a',
      'venera-resource:newer-1': 'eh:b',
      'venera-resource:newer-2': 'eh:c',
    };

    final plan = await VerifiedArtifactReusePlan.matchResolvedRelated(
      sourceChapter: newer,
      targetChapter: older,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(plan.mappings, hasLength(3));
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages.first)],
      readerPageDownloadId(newer, newer.pages[1]),
    );
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages[1])],
      readerPageDownloadId(newer, newer.pages[2]),
      reason: 'accepted affine offset aliases the whole reverse overlap',
    );
    expect(
      plan.mappings[readerPageDownloadId(older, older.pages.last)],
      readerPageDownloadId(newer, newer.pages[3]),
    );
  });

  test('reverse proof registration reuses one symmetric equivalence edge',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/1-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'https://e-hentai.org/s/aaaaaaaaaaaaaaaa/2-1',
      ],
    );
    final olderId = readerPageDownloadId(older, older.pages.single);
    final newerId = readerPageDownloadId(newer, newer.pages.single);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{
        olderId: Uint8List.fromList(<int>[9, 9, 9]),
      }),
    );
    final forward = VerifiedArtifactReusePlan.match(
      oldChapter: older,
      newChapter: newer,
    );
    final reverse = VerifiedArtifactReusePlan.match(
      oldChapter: newer,
      newChapter: older,
    );

    expect(forward.registerEquivalences(cache), 1);
    expect(reverse.registerEquivalences(cache), 1);
    expect(cache.equivalenceCount, 1);
    expect((await cache.readForeground(newerId))?.bytes, <int>[9, 9, 9]);
  });

  test('persisted verified offset restores aliases without a resolver', () {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
      ],
    );

    final forward = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: older,
      targetChapter: newer,
      targetOffsetFromSource: 1,
      verifiedSourceIndexes: const <int>[0, 1],
    );
    final reverse = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: newer,
      targetChapter: older,
      targetOffsetFromSource: -1,
      verifiedSourceIndexes: const <int>[1, 2],
    );

    expect(forward.mappings, hasLength(2));
    expect(reverse.mappings, hasLength(2));
    expect(
      forward.mappings[readerPageDownloadId(newer, newer.pages[1])],
      readerPageDownloadId(older, older.pages[0]),
    );
    expect(
      reverse.mappings[readerPageDownloadId(older, older.pages[0])],
      readerPageDownloadId(newer, newer.pages[1]),
    );
  });

  test('compact persisted offset resolves only queried target pages', () async {
    final older = _chapter(
      comicId: 'older-compact',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer-compact',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final oldSecond = readerPageDownloadId(older, older.pages[1]);
    final newSecond = readerPageDownloadId(newer, newer.pages[2]);
    final backend = _Backend(<DownloadId, Uint8List>{
      oldSecond: Uint8List.fromList(<int>[4, 2]),
    });
    final cache = ArtifactCacheManager(backend: backend);
    final resolver = VerifiedArtifactReuseResolver(targetChapter: newer);

    expect(
      resolver.addVerifiedOffset(
        sourceChapter: older,
        targetOffsetFromSource: 1,
        verifiedSourceIndexes: const <int>[0, 1, 2],
      ),
      3,
    );
    cache.registerEquivalentResolver(
      key: 'newer-compact',
      resolver: resolver.resolve,
    );

    expect(resolver.relationCount, 1);
    expect(resolver.eligiblePageCount, 3);
    expect(cache.equivalenceCount, 0,
        reason: 'compact relations must not materialize page-pair edges');
    expect(cache.directEquivalents(newSecond), <DownloadId>[oldSecond]);
    expect((await cache.readForeground(newSecond))?.bytes, <int>[4, 2]);
    expect(
      cache.directEquivalents(
        DownloadId(
          content: newSecond.content,
          sourceRevision: newSecond.sourceRevision,
          canonicalUri: Uri.parse('venera-resource:changed'),
        ),
      ),
      isEmpty,
      reason: 'the current target identity must still match exactly',
    );
  });

  test('compact related proof returns an affine offset without page pairs',
      () async {
    final older = _chapter(
      comicId: 'older-proof',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
        'venera-resource:older-2',
      ],
    );
    final newer = _chapter(
      comicId: 'newer-proof',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
        'venera-resource:newer-2',
      ],
    );
    final identities = <String, String>{
      'venera-resource:older-0': 'eh:a',
      'venera-resource:older-1': 'eh:b',
      'venera-resource:older-2': 'eh:c',
      'venera-resource:newer-0': 'eh:a',
      'venera-resource:newer-1': 'eh:b',
      'venera-resource:newer-2': 'eh:c',
    };

    final proof = await VerifiedArtifactReusePlan.matchResolvedRelatedOffset(
      sourceChapter: older,
      targetChapter: newer,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );

    expect(proof?.targetOffsetFromSource, 1);
    expect(proof?.verifiedSourceIndexes, <int>[0, 1, 2]);
  });

  test('persisted offset registers symmetric future-artifact equivalence',
      () async {
    final older = _chapter(
      comicId: 'older',
      revision: 'older',
      urls: const <String>[
        'venera-resource:older-0',
        'venera-resource:older-1',
      ],
    );
    final newer = _chapter(
      comicId: 'newer',
      revision: 'newer',
      urls: const <String>[
        'venera-resource:new-cover',
        'venera-resource:newer-0',
        'venera-resource:newer-1',
      ],
    );
    final oldFirst = readerPageDownloadId(older, older.pages.first);
    final newFirst = readerPageDownloadId(newer, newer.pages[1]);
    final cache = ArtifactCacheManager(
      backend: _Backend(<DownloadId, Uint8List>{}),
    );
    final plan = VerifiedArtifactReusePlan.fromVerifiedOffset(
      sourceChapter: older,
      targetChapter: newer,
      targetOffsetFromSource: 1,
      verifiedSourceIndexes: const <int>[0, 1],
    );

    expect(plan.registerEquivalences(cache), 2);
    expect(cache.equivalenceCount, 2);
    expect(await cache.lookup(oldFirst), isNull);

    await cache.storePromotedArtifact(
      id: newFirst,
      bytes: Uint8List.fromList(<int>[6, 6, 6]),
    );
    expect((await cache.readForeground(oldFirst))?.bytes, <int>[6, 6, 6]);
  });

  test('VibeVenera 2-of-3 anchors authorize the affine overlap', () async {
    final source = _chapter(
      comicId: 'source-middle-proof',
      revision: 'source',
      urls: const <String>[
        'venera-resource:source-a',
        'venera-resource:source-b',
        'venera-resource:source-c',
      ],
    );
    final target = _chapter(
      comicId: 'target-middle-proof',
      revision: 'target',
      urls: const <String>[
        'venera-resource:target-a',
        'venera-resource:target-x',
        'venera-resource:target-c',
      ],
    );
    final identities = <String, String>{
      'venera-resource:source-a': 'media:a',
      'venera-resource:source-b': 'media:b',
      'venera-resource:source-c': 'media:c',
      'venera-resource:target-a': 'media:a',
      'venera-resource:target-x': 'media:x',
      'venera-resource:target-c': 'media:c',
    };

    final proof = await VerifiedArtifactReusePlan.matchResolvedRelatedOffset(
      sourceChapter: source,
      targetChapter: target,
      resolveIdentity: (page) async => identities[page.uri.toString()],
    );
    expect(proof?.targetOffsetFromSource, 0);
    expect(proof?.verifiedSourceIndexes, <int>[0, 2]);

    final resolver = VerifiedArtifactReuseResolver(targetChapter: target);
    resolver.addVerifiedOffset(
      sourceChapter: source,
      targetOffsetFromSource: proof!.targetOffsetFromSource,
      verifiedSourceIndexes: proof.verifiedSourceIndexes,
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages.first)),
      <DownloadId>[readerPageDownloadId(source, source.pages.first)],
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages[1])),
      <DownloadId>[readerPageDownloadId(source, source.pages[1])],
      reason: 'two matching anchors authorize the whole affine overlap',
    );
    expect(
      resolver.resolve(readerPageDownloadId(target, target.pages.last)),
      <DownloadId>[readerPageDownloadId(source, source.pages.last)],
    );
  });

  test(
    'version resolver requires a validated non-identity page index hint',
    () {
      final source = _chapter(
        comicId: 'source-hint',
        revision: 'source-hint-r1',
        urls: const <String>[
          'https://example.test/source-0.webp',
          'https://example.test/source-1.webp',
        ],
      );
      final target = _chapter(
        comicId: 'target-hint',
        revision: 'target-hint-r1',
        urls: const <String>[
          'https://example.test/target-0.webp',
          'https://example.test/target-1.webp',
        ],
      );
      final resolver = VerifiedArtifactReuseResolver(targetChapter: target)
        ..addVerifiedInterval(
          sourceChapter: source,
          sourceStart: 0,
          sourceEndExclusive: 2,
          targetOffsetFromSource: 0,
        );
      final exact = readerPageDownloadId(target, target.pages[1]);
      final noHint = DownloadId(
        content: exact.content,
        sourceRevision: exact.sourceRevision,
        canonicalUri: exact.canonicalUri,
      );
      final wrongHint = DownloadId(
        content: exact.content,
        sourceRevision: exact.sourceRevision,
        canonicalUri: exact.canonicalUri,
        pageIndexHint: 0,
      );

      expect(resolver.resolve(noHint), isEmpty);
      expect(resolver.resolve(wrongHint), isEmpty);
      expect(resolver.resolve(exact), <DownloadId>[
        readerPageDownloadId(source, source.pages[1]),
      ]);
    },
  );

  test('verified affine intervals keep gaps and offset changes local', () {
    final predecessor = _chapter(
      comicId: 'interval-old',
      revision: 'interval-old-r1',
      urls: const <String>[
        'venera-resource:old-0',
        'venera-resource:old-1',
        'venera-resource:old-2',
        'venera-resource:old-3',
        'venera-resource:old-4',
        'venera-resource:old-5',
      ],
    );
    final successor = _chapter(
      comicId: 'interval-new',
      revision: 'interval-new-r1',
      urls: const <String>[
        'venera-resource:new-0',
        'venera-resource:new-1',
        'venera-resource:new-gap',
        'venera-resource:new-3',
        'venera-resource:new-4',
        'venera-resource:new-5',
        'venera-resource:new-6',
      ],
    );
    const intervals = <VerifiedComicVersionPageInterval>[
      VerifiedComicVersionPageInterval(
        predecessorStart: 0,
        predecessorEndExclusive: 2,
        successorOffset: 0,
      ),
      VerifiedComicVersionPageInterval(
        predecessorStart: 3,
        predecessorEndExclusive: 6,
        successorOffset: 1,
      ),
    ];

    final reverse = VerifiedArtifactReuseResolver(
      targetChapter: successor,
    );
    for (final interval in intervals) {
      reverse.addVerifiedInterval(
        sourceChapter: predecessor,
        sourceStart: interval.predecessorStart,
        sourceEndExclusive: interval.predecessorEndExclusive,
        targetOffsetFromSource: interval.successorOffset,
      );
    }
    expect(
      reverse.resolve(readerPageDownloadId(successor, successor.pages[1])),
      <DownloadId>[readerPageDownloadId(predecessor, predecessor.pages[1])],
    );
    expect(
      reverse.resolve(readerPageDownloadId(successor, successor.pages[2])),
      isEmpty,
      reason: 'the inserted successor page is outside every verified interval',
    );
    expect(
      reverse.resolve(readerPageDownloadId(successor, successor.pages[4])),
      <DownloadId>[readerPageDownloadId(predecessor, predecessor.pages[3])],
    );

    final forward = VerifiedArtifactReuseResolver.predecessorToSuccessor(
      predecessorChapter: predecessor,
      successorChapter: successor,
      verifiedIntervals: intervals,
    );
    expect(
      forward.resolve(readerPageDownloadId(predecessor, predecessor.pages[2])),
      isEmpty,
    );
    expect(
      forward.resolve(readerPageDownloadId(predecessor, predecessor.pages[5])),
      <DownloadId>[readerPageDownloadId(successor, successor.pages[6])],
    );
  });

  test(
    'bounded interval probe finds a middle insertion with constant budget',
    () async {
      final source = _chapter(
        comicId: 'binary-source-insert',
        revision: 'binary-source-insert-r1',
        urls: <String>[
          for (var index = 0; index < 8; index++)
            'venera-resource:source-insert-$index',
        ],
      );
      final target = _chapter(
        comicId: 'binary-target-insert',
        revision: 'binary-target-insert-r1',
        urls: <String>[
          for (var index = 0; index < 9; index++)
            'venera-resource:target-insert-$index',
        ],
      );
      final identities = <String, String>{
        for (var index = 0; index < 8; index++)
          'venera-resource:source-insert-$index': 'media:$index',
        for (var index = 0; index < 4; index++)
          'venera-resource:target-insert-$index': 'media:$index',
        'venera-resource:target-insert-4': 'media:inserted',
        for (var index = 5; index < 9; index++)
          'venera-resource:target-insert-$index': 'media:${index - 1}',
      };
      var resolveCalls = 0;
      final proof =
          await VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(
            sourceChapter: source,
            targetChapter: target,
            resolveIdentity: (page) async {
              resolveCalls++;
              return identities[page.uri.toString()];
            },
          );

      expect(proof, isNotNull);
      expect(proof!.probeCount, lessThanOrEqualTo(8));
      expect(resolveCalls, lessThanOrEqualTo(24));
      expect(
        proof.verifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 4, 0), (4, 8, 1)],
      );
    },
  );

  test(
    'bounded interval probe source work stays constant at 80k pages',
    () async {
      const pageCount = 80000;
      final source = _chapter(
        comicId: 'binary-source-80k',
        revision: 'binary-source-80k-r1',
        urls: <String>[
          for (var index = 0; index < pageCount; index++)
            'venera-resource:source-80k-$index',
        ],
      );
      final target = _chapter(
        comicId: 'binary-target-80k',
        revision: 'binary-target-80k-r1',
        urls: <String>[
          for (var index = 0; index < pageCount; index++)
            'venera-resource:target-80k-$index',
        ],
      );
      var resolveCalls = 0;
      final proof =
          await VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(
            sourceChapter: source,
            targetChapter: target,
            resolveIdentity: (page) async {
              resolveCalls++;
              final value = page.uri.toString();
              final index = int.parse(
                value.substring(value.lastIndexOf('-') + 1),
              );
              return 'media:$index';
            },
          );

      expect(proof, isNotNull);
      expect(proof!.probeCount, 3);
      expect(resolveCalls, 6);
      expect(proof.verifiedIntervals, hasLength(1));
      expect(proof.verifiedIntervals.single.predecessorStart, 0);
      expect(proof.verifiedIntervals.single.predecessorEndExclusive, pageCount);
      expect(proof.verifiedIntervals.single.successorOffset, 0);
    },
  );

  test(
    'bounded interval probe leaves a replacement as an unverified gap',
    () async {
      final source = _chapter(
        comicId: 'binary-source-replace',
        revision: 'binary-source-replace-r1',
        urls: <String>[
          for (var index = 0; index < 8; index++)
            'venera-resource:source-replace-$index',
        ],
      );
      final target = _chapter(
        comicId: 'binary-target-replace',
        revision: 'binary-target-replace-r1',
        urls: <String>[
          for (var index = 0; index < 8; index++)
            'venera-resource:target-replace-$index',
        ],
      );
      final identities = <String, String>{
        for (var index = 0; index < 8; index++)
          'venera-resource:source-replace-$index': 'media:$index',
        for (var index = 0; index < 8; index++)
          'venera-resource:target-replace-$index': index == 4
              ? 'media:replacement'
              : 'media:$index',
      };
      final proof =
          await VerifiedArtifactReusePlan.matchResolvedRelatedIntervals(
            sourceChapter: source,
            targetChapter: target,
            resolveIdentity: (page) async => identities[page.uri.toString()],
          );

      expect(proof, isNotNull);
      expect(proof!.probeCount, lessThanOrEqualTo(8));
      expect(
        proof.verifiedIntervals
            .map(
              (interval) => (
                interval.predecessorStart,
                interval.predecessorEndExclusive,
                interval.successorOffset,
              ),
            )
            .toList(),
        <(int, int, int)>[(0, 4, 0), (5, 8, 0)],
      );
    },
  );

  test('resolved offset requires verified anchor agreement', () async {
    final oldChapter = _chapter(
      comicId: 'old',
      revision: 'old',
      urls: const <String>[
        'venera-resource:old-0',
        'venera-resource:old-1',
        'venera-resource:old-2',
      ],
    );
    final newChapter = _chapter(
      comicId: 'new',
      revision: 'new',
      urls: const <String>[
        'venera-resource:new-0',
        'venera-resource:new-1',
        'venera-resource:new-2',
      ],
    );

    final plan = await VerifiedArtifactReusePlan.matchResolvedOffset(
      oldChapter: oldChapter,
      newChapter: newChapter,
      resolveIdentity: (page) async => page.uri.toString(),
    );

    expect(plan.mappings, isEmpty);
  });

  test(
    'persisted mappings are re-probed only when interval model is stale',
    () {
      const legacy = ComicVersionPageMapping(
        predecessorChapterId: 'old',
        successorChapterId: 'new',
        predecessorPageCount: 4,
        successorPageCount: 5,
        successorOffset: 1,
        verifiedPredecessorPageIndexes: <int>[0, 3],
      );
      const current = ComicVersionPageMapping(
        predecessorChapterId: 'old',
        successorChapterId: 'new',
        predecessorPageCount: 4,
        successorPageCount: 5,
        successorOffset: 1,
        verifiedPredecessorPageIndexes: <int>[0, 3],
        verifiedIntervals: <VerifiedComicVersionPageInterval>[
          VerifiedComicVersionPageInterval(
            predecessorStart: 0,
            predecessorEndExclusive: 2,
            successorOffset: 1,
          ),
        ],
        intervalProbeVersion: VerifiedArtifactReusePlan.intervalProbeVersion,
      );

      expect(VerifiedArtifactReusePlan.needsIntervalProbe(legacy), isTrue);
      expect(VerifiedArtifactReusePlan.needsIntervalProbe(current), isFalse);
      final expanded = current.recordVerifiedPageMatch(
        predecessorIndex: 3,
        successorIndex: 4,
      );
      expect(expanded.intervalProbeVersion, current.intervalProbeVersion);
    },
  );

  test('canonical projection survives reopen and rejects coordinate rebase',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-canonical-projection-',
    );
    addTearDown(() => root.delete(recursive: true));
    final original = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('chapter'),
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter-r1',
      sourceRevision: 'r1',
      pageCount: 8003,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 4000,
          segmentId: CanonicalMediaSegmentId('segment'),
          segmentStart: 0,
        ),
        CanonicalMediaBindingInterval(
          exactStart: 4003,
          exactEndExclusive: 8003,
          segmentId: CanonicalMediaSegmentId('segment'),
          segmentStart: 4000,
        ),
      ],
    );
    final first = await PersistentDownloadArtifactStore.open(root.path);
    await first.persistCanonicalMediaProjection(original);
    await first.close();

    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(reopened.close);
    final loaded = await reopened.loadCanonicalMediaProjections();
    expect(loaded, hasLength(1));
    final restored = loaded.single;
    expect(restored.exactKey, original.exactKey);
    expect(restored.coordinateForPageIndexOrNull(4000), isNull);
    expect(
      restored.coordinateForPageIndex(4003),
      original.coordinateForPageIndex(4003),
    );

    final rebased = restored.copyWithIntervals(
      const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 4000,
          segmentId: CanonicalMediaSegmentId('replacement-segment'),
          segmentStart: 0,
        ),
        CanonicalMediaBindingInterval(
          exactStart: 4003,
          exactEndExclusive: 8003,
          segmentId: CanonicalMediaSegmentId('segment'),
          segmentStart: 4000,
        ),
      ],
    );
    await expectLater(
      reopened.persistCanonicalMediaProjection(rebased),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );
    final afterRejectedWrite = await reopened.loadCanonicalMediaProjections();
    expect(
      afterRejectedWrite.single.coordinateForPageIndex(0),
      original.coordinateForPageIndex(0),
    );
  });

  test('canonical backfill migrates only active exact cache state', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-canonical-backfill-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final chapter = ChapterManifest(
      sourceId: 'venera:fixture',
      comicId: 'comic',
      chapter: const Chapter(
        chapterId: 'chapter',
        comicId: 'comic',
        title: 'Canonical backfill',
        sequence: 0,
        pageCount: 3,
        sourceRevision: 'r1',
      ),
      pages: <PageAsset>[
        for (var index = 0; index < 3; index++)
          PageAsset(
            pageId: 'page-$index',
            chapterId: 'chapter',
            index: index,
            uri: Uri.parse('venera-resource:backfill:$index'),
          ),
      ],
      readingDirection: ReadingDirection.vertical,
    );
    final projection = VersionChapterCanonicalProjection(
      familyId: const VersionFamilyId('family'),
      canonicalChapterId: const CanonicalChapterId('canonical-chapter'),
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: chapter.chapter.chapterId,
      sourceRevision: chapter.chapter.sourceRevision,
      pageCount: chapter.pages.length,
      intervals: const <CanonicalMediaBindingInterval>[
        CanonicalMediaBindingInterval(
          exactStart: 0,
          exactEndExclusive: 3,
          segmentId: CanonicalMediaSegmentId('segment'),
          segmentStart: 0,
        ),
      ],
    );
    final authority = CanonicalMediaChapterAuthority(
      manifest: chapter,
      projection: projection,
      activeProjectionRanges: const <CanonicalMediaActiveRange>[
        CanonicalMediaActiveRange(start: 0, endExclusive: 2),
      ],
    );
    final readyId = readerPageDownloadId(chapter, chapter.pages[0]);
    final activePartialId = readerPageDownloadId(chapter, chapter.pages[1]);
    final gapPartialId = readerPageDownloadId(chapter, chapter.pages[2]);
    final readyBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final activeBytes = Uint8List.fromList(<int>[5, 6, 7]);
    final gapBytes = Uint8List.fromList(<int>[8, 9]);

    await store.storePromotedArtifact(id: readyId, bytes: readyBytes);
    for (final entry in <(DownloadId, Uint8List)>[
      (activePartialId, activeBytes),
      (gapPartialId, gapBytes),
    ]) {
      await store.storePartialDownload(
        id: entry.$1,
        entry: PartialDownloadEntry(
          length: entry.$2.lengthInBytes,
          validators: const Validators(),
          totalLength: 12,
          open: ({required int start}) async* {
            yield Uint8List.sublistView(entry.$2, start);
          },
        ),
      );
    }

    expect(
      await store.backfillCanonicalReadyArtifacts(<CanonicalMediaChapterAuthority>[
        authority,
      ]),
      1,
    );
    final readyPhysical = PhysicalMediaId.canonical(
      projection.coordinateForPageIndex(0).stableKey,
    );
    expect((await store.openPhysicalArtifact(readyPhysical))?.length, readyBytes.lengthInBytes);

    expect(
      await store.backfillCanonicalPartials(<CanonicalMediaChapterAuthority>[
        authority,
      ]),
      1,
    );
    final activePhysical = PhysicalMediaId.canonical(
      projection.coordinateForPageIndex(1).stableKey,
    );
    expect(await store.index.get(activePartialId.key), isNull);
    expect(
      (await store.openPhysicalPartialDownload(
        physicalId: activePhysical,
        requestId: activePartialId,
      ))
          ?.length,
      activeBytes.lengthInBytes,
    );
    expect(
      (await store.index.get(gapPartialId.key))?.bytes,
      gapBytes.lengthInBytes,
      reason: 'inactive projection gaps must remain exact',
    );
  });

  for (final partial in <bool>[false, true]) {
    test('sparse canonical ${partial ? 'partial' : 'READY'} backfill validates current carriers', () async {
      final root = await Directory.systemTemp.createTemp('zic-sparse-backfill-');
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      final manifest = ChapterManifest(
        sourceId: 'venera:ehentai', comicId: 'current',
        chapter: const Chapter(chapterId: 'chapter', comicId: 'current',
          title: 'Sparse', sequence: 0, pageCount: 256, sourceRevision: 'r1'),
        pages: <PageAsset>[
          for (var index = 0; index < 256; index++)
            PageAsset(pageId: 'page-${index == 129 ? 7 : index}',
              chapterId: 'chapter', index: index,
              uri: Uri.parse('venera-resource:current-$index')),
        ],
        readingDirection: ReadingDirection.vertical,
      );
      final projection = VersionChapterCanonicalProjection(
        familyId: const VersionFamilyId('family'),
        canonicalChapterId: const CanonicalChapterId('canonical'),
        sourceId: manifest.sourceId, comicId: manifest.comicId,
        chapterId: manifest.chapter.chapterId, sourceRevision: 'r1', pageCount: 256,
        intervals: const <CanonicalMediaBindingInterval>[
          CanonicalMediaBindingInterval(exactStart: 0, exactEndExclusive: 256,
            segmentId: CanonicalMediaSegmentId('segment'), segmentStart: 0),
        ],
      );
      final authority = CanonicalMediaChapterAuthority(manifest: manifest,
        projection: projection, activeProjectionRanges: const [
          CanonicalMediaActiveRange(start: 0, endExclusive: 200),
        ]);
      DownloadId candidate(int index, {String? carrier, String? comic, String? revision}) =>
          DownloadId(content: ContentId(sourceId: manifest.sourceId,
              comicId: comic ?? manifest.comicId, chapterId: 'chapter',
              pageId: manifest.pages[index].pageId),
            sourceRevision: revision ?? 'r1',
            canonicalUri: carrier == null ? manifest.pages[index].uri : Uri.parse(carrier),
            pageIndexHint: 255);
      final valid = <DownloadId>[candidate(7), candidate(129)];
      final rejected = <DownloadId>[
        candidate(7, carrier: 'venera-resource:stale-carrier'),
        candidate(220),
        candidate(7, comic: 'other-version'),
        candidate(7, revision: 'old'),
      ];
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      for (final id in <DownloadId>[...valid, ...rejected]) {
        if (partial) {
          await store.storePartialDownload(id: id, entry: PartialDownloadEntry(
            length: bytes.length, validators: const Validators(), totalLength: 12,
            open: ({required int start}) async* { yield Uint8List.sublistView(bytes, start); },
          ));
        } else {
          await store.storePromotedArtifact(id: id, bytes: bytes);
        }
      }
      // Persisted identities deliberately omit execution-only page hints.
      await store.index.close();
      await store.index.open();
      expect((await store.index.get(valid.first.key))!.id.pageIndexHint, isNull);
      final migrated = partial
          ? await store.backfillCanonicalPartials([authority])
          : await store.backfillCanonicalReadyArtifacts([authority]);
      expect(migrated, 2);
      for (final index in <int>[7, 129]) {
        final physical = PhysicalMediaId.canonical(
          projection.coordinateForPageIndex(index).stableKey);
        final length = partial
            ? (await store.openPhysicalPartialDownload(physicalId: physical,
                requestId: readerPageDownloadId(manifest, manifest.pages[index])))?.length
            : (await store.openPhysicalArtifact(physical))?.length;
        expect(length, bytes.length);
        if (partial) expect(await store.index.get(candidate(index).key), isNull);
      }
      for (final id in rejected) {
        expect((await store.index.get(id.key))?.bytes, bytes.length,
          reason: 'pageId/hint must not override locator, revision, owner or active proof');
      }
      expect(await (store.index as PhysicalMediaArtifactIndex).getPhysicalMediaArtifact(
        PhysicalMediaId.canonical(projection.coordinateForPageIndex(220).stableKey)), isNull);
      expect(await (store.index as PhysicalPartialIndex).getPhysicalPartial(
        PhysicalMediaId.canonical(projection.coordinateForPageIndex(220).stableKey)), isNull);
    });
  }

  test('canonical backfill skips unrelated payloads', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-canonical-backfill-yield-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final chapter = _chapter(
      comicId: 'current',
      revision: 'r1',
      urls: <String>[
        'https://cdn.invalid/0123456789abcdef0123456789abcdef.jpg',
      ],
    );
    final authorities = <CanonicalMediaChapterAuthority>[
      CanonicalMediaChapterAuthority(manifest: chapter),
    ];
    for (final state in CacheState.values) {
      for (var index = 0; index < 128; index++) {
        await store.index.put(
          CacheRec(
            id: DownloadId(
              content: ContentId(
                sourceId: chapter.sourceId,
                comicId: 'unrelated',
                chapterId: 'old-chapter',
                pageId: '${state.name}-$index',
              ),
              sourceRevision: 'old',
              canonicalUri: Uri.parse('https://cdn.invalid/$index.jpg'),
            ),
            state: state,
            path: '${root.path}/${state.name}-$index',
            bytes: 4,
            checksum: '12345678',
            createdUs: 0,
            touchedUs: 0,
          ),
        );
      }
    }
    await store.index.close();
    await store.index.open();
    final db = sql.sqlite3.open(store.layout.dbPath);
    try {
      db.execute("UPDATE cache_entry SET download_json = 'malformed' "
          "WHERE comic_id = 'unrelated'");
    } finally {
      db.dispose();
    }
    for (final ready in <bool>[true, false]) {
      final migrated = ready
          ? await store.backfillCanonicalReadyArtifacts(authorities)
          : await store.backfillCanonicalPartials(authorities);
      expect(migrated, 0);
    }
  });

  test('resource reuse identity accepts only strong media keys', () {
    expect(
      verifiedComicResourceIdentity(
        Uri.parse('https://e-hentai.org/s/AaBbCc/1-1'),
      ),
      'eh:aabbcc',
    );
    expect(
      verifiedComicResourceIdentity(
        Uri.parse(
          'https://cdn.invalid/0123456789abcdef0123456789abcdef.jpg',
        ),
      ),
      'hash:0123456789abcdef0123456789abcdef',
    );
    expect(
      verifiedComicResourceIdentity(
        Uri.parse('https://cdn.invalid/page-1.jpg'),
      ),
      isNull,
    );
  });
}

ChapterManifest _chapter({
  required String comicId,
  required String revision,
  required List<String> urls,
  List<String?>? checksums,
  List<String?>? checksumAlgorithms,
}) {
  final chapterId = 'chapter-$revision';
  return ChapterManifest(
    sourceId: 'venera:ehentai',
    comicId: comicId,
    chapter: Chapter(
      chapterId: chapterId,
      comicId: comicId,
      title: 'Gallery',
      sequence: 0,
      pageCount: urls.length,
      sourceRevision: revision,
    ),
    pages: <PageAsset>[
      for (var index = 0; index < urls.length; index++)
        PageAsset(
          pageId: 'page-$index-$revision',
          chapterId: chapterId,
          index: index,
          uri: Uri.parse(urls[index]),
          checksum: checksums?[index],
          checksumAlgorithm: checksumAlgorithms?[index],
        ),
    ],
    readingDirection: ReadingDirection.vertical,
  );
}

final class _RecordingArtifactBytes implements ArtifactBytes {
  final ArtifactBytes _delegate = const LocalArtifactBytes();
  int existsCalls = 0;
  int lengthCalls = 0;
  int readChunkCalls = 0;
  int readBytes = 0;

  void resetReadCounters() {
    existsCalls = 0;
    lengthCalls = 0;
    readChunkCalls = 0;
    readBytes = 0;
  }

  @override
  Future<bool> exists(String path) {
    existsCalls++;
    return _delegate.exists(path);
  }

  @override
  Future<int> length(String path) {
    lengthCalls++;
    return _delegate.length(path);
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    readChunkCalls++;
    await for (final chunk in _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    )) {
      readBytes += chunk.lengthInBytes;
      yield chunk;
    }
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _FailDeleteOnceArtifactBytes implements ArtifactBytes {
  final ArtifactBytes _delegate = const LocalArtifactBytes();
  String? failDeletePath;
  bool _failed = false;

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<int> length(String path) => _delegate.length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) =>
      _delegate.readChunks(path, start: start, endExclusive: endExclusive);

  @override
  Future<void> delete(String path) async {
    if (!_failed && path == failDeletePath) {
      _failed = true;
      throw FileSystemException('simulated physical cleanup failure', path);
    }
    await _delegate.delete(path);
  }
}

final class _Backend implements ArtifactCacheBackend {
  _Backend(this.values);

  final Map<DownloadId, Uint8List> values;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async => bytes,
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    values.remove(id);
  }
}
