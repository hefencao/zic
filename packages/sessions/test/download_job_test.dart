import 'dart:async';
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_job_test_');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  DownloadSession createSession() => DownloadSession(
        id: DownloadId(
          content: const ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: 'page',
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/page.webp'),
        ),
        artifact: Artifact(
          partialPath: '${temp.path}/partial/page.webp',
          finalPath: '${temp.path}/cache/page.webp',
        ),
        clock: FakeMonoClock(),
      );

  test('resumes a durable partial with matching validators', () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      1,
      2,
      3,
      4,
    ];
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 3,
      failAfterBytes: 5,
      validators: const Validators(etag: 'v1'),
    );

    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    expect(session.committedLength, 5);
    expect(session.artifact.hasOpenWriter, isFalse);

    final resumed = FakeTransport(
      bytes: bytes,
      chunkSize: 4,
      validators: const Validators(etag: 'v1'),
    );
    final result = await DownloadJob(transport: resumed, session: session).run();

    expect(result.state, DownloadState.promoted);
    expect(result.activeRun, isFalse);
    expect(result.contentKind, ContentKind.webp);
    expect(resumed.requests, hasLength(1));
    expect(resumed.requests.single.range?.start, 5);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('equivalent provider URI never reuses foreign resume validators', () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(128 * 1024, (index) => index & 0xff),
    ];
    final session = createSession();
    final oldProvider = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      failAfterBytes: 96 * 1024,
      validators: const Validators(etag: 'old-provider-v1'),
    );
    await expectLater(
      DownloadJob(transport: oldProvider, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    expect(session.validatorRequestUri, session.id.canonicalUri);

    final newUri = Uri.parse('https://example.test/new-version.webp');
    final newProvider = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      validators: const Validators(etag: 'new-provider-v2'),
    );
    final result = await DownloadJob(
      transport: newProvider,
      session: session,
      requestUri: newUri,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(newProvider.requests, hasLength(1));
    expect(
      newProvider.requests.single.range?.start,
      preservedLength - 64 * 1024,
    );
    expect(newProvider.requests.single.validators, isNull);
    expect(session.validatorRequestUri, newUri);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('validator mismatch catches up full body without shrinking partial', () async {
    final bytes = List<int>.generate(20, (index) => index);
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      failAfterBytes: 6,
      validators: const Validators(etag: 'v1'),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preserved = session.committedLength;

    final changed = FakeTransport(
      bytes: bytes,
      validators: const Validators(etag: 'v2'),
    );
    final result = await DownloadJob(transport: changed, session: session).run();

    expect(result.state, DownloadState.promoted);
    expect(changed.requests, hasLength(1));
    expect(changed.requests.single.range?.start, preserved);
    expect(changed.discardCount, 0);
    expect(result.epoch, const SourceEpoch(0));
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('validatorless restart keeps playable ingress while full body catches up', () async {
    final factory = _CountingSourceFactory();
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(256 * 1024, (index) => index & 0xff),
    ];
    final ingress = Ingress(factory: factory, maxBytes: 2 * 1024 * 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'validatorless',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/validatorless.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/validatorless.webp',
        finalPath: '${temp.path}/cache/validatorless.webp',
      ),
      clock: FakeMonoClock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      failAfterBytes: 96 * 1024,
      validators: const Validators(),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    final preservedRevision = projection.snapshot.revision;
    final sourceCreates = factory.createCount;
    expect(preservedLength, greaterThan(0));

    final resumed = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      validators: const Validators(),
    );
    final result = await DownloadJob(transport: resumed, session: session).run();

    expect(resumed.requests, hasLength(1));
    final expectedProbeStart = preservedLength - 64 * 1024;
    expect(resumed.requests.single.range?.start, expectedProbeStart);
    expect(resumed.requests.single.validators, isNull);
    expect(result.epoch, const SourceEpoch(0));
    expect(result.state, DownloadState.promoted);
    expect(factory.createCount, sourceCreates);
    expect(projection.snapshot.revision, greaterThan(preservedRevision));
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('validatorless range ignored reuses the same full response for catchup', () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(256 * 1024, (index) => index & 0xff),
    ];
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      failAfterBytes: 96 * 1024,
      validators: const Validators(),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;

    final ignoredRange = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      rangeSupported: false,
      validators: const Validators(),
    );
    final token = CancelToken(priority: 820);
    final result = await DownloadJob(
      transport: ignoredRange,
      session: session,
    ).run(cancel: token);

    expect(result.state, DownloadState.promoted);
    expect(token.restartCostBytes, bytes.length);
    expect(ignoredRange.requests, hasLength(1));
    expect(
      ignoredRange.requests.single.range?.start,
      preservedLength - 64 * 1024,
    );
    expect(ignoredRange.discardCount, 0);
    expect(result.epoch, const SourceEpoch(0));
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('large background full-body catchup defers after range is ignored',
      () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(2 * 1024 * 1024, (index) => index & 0xff),
    ];
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 16 * 1024,
      failAfterBytes: 1536 * 1024,
      validators: const Validators(),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    expect(preservedLength, greaterThanOrEqualTo(1024 * 1024));

    final ignoredRange = FakeTransport(
      bytes: bytes,
      chunkSize: 16 * 1024,
      rangeSupported: false,
      validators: const Validators(),
    );
    final deferredToken = CancelToken(priority: 800);
    await expectLater(
      DownloadJob(
        transport: ignoredRange,
        session: session,
        allowFullBodyCatchup: (_) => false,
      ).run(cancel: deferredToken),
      throwsA(isA<DownloadCatchupDeferred>()),
    );

    expect(deferredToken.restartCostBytes, 0);
    expect(ignoredRange.requests, hasLength(1));
    expect(
      ignoredRange.requests.single.range?.start,
      preservedLength - 64 * 1024,
    );
    expect(ignoredRange.discardCount, 1);
    expect(session.committedLength, preservedLength);
    expect(session.state, DownloadState.idle);

    final foreground = FakeTransport(
      bytes: bytes,
      chunkSize: 16 * 1024,
      rangeSupported: false,
      validators: const Validators(),
    );
    final result = await DownloadJob(
      transport: foreground,
      session: session,
      allowFullBodyCatchup: (_) => true,
    ).run(cancel: CancelToken(priority: 820));
    expect(foreground.requests, hasLength(1));
    expect(
      foreground.requests.single.range?.start,
      preservedLength - 64 * 1024,
    );
    expect(result.state, DownloadState.promoted);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

  test('validatorless overlap mismatch preserves the existing playable partial', () async {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(128 * 1024, (index) => index & 0xff),
    ];
    final session = createSession();
    final broken = FakeTransport(
      bytes: bytes,
      chunkSize: 4096,
      failAfterBytes: 64 * 1024,
      validators: const Validators(),
    );
    await expectLater(
      DownloadJob(transport: broken, session: session).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    final preservedBytes = await File(session.artifact.partialPath).readAsBytes();
    final changed = List<int>.of(bytes);
    changed[32] ^= 0xff;

    await expectLater(
      DownloadJob(
        transport: FakeTransport(
          bytes: changed,
          chunkSize: 4096,
          validators: const Validators(),
        ),
        session: session,
      ).run(),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.resumeRejected,
        ),
      ),
    );

    expect(session.committedLength, preservedLength);
    expect(session.epoch, const SourceEpoch(0));
    expect(await File(session.artifact.partialPath).readAsBytes(), preservedBytes);
  });
  test('explicit cancellation closes a stalled response stream', () async {
    final session = createSession();
    final transport = _BlockingTransport();
    final cancel = CancelToken();
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: cancel,
    );

    await transport.firstChunk.future;
    cancel.cancel();

    await expectLater(
      run,
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await transport.cancelled.future.timeout(const Duration(seconds: 1));
  });

  test('rejects a declared empty image response', () async {
    final session = createSession();

    await expectLater(
      DownloadJob(transport: const _EmptyTransport(), session: session).run(),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );

    expect(session.state, isNot(DownloadState.promoted));
    expect(session.committedLength, 0);
  });

  test('rejects an unknown-length stream that produces no bytes', () async {
    final session = createSession();

    await expectLater(
      DownloadJob(
        transport: const _EmptyTransport(advertiseLength: false),
        session: session,
      ).run(),
      throwsA(
        isA<Failure>().having(
          (error) => error.code,
          'code',
          ErrorCode.artifactCorruption,
        ),
      ),
    );

    expect(session.state, DownloadState.failed);
    expect(session.committedLength, 0);
  });

  test('promotes a complete restored partial without another request', () async {
    final bytes = List<int>.generate(12, (index) => index + 1);
    final session = createSession();
    await session.restore();
    await session.bindResponse(
      validators: const Validators(etag: 'v1'),
      totalLength: bytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes);
    await session.fail(
      writer,
      const Failure(code: ErrorCode.network, message: 'simulated crash'),
    );

    final transport = FakeTransport(bytes: bytes);
    final result = await DownloadJob(
      transport: transport,
      session: session,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(transport.requests, isEmpty);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });


  test('coalesces tiny transport chunks before native/artifact ingress', () async {
    final factory = _CountingSourceFactory();
    final ingress = Ingress(factory: factory, maxBytes: 2 * 1024 * 1024);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'coalesced',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/coalesced.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/coalesced.webp',
        finalPath: '${temp.path}/cache/coalesced.webp',
      ),
      clock: FakeMonoClock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${session.id.key}',
      ingress: ingress,
    );
    session.attachIngressProjection(projection);
    final body = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(256 * 1024, (index) => index & 0xff),
    ];
    final result = await DownloadJob(
      transport: FakeTransport(bytes: body, chunkSize: 1400),
      session: session,
    ).run();

    expect(result.state, DownloadState.promoted);
    expect(factory.source.appendCalls, lessThanOrEqualTo(6));
    expect(factory.source.bytes, body);
  });

  test('animated frame credit pauses and resumes one response without reopen', () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(<int>[48, 48, 48]);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'flow-controlled',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/flow.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/flow.webp',
        finalPath: '${temp.path}/cache/flow.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _FlowBodyTransport(bytes, chunkSize: 17);
    final token = CancelToken(flowTargetFrames: 1);
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await _waitForFlowAction(trace, 'paused', targetFrames: 1);
    expect(transport.openCount, 1);
    expect(session.state, DownloadState.receiving);
    expect(session.committedLength, greaterThan(0));

    token.updateFlowTargetFrames(2);
    await _waitForFlowAction(trace, 'paused', targetFrames: 2);
    expect(transport.openCount, 1);
    expect(session.state, DownloadState.receiving);

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1);
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);

    final actions = trace.events
        .where(
          (event) =>
              event.kind == TraceEventKind.artifactSource &&
              event.payload['stage'] == 'transport-flow-control',
        )
        .map((event) => event.payload['action'])
        .toList(growable: false);
    expect(actions, containsAllInOrder(<Object?>['paused', 'resumed', 'paused', 'resumed']));
  });


  test('frame credit never pauses before an existing partial catch-up boundary', () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(<int>[48, 48, 48]);
    final prefixLength = 12 + (4 + 4 + 48) * 2;
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source', comicId: 'comic', chapterId: 'chapter', pageId: 'flow-catchup',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/flow-catchup.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/flow-catchup.webp',
        finalPath: '${temp.path}/cache/flow-catchup.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    await session.restore();
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes.sublist(0, prefixLength));
    await session.pause(writer);

    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _FullBodyFlowTransport(bytes, chunkSize: 17);
    final token = CancelToken(flowTargetFrames: 1);
    final run = DownloadJob(
      transport: transport,
      session: session,
      allowFullBodyCatchup: (_) => true,
    ).run(cancel: token);

    await _waitForFlowAction(trace, 'paused', targetFrames: 1);
    final paused = trace.events.lastWhere(
      (event) => event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'transport-flow-control' &&
          event.payload['action'] == 'paused',
    );
    expect(paused.payload['networkCursor'] as int, greaterThanOrEqualTo(prefixLength));
    expect(transport.openCount, 1);

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1);
  });

  test('cancelled transport attempt preserves an idle resumable partial', () async {
    final session = createSession();
    final transport = _BlockingTransport();
    final token = CancelToken();
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await transport.firstChunk.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    token.cancel();

    await expectLater(
      run.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.committedLength, 3);
    expect(session.artifact.hasOpenWriter, isFalse);
  });

  test('structural ANMF credit parks only after playable prefix floor',
      () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(<int>[48, 48, 384 * 1024]);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'playable-flow-floor',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://playable-floor.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/playable-floor.webp',
        finalPath: '${temp.path}/cache/playable-floor.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    final transport = _ConsumerPacedBodyTransport(bytes, chunkSize: 16 * 1024);
    final token = CancelToken(flowTargetFrames: 2);
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await _waitForFlowAction(trace, 'pseudo-parked', targetFrames: 2);
    final parked = trace.events.lastWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'transport-flow-control' &&
          event.payload['action'] == 'pseudo-parked',
    );
    expect(parked.payload['completedFrames'] as int, greaterThanOrEqualTo(2));
    expect(
      parked.payload['committedLength'] as int,
      greaterThanOrEqualTo(remoteWebpDecodePrefixQuantumBytes),
      reason: 'ANMF count alone must not authorize an unplayable park',
    );
    expect(parked.payload['responseRetained'], isTrue);
    expect(parked.payload['responseReadPermitHeld'], isFalse);
    expect(session.activeRun, isTrue);

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1);
  });

  test('consumer-paced flow parks and resumes the same response', () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(List<int>.filled(24, 48));
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'parked-flow',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://parked-flow.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/parked-flow.webp',
        finalPath: '${temp.path}/cache/parked-flow.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _ConsumerPacedBodyTransport(bytes, chunkSize: 31);
    final token = CancelToken(flowTargetFrames: 1);
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await _waitForFlowAction(trace, 'pseudo-parked', targetFrames: 1);
    expect(transport.openCount, 1);
    expect(session.activeRun, isTrue);
    expect(session.networkFlowSatisfiedFrames, greaterThanOrEqualTo(1));

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1,
        reason: 'flow credit release must resume the original response');
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] == 'transport-flow-control' &&
            event.payload['action'] == 'pseudo-resumed' &&
            event.payload['responseRetained'] == true,
      ),
      isTrue,
    );
  });

  test('parked response frees read permit while retaining same transport stream',
      () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(List<int>.filled(24, 48));
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'lane-response-parking',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://lane-response-parking.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/lane-response-parking.webp',
        finalPath: '${temp.path}/cache/lane-response-parking.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _ConsumerPacedBodyTransport(bytes, chunkSize: 31);
    final lane = NetLane(maxActive: 1);
    late CancelToken firstToken;
    late Future<DownloadSnapshot> firstRun;
    final firstStarted = Completer<void>();

    lane.submitRanked(
      key: 'first-response',
      priority: 800,
      bucket: 'remote:a',
      bucketLimit: 1,
      flowTargetFrames: 1,
      task: (token) async {
        firstToken = token;
        firstStarted.complete();
        firstRun = DownloadJob(transport: transport, session: session).run(
          cancel: token,
        );
        await firstRun;
      },
    );
    await firstStarted.future;
    await _waitForFlowAction(trace, 'pseudo-parked', targetFrames: 1);
    expect(lane.active, 0,
        reason: 'parked response releases only the bounded read permit');
    expect(lane.transportLeases, 1,
        reason: 'the same live HTTP/source response remains admitted');
    expect(lane.running, 1);
    expect(transport.openCount, 1);

    lane.updateFlowTargetFrames('first-response', 0);
    final result = await firstRun.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(firstToken.cancelled, isFalse);
    expect(transport.openCount, 1,
        reason: 'resume must continue the original response, not reopen it');
    await lane.idle();
  });

  test('durable artifact body uses artifact scheduler instead of NetLane permit',
      () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(<int>[24, 24]);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'durable-artifact-local-body',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://durable-artifact-local-body.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/durable-artifact-local-body.webp',
        finalPath: '${temp.path}/cache/durable-artifact-local-body.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    final transport = _BlockingDurableArtifactTransport(bytes);
    final lane = NetLane(maxActive: 1);
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final secondRelease = Completer<void>();
    late Future<DownloadSnapshot> firstRun;

    lane.submitRanked(
      key: 'artifact-body',
      priority: 760,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (token) async {
        firstStarted.complete();
        firstRun = DownloadJob(transport: transport, session: session).run(
          cancel: token,
        );
        await firstRun;
      },
    );
    await firstStarted.future;
    await transport.opened.future;
    for (var attempt = 0; attempt < 100 && lane.active != 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(lane.active, 0,
        reason: 'artifact-cache body must release the network read permit');
    expect(lane.transportLeases, 0,
        reason: 'durable local body must also release the source transport lease');
    expect(lane.running, 1);
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] == 'transport-read-permit' &&
            event.payload['reason'] == 'durable-artifact-local-body' &&
            event.payload['responseReadPermitHeld'] == false,
      ),
      isTrue,
    );

    lane.submitRanked(
      key: 'network-peer',
      priority: 740,
      bucket: 'remote:a',
      bucketLimit: 1,
      task: (_) async {
        secondStarted.complete();
        await secondRelease.future;
      },
    );
    await secondStarted.future.timeout(const Duration(seconds: 1));
    expect(lane.active, 1);
    expect(lane.running, 2);

    secondRelease.complete();
    transport.releaseBody.complete();
    final result = await firstRun.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    await lane.idle();
  });

  test('range capability no longer changes flow-credit response lifetime',
      () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(List<int>.filled(24, 48));
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'range-independent-parking',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://range-independent.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/range-independent.webp',
        finalPath: '${temp.path}/cache/range-independent.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _ConsumerPacedBodyTransport(
      bytes,
      chunkSize: 31,
      rangeSupported: true,
    );
    final token = CancelToken(flowTargetFrames: 3);
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await _waitForFlowAction(trace, 'pseudo-parked', targetFrames: 3);
    expect(transport.openCount, 1);
    expect(session.activeRun, isTrue);
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['stage'] == 'transport-flow-control' &&
            event.payload['action'] == 'pseudo-parked' &&
            event.payload['responseRangeSupported'] == true &&
            event.payload['retentionReason'] == 'bounded-flow-credit' &&
            event.payload['responseRetained'] == true,
      ),
      isTrue,
    );

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1);
  });

  test('consumer-paced frame credit parks instead of ending the attempt',
      () async {
    final trace = MemoryTraceSink();
    final bytes = _flowAnimatedWebp(<int>[48, 48, 48]);
    final session = DownloadSession(
      id: DownloadId(
        content: const ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: 'pseudo-flow-controlled',
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('runtime://flow.webp'),
      ),
      artifact: Artifact(
        partialPath: '${temp.path}/partial/pseudo-flow.webp',
        finalPath: '${temp.path}/cache/pseudo-flow.webp',
      ),
      clock: FakeMonoClock(),
      traceSink: trace,
    );
    session.observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _ConsumerPacedBodyTransport(bytes, chunkSize: 17);
    final token = CancelToken(flowTargetFrames: 1);
    final run = DownloadJob(transport: transport, session: session).run(
      cancel: token,
    );

    await _waitForFlowAction(trace, 'pseudo-parked', targetFrames: 1);
    expect(transport.openCount, 1);
    expect(session.activeRun, isTrue);
    final parkedLength = session.committedLength;
    expect(parkedLength, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(session.activeRun, isTrue,
        reason: 'parking must not end the physical DownloadJob attempt');

    token.updateFlowTargetFrames(0);
    final result = await run.timeout(const Duration(seconds: 2));
    expect(result.state, DownloadState.promoted);
    expect(transport.openCount, 1,
        reason: 'resume must not open a second response');
    expect(session.committedLength, greaterThanOrEqualTo(parkedLength));
    expect(await File(result.artifact.finalPath).readAsBytes(), bytes);
  });

}


