import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late CacheLayout layout;
  late SqliteIndex index;

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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cache_scanner_test_');
    layout = CacheLayout(temp.path);
    index = SqliteIndex.memory();
    await index.open();
  });

  tearDown(() async {
    await index.close();
    await temp.delete(recursive: true);
  });

  test('sidecar-only crash files never manufacture durable authority', () async {
    final artifact = layout.artifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{'download': id.toJson()});
    await artifact.append(0, <int>[1, 2, 3]);
    await artifact.pause();

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.recovered, 0);
    expect(await index.get(id.key), isNull);
    expect(await File(artifact.partialPath).exists(), isFalse);
    expect(await File(artifact.metaPath).exists(), isFalse);
  });

  test('authoritative READY ignores missing owner metadata in sidecar', () async {
    final artifact = layout.artifactFor(id);
    await artifact.restore();
    await artifact.writeMeta(<String, Object?>{'download': id.toJson()});
    await artifact.append(0, <int>[1, 2, 3, 4]);
    await artifact.seal(expectedLength: 4);
    await artifact.promote();
    final snapshot = artifact.snapshot;
    const artifactId = 'scanner-ready-object';
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u0000scanner',
    );
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: snapshot.finalPath,
        bytes: snapshot.committedLength,
        checksum: snapshot.checksum,
        createdUs: 1,
        touchedUs: 2,
        pinned: false,
        checksumAlgorithm: 'crc32',
        artifactId: artifactId,
        storageRootId: layout.root,
      ),
    );
    await index.putPhysicalMediaArtifactBinding(
      id: physical,
      artifactId: artifactId,
      createdUs: 1,
      touchedUs: 2,
    );
    await File(artifact.finalMetaPath).writeAsString(
      jsonEncode(<String, Object?>{
        'artifactState': 'ready',
        'path': artifact.finalPath,
        'bytes': snapshot.committedLength,
        'checksum': snapshot.checksum,
      }),
      flush: true,
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.invalidMeta, 0);
    expect(await File(artifact.finalPath).readAsBytes(), <int>[1, 2, 3, 4]);
    expect((await index.get(id.key))?.state, CacheState.ready);
    expect(await index.getPhysicalMediaArtifact(physical), isNotNull);
    expect(await index.listArtifactReplicas(artifactId), hasLength(1));
  });

  test('READY compatibility path absence never removes logical authority',
      () async {
    final missing = '${layout.finalDir}${Platform.pathSeparator}missing.bin';
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.ready,
        path: missing,
        bytes: 4,
        checksum: 'b63cfbcd',
        createdUs: 1,
        touchedUs: 2,
        checksumAlgorithm: 'crc32',
        artifactId: 'missing-ready-object',
        storageRootId: layout.root,
      ),
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.removedRecords, 0);
    expect((await index.get(id.key))?.state, CacheState.ready);
    expect(await index.listArtifactReplicas('missing-ready-object'), hasLength(1));
  });

  test('indexed partial body survives without sidecar', () async {
    final path = '${layout.partialDir}${Platform.pathSeparator}indexed.part';
    await Directory(layout.partialDir).create(recursive: true);
    await File(path).writeAsBytes(<int>[1, 2, 3], flush: true);
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.partial,
        path: path,
        bytes: 3,
        checksum: '',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: layout.root,
      ),
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.removedRecords, 0);
    expect(await File(path).readAsBytes(), <int>[1, 2, 3]);
    expect((await index.get(id.key))?.state, CacheState.partial);
  });

  test('missing indexed partial body removes only the partial binding', () async {
    final path = '${layout.partialDir}${Platform.pathSeparator}missing.part';
    final sidecar = File('$path.meta');
    await sidecar.parent.create(recursive: true);
    await sidecar.writeAsString('{}');
    await index.put(
      CacheRec(
        id: id,
        state: CacheState.partial,
        path: path,
        bytes: 3,
        checksum: '',
        createdUs: 1,
        touchedUs: 2,
        storageRootId: layout.root,
      ),
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.removedRecords, 1);
    expect(await index.get(id.key), isNull);
    expect(await sidecar.exists(), isTrue);
    // A scan-local preservation hint cannot make the sidecar an owner.
    final next = await CacheScanner(layout: layout, index: index).scan();
    expect(next.deletedOrphans, 1);
    expect(await sidecar.exists(), isFalse);
  });

  test('uncommitted final body is orphan cleanup, not crash authority', () async {
    final artifact = layout.artifactFor(id);
    final data = File(artifact.finalPath);
    await data.parent.create(recursive: true);
    await data.writeAsBytes(<int>[1, 2, 3], flush: true);
    await File(artifact.finalMetaPath).writeAsString(
      jsonEncode(<String, Object?>{
        'download': id.toJson(),
        'artifactState': 'ready',
        'path': artifact.finalPath,
        'bytes': 3,
      }),
      flush: true,
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(report.recovered, 0);
    expect(await index.get(id.key), isNull);
    expect(await data.exists(), isFalse);
    expect(await File(artifact.finalMetaPath).exists(), isFalse);
  });

  test('promotion journal protects both source and destination candidates',
      () async {
    final download = DownloadId(
      content: const ContentId(
        sourceId: 'promotion-source',
        comicId: 'promotion-comic',
        chapterId: 'promotion-chapter',
        pageId: 'promotion-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/promotion.webp'),
    );
    final physical = PhysicalMediaId.canonical('promotion-scanner');
    final artifact = layout.artifactForPhysical(physical);
    const body = <int>[1, 2, 3, 4];
    final crc = Crc32()..add(body);
    await File(artifact.partialPath).parent.create(recursive: true);
    await File(artifact.partialPath).writeAsBytes(body, flush: true);
    await File(artifact.finalPath).parent.create(recursive: true);
    await File(artifact.finalPath).writeAsBytes(body, flush: true);
    await index.putPhysicalPartial(
      PhysicalPartialRecord(
        id: physical,
        path: artifact.partialPath,
        bytes: body.length,
        checksum: crc.hex,
        createdUs: 1,
        touchedUs: 2,
        storageRootId: layout.root,
      ),
    );
    await index.beginArtifactPromotion(
      id: download,
      physicalId: physical,
      sourceAccessLocator: artifact.partialPath,
      destinationAccessLocator: artifact.finalPath,
      bytes: body.length,
      checksum: crc.hex,
      storageRootId: layout.root,
    );

    final report = await CacheScanner(layout: layout, index: index).scan();

    expect(await File(artifact.partialPath).exists(), isTrue);
    expect(await File(artifact.finalPath).exists(), isTrue);
    expect(report.deletedOrphans, 0);
  });

  test('does not delete an active orphan', () async {
    final orphan = File('${layout.partialDir}/active.part');
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes(<int>[1]);

    final report = await CacheScanner(
      layout: layout,
      index: index,
      activePaths: <String>{orphan.path},
    ).scan();
    expect(report.protected, 1);
    expect(await orphan.exists(), isTrue);
  });
}
