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
  test('persistent POSIX partial is adopted as the active spool without copying',
      () async {
    final durableRoot =
        await Directory.systemTemp.createTemp('partial-adopt-durable-');
    final hotRoot = await Directory.systemTemp.createTemp('partial-adopt-hot-');
    addTearDown(() async {
      await durableRoot.delete(recursive: true);
      await hotRoot.delete(recursive: true);
    });
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'adopt',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/adopt.webp'),
    );
    final bytes = Uint8List.fromList(
      List<int>.generate(8192, (index) => index & 0xff),
    );
    final store = await PersistentDownloadArtifactStore.open(durableRoot.path);
    final hot = DownloadRegistry(
      layout: CacheLayout(hotRoot.path),
      clock: SystemClock(),
    );
    addTearDown(() async {
      await hot.dispose();
      await store.close();
    });
    await store.storePartialDownload(
      id: id,
      entry: PartialDownloadEntry(
        length: bytes.lengthInBytes,
        validators: const Validators(etag: 'adopt-etag'),
        totalLength: bytes.lengthInBytes + 4096,
        open: ({required int start}) =>
            Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
      ),
    );
    final record = await store.index.get(id.key);
    expect(record, isNotNull);
    final durablePath = record!.path;
    expect(
      durablePath,
      contains('${Platform.pathSeparator}partial${Platform.pathSeparator}'),
    );

    final session = hot.get(id);
    await PartialDownloadHandoff(store: store).restoreInto(session);

    expect(session.committedLength, bytes.lengthInBytes);
    expect(session.validators.etag, 'adopt-etag');
    expect(session.totalLength, bytes.lengthInBytes + 4096);
    expect(
      session.artifact.partialPath,
      durablePath,
      reason: 'the physical session must append the durable spool itself',
    );
    expect(await session.artifact.readBytes(), bytes);

    final whileBorrowed = await store.clearArtifacts();
    expect(whileBorrowed.evictedEntries, 0);
    expect(whileBorrowed.skippedBusy, 1);
    expect(await store.index.get(id.key), isNotNull);
    expect(await File(durablePath).exists(), isTrue);

    final backend = _CountingArtifactBackend(store);
    final cache = ArtifactCacheManager(backend: backend);
    final promoted = PromotedArtifactCacheHandoff(cache: cache)..observe(session);
    final suffix = Uint8List.fromList(
      List<int>.generate(4096, (index) => (index + 17) & 0xff),
    );
    final writer = session.acquireWriter();
    await session.append(writer, bytes.lengthInBytes, suffix);
    await session.seal(
      writer,
      expectedLength: bytes.lengthInBytes + suffix.lengthInBytes,
    );
    await session.promote();
    expect(await promoted.settleAutomatic(session), isTrue);
    expect(
      backend.storeCalls,
      0,
      reason: 'adopted durable final must not be copied back into its backend',
    );
    final ready = await store.index.get(id.key);
    expect(ready?.state, CacheState.ready);
    expect(ready?.path, session.artifact.finalPath);

    await hot.dispose();
    final afterRelease = await store.clearArtifacts();
    expect(afterRelease.evictedEntries, 1);
    expect(afterRelease.skippedBusy, 0);
    expect(await store.index.get(id.key), isNull);
  });

  test(
    'canonical physical artifact restores before exact or equivalent carrier lookup',
    () async {
      final durableRoot = await Directory.systemTemp.createTemp(
        'physical-ready-durable-',
      );
      final hotRoot = await Directory.systemTemp.createTemp(
        'physical-ready-hot-',
      );
      addTearDown(() async {
        await durableRoot.delete(recursive: true);
        await hotRoot.delete(recursive: true);
      });
      DownloadId idFor(String version) => DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'comic-$version',
          chapterId: 'chapter-$version',
          pageId: 'page-$version',
        ),
        sourceRevision: 'revision-$version',
        canonicalUri: Uri.parse('https://example.test/$version.webp'),
      );
      final first = idFor('a');
      final second = idFor('b');
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000019',
      );
      final bytes = Uint8List.fromList(<int>[
        0x52,
        0x49,
        0x46,
        0x46,
        0x08,
        0x00,
        0x00,
        0x00,
        0x57,
        0x45,
        0x42,
        0x50,
        0x56,
        0x50,
        0x38,
        0x20,
      ]);
      final store = await PersistentDownloadArtifactStore.open(
        durableRoot.path,
      );
      final cache = ArtifactCacheManager(backend: store);
      final hot = DownloadRegistry(
        layout: CacheLayout(hotRoot.path),
        clock: SystemClock(),
      );
      addTearDown(() async {
        await hot.dispose();
        await store.close();
      });
      await cache.storePromotedArtifact(id: first, bytes: bytes);
      expect(
        await cache.bindPhysicalArtifact(physicalId: physical, sourceId: first),
        isTrue,
      );
      await store.index.remove(first.key);
      hot.bindPhysicalMedia(id: second, physicalId: physical);
      final session = hot.get(second);
      var candidateLookups = 0;
      final handoff = PartialDownloadHandoff(
        store: store,
        physicalArtifactCache: cache,
        equivalentCandidates: (_) {
          candidateLookups++;
          return <DownloadId>[first];
        },
      );

      await handoff.restoreInto(session);

      expect(session.state, DownloadState.promoted);
      expect(session.residentBodyBacked, isTrue);
      expect(session.physicalId, physical);
      expect(session.id, second);
      expect(session.committedLength, bytes.lengthInBytes);
      expect(candidateLookups, 0);
    },
  );

  test(
    'canonical physical restore backfills a historical provider URI through a verified direct candidate',
    () async {
      final durableRoot = await Directory.systemTemp.createTemp(
        'physical-uri-backfill-durable-',
      );
      final hotRoot = await Directory.systemTemp.createTemp(
        'physical-uri-backfill-hot-',
      );
      addTearDown(() async {
        await durableRoot.delete(recursive: true);
        await hotRoot.delete(recursive: true);
      });
      final oldContent = ContentId(
        sourceId: 'source',
        comicId: 'old-comic',
        chapterId: 'old-chapter',
        pageId: 'old-page-311',
      );
      final historicalOld = DownloadId(
        content: oldContent,
        sourceRevision: 'single',
        canonicalUri: Uri.parse('venera-resource:expired-old-uri'),
      );
      final currentOldCandidate = DownloadId(
        content: oldContent,
        sourceRevision: 'single',
        canonicalUri: Uri.parse('venera-resource:current-old-uri'),
        pageIndexHint: 311,
      );
      final currentNew = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'new-comic',
          chapterId: 'new-chapter',
          pageId: 'new-page-368',
        ),
        sourceRevision: 'single',
        canonicalUri: Uri.parse('venera-resource:current-new-uri'),
        pageIndexHint: 368,
      );
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u0000311',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(513, (index) => (index * 17) & 0xff),
      );
      final store = await PersistentDownloadArtifactStore.open(
        durableRoot.path,
      );
      final cache = ArtifactCacheManager(backend: store);
      final hot = DownloadRegistry(
        layout: CacheLayout(hotRoot.path),
        clock: SystemClock(),
      );
      addTearDown(() async {
        await hot.dispose();
        await store.close();
      });

      // The durable body predates both the current provider URI and the
      // canonical physical-media index. No exact current binding exists.
      await cache.storePromotedArtifact(id: historicalOld, bytes: bytes);
      expect(await cache.lookupAuthoritative(currentOldCandidate), isNull);
      expect(await cache.openPhysicalArtifact(physical), isNull);

      cache.registerEquivalentResolver(
        key: 'verified-direct-version-page',
        resolver: (id) sync* {
          if (id == currentNew && id.pageIndexHint == 368) {
            yield currentOldCandidate;
          }
        },
      );
      hot.bindPhysicalMedia(id: currentNew, physicalId: physical);
      final session = hot.get(currentNew);
      expect(session.id.pageIndexHint, 368);
      final handoff = PartialDownloadHandoff(
        store: store,
        physicalArtifactCache: cache,
        equivalentCandidates: cache.directEquivalents,
      );

      await handoff.restoreInto(session);

      expect(session.state, DownloadState.promoted);
      expect(session.residentBodyBacked, isTrue);
      expect(session.committedLength, bytes.lengthInBytes);
      expect(await cache.lookupAuthoritative(currentOldCandidate), isNull);
      expect(
        (await cache.openPhysicalArtifact(physical))?.length,
        bytes.lengthInBytes,
      );
    },
  );

  test(
    'physical partial keeps total length but drops provider validators across versions',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'physical-partial-provider-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      DownloadId idFor(String version) => DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'comic-$version',
          chapterId: 'chapter-$version',
          pageId: 'page-$version',
        ),
        sourceRevision: 'revision-$version',
        canonicalUri: Uri.parse('https://example.test/$version.webp'),
      );
      final first = idFor('a');
      final second = idFor('b');
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000023',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(257, (index) => index & 0xff),
      );

      await store.storePhysicalPartialDownload(
        physicalId: physical,
        providerHint: first,
        entry: PartialDownloadEntry(
          length: bytes.lengthInBytes,
          validators: const Validators(etag: 'provider-a'),
          totalLength: 1024,
          open: ({required int start}) =>
              Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
        ),
      );
      final initial = await store.index.list(state: CacheState.partial);
      expect(
        initial,
        isEmpty,
        reason: 'physical partial must not create exact rows',
      );
      final firstOpen = await store.openPhysicalPartialDownload(
        physicalId: physical,
        requestId: first,
      );
      expect(firstOpen, isNotNull);
      expect(firstOpen!.validators.etag, 'provider-a');
      expect(firstOpen.totalLength, 1024);
      final physicalRecord = (store.index as PhysicalPartialIndex);
      final before = await physicalRecord.getPhysicalPartial(physical);
      expect(before, isNotNull);

      final secondOpen = await store.openPhysicalPartialDownload(
        physicalId: physical,
        requestId: second,
      );
      expect(secondOpen, isNotNull);
      expect(secondOpen!.validators.isEmpty, isTrue);
      expect(secondOpen.totalLength, 1024);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in secondOpen.open(start: 0)) {
        builder.add(chunk);
      }
      expect(builder.takeBytes(), bytes);
      final after = await physicalRecord.getPhysicalPartial(physical);
      expect(after?.path, before?.path);
      expect(after?.id, physical);
    },
  );

  test(
    'physical partial keeps total length but drops provider validators across versions',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'physical-partial-provider-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = await PersistentDownloadArtifactStore.open(root.path);
      addTearDown(store.close);
      DownloadId idFor(String version) => DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'comic-$version',
          chapterId: 'chapter-$version',
          pageId: 'page-$version',
        ),
        sourceRevision: 'revision-$version',
        canonicalUri: Uri.parse('https://example.test/$version.webp'),
      );
      final first = idFor('a');
      final second = idFor('b');
      final physical = PhysicalMediaId.canonical(
        'family\u0000chapter\u0000segment\u000023',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(257, (index) => index & 0xff),
      );

      await store.storePhysicalPartialDownload(
        physicalId: physical,
        providerHint: first,
        entry: PartialDownloadEntry(
          length: bytes.lengthInBytes,
          validators: const Validators(etag: 'provider-a'),
          totalLength: 1024,
          open: ({required int start}) =>
              Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
        ),
      );
      final initial = await store.index.list(state: CacheState.partial);
      expect(
        initial,
        isEmpty,
        reason: 'physical partial must not create exact rows',
      );
      final firstOpen = await store.openPhysicalPartialDownload(
        physicalId: physical,
        requestId: first,
      );
      expect(firstOpen, isNotNull);
      expect(firstOpen!.validators.etag, 'provider-a');
      expect(firstOpen.totalLength, 1024);
      final physicalRecord = (store.index as PhysicalPartialIndex);
      final before = await physicalRecord.getPhysicalPartial(physical);
      expect(before, isNotNull);

      final secondOpen = await store.openPhysicalPartialDownload(
        physicalId: physical,
        requestId: second,
      );
      expect(secondOpen, isNotNull);
      expect(secondOpen!.validators.isEmpty, isTrue);
      expect(secondOpen.totalLength, 1024);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in secondOpen.open(start: 0)) {
        builder.add(chunk);
      }
      expect(builder.takeBytes(), bytes);
      final after = await physicalRecord.getPhysicalPartial(physical);
      expect(after?.path, before?.path);
      expect(after?.id, physical);
    },
  );

  test('partial survives Reader-session workspace replacement without promotion',
      () async {
    final firstRoot = await Directory.systemTemp.createTemp('partial-source-');
    final secondRoot = await Directory.systemTemp.createTemp('partial-target-');
    addTearDown(() async {
      await firstRoot.delete(recursive: true);
      await secondRoot.delete(recursive: true);
    });
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
    final backend = _PartialStore();
    final handoff = PartialDownloadHandoff(store: backend);
    final first = DownloadRegistry(
      layout: CacheLayout(firstRoot.path),
      clock: SystemClock(),
    );
    final target = DownloadRegistry(
      layout: CacheLayout(secondRoot.path),
      clock: SystemClock(),
    );
    addTearDown(() async {
      await first.dispose();
      await target.dispose();
    });

    final source = first.get(id);
    await source.restore();
    await source.bindResponse(
      validators: const Validators(etag: 'reader-etag'),
      totalLength: 1024,
    );
    final writer = source.acquireWriter();
    final bytes = Uint8List.fromList(List<int>.generate(320, (i) => i & 0xff));
    await source.append(writer, 0, bytes);
    await source.pause(writer);

    await handoff.drain(<DownloadSession>[source]);
    expect(backend.partial[id]?.bytes, bytes);

    final restored = target.get(id);
    await handoff.restoreInto(restored);
    expect(restored.state, DownloadState.idle);
    expect(restored.committedLength, bytes.lengthInBytes);
    expect(restored.validators.etag, 'reader-etag');
    expect(restored.totalLength, 1024);
    expect(await restored.artifact.readBytes(), bytes);
  });

  test('composition transfer resumes network suffix on the adopted durable spool',
      () async {
    final durableRoot =
        await Directory.systemTemp.createTemp('partial-adopt-resume-');
    addTearDown(() async => durableRoot.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'resume',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/resume.png'),
    );
    final fullBytes = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ...List<int>.generate(56, (index) => (index + 31) & 0xff),
    ]);
    const prefixLength = 24;
    const validators = Validators(etag: 'resume-v1');
    final store = await PersistentDownloadArtifactStore.open(durableRoot.path);
    final backend = _CountingArtifactBackend(store);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: store,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      if (runtime.hasConsumers) {
        for (final consumer in runtime.owner.consumers.toList(growable: false)) {
          await consumer.dispose();
        }
      }
      await runtime.dispose();
      await store.close();
    });
    await store.storePartialDownload(
      id: id,
      entry: PartialDownloadEntry(
        length: prefixLength,
        validators: validators,
        totalLength: fullBytes.lengthInBytes,
        open: ({required int start}) => Stream<List<int>>.value(
          Uint8List.sublistView(fullBytes, start, prefixLength),
        ),
      ),
    );
    final durableRecord = await store.index.get(id.key);
    expect(durableRecord, isNotNull);
    final transport = _RangeSuffixTransport(
      fullBytes,
      validators: validators,
    );
    final consumer = runtime.attachConsumer(
      scopeId: 'zero-copy-resume',
      transportFor: (_) => transport,
      consumerTraceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'zero-copy-resume',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 1000,
          reason: 'zero-copy-resume',
          completionIntent: TransferCompletionIntent.required,
        ),
      },
    );
    await consumer.idle();

    final session = runtime.registry.findExact(id);
    expect(session, isNotNull);
    expect(session!.state, DownloadState.promoted);
    expect(session.committedLength, fullBytes.lengthInBytes);
    expect(transport.rangeStarts, <int>[prefixLength]);
    expect(transport.validatorsSeen, hasLength(1));
    expect(transport.validatorsSeen.single?.etag, 'resume-v1');
    expect(
      session.artifact.finalPath,
      CacheLayout(
        defaultChapterDownloadDirectory(durableRoot.path),
      ).artifactFor(id).finalPath,
    );
    expect(await session.artifact.readBytes(), fullBytes);
    expect(await runtime.artifactCacheHandoff!.settleAutomatic(session), isTrue);
    expect(backend.storeCalls, 0);

    final ready = await store.index.get(id.key);
    expect(ready?.state, CacheState.ready);
    expect(ready?.bytes, fullBytes.lengthInBytes);
    await consumer.dispose();
  });

  test('replacement runtime restores recoverable app-private partial before network',
      () async {
    final stableId =
        'runtime-recovery-${DateTime.now().microsecondsSinceEpoch}';
    final firstWorkspace =
        EphemeralCacheWorkspace.recoverableTransfer(stableId);
    addTearDown(firstWorkspace.dispose);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'recoverable-runtime',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/recoverable-runtime.png'),
    );
    final fullBytes = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ...List<int>.generate(504, (index) => (index * 13 + 7) & 0xff),
    ]);
    const prefixLength = 320;
    const validators = Validators(etag: 'recoverable-runtime-v1');

    final firstRegistry = DownloadRegistry(
      layout: firstWorkspace.layout,
      clock: const SystemClock(),
    );
    final firstSession = firstRegistry.get(id);
    await firstSession.restore();
    await firstSession.bindResponse(
      validators: validators,
      totalLength: fullBytes.lengthInBytes,
    );
    final writer = firstSession.acquireWriter();
    await firstSession.append(
      writer,
      0,
      Uint8List.sublistView(fullBytes, 0, prefixLength),
    );
    await firstSession.pause(writer);
    await firstRegistry.dispose();

    // A new process receives the same deterministic app-private staging root.
    // No durable PartialDownloadStore entry is involved in this recovery.
    final replacementWorkspace =
        EphemeralCacheWorkspace.recoverableTransfer(stableId);
    expect(replacementWorkspace.rootPath, firstWorkspace.rootPath);
    final partialStore = _PartialStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: partialStore,
      transferWorkspace: replacementWorkspace,
      net: NetLane(maxActive: 1),
    );
    final transport = _RangeSuffixTransport(
      fullBytes,
      validators: validators,
    );
    final consumer = runtime.attachConsumer(
      scopeId: 'recoverable-runtime',
      transportFor: (_) => transport,
      consumerTraceSink: const NoopTraceSink(),
    );
    addTearDown(() async {
      await consumer.dispose();
      await runtime.dispose();
    });

    consumer.replaceDemands(
      'recoverable-runtime',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 1000,
          reason: 'recoverable-runtime',
          completionIntent: TransferCompletionIntent.required,
        ),
      },
    );
    await consumer.idle();

    expect(partialStore.partial, isEmpty,
        reason: 'restart recovery must not depend on durable partial handoff');
    expect(transport.rangeStarts, <int>[prefixLength]);
    final restored = runtime.registry.findExact(id);
    expect(restored, isNotNull);
    expect(restored!.state, DownloadState.promoted);
    expect(restored.committedLength, fullBytes.lengthInBytes);
    await consumer.dispose();
  });

  test('exact durable ready restore skips the second promoted backend preflight',
      () async {
    final durableRoot =
        await Directory.systemTemp.createTemp('ready-restore-proof-');
    addTearDown(() async => durableRoot.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'ready',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/ready.webp'),
    );
    final bytes = Uint8List.fromList(<int>[
      0x52, 0x49, 0x46, 0x46, 0x08, 0, 0, 0,
      0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
    ]);
    final store = await PersistentDownloadArtifactStore.open(durableRoot.path);
    await store.storePromotedArtifact(id: id, bytes: bytes);
    final backend = _CountingArtifactBackend(store);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: store,
      net: NetLane(maxActive: 1),
    );
    final transport = _RangeSuffixTransport(
      bytes,
      validators: const Validators(),
    );
    final consumer = runtime.attachConsumer(
      scopeId: 'ready-restore-proof',
      transportFor: (_) => transport,
      consumerTraceSink: const NoopTraceSink(),
    );
    addTearDown(() async {
      await consumer.dispose();
      await runtime.dispose();
      await store.close();
    });

    consumer.replaceDemands(
      'ready-restore-proof',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 1000,
          reason: 'ready-restore-proof',
          completionIntent: TransferCompletionIntent.required,
        ),
      },
    );
    await consumer.idle();

    final session = runtime.registry.findExact(id);
    expect(session, isNotNull);
    expect(session!.state, DownloadState.promoted);
    expect(session.committedLength, bytes.lengthInBytes);
    expect(session.residentReplayAccessMode, 'direct',
        reason: 'Persistent READY binds its selected physical access capability');
    expect(transport.rangeStarts, isEmpty,
        reason: 'a complete durable body must finish locally');
    expect(backend.openCalls, 0,
        reason: 'the just-consumed exact durable body already proves handoff');
    expect(backend.storeCalls, 0);

    final replay = runtime.residentReplayRangeSource(
      priorityFor: (_) => 1000,
    );
    final replayed = <int>[];
    await for (final chunk in await replay(session, 0, bytes.lengthInBytes)) {
      replayed.addAll(chunk);
    }
    expect(replayed, orderedEquals(bytes));
    expect(backend.openCalls, 0,
        reason: 'decoder ranges must reuse the READY generation authority');
  });

  test('physical partial never persists validators from an aliased provider',
      () async {
    final root = await Directory.systemTemp.createTemp('partial-validator-scope-');
    addTearDown(() async => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'physical',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final aliasedUri = Uri.parse('https://example.test/new.webp');
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final session = registry.get(id);
    await session.restore();
    await session.bindResponse(
      validators: const Validators(etag: 'new-provider-v2'),
      validatorRequestUri: aliasedUri,
      totalLength: 1024,
    );
    final writer = session.acquireWriter();
    final bytes = Uint8List.fromList(List<int>.generate(320, (i) => i & 0xff));
    await session.append(writer, 0, bytes);
    await session.pause(writer);

    final backend = _PartialStore();
    final handoff = PartialDownloadHandoff(store: backend);
    expect(await handoff.persist(session), isTrue);

    expect(backend.partial[id]?.bytes, bytes);
    expect(backend.partial[id]?.validators.isEmpty, isTrue);
    expect(backend.partial[id]?.totalLength, 1024);
  });

  test('verified equivalent cold partial restores without copying exact entry',
      () async {
    final root = await Directory.systemTemp.createTemp('partial-equivalent-');
    addTearDown(() async => root.delete(recursive: true));
    final oldId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'old',
        chapterId: 'chapter-old',
        pageId: 'page-old',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final newId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'new',
        chapterId: 'chapter-new',
        pageId: 'page-new',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('https://example.test/new.webp'),
    );
    final bytes = Uint8List.fromList(List<int>.generate(384, (i) => i & 0xff));
    final backend = _PartialStore();
    backend.partial[oldId] = _StoredPartial(
      bytes: bytes,
      validators: const Validators(etag: 'old-version-etag'),
      totalLength: 1024,
    );
    final handoff = PartialDownloadHandoff(
      store: backend,
      equivalentCandidates: (id) => id == newId
          ? <DownloadId>[oldId]
          : const <DownloadId>[],
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(newId);
    await handoff.restoreInto(session);

    expect(session.committedLength, bytes.lengthInBytes);
    expect(session.validators.isEmpty, isTrue);
    expect(session.totalLength, 1024);
    expect(await session.artifact.readBytes(), bytes);
    expect(backend.partial.containsKey(newId), isFalse);
    expect(backend.partial.containsKey(oldId), isTrue);
  });
  test('verified equivalent partials still choose the longest prefix', () async {
    final root = await Directory.systemTemp.createTemp(
      'partial-equivalent-longest-',
    );
    addTearDown(() async => root.delete(recursive: true));
    final shortId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'short',
        chapterId: 'chapter-short',
        pageId: 'page-short',
      ),
      sourceRevision: 'short-r1',
      canonicalUri: Uri.parse('https://example.test/short.webp'),
    );
    final longId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'long',
        chapterId: 'chapter-long',
        pageId: 'page-long',
      ),
      sourceRevision: 'long-r1',
      canonicalUri: Uri.parse('https://example.test/long.webp'),
    );
    final targetId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'target',
        chapterId: 'chapter-target',
        pageId: 'page-target',
      ),
      sourceRevision: 'target-r2',
      canonicalUri: Uri.parse('https://example.test/target.webp'),
    );
    final shortBytes = Uint8List.fromList(
      List<int>.generate(128, (index) => index & 0xff),
    );
    final longBytes = Uint8List.fromList(
      List<int>.generate(384, (index) => (index + 17) & 0xff),
    );
    final backend = _PartialStore();
    backend.partial[shortId] = _StoredPartial(
      bytes: shortBytes,
      validators: const Validators(etag: 'short-etag'),
      totalLength: 1024,
    );
    backend.partial[longId] = _StoredPartial(
      bytes: longBytes,
      validators: const Validators(etag: 'long-etag'),
      totalLength: 1024,
    );
    final handoff = PartialDownloadHandoff(
      store: backend,
      equivalentCandidates: (id) => id == targetId
          ? <DownloadId>[shortId, longId]
          : const <DownloadId>[],
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final session = registry.get(targetId);

    await handoff.restoreInto(session);

    expect(session.state, DownloadState.idle);
    expect(session.committedLength, longBytes.lengthInBytes);
    expect(session.validators.isEmpty, isTrue);
    expect(session.totalLength, 1024);
    expect(await session.artifact.readBytes(), orderedEquals(longBytes));
  });

  test('metadata ranking opens only the longest verified equivalent partial',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'partial-equivalent-metadata-ranking-',
    );
    addTearDown(() async => root.delete(recursive: true));
    final targetId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'target',
        chapterId: 'chapter-target',
        pageId: 'page-target',
      ),
      sourceRevision: 'target-r2',
      canonicalUri: Uri.parse('https://example.test/target.webp'),
    );
    final candidates = <DownloadId>[
      for (var i = 0; i < 16; i++)
        DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'old-$i',
            chapterId: 'chapter-$i',
            pageId: 'page-$i',
          ),
          sourceRevision: 'old-r$i',
          canonicalUri: Uri.parse('https://example.test/old-$i.webp'),
        ),
    ];
    final backend = _MetadataPartialStore();
    for (var i = 0; i < candidates.length; i++) {
      backend.partial[candidates[i]] = _StoredPartial(
        bytes: Uint8List.fromList(
          List<int>.generate(256 + i * 32, (index) => index & 0xff),
        ),
        validators: const Validators(),
        totalLength: 4096,
      );
    }
    final handoff = PartialDownloadHandoff(
      store: backend,
      equivalentCandidates: (id) => id == targetId
          ? candidates
          : const <DownloadId>[],
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(targetId);
    await handoff.restoreInto(session);

    expect(backend.metadataRequests, candidates);
    expect(
      backend.openRequests.where((id) => id != targetId),
      <DownloadId>[candidates.last],
      reason: 'only the metadata-ranked longest equivalent should open its body',
    );
    expect(
      session.committedLength,
      backend.partial[candidates.last]!.bytes.lengthInBytes,
    );
  });

  test('metadata ranking falls back when selected partial changes', () async {
    final root = await Directory.systemTemp.createTemp(
      'partial-equivalent-metadata-stale-',
    );
    addTearDown(() async => root.delete(recursive: true));
    final targetId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'target',
        chapterId: 'target-chapter',
        pageId: 'target-page',
      ),
      sourceRevision: 'target-r2',
      canonicalUri: Uri.parse('https://example.test/target.webp'),
    );
    DownloadId candidate(String name) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: name,
            chapterId: '$name-chapter',
            pageId: '$name-page',
          ),
          sourceRevision: '$name-r1',
          canonicalUri: Uri.parse('https://example.test/$name.webp'),
        );
    final first = candidate('first');
    final longest = candidate('longest');
    final backend = _MetadataPartialStore();
    backend.partial[first] = _StoredPartial(
      bytes: Uint8List(128),
      validators: const Validators(),
      totalLength: 1024,
    );
    backend.partial[longest] = _StoredPartial(
      bytes: Uint8List(512),
      validators: const Validators(),
      totalLength: 1024,
    );
    backend.metadataLengthOverrides[first] = 2048;
    final handoff = PartialDownloadHandoff(
      store: backend,
      equivalentCandidates: (id) => id == targetId
          ? <DownloadId>[first, longest]
          : const <DownloadId>[],
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(targetId);
    await handoff.restoreInto(session);

    expect(session.committedLength, 512,
        reason: 'stale metadata must fall back to physical longest-prefix scan');
  });

  test('cancelling partial restore aborts body and preserves durable source',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'partial-restore-cancel-',
    );
    addTearDown(() async => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'cancel',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/cancel.webp'),
    );
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final opened = Completer<void>();
    final cancelled = Completer<void>();
    final controller = StreamController<List<int>>(
      onListen: opened.complete,
      onCancel: cancelled.complete,
    );
    addTearDown(controller.close);
    final backend = _PartialStore(
      streamFor: (_) => controller.stream,
    );
    backend.partial[id] = _StoredPartial(
      bytes: bytes,
      validators: const Validators(etag: 'durable'),
      totalLength: 16,
    );
    final handoff = PartialDownloadHandoff(store: backend);
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final session = registry.get(id);
    final control = CancelToken(priority: 900);
    final restore = handoff.restoreInto(session, control: control);

    await opened.future.timeout(const Duration(seconds: 1));
    control.cancel();
    await expectLater(
      restore,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await cancelled.future.timeout(const Duration(seconds: 1));

    expect(session.state, DownloadState.idle);
    expect(session.committedLength, 0);
    expect(backend.partial[id]?.bytes, bytes);
  });

  test(
    'cancelled restore frees preparation ownership while physical read drains',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'partial-restore-draining-read-',
      );
      addTearDown(() async => root.delete(recursive: true));
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'draining-cancel',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/draining.webp'),
      );
      final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      final streamClosed = Completer<void>();
      Stream<List<int>> slowRead(Uint8List bytes) async* {
        try {
          if (!readEntered.isCompleted) readEntered.complete();
          await releaseRead.future;
          yield bytes;
        } finally {
          if (!streamClosed.isCompleted) streamClosed.complete();
        }
      }

      final backend = _PartialStore(streamFor: slowRead);
      final bytes = Uint8List.fromList(
        List<int>.generate(4096, (index) => index & 0xff),
      );
      backend.partial[id] = _StoredPartial(
        bytes: bytes,
        validators: const Validators(etag: 'durable'),
        totalLength: bytes.lengthInBytes + 1024,
      );
      final trace = MemoryTraceSink();
      final handoff = PartialDownloadHandoff(
        store: backend,
        readScheduler: scheduler,
        clock: SystemClock(),
        traceSink: trace,
      );
      final registry = DownloadRegistry(
        layout: CacheLayout(root.path),
        clock: SystemClock(),
      );
      addTearDown(registry.dispose);
      final session = registry.get(id);
      final control = CancelToken(priority: 640);
      final restore = handoff.restoreInto(session, control: control);

      await readEntered.future.timeout(const Duration(seconds: 1));
      expect(scheduler.activeCount, 1);
      control.cancel();
      await expectLater(
        restore,
        throwsA(
          isA<Failure>().having(
            (failure) => failure.code,
            'code',
            ErrorCode.cancelled,
          ),
        ),
      ).timeout(const Duration(seconds: 1));

      expect(session.state, DownloadState.idle);
      expect(session.committedLength, 0);
      expect(
        scheduler.activeCount,
        1,
        reason:
            'the uncancellable physical read must remain charged after the restore owner retires',
      );
      expect(
        trace.events.any(
          (event) =>
              event.kind == TraceEventKind.artifactSource &&
              event.payload['action'] == 'cancelled-read-draining',
        ),
        isTrue,
      );

      releaseRead.complete();
      await streamClosed.future.timeout(const Duration(seconds: 1));
      for (var i = 0; i < 20 && scheduler.activeCount != 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(scheduler.activeCount, 0);
      expect(
        trace.events.any(
          (event) =>
              event.kind == TraceEventKind.artifactSource &&
              event.payload['action'] == 'cancelled-read-drain-complete',
        ),
        isTrue,
      );
    },
  );

  test('cold partial hydration uses the shared persistent read scheduler', () async {
    final root = await Directory.systemTemp.createTemp('partial-read-scheduler-');
    addTearDown(() async => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'scheduler',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/scheduler.webp'),
    );
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    var activeWhileReading = 0;
    final backend = _PartialStore(
      onRead: () => activeWhileReading = scheduler.activeCount,
    );
    final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xff));
    backend.partial[id] = _StoredPartial(
      bytes: bytes,
      validators: const Validators(),
      totalLength: bytes.lengthInBytes + 1024,
    );
    final handoff = PartialDownloadHandoff(
      store: backend,
      readScheduler: scheduler,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);

    final session = registry.get(id);
    await handoff.restoreInto(session);

    expect(activeWhileReading, 1);
    expect(scheduler.activeCount, 0);
    expect(session.committedLength, bytes.lengthInBytes);
  });

  test(
    'deterministic session body keeps priority over exact READY fast path',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ready-local-priority-',
      );
      addTearDown(() => root.delete(recursive: true));
      final id = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'ready-priority',
          chapterId: 'chapter',
          pageId: 'page',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/ready-priority.webp'),
      );
      final registry = DownloadRegistry(
        layout: CacheLayout(root.path),
        clock: SystemClock(),
      );
      addTearDown(registry.dispose);
      final session = registry.get(id);
      final localBytes = Uint8List.fromList(<int>[
        ...'RIFF....WEBPlocal'.codeUnits,
      ]);
      await File(session.artifact.partialPath).create(recursive: true);
      await File(session.artifact.partialPath).writeAsBytes(localBytes);

      final durableBytes = Uint8List.fromList(<int>[
        ...'RIFF....WEBPdurable'.codeUnits,
        ...List<int>.generate(64, (index) => index),
      ]);
      final store = _ReadyBoundStore(id: id, bytes: durableBytes);
      final handoff = PartialDownloadHandoff(store: store);

      await handoff.restoreInto(session);

      expect(session.residentIngressDeferred, isFalse);
      expect(session.artifact.state, ArtifactState.partial);
      expect(session.committedLength, localBytes.lengthInBytes);
      expect(
        store.readerOpenCalls,
        0,
        reason: 'an existing deterministic body must keep restore priority',
      );
    },
  );

  test(
    'verified equivalent READY binds resident authority without body copy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'equivalent-ready-bound-reader-',
      );
      addTearDown(() => root.delete(recursive: true));
      final oldId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'old-comic',
          chapterId: 'old-chapter',
          pageId: 'old-page',
        ),
        sourceRevision: 'old-r1',
        canonicalUri: Uri.parse('https://example.test/old-ready.webp'),
      );
      final newId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'new-comic',
          chapterId: 'new-chapter',
          pageId: 'new-page',
        ),
        sourceRevision: 'new-r2',
        canonicalUri: Uri.parse('https://example.test/new-ready.webp'),
      );
      final neverId = DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'never-comic',
          chapterId: 'never-chapter',
          pageId: 'never-page',
        ),
        sourceRevision: 'never-r3',
        canonicalUri: Uri.parse('https://example.test/never-ready.webp'),
      );
      final bytes = Uint8List.fromList(<int>[
        ...'RIFF'.codeUnits,
        0x80, 0x00, 0x00, 0x00,
        ...'WEBP'.codeUnits,
        ...'VP8X'.codeUnits,
        10, 0, 0, 0,
        0x02, 0, 0, 0,
        0x7f, 0x02, 0,
        0xaf, 0x04, 0,
        ...List<int>.generate(1024, (index) => index & 0xff),
      ]);
      final store = _ReadyBoundStore(id: oldId, bytes: bytes);
      final trace = MemoryTraceSink();
      final handoff = PartialDownloadHandoff(
        store: store,
        equivalentCandidates: (id) => id == newId
            ? <DownloadId>[oldId, neverId]
            : const <DownloadId>[],
        clock: SystemClock(),
        traceSink: trace,
      );
      final registry = DownloadRegistry(
        layout: CacheLayout(root.path),
        clock: SystemClock(),
      );
      addTearDown(registry.dispose);
      final session = registry.get(newId);

      await handoff.restoreInto(session);

      expect(session.state, DownloadState.promoted);
      expect(session.residentBodyBacked, isTrue);
      expect(session.residentIngressDeferred, isTrue);
      expect(session.artifact.committedLength, 0,
          reason: 'equivalent READY bytes must not be copied into hot storage');
      expect(await session.artifact.hasRestorableBody(), isFalse,
          reason: 'the initialized deterministic artifact remains body-empty');
      expect(session.validators.isEmpty, isTrue,
          reason: 'provider validators never cross equivalent source revisions');
      expect(session.committedLength, bytes.lengthInBytes);
      expect(session.sourceMetadataPrefixLength, 64);
      expect(store.readerOpenCalls, 1);
      expect(store.readerReadCalls, 1,
          reason: 'restore reads only the metadata prefix before binding');
      expect(store.bodyOpenCalls, 0,
          reason: 'the historical full-body restore path must stay unused');
      expect(store.openRequests.where((id) => id == newId), hasLength(1),
          reason: 'the cold exact miss must not be queried twice');
      expect(store.openRequests, contains(oldId));
      expect(store.openRequests, isNot(contains(neverId)),
          reason: 'the first complete equivalent READY ends candidate search');
      expect(
        handoff.provesExactDurableBody(
          session,
          newId,
          bytes.lengthInBytes,
        ),
        isFalse,
        reason: 'verified equivalence is not exact-target durable ownership',
      );
      expect(
        trace.events.any(
          (event) =>
              event.kind == TraceEventKind.artifactSource &&
              event.payload['action'] == 'bound-ready-authority' &&
              event.payload['verifiedEquivalentReuse'] == true,
        ),
        isTrue,
      );

      final replay = session.residentReplayRangeChunks;
      expect(replay, isNotNull);
      final chunks = await replay!(64, 128);
      final replayed = <int>[];
      await for (final chunk in chunks) {
        replayed.addAll(chunk);
      }
      expect(replayed, orderedEquals(bytes.sublist(64, 128)));
      expect(store.readerReadCalls, 2);
    },
  );

  test('bound READY reader preserves metadata prefix and stays retained for ranges', () async {
    final root = await Directory.systemTemp.createTemp('ready-bound-reader-');
    addTearDown(() => root.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'ready-bound',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/ready-bound.jpg'),
    );
    final bytes = Uint8List.fromList(<int>[
      0xff, 0xd8, 0xff,
      ...List<int>.generate(1024, (index) => index & 0xff),
    ]);
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    var activeWhileOpening = 0;
    var activeWhileReading = 0;
    final store = _ReadyBoundStore(
      id: id,
      bytes: bytes,
      onReaderOpen: () => activeWhileOpening = scheduler.activeCount,
      onReaderRead: () => activeWhileReading = scheduler.activeCount,
    );
    final handoff = PartialDownloadHandoff(
      store: store,
      readScheduler: scheduler,
    );
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final session = registry.get(id);

    await handoff.restoreInto(session);
    expect(session.state, DownloadState.promoted);
    expect(session.artifact.state, ArtifactState.empty,
        reason: 'exact READY bypasses restore only with no deterministic body');
    expect(session.residentIngressDeferred, isTrue);
    expect(session.residentReplayAccessMode, 'saf');
    expect(session.contentKind, ContentKind.fallback,
        reason: 'READY binding must preserve its bounded metadata prefix');
    expect(store.readerOpenCalls, 1);
    expect(activeWhileOpening, 1,
        reason: 'descriptor open must run inside the local-read scheduler');
    expect(activeWhileReading, 1,
        reason: 'binding reads only the bounded metadata prefix');

    final replay = session.residentReplayRangeChunks;
    expect(replay, isNotNull);
    final first = await replay!(64, 128);
    final firstBytes = <int>[];
    await for (final chunk in first) { firstBytes.addAll(chunk); }
    final second = await replay(128, 256);
    final secondBytes = <int>[];
    await for (final chunk in second) { secondBytes.addAll(chunk); }
    expect(firstBytes, orderedEquals(bytes.sublist(64, 128)));
    expect(secondBytes, orderedEquals(bytes.sublist(128, 256)));
    expect(store.readerOpenCalls, 1);
    expect(store.readerReadCalls, 3,
        reason: 'one metadata read precedes the two decoder-demanded ranges');

    await session.reset(removeCacheRecord: false);
    expect(store.readerCloseCalls, 1,
        reason: 'reset is the generation boundary for the retained descriptor');
    expect(session.residentReplayRangeChunks, isNull);
  });

}

