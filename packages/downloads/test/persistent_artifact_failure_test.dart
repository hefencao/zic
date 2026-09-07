import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
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
