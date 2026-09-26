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
  test('promoted idle physical session stays hot inside bounded retention',
      () async {
    final root = await Directory.systemTemp.createTemp('physical-retention-');
    addTearDown(() => root.delete(recursive: true));
    final backend = _RetentionStore();
    final cache = ArtifactCacheManager(backend: backend);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePromotedSessions: 1,
      maxIdlePartialSessions: 4,
      maxIdlePartialBytes: 1024,
    );
    addTearDown(runtime.dispose);
    final id = _id('promoted');
    final session = runtime.registry.get(id);
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]);

    await session.bindResponse(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);
    await session.seal(writer, expectedLength: bytes.lengthInBytes);
    await session.promote();
    await runtime.settlePhysicalRetention();

    expect(runtime.registry.findExact(id), same(session));
    expect(runtime.registry.get(id), same(session));
    expect(runtime.registry.sessions, hasLength(1));
  });

  test('promoted pressure retires only the oldest durable hot session',
      () async {
    final root = await Directory.systemTemp.createTemp('promoted-pressure-');
    addTearDown(() => root.delete(recursive: true));
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePromotedSessions: 1,
    );
    addTearDown(runtime.dispose);
    final firstId = _id('promoted-first');
    final secondId = _id('promoted-second');
    final first = runtime.registry.get(firstId);
    final firstBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await first.bindResponse(
      validators: const Validators(),
      totalLength: firstBytes.lengthInBytes,
    );
    final firstWriter = first.acquireWriter();
    await first.append(firstWriter, 0, firstBytes);
    await first.seal(firstWriter, expectedLength: firstBytes.lengthInBytes);
    await first.promote();
    await runtime.settlePhysicalRetention();
    expect(runtime.registry.findExact(firstId), same(first));

    final second = runtime.registry.get(secondId);
    final secondBytes = Uint8List.fromList(<int>[5, 6, 7, 8]);
    await second.bindResponse(
      validators: const Validators(),
      totalLength: secondBytes.lengthInBytes,
    );
    final secondWriter = second.acquireWriter();
    await second.append(secondWriter, 0, secondBytes);
    await second.seal(secondWriter, expectedLength: secondBytes.lengthInBytes);
    await second.promote();
    await runtime.settlePhysicalRetention();

    expect(backend.artifacts[firstId], orderedEquals(firstBytes));
    expect(runtime.registry.findExact(firstId), isNull);
    expect(runtime.registry.findExact(secondId), same(second));
    expect(runtime.registry.sessions, hasLength(1));
  });

  test('promoted hot body remains when immutable handoff is unavailable',
      () async {
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: null,
      partialDownloadStore: null,
      net: NetLane(maxActive: 1),
      maxIdlePromotedSessions: 0,
    );
    addTearDown(runtime.dispose);
    final id = _id('promoted-without-handoff');
    final session = runtime.registry.get(id);
    final bytes = Uint8List.fromList(<int>[7, 7, 7, 7]);

    await session.bindResponse(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);
    await session.seal(writer, expectedLength: bytes.lengthInBytes);
    await session.promote();
    await runtime.settlePhysicalRetention();

    expect(runtime.registry.findExact(id), same(session));
    expect(session.state, DownloadState.promoted);
    expect(session.committedLength, bytes.lengthInBytes);
  });

  test('idle partial retention keeps recent hot prefixes and cold-stores victim',
      () async {
    final root = await Directory.systemTemp.createTemp('partial-retention-');
    addTearDown(() => root.delete(recursive: true));
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePartialSessions: 1,
      maxIdlePartialBytes: 1024,
    );
    addTearDown(runtime.dispose);
    final firstId = _id('first');
    final secondId = _id('second');
    final first = runtime.registry.get(firstId);
    await _writePartial(first, <int>[1, 2, 3, 4]);
    await runtime.settlePhysicalRetention();
    expect(runtime.registry.findExact(firstId), same(first));

    final second = runtime.registry.get(secondId);
    await _writePartial(second, <int>[5, 6, 7, 8]);
    await runtime.settlePhysicalRetention();

    expect(runtime.registry.findExact(firstId), isNull);
    expect(runtime.registry.findExact(secondId), same(second));
    expect(
      backend.partials[firstId]?.bytes,
      orderedEquals(<int>[1, 2, 3, 4]),
    );
    expect(backend.partials.containsKey(secondId), isFalse);
    expect(runtime.registry.sessions, hasLength(1));
  });

  test(
      'active transfer progress checkpoints durable partial without detach or close',
      () async {
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePartialSessions: 32,
      maxIdlePartialBytes: 256 * 1024 * 1024,
    );
    addTearDown(runtime.dispose);
    final id = _id('online-checkpoint');
    final session = runtime.registry.get(id);
    await session.bindResponse(
      validators: const Validators(etag: 'online-checkpoint'),
      totalLength: 5 * 1024 * 1024,
    );
    final writer = session.acquireWriter();
    final halfMiB = Uint8List(512 * 1024);

    await session.append(writer, 0, halfMiB);
    await runtime.settlePhysicalRetention();
    expect(backend.partials.containsKey(id), isFalse);

    await session.append(writer, 512 * 1024, halfMiB);
    await runtime.settlePhysicalRetention();
    expect(backend.partials[id]?.bytes.lengthInBytes, 1024 * 1024);
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue);

    await session.append(writer, 1024 * 1024, Uint8List(1024 * 1024));
    await runtime.settlePhysicalRetention();
    expect(backend.partials[id]?.bytes.lengthInBytes, 1024 * 1024,
        reason: 'online checkpoint stride is 2 MiB after the first MiB');

    await session.append(writer, 2 * 1024 * 1024, Uint8List(1024 * 1024));
    await runtime.settlePhysicalRetention();
    expect(backend.partials[id]?.bytes.lengthInBytes, 3 * 1024 * 1024);
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue,
        reason: 'durability checkpoint must not retire or pause the hot writer');

    await session.pause(writer);
  });

  test(
      'failed progress checkpoint never pauses writer and retries after another stride',
      () async {
    final backend = _RetentionStore()..failPartialStores = true;
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final id = _id('online-checkpoint-failure');
    final session = runtime.registry.get(id);
    await session.bindResponse(
      validators: const Validators(),
      totalLength: 5 * 1024 * 1024,
    );
    final writer = session.acquireWriter();

    await session.append(writer, 0, Uint8List(1024 * 1024));
    await runtime.settlePhysicalRetention();
    expect(backend.partials.containsKey(id), isFalse);
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue);

    backend.failPartialStores = false;
    await session.append(
      writer,
      1024 * 1024,
      Uint8List(2 * 1024 * 1024),
    );
    await runtime.settlePhysicalRetention();
    expect(backend.partials[id]?.bytes.lengthInBytes, 3 * 1024 * 1024);
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue);
    await session.pause(writer);
  });

  test('explicit runtime checkpoint persists hot partial without retiring owner',
      () async {
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePartialSessions: 32,
      maxIdlePartialBytes: 256 * 1024 * 1024,
    );
    addTearDown(runtime.dispose);
    final id = _id('lifecycle-checkpoint');
    final session = runtime.registry.get(id);
    await session.bindResponse(
      validators: const Validators(),
      totalLength: 8,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[9, 8, 7, 6, 5]);

    // An explicit runtime safety checkpoint remains available for real owner
    // teardown/migration boundaries. It snapshots only the committed prefix
    // and must not pause, retire, or replace the hot owner.
    await runtime.checkpointPartials(reason: 'runtime-safety-checkpoint');

    expect(
      backend.partials[id]?.bytes,
      orderedEquals(<int>[9, 8, 7, 6, 5]),
    );
    expect(runtime.registry.findExact(id), same(session));
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue);

    await session.append(writer, 5, <int>[4, 3, 2]);
    await runtime.checkpointPartials(reason: 'runtime-safety-checkpoint');
    expect(
      backend.partials[id]?.bytes,
      orderedEquals(<int>[9, 8, 7, 6, 5, 4, 3, 2]),
    );
    expect(runtime.registry.findExact(id), same(session));
    expect(session.state, DownloadState.receiving);
    expect(session.hasWriter, isTrue);
    await session.pause(writer);
  });

  test('promoted retirement preserves equivalence-only durable ownership',
      () async {
    final root = await Directory.systemTemp.createTemp('equivalent-retention-');
    addTearDown(() => root.delete(recursive: true));
    final backend = _RetentionStore();
    final oldId = _id('old');
    final newId = _id('new');
    final bytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
    backend.artifacts[oldId] = Uint8List.fromList(bytes);
    final cache = ArtifactCacheManager(backend: backend)
      ..linkEquivalent(first: oldId, second: newId);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePromotedSessions: 0,
    );
    addTearDown(runtime.dispose);
    final session = runtime.registry.get(newId);

    await session.bindResponse(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);
    await session.seal(writer, expectedLength: bytes.lengthInBytes);
    await session.promote();
    await runtime.settlePhysicalRetention();

    expect(runtime.registry.findExact(newId), isNull);
    expect(backend.artifacts[oldId], orderedEquals(bytes));
    expect(backend.artifacts.containsKey(newId), isFalse);
  });

  test('failed cold-partial handoff keeps the hot physical owner', () async {
    final root = await Directory.systemTemp.createTemp('handoff-failure-');
    addTearDown(() => root.delete(recursive: true));
    final backend = _RetentionStore()..failPartialStores = true;
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      maxIdlePartialSessions: 1,
      maxIdlePartialBytes: 1024,
    );
    addTearDown(runtime.dispose);
    final first = runtime.registry.get(_id('failure-first'));
    await _writePartial(first, <int>[1, 2, 3]);
    final second = runtime.registry.get(_id('failure-second'));
    await _writePartial(second, <int>[4, 5, 6]);
    await runtime.settlePhysicalRetention();

    expect(runtime.registry.sessions, hasLength(2));
  });

  test('version relation alone never replaces the requested physical owner', () async {
    final oldId = _id('relation-old');
    final newId = _id('relation-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
        },
      });
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);

    expect(runtime.owner.resolveTransferId(oldId), oldId);
    final session = runtime.sessionFor(oldId);
    expect(session.id, oldId);
    expect(runtime.registry.findExact(oldId), same(session));
    expect(runtime.registry.findExact(newId), isNull);
  });

  test('idle exact partial yields to a more advanced verified carrier', () async {
    final oldId = _id('prefer-old');
    final newId = _id('prefer-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
          if (id == newId) yield oldId;
        },
      });
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final oldCarrier = runtime.registry.get(oldId);
    final newCarrier = runtime.registry.get(newId);
    await _writePartial(oldCarrier, <int>[1, 2, 3]);
    await _writePartial(newCarrier, <int>[1, 2, 3, 4, 5, 6, 7, 8]);

    expect(oldCarrier.demanded, isFalse);
    expect(newCarrier.demanded, isFalse);
    expect(runtime.owner.resolveTransferId(oldId), newId);
    expect(runtime.sessionFor(oldId), same(newCarrier));
    expect(runtime.registry.findExact(oldId), same(oldCarrier));
    expect(runtime.registry.findExact(newId), same(newCarrier));
  });

  test('promoted exact body bypasses equivalent discovery on reacquire',
      () async {
    final exactId = _id('promoted-exact');
    final equivalentId = _id('promoted-equivalent');
    var equivalentLookups = 0;
    final authority = VersionPageAuthority()
      ..replaceScope('exact-equivalent', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          equivalentLookups++;
          if (id == exactId) yield equivalentId;
        },
      });
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final exact = runtime.registry.get(exactId);
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    await exact.bindResponse(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    final writer = exact.acquireWriter();
    await exact.append(writer, 0, bytes);
    await exact.seal(writer, expectedLength: bytes.lengthInBytes);
    await exact.promote();

    equivalentLookups = 0;
    expect(runtime.owner.resolveTransferId(exactId), exactId);
    expect(runtime.sessionFor(exactId), same(exact));
    expect(
      equivalentLookups,
      0,
      reason:
          'a complete exact body is already sufficient physical authority',
    );
  });

  test('demanded exact session does not switch to an equivalent carrier', () async {
    final oldId = _id('demanded-old');
    final newId = _id('demanded-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
          if (id == newId) yield oldId;
        },
      });
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final oldCarrier = runtime.registry.get(oldId);
    final newCarrier = runtime.registry.get(newId);
    await _writePartial(oldCarrier, <int>[1, 2, 3]);
    await _writePartial(newCarrier, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    final demand = oldCarrier.attachDemand(scopeId: 'reader', priority: 1000);
    addTearDown(demand.detach);

    expect(oldCarrier.demanded, isTrue);
    expect(runtime.owner.resolveTransferId(oldId), oldId);
    expect(runtime.sessionFor(oldId), same(oldCarrier));
  });

  test('version relation joins an already-existing reusable physical carrier', () async {
    final oldId = _id('join-old');
    final newId = _id('join-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
          if (id == newId) yield oldId;
        },
      });
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final newerCarrier = runtime.registry.get(newId);
    await _writePartial(newerCarrier, <int>[1, 2, 3]);

    expect(runtime.owner.resolveTransferId(oldId), newId);
    expect(runtime.sessionFor(oldId), same(newerCarrier));
    expect(runtime.registry.findExact(oldId), isNull);
  });

  test('relation discovery does not move an existing partial to another version', () async {
    final oldId = _id('partial-old');
    final newId = _id('partial-new');
    final authority = VersionPageAuthority();
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final oldCarrier = runtime.registry.get(oldId);
    await oldCarrier.bindResponse(
      validators: const Validators(etag: 'old-provider-etag'),
      totalLength: 16,
    );
    final writer = oldCarrier.acquireWriter();
    await oldCarrier.append(writer, 0, <int>[1, 2, 3, 4, 5]);
    await oldCarrier.pause(writer);

    authority.replaceScope('old-new', <String, VersionPageReuseResolver>{
      'page': (id) sync* {
        if (id == oldId) yield newId;
        if (id == newId) yield oldId;
      },
    });
    await runtime.checkpointPartials(reason: 'version-relation-refresh');

    expect(backend.partials[oldId]?.bytes, orderedEquals(<int>[1, 2, 3, 4, 5]));
    expect(backend.partials[oldId]?.validators.etag, 'old-provider-etag');
    expect(backend.partials.containsKey(newId), isFalse);
  });

  test('relation discovery does not rewrite a promoted artifact owner', () async {
    final oldId = _id('ready-old');
    final newId = _id('ready-new');
    final authority = VersionPageAuthority();
    final backend = _RetentionStore();
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final oldCarrier = runtime.registry.get(oldId);
    authority.replaceScope('old-new', <String, VersionPageReuseResolver>{
      'page': (id) sync* {
        if (id == oldId) yield newId;
        if (id == newId) yield oldId;
      },
    });
    final bytes = Uint8List.fromList(<int>[7, 6, 5, 4, 3, 2, 1]);
    await oldCarrier.bindResponse(
      validators: const Validators(etag: 'old-ready-etag'),
      totalLength: bytes.lengthInBytes,
    );
    final writer = oldCarrier.acquireWriter();
    await oldCarrier.append(writer, 0, bytes);
    await oldCarrier.seal(writer, expectedLength: bytes.lengthInBytes);
    await oldCarrier.promote();
    expect(await runtime.artifactCacheHandoff!.settleAutomatic(oldCarrier), isTrue);

    expect(backend.artifacts[oldId], orderedEquals(bytes));
    expect(backend.artifacts.containsKey(newId), isFalse);
  });


  test('resident replay binds runtime service to one physical generation',
      () async {
    final backend = _RetentionStore();
    final cache = ArtifactCacheManager(backend: backend);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final id = _id('resident-replay-binding');
    final session = runtime.registry.get(id);
    final bytes = Uint8List.fromList(
      List<int>.generate(128, (index) => index & 0xff),
    );
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress();
    await cache.storePromotedArtifact(id: id, bytes: bytes);

    final replaySource = runtime.residentReplaySource(
      priorityFor: (_) => 1000,
    );
    final prefix = await session.readSourcePrefix(
      96,
      residentReplayChunks: (endExclusive) =>
          replaySource(session, endExclusive),
    );

    expect(prefix, orderedEquals(bytes.sublist(0, 96)));
    expect(session.artifact.committedLength, 0);
  });

  test('controlled resident replay keeps physical current priority under foreground pressure',
      () async {
    final backend = _RetentionStore();
    final cache = ArtifactCacheManager(backend: backend);
    final scheduler = ArtifactCacheReadScheduler(
      maxActive: 2,
      maxBackgroundWhileForeground: 1,
    );
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: cache,
      partialDownloadStore: backend,
      net: NetLane(maxActive: 1),
      localReadScheduler: scheduler,
    );
    addTearDown(runtime.dispose);
    final id = _id('resident-current-priority');
    final bytes = Uint8List.fromList(<int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.generate(64, (index) => index & 0xff),
    ]);
    await cache.storePromotedArtifact(id: id, bytes: bytes);
    final session = runtime.registry.get(id);
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );
    final demand = session.attachDemand(scopeId: 'reader', priority: 1000);
    addTearDown(demand.detach);

    final pressure = scheduler.holdForegroundPressure();
    addTearDown(pressure.release);
    final background = await scheduler.acquire(priority: () => 0);
    addTearDown(background.release);
    expect(scheduler.activeBackgroundCount, 1);

    final replay = runtime.residentReplayRangeSourceWithControl(
      priorityFor: (_) => 0,
    );
    final control = _TestTaskControl(priority: 1000);
    final stream = await replay(
      session,
      0,
      32,
      control: control,
    );
    final iterator = StreamIterator<List<int>>(stream);
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext().timeout(const Duration(seconds: 1)), isTrue,
        reason: 'physical current priority must bypass a saturated background slot');
    expect(iterator.current, orderedEquals(bytes.sublist(0, 32)));
    expect(scheduler.activeForegroundCount, 0,
        reason: 'the per-chunk foreground lease is released after the chunk read');
  });

  test('retiring physical owner removes acquire-time aliases to that session',
      () async {
    final root = await Directory.systemTemp.createTemp('alias-retention-');
    addTearDown(() => root.delete(recursive: true));
    final registry = DownloadRegistry(
      layout: CacheLayout(root.path),
      clock: SystemClock(),
    );
    addTearDown(registry.dispose);
    final physicalId = _id('physical');
    final aliasId = _id('alias');
    final session = registry.get(physicalId);
    registry.aliasPhysical(id: aliasId, target: physicalId);

    expect(registry.resolvePhysicalId(aliasId), physicalId);
    expect(registry.takeIdlePhysical(physicalId), same(session));
    expect(registry.resolvePhysicalId(aliasId), aliasId);
    await session.dispose();
  });

  test('version authority feeds READY cache lookup without materialized aliases', () async {
    final oldId = _id('cache-old');
    final newId = _id('cache-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
          if (id == newId) yield oldId;
        },
      });
    final backend = _RetentionStore()
      ..artifacts[newId] = Uint8List.fromList(<int>[9, 8, 7]);
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);

    final lookup = await runtime.artifactCacheManager!.lookup(oldId);
    expect(lookup, isNotNull);
    expect(lookup!.storageId, newId);
    expect(await lookup.entry.readAll!(), orderedEquals(<int>[9, 8, 7]));
    expect(backend.artifacts.containsKey(oldId), isFalse);
  });

  test('version authority feeds cold partial restore with exact validator isolation', () async {
    final oldId = _id('cold-old');
    final newId = _id('cold-new');
    final authority = VersionPageAuthority()
      ..replaceScope('old-new', <String, VersionPageReuseResolver>{
        'page': (id) sync* {
          if (id == oldId) yield newId;
          if (id == newId) yield oldId;
        },
      });
    final backend = _RetentionStore();
    await backend.storePartialDownload(
      id: newId,
      entry: PartialDownloadEntry(
        length: 4,
        validators: const Validators(etag: 'new-provider-etag'),
        totalLength: 12,
        open: ({required int start}) async* {
          yield Uint8List.sublistView(Uint8List.fromList(<int>[1, 2, 3, 4]), start);
        },
      ),
    );
    final runtime = CompositionDownloadTransferRuntime(
      artifactCacheManager: ArtifactCacheManager(backend: backend),
      partialDownloadStore: backend,
      versionPageAuthority: authority,
      net: NetLane(maxActive: 1),
    );
    addTearDown(runtime.dispose);
    final oldSession = runtime.registry.get(oldId);

    await runtime.partialDownloadHandoff!.restoreInto(oldSession);

    expect(oldSession.committedLength, 4);
    expect(oldSession.resumeValidatorsFor(oldId.canonicalUri).isEmpty, isTrue);
    expect(backend.partials.containsKey(oldId), isFalse);
  });

}

