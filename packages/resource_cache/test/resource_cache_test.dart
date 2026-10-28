import 'dart:async';
import 'dart:typed_data';

import 'package:resource_cache/resource_cache.dart';
import 'package:test/test.dart';

void main() {
  test('automatic cache pending usage excludes retained cleanup debt', () {
    final manager = ResourceCacheManager();
    final usage = ResourceCacheUsage(
      responses: manager.stats,
      artifacts: const ArtifactCacheUsage(bytes: 100, entries: 3,
          retainedBytes: 60, pendingCleanupBytes: 30,
          automaticPendingCleanupBytes: 10),
    );
    expect(usage.totalBytes, 100);
    expect(usage.automaticPageBytes, 40);
    expect(usage.retainedDownloadBytes, 60);
    expect(usage.pendingCleanupBytes, 30);
    expect(usage.automaticPendingCleanupBytes, 10);
    addTearDown(manager.close);
  });

  test('encoded sources keep owned memory and stable local-file lifetimes', () {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final memory = MemoryEncodedResourceSource(bytes);
    const local = FileEncodedResourceSource(
      path: '/tmp/local-cover.webp',
      lengthInBytes: 42,
    );
    expect(memory.bytes, same(bytes));
    expect(memory.origin, EncodedResourceOrigin.memory);
    expect(memory.lengthInBytes, 3);
    expect(local.origin, EncodedResourceOrigin.localFile);
    expect(local.lengthInBytes, 42);
  });

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

  test(
    'coalesces complete encoded image resolution before durable lookup',
      () async {
    final cache = ResourceCacheManager();
    addTearDown(cache.close);
    final gate = Completer<void>();
    var loads = 0;
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/custom-locator-cover',
    );

    Future<Uint8List> loader() async {
      loads++;
      await gate.future;
      return Uint8List.fromList(<int>[8, 9, 10]);
    }

    final first = cache.getOrLoadEncodedImage(key: key, loader: loader);
    final second = cache.getOrLoadEncodedImage(key: key, loader: loader);
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);

    gate.complete();
      final values = await Future.wait<EncodedResourceSource>(
        <Future<EncodedResourceSource>>[first, second],
      );
    expect(
      (values.first as MemoryEncodedResourceSource).bytes,
      same((values.last as MemoryEncodedResourceSource).bytes),
    );
    expect(values.first.lengthInBytes, 3);
    },
  );

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

  test('metadata stays owner-local while image bytes survive cache reopen',
      () async {
    final store = _MemoryResourceByteStore();
    final metadataKeys = <ResourceCacheKey>[
      for (final kind in <ResourceCacheKind>[
        ResourceCacheKind.comicDetails,
        ResourceCacheKind.chapterMetadata,
        ResourceCacheKind.searchResults,
      ])
        ResourceCacheKey(kind: kind, identity: 'source/metadata'),
    ];
    for (final key in metadataKeys) {
      store.values[key] = PersistedResourceBytes(
        bytes: Uint8List.fromList(<int>[99]),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
    }
    const imageKey = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/cover',
    );
    var imageLoads = 0;
    final metadataLoads = <ResourceCacheKey, int>{};
    for (var generation = 1; generation <= 2; generation++) {
      final cache = ResourceCacheManager(byteStore: store);
      try {
        for (final key in metadataKeys) {
          Future<Uint8List> load() async {
            metadataLoads.update(key, (value) => value + 1, ifAbsent: () => 1);
            return Uint8List.fromList(<int>[generation]);
          }

          for (var read = 0; read < 2; read++) {
            expect(
              await cache.getOrLoad<Uint8List>(
                key: key, loader: load, weightOf: (value) => value.length,
              ),
              <int>[generation],
            );
          }
          expect(metadataLoads[key], generation);
          expect(store.values[key]!.bytes, <int>[99]);
        }
        expect(
          await cache.getOrLoad<Uint8List>(
            key: imageKey,
            loader: () async {
              imageLoads++;
              return Uint8List.fromList(<int>[7]);
            },
            weightOf: (value) => value.length,
          ),
          <int>[7],
        );
        expect(imageLoads, 1);
        expect(store.writes, 1);
      } finally {
        await cache.close();
      }
    }
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

  test('warm persisted image becomes an owned memory snapshot', () async {
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/persisted-cover',
      namespace: 'comic:source\u0000comic',
      revision: 'cover-r1',
    );
    final store = _MemoryResourceByteStore();
    final expiresAt = DateTime.utc(2026, 8, 1);
    await store.write(
      key: key,
      bytes: Uint8List.fromList(<int>[1, 3, 5, 7]),
      expiresAt: expiresAt,
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
        return Uint8List.fromList(<int>[9]);
      },
    );

    expect(source, isA<MemoryEncodedResourceSource>());
    expect((source as MemoryEncodedResourceSource).bytes, <int>[1, 3, 5, 7]);
    expect(source.origin, EncodedResourceOrigin.memory);
    expect(sourceLoads, 0);
    expect(cache.stats.persistentHits, 1);

    final repeated = await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async {
        sourceLoads++;
        return Uint8List.fromList(<int>[8]);
      },
    );
    expect(repeated, isA<MemoryEncodedResourceSource>());
    expect((repeated as MemoryEncodedResourceSource).bytes, <int>[1, 3, 5, 7]);
    expect(sourceLoads, 0);
  });

  test(
    'new encoded image persists bytes without lending its cache path',
      () async {
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/new-persisted-cover',
    );
    final store = _MemoryResourceByteStore();
    final cache = ResourceCacheManager(byteStore: store);
    addTearDown(cache.close);

    final source = await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async => Uint8List.fromList(<int>[8, 6, 4, 2]),
    );

    expect(source, isA<MemoryEncodedResourceSource>());
    expect((source as MemoryEncodedResourceSource).bytes, <int>[8, 6, 4, 2]);
    expect(store.values[key]?.bytes, <int>[8, 6, 4, 2]);
    },
  );

  test('foreground encoded image returns before durable persistence', () async {
    final writeStarted = Completer<void>();
    final writeGate = Completer<void>();
    final store = _MemoryResourceByteStore(
      writeStarted: writeStarted,
      writeGate: writeGate,
    );
    final cache = ResourceCacheManager(byteStore: store);
    addTearDown(() async {
      if (!writeGate.isCompleted) {
        writeGate.complete();
      }
      await cache.close();
    });
    const previousKey = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/previous-foreground-cover',
    );
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/foreground-cover',
    );

    await cache.getOrLoadEncodedImage(
      key: previousKey,
      awaitPersistence: false,
      loader: () async => Uint8List.fromList(<int>[9, 2, 6, 5]),
    );
    await writeStarted.future;

    final source = await cache.getOrLoadEncodedImage(
      key: key,
      awaitPersistence: false,
      loader: () async => Uint8List.fromList(<int>[3, 1, 4, 1, 5]),
    );

    expect(source, isA<MemoryEncodedResourceSource>());
    expect((source as MemoryEncodedResourceSource).bytes, <int>[3, 1, 4, 1, 5]);
    expect(store.writes, 1);

    writeGate.complete();
    await cache.drainPersistence();
    expect(store.writes, 2);
    expect(store.values[key]!.bytes, <int>[3, 1, 4, 1, 5]);
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
    expect(() => cache.peek<Uint8List>(key), throwsA(isA<StateError>()));
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

  test(
    'clear prevents an older in-flight response from repopulating cache',
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
    },
  );

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
    'a user cache limit updates the trim policy without eager eviction',
      () async {
    final artifacts = _FakeArtifactMaintenance();
    final coordinator = ResourceCacheCoordinator(
      responses: ResourceCacheManager(),
      artifacts: artifacts,
    );
    addTearDown(coordinator.close);

    final policy = ResourceCacheMaintenancePolicy.forArtifactLimitBytes(
      128 * 1024 * 1024,
    );
    expect(policy.artifactMaxWeight, 128 * 1024 * 1024);
    expect(policy.artifactTargetWeight, 128 * 1024 * 1024 - (128 * 1024 * 1024 ~/ 20));

    coordinator.updateMaintenancePolicy(policy);
    expect(identical(coordinator.maintenancePolicy, policy), isTrue);
    expect(artifacts.lastAutomaticLimits,
        (maxBytes: policy.artifactMaxWeight, targetBytes: policy.artifactTargetWeight));
    expect(ResourceCacheMaintenancePolicy.forArtifactLimitBytes(8192 * 1024 * 1024)
        .artifactTargetWeight, (8192 - 64) * 1024 * 1024);
    // Configuration delegates asynchronous work without eagerly running trim.
    expect(artifacts.trimCalls, 0);

    await coordinator.trim();
    expect(artifacts.trimCalls, 1);
      expect(artifacts.lastTrim?.maxBytes, 128 * 1024 * 1024);
    expect(artifacts.lastTrim?.targetBytes, 128 * 1024 * 1024 - (128 * 1024 * 1024 ~/ 20));
    },
  );

  test(
    'coordinator trim releases transient persistence but preserves retained artwork',
      () async {
    final store = _MemoryResourceByteStore();
    final responses = ResourceCacheManager(byteStore: store);
    final coordinator = ResourceCacheCoordinator(
      responses: responses,
      maintenancePolicy: const ResourceCacheMaintenancePolicy(
        responseTargetWeight: 0,
        transientPersistentResponseTargetWeight: 0,
      ),
    );
    addTearDown(coordinator.close);
    const retainedKey = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/retained-cover',
      namespace: 'comic:source\u0000retained',
    );
    const transientKey = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source/transient-preview',
      namespace: 'comic:source\u0000transient',
    );

    await responses.getOrLoadEncodedImage(
      key: retainedKey,
      retention: ResourceCacheRetention.retained,
      loader: () async => Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    await responses.getOrLoadEncodedImage(
      key: transientKey,
      loader: () async => Uint8List.fromList(<int>[5, 6]),
    );
    await responses.drainPersistence();

    final report = await coordinator.trim();
    expect(report.persistentResponseReleasedBytes, 2);
    expect(store.values.containsKey(transientKey), isFalse);
    expect(store.values.containsKey(retainedKey), isTrue);
    final usage = await coordinator.inspect();
    expect(usage.persistentResponses?.bytes, 4);
    expect(usage.persistentResponses?.retainedBytes, 4);
    expect(usage.persistentResponses?.transientBytes, 0);
    },
  );

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

  test(
    'coordinator includes volatile presentation raster maintenance plane',
    () async {
      final rasters = _FakePresentationRasterMaintenance();
      final coordinator = ResourceCacheCoordinator(
        responses: ResourceCacheManager(),
        presentationRasters: rasters,
      );
      addTearDown(coordinator.close);

      final usage = await coordinator.inspect();
      expect(usage.presentationRasters?.bytes, 40);
      expect(usage.presentationRasters?.entries, 2);
      expect(usage.volatilePresentationBytes, 40);
      expect(usage.volatilePresentationEntries, 2);
      expect(
        usage.totalBytes,
        0,
        reason:
            'volatile raster residency is coordinated but must not be misreported as the user durable-cache capacity',
      );

      final trim = await coordinator.trim();
      expect(rasters.trimCalls, 1);
      expect(trim.presentationRasters?.releasedBytes, 10);
      expect(trim.volatilePresentationReleasedBytes, 10);

      final clear = await coordinator.clear();
      expect(rasters.clearCalls, 1);
      expect(clear.presentationRasters?.releasedBytes, 30);
    },
  );

  test(
    'retained image promotes the same durable key without a second namespace',
      () async {
    final store = _MemoryResourceByteStore();
    const key = ResourceCacheKey(
      kind: ResourceCacheKind.imageBytes,
      identity: 'source\u0000cover',
      namespace: 'comic:source\u0000comic',
      revision: 'artwork-v2',
    );
    final cache = ResourceCacheManager(byteStore: store);
    addTearDown(cache.close);

    await cache.getOrLoadEncodedImage(
      key: key,
      loader: () async => Uint8List.fromList(<int>[1, 2, 3]),
    );
    await cache.drainPersistence();
    expect(store.retentions[key], ResourceCacheRetention.transient);

    final source = await cache.getOrLoadEncodedImage(
      key: key,
      retention: ResourceCacheRetention.retained,
        loader: () async =>
            throw StateError('memory hit must not reload source'),
    );
    expect(source, isNotNull);
    await cache.drainPersistence();

    expect(store.values.keys, <ResourceCacheKey>[key]);
    expect(store.writes, 1);
    expect(store.retentions[key], ResourceCacheRetention.retained);
    expect(store.values[key]!.expiresAt, isNull);
    final trim = await store.trimTo(targetBytes: 0);
    expect(trim.releasedBytes, 0);
    expect(store.values[key]!.bytes, <int>[1, 2, 3]);
    },
  );

  for (final revocation in <String>[
    'invalidate', 'clear', 'refresh', 'transient-refresh', 'expire', 'memory-trim',
  ]) {
    test('queued hot promotion respects $revocation', () async {
      var now = DateTime.utc(2026, 10, 8);
      final retainStarted = Completer<void>();
      final retainGate = Completer<void>();
      final store = _MemoryResourceByteStore(
        retainStarted: retainStarted,
        retainGate: retainGate,
      );
      const key = ResourceCacheKey(
        kind: ResourceCacheKind.imageBytes,
        identity: 'evicted-browse-cover',
      );
      final cache = ResourceCacheManager(byteStore: store, now: () => now);
      addTearDown(cache.close);
      addTearDown(() {
        if (!retainGate.isCompleted) {
          retainGate.complete();
        }
      });
      await cache.getOrLoadEncodedImage(
        key: key,
        loader: () async => Uint8List.fromList(<int>[1, 2, 3]),
      );
      store.values.clear();
      store.retentions.clear();

      final promoted = await cache.getEncodedImageIfPresent(
        key,
        retention: ResourceCacheRetention.retained,
      ).timeout(const Duration(seconds: 1));
      expect((promoted as MemoryEncodedResourceSource).bytes, <int>[1, 2, 3]);
      await retainStarted.future;

      if (revocation == 'invalidate') {
        cache.invalidate(key);
      } else if (revocation == 'clear') {
        cache.clear();
      } else if (revocation == 'refresh' || revocation == 'transient-refresh') {
        await cache.getOrLoadEncodedImage(
          key: key,
          forceRefresh: true,
          awaitPersistence: false,
          retention: revocation == 'refresh'
              ? ResourceCacheRetention.retained
              : ResourceCacheRetention.transient,
          loader: () async => Uint8List.fromList(<int>[9]),
        );
      } else if (revocation == 'expire') {
        now = now.add(const Duration(days: 8));
      } else {
        cache.trimTo(targetWeight: 0);
      }
      retainGate.complete();
      await cache.drainPersistence();

      if (revocation == 'refresh' || revocation == 'transient-refresh') {
        expect(store.writes, 2);
        expect(store.values[key]!.bytes, <int>[9]);
        expect(store.retentions[key], revocation == 'refresh'
            ? ResourceCacheRetention.retained
            : ResourceCacheRetention.transient);
      } else if (revocation == 'memory-trim') {
        expect(store.writes, 2);
        expect(store.values[key]!.bytes, <int>[1, 2, 3]);
        expect(store.retentions[key], ResourceCacheRetention.retained);
      } else {
        expect(store.writes, 1);
        expect(store.values, isEmpty);
      }
    });
  }
}

