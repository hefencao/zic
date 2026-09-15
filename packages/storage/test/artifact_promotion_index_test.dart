import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  DownloadId id(String page) => DownloadId(
        content: ContentId(
          sourceId: 'promotion-source',
          comicId: 'promotion-comic',
          chapterId: 'promotion-chapter',
          pageId: page,
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/$page.webp'),
      );

  test('promotion commit atomically publishes replica and physical routing',
      () async {
    final index = SqliteIndex.memory();
    await index.open();
    addTearDown(index.close);
    final download = id('canonical');
    final physical = PhysicalMediaId.canonical('promotion-family:canonical');
    const source = '/cache/partial/canonical.part';
    const destination = '/cache/final/canonical.bin';
    const checksum = '01020304';
    await index.putPhysicalPartial(
      PhysicalPartialRecord(
        id: physical,
        path: source,
        bytes: 4,
        checksum: checksum,
        createdUs: 1,
        touchedUs: 2,
        storageRootId: '/cache',
      ),
    );

    final promotion = await index.beginArtifactPromotion(
      id: download,
      physicalId: physical,
      sourceAccessLocator: source,
      destinationAccessLocator: destination,
      bytes: 4,
      checksum: checksum,
      storageRootId: '/cache',
    );

    final pending = await index.listArtifactPromotions();
    expect(pending, hasLength(1));
    expect(pending.single.promotionKey, promotion.promotionKey);
    expect(await index.isStorageAccessLocatorAuthoritative(source), isTrue);
    expect(await index.isStorageAccessLocatorAuthoritative(destination), isTrue);
    expect(await index.get(download.key), isNull,
        reason: 'promotion progress must not be exposed as READY authority');

    final ready = await index.commitArtifactPromotion(promotion.promotionKey);

    expect(ready.state, CacheState.ready);
    expect(ready.path, destination);
    expect(ready.bytes, 4);
    expect(ready.checksum, checksum);
    expect(await index.listArtifactPromotions(), isEmpty);
    expect(await index.getPhysicalPartial(physical), isNull);
    final physicalReady = await index.getPhysicalMediaArtifact(physical);
    expect(physicalReady, isNotNull);
    expect(physicalReady!.artifactId, ready.effectiveArtifactId);
    final replicas = await index.listArtifactReplicas(ready.effectiveArtifactId);
    expect(replicas, hasLength(1));
    expect(replicas.single.accessLocator, destination);
    expect((await index.get(download.key))?.effectiveArtifactId,
        ready.effectiveArtifactId);
  });

  test('schema 16 upgrades through schema 18 promotion journal', () async {
    final temp = await Directory.systemTemp.createTemp(
      'cache_index_v16_promotion_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/cache.sqlite';
    final seed = SqliteIndex(path);
    await seed.open();
    await seed.close();

    final legacy = sql.sqlite3.open(path);
    legacy.execute('DROP TABLE artifact_promotion');
    legacy.execute('PRAGMA user_version = 16');
    legacy.dispose();

    final migrated = SqliteIndex(path);
    await migrated.open();
    expect(await migrated.listArtifactPromotions(), isEmpty);
    await migrated.close();

    final checked = sql.sqlite3.open(path);
    addTearDown(checked.dispose);
    expect(checked.select('PRAGMA user_version').single.values.single, 19);
    expect(
      checked.select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='artifact_promotion'",
      ),
      hasLength(1),
    );
  });
}
