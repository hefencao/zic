import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_cache_manager.dart';
import 'artifact_cache_read_scheduler.dart';
import 'artifact_cache_store.dart';

const int _foregroundStartupChunkBytes = 1024 * 1024;
const int _foregroundContinuationChunkBytes = 1024 * 1024;

/// Read-through transport for immutable Reader page artifacts.
///
/// Tier lookup is delegated to the composition-owned [ArtifactCacheManager].
/// This transport only applies authoritative demand priority, foreground read
/// scheduling and the origin fallback selected by the owning Reader session.
final class ArtifactCacheTransport implements ControlledTransport {
  ArtifactCacheTransport({
    required ArtifactCacheManager cache,
    required Iterable<MapEntry<Uri, DownloadId>> identities,
    required Transport Function(Uri uri) fallbackFor,
    ArtifactCacheReadScheduler? readScheduler,
    int Function(DownloadId id)? demandPriority,
    MonoClock? clock,
    TraceSink traceSink = const NoopTraceSink(),
    String sessionId = 'artifact-cache',
    int Function()? demandRevision,
  })  : _cache = cache,
        _identities = _uniqueIdentities(identities),
        _fallbackFor = fallbackFor,
        _readScheduler = readScheduler,
        _demandPriority = demandPriority,
        _clock = clock,
        _traceSink = traceSink,
        _sessionId = sessionId,
        _demandRevision = demandRevision;

