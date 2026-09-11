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
  test('upload consumes the decoded frame and present claim delays disposal', () async {
    final temp = await Directory.systemTemp.createTemp('upload_session_test_');
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
    final cursorFactory = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      ingress: projection,
      cursors: cursorFactory,
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'test',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    final uploader = _Uploader();
    final playbackClock = _Clock();
    final trace = MemoryTraceSink();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: playbackClock,
      traceSink: trace,
    );
    final snapshots = <UploadSnapshot>[];
    upload.addSnapshotListener(snapshots.add);
    final ready = await upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'test',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(ready.state, UploadState.ready);
    expect(ready.frameIndex, 0);
    expect(decode.holder?.depth, 0);
    expect(cursorFactory.frames.single.disposed, isTrue);

    final claim = upload.claimPresent();
    expect(claim, isNotNull);
    upload.setPlayback(paused: true, speed: 2);
    await upload.present(claim!);
    expect(uploader.outputs.single.presented, 1);
    expect(upload.playbackState, PlaybackState.frozen);
    expect(upload.playbackDeadlineMicros, isNull);
    playbackClock.value = 16000;
    expect(upload.takeDueFrame(), isNull);
    expect(upload.freezePlayback(), isTrue);
    upload.setPlayback(paused: false, speed: 1);
    playbackClock.value = 32000;
    expect(upload.takeDueFrame(), isNull);
    expect(upload.resumePlayback(), isTrue);
    expect(upload.playbackState, PlaybackState.running);
    expect(upload.playbackDeadlineMicros, 48000);
    playbackClock.value = 47999;
    expect(upload.takeDueFrame(), isNull);
    playbackClock.value = 48000;
    expect(upload.takeDueFrame(), 0);
    expect(upload.playbackState, PlaybackState.idle);
    expect(snapshots.any((snapshot) => snapshot.state == UploadState.ready), isTrue);

    expect(upload.detach(), isTrue);
    expect(decode.state, DecodeState.idle);
    final uploaded = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.frameUploaded,
    );
    expect(uploaded.payload['uploadMicros'], isA<int>());
    expect(uploaded.payload['inputBytes'], greaterThan(0));
    expect(uploaded.payload['outputBytes'], greaterThan(0));
    final pipelineTiming = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.framePipelineTiming,
    );
    expect(pipelineTiming.payload['traceReason'], 'startup');
    expect(pipelineTiming.payload['workerReadyMicros'], 7);
    expect(pipelineTiming.payload['workerQueueMicros'], 11);
    expect(pipelineTiming.payload['nativeDecodeMicros'], 17);
    expect(pipelineTiming.payload['nativeMetadataMicros'], 19);
    expect(pipelineTiming.payload['nativePrepareMicros'], 23);
    expect(pipelineTiming.payload['nativeCanvasPrepareMicros'], 29);
    expect(pipelineTiming.payload['nativeFragmentDecodeMicros'], 31);
    expect(pipelineTiming.payload['nativeCompositeMicros'], 37);
    expect(pipelineTiming.payload['nativeFrameCopyMicros'], 41);
    expect(pipelineTiming.payload['nativeThreadId'], 1234);
    expect(pipelineTiming.payload['nativeCpuStart'], 2);
    expect(pipelineTiming.payload['nativeCpuEnd'], 3);
    expect(pipelineTiming.payload['nativeCpuAllowedMask'], 15);
    expect(pipelineTiming.payload['decodedRole'], 'current');
    expect(pipelineTiming.payload['decodedLeadMicros'], 0);
    expect(pipelineTiming.payload['uploadBackpressureMicros'], isA<int>());
    expect(pipelineTiming.payload['platformUploadMicros'], 200);
    expect(pipelineTiming.payload['platformOtherMicros'], 49);
    expect(pipelineTiming.payload['platformResultDispatchMicros'], 43);
    expect(pipelineTiming.payload['presentationPath'], 'platform');
    expect(pipelineTiming.payload['presentationAckCreditMicros'], 6);
    expect(pipelineTiming.payload['presentationVisibleAtMicros'], 0);
    final released = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.pageOutputReleased,
    );
    expect(released.payload['reason'], 'demand-detached');
    expect(released.payload['decodeRestarted'], isTrue);
    expect(uploader.released, <DecodeId>[decode.id]);
    expect(uploader.outputs.single.disposed, isFalse);
    claim.release();
    expect(uploader.outputs.single.disposed, isTrue);

    upload.dispose();
    expect(snapshots.last.state, UploadState.disposed);
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });


  test(
    'detached authoritative static output remains until budget trim',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'upload_static_retention_test_',
      );
      addTearDown(() async => temp.delete(recursive: true));
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
        ingress: projection,
        cursors: _CursorFactory(
          duration: Duration.zero,
          frameLimit: 1,
          animation: const AnimationInfo(
            frameCount: 1,
            loopCount: 1,
            complete: true,
          ),
        ),
        clock: _Clock(),
      );
      await decode.fill(
        demand: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'static-retention',
          expirationRevision: 1,
        ),
        revision: 1,
        cancel: CancelToken(),
      );
      final trace = MemoryTraceSink();
      final uploader = _Uploader();
      final upload = UploadSession(
        id: decode.id,
        decode: decode,
        uploader: uploader,
        clock: _Clock(),
        traceSink: trace,
      );
      await upload.prepare(
        demand: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'static-retention',
          expirationRevision: 1,
        ),
        revision: 1,
        cancel: CancelToken(),
      );
      final retainedBytes = upload.outputBytes;

      expect(upload.detach(retainStaticOutput: true), isFalse);
      expect(upload.state, UploadState.ready);
      expect(upload.outputBytes, retainedBytes);
      expect(uploader.released, isEmpty);
      expect(
        trace.events.any(
          (event) => event.kind == TraceEventKind.staticFrameKept,
        ),
        isTrue,
      );
      expect(
        trace.events.any(
          (event) => event.kind == TraceEventKind.pageOutputReleased,
        ),
        isFalse,
      );
      expect(
        upload.reusePreparedStaticForDemand(
          demand: const UploadDemand(
            role: PageRole.transition,
            priority: 900,
            reason: 'static-role-migration',
            expirationRevision: 3,
          ),
          revision: 2,
        ),
        isTrue,
      );
      expect(upload.state, UploadState.ready);
      expect(upload.outputBytes, retainedBytes);
      expect(uploader.outputs, hasLength(1));

      upload.trimOutput();
      expect(upload.outputBytes, 0);
      final released = trace.events.lastWhere(
        (event) => event.kind == TraceEventKind.pageOutputReleased,
      );
      expect(released.payload['reason'], 'frame-budget');

      upload.dispose();
      decode.dispose();
      await download.dispose();
    },
  );

  test('static zero-duration output remains visible without playback advance', () async {
    final temp = await Directory.systemTemp.createTemp('upload_static_test_');
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
      ingress: projection,
      cursors: _CursorFactory(
        duration: Duration.zero,
        frameLimit: 1,
        animation: const AnimationInfo(
          frameCount: 1,
          loopCount: 1,
          complete: true,
        ),
      ),
      clock: _Clock(),
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'static',
      expirationRevision: 1,
    );
    await decode.fill(
      demand: decodeDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final playbackClock = _Clock();
    final uploader = _Uploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: playbackClock,
    );
    final ready = await upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'static',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    expect(ready.state, UploadState.ready);
    final claim = upload.claimPresent();
    expect(claim, isNotNull);
    await upload.present(claim!);
    claim.release();

    expect(upload.playbackState, PlaybackState.idle);
    playbackClock.value = 1000000;
    expect(upload.takeDueFrame(), isNull);
    expect(upload.frame?.index, 0);
    expect(uploader.outputs.single.disposed, isFalse);

    upload.detach();
    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('retained static output reuses prior presentation without re-presenting',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'upload_static_reproject_test_',
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
    final decode = DecodeSession(
      id: _decodeId(download.id),
      ingress: projection,
      cursors: _CursorFactory(
        duration: Duration.zero,
        frameLimit: 1,
        animation: const AnimationInfo(
          frameCount: 1,
          loopCount: 1,
          complete: true,
        ),
      ),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'static-reproject',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final uploader = _Uploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );
    const demand = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'static-reproject',
      expirationRevision: 1,
    );
    await upload.prepare(
      demand: demand,
      revision: 1,
      cancel: CancelToken(),
    );

    final first = upload.claimPresent();
    expect(first, isNotNull);
    expect(upload.reusePresentedStatic(first!), isFalse);
    await upload.present(first);
    first.release();
    expect(uploader.outputs.single.presented, 1);

    expect(upload.detach(retainStaticOutput: true), isFalse);
    await upload.prepare(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );
    final revisit = upload.claimPresent();
    expect(revisit, isNotNull);
    expect(upload.reusePresentedStatic(revisit!), isTrue);
    expect(uploader.outputs.single.presented, 1);
    revisit.release();

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('current animation starts from the visible frame without a startup gate',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'upload_holder_driven_playback_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
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
      ingress: projection,
      cursors: _CursorFactory(
        frameLimit: 10,
        animation: const AnimationInfo(
          frameCount: 10,
          loopCount: 0,
          complete: true,
        ),
      ),
      clock: _Clock(),
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'holder-driven-playback',
      expirationRevision: 1,
    );
    await decode.fill(
      demand: decodeDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final clock = _Clock();
    final trace = MemoryTraceSink();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: _Uploader(),
      clock: clock,
      traceSink: trace,
    );
    const current = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'holder-driven-playback',
      expirationRevision: 1,
    );
    await upload.prepare(
      demand: current,
      revision: 1,
      cancel: CancelToken(),
    );
    final claim = upload.claimPresent();
    expect(claim, isNotNull);
    await upload.present(claim!);
    claim.release();

    expect(upload.playbackRunning, isTrue);
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.playbackBuffering,
      ),
      isEmpty,
    );

    const transition = UploadDemand(
      role: PageRole.transition,
      priority: 900,
      reason: 'holder-driven-playback',
      expirationRevision: 1,
    );
    await upload.prepare(
      demand: transition,
      revision: 2,
      cancel: CancelToken(),
    );
    await upload.prepare(
      demand: current,
      revision: 3,
      cancel: CancelToken(),
    );
    expect(upload.playbackRunning, isTrue);

    upload.dispose();
    decode.dispose();
    await download.dispose();
  });

  test('animated output buffers one successor without early replacement',
      () async {
    final temp = await Directory.systemTemp.createTemp('upload_buffer_test_');
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
      ingress: projection,
      cursors: _CursorFactory(
        frameLimit: 2,
        animation: const AnimationInfo(
          frameCount: 2,
          loopCount: 1,
          complete: true,
        ),
      ),
      clock: _Clock(),
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'buffer',
      expirationRevision: 3,
    );
    await decode.fill(
      demand: decodeDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final playbackClock = _Clock();
    final uploader = _Uploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: playbackClock,
    );
    final snapshots = <UploadSnapshot>[];
    upload.addSnapshotListener(snapshots.add);
    const uploadDemand = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'buffer',
      expirationRevision: 3,
    );
    await upload.prepare(
      demand: uploadDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final firstClaim = upload.claimPresent();
    expect(firstClaim, isNotNull);
    await upload.present(firstClaim!);
    firstClaim.release();
    snapshots.clear();

    expect(upload.preparedDepth, 0);
    final buffered = await decode.fill(
      demand: decodeDemand,
      revision: 2,
      cancel: CancelToken(),
      preparedDepth: upload.preparedDepth,
    );
    expect(buffered.depth, 1);
    final early = await upload.prepare(
      demand: uploadDemand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(early.frameIndex, 0);
    expect(decode.holder?.depth, 1);
    expect(uploader.outputs, hasLength(1));

    playbackClock.value = 16000;
    expect(upload.takeDueFrame(), 0);
    expect(upload.advance(0), isTrue);
    expect(
      snapshots,
      isEmpty,
      reason: 'advancing an animated output must not rebroadcast its old frame',
    );
    final replaced = await upload.prepare(
      demand: uploadDemand,
      revision: 3,
      cancel: CancelToken(),
    );
    expect(
      snapshots.map((snapshot) => snapshot.state),
      isNot(contains(UploadState.uploading)),
    );
    expect(replaced.frameIndex, 1);
    expect(uploader.outputs, hasLength(2));
    expect(uploader.outputs.first.disposed, isTrue);
    expect(uploader.outputs.last.disposed, isFalse);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('finite animation keeps its final output after decoder end', () async {
    final temp = await Directory.systemTemp.createTemp('upload_finite_test_');
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
      ingress: projection,
      cursors: _CursorFactory(
        frameLimit: 1,
        animation: const AnimationInfo(
          frameCount: 1,
          loopCount: 1,
          complete: true,
        ),
      ),
      clock: _Clock(),
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'finite',
      expirationRevision: 3,
    );
    await decode.fill(
      demand: decodeDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final playbackClock = _Clock();
    final uploader = _Uploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: playbackClock,
    );
    const uploadDemand = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'finite',
      expirationRevision: 3,
    );
    await upload.prepare(
      demand: uploadDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    final claim = upload.claimPresent();
    expect(claim, isNotNull);
    await upload.present(claim!);
    claim.release();
    playbackClock.value = 16000;
    expect(upload.takeDueFrame(), 0);
    expect(upload.advance(0), isTrue);
    expect(upload.frame?.index, 0);
    expect(upload.preparedDepth, 0);
    expect(uploader.outputs.single.disposed, isFalse);

    final ended = await decode.fill(
      demand: decodeDemand,
      revision: 2,
      cancel: CancelToken(),
      preparedDepth: upload.preparedDepth,
    );
    expect(ended.state, DecodeState.ended);
    final finalOutput = await upload.prepare(
      demand: uploadDemand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(finalOutput.state, UploadState.ready);
    expect(finalOutput.frameIndex, 0);
    expect(upload.preparedDepth, 1);
    expect(uploader.outputs.single.disposed, isFalse);

    upload.detach();
    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('accepts an aspect-fitted output inside DecodeId bounds', () async {
    final temp = await Directory.systemTemp.createTemp('upload_fit_test_');
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
      ingress: projection,
      cursors: _CursorFactory(width: 4, height: 8),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'fit',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: _Uploader(),
      clock: _Clock(),
    );

    final ready = await upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'fit',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    expect(ready.state, UploadState.ready);
    expect(upload.frame?.width, 4);
    expect(upload.frame?.height, 8);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('detach waits for an active upload before releasing the platform slot',
      () async {
    final temp = await Directory.systemTemp.createTemp('upload_detach_test_');
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
      ingress: projection,
      cursors: _CursorFactory(),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'detach-race',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final uploader = _ControlledUploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );

    final preparing = upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'detach-race',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    await uploader.started.future;
    upload.detach();
    expect(uploader.released, isEmpty);

    uploader.complete();
    await expectLater(
      preparing,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );
    expect(uploader.released, <DecodeId>[decode.id]);
    expect(uploader.output?.disposed, isTrue);
    expect(upload.state, UploadState.idle);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('dispose retires a pending generation uploader slot immediately', () async {
    final temp = await Directory.systemTemp.createTemp('upload_dispose_generation_');
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
      ingress: projection,
      cursors: _CursorFactory(),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'dispose-generation',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final uploader = _ControlledUploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );

    final preparing = upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'dispose-generation',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    await uploader.started.future;

    // Generation replacement can construct a new UploadSession with this same
    // logical DecodeId immediately after dispose(). The old session must retire
    // its uploader slot now, not when this pending prepare eventually unwinds.
    upload.dispose();
    expect(uploader.released, <DecodeId>[decode.id]);
    expect(upload.state, UploadState.disposed);

    uploader.complete();
    await expectLater(
      preparing,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );
    expect(uploader.released, <DecodeId>[decode.id]);
    expect(uploader.output?.disposed, isTrue);

    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('superseded uploads serialize one platform slot per decode identity',
      () async {
    final temp = await Directory.systemTemp.createTemp('upload_serial_test_');
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
      ingress: projection,
      cursors: _CursorFactory(),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 2,
        reason: 'serial-upload',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    final uploader = _SequencedControlledUploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );

    final first = upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'first',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );
    await uploader.firstStarted.future;
    final second = upload.prepare(
      demand: const UploadDemand(
        role: PageRole.current,
        priority: 1000,
        reason: 'replacement',
        expirationRevision: 2,
      ),
      revision: 2,
      cancel: CancelToken(),
    );

    expect(uploader.calls, 1, reason: 'same DecodeId must not upload concurrently');
    uploader.complete(0);
    await expectLater(
      first,
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.cancelled,
      )),
    );
    await uploader.secondStarted.future;
    expect(uploader.calls, 2);
    uploader.complete(1);
    final ready = await second;

    expect(ready.state, UploadState.ready);
    expect(ready.frameIndex, 0);
    expect(uploader.outputs[0].disposed, isTrue);
    expect(uploader.outputs[1].disposed, isFalse);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('buffered successors continue after a transient decode failure',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'upload_buffered_decode_failure_test_',
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
    final decode = DecodeSession(
      id: _decodeId(download.id),
      ingress: projection,
      cursors: _BufferedFailureCursorFactory(),
      clock: _Clock(),
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 3,
      reason: 'buffered-failure',
      expirationRevision: 3,
    );
    await expectLater(
      decode.fill(
        demand: decodeDemand,
        revision: 1,
        cancel: CancelToken(),
      ),
      throwsA(isA<Failure>()),
    );
    expect(decode.snapshot.state, DecodeState.failed);
    expect(decode.snapshot.depth, 2);

    final uploader = _Uploader();
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );
    const uploadDemand = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'buffered-failure',
      expirationRevision: 3,
    );
    var result = await upload.prepare(
      demand: uploadDemand,
      revision: 1,
      cancel: CancelToken(),
    );
    expect(result.state, UploadState.ready);
    expect(result.frameIndex, 0);
    expect(decode.holder?.depth, 1);

    expect(upload.advance(0), isTrue);
    result = await upload.prepare(
      demand: uploadDemand,
      revision: 2,
      cancel: CancelToken(),
    );
    expect(result.state, UploadState.ready);
    expect(result.frameIndex, 1);
    expect(decode.holder?.depth, 0);

    upload.dispose();
    decode.dispose();
    await download.dispose();
    await temp.delete(recursive: true);
  });

  test('stale uploaded output is disposed and never replaces current state', () async {
    final temp = await Directory.systemTemp.createTemp('upload_stale_test_');
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
      ingress: projection,
      cursors: _CursorFactory(),
      clock: _Clock(),
    );
    await decode.fill(
      demand: const DecodeDemand(
        role: PageRole.current,
        priority: 1000,
        targetWatermark: 1,
        reason: 'test',
        expirationRevision: 1,
      ),
      revision: 1,
      cancel: CancelToken(),
    );

    final uploader = _Uploader(epochOffset: 1);
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: _Clock(),
    );

    await expectLater(
      upload.prepare(
        demand: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'stale',
          expirationRevision: 1,
        ),
        revision: 1,
        cancel: CancelToken(),
      ),
      throwsA(isA<Failure>().having(
        (error) => error.code,
        'code',
        ErrorCode.staleEpoch,
      )),
    );
    expect(uploader.outputs.single.disposed, isTrue);
    expect(upload.frame, isNull);

    upload.dispose();
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
      renderer: RendererKind.androidTexture,
    );