Future<void> _waitForFlowAction(
  MemoryTraceSink trace,
  String action, {
  required int targetFrames,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final found = trace.events.any(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'transport-flow-control' &&
          event.payload['action'] == action &&
          event.payload['targetFrames'] == targetFrames,
    );
    if (found) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('flow action $action target=$targetFrames not observed');
}

final class _FlowBodyTransport implements Transport {
  _FlowBodyTransport(this.bytes, {required this.chunkSize});

  final List<int> bytes;
  final int chunkSize;
  int openCount = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    openCount++;
    final start = range?.start ?? 0;
    Stream<List<int>> body() async* {
      for (var offset = start; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
        yield bytes.sublist(offset, end);
      }
    }

    return ByteResponse(
      bytes: body(),
      statusCode: start == 0 ? HttpStatus.ok : HttpStatus.partialContent,
      rangeStart: start,
      totalLength: bytes.length,
      rangeSupported: true,
      flowControl: ByteResponseFlowControl.streamBackpressure,
      validators: const Validators(etag: 'flow-v1'),
    );
  }
}

List<int> _flowAnimatedWebp(List<int> payloadSizes) {
  final chunks = <int>[];
  for (final size in payloadSizes) {
    chunks
      ..addAll('ANMF'.codeUnits)
      ..addAll(_flowU32(size))
      ..addAll(List<int>.generate(size, (index) => (index * 13) & 0xff));
    if (size.isOdd) chunks.add(0);
  }
  return <int>[
    ...'RIFF'.codeUnits,
    ..._flowU32(4 + chunks.length),
    ...'WEBP'.codeUnits,
    ...chunks,
  ];
}

