import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
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
  test('retained logical demands reuse acquire-time physical resolution', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_resolution_reuse_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    var resolutionCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      resolveTransferId: (id) {
        resolutionCalls++;
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final transport = _BlockedControlledTransport();
    final consumer = owner.attachConsumer(
      scopeId: 'reader-resolution-reuse',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    final first = _id('resolution-first');
    final second = _id('resolution-second');
    final third = _id('resolution-third');
    final fourth = _id('resolution-fourth');

    consumer.replaceDemands(
      'reader-resolution-reuse',
      1,
      <DownloadId, TransferDemand>{
        first: const TransferDemand(priority: 820, reason: 'next'),
        second: const TransferDemand(priority: 800, reason: 'next2'),
        third: const TransferDemand(priority: 780, reason: 'previous'),
      },
    );
    expect(resolutionCalls, 3);

    consumer.replaceDemands(
      'reader-resolution-reuse',
      2,
      <DownloadId, TransferDemand>{
        first: const TransferDemand(priority: 1000, reason: 'current'),
        second: const TransferDemand(priority: 820, reason: 'next'),
        third: const TransferDemand(priority: 800, reason: 'next2'),
      },
    );
    expect(
      resolutionCalls,
      3,
      reason: 'role migration must not reacquire unchanged logical identities',
    );

    consumer.replaceDemands(
      'reader-resolution-reuse',
      3,
      <DownloadId, TransferDemand>{
        second: const TransferDemand(priority: 1000, reason: 'current'),
        third: const TransferDemand(priority: 820, reason: 'next'),
        fourth: const TransferDemand(priority: 800, reason: 'next2'),
      },
    );
    expect(
      resolutionCalls,
      4,
      reason: 'only the newly acquired logical identity should resolve',
      );
    },
  );

  test('incremental logical changes recompute only the shared physical carrier',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_incremental_shared_physical_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final logicalA = _id('incremental-shared-a');
    final logicalB = _id('incremental-shared-b');
    final physical = _id('incremental-shared-physical');
    var resolutionCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      resolveTransferId: (id) {
        resolutionCalls++;
        return id == logicalA || id == logicalB ? physical : id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final transport = _BlockedControlledTransport();
    final consumer = owner.attachConsumer(
      scopeId: 'reader-incremental-shared',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-incremental-shared',
      1,
      <DownloadId, TransferDemand>{
        logicalA: const TransferDemand(priority: 820, reason: 'next'),
        logicalB: const TransferDemand(priority: 780, reason: 'previous'),
      },
    );
    expect(resolutionCalls, 2);
    expect(owner.claimCount(physical), 1);
    expect(registry.get(physical).effectivePriority, 820);

    consumer.replaceDemands(
      'reader-incremental-shared',
      2,
      <DownloadId, TransferDemand>{
        logicalA: const TransferDemand(priority: 820, reason: 'next'),
        logicalB: const TransferDemand(priority: 1000, reason: 'current'),
      },
    );
    expect(resolutionCalls, 2);
    expect(owner.claimCount(physical), 1);
    expect(registry.get(physical).effectivePriority, 1000);

    consumer.replaceDemands(
      'reader-incremental-shared',
      3,
      <DownloadId, TransferDemand>{
        logicalA: const TransferDemand(priority: 820, reason: 'next'),
      },
    );
    expect(resolutionCalls, 2);
    expect(owner.claimCount(physical), 1);
    expect(registry.get(physical).effectivePriority, 820);
  });

  test('two consumers join one exact physical transfer and writer', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_join_');
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('join');
    final transportA = _GateBytesTransport('RIFF....WEBPshared'.codeUnits);
    final transportB = _CountingBytesTransport('RIFF....WEBPother'.codeUnits);
    final a = owner.attachConsumer(
      scopeId: 'reader-a',
      transportFor: (_) => transportA,
      traceSink: const NoopTraceSink(),
    );
    final b = owner.attachConsumer(
      scopeId: 'reader-b',
      transportFor: (_) => transportB,
      traceSink: const NoopTraceSink(),
    );

    a.replaceDemands('reader-a', 1, _desired(id, priority: 1000));
    await transportA.opened.future;
    final session = registry.get(id);
    expect(session.activeRun, isTrue);

    b.replaceDemands('reader-b', 1, _desired(id, priority: 700));
    expect(registry.sessions, hasLength(1));
    expect(identical(registry.get(id), session), isTrue);
    expect(owner.claimCount(id), 2);
    expect(session.demandCount, 2);
    expect(session.effectivePriority, 1000);
    expect(transportA.opens, 1);
    expect(transportB.opens, 0);

    transportA.release.complete();
    await b.idle();
    expect(session.state, DownloadState.promoted);
    expect(transportA.opens, 1);
    expect(transportB.opens, 0);
    expect(registry.sessions, hasLength(1));
  });

  test(
      'presentation recovery restarts one active required transfer on the same physical session',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_presentation_recovery_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final bytes = _ownerAnimatedWebp(<int>[64, 64, 64]);
    final transport = _CancelThenSucceedTransport(bytes: bytes);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('presentation-active-required');
    final consumer = owner.attachConsumer(
      scopeId: 'chapter-command',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'chapter-command',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-download-command',
          completionIntent: TransferCompletionIntent.required,
        ),
      });
    await transport.firstOpened.future.timeout(const Duration(seconds: 2));
    final session = registry.get(id);
    final epochBefore = session.epoch;
    expect(owner.claimCount(id), 1);
    expect(owner.requiredExactDurableTargets(id), contains(id));

    var invalidations = 0;
    var resetCallbacks = 0;
    expect(
      await owner.recoverPresentationArtifact(
        id,
        invalidateArtifact: () async {
          invalidations++;
          return true;
        },
        afterPhysicalReset: () async => resetCallbacks++,
      ),
      isTrue,
    );
    expect(transport.firstCancelled.isCompleted, isTrue);
    expect(identical(registry.get(id), session), isTrue);
    expect(session.epoch, isNot(epochBefore));
    expect(owner.claimCount(id), 1);
    expect(owner.requiredExactDurableTargets(id), contains(id));
    expect(invalidations, 1);
    expect(resetCallbacks, 1);

    consumer.refreshScheduling();
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(transport.opens, 2);
    expect(identical(registry.get(id), session), isTrue);
    expect(session.state, DownloadState.promoted);
    expect(session.committedLength, bytes.length);
    expect(owner.claimCount(id), 1);
    expect(owner.requiredExactDurableTargets(id), contains(id));

    await consumer.dispose();
  },
  );

  test('prepared local completion bypasses provider transport admission', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_completion_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final bytes = _ownerAnimatedWebp(<int>[64, 64, 64]);
    final trace = MemoryTraceSink();
    var transportLookups = 0;
    final transport = _CountingBytesTransport(bytes);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (session) async {
        await session.bindResponse(
          validators: const Validators(),
          totalLength: bytes.length,
        );
        final writer = session.acquireWriter();
        await session.append(writer, 0, bytes);
        await session.seal(writer, expectedLength: bytes.length);
        await session.promote();
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-completion');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-completion',
      transportFor: (_) {
        transportLookups++;
        return transport;
      },
      traceSink: trace,
    );

    consumer.replaceDemands(
      'reader-local-completion',
      1,
      _desired(id, priority: 780, flowTargetFrames: 1),
    );
    await consumer.idle();

    expect(registry.get(id).state, DownloadState.promoted);
    expect(transportLookups, 0);
    expect(transport.opens, 0);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.downloadStarted,
        ),
      isEmpty,
    );
    final shortCircuit = trace.events.lastWhere(
      (event) =>
          event.kind == TraceEventKind.artifactSource &&
          event.payload['stage'] == 'physical-local-prepare' &&
          event.payload['action'] == 'local-completion-short-circuit',
    );
    expect(shortCircuit.payload['state'], DownloadState.promoted.name);
    expect(shortCircuit.payload['committedLength'], bytes.length);
    },
  );

  test('promoted idle rank syncs only when physical work needs it', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_promoted_rank_sync_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final bytes = _ownerAnimatedWebp(<int>[64]);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (session) async {
        await session.bindResponse(
          validators: const Validators(),
          totalLength: bytes.length,
        );
        final writer = session.acquireWriter();
        await session.append(writer, 0, bytes);
        await session.seal(writer, expectedLength: bytes.length);
        await session.promote();
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('promoted-rank-sync');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-promoted-rank-sync',
      transportFor: (_) => throw StateError('local completion must win'),
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-promoted-rank-sync',
      1,
      _desired(id, priority: 780),
    );
    await consumer.idle();
    final session = registry.get(id);
    expect(session.state, DownloadState.promoted);
    expect(session.effectivePriority, 780);

    consumer.replaceDemands(
      'reader-promoted-rank-sync',
      2,
      _desired(id, priority: 620),
    );
    expect(consumer.demands[id]?.priority, 620);
    expect(
      session.effectivePriority,
      780,
      reason: 'idle promoted rank stays claim-local until physical work starts',
    );

    expect(consumer.syncAcquiredSessionPriority(id), same(session));
    expect(session.effectivePriority, 620);
  });

  test('failed local completion resets corrupt bytes before network fallback',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_completion_recovery_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final networkBytes = _ownerAnimatedWebp(<int>[64, 64, 64]);
    final localBytes = List<int>.of(networkBytes)
      ..[networkBytes.length - 1] ^= 0xff;
    final expectedChecksum = (Crc32()..add(networkBytes)).hex;
    final trace = MemoryTraceSink();
    final transport = _CountingBytesTransport(networkBytes);
    var prepareCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (session) async {
        prepareCalls++;
        await session.bindResponse(
          validators: const Validators(),
          totalLength: localBytes.length,
        );
        final writer = session.acquireWriter();
        await session.append(writer, 0, localBytes);
        await session.pause(writer);
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-completion-recovery');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-completion-recovery',
      transportFor: (_) => transport,
      traceSink: trace,
    );
    consumer.replaceDemands(
      'reader-local-completion-recovery',
      1,
      <DownloadId, TransferDemand>{
        id: TransferDemand(
          priority: 780,
          reason: 'test-local-completion-recovery',
          expectedChecksum: expectedChecksum,
        ),
      },
    );
    await consumer.idle();

    final session = registry.get(id);
    expect(prepareCalls, 1);
    expect(transport.opens, 1);
    expect(session.state, DownloadState.promoted);
    expect(session.hasWriter, isFalse);
    expect(session.committedLength, networkBytes.length);
    expect(owner.taskKeyFor(id), isNull);
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.artifactSource &&
            event.payload['action'] ==
                'local-completion-failed-network-fallback',
      ),
      isTrue,
    );
  },
  );

  test('open watchdog aborts one attempt and provider retries the demand',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_open_watchdog_retry_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final transport = _CancelThenSucceedTransport(
      bytes: _ownerAnimatedWebp(<int>[64, 64, 64]),
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      readStallTimeout: const Duration(milliseconds: 60),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('open-watchdog-retry');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-open-watchdog-retry',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
      retry: const RetryPolicy(
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );

    consumer.replaceDemands(
      'reader-open-watchdog-retry',
      1,
      _desired(id, priority: 900),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));

    expect(transport.opens, 2);
    expect(transport.firstCancelled.isCompleted, isTrue);
    expect(registry.get(id).state, DownloadState.promoted);
    expect(registry.get(id).snapshot.failure, isNull);
  },
  );

  test('transport attempt exhaustion does not multiply into owner recovery',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_open_watchdog_exhausted_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final trace = MemoryTraceSink();
    final transport = _AlwaysStallControlledTransport();
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      readStallTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('open-watchdog-exhausted');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-open-watchdog-exhausted',
      transportFor: (_) => transport,
      traceSink: trace,
      retry: const RetryPolicy(
        maxAttempts: 3,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );

    consumer.replaceDemands(
      'reader-open-watchdog-exhausted',
      1,
      _desired(id, priority: 1000),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));

    final session = registry.get(id);
    final exhaustedOpenCalls = transport.opens;
    expect(exhaustedOpenCalls, greaterThanOrEqualTo(3));
    expect(session.state, DownloadState.failed);
    expect(session.committedLength, 0);
    expect(
      trace.events.where(
        (event) => event.kind == TraceEventKind.downloadStarted).length,
      1,
    );
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.retryScheduled &&
            event.payload['stage'] == 'download-recovery',
      ),
      isEmpty,
    );
    expect(
      trace.events.where(
        (event) =>
            event.kind == TraceEventKind.retryScheduled &&
            event.payload['stage'] == 'download-attempt',
      ).length,
      2,
    );

    // Scheduling-only claim churn must not create another physical task after
    // the provider retry budget is already terminal.
    consumer.replaceDemands(
      'reader-open-watchdog-exhausted',
      2,
      _desired(id, priority: 780),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(transport.opens, exhaustedOpenCalls);
  },
  );

  test('provider setup failures retry finitely and publish terminal failure',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_provider_setup_failure_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    var lookups = 0;
    var recoverySleeps = 0;
    final id = _id('provider-setup-failure');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-provider-setup-failure',
      transportFor: (_) {
        lookups++;
        throw StateError('provider unavailable');
      },
      traceSink: const NoopTraceSink(),
      retry: const RetryPolicy(
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
      sleep: (_) async {
        recoverySleeps++;
      },
    );
    consumer.replaceDemands(
      'reader-provider-setup-failure',
      1,
      _desired(id, priority: 780),
    );
    await consumer.idle();

    final session = registry.get(id);
    expect(lookups, 5);
    expect(recoverySleeps, 4);
    expect(session.state, DownloadState.failed);
    expect(session.snapshot.failure?.code, ErrorCode.network);
    expect(session.hasWriter, isFalse);
    expect(owner.taskKeyFor(id), isNull);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(lookups, 5, reason: 'unchanged demand must not hot-loop');
  },
  );

  test('retry sleeper failure still reaches the bounded terminal outcome',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_retry_sleep_failure_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    var opens = 0;
    final id = _id('retry-sleep-failure');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-retry-sleep-failure',
      transportFor: (_) => _FailingOpenTransport(() => opens++),
      traceSink: const NoopTraceSink(),
      retry: const RetryPolicy(
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
      sleep: (_) async {
        throw StateError('retry clock failed');
      },
    );
    consumer.replaceDemands(
      'reader-retry-sleep-failure',
      1,
      _desired(id, priority: 780),
    );

    await consumer.idle().timeout(const Duration(seconds: 1));

    expect(opens, greaterThanOrEqualTo(3));
    expect(registry.get(id).state, DownloadState.failed);
    expect(registry.get(id).snapshot.failure?.code, ErrorCode.network);
  },
  );

  test('demand withdrawal during retry sleep does not start another attempt',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_retry_withdrawal_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final sleepStarted = Completer<void>();
    final releaseSleep = Completer<void>();
    var opens = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      if (!releaseSleep.isCompleted) releaseSleep.complete();
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('retry-withdrawal');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-retry-withdrawal',
      transportFor: (_) => _FailingOpenTransport(() => opens++),
      traceSink: const NoopTraceSink(),
      retry: const RetryPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 1),
      ),
      sleep: (_) {
        if (!sleepStarted.isCompleted) sleepStarted.complete();
        return releaseSleep.future;
      },
    );
    consumer.replaceDemands(
      'reader-retry-withdrawal',
      1,
      _desired(id, priority: 780),
    );

    await sleepStarted.future;
    consumer.replaceDemands('reader-retry-withdrawal', 2, const {});
    await net.idle().timeout(const Duration(seconds: 1));
    releaseSleep.complete();

    expect(opens, 1);
    expect(owner.taskKeyFor(id), isNull);
  },
  );

  test('authoritative progress cancels a stale recovery timer', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_retry_progress_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final sleepStarted = Completer<void>();
    final releaseSleep = Completer<void>();
    var opens = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      if (!releaseSleep.isCompleted) releaseSleep.complete();
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('retry-progress');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-retry-progress',
      transportFor: (_) => _FailingOpenTransport(() => opens++),
      traceSink: const NoopTraceSink(),
      retry: const RetryPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 1),
      ),
      sleep: (_) {
        if (!sleepStarted.isCompleted) sleepStarted.complete();
        return releaseSleep.future;
      },
    );
    consumer.replaceDemands(
      'reader-retry-progress',
      1,
      _desired(id, priority: 780),
    );

    await sleepStarted.future;
    final session = registry.get(id);
    await session.bindResponse(
      validators: const Validators(),
      totalLength: 1);
    final writer = session.acquireWriter();
    await session.append(writer, 0, <int>[1]);
    await session.pause(writer);

    releaseSleep.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(opens, 1);

    consumer.replaceDemands('reader-retry-progress', 2, const {});
    await net.idle().timeout(const Duration(seconds: 1));
  });

  test('cold local prepare hydrates physical partial before NetLane admission', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_before_lane_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final blockerStarted = Completer<void>();
    final blockerRelease = Completer<void>();
    net.submitRanked(
      key: 'network-blocker',
      priority: 900,
      bucket: 'source:test',
      bucketLimit: 1,
      task: (_) async {
        blockerStarted.complete();
        await blockerRelease.future;
      },
    );
    await blockerStarted.future;

    final partial = <int>[...'RIFF....WEBP'.codeUnits, ...List<int>.filled(4096, 7),
      ];
    final prepareDone = Completer<void>();
    var prepareCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
      prepareDownload: (session) async {
        prepareCalls++;
        await session.bindResponse(
          validators: const Validators(),
          totalLength: partial.length + 4096,
        );
        final writer = session.acquireWriter();
        await session.append(writer, 0, partial);
        await session.pause(writer);
        prepareDone.complete();
      },
    );
    addTearDown(() async {
      if (!blockerRelease.isCompleted) blockerRelease.complete();
      await owner.dispose();
      await net.idle();
      await registry.dispose();
    });

    final id = _id('cold-partial-before-lane');
    final transport = _CountingBytesTransport(
      <int>[...partial, ...List<int>.filled(4096, 8),
      ]);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-cold-partial-before-lane',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-cold-partial-before-lane',
      1,
      _desired(id, priority: 700),
    );
    await prepareDone.future;

    final session = registry.get(id);
    expect(prepareCalls, 1);
    expect(session.committedLength, partial.length);
    expect(session.state, DownloadState.idle);
    expect(transport.opens, 0);
    // The only NetLane slot is still held by unrelated network work. Local
    // hydration therefore cannot have depended on source/network admission.
    expect(net.active, 1);

    consumer.replaceDemands(
      'reader-cold-partial-before-lane',
      2,
      const <DownloadId, TransferDemand>{},
    );
    blockerRelease.complete();
    await net.idle();
    expect(transport.opens, 0);
  },
  );

  test('cancelling the final demand cancels controlled local preparation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_cancel_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final entered = Completer<void>();
    final cancelled = Completer<void>();
    var prepareCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownloadWithControl: (session, {required control}) async {
        prepareCalls++;
        entered.complete();
        try {
          await control.whenCancelled;
        } finally {
          if (!cancelled.isCompleted) cancelled.complete();
        }
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-prepare-cancel');
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-cancel',
      transportFor: (_) => _CountingBytesTransport('RIFF....WEBPcancel'.codeUnits),
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-local-prepare-cancel',
      1,
      _desired(id, priority: 800),
    );
    await entered.future;

    consumer.replaceDemands(
      'reader-local-prepare-cancel',
      2,
      const <DownloadId, TransferDemand>{},
    );
    await cancelled.future.timeout(const Duration(seconds: 1));
    expect(prepareCalls, 1);
    expect(owner.taskKeyFor(id), isNull);
    expect(owner.registry.get(id).state, DownloadState.idle);
  },
  );

  test('withdrawn local preparations release both operation slots for a new window',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_window_release_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final stale1 = _id('local-prepare-stale-1');
    final stale2 = _id('local-prepare-stale-2');
    final incoming = _id('local-prepare-incoming');
    final stale1Entered = Completer<void>();
    final stale2Entered = Completer<void>();
    final stale1Cancelled = Completer<void>();
    final stale2Cancelled = Completer<void>();
    final incomingEntered = Completer<void>();
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownloadWithControl: (session, {required control}) async {
        if (session.id == stale1 || session.id == stale2) {
          final entered = session.id == stale1 ? stale1Entered : stale2Entered;
          final cancelled =
              session.id == stale1 ? stale1Cancelled : stale2Cancelled;
          if (!entered.isCompleted) entered.complete();
          await control.whenCancelled;
          if (!cancelled.isCompleted) cancelled.complete();
          control.throwIfCancelled();
        }
        if (session.id == incoming && !incomingEntered.isCompleted) {
          incomingEntered.complete();
        }
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-window-release',
      transportFor: (_) =>
          _CountingBytesTransport('RIFF....WEBPwindow'.codeUnits),
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-local-prepare-window-release',
      1,
      <DownloadId, TransferDemand>{
        stale1: const TransferDemand(priority: 800, reason: 'old-next2'),
        stale2: const TransferDemand(priority: 780, reason: 'old-near'),
      },
    );
    await Future.wait<void>(<Future<void>>[
      stale1Entered.future,
      stale2Entered.future,
    ]);

    consumer.replaceDemands(
      'reader-local-prepare-window-release',
      2,
      <DownloadId, TransferDemand>{
        incoming: const TransferDemand(priority: 800, reason: 'new-next2'),
      },
    );

    await Future.wait<void>(<Future<void>>[
      stale1Cancelled.future,
      stale2Cancelled.future,
      incomingEntered.future,
    ]).timeout(const Duration(seconds: 1));

    consumer.replaceDemands(
      'reader-local-prepare-window-release',
      3,
      const <DownloadId, TransferDemand>{},
    );
  },
  );

  test('post-local network admission preserves higher demand priority', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_priority_barrier_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final high = _id('prepare-priority-current');
    final low = _id('prepare-priority-prefetch');
    final highRelease = Completer<void>();
    final lowRelease = Completer<void>();
    final highPrepared = Completer<void>();
    final lowPrepared = Completer<void>();
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 2),
      prepareDownload: (session) async {
        if (session.id == high) {
          await highRelease.future;
          highPrepared.complete();
        } else if (session.id == low) {
          await lowRelease.future;
          lowPrepared.complete();
        }
      },
    );
    addTearDown(() async {
      if (!highRelease.isCompleted) highRelease.complete();
      if (!lowRelease.isCompleted) lowRelease.complete();
      await owner.dispose();
      await registry.dispose();
    });

    final openOrder = <Uri>[];
    final consumer = owner.attachConsumer(
      scopeId: 'reader-prepare-priority',
      transportFor: (uri) {
        openOrder.add(uri);
        return _CountingBytesTransport('RIFF....WEBPpriority'.codeUnits);
      },
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-prepare-priority',
      1,
      <DownloadId, TransferDemand>{
        high: const TransferDemand(priority: 850, reason: 'next'),
        low: const TransferDemand(priority: 820, reason: 'next2'),
      },
    );

    // The lower-priority local miss completes first. It must not manufacture
    // an earlier source/runtime admission while current is still in the same
    // physical-owner pre-admission phase.
    lowRelease.complete();
    await lowPrepared.future;
    await Future<void>.delayed(Duration.zero);
    expect(openOrder, isEmpty);

    highRelease.complete();
    await highPrepared.future;
    await consumer.idle();
    expect(openOrder, hasLength(2));
    expect(openOrder.first, high.canonicalUri);
    expect(openOrder.last, low.canonicalUri);
  },
  );

  test('local preparation bounds operations without a foreground eligibility gate',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_bounded_prepare_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final foreground = _id('fg-prepare-bounded');
    final background1 = _id('bg1-prepare-bounded');
    final background2 = _id('bg2-prepare-bounded');
    final fgEntered = Completer<void>();
    final bg1Entered = Completer<void>();
    final bg2Entered = Completer<void>();
    final fgRelease = Completer<void>();
    final bg1Release = Completer<void>();
    var activePreparations = 0;
    var maxActivePreparations = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 3),
      prepareDownload: (session) async {
        activePreparations++;
        if (activePreparations > maxActivePreparations) {
          maxActivePreparations = activePreparations;
        }
        try {
          if (session.id == foreground) {
            if (!fgEntered.isCompleted) fgEntered.complete();
            await fgRelease.future;
          } else if (session.id == background1) {
            if (!bg1Entered.isCompleted) bg1Entered.complete();
            await bg1Release.future;
          } else if (session.id == background2) {
            if (!bg2Entered.isCompleted) bg2Entered.complete();
          }
        } finally {
          activePreparations--;
        }
      },
    );
    addTearDown(() async {
      if (!fgRelease.isCompleted) fgRelease.complete();
      if (!bg1Release.isCompleted) bg1Release.complete();
      await owner.dispose();
      await registry.dispose();
    });

    final consumer = owner.attachConsumer(
      scopeId: 'reader-bounded-prepare',
      transportFor: (uri) =>
          _CountingBytesTransport('RIFF....WEBPpriority'.codeUnits),
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-bounded-prepare',
      1,
      <DownloadId, TransferDemand>{
        foreground: const TransferDemand(priority: 1000, reason: 'current'),
        background1: const TransferDemand(priority: 820, reason: 'next'),
        background2: const TransferDemand(priority: 810, reason: 'next2'),
      },
    );

    await fgEntered.future;
    await bg1Entered.future;
    expect(bg2Entered.isCompleted, isFalse);
    expect(maxActivePreparations, equals(2));

    bg1Release.complete();
    await bg2Entered.future;
    expect(fgRelease.isCompleted, isFalse,
        reason: 'lower-priority work must not require current to finish first',
      );
    expect(maxActivePreparations, equals(2));

    fgRelease.complete();
    await consumer.idle();
  },
  );

  test(
      'blocked high-priority local preparation preempts one lower operation without narrowing the window',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_preempt_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    const clock = SystemClock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final background1 = _id('prepare-preempt-bg1');
    final background2 = _id('prepare-preempt-bg2');
    final promoted = _id('prepare-preempt-promoted');
    final bg1Entered = Completer<void>();
    final bg2Entered = Completer<void>();
    final bg2Cancelled = Completer<void>();
    final bg2Reentered = Completer<void>();
    final promotedEntered = Completer<void>();
    final bg1Release = Completer<void>();
    final bg2Release = Completer<void>();
    var bg2Calls = 0;
    var activePreparations = 0;
    var maxActivePreparations = 0;
    final trace = MemoryTraceSink();
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(
        maxActive: 3,
        reservedHighPrioritySlots: 1,
        highPriorityThreshold: 1000,
        preemptionThreshold: 40,
        preemptionCandidateGrace: const Duration(milliseconds: 20),
      ),
      prepareDownloadWithControl: (session, {required control}) async {
        activePreparations++;
        if (activePreparations > maxActivePreparations) {
          maxActivePreparations = activePreparations;
        }
        try {
          if (session.id == background1) {
            if (!bg1Entered.isCompleted) bg1Entered.complete();
            await Future.any<void>(<Future<void>>[
              control.whenCancelled,
              bg1Release.future,
            ]);
          } else if (session.id == background2) {
            bg2Calls++;
            if (!bg2Entered.isCompleted) bg2Entered.complete();
            if (bg2Calls >= 2 && !bg2Reentered.isCompleted) {
              bg2Reentered.complete();
            }
            await Future.any<void>(<Future<void>>[
              control.whenCancelled,
              bg2Release.future,
            ]);
            if (control.cancelled && !bg2Cancelled.isCompleted) {
              bg2Cancelled.complete();
            }
          } else if (session.id == promoted) {
            if (!promotedEntered.isCompleted) promotedEntered.complete();
          }
        } finally {
          activePreparations--;
        }
      },
    );
    addTearDown(() async {
      if (!bg1Release.isCompleted) bg1Release.complete();
      if (!bg2Release.isCompleted) bg2Release.complete();
      await owner.dispose();
      await registry.dispose();
    });

    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-preempt',
      transportFor: (_) =>
          _CountingBytesTransport('RIFF....WEBPpriority-preempt'.codeUnits),
      traceSink: trace,
    );
    consumer.replaceDemands(
      'reader-local-prepare-preempt',
      1,
      <DownloadId, TransferDemand>{
        background1: const TransferDemand(priority: 820, reason: 'next'),
        background2: const TransferDemand(priority: 800, reason: 'next2'),
        promoted: const TransferDemand(priority: 760, reason: 'near'),
      },
    );

    await bg1Entered.future;
    await bg2Entered.future;
    expect(promotedEntered.isCompleted, isFalse);
    expect(maxActivePreparations, 2);

    // The same page becomes foreground while both bounded local-operation
    // slots are occupied. Pipeline changes only its numeric rank; the physical
    // owner must let that rank cross the local-preparation seam promptly.
    consumer.replaceDemands(
      'reader-local-prepare-preempt',
      2,
      <DownloadId, TransferDemand>{
        background1: const TransferDemand(priority: 820, reason: 'next'),
        background2: const TransferDemand(priority: 800, reason: 'next2'),
        promoted: const TransferDemand(priority: 1000, reason: 'current'),
      },
    );

    expect(bg2Cancelled.isCompleted, isFalse,
        reason: 'a transient current must keep the shared preemption grace',
      );
    await bg2Cancelled.future.timeout(const Duration(seconds: 1));
    await promotedEntered.future.timeout(const Duration(seconds: 1));
    expect(maxActivePreparations, 2,
        reason: 'preemption must not exceed the operation-lifetime bound',
      );
    await bg2Reentered.future.timeout(const Duration(seconds: 1));
    expect(bg2Calls, 2,
        reason: 'preemption cancels only the acceleration attempt, not demand',
      );
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.policyDecision &&
            event.payload['stage'] == 'local-preparation-preempted' &&
            event.payload['incomingPriority'] == 1000 &&
            event.payload['victimPriority'] == 800,
      ),
      isTrue,
    );

    bg1Release.complete();
    bg2Release.complete();
    await consumer.idle();
  },
  );

  test('local preparation is retried after the physical session epoch resets',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_epoch_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final firstRelease = Completer<void>();
    final secondEntered = Completer<void>();
    var prepareCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (_) async {
        prepareCalls++;
        if (prepareCalls == 1) {
          await firstRelease.future;
        } else {
          secondEntered.complete();
          await Future<void>.delayed(Duration.zero);
        }
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-prepare-epoch');
    final transport = _CountingBytesTransport('RIFF....WEBPepoch'.codeUnits);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-epoch',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-local-prepare-epoch',
      1,
      _desired(id, priority: 800),
    );
    await Future<void>.delayed(Duration.zero);

    final session = registry.get(id);
    await session.reset();
    firstRelease.complete();
    await secondEntered.future.timeout(const Duration(seconds: 1));

    // The first preparation belonged to the discarded epoch. It must not
    // suppress hydration for the new generation or manufacture a network task
    // before the replacement preparation has returned.
    expect(prepareCalls, 2);
    expect(transport.opens, 0);
    consumer.replaceDemands(
      'reader-local-prepare-epoch',
      2,
      const <DownloadId, TransferDemand>{},
    );
  },
  );

  test('reentrant local preparation is coalesced before callback returns',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_reentrant_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final release = Completer<void>();
    final entered = Completer<void>();
    var prepareCalls = 0;
    late DownloadTransferConsumer consumer;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (_) async {
        prepareCalls++;
        if (prepareCalls == 1) {
          // The callback runs synchronously until its first await. This
          // refresh must observe the preparation slot already installed by
          // the owner rather than recursively starting another hydration.
          consumer.refreshScheduling();
          entered.complete();
          await release.future;
        }
      },
    );
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-prepare-reentrant');
    final transport = _CountingBytesTransport('RIFF....WEBPreentrant'.codeUnits,
      );
    consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-reentrant',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-local-prepare-reentrant',
      1,
      _desired(id, priority: 800),
    );

    await entered.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(prepareCalls, 1);

    release.complete();
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(prepareCalls, 1);
    expect(registry.get(id).state, DownloadState.promoted);
  },
  );

  test('failed local prepare falls back to provider once without prepare loop', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_local_prepare_fallback_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    var prepareCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      prepareDownload: (_) async {
        prepareCalls++;
        throw StateError('simulated durable partial read failure');
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('local-prepare-network-fallback');
    final transport = _CountingBytesTransport('RIFF....WEBPfallback'.codeUnits,
      );
    final consumer = owner.attachConsumer(
      scopeId: 'reader-local-prepare-network-fallback',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-local-prepare-network-fallback',
      1,
      _desired(id, priority: 1000),
    );
    await consumer.idle();

    expect(prepareCalls, 1);
    expect(transport.opens, 1);
    expect(registry.get(id).state, DownloadState.promoted);
  },
  );

  test('detached active physical work becomes inactive and is reclaimed only under pressure',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_preopen_rank_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final openingId = _id('opening-rank-zero');
    final nextId = _id('next-preempts-opening');
    final opening = _BlockedControlledTransport();
    final next = _CountingBytesTransport('RIFF....WEBPnext'.codeUnits);
    final a = owner.attachConsumer(
      scopeId: 'reader-opening',
      transportFor: (_) => opening,
      traceSink: const NoopTraceSink(),
    );
    final b = owner.attachConsumer(
      scopeId: 'reader-next',
      transportFor: (_) => next,
      traceSink: const NoopTraceSink(),
    );

    a.replaceDemands('reader-opening', 1, _desired(openingId, priority: 820));
    await opening.opened.future;
    final openingKey = owner.taskKeyFor(openingId)!;
    expect(net.isActive(openingKey), isTrue);
    expect(net.demandedOf(openingKey), isTrue);

    a.replaceDemands('reader-opening', 2, const <DownloadId, TransferDemand>{},
      );
    expect(net.isActive(openingKey), isTrue);
    expect(net.priorityOf(openingKey), 0);
    expect(net.demandedOf(openingKey), isFalse);
    expect(opening.cancelled.isCompleted, isFalse);

    b.replaceDemands('reader-next', 1, _desired(nextId, priority: 780));
    await opening.cancelled.future.timeout(const Duration(seconds: 1));
    await b.idle();
    expect(next.opens, 1);
    expect(registry.get(nextId).state, DownloadState.promoted);
  },
  );

  test('working-set turn out and back reuses the same active physical task', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_revisit_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('turn-out-back');
    final transport = _BlockedControlledTransport();
    final trace = MemoryTraceSink();
    final reader = owner.attachConsumer(
      scopeId: 'reader-turn-out-back',
      transportFor: (_) => transport,
      traceSink: trace,
    );

    reader.replaceDemands('reader-turn-out-back', 1, _desired(id, priority: 820),
      );
    await transport.opened.future;
    final firstKey = owner.taskKeyFor(id)!;
    expect(net.isActive(firstKey), isTrue);
    expect(net.demandedOf(firstKey), isTrue);

    reader.replaceDemands(
      'reader-turn-out-back',
      2,
      const <DownloadId, TransferDemand>{},
    );
    expect(owner.taskKeyFor(id), firstKey);
    expect(net.isActive(firstKey), isTrue);
    expect(net.demandedOf(firstKey), isFalse);
    expect(transport.cancelled.isCompleted, isFalse);
    final retentionEntered = trace.events.lastWhere(
      (event) =>
          event.kind == TraceEventKind.policyDecision &&
          event.payload['stage'] == 'inactive-retention-enter',
    );
    expect(retentionEntered.payload['networkPhase'], 'opening');
    expect(retentionEntered.payload['responseOpened'], isFalse);
    expect(retentionEntered.payload['transportLeaseHeld'], isTrue);

    reader.replaceDemands('reader-turn-out-back', 3, _desired(id, priority: 800),
      );
    expect(owner.taskKeyFor(id), firstKey);
    expect(net.isActive(firstKey), isTrue);
    expect(net.demandedOf(firstKey), isTrue);
    expect(net.priorityOf(firstKey), 800);
    expect(transport.cancelled.isCompleted, isFalse);
    final retentionReattached = trace.events.lastWhere(
      (event) =>
          event.kind == TraceEventKind.policyDecision &&
          event.payload['stage'] == 'inactive-retention-reattached',
    );
    expect(retentionReattached.payload['networkPhase'], 'opening');
    expect(retentionReattached.payload['responseOpened'], isFalse);
    expect(retentionReattached.payload['inactiveMicros'], isA<int>());

    // Disposal is the explicit lifetime boundary for this consumer-bound
    // transport; ordinary working-set churn above never cancelled it.
    await reader.dispose();
    await transport.cancelled.future.timeout(const Duration(seconds: 1));
  },
  );

  test('scheduler preemption preserves committed partial as idle state', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_preempt_partial_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final victimId = _id('preempted-partial');
    final incomingId = _id('incoming-current');
    final victimBytes = _ownerAnimatedWebp(<int>[96 * 1024, 48, 48]);
    const prefixLength = 64 * 1024;
    final victim = _RetainedGateControlledTransport(
      prefix: victimBytes.sublist(0, prefixLength),
      suffix: victimBytes.sublist(prefixLength),
    );
    final incoming = _CountingBytesTransport(
      _ownerAnimatedWebp(<int>[48]));
    final trace = MemoryTraceSink();
    final oldReader = owner.attachConsumer(
      scopeId: 'reader-preempt-victim',
      transportFor: (_) => throw StateError('retained transport must win'),
      retainedTransportFor: (_) => victim,
      traceSink: trace,
    );
    final currentReader = owner.attachConsumer(
      scopeId: 'reader-preempt-current',
      transportFor: (_) => incoming,
      traceSink: trace,
    );

    oldReader.replaceDemands(
      'reader-preempt-victim',
      1,
      _desired(victimId, priority: 820),
    );
    await victim.prefixSent.future.timeout(const Duration(seconds: 1));
    final session = registry.get(victimId);
    await _waitUntil(() => session.committedLength > 0);
    final preservedLength = session.committedLength;

    oldReader.replaceDemands(
      'reader-preempt-victim',
      2,
      const <DownloadId, TransferDemand>{},
    );
    expect(session.effectivePriority, 0);

    currentReader.replaceDemands(
      'reader-preempt-current',
      1,
      _desired(incomingId, priority: 1000),
    );
    await victim.cancelled.future.timeout(const Duration(seconds: 1));
    await currentReader.idle().timeout(const Duration(seconds: 2));

    expect(session.state, DownloadState.idle);
    expect(session.snapshot.failure, isNull);
    expect(session.committedLength, preservedLength);
    final preemption = trace.events.lastWhere(
      (event) =>
          (event.kind == TraceEventKind.downloadPreempted ||
              event.kind == TraceEventKind.downloadEvicted) &&
          event.identityHash == victimId.key,
    );
    expect(preemption.payload['partialPreserved'], isTrue);
    expect(preemption.payload['partialState'], DownloadState.idle.name);
  },
  );

  test('queued priority revisions keep one physical transfer task identity', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_queue_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final blockerStarted = Completer<void>();
    final blockerRelease = Completer<void>();
    net.submitRanked(
      key: 'blocker',
      priority: 1000,
      bucket: 'blocker',
      bucketLimit: 1,
      task: (_) async {
        blockerStarted.complete();
        await blockerRelease.future;
      },
    );
    await blockerStarted.future;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('queued-priority');
    final transport = _CountingBytesTransport('RIFF....WEBPqueued'.codeUnits);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-queued',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-queued',
      1,
      _desired(id, priority: 700));
    final taskKey = owner.taskKeyFor(id);
    expect(taskKey, isNotNull);
    expect(net.queued, 1);

    consumer.replaceDemands(
      'reader-queued',
      2,
      _desired(id, priority: 720));
    consumer.replaceDemands(
      'reader-queued',
      3,
      _desired(id, priority: 780));
    consumer.replaceDemands(
      'reader-queued',
      4,
      _desired(id, priority: 1000));

    expect(owner.taskKeyFor(id), taskKey);
    expect(net.queued, 1);
    expect(net.priorityOf(taskKey!), 1000);

    blockerRelease.complete();
    await consumer.idle();
    expect(transport.opens, 1);
    expect(registry.get(id).state, DownloadState.promoted);
  },
  );

  test('consumer-paced flow suspension stays quiescent until unmet target arrives',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_flow_suspension_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('flow-suspension');
    final bytes = _ownerAnimatedWebp(<int>[48, 48, 48]);
    registry.get(id).observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _FlowSuspendingTransport(bytes, chunkSize: 17);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-flow',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-flow',
      1,
      _desired(id, priority: 700, flowTargetFrames: 1),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    final suspended = registry.get(id);
    expect(suspended.networkFlowSatisfiedFrames, greaterThanOrEqualTo(1));
    expect(suspended.committedLength, greaterThan(0));
    expect(transport.opens, 1);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(transport.opens, 1,
        reason: 'satisfied speculative credit must not reopen itself',
      );

    consumer.replaceDemands(
      'reader-flow',
      2,
      _desired(id, priority: 1000, flowTargetFrames: 0),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(registry.get(id).state, DownloadState.promoted);
    expect(transport.opens, 1,
        reason: 'raising flow credit resumes from the preserved open response',
      );
  },
  );

  test(
      'flow frame proof satisfies lower targets across role and demand changes',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_flow_frame_proof_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('flow-frame-proof');
    final bytes = _ownerAnimatedWebp(List<int>.filled(8, 48));
    registry.get(id).observePlayablePrefixEvidence(
      decodedPrefixFrames: 1,
      sourceLength: 1,
      firstPlayablePrefixBytes: 1,
      firstFrameRequiredSourceLength: 0,
    );
    final transport = _FlowSuspendingTransport(bytes, chunkSize: 220);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-flow-proof',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-flow-proof',
      1,
      _desired(id, priority: 700, flowTargetFrames: 1),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    final session = registry.get(id);
    expect(session.networkFlowSatisfiedFrames, greaterThanOrEqualTo(1));
    expect(transport.opens, 1);

    // One transport chunk contains three complete ANMF records. The physical
    // partial therefore proves more frames than the target that happened to
    // trigger suspension. Lower/equal future targets must reuse that proof.
    consumer.replaceDemands(
      'reader-flow-proof',
      2,
      _desired(id, priority: 780, flowTargetFrames: 2),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(transport.opens, 1);

    consumer.replaceDemands(
      'reader-flow-proof',
      3,
      const <DownloadId, TransferDemand>{},
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    consumer.replaceDemands(
      'reader-flow-proof',
      4,
      _desired(id, priority: 800, flowTargetFrames: 3),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(transport.opens, 1,
        reason: 'flow proof belongs to the partial, not to a live demand',
      );

    consumer.replaceDemands(
      'reader-flow-proof',
      5,
      _desired(id, priority: 820, flowTargetFrames: 4),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(transport.opens, 1,
        reason: 'only a target above the proven frame floor may reopen',
      );

    consumer.replaceDemands(
      'reader-flow-proof',
      6,
      _desired(id, priority: 1000, flowTargetFrames: 0),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    expect(registry.get(id).state, DownloadState.promoted);
    expect(transport.opens, 1,
        reason: 'foreground unlimited must not be satisfied by a bounded proof',
      );
  },
  );

  test('decoder prefix floor invalidates an insufficient structural flow proof',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_playable_flow_floor_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('playable-flow-floor');
    final bytes = _ownerAnimatedWebp(<int>[48, 48, 768 * 1024]);
    final transport = _FlowSuspendingTransport(bytes, chunkSize: 64 * 1024);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-playable-flow-floor',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-playable-flow-floor',
      1,
      _desired(id, priority: 700, flowTargetFrames: 2),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));
    final session = registry.get(id);
    final firstSuspendedLength = session.committedLength;
    expect(firstSuspendedLength, greaterThanOrEqualTo(256 * 1024));
    expect(firstSuspendedLength, lessThan(512 * 1024));
    expect(transport.opens, 1);

    consumer.observeDecodePrefixEvidence(
      session,
      DecodeSnapshot(
        id: DecodeId(
          download: id,
          physicalWidth: 1,
          physicalHeight: 1,
          pixelFormat: PixelFormat.rgba8888,
          renderer: RendererKind.androidTexture,
        ),
        state: DecodeState.waitingSource,
        epoch: const SourceEpoch(0),
        depth: 0,
        bytes: 0,
        revision: 1,
        animation: const AnimationInfo.unknown(),
        cycle: 0,
        sourceLength: firstSuspendedLength,
        sourceSealed: false,
        requiredSourceLength: 512 * 1024,
        decodedPrefixFrames: 0,
        firstPlayablePrefixBytes: 0,
        firstFrameRequiredSourceLength: 512 * 1024,
      ),
    );
    await consumer.idle().timeout(const Duration(seconds: 2));

    expect(transport.opens, 1,
        reason: 'decoder need-more-data must invalidate the old flow proof',
      );
    expect(session.committedLength, greaterThanOrEqualTo(512 * 1024));
  },
  );

  test('transfer checksum constraints aggregate across consumers atomically',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_checksum_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final net = NetLane(maxActive: 1);
    final blockerStarted = Completer<void>();
    final blockerRelease = Completer<void>();
    net.submitRanked(
      key: 'checksum-blocker',
      priority: 1000,
      bucket: 'blocker',
      bucketLimit: 1,
      task: (_) async {
        blockerStarted.complete();
        await blockerRelease.future;
      },
    );
    await blockerStarted.future;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
    );
    addTearDown(() async {
      if (!blockerRelease.isCompleted) blockerRelease.complete();
      await owner.dispose();
      await registry.dispose();
    });
    final id = _id('checksum-shared');
    final transport = _CountingBytesTransport('RIFF....WEBPchecksum'.codeUnits,
      );
    final reader = owner.attachConsumer(
      scopeId: 'reader-checksum',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    final chapter = owner.attachConsumer(
      scopeId: 'chapter-checksum',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    final conflicting = owner.attachConsumer(
      scopeId: 'chapter-conflict',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );

    reader.replaceDemands(
      'reader-checksum',
      1,
      _desired(id, priority: 1000));
    chapter.replaceDemands(
      'chapter-checksum',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-command',
          expectedChecksum: 'checksum-a',
        ),
      });
    expect(owner.claimCount(id), 2);
    expect(registry.sessions, hasLength(1));

    // Checksum proof is case/whitespace normalized at the physical owner
    // boundary; a second consumer must not be rejected for spelling the same
    // digest differently.
    chapter.replaceDemands(
      'chapter-checksum',
      2,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-command',
          expectedChecksum: ' CHECKSUM-A ',
        ),
      });
    expect(owner.claimCount(id), 2);

    expect(
      () => conflicting.replaceDemands(
        'chapter-conflict',
        1,
        <DownloadId, TransferDemand>{
          id: const TransferDemand(
            priority: 120,
            reason: 'chapter-command',
            expectedChecksum: 'checksum-b',
          ),
        }),
      throwsStateError,
    );
    expect(conflicting.demands, isEmpty);
    expect(owner.claimCount(id), 2);
    expect(registry.sessions, hasLength(1));
  },
  );

  test('required completion dynamically bypasses speculative budget on same physical task', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_required_budget_bypass_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final budget = SpeculativeEncodedReadBudget(limitBytes: 64);
    final net = NetLane(maxActive: 1);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
      speculativeEncodedReadBudget: budget,
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('required-budget-bypass');
    final bytes = List<int>.generate(192, (index) => index & 0xff);
    final transport = _FlowSuspendingTransport(bytes, chunkSize: 64);
    final reader = owner.attachConsumer(
      scopeId: 'reader-budgeted',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    reader.replaceDemands(
      'reader-budgeted',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 700,
          reason: 'reader-prefetch'),
      });

    for (var attempt = 0;
        attempt < 100 && budget.activeSpeculativeBytes < 64;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(budget.activeSpeculativeBytes, 64);
    expect(registry.get(id).state, DownloadState.receiving);
    expect(transport.opens, 1);
    for (var attempt = 0;
        attempt < 100 && net.readPermitReleasedTasks < 1;
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(registry.get(id).state, DownloadState.receiving,
        reason: 'speculative task must remain paused at the byte budget',
      );
    expect(budget.activeSpeculativeBytes, 64);
    expect(net.readPermitReleasedTasks, 1,
        reason: 'budget waiting must park the response instead of occupying the read permit',
      );

    final required = owner.attachConsumer(
      scopeId: 'chapter-required-budget-bypass',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    required.replaceDemands(
      'chapter-required-budget-bypass',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-download-command',
          completionIntent: TransferCompletionIntent.required,
        ),
      },
    );

    await required.idle().timeout(const Duration(seconds: 2));
    expect(registry.get(id).state, DownloadState.promoted);
    expect(transport.opens, 1,
        reason: 'required completion must reuse the already-open physical task',
      );
  },
  );

  test('confirmed full-body mismatch discards one stale partial and restarts clean', () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_resume_mismatch_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final trace = MemoryTraceSink();
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('resume-mismatch-clean-restart');
    final oldBytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(96 * 1024, (index) => index & 0xff),
    ];
    final newBytes = List<int>.of(oldBytes)..[32] ^= 0xff;
    final session = registry.get(id);
    await session.restore();
    await session.bindResponse(
      validators: const Validators(),
      totalLength: oldBytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, oldBytes.sublist(0, 64 * 1024));
    await session.pause(writer);
    final staleLength = session.committedLength;

    final transport = _CountingBytesTransport(newBytes);
    final consumer = owner.attachConsumer(
      scopeId: 'reader-resume-mismatch-clean-restart',
      transportFor: (_) => transport,
      traceSink: trace,
      retry: const RetryPolicy(
        maxAttempts: 1,
        baseDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );
    consumer.replaceDemands(
      'reader-resume-mismatch-clean-restart',
      1,
      _desired(id, priority: 1000),
    );

    await consumer.idle().timeout(const Duration(seconds: 2));
    final result = registry.get(id);
    expect(result.state, DownloadState.promoted);
    expect(result.epoch.value, 1);
    expect(transport.opens, 2,
        reason: 'one mismatching catchup plus one clean offset-zero restart',
      );
    expect(
      await File(result.artifact.finalPath).readAsBytes(),
      newBytes);
    final restart = trace.events.singleWhere(
      (event) =>
          event.kind == TraceEventKind.resumeRestarted &&
          event.payload['strategy'] ==
              'confirmed-full-body-mismatch-clean-restart',
    );
    expect(restart.payload['discardedPartialBytes'], staleLength);
  },
  );

  test('required completion claim can finish a costly full-body catchup', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_required_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('required-completion');
    final fullBytes = List<int>.generate(
      2 * 1024 * 1024,
      (index) => index & 0xff,
      growable: false,
    );
    final preservedLength = 1200 * 1024;
    final session = registry.get(id);
    await session.restore();
    await session.bindResponse(
      validators: const Validators(),
      totalLength: fullBytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, fullBytes.sublist(0, preservedLength));
    await session.fail(
      writer,
      const Failure(code: ErrorCode.network, message: 'simulated partial'),
    );

    final transport = _CountingBytesTransport(fullBytes);
    final opportunistic = owner.attachConsumer(
      scopeId: 'prefetch-low',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    opportunistic.replaceDemands(
      'prefetch-low',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'opportunistic-prefetch',
        ),
      },
    );
    await opportunistic.idle();
    expect(session.state, isNot(DownloadState.promoted));
    expect(session.committedLength, preservedLength);

    final required = owner.attachConsumer(
      scopeId: 'chapter-required',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    required.replaceDemands(
      'chapter-required',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-download-command',
          completionIntent: TransferCompletionIntent.required,
        ),
      });
    await required.idle();
    expect(session.state, DownloadState.promoted);
    expect(session.committedLength, fullBytes.length);
  },
  );

  test('final consumer detach retains hot physical partial for later reuse',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_partial_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('partial-detach');
    final transport = _PrefixThenBlockTransport();
    final consumer = owner.attachConsumer(
      scopeId: 'reader-partial',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reader-partial',
      1,
      _desired(id, priority: 1000),
    );
    final session = registry.get(id);
    final committed = Completer<void>();
    void listener(DownloadSnapshot snapshot) {
      if (snapshot.committedLength > 0 && !committed.isCompleted) {
        committed.complete();
      }
    }
    session.addSnapshotListener(listener);
    await committed.future;
    session.removeSnapshotListener(listener);

    await consumer.dispose();
    expect(session.activeRun, isFalse);
    expect(session.committedLength, greaterThan(0));
    expect(registry.sessions, hasLength(1));
    expect(identical(registry.findExact(id), session), isTrue);
  },
  );

  test('equivalent failed partial resumes through provider exact request URI', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_alias_source_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = _id('physical-old');
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-new',
        chapterId: 'chapter-new',
        pageId: 'exact-new',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('custom-resource:exact-new'),
    );
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0,
      ...'WEBP'.codeUnits,
      ...List<int>.generate(128, (index) => index & 0xff),
    ];
    final session = registry.get(physical);
    await session.restore();
    await session.bindResponse(
      validators: const Validators(etag: 'old-provider-v1'),
      totalLength: bytes.length,
    );
    final writer = session.acquireWriter();
    await session.append(writer, 0, bytes.sublist(0, 32));
    await session.fail(
      writer,
      const Failure(code: ErrorCode.network, message: 'old provider failed'),
    );
    expect(session.state, DownloadState.failed);
    expect(session.committedLength, 32);

    final transport = _ExactUriRangeTransport(
      expectedUri: exact.canonicalUri,
      bytes: bytes,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      resolveTransferId: (id) {
        if (id == exact) {
          registry.aliasPhysical(id: exact, target: physical);
          return physical;
        }
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });
    final consumer = owner.attachConsumer(
      scopeId: 'reader-new-version',
      transportFor: (uri) {
        expect(uri, exact.canonicalUri);
        return transport;
      },
      traceSink: const NoopTraceSink(),
    );

    consumer.replaceDemands(
      'reader-new-version',
      1,
      _desired(exact, priority: 1000),
    );
    await consumer.idle();

    expect(session.state, DownloadState.promoted);
    expect(session.id, physical);
    expect(registry.resolvePhysicalId(exact), physical);
    expect(transport.openedUris, isNotEmpty);
    expect(transport.openedUris, everyElement(exact.canonicalUri));
    expect(transport.ranges.first?.start, 0);
    expect(transport.validatorsSeen.first, isNull);
    expect(await File(session.artifact.finalPath).readAsBytes(), bytes);
  },
  );

  test(
      'orphaned provider claim stays on the admitted task until provider disposal',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_provider_retain_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = _id('provider-retain-old');
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-new',
        chapterId: 'chapter-new',
        pageId: 'provider-retain-new',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/provider-retain-new.webp',
        ),
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      resolveTransferId: (id) {
        if (id == exact) {
          registry.aliasPhysical(id: exact, target: physical);
          return physical;
        }
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final fullBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(24 * 1024, 7),
    ];
    final oldTransport = _PrefixThenBlockTransport(
      fullBytes.sublist(0, 20 * 1024),
    );
    final newTransport = _GateBytesTransport(fullBytes);
    final oldReader = owner.attachConsumer(
      scopeId: 'reader-old-provider',
      transportFor: (_) => oldTransport,
      traceSink: const NoopTraceSink(),
    );
    final newReader = owner.attachConsumer(
      scopeId: 'reader-new-provider',
      transportFor: (uri) {
        expect(uri, exact.canonicalUri);
        return newTransport;
      },
      traceSink: const NoopTraceSink(),
    );

    oldReader.replaceDemands(
      'reader-old-provider',
      1,
      _desired(physical, priority: 1000),
    );
    final session = registry.get(physical);
    final committed = Completer<void>();
    void listener(DownloadSnapshot snapshot) {
      if (snapshot.committedLength > 0 && !committed.isCompleted) {
        committed.complete();
      }
    }
    session.addSnapshotListener(listener);
    await committed.future;
    session.removeSnapshotListener(listener);
    expect(owner.activeProviderScope(physical), 'reader-old-provider');
    expect(owner.activeProviderExactId(physical), physical);

    oldReader.replaceDemands(
      'reader-old-provider',
      2,
      const <DownloadId, TransferDemand>{},
    );
    expect(session.demandCount, 0);
    expect(session.activeRun, isTrue);

    newReader.replaceDemands(
      'reader-new-provider',
      1,
      _desired(exact, priority: 820),
    );
    await Future<void>.delayed(Duration.zero);

    expect(registry.resolvePhysicalId(exact), physical);
    expect(identical(registry.find(exact), session), isTrue);
    expect(newTransport.opened.isCompleted, isFalse);
    expect(owner.activeProviderScope(physical), 'reader-old-provider');
    expect(owner.activeProviderExactId(physical), physical);
    expect(session.committedLength, greaterThan(0));
    expect(session.effectivePriority, 820);

    // The old Reader claim is already gone, but its transport owner is still
    // alive. Only disposing that provider consumer is allowed to revoke the
    // admitted attempt and reopen on the remaining exact provider.
    await oldReader.dispose();
    await newTransport.opened.future;
    expect(owner.activeProviderScope(physical), 'reader-new-provider');
    expect(owner.activeProviderExactId(physical), exact);

    newTransport.release.complete();
    await newReader.idle();
    expect(session.state, DownloadState.promoted);
  },
  );


  test(
      'current exact demand migrates physical rank without replacing the admitted equivalent provider',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_current_provider_stable_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = _id('current-provider-old');
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-current-v2',
        chapterId: 'chapter-current-v2',
        pageId: 'current-provider-new',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/current-provider-new.webp',
        ),
    );
    final net = NetLane(maxActive: 1, highPriorityThreshold: 1000);
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: net,
      resolveTransferId: (id) {
        if (id == exact) {
          registry.aliasPhysical(id: exact, target: physical);
          return physical;
        }
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final fullBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(48 * 1024, 13),
    ];
    final retainedOldTransport = _RetainedGateControlledTransport(
      prefix: fullBytes.sublist(0, 20 * 1024),
      suffix: fullBytes.sublist(20 * 1024),
    );
    final currentTransport = _GateBytesTransport(fullBytes);
    final oldReader = owner.attachConsumer(
      scopeId: 'reader-old-version',
      transportFor: (_) => throw StateError('retained transport must win'),
      retainedTransportFor: (_) => retainedOldTransport,
      traceSink: const NoopTraceSink(),
    );
    final currentReader = owner.attachConsumer(
      scopeId: 'reader-current-version',
      transportFor: (_) => currentTransport,
      traceSink: const NoopTraceSink(),
    );

    oldReader.replaceDemands(
      'reader-old-version',
      1,
      _desired(physical, priority: 820),
    );
    final session = registry.get(physical);
    await retainedOldTransport.prefixSent.future;
    final prefixLength = session.committedLength;
    expect(prefixLength, greaterThan(0));

    oldReader.replaceDemands(
      'reader-old-version',
      2,
      const <DownloadId, TransferDemand>{},
    );
    currentReader.replaceDemands(
      'reader-current-version',
      1,
      _desired(exact, priority: 1000),
    );
    await Future<void>.delayed(Duration.zero);

    expect(registry.resolvePhysicalId(exact), physical);
    expect(identical(registry.find(exact), session), isTrue);
    expect(session.committedLength, prefixLength);
    expect(session.effectivePriority, 1000);
    expect(owner.activeProviderScope(physical), 'reader-old-version');
    expect(owner.activeProviderExactId(physical), physical);
    expect(retainedOldTransport.cancelled.isCompleted, isFalse);
    expect(currentTransport.opened.isCompleted, isFalse);

    retainedOldTransport.release.complete();
    await currentReader.idle();
    expect(session.state, DownloadState.promoted);
    expect(currentTransport.opened.isCompleted, isFalse);
  },
  );


  test(
      'provider exact selection is task lifetime state rather than scheduler policy',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_provider_task_lifetime_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = _id('provider-task-old');
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-provider-v2',
        chapterId: 'chapter-provider-v2',
        pageId: 'provider-task-new',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/provider-task-new.webp'),
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(
        maxActive: 1,
        highPriorityThreshold: 1000,
        preemptionThreshold: 40,
      ),
      resolveTransferId: (id) {
        if (id == exact) {
          registry.aliasPhysical(id: exact, target: physical);
          return physical;
        }
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final fullBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(48 * 1024, 17),
    ];
    final oldTransport = _RetainedGateControlledTransport(
      prefix: fullBytes.sublist(0, 20 * 1024),
      suffix: fullBytes.sublist(20 * 1024),
    );
    final newTransport = _GateBytesTransport(fullBytes);
    final oldReader = owner.attachConsumer(
      scopeId: 'reader-provider-old',
      transportFor: (_) => throw StateError('retained transport must win'),
      retainedTransportFor: (_) => oldTransport,
      traceSink: const NoopTraceSink(),
    );
    final newReader = owner.attachConsumer(
      scopeId: 'reader-provider-new',
      transportFor: (_) => newTransport,
      traceSink: const NoopTraceSink(),
    );

    oldReader.replaceDemands(
      'reader-provider-old',
      1,
      _desired(physical, priority: 820),
    );
    await oldTransport.prefixSent.future;
    final session = registry.get(physical);
    final prefixLength = session.committedLength;
    expect(prefixLength, greaterThan(0));

    newReader.replaceDemands(
      'reader-provider-new',
      1,
      _desired(exact, priority: 1000),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.effectivePriority, 1000);
    expect(session.committedLength, prefixLength);
    expect(oldTransport.cancelled.isCompleted, isFalse);
    expect(newTransport.opened.isCompleted, isFalse);
    expect(owner.activeProviderExactId(physical), physical);

    oldTransport.release.complete();
    await newReader.idle();
    expect(session.state, DownloadState.promoted);
    expect(newTransport.opened.isCompleted, isFalse);
  },
  );


  test('a re-demand waits for cancelled task retirement before reopening',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_cancel_redemand_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('cancel-redemand');
    final transport = _CancelThenSucceedTransport(
      bytes: _ownerAnimatedWebp(<int>[24]),
    );
    final consumer = owner.attachConsumer(
      scopeId: 'cancel-redemand-reader',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'cancel-redemand',
      1,
      _desired(id, priority: 700),
    );
    await transport.firstOpened.future.timeout(const Duration(seconds: 1));
    final firstTaskKey = owner.taskKeyFor(id);
    expect(firstTaskKey, isNotNull);
    owner.net.cancel(firstTaskKey!);
    await transport.firstCancelled.future.timeout(const Duration(seconds: 1));

    // The old token is still active while its controlled open unwinds. A new
    // demand must not revive that cancelled token or admit a second physical
    // task beside it.
    consumer.replaceDemands(
      'cancel-redemand',
      2,
      _desired(id, priority: 1000),
    );
    expect(owner.taskKeyFor(id), firstTaskKey);
    await consumer.idle().timeout(const Duration(seconds: 2));

    expect(transport.opens, 2);
    expect(registry.get(id).state, DownloadState.promoted);
  },
  );

  test('reset during an admitted open cannot publish stale lifecycle failure',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'transfer_owner_reset_during_open_',
    );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('reset-during-open');
    final transport = _GateBytesTransport(_ownerAnimatedWebp(<int>[24]));
    final consumer = owner.attachConsumer(
      scopeId: 'reset-during-open-reader',
      transportFor: (_) => transport,
      traceSink: const NoopTraceSink(),
    );
    consumer.replaceDemands(
      'reset-during-open-reader',
      1,
      _desired(id, priority: 800),
    );
    await transport.opened.future.timeout(const Duration(seconds: 1));

    final session = registry.get(id);
    await session.reset();
    expect(session.state, DownloadState.idle);
    expect(session.hasWriter, isFalse);
    expect(session.snapshot.failure, isNull);

    // The old open now completes against the reset generation. Its stale run
    // must retire normally, after which the owner admits one fresh task for
    // the still-demanded session.
    transport.release.complete();
    await consumer.idle().timeout(const Duration(seconds: 2));

    expect(transport.opens, 2);
    expect(session.state, DownloadState.promoted);
    expect(session.snapshot.failure, isNull);
    expect(session.hasWriter, isFalse);
  },
  );

  test(
      'task-retained transport survives provider consumer disposal on shared partial',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_retained_transport_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final physical = _id('retained-transport-physical');
    final exact = DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic-v2',
        chapterId: 'chapter-v2',
        pageId: 'retained-transport-exact',
      ),
      sourceRevision: 'r2',
      canonicalUri: Uri.parse('https://example.test/retained-transport-exact.webp',
        ),
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      resolveTransferId: (id) {
        if (id == exact) {
          registry.aliasPhysical(id: exact, target: physical);
          return physical;
        }
        return id;
      },
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final fullBytes = <int>[
      ...'RIFF....WEBP'.codeUnits,
      ...List<int>.filled(96 * 1024, 11),
    ];
    final retainedTransport = _RetainedGateControlledTransport(
      prefix: fullBytes.sublist(0, 32 * 1024),
      suffix: fullBytes.sublist(32 * 1024),
    );
    final replacementTransport = _GateBytesTransport(fullBytes);
    final oldReader = owner.attachConsumer(
      scopeId: 'reader-retained-provider',
      transportFor: (_) => throw StateError('retained transport must win'),
      retainedTransportFor: (_) => retainedTransport,
      traceSink: const NoopTraceSink(),
    );
    final newReader = owner.attachConsumer(
      scopeId: 'reader-replacement-provider',
      transportFor: (_) => replacementTransport,
      traceSink: const NoopTraceSink(),
    );

    oldReader.replaceDemands(
      'reader-retained-provider',
      1,
      _desired(physical, priority: 1000),
    );
    final session = registry.get(physical);
    await retainedTransport.prefixSent.future;
    final committed = Completer<void>();
    void listener(DownloadSnapshot snapshot) {
      if (snapshot.committedLength > 0 && !committed.isCompleted) {
        committed.complete();
      }
    }
    session.addSnapshotListener(listener);
    if (session.committedLength == 0) await committed.future;
    session.removeSnapshotListener(listener);
    final prefixLength = session.committedLength;
    expect(prefixLength, greaterThan(0));

    oldReader.replaceDemands(
      'reader-retained-provider',
      2,
      const <DownloadId, TransferDemand>{},
    );
    newReader.replaceDemands(
      'reader-replacement-provider',
      1,
      _desired(exact, priority: 820),
    );
    await oldReader.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(retainedTransport.cancelled.isCompleted, isFalse);
    expect(replacementTransport.opened.isCompleted, isFalse);
    expect(registry.resolvePhysicalId(exact), physical);
    expect(identical(registry.find(exact), session), isTrue);
    expect(session.committedLength, prefixLength);

    retainedTransport.release.complete();
    await newReader.idle();
    expect(retainedTransport.cancelled.isCompleted, isFalse);
    expect(replacementTransport.opened.isCompleted, isFalse);
    expect(session.state, DownloadState.promoted);
    expect(session.committedLength, fullBytes.length);
  },
  );

  test('disposing active provider preserves remaining consumer and reopens once',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_detach_',
      );
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
    );
    addTearDown(() async {
      await owner.dispose();
      await registry.dispose();
    });

    final id = _id('provider-detach');
    final transportA = _BlockedControlledTransport();
    final transportB = _CountingBytesTransport('RIFF....WEBPresumed'.codeUnits,
      );
    final a = owner.attachConsumer(
      scopeId: 'reader-a',
      transportFor: (_) => transportA,
      traceSink: const NoopTraceSink(),
    );
    final b = owner.attachConsumer(
      scopeId: 'reader-b',
      transportFor: (_) => transportB,
      traceSink: const NoopTraceSink(),
    );

    a.replaceDemands('reader-a', 1, _desired(id, priority: 1000));
    await transportA.opened.future;
    b.replaceDemands('reader-b', 1, _desired(id, priority: 700));
    final session = registry.get(id);
    expect(owner.activeProviderScope(id), 'reader-a');
    expect(owner.claimCount(id), 2);
    expect(session.effectivePriority, 1000);

    await a.dispose();
    await transportA.cancelled.future;
    expect(a.disposed, isTrue);
    expect(owner.claimCount(id), 1);
    expect(session.demandCount, 1);
    expect(session.effectivePriority, 700);

    await b.idle();
    expect(session.state, DownloadState.promoted);
    expect(transportB.opens, 1);
    expect(registry.sessions, hasLength(1));
    expect(owner.claimCount(id), 1);
  },
  );
}