final class _Clock implements MonoClock {
  int value = 0;

  @override
  int nowMicros() => value;
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

final class _BufferedFailureCursorFactory implements CursorFactory {
  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _BufferedFailureCursor(epoch));
}

final class _BufferedFailureCursor implements FrameCursor {
  _BufferedFailureCursor(this.epoch);

  @override
  final int epoch;
  int next = 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (next >= 2) {
      throw StateError('transient buffered failure');
    }
    return CursorStep.frame(_Frame(epoch, next++));
  }

  @override
  void dispose() {}
}

final class _CursorFactory implements CursorFactory {
  _CursorFactory({
    this.width = 8,
    this.height = 8,
    this.duration = const Duration(milliseconds: 16),
    this.frameLimit,
    this.animation = const AnimationInfo(
      frameCount: 2,
      loopCount: 0,
      complete: true,
    ),
  });

  final int width;
  final int height;
  final Duration duration;
  final int? frameLimit;
  final AnimationInfo animation;
  final List<_Frame> frames = <_Frame>[];

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    final cursor = _Cursor(
      epoch,
      frames,
      width: width,
      height: height,
      duration: duration,
      frameLimit: frameLimit,
      animation: animation,
    );
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _Cursor implements FrameCursor, LoopCursor {
  _Cursor(
    this.epoch,
    this.frames, {
    required this.width,
    required this.height,
    required this.duration,
    required this.frameLimit,
    required this.animation,
  });

  @override
  final int epoch;
  final List<_Frame> frames;
  final int width;
  final int height;
  final Duration duration;
  final int? frameLimit;
  @override
  final AnimationInfo animation;
  @override
  int cycle = 0;
  int next = 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (frameLimit != null && next >= frameLimit!) {
      return const CursorStep.end();
    }
    final frame = _Frame(
      epoch,
      next++,
      width: width,
      height: height,
      duration: duration,
    );
    frames.add(frame);
    return CursorStep.frame(frame);
  }

