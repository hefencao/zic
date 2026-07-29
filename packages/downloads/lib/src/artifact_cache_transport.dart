import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_store.dart';
import 'promoted_artifact_read_pool.dart';

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
    PromotedArtifactReadPool? readPool,
    MonoClock? clock,
    TraceSink traceSink = const NoopTraceSink(),
    String sessionId = 'artifact-cache',
    int Function()? demandRevision,
  })  : _cache = cache,
        _identities = _uniqueIdentities(identities),
        _fallbackFor = fallbackFor,
        _readPool = readPool,
        _clock = clock,
        _traceSink = traceSink,
        _sessionId = sessionId,
        _demandRevision = demandRevision {
    if (readPool != null && !identical(readPool.cache, cache)) {
      throw ArgumentError.value(
        readPool,
        'readPool',
        'must read from the same artifact cache',
      );
    }
  }

  final ArtifactCacheStore _cache;
  final Map<String, DownloadId> _identities;
  final Transport Function(Uri uri) _fallbackFor;
  final PromotedArtifactReadPool? _readPool;
  final MonoClock? _clock;
  final TraceSink _traceSink;
  final String _sessionId;
  final int Function()? _demandRevision;

  @override
  Future<ByteResponse> open(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
  }) async {
    final revision = _demandRevision?.call();
    range?.validate();
    final id = _identities[uri.toString()];
    if (id != null) {
      final readStarted = _clock?.nowMicros();
      try {
        final bytes = await (_readPool?.read(id) ?? _cache.readArtifact(id));
        final readMicros = readStarted == null
            ? null
            : (_clock!.nowMicros() - readStarted).clamp(0, 1 << 62).toInt();
        if (bytes != null) {
          final response = _cachedResponse(
            id: id,
            bytes: bytes,
            range: range,
            validators: validators,
          );
          if (response != null) {
            _recordSource(
              source: 'artifact-cache',
              id: id,
              uri: uri,
              bytes: bytes.lengthInBytes,
              range: range,
              revision: revision,
              readMicros: readMicros,
            );
            return response;
          }
        }
      } on Object catch (error) {
        _recordCacheFailure(
          id: id,
          uri: uri,
          revision: revision,
          error: error,
          readStarted: readStarted,
        );
      }
    }
    _recordSource(
      source: 'origin',
      id: id,
      uri: uri,
      range: range,
      revision: revision,
    );
    return _fallbackFor(uri).open(
      uri,
      range: range,
      validators: validators,
    );
  }

  void _recordCacheFailure({
    required DownloadId id,
    required Uri uri,
    required int? revision,
    required Object error,
    required int? readStarted,
  }) {
    final clock = _clock;
    if (clock == null) {
      return;
    }
    _traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: _sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'lane': 'artifact-cache-read',
          'uri': uri.toString(),
          'reason': error.toString(),
          if (readStarted != null)
            'readMicros':
                (clock.nowMicros() - readStarted).clamp(0, 1 << 62).toInt(),
          'fallback': 'origin',
        },
      ),
    );
  }

  void _recordSource({
    required String source,
    required DownloadId? id,
    required Uri uri,
    required ByteRange? range,
    int? bytes,
    int? revision,
    int? readMicros,
  }) {
    final clock = _clock;
    if (clock == null) {
      return;
    }
    _traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: _sessionId,
        kind: TraceEventKind.artifactSource,
        identityHash: id?.key,
        revision: revision,
        payload: <String, Object?>{
          'source': source,
          'uri': uri.toString(),
          if (bytes != null) 'bytes': bytes,
          if (range != null) 'rangeStart': range.start,
          if (range?.end != null) 'rangeEnd': range!.end,
          if (readMicros != null) 'readMicros': readMicros,
          'consumer': 'session-copy',
        },
      ),
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
    etag: '"zic-artifact-${bytes.lengthInBytes}-'
        '${_fnv64String(id.key)}"',
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
    bytes: _chunkedBytes(body),
    statusCode: canServeRange ? 206 : 200,
    rangeStart: start,
    totalLength: bytes.lengthInBytes,
    validators: currentValidators,
    rangeSupported: true,
  );
}

Stream<List<int>> _chunkedBytes(Uint8List bytes) async* {
  const chunkSize = 64 * 1024;
  for (var offset = 0; offset < bytes.lengthInBytes; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, bytes.lengthInBytes).toInt();
    yield Uint8List.sublistView(bytes, offset, end);
  }
}

String _fnv64String(String value) {
  var hash = 0xcbf29ce484222325;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
