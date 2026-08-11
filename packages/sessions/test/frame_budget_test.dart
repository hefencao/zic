import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('frame budget preserves current and last outputs only', () async {
    final temp = await Directory.systemTemp.createTemp('frame_budget_test_');
    final clock = _Clock();
    final sources = SourcePool(
      factory: _SourceFactory(),
      budgetFor: (_) => 4096,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    late final DownloadRegistry downloads;
    downloads = DownloadRegistry(
      layout: CacheLayout(temp.path),
      clock: clock,
      onSessionCreated: ingresses.attach,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _CursorFactory(),
      clock: clock,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _Uploader(),
      clock: clock,
    );
    final current = _decodeId('current');
    final last = _decodeId('last');
    final near = _decodeId('near');

    for (final id in <DecodeId>[current, last, near]) {
      ingresses.get(downloads.get(id.download)).ingress.append(
        epoch: const SourceEpoch(0),
        offset: 0,
        bytes: 'RIFF....WEBPpayload'.codeUnits,
      );
      await decodes.fill(
        id,
        DecodeDemand(
          role: id == current ? PageRole.current : PageRole.near,
          priority: id == current ? 1000 : 500,
          targetWatermark: 2,
          reason: 'test',
          expirationRevision: 1,
        ),
        CancelToken(),
        revision: 1,
      );
      await uploads.prepare(
        id,
        UploadDemand(
          role: id == current
              ? PageRole.current
              : id == last
                  ? PageRole.last
                  : PageRole.near,
          priority: id == current
              ? 1000
              : id == last
                  ? 850
                  : 500,
          reason: 'test',
          expirationRevision: 1,
        ),
        CancelToken(),
        revision: 1,
      );
    }

    final report = FrameBudgeter(
      decodes: decodes,
      uploads: uploads,
      limits: const FrameBudget(
        decodedBytes: 250,
        outputBytes: 450,
        currentDecodedReserve: 100,
        currentOutputReserve: 100,
      ),
    ).enforce(
      decodeDemands: <DecodeId, DecodeDemand>{
        current: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 2,
          reason: 'test',
          expirationRevision: 1,
        ),
        near: const DecodeDemand(
          role: PageRole.near,
          priority: 500,
          targetWatermark: 1,
          reason: 'test',
          expirationRevision: 1,
        ),
      },
      uploadDemands: <DecodeId, UploadDemand>{
        current: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'test',
          expirationRevision: 1,
        ),
        last: const UploadDemand(
          role: PageRole.last,
          priority: 850,
          reason: 'test',
          expirationRevision: 1,
        ),
        near: const UploadDemand(
          role: PageRole.near,
          priority: 500,
          reason: 'test',
          expirationRevision: 1,
        ),
      },
    );

    expect(decodes.find(current)?.bytes, 200);
    expect(decodes.find(last)?.bytes, 0,
        reason: 'last keeps the output, not decoded successors');
    expect(decodes.find(near)?.bytes, 0);
    expect(uploads.find(current)?.outputBytes, 200);
    expect(uploads.find(last)?.outputBytes, 200);
    expect(uploads.find(near)?.outputBytes, 0);
    expect(report.currentDecoded, 200);
    expect(report.currentOutput, 400);
    expect(report.decodedFreed, 400);
    expect(report.outputFreed, 200);

    uploads.dispose();
    decodes.dispose();
    ingresses.dispose(downloads.sessions);
    sources.dispose();
    await downloads.dispose();
    await temp.delete(recursive: true);
  });

  test('undemanded output remains until the byte budget is exceeded', () async {
    final temp = await Directory.systemTemp.createTemp(
      'frame_budget_retained_static_test_',
    );
    final clock = _Clock();
    final sources = SourcePool(
      factory: _SourceFactory(),
      budgetFor: (_) => 4096,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    late final DownloadRegistry downloads;
    downloads = DownloadRegistry(
      layout: CacheLayout(temp.path),
      clock: clock,
      onSessionCreated: ingresses.attach,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _CursorFactory(),
      clock: clock,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _Uploader(),
      clock: clock,
    );
    final retained = _decodeId('retained');
    ingresses.get(downloads.get(retained.download)).ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpayload'.codeUnits,
    );
    await decodes.fill(
      retained,
      const DecodeDemand(
        role: PageRole.near,
        priority: 500,
        targetWatermark: 1,
        reason: 'retained-static',
        expirationRevision: 1,
      ),
      CancelToken(),
      revision: 1,
    );
    await uploads.prepare(
      retained,
      const UploadDemand(
        role: PageRole.near,
        priority: 500,
        reason: 'retained-static',
        expirationRevision: 1,
      ),
      CancelToken(),
      revision: 1,
    );

    final withinBudget = FrameBudgeter(
      decodes: decodes,
      uploads: uploads,
      limits: const FrameBudget(
        decodedBytes: 1024,
        outputBytes: 256,
        currentDecodedReserve: 0,
        currentOutputReserve: 0,
      ),
    ).enforce(
      decodeDemands: const <DecodeId, DecodeDemand>{},
      uploadDemands: const <DecodeId, UploadDemand>{},
    );
    expect(withinBudget.outputFreed, 0);
    expect(uploads.find(retained)?.outputBytes, 200);

    final overBudget = FrameBudgeter(
      decodes: decodes,
      uploads: uploads,
      limits: const FrameBudget(
        decodedBytes: 1024,
        outputBytes: 100,
        currentDecodedReserve: 0,
        currentOutputReserve: 0,
      ),
    ).enforce(
      decodeDemands: const <DecodeId, DecodeDemand>{},
      uploadDemands: const <DecodeId, UploadDemand>{},
    );
    expect(overBudget.outputFreed, 200);
    expect(uploads.find(retained)?.outputBytes, 0);

    uploads.dispose();
    decodes.dispose();
    ingresses.dispose(downloads.sessions);
    sources.dispose();
    await downloads.dispose();
    await temp.delete(recursive: true);
  });

  test('invalid current reserve is rejected', () {
    expect(
      () => const FrameBudget(
        decodedBytes: 100,
        outputBytes: 100,
        currentDecodedReserve: 101,
        currentOutputReserve: 0,
      ).validate(),
      throwsArgumentError,
    );
  });
}