DownloadId _id(String pageId) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: pageId,
      ),
      sourceRevision: 'r1',
      canonicalUri: Uri.parse('https://example.test/$pageId.webp'),
    );

Map<DownloadId, TransferDemand> _desired(
  DownloadId id, {
  required int priority,
  int flowTargetFrames = 0,
}) =>
    <DownloadId, TransferDemand>{
      id: TransferDemand(
        priority: priority,
        reason: 'test',
        flowTargetFrames: flowTargetFrames,
      ),
    };

final class _FailingOpenTransport implements Transport {
  _FailingOpenTransport(this.onOpen);

  final void Function() onOpen;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    onOpen();
    throw const Failure(
      code: ErrorCode.network,
      message: 'test transport open failure',
    );
  }
}

final class _GateBytesTransport implements Transport {
  _GateBytesTransport(this.bytes);

  final List<int> bytes;
  final Completer<void> opened = Completer<void>();
  final Completer<void> release = Completer<void>();
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    if (!opened.isCompleted) opened.complete();
    await release.future;
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
      validators: const Validators(etag: 'gate'),
      rangeSupported: false,
    );
  }
}

final class _CountingBytesTransport implements Transport {
  _CountingBytesTransport(this.bytes);

  final List<int> bytes;
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
      validators: const Validators(etag: 'counting'),
      rangeSupported: false,
    );
  }
}


