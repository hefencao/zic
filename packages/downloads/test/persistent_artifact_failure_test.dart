import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('unclean-store marker runs startup recovery without taxing clean opens',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-startup-recovery-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final orphan = File(
      '${layout.finalDir}${Platform.pathSeparator}crash-orphan.bin',
    );
    await orphan.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
    final marker = File(
      '${layout.root}${Platform.pathSeparator}.zic-cache-recovery-required',
    );
    await marker.parent.create(recursive: true);
    await marker.writeAsString('stale-process-owner', flush: true);

    final store = await PersistentDownloadArtifactStore.open(root.path);

    expect(await orphan.exists(), isFalse,
        reason: 'crash evidence must activate the existing CacheScanner');
    expect(await marker.exists(), isTrue,
        reason: 'the current open remains marked dirty until clean close');
    await store.close();
    expect(await marker.exists(), isFalse);
  });

  test('promoted cache body survives dirty-reopen startup recovery', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-promoted-dirty-reopen-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final id = _id('promoted-dirty-reopen');
    final bytes = Uint8List.fromList(<int>[1, 4, 1, 5, 9, 2, 6, 5]);

    final first = await PersistentDownloadArtifactStore.open(root.path);
    await first.storePromotedArtifact(id: id, bytes: bytes);

    final artifact = layout.artifactFor(id);
    final metaFile = File(artifact.finalMetaPath);
    final rawMeta = jsonDecode(await metaFile.readAsString());
    expect(rawMeta, isA<Map>());
    final meta = Map<String, Object?>.from(rawMeta as Map);
    expect(meta['artifactState'], 'ready');
    final rawDownload = meta['download'];
    expect(rawDownload, isA<Map>(),
        reason: 'new session metadata remains self-describing before DB commit');
    expect(
      DownloadId.fromJson(Map<String, Object?>.from(rawDownload as Map)),
      id,
    );
    await first.close();

    final marker = File(
      '${layout.root}${Platform.pathSeparator}.zic-cache-recovery-required',
    );
    await marker.writeAsString('stale-process-owner', flush: true);

    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    expect(await reopened.readPromoted(id), bytes,
        reason: 'dirty-reopen CacheScanner must preserve a valid promoted body');
    expect(await File(artifact.finalPath).length(), bytes.lengthInBytes);
    await reopened.close();
  });

  test('dirty reopen and repeated store ignore READY sidecar ownership',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-ready-sidecar-nonauthority-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final id = _id('ready-sidecar-nonauthority');
    final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5, 9, 2, 6]);

    final first = await PersistentDownloadArtifactStore.open(root.path);
    await first.storePromotedArtifact(id: id, bytes: bytes);
    final before = await first.index.get(id.key);
    expect(before, isNotNull);
    expect(before!.state, CacheState.ready);
    expect(
      await (first.index as SqliteIndex)
          .listArtifactReplicas(before.effectiveArtifactId),
      hasLength(1),
    );
    final artifact = layout.artifactFor(id);
    await first.close();

    final raw = Map<String, Object?>.from(
      jsonDecode(await File(artifact.finalMetaPath).readAsString()) as Map,
    )
      ..remove('download')
      ..remove('downloadKey');
    await File(artifact.finalMetaPath).writeAsString(
      jsonEncode(raw),
      flush: true,
    );
    final marker = File(
      '${layout.root}${Platform.pathSeparator}.zic-cache-recovery-required',
    );
    await marker.writeAsString('stale-process-owner', flush: true);

    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    expect(await reopened.readPromoted(id), bytes,
        reason: 'sealed replica authority must not depend on sidecar owner fields');
    await reopened.storePromotedArtifact(id: id, bytes: bytes);
    final afterMeta = Map<String, Object?>.from(
      jsonDecode(await File(artifact.finalMetaPath).readAsString()) as Map,
    );
    expect(afterMeta['download'], isNull,
        reason: 'reusing READY must not recreate a session to repair metadata');
    final after = await reopened.index.get(id.key);
    expect(after, isNotNull);
    expect(after!.effectiveArtifactId, before.effectiveArtifactId);
    expect(
      await (reopened.index as SqliteIndex)
          .listArtifactReplicas(after.effectiveArtifactId),
      hasLength(1),
    );
    await reopened.close();
  });

  test('direct cleanup debt drains asynchronously without blocking store open',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-direct-cleanup-debt-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final temporary = File(
      '${layout.finalDir}${Platform.pathSeparator}orphan.zic-tmp-123',
    );
    await temporary.writeAsBytes(<int>[9, 8, 7], flush: true);
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: temporary.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    final scheduler = StorageWriteScheduler(
      localReadScheduler: ArtifactCacheReadScheduler(),
    );
    final blocker = await scheduler.acquireQuantum();

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      storageWriteScheduler: scheduler,
    );
    expect(await temporary.exists(), isTrue,
        reason: 'store open must not wait for asynchronous cleanup I/O');
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.pendingCount, 1,
        reason: 'cleanup should wait behind the shared storage-write capacity');

    blocker.release();
    await store.close();
    expect(await temporary.exists(), isFalse);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    expect(await index.listStorageCleanupDebts(), isEmpty);
    await index.close();
  });

  test('signed padded migration temp token remains eligible cleanup debt', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-negative-migration-temp-debt-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final temporary = File(
      '${layout.finalDir}${Platform.pathSeparator}'
      'orphan.zic-migrate-0-8747f636549eb2.part',
    );
    await temporary.writeAsBytes(<int>[9, 7, 5, 3], flush: true);
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: temporary.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
    );

    final store = await PersistentDownloadArtifactStore.open(root.path);
    await store.close();

    expect(await temporary.exists(), isFalse);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    expect(await index.listStorageCleanupDebts(), isEmpty);
    await index.close();
  });

  test('negative migration temp token remains eligible cleanup debt', () async {
    final root = await Directory.systemTemp.createTemp('zic-negative-migration-temp-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final valid = File(
      '${layout.finalDir}${Platform.pathSeparator}page.bin.zic-migrate--123456789abcdef.part',
    );
    final malformed = File(
      '${layout.finalDir}${Platform.pathSeparator}page.bin.zic-migrate-1234-56789abcdef.part',
    );
    await valid.writeAsBytes(<int>[1, 2, 3], flush: true);
    await malformed.writeAsBytes(<int>[4, 5, 6], flush: true);
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: valid.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: malformed.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 2,
        touchedUs: 2,
      ),
    );

    final store = await PersistentDownloadArtifactStore.open(root.path);
    await store.close();

    expect(await valid.exists(), isFalse);
    expect(await malformed.exists(), isTrue);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final debts = await index.listStorageCleanupDebts();
    expect(debts, hasLength(1));
    expect(debts.single.accessLocator, malformed.path);
    await index.close();
  });

  test('obsolete sealed source debt removes only still-matching old bytes',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-obsolete-source-debt-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final oldBytes = Uint8List.fromList(<int>[1, 3, 3, 7]);
    final obsolete = File(
      '${layout.finalDir}${Platform.pathSeparator}obsolete.bin',
    );
    await obsolete.writeAsBytes(oldBytes, flush: true);
    final checksum = (Crc32()..add(oldBytes)).hex;
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: obsolete.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.obsoleteSealedSource,
        createdUs: 1,
        touchedUs: 1,
        expectedBytes: oldBytes.lengthInBytes,
        expectedChecksum: checksum,
        expectedChecksumAlgorithm: 'crc32',
      ),
    );

    final store = await PersistentDownloadArtifactStore.open(root.path);
    await store.close();

    expect(await obsolete.exists(), isFalse);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    expect(await index.listStorageCleanupDebts(), isEmpty);
    await index.close();
  });

  test('obsolete sealed debt follows a re-proven Direct alias after remount',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-obsolete-remount-app-',
    );
    final oldRoot = await Directory.systemTemp.createTemp(
      'zic-obsolete-remount-old-',
    );
    final newParent = await Directory.systemTemp.createTemp(
      'zic-obsolete-remount-new-parent-',
    );
    final newRoot = Directory(
      '${newParent.path}${Platform.pathSeparator}remounted',
    );
    addTearDown(() async {
      for (final directory in <Directory>[appRoot, oldRoot, newParent]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    const safTree =
        'content://com.android.externalstorage.documents/tree/ABCD-1234%3ABooks';
    final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5, 9]);
    final oldFile = File('${oldRoot.path}${Platform.pathSeparator}page.bin');
    await oldFile.writeAsBytes(bytes, flush: true);
    final checksum = (Crc32()..add(bytes)).hex;
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final index = SqliteIndex(indexPath);
    await index.open();
    final root = await index.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(oldRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
      verifiedUs: 10,
    );
    await index.putStorageCleanupDebt(
      StorageCleanupDebtRecord(
        accessLocator: oldFile.path,
        storageRootId: root.rootId,
        kind: StorageCleanupDebtKind.obsoleteSealedSource,
        createdUs: 11,
        touchedUs: 11,
        expectedBytes: bytes.lengthInBytes,
        expectedChecksum: checksum,
        expectedChecksumAlgorithm: 'crc32',
      ),
    );
    await index.close();

    await oldRoot.rename(newRoot.path);
    final newFile = File('${newRoot.path}${Platform.pathSeparator}page.bin');
    expect(await newFile.readAsBytes(), bytes);

    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: newRoot.path,
      indexPath: indexPath,
    );
    await store.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(newRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );
    await store.close();

    expect(await newFile.exists(), isFalse);
    final checked = SqliteIndex(indexPath);
    await checked.open();
    expect(await checked.listStorageCleanupDebts(), isEmpty);
    await checked.close();
  });

  for (final cacheFile in <bool>[true, false]) {
    test('obsolete source cleanup ${cacheFile ? 'deletes cache replacements' : 'preserves export replacements'}',
        () async {
      final root = await Directory.systemTemp.createTemp('zic-obsolete-replaced-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
      final directory = cacheFile
          ? layout.finalDir
          : '${layout.root}${Platform.pathSeparator}export';
      await Directory(directory).create(recursive: true);
      final oldBytes = Uint8List.fromList(<int>[2, 4, 6, 8]);
      final replacement = Uint8List.fromList(<int>[8, 6, 4, 2]);
      final obsolete = File(
        '$directory${Platform.pathSeparator}reused.bin',
      );
      await obsolete.writeAsBytes(replacement, flush: true);
      final checksum = (Crc32()..add(oldBytes)).hex;
      await _seedCleanupDebt(
        layout.dbPath,
        StorageCleanupDebtRecord(
          accessLocator: obsolete.path,
          storageRootId: layout.root,
          kind: StorageCleanupDebtKind.obsoleteSealedSource,
          createdUs: 1,
          touchedUs: 1,
          expectedBytes: oldBytes.lengthInBytes,
          expectedChecksum: checksum,
          expectedChecksumAlgorithm: 'crc32',
        ),
      );

      final store = await PersistentDownloadArtifactStore.open(root.path);
      await store.close();

      if (cacheFile) {
        expect(await obsolete.exists(), isFalse);
      } else {
        expect(await obsolete.readAsBytes(), replacement);
      }
      final index = SqliteIndex(layout.dbPath);
      await index.open();
      expect(await index.listStorageCleanupDebts(), isEmpty);
      await index.close();
    });
  }

  test('obsolete sealed source debt yields to a surviving durable replica authority',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-obsolete-authority-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final bytes = Uint8List.fromList(<int>[5, 7, 11, 13]);
    final file = File('${layout.finalDir}${Platform.pathSeparator}owned.bin');
    await file.writeAsBytes(bytes, flush: true);
    final checksum = (Crc32()..add(bytes)).hex;
    final id = _id('obsolete-authority');
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: file.path,
        bytes: bytes.lengthInBytes,
        checksum: checksum,
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'obsolete-authority-artifact',
        storageRootId: layout.root,
      ),
    );
    await index.putStorageCleanupDebt(
      StorageCleanupDebtRecord(
        accessLocator: file.path,
        storageRootId: layout.root,
        kind: StorageCleanupDebtKind.obsoleteSealedSource,
        createdUs: 2,
        touchedUs: 2,
        expectedBytes: bytes.lengthInBytes,
        expectedChecksum: checksum,
        expectedChecksumAlgorithm: 'crc32',
      ),
    );
    await index.close();

    final store = await PersistentDownloadArtifactStore.open(root.path);
    await store.close();

    expect(await file.readAsBytes(), bytes);
    final checked = SqliteIndex(layout.dbPath);
    await checked.open();
    expect(await checked.listStorageCleanupDebts(), isEmpty);
    expect(await checked.get(id.key), isNotNull);
    await checked.close();
  });

  test('SAF cleanup debt deletes only the exact locator without listing tree',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-cleanup-debt-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const treeUri = 'content://cleanup-tree/root';
    const relative = 'partial/page.part.zic-tmp-456';
    final io = _CleanupDebtSafIo()
      ..storage[relative] = Uint8List.fromList(<int>[1, 2, 3]);
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final locator = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: relative,
    );
    await _seedCleanupDebt(
      layout.dbPath,
      const StorageCleanupDebtRecord(
        accessLocator: 'saf-record://placeholder',
        storageRootId: treeUri,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
      replacementLocator: locator,
    );

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      safMirror: io,
      safTreeUri: treeUri,
    );
    await store.close();

    expect(io.storage.containsKey(relative), isFalse);
    expect(io.listCalls, 0,
        reason: 'cleanup recovery must never enumerate the SAF tree');
    expect(io.deletedPaths, <String>[relative]);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    expect(await index.listStorageCleanupDebts(), isEmpty);
    await index.close();
  });

  test('SAF cleanup I/O failure keeps exact cleanup debt durable', () async {
    final root = await Directory.systemTemp.createTemp('zic-saf-cleanup-failure-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const treeUri = 'content://cleanup-failure-tree/root';
    const relative = 'partial/page.part.zic-tmp-654';
    final io = _CleanupDebtSafIo(failDelete: true)
      ..storage[relative] = Uint8List.fromList(<int>[4, 5, 6]);
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final locator = encodeSafRecordPath(
      treeUri: treeUri,
      relativePath: relative,
    );
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: locator,
        storageRootId: treeUri,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
    );

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      safMirror: io,
      safTreeUri: treeUri,
    );
    await store.close();

    expect(io.storage.containsKey(relative), isTrue);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final debts = await index.listStorageCleanupDebts();
    expect(debts, hasLength(1));
    expect(debts.single.accessLocator, locator);
    await index.close();
  });

  test('cleanup debt for an unavailable SAF tree remains durable', () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-unavailable-saf-cleanup-debt-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    const oldTree = 'content://old-cleanup-tree/root';
    const currentTree = 'content://current-cleanup-tree/root';
    const relative = 'partial/page.part.zic-tmp-789';
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final locator = encodeSafRecordPath(
      treeUri: oldTree,
      relativePath: relative,
    );
    await _seedCleanupDebt(
      layout.dbPath,
      StorageCleanupDebtRecord(
        accessLocator: locator,
        storageRootId: oldTree,
        kind: StorageCleanupDebtKind.temporary,
        createdUs: 1,
        touchedUs: 1,
      ),
    );
    final io = _CleanupDebtSafIo();

    final store = await PersistentDownloadArtifactStore.open(
      root.path,
      safMirror: io,
      safTreeUri: currentTree,
    );
    await store.close();

    expect(io.deletedPaths, isEmpty);
    expect(io.listCalls, 0);
    final index = SqliteIndex(layout.dbPath);
    await index.open();
    final debts = await index.listStorageCleanupDebts();
    expect(debts, hasLength(1));
    expect(debts.single.accessLocator, locator);
    await index.close();
  });

  test('sealed persistent entry distinguishes hot-path trust from full CRC',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-sealed-trust-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('sealed-trust');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    await store.storePromotedArtifact(id: id, bytes: bytes);

    final entry = await store.openArtifactStream(id);

    expect(entry, isNotNull);
    expect(
      entry!.streamIntegrity,
      ArtifactReadIntegrityBasis.sealedMetadataLength,
    );
    expect(entry.fullReadIntegrity, ArtifactReadIntegrityBasis.crc32Verified);
  });

  test('persistent store can keep metadata outside the selected byte root',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-private-download-metadata-',
    );
    final byteRoot = await Directory.systemTemp.createTemp(
      'zic-private-download-bytes-',
    );
    addTearDown(() async {
      if (await appRoot.exists()) await appRoot.delete(recursive: true);
      if (await byteRoot.exists()) await byteRoot.delete(recursive: true);
    });
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: byteRoot.path,
      indexPath: indexPath,
    );
    addTearDown(store.close);
    final id = _id('private-metadata');
    final bytes = Uint8List.fromList(<int>[1, 4, 9, 16]);

    await store.storePromotedArtifact(id: id, bytes: bytes);

    expect(await File(indexPath).exists(), isTrue);
    expect(
      await File('${byteRoot.path}${Platform.pathSeparator}cache.sqlite').exists(),
      isFalse,
    );
    final record = (await store.indexedRecords())[id.key];
    expect(record, isNotNull);
    expect(record!.path.startsWith(byteRoot.path), isTrue);
    expect(await File(record.path).readAsBytes(), bytes);
  });

  test('shared artifact reads through artifact_object locator when binding path is stale', () async {
    final root = await Directory.systemTemp.createTemp('zic-artifact-object-read-');
    addTearDown(() => root.delete(recursive: true));
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final bytes = Uint8List.fromList(<int>[1, 3, 3, 7, 9]);
    final checksum = (Crc32()..add(bytes)).hex;
    final firstId = _id('artifact-object-old-binding');
    final secondId = _id('artifact-object-new-binding');
    final historicalRoot = '${root.path}/historical-root';
    final stalePath = '$historicalRoot/stale.bin';
    final authoritativePath = '${layout.finalDir}/authoritative.bin';
    await File(authoritativePath).writeAsBytes(bytes, flush: true);

    final index = SqliteIndex(layout.dbPath);
    await index.open();
    await index.put(
      CacheRec(
        id: firstId,
        state: CacheState.ready,
        path: stalePath,
        bytes: bytes.length,
        checksum: checksum,
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'shared-artifact-object',
        storageRootId: historicalRoot,
      ),
    );
    await index.put(
      CacheRec(
        id: secondId,
        state: CacheState.ready,
        path: authoritativePath,
        bytes: bytes.length,
        checksum: checksum,
        createdUs: 2,
        touchedUs: 2,
        artifactId: 'shared-artifact-object',
        storageRootId: layout.root,
      ),
    );
    await index.close();

    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final entry = await store.openArtifactStream(firstId);
    expect(entry, isNotNull);
    final read = <int>[];
    await for (final chunk in entry!.open(start: 0)) {
      read.addAll(chunk);
    }
    expect(read, bytes);
    expect((await store.indexedRecords()).containsKey(firstId.key), isTrue);
  });

  test('structural failure deletes authoritative artifact_object locator, not stale binding path',
      () async {
    final root = await Directory.systemTemp.createTemp('zic-artifact-object-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final expected = Uint8List.fromList(<int>[2, 4, 6, 8, 10, 12]);
    final checksum = (Crc32()..add(expected)).hex;
    final firstId = _id('artifact-object-cleanup-old');
    final secondId = _id('artifact-object-cleanup-current');
    final stalePath = '${layout.finalDir}/stale-binding.bin';
    final authoritativePath = '${layout.finalDir}/authoritative-corrupt.bin';
    await File(stalePath).writeAsBytes(<int>[99], flush: true);
    await File(authoritativePath).writeAsBytes(<int>[2, 4, 6], flush: true);

    final index = SqliteIndex(layout.dbPath);
    await index.open();
    await index.put(
      CacheRec(
        id: firstId,
        state: CacheState.ready,
        path: stalePath,
        bytes: expected.length,
        checksum: checksum,
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'cleanup-artifact-object',
        storageRootId: layout.root,
      ),
    );
    await index.put(
      CacheRec(
        id: secondId,
        state: CacheState.ready,
        path: authoritativePath,
        bytes: expected.length,
        checksum: checksum,
        createdUs: 2,
        touchedUs: 2,
        artifactId: 'cleanup-artifact-object',
        storageRootId: layout.root,
      ),
    );
    await index.remove(secondId.key);
    final object = await index.getArtifactObject('cleanup-artifact-object');
    expect(object?.accessLocator, authoritativePath);
    await index.close();

    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    await expectLater(
      store.openArtifactStream(firstId),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.lengthChanged,
            )
            .having(
              (failure) => failure.accessLocator,
              'accessLocator',
              authoritativePath,
            ),
      ),
    );
    expect((await store.indexedRecords()).containsKey(firstId.key), isFalse);
    expect(await File(authoritativePath).exists(), isFalse);
    expect(await File(stalePath).exists(), isTrue,
        reason: 'logical compatibility path is not physical object authority');
  });

  test('accessDenied on artifact_object locator preserves logical binding', () async {
    final root = await Directory.systemTemp.createTemp('zic-artifact-object-denied-');
    addTearDown(() => root.delete(recursive: true));
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    await Directory(layout.finalDir).create(recursive: true);
    final bytes = Uint8List.fromList(<int>[5, 4, 3, 2, 1]);
    final checksum = (Crc32()..add(bytes)).hex;
    final firstId = _id('artifact-object-denied-old');
    final secondId = _id('artifact-object-denied-current');
    final stalePath = '${layout.finalDir}/denied-stale.bin';
    final authoritativePath = '${layout.finalDir}/denied-authoritative.bin';
    await File(authoritativePath).writeAsBytes(bytes, flush: true);

    final index = SqliteIndex(layout.dbPath);
    await index.open();
    await index.put(
      CacheRec(
        id: firstId,
        state: CacheState.ready,
        path: stalePath,
        bytes: bytes.length,
        checksum: checksum,
        createdUs: 1,
        touchedUs: 1,
        artifactId: 'denied-artifact-object',
        storageRootId: layout.root,
      ),
    );
    await index.put(
      CacheRec(
        id: secondId,
        state: CacheState.ready,
        path: authoritativePath,
        bytes: bytes.length,
        checksum: checksum,
        createdUs: 2,
        touchedUs: 2,
        artifactId: 'denied-artifact-object',
        storageRootId: layout.root,
      ),
    );
    await index.remove(secondId.key);
    await index.close();

    final denied = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: const _AccessDeniedArtifactBytes(),
    );
    addTearDown(denied.close);
    await expectLater(
      denied.openArtifactStream(firstId),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.accessDenied,
            )
            .having(
              (failure) => failure.accessLocator,
              'accessLocator',
              authoritativePath,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              'denied-artifact-object',
            ),
      ),
    );
    expect((await denied.indexedRecords()).containsKey(firstId.key), isTrue);
    expect(await File(authoritativePath).exists(), isTrue);
  });

  test('proven root alias falls back from denied Direct access to SAF', () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-root-alias-app-');
    final directRoot = await Directory.systemTemp.createTemp('zic-root-alias-direct-');
    addTearDown(() async {
      if (await appRoot.exists()) await appRoot.delete(recursive: true);
      if (await directRoot.exists()) await directRoot.delete(recursive: true);
    });
    const safTree =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final id = _id('root-alias-fallback');
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8]);

    final direct = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: directRoot.path,
      indexPath: indexPath,
    );
    await direct.storePromotedArtifact(id: id, bytes: bytes);
    final directRecord = (await direct.indexedRecords())[id.key]!;
    await direct.close();

    final access = _AliasFallbackArtifactBytes(bytes);
    final saf = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      indexPath: indexPath,
      bytes: access,
      safTreeUri: safTree,
    );
    addTearDown(saf.close);
    await saf.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(directRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );

    final entry = await saf.openArtifactStream(id);
    expect(entry, isNotNull);
    final read = <int>[];
    await for (final chunk in entry!.open(start: 0)) {
      read.addAll(chunk);
    }
    expect(read, bytes);
    expect(access.directExistsCalls, 1);
    expect(access.safExistsCalls, 1);
    expect(await File(directRecord.path).exists(), isTrue,
        reason: 'access fallback must not migrate or delete the replica');

    final root = await saf.storageRootForAccess(directRoot.path);
    expect(root, isNotNull);
    final directAccess = root!.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.direct,
    );
    final safAccess = root.accessLocators.singleWhere(
      (value) => value.kind == StorageAccessLocatorKind.saf,
    );
    expect(directAccess.health, StorageAccessHealth.accessDenied);
    expect(safAccess.health, StorageAccessHealth.healthy);

    access.resetCounters();
    final second = await saf.openArtifactStream(id);
    expect(second, isNotNull);
    expect(access.safExistsCalls, 1);
    expect(access.directExistsCalls, 0,
        reason: 'durable access health should prefer the healthy SAF alias');
  });

  test('one corrupt replica is retired while another sealed copy remains readable',
      () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-replica-app-');
    final rootA = await Directory.systemTemp.createTemp('zic-replica-a-');
    final rootB = await Directory.systemTemp.createTemp('zic-replica-b-');
    addTearDown(() async {
      for (final directory in <Directory>[appRoot, rootA, rootB]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final id = _id('multi-replica-fallback');
    final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5, 9, 2, 6]);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: rootA.path,
      indexPath: indexPath,
    );
    addTearDown(store.close);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final initial = await store.artifactReplicasFor(id);
    expect(initial, hasLength(1));
    final primary = initial.single;

    final replicaFile = File(
      '${rootB.path}${Platform.pathSeparator}replica.bin',
    );
    await replicaFile.writeAsBytes(bytes, flush: true);
    final second = await store.registerVerifiedArtifactReplica(
      id: id,
      accessLocator: replicaFile.path,
      storageRootId: rootB.path,
    );
    expect(second.replicaId, isNot(primary.replicaId));
    expect(await store.artifactReplicasFor(id), hasLength(2));

    // The newest replica is selected first; corrupt it after registration so
    // preflight must retire only that copy and continue to the primary.
    await replicaFile.writeAsBytes(<int>[3, 1, 4], flush: true);
    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull);
    final read = <int>[];
    await for (final chunk in entry!.open(start: 0)) {
      read.addAll(chunk);
    }
    expect(read, bytes);

    final remaining = await store.artifactReplicasFor(id);
    expect(remaining, hasLength(1));
    expect(remaining.single.replicaId, primary.replicaId);
    expect((await store.indexedRecords()).containsKey(id.key), isTrue,
        reason: 'one failed replica must not erase logical artifact authority');
  });

  test('full CRC falls through a same-length corrupt replica to a sealed copy',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-replica-crc-fallback-app-',
    );
    final rootA = await Directory.systemTemp.createTemp(
      'zic-replica-crc-fallback-a-',
    );
    final rootB = await Directory.systemTemp.createTemp(
      'zic-replica-crc-fallback-b-',
    );
    addTearDown(() async {
      for (final directory in <Directory>[appRoot, rootA, rootB]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final id = _id('multi-replica-crc-fallback');
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8]);
    final corrupt = Uint8List.fromList(<int>[8, 2, 8, 1, 7, 2]);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: rootA.path,
      indexPath: indexPath,
    );
    addTearDown(store.close);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final primary = (await store.artifactReplicasFor(id)).single;

    final replicaFile = File(
      '${rootB.path}${Platform.pathSeparator}replica.bin',
    );
    await replicaFile.writeAsBytes(bytes, flush: true);
    final second = await store.registerVerifiedArtifactReplica(
      id: id,
      accessLocator: replicaFile.path,
      storageRootId: rootB.path,
    );
    await replicaFile.writeAsBytes(corrupt, flush: true);

    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull);
    final streamed = <int>[];
    await for (final chunk in entry!.open(start: 0)) {
      streamed.addAll(chunk);
    }
    expect(streamed, corrupt,
        reason: 'ordinary stream keeps the selected sealed replica hot path');
    expect(await entry.readAll!(), bytes,
        reason: 'explicit full verification must continue to another replica');

    final remaining = await store.artifactReplicasFor(id);
    expect(remaining, hasLength(1));
    expect(remaining.single.replicaId, primary.replicaId);
    expect(remaining.single.replicaId, isNot(second.replicaId));
    expect((await store.indexedRecords()).containsKey(id.key), isTrue);
  });

  test('proven SAF locator for one Direct replica is not a second replica',
      () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-replica-alias-app-');
    final directRoot = await Directory.systemTemp.createTemp('zic-replica-alias-direct-');
    addTearDown(() async {
      if (await appRoot.exists()) await appRoot.delete(recursive: true);
      if (await directRoot.exists()) await directRoot.delete(recursive: true);
    });
    const safTree =
        'content://com.android.externalstorage.documents/tree/primary%3ABooks';
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final id = _id('replica-alias');
    final bytes = Uint8List.fromList(<int>[8, 6, 7, 5, 3, 0, 9]);
    final direct = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: directRoot.path,
      indexPath: indexPath,
    );
    await direct.storePromotedArtifact(id: id, bytes: bytes);
    final primary = (await direct.artifactReplicasFor(id)).single;
    await direct.close();

    final access = _AliasFallbackArtifactBytes(bytes);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      indexPath: indexPath,
      bytes: access,
      safTreeUri: safTree,
    );
    addTearDown(store.close);
    await store.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(directRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );
    final relative = primary.accessLocator
        .substring(directRoot.path.length + 1)
        .split(Platform.pathSeparator)
        .join('/');
    final aliasPath = encodeSafRecordPath(treeUri: safTree, relativePath: relative);
    final registered = await store.registerVerifiedArtifactReplica(
      id: id,
      accessLocator: aliasPath,
      storageRootId: safTree,
    );
    expect(registered.replicaId, primary.replicaId);
    expect(await store.artifactReplicasFor(id), hasLength(1));
  });

  for (final replaceGeneration in <bool>[false, true]) {
    test('explicit invalidation distinguishes recency from replacement '
        '(replace generation: $replaceGeneration)', () async {
      final root = await Directory.systemTemp.createTemp('zic-invalidate-touch-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final id = _id('invalidate-touch');
      final bytes = Uint8List.fromList(<int>[9, 8, 7, 6, 5, 4, 3, 2]);
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      await store.storePromotedArtifact(id: id, bytes: bytes);
      final index = store.index as SqliteIndex;
      final before = (await index.get(id.key))!;

      final invalidation = store.invalidateArtifact(id);
      // Change SQLite metadata between the command's snapshot and its locked
      // recheck. Recency is the same maintenance-only mutation as deferred
      // foreground-read touch; a new binding generation remains protected.
      await Future<void>.microtask(() async {
        if (replaceGeneration) {
          await index.put(before.copyWith(createdUs: before.createdUs + 1));
        } else {
          await index.touch(id.key, before.touchedUs + 1);
        }
      });
      await invalidation;
      expect(await index.get(id.key), replaceGeneration ? isNotNull : isNull);
      expect(await File(before.path).exists(), replaceGeneration);
    });
  }

  test('remounted proven Direct alias serves and deletes a sealed replica',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-replica-remount-app-',
    );
    final oldRoot = await Directory.systemTemp.createTemp(
      'zic-replica-remount-old-',
    );
    final newRoot = await Directory.systemTemp.createTemp(
      'zic-replica-remount-new-',
    );
    addTearDown(() async {
      for (final directory in <Directory>[appRoot, oldRoot, newRoot]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    const safTree =
        'content://com.android.externalstorage.documents/tree/CAFE-BEEF%3ABooks';
    final id = _id('replica-remount-delete');
    final bytes = Uint8List.fromList(<int>[9, 8, 7, 6, 5, 4, 3, 2]);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: oldRoot.path,
      indexPath: defaultChapterDownloadMetadataPath(appRoot.path),
    );
    addTearDown(store.close);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    await store.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(oldRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );
    final replica = (await store.artifactReplicasFor(id)).single;
    final relative = replica.accessLocator.substring(oldRoot.path.length + 1);
    final remountedBody = File(
      '${newRoot.path}${Platform.pathSeparator}$relative',
    );
    await remountedBody.parent.create(recursive: true);
    await File(replica.accessLocator).rename(remountedBody.path);
    final oldSidecar = File('${replica.accessLocator}.meta');
    final remountedSidecar = File('${remountedBody.path}.meta');
    if (await oldSidecar.exists()) {
      await remountedSidecar.parent.create(recursive: true);
      await oldSidecar.rename(remountedSidecar.path);
    }
    await store.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(newRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );

    final reopened = await store.openArtifactStream(id);
    expect(reopened, isNotNull);
    expect(await reopened!.readAll!(), orderedEquals(bytes));

    await store.invalidateArtifact(id);
    expect((await store.indexedRecords()).containsKey(id.key), isFalse);
    expect(await remountedBody.exists(), isFalse,
        reason:
            'destructive cleanup must resolve the current proven alias rather '
            'than deleting only the stale compatibility locator');
    expect(await remountedSidecar.exists(), isFalse);
  });

  test('explicit invalidation removes every replica when no binding remains',
      () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-replica-delete-app-');
    final rootA = await Directory.systemTemp.createTemp('zic-replica-delete-a-');
    final rootB = await Directory.systemTemp.createTemp('zic-replica-delete-b-');
    addTearDown(() async {
      for (final directory in <Directory>[appRoot, rootA, rootB]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
    final id = _id('replica-delete');
    final bytes = Uint8List.fromList(<int>[1, 6, 1, 8, 0, 3, 3, 9]);
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: rootA.path,
      indexPath: defaultChapterDownloadMetadataPath(appRoot.path),
    );
    addTearDown(store.close);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final primary = (await store.artifactReplicasFor(id)).single;
    final secondFile = File('${rootB.path}${Platform.pathSeparator}replica.bin');
    await secondFile.writeAsBytes(bytes, flush: true);
    await store.registerVerifiedArtifactReplica(
      id: id,
      accessLocator: secondFile.path,
      storageRootId: rootB.path,
    );
    expect(await store.artifactReplicasFor(id), hasLength(2));

    await store.invalidateArtifact(id);
    expect((await store.indexedRecords()).containsKey(id.key), isFalse);
    expect(await File(primary.accessLocator).exists(), isFalse);
    expect(await secondFile.exists(), isFalse);
    expect(await store.artifactReplicasFor(id), isEmpty);
  });

  test('replica registration rejects bytes that do not match artifact proof',
      () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-replica-proof-app-');
    final root = await Directory.systemTemp.createTemp('zic-replica-proof-root-');
    addTearDown(() async {
      if (await appRoot.exists()) await appRoot.delete(recursive: true);
      if (await root.exists()) await root.delete(recursive: true);
    });
    final id = _id('replica-proof');
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      indexPath: defaultChapterDownloadMetadataPath(appRoot.path),
    );
    addTearDown(store.close);
    await store.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final foreign = File('${root.path}${Platform.pathSeparator}foreign.bin');
    await foreign.writeAsBytes(<int>[4, 3, 2, 1], flush: true);

    await expectLater(
      store.registerVerifiedArtifactReplica(
        id: id,
        accessLocator: foreign.path,
        storageRootId: root.path,
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );
    expect(await store.artifactReplicasFor(id), hasLength(1));
  });

  test('SAF transient length mismatch is rechecked before replica retirement', () async {
    final appRoot = await Directory.systemTemp.createTemp('zic-saf-length-app-');
    final directRoot = await Directory.systemTemp.createTemp('zic-saf-length-direct-');
    addTearDown(() async {
      if (await appRoot.exists()) await appRoot.delete(recursive: true);
      if (await directRoot.exists()) await directRoot.delete(recursive: true);
    });
    const safTree =
        'content://com.android.externalstorage.documents/tree/primary%3ATrace';
    final indexPath = defaultChapterDownloadMetadataPath(appRoot.path);
    final id = _id('saf-transient-length');
    final bytes = Uint8List.fromList(<int>[1, 3, 5, 7, 9, 11, 13, 15]);

    final direct = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      directory: directRoot.path,
      indexPath: indexPath,
    );
    await direct.storePromotedArtifact(id: id, bytes: bytes);
    final primary = (await direct.artifactReplicasFor(id)).single;
    await direct.close();

    final relative = primary.accessLocator
        .substring(directRoot.path.length + 1)
        .split(Platform.pathSeparator)
        .join('/');
    final saf = _TransientLengthSafIo(
      relativePath: relative,
      bytes: bytes,
      lengthResponses: <int>[
        bytes.lengthInBytes - 1,
        bytes.lengthInBytes,
        bytes.lengthInBytes - 1,
        bytes.lengthInBytes,
      ],
    );
    final store = await PersistentDownloadArtifactStore.open(
      appRoot.path,
      indexPath: indexPath,
      bytes: CompositeArtifactBytes(
        local: const _AccessDeniedArtifactBytes(),
        saf: SafArtifactBytes(saf, treeUri: safTree),
      ),
      safTreeUri: safTree,
    );
    addTearDown(store.close);
    await store.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator(directRoot.path),
        saf: const SafStorageAccessLocator(safTree),
      ),
    );

    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull);
    final bound = await entry!.openBoundRangeReader!();
    expect(bound, isNotNull);
    expect(await bound!.readRange(0, bytes.lengthInBytes), bytes);
    await bound.close();

    expect(saf.lengthCalls, 4,
        reason: 'both preflight and retained descriptor must independently recheck');
    expect((await store.indexedRecords()).containsKey(id.key), isTrue);
    expect(await store.artifactReplicasFor(id), hasLength(1));
  });

  test('persistent preflight reports lengthChanged with replica identity', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-length-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('length-changed');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final record = (await store.indexedRecords()).values.single;
    await File(record.path).writeAsBytes(<int>[1, 2, 3], flush: true);

    await expectLater(
      store.openArtifactStream(id),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.lengthChanged,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              record.effectiveArtifactId,
            )
            .having(
              (failure) => failure.expectedLength,
              'expectedLength',
              bytes.lengthInBytes,
            )
            .having(
              (failure) => failure.observedLength,
              'observedLength',
              3,
            ),
      ),
    );
    expect((await store.indexedRecords()).containsKey(id.key), isFalse);
  });

  test('full CRC retires same-length corrupted sealed replica', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-crc-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('checksum-changed');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);
    final corrupt = Uint8List.fromList(<int>[6, 5, 4, 3, 2, 1]);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final record = (await store.indexedRecords()).values.single;
    await File(record.path).writeAsBytes(corrupt, flush: true);

    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull,
        reason: 'normal sealed open intentionally performs length/access preflight only');
    final streamed = <int>[];
    await for (final chunk in entry!.open(start: 0)) {
      streamed.addAll(chunk);
    }
    expect(streamed, corrupt,
        reason: 'ordinary Reader stream must not pay whole-file CRC on every access');

    await expectLater(
      entry.readAll!(),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.checksumMismatch,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              record.effectiveArtifactId,
            ),
      ),
    );
    expect(await store.artifactReplicasFor(id), isEmpty);
    expect((await store.indexedRecords()).containsKey(id.key), isFalse,
        reason: 'last-replica retirement must synchronously drop logical authority');
    expect(await store.openArtifactStream(id), isNull,
        reason: 'a checksum-failed sealed replica must not remain reusable');
  });

  test('accessDenied preserves the replica binding for later permission recovery', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-denied-');
    final id = _id('access-denied');
    final first = await PersistentDownloadArtifactStore.open(root.path);
    await first.storePromotedArtifact(
      id: id,
      bytes: Uint8List.fromList(<int>[7, 8, 9, 10]),
    );
    final record = (await first.indexedRecords()).values.single;
    await first.close();

    final denied = await PersistentDownloadArtifactStore.open(
      root.path,
      bytes: const _AccessDeniedArtifactBytes(),
    );
    addTearDown(() async {
      await denied.close();
      await root.delete(recursive: true);
    });

    await expectLater(
      denied.openArtifactStream(id),
      throwsA(
        isA<ArtifactReadFailure>()
            .having(
              (failure) => failure.kind,
              'kind',
              ArtifactReadFailureKind.accessDenied,
            )
            .having(
              (failure) => failure.replicaId,
              'replicaId',
              record.effectiveArtifactId,
            ),
      ),
    );
    expect((await denied.indexedRecords()).containsKey(id.key), isTrue);
    expect(await File(record.path).exists(), isTrue);
  });

  test('duplicate same-process open does not recover another owner promotion',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-promotion-concurrent-open-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final first = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(first.close);
    final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
    final id = _id('promotion-concurrent-open');
    final physical = PhysicalMediaId.canonical('promotion:concurrent-open');
    final artifact = layout.artifactForPhysical(physical);
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8, 1, 8]);
    final crc = Crc32()..add(bytes);
    await File(artifact.partialPath).parent.create(recursive: true);
    await File(artifact.partialPath).writeAsBytes(bytes, flush: true);
    final index = first.index as SqliteIndex;
    await index.putPhysicalPartial(
      PhysicalPartialRecord(
        id: physical,
        path: artifact.partialPath,
        bytes: bytes.lengthInBytes,
        checksum: crc.hex,
        createdUs: 1,
        touchedUs: 2,
        storageRootId: layout.root,
      ),
    );
    await index.beginArtifactPromotion(
      id: id,
      physicalId: physical,
      sourceAccessLocator: artifact.partialPath,
      destinationAccessLocator: artifact.finalPath,
      bytes: bytes.lengthInBytes,
      checksum: crc.hex,
      storageRootId: layout.root,
    );

    await expectLater(
      PersistentDownloadArtifactStore.open(root.path),
      throwsA(isA<StateError>()),
    );

    expect(await index.listArtifactPromotions(), hasLength(1),
        reason: 'the rejected second owner must not advance the journal');
    expect(await index.getPhysicalPartial(physical), isNotNull);
    expect(await index.get(id.key), isNull);
    expect(await File(artifact.partialPath).readAsBytes(), bytes);
    expect(await File(artifact.finalPath).exists(), isFalse);
  });

  for (final crashAfterRename in <bool>[false, true]) {
    test(
      'promotion journal recovers complete body ${crashAfterRename ? 'after' : 'before'} final rename',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'zic-promotion-crash-${crashAfterRename ? 'after' : 'before'}-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final seeded = await _seedPromotionCrash(
          root,
          crashAfterRename ? 'after-rename' : 'before-rename',
          renameToFinal: crashAfterRename,
        );
        expect(
          await File(seeded.artifact.finalMetaPath).exists(),
          isFalse,
          reason: 'journal recovery must not require a final sidecar',
        );

        final store = await PersistentDownloadArtifactStore.open(root.path);
        addTearDown(store.close);

        expect(await store.readPromoted(seeded.id), seeded.bytes);
        final index = store.index as SqliteIndex;
        expect(await index.listArtifactPromotions(), isEmpty);
        expect(await index.getPhysicalPartial(seeded.physical), isNull);
        final physical = await index.getPhysicalMediaArtifact(seeded.physical);
        expect(physical, isNotNull);
        final ready = await index.get(seeded.id.key);
        expect(ready?.state, CacheState.ready);
        expect(physical!.artifactId, ready!.effectiveArtifactId);
        expect(await File(seeded.artifact.finalPath).readAsBytes(), seeded.bytes);
        expect(await File(seeded.artifact.partialPath).exists(), isFalse);
      },
    );
  }

  test('promotion collision rolls back to sealed partial without hijacking final',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-promotion-collision-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final foreign = Uint8List.fromList(<int>[9, 9, 9, 9, 9, 9, 9, 9]);
    final seeded = await _seedPromotionCrash(
      root,
      'collision',
      renameToFinal: false,
      conflictingFinal: foreign,
    );

    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(store.close);
    final index = store.index as SqliteIndex;

    expect(await index.listArtifactPromotions(), isEmpty,
        reason: 'conflicting destination rolls the transaction back');
    expect(await index.get(seeded.id.key), isNull);
    expect(await index.getPhysicalMediaArtifact(seeded.physical), isNull);
    final partial = await index.getPhysicalPartial(seeded.physical);
    expect(partial, isNotNull);
    expect(partial!.path, seeded.artifact.partialPath);
    expect(await File(seeded.artifact.partialPath).readAsBytes(), seeded.bytes);
    expect(await File(seeded.artifact.finalPath).readAsBytes(), foreign,
        reason: 'journal progress never authorizes overwriting a foreign final');
  });

  test('mid-stream failure keeps emitted offset and replica identity', () async {
    final root = await Directory.systemTemp.createTemp('zic-replica-stream-');
    final store = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });
    final id = _id('mid-stream');
    final bytes = Uint8List(700 * 1024);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = index & 0xff;
    }
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final record = (await store.indexedRecords()).values.single;
    final entry = await store.openArtifactStream(id);
    expect(entry, isNotNull);
    await File(record.path).writeAsBytes(
      bytes.sublist(0, 256 * 1024),
      flush: true,
    );

    var emitted = 0;
    Object? failure;
    try {
      await for (final chunk
          in entry!.open(start: 0, endExclusive: entry.length)) {
        emitted += chunk.length;
      }
    } catch (error) {
      failure = error;
    }

    expect(emitted, 256 * 1024);
    expect(
      failure,
      isA<ArtifactReadFailure>()
          .having(
            (value) => value.kind,
            'kind',
            ArtifactReadFailureKind.shortRead,
          )
          .having(
            (value) => value.replicaId,
            'replicaId',
            record.effectiveArtifactId,
          )
          .having(
            (value) => value.failedOffset,
            'failedOffset',
            256 * 1024,
          )
          .having(
            (value) => value.bytesEmitted,
            'bytesEmitted',
            256 * 1024,
          ),
    );
  });
}

