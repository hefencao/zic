import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';

void main() {
  late Directory temp;
  late DownloadSession session;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_session_test_');
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/page.webp',
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    await session.restore();
  });

  tearDown(() async {
    if (session.hasWriter) {
      await session.reset();
    }
    if (!session.activeRun) {
      await session.dispose();
    }
    if (temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  });

  test('writer is exclusive', () {
    final writer = session.acquireWriter();
    expect(writer.epoch, const SourceEpoch(0));
    expect(
      session.acquireWriter,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.writerBusy,
      )),
    );
  });

  test('reset rejects late chunks from the old epoch', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2]);
    await session.reset();

    await expectLater(
      session.append(writer, 0, <int>[3]),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
  });

  test('detach retains an active receiving writer', () async {
    final writer = session.acquireWriter();
    session.detach();
    expect(session.state, DownloadState.receiving);
    expect(session.demanded, isFalse);

    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.seal(writer, expectedLength: 3);
    expect(session.state, DownloadState.sealed);
  });

  test('consumer demand claims use max priority and detach independently', () {
    session.detach();
    final current = session.attachDemand(scopeId: 'reader-a', priority: 1000);
    final preload = session.attachDemand(scopeId: 'reader-b', priority: 700);

    expect(session.demandCount, 2);
    expect(session.effectivePriority, 1000);
    expect(session.demanded, isTrue);

    current.detach();
    expect(session.demandCount, 1);
    expect(session.effectivePriority, 700);
    expect(session.demanded, isTrue);

    preload.updatePriority(820);
    expect(session.effectivePriority, 820);

    preload.detach();
    expect(session.demandCount, 0);
    expect(session.effectivePriority, 0);
    expect(session.demanded, isFalse);
  });
  test('source listeners are notified as an incremental source grows',
      () async {
    await session.dispose();
    final ingress = Ingress(factory: _TestSourceFactory(), maxBytes: 1024);
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/stream.webp',
        finalPath: '${temp.path}/cache/stream.webp',
      ),
      clock: FakeMonoClock(),
    );
    final projection1 = DownloadIngressProjection(
      scopeId: 'test-1:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection1);
    await session.restore();
    final lengths = <int>[];
    projection1.addSourceListener((snapshot) => lengths.add(snapshot.length));

    final writer = session.acquireWriter();
    await session.append(writer, 0, 'RIFF....WEBP'.codeUnits);
    await session.append(writer, 12, <int>[1, 2, 3, 4]);

    expect(lengths.length, greaterThanOrEqualTo(2));
    expect(lengths.last, 16);
  });


  test('source listeners receive authoritative ingress failure', () async {
    await session.dispose();
    final ingress = Ingress(factory: _FailingSourceFactory(), maxBytes: 1024);
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/failed.webp',
        finalPath: '${temp.path}/cache/failed.webp',
      ),
      clock: FakeMonoClock(),
    );
    final projection2 = DownloadIngressProjection(
      scopeId: 'test-2:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection2);
    await session.restore();
    final snapshots = <IngressSnap>[];
    projection2.addSourceListener(snapshots.add);

    final writer = session.acquireWriter();
    await session.append(writer, 0, 'RIFF....WEBP'.codeUnits);

    expect(snapshots, isNotEmpty);
    expect(snapshots.last.sourceReady, isFalse);
    expect(snapshots.last.failure?.code, ErrorCode.source);

    final lateSnapshots = <IngressSnap>[];
    projection2.addSourceListener(lateSnapshots.add);
    expect(lateSnapshots, hasLength(1));
    expect(lateSnapshots.single.failure?.code, ErrorCode.source);
  });

  test('source listeners observe restored readiness and terminal seal', () async {
    await session.dispose();
    final ingress = Ingress(factory: _TestSourceFactory(), maxBytes: 1024);
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/sealed.webp',
        finalPath: '${temp.path}/cache/sealed.webp',
      ),
      clock: FakeMonoClock(),
    );
    final projection3 = DownloadIngressProjection(
      scopeId: 'test-3:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection3);
    await session.restore();
    final writer = session.acquireWriter();
    await session.append(writer, 0, 'RIFF....WEBP'.codeUnits);

    final snapshots = <IngressSnap>[];
    projection3.addSourceListener(snapshots.add);
    await session.seal(writer, expectedLength: 12);

    expect(snapshots.first.sourceReady, isTrue);
    expect(snapshots.last.sealed, isTrue);
  });

  test('late Reader ingress projections replay and then diverge independently',
      () async {
    await session.dispose();
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/shared.webp',
        finalPath: '${temp.path}/cache/shared.webp',
      ),
      clock: FakeMonoClock(),
    );
    await session.restore();
    final writer = session.acquireWriter();
    final first = <int>[...'RIFF....WEBP'.codeUnits, 1, 2, 3, 4];
    await session.append(writer, 0, first);

    final projectionA = DownloadIngressProjection(
      scopeId: 'reader-a',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    final projectionB = DownloadIngressProjection(
      scopeId: 'reader-b',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    await session.attachSynchronizedIngressProjection(projectionA);
    final joinB = session.attachSynchronizedIngressProjection(projectionB);
    await session.append(writer, first.length, <int>[5, 6, 7, 8]);
    await joinB;

    expect(session.snapshot.ingressProjectionCount, 2);
    expect(projectionA.snapshot.length, first.length + 4);
    expect(projectionB.snapshot.length, first.length + 4);
    final projectionBSource = projectionB.source;
    expect(projectionBSource, isNotNull);

    expect(session.detachIngressProjection('reader-a'), isTrue);
    await session.append(writer, first.length + 4, <int>[9, 10]);
    expect(identical(projectionB.source, projectionBSource), isTrue);
    expect(projectionA.snapshot.length, first.length + 4);
    expect(projectionB.snapshot.length, first.length + 6);
    expect(session.snapshot.ingressProjectionCount, 1);
  });

  test('Reader-local ingress registry joins an existing physical prefix asynchronously',
      () async {
    final writer = session.acquireWriter();
    final first = <int>[...'RIFF....WEBP'.codeUnits, 1, 2, 3, 4];
    await session.append(writer, 0, first);

    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-late',
    );

    // Late consumer projection creation is intentionally synchronous and cheap:
    // it must not throw merely because the composition physical transfer has
    // already committed bytes. Prefix replay happens behind this call.
    final projection = ingresses.get(session);
    expect(projection.snapshot.length, 0);

    await ingresses.settled(session.id);
    expect(projection.snapshot.length, first.length);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(session.snapshot.ingressProjectionCount, 1);

    ingresses.dispose();
    sources.dispose();
    expect(session.snapshot.ingressProjectionCount, 0);
  });


  test('late WebP Reader publishes a playable prefix before full partial catch-up',
      () async {
    await session.dispose();
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/late-playable.webp',
        finalPath: '${temp.path}/cache/late-playable.webp',
      ),
      clock: FakeMonoClock(),
    );
    await session.restore();
    final writer = session.acquireWriter();
    final body = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(2 * 1024 * 1024, 1),
    ];
    await session.append(writer, 0, body);

    final projection = DownloadIngressProjection(
      scopeId: 'reader-playable-prefix',
      ingress: Ingress(
        factory: _TestSourceFactory(),
        maxBytes: 4 * 1024 * 1024,
      ),
    );
    final ready = Completer<IngressSnap>();
    projection.addSourceListener((snapshot) {
      if (snapshot.sourceReady && !ready.isCompleted) ready.complete(snapshot);
    });

    final join = session.attachSynchronizedIngressProjection(projection);
    final firstReady = await ready.future;
    expect(firstReady.sourceReady, isTrue);
    expect(firstReady.length, greaterThan(0));
    expect(firstReady.length, lessThan(body.length));
    expect(firstReady.length, remoteWebpDecodePrefixQuantumBytes);

    await join;
    expect(projection.snapshot.length, body.length);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(session.snapshot.ingressProjectionCount, 1);
  });

  test('late Reader replay survives artifact promotion path handoff', () async {
    final writer = session.acquireWriter();
    final body = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(512 * 1024, 7),
    ];
    await session.append(writer, 0, body);
    await session.seal(writer, expectedLength: body.length);

    // Promotion owns the rename. Reproduce the small interval where the data
    // already lives at finalPath while DownloadSession/Artifact still report a
    // sealed generation. Synchronized replay must see the same authoritative
    // bytes instead of a zero-length source.
    await File(session.artifact.finalPath).parent.create(recursive: true);
    await File(session.artifact.partialPath).rename(session.artifact.finalPath);

    final projection = DownloadIngressProjection(
      scopeId: 'reader-promotion-window',
      ingress: Ingress(
        factory: _TestSourceFactory(),
        maxBytes: 1024 * 1024,
      ),
    );
    await session.attachSynchronizedIngressProjection(projection);

    expect(projection.snapshot.length, body.length);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(projection.snapshot.sealed, isTrue);
    expect(projection.snapshot.failure, isNull);
    expect(session.snapshot.ingressProjectionCount, 1);
  });

  test('Reader ingress registry replaces a retired same-id session generation',
      () async {
    final clock = FakeMonoClock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/generation-cache'),
      clock: clock,
    );
    final id = _id();
    final firstSession = downloads.get(id);
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-generation',
    );
    final firstProjection = ingresses.get(firstSession);
    final retired = downloads.takeIdlePhysical(id);
    expect(retired, same(firstSession));

    final secondSession = downloads.get(id);
    expect(identical(secondSession, firstSession), isFalse);
    final secondProjection = ingresses.get(secondSession);
    expect(identical(secondProjection, firstProjection), isFalse);
    expect(secondProjection.snapshot.sourceReady, isFalse);
    expect(secondSession.snapshot.ingressProjectionCount, 1);
    expect(firstSession.snapshot.ingressProjectionCount, 0);

    ingresses.dispose();
    sources.dispose();
    await retired!.dispose();
    await downloads.dispose();
  });

  test('Reader ingress registry preserves sealed same-id encoded generation',
      () async {
    final clock = FakeMonoClock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/sealed-generation-cache'),
      clock: clock,
    );
    final id = _id();
    final firstSession = downloads.get(id);
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-sealed-generation',
    );
    final firstProjection = ingresses.get(firstSession);
    final body = <int>[...'RIFF....WEBPsealed-generation'.codeUnits];
    await firstSession.bindResponse(totalLength: body.length);
    final writer = firstSession.acquireWriter();
    await firstSession.append(writer, 0, body);
    await firstSession.seal(writer, expectedLength: body.length);
    expect(firstProjection.snapshot.sealed, isTrue);
    expect(firstProjection.snapshot.sourceReady, isTrue);

    final retired = downloads.takeIdlePhysical(id);
    expect(retired, same(firstSession));
    final secondSession = downloads.get(id);
    expect(identical(secondSession, firstSession), isFalse);
    final secondProjection = ingresses.get(secondSession);

    expect(secondProjection, same(firstProjection));
    expect(secondProjection.snapshot.length, body.length);
    expect(secondProjection.snapshot.sealed, isTrue);
    expect(secondProjection.snapshot.failure, isNull);
    expect(firstSession.snapshot.ingressProjectionCount, 0);
    expect(secondSession.snapshot.ingressProjectionCount, 0);

    // A late teardown from the retired same-id physical object must not remove
    // the preserved Reader encoded-generation entry now owned by secondSession.
    ingresses.detach(firstSession);
    expect(ingresses.find(id), same(secondProjection));

    ingresses.dispose();
    sources.dispose();
    await retired!.dispose();
    await downloads.dispose();
  });

  test('late Reader projection stays unpublished until replay is authoritative',
      () async {
    final bytes = <int>[...'RIFF....WEBP'.codeUnits, 1, 2, 3, 4, 5, 6];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress();

    final controller = StreamController<List<int>>();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-staged',
      residentReplayChunks: (_) async => controller.stream,
    );

    final projection = ingresses.get(session);
    controller.add(bytes.sublist(0, 12));
    await Future<void>.delayed(Duration.zero);
    expect(projection.source, isNull);
    expect(projection.snapshot.sourceReady, isFalse);

    controller.add(bytes.sublist(12));
    await controller.close();
    await ingresses.settled(session.id);
    expect(projection.source, isNotNull);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(projection.snapshot.length, bytes.length);

    ingresses.dispose();
    sources.dispose();
  });

  test('resident cache retains source metadata prefix outside Artifact', () {
    final prefix = <int>[
      0x52, 0x49, 0x46, 0x46,
      0xf4, 0x03, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      0x56, 0x50, 0x38, 0x20,
      0xe8, 0x03, 0x00, 0x00,
      0x00, 0x00, 0x00,
      0x9d, 0x01, 0x2a,
      0x80, 0x02,
      0xb0, 0x04,
    ];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: prefix.length,
    );
    session.appendResidentImmutableIngress(0, prefix);
    session.sealResidentImmutableIngress();

    expect(session.artifact.committedLength, 0);
    expect(session.snapshot.sourceCanvasWidth, 640);
    expect(session.snapshot.sourceCanvasHeight, 1200);
    expect(session.readIngressPrefix(prefix.length), prefix);
  });

  test('resident source prefix uses external body authority beyond metadata',
      () async {
    final bytes = <int>[
      0x52, 0x49, 0x46, 0x46,
      0x80, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      ...List<int>.generate(120, (index) => index & 0xff),
    ];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress();

    final prefix = await session.readSourcePrefix(96,
        residentReplayChunks: (endExclusive) async {
      return Stream<List<int>>.value(bytes.sublist(0, endExclusive));
    });

    expect(session.artifact.committedLength, 0);
    expect(prefix, bytes.sublist(0, 96));
  });

  test('resident-cache late Reader replays from external byte authority',
      () async {
    final bytes = <int>[...'RIFF....WEBP'.codeUnits, 1, 2, 3, 4, 5, 6];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress();

    expect(session.residentBodyBacked, isTrue);
    expect(session.committedLength, bytes.length);
    expect(session.artifact.committedLength, 0);

    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident',
      residentReplaySource: (physical, endExclusive) async {
        expect(physical, same(session));
        return Stream<List<int>>.value(bytes.sublist(0, endExclusive));
      },
    );

    final projection = ingresses.get(session);
    expect(projection.snapshot.length, 0);
    await ingresses.settled(session.id);

    expect(projection.snapshot.length, bytes.length);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(projection.snapshot.sealed, isTrue);
    expect(session.artifact.committedLength, 0);

    ingresses.dispose();
    sources.dispose();
  });

  test('cancelled writer attempt preserves partial without failed state', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3, 4]);
    await session.fail(
      writer,
      const Failure(code: ErrorCode.cancelled, message: 'scheduler preempted'),
    );

    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.committedLength, 4);
    expect(session.artifact.hasOpenWriter, isFalse);
  });

  test('snapshot owns the resume baseline for one network run', () async {
    var writer = session.acquireWriter();
    expect(session.snapshot.networkStartLength, 0);
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.fail(
      writer,
      const Failure(code: ErrorCode.network, message: 'controlled pause'),
    );

    session.queue();
    expect(session.snapshot.networkStartLength, 3);
    writer = session.acquireWriter();
    expect(session.snapshot.networkStartLength, 3);
    await session.append(writer, 3, <int>[4, 5]);

    expect(session.snapshot.committedLength, 5);
    expect(session.snapshot.networkStartLength, 3);
  });

  test('commit telemetry batches small chunks and flushes the final tail',
      () async {
    await session.dispose();
    final trace = MemoryTraceSink();
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/trace.webp',
        finalPath: '${temp.path}/cache/trace.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    await session.restore();
    final writer = session.acquireWriter();
    var offset = 0;
    for (var index = 0; index < 4; index++) {
      final chunk = List<int>.filled(20 * 1024, index);
      await session.append(writer, offset, chunk);
      offset += chunk.length;
    }
    await session.append(writer, offset, List<int>.filled(1024, 9));
    offset += 1024;
    await session.seal(writer, expectedLength: offset);

    final commits = trace.events
        .where((event) => event.kind == TraceEventKind.bytesCommitted)
        .toList(growable: false);
    expect(commits, hasLength(2));
    expect(commits.first.payload['chunks'], 4);
    expect(commits.first.payload['bytes'], 80 * 1024);
    expect(commits.last.payload['chunks'], 1);
    expect(commits.last.payload['bytes'], 1024);
  });

  test('run lease serializes active transport work', () {
    final run = session.beginRun();
    expect(session.activeRun, isTrue);
    expect(session.canEvict, isFalse);
    expect(
      session.beginRun,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );

    session.endRun(run);
    expect(session.activeRun, isFalse);
    expect(session.canEvict, isTrue);
  });

  test(
    'snapshot observers follow promotion and cannot break the session',
    () async {
      final states = <DownloadState>[];
      session.addSnapshotListener((snapshot) => states.add(snapshot.state));
      session.addSnapshotListener((_) => throw StateError('observer failure'));

      final writer = session.acquireWriter();
      await session.append(writer, 0, <int>[1, 2, 3]);
      await session.seal(writer, expectedLength: 3);
      await session.promote();

      expect(
        states,
        containsAllInOrder(<DownloadState>[
          DownloadState.idle,
          DownloadState.receiving,
          DownloadState.sealed,
          DownloadState.promoted,
        ]),
      );
      expect(session.state, DownloadState.promoted);
    },
  );

  test('snapshot observers receive terminal disposal', () async {
    final states = <DownloadState>[];
    session.addSnapshotListener((snapshot) => states.add(snapshot.state));

    await session.dispose();

    expect(states.last, DownloadState.disposed);
  });

  test('legacy unscoped resume validators are discarded but length survives',
      () async {
    await session.dispose();
    final partial = File('${temp.path}/partial/page.webp');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(<int>[1, 2, 3, 4]);
    await File('${partial.path}.meta').writeAsString(jsonEncode(<String, Object?>{
      'version': 2,
      'downloadKey': _id().key,
      'download': _id().toJson(),
      'validators': const Validators(etag: 'legacy-v2').toJson(),
      'totalLength': 100,
    }));

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partial.path,
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    final restored = await session.restore();

    expect(restored.committedLength, 4);
    expect(restored.validators.isEmpty, isTrue);
    expect(session.validatorRequestUri, isNull);
    expect(restored.totalLength, 100);
  });

  test('corrupt resume metadata preserves committed media bytes', () async {
    await session.dispose();
    final partial = File('${temp.path}/partial/page.webp');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(<int>[1, 2, 3]);
    await File('${partial.path}.meta').writeAsString('{broken');

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partial.path,
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    final restored = await session.restore();

    expect(restored.committedLength, 3);
    expect(restored.validators.isEmpty, isTrue);
    expect(restored.totalLength, isNull);
    expect(restored.state, DownloadState.idle);
  });


  test('malformed owner metadata does not discard committed media bytes', () async {
    await session.dispose();
    final partial = File('${temp.path}/partial/page.webp');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(<int>[1, 2, 3, 4]);
    await File('${partial.path}.meta').writeAsString(
      '{"download":"not-a-download-id","validators":{}}',
    );

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partial.path,
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    final restored = await session.restore();

    expect(restored.committedLength, 4);
    expect(restored.validators.isEmpty, isTrue);
    expect(restored.totalLength, isNull);
  });

  test('explicit different download owner invalidates the partial', () async {
    await session.dispose();
    final partial = File('${temp.path}/partial/page.webp');
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(<int>[1, 2, 3, 4]);
    await File('${partial.path}.meta').writeAsString(
      '{"downloadKey":"different-owner","validators":{}}',
    );

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partial.path,
        finalPath: '${temp.path}/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    final restored = await session.restore();

    expect(restored.committedLength, 0);
    expect(restored.validators.isEmpty, isTrue);
    expect(restored.totalLength, isNull);
  });

  test('playable-prefix evidence strengthens within one physical generation',
      () async {
    const unresolvedFloor = 256 * 1024;
    expect(
      session.playableFlowPrefixFloorBytes(
        unresolvedFloorBytes: unresolvedFloor,
      ),
      unresolvedFloor,
    );

    expect(
      session.observePlayablePrefixEvidence(
        decodedPrefixFrames: 0,
        sourceLength: 128 * 1024,
        firstPlayablePrefixBytes: 0,
        firstFrameRequiredSourceLength: 512 * 1024,
      ),
      isTrue,
    );
    expect(session.firstFrameRequiredPrefixBytes, 512 * 1024);
    expect(
      session.playableFlowPrefixFloorBytes(
        unresolvedFloorBytes: unresolvedFloor,
      ),
      512 * 1024,
    );

    expect(
      session.observePlayablePrefixEvidence(
        decodedPrefixFrames: 1,
        sourceLength: 384 * 1024,
        firstPlayablePrefixBytes: 384 * 1024,
        firstFrameRequiredSourceLength: 0,
      ),
      isTrue,
    );
    expect(session.decodedPrefixFrames, 1);
    expect(session.firstPlayablePrefixBytes, 384 * 1024);
    expect(
      session.playableFlowPrefixFloorBytes(
        unresolvedFloorBytes: unresolvedFloor,
      ),
      384 * 1024,
    );

    // A later need-more-data observation for another frame cannot make the
    // already proven first playable prefix less valid.
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 640 * 1024,
      firstPlayablePrefixBytes: 384 * 1024,
      firstFrameRequiredSourceLength: 768 * 1024,
    );
    expect(
      session.playableFlowPrefixFloorBytes(
        unresolvedFloorBytes: unresolvedFloor,
      ),
      384 * 1024,
    );

    await session.reset();
    expect(session.firstPlayablePrefixBytes, 0);
    expect(session.firstFrameRequiredPrefixBytes, 0);
    expect(session.decodedPrefixFrames, 0);
  });
}

DownloadId _id() => DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );


final class _TestSourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _TestEncodedSource(epoch);
}

final class _TestEncodedSource implements EncodedSource {
  _TestEncodedSource(this._epoch);

  int _epoch;
  final List<int> _bytes = <int>[];
  bool _sealed = false;

  @override
  int get epoch => _epoch;

  @override
  int get length => _bytes.length;

  @override
  SourceKind get kind => SourceKind.webp;

  @override
  bool get sealed => _sealed;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    if (epoch != _epoch) return SourceStatus.staleEpoch;
    if (offset != _bytes.length) return SourceStatus.invalidOffset;
    _bytes.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    _epoch = epoch;
    _bytes.clear();
    _sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    if (epoch != _epoch) return SourceStatus.staleEpoch;
    _sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _FailingSourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _FailingEncodedSource(epoch);
}

final class _FailingEncodedSource implements EncodedSource {
  _FailingEncodedSource(this.epoch);

  @override
  int epoch;

  @override
  int get length => 0;

  @override
  SourceKind get kind => SourceKind.webp;

  @override
  bool get sealed => false;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) =>
      SourceStatus.failed;

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) => SourceStatus.failed;

  @override
  void dispose() {}
}
