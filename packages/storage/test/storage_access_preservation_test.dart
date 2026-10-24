import 'dart:io';

import 'package:domain/domain.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:storage/storage.dart';
import 'package:test/test.dart';

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source', comicId: 'comic', chapterId: 'chapter', pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$page.webp'),
    );

void main() {
  late Directory temp;
  late SqliteIndex index;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('storage_preservation_test_');
    index = SqliteIndex('${temp.path}/cache.sqlite');
    await index.open();
  });

  tearDown(() async {
    await index.close();
    await temp.delete(recursive: true);
  });

  Future<void> put(String page, String path, CacheState state) => index.put(
        CacheRec(
          id: _id(page), state: state, path: path, bytes: 1, checksum: 'abcd',
          createdUs: 1, touchedUs: 2, artifactId: page,
        ),
      );

  test('hints match live partial, replica, promotion and migration protection',
      () async {
    await put('partial', '/exact.part', CacheState.partial);
    await put('ready', '/sealed.bin', CacheState.ready);
    final physical = PhysicalMediaId.canonical('preservation-promotion');
    await index.putPhysicalPartial(PhysicalPartialRecord(
      id: physical, path: '/physical.part', bytes: 1, checksum: 'abcd',
      createdUs: 1, touchedUs: 2,
    ));
    await index.beginArtifactPromotion(
      id: _id('promotion'), physicalId: physical,
      sourceAccessLocator: '/physical.part',
      destinationAccessLocator: '/promotion.bin', bytes: 1, checksum: 'abcd',
      storageRootId: 'default',
    );
    for (final phase in ['copying', 'cleanupPending']) {
      final source = '/$phase/source.bin';
      await put(phase, source, CacheState.ready);
      final replica = (await index.listArtifactReplicas(phase)).single;
      await index.beginArtifactReplicaMigration(
        replicaId: replica.replicaId, sourceAccessLocator: source,
        sourceStorageRootId: 'default',
        destinationAccessLocator: '/$phase/destination.bin',
        destinationStorageRootId: 'destination',
        temporaryAccessLocator: '/$phase/temporary.part', touchedUs: 3,
      );
      if (phase == 'cleanupPending') {
        await index.commitArtifactReplicaMigration(
          replicaId: replica.replicaId, touchedUs: 4,
        );
      }
    }
    final db = sql.sqlite3.open(index.path!);
    try {
      // Compatibility mirrors and corrupt READY identity JSON cannot become
      // owners or force full cache-record decoding during preservation reads.
      db.execute("UPDATE cache_entry SET path='/binding-mirror', "
          "download_json='invalid' WHERE key=?", <Object?>[_id('ready').key]);
      db.execute("UPDATE artifact_object SET path='/object-mirror' "
          "WHERE artifact_id='ready'");
    } finally {
      db.close();
    }

    final hints = await index.readStorageAccessPreservationHints();
    final expected = <String>{
      '/exact.part', '/sealed.bin', '/physical.part', '/promotion.bin',
      '/copying/source.bin', '/copying/destination.bin', '/copying/temporary.part',
      '/cleanupPending/destination.bin',
    };
    expect(hints, expected);
    expect(() => hints.add('/other'), throwsUnsupportedError);
    for (final locator in expected) {
      expect(await index.isStorageAccessLocatorAuthoritative(locator), isTrue,
          reason: locator);
    }
    for (final locator in [
      '/binding-mirror', '/object-mirror', '/sealed.bin.meta', '/orphan',
      '/cleanupPending/source.bin', '/cleanupPending/temporary.part',
    ]) {
      expect(await index.isStorageAccessLocatorAuthoritative(locator), isFalse,
          reason: locator);
      expect(hints, isNot(contains(locator)));
    }
  });

  test('a new read refreshes hints and close drains an accepted read', () async {
    await put('partial', '/old.part', CacheState.partial);
    final old = await index.readStorageAccessPreservationHints();
    await index.remove(_id('partial').key);
    await put('partial', '/new.part', CacheState.partial);

    var completed = false;
    final read = index.readStorageAccessPreservationHints().then((hints) {
      completed = true;
      return hints;
    });
    await index.close();

    expect(completed, isTrue);
    expect(await read, <String>{'/new.part'});
    expect(old, <String>{'/old.part'});
    await expectLater(index.readStorageAccessPreservationHints(), throwsStateError);
    await index.open();
    expect(await index.readStorageAccessPreservationHints(), <String>{'/new.part'});
  });
}
