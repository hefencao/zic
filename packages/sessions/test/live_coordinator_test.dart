import 'dart:async';
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


  test('active nonresumable transfer survives window detach and is not reopened',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('live_retained_download_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'retained',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/retained.webp'),
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
    final transport = _RetainedStreamTransport();
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'retained',
      expirationRevision: 8,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await transport.opened.future;
    transport.add('RIFF....WEBP'.codeUnits);
    await Future<void>.delayed(Duration.zero);
    expect(registry.find(id)?.activeRun, isTrue);

    final detached = DemandPlan(
      revision: 2,
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: const <ResourceId>{},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: detached,
        diff: DemandDiff.between(first, detached),
        window: const RoleWindow(<int, PageRole>{}),
      ),
    );
    expect(registry.find(id)?.demanded, isFalse);

    transport.add('payload'.codeUnits);
    await transport.close();
    await coordinator.idle();
    expect(registry.find(id)?.state, DownloadState.promoted);
    expect(transport.opens, 1);

    final revisited = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: revisited,
        diff: DemandDiff.between(detached, revisited),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    expect(transport.opens, 1);
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
    final trace = MemoryTraceSink();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      sources: sources,
      traceSink: trace,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: _TestCursorFactory(),
      clock: clock,
      traceSink: trace,
    );
    final uploader = _TestUploader();
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: uploader,
      clock: clock,
      traceSink: trace,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      traceSink: trace,
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
    final decodeDemand = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.decodeDemand,
    );
    final decodeStarted = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.decodeStarted,
    );
    final frameDecoded = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.frameDecoded,
    );
    final uploadDemand = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.uploadDemand,
    );
    final uploadStarted = trace.events.firstWhere(
      (event) => event.kind == TraceEventKind.uploadStarted,
    );
    expect(decodeDemand.revision, 1);
    expect(decodeStarted.revision, 1);
    expect(frameDecoded.revision, 1);
    expect(uploadDemand.revision, 1);
    expect(uploadStarted.revision, 1);
    expect(decodeDemand.identityHash, decodeId.key);
    expect(uploadDemand.identityHash, decodeId.key);
    expect(decodeDemand.monotonicMicros, lessThan(decodeStarted.monotonicMicros));
    expect(decodeStarted.monotonicMicros, lessThan(frameDecoded.monotonicMicros));

    final claim = uploads.find(decodeId)?.claimPresent();
    expect(claim, isNotNull);
    await uploads.find(decodeId)!.present(claim!);
    claim.release();
    expect(coordinator.advanceFrame('reader', decodeId, 0), isTrue);
    await coordinator.idle();

    expect(uploader.outputs, hasLength(2));
    expect(uploads.find(decodeId)?.snapshot.frameIndex, 1);
    expect(decodes.find(decodeId)?.snapshot.depth, 0);
    expect(
      trace.events
          .where((event) => event.kind == TraceEventKind.decodeStarted)
          .length,
      lessThanOrEqualTo(4),
    );
    expect(
      trace.events
          .where((event) => event.kind == TraceEventKind.uploadStarted)
          .length,
      lessThanOrEqualTo(4),
    );

    await coordinator.dispose();
    uploads.dispose();
    decodes.dispose();
    await downloads.dispose();
    await temp.delete(recursive: true);
  });


  test('startup buffering chains current through later staged waterlines',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_startup_buffer_refill_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPstartup'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'startup',
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
    final trace = MemoryTraceSink();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      sources: SourcePool(
        factory: _TestSourceFactory(),
        budgetFor: (_) => 1024,
      ),
      traceSink: trace,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: _StartupAnimationCursorFactory(),
      clock: clock,
      traceSink: trace,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _TestUploader(),
      clock: clock,
      traceSink: trace,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      traceSink: trace,
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
          reason: 'startup-buffer',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'startup-buffer',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'startup-buffer',
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

    final upload = uploads.find(decodeId);
    final claim = upload?.claimPresent();
    expect(claim, isNotNull);
    await upload!.present(claim!);
    claim.release();
    expect(upload.startupBuffering, isTrue);

    coordinator.refreshDecodeScheduling('reader', only: decodeId);
    await coordinator.idle();

    expect(upload.startupBuffering, isFalse);
    expect(upload.playbackRunning, isTrue);
    expect(decodes.find(decodeId)!.snapshot.depth, greaterThanOrEqualTo(7));
    final stages = trace.events
        .where((event) => event.kind == TraceEventKind.decodeRefill)
        .map((event) => event.payload['stage'])
        .toList(growable: false);
    expect(stages, containsAllInOrder(<Object?>['c>2', 'c>4', 'c>6']));
    expect(
      trace.events
          .where((event) => event.kind == TraceEventKind.playbackBuffering)
          .map((event) => event.payload['state']),
      containsAllInOrder(<Object?>['waiting', 'ready']),
    );

    await coordinator.dispose();
    uploads.dispose();
    decodes.dispose();
    await downloads.dispose();
  });


  test('startup buffering defers but does not consume another source revision',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_startup_deferred_source_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final currentFile = File('${temp.path}/current.webp');
    await currentFile.writeAsBytes('RIFF....WEBPcurrent'.codeUnits);
    final currentId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'current-deferred',
      ),
      sourceRevision: 'r1',
      canonicalUri: currentFile.uri,
    );
    final nextId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'next-deferred',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/next-deferred.webp'),
    );
    DecodeId decodeId(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final currentDecode = decodeId(currentId);
    final nextDecode = decodeId(nextId);
    final clock = _Clock();
    final trace = MemoryTraceSink();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      sources: SourcePool(
        factory: _TestSourceFactory(),
        budgetFor: (_) => 1024,
      ),
      traceSink: trace,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: _StartupAnimationCursorFactory(),
      clock: clock,
      traceSink: trace,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _TestUploader(),
      clock: clock,
      traceSink: trace,
    );
    final nextTransport = _ControlledTransport();
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (uri) => uri == nextId.canonicalUri
          ? nextTransport
          : const FileTransport(),
      clock: clock,
      traceSink: trace,
      decodes: decodes,
      uploads: uploads,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
      upload: UploadLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      uploads.dispose();
      decodes.dispose();
      await downloads.dispose();
    });

    final initial = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        currentId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'startup-deferred',
          expirationRevision: 3,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        currentDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'startup-deferred',
          expirationRevision: 3,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        currentDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'startup-deferred',
          expirationRevision: 3,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(currentId),
        ResourceId.decode(currentDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: initial,
        diff: DemandDiff.between(DemandPlan.empty(), initial),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    final currentUpload = uploads.find(currentDecode);
    final claim = currentUpload?.claimPresent();
    expect(claim, isNotNull);
    await currentUpload!.present(claim!);
    claim.release();
    expect(currentUpload.startupBuffering, isTrue);

    final withNext = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{
        ...initial.downloads,
        nextId: const DownloadDemand(
          role: PageRole.far,
          priority: 760,
          reason: 'startup-deferred',
          expirationRevision: 4,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        ...initial.decodes,
        nextDecode: const DecodeDemand(
          role: PageRole.far,
          priority: 760,
          targetWatermark: 1,
          reason: 'startup-deferred',
          expirationRevision: 4,
        ),
      },
      uploads: initial.uploads,
      keep: <ResourceId>{
        ...initial.keep,
        ResourceId.download(nextId),
        ResourceId.decode(nextDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: withNext,
        diff: DemandDiff.between(initial, withNext),
        window: RoleWindow(
          const <int, PageRole>{0: PageRole.current, 1: PageRole.far},
        ),
      ),
    );
    nextTransport.add('RIFF....WEBPnext'.codeUnits);
    await nextTransport.close();
    await coordinator.idle();

    expect(decodes.find(nextDecode)?.snapshot.depth ?? 0, 0);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.retryScheduled &&
            event.payload['stage'] == 'decode-startup-deferred',
      ),
      isNotEmpty,
    );

    coordinator.refreshDecodeScheduling('reader', only: currentDecode);
    await coordinator.idle();
    expect(currentUpload.startupBuffering, isFalse);

    final promoted = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{
        currentId: const DownloadDemand(
          role: PageRole.previous,
          priority: 680,
          reason: 'startup-deferred',
          expirationRevision: 5,
        ),
        nextId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'startup-deferred',
          expirationRevision: 5,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        currentDecode: const DecodeDemand(
          role: PageRole.previous,
          priority: 680,
          targetWatermark: 2,
          reason: 'startup-deferred',
          expirationRevision: 5,
        ),
        nextDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'startup-deferred',
          expirationRevision: 5,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        nextDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'startup-deferred',
          expirationRevision: 5,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(currentId),
        ResourceId.download(nextId),
        ResourceId.decode(currentDecode),
        ResourceId.decode(nextDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: promoted,
        diff: DemandDiff.between(withNext, promoted),
        window: RoleWindow(
          const <int, PageRole>{0: PageRole.previous, 1: PageRole.current},
        ),
      ),
    );
    await coordinator.idle();

    expect(decodes.find(nextDecode)?.snapshot.depth, greaterThan(0));
  });

  test('source-ready prefetch refill is directed to its own decode id',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_directed_source_wake_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final currentId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'current',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/current.webp'),
    );
    final prefetchId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'prefetch',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/prefetch.webp'),
    );
    DecodeId decodeId(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final currentDecode = decodeId(currentId);
    final prefetchDecode = decodeId(prefetchId);
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
    final currentDecodeStarted = Completer<void>();
    final releaseCurrentDecode = Completer<void>();
    final prefetchDecoded = Completer<void>();
    final cursors = _DirectedWakeCursorFactory(
      currentDecodeStarted: currentDecodeStarted,
      releaseCurrentDecode: releaseCurrentDecode,
      prefetchDecoded: prefetchDecoded,
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: cursors,
      clock: clock,
    );
    final prefetchTransport = _ControlledTransport();
    final currentBytes = 'RIFF....WEBPcurrent'.codeUnits;
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (uri) => uri == prefetchId.canonicalUri
          ? prefetchTransport
          : _ImmediateTransport(currentBytes),
      clock: clock,
      decodes: decodes,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        currentId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'current',
          expirationRevision: 2,
        ),
        prefetchId: const DownloadDemand(
          role: PageRole.far,
          priority: 760,
          reason: 'prefetch',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        currentDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 8,
          reason: 'current',
          expirationRevision: 2,
        ),
        prefetchDecode: const DecodeDemand(
          role: PageRole.far,
          priority: 760,
          targetWatermark: 1,
          reason: 'prefetch',
          expirationRevision: 2,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{
        ResourceId.download(currentId),
        ResourceId.download(prefetchId),
        ResourceId.decode(currentDecode),
        ResourceId.decode(prefetchDecode),
      },
    );

    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(
          const <int, PageRole>{
            0: PageRole.current,
            1: PageRole.far,
          },
        ),
      ),
    );
    await currentDecodeStarted.future;
    prefetchTransport.add('RIFF....WEBPprefetch'.codeUnits);
    await prefetchTransport.close();

    await prefetchDecoded.future.timeout(const Duration(seconds: 1));
    expect(decodes.find(prefetchDecode)?.snapshot.depth, 1);

    releaseCurrentDecode.complete();
    await coordinator.idle();
    await coordinator.dispose();
    decodes.dispose();
    await downloads.dispose();
  });

  test('role promotion reaches an already active cursor decode request',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_decode_priority_promotion_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPpayload'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'priority',
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
    final cursors = _RolePromotionCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: cursors,
      clock: clock,
    );
    final trace = MemoryTraceSink();
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      traceSink: trace,
      decodes: decodes,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      await downloads.dispose();
    });

    DemandPlan plan({
      required int revision,
      required PageRole role,
      required int priority,
    }) =>
        DemandPlan(
          revision: revision,
          downloads: <DownloadId, DownloadDemand>{
            id: DownloadDemand(
              role: role,
              priority: priority,
              reason: 'priority',
              expirationRevision: revision + 2,
            ),
          },
          decodes: <DecodeId, DecodeDemand>{
            decodeId: DecodeDemand(
              role: role,
              priority: priority,
              targetWatermark: 1,
              reason: 'priority',
              expirationRevision: revision + 2,
            ),
          },
          uploads: const <DecodeId, UploadDemand>{},
          keep: <ResourceId>{
            ResourceId.download(id),
            ResourceId.decode(decodeId),
          },
        );

    final far = plan(revision: 1, role: PageRole.far, priority: 320);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: far,
        diff: DemandDiff.between(DemandPlan.empty(), far),
        window: RoleWindow(const <int, PageRole>{0: PageRole.far}),
      ),
    );
    await cursors.cursor.started.future;

    final current =
        plan(revision: 2, role: PageRole.current, priority: 1000);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: current,
        diff: DemandDiff.between(far, current),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    expect(cursors.cursor.promotions, 1);
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.decodePriorityPromoted,
      ),
      hasLength(1),
    );

    cursors.cursor.release.complete();
    await coordinator.idle();
    expect(decodes.find(decodeId)?.snapshot.depth, 1);
  });

  test('source revisions arriving during decode are drained exactly once',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_growth_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'growth',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/growth.webp'),
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
    final transport = _ControlledTransport();
    final initialStarted = Completer<void>();
    final initialRelease = Completer<void>();
    final followStarted = Completer<void>();
    final followRelease = Completer<void>();
    var decodeCalls = 0;
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
      onDecode: (id, demand, token) async {
        decodeCalls++;
        if (decodeCalls == 1) {
          initialStarted.complete();
          await initialRelease.future;
        } else if (decodeCalls == 2) {
          followStarted.complete();
          await followRelease.future;
        }
        token.throwIfCancelled();
      },
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'growth',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'growth',
          expirationRevision: 2,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
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
    await initialStarted.future;
    transport.add('RIFF....WEBP'.codeUnits);
    transport.add('first-growth'.codeUnits);
    initialRelease.complete();
    await followStarted.future;
    transport.add('second-growth'.codeUnits);
    await transport.close();
    followRelease.complete();
    await coordinator.idle();

    expect(
      decodeCalls,
      4,
      reason: 'initial demand, first source growth, accumulated growth, '
          'and the authoritative seal are distinct decode opportunities',
    );

    await coordinator.dispose();
    await downloads.dispose();
  });

  test('static output stays resident across a demand gap and page revisit',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_revisit_test_');
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPpayload'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'revisit',
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
    final trace = MemoryTraceSink();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      sources: sources,
      traceSink: trace,
    );
    final cursors = _StaticCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      cursors: cursors,
      clock: clock,
      traceSink: trace,
    );
    final uploader = _TestUploader();
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: uploader,
      clock: clock,
      traceSink: trace,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      traceSink: trace,
      decodes: decodes,
      uploads: uploads,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
      upload: UploadLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      uploads.dispose();
      decodes.dispose();
      await downloads.dispose();
    });

    DemandPlan plan({
      required int revision,
      required bool decode,
      required bool upload,
    }) =>
        DemandPlan(
          revision: revision,
          downloads: <DownloadId, DownloadDemand>{
            id: DownloadDemand(
              role: PageRole.current,
              priority: 1000,
              reason: 'revisit',
              expirationRevision: revision + 1,
            ),
          },
          decodes: decode
              ? <DecodeId, DecodeDemand>{
                  decodeId: DecodeDemand(
                    role: PageRole.near,
                    priority: 720,
                    targetWatermark: 1,
                    reason: 'revisit',
                    expirationRevision: revision + 1,
                  ),
                }
              : const <DecodeId, DecodeDemand>{},
          uploads: upload
              ? <DecodeId, UploadDemand>{
                  decodeId: UploadDemand(
                    role: PageRole.current,
                    priority: 1000,
                    reason: 'revisit',
                    expirationRevision: revision + 1,
                  ),
                }
              : const <DecodeId, UploadDemand>{},
          keep: <ResourceId>{
            ResourceId.download(id),
            if (decode) ResourceId.decode(decodeId),
          },
        );

    var prior = DemandPlan.empty();
    final visible = plan(revision: 1, decode: true, upload: true);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: visible,
        diff: DemandDiff.between(prior, visible),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    expect(uploads.find(decodeId)?.state, UploadState.ready);
    expect(decodes.find(decodeId)?.snapshot.depth, 0);
    expect(uploader.outputs, hasLength(1));

    prior = visible;
    final dormant = plan(revision: 2, decode: false, upload: false);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: dormant,
        diff: DemandDiff.between(prior, dormant),
        window: RoleWindow(const <int, PageRole>{0: PageRole.near}),
      ),
    );
    await coordinator.idle();
    expect(decodes.find(decodeId)?.snapshot.depth, 0);
    expect(cursors.created, 1);
    expect(uploads.find(decodeId)?.outputBytes, greaterThan(0));
    expect(
      trace.events.any(
        (event) => event.kind == TraceEventKind.staticFrameKept,
      ),
      isTrue,
    );
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.pageOutputReleased &&
            event.payload['reason'] == 'demand-detached',
      ),
      isFalse,
    );

    prior = dormant;
    final revisited = plan(revision: 3, decode: true, upload: true);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: revisited,
        diff: DemandDiff.between(prior, revisited),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    expect(uploads.find(decodeId)?.state, UploadState.ready);
    expect(uploader.outputs, hasLength(1),
        reason: 'revisit reuses the retained static output');
  });

}

