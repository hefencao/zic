import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'transport.dart';

typedef TransportByteLoader = Future<Uint8List> Function();

final class LoaderTransportSource {
  const LoaderTransportSource({
    required this.loadBytes,
    required this.revision,
  });

  final TransportByteLoader loadBytes;
  final String revision;
}

/// Adapts platform-owned or in-memory byte loaders to the same range/resume
/// contract used by Reader download sessions.
final class LoaderTransport implements Transport {
  LoaderTransport(Map<Uri, LoaderTransportSource> sources)
      : _sources = Map<String, LoaderTransportSource>.unmodifiable(
          sources.map(
            (uri, source) => MapEntry<String, LoaderTransportSource>(
              uri.toString(),
              source,
            ),
          ),
        );

  final Map<String, LoaderTransportSource> _sources;

  bool contains(Uri uri) => _sources.containsKey(uri.toString());

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    range?.validate();
    final source = _sources[uri.toString()];
    if (source == null) {
      throw Failure(
        code: ErrorCode.source,
        message: 'no byte loader registered for $uri',
      );
    }

    final bytes = await source.loadBytes();
    final contentHash = _fnv64Bytes(bytes);
    final currentValidators = Validators(
      etag: '"${source.revision}-${bytes.length}-$contentHash"',
    );
    final canServeRange = range != null &&
        range.start <= bytes.length &&
        (validators == null ||
            validators.isEmpty ||
            validators.matches(currentValidators));
    final start = canServeRange ? range!.start : 0;
    final requestedEnd = canServeRange ? range!.end : null;
    final endExclusive = requestedEnd == null
        ? bytes.length
        : (requestedEnd + 1).clamp(start, bytes.length).toInt();
    final body = Uint8List.sublistView(bytes, start, endExclusive);

    return ByteResponse(
      bytes: Stream<List<int>>.value(body),
      statusCode: canServeRange ? 206 : 200,
      rangeStart: start,
      totalLength: bytes.length,
      validators: currentValidators,
      rangeSupported: true,
    );
  }
}


String _fnv64Bytes(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
