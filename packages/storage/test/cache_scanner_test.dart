import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

class _LiveIndex implements CacheIndex, StorageAccessAuthorityQuery {
  _LiveIndex(this.inner);

  final SqliteIndex inner;
  final authorityQueries = <String>[];

  @override
  Future<bool> isStorageAccessLocatorAuthoritative(String path) {
    authorityQueries.add(path);
    return inner.isStorageAccessLocatorAuthoritative(path);
  }

  @override
  Future<List<CacheRec>> list({CacheState? state}) => inner.list(state: state);

  @override
  Future<void> remove(String key) => inner.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PreservingIndex extends _LiveIndex
    implements StorageAccessPreservationQuery {
  _PreservingIndex(super.inner, {this.afterSnapshot});

  final Future<void> Function()? afterSnapshot;
  int snapshots = 0;

  @override
  Future<Set<String>> readStorageAccessPreservationHints() async {
    snapshots++;
    final hints = await inner.readStorageAccessPreservationHints();
    await afterSnapshot?.call();
    return hints;
  }
}

CacheRec _partial(DownloadId id, String path) => CacheRec(
      id: id,
      state: CacheState.partial,
      path: path,
      bytes: 1,
      checksum: '',
      createdUs: 1,
      touchedUs: 2,
    );

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

  test('known preservation hints avoid per-file authority queries', () async {
    final path = '${layout.partialDir}/known.part';
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(<int>[1]);
    await File('$path.meta').writeAsString('malformed sidecar');
    await index.put(_partial(id, path));
    final observed = _PreservingIndex(index);

    final report = await CacheScanner(layout: layout, index: observed).scan();

    expect(observed.snapshots, 1);
    expect(observed.authorityQueries, isEmpty);
    expect(report.deletedOrphans, 0);
    expect(await File(path).exists(), isTrue);
    expect(await File('$path.meta').exists(), isTrue);
  });

  test('live misses preserve new authority and stale hints only defer cleanup',
      () async {
    final stale = '${layout.partialDir}/stale.part';
    final fresh = '${layout.partialDir}/fresh.part';
    await File(stale).parent.create(recursive: true);
    await File(stale).writeAsBytes(<int>[1]);
    await File('$stale.meta').writeAsString('{}');
    await index.put(_partial(id, stale));
    final freshId = DownloadId(
      content: const ContentId(
        sourceId: 'source', comicId: 'comic', chapterId: 'chapter', pageId: 'fresh',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/fresh.webp'),
    );
    var mutate = true;
    final observed = _PreservingIndex(index, afterSnapshot: () async {
      if (!mutate) return;
      mutate = false;
      await index.remove(id.key);
      await File(fresh).writeAsBytes(<int>[2]);
      await File('$fresh.meta.tmp').writeAsString('{}');
      await index.put(_partial(freshId, fresh));
    });

    final scanner = CacheScanner(layout: layout, index: observed);
    final first = await scanner.scan();

    expect(first.deletedOrphans, 0);
    expect(observed.authorityQueries, contains(fresh));
    expect(observed.authorityQueries, isNot(contains(stale)));
    expect(await File(fresh).readAsBytes(), <int>[2]);
    expect(await File('$fresh.meta').exists(), isTrue);
    expect(await File('$fresh.meta.tmp').exists(), isFalse);
    expect(await File(stale).exists(), isTrue);
    expect(await index.isStorageAccessLocatorAuthoritative(stale), isFalse);

    // Reusing the scanner cannot retain a previous pass's stale hints.
    final second = await scanner.scan();
    expect(observed.snapshots, 2);
    expect(second.deletedOrphans, 2);
    expect(await File(stale).exists(), isFalse);
    expect(await File('$stale.meta').exists(), isFalse);
    expect(await File(fresh).exists(), isTrue);
    expect((await scanner.scan()).deletedOrphans, 0);
  });

  test('indexes without preservation prefetch still use live authority', () async {
    final path = '${layout.partialDir}/live.part';
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(<int>[1]);
    await index.put(_partial(id, path));
    final observed = _LiveIndex(index);

    final report = await CacheScanner(layout: layout, index: observed).scan();

    expect(observed.authorityQueries, <String>[path]);
    expect(report.deletedOrphans, 0);
    expect(await File(path).exists(), isTrue);
  });
}
