import 'dart:async';
import 'dart:typed_data';

import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';

void main() {
  test('coalesces concurrent loads across one resource identity', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    var loads = 0;
    final key = const ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/cover',
    );
    Future<Uint8List> loader() async {
      loads++;
      return Uint8List.fromList(<int>[1, 2, 3]);
    }

    final values = await Future.wait(<Future<Uint8List>>[
      cache.getOrLoad(key: key, loader: loader, weightOf: (v) => v.length),
      cache.getOrLoad(key: key, loader: loader, weightOf: (v) => v.length),
    ]);

    expect(loads, 1);
    expect(values[0], same(values[1]));
  });

  test('coalesced loader failures stay owned by awaiting callers', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final gate = Completer<void>();
    var loads = 0;
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: 'source/failing-comic',
    );

    Future<String> loader() async {
      loads++;
      await gate.future;
      throw StateError('transient source failure');
    }

    final first = cache.getOrLoad<String>(
      key: key,
      loader: loader,
      weightOf: (value) => value.length,
    );
    final second = cache.getOrLoad<String>(
      key: key,
      loader: loader,
      weightOf: (value) => value.length,
    );
    final firstFailure = expectLater(first, throwsStateError);
    final secondFailure = expectLater(second, throwsStateError);
    gate.complete();

    await Future.wait<void>(<Future<void>>[firstFailure, secondFailure]);
    expect(loads, 1);
    expect(cache.stats.inFlight, 0);
  });

  test('restores durable image bytes before invoking the source', () async {
    final store = _MemoryResourceByteStore();
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/cover-persistent',
      namespace: 'comic:source\u0000comic',
    );
    var sourceLoads = 0;

    final first = ResourceCacheManager(byteStore: store);
    expect(
      await first.getOrLoad<Uint8List>(
        key: key,
        loader: () async {
          sourceLoads++;
          return Uint8List.fromList(<int>[7, 8, 9]);
        },
        weightOf: (bytes) => bytes.lengthInBytes,
      ),
      <int>[7, 8, 9],
    );
    await first.close();

    final reopened = ResourceCacheManager(byteStore: store);
    addTearDown(reopened.close);
    final restored = await reopened.getOrLoad<Uint8List>(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List.fromList(<int>[1]);
      },
      weightOf: (bytes) => bytes.lengthInBytes,
    );

    expect(restored, <int>[7, 8, 9]);
    expect(sourceLoads, 1);
    expect(reopened.stats.persistentHits, 1);
  });

  test('file-backed warm image hit avoids legacy byte materialization',
      () async {
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/file-backed-cover',
      namespace: 'comic:source\u0000comic',
      revision: 'cover-r1',
    );
    final store = _FileResourceByteStore(
      file: PersistedResourceFile(
        path: '/cache/cover-r1.webp',
        byteLength: 4096,
        expiresAt: DateTime.utc(2026, 8, 1),
      ),
    );
    final cache = ResourceCacheManager(
      byteStore: store,
      now: () => DateTime.utc(2026, 7, 29),
    );
    addTearDown(cache.close);
    var sourceLoads = 0;

    final source = await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );

    expect(source, isA<FileEncodedResourceSource>());
    expect((source as FileEncodedResourceSource).path, '/cache/cover-r1.webp');
    expect(source.lengthInBytes, 4096);
    expect(sourceLoads, 0);
    expect(store.locateCalls, 1);
    expect(store.readCalls, 0);
    final repeated = await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List(1);
      },
    );
    expect(repeated, same(source));
    expect(store.locateCalls, 1);
    expect(sourceLoads, 0);
  });

  test('new encoded image is persisted then returned as a file source',
      () async {
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/new-file-backed-cover',
    );
    final store = _FileResourceByteStore();
    final cache = ResourceCacheManager(byteStore: store);
    addTearDown(cache.close);

    final source = await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async => Uint8List.fromList(<int>[8, 6, 4, 2]),
    );

    expect(source, isA<FileEncodedResourceSource>());
    expect(store.writes, 1);
    expect(store.readCalls, 0);
    expect((source as FileEncodedResourceSource).path, '/cache/generated.bin');
  });

  test('close drains active image persistence before store shutdown', () async {
    final store = _MemoryResourceByteStore();
    final cache = ResourceCacheManager(byteStore: store);
    final started = Completer<void>();
    final gate = Completer<void>();
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/cover-close-drain',
    );

    final request = cache.getOrLoad<Uint8List>(
      key: key,
      loader: () async {
        started.complete();
        await gate.future;
        return Uint8List.fromList(<int>[2, 4, 6]);
      },
      weightOf: (bytes) => bytes.lengthInBytes,
    );
    await started.future;
    final closing = cache.close();
    expect(
      () => cache.peek<Uint8List>(key),
      throwsA(isA<StateError>()),
    );
    expect(cache.clear, throwsA(isA<StateError>()));
    gate.complete();
    expect(await request, <int>[2, 4, 6]);
    await closing;

    final reopened = ResourceCacheManager(byteStore: store);
    addTearDown(reopened.close);
    var sourceLoads = 0;
    expect(
      await reopened.getOrLoad<Uint8List>(
        key: key,
        loader: () async {
          sourceLoads++;
          return Uint8List.fromList(<int>[9]);
        },
        weightOf: (bytes) => bytes.lengthInBytes,
      ),
      <int>[2, 4, 6],
    );
    expect(sourceLoads, 0);
  });

  test('namespace invalidation also removes unseen durable images', () async {
    final store = _MemoryResourceByteStore();
    const namespace = 'comic:source\u0000comic';
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/cover-invalidate',
      namespace: namespace,
    );
    final first = ResourceCacheManager(byteStore: store);
    await first.getOrLoad<Uint8List>(
      key: key,
      loader: () async => Uint8List.fromList(<int>[4, 5, 6]),
      weightOf: (bytes) => bytes.lengthInBytes,
    );
    await first.close();

    final reopened = ResourceCacheManager(byteStore: store);
    addTearDown(reopened.close);
    reopened.invalidateNamespace(namespace);
    var sourceLoads = 0;
    final value = await reopened.getOrLoad<Uint8List>(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List.fromList(<int>[9]);
      },
      weightOf: (bytes) => bytes.lengthInBytes,
    );

    expect(value, <int>[9]);
    expect(sourceLoads, 1);
  });

  test('applies TTL and reloads expired metadata', () async {
    var now = DateTime.utc(2026, 1, 1);
    final cache = ResourceCacheManager(
      now: () => now,
      policies: <ResourceCacheKind, ResourceCachePolicy>{
        for (final kind in ResourceCacheKind.values)
          kind: const ResourceCachePolicy(
            maxEntries: 8,
            maxWeight: 1024,
            ttl: Duration(seconds: 1),
          ),
      },
    );
    addTearDown(cache.close);
    var loads = 0;
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: 'source/comic',
    );

    Future<String> load() async => 'value-${++loads}';
    expect(
      await cache.getOrLoad(key: key, loader: load, weightOf: (_) => 1),
      'value-1',
    );
    now = now.add(const Duration(seconds: 2));
    expect(
      await cache.getOrLoad(key: key, loader: load, weightOf: (_) => 1),
      'value-2',
    );
  });

  test('shares a global budget across resource kinds', () async {
    final cache = ResourceCacheManager(
      globalMaxWeight: 4,
      policies: <ResourceCacheKind, ResourceCachePolicy>{
        for (final kind in ResourceCacheKind.values)
          kind: const ResourceCachePolicy(
            maxEntries: 8,
            maxWeight: 4,
            ttl: Duration(minutes: 1),
          ),
      },
    );
    addTearDown(cache.close);

    for (var index = 0; index < 3; index++) {
      final kind = index.isEven
          ? ResourceCacheKind.imageBytes
          : ResourceCacheKind.searchResults;
      await cache.getOrLoad(
        key: ResourceCacheKey(kind: kind, identity: '$index'),
        loader: () async => Uint8List(2),
        weightOf: (value) => value.length,
      );
    }

    expect(cache.stats.weight, lessThanOrEqualTo(4));
    expect(cache.stats.evictions, greaterThan(0));
  });

  test('namespace invalidation removes related resource kinds only', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    const namespace = 'comic:source\u0000comic-a';

    for (final kind in <ResourceCacheKind>[
      ResourceCacheKind.imageBytes,
      ResourceCacheKind.comicDetails,
      ResourceCacheKind.chapterMetadata,
    ]) {
      await cache.getOrLoad<String>(
        key: ResourceCacheKey(
          kind: kind,
          identity: kind.name,
          namespace: namespace,
        ),
        loader: () async => kind.name,
        weightOf: (value) => value.length,
      );
    }
    await cache.getOrLoad<String>(
      key: const ResourceCacheKey(
        kind: ResourceCacheKind.searchResults,
        identity: 'search',
        namespace: 'source:source',
      ),
      loader: () async => 'search',
      weightOf: (value) => value.length,
    );

    cache.invalidateNamespace(namespace);

    expect(cache.stats.forKind(ResourceCacheKind.imageBytes).entries, 0);
    expect(cache.stats.forKind(ResourceCacheKind.comicDetails).entries, 0);
    expect(cache.stats.forKind(ResourceCacheKind.chapterMetadata).entries, 0);
    expect(cache.stats.forKind(ResourceCacheKind.searchResults).entries, 1);
  });

  test('clear prevents an older in-flight response from repopulating cache',
      () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final gate = Completer<void>();
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: 'source/comic',
    );

    final pending = cache.getOrLoad<String>(
      key: key,
      loader: () async {
        await gate.future;
        return 'stale';
      },
      weightOf: (value) => value.length,
    );
    cache.clear();
    gate.complete();
    expect(await pending, 'stale');
    expect(cache.peek<String>(key), isNull);
  });

  test('force refresh supersedes a slower previous response', () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final firstGate = Completer<void>();
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.comicDetails,
      identity: 'source/comic',
    );

    final first = cache.getOrLoad<String>(
      key: key,
      loader: () async {
        await firstGate.future;
        return 'old';
      },
      weightOf: (value) => value.length,
    );
    final refreshed = cache.getOrLoad<String>(
      key: key,
      forceRefresh: true,
      loader: () async => 'new',
      weightOf: (value) => value.length,
    );
    expect(await refreshed, 'new');
    firstGate.complete();
    expect(await first, 'old');
    expect(cache.peek<String>(key), 'new');
  });

  test('coordinator counts and clears durable response bytes', () async {
    final store = _MemoryResourceByteStore();
    final responses = ResourceCacheManager(byteStore: store);
    final coordinator = ResourceCacheCoordinator(responses: responses);
    addTearDown(coordinator.close);
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/durable-cover',
      namespace: 'comic:source\u0000comic',
    );

    await responses.getOrLoad<Uint8List>(
      key: key,
      loader: () async => Uint8List.fromList(<int>[1, 2, 3]),
      weightOf: (bytes) => bytes.lengthInBytes,
    );

    final usage = await coordinator.inspect();
    expect(usage.responses.weight, 3);
    expect(usage.persistentResponses?.bytes, 3);
    expect(usage.persistentResponses?.entries, 1);
    expect(usage.totalBytes, 6);

    final report = await coordinator.clear();
    expect(report.responseReleasedBytes, 3);
    expect(report.persistentResponseReleasedBytes, 3);
    expect(report.persistentResponses?.bytes, 0);
    expect(store.values, isEmpty);
  });

  test(
    'coordinator reports response and artifact planes without taking ownership',
    () async {
      final responses = ResourceCacheManager();
      final artifacts = _FakeArtifactMaintenance();
      final coordinator = ResourceCacheCoordinator(
        responses: responses,
        artifacts: artifacts,
      );
      addTearDown(coordinator.close);

      await responses.getOrLoad<String>(
        key: const ResourceCacheKey(
          kind: ResourceCacheKind.searchResults,
          identity: 'source/search',
        ),
        loader: () async => 'cached',
        weightOf: (value) => value.length,
      );

      final usage = await coordinator.inspect();
      expect(usage.responses.entries, 1);
      expect(usage.artifacts?.entries, 2);
      expect(usage.totalBytes, 'cached'.length + 12);

      final clearReport = await coordinator.clear();
      expect(responses.stats.entries, 0);
      expect(clearReport.totalReleasedBytes, 'cached'.length + 12);
      expect(artifacts.clearCalls, 1);
    },
  );
}