DownloadId _id(String pageId) => DownloadId(
      content: ContentId(
        sourceId: 'typed-read-source',
        comicId: 'typed-read-comic',
        chapterId: 'typed-read-chapter',
        pageId: pageId,
      ),
      sourceRevision: 'typed-read-r1',
      canonicalUri: Uri.parse('https://example.invalid/$pageId.bin'),
    );

Future<({
  DownloadId id,
  PhysicalMediaId physical,
  Artifact artifact,
  Uint8List bytes,
})> _seedPromotionCrash(
  Directory root,
  String pageId, {
  required bool renameToFinal,
  Uint8List? conflictingFinal,
}) async {
  final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
  final id = _id('promotion-$pageId');
  final physical = PhysicalMediaId.canonical('promotion:$pageId');
  final artifact = layout.artifactForPhysical(physical);
  final bytes = Uint8List.fromList(<int>[1, 4, 1, 5, 9, 2, 6, 5]);
  final crc = Crc32()..add(bytes);
  await File(artifact.partialPath).parent.create(recursive: true);
  await File(artifact.partialPath).writeAsBytes(bytes, flush: true);
  if (conflictingFinal != null) {
    await File(artifact.finalPath).parent.create(recursive: true);
    await File(artifact.finalPath).writeAsBytes(conflictingFinal, flush: true);
  }

  final index = SqliteIndex(layout.dbPath);
  await index.open();
  await index.putPhysicalPartial(
    PhysicalPartialRecord(
      id: physical,
      path: artifact.partialPath,
      bytes: bytes.lengthInBytes,
      checksum: crc.hex,
      createdUs: 1,
      touchedUs: 2,
      storageRootId: layout.root,
    ),
  );
  await index.beginArtifactPromotion(
    id: id,
    physicalId: physical,
    sourceAccessLocator: artifact.partialPath,
    destinationAccessLocator: artifact.finalPath,
    bytes: bytes.lengthInBytes,
    checksum: crc.hex,
    storageRootId: layout.root,
  );
  await index.close();

  if (renameToFinal) {
    await File(artifact.finalPath).parent.create(recursive: true);
    await File(artifact.partialPath).rename(artifact.finalPath);
  }
  return (
    id: id,
    physical: physical,
    artifact: artifact,
    bytes: bytes,
  );
}