final class _ExactUriRangeTransport implements Transport {
  _ExactUriRangeTransport({required this.expectedUri, required this.bytes});

  final Uri expectedUri;
  final List<int> bytes;
  final List<Uri> openedUris = <Uri>[];
  final List<ByteRange?> ranges = <ByteRange?>[];
  final List<Validators?> validatorsSeen = <Validators?>[];

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    openedUris.add(uri);
    ranges.add(range);
    validatorsSeen.add(validators);
    if (uri != expectedUri) {
      throw Failure(
        code: ErrorCode.source,
        message: 'unexpected provider URI: $uri',
      );
    }
    const current = Validators(etag: 'new-provider-v2');
    final canRange = range != null &&
        range.start <= bytes.length &&
        (validators == null || validators.isEmpty || validators.matches(current));
    final start = canRange ? range.start : 0;
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes.sublist(start)),
      statusCode: canRange ? 206 : 200,
      rangeStart: start,
      totalLength: bytes.length,
      validators: current,
      rangeSupported: true,
    );
  }
}

final class _PrefixThenBlockTransport implements ControlledTransport {
  _PrefixThenBlockTransport([List<int>? prefix])
      : prefix = prefix ?? List<int>.filled(20 * 1024, 7);

  final List<int> prefix;
  final Completer<void> opened = Completer<void>();

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
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('physical scheduler must pass TaskControl');
    }
    if (!opened.isCompleted) opened.complete();
    return ByteResponse(
      bytes: _body(taskControl),
      statusCode: 200,
      rangeStart: 0,
      totalLength: null,
      validators: const Validators(etag: 'partial'),
      rangeSupported: false,
    );
  }

  Stream<List<int>> _body(TaskControl control) async* {
    yield prefix;
    await control.whenCancelled;
  }
}


