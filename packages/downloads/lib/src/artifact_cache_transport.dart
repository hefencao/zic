import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_store.dart';
import 'promoted_artifact_byte_cache.dart';
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
    PromotedArtifactByteCache? byteCache,
    ArtifactCacheReadScheduler? readScheduler,
    int Function(DownloadId id)? demandPriority,
    MonoClock? clock,
    TraceSink traceSink = const NoopTraceSink(),
    String sessionId = 'artifact-cache',
    int Function()? demandRevision,
  })  : _cache = cache,
        _identities = _uniqueIdentities(identities),
        _fallbackFor = fallbackFor,
        _readPool = readPool,
        _byteCache = byteCache,
        _readScheduler = readScheduler,
        _demandPriority = demandPriority,
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
  final PromotedArtifactByteCache? _byteCache;
  final ArtifactCacheReadScheduler? _readScheduler;
  final int Function(DownloadId id)? _demandPriority;
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
        if (_cache is ArtifactCacheStreamStore) {
          final streamingCache = _cache as ArtifactCacheStreamStore;
          final entry = await streamingCache.openArtifactStream(id);
          final readMicros = readStarted == null
              ? null
              : (_clock!.nowMicros() - readStarted)
                  .clamp(0, 1 << 62)
                  .toInt();
          if (entry != null) {
            final foregroundResponse = await _foregroundArtifactResponse(
              id: id,
              uri: uri,
              entry: entry,
              range: range,
              validators: validators,
              revision: revision,
              openMicros: readMicros,
            );
            if (foregroundResponse != null) {
              return foregroundResponse;
            }
            final cachedResponse = _streamedCachedResponse(
              id: id,
              entry: entry,
              range: range,
              validators: validators,
            );
            if (cachedResponse != null) {
              var schedulerWaitMicros = 0;
              var schedulerMaxWaitMicros = 0;
              var schedulerAcquires = 0;
              var schedulerForegroundAcquires = 0;
              var acquiredPriority = _demandPriority?.call(id) ?? 0;
              final readScheduler = _readScheduler;
              final response = readScheduler == null
                  ? cachedResponse
                  : _scheduledArtifactResponse(
                      cachedResponse,
                      scheduler: readScheduler,
                      priority: () => _demandPriority?.call(id) ?? 0,
                      onAcquired: (waitMicros, priority) {
                        schedulerWaitMicros += waitMicros;
                        if (waitMicros > schedulerMaxWaitMicros) {
                          schedulerMaxWaitMicros = waitMicros;
                        }
                        schedulerAcquires++;
                        if (priority >= readScheduler.foregroundPriority) {
                          schedulerForegroundAcquires++;
                        }
                        acquiredPriority = priority;
                      },
                    );
              _recordSource(
                source: 'artifact-cache-stream',
                id: id,
                uri: uri,
                bytes: entry.length,
                range: range,
                revision: revision,
                readMicros: readMicros,
                sourceClass: 'persistent-artifact',
                priority: acquiredPriority,
              );
              return _traceResponse(
                response,
                source: 'artifact-cache-stream',
                sourceClass: 'persistent-artifact',
                id: id,
                uri: uri,
                revision: revision,
                openMicros: readMicros,
                priority: () => acquiredPriority,
                schedulerWaitMicros: () => schedulerWaitMicros,
                schedulerMaxWaitMicros: () => schedulerMaxWaitMicros,
                schedulerAcquires: () => schedulerAcquires,
                schedulerForegroundAcquires: () =>
                    schedulerForegroundAcquires,
              );
            }
          }
        } else {
          final bytes = await (_readPool?.read(id) ?? _cache.readArtifact(id));
          final readMicros = readStarted == null
              ? null
              : (_clock!.nowMicros() - readStarted)
                  .clamp(0, 1 << 62)
                  .toInt();
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
                sourceClass: 'persistent-artifact',
              );
              return _traceResponse(
                response,
                source: 'artifact-cache',
                sourceClass: 'persistent-artifact',
                id: id,
                uri: uri,
                revision: revision,
                openMicros: readMicros,
              );
            }
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
    final fallback = _fallbackFor(uri);
    final openStarted = _clock?.nowMicros();
    final response = await fallback.open(
      uri,
      range: range,
      validators: validators,
    );
    final openMicros = openStarted == null
        ? null
        : (_clock!.nowMicros() - openStarted).clamp(0, 1 << 62).toInt();
    final sourceClass = _originSourceClass(uri, fallback);
    _recordSource(
      source: 'origin',
      id: id,
      uri: uri,
      range: range,
      revision: revision,
      readMicros: openMicros,
      sourceClass: sourceClass,
      statusCode: response.statusCode,
      totalLength: response.totalLength,
    );
    return _traceResponse(
      response,
      source: 'origin',
      sourceClass: sourceClass,
      id: id,
      uri: uri,
      revision: revision,
      openMicros: openMicros,
    );
  }

  Future<ByteResponse?> _foregroundArtifactResponse({
    required DownloadId id,
    required Uri uri,
    required ArtifactCacheStreamEntry entry,
    required ByteRange? range,
    required Validators? validators,
    required int? revision,
    required int? openMicros,
  }) async {
    final byteCache = _byteCache;
    final readAll = entry.readAll;
    if (byteCache == null || readAll == null) return null;
    final scheduler = _readScheduler;
    final foregroundPriority = scheduler?.foregroundPriority ?? 900;
    final requestedPriority = _demandPriority?.call(id) ?? 0;
    if (requestedPriority < foregroundPriority) return null;

    var schedulerWaitMicros = 0;
    var schedulerAcquires = 0;
    var schedulerForegroundAcquires = 0;
    var acquiredPriority = requestedPriority;
    ArtifactCacheReadLease? lease;
    final materializeStarted = _clock?.nowMicros();
    PromotedArtifactByteRead read;
    try {
      final cached = byteCache.lookup(id, length: entry.length);
      if (cached != null) {
        read = PromotedArtifactByteRead(
          bytes: cached,
          memoryHit: true,
          joined: false,
        );
      } else {
        if (scheduler != null) {
          final wait = Stopwatch()..start();
          lease = await scheduler.acquire(
            priority: () => _demandPriority?.call(id) ?? requestedPriority,
          );
          schedulerWaitMicros = wait.elapsedMicroseconds;
          schedulerAcquires = 1;
          schedulerForegroundAcquires = lease.foreground ? 1 : 0;
          acquiredPriority = lease.priority;
        }
        read = await byteCache.read(
          id: id,
          length: entry.length,
          loader: readAll,
        );
      }
    } on Object catch (error) {
      _recordForegroundReadFailure(
        id: id,
        uri: uri,
        revision: revision,
        error: error,
        materializeStarted: materializeStarted,
      );
      return null;
    } finally {
      lease?.release();
    }
    final bytes = read.bytes;
    final materializeMicros = materializeStarted == null
        ? null
        : (_clock!.nowMicros() - materializeStarted)
            .clamp(0, 1 << 62)
            .toInt();
    final response = _cachedResponse(
      id: id,
      bytes: bytes,
      range: range,
      validators: validators,
    );
    if (response == null) return null;
    final source = read.memoryHit
        ? 'artifact-byte-cache'
        : 'artifact-read-all';
    final details = <String, Object?>{
      'artifactReadMode': read.memoryHit
          ? 'memory-hit'
          : read.joined
              ? 'joined-read-all'
              : 'read-all',
      'memoryCacheHit': read.memoryHit,
      'memoryCacheJoined': read.joined,
      if (materializeMicros != null)
        'artifactMaterializeMicros': materializeMicros,
      'readSchedulerWaitMicros': schedulerWaitMicros,
      'readSchedulerAcquires': schedulerAcquires,
      'readSchedulerForegroundAcquires': schedulerForegroundAcquires,
      'hotCacheEntries': byteCache.entryCount,
      'hotCacheBytes': byteCache.retainedBytes,
    };
    _recordSource(
      source: source,
      id: id,
      uri: uri,
      bytes: bytes.lengthInBytes,
      range: range,
      revision: revision,
      readMicros: openMicros,
      sourceClass: 'persistent-artifact',
      priority: acquiredPriority,
      details: details,
    );
    return _traceResponse(
      response,
      source: source,
      sourceClass: 'persistent-artifact',
      id: id,
      uri: uri,
      revision: revision,
      openMicros: openMicros,
      priority: () => acquiredPriority,
      readDetails: () => details,
    );
  }


  void _recordForegroundReadFailure({
    required DownloadId id,
    required Uri uri,
    required int? revision,
    required Object error,
    required int? materializeStarted,
  }) {
    final clock = _clock;
    if (clock == null) return;
    _traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: _sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'lane': 'artifact-cache-read-all',
          'uri': uri.toString(),
          'error': error.toString(),
          'reason': error.toString(),
          if (materializeStarted != null)
            'readMicros': (clock.nowMicros() - materializeStarted)
                .clamp(0, 1 << 62)
                .toInt(),
          'fallback': 'artifact-cache-stream',
        },
      ),
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
    String? sourceClass,
    int? statusCode,
    int? totalLength,
    int? priority,
    Map<String, Object?> details = const <String, Object?>{},
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
          if (sourceClass != null) 'sourceClass': sourceClass,
          if (statusCode != null) 'statusCode': statusCode,
          if (totalLength != null) 'totalLength': totalLength,
          if (priority != null) 'priority': priority,
          ...details,
          'uriScheme': uri.scheme.isEmpty ? 'file' : uri.scheme,
          'consumer': 'session-copy',
        },
      ),
    );
  }

  ByteResponse _traceResponse(
    ByteResponse response, {
    required String source,
    required String sourceClass,
    required DownloadId? id,
    required Uri uri,
    required int? revision,
    required int? openMicros,
    int Function()? priority,
    int Function()? schedulerWaitMicros,
    int Function()? schedulerMaxWaitMicros,
    int Function()? schedulerAcquires,
    int Function()? schedulerForegroundAcquires,
    Map<String, Object?> Function()? readDetails,
  }) {
    final clock = _clock;
    if (clock == null) {
      return response;
    }
    final streamStarted = clock.nowMicros();
    var firstChunkMicros = 0;
    var bytes = 0;
    var chunks = 0;
    var minChunkBytes = 0;
    var maxChunkBytes = 0;
    var maxChunkGapMicros = 0;
    var lastChunkMicros = streamStarted;
    var completed = false;
    Object? failure;

    Stream<List<int>> tracedBytes() async* {
      try {
        await for (final chunk in response.bytes) {
          final nowMicros = clock.nowMicros();
          final chunkGapMicros =
              (nowMicros - lastChunkMicros).clamp(0, 1 << 62).toInt();
          if (chunks == 0) {
            firstChunkMicros =
                (nowMicros - streamStarted).clamp(0, 1 << 62).toInt();
            minChunkBytes = chunk.length;
          } else if (chunk.length < minChunkBytes) {
            minChunkBytes = chunk.length;
          }
          if (chunk.length > maxChunkBytes) {
            maxChunkBytes = chunk.length;
          }
          if (chunkGapMicros > maxChunkGapMicros) {
            maxChunkGapMicros = chunkGapMicros;
          }
          lastChunkMicros = nowMicros;
          chunks++;
          bytes += chunk.length;
          yield chunk;
        }
        completed = true;
      } on Object catch (error) {
        failure = error;
        rethrow;
      } finally {
        _traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: _sessionId,
            kind: TraceEventKind.sourceRead,
            identityHash: id?.key,
            revision: revision,
            payload: <String, Object?>{
              'source': source,
              'sourceClass': sourceClass,
              'uriScheme': uri.scheme.isEmpty ? 'file' : uri.scheme,
              'statusCode': response.statusCode,
              'rangeStart': response.rangeStart,
              if (response.totalLength != null)
                'totalLength': response.totalLength,
              if (openMicros != null) 'openMicros': openMicros,
              if (priority != null) 'priority': priority(),
              if (schedulerWaitMicros != null)
                'readSchedulerWaitMicros': schedulerWaitMicros(),
              if (schedulerMaxWaitMicros != null)
                'readSchedulerMaxWaitMicros': schedulerMaxWaitMicros(),
              if (schedulerAcquires != null)
                'readSchedulerAcquires': schedulerAcquires(),
              if (schedulerForegroundAcquires != null)
                'readSchedulerForegroundAcquires':
                    schedulerForegroundAcquires(),
              if (readDetails != null) ...readDetails(),
              'firstChunkMicros': firstChunkMicros,
              'streamMicros':
                  (clock.nowMicros() - streamStarted).clamp(0, 1 << 62).toInt(),
              'bytes': bytes,
              'chunks': chunks,
              'minChunkBytes': minChunkBytes,
              'maxChunkBytes': maxChunkBytes,
              'maxChunkGapMicros': maxChunkGapMicros,
              'completed': completed,
              if (failure != null) 'failure': failure.toString(),
              'consumer': 'session-copy',
            },
          ),
        );
      }
    }

    return ByteResponse(
      bytes: tracedBytes(),
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      onDiscard: response.discard,
    );
  }
}