  @override
  bool rewind() {
    final nextCycle = cycle + 1;
    if (!animation.allowsCycle(nextCycle)) {
      return false;
    }
    cycle = nextCycle;
    next = 0;
    return true;
  }

  @override
  void dispose() {}
}

final class _Frame
    implements
        FrameRef,
        FrameCycleInfo,
        FrameDecodeTiming,
        FrameNativeDecodeObservation {
  _Frame(
    this.epoch,
    this.index, {
    this.width = 8,
    this.height = 8,
    this.duration = const Duration(milliseconds: 16),
  });

  @override
  final int epoch;
  @override
  final int index;
  @override
  int get byteLength => 4;
  @override
  final Duration duration;
  @override
  final int width;
  @override
  final int height;
  @override
  bool disposed = false;
  @override
  int get cycle => 0;
  @override
  int get workerReadyMicros => 7;
  @override
  int get workerQueueMicros => 11;
  @override
  int get dispatchMicros => 13;
  @override
  int get nativeDecodeMicros => 17;
  @override
  int get nativeMetadataMicros => 19;
  @override
  int get workerRoundTripMicros => 49;
  @override
  int get workerIndex => 1;
  @override
  int get workerPlacementStatus => 1;
  @override
  int get nativePrepareMicros => 23;
  @override
  int get nativeCanvasPrepareMicros => 29;
  @override
  int get nativeFragmentDecodeMicros => 31;
  @override
  int get nativeCompositeMicros => 37;
  @override
  int get nativeFrameCopyMicros => 41;
  @override
  int get nativeThreadId => 1234;
  @override
  int get nativeCpuStart => 2;
  @override
  int get nativeCpuEnd => 3;
  @override
  int get nativeCpuAllowedMask => 15;
  @override
  int get nativeKnownFrameCount => 12;
  @override
  int get nativeFullCanvasFrameCount => 8;
  @override
  int get nativeIndependentFrameCount => 5;
  @override
  int get nativeMaxDependentRun => 3;

  @override
  void dispose() => disposed = true;
}