  final ArtifactCacheManager _cache;
  final Map<String, DownloadId> _identities;
  final Transport Function(Uri uri) _fallbackFor;
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
  }) =>
      openControlled(uri, range: range, validators: validators);

  @override
  Future<ByteResponse> openControlled(
    Uri uri, {
    ByteRange? range,
    Validators? validators,
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final revision = _demandRevision?.call();
    range?.validate();
    final id = _identities[uri.toString()];
    final verifiedEquivalentCandidates = id == null
        ? 0
        : _cache.directEquivalents(id).length;
    if (id != null) {
      final readStarted = _clock?.nowMicros();
      try {
        final lookup = await _cache.lookup(id);
        _throwIfTaskCancelled(control);
        final readMicros = readStarted == null
            ? null
            : (_clock!.nowMicros() - readStarted)
                .clamp(0, 1 << 62)
                .toInt();
        if (lookup != null) {
          final foregroundResponse = await _foregroundArtifactResponse(
            lookup: lookup,
            uri: uri,
            range: range,
            validators: validators,
            revision: revision,
            openMicros: readMicros,
            control: control,
          );
          if (foregroundResponse != null) return foregroundResponse;

          final cachedResponse = _streamedCachedResponse(
            id: id,
            entry: lookup.entry,
            range: range,
            validators: validators,
            durable: lookup.durable,
          );
          if (cachedResponse != null) {
            var schedulerWaitMicros = 0;
            var schedulerMaxWaitMicros = 0;
            var schedulerAcquires = 0;
            var schedulerForegroundAcquires = 0;
            var acquiredPriority = _demandPriority?.call(id) ?? control?.priority ?? 0;
            final readScheduler = _readScheduler;
            final response = readScheduler == null
                ? cachedResponse
                : _scheduledArtifactResponse(
                    cachedResponse,
                    scheduler: readScheduler,
                    priority: () => _demandPriority?.call(id) ?? control?.priority ?? 0,
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
            final source = lookup.tier == ArtifactCacheTier.memory
                ? 'artifact-byte-cache-stream'
                : 'artifact-cache-stream';
            final details = <String, Object?>{
              'cacheTier': lookup.tier.name,
              'memoryCacheHit': lookup.tier == ArtifactCacheTier.memory,
              'verifiedEquivalentReuse':
                  lookup.storageId != id,
              'verifiedEquivalentCandidates': verifiedEquivalentCandidates,
              'hotCacheEntries': _cache.memoryEntryCount,
              'hotCacheBytes': _cache.memoryBytes,
            };
            _recordSource(
              source: source,
              id: id,
              uri: uri,
              bytes: lookup.entry.length,
              range: range,
              revision: revision,
              readMicros: readMicros,
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
              openMicros: readMicros,
              priority: () => acquiredPriority,
              schedulerWaitMicros: () => schedulerWaitMicros,
              schedulerMaxWaitMicros: () => schedulerMaxWaitMicros,
              schedulerAcquires: () => schedulerAcquires,
              schedulerForegroundAcquires: () =>
                  schedulerForegroundAcquires,
              schedulerPressureHolds: () =>
                  readScheduler?.foregroundPressureHoldCount ?? 0,
              readDetails: () => details,
            );
          }
        }
      } on Object catch (error) {
        _throwIfTaskCancelled(control);
        _recordCacheFailure(
          id: id,
          uri: uri,
          revision: revision,
          error: error,
          readStarted: readStarted,
        );
      }
    }

    _throwIfTaskCancelled(control);
    final fallback = _fallbackFor(uri);
    final controlledFallback = fallback is ControlledTransport;
    final openStarted = _clock?.nowMicros();
    final response = fallback is ControlledTransport
        ? await fallback.openControlled(
            uri,
            range: range,
            validators: validators,
            control: control,
          )
        : await fallback.open(
            uri,
            range: range,
            validators: validators,
          );
    if (control?.cancelled == true) {
      await response.discard();
      _throwIfTaskCancelled(control);
    }
    final openMicros = openStarted == null
        ? null
        : (_clock!.nowMicros() - openStarted).clamp(0, 1 << 62).toInt();
    final sourceClass = _originSourceClass(uri, fallback);
    final retainedResponse = id != null &&
            range == null &&
            response.statusCode == 200 &&
            response.rangeStart == 0 &&
            response.totalLength != null &&
            _isImmutableLocalSourceClass(sourceClass)
        ? _retainCompletedOrigin(
            response,
            id: id,
          )
        : response;
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
      priority: control?.priority,
      details: <String, Object?>{
        'controlledFallback': controlledFallback,
        if (id != null)
          'verifiedEquivalentCandidates': verifiedEquivalentCandidates,
        ...response.diagnostics,
      },
    );
    return _traceResponse(
      retainedResponse,
      source: 'origin',
      sourceClass: sourceClass,
      id: id,
      uri: uri,
      revision: revision,
      openMicros: openMicros,
      priority: control == null ? null : () => control.priority,
      readDetails: () => <String, Object?>{
        'controlledFallback': controlledFallback,
        if (id != null)
          'verifiedEquivalentCandidates': verifiedEquivalentCandidates,
        ...response.diagnostics,
      },
    );
  }

  ByteResponse _retainCompletedOrigin(
    ByteResponse response, {
    required DownloadId id,
  }) {
    final expectedLength = response.totalLength!;
    final builder = BytesBuilder(copy: false);
    var discarded = false;
    var completed = false;

    Stream<List<int>> bytes() async* {
      try {
        await for (final chunk in response.bytes) {
          if (!discarded) builder.add(chunk);
          yield chunk;
        }
        completed = true;
      } finally {
        if (!discarded && completed) {
          final retained = builder.takeBytes();
          if (retained.lengthInBytes == expectedLength) {
            // Composition-owned hot bytes survive Reader-session recreation.
            // This mirrors VibeVenera's ByteCache without introducing a
            // Reader/App private cache or changing durable artifact ownership.
            _cache.remember(id: id, bytes: retained, durable: true);
          }
        }
      }
    }

    return ByteResponse(
      bytes: bytes(),
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      disposition: response.disposition,
    bodyAuthority: response.bodyAuthority,
      diagnostics: response.diagnostics,
      readDiagnostics: response.readDiagnostics,
      onDiscard: () async {
        discarded = true;
        await response.discard();
      },
    );
  }

  Future<ByteResponse?> _foregroundArtifactResponse({
    required ArtifactCacheLookup lookup,
    required Uri uri,
    required ByteRange? range,
    required Validators? validators,
    required int? revision,
    required int? openMicros,
    TaskControl? control,
  }) async {
    _throwIfTaskCancelled(control);
    final id = lookup.id;
    final scheduler = _readScheduler;
    final foregroundPriority = scheduler?.foregroundPriority ?? 900;
    final requestedPriority =
        _demandPriority?.call(id) ?? control?.priority ?? 0;
    if (requestedPriority < foregroundPriority) return null;

    var schedulerWaitMicros = 0;
    var schedulerAcquires = 0;
    var schedulerForegroundAcquires = 0;
    var acquiredPriority = requestedPriority;
    ArtifactCacheReadLease? lease;
    final materializeStarted = _clock?.nowMicros();
    late final ArtifactCacheRead read;
    try {
      if (scheduler != null) {
        final wait = Stopwatch()..start();
        final acquiredLease = await scheduler.acquire(
          priority: () =>
              _demandPriority?.call(id) ?? control?.priority ?? requestedPriority,
        );
        lease = acquiredLease;
        if (control?.cancelled == true) {
          acquiredLease.release();
          lease = null;
          _throwIfTaskCancelled(control);
        }
        schedulerWaitMicros = wait.elapsedMicroseconds;
        schedulerAcquires = 1;
        schedulerForegroundAcquires = acquiredLease.foreground ? 1 : 0;
        acquiredPriority = acquiredLease.priority;
      }
      read = await _cache.readForegroundLookup(lookup);
      _throwIfTaskCancelled(control);
    } on Object catch (error) {
      lease?.release();
      _throwIfTaskCancelled(control);
      _recordForegroundReadFailure(
        id: id,
        uri: uri,
        revision: revision,
        error: error,
        materializeStarted: materializeStarted,
      );
      return null;
    }

    final bytes = read.bytes;
    final materializeMicros = materializeStarted == null
        ? null
        : (_clock!.nowMicros() - materializeStarted)
            .clamp(0, 1 << 62)
            .toInt();
    var response = _cachedResponse(
      id: id,
      bytes: bytes,
      range: range,
      validators: validators,
      foregroundStartupSegmented: !read.memoryHit,
      directMemoryBody: read.memoryHit,
      durable: read.durable,
    );
    if (response == null) {
      lease?.release();
      return null;
    }
    if (lease != null) response = _leaseBoundResponse(response, lease);

    final source = read.memoryHit
        ? 'artifact-byte-cache'
        : 'artifact-read-all';
    final details = <String, Object?>{
      'cacheTier': read.memoryHit
          ? ArtifactCacheTier.memory.name
          : lookup.tier.name,
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
      'readSchedulerLeaseThroughStream': lease != null,
      'readSchedulerPressureHolds':
          scheduler?.foregroundPressureHoldCount ?? 0,
      'deliveryMode': read.memoryHit ? 'memory-direct' : 'startup-segmented',
      if (!read.memoryHit) 'startupChunkBytes': _foregroundStartupChunkBytes,
      if (!read.memoryHit)
        'continuationChunkBytes': _foregroundContinuationChunkBytes,
      'hotCacheEntries': _cache.memoryEntryCount,
      'hotCacheBytes': _cache.memoryBytes,
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
    int Function()? schedulerPressureHolds,
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
              if (schedulerPressureHolds != null)
                'readSchedulerPressureHolds': schedulerPressureHolds(),
              if (readDetails != null) ...readDetails(),
              if (response.readDiagnostics != null)
                ...response.readDiagnostics!.snapshot(),
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
      disposition: response.disposition,
    bodyAuthority: response.bodyAuthority,
      diagnostics: response.diagnostics,
      readDiagnostics: response.readDiagnostics,
      onDiscard: response.discard,
    );
  }
}

