import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'transport.dart';

typedef TransportByteLoader = Future<Uint8List> Function();
typedef TransportResponseLoader = Future<ByteResponse> Function({
  ByteRange? range,
  Validators? validators,
});

typedef ControlledTransportResponseLoader = Future<ByteResponse> Function({
  ByteRange? range,
  Validators? validators,
  TaskControl? control,
});

final class LoaderTransportSource {
  const LoaderTransportSource({
    this.loadBytes,
    this.openResponse,
    this.openControlledResponse,
    required this.revision,
  }) : assert(
          loadBytes != null ||
              openResponse != null ||
              openControlledResponse != null,
        );

  final TransportByteLoader? loadBytes;
  final TransportResponseLoader? openResponse;
  final ControlledTransportResponseLoader? openControlledResponse;
  final String revision;
}

/// Adapts platform-owned or in-memory byte loaders to the same range/resume
/// contract used by Reader download sessions.
final class LoaderTransport implements ControlledTransport {
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
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    range?.validate();
    final source = _sources[uri.toString()];
    if (source == null) {
      throw Failure(
        code: ErrorCode.source,
        message: 'no byte loader registered for $uri',
      );
    }

    final openControlledResponse = source.openControlledResponse;
    if (openControlledResponse != null) {
      return openControlledResponse(
        range: range,
        validators: validators,
        control: control,
      );
    }
    final openResponse = source.openResponse;
    if (openResponse != null) {
      return openResponse(range: range, validators: validators);
    }
    final bytes = await source.loadBytes!();
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
      bytes: _chunkedLoaderBytes(body),
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


Stream<List<int>> _chunkedLoaderBytes(Uint8List bytes) async* {
  for (var offset = 0;
      offset < bytes.lengthInBytes;
      offset += defaultTransportChunkBytes) {
    final end = (offset + defaultTransportChunkBytes)
        .clamp(0, bytes.lengthInBytes)
        .toInt();
    yield Uint8List.sublistView(bytes, offset, end);
  }
}
