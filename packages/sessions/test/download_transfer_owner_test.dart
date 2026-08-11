import 'dart:async';
import 'dart:io';

import 'package:domain/domain.dart';
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

    a.reconcile('reader-a', 1, _added(id, priority: 1000, role: PageRole.current));
    await transportA.opened.future;
    final session = registry.get(id);
    expect(session.activeRun, isTrue);

    b.reconcile('reader-b', 1, _added(id, priority: 700, role: PageRole.next));
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

  test('final consumer detach persists committed physical partial after writer exits',
      () async {
    final temp = await Directory.systemTemp.createTemp('transfer_owner_partial_');
    addTearDown(() async => temp.delete(recursive: true));
    final clock = _Clock();
    final registry = DownloadRegistry(
      layout: CacheLayout('${temp.path}/cache'),
      clock: clock,
    );
    var persistedBytes = 0;
    var persistCalls = 0;
    final owner = DownloadTransferOwner(
      registry: registry,
      clock: clock,
      net: NetLane(maxActive: 1),
      persistUnclaimed: (session) async {
        persistCalls++;
        persistedBytes = session.committedLength;
      },
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
    consumer.reconcile(
      'reader-partial',
      1,
      _added(id, priority: 1000, role: PageRole.current),
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
    expect(persistCalls, 1);
    expect(persistedBytes, session.committedLength);
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

    a.reconcile('reader-a', 1, _added(id, priority: 1000, role: PageRole.current));
    await transportA.opened.future;
    b.reconcile('reader-b', 1, _added(id, priority: 700, role: PageRole.next));
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

MapDiff<DownloadId, DownloadDemand> _added(
  DownloadId id, {
  required int priority,
  required PageRole role,
}) =>
    MapDiff<DownloadId, DownloadDemand>(
      added: <DownloadId, DownloadDemand>{
        id: DownloadDemand(
          role: role,
          priority: priority,
          reason: 'test',
          expirationRevision: 4,
        ),
      },
      changed: const <DownloadId, DownloadDemand>{},
      removed: const <DownloadId>{},
    );

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

final class _PrefixThenBlockTransport implements ControlledTransport {
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
    yield List<int>.filled(20 * 1024, 7);
    await control.whenCancelled;
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