bool _isImmutableLocalSourceClass(String sourceClass) =>
    sourceClass == 'local-document' ||
    sourceClass == 'local-file' ||
    sourceClass == 'asset';

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


void _throwIfTaskCancelled(TaskControl? control) {
  if (control?.cancelled != true) return;
  throw const Failure(
    code: ErrorCode.cancelled,
    message: 'artifact cache transport was cancelled by its scheduler owner',
  );
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

ByteResponse _leaseBoundResponse(
  ByteResponse response,
  ArtifactCacheReadLease lease,
) {
  var released = false;
  void release() {
    if (released) return;
    released = true;
    lease.release();
  }

  Stream<List<int>> bytes() async* {
    try {
      yield* response.bytes;
    } finally {
      release();
    }
  }

  return ByteResponse(
    bytes: bytes(),
    statusCode: response.statusCode,
    rangeStart: response.rangeStart,
    totalLength: response.totalLength,
    validators: response.validators,
    rangeSupported: response.rangeSupported,
    disposition: response.disposition,
    bodyAuthority: response.bodyAuthority,
    diagnostics: response.diagnostics,
    readDiagnostics: response.readDiagnostics,
    onDiscard: () async {
      try {
        await response.discard();
      } finally {
        release();
      }
    },
  );
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
    disposition: response.disposition,
    bodyAuthority: response.bodyAuthority,
    diagnostics: response.diagnostics,
    readDiagnostics: response.readDiagnostics,
    onDiscard: response.discard,
  );
}