final class _MemoryResourceByteStore
    implements ResourceCacheByteStore, ResourceCacheByteStoreMaintenance {
  _MemoryResourceByteStore({
    this.writeStarted,
    this.writeGate,
    this.retainStarted,
    this.retainGate,
  });

  final Completer<void>? writeStarted;
  final Completer<void>? writeGate;
  final Completer<void>? retainStarted;
  final Completer<void>? retainGate;
  int writes = 0;
  final Map<ResourceCacheKey, PersistedResourceBytes> values =
      <ResourceCacheKey, PersistedResourceBytes>{};
  final Map<ResourceCacheKey, ResourceCacheRetention> retentions =
      <ResourceCacheKey, ResourceCacheRetention>{};

  @override
  Future<PersistedResourceBytes?> read(ResourceCacheKey key) async =>
      values[key];

  @override
  Future<void> write({
    required ResourceCacheKey key,
    required Uint8List bytes,
    required DateTime? expiresAt,
    ResourceCacheRetention retention = ResourceCacheRetention.transient,
  }) async {
    writes++;
    if (writeStarted != null && !writeStarted!.isCompleted) {
      writeStarted!.complete();
    }
    if (writeGate != null) {
      await writeGate!.future;
    }
    retentions[key] = retention;
    values[key] = PersistedResourceBytes(
      bytes: Uint8List.fromList(bytes),
      expiresAt: retention == ResourceCacheRetention.retained
          ? null
          : expiresAt,
    );
  }

  @override
  Future<bool> retain(ResourceCacheKey key) async {
    if (retainStarted != null && !retainStarted!.isCompleted) {
      retainStarted!.complete();
    }
    if (retainGate != null) {
      await retainGate!.future;
    }
    final value = values[key];
    if (value == null) {
      return false;
    }
    retentions[key] = ResourceCacheRetention.retained;
    values[key] = PersistedResourceBytes(bytes: value.bytes, expiresAt: null);
    return true;
  }

  @override
  Future<void> remove(ResourceCacheKey key) async {
    values.remove(key);
    retentions.remove(key);
  }

  @override
  Future<void> removeWhere(
    bool Function(ResourceCacheKey key) predicate,
  ) async {
    final removed = values.keys.where(predicate).toList(growable: false);
    values.removeWhere((key, value) => predicate(key));
    for (final key in removed) {
      retentions.remove(key);
    }
  }

  @override
  Future<void> clear() async {
    values.clear();
    retentions.clear();
  }

  @override
  Future<ResourceCacheByteStoreUsage> inspect() async =>
      ResourceCacheByteStoreUsage(
        bytes: values.values.fold<int>(
          0,
          (sum, value) => sum + value.bytes.lengthInBytes,
        ),
        entries: values.length,
        retainedBytes: values.entries
            .where(
              (entry) =>
                  retentions[entry.key] == ResourceCacheRetention.retained,
            )
            .fold<int>(
              0,
              (sum, entry) => sum + entry.value.bytes.lengthInBytes,
            ),
        retainedEntries: retentions.values
            .where((retention) => retention == ResourceCacheRetention.retained)
            .length,
      );

  @override
  Future<ResourceCacheByteStoreTrimReport> trimTo({
    required int targetBytes,
  }) async {
    final transientKeys = values.keys
        .where((key) => retentions[key] != ResourceCacheRetention.retained)
        .toList(growable: false);
    final before = transientKeys.fold<int>(
      0,
      (sum, key) => sum + values[key]!.bytes.lengthInBytes,
    );
    var remaining = before;
    var evicted = 0;
    for (final key in transientKeys) {
      if (remaining <= targetBytes) {
        break;
      }
      remaining -= values.remove(key)!.bytes.lengthInBytes;
      retentions.remove(key);
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

final class _FakePresentationRasterMaintenance
    implements PresentationRasterCacheMaintenance {
  int trimCalls = 0;
  int clearCalls = 0;
  int bytes = 40;
  int entries = 2;

  @override
  PresentationRasterCacheUsage inspectPresentationRasters() =>
      PresentationRasterCacheUsage(bytes: bytes, entries: entries);

  @override
  PresentationRasterCacheReport trimPresentationRasters() {
    trimCalls++;
    final beforeBytes = bytes;
    final beforeEntries = entries;
    bytes = 30;
    entries = 1;
    return PresentationRasterCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes - bytes,
      remainingBytes: bytes,
      evictedEntries: beforeEntries - entries,
    );
  }

  @override
  PresentationRasterCacheReport clearPresentationRasters() {
    clearCalls++;
    final beforeBytes = bytes;
    final beforeEntries = entries;
    bytes = 0;
    entries = 0;
    return PresentationRasterCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes,
      remainingBytes: 0,
      evictedEntries: beforeEntries,
    );
  }
}

final class _FakeArtifactMaintenance
    implements ArtifactCacheMaintenance, AutomaticArtifactCacheMaintenance {
  int clearCalls = 0;
  int trimCalls = 0;
  ({int maxBytes, int targetBytes})? lastTrim;
  ({int maxBytes, int targetBytes})? lastAutomaticLimits;

  @override
  void configureAutomaticCacheMaintenance({required int maxBytes, required int targetBytes}) {
    lastAutomaticLimits = (maxBytes: maxBytes, targetBytes: targetBytes);
  }

  @override
  Future<ArtifactCacheUsage> inspectArtifacts() async =>
      const ArtifactCacheUsage(bytes: 12, entries: 2);

  @override
  Future<ArtifactCacheReport> trimArtifacts({
    required int maxBytes,
    required int targetBytes,
  }) async {
    trimCalls++;
    lastTrim = (maxBytes: maxBytes, targetBytes: targetBytes);
    return const ArtifactCacheReport(
      beforeBytes: 12,
      releasedBytes: 4,
      remainingBytes: 8,
      evictedEntries: 1,
      skippedBusy: 0,
    );
  }

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