final class _RangeSuffixTransport implements Transport {
  _RangeSuffixTransport(this.bytes, {required this.validators});

  final Uint8List bytes;
  final Validators validators;
  final List<int> rangeStarts = <int>[];
  final List<Validators?> validatorsSeen = <Validators?>[];

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final start = range?.start ?? 0;
    rangeStarts.add(start);
    validatorsSeen.add(validators);
    return ByteResponse(
      bytes: Stream<List<int>>.value(Uint8List.sublistView(bytes, start)),
      statusCode: start > 0 ? 206 : 200,
      rangeStart: start,
      totalLength: bytes.lengthInBytes,
      validators: this.validators,
      rangeSupported: true,
    );
  }
}

final class _CountingArtifactBackend implements ArtifactCacheBackend {
  _CountingArtifactBackend(this.delegate);

  final ArtifactCacheBackend delegate;
  int openCalls = 0;
  int storeCalls = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) {
    openCalls++;
    return delegate.openArtifactStream(id);
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) {
    storeCalls++;
    return delegate.storePromotedArtifact(id: id, bytes: bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) =>
      delegate.invalidateArtifact(id);
}

final class _ReadyBoundStore implements PartialDownloadStore {
  _ReadyBoundStore({
    required this.id,
    required this.bytes,
    this.onReaderOpen,
    this.onReaderRead,
  });

