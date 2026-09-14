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
    'cleanup debt survives reopen and is retried without moving authority back',
    () async {
      final roots = await _MigrationRoots.create('cleanup-reopen');
      addTearDown(roots.delete);
      final failingBytes = _DeleteFailArtifactBytes();
      final first = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: failingBytes,
      );
      final id = _id('cleanup-reopen');
      final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5, 9, 2, 6]);
      await first.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await first.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}committed.bin';
      failingBytes.failDeletePath = sourcePath;

      final firstResult = await first.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(firstResult.sourceCleanupComplete, isFalse);
      await first.close();

      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final debt = await between.getArtifactReplicaMigration(before.replicaId);
      expect(debt, isNotNull);
      expect(debt!.phase, ArtifactReplicaMigrationPhase.cleanupPending);
      expect(
        (await between.listArtifactReplicas(debt.replicaId)).single.accessLocator,
        destination,
      );
      await between.close();
      expect(await File(sourcePath).exists(), isTrue);

      final reopened = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      final retry = await reopened.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(retry.sourceCleanupComplete, isTrue);
      expect(retry.replica.accessLocator, destination);
      expect(await File(sourcePath).exists(), isFalse);
      expect(await File(destination).readAsBytes(), bytes);
      await reopened.close();

      final after = SqliteIndex(indexPath);
      await after.open();
      expect(await after.getArtifactReplicaMigration(before.replicaId), isNull);
      expect(
        (await after.listArtifactReplicas(before.artifactId)).single.accessLocator,
        destination,
      );
      await after.close();
    },
  );

  test(
    'cleanupPending debt is retried asynchronously on reopen without explicit migration',
    () async {
      final roots = await _MigrationRoots.create('cleanup-auto-reopen');
      addTearDown(roots.delete);
      final failingBytes = _DeleteFailArtifactBytes();
      final first = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: failingBytes,
      );
      final id = _id('cleanup-auto-reopen');
      final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8]);
      await first.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await first.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}auto.bin';
      failingBytes.failDeletePath = sourcePath;
      final migrated = await first.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(migrated.sourceCleanupComplete, isFalse);
      await first.close();
      expect(await File(sourcePath).exists(), isTrue);

      final reopened = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await reopened.close();

      expect(await File(sourcePath).exists(), isFalse,
          reason: 'cleanupPending should reuse the asynchronous cleanup drainer');
      expect(await File(destination).readAsBytes(), bytes);
      final index = SqliteIndex(CacheLayout(roots.source.path).dbPath);
      await index.open();
      expect(await index.getArtifactReplicaMigration(before.replicaId), isNull);
      await index.close();
    },
  );


  test(
    'cleanupPending source follows a re-proven Direct alias after remount',
    () async {
      final roots = await _MigrationRoots.create('cleanup-remount');
      const safTree =
          'content://com.android.externalstorage.documents/tree/ABCD-1234%3ACleanup';
      final remounted = Directory('${roots.source.path}-remounted');
      addTearDown(() async {
        await roots.delete();
        if (await remounted.exists()) {
          await remounted.delete(recursive: true);
        }
      });
      final indexPath = defaultChapterDownloadMetadataPath(roots.app.path);
      final failingBytes = _DeleteFailArtifactBytes();
      final first = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        indexPath: indexPath,
        bytes: failingBytes,
      );
      final id = _id('cleanup-remount');
      final bytes = Uint8List.fromList(<int>[1, 4, 1, 4, 2, 1, 3, 5]);
      await first.storePromotedArtifact(id: id, bytes: bytes);
      await first.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(roots.source.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      final before = (await first.artifactReplicasFor(id)).single;
      final oldSourcePath = before.accessLocator;
      final relative = oldSourcePath.substring(roots.source.path.length + 1);
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}committed.bin';
      failingBytes.failDeletePath = oldSourcePath;
      final migrated = await first.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(migrated.sourceCleanupComplete, isFalse);
      await first.close();

      await roots.source.rename(remounted.path);
      final remountedSourcePath =
          '${remounted.path}${Platform.pathSeparator}$relative';
      expect(await File(remountedSourcePath).readAsBytes(), bytes);
      expect(await File(oldSourcePath).exists(), isFalse);

      final reopened = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: remounted.path,
        indexPath: indexPath,
      );
      await reopened.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(remounted.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      for (var attempt = 0;
          attempt < 20 && await File(remountedSourcePath).exists();
          attempt++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        await File(remountedSourcePath).exists(),
        isFalse,
        reason:
            'cleanupPending must resolve the current proven Direct alias instead of treating the stale mount path as already absent',
      );
      await reopened.close();

      final index = SqliteIndex(indexPath);
      await index.open();
      expect(await index.getArtifactReplicaMigration(before.replicaId), isNull);
      await index.close();
      expect(await File(destination).readAsBytes(), bytes);
    },
  );

  test(
    'direct interrupted copy resumes from verified durable temporary after reopen',
    () async {
      final roots = await _MigrationRoots.create('direct-resume');
      addTearDown(roots.delete);
      final id = _id('direct-resume');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 97, (index) => index % 227),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();

      final destination =
          '${roots.destination.path}${Platform.pathSeparator}resumed.bin';
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
      );
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: interruptedBytes,
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: roots.destination.path,
          control: control,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.cancelled,
          ),
        ),
      );
      await interrupted.close();

      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final migration =
          await between.getArtifactReplicaMigration(before.replicaId);
      expect(migration, isNotNull);
      expect(migration!.phase, ArtifactReplicaMigrationPhase.copying);
      expect(
        (await between.listArtifactReplicas(before.artifactId)).single.accessLocator,
        sourcePath,
        reason: 'partial temporary bytes are never replica authority',
      );
      await between.close();
      final temporary = File(migration.temporaryAccessLocator);
      final durablePrefixLength = await temporary.length();
      expect(durablePrefixLength, greaterThan(0));
      expect(durablePrefixLength, lessThan(bytes.lengthInBytes));
      expect(await File(destination).exists(), isFalse);
      expect(await File(sourcePath).readAsBytes(), bytes);

      final recoveryOnly = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await recoveryOnly.close();
      expect(await temporary.exists(), isTrue,
          reason: 'generic cleanup recovery must never delete a resumable copying temp');

      final recordingBytes = _RecordingArtifactBytes(sourcePath: sourcePath);
      final resumed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: recordingBytes,
      );
      final result = await resumed.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(result.sourceCleanupComplete, isTrue);
      expect(
        recordingBytes.sourceReadStarts,
        contains(durablePrefixLength),
        reason: 'after prefix proof, the body copy must restart at the temp length',
      );
      expect(await File(destination).readAsBytes(), bytes);
      expect(await File(sourcePath).exists(), isFalse);
      expect(await temporary.exists(), isFalse);
      await resumed.close();

      final after = SqliteIndex(indexPath);
      await after.open();
      expect(await after.getArtifactReplicaMigration(before.replicaId), isNull);
      await after.close();
    },
  );


  test(
    'copying destination and temporary rebind after a Direct remount',
    () async {
      final roots = await _MigrationRoots.create('destination-remount');
      const safTree =
          'content://com.android.externalstorage.documents/tree/ABCD-1234%3ADestination';
      final remounted = Directory('${roots.destination.path}-remounted');
      addTearDown(() async {
        await roots.delete();
        if (await remounted.exists()) {
          await remounted.delete(recursive: true);
        }
      });
      final indexPath = defaultChapterDownloadMetadataPath(roots.app.path);
      final id = _id('destination-remount');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 137, (index) => index % 211),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        indexPath: indexPath,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      await seed.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(roots.destination.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();

      final oldDestination =
          '${roots.destination.path}${Platform.pathSeparator}resumed.bin';
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
      );
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        indexPath: indexPath,
        bytes: interruptedBytes,
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: oldDestination,
          destinationStorageRootId: safTree,
          control: control,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.cancelled,
          ),
        ),
      );
      await interrupted.close();

      final between = SqliteIndex(indexPath);
      await between.open();
      final pending = await between.getArtifactReplicaMigration(before.replicaId);
      await between.close();
      expect(pending, isNotNull);
      final oldTemporary = pending!.temporaryAccessLocator;
      final tempRelative = oldTemporary.substring(roots.destination.path.length + 1);
      final prefixLength = await File(oldTemporary).length();
      expect(prefixLength, greaterThan(0));
      expect(prefixLength, lessThan(bytes.lengthInBytes));

      await roots.destination.rename(remounted.path);
      final newDestination =
          '${remounted.path}${Platform.pathSeparator}resumed.bin';
      final rebasedTemporary =
          '${remounted.path}${Platform.pathSeparator}$tempRelative';
      expect(await File(rebasedTemporary).length(), prefixLength);
      expect(await File(oldTemporary).exists(), isFalse);

      final recordingBytes = _RecordingArtifactBytes(sourcePath: sourcePath);
      final resumed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        indexPath: indexPath,
        bytes: recordingBytes,
      );
      await resumed.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(remounted.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      final result = await resumed.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: newDestination,
        destinationStorageRootId: safTree,
      );
      expect(result.sourceCleanupComplete, isTrue);
      expect(result.replica.accessLocator, newDestination);
      expect(
        recordingBytes.sourceReadStarts,
        contains(prefixLength),
        reason:
            'the durable temporary must be rebound to the new mount path and resumed instead of restarted',
      );
      expect(await File(newDestination).readAsBytes(), bytes);
      expect(await File(rebasedTemporary).exists(), isFalse);
      await resumed.close();

      final after = SqliteIndex(indexPath);
      await after.open();
      expect(await after.getArtifactReplicaMigration(before.replicaId), isNull);
      await after.close();
    },
  );

  test(
    'corrupted durable temporary prefix is rejected and recopied from zero',
    () async {
      final roots = await _MigrationRoots.create('corrupt-resume-prefix');
      addTearDown(roots.delete);
      final id = _id('corrupt-resume-prefix');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 113, (index) => index % 219),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}repaired.bin';
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
      );
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: interruptedBytes,
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: roots.destination.path,
          control: control,
        ),
        throwsA(isA<Failure>()),
      );
      await interrupted.close();

      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final migration =
          await between.getArtifactReplicaMigration(before.replicaId);
      await between.close();
      final temporary = File(migration!.temporaryAccessLocator);
      final prefixLength = await temporary.length();
      expect(prefixLength, greaterThan(0));
      final tempBytes = await temporary.readAsBytes();
      tempBytes[0] ^= 0xff;
      await temporary.writeAsBytes(tempBytes, flush: true);

      final recordingBytes = _RecordingArtifactBytes(sourcePath: sourcePath);
      final resumed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: recordingBytes,
      );
      final result = await resumed.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: roots.destination.path,
      );
      expect(result.sourceCleanupComplete, isTrue);
      expect(
        recordingBytes.sourceReadStarts.where((start) => start == 0).length,
        greaterThanOrEqualTo(2),
        reason: 'one read proves the prefix mismatch and another recopies from zero',
      );
      expect(recordingBytes.sourceReadStarts, isNot(contains(prefixLength)));
      expect(await File(destination).readAsBytes(), bytes);
      expect(await temporary.exists(), isFalse);
      await resumed.close();
    },
  );

  test(
    'final logical invalidation removes a non-authoritative migration temporary',
    () async {
      final roots = await _MigrationRoots.create('invalidate-copying');
      addTearDown(roots.delete);
      final id = _id('invalidate-copying');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 127, (index) => index % 217),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}never-committed.bin';
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
      );
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: interruptedBytes,
      );
      await expectLater(
        store.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: roots.destination.path,
          control: control,
        ),
        throwsA(isA<Failure>()),
      );
      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final migration =
          await between.getArtifactReplicaMigration(before.replicaId);
      await between.close();
      expect(migration, isNotNull);
      expect(await File(migration!.temporaryAccessLocator).exists(), isTrue);

      await store.invalidateArtifact(id);
      expect(await File(sourcePath).exists(), isFalse);
      expect(await File(migration.temporaryAccessLocator).exists(), isFalse);
      expect(await File(destination).exists(), isFalse);
      await store.close();

      final after = SqliteIndex(indexPath);
      await after.open();
      expect(await after.get(id.key), isNull);
      expect(await after.getArtifactReplicaMigration(before.replicaId), isNull);
      expect(await after.listArtifactReplicas(before.artifactId), isEmpty);
      await after.close();
    },
  );

  test(
    'final invalidation cleans a copying temp through a re-proven remount alias',
    () async {
      final roots = await _MigrationRoots.create('invalidate-remount-copying');
      final remountParent = await Directory.systemTemp.createTemp(
        'zic-migrate-remount-invalidate-parent-',
      );
      final remounted = Directory(
        '${remountParent.path}${Platform.pathSeparator}destination',
      );
      addTearDown(() async {
        await roots.delete();
        if (await remountParent.exists()) {
          await remountParent.delete(recursive: true);
        }
      });
      const safTree =
          'content://com.android.externalstorage.documents/tree/ABCD-1234%3AMigrate';
      final id = _id('invalidate-remount-copying');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 157, (index) => index % 211),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();

      final destination =
          '${roots.destination.path}${Platform.pathSeparator}never-committed.bin';
      final control = _TestTaskControl(priority: 0);
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: _InterruptAfterFirstSourceChunkArtifactBytes(
          sourcePath: sourcePath,
          control: control,
        ),
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: roots.destination.path,
          control: control,
        ),
        throwsA(isA<Failure>()),
      );
      final indexPath = CacheLayout(roots.source.path).dbPath;
      final firstMigration =
          await interrupted.indexedRecords().then((_) async {
        final index = SqliteIndex(indexPath);
        await index.open();
        final migration =
            await index.getArtifactReplicaMigration(before.replicaId);
        await index.close();
        return migration;
      });
      expect(firstMigration, isNotNull);
      await interrupted.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(roots.destination.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      await interrupted.close();

      final oldDestinationRoot = roots.destination.path;
      await roots.destination.rename(remounted.path);
      final relativeTemp = firstMigration!.temporaryAccessLocator.substring(
        oldDestinationRoot.length + 1,
      );
      final remountedTemp = File(
        '${remounted.path}${Platform.pathSeparator}$relativeTemp',
      );
      expect(await remountedTemp.exists(), isTrue);

      final reopened = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        indexPath: indexPath,
      );
      await reopened.registerStorageRootAccessAliasProof(
        StorageRootAccessAliasProof(
          direct: DirectStorageAccessLocator(remounted.path),
          saf: const SafStorageAccessLocator(safTree),
        ),
      );
      await reopened.invalidateArtifact(id);
      expect(await remountedTemp.exists(), isFalse);
      expect(await File(sourcePath).exists(), isFalse);
      await reopened.close();

      final checked = SqliteIndex(indexPath);
      await checked.open();
      expect(await checked.getArtifactReplicaMigration(before.replicaId), isNull);
      expect(await checked.listStorageCleanupDebts(), isEmpty);
      await checked.close();
    },
  );

  test(
    'structural source retirement during copy removes durable migration temp',
    () async {
      final roots = await _MigrationRoots.create('retire-copying');
      addTearDown(roots.delete);
      final id = _id('retire-copying');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 193, (index) => index % 229),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();

      final failingBytes = _FailAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
      );
      final store = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: failingBytes,
      );
      final destination =
          '${roots.destination.path}${Platform.pathSeparator}never-committed.bin';
      await expectLater(
        store
            .migrateArtifactReplica(
              id: id,
              replicaId: before.replicaId,
              destinationAccessLocator: destination,
              destinationStorageRootId: roots.destination.path,
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<ArtifactReadFailure>().having(
            (value) => value.kind,
            'kind',
            ArtifactReadFailureKind.shortRead,
          ),
        ),
      );

      expect(await File(sourcePath).exists(), isFalse);
      expect(await File(destination).exists(), isFalse);
      expect(await store.artifactReplicasFor(id), isEmpty);
      await store.close();
      expect(
        await roots.destination
            .list()
            .where((entry) => entry.path.contains('.zic-migrate-'))
            .isEmpty,
        isTrue,
        reason:
            'structural retirement defers generated-temp cleanup to avoid re-entering the storage scheduler from a failing read',
      );

      final index = SqliteIndex(CacheLayout(roots.source.path).dbPath);
      await index.open();
      expect(await index.getArtifactReplicaMigration(before.replicaId), isNull);
      await index.close();
    },
  );

  test(
    'SAF interrupted copy reopens the verified durable temporary in append mode',
    () async {
      final roots = await _MigrationRoots.create('saf-resume');
      addTearDown(roots.delete);
      final saf = _MemorySafTreeIo();
      const safTree =
          'content://com.android.externalstorage.documents/tree/primary%3ASafResume';
      final id = _id('saf-resume');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 131, (index) => index % 223),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        safMirror: saf,
        safTreeUri: safTree,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      expect(parseSafRecordPath(sourcePath), isNull);
      await seed.close();

      final destination = encodeSafRecordPath(
        treeUri: safTree,
        relativePath: 'offline/resumed.bin',
      );
      final firstDelegate = CompositeArtifactBytes(
        local: const LocalArtifactBytes(),
        saf: SafArtifactBytes(saf, treeUri: safTree),
      );
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
        delegate: firstDelegate,
      );
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: interruptedBytes,
        safMirror: saf,
        safTreeUri: safTree,
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: safTree,
          control: control,
        ),
        throwsA(
          isA<Failure>().having(
            (value) => value.code,
            'code',
            ErrorCode.cancelled,
          ),
        ),
      );
      await interrupted.close();

      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final migration =
          await between.getArtifactReplicaMigration(before.replicaId);
      expect(migration, isNotNull);
      expect(migration!.phase, ArtifactReplicaMigrationPhase.copying);
      await between.close();
      final temporary = parseSafRecordPath(migration.temporaryAccessLocator)!;
      final durablePrefixLength = saf.storage[temporary.relativePath]!.lengthInBytes;
      expect(durablePrefixLength, greaterThan(0));
      expect(durablePrefixLength, lessThan(bytes.lengthInBytes));
      expect(saf.storage.containsKey('offline/resumed.bin'), isFalse);
      expect(await File(sourcePath).readAsBytes(), bytes);

      saf.opens.clear();
      final secondDelegate = CompositeArtifactBytes(
        local: const LocalArtifactBytes(),
        saf: SafArtifactBytes(saf, treeUri: safTree),
      );
      final recordingBytes = _RecordingArtifactBytes(
        sourcePath: sourcePath,
        delegate: secondDelegate,
      );
      final resumed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: recordingBytes,
        safMirror: saf,
        safTreeUri: safTree,
      );
      final result = await resumed.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: safTree,
      );
      expect(result.sourceCleanupComplete, isTrue);
      expect(
        saf.opens,
        contains(
          (path: temporary.relativePath, mode: SafWriteMode.writeAppend),
        ),
        reason: 'a proven SAF temporary must be reopened for append, not truncate',
      );
      expect(recordingBytes.sourceReadStarts, contains(durablePrefixLength));
      expect(saf.storage['offline/resumed.bin'], bytes);
      expect(saf.storage.containsKey(temporary.relativePath), isFalse);
      expect(await File(sourcePath).exists(), isFalse);
      await resumed.close();

      final after = SqliteIndex(indexPath);
      await after.open();
      expect(await after.getArtifactReplicaMigration(before.replicaId), isNull);
      await after.close();
    },
  );

  test(
    'SAF resume restarts from zero when provider cannot prove temporary length',
    () async {
      final roots = await _MigrationRoots.create('saf-no-length');
      addTearDown(roots.delete);
      final saf = _MemorySafTreeIo();
      const safTree =
          'content://com.android.externalstorage.documents/tree/primary%3ASafNoLength';
      final id = _id('saf-no-length');
      final bytes = Uint8List.fromList(
        List<int>.generate(1024 * 1024 + 149, (index) => index % 211),
      );
      final seed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        safMirror: saf,
        safTreeUri: safTree,
      );
      await seed.storePromotedArtifact(id: id, bytes: bytes);
      final before = (await seed.artifactReplicasFor(id)).single;
      final sourcePath = before.accessLocator;
      await seed.close();
      final destination = encodeSafRecordPath(
        treeUri: safTree,
        relativePath: 'offline/no-length.bin',
      );
      final firstDelegate = CompositeArtifactBytes(
        local: const LocalArtifactBytes(),
        saf: SafArtifactBytes(saf, treeUri: safTree),
      );
      final control = _TestTaskControl(priority: 0);
      final interruptedBytes = _InterruptAfterFirstSourceChunkArtifactBytes(
        sourcePath: sourcePath,
        control: control,
        delegate: firstDelegate,
      );
      final interrupted = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: interruptedBytes,
        safMirror: saf,
        safTreeUri: safTree,
      );
      await expectLater(
        interrupted.migrateArtifactReplica(
          id: id,
          replicaId: before.replicaId,
          destinationAccessLocator: destination,
          destinationStorageRootId: safTree,
          control: control,
        ),
        throwsA(isA<Failure>()),
      );
      await interrupted.close();

      final indexPath = CacheLayout(roots.source.path).dbPath;
      final between = SqliteIndex(indexPath);
      await between.open();
      final migration =
          await between.getArtifactReplicaMigration(before.replicaId);
      await between.close();
      expect(migration, isNotNull);
      final temporary = parseSafRecordPath(migration!.temporaryAccessLocator)!;
      expect(saf.storage[temporary.relativePath]!.lengthInBytes, greaterThan(0));

      saf.suppressedLengthCalls = 1;
      saf.opens.clear();
      final secondDelegate = CompositeArtifactBytes(
        local: const LocalArtifactBytes(),
        saf: SafArtifactBytes(saf, treeUri: safTree),
      );
      final recordingBytes = _RecordingArtifactBytes(
        sourcePath: sourcePath,
        delegate: secondDelegate,
      );
      final resumed = await PersistentDownloadArtifactStore.open(
        roots.app.path,
        directory: roots.source.path,
        bytes: recordingBytes,
        safMirror: saf,
        safTreeUri: safTree,
      );
      final result = await resumed.migrateArtifactReplica(
        id: id,
        replicaId: before.replicaId,
        destinationAccessLocator: destination,
        destinationStorageRootId: safTree,
      );
      expect(result.sourceCleanupComplete, isTrue);
      expect(
        saf.opens,
        contains(
          (path: temporary.relativePath, mode: SafWriteMode.writeTruncate),
        ),
        reason: 'unprovable provider length must force a fresh temporary',
      );
      expect(
        saf.opens,
        isNot(
          contains(
            (path: temporary.relativePath, mode: SafWriteMode.writeAppend),
          ),
        ),
      );
      expect(recordingBytes.sourceReadStarts, contains(0));
      expect(saf.storage['offline/no-length.bin'], bytes);
      await resumed.close();
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