Future<void> _seedCleanupDebt(
  String dbPath,
  StorageCleanupDebtRecord debt, {
  String? replacementLocator,
}) async {
  final index = SqliteIndex(dbPath);
  await index.open();
  await index.putStorageCleanupDebt(
    StorageCleanupDebtRecord(
      accessLocator: replacementLocator ?? debt.accessLocator,
      storageRootId: debt.storageRootId,
      kind: debt.kind,
      createdUs: debt.createdUs,
      touchedUs: debt.touchedUs,
      expectedBytes: debt.expectedBytes,
      expectedChecksum: debt.expectedChecksum,
      expectedChecksumAlgorithm: debt.expectedChecksumAlgorithm,
    ),
  );
  await index.close();
}

final class _CleanupDebtSafIo implements SafTreeIo {
  _CleanupDebtSafIo({this.failDelete = false});

  final bool failDelete;
  final Map<String, Uint8List> storage = <String, Uint8List>{};
  final List<String> deletedPaths = <String>[];
  int listCalls = 0;

  @override
  Future<bool> exists(String relativePath) async =>
      storage.containsKey(relativePath);

  @override
  Future<bool> delete(String relativePath) async {
    deletedPaths.add(relativePath);
    if (failDelete) {
      throw const SafTreeAccessFailure(
        kind: ArtifactReadFailureKind.ioFailure,
        operation: 'delete',
      );
    }
    return storage.remove(relativePath) != null;
  }

