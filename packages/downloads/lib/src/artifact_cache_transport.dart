import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_store.dart';

/// Read-through transport for already-promoted page artifacts.
///
/// The transport never writes cache state and never chooses which pages should
/// be requested. It only serves an exact Reader DownloadId from the persistent
/// artifact tier before delegating the same request to the authoritative source
/// transport selected by the session coordinator.
final class ArtifactCacheTransport implements Transport {
  ArtifactCacheTransport({
    required ArtifactCacheStore cache,
    required Iterable<MapEntry<Uri, DownloadId>> identities,
    required Transport Function(Uri uri) fallbackFor,
  })  : _cache = cache,
        _identities = _uniqueIdentities(identities),
        _fallbackFor = fallbackFor;

  final ArtifactCacheStore _cache;
  final Map<String, DownloadId> _identities;
  final Transport Function(Uri uri) _fallbackFor;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    range?.validate();
    final id = _identities[uri.toString()];
    if (id != null) {
      final bytes = await _cache.readArtifact(id);
      if (bytes != null) {
        final response = _cachedResponse(
          id: id,
          bytes: bytes,
          range: range,
          validators: validators,
        );
        if (response != null) {
          return response;
        }
      }
    }
    return _fallbackFor(uri).open(
      uri,
      range: range,
      validators: validators,
    );
  }
}

Map<String, DownloadId> _uniqueIdentities(
  Iterable<MapEntry<Uri, DownloadId>> identities,
) {
  final result = <String, DownloadId>{};
  final collisions = <String>{};
  for (final entry in identities) {
    final key = entry.key.toString();
    if (result.containsKey(key)) {
      collisions.add(key);
    } else {
      result[key] = entry.value;
    }
  }
  for (final key in collisions) {
    result.remove(key);
  }
  return Map<String, DownloadId>.unmodifiable(result);
}

ByteResponse? _cachedResponse({
  required DownloadId id,
  required Uint8List bytes,
  required ByteRange? range,
  required Validators? validators,
}) {
  final currentValidators = Validators(
    etag: '"zic-artifact-${id.sourceRevision}-'
        '${bytes.lengthInBytes}-${_fnv64Bytes(bytes)}"',
  );
  final canServeRange = range != null &&
      range.start < bytes.lengthInBytes &&
      (validators == null ||
          validators.isEmpty ||
          validators.matches(currentValidators));
  if (range != null && !canServeRange) {
    return null;
  }
  final start = canServeRange ? range!.start : 0;
  final requestedEnd = canServeRange ? range!.end : null;
  final endExclusive = requestedEnd == null
      ? bytes.lengthInBytes
      : (requestedEnd + 1).clamp(start, bytes.lengthInBytes).toInt();
  final body = Uint8List.sublistView(bytes, start, endExclusive);
  return ByteResponse(
    bytes: Stream<List<int>>.value(body),
    statusCode: canServeRange ? 206 : 200,
    rangeStart: start,
    totalLength: bytes.lengthInBytes,
    validators: currentValidators,
    rangeSupported: true,
  );
}

String _fnv64Bytes(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
