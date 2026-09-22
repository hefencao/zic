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
  test('Reader cache lookup hang keeps the generic open watchdog',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-cache-open-watchdog-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('https://example.invalid/cache-lookup-hang.bin');
    final id = _downloadId(uri, 'cache-lookup-hang');
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: const SystemClock(),
    );
    addTearDown(registry.dispose);
    final fallback = _SelfBoundedRecordingTransport(
      Uint8List.fromList(<int>[1, 2, 3]),
      delay: const Duration(milliseconds: 180),
    );
    final backend = _BlockingLookupArtifactStore();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: backend),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    await expectLater(
      DownloadJob(
        transport: transport,
        session: registry.get(id),
        readStallTimeout: const Duration(milliseconds: 80),
      ).run(cancel: CancelToken()),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.network)
            .having(
              (error) => error.message,
              'message',
              contains('transport open stalled'),
            ),
      ),
    );
    expect(fallback.opens, 0);

    // The timed-out local lookup may physically finish later, but it no longer
    // owns the attempt and must not cross into an origin open after the NetLane
    // task has already returned its slot.
    backend.pending.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fallback.opens, 0);
  });

  test('Reader cache miss keeps the generic watchdog for an unbounded origin',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-unbounded-origin-watchdog-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('https://example.invalid/cache-miss-hung-origin.bin');
    final id = _downloadId(uri, 'cache-miss-hung-origin');
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: const SystemClock(),
    );
    addTearDown(registry.dispose);
    final fallback = _BlockingControlledTransport();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    await expectLater(
      DownloadJob(
        transport: transport,
        session: registry.get(id),
        readStallTimeout: const Duration(milliseconds: 80),
      ).run(cancel: CancelToken()),
      throwsA(
        isA<Failure>()
            .having((error) => error.code, 'code', ErrorCode.network)
            .having(
              (error) => error.message,
              'message',
              contains('transport open stalled'),
            ),
      ),
    ).timeout(const Duration(seconds: 1));
    expect(fallback.opens, 1);
  });

  test('Reader cache miss hands open timeout to a self-bounded origin',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'zic-reader-origin-open-watchdog-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final uri = Uri.parse('https://example.invalid/cache-miss-slow-origin.bin');
    final id = _downloadId(uri, 'cache-miss-slow-origin');
    final registry = DownloadRegistry(
      layout: CacheLayout(directory.path),
      clock: const SystemClock(),
    );
    addTearDown(registry.dispose);
    final fallback = _SelfBoundedRecordingTransport(
      Uint8List.fromList(<int>[1, 2, 3]),
      delay: const Duration(milliseconds: 180),
    );
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final result = await DownloadJob(
      transport: transport,
      session: registry.get(id),
      readStallTimeout: const Duration(milliseconds: 80),
    ).run(cancel: CancelToken());

    expect(result.state, DownloadState.promoted);
    expect(result.committedLength, 3);
    expect(fallback.opens, 1);
    expect(fallback.lastControl, isNotNull);
  });

  test('serves an exact promoted artifact without opening the source',
      () async {
    final uri = Uri.parse('https://example.invalid/page.bin');
    final id = _downloadId(uri, 'page-1');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3, 4]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
      sessionId: 'reader-cache-test',
      demandRevision: () => 7,
    );

    final response = await transport.open(uri);

    expect(await _collect(response), <int>[1, 2, 3, 4]);
    expect(response.statusCode, 200);
    expect(response.totalLength, 4);
    expect(
      response.disposition,
      ByteResponseDisposition.durableImmutable,
    );
    expect(
      response.bodyAuthority,
      ByteResponseBodyAuthority.artifactCache,
    );
    expect(fallback.opens, 0);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.identityHash, id.key);
    expect(source.revision, 7);
    expect(source.payload['source'], 'artifact-cache-stream');
    expect(source.payload['sourceClass'], 'persistent-artifact');
    expect(source.payload['bytes'], 4);
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.identityHash, id.key);
    expect(read.payload['source'], 'artifact-cache-stream');
    expect(read.payload['sourceClass'], 'persistent-artifact');
    expect(read.payload['bytes'], 4);
    expect(read.payload['chunks'], 1);
    expect(read.payload['minChunkBytes'], 4);
    expect(read.payload['maxChunkBytes'], 4);
    expect(read.payload['maxChunkGapMicros'], isA<int>());
    expect(read.payload['completed'], isTrue);
  });

  test('retained local-source bytes remain memory-only provenance', () async {
    final uri = Uri.parse('file:///fixture/page.bin');
    final id = _downloadId(uri, 'local-page');
    final bytes = Uint8List.fromList(<int>[7, 1, 8, 2]);
    final cache = ArtifactCacheManager(
      backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
    );
    final transport = ArtifactCacheTransport(
      cache: cache,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(bytes),
    );

    final response = await transport.open(uri);
    expect(await _collect(response), bytes);

    final lookup = await cache.lookup(id);
    expect(lookup?.tier, ArtifactCacheTier.memory);
    expect(lookup?.durable, isFalse);
  });

  test('cancelling retained local-origin bytes discards the source response',
      () async {
    final uri = Uri.parse('file:///fixture/cancel-retained-page.bin');
    final id = _downloadId(uri, 'cancel-retained-page');
    final bodyStarted = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: () {
        if (!bodyStarted.isCompleted) bodyStarted.complete();
      },
    );
    addTearDown(() async {
      if (!body.isClosed) await body.close();
    });
    final fallback = _DiscardTrackingTransport(body);
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(uri);
    final subscription = response.bytes.listen((_) {});
    await bodyStarted.future;
    await subscription.cancel();

    await fallback.discarded.future.timeout(const Duration(seconds: 1));
    expect(fallback.opens, 1);
  });

  test('cancelling a traced origin stream discards the source response',
      () async {
    final uri = Uri.parse('https://example.invalid/cancel-traced-page.bin');
    final id = _downloadId(uri, 'cancel-traced-page');
    final bodyStarted = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: () {
        if (!bodyStarted.isCompleted) bodyStarted.complete();
      },
    );
    addTearDown(() async {
      if (!body.isClosed) await body.close();
    });
    final fallback = _DiscardTrackingTransport(body);
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);
    final subscription = response.bytes.listen((_) {});
    await bodyStarted.future;
    await subscription.cancel();

    await fallback.discarded.future.timeout(const Duration(seconds: 1));
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['completed'], isFalse);
  });

  test('streams a large promoted artifact in cooperative chunks', () async {
    final uri = Uri.parse('https://example.invalid/large-page.bin');
    final id = _downloadId(uri, 'page-large');
    final bytes = Uint8List(defaultTransportChunkBytes * 2 + 32 * 1024);
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{id: bytes});
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
    );

    final response = await transport.open(uri);
    final chunks = await response.bytes.map((chunk) => chunk.length).toList();

    expect(
      chunks,
      <int>[
        defaultTransportChunkBytes,
        defaultTransportChunkBytes,
        32 * 1024,
      ],
    );
  });

  test('stream-capable cache bypasses full-page Uint8List reads', () async {
    final uri = Uri.parse('https://example.invalid/streamed-page.bin');
    final id = _downloadId(uri, 'page-streamed');
    final cache = _StreamingArtifactStore(
      id,
      Uint8List.fromList(
        List<int>.generate(1500000, (index) => index & 0xff),
      ),
    );
    final fallback = _RecordingTransport(Uint8List(0));
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);
    final chunks = await response.bytes.map((chunk) => chunk.length).toList();

    expect(
      response.disposition,
      ByteResponseDisposition.durableImmutable,
    );
    expect(cache.fullReads, 0);
    expect(cache.streamOpens, 1);
    expect(fallback.opens, 0);
    expect(chunks, <int>[1024 * 1024, 451424]);
    expect(
      trace.events
          .singleWhere((event) => event.kind == TraceEventKind.artifactSource)
          .payload['source'],
      'artifact-cache-stream',
    );
  });

  test('background artifact stream reacquires the scheduler per chunk',
      () async {
    final uri = Uri.parse('https://example.invalid/scheduled-page.bin');
    final id = _downloadId(uri, 'page-scheduled');
    final cache = _StreamingArtifactStore(
      id,
      Uint8List(promotedArtifactReadChunkBytes + 256),
    );
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: ArtifactCacheReadScheduler(maxActive: 3),
      demandPriority: (_) => 400,
      clock: _Clock(),
      traceSink: trace,
    );

    expect((await _collect(await transport.open(uri))).length,
        promotedArtifactReadChunkBytes + 256);
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['chunks'], 2);
    expect(read.payload['readSchedulerAcquires'], 2);
    expect(read.payload['readSchedulerForegroundAcquires'], 0);
    expect(read.payload['readSchedulerMaxWaitMicros'], isA<int>());
  });

  test('cancelled cache stream does not remain queued for a local-read lease',
      () async {
    final uri = Uri.parse('https://example.invalid/cancelled-local-read.bin');
    final id = _downloadId(uri, 'page-cancelled-local-read');
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final blockerA = await scheduler.acquire(priority: () => 1000);
    final blockerB = await scheduler.acquire(priority: () => 1000);
    final control = _MutableTaskControl(priority: 400);
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _StreamingArtifactStore(
          id,
          Uint8List(promotedArtifactReadChunkBytes),
        ),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: scheduler,
      demandPriority: (_) => 400,
    );

    final response = await transport.openControlled(uri, control: control);
    final iterator = StreamIterator<List<int>>(response.bytes);
    final read = iterator.moveNext();
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.pendingCount, 1);

    control.cancel();
    await expectLater(
      read,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(scheduler.pendingCount, 0);

    blockerA.release();
    blockerB.release();
    await iterator.cancel();
  });

  test('cancellation aborts an already-admitted cache body read', () async {
    final uri = Uri.parse('https://example.invalid/cancelled-admitted-read.bin');
    final id = _downloadId(uri, 'page-cancelled-admitted-read');
    final control = _MutableTaskControl(priority: 400);
    final bodyCancelled = Completer<void>();
    final body = StreamController<List<int>>(
      onCancel: () {
        if (!bodyCancelled.isCompleted) bodyCancelled.complete();
      },
    );
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _CancellableStreamingArtifactStore(
          id,
          body.stream,
        ),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: scheduler,
      demandPriority: (_) => 400,
    );

    final response = await transport.openControlled(uri, control: control);
    final iterator = StreamIterator<List<int>>(response.bytes);
    final read = iterator.moveNext();
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.activeCount, 1);

    control.cancel();
    await expectLater(
      read,
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    await bodyCancelled.future.timeout(const Duration(seconds: 1));
    expect(scheduler.activeCount, 0);
    await iterator.cancel();
    await body.close();
  });

  test('foreground artifact stream keeps its scheduler lease across chunks',
      () async {
    final uri = Uri.parse('https://example.invalid/current-page.bin');
    final id = _downloadId(uri, 'page-current');
    final cache = _StreamingArtifactStore(
      id,
      Uint8List(promotedArtifactReadChunkBytes + 256),
    );
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: ArtifactCacheReadScheduler(maxActive: 3),
      demandPriority: (_) => 1000,
      clock: _Clock(),
      traceSink: trace,
    );

    expect((await _collect(await transport.open(uri))).length,
        promotedArtifactReadChunkBytes + 256);
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['chunks'], 2);
    expect(read.payload['readSchedulerAcquires'], 1);
    expect(read.payload['readSchedulerForegroundAcquires'], 1);
  });

  test('background promotion reclassifies the next chunk without reopening',
      () async {
    final uri = Uri.parse('https://example.invalid/promoted-page.bin');
    final id = _downloadId(uri, 'page-promoted');
    final cache = _StreamingArtifactStore(
      id,
      Uint8List(promotedArtifactReadChunkBytes * 2 + 256),
    );
    final trace = MemoryTraceSink();
    var priority = 400;
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: ArtifactCacheReadScheduler(maxActive: 3),
      demandPriority: (_) => priority,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, promotedArtifactReadChunkBytes);
    priority = 1000;
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, promotedArtifactReadChunkBytes);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, 256);
    expect(await iterator.moveNext(), isFalse);

    expect(cache.streamOpens, 1);
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['readSchedulerAcquires'], 2);
    expect(read.payload['readSchedulerForegroundAcquires'], 1);
    await iterator.cancel();
  });

  test('foreground persistent stream stays lazy and leaves hot byte cache cold',
      () async {
    final uri = Uri.parse('https://example.invalid/cold-stream-page.bin');
    final id = _downloadId(uri, 'page-cold-stream');
    final bytes = Uint8List(promotedArtifactReadChunkBytes + 17);
    final cache = _StreamingArtifactStore(id, bytes, exposeReadAll: true);
    final manager = ArtifactCacheManager(backend: cache);
    final trace = MemoryTraceSink();
    final scheduler = ArtifactCacheReadScheduler(maxActive: 3);
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: scheduler,
      demandPriority: (_) => 1000,
      clock: _Clock(),
      traceSink: trace,
    );

    final firstResponse = await transport.open(uri);
    // Opening a cold foreground artifact must not start or materialize its body.
    expect(cache.readAllCalls, 0);
    expect(scheduler.activeForegroundCount, 0);
    final first = await firstResponse.bytes.map((chunk) => chunk.length).toList();
    final secondResponse = await transport.open(uri);
    final second =
        await secondResponse.bytes.map((chunk) => chunk.length).toList();

    expect(first, <int>[promotedArtifactReadChunkBytes, 17]);
    expect(second, <int>[promotedArtifactReadChunkBytes, 17]);
    expect(cache.readAllCalls, 0);
    expect(cache.streamOpens, 2);
    expect(manager.memoryEntryCount, 0);
    final sources = trace.events
        .where((event) => event.kind == TraceEventKind.artifactSource)
        .map((event) => event.payload['source'])
        .toList();
    expect(sources, <Object?>['artifact-cache-stream', 'artifact-cache-stream']);
    final reads = trace.events
        .where((event) => event.kind == TraceEventKind.sourceRead)
        .toList();
    expect(reads, hasLength(2));
    expect(reads[0].payload['cacheTier'], ArtifactCacheTier.persistent.name);
    expect(reads[0].payload['memoryCacheHit'], isFalse);
    expect(reads[0].payload['readSchedulerAcquires'], 1);
    expect(reads[0].payload['readSchedulerForegroundAcquires'], 1);
    expect(
      reads[0].payload['artifactIntegrityBasis'],
      ArtifactReadIntegrityBasis.sealedMetadataLength.name,
    );
    expect(reads[0].payload['artifactWholeChecksumVerifiedThisRead'], isFalse);
  });

  test('foreground memory artifact keeps the direct hot-byte fast path',
      () async {
    final uri = Uri.parse('https://example.invalid/hot-memory-page.bin');
    final id = _downloadId(uri, 'page-hot-memory');
    final bytes = Uint8List(promotedArtifactReadChunkBytes + 17);
    final backend = _MemoryArtifactStore(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    await manager.storePromotedArtifact(id: id, bytes: bytes);
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: ArtifactCacheReadScheduler(maxActive: 3),
      demandPriority: (_) => 1000,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);
    final chunks = await response.bytes.map((chunk) => chunk.length).toList();

    expect(chunks, <int>[bytes.lengthInBytes]);
    expect(manager.memoryEntryCount, 1);
    expect(backend.reads, 0);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['source'], 'artifact-byte-cache');
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['artifactReadMode'], 'memory-hit');
    expect(read.payload['deliveryMode'], 'memory-direct');
  });

  test('foreground persistent stream acquires its scheduler lease lazily',
      () async {
    final uri = Uri.parse('https://example.invalid/lease-body.bin');
    final id = _downloadId(uri, 'page-lease-body');
    final bytes = Uint8List(promotedArtifactReadChunkBytes + 17);
    final cache = _StreamingArtifactStore(id, bytes, exposeReadAll: true);
    final scheduler = ArtifactCacheReadScheduler(maxActive: 2);
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      readScheduler: scheduler,
      demandPriority: (_) => 1000,
    );

    final response = await transport.open(uri);
    expect(cache.readAllCalls, 0);
    expect(scheduler.activeForegroundCount, 0);
    final iterator = StreamIterator<List<int>>(response.bytes);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, promotedArtifactReadChunkBytes);
    expect(scheduler.activeForegroundCount, 1);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.length, 17);
    expect(scheduler.activeForegroundCount, 1);
    expect(await iterator.moveNext(), isFalse);
    expect(scheduler.activeForegroundCount, 0);
  });

  test('foreground persistent stream ignores a failing read-all capability',
      () async {
    final uri = Uri.parse('https://example.invalid/read-all-failure.bin');
    final id = _downloadId(uri, 'page-read-all-failure');
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final cache = _StreamingArtifactStore(
      id,
      bytes,
      exposeReadAll: true,
      failReadAll: true,
    );
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      readScheduler: ArtifactCacheReadScheduler(),
      demandPriority: (_) => 1000,
      clock: _Clock(),
      traceSink: trace,
    );

    expect(await _collect(await transport.open(uri)), <int>[1, 2, 3, 4]);
    expect(fallback.opens, 0);
    expect(cache.readAllCalls, 0);
    expect(
      trace.events.where((event) => event.kind == TraceEventKind.taskFailed),
      isEmpty,
    );
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['source'], 'artifact-cache-stream');
  });

  test('serves resumable ranges only for matching cache validators',
      () async {
    final uri = Uri.parse('https://example.invalid/range.bin');
    final id = _downloadId(uri, 'page-range');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );
    final full = await transport.open(uri);

    final response = await transport.open(
      uri,
      range: const ByteRange(start: 2),
      validators: full.validators,
    );

    expect(await _collect(response), <int>[3, 4, 5]);
    expect(response.statusCode, 206);
    expect(response.rangeStart, 2);
    expect(response.totalLength, 5);
    expect(fallback.opens, 0);
  });

  test('falls back when the artifact is missing or cannot resume', () async {
    final uri = Uri.parse('https://example.invalid/miss.bin');
    final id = _downloadId(uri, 'page-miss');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      id: Uint8List.fromList(<int>[1, 2, 3]),
    });
    final fallback = _RecordingTransport(
      Uint8List.fromList(<int>[8, 9]),
      diagnostics: const <String, Object?>{
        'sourceRequestPlanMicros': 1200,
        'sourceRequestPlanCacheHit': false,
        'sourceHostOpenMicros': 3400,
        'sourceOpenPath': 'direct',
      },
    );
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
      demandRevision: () => 9,
    );

    final response = await transport.open(
      uri,
      range: const ByteRange(start: 1),
      validators: const Validators(etag: '"different"'),
    );

    expect(await _collect(response), <int>[8, 9]);
    expect(fallback.opens, 1);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.revision, 9);
    expect(source.payload['source'], 'origin');
    expect(source.payload['sourceRequestPlanMicros'], 1200);
    expect(source.payload['sourceRequestPlanCacheHit'], isFalse);
    expect(source.payload['sourceHostOpenMicros'], 3400);
    expect(source.payload['sourceOpenPath'], 'direct');
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['source'], 'origin');
    expect(read.payload['sourceClass'], 'remote');
    expect(read.payload['sourceRequestPlanMicros'], 1200);
    expect(read.payload['sourceRequestPlanCacheHit'], isFalse);
    expect(read.payload['sourceHostOpenMicros'], 3400);
    expect(read.payload['sourceOpenPath'], 'direct');
    expect(read.payload['bytes'], 2);
    expect(read.payload['completed'], isTrue);
  });

  test('cache read failure falls back to the source transport', () async {
    final uri = Uri.parse('https://example.invalid/cache-error.bin');
    final id = _downloadId(uri, 'page-cache-error');
    final cache = _ThrowingArtifactStore();
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[7, 8]));
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);

    expect(await _collect(response), <int>[7, 8]);
    expect(fallback.opens, 1);
    expect(
      trace.events.any(
        (event) =>
            event.kind == TraceEventKind.taskFailed &&
            event.payload['lane'] == 'artifact-cache-read' &&
            event.payload['fallback'] == 'origin',
      ),
      isTrue,
    );
  });

  test('typed cache preflight failure falls back before local bytes are exposed', () async {
    final uri = Uri.parse('https://example.invalid/typed-preflight.bin');
    final id = _downloadId(uri, 'page-typed-preflight');
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[7, 8]));
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _TypedPreflightFailureArtifactStore(id),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    expect(await _collect(await transport.open(uri)), <int>[7, 8]);
    expect(fallback.opens, 1);
  });

  test('mid-stream typed cache failure never splices origin into committed prefix',
      () async {
    final uri = Uri.parse('https://example.invalid/typed-midstream.bin');
    final id = _downloadId(uri, 'page-typed-midstream');
    final cache = _TypedBodyFailureArtifactStore(
      id,
      kind: ArtifactReadFailureKind.shortRead,
    );
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9, 10, 11]));
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final first = await transport.open(uri);
    final delivered = <int>[];
    Object? failure;
    try {
      await for (final chunk in first.bytes) {
        delivered.addAll(chunk);
      }
    } catch (error) {
      failure = error;
    }

    expect(delivered, <int>[1, 2, 3]);
    expect(failure, isA<ArtifactReadFailure>());
    expect(fallback.opens, 0);
    await Future<void>.delayed(Duration.zero);
    expect(cache.invalidations, 1);

    expect(await _collect(await transport.open(uri)), <int>[9, 10, 11]);
    expect(fallback.opens, 1);
    expect(cache.streamOpens, 1);
  });

  test('access denied cache failure is bypassed without invalidating durable binding',
      () async {
    final uri = Uri.parse('https://example.invalid/access-denied.bin');
    final id = _downloadId(uri, 'page-access-denied');
    final cache = _TypedBodyFailureArtifactStore(
      id,
      kind: ArtifactReadFailureKind.accessDenied,
      emitPrefix: false,
    );
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[4, 5]));
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    await expectLater(
      _collect(await transport.open(uri)),
      throwsA(
        isA<ArtifactReadFailure>().having(
          (error) => error.kind,
          'kind',
          ArtifactReadFailureKind.accessDenied,
        ),
      ),
    );
    expect(cache.invalidations, 0);
    expect(fallback.opens, 0);

    expect(await _collect(await transport.open(uri)), <int>[4, 5]);
    expect(cache.invalidations, 0);
    expect(fallback.opens, 1);
  });

  test('completed immutable local origin is hot across Reader sessions without durable provenance',
      () async {
    final uri = Uri.parse('content://reader/page-restore.webp');
    final id = _downloadId(uri, 'page-local-hot');
    final backend = _MemoryArtifactStore(<DownloadId, Uint8List>{});
    final manager = ArtifactCacheManager(backend: backend);
    final fallback = _RecordingTransport(
      Uint8List.fromList(List<int>.generate(4096, (index) => index & 0xff)),
    );
    final first = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    expect((await _collect(await first.open(uri))).length, 4096);
    expect(fallback.opens, 1);
    expect(manager.lookupMemory(id), isNotNull);

    final trace = MemoryTraceSink();
    final second = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      readScheduler: ArtifactCacheReadScheduler(),
      demandPriority: (_) => 1000,
      clock: _Clock(),
      traceSink: trace,
    );
    final restored = await second.open(uri);
    expect(restored.disposition, ByteResponseDisposition.durableImmutable);
    expect(restored.bodyAuthority, ByteResponseBodyAuthority.source);
    expect(restored.immutableRangeReplay, isNotNull);
    expect((await manager.lookup(id))!.durable, isFalse);
    expect(
      await restored.bytes.map((chunk) => chunk.length).toList(),
      <int>[4096],
    );
    expect(fallback.opens, 1);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['source'], 'artifact-byte-cache');
    expect(source.payload['deliveryMode'], 'memory-direct');
    expect(source.payload['artifactDurable'], isFalse);
  });

  test('cache miss preserves scheduler control into controlled origin fallback',
      () async {
    final uri = Uri.parse('venera-resource:current-page');
    final id = _downloadId(uri, 'page-controlled-origin');
    final fallback = _ControlledRecordingTransport(
      Uint8List.fromList(<int>[4, 5, 6]),
    );
    final control = _MutableTaskControl(priority: 1000);
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.openControlled(uri, control: control);

    expect(await _collect(response), <int>[4, 5, 6]);
    expect(fallback.controlledOpens, 1);
    expect(fallback.uncontrolledOpens, 0);
    expect(identical(fallback.lastControl, control), isTrue);
    expect(fallback.lastControl?.priority, 1000);
  });

  test('cancelled controlled cache miss never opens origin fallback', () async {
    final uri = Uri.parse('venera-resource:cancelled-page');
    final id = _downloadId(uri, 'page-cancelled-origin');
    final fallback = _ControlledRecordingTransport(Uint8List.fromList(<int>[7]));
    final control = _MutableTaskControl(priority: 1000)..cancel();
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(
        backend: _MemoryArtifactStore(<DownloadId, Uint8List>{}),
      ),
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    await expectLater(
      transport.openControlled(uri, control: control),
      throwsA(
        isA<Failure>().having(
          (failure) => failure.code,
          'code',
          ErrorCode.cancelled,
        ),
      ),
    );
    expect(fallback.controlledOpens, 0);
    expect(fallback.uncontrolledOpens, 0);
  });

  test('ambiguous URI identities bypass the artifact cache', () async {
    final uri = Uri.parse('https://example.invalid/shared.bin');
    final first = _downloadId(uri, 'page-a');
    final second = _downloadId(uri, 'page-b');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      first: Uint8List.fromList(<int>[1]),
      second: Uint8List.fromList(<int>[2]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[7]));
    final transport = ArtifactCacheTransport(
      cache: ArtifactCacheManager(backend: cache),
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(uri, first),
        MapEntry(uri, second),
      ],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(uri);

    expect(await _collect(response), <int>[7]);
    expect(cache.reads, 0);
    expect(fallback.opens, 1);
  });

  test('strict carrier policy reopens source instead of trusting old URI',
      () async {
    final currentUri = Uri.parse('venera-resource:current-carrier');
    final historicalUri = Uri.parse('venera-resource:historical-carrier');
    final current = _downloadId(currentUri, 'page-carrier-policy');
    final historical = _downloadId(historicalUri, 'page-carrier-policy');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      historical: Uint8List.fromList(<int>[1, 2, 3, 4]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[8, 9]));
    final manager = ArtifactCacheManager(backend: cache);
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[8, 9]);
    expect(fallback.opens, 1);
    expect(manager.hasPendingHistoricalCarrierRevalidation(current), isFalse);
  });

  test('trust-cache carrier policy serves old URI without source or alias',
      () async {
    final currentUri = Uri.parse('venera-resource:current-trusted-carrier');
    final historicalUri = Uri.parse('venera-resource:trusted-cache-carrier');
    final current = _downloadId(currentUri, 'page-trusted-carrier');
    final historical = _downloadId(historicalUri, 'page-trusted-carrier');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      historical: Uint8List.fromList(<int>[4, 3, 2, 1]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[8, 9]));
    final trace = MemoryTraceSink();
    final manager = ArtifactCacheManager(
      backend: cache,
      carrierMismatchPolicy: CachedCarrierMismatchPolicy.trustCached,
    );
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[4, 3, 2, 1]);
    expect(response.bodyAuthority, ByteResponseBodyAuthority.artifactCache);
    final replay = response.immutableRangeReplay;
    expect(replay, isNotNull);
    expect(
      await _collectStream(await replay!(1, 3)),
      <int>[3, 2],
      reason: 'resident replay must reopen the exact selected historical body',
    );
    expect(fallback.opens, 0);
    expect(cache.values.containsKey(current), isFalse);
    expect(manager.directEquivalents(current), isEmpty);
    expect(manager.hasPendingHistoricalCarrierRevalidation(current), isFalse);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['source'], 'historical-artifact-cache-stream');
    expect(source.payload['historicalCarrierReuse'], isTrue);
    expect(source.payload['historicalCarrierPolicy'], 'trustCached');
  });

  test('conflicting complete historical carriers fail closed by default',
      () async {
    final currentUri = Uri.parse('venera-resource:current-conflict');
    final historicalUriA = Uri.parse('venera-resource:historical-conflict-a');
    final historicalUriB = Uri.parse('venera-resource:historical-conflict-b');
    final current = _downloadId(currentUri, 'page-conflicting-carrier');
    final historicalA = _downloadId(
      historicalUriA,
      'page-conflicting-carrier',
    );
    final historicalB = _downloadId(
      historicalUriB,
      'page-conflicting-carrier',
    );
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      historicalA: Uint8List.fromList(<int>[1, 2, 3]),
      historicalB: Uint8List.fromList(<int>[4, 5, 6, 7]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final manager = ArtifactCacheManager(
      backend: cache,
      carrierMismatchPolicy: CachedCarrierMismatchPolicy.trustCached,
    );
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[9]);
    expect(fallback.opens, 1);
    expect(cache.values.containsKey(current), isFalse);
  });

  test('source-scoped conflict trust accepts complete conflicting carrier',
      () async {
    final currentUri = Uri.parse('venera-resource:current-conflict-trusted');
    final historicalUriA =
        Uri.parse('venera-resource:historical-conflict-trusted-a');
    final historicalUriB =
        Uri.parse('venera-resource:historical-conflict-trusted-b');
    final current = _downloadId(currentUri, 'page-conflicting-trusted');
    final historicalA = _downloadId(
      historicalUriA,
      'page-conflicting-trusted',
    );
    final historicalB = _downloadId(
      historicalUriB,
      'page-conflicting-trusted',
    );
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      historicalA: Uint8List.fromList(<int>[1, 2, 3]),
      historicalB: Uint8List.fromList(<int>[4, 5, 6, 7]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final trace = MemoryTraceSink();
    final manager = ArtifactCacheManager(
      backend: cache,
      carrierMismatchPolicy: CachedCarrierMismatchPolicy.trustCached,
    )..updateHistoricalCarrierSignatureConflictTrust(
        (sourceId) => sourceId == current.content.sourceId,
      );
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[1, 2, 3]);
    expect(fallback.opens, 0);
    expect(cache.values.containsKey(current), isFalse);
    expect(manager.directEquivalents(current), isEmpty);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.payload['historicalCarrierSignatureConflict'], isTrue);
    expect(
      source.payload['historicalCarrierSignatureConflictTrusted'],
      isTrue,
    );
  });

  test('persistent backend exposes conflicting READY carriers in touch order',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'zic-historical-carrier-conflict-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = await PersistentDownloadArtifactStore.open(root.path);
    final currentUri = Uri.parse('venera-resource:persistent-current');
    final historicalUriA = Uri.parse('venera-resource:persistent-old-a');
    final historicalUriB = Uri.parse('venera-resource:persistent-old-b');
    final current = _downloadId(currentUri, 'persistent-conflict-page');
    final historicalA = _downloadId(
      historicalUriA,
      'persistent-conflict-page',
    );
    final historicalB = _downloadId(
      historicalUriB,
      'persistent-conflict-page',
    );
    await store.storePromotedArtifact(
      id: historicalA,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    await store.storePromotedArtifact(
      id: historicalB,
      bytes: Uint8List.fromList(<int>[4, 5, 6, 7]),
    );
    await store.close();
    final reopened = await PersistentDownloadArtifactStore.open(root.path);
    addTearDown(reopened.close);
    expect(await reopened.openArtifactStream(historicalA), isNotNull);
    expect(await reopened.openArtifactStream(historicalB), isNotNull);
    final historicalCandidates =
        await reopened.historicalArtifactCarriers(current);
    expect(historicalCandidates.readyRecordCount, 2);
    expect(historicalCandidates.signatureCount, 2);
    expect(historicalCandidates.ids, containsAll(<DownloadId>[historicalA, historicalB]));
    for (final candidate in historicalCandidates.ids) {
      expect(await reopened.openArtifactStream(candidate), isNotNull);
    }
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    var conflictTrustCalls = 0;
    final manager = ArtifactCacheManager(
      backend: reopened,
      carrierMismatchPolicy: CachedCarrierMismatchPolicy.trustCached,
    )..updateHistoricalCarrierSignatureConflictTrust((_) {
        conflictTrustCalls++;
        return true;
      });
    expect(
      await manager.lookupAuthoritative(historicalCandidates.ids.first),
      isNotNull,
    );
    final historicalLookup = await manager.lookupHistoricalCarrier(current);
    expect(conflictTrustCalls, 1);
    expect(historicalLookup, isNotNull);
    expect(historicalLookup?.signatureConflictTrusted, isTrue);
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[4, 5, 6, 7]);
    expect(fallback.opens, 0);
    expect(await manager.lookupAuthoritative(current), isNull);
  });

  test('reuse-then-refresh serves old URI and arms revalidation only',
      () async {
    final currentUri = Uri.parse('venera-resource:current-lazy-carrier');
    final historicalUri = Uri.parse('venera-resource:lazy-cache-carrier');
    final current = _downloadId(currentUri, 'page-lazy-carrier');
    final historical = _downloadId(historicalUri, 'page-lazy-carrier');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{
      historical: Uint8List.fromList(<int>[5, 6, 7]),
    });
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[9]));
    final manager = ArtifactCacheManager(
      backend: cache,
      carrierMismatchPolicy: CachedCarrierMismatchPolicy.reuseThenRefresh,
    );
    final transport = ArtifactCacheTransport(
      cache: manager,
      identities: <MapEntry<Uri, DownloadId>>[
        MapEntry(currentUri, current),
      ],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(currentUri);

    expect(await _collect(response), <int>[5, 6, 7]);
    expect(fallback.opens, 0);
    expect(cache.values.containsKey(current), isFalse);
    expect(manager.directEquivalents(current), isEmpty);
    expect(manager.hasPendingHistoricalCarrierRevalidation(current), isTrue);
    expect(manager.consumeHistoricalCarrierRevalidation(current), isTrue);
    expect(manager.hasPendingHistoricalCarrierRevalidation(current), isFalse);
  });
}