List<int> _flowU32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];


final class _FullBodyFlowTransport implements Transport {
  _FullBodyFlowTransport(this.bytes, {required this.chunkSize});

  final List<int> bytes;
  final int chunkSize;
  int openCount = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    openCount++;
    Stream<List<int>> body() async* {
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
        yield bytes.sublist(offset, end);
      }
    }
    return ByteResponse(
      bytes: body(),
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: bytes.length,
      rangeSupported: false,
      flowControl: ByteResponseFlowControl.streamBackpressure,
      validators: const Validators(etag: 'full-flow-v1'),
    );
  }
}

final class _ConsumerPacedBodyTransport implements Transport {
  _ConsumerPacedBodyTransport(
    this.bytes, {
    required this.chunkSize,
    this.rangeSupported = true,
  });

  final List<int> bytes;
  final int chunkSize;
  final bool rangeSupported;
  int openCount = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    openCount++;
    final requestedStart = range?.start ?? 0;
    final start = rangeSupported ? requestedStart : 0;
    Stream<List<int>> body() async* {
      for (var offset = start; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
        yield bytes.sublist(offset, end);
      }
    }
    return ByteResponse(
      bytes: body(),
      statusCode: start == 0 ? HttpStatus.ok : HttpStatus.partialContent,
      rangeStart: start,
      totalLength: bytes.length,
      rangeSupported: rangeSupported,
      flowControl: ByteResponseFlowControl.consumerPacing,
      validators: const Validators(etag: 'pseudo-flow-v1'),
    );
  }
}

