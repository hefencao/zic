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
      ingress: ingress,
    );
    final cursorFactory = _CursorFactory();
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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
    final upload = UploadSession(
      id: decode.id,
      decode: decode,
      uploader: uploader,
      clock: playbackClock,
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
    playbackClock.value = 16000;
    expect(upload.takeDueFrame(), isNull);
    expect(upload.freezePlayback(), isTrue);
    upload.setPlayback(paused: false, speed: 1);
    playbackClock.value = 32000;
    expect(upload.takeDueFrame(), isNull);
    expect(upload.resumePlayback(), isTrue);
    expect(upload.playbackState, PlaybackState.running);
    playbackClock.value = 47999;
    expect(upload.takeDueFrame(), isNull);
    playbackClock.value = 48000;
    expect(upload.takeDueFrame(), 0);
    expect(upload.playbackState, PlaybackState.idle);
    expect(snapshots.any((snapshot) => snapshot.state == UploadState.ready), isTrue);

    upload.detach();
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
      ingress: ingress,
    );
    final decode = DecodeSession(
      id: _decodeId(download.id),
      download: download,
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

final class _CursorFactory implements CursorFactory {
  final List<_Frame> frames = <_Frame>[];

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _Cursor(epoch, frames));
}

final class _Cursor implements FrameCursor {
  _Cursor(this.epoch, this.frames);

  @override
  final int epoch;
  final List<_Frame> frames;
  int next = 0;

  @override
  Future<CursorStep> decodeNext() async {
    final frame = _Frame(epoch, next++);
    frames.add(frame);
    return CursorStep.frame(frame);
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
  int get height => 8;
  @override
  int get width => 8;
  @override
  bool disposed = false;

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
    );
    outputs.add(output);
    return output;
  }

  @override
  void release(DecodeId id) => released.add(id);
}

final class _Output implements OutputFrame {
  _Output({required this.epoch, required this.index});

  @override
  final int epoch;
  @override
  final int index;
  @override
  int get width => 8;
  @override
  int get height => 8;
  @override
  int get byteLength => 256;
  @override
  Duration get duration => const Duration(milliseconds: 16);
  @override
  RendererKind get renderer => RendererKind.androidTexture;
  @override
  bool disposed = false;
  int presented = 0;

  @override
  Future<void> present() async {
    presented++;
  }

  @override
  void dispose() => disposed = true;
}