Future<void> _writePartial(DownloadSession session, List<int> values) async {
  final bytes = Uint8List.fromList(values);
  await session.bindResponse(
    validators: const Validators(etag: 'retention-etag'),
    totalLength: bytes.lengthInBytes * 2,
  );
  final writer = session.acquireWriter();
  await session.append(writer, 0, bytes);
  await session.pause(writer);
}

DownloadId _id(String page) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: page,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$page.webp'),
    );

final class _RetentionStore
    implements ArtifactCacheBackend, PartialDownloadStore {
  final Map<DownloadId, Uint8List> artifacts = <DownloadId, Uint8List>{};
  final Map<DownloadId, _StoredPartial> partials =
      <DownloadId, _StoredPartial>{};
  bool failPartialStores = false;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    final bytes = artifacts[id];
    if (bytes == null) return null;
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
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    artifacts[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    artifacts.remove(id);
  }

  @override
  Future<PartialDownloadEntry?> openPartialDownload(DownloadId id) async {
    final stored = partials[id];
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
  }) async {
    if (failPartialStores) {
      throw StateError('forced partial store failure');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in entry.open(start: 0)) {
      builder.add(chunk);
    }
    partials[id] = _StoredPartial(
      bytes: builder.takeBytes(),
      validators: entry.validators,
      totalLength: entry.totalLength,
    );
  }

  @override
  Future<void> invalidatePartialDownload(DownloadId id) async {
    partials.remove(id);
  }
}

final class _TestTaskControl implements TaskControl {
  _TestTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;
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