DownloadId _downloadId(Uri uri, String pageId) => DownloadId(
      content: ContentId(
        sourceId: 'source',
        comicId: 'comic',
        chapterId: 'chapter',
        pageId: pageId,
      ),
      sourceRevision: 'r1',
      canonicalUri: uri,
    );

Future<List<int>> _collect(ByteResponse response) async {
  final bytes = <int>[];
  await for (final chunk in response.bytes) {
    bytes.addAll(chunk);
  }
  return bytes;
}

Future<List<int>> _collectStream(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

final class _MemoryArtifactStore
    implements ArtifactCacheBackend, HistoricalArtifactCarrierQueryBackend {
  _MemoryArtifactStore(this.values);

  final Map<DownloadId, Uint8List> values;
  int reads = 0;

  @override
  Future<HistoricalArtifactCarrierCandidates> historicalArtifactCarriers(
    DownloadId id,
  ) async {
    final candidates = values.keys
        .where(
          (candidate) =>
              candidate != id &&
              candidate.content == id.content &&
              candidate.sourceRevision == id.sourceRevision,
        )
        .toList(growable: false);
    final signatures = <String>{
      for (final candidate in candidates)
        '${values[candidate]!.lengthInBytes}:${values[candidate]!.join(',')}',
    };
    return HistoricalArtifactCarrierCandidates(
      ids: candidates,
      readyRecordCount: candidates.length,
      signatureCount: signatures.length,
    );
  }

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    reads++;
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = (endExclusive ?? bytes.lengthInBytes)
            .clamp(start, bytes.lengthInBytes)
            .toInt();
        const chunkSize = defaultTransportChunkBytes;
        for (var offset = start; offset < end; offset += chunkSize) {
          final chunkEnd = (offset + chunkSize).clamp(offset, end).toInt();
          yield Uint8List.sublistView(bytes, offset, chunkEnd);
        }
      },
      readAll: () async => bytes,
    );
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    values.remove(id);
  }
}

