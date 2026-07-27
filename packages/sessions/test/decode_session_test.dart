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
    factory.cursor.next.complete(frame);

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
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    final cursor = _Cursor(epoch);
    cursors.add(cursor);
    return cursor;
  }
}

final class _Cursor implements FrameCursor {
  _Cursor(this.epoch);

  @override
  final int epoch;
  int next = 0;

  @override
  Future<FrameRef?> decodeNext() async => _Frame(epoch, next++);

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

final class _DelayedCursorFactory implements CursorFactory {
  late final _DelayedCursor cursor;

  @override
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    cursor = _DelayedCursor(epoch);
    return cursor;
  }
}

final class _DelayedCursor implements FrameCursor {
  _DelayedCursor(this.epoch);

  @override
  final int epoch;
  final Completer<FrameRef?> next = Completer<FrameRef?>();

  @override
  Future<FrameRef?> decodeNext() => next.future;

  @override
  void dispose() {}
}