  final DownloadId id;
  final Uint8List bytes;
  final void Function()? onReaderOpen;
  final void Function()? onReaderRead;
  int readerOpenCalls = 0;
  int readerReadCalls = 0;
  int readerCloseCalls = 0;
  int bodyOpenCalls = 0;
  final List<DownloadId> openRequests = <DownloadId>[];

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId requested) async {
    openRequests.add(requested);
    if (requested != id) return null;
    return PartialDownloadEntry(
      length: bytes.lengthInBytes,
      validators: const Validators(etag: '"ready"'),
      totalLength: bytes.lengthInBytes,
      exactDurableFinal: true,
      accessMode: 'saf',
      open: ({required int start}) async* {
        bodyOpenCalls++;
        yield Uint8List.sublistView(bytes, start);
      },
      openRange: ({required int start, required int endExclusive}) async* {
        yield Uint8List.sublistView(bytes, start, endExclusive);
      },
      openBoundRangeReader: () async {
        onReaderOpen?.call();
        readerOpenCalls++;
        return (
          accessMode: 'saf',
          readRange: (int start, int endExclusive) async {
            onReaderRead?.call();
            readerReadCalls++;
            return Uint8List.sublistView(bytes, start, endExclusive);
          },
          close: () async { readerCloseCalls++; },
        );
      },
    );
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {}

  @override
  Future<void> invalidatePartialDownload(DownloadId id) async {}
}