final class _ImmediateTransport implements Transport {
  const _ImmediateTransport(this.bytes);

  final List<int> bytes;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: Stream<List<int>>.value(bytes),
        statusCode: 200,
        rangeStart: 0,
        totalLength: bytes.length,
        validators: const Validators(etag: 'immediate'),
        rangeSupported: false,
      );
}

final class _DirectedWakeCursorFactory implements CursorFactory {
  _DirectedWakeCursorFactory({
    required this.currentDecodeStarted,
    required this.releaseCurrentDecode,
    required this.prefetchDecoded,
  });

  final Completer<void> currentDecodeStarted;
  final Completer<void> releaseCurrentDecode;
  final Completer<void> prefetchDecoded;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    if (id.download.content.pageId == 'current') {
      return CursorBinding(
        frames: _BlockingCursor(
          epoch,
          started: currentDecodeStarted,
          release: releaseCurrentDecode,
        ),
      );
    }
    return CursorBinding(
      frames: _SignallingStaticCursor(epoch, decoded: prefetchDecoded),
    );
  }
}

final class _BlockingCursor implements FrameCursor {
  _BlockingCursor(
    this.epoch, {
    required this.started,
    required this.release,
  });

  @override
  final int epoch;
  final Completer<void> started;
  final Completer<void> release;
  int _next = 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return CursorStep.frame(_TestFrame(epoch, _next++));
  }

  @override
  void dispose() {}
}

