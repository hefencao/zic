import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('commits bytes only after the session promotes its artifact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    expect(backend.values, isEmpty);
    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(session.state, DownloadState.promoted);
    expect(backend.values[id], bytes);
  });

  test('transfer staging still materializes the promoted durable artifact',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-transfer-staging-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'staging-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('memory://transfer-staging-page'),
    );
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u0000staging',
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);

    final original = CacheLayout('${directory.path}/ephemeral')
        .artifactForPhysical(physical);
    final session = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: original,
      clock: SystemClock(),
      initiallyDemanded: false,
    );
    await session.restore();
    handoff.observe(session);
    addTearDown(() async {
      handoff.detach();
      if (session.state != DownloadState.disposed) await session.dispose();
    });

    final staging = CacheLayout('${directory.path}/staging')
        .artifactForPhysical(physical);
    await staging.restore();
    final bytes = Uint8List.fromList(
      <int>[...'RIFF....WEBP'.codeUnits, ...List<int>.filled(128, 7)],
    );
    await staging.append(0, bytes);
    await staging.pause();
    await staging.dispose();
    final adopted = CacheLayout('${directory.path}/staging')
        .artifactForPhysical(physical);

    await session.adoptDurablePartialBacking(
      artifact: adopted,
      index: index,
      storageRootId: '${directory.path}/staging',
      expectedLength: bytes.lengthInBytes,
      validators: const Validators(etag: 'staging-v1'),
      totalLength: bytes.lengthInBytes,
      releaseBacking: () {},
      transferStaging: true,
    );
    expect(session.hasBorrowedDurableSpool, isFalse);

    final writer = session.acquireWriter();
    await session.seal(writer, expectedLength: bytes.lengthInBytes);
    await session.promote();
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.values[id], bytes,
        reason: 'staging cannot use the adopted-durable zero-copy skip');
    expect(backend.physicalSources[physical], id);
    expect(
      trace.events.any(
        (event) => event.payload['action'] == 'skip-adopted-durable',
      ),
      isFalse,
    );
  });

  test('canonical physical media is bound automatically after promotion',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-physical-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'version-a',
        chapterId: 'chapter-a',
        pageId: 'page-a',
      ),
      sourceRevision: 'revision-a',
      canonicalUri: Uri.parse('memory://physical-promoted-page'),
    );
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u00005',
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    registry.bindPhysicalMedia(id: id, physicalId: physical);
    final session = registry.get(id);
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      id.canonicalUri: LoaderTransportSource(
        revision: 'fixture-a',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.values[id], bytes);
    expect(backend.physicalSources[physical], id);
    expect((await cache.openPhysicalArtifact(physical))?.length, bytes.length);
  });

  test(
    'automatic handoff keeps matching canonical physical durable body without exact copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zic-promoted-cache-physical-seal-',
      );
      addTearDown(() => directory.delete(recursive: true));
      DownloadId idFor(String version) => DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'version-$version',
          chapterId: 'chapter-$version',
          pageId: 'page-$version',
        ),
        sourceRevision: 'revision-$version',
        canonicalUri: Uri.parse('memory://physical-seal-$version'),
      );
      final incumbent = idFor('old');
      final target = idFor('new');
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000011',
      );
      final bytes = Uint8List.fromList(<int>[1, 4, 1, 4, 2, 1, 3, 5]);
      final backend = _RecordingArtifactStore()
        ..values[incumbent] = Uint8List.fromList(bytes)
        ..physicalSources[physical] = incumbent;
      final cache = ArtifactCacheManager(backend: backend);
      final trace = MemoryTraceSink();
      final handoff = PromotedArtifactCacheHandoff(
        cache: cache,
        clock: const SystemClock(),
        traceSink: trace,
      );
      final registry = DownloadRegistry(
        layout: CacheLayout(directory.path),
        clock: const SystemClock(),
        onSessionCreated: handoff.observe,
      );
      addTearDown(() async {
        handoff.detach();
        await registry.dispose();
      });
      registry.bindPhysicalMedia(id: target, physicalId: physical);
      final session = registry.get(target);
      final transport = LoaderTransport(<Uri, LoaderTransportSource>{
        target.canonicalUri: LoaderTransportSource(
          revision: 'fixture-new',
          loadBytes: () async => bytes,
        ),
      });

      await DownloadJob(transport: transport, session: session).run();
      await handoff.drain(<DownloadSession>[session]);

      expect(backend.values[target], isNull,
          reason: 'automatic Reader cache must keep the existing physical body');
      expect(backend.physicalSources[physical], incumbent);
      expect(
        trace.events.any(
          (event) => event.payload['action'] == 'skip-existing-physical-seal',
        ),
        isTrue,
      );

      await handoff.persist(session);
      expect(backend.values[target], bytes,
          reason: 'explicit exact durability still materializes the target');
    },
  );

  test(
    'persistent canonical body skips automatic copy and survives dirty reopen',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'zic-promoted-persistent-physical-seal-',
      );
      final hotRoot = await Directory.systemTemp.createTemp(
        'zic-promoted-persistent-hot-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await hotRoot.exists()) await hotRoot.delete(recursive: true);
      });
      DownloadId idFor(String version) => DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'version-$version',
          chapterId: 'chapter-$version',
          pageId: 'page-$version',
        ),
        sourceRevision: 'revision-$version',
        canonicalUri: Uri.parse('memory://persistent-physical-seal-$version'),
      );
      final incumbent = idFor('old');
      final target = idFor('new');
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000012',
      );
      final bytes = Uint8List.fromList(
        <int>[...'RIFF....WEBP'.codeUnits, ...List<int>.filled(96, 7)],
      );

      final store = await PersistentDownloadArtifactStore.open(root.path);
      final cache = ArtifactCacheManager(backend: store);
      await cache.storePromotedArtifact(id: incumbent, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifactFromCandidates(
          physicalId: physical,
          candidates: <DownloadId>[incumbent],
        ),
        isTrue,
      );

      final trace = MemoryTraceSink();
      final handoff = PromotedArtifactCacheHandoff(
        cache: cache,
        clock: const SystemClock(),
        traceSink: trace,
      );
      final session = DownloadSession(
        id: target,
        physicalId: physical,
        artifact: CacheLayout(hotRoot.path).artifactForPhysical(physical),
        clock: const SystemClock(),
        initiallyDemanded: false,
      );
      handoff.observe(session);
      final transport = LoaderTransport(<Uri, LoaderTransportSource>{
        target.canonicalUri: LoaderTransportSource(
          revision: 'fixture-new',
          loadBytes: () async => bytes,
        ),
      });

      await DownloadJob(transport: transport, session: session).run();
      await handoff.drain(<DownloadSession>[session]);

      expect(await store.openArtifactStream(target), isNull,
          reason: 'automatic Reader caching must not create an exact body copy');
      expect(
        trace.events.any(
          (event) => event.payload['action'] == 'skip-existing-physical-seal',
        ),
        isTrue,
      );

      await handoff.persist(session);
      final exact = await store.openArtifactStream(target);
      expect(exact, isNotNull,
          reason: 'explicit persistence still creates an exact durable binding');
      expect(exact!.length, bytes.lengthInBytes);

      handoff.detach();
      await session.dispose();
      await store.close();

      final layout = CacheLayout(defaultChapterDownloadDirectory(root.path));
      final marker = File(
        '${layout.root}${Platform.pathSeparator}.zic-cache-recovery-required',
      );
      await marker.writeAsString('stale-process-owner', flush: true);
      final reopened = await PersistentDownloadArtifactStore.open(root.path);
      final physicalAfterRestart = await reopened.openPhysicalArtifact(physical);
      expect(physicalAfterRestart, isNotNull);
      expect(physicalAfterRestart!.length, bytes.lengthInBytes);
      expect(await reopened.readPromoted(target), bytes);
      await reopened.close();
    },
  );

  test('canonical bind conflict falls back to exact once per promoted epoch',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-physical-conflict-',
    );
    addTearDown(() => directory.delete(recursive: true));
    DownloadId idFor(String version) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'version-$version',
        chapterId: 'chapter-$version',
        pageId: 'page-$version',
      ),
      sourceRevision: 'revision-$version',
      canonicalUri: Uri.parse('memory://physical-conflict-$version'),
    );
    final incumbent = idFor('old');
    final target = idFor('new');
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u00009',
    );
    final incumbentBytes = Uint8List.fromList(<int>[1, 1, 2, 3]);
    final targetBytes = Uint8List.fromList(<int>[5, 8, 13, 21]);
    final backend = _RecordingArtifactStore()
      ..values[incumbent] = incumbentBytes
      ..physicalSources[physical] = incumbent;
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: const SystemClock(),
      traceSink: trace,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: const SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    registry.bindPhysicalMedia(id: target, physicalId: physical);
    final session = registry.get(target);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      target.canonicalUri: LoaderTransportSource(
        revision: 'fixture-new',
        loadBytes: () async => targetBytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.values[target], targetBytes);
    expect(backend.physicalSources[physical], incumbent);
    expect(backend.physicalBindCalls, 1);
    expect(await handoff.settleAutomatic(session), isTrue);
    expect(backend.physicalBindCalls, 1,
        reason: 'one canonical conflict must not resubmit the same epoch');
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['action'] ==
                'canonical-bind-unavailable-exact-fallback' &&
            event.payload['physicalMediaKey'] == physical.key,
      ),
      isTrue,
    );
  });

  test('a new physical epoch receives a fresh automatic handoff', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-epoch-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://promoted-page-epoch');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'epoch-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    var bytes = Uint8List.fromList(<int>[3, 1, 4, 1, 5]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);
    expect(backend.values[id], bytes);

    await session.evict();
    backend.values.clear();
    bytes = Uint8List.fromList(<int>[9, 2, 6, 5, 3]);

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);
    expect(session.state, DownloadState.promoted);
    expect(backend.values[id], bytes);
  });

  test('memory-only hit still writes through to the backend', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-memory-only-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://memory-only-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'memory-only-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final bytes = Uint8List.fromList(<int>[1, 6, 1, 8]);
    cache.remember(id: id, bytes: bytes);
    final handoff = PromotedArtifactCacheHandoff(cache: cache);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(backend.values[id], bytes);
  });

  test('source-resident promotion defers durable materialization until required',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-resident-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://resident-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'resident-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
      residentReplaySource: (session, endExclusive) async =>
          Stream<List<int>>.value(bytes.sublist(0, endExclusive)),
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);

    await DownloadJob(
      transport: _ResidentTransport(bytes),
      session: session,
    ).run();
    await handoff.drain(registry.sessions);

    expect(session.residentBodyBacked, isTrue);
    expect(session.residentSource, 'reopenable-immutable-source');
    expect(session.artifact.committedLength, 0);
    expect(backend.values, isEmpty);
    expect(
      trace.events.any(
        (event) => event.payload['action'] == 'defer-resident-source',
      ),
      isTrue,
    );

    await handoff.persist(session);
    expect(backend.values[id], bytes);
    expect(
      trace.events.any(
        (event) => event.payload['action'] == 'stored-resident-source',
      ),
      isTrue,
    );
  });

  test('does not repopulate an exact cache entry invalidated during replay',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-invalidation-race-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://resident-invalidation-race');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'invalidation-race-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final replayStarted = Completer<void>();
    final releaseReplay = Completer<void>();
    final backend = _RecordingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      residentReplaySource: (session, endExclusive) async {
        replayStarted.complete();
        await releaseReplay.future;
        return Stream<List<int>>.value(bytes.sublist(0, endExclusive));
      },
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      if (!releaseReplay.isCompleted) releaseReplay.complete();
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);

    await DownloadJob(
      transport: _ResidentTransport(bytes),
      session: session,
    ).run();
    await handoff.settleAutomatic(session);

    final persist = handoff.persist(session);
    await replayStarted.future;
    await cache.invalidate(id);
    releaseReplay.complete();
    await persist;

    expect(backend.values, isEmpty);
  });

  test('skips materializing a session artifact already present durably',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-existing-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://existing-promoted-page');
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'existing-page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );
    final backend = _ExistingArtifactStore();
    final cache = ArtifactCacheManager(backend: backend);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
      sessionId: 'reader-existing',
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(id);
    final bytes = Uint8List.fromList(<int>[2, 7, 1, 8, 2, 8]);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      uri: LoaderTransportSource(
        revision: 'fixture-r1',
        loadBytes: () async => bytes,
      ),
    });

    backend.existing = Uint8List(bytes.lengthInBytes);
    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(<DownloadSession>[session]);
    await handoff.drain(<DownloadSession>[session]);

    expect(backend.storeCalls, 0);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['action'] == 'skip-existing',
      ),
      hasLength(1),
    );
    final event = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['action'] == 'skip-existing',
    );
    expect(event.payload['bytes'], bytes.lengthInBytes);
  });
  test('verified equivalent durable artifact avoids Reader-side exact copy',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-cache-handoff-equivalent-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'old-comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('memory://old-equivalent-page'),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'new-comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('memory://new-equivalent-page'),
    );
    final bytes = Uint8List.fromList(<int>[8, 6, 7, 5, 3, 0, 9]);
    final backend = _RecordingArtifactStore()
      ..values[oldId] = Uint8List.fromList(bytes);
    final cache = ArtifactCacheManager(backend: backend)
      ..linkEquivalent(first: oldId, second: newId);
    final trace = MemoryTraceSink();
    final handoff = PromotedArtifactCacheHandoff(
      cache: cache,
      clock: SystemClock(),
      traceSink: trace,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: handoff.observe,
    );
    addTearDown(() async {
      handoff.detach();
      await registry.dispose();
    });
    final session = registry.get(newId);
    final transport = LoaderTransport(<Uri, LoaderTransportSource>{
      newId.canonicalUri: LoaderTransportSource(
        revision: 'fixture-new',
        loadBytes: () async => bytes,
      ),
    });

    await DownloadJob(transport: transport, session: session).run();
    await handoff.drain(registry.sessions);

    expect(backend.values[newId], isNull);
    expect((await cache.readForeground(newId))?.bytes, bytes);
    expect(
      trace.events.any(
        (event) =>
            event.payload['action'] == 'skip-verified-equivalent-durable',
      ),
      isTrue,
    );

    await handoff.persist(session);
    expect(backend.values[newId], bytes);
  });

}