String _originSourceClass(Uri uri, Transport transport) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'content') {
    return 'local-document';
  }
  if (scheme.isEmpty || scheme == 'file') {
    return 'local-file';
  }
  if (scheme == 'asset') {
    return 'asset';
  }
  if (transport is LoaderTransport) {
    return 'source-loader';
  }
  if (scheme.startsWith('mihon') || scheme.startsWith('venera')) {
    return 'plugin-resource';
  }
  return 'remote';
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

ByteResponse _scheduledArtifactResponse(
  ByteResponse response, {
  required ArtifactCacheReadScheduler scheduler,
  required int Function() priority,
  required void Function(int waitMicros, int priority) onAcquired,
}) {
  Stream<List<int>> scheduledBytes() async* {
    final iterator = StreamIterator<List<int>>(response.bytes);
    ArtifactCacheReadLease? lease;
    try {
      while (true) {
        var activeLease = lease;
        if (activeLease == null) {
          final wait = Stopwatch()..start();
          activeLease = await scheduler.acquire(priority: priority);
          lease = activeLease;
          onAcquired(wait.elapsedMicroseconds, activeLease.priority);
        }
        final available = await iterator.moveNext();
        if (!available) {
          return;
        }
        yield iterator.current;

        final stillForeground =
            priority() >= scheduler.foregroundPriority;
        if (!activeLease.foreground || !stillForeground) {
          activeLease.release();
          lease = null;
        }
      }
    } finally {
      lease?.release();
      await iterator.cancel();
    }
  }

  return ByteResponse(
    bytes: scheduledBytes(),
    statusCode: response.statusCode,
    rangeStart: response.rangeStart,
    totalLength: response.totalLength,
    validators: response.validators,
    rangeSupported: response.rangeSupported,
    onDiscard: response.discard,
  );
}

