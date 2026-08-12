import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
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

  test('queued priority revisions keep one physical transfer task identity', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_queue_');
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
      _desired(id, priority: 700),
    );
    final taskKey = owner.taskKeyFor(id);
    expect(taskKey, isNotNull);
    expect(net.queued, 1);

    consumer.replaceDemands(
      'reader-queued',
      2,
      _desired(id, priority: 720),
    );
    consumer.replaceDemands(
      'reader-queued',
      3,
      _desired(id, priority: 780),
    );
    consumer.replaceDemands(
      'reader-queued',
      4,
      _desired(id, priority: 1000),
    );

    expect(owner.taskKeyFor(id), taskKey);
    expect(net.queued, 1);
    expect(net.priorityOf(taskKey!), 1000);

    blockerRelease.complete();
    await consumer.idle();
    expect(transport.opens, 1);
    expect(registry.get(id).state, DownloadState.promoted);
  });

  test('transfer checksum constraints aggregate across consumers atomically',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_checksum_');
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
    final transport = _CountingBytesTransport('RIFF....WEBPchecksum'.codeUnits);
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
      _desired(id, priority: 1000),
    );
    chapter.replaceDemands(
      'chapter-checksum',
      1,
      <DownloadId, TransferDemand>{
        id: const TransferDemand(
          priority: 120,
          reason: 'chapter-command',
          expectedChecksum: 'checksum-a',
        ),
      },
    );
    expect(owner.claimCount(id), 2);
    expect(registry.sessions, hasLength(1));

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
        },
      ),
      throwsStateError,
    );
    expect(conflicting.demands, isEmpty);
    expect(owner.claimCount(id), 2);
    expect(registry.sessions, hasLength(1));
  });

  test('required completion claim can finish a costly full-body catchup', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_required_');
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
      },
    );
    await required.idle();
    expect(session.state, DownloadState.promoted);
    expect(session.committedLength, fullBytes.length);
  });

  test('final consumer detach retains hot physical partial for later reuse',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_partial_');
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
  });

  test('equivalent failed partial resumes through provider exact request URI', () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_alias_source_');
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
  });

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
      canonicalUri: Uri.parse('https://example.test/provider-retain-new.webp'),
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
      _desired(exact, priority: 1000),
    );
    await Future<void>.delayed(Duration.zero);

    expect(registry.resolvePhysicalId(exact), physical);
    expect(identical(registry.find(exact), session), isTrue);
    expect(newTransport.opened.isCompleted, isFalse);
    expect(owner.activeProviderScope(physical), 'reader-old-provider');
    expect(owner.activeProviderExactId(physical), physical);
    expect(session.committedLength, greaterThan(0));
    expect(session.effectivePriority, 1000);

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
  });


  test(
      'task-retained transport survives provider consumer disposal on shared partial',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_retained_transport_');
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
      canonicalUri: Uri.parse('https://example.test/retained-transport-exact.webp'),
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
      _desired(exact, priority: 1000),
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
  });

  test('disposing active provider preserves remaining consumer and reopens once',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_detach_');
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
    final transportB = _CountingBytesTransport('RIFF....WEBPresumed'.codeUnits);
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
  });
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
}) =>
    <DownloadId, TransferDemand>{
      id: TransferDemand(
        priority: priority,
        reason: 'test',
      ),
    };

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
    final start = canRange ? range!.start : 0;
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
