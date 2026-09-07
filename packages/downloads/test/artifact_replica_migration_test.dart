import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test(
    'direct replica migration preserves replica identity and logical binding',
    () async {
      final roots = await _MigrationRoots.create('identity');
      final reads = ArtifactCacheReadScheduler();
      final writes = StorageWriteScheduler(localReadScheduler: reads);
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        storageWriteScheduler: writes,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('identity');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 17, (index) => index % 251),
      );
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final bindingBefore = (await store.indexedRecords())[id.key]!;
      final sourcePath = before.accessLocator;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}migrated.bin';

      final result = await store.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );

      expect(result.sourceCleanupComplete, isTrue);
      expect(result.replica.replicaId, before.replicaId);
      expect(result.replica.accessLocator, destination);
      expect(result.replica.storageRootId, roots.destination.path);
      expect(await File(sourcePath).exists(), isFalse);
      expect(await File(destination).readAsBytes(), bytes);
      final replicas = await store.artifactReplicasFor(id);
      expect(replicas, hasLength(1));
      expect(replicas.single.replicaId, before.replicaId);
      expect(replicas.single.accessLocator, destination);
      final indexed = (await store.indexedRecords())[id.key];
      expect(indexed, isNotNull);
      expect(
        indexed!.path,
        destination,
        reason: 'primary replica migration keeps compatibility mirror coherent',
      );
      expect(
        indexed.touchedUs,
        bindingBefore.touchedUs,
        reason: 'physical migration must not manufacture logical cache recency',
      );
      expect(await store.readPromoted(id), bytes);
    },
  );

  test(
    'migration never overwrites mismatching pre-existing destination',
    () async {
      final roots = await _MigrationRoots.create('collision');
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('collision');
      final bytes = Uint8List.fromList(<int>[1, 3, 3, 7, 9, 9]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      final destination = File(
        '${roots.destination.path}${Platform.pathSeparator}occupied.bin',
      );
      final foreign = Uint8List.fromList(<int>[9, 9, 7, 3, 3, 1]);
      await destination.writeAsBytes(foreign, flush: true);

      await expectLater(
        store.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination.path,
          destinationStorageRootId: roots.destination.path,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.artifactCorruption,
          ),
        ),
      );

      expect(await File(sourcePath).readAsBytes(), bytes);
      expect(await destination.readAsBytes(), foreign);
      final after = (await store.artifactReplicasFor(id)).single;
      expect(after.replicaId, before.replicaId);
      expect(after.accessLocator, sourcePath);
    },
  );

  test(
    'migration adopts a fully verified pre-existing destination after crash',
    () async {
      final roots = await _MigrationRoots.create('crash-retry');
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('crash-retry');
      final bytes = Uint8List.fromList(<int>[6, 2, 6, 4, 3, 3, 8, 3]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      final destination = File(
        '${roots.destination.path}${Platform.pathSeparator}already-copied.bin',
      );
      await destination.writeAsBytes(bytes, flush: true);

      final result = await store.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination.path,
        destinationStorageRootId: roots.destination.path,
      );

      expect(result.sourceCleanupComplete, isTrue);
      expect(await File(sourcePath).exists(), isFalse);
      expect(await destination.readAsBytes(), bytes);
      final after = (await store.artifactReplicasFor(id)).single;
      expect(after.replicaId, before.replicaId);
      expect(after.accessLocator, destination.path);
    },
  );

  test(
    'migration rejects a destination outside the declared storage root',
    () async {
      final roots = await _MigrationRoots.create('wrong-root');
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('wrong-root');
      final bytes = Uint8List.fromList(<int>[5, 8, 5, 8, 5, 8]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}wrong-root.bin';

      await expectLater(
        store.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: roots.source.path,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.policy,
          ),
        ),
      );

      expect(
        (await store.artifactReplicasFor(id)).single.accessLocator,
        before.accessLocator,
      );
      expect(await File(before.accessLocator).readAsBytes(), bytes);
      expect(await File(destination).exists(), isFalse);
    },
  );

  test(
    'cancellation while yielding to Reader pressure preserves source authority',
    () async {
      final roots = await _MigrationRoots.create('cancel');
      final reads = ArtifactCacheReadScheduler();
      final writes = StorageWriteScheduler(localReadScheduler: reads);
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        storageWriteScheduler: writes,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('cancel');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 23, (index) => index % 239),
      );
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}cancelled.bin';
      final foreground = reads.holdForegroundPressure();
      final control = _TestTaskControl(priority: 0);
      final migration = store.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
        control: control,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(writes.activeCount, 0);
      expect(await File(sourcePath).exists(), isTrue);
      control.cancel();
      await expectLater(
        migration,
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.cancelled,
          ),
        ),
      );
      foreground.release();

      final after = (await store.artifactReplicasFor(id)).single;
      expect(after.replicaId, before.replicaId);
      expect(after.accessLocator, sourcePath);
      expect(await File(sourcePath).readAsBytes(), bytes);
      expect(await File(destination).exists(), isFalse);
      expect(
        await roots.destination
            .list()
            .where((entry) => entry.path.contains('.zic-migrate-tmp-'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'source cleanup failure does not roll back committed destination authority',
    () async {
      final roots = await _MigrationRoots.create('cleanup');
      final artifactBytes = _DeleteFailArtifactBytes();
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: artifactBytes,
      );
      addTearDown(() async {
        artifactBytes.failDeletePath = null;
        await store.close();
        await roots.delete();
      });
      final id = _id('cleanup');
      final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8, 1, 8]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await store.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      artifactBytes.failDeletePath = sourcePath;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}committed.bin';

      final result = await store.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );

      expect(result.sourceCleanupComplete, isFalse);
      expect(
        await File(sourcePath).exists(),
        isTrue,
        reason: 'failed cleanup may leave unadvertised old bytes',
      );
      expect(await File(destination).readAsBytes(), bytes);
      final after = (await store.artifactReplicasFor(id)).single;
      expect(after.replicaId, before.replicaId);
      expect(after.accessLocator, destination);
      expect(
        await store.readPromoted(id),
        bytes,
        reason:
            'committed destination remains authoritative despite cleanup debt',
      );
    },
  );

  test(
    'secondary replica migration does not move the primary compatibility mirror',
    () async {
      final roots = await _MigrationRoots.create('secondary');
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('secondary');
      final bytes = Uint8List.fromList(<int>[4, 2, 4, 2, 4, 2, 4, 2]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final primary = (await store.artifactReplicasFor(id)).single;
      final secondFile = File(
        '${roots.destination.path}${Platform.pathSeparator}secondary.bin',
      );
      await secondFile.writeAsBytes(bytes, flush: true);
      final secondary = await store.registerVerifiedArtifactReplica(
        id: id,
        accessLocator: secondFile.path,
        storageRootId: roots.destination.path,
      );
      expect(secondary.replicaId, isNot(primary.replicaId));
      final target =
          '${roots.source.path}${Platform.pathSeparator}secondary-moved.bin';

      final result = await store.migrateArtifactReplica(
        id: id,
        replicaId: secondary.replicaId,
        destinationAccessLocator: target,
        destinationStorageRootId: roots.source.path,
      );

      expect(result.replica.replicaId, secondary.replicaId);
      expect(await secondFile.exists(), isFalse);
      expect(await File(target).readAsBytes(), bytes);
      final replicas = await store.artifactReplicasFor(id);
      expect(replicas, hasLength(2));
      final primaryAfter = replicas.singleWhere(
        (value) => value.replicaId == primary.replicaId,
      );
      final secondaryAfter = replicas.singleWhere(
        (value) => value.replicaId == secondary.replicaId,
      );
      expect(primaryAfter.accessLocator, primary.accessLocator);
      expect(secondaryAfter.accessLocator, target);
      expect(
        (await store.indexedRecords())[id.key]!.path,
        primary.accessLocator,
        reason: 'secondary movement must not rewrite the primary mirror',
      );
    },
  );

  test(
    'direct to SAF to direct migration preserves one replica identity',
    () async {
      final roots = await _MigrationRoots.create('saf-roundtrip');
      final saf = _MemorySafTreeIo();
      const safTree =
          'content://com.android.externalstorage.documents/tree/primary%3AZicMigration';
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        safMirror: saf,
        safTreeUri: safTree,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
      });
      final id = _id('saf-roundtrip');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 29, (index) => index % 233),
      );
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final initial = (await store.artifactReplicasFor(id)).single;
      final initialPath = initial.accessLocator;
      const relativePath = 'offline/roundtrip.bin';
      final safLocator = encodeSafRecordPath(
        treeUri: safTree,
        relativePath: relativePath,
      );

      final intoSaf = await store.migrateArtifactReplica(
        id: id,
        replicaId: initial.replicaId,
        destinationAccessLocator: safLocator,
        destinationStorageRootId: safTree,
      );

      expect(intoSaf.sourceCleanupComplete, isTrue);
      expect(intoSaf.replica.replicaId, initial.replicaId);
      expect(intoSaf.replica.accessLocator, safLocator);
      expect(await File(initialPath).exists(), isFalse);
      expect(saf.storage[relativePath], bytes);
      expect(await store.readPromoted(id), bytes);

      final directTarget =
          '${roots.destination.path}${Platform.pathSeparator}saf-roundtrip.bin';
      final backToDirect = await store.migrateArtifactReplica(
        id: id,
        replicaId: initial.replicaId,
        destinationAccessLocator: directTarget,
        destinationStorageRootId: roots.destination.path,
      );

      expect(backToDirect.sourceCleanupComplete, isTrue);
      expect(backToDirect.replica.replicaId, initial.replicaId);
      expect(backToDirect.replica.accessLocator, directTarget);
      expect(saf.storage.containsKey(relativePath), isFalse);
      expect(await File(directTarget).readAsBytes(), bytes);
      final finalReplicas = await store.artifactReplicasFor(id);
      expect(finalReplicas, hasLength(1));
      expect(finalReplicas.single.replicaId, initial.replicaId);
      expect(finalReplicas.single.accessLocator, directTarget);
      expect((await store.indexedRecords())[id.key]!.path, directTarget);
      expect(await store.readPromoted(id), bytes);
    },
  );

  test(
    'migration rejects a proven access alias owned by another replica',
    () async {
      final roots = await _MigrationRoots.create('alias-collision');
      final thirdRoot = await Directory.systemTemp.createTemp(
        'zic-migrate-third-alias-collision-',
      );
      final saf = _MemorySafTreeIo();
      const safTree =
          'content://com.android.externalstorage.documents/tree/primary%3AAliasCollision';
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        safMirror: saf,
        safTreeUri: safTree,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
        if (await thirdRoot.exists()) await thirdRoot.delete(recursive: true);
      });
      final id = _id('alias-collision');
      final bytes = Uint8List.fromList(<int>[9, 2, 6, 5, 3, 5, 8, 9]);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final primary = (await store.artifactReplicasFor(id)).single;
      final secondFile = File(
        '${thirdRoot.path}${Platform.pathSeparator}replica.bin',
      );
      await secondFile.writeAsBytes(bytes, flush: true);
      final secondary = await store.registerVerifiedArtifactReplica(
        id: id,
        accessLocator: secondFile.path,
        storageRootId: thirdRoot.path,
      );
      expect(secondary.replicaId, isNot(primary.replicaId));
      await store.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(thirdRoot.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      const relativePath = 'replica.bin';
      saf.storage[relativePath] = Uint8List.fromList(bytes);
      final aliasLocator = encodeSafRecordPath(
        treeUri: safTree,
        relativePath: relativePath,
      );

      await expectLater(
        store.migrateArtifactReplica(
          id: id,
          replicaId: primary.replicaId,
          destinationAccessLocator: aliasLocator,
          destinationStorageRootId: thirdRoot.path,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.policy,
          ),
        ),
      );

      final after = await store.artifactReplicasFor(id);
      expect(after, hasLength(2));
      expect(
        after
            .singleWhere((value) => value.replicaId == primary.replicaId)
            .accessLocator,
        primary.accessLocator,
      );
      expect(
        after
            .singleWhere((value) => value.replicaId == secondary.replicaId)
            .accessLocator,
        secondary.accessLocator,
      );
    },
  );

  test(
    'migration never shares one physical locator across different artifacts',
    () async {
      final roots = await _MigrationRoots.create('cross-artifact-alias');
      final thirdRoot = await Directory.systemTemp.createTemp(
        'zic-migrate-third-cross-artifact-alias-',
      );
      final saf = _MemorySafTreeIo();
      const safTree =
          'content://com.android.externalstorage.documents/tree/primary%3ACrossArtifact';
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        safMirror: saf,
        safTreeUri: safTree,
      );
      addTearDown(() async {
        await store.close();
        await roots.delete();
        if (await thirdRoot.exists()) await thirdRoot.delete(recursive: true);
      });
      final firstId = _id('cross-artifact-first');
      final secondId = _id('cross-artifact-second');
      final firstBytes = Uint8List.fromList(<int>[1, 4, 1, 4, 2, 1, 3, 5]);
      final secondBytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8, 1, 8]);
      await store.storePromotedArtifact(id: firstId, bytes: firstBytes);
      await store.storePromotedArtifact(id: secondId, bytes: secondBytes);
      final firstReplica = (await store.artifactReplicasFor(firstId)).single;
      final secondReplica = (await store.artifactReplicasFor(secondId)).single;
      final secondSource = secondReplica.accessLocator;
      await store.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(thirdRoot.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      final directDestination =
          '${thirdRoot.path}${Platform.pathSeparator}shared-locator.bin';
      await store.migrateArtifactReplica(
        id: firstId,
        replicaId: firstReplica.replicaId,
        destinationAccessLocator: directDestination,
        destinationStorageRootId: thirdRoot.path,
      );
      final safAlias = encodeSafRecordPath(
        treeUri: safTree,
        relativePath: 'shared-locator.bin',
      );

      await expectLater(
        store.migrateArtifactReplica(
          id: secondId,
          replicaId: secondReplica.replicaId,
          destinationAccessLocator: safAlias,
          destinationStorageRootId: thirdRoot.path,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.policy,
          ),
        ),
      );

      expect(await File(directDestination).readAsBytes(), firstBytes);
      expect(await File(secondSource).readAsBytes(), secondBytes);
      expect(
        (await store.artifactReplicasFor(firstId)).single.accessLocator,
        directDestination,
      );
      expect(
        (await store.artifactReplicasFor(secondId)).single.accessLocator,
        secondSource,
      );
    },
  );

  test(
    'shared logical bindings serialize migration through artifact authority',
    () async {
      final roots = await _MigrationRoots.create('shared-artifact-lock');
      final thirdRoot = await Directory.systemTemp.createTemp(
        'zic-migrate-third-shared-artifact-lock-',
      );
      addTearDown(() async {
        await roots.delete();
        if (await thirdRoot.exists()) await thirdRoot.delete(recursive: true);
      });
      final firstId = _id('shared-first');
      final secondId = _id('shared-second');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 31, (index) => index % 229),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: firstId, bytes: bytes);
      final seeded = (await seed.indexedRecords())[firstId.key]!;
      final primary = (await seed.artifactReplicasFor(firstId)).single;
      await seed.close();

      final index = SqliteIndex(CacheLayout(roots.source.path).dbPath);
      await index.open();
      await index.put(
        CacheRec(
          id: secondId,
          state: CacheState.ready,
          path: seeded.path,
          bytes: seeded.bytes,
          checksum: seeded.checksum,
          createdUs: seeded.createdUs,
          touchedUs: seeded.touchedUs,
          pinned: seeded.pinned,
          checksumAlgorithm: seeded.checksumAlgorithm,
          artifactId: seeded.effectiveArtifactId,
          storageRootId: seeded.storageRootId,
        ),
      );
      await index.close();

      final gatedBytes = _GatedArtifactBytes(sourcePath: seeded.path);
      final reads = ArtifactCacheReadScheduler();
      final writes = StorageWriteScheduler(
        localReadScheduler: reads,
        maxActive: 2,
      );
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: gatedBytes,
        storageWriteScheduler: writes,
      );
      addTearDown(store.close);
      final destinationA =
          '${roots.destination.path}${Platform.pathSeparator}shared-a.bin';
      final destinationB =
          '${thirdRoot.path}${Platform.pathSeparator}shared-b.bin';

      final first = store.migrateArtifactReplica(
        id: firstId,
        replicaId: primary.replicaId,
        destinationAccessLocator: destinationA,
        destinationStorageRootId: roots.destination.path,
      );
      await gatedBytes.firstSourceReadStarted.future.timeout(
        const Duration(seconds: 1),
      );
      final second = store.migrateArtifactReplica(
        id: secondId,
        replicaId: primary.replicaId,
        destinationAccessLocator: destinationB,
        destinationStorageRootId: thirdRoot.path,
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        gatedBytes.sourceReadStarts,
        1,
        reason: 'a second logical binding must wait on artifact replica authority',
      );

      gatedBytes.releaseSourceReads();
      await Future.wait<ArtifactReplicaMigrationResult>(<Future<ArtifactReplicaMigrationResult>>[
        first,
        second,
      ]);

      expect(await File(seeded.path).exists(), isFalse);
      expect(await File(destinationA).exists(), isFalse,
          reason: 'the serialized second relocation must clean the intermediate source');
      expect(await File(destinationB).readAsBytes(), bytes);
      final replicas = await store.artifactReplicasFor(firstId);
      expect(replicas, hasLength(1));
      expect(replicas.single.replicaId, primary.replicaId);
      expect(replicas.single.accessLocator, destinationB);
      final indexed = await store.indexedRecords();
      expect(indexed[firstId.key]!.path, destinationB);
      expect(indexed[secondId.key]!.path, destinationB);
    },
  );
}