final class _FileResourceByteStore
    implements ResourceCacheByteStore, ResourceCacheByteStoreFileAccess {
  _FileResourceByteStore({this.file});

  PersistedResourceFile? file;
  int locateCalls = 0;
  int readCalls = 0;
  int writes = 0;

  @override
  Future<PersistedResourceFile?> locate(ResourceCacheKey key) async {
    locateCalls++;
    return file;
  }

  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) async {
    readCalls++;
    throw StateError('file-capable image path must not call read');
  }

  @override
  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) async {
    writes++;
    file = PersistedResourceFile(
      path: '/cache/generated.bin',
      byteLength: bytes.lengthInBytes,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> remove(ResourceCacheKey key) async {
    file = null;
  }

  @override
  Future<void> removeWhere(
    bool Function(ResourceCacheKey key) predicate,
  ) async {
    file = null;
  }

  @override
  Future<void> clear() async {
    file = null;
  }

  @override
  Future<void> close() async {}
}

final class _MemoryResourceByteStore
    implements ResourceCacheByteStore, ResourceCacheByteStoreMaintenance {
  final Map<ResourceCacheKey, PersistedResourceBytes> values =
      <ResourceCacheKey, PersistedResourceBytes>{};

  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) async =>
      values[key];

  @override
  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) async {
    values[key] = PersistedResourceBytes(
      bytes: Uint8List.fromList(bytes),
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> remove(ResourceCacheKey key) async {
    values.remove(key);
  }

  @override
  Future<void> removeWhere(
    bool Function(ResourceCacheKey key) predicate,
  ) async {
    values.removeWhere((key, value) => predicate(key));
  }

  @override
  Future<void> clear() async => values.clear();

  @override
  Future<ResourceCacheByteStoreUsage> inspect() async =>
      ResourceCacheByteStoreUsage(
        bytes: values.values.fold<int>(
          0,
          (sum, value) => sum + value.bytes.lengthInBytes,
        ),
        entries: values.length,
      );

  @override
  Future<ResourceCacheByteStoreTrimReport> trimTo({
    required int targetBytes,
  }) async {
    final before = (await inspect()).bytes;
    var remaining = before;
    var evicted = 0;
    for (final key in values.keys.toList(growable: false)) {
      if (remaining <= targetBytes) {
        break;
      }
      remaining -= values.remove(key)!.bytes.lengthInBytes;
      evicted++;
    }
    return ResourceCacheByteStoreTrimReport(
      beforeBytes: before,
      releasedBytes: before - remaining,
      remainingBytes: remaining,
      evictedEntries: evicted,
    );
  }

  @override
  Future<void> close() async {}
}

final class _FakeArtifactMaintenance implements ArtifactCacheMaintenance {
  int clearCalls = 0;

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async =>
      const ArtifactCacheUsage(bytes: 12, entries: 2);

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async =>
      const ArtifactCacheReport(
        beforeBytes: 12,
        releasedBytes: 4,
        remainingBytes: 8,
        evictedEntries: 1,
        skippedBusy: 0,
      );

  @override
  Future<ArtifactCacheReport> clearArtifacts() async {
    clearCalls++;
    return const ArtifactCacheReport(
      beforeBytes: 12,
      releasedBytes: 12,
      remainingBytes: 0,
      evictedEntries: 2,
      skippedBusy: 0,
    );
  }
}