final class _Uploader implements FrameUploader {
  _Uploader({this.epochOffset = 0});

  final int epochOffset;
  final List<_Output> outputs = <_Output>[];
  final List<DecodeId> released = <DecodeId>[];

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) async {
    final output = _Output(
      epoch: frame.epoch + epochOffset,
      index: frame.index,
      width: frame.width,
      height: frame.height,
      duration: frame.duration,
    );
    outputs.add(output);
    return output;
  }

  @override
  void release(DecodeId id) => released.add(id);
}

final class _ControlledUploader implements FrameUploader {
  final Completer<void> started = Completer<void>();
  final Completer<OutputFrame> _result = Completer<OutputFrame>();
  final List<DecodeId> released = <DecodeId>[];
  _Output? output;

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) {
    output = _Output(
      epoch: frame.epoch,
      index: frame.index,
      width: frame.width,
      height: frame.height,
      duration: frame.duration,
    );
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete() {
    _result.complete(output!);
  }

  @override
  void release(DecodeId id) => released.add(id);
}

final class _SequencedControlledUploader implements FrameUploader {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final List<Completer<OutputFrame>> _results = <Completer<OutputFrame>>[];
  final List<_Output> outputs = <_Output>[];
  final List<DecodeId> released = <DecodeId>[];
  int calls = 0;

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) {
    final call = calls++;
    final output = _Output(
      epoch: frame.epoch,
      index: frame.index,
      width: frame.width,
      height: frame.height,
      duration: frame.duration,
    );
    outputs.add(output);
    final result = Completer<OutputFrame>();
    _results.add(result);
    if (call == 0) {
      firstStarted.complete();
    } else if (call == 1) {
      secondStarted.complete();
    }
    return result.future;
  }

  void complete(int index) => _results[index].complete(outputs[index]);

  @override
  void release(DecodeId id) => released.add(id);
}