final class _RetainedGateControlledTransport implements ControlledTransport {
  _RetainedGateControlledTransport({
    required this.prefix,
    required this.suffix,
  });

  final List<int> prefix;
  final List<int> suffix;
  final Completer<void> prefixSent = Completer<void>();
  final Completer<void> release = Completer<void>();
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
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('physical scheduler must pass TaskControl');
    }
    return ByteResponse(
      bytes: _body(taskControl),
      statusCode: 200,
      rangeStart: 0,
      totalLength: prefix.length + suffix.length,
      validators: const Validators(etag: 'retained-task-transport'),
      rangeSupported: false,
    );
  }

  Stream<List<int>> _body(TaskControl control) async* {
    yield prefix;
    if (!prefixSent.isCompleted) prefixSent.complete();
    await Future.any<void>(<Future<void>>[
      release.future,
      control.whenCancelled,
    ]);
    if (control.cancelled) {
      if (!cancelled.isCompleted) cancelled.complete();
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'retained task transport cancelled',
      );
    }
    yield suffix;
  }
}


final class _FlowSuspendingTransport implements Transport {
  _FlowSuspendingTransport(this.bytes, {required this.chunkSize});

  final List<int> bytes;
  final int chunkSize;
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    final start = range?.start ?? 0;
    Stream<List<int>> body() async* {
      for (var offset = start; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
        yield bytes.sublist(offset, end);
      }
    }

