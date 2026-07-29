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
  });
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
