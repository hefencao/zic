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

  test('file location avoids byte reads and batches LRU metadata touches',
      () async {
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
    final metadata = await directory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .single;
    final beforeTouch = await metadata.readAsString();

    now = now.add(const Duration(minutes: 5));
    final located = await store.locate(key);

    expect(located, isNotNull);
    expect(located!.byteLength, 4);
    expect(await File(located.path).readAsBytes(), <int>[1, 3, 5, 7]);
    expect(await metadata.readAsString(), beforeTouch);

    await store.close();
    final afterClose = jsonDecode(await metadata.readAsString())
        as Map<String, Object?>;
    expect(
      DateTime.parse(afterClose['lastAccessedAt']! as String).toUtc(),
      now,
    );
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
    final store = FileResourceCacheByteStore(directory.path);
    addTearDown(store.close);

    await store.write(
      key: key,
      bytes: Uint8List.fromList(<int>[3, 1, 4]),
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final metadata = files.singleWhere((file) => file.path.endsWith('.json'));
    final bytes = files.singleWhere((file) => file.path.endsWith('.bin'));
    await metadata.writeAsString('{', flush: true);

    expect(await store.read(key), isNull);
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