  @override
  Future<List<SafTreeFile>> list(String relativePath) async {
    listCalls++;
    return const <SafTreeFile>[];
  }

  @override
  Future<int?> open(
    String relativePath, {
    SafWriteMode mode = SafWriteMode.read,
  }) async => null;

  @override
  Future<Uint8List> read(int handle, int length) =>
      throw UnsupportedError('cleanup fixture is delete-only');

  @override
  Future<void> write(int handle, Uint8List bytes) =>
      throw UnsupportedError('cleanup fixture is delete-only');

  @override
  Future<int?> length(int handle) =>
      throw UnsupportedError('cleanup fixture is delete-only');

  @override
  Future<void> seek(int handle, int position) =>
      throw UnsupportedError('cleanup fixture is delete-only');

  @override
  Future<void> close(int handle) async {}

  @override
  Future<bool> rename(String relativePath, String newRelativePath) async => false;
}

final class _AliasFallbackArtifactBytes implements ArtifactBytes {
  _AliasFallbackArtifactBytes(this.bytes);

  final Uint8List bytes;
  int directExistsCalls = 0;
  int safExistsCalls = 0;

  void resetCounters() {
    directExistsCalls = 0;
    safExistsCalls = 0;
  }

  bool _isSaf(String path) => path.startsWith('saf:');

