import 'dart:io';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('artifact authority snapshot is transactionally consistent', () async {
    final dir = await Directory.systemTemp.createTemp(
      'artifact-authority-snapshot-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final index = SqliteIndex('${dir.path}/cache.sqlite');
    await index.open();
    addTearDown(index.close);

    final root = await index.registerStorageRootAccessAliasProof(
      StorageRootAccessAliasProof(
        direct: DirectStorageAccessLocator('${dir.path}/root'),
        saf: const SafStorageAccessLocator('content://zic.test/tree/root'),
      ),
      verifiedUs: 10,
    );
    const artifactId = 'artifact-read-worker-object';
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '${dir.path}/root/page.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
        storageRootId: root.rootId,
      ),
    );
    await index.putArtifactReplica(
      artifactId: artifactId,
      accessLocator: 'content://zic.test/tree/root/document/page.bin',
      storageRootId: root.rootId,
      createdUs: 2,
      touchedUs: 2,
    );

    final snapshot = index.readArtifactAuthoritySnapshot(artifactId);

    expect(snapshot.object?.artifactId, artifactId);
    expect(snapshot.object?.accessLocator, '${dir.path}/root/page.bin');
    expect(snapshot.replicas, hasLength(2));
    expect(
      snapshot.replicas.map((value) => value.accessLocator).toSet(),
      <String>{
        '${dir.path}/root/page.bin',
        'content://zic.test/tree/root/document/page.bin',
      },
    );
    expect(snapshot.storageRootsByIdentity.keys, <String>[root.rootId]);
    expect(
      snapshot.storageRootsByIdentity[root.rootId]?.accessLocators
          .map((value) => value.locator)
          .toSet(),
      <String>{'${dir.path}/root', 'content://zic.test/tree/root'},
    );

    // Snapshot reads stay on the owning connection and leave it writable.
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '${dir.path}/root/page.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 1,
        touchedUs: 3,
        artifactId: artifactId,
        storageRootId: root.rootId,
      ),
    );
    expect((await index.get(id.key))?.touchedUs, 3);
  });

  test('artifact recency writer is conditional and flushes on close', () async {
    final dir = await Directory.systemTemp.createTemp('artifact-touch-worker-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/cache.sqlite';
    final index = SqliteIndex(path);
    await index.open();

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'touch-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/touch.webp'),
    );
    const artifactId = 'touch-artifact';
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '${dir.path}/touch.bin',
        bytes: 8,
        checksum: '11112222',
        createdUs: 1,
        touchedUs: 1,
        artifactId: artifactId,
      ),
    );
    await index.touchIfArtifactInBackground(
      key: id.key,
      expectedArtifactId: artifactId,
      touchedUs: 10,
    );
    await index.close();

    final reopened = SqliteIndex(path);
    await reopened.open();
    addTearDown(reopened.close);
    expect((await reopened.get(id.key))?.touchedUs, 10);

    // Rebind the logical key, then prove an old delayed touch cannot advance
    // the new owner's recency timestamp.
    await reopened.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: '${dir.path}/touch-new.bin',
        bytes: 8,
        checksum: '33334444',
        createdUs: 20,
        touchedUs: 20,
        artifactId: 'touch-artifact-new',
      ),
    );
    await reopened.touchIfArtifactInBackground(
      key: id.key,
      expectedArtifactId: artifactId,
      touchedUs: 100,
    );
    await reopened.close();

    final verified = SqliteIndex(path);
    await verified.open();
    addTearDown(verified.close);
    final current = await verified.get(id.key);
    expect(current?.effectiveArtifactId, 'touch-artifact-new');
    expect(current?.touchedUs, 20);
  });
}
