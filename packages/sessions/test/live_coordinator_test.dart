import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:testkit/testkit.dart';
import 'package:transport/transport.dart';

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

void main() {
  test('live coordinator runs added download demand through network lane', () async {
    final temp = await Directory.systemTemp.createTemp('live_coordinator_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));

    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.com/page.bin'),
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
    final bytes = 'RIFF....WEBPpage'.codeUnits;
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => FakeTransport(bytes: bytes),
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
      bytes,
    );
    expect((await index.get(id.key))?.state, CacheState.ready);
  },
  );

  test('Reader-local source follows media demand rather than download-window retention', () async {
    final temp = await Directory.systemTemp.createTemp('live_source_lifetime_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'source-lifetime',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/source-lifetime.webp'),
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'source-lifetime',
    );
    final sourceKinds = <ContentKind>[];
    final coordinator = LiveCoordinator(
      registry: registry,
      ingresses: ingresses,
      transportFor: (_) =>
          FakeTransport(bytes: <int>[...'RIFF....WEBPsource'.codeUnits]),
      clock: clock,
      onDecode: (_, _, _) async {},
      onSourceKindObserved: (_, kind) => sourceKinds.add(kind),
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      ingresses.dispose();
      sources.dispose();
      await registry.dispose();
    });

    final withMedia = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'source-lifetime',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'source-lifetime',
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
        plan: withMedia,
        diff: DemandDiff.between(DemandPlan.empty(), withMedia),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    expect(ingresses.find(id), isNotNull);
    expect(sources.find(id), isNotNull);
    expect(registry.find(id), isNotNull);
    expect(sourceKinds, contains(ContentKind.webp));
    final unknownBeforeConsumerRelease =
        sourceKinds.where((kind) => kind == ContentKind.unknown).length;

    final downloadOnly = DemandPlan(
      revision: 2,
      downloads: withMedia.downloads,
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: downloadOnly,
        diff: DemandDiff.between(withMedia, downloadOnly),
        window: RoleWindow(const <int, PageRole>{0: PageRole.next2}),
      ),
    );

    expect(coordinator.demands, contains(id));
    expect(registry.find(id), isNotNull,
        reason: 'encoded transfer retention is independent from Reader media',
      );
    expect(ingresses.find(id), isNull);
    expect(sources.find(id), isNull);
    expect(
      sourceKinds.where((kind) => kind == ContentKind.unknown).length,
      unknownBeforeConsumerRelease,
      reason: 'consumer source release is not negative content-kind evidence',
    );

    final withMediaAgain = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'source-lifetime',
          expirationRevision: 4,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'source-lifetime',
          expirationRevision: 4,
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
        plan: withMediaAgain,
        diff: DemandDiff.between(downloadOnly, withMediaAgain),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();

    expect(ingresses.find(id), isNotNull);
    expect(sources.find(id), isNotNull);
    expect(
      sourceKinds.where((kind) => kind == ContentKind.unknown).length,
      unknownBeforeConsumerRelease,
      reason: 'reacquiring the same source must not oscillate WebP cost evidence',
    );
  },
  );

  test('durable resident needMoreData expands Reader prefix and wakes decode',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_resident_need_more_data_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'resident-need-more-data',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/resident-need-more.webp'),
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final initialQuantum = webpDecodePrefixQuantumBytesFor(id);
    final totalLength = initialQuantum * 2 + 4096;
    final bytes = List<int>.filled(totalLength, 0);
    final header = 'RIFF....WEBP'.codeUnits;
    bytes.setRange(0, header.length, header);
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = registry.get(id);
    physical.bindResidentImmutableAuthority(
      validators: const Validators(etag: '"resident-ready"'),
      totalLength: totalLength,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );
    final ranges = <(int, int)>[];
    final trace = MemoryTraceSink();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => totalLength + 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'resident-need-more-data',
      traceSink: trace,
      residentReplayRangeSourceWithControl:
          (session, start, endExclusive, {required control}) async {
        expect(session, same(physical));
        control.throwIfCancelled();
        ranges.add((start, endExclusive));
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive),
              );
      },
    );
    final cursorFactory =
        _NeedMoreDataCursorFactory(requiredLength: initialQuantum * 2,
      );
    final decodes = DecodeRegistry(
      downloads: registry,
      ingresses: ingresses,
      cursors: cursorFactory,
      clock: clock,
      traceSink: trace,
    );
    final coordinator = LiveCoordinator(
      registry: registry,
      ingresses: ingresses,
      decodes: decodes,
      transportFor: (_) =>
          FakeTransport(bytes: <int>[...'RIFF....WEBPunused'.codeUnits]),
      clock: clock,
      traceSink: trace,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      ingresses.dispose();
      sources.dispose();
      await registry.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'resident-need-more-data',
          expirationRevision: 2,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.decode(decodeId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    for (var turn = 0; turn < 500 && !cursorFactory.frameDecoded.isCompleted; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (!cursorFactory.frameDecoded.isCompleted) {
      final decodeSnapshot = decodes.find(decodeId)?.snapshot;
      final ingressSnapshot = ingresses.find(id)?.snapshot;
      fail(
        'resident needMoreData chain stalled: ranges=$ranges '
        'decode=$decodeSnapshot ingress=$ingressSnapshot '
        'events=${trace.events.map((event) => "${event.kind.name}:${event.payload}").join(" | ")}',
      );
    }
    final snapshot = decodes.find(decodeId)?.snapshot;
    expect(snapshot?.depth, 1);
    expect(snapshot?.state, DecodeState.ready);
    expect(ranges, contains((0, initialQuantum)));
    expect(ranges, contains((initialQuantum, totalLength)),
        reason: 'durable SAF replay uses the physical-local decode quantum and '
            'clamps its next growth step to durable EOF',
      );
    expect(cursorFactory.needMoreCount, 1,
        reason: 'decoder evidence should request one larger durable prefix',
      );
    expect(ingresses.find(id)?.snapshot.length, totalLength);
    expect(physical.artifact.committedLength, 0,
        reason: 'decoder-driven hydration must not recreate a session artifact',
      );
  },
  );

  test('download priority migration does not re-observe physical identity', () async {
    final temp = await Directory.systemTemp.createTemp('live_identity_observe_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'identity-observe',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/identity-observe.bin'),
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
    var observed = 0;
      var compositionFinds = 0;
      final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => FakeTransport(bytes: const <int>[1, 2, 3]),
      clock: clock,
      net: NetLane(maxActive: 1),
      onDownloadObserved: (_) => observed++,
        findDownloadSession: (candidate) {
          compositionFinds++;
          return registry.find(candidate);
        },
    );
    addTearDown(coordinator.dispose);

    DemandPlan plan(int revision, int priority) => DemandPlan(
          revision: revision,
          downloads: <DownloadId, DownloadDemand>{
            id: DownloadDemand(
              role: priority >= 1000 ? PageRole.current : PageRole.next,
              priority: priority,
              reason: 'identity-observe',
              expirationRevision: revision + 1,
            ),
          },
          decodes: const <DecodeId, DecodeDemand>{},
          uploads: const <DecodeId, UploadDemand>{},
          keep: <ResourceId>{ResourceId.download(id)},
        );

    final first = plan(1, 1000);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    expect(observed, 1);
      expect(compositionFinds, 0);

      final changed = plan(2, 700);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: changed,
        diff: DemandDiff.between(first, changed),
        window: RoleWindow(const <int, PageRole>{0: PageRole.next}),
      ),
    );
    expect(observed, 1);
      expect(
        compositionFinds,
        0,
        reason:
            'scheduling-only migration must use the acquire-time physical carrier',
      );
    },
  );

  test('priority-role migration stays aggregate in reconcile trace', () async {
    final temp = await Directory.systemTemp.createTemp('live_trace_migration_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'trace-migration',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/trace-migration.webp'),
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 320,
      physicalHeight: 480,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final clock = _Clock();
    final trace = MemoryTraceSink();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      index: index,
    );
    addTearDown(registry.dispose);
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => FakeTransport(bytes: const <int>[1]),
      clock: clock,
      traceSink: trace,
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    DemandPlan plan(int revision, PageRole role, int priority) => DemandPlan(
          revision: revision,
          downloads: const <DownloadId, DownloadDemand>{},
          decodes: <DecodeId, DecodeDemand>{
            decodeId: DecodeDemand(
              role: role,
              priority: priority,
              targetWatermark: 1,
              reason: 'trace-migration',
              expirationRevision: revision + 1,
            ),
          },
          uploads: <DecodeId, UploadDemand>{
            decodeId: UploadDemand(
              role: role,
              priority: priority,
              reason: 'trace-migration',
              expirationRevision: revision + 1,
            ),
          },
          keep: <ResourceId>{ResourceId.decode(decodeId)},
        );

    final first = plan(1, PageRole.current, 1000);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.decodeDemand),
      hasLength(1),
    );
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.uploadDemand),
      hasLength(1),
    );

    final changed = plan(2, PageRole.transition, 900);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: changed,
        diff: DemandDiff.between(first, changed),
        window: RoleWindow(const <int, PageRole>{0: PageRole.transition}),
      ),
    );

    expect(
      trace.events.where((event) => event.kind == TraceEventKind.decodeDemand),
      hasLength(1),
    );
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.uploadDemand),
      hasLength(1),
    );
    final timing = trace.events.lastWhere(
      (event) => event.kind == TraceEventKind.pipelineReconcileTiming,
    );
    expect(timing.payload['decodeChanged'], 1);
    expect(timing.payload['uploadChanged'], 1);
  });

  test('large unsupported-range catchup waits for foreground-adjacent demand',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_catchup_defer_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'catchup-defer',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/catchup-defer.webp'),
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
    final session = registry.get(id);
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(2 * 1024 * 1024, (index) => index & 0xff),
    ];
    await expectLater(
      DownloadJob(
        transport: FakeTransport(
          bytes: bytes,
          chunkSize: 16 * 1024,
          failAfterBytes: 1536 * 1024,
          validators: const Validators(),
        ),
        session: session,
      ).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    expect(preservedLength, greaterThanOrEqualTo(1024 * 1024));

    final transport = FakeTransport(
      bytes: bytes,
      chunkSize: 16 * 1024,
      rangeSupported: false,
      validators: const Validators(),
    );
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    const backgroundDemand = DownloadDemand(
      role: PageRole.next2,
      priority: 800,
      reason: 'costly-catchup-background',
      expirationRevision: 8,
    );
    final background = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: backgroundDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: background,
        diff: DemandDiff.between(DemandPlan.empty(), background),
        window: RoleWindow(const <int, PageRole>{2: PageRole.next2}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(1));
    expect(transport.discardCount, 1);
    expect(session.committedLength, preservedLength);
    expect(session.state, DownloadState.idle);

    const stillBackgroundDemand = DownloadDemand(
      role: PageRole.previous,
      priority: 780,
      reason: 'costly-catchup-still-background',
      expirationRevision: 9,
    );
    final stillBackground = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{id: stillBackgroundDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: stillBackground,
        diff: DemandDiff.between(background, stillBackground),
        window: RoleWindow(const <int, PageRole>{-1: PageRole.previous}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(1));

    final detached = DemandPlan(
      revision: 3,
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: const <ResourceId>{},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: detached,
        diff: DemandDiff.between(stillBackground, detached),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(1));

    final readdedBackground = DemandPlan(
      revision: 4,
      downloads: <DownloadId, DownloadDemand>{id: stillBackgroundDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: readdedBackground,
        diff: DemandDiff.between(detached, readdedBackground),
        window: RoleWindow(const <int, PageRole>{-1: PageRole.previous}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(1));

    const foregroundDemand = DownloadDemand(
      role: PageRole.next,
      priority: 820,
      reason: 'costly-catchup-foreground-adjacent',
      expirationRevision: 10,
    );
    final foreground = DemandPlan(
      revision: 5,
      downloads: <DownloadId, DownloadDemand>{id: foregroundDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: foreground,
        diff: DemandDiff.between(readdedBackground, foreground),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(2));
    expect(
      transport.requests[1].range?.start,
      preservedLength - 64 * 1024);
    expect(session.state, DownloadState.promoted);
    expect(await File(session.artifact.finalPath).readAsBytes(), bytes);
  },
  );

  test('very large unsupported-range partial waits for transition demand',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_catchup_tier_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'catchup-tier',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/catchup-tier.webp'),
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
    final session = registry.get(id);
    final bytes = Uint8List(9 * 1024 * 1024 + 256 * 1024);
    bytes.setAll(0, 'RIFF'.codeUnits);
    bytes.setAll(8, 'WEBP'.codeUnits);
    await expectLater(
      DownloadJob(
        transport: FakeTransport(
          bytes: bytes,
          chunkSize: 256 * 1024,
          failAfterBytes: 8 * 1024 * 1024 + 128 * 1024,
          validators: const Validators(),
        ),
        session: session,
      ).run(),
      throwsA(isA<Failure>()),
    );
    final preservedLength = session.committedLength;
    expect(preservedLength, greaterThanOrEqualTo(8 * 1024 * 1024));

    final transport = FakeTransport(
      bytes: bytes,
      chunkSize: 256 * 1024,
      rangeSupported: false,
      validators: const Validators(),
    );
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    const nextDemand = DownloadDemand(
      role: PageRole.next,
      priority: 820,
      reason: 'very-large-catchup-next',
      expirationRevision: 8,
    );
    final next = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: nextDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: next,
        diff: DemandDiff.between(DemandPlan.empty(), next),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(1));
    expect(session.state, DownloadState.idle);
    expect(session.committedLength, preservedLength);

    const transitionDemand = DownloadDemand(
      role: PageRole.transition,
      priority: 900,
      reason: 'very-large-catchup-transition',
      expirationRevision: 9,
    );
    final transition = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{id: transitionDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: transition,
        diff: DemandDiff.between(next, transition),
        window: RoleWindow(const <int, PageRole>{0: PageRole.transition}),
      ),
    );
    await coordinator.idle();
    expect(transport.requests, hasLength(2));
    expect(session.state, DownloadState.promoted);
    expect(await File(session.artifact.finalPath).readAsBytes(), bytes);
  },
  );

  test('active nonresumable transfer survives window detach and is not reopened',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('live_retained_download_test_',
      );
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
    expect(registry.find(id)?.state, DownloadState.receiving);

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
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    expect(registry.find(id)?.demanded, isFalse);
    expect(
      coordinator.net.priorityOf(coordinator.downloadTaskKeyFor(id)!),
      0,
    );

    // A short forward/back gesture must reuse the same receiving transport,
    // not cancel and reopen it. This matches VibeVenera's logical-detach
    // policy: receiving work is retained until real priority pressure needs
    // the slot.
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
    await Future<void>.delayed(Duration.zero);
    expect(registry.find(id)?.demanded, isTrue);
    expect(
      coordinator.net.priorityOf(coordinator.downloadTaskKeyFor(id)!),
      1000,
    );
    expect(transport.opens, 1);

    transport.add('payload'.codeUnits);
    await transport.close();
    await coordinator.idle();
    expect(registry.find(id)?.state, DownloadState.promoted);
    expect(transport.opens, 1);
  },
  );

  test('remaining consumer claim keeps transfer and downgrades priority',
      () async {
    final temp = await Directory.systemTemp
        .createTemp('live_multi_consumer_claim_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'multi-consumer',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/multi-consumer.webp'),
    );
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final transport = _RetainedStreamTransport();
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: clock,
      net: NetLane(maxActive: 1),
    );

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'reader-a',
      expirationRevision: 2,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: demand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader-a',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await transport.opened.future;
    transport.add('RIFF....WEBP'.codeUnits);
    await Future<void>.delayed(Duration.zero);

    final session = registry.get(id);
    final other = session.attachDemand(scopeId: 'reader-b', priority: 700);
    final detached = DemandPlan(
      revision: 2,
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: const <ResourceId>{},
    );
    coordinator.reconcile(
      'reader-a',
      PipelineDelta(
        plan: detached,
        diff: DemandDiff.between(first, detached),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );

    expect(session.demanded, isTrue);
    expect(session.demandCount, 1);
    expect(session.effectivePriority, 700);
    expect(
      coordinator.net.priorityOf(coordinator.downloadTaskKeyFor(id)!),
      700,
    );
    expect(transport.opens, 1);

    transport.add('payload'.codeUnits);
    await transport.close();
    await coordinator.net.idle();
    await coordinator.idle();
    expect(session.state, DownloadState.promoted);
    expect(transport.opens, 1);

    other.detach();
    await coordinator.dispose();
    await registry.dispose();
  },
  );

  test('detached receiving survives adjacent previous pressure', () async {
    final temp =
        await Directory.systemTemp.createTemp('live_receiving_pressure_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final retainedId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'retained-pressure',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/retained-pressure.webp'),
    );
    final previousId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'previous-pressure',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/previous-pressure.webp'),
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
    final retained = _RetainedStreamTransport();
    final previous = _BytesTransport('RIFF....WEBPprevious'.codeUnits);
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (uri) => uri == retainedId.canonicalUri ? retained : previous,
      clock: clock,
      net: NetLane(
        maxActive: 1,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 1000,
        preemptionThreshold: 40,
      ),
    );
    addTearDown(coordinator.dispose);

    const retainedDemand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'receiving-before-detach',
      expirationRevision: 8,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{retainedId: retainedDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(retainedId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await retained.opened.future;
    retained.add('RIFF....WEBP'.codeUnits);
    await Future<void>.delayed(Duration.zero);
    final retainedSession = registry.find(retainedId);
    expect(retainedSession?.state, DownloadState.receiving);
    expect(retainedSession?.activeRun, isTrue);

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
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    expect(
      coordinator.net.priorityOf(coordinator.downloadTaskKeyFor(retainedId)!),
      0,
    );
    expect(retainedSession?.activeRun, isTrue);

    const previousDemand = DownloadDemand(
      role: PageRole.previous,
      priority: 780,
      reason: 'adjacent-previous-pressure',
      expirationRevision: 9,
    );
    final pressured = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{previousId: previousDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(previousId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: pressured,
        diff: DemandDiff.between(detached, pressured),
        window: RoleWindow(const <int, PageRole>{-1: PageRole.previous}),
      ),
    );

    await Future<void>.delayed(Duration.zero);
    expect(previous.opened.isCompleted, isFalse);
    expect(retainedSession?.activeRun, isTrue);
    expect(retained.cancelled.isCompleted, isFalse);

    await retained.close();
    await previous.opened.future.timeout(const Duration(seconds: 1));
    await coordinator.idle();
    expect(retainedSession?.activeRun, isFalse);
    expect(registry.find(previousId)?.state, DownloadState.promoted);
    expect(retained.opens, 1);
  });

  test('detached pre-open run drops to rank zero and yields only to current', () async {
    final temp =
        await Directory.systemTemp.createTemp('live_preopen_detach_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final openingId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'opening',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/opening.webp'),
    );
    final previousId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'previous',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/previous.webp'),
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
    final opening = _BlockedControlledTransport();
    final previous = _BytesTransport('RIFF....WEBPprevious'.codeUnits);
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (uri) => uri == openingId.canonicalUri ? opening : previous,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    const openingDemand = DownloadDemand(
      role: PageRole.next,
      priority: 820,
      reason: 'opening-prefetch',
      expirationRevision: 8,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{openingId: openingDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(openingId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );
    await opening.opened.future;
    final openingSession = registry.find(openingId);
    expect(openingSession?.activeRun, isTrue);
    expect(openingSession?.state, DownloadState.queued);

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
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    final openingKey = coordinator.downloadTaskKeyFor(openingId)!;
    expect(coordinator.net.isActive(openingKey), isTrue);
    expect(coordinator.net.priorityOf(openingKey), 0);
    expect(opening.cancelled.isCompleted, isFalse);

    const previousDemand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'current-pressure',
      expirationRevision: 9,
    );
    final second = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{previousId: previousDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(previousId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: second,
        diff: DemandDiff.between(detached, second),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );

    await opening.cancelled.future.timeout(const Duration(seconds: 1));
    await previous.opened.future.timeout(const Duration(seconds: 1));
    await coordinator.idle();
    expect(openingSession?.activeRun, isFalse);
    expect(registry.find(previousId)?.state, DownloadState.promoted);
  },
  );

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
    final transport = _FlakyTransport('RIFF....WEBPretry'.codeUnits);
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

  test('terminal source failure survives scheduling-only demand changes',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_terminal_failure_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'terminal',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/terminal'),
    );
    final index = MemIndex();
    await index.open();
    addTearDown(index.close);
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: _Clock(),
      index: index,
    );
    addTearDown(registry.dispose);
    final transport = _AlwaysFailTransport(
      const Failure(code: ErrorCode.source, message: 'deterministic source failure',
        ),
    );
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (_) => transport,
      clock: _Clock(),
      net: NetLane(maxActive: 1),
    );
    addTearDown(coordinator.dispose);

    const demand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'terminal',
      expirationRevision: 1,
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
    await coordinator.idle();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(transport.opens, 1);

    const changedDemand = DownloadDemand(
      role: PageRole.current,
      priority: 999,
      reason: 'scheduling-only-demand-change',
      expirationRevision: 2,
    );
    final second = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{id: changedDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(id)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: second,
        diff: DemandDiff.between(first, second),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    await Future<void>.delayed(Duration.zero);
    expect(transport.opens, 1);
  },
  );

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
      traceSink: trace,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
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
      ingresses: ingresses,
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
        ResourceId.decode(decodeId)},
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
    expect(decodeDemand.identityHash, decodeStarted.identityHash);
    expect(decodeDemand.identityHash, frameDecoded.identityHash);
    expect(decodeDemand.identityHash, uploadDemand.identityHash);
    expect(decodeDemand.identityHash, uploadStarted.identityHash);
    expect(decodeDemand.monotonicMicros, lessThan(decodeStarted.monotonicMicros),
    );
    expect(decodeStarted.monotonicMicros, lessThan(frameDecoded.monotonicMicros),
    );

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
      lessThanOrEqualTo(6),
    );

    await coordinator.dispose();
    uploads.dispose();
    decodes.dispose();
    await downloads.dispose();
    await temp.delete(recursive: true);
  });


  test('same physical session epoch reset wakes fresh streaming source', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_same_session_epoch_reload_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPinitial'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'same-session-epoch-reload',
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
      traceSink: trace,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'same-session-epoch-reload',
    );
    final cursors = _StaticCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
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
      ingresses: ingresses,
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
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'same-session-epoch-reload',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'same-session-epoch-reload',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'same-session-epoch-reload',
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
    expect(cursors.created, 1);
    expect(uploader.outputs, hasLength(1));

    final session = downloads.find(id)!;
    final firstEpoch = session.epoch;
    await session.reset(deleteFinalArtifact: true);
    expect(session.epoch, isNot(firstEpoch));

    final run = session.beginRun();
    final writer = session.acquireWriter(expectedRun: run);
    final freshPrefix = 'RIFF....WEBPinitial'.codeUnits;
    await session.append(writer, 0, freshPrefix);

    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (cursors.created < 2 || uploader.outputs.length < 2) {
      if (DateTime.now().isAfter(deadline)) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      cursors.created,
      2,
      reason: 'the first source-ready prefix of a new epoch must wake decode',
    );
    expect(uploader.outputs, hasLength(2));
    expect(uploader.outputs.last.epoch, session.epoch.value);

    await session.pause(writer);
    session.endRun(run);
  },
  );

  test('draining the last buffered partial frame re-enters partial loop',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_partial_loop_late_wake_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'partial-loop',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/partial-loop.webp'),
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
      budgetFor: (_) => 1024 * 1024,
    );
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
      traceSink: trace,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final physical = downloads.get(id);
    final ingress = ingresses.get(physical);
    ingress.append(
      epoch: const SourceEpoch(0),
      offset: 0,
      bytes: 'RIFF....WEBPpartial-animation'.codeUnits,
    );
    final cursors = _LatePartialLoopCursorFactory(frameCount: 30);
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: cursors,
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
      ingresses: ingresses,
      transportFor: (_) => FakeTransport(bytes: const <int>[]),
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
      downloads: const <DownloadId, DownloadDemand>{},
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'partial-loop-current',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'partial-loop-current',
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

    var sawWaitingWithBufferedFrames = false;
    var advances = 0;
    while (cursors.created == 1 && advances < 40) {
      final decode = decodes.find(decodeId)!.snapshot;
      if (decode.state == DecodeState.waitingSource && decode.depth > 0) {
        sawWaitingWithBufferedFrames = true;
        expect(decode.partialPrefixLoopEligible, isFalse);
      }
      final frameIndex = uploads.find(decodeId)!.snapshot.frameIndex;
      expect(frameIndex, isNotNull);
      expect(
        coordinator.advanceFrame('reader', decodeId, frameIndex!),
        isTrue,
      );
      await coordinator.idle();
      advances++;
    }

    expect(sawWaitingWithBufferedFrames, isTrue);
    expect(cursors.created, 2,
        reason: 'last buffered frame must wake decoder to rewind the partial',
      );
    expect(decodes.find(decodeId)!.snapshot.cycle, 1);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.animationLoop &&
            event.payload['partialPrefix'] == true,
      ),
      hasLength(1),
    );

    await coordinator.dispose();
    uploads.dispose();
    decodes.dispose();
    await downloads.dispose();
  },
  );


  test('playback state never gates decode refill for other demanded pages',
      () async {
    // The directed source-wake test below covers the operational path. This
    // regression guard keeps the VibeVenera producer/consumer contract
    // explicit: LiveCoordinator has no startup-buffer eligibility gate.
    final path = File('lib/src/live_coordinator.dart').existsSync()
        ? 'lib/src/live_coordinator.dart'
        : 'packages/sessions/lib/src/live_coordinator.dart';
    final source = File(path).readAsStringSync();
    expect(source, isNot(contains('decode-startup-deferred')));
    expect(source, isNot(contains('_startupBufferingCurrent')));
    expect(source, isNot(contains('isStartupBuffering')));
  },
  );

  test('paged next preupload stays frozen until role promotion', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_paged_next_preupload_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'next',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/next.webp'),
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
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _LatePartialLoopCursorFactory(frameCount: 5),
      clock: clock,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _TestUploader(),
      clock: clock,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => _ImmediateTransport(
        'RIFF....WEBPnext'.codeUnits),
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
      ingresses.dispose();
      sources.dispose();
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
              reason: 'paged-next-preupload',
              expirationRevision: revision + 1,
            ),
          },
          decodes: <DecodeId, DecodeDemand>{
            decodeId: DecodeDemand(
              role: role,
              priority: priority,
              targetWatermark: role == PageRole.next ? 3 : 1,
              reason: 'paged-next-preupload',
              expirationRevision: revision + 1,
            ),
          },
          uploads: <DecodeId, UploadDemand>{
            decodeId: UploadDemand(
              role: role,
              priority: priority,
              reason: 'paged-next-preupload',
              expirationRevision: revision + 1,
            ),
          },
          keep: <ResourceId>{
            ResourceId.download(id),
            ResourceId.decode(decodeId)},
        );

    final nextPlan = plan(
      revision: 1,
      role: PageRole.next,
      priority: 820);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: nextPlan,
        diff: DemandDiff.between(DemandPlan.empty(), nextPlan),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );
    await coordinator.idle();
    final nextUpload = uploads.find(decodeId);
    expect(nextUpload, isNotNull);
    expect(nextUpload!.state, UploadState.ready);
    final claim = nextUpload.claimPresent();
    expect(claim, isNotNull);
    await nextUpload.present(claim!);
    expect(nextUpload.playbackState, PlaybackState.frozen);
    expect(nextUpload.playbackDeadlineMicros, isNull);
    claim.release();
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.uploadStarted &&
            event.identityHash == decodeId.key &&
            event.payload['priority'] == 820,
      ),
      hasLength(1),
      reason: 'decode refill behind frozen next must not re-enter UploadLane',
    );

    final transitionPlan = plan(
      revision: 2,
      role: PageRole.transition,
      priority: 900,
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: transitionPlan,
        diff: DemandDiff.between(nextPlan, transitionPlan),
        window: RoleWindow(
          const <int, PageRole>{1: PageRole.transition}),
      ),
    );
    await coordinator.idle();
    expect(nextUpload.playbackState, PlaybackState.running);
    expect(nextUpload.playbackDeadlineMicros, isNotNull);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.uploadStarted &&
            event.identityHash == decodeId.key,
      ),
      hasLength(1),
      reason: 'role promotion must reuse the resident animated output',
    );

    final nextAgainPlan = plan(
      revision: 3,
      role: PageRole.next,
      priority: 820);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: nextAgainPlan,
        diff: DemandDiff.between(transitionPlan, nextAgainPlan),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );
    await coordinator.idle();
    expect(nextUpload.playbackState, PlaybackState.frozen);
    expect(nextUpload.playbackDeadlineMicros, isNull);
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.uploadStarted &&
            event.identityHash == decodeId.key &&
            event.payload['priority'] == 820,
      ),
      hasLength(1),
      reason: 'viewport role oscillation must not restart hidden next upload',
    );
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
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
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
      ingresses: ingresses,
      cursors: cursors,
      clock: clock,
    );
    final prefetchTransport = _ControlledTransport();
    final currentBytes = 'RIFF....WEBPcurrent'.codeUnits;
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
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
          role: PageRole.transition,
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
          role: PageRole.transition,
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
            1: PageRole.transition,
          }),
      ),
    );
    await currentDecodeStarted.future;
    prefetchTransport.add('RIFF....WEBPprefetch'.codeUnits);
    await prefetchTransport.close();

    await prefetchDecoded.future.timeout(const Duration(seconds: 1));
      final prefetchCommitDeadline = DateTime.now().add(
        const Duration(seconds: 1),
      );
      while ((decodes.find(prefetchDecode)?.snapshot.depth ?? 0) < 1) {
        if (DateTime.now().isAfter(prefetchCommitDeadline)) {
          fail('prefetch cursor completed without committing decode depth');
        }
        await Future<void>.delayed(Duration.zero);
      }
      expect(decodes.find(prefetchDecode)?.snapshot.depth, 1);

    releaseCurrentDecode.complete();
    await coordinator.idle();
    await coordinator.dispose();
    decodes.dispose();
    await downloads.dispose();
  },
  );

  test('gated source revision survives until prefetch is promoted current',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_gated_source_revision_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final blockedId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'blocked-current',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/blocked-current.webp'),
    );
    final promotedId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'promoted-prefetch',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/promoted-prefetch.webp'),
    );
    DecodeId decodeId(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final blockedDecode = decodeId(blockedId);
    final promotedDecode = decodeId(promotedId);
    final clock = _Clock();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final cursors = _StaticCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: cursors,
      clock: clock,
    );
    const prefetchedDemand = DecodeDemand(
      role: PageRole.next2,
      priority: 780,
      targetWatermark: 3,
      reason: 'prefetch-next2',
      expirationRevision: 2,
    );

    // Reproduce the device failure shape: this decode holder already exists
    // and is waitingSource before the physical prefetch becomes sourceReady.
    final waiting = await decodes.fill(
      promotedDecode,
      prefetchedDemand,
      CancelToken(),
      revision: 0,
    );
    expect(waiting.state, DecodeState.waitingSource);

    final blockedTransport = _BlockedControlledTransport();
    final promotedBytes = 'RIFF....WEBPpromoted'.codeUnits;
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (uri) => uri == blockedId.canonicalUri
          ? blockedTransport
          : _ImmediateTransport(promotedBytes),
      clock: clock,
      decodes: decodes,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
    );
    final initial = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        blockedId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'blocked-current',
          expirationRevision: 2,
        ),
        promotedId: const DownloadDemand(
          role: PageRole.next2,
          priority: 780,
          reason: 'prefetch-next2',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        blockedDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'blocked-current',
          expirationRevision: 2,
        ),
        promotedDecode: prefetchedDemand,
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{
        ResourceId.download(blockedId),
        ResourceId.download(promotedId),
        ResourceId.decode(blockedDecode),
        ResourceId.decode(promotedDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: initial,
        diff: DemandDiff.between(DemandPlan.empty(), initial),
        window: RoleWindow(
          const <int, PageRole>{
            0: PageRole.current,
            2: PageRole.next2,
          }),
      ),
    );
    await blockedTransport.opened.future;

    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (!(ingresses.find(promotedId)?.snapshot.sourceReady ?? false)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('prefetched source never became ready');
      }
      await Future<void>.delayed(Duration.zero);
    }
    // Let the directed source-wake task run while current bootstrap gates it.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(decodes.find(promotedDecode)?.snapshot.state, DecodeState.waitingSource,
      );
    expect(decodes.find(promotedDecode)?.snapshot.depth, 0);

    final promoted = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{
        promotedId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'promoted-current',
          expirationRevision: 3,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        promotedDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 7,
          reason: 'promoted-current',
          expirationRevision: 3,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{
        ResourceId.download(promotedId),
        ResourceId.decode(promotedDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: promoted,
        diff: DemandDiff.between(initial, promoted),
        window: RoleWindow(const <int, PageRole>{2: PageRole.current}),
      ),
    );

    await coordinator.idle();
    final afterPromotion = decodes.find(promotedDecode)!.snapshot;
    expect(afterPromotion.depth, greaterThanOrEqualTo(1));
    expect(afterPromotion.state, isNot(DecodeState.waitingSource));
    expect(cursors.created, 1);

    await coordinator.dispose();
    decodes.dispose();
    await downloads.dispose();
  },
  );

  test(
      'logical source watch rebinds after aliased physical owner retires',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_source_watch_rebind_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final oldPhysicalId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'old',
        pageId: 'physical-old',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('https://example.test/old.webp'),
    );
    final logicalId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'new',
        pageId: 'logical-revisit',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('https://example.test/new.webp'),
    );
    final decodeId = DecodeId(
      download: logicalId,
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
    );
    final oldPhysical = downloads.get(oldPhysicalId);
    downloads.aliasPhysical(id: logicalId, target: oldPhysicalId);
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'source-watch-rebind',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _StaticCursorFactory(),
      clock: clock,
    );
    final uploader = _TestUploader();
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: uploader,
      clock: clock,
    );
    final bytes = 'RIFF....WEBPsource-watch-rebind'.codeUnits;
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => _ImmediateTransport(bytes),
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
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    const firstDownload = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'old-physical-alias',
      expirationRevision: 2,
    );
    final first = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{logicalId: firstDownload},
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'old-physical-alias',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'old-physical-alias',
          expirationRevision: 2,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(logicalId),
        ResourceId.decode(decodeId),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: first,
        diff: DemandDiff.between(DemandPlan.empty(), first),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();
    expect(oldPhysical.state, DownloadState.promoted);
    expect(uploader.outputs, hasLength(1));
    final oldUploadSession = uploads.find(decodeId);
    expect(oldUploadSession, isNotNull);
    expect(oldUploadSession!.state, UploadState.ready);

    final empty = DemandPlan.empty(revision: 2);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: empty,
        diff: DemandDiff.between(first, empty),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    await coordinator.idle();
    final retired = downloads.takeIdlePhysical(oldPhysicalId);
    expect(retired, same(oldPhysical));
    await retired!.dispose();
    expect(downloads.resolvePhysicalId(logicalId), logicalId);

    const currentDecode = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'logical-revisit-current',
      expirationRevision: 4,
    );
    final revisited = DemandPlan(
      revision: 3,
      downloads: <DownloadId, DownloadDemand>{
        logicalId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'logical-revisit-current',
          expirationRevision: 4,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{decodeId: currentDecode},
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'logical-revisit-current',
          expirationRevision: 4,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(logicalId),
        ResourceId.decode(decodeId),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: revisited,
        diff: DemandDiff.between(empty, revisited),
        window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
      ),
    );
    await coordinator.idle();

    final newPhysical = downloads.get(logicalId);
    expect(identical(newPhysical, oldPhysical), isFalse);
    expect(newPhysical.state, DownloadState.promoted);
    final decoded = decodes.find(decodeId)?.snapshot;
    expect(decoded, isNotNull);
    expect(decoded!.depth, 0);
    expect(decoded.state, DecodeState.ready);
    expect(uploader.outputs, hasLength(2));
    final reboundUploadSession = uploads.find(decodeId);
    expect(reboundUploadSession, isNotNull);
    expect(reboundUploadSession, isNot(same(oldUploadSession)));
    expect(reboundUploadSession!.state, UploadState.ready);
    final generationRebind = trace.events.lastWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['action'] == 'physical-generation-changed',
    );
    expect(generationRebind.payload['invalidatedUploads'], 1);
    expect(generationRebind.payload['invalidatedDecodes'], 1);
  },
  );

  test(
      'upload registry replaces a stale concrete decode generation binding',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'upload_registry_decode_generation_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'generation',
        pageId: 'upload-registry',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/generation.webp'),
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'upload-registry-generation',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _StaticCursorFactory(),
      clock: clock,
    );
    final uploads = UploadRegistry(
      decodes: decodes,
      uploader: _TestUploader(),
      clock: clock,
    );
    addTearDown(() async {
      uploads.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final firstDecode = decodes.get(decodeId);
    final firstUpload = uploads.get(decodeId);
    expect(firstUpload.decode, same(firstDecode));

    expect(decodes.invalidateForDownload(id), 1);
    final replacementDecode = decodes.get(decodeId);
    expect(replacementDecode, isNot(same(firstDecode)));

    final replacementUpload = uploads.get(decodeId);
    expect(replacementUpload, isNot(same(firstUpload)));
    expect(firstUpload.state, UploadState.disposed);
    expect(replacementUpload.decode, same(replacementDecode));
  },
  );

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
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final cursors = _RolePromotionCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: cursors,
      clock: clock,
    );
    final trace = MemoryTraceSink();
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
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
  },
  );

  test('source retirement waits for cancelled decode work to physically exit',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_decode_retirement_barrier_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    await source.writeAsBytes('RIFF....WEBPpayload'.codeUnits);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'retirement-barrier',
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
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'retirement-barrier',
    );
    final cursors = _RolePromotionCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: cursors,
      clock: clock,
    );
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => const FileTransport(),
      clock: clock,
      decodes: decodes,
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'retirement-barrier',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'retirement-barrier',
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
    await cursors.cursor.started.future;

    final empty = DemandPlan.empty(revision: 2);
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: empty,
        diff: DemandDiff.between(plan, empty),
        window: RoleWindow(const <int, PageRole>{}),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.decode.isIdle, isFalse);
    expect(
      decodes.find(decodeId),
      isNotNull,
      reason: 'cancelled lane work still owns its concrete source generation',
    );

    cursors.cursor.release.complete();
    await coordinator.idle();
    expect(coordinator.decode.isIdle, isTrue);
    expect(
      decodes.find(decodeId),
      isNull,
      reason: 'source/decode generation retires only after real lane exit',
    );
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
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final transport = _ControlledTransport();
    final initialStarted = Completer<void>();
    final initialRelease = Completer<void>();
    final followStarted = Completer<void>();
    final followRelease = Completer<void>();
    var decodeCalls = 0;
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
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
  },
  );

  test(
      'logical decode observes the same equivalent physical carrier selected by transfer owner',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_equivalent_physical_source_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final logicalId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'logical-page',
      ),
      sourceRevision: 'old',
      canonicalUri: Uri.parse('file:///logical-page.webp'),
    );
    final physicalId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'physical-page',
      ),
      sourceRevision: 'new',
      canonicalUri: Uri.parse('file:///physical-page.webp'),
    );
    final decodeId = DecodeId(
      download: logicalId,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final bytes = Uint8List.fromList(
      'RIFF....WEBPequivalent-physical-carrier'.codeUnits,
    );
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final idleExact = downloads.get(logicalId);
    final physical = downloads.get(physicalId);
    physical.bindResidentImmutableAuthority(
      validators: const Validators(),
      totalLength: bytes.lengthInBytes,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes,
      residentReplayRangeChunks: (start, endExclusive) async =>
          Stream<List<int>>.value(bytes.sublist(start, endExclusive)),
      residentReplayAccessMode: 'direct',
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'equivalent-physical-source',
      residentReplayRangeSourceWithControl:
          (session, start, endExclusive, {required control}) async {
        expect(session, same(physical));
        control.throwIfCancelled();
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive),
              );
      },
    );
    final net = NetLane(maxActive: 1);
    final owner = DownloadTransferOwner(
      registry: downloads,
      clock: clock,
      net: net,
      resolveTransferId: (id) => id == logicalId ? physicalId : id,
    );
    final consumer = owner.attachConsumer(
      scopeId: 'equivalent-physical-source',
      transportFor: (_) => FakeTransport(bytes: bytes),
      traceSink: const NoopTraceSink(),
    );
      var acquireFallbacks = 0;
      final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => FakeTransport(bytes: bytes),
      clock: clock,
      onDecode: (_, _, _) async {},
      downloadTransfer: consumer,
      downloadSessionFor: (id) {
          acquireFallbacks++;
          return id == logicalId ? physical : downloads.get(id);
        },
      findDownloadSession: (id) => id == logicalId ? physical : downloads.find(id),
      net: net,
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      await owner.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        logicalId: const DownloadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'reader-next',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.next,
          priority: 720,
          targetWatermark: 2,
          reason: 'reader-next',
          expirationRevision: 2,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{
        ResourceId.download(logicalId),
        ResourceId.decode(decodeId),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(const <int, PageRole>{1: PageRole.next}),
      ),
    );

    await ingresses.settled(physicalId);
    await Future<void>.delayed(Duration.zero);

    final projection = ingresses.find(physicalId);
    expect(projection, isNotNull);
    expect(projection!.snapshot.length, bytes.lengthInBytes);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(ingresses.find(logicalId), isNull);
    expect(idleExact.demanded, isFalse);
    expect(physical.demanded, isTrue);
      expect(
        acquireFallbacks,
        0,
        reason:
            'added observation must reuse the physical carrier already selected by transfer acquisition',
      );
    },
  );

  test(
      'late Reader joins promoted physical download without blocking decode/upload reconcile',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_late_reader_test_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final source = File('${temp.path}/source.webp');
    final bytes = 'RIFF....WEBPpromoted-reader-reentry'.codeUnits;
    await source.writeAsBytes(bytes);
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'late-reader',
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
      traceSink: trace,
    );
    final physical = downloads.get(id);
    await DownloadJob(
      transport: const FileTransport(),
      session: physical,
    ).run();
    expect(physical.state, DownloadState.promoted);
    expect(physical.committedLength, bytes.length);

    // This SourcePool/ingress registry represents a later Reader. The physical
    // transfer already contains bytes, so projection replay must be async
    // consumer work and must not abort the demand reconciliation pass.
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'late-reader',
      residentReplaySource: (physical, endExclusive) async {
        expect(identical(physical, downloads.get(id)), isTrue);
        return source.openRead(0, endExclusive);
      },
      residentReplayRangeSource:
          (physical, start, endExclusive) async {
        expect(identical(physical, downloads.get(id)), isTrue);
        return source.openRead(start, endExclusive);
      },
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _StaticCursorFactory(),
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
      ingresses: ingresses,
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
      ingresses.dispose();
      sources.dispose();
      uploads.dispose();
      decodes.dispose();
      await downloads.dispose();
    });

    const downloadDemand = DownloadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'late-reader',
      expirationRevision: 2,
    );
    const decodeDemand = DecodeDemand(
      role: PageRole.current,
      priority: 1000,
      targetWatermark: 1,
      reason: 'late-reader',
      expirationRevision: 2,
    );
    const uploadDemand = UploadDemand(
      role: PageRole.current,
      priority: 1000,
      reason: 'late-reader',
      expirationRevision: 2,
    );
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{id: downloadDemand},
      decodes: <DecodeId, DecodeDemand>{decodeId: decodeDemand},
      uploads: <DecodeId, UploadDemand>{decodeId: uploadDemand},
      keep: <ResourceId>{
        ResourceId.download(id),
        ResourceId.decode(decodeId),
      },
    );

    expect(
      () => coordinator.reconcile(
        'late-reader',
        PipelineDelta(
          plan: plan,
          diff: DemandDiff.between(DemandPlan.empty(), plan),
          window: RoleWindow(const <int, PageRole>{0: PageRole.current}),
        ),
      ),
      returnsNormally,
      reason: 'physical prefix replay must not abort decode/upload reconcile',
    );

    final projection = ingresses.find(id);
    expect(projection, isNotNull);
    await ingresses.settled(id);
    await Future<void>.delayed(Duration.zero);
    await coordinator.idle();

    expect(projection!.snapshot.length, bytes.length);
    expect(projection.snapshot.sourceReady, isTrue);
    expect(decodes.find(decodeId), isNotNull);
    expect(uploads.find(decodeId)?.state, UploadState.ready);
    expect(uploader.outputs, hasLength(1));
  },
  );

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
      traceSink: trace,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'test',
    );
    final cursors = _StaticCursorFactory();
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
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
      ingresses: ingresses,
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
    final uploadStartsBeforeDormant = trace.events
        .where((event) => event.kind == TraceEventKind.uploadStarted)
        .length;
    final decodeStartsBeforeDormant = trace.events
        .where((event) => event.kind == TraceEventKind.decodeStarted)
        .length;

      final reranked = DemandPlan(
        revision: 2,
        downloads: <DownloadId, DownloadDemand>{
          id: const DownloadDemand(
            role: PageRole.next,
            priority: 820,
            reason: 'revisit-reranked',
            expirationRevision: 3,
          ),
        },
        decodes: <DecodeId, DecodeDemand>{
          decodeId: const DecodeDemand(
            role: PageRole.next,
            priority: 820,
            targetWatermark: 1,
            reason: 'revisit-reranked',
            expirationRevision: 3,
          ),
        },
        uploads: <DecodeId, UploadDemand>{
          decodeId: const UploadDemand(
            role: PageRole.next2,
            priority: 800,
            reason: 'revisit-reranked',
            expirationRevision: 3,
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
          plan: reranked,
          diff: DemandDiff.between(visible, reranked),
          window: RoleWindow(const <int, PageRole>{0: PageRole.next}),
        ),
      );
      await coordinator.idle();
      final rerankTiming = trace.events.lastWhere(
        (event) => event.kind == TraceEventKind.pipelineReconcileTiming,
      );
      expect(rerankTiming.payload['decodeChanged'], 1);
      expect(rerankTiming.payload['uploadChanged'], 1);
      expect(rerankTiming.payload['decodeMetadataOnly'], 1);
      expect(rerankTiming.payload['uploadMetadataOnly'], 1);
      expect(
        trace.events
            .where((event) => event.kind == TraceEventKind.decodeStarted)
            .length,
        decodeStartsBeforeDormant,
        reason: 'satisfied static rerank is not decode work',
      );
      expect(
        trace.events
            .where((event) => event.kind == TraceEventKind.uploadStarted)
            .length,
        uploadStartsBeforeDormant,
        reason: 'resident static rerank is not upload work',
      );

      prior = reranked;
    final dormant = plan(revision: 3, decode: false, upload: false);
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
    final revisited = plan(revision: 4, decode: true, upload: true);
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
        reason: 'revisit reuses the retained static output',
      );
    expect(
      trace.events
          .where((event) => event.kind == TraceEventKind.uploadStarted)
          .length,
      uploadStartsBeforeDormant,
      reason: 'static revisit must not enqueue a no-op upload lane task',
    );
    expect(
      trace.events
          .where((event) => event.kind == TraceEventKind.decodeStarted)
          .length,
      decodeStartsBeforeDormant,
      reason: 'static revisit must not enqueue a no-op decode fill',
    );
  },
  );


  test('resident fallback current wakes after initial ingress hydration', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_resident_fallback_bootstrap_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final id = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'resident-fallback',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/resident-fallback.jpg'),
    );
    final decodeId = DecodeId(
      download: id,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final bytes = <int>[
      0xff, 0xd8, 0xff, 0xe0,
      ...List<int>.filled(512 * 1024 - 4, 0),
    ];
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = downloads.get(id);
    physical.bindResidentImmutableAuthority(
      validators: const Validators(etag: '"resident-fallback"'),
      totalLength: bytes.length,
      bodyAuthority: ByteResponseBodyAuthority.artifactCache,
      metadataPrefix: bytes.sublist(0, 64),
    );
    final trace = MemoryTraceSink();
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => bytes.length + 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'resident-fallback-bootstrap',
      traceSink: trace,
      residentReplayRangeSourceWithControl:
          (session, start, endExclusive, {required control}) async {
        expect(session, same(physical));
        control.throwIfCancelled();
        return Stream<List<int>>.value(bytes.sublist(start, endExclusive),
              );
      },
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _NeverUsedCursorFactory(),
      clock: clock,
      traceSink: trace,
    );
    final requested = <DecodeId>[];
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      decodes: decodes,
      transportFor: (_) => const _ImmediateTransport(<int>[1]),
      clock: clock,
      traceSink: trace,
      onExternalPresentationRequested: (id, revision) {
        requested.add(id);
      },
      net: NetLane(maxActive: 1),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        id: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'resident-fallback',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        decodeId: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'resident-fallback',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        decodeId: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'resident-fallback',
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

    final hydrationDeadline = DateTime.now().add(
      const Duration(seconds: 2),
    );
    while (requested.isEmpty) {
      if (DateTime.now().isAfter(hydrationDeadline)) {
        final decodeSnapshot = decodes.find(decodeId)?.snapshot;
        final ingressSnapshot = ingresses.find(id)?.snapshot;
        fail(
          'resident fallback current stalled after ingress hydration: '
          'decodeState=${decodeSnapshot?.state} '
          'decodeDepth=${decodeSnapshot?.depth} '
          'external=${decodeSnapshot?.externalPresentationRequired} '
          'ingressLength=${ingressSnapshot?.length} '
          'ingressRevision=${ingressSnapshot?.revision} '
          'ingressReady=${ingressSnapshot?.sourceReady} '
          'ingressKind=${ingressSnapshot?.kind} '
          'events=${trace.events.map((event) => "${event.kind.name}:${event.payload}").join(" | ")}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ingresses.find(id)?.snapshot.kind, isNot(ContentKind.unknown));
    expect(requested, <DecodeId>[decodeId]);
  });

  test('downloaded static neighbor presents while single-frame current waits', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_waiting_static_current_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    DownloadId download(String pageId) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.jpg'),
        );
    DecodeId decodeId(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final currentId = download('waiting-current');
    final nextId = download('downloaded-next');
    final currentDecode = decodeId(currentId);
    final nextDecode = decodeId(nextId);
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'waiting-static-current',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: const _NeverUsedCursorFactory(),
      clock: clock,
    );
    final currentTransport = _ControlledTransport();
    final requested = <DecodeId>[];
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (uri) => uri == currentId.canonicalUri
          ? currentTransport
          : const _ImmediateTransport(
              <int>[0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            ),
      clock: clock,
      decodes: decodes,
      onExternalPresentationRequested: (id, _) => requested.add(id),
      externalPresentationAvailable: (_) => true,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });
    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        currentId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'static-current',
          expirationRevision: 2,
        ),
        nextId: const DownloadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'static-next',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        currentDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'static-current',
          expirationRevision: 2,
        ),
        nextDecode: const DecodeDemand(
          role: PageRole.next,
          priority: 820,
          targetWatermark: 1,
          reason: 'static-next',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        currentDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'static-current',
          expirationRevision: 2,
        ),
        nextDecode: const UploadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'static-next',
          expirationRevision: 2,
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
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(
          const <int, PageRole>{0: PageRole.current, 1: PageRole.next},
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!requested.contains(nextDecode)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('downloaded neighbor stayed loading without another Reader observation: '
            'download=${downloads.find(nextId)?.state}, '
            'current=${decodes.find(currentDecode)?.state}, '
            'next=${decodes.find(nextDecode)?.state}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(decodes.find(currentDecode)?.state, DecodeState.waitingSource);
    expect(requested, <DecodeId>[nextDecode]);
    expect(coordinator.completeExternalPresentation('reader', nextDecode), isTrue);
    currentTransport.add(<int>[0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    await currentTransport.close();
    await coordinator.idle();
    expect(requested, <DecodeId>[nextDecode, currentDecode]);
    expect(coordinator.completeExternalPresentation('reader', currentDecode), isTrue);
  });

  test('external fallback presentation releases one speculative page at a time', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_external_presentation_refill_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));

    DownloadId download(String pageId, int index) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.jpg'),
          pageIndexHint: index,
        );
    DecodeId decode(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final firstId = download('first-fallback', 0);
    final secondId = download('second-fallback', 1);
    final firstDecode = decode(firstId);
    final secondDecode = decode(secondId);
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'external-presentation-refill',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _NeverUsedCursorFactory(),
      clock: clock,
    );
    final requested = <DecodeId>[];
    final presentationAvailable = <DecodeId>{firstDecode};
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => const _ImmediateTransport(
        <int>[0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]),
      clock: clock,
      decodes: decodes,
      onExternalPresentationRequested: (id, revision) {
        requested.add(id);
      },
      externalPresentationAvailable: presentationAvailable.contains,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        firstId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'first-fallback',
          expirationRevision: 2,
        ),
        secondId: const DownloadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'second-fallback',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        firstDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'first-fallback',
          expirationRevision: 2,
        ),
        secondDecode: const DecodeDemand(
          role: PageRole.next,
          priority: 820,
          targetWatermark: 1,
          reason: 'second-fallback',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        firstDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'first-fallback',
          expirationRevision: 2,
        ),
        secondDecode: const UploadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'second-fallback',
          expirationRevision: 2,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(firstId),
        ResourceId.download(secondId),
        ResourceId.decode(firstDecode),
        ResourceId.decode(secondDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(
          const <int, PageRole>{0: PageRole.current, 1: PageRole.next,
          }),
      ),
    );

    final firstDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (requested.isEmpty) {
      if (DateTime.now().isAfter(firstDeadline)) {
        fail('first external presentation request was not released');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requested, <DecodeId>[firstDecode]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requested, <DecodeId>[firstDecode],
        reason: 'second fallback must wait for the first actual presented frame',
      );

    expect(
      coordinator.completeExternalPresentation('reader', firstDecode),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      requested,
      <DecodeId>[firstDecode],
      reason: 'an offscreen fallback without a presentation consumer must not occupy a grant',
    );
    presentationAvailable.add(secondDecode);
    coordinator.updateExternalPresentationAvailability(
      'reader',
      secondDecode,
      available: true,
    );
    final secondDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (requested.length < 2) {
      if (DateTime.now().isAfter(secondDeadline)) {
        fail('second external presentation request did not follow first-frame proof',
          );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requested, <DecodeId>[firstDecode, secondDecode]);
  },
  );

  test('current presentation wait does not block one bounded static warm', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_external_presentation_parallel_refill_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));

    DownloadId download(String pageId, int index) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.jpg'),
          pageIndexHint: index,
        );
    DecodeId decode(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );

    final currentId = download('current-fallback', 0);
    final warmId = download('warm-fallback', 1);
    final currentDecode = decode(currentId);
    final warmDecode = decode(warmId);
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'external-presentation-parallel-refill',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _NeverUsedCursorFactory(),
      clock: clock,
    );
    final requested = <DecodeId>[];
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => const _ImmediateTransport(
        <int>[0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      ),
      clock: clock,
      decodes: decodes,
      onExternalPresentationRequested: (id, revision) {
        requested.add(id);
      },
      externalPresentationAvailable: (_) => true,
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
      maxSpeculativeExternalPresentationPending: 1,
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        currentId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'current-fallback',
          expirationRevision: 2,
        ),
        warmId: const DownloadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'warm-fallback',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        currentDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'current-fallback',
          expirationRevision: 2,
        ),
        warmDecode: const DecodeDemand(
          role: PageRole.next,
          priority: 820,
          targetWatermark: 1,
          reason: 'warm-fallback',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        currentDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'current-fallback',
          expirationRevision: 2,
          viewportVisible: true,
        ),
        warmDecode: const UploadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'warm-fallback',
          expirationRevision: 2,
          viewportVisible: false,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(currentId),
        ResourceId.download(warmId),
        ResourceId.decode(currentDecode),
        ResourceId.decode(warmDecode),
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
            1: PageRole.next,
          },
        ),
      ),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (requested.toSet().length < 2) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'offscreen static warm stayed decode-blocked behind current presentation: $requested',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requested.toSet(), <DecodeId>{currentDecode, warmDecode});
    expect(
      coordinator.externalPresentationPendingFor(currentDecode),
      isTrue,
    );
    expect(
      coordinator.externalPresentationPendingFor(warmDecode),
      isTrue,
      reason:
          'current/visible presentation wait is not part of the speculative warm cap',
    );
  });

  test('visible fallback preempts another visible external first-frame wait', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_visible_external_presentation_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));

    DownloadId download(String pageId, int index) => DownloadId(
          content: ContentId(
            sourceId: 'source',
            comicId: 'comic',
            chapterId: 'chapter',
            pageId: pageId,
          ),
          sourceRevision: 'r1',
          canonicalUri: Uri.parse('https://example.test/$pageId.jpg'),
          pageIndexHint: index,
        );
    DecodeId decode(DownloadId id) => DecodeId(
          download: id,
          physicalWidth: 8,
          physicalHeight: 8,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.flutterImage,
        );
    final firstId = download('visible-first', 0);
    final secondId = download('visible-second', 1);
    final firstDecode = decode(firstId);
    final secondDecode = decode(secondId);
    final clock = _Clock();
    final downloads = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final sources = SourcePool(
      factory: _TestSourceFactory(),
      budgetFor: (_) => 1024,
    );
    final ingresses = DownloadIngressProjectionRegistry(
      sources: sources,
      scopePrefix: 'visible-external-presentation',
    );
    final decodes = DecodeRegistry(
      downloads: downloads,
      ingresses: ingresses,
      cursors: _NeverUsedCursorFactory(),
      clock: clock,
    );
    final requested = <DecodeId>[];
    final coordinator = LiveCoordinator(
      registry: downloads,
      ingresses: ingresses,
      transportFor: (_) => const _ImmediateTransport(
        <int>[0xff, 0xd8, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]),
      clock: clock,
      decodes: decodes,
      onExternalPresentationRequested: (id, revision) {
        requested.add(id);
      },
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 2),
    );
    addTearDown(() async {
      await coordinator.dispose();
      decodes.dispose();
      ingresses.dispose();
      sources.dispose();
      await downloads.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        firstId: const DownloadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'visible-first',
          expirationRevision: 2,
        ),
        secondId: const DownloadDemand(
          role: PageRole.transition,
          priority: 900,
          reason: 'visible-second',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        firstDecode: const DecodeDemand(
          role: PageRole.current,
          priority: 1000,
          targetWatermark: 1,
          reason: 'visible-first',
          expirationRevision: 2,
        ),
        secondDecode: const DecodeDemand(
          role: PageRole.transition,
          priority: 900,
          targetWatermark: 1,
          reason: 'visible-second',
          expirationRevision: 2,
        ),
      },
      uploads: <DecodeId, UploadDemand>{
        firstDecode: const UploadDemand(
          role: PageRole.current,
          priority: 1000,
          reason: 'visible-first',
          expirationRevision: 2,
          viewportVisible: true,
        ),
        secondDecode: const UploadDemand(
          role: PageRole.transition,
          priority: 900,
          reason: 'visible-second',
          expirationRevision: 2,
          viewportVisible: true,
        ),
      },
      keep: <ResourceId>{
        ResourceId.download(firstId),
        ResourceId.download(secondId),
        ResourceId.decode(firstDecode),
        ResourceId.decode(secondDecode),
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
            1: PageRole.transition,
          }),
      ),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (requested.toSet().length < 2) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'a visible fallback remained serialized behind another visible external first-frame wait: $requested',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requested.toSet(), <DecodeId>{firstDecode, secondDecode});
  },
  );

  test('stalled nearer decode never gates farther encoded transfer', () async {
    final temp = await Directory.systemTemp.createTemp(
      'live_decode_independent_download_test_',
    );
    addTearDown(() async => temp.delete(recursive: true));

    final nearId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'near',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/near.webp'),
    );
    final farId = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'far',
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/far.webp'),
    );
    final nearDecode = DecodeId(
      download: nearId,
      physicalWidth: 8,
      physicalHeight: 8,
      pixelFormat: PixelFormat.rgba8888,
      renderer: RendererKind.flutterImage,
    );
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final nearTransport = _RetainedStreamTransport();
    final decodeStarted = Completer<void>();
    final releaseDecode = Completer<void>();
    final coordinator = LiveCoordinator(
      registry: registry,
      transportFor: (uri) => uri == nearId.canonicalUri
          ? nearTransport
          : _ImmediateTransport('RIFF....WEBPfar'.codeUnits),
      clock: clock,
      onDecode: (id, demand, token) async {
        if (id != nearDecode) return;
        if (!decodeStarted.isCompleted) decodeStarted.complete();
        await releaseDecode.future;
      },
      net: NetLane(maxActive: 2),
      decode: DecodeLane(maxActive: 1),
    );
    addTearDown(() async {
      if (!releaseDecode.isCompleted) releaseDecode.complete();
      await nearTransport.close();
      await coordinator.dispose();
      await registry.dispose();
    });

    final plan = DemandPlan(
      revision: 1,
      downloads: <DownloadId, DownloadDemand>{
        nearId: const DownloadDemand(
          role: PageRole.next,
          priority: 820,
          reason: 'near-slow',
          expirationRevision: 2,
        ),
        farId: const DownloadDemand(
          role: PageRole.far,
          priority: 680,
          reason: 'far-prefetch',
          expirationRevision: 2,
        ),
      },
      decodes: <DecodeId, DecodeDemand>{
        nearDecode: const DecodeDemand(
          role: PageRole.next,
          priority: 820,
          targetWatermark: 5,
          reason: 'near-slow',
          expirationRevision: 2,
        ),
      },
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{
        ResourceId.download(nearId),
        ResourceId.download(farId),
        ResourceId.decode(nearDecode),
      },
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: plan,
        diff: DemandDiff.between(DemandPlan.empty(), plan),
        window: RoleWindow(
          const <int, PageRole>{0: PageRole.next, 1: PageRole.far,
        }),
      ),
    );

    await nearTransport.opened.future.timeout(const Duration(seconds: 2));
    await decodeStarted.future.timeout(const Duration(seconds: 2));

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (registry.find(farId)?.state != DownloadState.promoted) {
      if (DateTime.now().isAfter(deadline)) {
        fail('far download was gated by unrelated nearer decode progress');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(registry.find(farId)?.state, DownloadState.promoted);
    expect(registry.find(nearId)?.state, isNot(DownloadState.promoted));
  });

}