    return ByteResponse(
      bytes: body(),
      statusCode: start == 0 ? HttpStatus.ok : HttpStatus.partialContent,
      rangeStart: start,
      totalLength: bytes.length,
      rangeSupported: true,
      flowControl: ByteResponseFlowControl.consumerPacing,
      validators: const Validators(etag: 'flow-suspension-v1'),
    );
  }
}

List<int> _ownerAnimatedWebp(List<int> payloadSizes) {
  final chunks = <int>[];
  for (final size in payloadSizes) {
    chunks
      ..addAll('ANMF'.codeUnits)
      ..addAll(_ownerU32(size))
      ..addAll(List<int>.generate(size, (index) => (index * 13) & 0xff));
    if (size.isOdd) chunks.add(0);
  }
  return <int>[
    ...'RIFF'.codeUnits,
    ..._ownerU32(4 + chunks.length),
    ...'WEBP'.codeUnits,
    ...chunks,
  ];
}

List<int> _ownerU32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];


final class _CancelThenSucceedTransport implements ControlledTransport {
  _CancelThenSucceedTransport({required this.bytes});

  final List<int> bytes;
  final Completer<void> firstOpened = Completer<void>();
  final Completer<void> firstCancelled = Completer<void>();
  int opens = 0;

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
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('physical scheduler must pass TaskControl');
    }
    opens++;
    if (opens == 1) {
      firstOpened.complete();
      await taskControl.whenCancelled;
      firstCancelled.complete();
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'first provider attempt cancelled',
      );
    }
    return ByteResponse(
      bytes: Stream<List<int>>.value(bytes),
      statusCode: 200,
      rangeStart: 0,
      totalLength: bytes.length,
      rangeSupported: true,
    );
  }
}


final class _AlwaysStallControlledTransport implements ControlledTransport {
  int opens = 0;

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
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('physical scheduler must pass TaskControl');
    }
    opens++;
    await taskControl.whenCancelled;
    throw const Failure(
      code: ErrorCode.cancelled,
      message: 'attempt-local open aborted by watchdog',
    );
  }
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
    if (!opened.isCompleted) opened.complete();
    final taskControl = control;
    if (taskControl == null) {
      throw StateError('physical scheduler must pass TaskControl');
    }
    await taskControl.whenCancelled;
    if (!cancelled.isCompleted) cancelled.complete();
    throw const Failure(
      code: ErrorCode.cancelled,
      message: 'provider transport cancelled',
    );
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('condition not met');
}
