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
      ingress: ingress,
    );
    final factory = _CursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      cursors: factory,
      clock: _Clock(),
    );

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
    );

    expect(result.state, DecodeState.ready);
    expect(result.depth, 2);
    expect(factory.created, 1);

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
      ingress: ingress,
    );
    final factory = _DelayedCursorFactory();
    final session = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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
      ingress: ingress,
    );
    final cursors = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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
      ingress: ingress,
    );
    final trace = MemoryTraceSink();
    final loops = _LoopCursorFactory(frameCount: 2, loopCount: 0);
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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

  test('finite animation enters ended after its play count is exhausted', () async {
    final temp = await Directory.systemTemp.createTemp('decode_end_test_');
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
      ingress: ingress,
    );
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
      cursors: _LoopCursorFactory(frameCount: 1, loopCount: 1),
      clock: _Clock(),
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
    expect(decode.holder!.consume(0), isTrue);
    final ended = await decode.fill(
      demand: demand,
      revision: 2,
      cancel: CancelToken(),
    );

    expect(ended.state, DecodeState.ended);
    expect(ended.cycle, 0);
    expect(ended.animation.loopCount, 1);

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
      ingress: ingress,
    );
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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
      ingress: ingress,
    );
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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

final class _Cursor implements FrameCursor {
  _Cursor(this.epoch);

  @override
  final int epoch;
  int next = 0;

  @override
  Future<CursorStep> decodeNext() async =>
      CursorStep.frame(_Frame(epoch, next++));

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

final class _LoopCursorFactory implements CursorFactory {
  _LoopCursorFactory({required this.frameCount, required this.loopCount});

  final int frameCount;
  final int loopCount;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
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