final class _MetadataPartialStore
    implements PartialDownloadStore, PartialDownloadMetadataStore {
  final Map<DownloadId, _StoredPartial> partial =
      <DownloadId, _StoredPartial>{};
  final Map<DownloadId, int> metadataLengthOverrides = <DownloadId, int>{};
  final List<DownloadId> metadataRequests = <DownloadId>[];
  final List<DownloadId> openRequests = <DownloadId>[];

  @override
  Future<PartialDownloadMetadata?> inspectPartialDownloadMetadata(
    DownloadId id,
  ) async {
    metadataRequests.add(id);
    final stored = partial[id];
    if (stored == null) return null;
    return PartialDownloadMetadata(
      length: metadataLengthOverrides[id] ?? stored.bytes.lengthInBytes,
      exactDurableFinal: false,
    );
  }

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) async {
    openRequests.add(id);
    final stored = partial[id];
    if (stored == null) return null;
    return PartialDownloadEntry(
      length: stored.bytes.lengthInBytes,
      validators: stored.validators,
      totalLength: stored.totalLength,
      open: ({required int start}) async* {
        yield Uint8List.sublistView(stored.bytes, start);
      },
    );
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {}

  @override
  Future<void> invalidatePartialDownload(DownloadId id) async {
    partial.remove(id);
  }
}

