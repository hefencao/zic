import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('fills the requested watermark and rebuilds on epoch change', () async {
    final temp = await Directory.systemTemp.createTemp('decode_session_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _CursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
    );

    final readyDepths = <int>[];
    final result = await session.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 2,
        reason: 'test',
        expirationRevision: 2,
      ),
      revision: 1,
      cancel: CancelToken(),
      onFrameReady: (snapshot) => readyDepths.add(snapshot.depth),
    );

    expect(readyDepths, <int>[1, 2],
        reason: 'upload may start after frame 0 while refill continues');
    expect(result.state, DecodeState.ready);
    expect(result.depth, 2);
    expect(factory.created, 1);
    expect(
      factory.cursors.single.executionClasses,
      <DecodeExecutionClass>[
        DecodeExecutionClass.current,
        DecodeExecutionClass.current,
      ],
    );

    await download.reset();
    ingress.append(
      epoch: download.epoch,
      offset: 0,
      bytes: 'RIFF....WEBPnew'.codeUnits,
    );
    final next = await session.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'epoch',
        expirationRevision: 3,
      ),
      revision: 2,
      cancel: CancelToken(),
    );

    expect(next.epoch, const SourceEpoch(1));
    expect(next.depth, 1);
    expect(factory.created, 2);

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('rebinds when ingress replaces encoded source inside the same epoch',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'decode_same_epoch_source_rebind_test_',
    );
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPold'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _CursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
    );

    final first = await session.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'initial-source',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final firstSource = projection.source;
    expect(first.depth, 1);
    expect(factory.created, 1);

    await projection.rebuild(
      epoch: download.epoch,
      chunks: Stream<List<int>>.value('RIFF....WEBPnew'.codeUnits),
      sealed: false,
    );
    expect(projection.source, isNot(same(firstSource)));
    expect(download.epoch, const SourceEpoch(0));

    final second = await session.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'replacement-source',
        expirationRevision: 2,
      ),
      revision: 2,
      cancel: CancelToken(),
    );

    expect(second.epoch, const SourceEpoch(0));
    expect(second.depth, 1);
    expect(factory.created, 2,
        reason: 'same-epoch source replacement must invalidate the old cursor');

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('promotes an already queued native-style decode when page becomes current',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'decode_priority_promotion_test_',
    );
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _PromotableCursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
    );

    final fill = session.fill(
      demand: const DecodeDemand(
        role: PageRole.far,
        priority: 320,
        targetWatermark: 1,
        reason: 'prefetch',
        expirationRevision: 2,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    await factory.cursor.started.future;

    expect(
      session.promotePendingDecodeToCurrent(),
      DecodePriorityPromotion.queued,
    );
    expect(factory.cursor.promotions, 1);

    factory.cursor.release.complete();
    final result = await fill;
    expect(result.depth, 1);

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('partial WebP retries only after the learned per-frame prefix', () async {
    final temp = await Directory.systemTemp.createTemp(
      'decode_prefix_hint_test_',
    );
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024 * 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: List<int>.filled(300000, 1),
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _PrefixCursorFactory();
    final hints = WebpDecodePrefixHints();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
      prefixHints: hints,
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'adaptive-prefix',
      expirationRevision: 1,
    );

    final first = await session.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(first.state, DecodeState.waitingSource);
    expect(first.requiredSourceLength, 524288);
    expect(factory.cursor.calls, 1);

    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 300000,
      bytes: List<int>.filled(100000, 2),
    );
    final early = await session.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(early.state, DecodeState.waitingSource);
    expect(factory.cursor.calls, 1);

    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 400000,
      bytes: List<int>.filled(124288, 3),
    );
    final ready = await session.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(ready.state, DecodeState.ready);
    expect(ready.depth, 1);
    expect(factory.cursor.calls, 2);
    expect(hints.minimumBytes(download.id, 0), 524288);

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('transition decode uses the non-current worker class', () async {
    final temp = await Directory.systemTemp.createTemp('decode_role_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _CursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
    );

    await session.fill(
      demand: const DecodeDemand(
        role: PageRole.transition,
        priority: 900,
        targetWatermark: 1,
        reason: 'transition-role',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(
      factory.cursors.single.executionClasses,
      <DecodeExecutionClass>[DecodeExecutionClass.nonCurrent],
    );

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('authoritative ingress failure terminates decode loading', () async {
    final temp = await Directory.systemTemp.createTemp('decode_source_failure_');
    final ingress = Ingress(factory: _FailingSourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );

    final result = await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'source-failure',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(result.state, DecodeState.failed);
    expect(result.failure?.code, ErrorCode.source);
    expect(cursors.created, 0);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('disposes a decoded frame when cancellation wins the race', () async {
    final temp = await Directory.systemTemp.createTemp('decode_cancel_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final factory = _DelayedCursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: factory,
      clock: _Clock(),
    );
    final token = CancelToken();
    final pending = session.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'cancel',
        expirationRevision: 2,
      ),
      revision: 1,
      cancel: token,
    );
    await Future<void>.delayed(Duration.zero);

    final frame = _Frame(0, 0);
    token.cancel();
    factory.cursor.next.complete(CursorStep.frame(frame));

    await expectLater(
      pending,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );
    expect(frame.disposed, isTrue);

    session.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('prepared output contributes to the target watermark', () async {
    final temp = await Directory.systemTemp.createTemp('decode_prepared_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );

    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'prepared',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
      preparedDepth: 1,
    );

    expect(decode.snapshot.depth, 0);
    expect(cursors.cursors.single.next, 0);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('cycles a thirty-frame partial prefix while source remains unsealed', () async {
    final temp =
        await Directory.systemTemp.createTemp('decode_partial_loop_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024 * 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpartial-animation'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final trace = MemoryTraceSink();
    final cursors = _PartialPrefixCursorFactory(frameCount: 30);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
      traceSink: trace,
      partialLoopMinFrames: 30,
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'partial-prefix-loop',
      expirationRevision: 64,
    );

    for (var revision = 1; revision <= 30; revision++) {
      final snap = await decode.fill(
        demand: demand,
        revision: revision,
        cancel: CancelToken(),
      );
      expect(snap.depth, 1);
      expect(decode.holder!.consume(revision - 1), isTrue);
    }

    final looped = await decode.fill(
      demand: demand,
      revision: 31,
      cancel: CancelToken(),
    );
    expect(looped.depth, 1);
    expect(decode.holder!.frames.single.index, 0);
    expect(looped.cycle, 1);
    expect(cursors.created, 2);
    final loop = trace.events.lastWhere(
      (event) => event.kind == TraceEventKind.animationLoop,
    );
    expect(loop.payload['partialPrefix'], isTrue);
    expect(loop.payload['frameCount'], 30);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('rewinds an infinite animation only after held frames are consumed', () async {
    final temp = await Directory.systemTemp.createTemp('decode_loop_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final trace = MemoryTraceSink();
    final loops = _LoopCursorFactory(frameCount: 2, loopCount: 0);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: loops,
      clock: _Clock(),
      traceSink: trace,
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'loop',
      expirationRevision: 8,
    );

    var snap = await decode.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(snap.cycle, 0);
    expect(snap.animation, const AnimationInfo(
      frameCount: 2,
      loopCount: 0,
      complete: true,
    ));
    expect(decode.holder!.consume(0), isTrue);

    snap = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(snap.cycle, 0);
    expect(decode.holder!.consume(1), isTrue);

    snap = await decode.fill(
      demand: demand,
      revision: 3,
      cancel: CancelToken(),
    );
    expect(snap.state, DecodeState.ready);
    expect(snap.cycle, 1);
    expect(decode.holder!.frames.single.index, 0);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.animationLoop),
      hasLength(1),
    );

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('detached static page recreates its cursor on the next demand', () async {
    final temp = await Directory.systemTemp.createTemp('decode_replay_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _LoopCursorFactory(frameCount: 1, loopCount: 1);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'replay',
      expirationRevision: 8,
    );

    final first = await decode.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(first.depth, 1);
    expect(decode.holder!.consume(0), isTrue);
    decode.detach(retainDepth: 0);

    final replayed = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(replayed.state, DecodeState.ready);
    expect(replayed.depth, 1);
    expect(decode.holder!.frames.single.index, 0);
    expect(cursors.created, 2);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'detached exhausted partial cursor drops stale next-frame prefix gate',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'decode_partial_reentry_prefix_test_',
      );
      final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024 * 1024);
      ingress.append(
        epoch: const SourceEpoch(0),
        offset: 0,
        bytes: List<int>.filled(300000, 1),
      );
      final download = DownloadSession(
        id: _downloadId(),
        artifact: Artifact(
          partialPath: '${temp.path}/page.part',
          finalPath: '${temp.path}/page.webp',
        ),
        clock: _Clock(),
      );
      final projection = DownloadIngressProjection(
        scopeId: 'test:${download.id.key}',
        ingress: ingress,
      );
      download.attachIngressProjection(projection);
      final cursors = _PartialPrefixCursorFactory(frameCount: 1);
      final hints = WebpDecodePrefixHints();
      final decode = DecodeSession(
        id: _decodeId(download.id),
        download: download,
        ingress: projection,
        cursors: cursors,
        clock: _Clock(),
        prefixHints: hints,
      );
      const continuationDemand = DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 2,
        reason: 'consume-prefix-before-detach',
        expirationRevision: 8,
      );

      final waiting = await decode.fill(
        demand: continuationDemand,
        revision: 1,
        cancel: CancelToken(),
      );
      expect(waiting.state, DecodeState.waitingSource);
      expect(waiting.depth, 1);
      expect(waiting.requiredSourceLength, greaterThan(ingress.source!.length));
      expect(decode.holder!.consume(0), isTrue);
      decode.detach(retainDepth: 0);

      final replayed = await decode.fill(
        demand: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'reenter-from-existing-partial',
          expirationRevision: 9,
        ),
        revision: 2,
        cancel: CancelToken(),
      );
      expect(replayed.state, DecodeState.ready);
      expect(replayed.depth, 1);
      expect(replayed.requiredSourceLength, 0);
      expect(decode.holder!.frames.single.index, 0);
      expect(cursors.created, 2);

      decode.dispose();
      await download.dispose();
      await temp.delete(recursive: true);
    },
  );

  test('retained frame detach preserves cursor continuation', () async {
    final temp = await Directory.systemTemp.createTemp('decode_retain_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );
    const firstDemand = DecodeDemand(
      role: PageRole.transition,
      priority: 900,
      targetWatermark: 1,
      reason: 'retain-transition',
      expirationRevision: 8,
    );

    final retained = await decode.fill(
      demand: firstDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(retained.depth, 1);
    expect(decode.holder!.frames.single.index, 0);
    decode.detach(retainDepth: 1);
    expect(decode.holder!.consume(0), isTrue);

    final continued = await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 2,
        reason: 'promoted-current',
        expirationRevision: 9,
      ),
      revision: 3,
      cancel: CancelToken(),
    );
    expect(continued.state, DecodeState.ready);
    expect(decode.holder!.frames.map((frame) => frame.index), <int>[1, 2]);
    expect(cursors.created, 1);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('finite animation enters ended after its play count is exhausted', () async {
    final temp = await Directory.systemTemp.createTemp('decode_end_test_');
    AnimationInfo? resolvedAnimation;
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: _LoopCursorFactory(frameCount: 1, loopCount: 1),
      clock: _Clock(),
      onAnimationResolved: (_, animation) {
        resolvedAnimation = animation;
      },
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'finite',
      expirationRevision: 8,
    );

    await decode.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(resolvedAnimation?.complete, isTrue);
    expect(resolvedAnimation?.frameCount, 1);
    expect(decode.holder!.consume(0), isTrue);
    final ended = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );

    expect(ended.state, DecodeState.ended);
    expect(ended.cycle, 0);
    expect(ended.animation.loopCount, 1);
    expect(resolvedAnimation?.complete, isTrue);
    expect(resolvedAnimation?.frameCount, 1);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('transient cursor failure retries in place while successors remain',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'decode_transient_failure_test_',
    );
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _TransientCursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 2,
      reason: 'transient-failure',
      expirationRevision: 3,
    );

    await expectLater(
      decode.fill(
        demand: demand,
        revision: 1,
        cancel: CancelToken(),
      ),
      throwsA(isA<Failure>()),
    );
    expect(decode.snapshot.state, DecodeState.failed);
    expect(decode.snapshot.depth, 1);

    final recovered = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(recovered.state, DecodeState.ready);
    expect(recovered.depth, 2);
    expect(cursors.created, 1,
        reason: 'a buffered transient failure retries the same cursor');

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('decode exceptions become authoritative failures for upload projection',
      () async {
    final temp = await Directory.systemTemp.createTemp('decode_failure_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    ingress.seal(const SourceEpoch(0));
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: const _ThrowingCursorFactory(),
      clock: _Clock(),
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'failure',
      expirationRevision: 1,
    );

    await expectLater(
      decode.fill(
        demand: demand,
        revision: 1,
        cancel: CancelToken(),
      ),
      throwsA(isA<Failure>().having(
        (failure) => failure.code,
        'code',
        ErrorCode.decode,
      )),
    );
    expect(decode.snapshot.state, DecodeState.failed);

    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: _NoopUploader(),
      clock: _Clock(),
    );
    final projected = await upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'failure',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    expect(projected.state, UploadState.failed);
    expect(projected.failure?.code, ErrorCode.decode);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test(
      'unsealed first-frame decode error waits for source growth instead of failing',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'decode_unsealed_provisional_failure_test_',
    );
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024 * 1024);
    final initial = 'RIFF....WEBPpayload'.codeUnits;
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: initial,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final cursors = _GrowingPrefixFailureCursorFactory(minimumBytes: 256 * 1024);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: cursors,
      clock: _Clock(),
    );
    const demand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'growing-prefix',
      expirationRevision: 2,
    );

    final waiting = await decode.fill(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(waiting.state, DecodeState.waitingSource);
    expect(waiting.failure, isNull);
    expect(waiting.requiredSourceLength, greaterThan(initial.length));

    final target = waiting.requiredSourceLength;
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: initial.length,
      bytes: List<int>.filled(target - initial.length, 0),
    );
    final recovered = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(recovered.state, DecodeState.ready);
    expect(recovered.depth, 1);
    expect(recovered.failure, isNull);
    expect(cursors.created, 2,
        reason: 'the provisional failure must restart on the grown prefix');

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('need-more-data is explicit and does not require loop capability', () async {
    final temp = await Directory.systemTemp.createTemp('decode_wait_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: const _StepCursorFactory(CursorStep.needMoreData()),
      clock: _Clock(),
    );

    final result = await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'wait',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(result.state, DecodeState.waitingSource);
    expect(result.depth, 0);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('non-loop cursor reports terminal end explicitly', () async {
    final temp = await Directory.systemTemp.createTemp('decode_plain_end_test_');
    final ingress = Ingress(factory: _SourceFactory(), maxBytes: 1024);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    final download = DownloadSession(
      id: _downloadId(),
      artifact: Artifact(
        partialPath: '${temp.path}/page.part',
        finalPath: '${temp.path}/page.webp',
      ),
      clock: _Clock(),
    );
    final projection = DownloadIngressProjection(
      scopeId: 'test:${download.id.key}',
      ingress: ingress,
    );
    download.attachIngressProjection(projection);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      ingress: projection,
      cursors: const _StepCursorFactory(CursorStep.end()),
      clock: _Clock(),
    );

    final result = await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'end',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(result.state, DecodeState.ended);
    expect(result.depth, 0);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

}

DownloadId _downloadId() => DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/page.webp'),
    );

DecodeId _decodeId(DownloadId download) => DecodeId(
      download: download,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );

final class _Clock implements MonoClock {
  @override
  int nowMicros() => 0;
}

final class _SourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _Source(epoch);
}

final class _Source implements EncodedSource {
  _Source(this.epoch);

  @override
  int epoch;
  final List<int> bytes = <int>[];
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
    sealed = true;
    return SourceStatus.ok;
  }

  @override
  void dispose() {}
}

final class _CursorFactory implements CursorFactory {
  final List<_Cursor> cursors = <_Cursor>[];

  int get created => cursors.length;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    final cursor = _Cursor(epoch);
    cursors.add(cursor);
    return CursorBinding(frames: cursor);
  }
}

final class _Cursor implements ScheduledFrameCursor {
  _Cursor(this.epoch);

  @override
  final int epoch;
  int next = 0;
  final List<DecodeExecutionClass> executionClasses =
      <DecodeExecutionClass>[];

  @override
  Future<CursorStep> decodeNext() =>
      decodeNextScheduled(DecodeExecutionClass.nonCurrent);

  @override
  Future<CursorStep> decodeNextScheduled(
    DecodeExecutionClass executionClass,
  ) async {
    executionClasses.add(executionClass);
    return CursorStep.frame(_Frame(epoch, next++));
  }

  @override
  void dispose() {}
}

final class _Frame implements FrameRef {
  _Frame(this.epoch, this.index);

  @override
  final int epoch;
  @override
  final int index;
  @override
  int get byteLength => 4;
  @override
  Duration get duration => const Duration(milliseconds: 16);
  @override
  int get height => 1;
  @override
  int get width => 1;
  @override
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}


final class _PromotableCursorFactory implements CursorFactory {
  final _PromotableCursor cursor = _PromotableCursor();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      CursorBinding(frames: cursor);
}

final class _PromotableCursor implements PrioritizableScheduledFrameCursor {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int promotions = 0;

  @override
  int get epoch => 0;

  @override
  Future<CursorStep> decodeNext() =>
      decodeNextScheduled(DecodeExecutionClass.nonCurrent);

  @override
  Future<CursorStep> decodeNextScheduled(
    DecodeExecutionClass executionClass,
  ) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return CursorStep.frame(_Frame(epoch, 0));
  }

  @override
  DecodePriorityPromotion promotePendingDecodeToCurrent() {
    promotions++;
    return DecodePriorityPromotion.queued;
  }

  @override
  void dispose() {}
}

final class _PartialPrefixCursorFactory implements CursorFactory {
  _PartialPrefixCursorFactory({required this.frameCount});

  final int frameCount;
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    final cursor = _PartialPrefixCursor(epoch, frameCount);
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _PartialPrefixCursor implements FrameCursor, LoopCursor {
  _PartialPrefixCursor(this.epoch, this.frameCount);

  @override
  final int epoch;
  final int frameCount;
  int _next = 0;

  @override
  AnimationInfo get animation => AnimationInfo(
        frameCount: frameCount,
        loopCount: 0,
        complete: false,
      );

  @override
  int get cycle => 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (_next >= frameCount) {
      return const CursorStep.needMoreData();
    }
    return CursorStep.frame(_Frame(epoch, _next++));
  }

  @override
  bool rewind() => false;

  @override
  void dispose() {}
}

final class _LoopCursorFactory implements CursorFactory {
  _LoopCursorFactory({required this.frameCount, required this.loopCount});

  final int frameCount;
  final int loopCount;
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    final cursor = _LoopCursor(
      epoch: epoch,
      frameCount: frameCount,
      loopCount: loopCount,
    );
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _LoopCursor implements FrameCursor, LoopCursor {
  _LoopCursor({
    required this.epoch,
    required this.frameCount,
    required this.loopCount,
  });

  @override
  final int epoch;
  final int frameCount;
  final int loopCount;
  int _next = 0;
  int _cycle = 0;

  @override
  AnimationInfo get animation => AnimationInfo(
        frameCount: frameCount,
        loopCount: loopCount,
        complete: true,
      );

  @override
  int get cycle => _cycle;

  @override
  Future<CursorStep> decodeNext() async {
    if (_next >= frameCount) {
      return const CursorStep.end();
    }
    return CursorStep.frame(_Frame(epoch, _next++));
  }

  @override
  bool rewind() {
    if (_next < frameCount) {
      throw StateError('cursor must reach end before rewind');
    }
    if (loopCount != 0 && _cycle + 1 >= loopCount) {
      return false;
    }
    _cycle++;
    _next = 0;
    return true;
  }

  @override
  void dispose() {}
}

final class _StepCursorFactory implements CursorFactory {
  const _StepCursorFactory(this.step);

  final CursorStep step;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _StepCursor(epoch, step));
}

final class _StepCursor implements FrameCursor {
  const _StepCursor(this.epoch, this.step);

  @override
  final int epoch;
  final CursorStep step;

  @override
  Future<CursorStep> decodeNext() async => step;

  @override
  void dispose() {}
}


final class _PrefixCursorFactory implements CursorFactory {
  late final _PrefixCursor cursor;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    cursor = _PrefixCursor(epoch);
    return CursorBinding(frames: cursor);
  }
}

final class _PrefixCursor implements FrameCursor {
  _PrefixCursor(this.epoch);

  @override
  final int epoch;
  int calls = 0;

  @override
  Future<CursorStep> decodeNext() async {
    calls++;
    if (calls == 1) {
      return const CursorStep.needMoreData();
    }
    return CursorStep.frame(_Frame(epoch, 0));
  }

  @override
  void dispose() {}
}

final class _TransientCursorFactory implements CursorFactory {
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    return CursorBinding(frames: _TransientCursor(epoch));
  }
}

final class _TransientCursor implements FrameCursor {
  _TransientCursor(this.epoch);

  @override
  final int epoch;
  int calls = 0;

  @override
  Future<CursorStep> decodeNext() async {
    final call = calls++;
    if (call == 1) {
      throw StateError('transient decode failure');
    }
    return CursorStep.frame(_Frame(epoch, call > 1 ? call - 1 : call));
  }

  @override
  void dispose() {}
}

final class _GrowingPrefixFailureCursorFactory implements CursorFactory {
  _GrowingPrefixFailureCursorFactory({required this.minimumBytes});

  final int minimumBytes;
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    return CursorBinding(
      frames: _GrowingPrefixFailureCursor(
        epoch: epoch,
        source: source,
        minimumBytes: minimumBytes,
      ),
    );
  }
}

