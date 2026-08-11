import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
import 'package:telemetry/telemetry.dart';
import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
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

  test('foreground read-all populates and reuses the shared byte cache',
      () async {
    final uri = Uri.parse('https://example.invalid/hot-page.bin');
    final id = _downloadId(uri, 'page-hot');
    final bytes = Uint8List(promotedArtifactReadChunkBytes + 17);
    final cache = _StreamingArtifactStore(id, bytes, exposeReadAll: true);
    final manager = ArtifactCacheManager(backend: cache);
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

    final firstResponse = await transport.open(uri);
    final first = await firstResponse.bytes.map((chunk) => chunk.length).toList();
    final secondResponse = await transport.open(uri);
    final second =
        await secondResponse.bytes.map((chunk) => chunk.length).toList();

    expect(
      firstResponse.disposition,
      ByteResponseDisposition.durableImmutable,
    );
    expect(
      secondResponse.disposition,
      ByteResponseDisposition.durableImmutable,
    );

    expect(first, <int>[promotedArtifactReadChunkBytes, 17]);
    expect(second, <int>[bytes.lengthInBytes]);
    expect(cache.readAllCalls, 1);
    expect(cache.streamOpens, 1);
    expect(manager.memoryEntryCount, 1);
    final sources = trace.events
        .where((event) => event.kind == TraceEventKind.artifactSource)
        .map((event) => event.payload['source'])
        .toList();
    expect(sources, <Object?>['artifact-read-all', 'artifact-byte-cache']);
    final reads = trace.events
        .where((event) => event.kind == TraceEventKind.sourceRead)
        .toList();
    expect(reads[0].payload['artifactReadMode'], 'read-all');
    expect(reads[0].payload['deliveryMode'], 'startup-segmented');
    expect(
      reads[0].payload['startupChunkBytes'],
      promotedArtifactReadChunkBytes,
    );
    expect(reads[0].payload['readSchedulerLeaseThroughStream'], isTrue);
    expect(reads[1].payload['artifactReadMode'], 'memory-hit');
    expect(reads[1].payload['deliveryMode'], 'memory-direct');
    expect(reads[1].payload['readSchedulerAcquires'], 1);
  });

  test('foreground read-all holds its scheduler lease until body drains',
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
    expect(scheduler.activeForegroundCount, 1);
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

  test('read-all failure falls back to the artifact stream, not origin',
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
    expect(cache.readAllCalls, 1);
    final failure = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.taskFailed,
    );
    expect(failure.payload['lane'], 'artifact-cache-read-all');
    expect(failure.payload['fallback'], 'artifact-cache-stream');
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

  test('completed immutable local origin is hot across Reader sessions',
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

final class _Clock implements MonoClock {
  int _value = 0;

  @override
  int nowMicros() => _value++;
}

final class _MemoryArtifactStore implements ArtifactCacheBackend {
  _MemoryArtifactStore(this.values);

  final Map<DownloadId, Uint8List> values;
  int reads = 0;

  @override
  Future<ArtifactCacheStreamEntry?> openArtifactStream(DownloadId id) async {
    reads++;
    final bytes = values[id];
    if (bytes == null) return null;
    return ArtifactCacheStreamEntry(
      length: bytes.lengthInBytes,
      open: ({required int start, int? endExclusive}) async* {
        yield Uint8List.sublistView(
          bytes,
          start,
          endExclusive ?? bytes.lengthInBytes,
        );
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