final class _NeverUsedCursorFactory implements CursorFactory {
  const _NeverUsedCursorFactory();

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    throw StateError('fallback presentation must not create a native cursor');
  }
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
    required this.release});

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
        complete: true);

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
  final Completer<void> cancelled = Completer<void>();
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
      onDiscard: () async {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
      },
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

final class _BlockedControlledTransport implements ControlledTransport {
  final Completer<void> opened = Completer<void>();
  final Completer<void> cancelled = Completer<void>();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    if (!opened.isCompleted) {
      opened.complete();
    }
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('controlled opener requires TaskControl');
    }
    await taskControl.whenCancelled;
    if (!cancelled.isCompleted) {
      cancelled.complete();
    }
    throw const Failure(
      code: ErrorCode.cancelled,
      message: 'pre-open request cancelled',
    );
  }
}

final class _BytesTransport implements Transport {
  _BytesTransport(this.bytes);

  final List<int> bytes;
  final Completer<void> opened = Completer<void>();

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    if (!opened.isCompleted) {
      opened.complete();
    }
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
      validators: const Validators(),
      rangeSupported: false,
    );
  }
}

final class _AlwaysFailTransport implements Transport {
  _AlwaysFailTransport(this.failure);

  final Failure failure;
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    throw failure;
  }
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

