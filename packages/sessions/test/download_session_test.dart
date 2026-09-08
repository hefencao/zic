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
    await session.dispose();
    expect(released, 1);
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