ByteResponse? _streamedCachedResponse({
  required DownloadId id,
  required ArtifactCacheStreamEntry entry,
  required ByteRange? range,
  required Validators? validators,
}) {
  final currentValidators = Validators(
    etag: '"zic-artifact-${entry.length}-${_fnv64String(id.key)}"',
  );
  final canServeRange = range != null &&
      range.start < entry.length &&
      (validators == null ||
          validators.isEmpty ||
          validators.matches(currentValidators));
  if (range != null && !canServeRange) {
    return null;
  }
  final start = canServeRange ? range!.start : 0;
  final requestedEnd = canServeRange ? range!.end : null;
  final endExclusive = requestedEnd == null
      ? entry.length
      : (requestedEnd + 1).clamp(start, entry.length).toInt();
  return ByteResponse(
    bytes: entry.open(start: start, endExclusive: endExclusive),
    statusCode: canServeRange ? 206 : 200,
    rangeStart: start,
    totalLength: entry.length,
    validators: currentValidators,
    rangeSupported: true,
  );
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
    bytes: _chunkedBytes(
      body,
      chunkSize: promotedArtifactReadChunkBytes,
    ),
    statusCode: canServeRange ? 206 : 200,
    rangeStart: start,
    totalLength: bytes.lengthInBytes,
    validators: currentValidators,
    rangeSupported: true,
  );
}

Stream<List<int>> _chunkedBytes(
  Uint8List bytes, {
  int chunkSize = defaultTransportChunkBytes,
}) async* {
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