final class _RecordingArtifactStore
    implements ArtifactCacheBackend, PhysicalArtifactCacheBackend {
  final Map<DownloadId, Uint8List> values = <DownloadId, Uint8List>{};
  final Map<PhysicalMediaId, DownloadId> physicalSources =
      <PhysicalMediaId, DownloadId>{};
  int physicalBindCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = values[id];
    if (bytes == null) return null;
    return _entry(bytes);
  }


  @override
  Future<ArtifactCacheStreamEntry?> openPhysicalArtifact(
    PhysicalMediaId id,
  ) async {
    final source = physicalSources[id];
    if (source == null) return null;
    final bytes = values[source];
    return bytes == null ? null : _entry(bytes, sealed: true);
  }

  @override
  Future<bool> bindPhysicalArtifact({
    required PhysicalMediaId physicalId,
    required DownloadId sourceId,
  }) async {
    physicalBindCalls++;
    if (!values.containsKey(sourceId)) return false;
    final existing = physicalSources[physicalId];
    if (existing != null) return existing == sourceId;
    physicalSources[physicalId] = sourceId;
    return true;
  }

  @override
  Future<void> invalidatePhysicalArtifact(PhysicalMediaId id) async {
    physicalSources.remove(id);
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    values.remove(id);
  }
}

final class _ExistingArtifactStore implements ArtifactCacheBackend {
  Uint8List? existing;
  int storeCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = existing;
    return bytes == null ? null : _entry(bytes);
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    storeCalls++;
    existing = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    existing = null;
  }
}

ArtifactCacheStreamEntry _entry(Uint8List bytes, {bool sealed = false}) {
  final crc = Crc32();
  if (sealed) crc.add(bytes);
  return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
      },
      readAll: () async => bytes,
      sealedChecksum: sealed ? crc.hex : null,
      sealedChecksumAlgorithm: sealed ? 'crc32' : null,
    );
}


final class _ResidentTransport implements Transport {
  const _ResidentTransport(this.bytes);

  final Uint8List bytes;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.value(bytes),
        statusCode: 200,
        rangeStart: 0,
        totalLength: bytes.lengthInBytes,
        disposition: ByteResponseDisposition.durableImmutable,
      );
}
