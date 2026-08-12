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

    expect(session.detachIngressProjection('reader-a'), isTrue);
    await session.append(writer, first.length + 4, <int>[9, 10]);
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
        expect(identical(physical, session), isTrue);
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