  Never _deny(String path) => throw ArtifactReadFailure(
        kind: ArtifactReadFailureKind.accessDenied,
        accessLocator: path,
        failedOffset: 0,
        bytesEmitted: 0,
      );

  @override
  Future<bool> exists(String path) async {
    if (_isSaf(path)) {
      safExistsCalls++;
      return true;
    }
    directExistsCalls++;
    return _deny(path);
  }

  @override
  Future<int> length(String path) async {
    if (!_isSaf(path)) return _deny(path);
    return bytes.lengthInBytes;
  }

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) async* {
    if (!_isSaf(path)) _deny(path);
    final end = endExclusive == null || endExclusive > bytes.lengthInBytes
        ? bytes.lengthInBytes
        : endExclusive;
    if (start < end) yield Uint8List.fromList(bytes.sublist(start, end));
  }

  @override
  Future<void> delete(String path) async {}
}

final class _TransientLengthSafIo implements SafTreeIo {
  _TransientLengthSafIo({
    required this.relativePath,
    required Uint8List bytes,
    required Iterable<int> lengthResponses,
  })  : _bytes = Uint8List.fromList(bytes),
        _lengthResponses = List<int>.of(lengthResponses);

  final String relativePath;
  final Uint8List _bytes;
  final List<int> _lengthResponses;
  final Map<int, int> _positions = <int, int>{};
  int _nextHandle = 1;
  int lengthCalls = 0;