final class _BlockingDurableArtifactTransport implements Transport {
  _BlockingDurableArtifactTransport(this.bytes);

  final List<int> bytes;
  final Completer<void> opened = Completer<void>();
  final Completer<void> releaseBody = Completer<void>();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    if (!opened.isCompleted) opened.complete();
    Stream<List<int>> body() async* {
      final split = bytes.length.clamp(1, 16).toInt();
      yield bytes.sublist(0, split);
      await releaseBody.future;
      if (split < bytes.length) yield bytes.sublist(split);
    }

    return ByteResponse(
      bytes: body(),
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: bytes.length,
      rangeSupported: true,
      disposition: ByteResponseDisposition.durableImmutable,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      validators: const Validators(etag: 'artifact-cache-v1'),
    );
  }
}

final class _BlockingTransport implements Transport {
  final Completer<void> firstChunk = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        controller.add(<int>[1, 2, 3]);
        if (!firstChunk.isCompleted) firstChunk.complete();
      },
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    return ByteResponse(
      bytes: controller.stream,
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: 6,
    );
  }
}

final class _EmptyTransport implements Transport {
  const _EmptyTransport({this.advertiseLength = true});

  final bool advertiseLength;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: const Stream<List<int>>.empty(),
        statusCode: HttpStatus.ok,
        rangeStart: 0,
        totalLength: advertiseLength ? 0 : null,
      );
}


final class _CountingSourceFactory implements SourceFactory {
  late _CountingSource source;
  int createCount = 0;

  @override
  EncodedSource create({required int epoch, required int maxBytes}) {
    createCount++;
    source = _CountingSource(epoch: epoch, maxBytes: maxBytes);
    return source;
  }
}

final class _CountingSource implements EncodedSource {
  _CountingSource({required this.epoch, required this.maxBytes});

  @override
  int epoch;
  final int maxBytes;
  final List<int> bytes = <int>[];
  int appendCalls = 0;

  @override
  int get length => bytes.length;
  @override
  bool sealed = false;
  @override
  SourceKind get kind => SourceKind.webp;

  @override
  SourceStatus append({
    required int epoch,
    required int offset,
    required List<int> bytes,
  }) {
    if (epoch != this.epoch) return SourceStatus.staleEpoch;
    if (offset != this.bytes.length) return SourceStatus.invalidOffset;
    if (this.bytes.length + bytes.length > maxBytes) return SourceStatus.budget;
    appendCalls++;
    this.bytes.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    bytes.clear();
    sealed = false;
    return SourceStatus.ok;
  }

  @override
  SourceStatus seal(int epoch) {
    if (epoch != this.epoch) return SourceStatus.staleEpoch;
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}
