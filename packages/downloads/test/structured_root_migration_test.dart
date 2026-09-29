import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('explicit direct-root migration moves only manual sealed authority',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-root-migration-app-',
    );
    final source = await Directory.systemTemp.createTemp(
      'zic-root-migration-source-',
    );
    final destination = await Directory.systemTemp.createTemp(
      'zic-root-migration-destination-',
    );
    addTearDown(() => appRoot.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => destination.delete(recursive: true));

    final composition = await PersistentDownloadComposition.open(
      appRoot.path,
      directory: source.path,
      indexPath: '${appRoot.path}/chapter_downloads.sqlite',
      transferNet: NetLane(maxActive: 5),
    );
    addTearDown(composition.close);
    final store = composition.artifactStore;
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;

    final manualBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final manualChecksum = (Crc32()..add(manualBytes)).hex;
    final manualPath = '${source.path}/Comic/001.webp';
    await File(manualPath).create(recursive: true);
    await File(manualPath).writeAsBytes(manualBytes);
    final manualId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'manual',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/manual.webp'),
    );
    await store.index.put(
      CacheRec(
        id: manualId,
        state: CacheState.ready,
        path: manualPath,
        bytes: manualBytes.length,
        checksum: manualChecksum,
        createdUs: nowUs,
        touchedUs: nowUs,
        pinned: true,
        storageRootId: source.path,
      ),
    );
    final replicaBefore =
        (await store.artifactReplicasFor(manualId)).single;

    final automaticBytes = Uint8List.fromList(<int>[5, 6, 7, 8]);
    final automaticChecksum = (Crc32()..add(automaticBytes)).hex;
    final automaticPath = '${source.path}/final/automatic.webp';
    await File(automaticPath).create(recursive: true);
    await File(automaticPath).writeAsBytes(automaticBytes);
    final automaticId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'automatic',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/automatic.webp'),
    );
    await store.index.put(
      CacheRec(
        id: automaticId,
        state: CacheState.ready,
        path: automaticPath,
        bytes: automaticBytes.length,
        checksum: automaticChecksum,
        createdUs: nowUs,
        touchedUs: nowUs,
        pinned: false,
        storageRootId: source.path,
      ),
    );

    final partialBytes = Uint8List.fromList(<int>[9, 8, 7]);
    final partialPath = '${source.path}/partial/manual.part';
    await File(partialPath).create(recursive: true);
    await File(partialPath).writeAsBytes(partialBytes);
    final partialId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'partial',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/partial.webp'),
    );
    await store.index.put(
      CacheRec(
        id: partialId,
        state: CacheState.partial,
        path: partialPath,
        bytes: partialBytes.length,
        checksum: '',
        createdUs: nowUs,
        touchedUs: nowUs,
        pinned: true,
        storageRootId: source.path,
      ),
    );

    final placement = DownloadPlacement(
      placementId: 'source\u0000comic',
      sourceId: 'source',
      comicId: 'comic',
      comicTitle: 'Comic',
      mode: DownloadPlacementMode.incremental,
      relativeDirectory: 'Comic',
      storageRootId: 'default',
      generation: 4,
      fingerprint: 'stable-fingerprint',
      pageOrder: ComicPageOrder.chronological,
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
    );
    await store.index.putPlacement(placement);
    final manifestPath = '${source.path}/Comic/$comicManifestFileName';
    const manifestBytes = <int>[123, 34, 111, 107, 34, 58, 116, 114, 117, 101, 125];
    await File(manifestPath).writeAsBytes(manifestBytes);

    final result = await store.migrateStructuredDirectRoot(
      sourceRoot: source.path,
      destinationRoot: destination.path,
    );

    expect(result.replicas, 1);
    expect(result.placements, 1);
    final destinationManual = '${destination.path}/Comic/001.webp';
    expect(await File(destinationManual).readAsBytes(), manualBytes);
    expect(await File(manualPath).exists(), isFalse);
    final manualAfter = await store.index.get(manualId.key);
    expect(manualAfter?.path, destinationManual);
    expect(manualAfter?.storageRootId, destination.path);
    final replicaAfter = (await store.artifactReplicasFor(manualId)).single;
    expect(replicaAfter.replicaId, replicaBefore.replicaId);
    expect(replicaAfter.accessLocator, destinationManual);
    expect(replicaAfter.storageRootId, destination.path);

    expect(await File(automaticPath).readAsBytes(), automaticBytes);
    final automaticAfter = await store.index.get(automaticId.key);
    expect(automaticAfter?.path, automaticPath);
    expect(automaticAfter?.storageRootId, source.path);
    expect(await File(partialPath).readAsBytes(), partialBytes);
    final partialAfter = await store.index.get(partialId.key);
    expect(partialAfter?.path, partialPath);
    expect(partialAfter?.storageRootId, source.path);

    final placementAfter = await store.index.getPlacement(
      sourceId: 'source',
      comicId: 'comic',
    );
    expect(placementAfter?.storageRootId, destination.path);
    expect(placementAfter?.generation, placement.generation + 1);
    expect(placementAfter?.fingerprint, placement.fingerprint);
    expect(
      await File(
        '${destination.path}/Comic/$comicManifestFileName',
      ).readAsBytes(),
      manifestBytes,
    );
    expect(await File(manifestPath).exists(), isFalse);
  });

  test('direct-root migration preflights destination conflict before authority',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-root-migration-conflict-app-',
    );
    final source = await Directory.systemTemp.createTemp(
      'zic-root-migration-conflict-source-',
    );
    final destination = await Directory.systemTemp.createTemp(
      'zic-root-migration-conflict-destination-',
    );
    addTearDown(() => appRoot.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => destination.delete(recursive: true));

    final composition = await PersistentDownloadComposition.open(
      appRoot.path,
      directory: source.path,
      indexPath: '${appRoot.path}/chapter_downloads.sqlite',
      transferNet: NetLane(maxActive: 5),
    );
    addTearDown(composition.close);
    final store = composition.artifactStore;
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final checksum = (Crc32()..add(bytes)).hex;
    final sourcePath = '${source.path}/Comic/001.webp';
    final destinationPath = '${destination.path}/Comic/001.webp';
    await File(sourcePath).create(recursive: true);
    await File(sourcePath).writeAsBytes(bytes);
    await File(destinationPath).create(recursive: true);
    await File(destinationPath).writeAsBytes(<int>[9, 9, 9, 9]);
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
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    await store.index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: sourcePath,
        bytes: bytes.length,
        checksum: checksum,
        createdUs: nowUs,
        touchedUs: nowUs,
        pinned: true,
        storageRootId: source.path,
      ),
    );

    await expectLater(
      store.migrateStructuredDirectRoot(
        sourceRoot: source.path,
        destinationRoot: destination.path,
      ),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.policy,
        ),
      ),
    );

    expect(await File(sourcePath).readAsBytes(), bytes);
    final record = await store.index.get(id.key);
    expect(record?.path, sourcePath);
    expect(record?.storageRootId, source.path);
  });

  test('cold recovery resumes after an earlier replica authority commit',
      () async {
    final appRoot = await Directory.systemTemp.createTemp(
      'zic-root-migration-resume-app-',
    );
    final source = await Directory.systemTemp.createTemp(
      'zic-root-migration-resume-source-',
    );
    final destination = await Directory.systemTemp.createTemp(
      'zic-root-migration-resume-destination-',
    );
    addTearDown(() => appRoot.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    addTearDown(() => destination.delete(recursive: true));
    final indexPath = '${appRoot.path}/chapter_downloads.sqlite';

    final composition = await PersistentDownloadComposition.open(
      appRoot.path,
      directory: source.path,
      indexPath: indexPath,
      transferNet: NetLane(maxActive: 5),
    );
    addTearDown(composition.close);
    final store = composition.artifactStore;
    final nowUs = DateTime.now().toUtc().microsecondsSinceEpoch;
    final ids = <DownloadId>[];
    for (var page = 1; page <= 2; page++) {
      final bytes = Uint8List.fromList(<int>[page, page + 1, page + 2]);
      final path = '${source.path}/Comic/00$page.webp';
      await File(path).create(recursive: true);
      await File(path).writeAsBytes(bytes);
      final id = DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'resume-comic',
          chapterId: 'chapter',
          pageId: 'p$page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/resume-$page.webp'),
      );
      ids.add(id);
      await store.index.put(
        CacheRec(
          id: id,
          state: CacheState.ready,
          path: path,
          bytes: bytes.length,
          checksum: (Crc32()..add(bytes)).hex,
          createdUs: nowUs,
          touchedUs: nowUs,
          pinned: true,
          storageRootId: source.path,
        ),
      );
    }
    await store.index.putPlacement(
      DownloadPlacement(
        placementId: 'source\u0000resume-comic',
        sourceId: 'source',
        comicId: 'resume-comic',
        comicTitle: 'Comic',
        mode: DownloadPlacementMode.incremental,
        relativeDirectory: 'Comic',
        storageRootId: source.path,
        generation: 2,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      ),
    );
    final manifest = File('${source.path}/Comic/$comicManifestFileName');
    await manifest.writeAsString('{"resume":true}');

    final firstReplica = (await store.artifactReplicasFor(ids.first)).single;
    await store.migrateArtifactReplica(
      id: ids.first,
      replicaId: firstReplica.replicaId,
      destinationAccessLocator: '${destination.path}/Comic/001.webp',
      destinationStorageRootId: destination.path,
    );
    expect(await File('${source.path}/Comic/001.webp').exists(), isFalse);
    expect(await File('${source.path}/Comic/002.webp').exists(), isTrue);
    await composition.close();

    final recovered = await migratePersistentDownloadStructuredDirectRoot(
      root: appRoot.path,
      sourceRoot: source.path,
      destinationRoot: destination.path,
      indexPath: indexPath,
    );
    expect(recovered.replicas, 1,
        reason: 'the already-committed first replica must not be recopied');
    expect(recovered.placements, 1);

    final reopened = await PersistentDownloadComposition.open(
      appRoot.path,
      directory: destination.path,
      indexPath: indexPath,
      transferNet: NetLane(maxActive: 5),
    );
    addTearDown(reopened.close);
    for (var page = 1; page <= 2; page++) {
      final record = await reopened.artifactStore.index.get(ids[page - 1].key);
      expect(record?.path, '${destination.path}/Comic/00$page.webp');
      expect(record?.storageRootId, destination.path);
    }
    final placement = await reopened.artifactStore.index.getPlacement(
      sourceId: 'source',
      comicId: 'resume-comic',
    );
    expect(placement?.storageRootId, destination.path);
    expect(await manifest.exists(), isFalse);
    expect(
      await File(
        '${destination.path}/Comic/$comicManifestFileName',
      ).readAsString(),
      '{"resume":true}',
    );
  });

}
