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


  test('large unsupported-range catchup waits for foreground-adjacent demand',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_catchup_defer_test_');
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
      downloads: const <DownloadId, DownloadDemand>{id: stillBackgroundDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: const <ResourceId>{ResourceId.download(id)},
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
      preservedLength - 64 * 1024,
    );
    expect(session.state, DownloadState.promoted);
    expect(await File(session.artifact.finalPath).readAsBytes(), bytes);
  });

  test('very large unsupported-range partial waits for transition demand',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_catchup_tier_test_');
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
        window: const RoleWindow(<int, PageRole>{}),
      ),
    );
    expect(registry.find(id)?.demanded, isFalse);
    expect(coordinator.net.priorityOf('reader:${id.key}'), 0);

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
    expect(coordinator.net.priorityOf('reader:${id.key}'), 1000);
    expect(transport.opens, 1);

    transport.add('payload'.codeUnits);
    await transport.close();
    await coordinator.idle();
    expect(registry.find(id)?.state, DownloadState.promoted);
    expect(transport.opens, 1);
  });

  test('remaining consumer claim keeps transfer and downgrades priority',
      () async {
    final temp = await Directory.systemTemp
        .createTemp('live_multi_consumer_claim_test_');
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
        window: const RoleWindow(<int, PageRole>{}),
      ),
    );

    expect(session.demanded, isTrue);
    expect(session.demandCount, 1);
    expect(session.effectivePriority, 700);
    expect(coordinator.net.priorityOf('reader-a:${id.key}'), 700);
    expect(transport.opens, 1);

    transport.add('payload'.codeUnits);
    await transport.close();
    await coordinator.idle();
    expect(session.state, DownloadState.promoted);
    expect(transport.opens, 1);

    other.detach();
    await coordinator.dispose();
    await registry.dispose();
  });

  test('detached receiving yields to adjacent previous pressure', () async {
    final temp =
        await Directory.systemTemp.createTemp('live_receiving_pressure_test_');
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
        pressurePreemptionPriorityFloor: 780,
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
        window: const RoleWindow(<int, PageRole>{}),
      ),
    );
    expect(coordinator.net.priorityOf('reader:${retainedId.key}'), 0);
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

    await previous.opened.future.timeout(const Duration(seconds: 1));
    await coordinator.idle();
    expect(retainedSession?.activeRun, isFalse);
    expect(registry.find(previousId)?.state, DownloadState.promoted);
    expect(retained.opens, 1);
    await retained.close();
  });

  test('detached pre-open run yields its slot to adjacent previous', () async {
    final temp =
        await Directory.systemTemp.createTemp('live_preopen_detach_test_');
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

    const previousDemand = DownloadDemand(
      role: PageRole.previous,
      priority: 780,
      reason: 'adjacent-previous',
      expirationRevision: 9,
    );
    final second = DemandPlan(
      revision: 2,
      downloads: <DownloadId, DownloadDemand>{previousId: previousDemand},
      decodes: const <DecodeId, DecodeDemand>{},
      uploads: const <DecodeId, UploadDemand>{},
      keep: <ResourceId>{ResourceId.download(previousId)},
    );
    coordinator.reconcile(
      'reader',
      PipelineDelta(
        plan: second,
        diff: DemandDiff.between(first, second),
        window: RoleWindow(const <int, PageRole>{-1: PageRole.previous}),
      ),
    );

    await opening.cancelled.future.timeout(const Duration(seconds: 1));
    await previous.opened.future.timeout(const Duration(seconds: 1));
    await coordinator.idle();
    expect(openingSession?.activeRun, isFalse);
    expect(registry.find(previousId)?.state, DownloadState.promoted);
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

  test('terminal source failure is not hot-looped while demand is unchanged',
      () async {
    final temp = await Directory.systemTemp.createTemp('live_terminal_failure_');
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
      const Failure(code: ErrorCode.source, message: 'deterministic source failure'),
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
      reason: 'explicit-demand-change',
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
    expect(transport.opens, 2);
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


  test('playback state never gates decode refill for other demanded pages',
      () async {
    // The directed source-wake test below covers the operational path. This
    // regression guard keeps the VibeVenera producer/consumer contract
    // explicit: LiveCoordinator has no startup-buffer eligibility gate.
    final source = File('lib/src/live_coordinator.dart').readAsStringSync();
    expect(source, isNot(contains('decode-startup-deferred')));
    expect(source, isNot(contains('_startupBufferingCurrent')));
    expect(source, isNot(contains('isStartupBuffering')));
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
