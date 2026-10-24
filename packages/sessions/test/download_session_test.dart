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
import 'package:transport/transport.dart';

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

  test('resident direct file capability is generation-scoped', () async {
    var closes = 0;
    final bytes = <int>[
      ...('RIFF....WEBP'.codeUnits),
      ...List<int>.filled(64, 1),
    ];
    const directPath = '/proc/self/fd/123';
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.length,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
      residentReplayRangeChunks: (start, endExclusive) async =>
          Stream<List<int>>.value(bytes.sublist(start, endExclusive)),
      residentReplayRangeClose: () async {
        closes++;
      },
      residentReplayDirectFilePath: directPath,
      residentReplayAccessMode: 'direct',
    );

    expect(session.residentReplayDirectFilePath, directPath);
    expect(session.residentIngressDeferred, isTrue);

    await session.reset(removeCacheRecord: false);

    expect(session.residentReplayDirectFilePath, isNull);
    expect(session.residentIngressDeferred, isFalse);
    await session.settleCacheMutations();
    expect(
      closes,
      1,
      reason: 'retiring the physical generation closes its retained lease',
    );
  });

  test('network attempt publishes transient response total without owning durable length',
      () async {
    expect(session.totalLength, isNull);
    expect(session.networkAttemptTotalLength, isNull);

    session.beginNetworkAttemptProgress(0, totalLength: 15_640_724);

    expect(session.snapshot.networkAttemptActive, isTrue);
    expect(session.snapshot.networkAttemptTotalLength, 15_640_724);
    expect(session.snapshot.totalLength, isNull,
        reason: 'attempt metadata must not become durable resume authority');

    session.endNetworkAttemptProgress();
    expect(session.snapshot.networkAttemptActive, isFalse);
    expect(session.snapshot.networkAttemptTotalLength, isNull);
    expect(session.snapshot.totalLength, isNull);
  });

  test('local WebP RIFF prefix exposes a display-only total length hint',
      () async {
    const declaredTotal = 15_640_724;
    final riffPayload = declaredTotal - 8;
    final prefix = <int>[
      0x52, 0x49, 0x46, 0x46,
      riffPayload & 0xff,
      (riffPayload >> 8) & 0xff,
      (riffPayload >> 16) & 0xff,
      (riffPayload >> 24) & 0xff,
      0x57, 0x45, 0x42, 0x50,
      ...List<int>.filled(52, 0),
    ];
    final writer = session.acquireWriter();
    await session.append(writer, 0, prefix);

    expect(session.totalLength, isNull);
    expect(session.localEncodedTotalLengthHint, declaredTotal);
    expect(session.snapshot.localEncodedTotalLengthHint, declaredTotal);
    expect(session.snapshot.totalLength, isNull,
        reason: 'RIFF length is presentation metadata, not resume authority');
  });

  test('restore preserves an explicitly foreign colliding partial artifact',
      () async {
    final foreign = _idWithSource('foreign-source');
    final partial = File(session.artifact.partialPath);
    await partial.parent.create(recursive: true);
    final bytes = <int>[9, 8, 7, 6];
    await partial.writeAsBytes(bytes);
    await File('${partial.path}.meta').writeAsString(
      jsonEncode(<String, Object?>{'download': foreign.toJson()}),
    );

    final colliding = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partial.path,
        finalPath: session.artifact.finalPath,
      ),
      clock: FakeMonoClock(),
    );
    await expectLater(
      colliding.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    expect(await partial.readAsBytes(), orderedEquals(bytes));
    await colliding.dispose();
  });

  test('durable backing adoption preserves session and ordered Reader ingress',
      () async {
    final durablePartial = '${temp.path}/durable/partial/page.webp';
    final durableFinal = '${temp.path}/durable/final/page.webp';
    final durableWriter = Artifact(
      partialPath: durablePartial,
      finalPath: durableFinal,
    );
    await durableWriter.restore();
    final prefix = List<int>.generate(48, (index) => index & 0xff);
    await durableWriter.append(0, prefix);
    await durableWriter.pause();
    await durableWriter.dispose();
    final durableArtifact = Artifact(
      partialPath: durablePartial,
      finalPath: durableFinal,
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    var released = 0;
    final projection = DownloadIngressProjection(
      scopeId: 'adopt-reader',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    await session.attachSynchronizedIngressProjection(projection);
    final originalEpoch = session.epoch;

    await session.adoptDurablePartialBacking(
      artifact: durableArtifact,
      index: index,
      storageRootId: '${temp.path}/durable',
      expectedLength: prefix.length,
      validators: const Validators(etag: 'durable-v1'),
      totalLength: 64,
      releaseBacking: () => released++,
    );

    expect(session.epoch, originalEpoch);
    expect(session.artifact, same(durableArtifact));
    expect(session.committedLength, prefix.length);
    expect(session.networkStartLength, prefix.length);
    expect(session.networkCursorLength, 0);
    expect(projection.snapshot.epoch, originalEpoch);
    expect(projection.snapshot.length, prefix.length);
    expect(projection.snapshot.failure, isNull);

    final writer = session.acquireWriter();
    final suffix = List<int>.generate(16, (index) => 0x80 + index);
    await session.append(writer, prefix.length, suffix);
    expect(session.committedLength, 64);
    expect(projection.snapshot.length, 64);
    expect(projection.snapshot.failure, isNull);
    await session.pause(writer);
    await session.dispose(discardOwnedArtifactBody: true);
    expect(released, 1);
    expect(await File(durablePartial).exists(), isTrue,
        reason: 'retirement discard must never delete borrowed durable backing');
  });

  test('borrowed durable backing delegates later cache mutations to its owner',
      () async {
    final durablePartial = '${temp.path}/owned/partial/page.webp';
    final durableFinal = '${temp.path}/owned/final/page.webp';
    final durableWriter = Artifact(
      partialPath: durablePartial,
      finalPath: durableFinal,
    );
    await durableWriter.restore();
    final prefix = <int>[...'RIFF....WEBP'.codeUnits, ...List<int>.filled(32, 3)];
    await durableWriter.append(0, prefix);
    await durableWriter.pause();
    await durableWriter.dispose();

    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final owner = _RecordingCacheMutationOwner();
    var released = 0;

    await session.adoptDurablePartialBacking(
      artifact: Artifact(
        partialPath: durablePartial,
        finalPath: durableFinal,
      ),
      index: index,
      cacheMutationOwner: owner,
      storageRootId: '${temp.path}/owned',
      expectedLength: prefix.length,
      validators: const Validators(etag: 'owned-v1'),
      totalLength: prefix.length + 8,
      releaseBacking: () => released++,
    );

    expect(owner.syncedStates, isEmpty,
        reason: 'adoption itself is already inside the lending owner boundary');
    expect((await index.get(session.id.key))?.bytes, prefix.length);

    final writer = session.acquireWriter();
    await session.append(writer, prefix.length, List<int>.filled(8, 4));
    await session.pause(writer);
    expect(owner.syncedStates, <CacheState>[CacheState.partial]);
    expect((await index.get(session.id.key))?.bytes, prefix.length,
        reason: 'the session must not bypass the delegated persistent owner');

    await session.reset();
    expect(owner.clearCalls, 1);
    await session.dispose();
    expect(released, 1);
  });

  test('transfer-staging adoption updates only physical partial authority',
      () async {
    await session.dispose();
    final id = _idWithSource('transfer-staging');
    final physical = PhysicalMediaId.canonical('transfer-staging-physical');
    session = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: Artifact(
        partialPath: '${temp.path}/ephemeral/partial/page.webp',
        finalPath: '${temp.path}/ephemeral/final/page.webp',
      ),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    await session.restore();

    final staging = Artifact(
      partialPath: '${temp.path}/staging/partial/page.webp',
      finalPath: '${temp.path}/staging/final/page.webp',
    );
    await staging.restore();
    final prefix = <int>[...'RIFF....WEBP'.codeUnits, ...List<int>.filled(64, 1)];
    await staging.append(0, prefix);
    await staging.pause();
    await staging.dispose();

    final stagingArtifact = Artifact(
      partialPath: '${temp.path}/staging/partial/page.webp',
      finalPath: '${temp.path}/staging/final/page.webp',
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    var released = 0;

    await session.adoptDurablePartialBacking(
      artifact: stagingArtifact,
      index: index,
      storageRootId: '${temp.path}/staging',
      expectedLength: prefix.length,
      validators: const Validators(etag: 'staging-v1'),
      totalLength: prefix.length + 16,
      releaseBacking: () => released++,
      transferStaging: true,
    );

    expect(session.index, isNull,
        reason: 'transfer staging must not acquire exact-cache authority');
    expect(session.hasBorrowedPartialBacking, isTrue);
    expect(session.hasBorrowedDurableSpool, isFalse);

    final writer = session.acquireWriter();
    final suffix = List<int>.filled(16, 2);
    await session.append(writer, prefix.length, suffix);
    await session.pause(writer);
    final physicalRecord = await index.getPhysicalPartial(physical);
    expect(physicalRecord, isNotNull);
    expect(physicalRecord!.bytes, prefix.length + suffix.length);
    expect(await index.get(id.key), isNull,
        reason: 'partial growth may update only physical-partial metadata');

    final sealingWriter = session.acquireWriter();
    await session.seal(
      sealingWriter,
      expectedLength: prefix.length + suffix.length,
    );
    await session.promote();
    expect(session.state, DownloadState.promoted);
    expect(await index.get(id.key), isNull,
        reason: 'staging promotion is not a durable exact binding');
    expect(session.hasBorrowedDurableSpool, isFalse);

    await session.dispose();
    expect(released, 1);
  });

  test('owned partial checkpoint restores without eager whole-body checksum',
      () async {
    await session.dispose();
    final id = _idWithSource('owned-partial-checkpoint');
    final physical = PhysicalMediaId.canonical('owned-partial-checkpoint');
    final partialPath = '${temp.path}/recoverable/partial/page.webp';
    final finalPath = '${temp.path}/recoverable/final/page.webp';
    final first = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: Artifact(
        partialPath: partialPath,
        finalPath: finalPath,
      ),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    await first.restore();
    await first.bindResponse(
      validators: const Validators(etag: 'checkpoint-v1'),
      totalLength: 8192,
    );
    final writer = first.acquireWriter();
    final prefix = List<int>.generate(4096, (index) => index & 0xff);
    await first.append(writer, 0, prefix);
    await first.pause(writer);
    await first.dispose();

    session = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: Artifact(
        partialPath: partialPath,
        finalPath: finalPath,
      ),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    final restored = await session.restore(
      verifyPromotedChecksum: false,
      preferOwnedPartialCheckpoint: true,
    );

    expect(restored.state, DownloadState.idle);
    expect(restored.committedLength, prefix.length);
    expect(session.artifact.checksum, isEmpty,
        reason: 'owned mutable staging defers whole-body CRC until seal');
    expect(session.validators.etag, 'checkpoint-v1');
    expect(session.totalLength, 8192);
  });

  test('owned checkpoint recovers an unpaused crash tail without meta bytes',
      () async {
    await session.dispose();
    final id = _idWithSource('owned-crash-tail');
    final physical = PhysicalMediaId.canonical('owned-crash-tail');
    final partialPath = '${temp.path}/crash-tail/partial/page.webp';
    final finalPath = '${temp.path}/crash-tail/final/page.webp';
    final first = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: Artifact(partialPath: partialPath, finalPath: finalPath),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    await first.restore();
    await first.bindResponse(
      validators: const Validators(etag: 'crash-tail-v1'),
      totalLength: 8192,
    );
    final writer = first.acquireWriter();
    final prefix = List<int>.generate(4096, (index) => (index * 3) & 0xff);
    await first.append(writer, 0, prefix);
    // Simulate process death after the body flushes but before pause() refreshes
    // the sidecar with a `bytes` field. Artifact disposal closes the sink only.
    await first.artifact.dispose();

    session = DownloadSession(
      id: id,
      physicalId: physical,
      artifact: Artifact(partialPath: partialPath, finalPath: finalPath),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    final restored = await session.restore(
      verifyPromotedChecksum: false,
      preferOwnedPartialCheckpoint: true,
    );

    expect(restored.committedLength, prefix.length);
    expect(session.validators.etag, 'crash-tail-v1');
    expect(session.totalLength, 8192);
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

  test('append failure retires a session writer when the sink cannot open',
      () async {
    final writer = session.acquireWriter();
    final partialDirectory = Directory(
      File(session.artifact.partialPath).parent.path,
    );
    await partialDirectory.delete(recursive: true);
    await File(partialDirectory.path).writeAsString('not a directory');

    await expectLater(
      session.append(writer, 0, <int>[1, 2, 3]),
      throwsA(isNotNull),
    );

    expect(session.hasWriter, isFalse);
    expect(session.state, DownloadState.failed);
    expect(session.artifact.hasOpenWriter, isFalse);
  });

  test('unscoped completion cannot acquire a writer during an active run',
      () async {
    final writer = session.acquireWriter();
    await session.bindResponse(
      validators: const Validators(),
      totalLength: 3,
      validatorRequestUri: session.id.canonicalUri,
    );
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.pause(writer);

    final run = session.beginRun();
    await expectLater(
      DownloadJob.completeWithoutTransport(session: session),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );
    session.endRun(run);
  });

  test('unscoped promotion cannot mutate an active run', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.seal(writer, expectedLength: 3);

    final run = session.beginRun();
    await expectLater(
      session.promote(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );
    session.endRun(run);
  });

  test('writer admission is blocked while restore is synchronizing cache',
      () async {
    final index = _BlockingCacheIndex();
    await index.open();
    final partialPath = '${temp.path}/restore-race/partial/page.webp';
    await (File(partialPath)..createSync(recursive: true)).writeAsBytes(<int>[1]);
    final raced = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partialPath,
        finalPath: '${temp.path}/restore-race/cache/page.webp',
      ),
      clock: FakeMonoClock(),
      index: index,
    );
    final restoring = raced.restore();
    await index.getStarted.future;

    final observations = <DownloadSnapshot>[];
    void listener(DownloadSnapshot snapshot) {
      observations.add(snapshot);
    }
    raced.addSnapshotListener(listener);
    expect(observations, hasLength(1));
    expect(raced.canEvict, isFalse);
    final demandLease = raced.attachDemand(scopeId: 'reader', priority: 1000);
    expect(raced.effectivePriority, equals(1000));
    demandLease.detach();
    final projection = DownloadIngressProjection(
      scopeId: 'reader-projection',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    final attaching = raced.attachSynchronizedIngressProjection(projection);
    expect(attaching, isA<Future<void>>());
    expect(
      raced.acquireWriter,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );
    await expectLater(
      raced.dispose(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );
    await expectLater(
      raced.reset(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );

    index.releaseGet.complete();
    await restoring;
    await attaching;
    raced.removeSnapshotListener(listener);
    await raced.dispose();
    await index.close();
  });

  test('empty session attachIngressProjection succeeds without sessionBusy', () async {
    final session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/empty-test/partial/page.webp',
        finalPath: '${temp.path}/empty-test/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    expect(session.committedLength, equals(0));
    final demandLease = session.attachDemand(scopeId: 'reader', priority: 1000);
    expect(session.effectivePriority, equals(1000));
    final projection = DownloadIngressProjection(
      scopeId: 'reader-empty-projection',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    session.attachIngressProjection(projection);
    expect(session.snapshot.ingressProjectionCount, equals(1));

    demandLease.detach();
    projection.detach();
    await session.dispose();
  });

  test('empty projection attached after reset inherits current physical epoch',
      () async {
    final session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/post-reset-attach/partial/page.webp',
        finalPath: '${temp.path}/post-reset-attach/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    await session.reset();
    expect(session.epoch, isNot(const SourceEpoch(0)));

    final projection = DownloadIngressProjection(
      scopeId: 'reader-post-reset-projection',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    session.attachIngressProjection(projection);
    expect(projection.snapshot.epoch, session.epoch);

    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    expect(projection.snapshot.failure, isNull);
    expect(projection.snapshot.length, 3);
    await session.pause(writer);

    projection.detach();
    await session.dispose();
  });

  test('attachIngressProjection preserves an existing same-epoch prefix',
      () async {
    final session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/prefilled-attach/partial/page.webp',
        finalPath: '${temp.path}/prefilled-attach/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    final ingress = Ingress(factory: _TestSourceFactory(), maxBytes: 1024);
    const prefix = 'RIFF....WEBPpayload';
    ingress.append(
      epoch: session.epoch,
      offset: 0,
      bytes: prefix.codeUnits,
    );
    final projection = DownloadIngressProjection(
      scopeId: 'reader-prefilled-projection',
      ingress: ingress,
    );

    session.attachIngressProjection(projection);

    expect(projection.snapshot.epoch, session.epoch);
    expect(projection.snapshot.length, prefix.length);
    expect(projection.source, isNotNull);

    projection.detach();
    ingress.dispose();
    await session.dispose();
  });

  test('stale projection seal retires writer without failing physical body',
      () async {
    final session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/stale-seal/partial/page.webp',
        finalPath: '${temp.path}/stale-seal/cache/page.webp',
      ),
      clock: FakeMonoClock(),
    );
    await session.restore();
    final projection = DownloadIngressProjection(
      scopeId: 'reader-stale-seal',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    session.attachIngressProjection(projection);
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3, 4]);

    projection.reset(const SourceEpoch(1));
    await expectLater(
      session.seal(writer, expectedLength: 4),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );

    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.hasWriter, isFalse);
    expect(session.artifact.state, ArtifactState.sealed);

    await session.restore();
    expect(session.state, DownloadState.idle);
    expect(session.artifact.state, ArtifactState.partial);
    expect(session.committedLength, 4);
    expect(projection.snapshot.failure, isNull);
    expect(projection.snapshot.epoch, session.epoch);

    projection.detach();
    await session.dispose();
  });

  test('beginRun succeeds while attachSynchronizedIngressProjection is active', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.pause(writer);

    final projection = DownloadIngressProjection(
      scopeId: 'reader-pending-run',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    final attaching = session.attachSynchronizedIngressProjection(projection);
    expect(attaching, isA<Future<void>>());

    final run = session.beginRun();
    expect(session.activeRun, isTrue);
    session.endRun(run);

    await attaching;
    session.detachIngressProjection(projection.scopeId);
  });

  test('registry identity snapshots include aliases and unmaterialized bindings', () async {
    final registry = DownloadRegistry(layout: CacheLayout('${temp.path}/identity-snapshot'),
      clock: FakeMonoClock());
    addTearDown(registry.dispose);
    DownloadId idFor(String page) => DownloadId(content: ContentId(
      sourceId: 'source', comicId: 'comic', chapterId: 'chapter', pageId: page),
      sourceRevision: 'r1', canonicalUri: Uri.parse('https://example.test/$page'));
    final anchor = registry.get(idFor('anchor'));
    final alias = idFor('alias');
    registry.aliasPhysical(id: alias, target: anchor.id);
    final before = registry.knownIds;
    final bound = idFor('bound');
    registry.bindPhysicalMedia(id: bound, physicalId: PhysicalMediaId.canonical('fixture'));
    expect(before, {anchor.id, alias});
    expect(registry.knownIds, {anchor.id, alias, bound});
    expect(() => before.clear(), throwsUnsupportedError);
    expect(registry.sessions, hasLength(1));
    expect(registry.find(bound), isNull);
    await registry.dispose();
    expect(registry.knownIds, isEmpty);
    expect(before, {anchor.id, alias});
  });

  test('physical aliases cannot be rebound to a different session', () {
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/aliases'),
      clock: FakeMonoClock(),
    );
    addTearDown(registry.dispose);
    DownloadId idWithPage(String pageId) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
        );
    final first = registry.get(idWithPage('alias-first'));
    final logical = idWithPage('alias-logical');
    final second = registry.get(idWithPage('alias-second'));

    registry.aliasPhysical(id: logical, target: first.id);
    registry.aliasPhysical(id: logical, target: first.id);
    expect(
      () => registry.aliasPhysical(id: logical, target: second.id),
      throwsStateError,
    );
    expect(registry.resolvePhysicalId(logical), first.id);
  });

  test('canonical physical binding joins exact versions before session creation',
      () async {
    final trace = MemoryTraceSink();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/canonical-registry'),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    addTearDown(registry.dispose);
    DownloadId idWithPage(String pageId) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic-$pageId',
            chapterId: 'chapter-$pageId',
            pageId: pageId,
          ),
          sourceRevision: 'revision-$pageId',
          canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
        );
    final first = idWithPage('version-a');
    final second = idWithPage('version-b');
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u00007',
    );

    registry.bindPhysicalMedia(id: first, physicalId: physical);
    registry.bindPhysicalMedia(id: second, physicalId: physical);
    final firstSession = registry.get(first);
    final secondSession = registry.get(second);
    final demand = firstSession.attachDemand(scopeId: 'reader', priority: 1000);
    addTearDown(demand.detach);
    await firstSession.restore();

    final demandTrace = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.demandApplied,
    );
    expect(demandTrace.identityHash, registry.layout.tokenForPhysical(physical));
    expect(demandTrace.identityHash, isNot(first.key));
    expect(firstSession.sessionId, 'download:${demandTrace.identityHash}');
    expect(secondSession, same(firstSession));
    expect(firstSession.physicalId, physical);
    expect(firstSession.id, first);
    expect(
      firstSession.artifact.partialPath,
      registry.layout.artifactForPhysical(physical).partialPath,
    );
    final writer = firstSession.acquireWriter();
    expect(secondSession.hasWriter, isTrue);
    expect(secondSession.acquireWriter, throwsA(isA<Failure>()));
    await firstSession.pause(writer);
  });

  test('canonical partial and promoted artifact survive without exact carrier',
      () async {
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'version-a',
        chapterId: 'chapter-a',
        pageId: 'page-a',
      ),
      sourceRevision: 'revision-a',
      canonicalUri: Uri.parse('https://example.test/a.webp'),
    );
    final physical = PhysicalMediaId.canonical(
      'family\u0000chapter\u0000segment\u000011',
    );
    final layout = CacheLayout('${temp.path}/canonical-persistence');
    final canonical = DownloadSession(
      id: exact,
      physicalId: physical,
      artifact: layout.artifactForPhysical(physical),
      clock: FakeMonoClock(),
      index: index,
      storageRootId: layout.root,
    );
    addTearDown(() async {
      if (canonical.state != DownloadState.disposed) {
        await canonical.dispose();
      }
    });
    await canonical.restore();
    await canonical.bindResponse(
      validators: const Validators(),
      totalLength: 4,
    );
    final writer = canonical.acquireWriter();
    await canonical.append(writer, 0, <int>[1, 2, 3, 4]);
    await canonical.pause(writer);

    expect(await index.get(exact.key), isNull);
    expect(
      (await index.getPhysicalPartial(physical))?.path,
      canonical.artifact.partialPath,
    );

    final sealingWriter = canonical.acquireWriter();
    await canonical.seal(sealingWriter, expectedLength: 4);
    await canonical.promote();
    final exactReady = await index.get(exact.key);
    expect(exactReady?.state, CacheState.ready);
    expect(await index.getPhysicalPartial(physical), isNull);
    final physicalReady = await index.getPhysicalMediaArtifact(physical);
    expect(physicalReady?.artifactId, exactReady?.effectiveArtifactId);

    await index.remove(exact.key);
    expect(await index.get(exact.key), isNull);
    expect(
      (await index.getPhysicalMediaArtifact(physical))?.artifactId,
      physicalReady?.artifactId,
    );

    final otherExact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'version-b',
        chapterId: 'chapter-b',
        pageId: 'page-b',
      ),
      sourceRevision: 'revision-b',
      canonicalUri: Uri.parse('https://example.test/b.webp'),
    );
    final reopened = DownloadSession(
      id: otherExact,
      physicalId: physical,
      artifact: layout.artifactForPhysical(physical),
      clock: FakeMonoClock(),
      index: index,
      storageRootId: layout.root,
    );
    addTearDown(() async {
      if (reopened.state != DownloadState.disposed) await reopened.dispose();
    });
    await reopened.restore();
    expect(reopened.state, DownloadState.promoted);
    expect(reopened.committedLength, 4);
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

  test('destructive reset deletes a promoted final while ordinary reset preserves it',
      () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.seal(writer, expectedLength: 3);
    await session.promote();
    final finalFile = File(session.artifact.finalPath);
    expect(await finalFile.exists(), isTrue);

    await session.reset();
    expect(await finalFile.exists(), isTrue);
    expect(session.committedLength, 3);

    await session.reset(deleteFinalArtifact: true);
    expect(await finalFile.exists(), isFalse);
    expect(session.committedLength, 0);
    expect(session.state, DownloadState.idle);
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

  test('reset reentrancy cannot publish an old append after epoch advance',
      () async {
    final projection = DownloadIngressProjection(
      scopeId: 'reentrant-reset',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    session.attachIngressProjection(projection);
    Future<void>? resetting;
    var resetStarted = false;
    projection.addSourceListener((snapshot) {
      if (!resetStarted && snapshot.length >= 12) {
        resetStarted = true;
        resetting = session.reset();
      }
    });

    final writer = session.acquireWriter();
    await expectLater(
      session.append(writer, 0, 'RIFF....WEBP'.codeUnits),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
    await resetting;

    expect(session.state, DownloadState.idle);
    expect(session.contentKind, ContentKind.unknown);
    expect(session.hasWriter, isFalse);
    expect(session.committedLength, 0);
  });

  test('promotion failure retires the sealed writer lifecycle', () async {
    await File('${temp.path}/cache').writeAsString('not a directory');
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.seal(writer, expectedLength: 3);

    await expectLater(session.promote(), throwsA(isA<FileSystemException>()));

    expect(session.state, DownloadState.failed);
    expect(session.hasWriter, isFalse);
    expect(session.artifact.hasOpenWriter, isFalse);
  });

  test('seal validation failure retires the writer lifecycle', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);

    await expectLater(
      session.seal(writer, expectedLength: 3, expectedChecksum: '00000000'),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.checksumMismatch,
      )),
    );
    expect(session.hasWriter, isFalse);
    expect(session.state, DownloadState.failed);
    expect(session.artifact.hasOpenWriter, isFalse);

    final retry = session.acquireWriter();
    await session.fail(retry, const Failure(
      code: ErrorCode.cancelled,
      message: 'test cleanup',
    ));
  });

  test('promotion rejects an explicit foreign final sidecar', () async {
    final foreign = Artifact(
      partialPath: session.artifact.partialPath,
      finalPath: session.artifact.finalPath,
    );
    await foreign.restore();
    await foreign.writeMeta(<String, Object?>{
      'downloadKey': 'foreign-download',
    });
    await foreign.append(0, <int>[1, 2, 3]);
    await foreign.seal(expectedLength: 3);
    await foreign.promote();
    await foreign.dispose();

    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.seal(writer, expectedLength: 3);

    await expectLater(
      session.promote(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    expect(session.state, DownloadState.failed);
    expect(session.hasWriter, isFalse);
    expect(
      jsonDecode(await File(session.artifact.finalMetaPath).readAsString())
          ['downloadKey'],
      'foreign-download',
    );
  });

  test('projection failure after artifact seal retires the writer lifecycle',
      () async {
    final projection = DownloadIngressProjection(
      scopeId: 'disposed-projection',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    session.attachIngressProjection(projection);
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    projection.ingress.dispose();

    await expectLater(
      session.seal(writer, expectedLength: 3),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.invalidState,
      )),
    );

    expect(session.state, DownloadState.failed);
    expect(session.hasWriter, isFalse);
    expect(session.artifact.state, ArtifactState.sealed);
    expect(session.artifact.hasOpenWriter, isFalse);
  });

  test('cancelled restore remains idle and resumable', () async {
    await session.restore();
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3, 4]);
    await session.pause(writer);
    final committedBefore = session.committedLength;
    final control = CancelToken()..cancel();

    await expectLater(
      session.restore(control: control),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );

    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.committedLength, committedBefore);
    expect(session.artifact.state, ArtifactState.partial);
    expect(session.hasWriter, isFalse);

    final restored = await session.restore();
    expect(restored.state, DownloadState.idle);
    expect(restored.committedLength, committedBefore);
  });

  test('in-flight scheduler cancellation interrupts generic artifact rehash',
      () async {
    await session.dispose();
    final partialPath = '${temp.path}/cancel-rehash/partial/page.webp';
    final finalPath = '${temp.path}/cancel-rehash/final/page.webp';
    final partial = File(partialPath);
    await partial.parent.create(recursive: true);
    final handle = await partial.open(mode: FileMode.write);
    await handle.truncate(256 * 1024 * 1024);
    await handle.close();

    session = DownloadSession(
      id: _idWithSource('controlled-rehash-cancel'),
      artifact: Artifact(partialPath: partialPath, finalPath: finalPath),
      clock: FakeMonoClock(),
      initiallyDemanded: false,
    );
    final control = CancelToken(priority: 800);
    final restoring = session.restore(
      verifyPromotedChecksum: false,
      preferOwnedPartialCheckpoint: true,
      ownedCheckpointProbeOnly: true,
      control: control,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    control.cancel();

    await expectLater(
      restoring,
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    ).timeout(const Duration(seconds: 1));

    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.artifact.state, ArtifactState.empty);
    expect(session.committedLength, 0);
    expect(session.hasWriter, isFalse);

    await partial.delete();
    final retried = await session.restore();
    expect(retried.state, DownloadState.idle);
    expect(retried.committedLength, 0);
  });

  test('restore failure cannot leave the session advertising old promotion',
      () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3, 4]);
    await session.seal(writer, expectedLength: 4);
    await session.promote();

    await File(session.artifact.finalPath).writeAsBytes(<int>[4, 3, 2, 1]);

    await expectLater(
      session.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );

    expect(session.state, DownloadState.failed);
    expect(session.snapshot.failure?.code, ErrorCode.artifactCorruption);
    expect(session.hasWriter, isFalse);
    expect(session.artifact.state, ArtifactState.empty);
    expect(session.artifact.committedLength, 0);
    expect(
      await File(session.artifact.finalPath).readAsBytes(),
      <int>[4, 3, 2, 1],
    );
  });

  test('registry does not retire a session while projection attachment is pending',
      () async {
    final clock = FakeMonoClock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/registry-pending-cache'),
      clock: clock,
    );
    final physical = downloads.get(_id());
    await physical.restore();
    final writer = physical.acquireWriter();
    await physical.append(writer, 0, <int>[1, 2, 3]);
    await physical.pause(writer);
    physical.detach();

    final projection = DownloadIngressProjection(
      scopeId: 'registry-pending',
      ingress: Ingress(
        factory: _TestSourceFactory(),
        maxBytes: 1024,
      ),
    );
    final attaching = physical.attachSynchronizedIngressProjection(projection);

    expect(physical.canEvict, isFalse);
    expect(downloads.takeIdlePhysical(physical.id), isNull);
    physical.detachIngressProjection(projection.scopeId);
    await expectLater(
      attaching,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );

    final retired = downloads.takeIdlePhysical(physical.id);
    expect(retired, same(physical));
    await retired!.dispose();
    await downloads.dispose();
  });

  test('detaching a pending projection invalidates its late replay', () async {
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.pause(writer);

    final projection = DownloadIngressProjection(
      scopeId: 'pending-detach',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024),
    );
    final attaching = session.attachSynchronizedIngressProjection(projection);

    expect(session.canEvict, isFalse);
    expect(await session.resetIfIdle(removeCacheRecord: false), isFalse);
    expect(
      session.dispose,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );
    expect(session.detachIngressProjection(projection.scopeId), isTrue);

    await expectLater(
      attaching,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );
    expect(session.canEvict, isTrue);
  });

  test('dispose invalidates a completion awaiting cache synchronization',
      () async {
    final index = _BlockingCacheIndex();
    await index.open();
    final raced = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/raced.webp',
        finalPath: '${temp.path}/cache/raced.webp',
      ),
      clock: FakeMonoClock(),
      index: index,
    );
    await raced.restore();

    final writer = raced.acquireWriter();
    await raced.append(writer, 0, <int>[1, 2, 3]);
    final sealing = raced.seal(writer, expectedLength: 3);
    await index.getStarted.future;

    final sealingExpectation = expectLater(
      sealing,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        anyOf(ErrorCode.invalidState, ErrorCode.staleEpoch),
      )),
    );
    final disposing = raced.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(raced.state, isNot(DownloadState.disposed));
    index.releaseGet.complete();
    await disposing;
    await sealingExpectation;
    expect(await index.delegate.get(_id().key), isNull);
    await index.close();
  });

  test('idle reset holds its lifecycle boundary through owner cleanup',
      () async {
    await session.restore();
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1, 2, 3]);
    await session.pause(writer);

    final entered = Completer<void>();
    final release = Completer<void>();
    final resetting = session.resetIfIdleAndRun<bool>(
      removeCacheRecord: false,
      operation: () async {
        entered.complete();
        await release.future;
        expect(
          () => session.beginRun(),
          throwsA(isA<Failure>().having(
            (error) => error.code,
            'code',
            ErrorCode.sessionBusy,
          )),
        );
        return true;
      },
    );

    await entered.future;
    release.complete();
    expect(await resetting, isTrue);
    final run = session.beginRun();
    session.endRun(run);
  });

  test('reset boundary removes a cache row written by stale synchronization',
      () async {
    final index = _BlockingPutCacheIndex();
    await index.open();
    final raced = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/stale-sync.webp',
        finalPath: '${temp.path}/cache/stale-sync.webp',
      ),
      clock: FakeMonoClock(),
      index: index,
    );
    await raced.restore();

    final writer = raced.acquireWriter();
    await raced.append(writer, 0, <int>[1, 2, 3]);
    final pausing = raced.pause(writer);
    await index.putStarted.future;

    final resetting = raced.resetIfIdle(removeCacheRecord: false);
    index.releasePut.complete();

    await expectLater(
      pausing,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
    expect(await resetting, isTrue);
    expect(await index.delegate.get(_id().key), isNull);

    await raced.dispose();
    await index.close();
  });

  test('stale synchronization cleanup accepts SQLite artifact-id normalization',
      () async {
    final index = _BlockingPutCacheIndex(SqliteIndex.memory());
    await index.open();
    final raced = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/sqlite-stale-sync.webp',
        finalPath: '${temp.path}/cache/sqlite-stale-sync.webp',
      ),
      clock: FakeMonoClock(),
      index: index,
    );
    await raced.restore();

    final writer = raced.acquireWriter();
    await raced.append(writer, 0, <int>[1, 2, 3]);
    final pausing = raced.pause(writer);
    await index.putStarted.future;

    final resetting = raced.resetIfIdle(removeCacheRecord: false);
    index.releasePut.complete();

    await expectLater(
      pausing,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
    expect(await resetting, isTrue);
    expect(await index.delegate.get(_id().key), isNull);

    await raced.dispose();
    await index.close();
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

  test('Reader ingress replay queue is bounded and priority ordered without role gates',
      () async {
    Future<DownloadSession> resident(String name) async {
      final current = DownloadSession(
        id: _idWithSource(name),
        artifact: Artifact(
          partialPath: '${temp.path}/partial/$name.webp',
          finalPath: '${temp.path}/cache/$name.webp',
        ),
        clock: FakeMonoClock(),
      );
      await current.restore();
      final bytes = <int>[...'RIFF....WEBP$name'.codeUnits];
      current.beginResidentImmutableIngress(
        validators: const Validators(),
        totalLength: bytes.length,
        bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      );
      current.appendResidentImmutableIngress(0, bytes);
      current.sealResidentImmutableIngress();
      return current;
    }

    final blocker = await resident('replay-blocker');
    final low = await resident('replay-low');
    final high = await resident('replay-high');
    addTearDown(() async {
      await blocker.dispose();
      await low.dispose();
      await high.dispose();
    });
    final blockerDemand = blocker.attachDemand(scopeId: 'reader', priority: 500);
    final lowDemand = low.attachDemand(scopeId: 'reader', priority: 100);
    final highDemand = high.attachDemand(scopeId: 'reader', priority: 900);
    addTearDown(() {
      blockerDemand.detach();
      lowDemand.detach();
      highDemand.detach();
    });

    final blockerRelease = Completer<void>();
    final highRelease = Completer<void>();
    final starts = <DownloadId>[];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-bounded-replay',
      maxActiveReplays: 1,
      residentReplaySourceWithControl:
          (physical, endExclusive, {required control}) async {
        starts.add(physical.id);
        if (physical.id == blocker.id) {
          await blockerRelease.future;
        } else if (physical.id == high.id) {
          await highRelease.future;
        }
        control.throwIfCancelled();
        final bytes = <int>[...'RIFF....WEBP${physical.id.content.pageId}'.codeUnits];
        return Stream<List<int>>.value(
          bytes.sublist(0, endExclusive.clamp(0, bytes.length).toInt()),
        );
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    ingresses.get(blocker);
    await Future<void>.delayed(Duration.zero);
    expect(starts, <DownloadId>[blocker.id]);

    ingresses.get(low);
    ingresses.get(high);
    await Future<void>.delayed(Duration.zero);
    expect(starts, <DownloadId>[blocker.id]);

    blockerRelease.complete();
    while (starts.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(starts[1], high.id,
        reason: 'pending replay order follows demand priority, not page-role thresholds');
    expect(starts, isNot(contains(low.id)));

    highRelease.complete();
    await ingresses.settled(low.id);
    expect(starts, <DownloadId>[blocker.id, high.id, low.id]);
  });

  test('deferred READY and hot partial share same-turn replay admission rank',
      () async {
    final resident = DownloadSession(
      id: _idWithSource('same-turn-resident'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/same-turn-resident.webp',
        finalPath: '${temp.path}/cache/same-turn-resident.webp',
      ),
      clock: FakeMonoClock(),
    );
    final hot = DownloadSession(
      id: _idWithSource('same-turn-hot'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/same-turn-hot.webp',
        finalPath: '${temp.path}/cache/same-turn-hot.webp',
      ),
      clock: FakeMonoClock(),
    );
    addTearDown(() async {
      await resident.dispose();
      await hot.dispose();
    });
    await resident.restore();
    await hot.restore();

    final residentBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(128 * 1024, 1),
    ];
    resident.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: residentBytes.length,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: residentBytes.sublist(0, 64),
      residentReplayAccessMode: 'direct',
    );
    final hotBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(128 * 1024, 2),
    ];
    final hotWriter = hot.acquireWriter();
    await hot.append(hotWriter, 0, hotBytes);
    await hot.pause(hotWriter);

    final residentDemand =
        resident.attachDemand(scopeId: 'reader', priority: 820);
    final hotDemand = hot.attachDemand(scopeId: 'reader', priority: 1000);
    addTearDown(() {
      residentDemand.detach();
      hotDemand.detach();
    });

    final starts = <DownloadId>[];
    final hotRelease = Completer<void>();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024 * 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-same-turn-rank',
      maxActiveReplays: 1,
      residentReplayRangeSourceWithControl:
          (physical, start, endExclusive, {required control}) async {
        starts.add(physical.id);
        control.throwIfCancelled();
        return Stream<List<int>>.value(
          residentBytes.sublist(start, endExclusive),
        );
      },
      artifactReplayRangeSourceWithControl:
          (physical, start, endExclusive,
              {required chunkSize, required control}) async {
        starts.add(physical.id);
        await hotRelease.future;
        control.throwIfCancelled();
        return physical.artifact.readChunks(
          start: start,
          endExclusive: endExclusive,
          chunkSize: chunkSize,
        );
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    // The lower-ranked deferred READY arrives first in program order. Both
    // attach calls belong to the same synchronous Reader reconcile turn, so
    // admission must wait for that rank set rather than granting the first
    // free slot to the first callback.
    ingresses.get(resident);
    ingresses.get(hot);
    await Future<void>.delayed(Duration.zero);
    expect(starts, <DownloadId>[hot.id]);

    hotRelease.complete();
    await ingresses.settled(resident.id);
    expect(starts, <DownloadId>[hot.id, resident.id]);
  });

  test(
      'higher-priority source-less Reader entry reserves replay capacity for late READY',
      () async {
    Future<DownloadSession> hotPartial(String name, int fill) async {
      final session = DownloadSession(
        id: _idWithSource(name),
        artifact: Artifact(
          partialPath: '${temp.path}/partial/$name.webp',
          finalPath: '${temp.path}/cache/$name.webp',
        ),
        clock: FakeMonoClock(),
      );
      await session.restore();
      final writer = session.acquireWriter();
      await session.append(
        writer,
        0,
        <int>[
          ...'RIFF....WEBP'.codeUnits,
          ...List<int>.filled(512 * 1024, fill),
        ],
      );
      await session.pause(writer);
      return session;
    }

    final current = DownloadSession(
      id: _idWithSource('late-ready-current'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/late-ready-current.webp',
        finalPath: '${temp.path}/cache/late-ready-current.webp',
      ),
      clock: FakeMonoClock(),
    );
    await current.restore();
    final next = await hotPartial('late-ready-next', 1);
    final next2 = await hotPartial('late-ready-next2', 2);
    addTearDown(() async {
      await current.dispose();
      await next.dispose();
      await next2.dispose();
    });

    final currentDemand =
        current.attachDemand(scopeId: 'reader', priority: 1000);
    final nextDemand = next.attachDemand(scopeId: 'reader', priority: 820);
    final next2Demand = next2.attachDemand(scopeId: 'reader', priority: 800);
    addTearDown(() {
      currentDemand.detach();
      nextDemand.detach();
      next2Demand.detach();
    });

    final lowReleases = <DownloadId, Completer<void>>{
      next.id: Completer<void>(),
      next2.id: Completer<void>(),
    };
    addTearDown(() {
      for (final release in lowReleases.values) {
        if (!release.isCompleted) release.complete();
      }
    });
    final starts = <DownloadId>[];
    final currentBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(512 * 1024, 3),
    ];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024 * 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-late-ready-capacity',
      maxActiveReplays: 2,
      residentReplayRangeSourceWithControl:
          (physical, start, endExclusive, {required control}) async {
        starts.add(physical.id);
        control.throwIfCancelled();
        return Stream<List<int>>.value(
          currentBytes.sublist(start, endExclusive),
        );
      },
      artifactReplayRangeSourceWithControl:
          (physical, start, endExclusive,
              {required chunkSize, required control}) async {
        starts.add(physical.id);
        await lowReleases[physical.id]!.future;
        control.throwIfCancelled();
        return physical.artifact.readChunks(
          start: start,
          endExclusive: endExclusive,
          chunkSize: chunkSize,
        );
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    // The current page has no bytes yet while local preparation resolves its
    // durable READY body. Lower-ranked replay work may use spare capacity, but
    // must not consume every slot before that higher-ranked source can arrive.
    ingresses.get(current);
    ingresses.get(next);
    ingresses.get(next2);
    await Future<void>.delayed(Duration.zero);
    expect(starts, hasLength(1));
    expect(starts.single, next.id);

    current.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: currentBytes.length,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: currentBytes.sublist(0, 64),
      residentReplayAccessMode: 'direct',
    );
    for (var i = 0; i < 8 && !starts.contains(current.id); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // The READY replay may complete immediately and legitimately release its
    // slot to next2 before this assertion runs. The ownership contract is the
    // admission order: the reserved slot must let current start before next2,
    // not keep current artificially active after its replay has completed.
    expect(starts.take(2), <DownloadId>[next.id, current.id]);
    final next2Start = starts.indexOf(next2.id);
    if (next2Start >= 0) {
      expect(next2Start, greaterThan(starts.indexOf(current.id)));
    }

    lowReleases[next.id]!.complete();
    lowReleases[next2.id]!.complete();
    await ingresses.settled(next2.id);
  });

  test('source-less replay reservation releases when higher priority queues network',
      () async {
    final current = DownloadSession(
      id: _idWithSource('reserved-current-network'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/reserved-current-network.webp',
        finalPath: '${temp.path}/cache/reserved-current-network.webp',
      ),
      clock: FakeMonoClock(),
    );
    final low = DownloadSession(
      id: _idWithSource('reserved-low-replay'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/reserved-low-replay.webp',
        finalPath: '${temp.path}/cache/reserved-low-replay.webp',
      ),
      clock: FakeMonoClock(),
    );
    await current.restore();
    await low.restore();
    final writer = low.acquireWriter();
    await low.append(
      writer,
      0,
      <int>[
        ...'RIFF....WEBP'.codeUnits,
        ...List<int>.filled(128 * 1024, 1),
      ],
    );
    await low.pause(writer);
    addTearDown(() async {
      await current.dispose();
      await low.dispose();
    });
    final currentDemand =
        current.attachDemand(scopeId: 'reader', priority: 1000);
    final lowDemand = low.attachDemand(scopeId: 'reader', priority: 820);
    addTearDown(() {
      currentDemand.detach();
      lowDemand.detach();
    });

    final starts = <DownloadId>[];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024 * 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-reservation-release',
      maxActiveReplays: 1,
      artifactReplayRangeSourceWithControl:
          (physical, start, endExclusive,
              {required chunkSize, required control}) async {
        starts.add(physical.id);
        control.throwIfCancelled();
        return physical.artifact.readChunks(
          start: start,
          endExclusive: endExclusive,
          chunkSize: chunkSize,
        );
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    ingresses.get(current);
    ingresses.get(low);
    await Future<void>.delayed(Duration.zero);
    expect(starts, isEmpty);

    current.queue();
    for (var i = 0; i < 8 && starts.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(starts, <DownloadId>[low.id]);
    await ingresses.settled(low.id);
  });

  test('deferred durable resident hydrates only decoder-requested ranges',
      () async {
    final id = _idWithSource('deferred-durable-ready');
    final durable = DownloadSession(
      id: id,
      artifact: Artifact(
        partialPath: '${temp.path}/partial/deferred-ready.webp',
        finalPath: '${temp.path}/cache/deferred-ready.webp',
      ),
      clock: FakeMonoClock(),
    );
    addTearDown(durable.dispose);
    await durable.restore();
    final quantum = webpDecodePrefixQuantumBytesFor(id);
    final totalLength = quantum + 4096;
    final bytes = List<int>.filled(totalLength, 0);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    durable.bindResidentImmutableAuthority(
      validators: const Validators(etag: '"ready"'),
      totalLength: totalLength,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );

    expect(durable.state, DownloadState.promoted);
    expect(durable.committedLength, totalLength,
        reason: 'physical committed boundary is the immutable body authority');
    expect(durable.artifact.committedLength, 0,
        reason: 'READY authority must not be recopied into the session artifact');
    expect(durable.residentIngressDeferred, isTrue);

    final ranges = <(int, int)>[];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-deferred-ready',
      residentReplayRangeSourceWithControl:
          (physical, start, endExclusive, {required control}) async {
        expect(physical, same(durable));
        control.throwIfCancelled();
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    final projection = ingresses.get(durable);
    await ingresses.settled(id);
    expect(projection.snapshot.length, quantum);
    expect(projection.snapshot.sealed, isFalse);
    expect(ranges, <(int, int)>[(0, quantum)]);

    final secondTarget = quantum + 2048;
    await ingresses.ensureResidentPrefix(durable, secondTarget);
    expect(projection.snapshot.length, secondTarget);
    expect(projection.snapshot.sealed, isFalse);
    expect(ranges, <(int, int)>[(0, quantum), (quantum, secondTarget)]);

    await ingresses.ensureResidentPrefix(durable, totalLength);
    expect(projection.snapshot.length, totalLength);
    expect(projection.snapshot.sealed, isTrue);
    expect(ranges.last, (secondTarget, totalLength));
    expect(durable.artifact.committedLength, 0);
  });

  test('empty Reader projection hydrates when durable resident authority arrives later',
      () async {
    final id = _idWithSource('deferred-durable-late-authority');
    final durable = DownloadSession(
      id: id,
      artifact: Artifact(
        partialPath: '${temp.path}/partial/deferred-late.webp',
        finalPath: '${temp.path}/cache/deferred-late.webp',
      ),
      clock: FakeMonoClock(),
    );
    addTearDown(durable.dispose);
    await durable.restore();
    final quantum = webpDecodePrefixQuantumBytesFor(id);
    final totalLength = quantum + 4096;
    final bytes = List<int>.filled(totalLength, 0);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    final ranges = <(int, int)>[];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-deferred-late-authority',
      residentReplayRangeSourceWithControl:
          (physical, start, endExclusive, {required control}) async {
        expect(physical, same(durable));
        control.throwIfCancelled();
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    final projection = ingresses.get(durable);
    expect(projection.snapshot.length, 0);
    expect(projection.source, isNull);

    durable.bindResidentImmutableAuthority(
      validators: const Validators(etag: '\"ready-late\"'),
      totalLength: totalLength,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );

    for (var turn = 0; turn < 100 && projection.snapshot.length < quantum; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(projection.snapshot.length, quantum,
        reason: 'an already-attached empty Reader must observe 0->resident READY');
    expect(projection.decodePrefixQuantumBytes, localWebpDecodePrefixQuantumBytes,
        reason: 'late durable READY must switch decoder growth to physical-local quantum');
    expect(projection.snapshot.sourceReady, isTrue);
    expect(projection.snapshot.sealed, isFalse);
    expect(ranges, <(int, int)>[(0, quantum)]);
  });

  test('synchronized ingress projection attachment stages replays by priority and watermark',
      () async {
    final s1 = DownloadSession(
      id: _idWithSource('s1'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/p1.webp',
        finalPath: '${temp.path}/cache/p1.webp',
      ),
      clock: FakeMonoClock(),
    );
    final s2 = DownloadSession(
      id: _idWithSource('s2'),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/p2.webp',
        finalPath: '${temp.path}/cache/p2.webp',
      ),
      clock: FakeMonoClock(),
    );
    addTearDown(() async {
      await s1.dispose();
      await s2.dispose();
    });
    await s1.restore();
    await s2.restore();

    final w1 = s1.acquireWriter();
    await s1.append(w1, 0, <int>[...'RIFF....WEBP'.codeUnits, 1, 2]);
    await s1.seal(w1);
    final w2 = s2.acquireWriter();
    await s2.append(w2, 0, <int>[...'RIFF....WEBP'.codeUnits, 3, 4]);
    await s2.seal(w2);

    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-staged',
    );

    final d1 = s1.attachDemand(scopeId: 'reader', priority: 1000);
    final d2 = s2.attachDemand(scopeId: 'reader', priority: 700);
    addTearDown(() {
      d1.detach();
      d2.detach();
    });

    final proj1 = ingresses.get(s1);
    final proj2 = ingresses.get(s2);

    expect(proj1.snapshot.length, 0);
    expect(proj2.snapshot.length, 0);

    await ingresses.settled(s1.id);
    expect(proj1.snapshot.sourceReady, isTrue);

    await ingresses.settled(s2.id);
    expect(proj2.snapshot.sourceReady, isTrue);

    ingresses.dispose();
    sources.dispose();
  });


  test('late WebP Reader startup ignores transport-only playable evidence',
      () async {
    await session.dispose();
    final trace = MemoryTraceSink();
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/late-reader-local-probe.webp',
        finalPath: '${temp.path}/cache/late-reader-local-probe.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    await session.restore();
    final writer = session.acquireWriter();
    final body = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(2 * 1024 * 1024, 1),
    ];
    await session.append(writer, 0, body);

    const inheritedRequirement = 1024 * 1024;
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 0,
      sourceLength: remoteWebpDecodePrefixQuantumBytes,
      firstPlayablePrefixBytes: 0,
      firstFrameRequiredSourceLength: inheritedRequirement,
    );
    expect(
      session.transportFlowPlayableFloorBytes(
        unresolvedFloorBytes: remoteWebpDecodePrefixQuantumBytes,
      ),
      inheritedRequirement,
      reason: 'decoder evidence must remain available to transport flow control',
    );

    final projection = DownloadIngressProjection(
      scopeId: 'reader-local-probe',
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
    expect(firstReady.length, remoteWebpDecodePrefixQuantumBytes);
    final lateJoin = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'reader-ingress-late-join',
    );
    expect(lateJoin.payload['action'], 'decoder-probe-published');
    expect(lateJoin.payload['replayBasis'], 'reader-local-probe');
    expect(lateJoin.payload.containsKey('firstPlayablePrefixBytes'), isFalse);
    expect(lateJoin.payload.containsKey('firstFrameRequiredPrefixBytes'), isFalse);
    final sourceReady = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceReady,
    );
    expect(sourceReady.payload['length'], remoteWebpDecodePrefixQuantumBytes);
    expect(
      sourceReady.payload['readerLocalLength'],
      remoteWebpDecodePrefixQuantumBytes,
    );
    expect(sourceReady.payload['physicalCommittedLength'], body.length);

    await join;
    expect(projection.snapshot.length, body.length);
  });

  test('late WebP Reader skips prefixes already proven insufficient', () async {
    await session.dispose();
    final trace = MemoryTraceSink();
    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/late-retry-floor.webp',
        finalPath: '${temp.path}/cache/late-retry-floor.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    await session.restore();
    final writer = session.acquireWriter();
    final body = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(3 * 1024 * 1024, 1),
    ];
    await session.append(writer, 0, body);

    final hints = WebpDecodePrefixHints();
    final retryFloor = hints.recordNeedMoreData(
      id: session.id,
      frameIndex: 0,
      sourceLength: 800000,
    );
    expect(retryFloor, 1024 * 1024);

    final projection = DownloadIngressProjection(
      scopeId: 'reader-retry-floor',
      ingress: Ingress(
        factory: _TestSourceFactory(),
        maxBytes: 4 * 1024 * 1024,
      ),
    );
    final ready = Completer<IngressSnap>();
    projection.addSourceListener((snapshot) {
      if (snapshot.sourceReady && !ready.isCompleted) ready.complete(snapshot);
    });

    final join = session.attachSynchronizedIngressProjection(
      projection,
      preferredInitialProbeLength: hints.minimumBytes(session.id, 0),
    );
    final firstReady = await ready.future;
    expect(firstReady.length, retryFloor);
    final lateJoin = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'reader-ingress-late-join',
    );
    expect(lateJoin.payload['publishLength'], retryFloor);
    expect(lateJoin.payload['preferredInitialProbeLength'], retryFloor);
    expect(
      lateJoin.payload['replayBasis'],
      'reader-local-decoder-retry-floor',
    );

    await join;
    expect(projection.snapshot.length, body.length);
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

  test('sealed WebP late join keeps the source published to the decoder',
      () async {
    final writer = session.acquireWriter();
    final body = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(64 * 1024, 7),
    ];
    await session.append(writer, 0, body);
    await session.seal(writer, expectedLength: body.length);
    final projection = DownloadIngressProjection(
      scopeId: 'reader-complete-probe',
      ingress: Ingress(factory: _TestSourceFactory(), maxBytes: 1024 * 1024),
    );
    addTearDown(projection.ingress.dispose);
    EncodedSource? publishedSource;
    projection.addSourceListener((snapshot) {
      if (snapshot.sourceReady) publishedSource ??= projection.source;
    });

    await session.attachSynchronizedIngressProjection(projection);

    expect(publishedSource, isNotNull);
    expect(projection.source, same(publishedSource));
    expect(projection.source!.length, body.length);
    expect(projection.snapshot.sealed, isTrue);
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

  test('releasing a retired same-id physical session cannot remove the replacement source', () async {
    final clock = FakeMonoClock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/release-generation-cache'),
      clock: clock,
    );
    final id = _id();
    final first = downloads.get(id);
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-release-generation',
    );
    ingresses.get(first);
    final retired = downloads.takeIdlePhysical(id);
    expect(retired, same(first));

    final second = downloads.get(id);
    final replacement = ingresses.get(second);
    expect(sources.find(id), isNotNull);

    ingresses.release(first);
    expect(ingresses.find(id), same(replacement));
    expect(sources.find(id), isNotNull,
        reason: 'a late old-generation release must not erase the replacement source');

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
    await firstSession.bindResponse(
      validators: const Validators(),
      totalLength: body.length,
    );
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
      residentReplaySource: (_, __) async => controller.stream,
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

  test('static image metadata prefix exposes source canvas before decode', () {
    final prefix = <int>[
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      0x00, 0x00, 0x00, 0x0d,
      0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x02, 0xd0,
      0x00, 0x00, 0x02, 0xbc,
    ];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: prefix.length,
    );
    session.appendResidentImmutableIngress(0, prefix);

    expect(session.snapshot.contentKind, ContentKind.fallback);
    expect(session.snapshot.sourceCanvasWidth, 720);
    expect(session.snapshot.sourceCanvasHeight, 700);
  });

  test('JPEG dimension probe extends past the 64-byte metadata ABI', () {
    final jpeg = <int>[
      0xff, 0xd8,
      // APP1 pushes the SOF marker beyond the public 64-byte metadata prefix.
      0xff, 0xe1, 0x00, 0x82,
      ...List<int>.filled(128, 0),
      0xff, 0xc0, 0x00, 0x11, 0x08,
      0x0e, 0x10, // height = 3600
      0x04, 0x38, // width = 1080
      0x03,
      0x01, 0x11, 0x00,
      0x02, 0x11, 0x00,
      0x03, 0x11, 0x00,
    ];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: jpeg.length,
    );
    session.appendResidentImmutableIngress(0, jpeg.sublist(0, 64));

    expect(session.sourceMetadataPrefixLength, 64);
    expect(session.snapshot.sourceCanvasWidth, isNull);
    expect(session.snapshot.sourceCanvasHeight, isNull);

    session.appendResidentImmutableIngress(64, jpeg.sublist(64));

    expect(session.sourceMetadataPrefixLength, 64,
        reason: 'layout probing must not widen the public metadata prefix ABI');
    expect(session.snapshot.sourceCanvasWidth, 1080);
    expect(session.snapshot.sourceCanvasHeight, 3600);
  });

  test('source metadata prefix stays in-memory while receiving body grows',
      () async {
    final bytes = <int>[
      0x52, 0x49, 0x46, 0x46,
      0x80, 0x00, 0x00, 0x00,
      0x57, 0x45, 0x42, 0x50,
      ...List<int>.generate(256, (index) => index & 0xff),
    ];
    await session.bindResponse(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);

    expect(session.committedLength, bytes.length);
    expect(session.sourceMetadataPrefixLength, 64);
    expect(
      session.readSourceMetadataPrefix(),
      orderedEquals(bytes.sublist(0, 64)),
    );
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

  test('sealed resident source publishes probe before full late Reader replay',
      () async {
    final bytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled((1024 * 1024) - 12, 1),
    ];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress(
      deferFutureReaderIngress: true,
    );

    expect(session.residentBodyBacked, isTrue);
    expect(session.residentIngressDeferred, isTrue);

    final requestedRanges = <(int, int)>[];
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 2 * 1024 * 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident-probe-first',
      residentReplayRangeSource: (physical, start, endExclusive) async {
        expect(physical, same(session));
        requestedRanges.add((start, endExclusive));
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );

    final projection = ingresses.get(session);
    expect(projection.snapshot.length, 0);
    await ingresses.settled(session.id);

    expect(
      requestedRanges,
      <(int, int)>[(0, 256 * 1024)],
    );
    expect(projection.snapshot.sourceReady, isTrue);
    expect(projection.snapshot.length, 256 * 1024);
    expect(projection.snapshot.sealed, isFalse);

    await ingresses.ensureResidentPrefix(session, 512 * 1024);
    expect(
      requestedRanges,
      <(int, int)>[
        (0, 256 * 1024),
        (256 * 1024, 512 * 1024),
      ],
    );
    expect(projection.snapshot.length, 512 * 1024);
    expect(projection.snapshot.sealed, isFalse);

    ingresses.dispose();
    sources.dispose();
  });

  test('stale resident hydration failure yields to a new physical epoch', () async {
    final totalLength = 512 * 1024;
    final bytes = List<int>.filled(totalLength, 3);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: totalLength,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );

    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var hydrationAttempts = 0;
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident-stale-epoch',
      residentReplayRangeSource: (physical, start, endExclusive) async {
        expect(physical, same(session));
        hydrationAttempts++;
        if (hydrationAttempts == 1) {
          firstStarted.complete();
          await releaseFirst.future;
          throw const Failure(
            code: ErrorCode.source,
            message: 'retired resident replay failed late',
          );
        }
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      ingresses.dispose();
      sources.dispose();
    });

    final projection = ingresses.get(session);
    await firstStarted.future;
    final retiredEpoch = session.epoch;
    await session.reset(removeCacheRecord: false);
    expect(session.epoch, isNot(retiredEpoch));
    session.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: totalLength,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );
    releaseFirst.complete();

    for (var turn = 0;
        turn < 100 && projection.snapshot.length < 256 * 1024;
        turn++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(hydrationAttempts, 2);
    expect(projection.snapshot.epoch, session.epoch);
    expect(projection.snapshot.length, 256 * 1024);
    expect(projection.snapshot.failure, isNull);
  });

  test('running deferred resident hydration keeps one advanced target', () async {
    final totalLength = 768 * 1024;
    final bytes = List<int>.filled(totalLength, 2);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: totalLength,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress(
      deferFutureReaderIngress: true,
    );

    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final ranges = <(int, int)>[];
    var hydrationAttempts = 0;
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident-coalesced-target',
      residentReplayRangeSource: (physical, start, endExclusive) async {
        expect(physical, same(session));
        hydrationAttempts++;
        ranges.add((start, endExclusive));
        if (hydrationAttempts == 1) {
          firstStarted.complete();
          await releaseFirst.future;
        }
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      ingresses.dispose();
      sources.dispose();
    });

    final projection = ingresses.get(session);
    await firstStarted.future;
    final advanced = ingresses.ensureResidentPrefix(session, 512 * 1024);
    releaseFirst.complete();
    await advanced;
    for (var turn = 0;
        turn < 50 && projection.snapshot.length < 512 * 1024;
        turn++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(hydrationAttempts, 2);
    expect(
      ranges,
      <(int, int)>[
        (0, 256 * 1024),
        (256 * 1024, 512 * 1024),
      ],
    );
    expect(projection.snapshot.length, 512 * 1024);
    expect(projection.snapshot.failure, isNull);
  });

  test('failed deferred resident hydration does not self-retry', () async {
    final totalLength = 512 * 1024;
    final bytes = List<int>.filled(totalLength, 1);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: totalLength,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress(
      deferFutureReaderIngress: true,
    );

    final trace = MemoryTraceSink();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    var hydrationAttempts = 0;
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident-failure',
      traceSink: trace,
      residentReplayRangeSource: (physical, start, endExclusive) async {
        expect(physical, same(session));
        hydrationAttempts++;
        if (hydrationAttempts < 3) {
          throw const Failure(
            code: ErrorCode.source,
            message: 'resident replay failed',
          );
        }
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive));
      },
    );
    addTearDown(() {
      ingresses.dispose();
      sources.dispose();
    });

    final projection = ingresses.get(session);
    await ingresses.settled(session.id);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      hydrationAttempts,
      1,
      reason: 'one failed physical generation must wait for new authority '
          'instead of recursively hydrating the same range on the UI isolate',
    );
    expect(projection.snapshot.failure, isNotNull);
    await ingresses.ensureResidentPrefix(session, totalLength);
    expect(
      hydrationAttempts,
      1,
      reason: 'a larger request cannot retry the same failed physical epoch',
    );
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] == 'resident-ingress-hydration' &&
            event.payload['action'] == 'failed',
      ),
      hasLength(1),
    );
  });

  test('disposing an ingress registry cancels resident replay attachment', () async {
    final bytes = <int>[...'RIFF....WEBP'.codeUnits, 1, 2, 3, 4, 5, 6];
    session.beginResidentImmutableIngress(
      validators: const Validators(),
      totalLength: bytes.length,
    );
    session.appendResidentImmutableIngress(0, bytes);
    session.sealResidentImmutableIngress();

    final replayStarted = Completer<void>();
    final replayCancelled = Completer<void>();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'reader-resident-cancel',
      residentReplaySourceWithControl:
          (physical, endExclusive, {required control}) async {
        expect(physical, same(session));
        replayStarted.complete();
        try {
          await control.whenCancelled;
        } finally {
          replayCancelled.complete();
        }
        return Stream<List<int>>.value(bytes.sublist(0, endExclusive));
      },
    );

    final projection = ingresses.get(session);
    await replayStarted.future;
    ingresses.dispose();
    await replayCancelled.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    expect(projection.source, isNull);
    expect(session.snapshot.ingressProjectionCount, 0);
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

  test('restore rejects an active transport run', () {
    final run = session.beginRun();

    expect(
      session.restore,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.sessionBusy,
      )),
    );

    session.endRun(run);
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

  test('priority-only demand migration does not rebroadcast media snapshot', () {
    final snapshots = <DownloadSnapshot>[];
    session.addSnapshotListener(snapshots.add);
    expect(snapshots, hasLength(1));

    final lease = session.attachDemand(scopeId: 'reader', priority: 700);
    expect(snapshots, hasLength(2));

    lease.updatePriority(1000);

    expect(session.effectivePriority, 1000);
    expect(snapshots, hasLength(2));
    lease.detach();
    expect(snapshots, hasLength(3));
  });

  test('priority-only demand migration does not emit demand lifecycle trace', () async {
    final trace = MemoryTraceSink();
    final traced = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: '${temp.path}/trace-priority/page.webp.partial',
        finalPath: '${temp.path}/trace-priority/page.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    await traced.restore();
    addTearDown(() async {
      if (!traced.activeRun) {
        await traced.dispose();
      }
    });

    final lease = traced.attachDemand(scopeId: 'reader', priority: 700);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.demandApplied),
      hasLength(1),
    );

    lease.updatePriority(1000);

    expect(traced.effectivePriority, 1000);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.demandApplied),
      hasLength(1),
    );
    lease.detach();
  });

  test('diagnostic transport trace does not publish media snapshot', () {
    final snapshots = <DownloadSnapshot>[];
    session.addSnapshotListener(snapshots.add);
    expect(snapshots, hasLength(1));

    session.recordFlowControl(
      action: 'paused',
      targetFrames: 1,
      completedFrames: 1,
      networkCursor: 4096,
      demanded: true,
    );
    session.recordTransportReadPermit(
      action: 'released',
      reason: 'diagnostic-only',
      demanded: true,
    );
    session.recordResume(restarted: false, strategy: 'diagnostic-only');

    expect(snapshots, hasLength(1));
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

  test('explicit different download owner preserves the foreign partial', () async {
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
    await expectLater(
      session.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );

    expect(await partial.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(session.committedLength, 4);
    expect(session.validators.isEmpty, isTrue);
    expect(session.totalLength, isNull);
  });

  test('does not expose a promoted body claimed by another download', () async {
    await session.dispose();
    final partialPath = '${temp.path}/partial/page.webp';
    final finalPath = '${temp.path}/cache/page.webp';
    final foreign = Artifact(
      partialPath: partialPath,
      finalPath: finalPath,
    );
    await foreign.restore();
    await foreign.writeMeta(<String, Object?>{
      'downloadKey': 'different-owner',
    });
    await foreign.append(0, <int>[1, 2, 3, 4]);
    await foreign.seal(expectedLength: 4);
    await foreign.promote();
    await foreign.dispose();

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partialPath,
        finalPath: finalPath,
      ),
      clock: FakeMonoClock(),
    );

    await expectLater(
      session.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    // Ownership rejection happens before Artifact.restore binds the final
    // file, so a failed collision check cannot leave foreign bytes exposed as
    // this session's promoted state.
    expect(session.artifact.state, ArtifactState.empty);
    expect(session.artifact.committedLength, 0);
    expect(await File(finalPath).readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('does not promote a final body with a foreign crash-recovery sidecar',
      () async {
    await session.dispose();
    final partialPath = '${temp.path}/partial/page.webp';
    final finalPath = '${temp.path}/cache/page.webp';
    await File(finalPath).parent.create(recursive: true);
    await File(finalPath).writeAsBytes(<int>[1, 2, 3, 4]);
    await File(partialPath).parent.create(recursive: true);
    await File('$partialPath.meta').writeAsString(
      '{"downloadKey":"different-owner"}',
    );

    session = DownloadSession(
      id: _id(),
      artifact: Artifact(
        partialPath: partialPath,
        finalPath: finalPath,
      ),
      clock: FakeMonoClock(),
    );

    await expectLater(
      session.restore(),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.artifactCorruption,
      )),
    );
    expect(session.artifact.state, ArtifactState.empty);
    expect(session.artifact.committedLength, 0);
    expect(await File(finalPath).readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test('playable-prefix evidence strengthens within one physical generation',
      () async {
    const unresolvedFloor = 256 * 1024;
    expect(
      session.transportFlowPlayableFloorBytes(
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
      session.transportFlowPlayableFloorBytes(
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
      session.transportFlowPlayableFloorBytes(
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
      session.transportFlowPlayableFloorBytes(
        unresolvedFloorBytes: unresolvedFloor,
      ),
      384 * 1024,
    );

    await session.reset();
    expect(session.firstPlayablePrefixBytes, 0);
    expect(session.firstFrameRequiredPrefixBytes, 0);
    expect(session.decodedPrefixFrames, 0);
  });
  test('registry layoutResolver routes new artifacts to per-source roots', () {
      final clock = FakeMonoClock();
      final defaultLayout = CacheLayout('/tmp/registry-resolver-default');
      final customLayout = CacheLayout('/tmp/registry-resolver-custom');
      final downloads = DownloadRegistry(
        layout: defaultLayout,
        clock: clock,
        layoutResolver: (id) =>
            id.content.sourceId == 'venera:custom' ? customLayout : null,
      );
      addTearDown(downloads.dispose);

      final customSession = downloads.get(_idWithSource('venera:custom'));
      final defaultSession = downloads.get(_id());

      expect(customSession.artifact.partialPath,
          startsWith(customLayout.partialDir));
      expect(customSession.artifact.finalPath, startsWith(customLayout.finalDir));
      expect(defaultSession.artifact.partialPath,
          startsWith(defaultLayout.partialDir));
      expect(defaultSession.artifact.finalPath, startsWith(defaultLayout.finalDir));
      // Session identity stays derived from the download identity, not the
      // physical root.
      expect(
        downloads.find(customSession.id)!.sessionId,
        'download:${defaultLayout.tokenFor(customSession.id)}',
      );
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

DownloadId _idWithSource(String sourceId) => DownloadId(
      content: ContentId(
        sourceId: sourceId,
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );

final class _BlockingPutCacheIndex implements CacheIndex {
  _BlockingPutCacheIndex([CacheIndex? delegate])
      : delegate = delegate ?? MemIndex();

  final CacheIndex delegate;
  final Completer<void> putStarted = Completer<void>();
  final Completer<void> releasePut = Completer<void>();
  bool _blockNextPut = true;

  @override
  Future<void> open() => delegate.open();

  @override
  Future<CacheRec?> get(String key) => delegate.get(key);

  @override
  Future<List<CacheRec>> getMany(Iterable<String> keys) =>
      delegate.getMany(keys);

  @override
  Future<List<CacheRec>> list({CacheState? state}) => delegate.list(state: state);

  @override
  Future<void> put(CacheRec rec) async {
    if (_blockNextPut) {
      _blockNextPut = false;
      putStarted.complete();
      await releasePut.future;
    }
    await delegate.put(rec);
  }

  @override
  Future<void> remove(String key) => delegate.remove(key);

  @override
  Future<void> touch(String key, int touchedUs) =>
      delegate.touch(key, touchedUs);

  @override
  Future<int> totalBytes({CacheState? state}) =>
      delegate.totalBytes(state: state);

  @override
  Future<DownloadPlacement?> getPlacement({
    required String sourceId,
    required String comicId,
  }) => delegate.getPlacement(sourceId: sourceId, comicId: comicId);

  @override
  Future<List<DownloadPlacement>> listPlacements() => delegate.listPlacements();

  @override
  Future<void> putPlacement(DownloadPlacement placement) =>
      delegate.putPlacement(placement);

  @override
  Future<List<ExportPageBinding>> listExportPageBindings({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) =>
      delegate.listExportPageBindings(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
      );

  @override
  Future<void> putExportPageBindings(
    Iterable<ExportPageBinding> bindings,
  ) =>
      delegate.putExportPageBindings(bindings);

  @override
  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  }) => delegate.removePlacement(sourceId: sourceId, comicId: comicId);

  @override
  Future<bool> isPathOrArtifactReferenced({
    required String path,
    required String artifactId,
    String? excludingKey,
  }) =>
      delegate.isPathOrArtifactReferenced(
        path: path,
        artifactId: artifactId,
        excludingKey: excludingKey,
      );

  @override
  Future<void> close() => delegate.close();
}

final class _BlockingCacheIndex implements CacheIndex {
  final MemIndex delegate = MemIndex();
  final Completer<void> getStarted = Completer<void>();
  final Completer<void> releaseGet = Completer<void>();

  @override
  Future<void> open() => delegate.open();

  @override
  Future<CacheRec?> get(String key) async {
    if (!getStarted.isCompleted) {
      getStarted.complete();
      await releaseGet.future;
    }
    return delegate.get(key);
  }

  @override
  Future<List<CacheRec>> getMany(Iterable<String> keys) =>
      delegate.getMany(keys);

  @override
  Future<List<CacheRec>> list({CacheState? state}) => delegate.list(state: state);

  @override
  Future<void> put(CacheRec rec) => delegate.put(rec);

  @override
  Future<void> remove(String key) => delegate.remove(key);

  @override
  Future<void> touch(String key, int touchedUs) =>
      delegate.touch(key, touchedUs);

  @override
  Future<int> totalBytes({CacheState? state}) =>
      delegate.totalBytes(state: state);

  @override
  Future<DownloadPlacement?> getPlacement({
    required String sourceId,
    required String comicId,
  }) => delegate.getPlacement(sourceId: sourceId, comicId: comicId);

  @override
  Future<List<DownloadPlacement>> listPlacements() => delegate.listPlacements();

  @override
  Future<void> putPlacement(DownloadPlacement placement) =>
      delegate.putPlacement(placement);

  @override
  Future<List<ExportPageBinding>> listExportPageBindings({
    required String sourceId,
    required String comicId,
    required String chapterId,
  }) =>
      delegate.listExportPageBindings(
        sourceId: sourceId,
        comicId: comicId,
        chapterId: chapterId,
      );

  @override
  Future<void> putExportPageBindings(
    Iterable<ExportPageBinding> bindings,
  ) =>
      delegate.putExportPageBindings(bindings);

  @override
  Future<void> removePlacement({
    required String sourceId,
    required String comicId,
  }) => delegate.removePlacement(sourceId: sourceId, comicId: comicId);

  @override
  Future<bool> isPathOrArtifactReferenced({
    required String path,
    required String artifactId,
    String? excludingKey,
  }) =>
      delegate.isPathOrArtifactReferenced(
        path: path,
        artifactId: artifactId,
        excludingKey: excludingKey,
      );

  @override
  Future<void> close() => delegate.close();
}

final class _RecordingCacheMutationOwner implements DownloadCacheMutationOwner {
  final List<CacheState> syncedStates = <CacheState>[];
  int clearCalls = 0;

  @override
  Future<bool> beginDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  }) async =>
      false;

  @override
  Future<void> commitDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  }) async {}

  @override
  Future<void> abortDownloadCachePromotion(DownloadSession session) async {}

  @override
  Future<void> syncDownloadCache(
    DownloadSession session,
    CacheState state, {
    required SourceEpoch expectedEpoch,
    int? committedLength,
  }) async {
    syncedStates.add(state);
  }

  @override
  Future<void> clearDownloadCache(
    DownloadSession session, {
    required bool removeCacheRecord,
    required bool deleteFinalArtifact,
  }) async {
    clearCalls++;
  }
}

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
