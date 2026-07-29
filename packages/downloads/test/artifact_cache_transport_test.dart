import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:downloads/downloads.dart';
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
    final transport = ArtifactCacheTransport(
      cache: cache,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(uri);

    expect(await _collect(response), <int>[1, 2, 3, 4]);
    expect(response.statusCode, 200);
    expect(response.totalLength, 4);
    expect(fallback.opens, 0);
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
    final transport = ArtifactCacheTransport(
      cache: cache,
      identities: <MapEntry<Uri, DownloadId>>[MapEntry(uri, id)],
      fallbackFor: (_) => fallback,
    );

    final response = await transport.open(
      uri,
      range: const ByteRange(start: 1),
      validators: const Validators(etag: '"different"'),
    );

    expect(await _collect(response), <int>[8, 9]);
    expect(fallback.opens, 1);
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