ByteResponse? _streamedCachedResponse({
  required DownloadId id,
  required ArtifactCacheStreamEntry entry,
  required ByteRange? range,
  required Validators? validators,
  required bool durable,
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
    disposition: durable
        ? ByteResponseDisposition.durableImmutable
        : ByteResponseDisposition.staged,
    bodyAuthority: durable
        ? ByteResponseBodyAuthority.artifactCache
        : ByteResponseBodyAuthority.source,
  );
}

ByteResponse? _cachedResponse({
  required DownloadId id,
  required Uint8List bytes,
  required ByteRange? range,
  required Validators? validators,
  bool foregroundStartupSegmented = false,
  bool directMemoryBody = false,
  bool durable = true,
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
    bytes: directMemoryBody
        ? Stream<List<int>>.value(body)
        : foregroundStartupSegmented
            ? _startupSegmentedBytes(body)
            : _chunkedBytes(
                body,
                chunkSize: promotedArtifactReadChunkBytes,
              ),
    statusCode: canServeRange ? 206 : 200,
    rangeStart: start,
    totalLength: bytes.lengthInBytes,
    validators: currentValidators,
    rangeSupported: true,
    disposition: durable
        ? ByteResponseDisposition.durableImmutable
        : ByteResponseDisposition.staged,
    bodyAuthority: durable
        ? ByteResponseBodyAuthority.artifactCache
        : ByteResponseBodyAuthority.source,
  );
}

Stream<List<int>> _startupSegmentedBytes(Uint8List bytes) async* {
  if (bytes.isEmpty) return;
  final startupEnd = bytes.lengthInBytes < _foregroundStartupChunkBytes
      ? bytes.lengthInBytes
      : _foregroundStartupChunkBytes;
  yield Uint8List.sublistView(bytes, 0, startupEnd);
  for (var offset = startupEnd;
      offset < bytes.lengthInBytes;
      offset += _foregroundContinuationChunkBytes) {
    // Let source-ready listeners, decode workers and the current presentation
    // run after the codec prefix instead of blocking the Reader isolate on one
    // 5–20 MiB native ingress and artifact write.
    await Future<void>.delayed(Duration.zero);
    final end = (offset + _foregroundContinuationChunkBytes)
        .clamp(offset, bytes.lengthInBytes)
        .toInt();
    yield Uint8List.sublistView(bytes, offset, end);
  }
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