final class _SignallingStaticCursor implements FrameCursor, LoopCursor {
  _SignallingStaticCursor(this.epoch, {required this.decoded});

  @override
  final int epoch;
  final Completer<void> decoded;
  bool _emitted = false;

  @override
  AnimationInfo get animation => const AnimationInfo(
        frameCount: 1,
        loopCount: 1,
        complete: true,
      );

  @override
  int get cycle => 0;

  @override
  bool rewind() => false;

  @override
  Future<CursorStep> decodeNext() async {
    if (_emitted) {
      return const CursorStep.end();
    }
    _emitted = true;
    if (!decoded.isCompleted) {
      decoded.complete();
    }
    return CursorStep.frame(_TestFrame(epoch, 0));
  }

  @override
  void dispose() {}
}


final class _RetainedStreamTransport implements Transport {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>();
  final Completer<void> opened = Completer<void>();
  int opens = 0;

  void add(List<int> bytes) => _controller.add(bytes);

  Future<void> close() => _controller.close();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    if (!opened.isCompleted) {
      opened.complete();
    }
    return ByteResponse(
      bytes: _controller.stream,
      statusCode: 200,
      rangeStart: 0,
      totalLength: null,
      validators: const Validators(),
      rangeSupported: false,
    );
  }
}

final class _ControlledTransport implements Transport {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>();