final class _PartialStore implements PartialDownloadStore {
  _PartialStore({this.onRead, this.streamFor});

  final void Function()? onRead;
  final Stream<List<int>> Function(Uint8List bytes)? streamFor;
  final Map<DownloadId, _StoredPartial> partial =
      <DownloadId, _StoredPartial>{};

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) async {
    final stored = partial[id];
    if (stored == null) return null;
    return PartialDownloadEntry(
      length: stored.bytes.lengthInBytes,
      validators: stored.validators,
      totalLength: stored.totalLength,
      open: ({required int start}) {
        final selected = streamFor;
        if (selected != null) {
          return selected(Uint8List.sublistView(stored.bytes, start));
        }
        final controller = StreamController<List<int>>(sync: true);
        controller.onListen = () {
          onRead?.call();
          controller
            ..add(Uint8List.sublistView(stored.bytes, start))
            ..close();
        };
        return controller.stream;
      },
    );
  }

  @override
  Future<void> storePartialDownload({
    required DownloadId id,
    required PartialDownloadEntry entry,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    partial[id] = _StoredPartial(
      bytes: builder.takeBytes(),
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
  }

  @override
  Future<void> invalidatePartialDownload(DownloadId id) async {
    partial.remove(id);
  }
}

final class _StoredPartial {
  const _StoredPartial({
    required this.bytes,
    required this.validators,
    required this.totalLength,
  });

  final Uint8List bytes;
  final Validators validators;
  final int? totalLength;
}
