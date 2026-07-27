import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

void main() {
  test('live coordinator runs added download demand through network lane', () async {
    final temp = await Directory.systemTemp.createTemp('live_coordinator_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.bin');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: source.uri,
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      index: index,
    );
    addTearDown(registry.dispose);
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      net: NetLane(maxActive: 1),
    );

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'test',
      expirationRevision: 2,
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    await coordinator.idle();
    final session = registry.find(id);
    expect(session?.state, DownloadState.promoted);
    expect(
      await File(session!.artifact.finalPath).readAsBytes(),
      <int>[1, 2, 3, 4],
    );
    expect((await index.get(id.key))?.state, CacheState.ready);
  });

  test('live coordinator retries a demanded network failure', () async {
    final temp = await Directory.systemTemp.createTemp('live_retry_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'retry',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/retry'),
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      index: index,
    );
    addTearDown(registry.dispose);
    final transport = _FlakyTransport(<int>[1, 2, 3]);
    final delays = <Duration>[];
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
      retry: const RetryPolicy(
        maxAttempts: 2,
        baseDelay: Duration(milliseconds: 10),
      ),
      sleep: (delay) async => delays.add(delay),
    );

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'retry',
      expirationRevision: 1,
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    await coordinator.idle();
    expect(transport.opens, 2);
    expect(delays, <Duration>[const Duration(milliseconds: 10)]);
    expect(registry.find(id)?.state, DownloadState.promoted);
  });

  test('download completion wakes a waiting decode demand', () async {
    final temp = await Directory.systemTemp.createTemp('live_decode_test_');
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPpayload'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'decode',
      ),
      sourceRevision: 'r1',
      canonicalUri: source.uri,
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final clock = _Clock();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      sources: sources,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: _TestCursorFactory(),
      clock: clock,
    );
    final uploader = _TestUploader();
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: uploader,
      clock: clock,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      decodes: decodes,
      uploads: uploads,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
      upload: UploadLane(maxActive: 1),
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'decode',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'decode',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'upload',
          expirationRevision: 2,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(id),
        ResourceId.decode(decodeId),
      },
    );

    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();

    expect(downloads.find(id)?.state, DownloadState.promoted);
    expect(decodes.find(decodeId)?.snapshot.depth, 0);
    expect(decodes.find(decodeId)?.state, DecodeState.ready);
    expect(uploads.find(decodeId)?.state, UploadState.ready);
    expect(uploader.outputs, hasLength(1));

    final claim = uploads.find(decodeId)?.claimPresent();
    expect(claim, isNotNull);
    await uploads.find(decodeId)!.present(claim!);
    claim.release();
    expect(coordinator.advanceFrame('reader', decodeId, 0), isTrue);
    await coordinator.idle();

    expect(uploader.outputs, hasLength(2));
    expect(uploads.find(decodeId)?.snapshot.frameIndex, 1);
    expect(decodes.find(decodeId)?.snapshot.depth, 0);

    await coordinator.dispose();
    uploads.dispose();
    decodes.dispose();
    await downloads.dispose();
    await temp.delete(recursive: true);
  });
}

final class _FlakyTransport implements Transport {
  _FlakyTransport(this.bytes);

  final List<int> bytes;
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    if (opens == 1) {
      throw const Failure(code: ErrorCode.network, message: 'first open fails');
    }
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
      validators: const Validators(etag: 'v1'),
      rangeSupported: false,
    );
  }
}

final class _TestSourceFactory implements SourceFactory {
  @override
  EncodedSource create({required int epoch, required int maxBytes}) =>
      _TestSource(epoch);
}

final class _TestSource implements EncodedSource {
  _TestSource(this.epoch);

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

final class _TestCursorFactory implements CursorFactory {
  @override
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => _TestCursor(epoch);
}

final class _TestCursor implements FrameCursor {
  _TestCursor(this.epoch);

  @override
  final int epoch;
  int next = 0;

  @override
  Future<FrameRef?> decodeNext() async => _TestFrame(epoch, next++);

  @override
  void dispose() {}
}

final class _TestFrame implements FrameRef {
  _TestFrame(this.epoch, this.index);

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

final class _TestUploader implements FrameUploader {
  final List<_TestOutput> outputs = <_TestOutput>[];

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) async {
    final output = _TestOutput(frame.epoch, frame.index);
    outputs.add(output);
    return output;
  }
}

final class _TestOutput implements OutputFrame {
  _TestOutput(this.epoch, this.index);

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
  RendererKind get renderer => RendererKind.flutterImage;
  @override
  bool disposed = false;

  @override
  Future<void> present() async {}

  @override
  void dispose() => disposed = true;
}
