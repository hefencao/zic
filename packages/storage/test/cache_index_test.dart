import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  runCacheSchemaV2Tests();

  final id = DownloadId(
    content: ContentId(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page',
    ),
    sourceRevision: 'r1',
    canonicalUri: Uri.parse('https://example.test/page.webp'),
  );

  for (final previousVersion in <int?>[null, 19]) {
    test('replica locator lookup uses an index after open from $previousVersion',
        () async {
      final dir = await Directory.systemTemp.createTemp('locator-index-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/cache.sqlite';
      final initial = SqliteIndex(path);
      await initial.open();
      final record = CacheRec(
        id: id,
        state: CacheState.ready,
        path: '${dir.path}/retained.bin',
        bytes: 11,
        checksum: 'abcd',
        createdUs: 1,
        touchedUs: 2,
      );
      await initial.put(record);
      await initial.close();
      if (previousVersion != null) {
        final legacy = sql.sqlite3.open(path);
        legacy.execute('DROP INDEX IF EXISTS artifact_replica_access_locator');
        legacy.execute('PRAGMA user_version = $previousVersion');
        legacy.dispose();
      }
      final reopened = SqliteIndex(path);
      await reopened.open();
      try {
        expect(await reopened.isStorageAccessLocatorAuthoritative(record.path),
            isTrue);
        expect(await reopened.isStorageAccessLocatorAuthoritative('/missing'),
            isFalse);
        expect((await reopened.get(id.key))?.checksum, record.checksum);
        final db = sql.sqlite3.open(path);
        try {
          final plan = db.select(
            'EXPLAIN QUERY PLAN SELECT 1 FROM artifact_replica '
            'WHERE access_locator = ? LIMIT 1', <Object?>[record.path],
          ).map((row) => row['detail']).join(' ');
          expect(plan, contains('SEARCH'));
          expect(plan, contains('artifact_replica_access_locator'));
          expect(plan, isNot(contains('SCAN')));
          expect(db.select('SELECT count(*) AS n FROM artifact_replica')
              .single['n'], 1);
        } finally {
          db.dispose();
        }
      } finally {
        await reopened.close();
      }
    });
  }

  test('sqlite maintenance removal is atomic against exact READY and touches',
      () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final physicalId = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000010',
    );
    final ready = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/maintenance-ready.bin',
      bytes: 11,
      checksum: 'abcd',
      createdUs: 1,
      touchedUs: 2,
      artifactId: 'maintenance-ready-object',
    );
    await index.put(ready);
    await index.putPhysicalMediaArtifactBinding(
      id: physicalId,
      artifactId: ready.artifactId,
      createdUs: 3,
      touchedUs: 4,
    );

    expect(
      await index.removePhysicalMediaArtifactBindingForMaintenance(
        id: physicalId,
        expectedArtifactId: ready.artifactId,
        expectedTouchedUs: 4,
      ),
      isFalse,
      reason: 'a surviving exact READY binding protects canonical routing',
    );
    expect(await index.getPhysicalMediaArtifact(physicalId), isNotNull);

    await index.remove(id.key);
    await index.touchPhysicalMediaArtifact(physicalId, 5);
    expect(
      await index.removePhysicalMediaArtifactBindingForMaintenance(
        id: physicalId,
        expectedArtifactId: ready.artifactId,
        expectedTouchedUs: 4,
      ),
      isFalse,
      reason: 'an LRU touch after the maintenance snapshot makes it stale',
    );
    expect(await index.getPhysicalMediaArtifact(physicalId), isNotNull);
    expect(
      await index.removePhysicalMediaArtifactBindingForMaintenance(
        id: physicalId,
        expectedArtifactId: ready.artifactId,
        expectedTouchedUs: 5,
      ),
      isTrue,
    );
    expect(await index.getPhysicalMediaArtifact(physicalId), isNull);
    expect(await index.getArtifactObject(ready.artifactId), isNull);
  });

  test('sqlite retires replica-less artifact authority atomically', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final physicalId = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000replica-less\u00001',
    );
    final ready = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/replica-less-ready.bin',
      bytes: 11,
      checksum: 'abcdef12',
      createdUs: 1,
      touchedUs: 2,
      artifactId: 'replica-less-object',
    );
    await index.put(ready);
    await index.putPhysicalMediaArtifactBinding(
      id: physicalId,
      artifactId: ready.artifactId,
      createdUs: 3,
      touchedUs: 4,
    );

    expect(
      await index.removeArtifactAuthorityIfNoReplicas(ready.artifactId),
      isFalse,
      reason: 'a surviving replica remains immutable byte authority',
    );
    expect(await index.get(id.key), isNotNull);
    expect(await index.getPhysicalMediaArtifact(physicalId), isNotNull);

    for (final replica in await index.listArtifactReplicas(ready.artifactId)) {
      await index.removeArtifactReplica(replica.replicaId);
    }
    expect(
      await index.removeArtifactAuthorityIfNoReplicas(ready.artifactId),
      isTrue,
    );
    expect(await index.get(id.key), isNull);
    expect(await index.getPhysicalMediaArtifact(physicalId), isNull);
    expect(await index.getArtifactObject(ready.artifactId), isNull);
  });

  test('sqlite exact recency touch is guarded by artifact generation', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final oldReady = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/exact-touch-old.bin',
      bytes: 11,
      checksum: 'old',
      createdUs: 1,
      touchedUs: 2,
      artifactId: 'exact-touch-old-object',
    );
    await index.put(oldReady);
    final replacement = oldReady.copyWith(
      path: '/tmp/exact-touch-new.bin',
      checksum: 'new',
      touchedUs: 10,
      artifactId: 'exact-touch-new-object',
    );
    await index.put(replacement);

    await index.touchIfArtifact(
      key: id.key,
      expectedArtifactId: oldReady.artifactId,
      touchedUs: 99,
    );
    expect(
      (await index.get(id.key))?.touchedUs,
      10,
      reason: 'a deferred touch from an old READY generation must be stale',
    );

    await index.touchIfArtifact(
      key: id.key,
      expectedArtifactId: replacement.artifactId,
      touchedUs: 99,
    );
    expect((await index.get(id.key))?.touchedUs, 99);
  });

  for (final fixture in <String, CacheIndex Function()>{
    'memory': MemIndex.new,
    'sqlite': SqliteIndex.memory,
  }.entries) {
    test(
      '${fixture.key} physical partials are independent from exact cache bindings',
      () async {
        final index = fixture.value();
        await index.open();
        addTearDown(index.close);
        final physical = index as PhysicalPartialIndex;
        final physicalId = PhysicalMediaId.canonical(
          'family\u0000chapter\u0000segment\u00007',
        );
        final record = PhysicalPartialRecord(
          id: physicalId,
          path: '/tmp/canonical.part',
          bytes: 123,
          checksum: '',
          createdUs: 10,
          touchedUs: 11,
          storageRootId: 'root',
        );

        await physical.putPhysicalPartial(record);
        expect(await index.get(physicalId.key), isNull);
        expect(await physical.getPhysicalPartial(physicalId), record);
        expect(await physical.listPhysicalPartials(), <PhysicalPartialRecord>[
          record,
        ]);

        await physical.touchPhysicalPartial(physicalId, 12);
        expect((await physical.getPhysicalPartial(physicalId))?.touchedUs, 12);
        await physical.removePhysicalPartial(physicalId);
        expect(await physical.getPhysicalPartial(physicalId), isNull);
      },
    );

    test(
      '${fixture.key} physical artifact survives removal of its exact binding',
      () async {
        final index = fixture.value();
        await index.open();
        addTearDown(index.close);
        final physical = index as PhysicalMediaArtifactIndex;
        final physicalId = PhysicalMediaId.canonical(
          'family\u0000chapter\u0000segment\u00009',
        );
        final ready = CacheRec(
          id: id,
          state: CacheState.ready,
          path: '/tmp/canonical.bin',
          bytes: 77,
          checksum: 'abcd1234',
          createdUs: 20,
          touchedUs: 21,
          artifactId: 'canonical-object',
        );
        await index.put(ready);
        await physical.putPhysicalMediaArtifactBinding(
          id: physicalId,
          artifactId: ready.artifactId,
          createdUs: 22,
          touchedUs: 23,
        );

        final bound = await physical.getPhysicalMediaArtifact(physicalId);
        expect(bound?.artifactId, 'canonical-object');
        expect(bound?.bytes, 77);
        await index.remove(id.key);
        expect(await index.get(id.key), isNull);
        expect(
          (await physical.getPhysicalMediaArtifact(physicalId))?.artifactId,
          'canonical-object',
        );
        expect(
          await index.isPathOrArtifactReferenced(
            path: ready.path,
            artifactId: ready.artifactId,
            excludingKey: id.key,
          ),
          isTrue,
          reason: 'canonical physical binding owns the immutable body even '
              'after its exact logical binding is removed',
        );

        await physical.removePhysicalMediaArtifactBinding(physicalId);
        expect(await physical.getPhysicalMediaArtifact(physicalId), isNull);
        expect(
          await index.isPathOrArtifactReferenced(
            path: ready.path,
            artifactId: ready.artifactId,
            excludingKey: id.key,
          ),
          isFalse,
        );
      },
    );

    test(
      '${fixture.key} logical binding lookup survives provider URI churn',
      () async {
        final index = fixture.value();
        await index.open();
        addTearDown(index.close);
        final query = index as CacheLogicalBindingQuery;
        final historical = DownloadId(
          content: id.content,
          sourceRevision: id.sourceRevision,
          canonicalUri: Uri.parse('venera-resource:historical'),
        );
        final unrelated = DownloadId(
          content: ContentId(
            sourceId: id.content.sourceId,
            comicId: id.content.comicId,
            chapterId: id.content.chapterId,
            pageId: 'other-page',
          ),
          sourceRevision: id.sourceRevision,
          canonicalUri: Uri.parse('venera-resource:other'),
        );
        await index.put(
          CacheRec(
            id: historical,
            state: CacheState.ready,
            path: '/tmp/historical.bin',
            bytes: 77,
            checksum: 'abcd1234',
            createdUs: 1,
            touchedUs: 3,
          ),
        );
        await index.put(
          CacheRec(
            id: unrelated,
            state: CacheState.ready,
            path: '/tmp/other.bin',
            bytes: 88,
            checksum: 'dcba4321',
            createdUs: 1,
            touchedUs: 4,
          ),
        );

        final records = await query.listLogicalBindings(
          content: id.content,
          sourceRevision: id.sourceRevision,
          state: CacheState.ready,
        );

        expect(records.map((record) => record.id), <DownloadId>[historical]);
      },
    );

    test('${fixture.key} index upserts and totals records', () async {
      final index = fixture.value();
      await index.open();
      addTearDown(index.close);

      final partial = CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/tmp/page.part',
        bytes: 10,
        checksum: 'a',
        createdUs: 1,
        touchedUs: 2,
      );
      await index.put(partial);
      expect((await index.get(id.key))?.state, CacheState.partial);
      expect(await index.totalBytes(), 10);

      await index.put(
        partial.copyWith(
          state: CacheState.ready,
          path: '/tmp/page.bin',
          bytes: 20,
          checksum: 'b',
          touchedUs: 3,
        ),
      );
      expect(await index.list(state: CacheState.partial), isEmpty);
      expect(await index.totalBytes(state: CacheState.ready), 20);

      await index.remove(id.key);
      expect(await index.get(id.key), isNull);

      final placement = DownloadPlacement(
        placementId: 'source\u0000comic',
        sourceId: 'source',
        comicId: 'comic',
        comicTitle: '漫画测试',
        mode: DownloadPlacementMode.createNew,
        relativeDirectory: '漫画测试',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      await index.putPlacement(placement);
      final retrieved = await index.getPlacement(
        sourceId: 'source',
        comicId: 'comic',
      );
      expect(retrieved, isNotNull);
      expect(retrieved!.relativeDirectory, '漫画测试');
      expect(retrieved.mode, DownloadPlacementMode.createNew);
      expect(await index.listPlacements(), hasLength(1));
      await expectLater(
        index.putPlacement(placement.copyWith(relativeDirectory: '另一个目录')),
        throwsA(isA<StateError>()),
      );
      expect(
        (await index.getPlacement(
          sourceId: 'source',
          comicId: 'comic',
        ))?.relativeDirectory,
        '漫画测试',
      );

      final committedPlacement = placement.copyWith(
        generation: 1,
        fingerprint: 'fingerprint-a',
      );
      await index.putPlacement(committedPlacement);
      await expectLater(
        index.putPlacement(
          committedPlacement.copyWith(
            fingerprint: 'fingerprint-b',
            updatedAt: DateTime.now().toUtc().add(const Duration(days: 1)),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await index.getPlacement(
          sourceId: 'source',
          comicId: 'comic',
        ))?.fingerprint,
        'fingerprint-a',
      );

      await index.putPlacement(
        committedPlacement.copyWith(
          placementId: 'source\u0000comic-v2',
          generation: 2,
          fingerprint: 'fingerprint-c',
        ),
      );
      final replacedPlacement = await index.getPlacement(
        sourceId: 'source',
        comicId: 'comic',
      );
      expect(replacedPlacement?.placementId, 'source\u0000comic-v2');
      expect(replacedPlacement?.generation, 2);
      expect(await index.listPlacements(), hasLength(1));

      await index.removePlacement(sourceId: 'source', comicId: 'comic');
      expect(
        await index.getPlacement(sourceId: 'source', comicId: 'comic'),
        isNull,
      );
    });

    test(
      '${fixture.key} index batches exact-key lookups without unrelated rows',
      () async {
      final index = fixture.value();
      await index.open();
      addTearDown(index.close);
      final otherId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'other-page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/other.webp'),
      );
      for (final record in <CacheRec>[
        CacheRec(
          id: id,
          state: CacheState.ready,
          path: '/tmp/page.bin',
          bytes: 20,
          checksum: '00000001',
          createdUs: 1,
          touchedUs: 1,
        ),
        CacheRec(
          id: otherId,
          state: CacheState.ready,
          path: '/tmp/other.bin',
          bytes: 30,
          checksum: '00000002',
          createdUs: 1,
          touchedUs: 1,
        ),
      ]) {
        await index.put(record);
      }
        final rows = await index.getMany(<String>[
          id.key,
          id.key,
          'missing-key',
        ]);
      expect(rows.map((record) => record.key), <String>[id.key]);
      },
    );

    test(
      '${fixture.key} index separates identities that shared a legacy key',
      () async {
      final first = DownloadId(
        content: const ContentId(
          sourceId: 'source/a',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/page'),
      );
      final second = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'a/comic',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/page'),
      );
      expect(first.legacyKey, second.legacyKey);
      expect(first.key, isNot(second.key));

      final index = fixture.value();
      await index.open();
      addTearDown(index.close);
      await index.put(
        CacheRec(
          id: first,
          state: CacheState.partial,
          path: '/tmp/first.part',
          bytes: 1,
          checksum: '00000001',
          createdUs: 1,
          touchedUs: 1,
        ),
      );
      await index.put(
        CacheRec(
          id: second,
          state: CacheState.partial,
          path: '/tmp/second.part',
          bytes: 2,
          checksum: '00000002',
          createdUs: 2,
          touchedUs: 2,
        ),
      );

      expect((await index.get(first.key))?.path, '/tmp/first.part');
      expect((await index.get(second.key))?.path, '/tmp/second.part');
      expect(await index.list(), hasLength(2));
      },
    );
  }

  for (final fixture in <String, Object Function()>{
    'memory': MemIndex.new,
    'sqlite': SqliteIndex.memory,
  }.entries) {
    test(
      '${fixture.key} path binding query is exact and excludes one logical key',
        () async {
      final candidate = fixture.value();
      final index = candidate as CacheIndex;
      final pathQuery = candidate as CachePathBindingQuery;
      await index.open();
      addTearDown(index.close);

      DownloadId pathId(String pageId) => DownloadId(
            content: ContentId(
              sourceId: 'source',
              comicId: 'path-query',
              chapterId: 'chapter',
              pageId: pageId,
            ),
            sourceRevision: 'r1',
            canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
          );
      const sharedPath = '/cache/structured/shared.webp';
      final first = CacheRec(
        id: pathId('first'),
        state: CacheState.ready,
        path: sharedPath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
      );
      final second = CacheRec(
        id: pathId('second'),
        state: CacheState.ready,
        path: sharedPath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 2,
        touchedUs: 2,
      );
      final other = CacheRec(
        id: pathId('other'),
        state: CacheState.ready,
        path: '/cache/structured/other.webp',
        bytes: 4,
        checksum: '05060708',
        createdUs: 3,
        touchedUs: 3,
      );
      await index.put(first);
      await index.put(second);
      await index.put(other);
      // Populate SqliteIndex's whole-table read cache first. listPathBindings
      // must retain its targeted path-query semantics rather than reuse that
      // O(N) projection.
      expect(await index.list(), hasLength(3));

      expect(
          (await pathQuery.listPathBindings(
            sharedPath,
          )).map((record) => record.key).toSet(),
        <String>{first.key, second.key},
      );
      expect(
        (await pathQuery.listPathBindings(
          sharedPath,
          excludingKey: first.key,
          )).map((record) => record.key).toList(),
        <String>[second.key],
      );
      },
    );
  }

  test(
    'sqlite artifact_object locator is independent from logical binding path',
      () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final first = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/shared-old.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'shared-locator-artifact',
      storageRootId: '/tmp',
    );
    final second = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'locator-successor',
        ),
        sourceRevision: 'r1',
          canonicalUri: Uri.parse(
            'https://example.test/locator-successor.webp',
          ),
      ),
      state: CacheState.ready,
      path: '/tmp/shared-current.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 2,
      touchedUs: 2,
      artifactId: 'shared-locator-artifact',
      storageRootId: '/tmp',
    );
    await index.put(first);
    await index.put(second);

      expect(
        await index.totalBytes(),
        3,
        reason:
            'logical siblings sharing one artifact count physical bytes once',
      );
    expect((await index.get(first.key))!.path, '/tmp/shared-old.bin');
    final object = await index.getArtifactObject('shared-locator-artifact');
    expect(object, isNotNull);
    expect(object!.accessLocator, '/tmp/shared-current.bin');
    expect(object.bytes, 3);
    expect(object.checksum, '01020304');
    },
  );

  test(
    'sqlite cache materializes fallback artifact identity before a path move',
    () async {
      final index = SqliteIndex.memory();
      await index.open();
      addTearDown(index.close);

      await index.list();
      final initial = CacheRec(
        id: id,
        state: CacheState.ready,
        path: '/tmp/fallback-artifact-old.bin',
        bytes: 3,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        storageRootId: '/tmp',
      );
      await index.put(initial);

      final cached = await index.get(id.key);
      expect(cached, isNotNull);
      expect(cached!.artifactId, initial.effectiveArtifactId);
      final stableArtifactId = cached.artifactId;

      await index.put(
        cached.copyWith(
          path: '/tmp/fallback-artifact-new.bin',
          touchedUs: 2,
        ),
      );

      final moved = await index.get(id.key);
      expect(moved, isNotNull);
      expect(moved!.artifactId, stableArtifactId);
      expect(moved.effectiveArtifactId, stableArtifactId);
      final replicas = await index.listArtifactReplicas(stableArtifactId);
      expect(replicas, hasLength(1));
      expect(replicas.single.accessLocator, '/tmp/fallback-artifact-new.bin');
    },
  );

  test(
    'existing artifact binding preserves the physical object locator',
    () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final source = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/source-authority.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'binding-only-artifact',
      storageRootId: '/tmp',
    );
    final target = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'target-comic',
          chapterId: 'chapter',
          pageId: 'target-page',
        ),
        sourceRevision: 'r2',
        canonicalUri: Uri.parse('https://example.test/target.webp'),
      ),
      state: CacheState.ready,
      path: '/tmp/logical-target-compatibility.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 2,
      touchedUs: 2,
      artifactId: 'binding-only-artifact',
      storageRootId: '/tmp',
    );
    await index.put(source);
    await index.putExistingArtifactBinding(target);

    final object = await index.getArtifactObject('binding-only-artifact');
    expect(object, isNotNull);
      expect(
        object!.accessLocator,
        '/tmp/source-authority.bin',
        reason: 'binding-only commit must not redirect physical authority',
      );
      expect(
        (await index.get(target.key))?.artifactId,
        'binding-only-artifact',
      );
    expect(await index.totalBytes(), 3);
    },
  );

  test('existing artifact binding rejects a different content proof', () async {
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final source = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/source.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'shared-proof',
    );
    final target = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'other',
          chapterId: 'chapter',
          pageId: 'other',
        ),
        sourceRevision: 'r2',
        canonicalUri: Uri.parse('https://example.test/other.webp'),
      ),
      state: CacheState.ready,
      path: source.path,
      bytes: 4,
      checksum: source.checksum,
      createdUs: 2,
      touchedUs: 2,
      artifactId: source.artifactId,
      storageRootId: source.storageRootId,
    );
    await index.put(source);
    await expectLater(
      index.putExistingArtifactBinding(target),
      throwsA(isA<StateError>()),
    );
    expect(await index.get(target.key), isNull);
  });

  test(
    'sqlite rejects conflicting ready bindings for one artifact identity',
    () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final first = CacheRec(
      id: id,
      state: CacheState.ready,
      path: '/tmp/shared-a.bin',
      bytes: 3,
      checksum: '01020304',
      createdUs: 1,
      touchedUs: 1,
      artifactId: 'shared-artifact',
    );
    final second = CacheRec(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'other-page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/other.webp'),
      ),
      state: CacheState.ready,
      path: '/tmp/shared-b.bin',
      bytes: 4,
      checksum: '05060708',
      createdUs: 2,
      touchedUs: 2,
      artifactId: 'shared-artifact',
    );
    await index.put(first);
    await expectLater(index.put(second), throwsA(isA<StateError>()));
    expect((await index.get(first.key))?.checksum, '01020304');
    expect(await index.get(second.key), isNull);
    },
  );
}