  void add(List<int> bytes) => _controller.add(bytes);

  Future<void> close() => _controller.close();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async =>
      ByteResponse(
        bytes: _controller.stream,
        statusCode: 200,
        rangeStart: 0,
        totalLength: null,
        validators: const Validators(etag: 'growth'),
        rangeSupported: false,
      );
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

final class _RolePromotionCursorFactory implements CursorFactory {
  final _RolePromotionCursor cursor = _RolePromotionCursor();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      CursorBinding(frames: cursor);
}

final class _RolePromotionCursor
    implements PrioritizableScheduledFrameCursor {
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
    return CursorStep.frame(_TestFrame(epoch, 0));
  }

  @override
  DecodePriorityPromotion promotePendingDecodeToCurrent() {
    promotions++;
    return DecodePriorityPromotion.queued;
  }

  @override
  void dispose() {}
}

final class _StaticCursorFactory implements CursorFactory {
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    final cursor = _StaticCursor(epoch);
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _StaticCursor implements FrameCursor, LoopCursor {
  _StaticCursor(this.epoch);

  @override
  final int epoch;
  bool _emitted = false;

  @override
  AnimationInfo get animation => const AnimationInfo(
        frameCount: 1,
        loopCount: 1,
        complete: true,
      );

  @override
  int get cycle => 0;

  @override
  bool rewind() => false;

  @override
  Future<CursorStep> decodeNext() async {
    if (_emitted) {
      return const CursorStep.end();
    }
    _emitted = true;
    return CursorStep.frame(_TestFrame(epoch, 0));
  }

  @override
  void dispose() {}
}


final class _StartupAnimationCursorFactory implements CursorFactory {
  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    final cursor = _StartupAnimationCursor(epoch);
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _StartupAnimationCursor implements FrameCursor, LoopCursor {
  _StartupAnimationCursor(this.epoch);

  @override
  final int epoch;
  int _next = 0;

  @override
  AnimationInfo get animation => const AnimationInfo(
        frameCount: 93,
        loopCount: 0,
        complete: true,
      );

  @override
  int get cycle => 0;

  @override
  bool rewind() => true;

  @override
  Future<CursorStep> decodeNext() async =>
      CursorStep.frame(_TestFrame(epoch, _next++));

  @override
  void dispose() {}
}

final class _TestCursorFactory implements CursorFactory {
  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) => CursorBinding(frames: _TestCursor(epoch));
}

final class _TestCursor implements FrameCursor {
  _TestCursor(this.epoch);

  @override
  final int epoch;
  int next = 0;

  @override
  Future<CursorStep> decodeNext() async =>
      CursorStep.frame(_TestFrame(epoch, next++));

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

  @override
  void release(DecodeId id) {}
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
