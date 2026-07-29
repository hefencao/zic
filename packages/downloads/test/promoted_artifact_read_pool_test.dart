import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:sessions/sessions.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('page consumer and session transport share one promoted read', () async {
    final uri = Uri.parse('https://example.invalid/cold-reader.webp');
    final id = _downloadId(uri);
    final store = _DeferredArtifactStore();
    final pool = PromotedArtifactReadPool(cache: store);
    addTearDown(pool.close);
    final fallback = _RecordingTransport();
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: store,
      readPool: pool,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
      sessionId: 'reader-cold-open',
      demandRevision: () => 3,
    );

    final direct = pool.join(id);
    final response = transport.open(uri);
    expect(store.reads, 1);

    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    store.complete(bytes);

    expect(await direct, same(bytes));
    expect(await _collect(await response), bytes);
    expect(store.reads, 1);
    expect(fallback.opens, 0);
    expect(pool.retainedReadCount, 1);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['consumer'], 'session-copy');
    expect(source.payload['readMicros'], isA<int>());
  });

  test('authoritative active run primes before workspace restore completes',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-read-active-run-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _downloadId(Uri.parse('memory://active-run-cache-read'));
    final bytes = Uint8List.fromList(<int>[4, 5, 6]);
    final store = _MutableArtifactStore(bytes);
    final pool = PromotedArtifactReadPool(cache: store);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: pool.observe,
    );
    addTearDown(() async {
      pool.close();
      await registry.dispose();
    });
    final session = registry.get(id);
    final joined = pool.join(id);

    expect(store.reads, 0);
    final run = session.beginRun();

    expect(await joined, same(bytes));
    expect(store.reads, 1);
    session.endRun(run);
  });

  test('observing an already active run primes immediately', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-read-late-observer-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _downloadId(Uri.parse('memory://late-observer-cache-read'));
    final bytes = Uint8List.fromList(<int>[7, 7, 1]);
    final store = _MutableArtifactStore(bytes);
    final pool = PromotedArtifactReadPool(cache: store);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
    );
    addTearDown(() async {
      pool.close();
      await registry.dispose();
    });
    final session = registry.get(id);
    final run = session.beginRun();

    pool.observe(session);

    expect(await pool.join(id), same(bytes));
    expect(store.reads, 1);
    session.endRun(run);
  });

  test('authoritative queued session primes a waiting page join', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-read-prime-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final id = _downloadId(Uri.parse('memory://queued-cache-read'));
    final bytes = Uint8List.fromList(<int>[9, 8, 7]);
    final store = _MutableArtifactStore(bytes);
    final pool = PromotedArtifactReadPool(cache: store);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: pool.observe,
    );
    addTearDown(() async {
      pool.close();
      await registry.dispose();
    });
    final session = registry.get(id);
    final joined = pool.join(id);

    expect(store.reads, 0);
    session.queue();

    expect(await joined, same(bytes));
    expect(store.reads, 1);
  });

  test('joining does not initiate a cache read', () async {
    final id = _downloadId(Uri.parse('memory://join-without-demand'));
    final store = _DeferredArtifactStore();
    final pool = PromotedArtifactReadPool(cache: store);
    addTearDown(pool.close);

    final joined = pool.join(id);
    await Future<void>.delayed(Duration.zero);

    expect(store.reads, 0);
    pool.release(id);
    expect(await joined, isNull);
  });

  test('terminal replacement session releases the shared encoded read',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-promoted-read-pool-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('memory://promoted-reader-page');
    final id = _downloadId(uri);
    final store = _MutableArtifactStore(
      Uint8List.fromList(<int>[6, 7, 8]),
    );
    final pool = PromotedArtifactReadPool(cache: store);
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: SystemClock(),
      onSessionCreated: pool.observe,
    );
    addTearDown(() async {
      pool.close();
      await registry.dispose();
    });
    final session = registry.get(id);

    expect(await pool.read(id), store.bytes);
    expect(pool.retainedReadCount, 1);
    await DownloadJob(
      transport: LoaderTransport(<Uri, LoaderTransportSource>{
        uri: LoaderTransportSource(
          revision: 'fixture-r1',
          loadBytes: () async => store.bytes,
        ),
      }),
      session: session,
    ).run();

    expect(session.state, DownloadState.promoted);
    expect(pool.retainedReadCount, 0);
    expect(await pool.join(id), isNull);
    expect(store.reads, 1);
    await pool.read(id);
    expect(store.reads, 2);
  });

  test('failed cache reads are not retained', () async {
    final id = _downloadId(Uri.parse('memory://failed-cache-read'));
    final store = _FailingArtifactStore();
    final pool = PromotedArtifactReadPool(cache: store);
    addTearDown(pool.close);

    await expectLater(pool.read(id), throwsStateError);
    expect(pool.retainedReadCount, 0);
    await expectLater(pool.read(id), throwsStateError);
    expect(store.reads, 2);
  });
}

DownloadId _downloadId(Uri uri) => DownloadId(
      content: const ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: 'page',
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );

Future<Uint8List> _collect(ByteResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.bytes) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

final class _DeferredArtifactStore implements ArtifactCacheStore {
  final Completer<Uint8List?> _read = Completer<Uint8List?>();
  int reads = 0;

  void complete(Uint8List bytes) => _read.complete(bytes);

  @override
  Future<Uint8List?> readArtifact(DownloadId id) {
    reads++;
    return _read.future;
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}

final class _MutableArtifactStore implements ArtifactCacheStore {
  _MutableArtifactStore(this.bytes);

  final Uint8List bytes;
  int reads = 0;

  @override
  Future<Uint8List?> readArtifact(DownloadId id) async {
    reads++;
    return bytes;
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}

final class _FailingArtifactStore implements ArtifactCacheStore {
  int reads = 0;

  @override
  Future<Uint8List?> readArtifact(DownloadId id) {
    reads++;
    return Future<Uint8List?>.error(StateError('cache read failed'));
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}

final class _RecordingTransport implements Transport {
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    return ByteResponse(
      bytes: Stream<List<int>>.value(const <int>[9]),
      statusCode: 200,
      rangeStart: 0,
      totalLength: 1,
    );
  }
}