void runCacheSchemaV2Tests() {
  test('v1 cache databases migrate to v2 and keep records readable', () async {
    final temp = await Directory.systemTemp.createTemp('cache_index_v2_');
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('PRAGMA user_version = 1');
    legacy.execute('''
      CREATE TABLE cache_entry (
        key TEXT NOT NULL PRIMARY KEY,
        download_json TEXT NOT NULL,
        state TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        created_us INTEGER NOT NULL,
        touched_us INTEGER NOT NULL
      )
    ''');
    final id = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'legacy',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/legacy.webp'),
    );
    legacy.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.legacyKey,
        jsonEncode(id.toJson()),
        'ready',
        '${temp.path}/final/legacy.bin',
        123,
        'checksum',
        1,
        2,
      ],
    );
    legacy.dispose();

    final index = SqliteIndex(dbPath);
    await index.open();
    addTearDown(index.close);
    final record = await index.get(id.key);
    expect(record, isNotNull);
    expect(record!.pinned, isFalse);
    final legacyObject = await index.getArtifactObject(
      record.effectiveArtifactId,
    );
    expect(legacyObject, isNotNull);
    expect(legacyObject!.accessLocator, record.path);
    expect(legacyObject.storageRootId, record.storageRootId);

    final pinnedId = DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'pinned',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/pinned.webp'),
    );
    await index.put(
      CacheRec(
        id: pinnedId,
        state: CacheState.ready,
        path: '${temp.path}/final/pinned.bin',
        bytes: 10,
        checksum: 'c',
        createdUs: 3,
        touchedUs: 4,
        pinned: true,
      ),
    );
    expect((await index.get(pinnedId.key))!.pinned, isTrue);
    expect(await index.totalBytes(), 133);

    final placement = DownloadPlacement(
      placementId: 'p-order',
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: 'title',
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'dir',
      pageOrder: ComicPageOrder.chronological,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await index.putPlacement(placement);
    final read = await index.getPlacement(sourceId: 'source', comicId: 'comic');
    expect(read?.pageOrder, ComicPageOrder.chronological);
  });
  test(
    'memory export page bindings enforce the same sparse ordinal contract',
      () async {
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    const first = ExportPageBinding(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
      pageId: 'page-a',
      logicalIndex: 2,
      exportOrdinal: 3,
    );
    await index.putExportPageBindings(const <ExportPageBinding>[first]);
    expect(
      await index.listExportPageBindings(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
      ),
      const <ExportPageBinding>[first],
    );
    await expectLater(
        index.putExportPageBindings(const <ExportPageBinding>[
          ExportPageBinding(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: 'page-a',
            logicalIndex: 4,
            exportOrdinal: 9,
          ),
        ]),
      throwsStateError,
    );
    },
  );

  test(
    'sqlite export page bindings persist sparse immutable ordinals',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'export-binding-',
      );
    addTearDown(() => directory.delete(recursive: true));
    final dbPath = '${directory.path}/export-binding.sqlite';
    final index = SqliteIndex(dbPath);
    await index.open();
    final bindings = <ExportPageBinding>[
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-a',
        logicalIndex: 2,
        exportOrdinal: 3,
        placementGeneration: 4,
      ),
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-b',
        logicalIndex: 3,
        exportOrdinal: 2,
        placementGeneration: 4,
      ),
    ];
    await index.putExportPageBindings(bindings);
    await index.close();

    final reopened = SqliteIndex(dbPath);
    await reopened.open();
    addTearDown(reopened.close);
    final restored = await reopened.listExportPageBindings(
      sourceId: 'source',
      comicId: 'comic',
      chapterId: 'chapter',
    );
    expect(restored, <ExportPageBinding>[bindings[1], bindings[0]]);

    await reopened.putExportPageBindings(<ExportPageBinding>[
      const ExportPageBinding(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'old-a',
        logicalIndex: 4,
        exportOrdinal: 3,
        placementGeneration: 5,
      ),
    ]);
    expect(
      (await reopened.listExportPageBindings(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        )).singleWhere((binding) => binding.pageId == 'old-a').logicalIndex,
      4,
    );

    await expectLater(
      reopened.putExportPageBindings(<ExportPageBinding>[
        const ExportPageBinding(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'old-a',
          logicalIndex: 4,
          exportOrdinal: 7,
        ),
      ]),
      throwsStateError,
    );
    },
  );

  test(
    'v6 cache metadata migrates existing root identities into schema 7',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v6_root_',
      );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    const rootIdentity = '/storage/emulated/0/Books';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v6-root',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v6-root.webp'),
    );

    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$rootIdentity/final/page.bin',
        bytes: 3,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: rootIdentity,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE storage_access_locator');
    legacy.execute('DROP TABLE storage_root');
    legacy.execute('PRAGMA user_version = 6');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);
    final root = await migrated.getStorageRoot(rootIdentity);
    expect(root, isNotNull);
    expect(root!.rootId, rootIdentity);
    expect(root.accessLocators, hasLength(1));
    expect(root.accessLocators.single.kind, StorageAccessLocatorKind.direct);
    expect(root.accessLocators.single.locator, rootIdentity);
    expect(root.accessLocators.single.health, StorageAccessHealth.unknown);
    },
  );

  test(
    'v7 cache metadata backfills the compatibility object as replica one',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v7_replica_',
      );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v7-replica',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v7-replica.webp'),
    );
    const root = '/storage/emulated/0/Books';
    const artifactId = 'v7-artifact';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$root/final/page.bin',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        artifactId: artifactId,
        storageRootId: root,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE artifact_replica');
    legacy.execute('PRAGMA user_version = 7');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);
    final replicas = await migrated.listArtifactReplicas(artifactId);
    expect(replicas, hasLength(1));
    expect(replicas.single.replicaId, artifactId);
    expect(replicas.single.accessLocator, '$root/final/page.bin');
    expect(replicas.single.storageRootId, root);
    },
  );

  test(
    'v8 cache metadata adds durable replica migration state through schema 14',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v8_migration_',
      );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'v8-migration',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/v8-migration.webp'),
    );
    const artifactId = 'v8-migration-artifact';
    const sourceRoot = '/storage/source';
    const sourcePath = '/storage/source/page.bin';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: sourcePath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        artifactId: artifactId,
        storageRootId: sourceRoot,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('DROP TABLE artifact_replica_migration');
    legacy.execute('PRAGMA user_version = 8');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    final replica = (await migrated.listArtifactReplicas(artifactId)).single;
    expect(replica.replicaId, artifactId);
    final started = await migrated.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: sourcePath,
      sourceStorageRootId: sourceRoot,
      destinationAccessLocator: '/storage/destination/page.bin',
      destinationStorageRootId: '/storage/destination',
      temporaryAccessLocator: '/storage/destination/page.bin.part',
      touchedUs: 3,
    );
    expect(started.phase, ArtifactReplicaMigrationPhase.copying);
    await migrated.close();

    final schema = sql.sqlite3.open(dbPath);
      expect(schema.select('PRAGMA user_version').single.values.single, 22);
    expect(
      schema
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'artifact_replica_migration'",
          )
          .length,
      1,
    );
    schema.dispose();
    },
  );

  test(
    'v10 migration clears cache-final and partial legacy pins only',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v10_pin_migration_',
      );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    DownloadId id(String pageId) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'retention-migration',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
        );
    final cacheFinal = id('cache-final');
    final partial = id('partial');
    final structuredPinned = id('structured-pinned');
    final structuredUnpinned = id('structured-unpinned');
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.put(
      CacheRec(
        id: cacheFinal,
        state: CacheState.ready,
        path: '${temp.path}/final/cache-final.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: partial,
        state: CacheState.partial,
        path: '${temp.path}/partial/partial.part',
        bytes: 2,
        checksum: '',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: structuredPinned,
        state: CacheState.ready,
        path: '${temp.path}/Manual Comic/001.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        pinned: true,
      ),
    );
    await current.put(
      CacheRec(
        id: structuredUnpinned,
        state: CacheState.ready,
        path: '${temp.path}/Manual Comic/002.webp',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    await current.close();

    final legacy = sql.sqlite3.open(dbPath);
    legacy.execute('PRAGMA user_version = 10');
    legacy.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    addTearDown(migrated.close);

    expect((await migrated.get(cacheFinal.key))!.pinned, isFalse);
    expect((await migrated.get(partial.key))!.pinned, isFalse);
    expect((await migrated.get(structuredPinned.key))!.pinned, isTrue);
      expect(
        (await migrated.get(structuredUnpinned.key))!.pinned,
        isFalse,
        reason:
            'migration must not invent manual intent for ambiguous old rows',
      );
    final raw = sql.sqlite3.open(dbPath);
      expect(raw.select('PRAGMA user_version').single.values.single, 22);
    raw.dispose();
    },
  );

  test(
    'v11 upgrade adds path/physical-partial schema without legacy rewrites',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_v11_path_index_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.close();

    final legacyId = DownloadId(
      content: const ContentId(
        sourceId: 'source/legacy',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'path-index-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/path-index-page.webp'),
    );
    final raw = sql.sqlite3.open(dbPath);
    raw.execute('DROP INDEX cache_entry_path');
    raw.execute('PRAGMA user_version = 11');
    raw.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us, '
      'pinned, checksum_algorithm, artifact_id, storage_root_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        legacyId.legacyKey,
        jsonEncode(legacyId.toJson()),
        CacheState.partial.name,
        '${temp.path}/legacy-path.part',
        1,
        '',
        1,
        1,
        0,
        'crc32',
        '',
        temp.path,
      ],
    );
    raw.dispose();

    final migrated = SqliteIndex(dbPath);
    await migrated.open();
    await migrated.close();

    final checked = sql.sqlite3.open(dbPath);
    addTearDown(checked.dispose);
      expect(checked.select('PRAGMA user_version').single.values.single, 22);
    expect(
      checked.select(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'cache_entry_path'",
      ),
      hasLength(1),
    );
      expect(
        checked.select('SELECT key FROM cache_entry WHERE key = ?', <Object?>[
          legacyId.legacyKey,
        ]),
        hasLength(1),
        reason: '11→14 must add schema only, not rerun old key migration',
      );
    expect(
      checked.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'physical_partial'",
      ),
      hasLength(1),
    );
    final plan = checked.select(
      'EXPLAIN QUERY PLAN SELECT * FROM cache_entry '
      'WHERE path = ? AND key != ?',
      <Object?>['${temp.path}/legacy-path.part', legacyId.key],
    );
    expect(
      plan.map((row) => row['detail'].toString()).join(' '),
      contains('cache_entry_path'),
      reason: 'the structured-path query must use the new persistent index',
    );
    },
  );

  test(
    'v12 upgrade only adds physical partial table and keeps cache rows exact',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v12_physical_partial_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'legacy-partial',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/legacy-partial.webp'),
      );
      final current = SqliteIndex(dbPath);
      await current.open();
      await current.put(
        CacheRec(
          id: id,
          state: CacheState.partial,
          path: '${temp.path}/partial/legacy.part',
          bytes: 9,
          checksum: '',
          createdUs: 1,
          touchedUs: 2,
        ),
      );
      await current.close();

      final legacy = sql.sqlite3.open(dbPath);
      legacy.execute('DROP TABLE physical_partial');
      legacy.execute('PRAGMA user_version = 12');
      legacy.dispose();

      final migrated = SqliteIndex(dbPath);
      await migrated.open();
      expect(
        (await migrated.get(id.key))?.path,
        '${temp.path}/partial/legacy.part',
      );
      expect(
        await migrated.listPhysicalPartials(),
        isEmpty,
        reason: 'schema upgrade must not eagerly rewrite legacy exact partials',
      );
      await migrated.close();

      final checked = sql.sqlite3.open(dbPath);
      addTearDown(checked.dispose);
      expect(checked.select('PRAGMA user_version').single.values.single, 22);
      expect(
        checked.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'physical_partial'",
        ),
        hasLength(1),
      );
    },
  );

  test(
    'current cache schema does not rerun legacy identity migration on reopen',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_current_reopen_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final current = SqliteIndex(dbPath);
    await current.open();
    await current.close();

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source/legacy',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/current-reopen.webp'),
    );
    final raw = sql.sqlite3.open(dbPath);
      expect(raw.select('PRAGMA user_version').single.values.single, 22);
    raw.execute(
      'INSERT INTO cache_entry '
      '(key, download_json, state, path, bytes, checksum, created_us, touched_us, '
      'pinned, checksum_algorithm, artifact_id, storage_root_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id.legacyKey,
        jsonEncode(id.toJson()),
        CacheState.partial.name,
        '${temp.path}/legacy.part',
        1,
        '',
        1,
        1,
        0,
        'crc32',
        '',
        'default',
      ],
    );
    raw.dispose();

    final reopened = SqliteIndex(dbPath);
    await reopened.open();
    addTearDown(reopened.close);
    expect(await reopened.get(id.legacyKey), isNotNull);
    expect(
      await reopened.get(id.key),
      isNull,
      reason: 'schema-11 reopen must not rescan/rewrite all cache identities',
    );
    },
  );

  test(
    'replica migration authority switch and cleanup debt survive reopen',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_migration_state_',
      );
    addTearDown(() => temp.delete(recursive: true));
    final dbPath = '${temp.path}${Platform.pathSeparator}cache.sqlite';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'migration-state',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/migration-state.webp'),
    );
    const artifactId = 'migration-state-artifact';
    const sourceRoot = '/storage/a';
    const sourcePath = '/storage/a/page.bin';
    const destinationRoot = '/storage/b';
    const destinationPath = '/storage/b/page.bin';
    const temporaryPath = '/storage/b/page.bin.part';
    final first = SqliteIndex(dbPath);
    await first.open();
    await first.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: sourcePath,
        bytes: 4,
        checksum: '01020304',
        createdUs: 10,
        touchedUs: 20,
        artifactId: artifactId,
        storageRootId: sourceRoot,
      ),
    );
    final replica = (await first.listArtifactReplicas(artifactId)).single;
    await first.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: sourcePath,
      sourceStorageRootId: sourceRoot,
      destinationAccessLocator: destinationPath,
      destinationStorageRootId: destinationRoot,
      temporaryAccessLocator: temporaryPath,
      touchedUs: 30,
    );
    expect(
      (await first.listArtifactReplicas(artifactId)).single.accessLocator,
      sourcePath,
      reason: 'copying progress must not become replica authority',
    );
    expect(await first.isStorageAccessLocatorAuthoritative(sourcePath), isTrue);
    expect(
      await first.isStorageAccessLocatorAuthoritative(destinationPath),
      isTrue,
    );
    expect(await first.isStorageAccessLocatorAuthoritative(temporaryPath), isTrue);
    await first.close();

    final second = SqliteIndex(dbPath);
    await second.open();
      final restored = await second.getArtifactReplicaMigration(
        replica.replicaId,
      );
    expect(restored, isNotNull);
    expect(restored!.phase, ArtifactReplicaMigrationPhase.copying);
    expect(restored.temporaryAccessLocator, temporaryPath);
    final moved = await second.commitArtifactReplicaMigration(
      replicaId: replica.replicaId,
      touchedUs: 40,
    );
    expect(moved.replicaId, replica.replicaId);
    expect(moved.accessLocator, destinationPath);
    expect((await second.get(id.key))!.path, destinationPath);
    expect(
      (await second.get(id.key))!.touchedUs,
      20,
      reason: 'physical relocation must not refresh logical cache recency',
    );
    expect(
      (await second.getArtifactReplicaMigration(replica.replicaId))!.phase,
      ArtifactReplicaMigrationPhase.cleanupPending,
    );
    expect(await second.isStorageAccessLocatorAuthoritative(sourcePath), isFalse);
    expect(
      await second.isStorageAccessLocatorAuthoritative(destinationPath),
      isTrue,
    );
    expect(
      await second.isStorageAccessLocatorAuthoritative(temporaryPath),
      isFalse,
    );
    await second.close();

    final third = SqliteIndex(dbPath);
    await third.open();
    expect(
      (await third.getArtifactReplicaMigration(replica.replicaId))!.phase,
      ArtifactReplicaMigrationPhase.cleanupPending,
    );
    expect(
      (await third.listArtifactReplicas(artifactId)).single.accessLocator,
      destinationPath,
    );
    await third.finishArtifactReplicaMigrationCleanup(replica.replicaId);
      expect(
        await third.getArtifactReplicaMigration(replica.replicaId),
        isNull,
      );
    await third.close();
    },
  );

  test(
    'mutable partial records never become immutable artifact replicas',
    () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'partial-no-replica',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/partial-no-replica.webp'),
    );
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.partial,
        path: '/storage/a/partial/page.part',
        bytes: 4,
        checksum: '00000000',
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'partial-object',
        storageRootId: '/storage/a',
      ),
    );
    expect(await index.listArtifactReplicas('partial-object'), isEmpty);
    },
  );

  test(
    'one artifact keeps independent replicas on two physical roots',
    () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final firstId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'replica-a',
        chapterId: 'chapter',
        pageId: 'page-a',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/replica-a.webp'),
    );
    final secondId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'replica-b',
        chapterId: 'chapter',
        pageId: 'page-b',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/replica-b.webp'),
    );
    const artifactId = 'multi-root-artifact';
    const rootA = '/storage/a';
    const rootB = '/storage/b';
    await index.put(
      CacheRec(
        id: firstId,
        state: CacheState.ready,
        path: '$rootA/final/page.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
        storageRootId: rootA,
      ),
    );
    await index.putArtifactReplica(
      artifactId: artifactId,
      accessLocator: '$rootB/final/page.bin',
      storageRootId: rootB,
      createdUs: 2,
      touchedUs: 2,
    );

    final replicas = await index.listArtifactReplicas(artifactId);
    expect(replicas, hasLength(2));
      expect(replicas.map((value) => value.accessLocator).toSet(), <String>{
        '$rootA/final/page.bin',
        '$rootB/final/page.bin',
      });
    expect(replicas.map((value) => value.replicaId).toSet(), hasLength(2));
    expect(replicas.any((value) => value.replicaId == artifactId), isTrue);
      expect(
        (await index.getArtifactObject(artifactId))?.accessLocator,
        '$rootA/final/page.bin',
        reason:
            'adding a replica must not silently move the compatibility object',
      );

    await index.put(
      CacheRec(
        id: secondId,
        state: CacheState.ready,
        path: '$rootB/final/relocated.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 3,
        touchedUs: 3,
        artifactId: artifactId,
        storageRootId: rootB,
      ),
    );
    final afterBindingWrite = await index.listArtifactReplicas(artifactId);
      expect(
        afterBindingWrite,
        hasLength(2),
        reason:
            'ordinary binding/object updates are not implicit replica copies',
      );
    },
  );

  test('schema 7 backfills one durable locator for a storage root', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final rootId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-backfill',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/root-backfill.webp'),
    );
    await index.put(
      CacheRec(
        id: rootId,
        state: CacheState.ready,
        path: '/storage/emulated/0/Books/final/page.bin',
        bytes: 3,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: '/storage/emulated/0/Books',
      ),
    );

    final root = await index.getStorageRoot('/storage/emulated/0/Books');
    expect(root, isNotNull);
    expect(root!.accessLocators, hasLength(1));
    expect(root.accessLocators.single.kind, StorageAccessLocatorKind.direct);
    expect(root.accessLocators.single.health, StorageAccessHealth.unknown);
  });

  test('verified SAF and Direct locators merge into one durable root', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/Books';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final directId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-direct',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/direct.webp'),
    );
    final safId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'root-saf',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/saf.webp'),
    );
    await index.put(
      CacheRec(
        id: directId,
        state: CacheState.ready,
        path: '$direct/final/direct.bin',
        bytes: 3,
        checksum: '11111111',
        createdUs: 1,
        touchedUs: 1,
        storageRootId: direct,
      ),
    );
    await index.put(
      CacheRec(
        id: safId,
        state: CacheState.ready,
        path: 'saf:placeholder',
        bytes: 3,
        checksum: '22222222',
        createdUs: 2,
        touchedUs: 2,
        storageRootId: saf,
      ),
    );

    final merged = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 99,
    );

    expect(merged.accessLocators, hasLength(2));
    expect(
      merged.accessLocators.map((value) => value.kind).toSet(),
      <StorageAccessLocatorKind>{
        StorageAccessLocatorKind.direct,
        StorageAccessLocatorKind.saf,
      },
    );
    expect(
      merged.accessLocators.every(
        (value) =>
            value.health == StorageAccessHealth.healthy &&
            value.verifiedUs == 99,
      ),
      isTrue,
    );
    expect((await index.getStorageRoot(direct))?.rootId, merged.rootId);
    expect((await index.getStorageRoot(saf))?.rootId, merged.rootId);
    final directRecord = await index.get(directId.key);
    final safRecord = await index.get(safId.key);
    final directReplica = (await index.listArtifactReplicas(
      directRecord!.effectiveArtifactId,
    )).single;
    final safReplica = (await index.listArtifactReplicas(
      safRecord!.effectiveArtifactId,
    )).single;
    expect(directReplica.storageRootId, merged.rootId);
    expect(safReplica.storageRootId, merged.rootId);
  });

  test(
    're-proven removable mount path keeps one durable SAF-root identity',
    () async {
      final index = SqliteIndex.memory();
      await index.open();
      addTearDown(index.close);
      const saf =
          'content://com.android.externalstorage.documents/tree/CAFE-BEEF%3ABooks';
      const firstDirect = '/storage/CAFE-BEEF/Books';
      const remountedDirect = '/mnt/media_rw/CAFE-BEEF/Books';

      final initial = await index.registerStorageRootAccessAliasProof(
        const StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(firstDirect),
          saf: SafStorageAccessLocator(saf),
        ),
        verifiedUs: 10,
      );
      final remounted = await index.registerStorageRootAccessAliasProof(
        const StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(remountedDirect),
          saf: SafStorageAccessLocator(saf),
        ),
        verifiedUs: 20,
      );

      expect(remounted.rootId, initial.rootId);
      expect((await index.getStorageRoot(firstDirect))?.rootId, initial.rootId);
      expect(
        (await index.getStorageRoot(remountedDirect))?.rootId,
        initial.rootId,
      );
      final directLocators = remounted.accessLocators
          .where((value) => value.kind == StorageAccessLocatorKind.direct)
          .toList(growable: false);
      expect(directLocators, hasLength(2));
      expect(
        directLocators.map((value) => value.locator).toSet(),
        <String>{firstDirect, remountedDirect},
      );
      final latest = directLocators.singleWhere(
        (value) => value.locator == remountedDirect,
      );
      expect(latest.verifiedUs, 20);
      expect(latest.health, StorageAccessHealth.healthy);
      expect(
        remounted.accessLocators
            .where((value) => value.kind == StorageAccessLocatorKind.saf)
            .single
            .verifiedUs,
        20,
      );
    },
  );

  test(
    'storage-root alias merge keeps durable migration roots aligned',
    () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/MigrationBooks';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3AMigrationBooks';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'migration-root-merge',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
        canonicalUri: Uri.parse(
          'https://example.test/migration-root-merge.webp',
        ),
    );
    const artifactId = 'migration-root-merge-artifact';
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '$direct/final/page.bin',
        bytes: 4,
        checksum: '01020304',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
        storageRootId: direct,
      ),
    );
    final replica = (await index.listArtifactReplicas(artifactId)).single;
    await index.beginArtifactReplicaMigration(
      replicaId: replica.replicaId,
      sourceAccessLocator: replica.accessLocator,
      sourceStorageRootId: direct,
      destinationAccessLocator: 'saf:destination',
      destinationStorageRootId: saf,
      temporaryAccessLocator: 'saf:temporary',
      touchedUs: 2,
    );

    final merged = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 3,
    );

      final afterReplica = (await index.listArtifactReplicas(
        artifactId,
      )).single;
      final migration = await index.getArtifactReplicaMigration(
        replica.replicaId,
      );
    expect(afterReplica.storageRootId, merged.rootId);
    expect(migration, isNotNull);
    expect(migration!.sourceStorageRootId, merged.rootId);
    expect(migration.destinationStorageRootId, merged.rootId);
    expect(migration.phase, ArtifactReplicaMigrationPhase.copying);
    },
  );

  test('access health changes do not alter root identity', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const direct = '/storage/emulated/0/Books';
    const saf =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final root = await index.registerStorageRootAccessAliasProof(
      const StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(direct),
        saf: SafStorageAccessLocator(saf),
      ),
      verifiedUs: 10,
    );

    await index.updateStorageAccessHealth(
      kind: StorageAccessLocatorKind.direct,
      locator: direct,
      health: StorageAccessHealth.accessDenied,
      touchedUs: 11,
    );

    final current = await index.getStorageRoot(root.rootId);
    expect(current, isNotNull);
    final directAccess = current!.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.direct,
    );
    final safAccess = current.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.saf,
    );
    expect(directAccess.health, StorageAccessHealth.accessDenied);
    expect(safAccess.health, StorageAccessHealth.healthy);
    expect(current.rootId, root.rootId);
  });

  test(
    'physical media projection rows roundtrip compact control-plane json',
    () async {
      final index = SqliteIndex.memory();
      await index.open();
      addTearDown(index.close);
      const record = PhysicalMediaProjectionRecord(
        exactKey: 'source\u0000comic\u0000chapter\u0000r1',
        familyKey: 'family-1',
        projectionJson: '{"intervals":[[0,8000,"segment",0]]}',
        createdUs: 1,
        touchedUs: 2,
      );

      await index.putPhysicalMediaProjection(record);

      expect(
        await index.getPhysicalMediaProjection(record.exactKey),
        isNotNull,
      );
      final restored = await index.getPhysicalMediaProjection(record.exactKey);
      expect(restored?.familyKey, record.familyKey);
      expect(restored?.projectionJson, record.projectionJson);
      expect(await index.listPhysicalMediaProjections(), hasLength(1));
      await index.removePhysicalMediaProjection(record.exactKey);
      expect(await index.getPhysicalMediaProjection(record.exactKey), isNull);
    },
  );

  test('physical media projection batch rejects partial publication', () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    const first = PhysicalMediaProjectionRecord(
      exactKey: 'source\u0000comic-a\u0000chapter\u0000r1',
      familyKey: 'family-1',
      projectionJson: '{"intervals":[[0,1,"segment",0]]}',
      createdUs: 1,
      touchedUs: 2,
    );
    const invalidSecond = PhysicalMediaProjectionRecord(
      exactKey: 'source\u0000comic-b\u0000chapter\u0000r1',
      familyKey: '',
      projectionJson: '{"intervals":[[0,1,"segment",0]]}',
      createdUs: 1,
      touchedUs: 2,
    );

    await expectLater(
      index.putPhysicalMediaProjections(
        const <PhysicalMediaProjectionRecord>[first, invalidSecond],
      ),
      throwsArgumentError,
    );

    expect(await index.getPhysicalMediaProjection(first.exactKey), isNull);
    expect(await index.listPhysicalMediaProjections(), isEmpty);
  });

  test(
    'schema 14 backfills indexed logical page identity without changing DownloadId',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v14_logical_binding_migration_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/cache.sqlite';
      final historical = DownloadId(
        content: const ContentId(
          sourceId: 'venera:ehentai',
          comicId: 'old-comic',
          chapterId: 'old-chapter',
          pageId: 'old-page-311',
        ),
        sourceRevision: 'single',
        canonicalUri: Uri.parse('venera-resource:expired-provider-uri'),
      );
      // Keep the other durable tables present in a real v14 database; only
      // the logical-binding table below is the subject of this migration.
      final seed = SqliteIndex(path);
      await seed.open();
      await seed.close();
      final legacy = sql.sqlite3.open(path);
      // Candidate references did not exist in v14 and cannot reference the
      // replacement historical table's not-yet-created numeric column.
      legacy.execute('DROP TABLE cache_entry_identity');
      legacy.execute('DROP TABLE cache_entry');
      legacy.execute('''
      CREATE TABLE cache_entry (
        key TEXT NOT NULL PRIMARY KEY,
        download_json TEXT NOT NULL,
        state TEXT NOT NULL,
        path TEXT NOT NULL,
        bytes INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        created_us INTEGER NOT NULL,
        touched_us INTEGER NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        checksum_algorithm TEXT NOT NULL DEFAULT 'crc32',
        artifact_id TEXT NOT NULL DEFAULT '',
        storage_root_id TEXT NOT NULL DEFAULT 'default'
      )
    ''');
      legacy.execute(
        'INSERT INTO cache_entry '
        '(key, download_json, state, path, bytes, checksum, created_us, touched_us, '
        'pinned, checksum_algorithm, artifact_id, storage_root_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          historical.key,
          jsonEncode(historical.toJson()),
          'ready',
          '/tmp/historical.bin',
          77,
          'abcd1234',
          1,
          2,
          0,
          'crc32',
          'historical-artifact',
          'default',
        ],
      );
      legacy.execute('PRAGMA user_version = 14');
      legacy.dispose();

      final migrated = SqliteIndex(path);
      await migrated.open();
      final records = await migrated.listLogicalBindings(
        content: historical.content,
        sourceRevision: historical.sourceRevision,
        state: CacheState.ready,
      );
      expect(records.map((record) => record.id), <DownloadId>[historical]);
      await migrated.close();

      final checked = sql.sqlite3.open(path);
      addTearDown(checked.dispose);
      expect(checked.select('PRAGMA user_version').single.values.single, 22);
      final columns = checked
          .select('PRAGMA table_info(cache_entry)')
          .map((row) => row['name'])
          .toSet();
      expect(columns, containsAll(<String>['content_key', 'source_revision']));
      expect(
        checked.select(
          "SELECT name FROM sqlite_master WHERE type='index' "
          "AND name='cache_entry_logical_identity'",
        ),
        hasLength(1),
      );
    },
  );

  test(
    'schema 13 reaches current physical media and logical identity schema once',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cache_index_v13_projection_migration_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/cache.sqlite';
      final seed = SqliteIndex(path);
      await seed.open();
      await seed.close();

      final legacy = sql.sqlite3.open(path);
      legacy.execute('DROP TABLE physical_media_projection');
      legacy.execute('PRAGMA user_version = 13');
      legacy.dispose();

      final migrated = SqliteIndex(path);
      await migrated.open();
      await migrated.putPhysicalMediaProjection(
        const PhysicalMediaProjectionRecord(
          exactKey: 'exact',
          familyKey: 'family',
          projectionJson: '{}',
          createdUs: 1,
          touchedUs: 1,
        ),
      );
      await migrated.close();

      final checked = sql.sqlite3.open(path);
      addTearDown(checked.dispose);
      expect(checked.select('PRAGMA user_version').single.values.single, 22);
      expect(
        checked.select(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='physical_media_projection'",
        ),
        hasLength(1),
      );
      expect(
        checked.select('SELECT exact_key FROM physical_media_projection'),
        hasLength(1),
      );
    },
  );

  test('schema 15 adds cleanup debt and upgrades through schema 18',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_v15_cleanup_debt_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/cache.sqlite';
    final seed = SqliteIndex(path);
    await seed.open();
    await seed.close();

    final legacy = sql.sqlite3.open(path);
    legacy.execute('DROP TABLE storage_cleanup_debt');
    legacy.execute('PRAGMA user_version = 15');
    legacy.dispose();

    final migrated = SqliteIndex(path);
    await migrated.open();
    const debt = StorageCleanupDebtRecord(
      accessLocator: 'saf-record://tree/partial/page.part.zic-tmp-1',
      storageRootId: 'tree',
      kind: StorageCleanupDebtKind.temporary,
      createdUs: 10,
      touchedUs: 11,
    );
    await migrated.putStorageCleanupDebt(debt);
    expect(await migrated.listStorageCleanupDebts(), hasLength(1));
    final restored = (await migrated.listStorageCleanupDebts()).single;
    expect(restored.accessLocator, debt.accessLocator);
    expect(restored.storageRootId, debt.storageRootId);
    expect(restored.kind, StorageCleanupDebtKind.temporary);
    await migrated.removeStorageCleanupDebt(debt.accessLocator);
    expect(await migrated.listStorageCleanupDebts(), isEmpty);
    const obsolete = StorageCleanupDebtRecord(
      accessLocator: '/storage/old/page.bin',
      storageRootId: '/storage/old',
      kind: StorageCleanupDebtKind.obsoleteSealedSource,
      createdUs: 12,
      touchedUs: 13,
      expectedBytes: 4,
      expectedChecksum: '01020304',
      expectedChecksumAlgorithm: 'crc32',
    );
    await migrated.putStorageCleanupDebt(obsolete);
    final obsoleteRestored = (await migrated.listStorageCleanupDebts()).single;
    expect(obsoleteRestored.kind, StorageCleanupDebtKind.obsoleteSealedSource);
    expect(obsoleteRestored.expectedBytes, 4);
    expect(obsoleteRestored.expectedChecksum, '01020304');
    expect(obsoleteRestored.expectedChecksumAlgorithm, 'crc32');
    await migrated.removeStorageCleanupDebt(obsolete.accessLocator);
    const obsoletePartial = StorageCleanupDebtRecord(
      accessLocator: '/storage/old/page.part',
      storageRootId: '/storage/old',
      kind: StorageCleanupDebtKind.obsoletePartialSource,
      createdUs: 14,
      touchedUs: 15,
      expectedBytes: 4096,
      expectedChecksum: '1234abcd',
      expectedChecksumAlgorithm: 'crc32',
    );
    await migrated.putStorageCleanupDebt(obsoletePartial);
    final partialRestored = (await migrated.listStorageCleanupDebts()).single;
    expect(partialRestored.kind, StorageCleanupDebtKind.obsoletePartialSource);
    expect(partialRestored.expectedBytes, 4096);
    expect(partialRestored.expectedChecksum, '1234abcd');
    await migrated.removeStorageCleanupDebt(obsoletePartial.accessLocator);
    expect(
      () => migrated.putStorageCleanupDebt(
        const StorageCleanupDebtRecord(
          accessLocator: '/storage/old/unproven.bin',
          storageRootId: '/storage/old',
          kind: StorageCleanupDebtKind.obsoleteSealedSource,
          createdUs: 14,
          touchedUs: 14,
        ),
      ),
      throwsArgumentError,
    );
    await migrated.close();

    final checked = sql.sqlite3.open(path);
    addTearDown(checked.dispose);
    expect(checked.select('PRAGMA user_version').single.values.single, 22);
    expect(
      checked.select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='storage_cleanup_debt'",
      ),
      hasLength(1),
    );
  });

  test('schema 17 repairs historical leading-slash SAF identity', () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_v17_saf_identity_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/cache.sqlite';
    final seed = SqliteIndex(path);
    await seed.open();
    await seed.close();

    const legacyTree =
        '/content://com.android.externalstorage.documents/tree/primary%3Abooks';
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3Abooks';
    final legacyLocator =
        'saf:${Uri.encodeComponent(legacyTree)}?path=${Uri.encodeComponent('Comic/001.webp')}';
    final repairedLocator =
        'saf:${Uri.encodeComponent(tree)}?path=${Uri.encodeComponent('Comic/001.webp')}';

    final legacy = sql.sqlite3.open(path);
    legacy.execute(
      'INSERT INTO storage_root (root_id, created_us, touched_us) VALUES (?, ?, ?)',
      <Object?>[legacyTree, 10, 20],
    );
    legacy.execute(
      'INSERT INTO storage_access_locator '
      '(kind, locator, root_id, health, verified_us, touched_us) '
      "VALUES ('direct', ?, ?, 'unknown', NULL, ?)",
      <Object?>[legacyTree, legacyTree, 20],
    );
    legacy.execute(
      'INSERT INTO artifact_object '
      '(artifact_id, path, bytes, checksum, checksum_algorithm, storage_root_id, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>['artifact', legacyLocator, 4, '01020304', 'crc32', legacyTree, 10, 20],
    );
    legacy.execute(
      'INSERT INTO artifact_replica '
      '(replica_id, artifact_id, access_locator, storage_root_id, created_us, touched_us) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      <Object?>['replica', 'artifact', legacyLocator, legacyTree, 10, 20],
    );
    legacy.execute('PRAGMA user_version = 17');
    legacy.dispose();

    final migrated = SqliteIndex(path);
    await migrated.open();
    await migrated.close();

    final checked = sql.sqlite3.open(path);
    addTearDown(checked.dispose);
    expect(checked.select('PRAGMA user_version').single.values.single, 22);
    expect(
      checked.select('SELECT root_id FROM storage_root').map((row) => row['root_id']),
      contains(tree),
    );
    expect(
      checked.select('SELECT root_id FROM storage_root').map((row) => row['root_id']),
      isNot(contains(legacyTree)),
    );
    final access = checked.select(
      'SELECT kind, locator, root_id, health FROM storage_access_locator WHERE root_id = ?',
      <Object?>[tree],
    ).single;
    expect(access['kind'], 'saf');
    expect(access['locator'], tree);
    expect(access['health'], 'unknown');
    final replica = checked.select(
      'SELECT access_locator, storage_root_id FROM artifact_replica WHERE replica_id = ?',
      <Object?>['replica'],
    ).single;
    expect(replica['access_locator'], repairedLocator);
    expect(replica['storage_root_id'], tree);
    final object = checked.select(
      'SELECT path, storage_root_id FROM artifact_object WHERE artifact_id = ?',
      <Object?>['artifact'],
    ).single;
    expect(object['path'], repairedLocator);
    expect(object['storage_root_id'], tree);
  });

  test('schema 19 retires deprecated volatile Venera physical aliases only', () async {
    final temp = await Directory.systemTemp.createTemp('zic-schema19-volatile-page-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/cache.sqlite';
    final seed = SqliteIndex(path);
    await seed.open();
    final migrationId = DownloadId(
      content: const ContentId(
        sourceId: 'venera:jm',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'ep-1',
      canonicalUri: Uri.parse('venera-resource:carrier'),
    );
    final ready = CacheRec(
      id: migrationId,
      state: CacheState.ready,
      path: '${temp.path}/ready.bin',
      bytes: 4,
      checksum: '01020304',
      createdUs: 10,
      touchedUs: 20,
      artifactId: 'schema19-ready',
    );
    await seed.put(ready);
    final deprecated = PhysicalMediaId.canonical(
      'volatile-page:v16:source5:comic7:chapter2:r14:page',
    );
    await seed.putPhysicalMediaArtifactBinding(
      id: deprecated,
      artifactId: ready.artifactId,
      createdUs: 30,
      touchedUs: 40,
    );
    await seed.close();

    final legacy = sql.sqlite3.open(path);
    legacy.execute('PRAGMA user_version = 18');
    legacy.dispose();

    final migrated = SqliteIndex(path);
    await migrated.open();
    expect(await migrated.getPhysicalMediaArtifact(deprecated), isNull);
    expect(await migrated.get(migrationId.key), isNotNull);
    await migrated.close();

    final checked = sql.sqlite3.open(path);
    addTearDown(checked.dispose);
    expect(checked.select('PRAGMA user_version').single.values.single, 22);
    expect(
      checked.select(
        'SELECT artifact_id FROM artifact_object WHERE artifact_id = ?',
        <Object?>[ready.artifactId],
      ),
      hasLength(1),
      reason: 'retiring the invalid routing alias must preserve body authority',
    );
    expect(
      checked.select(
        'SELECT artifact_id FROM artifact_replica WHERE artifact_id = ?',
        <Object?>[ready.artifactId],
      ),
      hasLength(1),
    );
  });

  test('DownloadPlacement equality includes export page order', () {
    final now = DateTime.utc(2026, 9, 6);
    final origin = DownloadPlacement(
      placementId: 'p',
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: 'title',
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'dir',
      pageOrder: ComicPageOrder.origin,
      createdAt: now,
      updatedAt: now,
    );
    expect(
      origin,
      isNot(origin.copyWith(pageOrder: ComicPageOrder.chronological)),
    );
  });
}