final class _InterruptAfterFirstSourceChunkArtifactBytes
    implements ArtifactBytes {
  _InterruptAfterFirstSourceChunkArtifactBytes({
    required this.sourcePath,
    required this.control,
    ArtifactBytes? delegate,
  }) : _delegate = delegate ?? const LocalArtifactBytes();

  final String sourcePath;
  final _TestTaskControl control;
  final ArtifactBytes _delegate;
  bool _cancelled = false;

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
    await for (final chunk in _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    )) {
      yield chunk;
      if (path == sourcePath && !_cancelled) {
        _cancelled = true;
        control.cancel();
      }
    }
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _RecordingArtifactBytes implements ArtifactBytes {
  _RecordingArtifactBytes({
    required this.sourcePath,
    ArtifactBytes? delegate,
  }) : _delegate = delegate ?? const LocalArtifactBytes();

  final String sourcePath;
  final ArtifactBytes _delegate;
  final List<int> sourceReadStarts = <int>[];

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<int> length(String path) => _delegate.length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) {
    if (path == sourcePath) sourceReadStarts.add(start);
    return _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    );
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _FailAfterFirstSourceChunkArtifactBytes implements ArtifactBytes {
  _FailAfterFirstSourceChunkArtifactBytes({required this.sourcePath});

  final String sourcePath;
  final ArtifactBytes _delegate = const LocalArtifactBytes();
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
  }) async* {
    await for (final chunk in _delegate.readChunks(
      path,
      start: start,
      endExclusive: endExclusive,
    )) {
      yield chunk;
      if (path == sourcePath && !_failed) {
        _failed = true;
        throw ArtifactReadFailure(
          kind: ArtifactReadFailureKind.shortRead,
          accessLocator: path,
          failedOffset: start + chunk.lengthInBytes,
          bytesEmitted: chunk.lengthInBytes,
        );
      }
    }
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);
}

final class _MemorySafTreeIo implements SafTreeIo {
  final Map<String, Uint8List> storage = <String, Uint8List>{};
  final List<({String path, SafWriteMode mode})> opens =
      <({String path, SafWriteMode mode})>[];
  int suppressedLengthCalls = 0;
  final Map<int, ({String path, int position})> _handles =
      <int, ({String path, int position})>{};
  int _nextHandle = 1;

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) async {
    opens.add((path: relativePath, mode: mode));
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
    if (suppressedLengthCalls > 0) {
      suppressedLengthCalls--;
      return null;
    }
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