DecodeId _decodeId(String page) => DecodeId(
      download: DownloadId(
        content: ContentId(
          sourceId: 'source',
          comicId: 'comic',
          chapterId: 'chapter',
          pageId: page,
        ),
        sourceRevision: 'r1',
        canonicalUri: Uri.parse('https://example.test/$page.webp'),
      ),
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
  final List<int> data = <int>[];
  @override
  int get length => data.length;
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
    if (offset != data.length) return SourceStatus.invalidOffset;
    data.addAll(bytes);
    return SourceStatus.ok;
  }

  @override
  SourceStatus reset(int epoch) {
    this.epoch = epoch;
    data.clear();
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
  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _Cursor(epoch));
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
  int get width => 8;
  @override
  int get height => 8;
  @override
  int get byteLength => 100;
  @override
  Duration get duration => const Duration(milliseconds: 16);
  @override
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}

final class _Uploader implements FrameUploader {
  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) async => _Output(frame.epoch, frame.index);

  @override
  void release(DecodeId id) {}
}

final class _Output implements OutputFrame {
  _Output(this.epoch, this.index);

  @override
  final int epoch;
  @override
  final int index;
  @override
  int get width => 8;
  @override
  int get height => 8;
  @override
  int get byteLength => 200;
  @override
  Duration get duration => const Duration(milliseconds: 16);
  @override
  RendererKind get renderer => RendererKind.flutterImage;
  @override
  bool disposed = false;

  @override
  Future<void> present() async {}

  @override
  void dispose() => disposed = true;
}
