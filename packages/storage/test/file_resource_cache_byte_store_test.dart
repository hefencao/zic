import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resource_cache/resource_cache.dart';
import 'package:storage/storage.dart';
import 'package:test/test.dart';

void main() {
  test('durable response bytes survive store reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-bytes-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source\u0000https://example.invalid/cover.webp',
      namespace: 'comic:source\u0000comic',
      revision: 'cover-r1',
    );
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));

    final first = FileResourceCacheByteStore(directory.path);
    await first.write(
      key: key,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      expiresAt: expiresAt,
    );
    await first.close();

    final reopened = FileResourceCacheByteStore(directory.path);
    addTearDown(reopened.close);
    final restored = await reopened.read(key);

    expect(restored, isNotNull);
    expect(restored!.bytes, <int>[1, 2, 3, 4]);
    expect(restored.expiresAt.toUtc(), expiresAt);
  });

  test('resource manager reuses a persisted cover after process reopen',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-manager-reopen-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source\u0000cover',
      namespace: 'comic:source\u0000comic',
      revision: 'r1',
    );
    var loads = 0;

    final first = ResourceCacheManager(
      byteStore: FileResourceCacheByteStore(directory.path),
    );
    await first.getOrLoad<Uint8List>(
      key: key,
      loader: () async {
        loads++;
        return Uint8List.fromList(<int>[8, 6, 4, 2]);
      },
      weightOf: (bytes) => bytes.lengthInBytes,
    );
    await first.close();

    final reopened = ResourceCacheManager(
      byteStore: FileResourceCacheByteStore(directory.path),
    );
    addTearDown(reopened.close);
    final bytes = await reopened.getOrLoad<Uint8List>(
      key: key,
      loader: () async {
        loads++;
        return Uint8List.fromList(<int>[1]);
      },
      weightOf: (value) => value.lengthInBytes,
    );

    expect(bytes, <int>[8, 6, 4, 2]);
    expect(loads, 1);
    expect(reopened.stats.persistentHits, 1);
  });

  test('encoded image reopen returns owned bytes without source load',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-encoded-source-reopen-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'encoded-source-cover',
      revision: 'r1',
    );
    final first = ResourceCacheManager(
      byteStore: FileResourceCacheByteStore(directory.path),
    );
    await first.getOrLoadEncodedImage(
      key: key,
      loader: () async => Uint8List.fromList(<int>[5, 4, 3, 2, 1]),
    );
    await first.close();

    var sourceLoads = 0;
    final reopened = ResourceCacheManager(
      byteStore: FileResourceCacheByteStore(directory.path),
    );
    addTearDown(reopened.close);
    final source = await reopened.getOrLoadEncodedImage(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List.fromList(<int>[9]);
      },
    );

    expect(source, isA<MemoryEncodedResourceSource>());
    expect(source.origin, EncodedResourceOrigin.memory);
    expect((source as MemoryEncodedResourceSource).bytes, <int>[5, 4, 3, 2, 1]);
    expect(sourceLoads, 0);
  });

  test('file read uses one manifest and batches LRU touches', () async {
    var now = DateTime.utc(2026, 7, 29, 10);
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-file-location-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'cover-file-location',
      revision: 'r1',
    );
    final store = FileResourceCacheByteStore(
      directory.path,
      now: () => now,
    );
    final expiresAt = now.add(const Duration(hours: 1));
    await store.write(
      key: key,
      bytes: Uint8List.fromList(<int>[1, 3, 5, 7]),
      expiresAt: expiresAt,
    );
    final manifest = File(
      '${directory.path}/response-manifest-v1.json',
    );
    final beforeTouch = await manifest.readAsString();

    now = now.add(const Duration(minutes: 5));
    final persisted = await store.read(key);

    expect(persisted, isNotNull);
    expect(persisted!.bytes, <int>[1, 3, 5, 7]);
    expect(await manifest.readAsString(), beforeTouch);

    await store.close();
    final afterClose = jsonDecode(await manifest.readAsString())
        as Map<String, Object?>;
    final records = afterClose['records']! as List<Object?>;
    final record = (records.single as Map<Object?, Object?>)
        .cast<String, Object?>();
    expect(
      DateTime.parse(record['lastAccessedAt']! as String).toUtc(),
      now,
    );
  });

  test('reopen reads warm covers without per-entry metadata reads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-manifest-reopen-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'manifest-cover',
      revision: 'r1',
    );
    final first = FileResourceCacheByteStore(directory.path);
    await first.write(
      key: key,
      bytes: Uint8List.fromList(<int>[2, 4, 6, 8]),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    await first.close();

    final entryMetadata = await directory
        .list(recursive: true)
        .where(
          (entity) =>
              entity is File &&
              entity.path.endsWith('.json') &&
              !entity.path.endsWith('response-manifest-v1.json'),
        )
        .cast<File>()
        .single;
    await entryMetadata.delete();

    final reopened = FileResourceCacheByteStore(directory.path);
    addTearDown(reopened.close);
    final persisted = await reopened.read(key);

    expect(persisted, isNotNull);
    expect(persisted!.bytes, <int>[2, 4, 6, 8]);
  });

  test('missing manifest migrates the legacy per-entry journal once', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-manifest-migration-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'legacy-cover',
      revision: 'r1',
    );
    final first = FileResourceCacheByteStore(directory.path);
    await first.write(
      key: key,
      bytes: Uint8List.fromList(<int>[9, 7, 5]),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    await first.close();
    final manifest = File(
      '${directory.path}/response-manifest-v1.json',
    );
    await manifest.delete();

    final migrated = FileResourceCacheByteStore(directory.path);
    addTearDown(migrated.close);
    expect((await migrated.read(key))?.bytes, <int>[9, 7, 5]);
    expect(await manifest.exists(), isTrue);
  });

  test('manifest recovery removes encoded bytes with no journal', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-orphan-recovery-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'orphan-cover',
    );
    final first = FileResourceCacheByteStore(directory.path);
    await first.write(
      key: key,
      bytes: Uint8List.fromList(<int>[1, 4, 9]),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    await first.close();
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    await files
        .singleWhere((file) => file.path.endsWith('response-manifest-v1.json'))
        .delete();
    await files
        .singleWhere(
          (file) =>
              file.path.endsWith('.json') &&
              !file.path.endsWith('response-manifest-v1.json'),
        )
        .delete();
    final bytes = files.singleWhere((file) => file.path.endsWith('.bin'));

    final recovered = FileResourceCacheByteStore(directory.path);
    addTearDown(recovered.close);
    expect(await recovered.read(key), isNull);
    expect(await bytes.exists(), isFalse);
  });

  test('expired response bytes are rejected', () async {
    var now = DateTime.utc(2026, 7, 29, 10);
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-expiry-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'cover-expired',
    );
    final store = FileResourceCacheByteStore(
      directory.path,
      now: () => now,
    );
    addTearDown(store.close);

    await store.write(
      key: key,
      bytes: Uint8List.fromList(<int>[7, 8]),
      expiresAt: now.add(const Duration(minutes: 1)),
    );
    now = now.add(const Duration(minutes: 2));

    expect(await store.read(key), isNull);
  });

  test('corrupted metadata and its orphaned bytes are removed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-corrupt-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'cover-corrupt',
    );
    final first = FileResourceCacheByteStore(directory.path);
    await first.write(
      key: key,
      bytes: Uint8List.fromList(<int>[3, 1, 4]),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    await first.close();
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final manifest = files.singleWhere(
      (file) => file.path.endsWith('response-manifest-v1.json'),
    );
    final metadata = files.singleWhere(
      (file) =>
          file.path.endsWith('.json') &&
          !file.path.endsWith('response-manifest-v1.json'),
    );
    final bytes = files.singleWhere((file) => file.path.endsWith('.bin'));
    await manifest.delete();
    await metadata.writeAsString('{', flush: true);

    final reopened = FileResourceCacheByteStore(directory.path);
    addTearDown(reopened.close);
    expect(await reopened.read(key), isNull);
    expect(await metadata.exists(), isFalse);
    expect(await bytes.exists(), isFalse);
  });

  test('maintenance reports and trims durable response bytes by LRU', () async {
    var now = DateTime.utc(2026, 7, 29, 10);
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-maintenance-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final store = FileResourceCacheByteStore(
      directory.path,
      now: () => now,
    );
    addTearDown(store.close);
    final expiresAt = now.add(const Duration(hours: 1));
    const older = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'older-cover',
    );
    const newer = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'newer-cover',
    );

    await store.write(
      key: older,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      expiresAt: expiresAt,
    );
    now = now.add(const Duration(seconds: 1));
    await store.write(
      key: newer,
      bytes: Uint8List.fromList(<int>[4, 5]),
      expiresAt: expiresAt,
    );

    expect((await store.inspect()).bytes, 5);
    expect((await store.inspect()).entries, 2);
    final report = await store.trimTo(targetBytes: 2);

    expect(report.beforeBytes, 5);
    expect(report.releasedBytes, 3);
    expect(report.remainingBytes, 2);
    expect(report.evictedEntries, 1);
    expect(await store.read(older), isNull);
    expect((await store.read(newer))?.bytes, <int>[4, 5]);
  });

  test('namespace removal scans entries not loaded in memory', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-resource-namespace-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final store = FileResourceCacheByteStore(directory.path);
    addTearDown(store.close);
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));
    const removed = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'removed',
      namespace: 'comic:a',
    );
    const retained = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'retained',
      namespace: 'comic:b',
    );
    await store.write(
      key: removed,
      bytes: Uint8List.fromList(<int>[1]),
      expiresAt: expiresAt,
    );
    await store.write(
      key: retained,
      bytes: Uint8List.fromList(<int>[2]),
      expiresAt: expiresAt,
    );

    await store.removeWhere((key) => key.namespace == 'comic:a');

    expect(await store.read(removed), isNull);
    expect((await store.read(retained))?.bytes, <int>[2]);
  });
}