final class _StreamingArtifactStore implements ArtifactCacheBackend {
  _StreamingArtifactStore(
    this.id,
    this.bytes, {
    this.exposeReadAll = false,
    this.failReadAll = false,
  });

  final DownloadId id;
  final Uint8List bytes;
  final bool exposeReadAll;
  final bool failReadAll;
  int fullReads = 0;
  int streamOpens = 0;
  int readAllCalls = 0;


  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    if (id != this.id) return null;
    streamOpens++;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        final end = (endExclusive ?? bytes.lengthInBytes)
            .clamp(start, bytes.lengthInBytes)
            .toInt();
        const chunkSize = promotedArtifactReadChunkBytes;
        for (var offset = start; offset < end; offset += chunkSize) {
          final chunkEnd = (offset + chunkSize).clamp(offset, end).toInt();
          yield Uint8List.sublistView(bytes, offset, chunkEnd);
        }
      },
      readAll: exposeReadAll
          ? () async {
              readAllCalls++;
              if (failReadAll) throw StateError('read-all fixture failure');
              return bytes;
            }
          : null,
      streamIntegrity: ArtifactReadIntegrityBasis.sealedMetadataLength,
      fullReadIntegrity: exposeReadAll
          ? ArtifactReadIntegrityBasis.crc32Verified
          : ArtifactReadIntegrityBasis.unspecified,
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _CancellableStreamingArtifactStore
    implements ArtifactCacheBackend {
  _CancellableStreamingArtifactStore(this.id, this.body);

  final DownloadId id;
  final Stream<List<int>> body;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    if (id != this.id) return null;
    return ArtifactCacheStreamEntry(
      length: 1,
      open: ({required int start, int? endExclusive}) => body,
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _TypedPreflightFailureArtifactStore
    implements ArtifactCacheBackend {
  _TypedPreflightFailureArtifactStore(this.id);

  final DownloadId id;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    if (id != this.id) return null;
    throw const ArtifactReadFailure(
      kind: ArtifactReadFailureKind.missing,
      accessLocator: '/missing/page.webp',
      failedOffset: 0,
      bytesEmitted: 0,
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _TypedBodyFailureArtifactStore implements ArtifactCacheBackend {
  _TypedBodyFailureArtifactStore(
    this.id, {
    required this.kind,
    this.emitPrefix = true,
  });

  final DownloadId id;
  final ArtifactReadFailureKind kind;
  final bool emitPrefix;
  int streamOpens = 0;
  int invalidations = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    if (id != this.id) return null;
    streamOpens++;
    return ArtifactCacheStreamEntry(
      length: 6,
      open: ({required int start, int? endExclusive}) async* {
        var emitted = 0;
        if (emitPrefix) {
          const prefix = <int>[1, 2, 3];
          emitted = prefix.length;
          yield Uint8List.fromList(prefix);
        }
        throw ArtifactReadFailure(
          kind: kind,
          accessLocator: '/fixture/page.webp',
          replicaId: 'fixture-replica',
          failedOffset: start + emitted,
          bytesEmitted: emitted,
          expectedLength: 6,
          observedLength: emitted,
        );
      },
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {
    invalidations++;
  }
}

final class _BlockingLookupArtifactStore implements ArtifactCacheBackend {
  final Completer<ArtifactCacheStreamEntry?> pending =
      Completer<ArtifactCacheStreamEntry?>();

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) =>
      pending.future;

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _BlockingControlledTransport implements ControlledTransport {
  final Completer<ByteResponse> pending = Completer<ByteResponse>();
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
  }) {
    opens++;
    return pending.future;
  }
}

final class _SelfBoundedRecordingTransport
    implements ControlledTransport, SelfBoundedOpenTransport {
  _SelfBoundedRecordingTransport(this.body, {required this.delay});

  final Uint8List body;
  final Duration delay;
  int opens = 0;
  TaskControl? lastControl;

  @override
  bool selfBoundsOpen(Uri uri) => true;

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
    opens++;
    lastControl = control;
    await Future<void>.delayed(delay);
    control?.throwIfCancelled();
    return ByteResponse(
      bytes: Stream<List<int>>.value(body),
      statusCode: HttpStatus.ok,
      rangeStart: 0,
      totalLength: body.length,
    );
  }
}

final class _ThrowingArtifactStore implements ArtifactCacheBackend {
  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    throw StateError('corrupt promoted artifact');
  }


  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}

  @override
  Future<void> invalidateArtifact(DownloadId id) async {}
}