final class _GrowingPrefixFailureCursor implements FrameCursor {
  _GrowingPrefixFailureCursor({
    required this.epoch,
    required this.source,
    required this.minimumBytes,
  });

  @override
  final int epoch;
  final EncodedSource source;
  final int minimumBytes;

  @override
  Future<CursorStep> decodeNext() async {
    if (source.length < minimumBytes) {
      throw StateError('prefix is not yet decodable');
    }
    return CursorStep.frame(_Frame(epoch, 0));
  }

  @override
  void dispose() {}
}

final class _DelayedCursorFactory implements CursorFactory {
  late final _DelayedCursor cursor;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    cursor = _DelayedCursor(epoch);
    return CursorBinding(frames: cursor);
  }
}

final class _DelayedCursor implements FrameCursor {
  _DelayedCursor(this.epoch);

  @override
  final int epoch;
  final Completer<CursorStep> next = Completer<CursorStep>();

  @override
  Future<CursorStep> decodeNext() => next.future;

  @override
  void dispose() {}
}



final class _ThrowingCursorFactory implements CursorFactory {
  const _ThrowingCursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _ThrowingCursor(epoch));
}

final class _ThrowingCursor implements FrameCursor {
  const _ThrowingCursor(this.epoch);

  @override
  final int epoch;

  @override
  Future<CursorStep> decodeNext() async => throw StateError('decode boom');

  @override
  void dispose() {}
}

final class _NoopUploader implements FrameUploader {
  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) => throw StateError('upload must not run after decode failure');

  @override
  void release(DecodeId id) {}
}

final class _FailingSourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _FailingSource(epoch);
}

final class _FailingSource implements EncodedSource {
  _FailingSource(this.epoch);

  @override
  int epoch;

  @override
  int get length => 0;

  @override
  bool get sealed => false;

  @override
  SourceKind get kind => SourceKind.webp;

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