final class _Output implements OutputFrame, OutputFrameTiming {
  _Output({
    required this.epoch,
    required this.index,
    required this.width,
    required this.height,
    required this.duration,
  });

  @override
  final int epoch;
  @override
  final int index;
  @override
  final int width;
  @override
  final int height;
  @override
  int get byteLength => width * height * 4;
  @override
  final Duration duration;
  @override
  RendererKind get renderer => RendererKind.androidTexture;
  @override
  bool disposed = false;
  int presented = 0;

  FramePresentationTiming? _lastPresentationTiming;

  @override
  FramePresentationTiming? get lastPresentationTiming =>
      _lastPresentationTiming;

  @override
  Future<void> present() async {
    presented++;
    _lastPresentationTiming = const FramePresentationTiming(
      channelRoundTripMicros: 101,
      platformQueueMicros: 23,
      platformUploadMicros: 200,
      platformRetainMicros: 31,
      platformBlitMicros: 37,
      surfaceReconfigureCount: 1,
      platformScheduleMicros: 41,
      platformScheduleQueueMicros: 29,
      platformScheduleCallMicros: 12,
      platformReplaceMicros: 42,
      platformResultDispatchMicros: 43,
      channelDispatchMicros: 6,
      fallbackDecodeMicros: 0,
      deadlineMissMicros: 0,
      path: FramePresentationPath.platform,
    );
  }

  @override
  void dispose() => disposed = true;
}