final class _MutableTaskControl implements TaskControl {
  _MutableTaskControl({required this.priority});

  final Completer<void> _cancelled = Completer<void>();

  @override
  int priority;

  @override
  bool get cancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class _ControlledRecordingTransport implements ControlledTransport {
  _ControlledRecordingTransport(this.body);

  final Uint8List body;
  int controlledOpens = 0;
  int uncontrolledOpens = 0;
  TaskControl? lastControl;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    uncontrolledOpens++;
    return _response();
  }

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    controlledOpens++;
    lastControl = control;
    return _response();
  }

  ByteResponse _response() => ByteResponse(
        bytes: Stream<List<int>>.value(body),
        statusCode: 200,
        rangeStart: 0,
        totalLength: body.lengthInBytes,
      );
}

final class _RecordingTransport implements Transport {
  _RecordingTransport(
    this.body, {
    this.diagnostics = const <String, Object?>{},
  });

  final Uint8List body;
  final Map<String, Object?> diagnostics;
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    return ByteResponse(
      bytes: Stream<List<int>>.value(body),
      statusCode: 200,
      rangeStart: 0,
      totalLength: body.lengthInBytes,
      diagnostics: diagnostics,
    );
  }
}

final class _DiscardTrackingTransport implements Transport {
  _DiscardTrackingTransport(this.body);

  final StreamController<List<int>> body;
  final Completer<void> discarded = Completer<void>();
  int opens = 0;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    opens++;
    return ByteResponse(
      bytes: body.stream,
      statusCode: 200,
      rangeStart: 0,
      totalLength: 1,
      onDiscardControlled: ({TaskControl? control}) async {
        if (!discarded.isCompleted) discarded.complete();
        if (!body.isClosed) await body.close();
      },
    );
  }
}