final class _NeedMoreDataCursorFactory implements CursorFactory {
  _NeedMoreDataCursorFactory({required this.requiredLength});

  final int requiredLength;
  final Completer<void> frameDecoded = Completer<void>();
  int needMoreCount = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) =>
      CursorBinding(
        frames: _NeedMoreDataCursor(
          epoch: epoch,
          source: source,
          requiredLength: requiredLength,
          onNeedMore: () => needMoreCount++,
          frameDecoded: frameDecoded,
        ),
      );
}

final class _NeedMoreDataCursor implements FrameCursor {
  _NeedMoreDataCursor({
    required this.epoch,
    required this.source,
    required this.requiredLength,
    required this.onNeedMore,
    required this.frameDecoded,
  });

  @override
  final int epoch;
  final EncodedSource source;
  final int requiredLength;
  final void Function() onNeedMore;
  final Completer<void> frameDecoded;
  bool _emitted = false;

  @override
  Future<CursorStep> decodeNext() async {
    if (_emitted) return const CursorStep.end();
    if (source.length < requiredLength) {
      onNeedMore();
      return const CursorStep.needMoreData();
    }
    _emitted = true;
    if (!frameDecoded.isCompleted) frameDecoded.complete();
    return CursorStep.frame(_TestFrame(epoch, 0));
  }

  @override
  void dispose() {}
}

final class _LatePartialLoopCursorFactory implements CursorFactory {
  _LatePartialLoopCursorFactory({required this.frameCount});

  final int frameCount;
  int created = 0;

  @override
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    created++;
    final cursor = _LatePartialLoopCursor(epoch, frameCount);
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class _LatePartialLoopCursor implements FrameCursor, LoopCursor {
  _LatePartialLoopCursor(this.epoch, this.frameCount);

  @override
  final int epoch;
  final int frameCount;
  int _next = 0;

  @override
  AnimationInfo get animation => AnimationInfo(
        frameCount: frameCount,
        loopCount: 0,
        complete: false);

  @override
  int get cycle => 0;

  @override
  Future<CursorStep> decodeNext() async {
    if (_next >= frameCount) {
      return const CursorStep.needMoreData();
    }
    return CursorStep.frame(_TestFrame(epoch, _next++));
  }

  @override
  bool rewind() => false;

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
    DecodeExecutionClass executionClass, {
    TaskControl? control,
  }) async {
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
        complete: true);

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
