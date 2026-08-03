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
      cache: cache,
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
    expect(fallback.opens, 0);
    final source = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.artifactSource,
    );
    expect(source.identityHash, id.key);
    expect(source.revision, 7);
    expect(source.payload['source'], 'artifact-cache');
    expect(source.payload['sourceClass'], 'persistent-artifact');
    expect(source.payload['bytes'], 4);
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.identityHash, id.key);
    expect(read.payload['source'], 'artifact-cache');
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
      cache: cache,
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
      cache: cache,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
      clock: _Clock(),
      traceSink: trace,
    );

    final response = await transport.open(uri);
    final chunks = await response.bytes.map((chunk) => chunk.length).toList();

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

  test('rejects a read pool backed by another cache', () {
    final uri = Uri.parse('https://example.invalid/pool-mismatch.bin');
    final id = _downloadId(uri, 'page-pool-mismatch');
    final cache = _MemoryArtifactStore(<DownloadId, Uint8List>{});
    final other = _MemoryArtifactStore(<DownloadId, Uint8List>{});
    final pool = PromotedArtifactReadPool(cache: other);
    addTearDown(pool.close);

    expect(
      () => ArtifactCacheTransport(
        cache: cache,
        readPool: pool,
        identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
        fallbackFor: (_) => _RecordingTransport(Uint8List(0)),
      ),
      throwsArgumentError,
    );
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
      cache: cache,
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
    final fallback = _RecordingTransport(Uint8List.fromList(<int>[8, 9]));
    final trace = MemoryTraceSink();
    final transport = ArtifactCacheTransport(
      cache: cache,
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
    final read = trace.events.singleWhere(
      (event) => event.kind == TraceEventKind.sourceRead,
    );
    expect(read.payload['source'], 'origin');
    expect(read.payload['sourceClass'], 'remote');
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
      cache: cache,
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
      cache: cache,
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

final class _MemoryArtifactStore implements ArtifactCacheStore {
  _MemoryArtifactStore(this.values);

  final Map<DownloadId, Uint8List> values;
  int reads = 0;

  @override
  Future<Uint8List?> readArtifact(DownloadId id) async {
    reads++;
    return values[id];
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {
    values[id] = Uint8List.fromList(bytes);
  }
}

final class _StreamingArtifactStore
    implements ArtifactCacheStore, ArtifactCacheStreamStore {
  _StreamingArtifactStore(this.id, this.bytes);

  final DownloadId id;
  final Uint8List bytes;
  int fullReads = 0;
  int streamOpens = 0;

  @override
  Future<Uint8List?> readArtifact(DownloadId id) async {
    fullReads++;
    return bytes;
  }

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
    );
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}

final class _ThrowingArtifactStore implements ArtifactCacheStore {
  @override
  Future<Uint8List?> readArtifact(DownloadId id) async {
    throw StateError('corrupt promoted artifact');
  }

  @override
  Future<void> storePromotedArtifact({
    required DownloadId id,
    required Uint8List bytes,
  }) async {}
}

final class _RecordingTransport implements Transport {
  _RecordingTransport(this.body);

  final Uint8List body;
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
    );
  }
}