DownloadId _id(String pageId) => DownloadId(
  content: ContentId(
    sourceId: 'migration-source',
    comicId: 'migration-comic',
    chapterId: 'migration-chapter',
    pageId: pageId,
  ),
  sourceRevision: 'migration-r1',
  canonicalUri: Uri.parse('https://example.invalid/$pageId.bin'),
);

final class _MigrationRoots {
  const _MigrationRoots({
    required this.app,
    required this.source,
    required this.destination,
  });

  final Directory app;
  final Directory source;
  final Directory destination;

  static Future<_MigrationRoots> create(String suffix) async => _MigrationRoots(
    app: await Directory.systemTemp.createTemp('zic-migrate-app-$suffix-'),
    source: await Directory.systemTemp.createTemp(
      'zic-migrate-source-$suffix-',
    ),
    destination: await Directory.systemTemp.createTemp(
      'zic-migrate-destination-$suffix-',
    ),
  );

  Future<void> delete() async {
    for (final directory in <Directory>[app, source, destination]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

final class _TestTaskControl implements TaskControl {
  _TestTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class _DeleteFailArtifactBytes implements ArtifactBytes {
  final ArtifactBytes _delegate = const LocalArtifactBytes();
  String? failDeletePath;

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<int> length(String path) => _delegate.length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) => _delegate.readChunks(path, start: start, endExclusive: endExclusive);

  @override
  Future<void> delete(String path) {
    if (path == failDeletePath) {
      throw FileSystemException('synthetic source cleanup failure', path);
    }
    return _delegate.delete(path);
  }
}

final class _GatedArtifactBytes implements ArtifactBytes {
  _GatedArtifactBytes({required this.sourcePath});

  final String sourcePath;
  final ArtifactBytes _delegate = const LocalArtifactBytes();
  final Completer<void> firstSourceReadStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  int sourceReadStarts = 0;

  void releaseSourceReads() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<int> length(String path) => _delegate.length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    if (path == sourcePath) {
      sourceReadStarts++;
      if (!firstSourceReadStarted.isCompleted) {
        firstSourceReadStarted.complete();
      }
      await _release.future;
    }
    yield* _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    );
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _MemorySafTreeIo implements SafTreeIo {
  final Map<String, Uint8List> storage = <String, Uint8List>{};
  final Map<int, ({String path, int position})> _handles =
      <int, ({String path, int position})>{};
  int _nextHandle = 1;

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) async {
    if (!storage.containsKey(relativePath)) {
      if (mode == SafWriteMode.writeTruncate ||
          mode == SafWriteMode.writeAppend) {
        storage[relativePath] = Uint8List(0);
      } else {
        return null;
      }
    } else if (mode == SafWriteMode.writeTruncate) {
      storage[relativePath] = Uint8List(0);
    }
    final handle = _nextHandle++;
    final position = mode == SafWriteMode.writeAppend
        ? storage[relativePath]!.lengthInBytes
        : 0;
    _handles[handle] = (path: relativePath, position: position);
    return handle;
  }

  @override
  Future<Uint8List> read(int handle, int length) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid SAF handle');
    final bytes = storage[state.path] ?? Uint8List(0);
    final end = (state.position + length).clamp(0, bytes.lengthInBytes);
    _handles[handle] = (path: state.path, position: end);
    return Uint8List.fromList(bytes.sublist(state.position, end));
  }

  @override
  Future<void> write(int handle, Uint8List bytes) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid SAF handle');
    final existing = storage[state.path] ?? Uint8List(0);
    final builder = BytesBuilder(copy: false);
    builder.add(existing.sublist(0, state.position));
    builder.add(bytes);
    if (state.position + bytes.lengthInBytes < existing.lengthInBytes) {
      builder.add(existing.sublist(state.position + bytes.lengthInBytes));
    }
    storage[state.path] = builder.takeBytes();
    _handles[handle] = (
      path: state.path,
      position: state.position + bytes.lengthInBytes,
    );
  }

  @override
  Future<int?> length(int handle) async {
    final state = _handles[handle];
    if (state == null) return null;
    return storage[state.path]?.lengthInBytes;
  }

  @override
  Future<void> seek(int handle, int position) async {
    final state = _handles[handle];
    if (state == null) throw StateError('invalid SAF handle');
    _handles[handle] = (path: state.path, position: position);
  }

  @override
  Future<void> close(int handle) async {
    _handles.remove(handle);
  }

  @override
  Future<bool> delete(String relativePath) async =>
      storage.remove(relativePath) != null;

  @override
  Future<bool> rename(String relativePath, String newRelativePath) async {
    if (!storage.containsKey(relativePath) ||
        storage.containsKey(newRelativePath)) {
      return false;
    }
    storage[newRelativePath] = storage.remove(relativePath)!;
    return true;
  }

  @override
  Future<bool> exists(String relativePath) async =>
      storage.containsKey(relativePath);

  @override
  Future<List<SafTreeFile>> list(String relativePath) async =>
      const <SafTreeFile>[];
}