  @override
  Future<int?> open(String path, {SafWriteMode mode = SafWriteMode.read}) async {
    if (path != relativePath || mode != SafWriteMode.read) return null;
    final handle = _nextHandle++;
    _positions[handle] = 0;
    return handle;
  }

  @override
  Future<int?> length(int handle) async {
    if (!_positions.containsKey(handle)) return null;
    lengthCalls++;
    if (_lengthResponses.isNotEmpty) return _lengthResponses.removeAt(0);
    return _bytes.lengthInBytes;
  }

  @override
  Future<Uint8List> read(int handle, int length) async {
    final start = _positions[handle];
    if (start == null) throw StateError('invalid SAF test handle');
    final end = (start + length).clamp(0, _bytes.lengthInBytes);
    _positions[handle] = end;
    return Uint8List.fromList(_bytes.sublist(start, end));
  }

  @override
  Future<void> seek(int handle, int position) async {
    if (!_positions.containsKey(handle)) throw StateError('invalid SAF test handle');
    _positions[handle] = position;
  }

  @override
  Future<void> close(int handle) async {
    _positions.remove(handle);
  }

  @override
  Future<bool> exists(String path) async => path == relativePath;

  @override
  Future<void> write(int handle, Uint8List bytes) =>
      throw UnsupportedError('read-only SAF test fixture');

  @override
  Future<bool> delete(String path) async => false;

  @override
  Future<bool> rename(String path, String newRelativePath) async => false;

  @override
  Future<List<SafTreeFile>> list(String path) async => const <SafTreeFile>[];
}

final class _AccessDeniedArtifactBytes implements ArtifactBytes {
  const _AccessDeniedArtifactBytes();

  @override
  Future<bool> exists(String path) async {
    throw ArtifactReadFailure(
      kind: ArtifactReadFailureKind.accessDenied,
      accessLocator: path,
      failedOffset: 0,
      bytesEmitted: 0,
    );
  }

  @override
  Future<int> length(String path) => const LocalArtifactBytes().length(path);

  @override
  Stream<Uint8List> readChunks(
    String path, {
    required int start,
    int? endExclusive,
  }) =>
      const LocalArtifactBytes().readChunks(
        path,
        start: start,
        endExclusive: endExclusive,
      );

  @override
  Future<void> delete(String path) => const LocalArtifactBytes().delete(path);
}
