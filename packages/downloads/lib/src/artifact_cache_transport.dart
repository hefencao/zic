import 'dart:async';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'artifact_bytes.dart';
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
  final Set<DownloadId> _persistentReadBypass = <DownloadId>{};

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
    final persistentReadBypassed =
        id != null && _persistentReadBypass.contains(id);
    if (id != null && !persistentReadBypassed) {
      final readStarted = _clock?.nowMicros();
      try {
        var lookup = await _lookupCache(id, control);
        _throwIfTaskCancelled(control);
        final readMicros = readStarted == null
            ? null
            : (_clock!.nowMicros() - readStarted)
                .clamp(0, 1 << 62)
                .toInt();
        if (lookup != null) {
          // Only an already-resident memory artifact may take the foreground
          // materialization path. Persistent artifacts must stay lazy: their
          // first Reader chunk comes directly from ArtifactCacheStreamEntry.open
          // instead of waiting for readAll()/full-body collection first.
          final foregroundMemoryCandidate =
              lookup.tier == ArtifactCacheTier.memory;
          final foregroundResponse = foregroundMemoryCandidate
              ? await _foregroundArtifactResponse(
                  lookup: lookup,
                  uri: uri,
                  range: range,
                  validators: validators,
                  revision: revision,
                  openMicros: readMicros,
                  control: control,
                )
              : null;
          if (foregroundResponse != null) return foregroundResponse;

          final foregroundPriority =
              _readScheduler?.foregroundPriority ?? 900;
          final requestedPriority =
              _demandPriority?.call(id) ?? control?.priority ?? 0;
          if (foregroundMemoryCandidate &&
              requestedPriority >= foregroundPriority) {
            // A stale memory-generation read can fail after the initial lookup.
            // Refresh only that attempted memory binding. Persistent lookups
            // were not consumed yet and must not be reopened before streaming.
            lookup = await _lookupCache(id, control);
            _throwIfTaskCancelled(control);
          }
          if (lookup != null) {
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
                    control: control,
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
              'artifactIntegrityBasis': lookup.entry.streamIntegrity.name,
              'artifactWholeChecksumVerifiedThisRead':
                  lookup.entry.streamIntegrity ==
                      ArtifactReadIntegrityBasis.crc32Verified,
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
            final storageId = lookup.storageId;
            final observedResponse = lookup.tier == ArtifactCacheTier.persistent
                ? _observePersistentReadFailure(
                    response,
                    onFailure: (error, _) {
                      if (error is! ArtifactReadFailure) return;
                      _persistentReadBypass.add(id);
                      if (_shouldInvalidateFailedReplica(error.kind)) {
                        unawaited(
                          _cache.invalidate(storageId).catchError(
                                (Object _, StackTrace _) {},
                              ),
                        );
                      }
                    },
                  )
                : response;
            return _traceResponse(
              observedResponse,
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
    final selfBoundedFallback = fallback is SelfBoundedOpenTransport &&
        fallback.selfBoundsOpen(uri);
    if (selfBoundedFallback && control is OpenPhaseReportingTaskControl) {
      control.markOpenSelfBounded();
    }
    final openStarted = _clock?.nowMicros();
    final pendingResponse = fallback is ControlledTransport
        ? fallback.openControlled(
            uri,
            range: range,
            validators: validators,
            control: control,
          )
        : fallback.open(
            uri,
            range: range,
            validators: validators,
          );
    final response = await _awaitResponseWithControl(
      pendingResponse,
      control,
    );
    if (control?.cancelled == true) {
      await response.discard(control: control);
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
        if (persistentReadBypassed) 'persistentReadBypassed': true,
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
    final generation = _cache.generationFor(id);
    final builder = BytesBuilder(copy: false);
    var discarded = false;
    var completed = false;

    Stream<List<int>> retainedBytes() async* {
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
            // Historical contract: _cache.remember(id: id, bytes: retained, durable: true)
            // This mirrors VibeVenera's ByteCache without introducing a
            // Reader/App private cache or changing durable artifact ownership.
            _cache.remember(
              id: id,
              bytes: retained,
              // This is only a composition-memory retention. The local source
              // response has not been committed to the persistent artifact
              // backend, so it must not masquerade as durable provenance.
              generation: generation,
            );
          }
        }
      }
    }

    return ByteResponse(
      bytes: _cancelAwareBody(
        retainedBytes(),
        onDone: () {},
        onAborted: () {
          discarded = true;
          _discardUnawaited(response);
        },
      ),
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
      diagnostics: response.diagnostics,
      readDiagnostics: response.readDiagnostics,
      onDiscardControlled: ({TaskControl? control}) async {
        discarded = true;
        await response.discard(control: control);
      },
    );
  }

  Future<ArtifactCacheLookup?> _lookupCache(
    DownloadId id,
    TaskControl? control,
  ) async {
    if (control == null) {
      final lookup = await _cache.lookup(id);
      return lookup;
    }
    return _cache.lookup(id, control: control);
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
          control: control,
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
      read = await _cache.readForegroundLookup(
        lookup,
        control: control,
      );
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
      'artifactIntegrityBasis': read.integrityBasis.name,
      'artifactWholeChecksumVerifiedThisRead':
          read.integrityBasis == ArtifactReadIntegrityBasis.crc32Verified,
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

  bool _shouldInvalidateFailedReplica(ArtifactReadFailureKind kind) =>
      kind == ArtifactReadFailureKind.missing ||
      kind == ArtifactReadFailureKind.staleLocator ||
      kind == ArtifactReadFailureKind.shortRead ||
      kind == ArtifactReadFailureKind.lengthChanged;

  ByteResponse _observePersistentReadFailure(
    ByteResponse response, {
    required void Function(Object error, int bytesEmitted) onFailure,
  }) {
    var bytesEmitted = 0;
    Stream<List<int>> body() async* {
      try {
        await for (final chunk in response.bytes) {
          bytesEmitted += chunk.length;
          yield chunk;
        }
      } on Object catch (error) {
        onFailure(error, bytesEmitted);
        rethrow;
      }
    }

    return ByteResponse(
      bytes: body(),
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
      diagnostics: response.diagnostics,
      readDiagnostics: response.readDiagnostics,
      onDiscardControlled: response.discard,
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
    var consumerAborted = false;
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
              'completed': completed && !consumerAborted,
              if (failure != null) 'failure': failure.toString(),
              'consumer': 'session-copy',
            },
          ),
        );
      }
    }

    return ByteResponse(
      bytes: _cancelAwareBody(
        tracedBytes(),
        onDone: () {},
        onAborted: () {
          consumerAborted = true;
          _discardUnawaited(response);
        },
      ),
      statusCode: response.statusCode,
      rangeStart: response.rangeStart,
      totalLength: response.totalLength,
      validators: response.validators,
      rangeSupported: response.rangeSupported,
      disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
      diagnostics: response.diagnostics,
      readDiagnostics: response.readDiagnostics,
      onDiscardControlled: response.discard,
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


void _discardUnawaited(ByteResponse response) {
  try {
    unawaited(
      response.discard().then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  } on Object {
    // Discard is best-effort from a stream cancellation callback.
  }
}

void _cancelUnawaited(StreamSubscription<List<int>>? subscription) {
  if (subscription == null) return;
  try {
    unawaited(
      subscription.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  } on Object {
    // The source body is already being torn down by the caller.
  }
}

Stream<List<int>> _cancelAwareBody(
  Stream<List<int>> source, {
  required void Function() onDone,
  required void Function() onAborted,
}) {
  late final StreamController<List<int>> controller;
  StreamSubscription<List<int>>? sourceSubscription;
  var terminated = false;
  var cancelled = false;

  void abort() {
    if (terminated) return;
    terminated = true;
    onAborted();
  }

  controller = StreamController<List<int>>(
    sync: true,
    onListen: () {
      try {
        sourceSubscription = source.listen(
          (chunk) {
            if (!cancelled) controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (cancelled) return;
            abort();
            controller.addError(error, stackTrace);
            unawaited(controller.close());
          },
          onDone: () {
            if (cancelled) return;
            if (!terminated) {
              terminated = true;
              onDone();
            }
            unawaited(controller.close());
          },
          cancelOnError: true,
        );
      } on Object catch (error, stackTrace) {
        if (cancelled) return;
        abort();
        controller.addError(error, stackTrace);
        unawaited(controller.close());
      }
    },
    onPause: () => sourceSubscription?.pause(),
    onResume: () => sourceSubscription?.resume(),
    onCancel: () {
      cancelled = true;
      _cancelUnawaited(sourceSubscription);
      abort();
    },
  );
  return controller.stream;
}

final class _BodyTaskControl implements TaskControl {
  _BodyTaskControl({required this.prioritySource, this.parent});

  final int Function() prioritySource;
  final TaskControl? parent;
  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get cancelled => _cancelled.isCompleted || parent?.cancelled == true;

  @override
  Future<void> get whenCancelled {
    final parent = this.parent;
    if (parent == null) return _cancelled.future;
    return Future.any<void>(<Future<void>>[
      _cancelled.future,
      parent.whenCancelled,
    ]);
  }

  @override
  int get priority => prioritySource();

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

void _throwIfTaskCancelled(TaskControl? control) {
  if (control?.cancelled != true) return;
  throw const Failure(
    code: ErrorCode.cancelled,
    message: 'artifact cache transport was cancelled by its scheduler owner',
  );
}

Future<ByteResponse> _awaitResponseWithControl(
  Future<ByteResponse> pending,
  TaskControl? control,
) async {
  if (control == null) return pending;
  _throwIfTaskCancelled(control);
  try {
    return await Future.any<ByteResponse>(<Future<ByteResponse>>[
      pending,
      control.whenCancelled.then<ByteResponse>((_) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'artifact cache transport was cancelled while opening',
        );
      }),
    ]);
  } catch (error, stackTrace) {
    if (control.cancelled) {
      // An uncontrolled fallback may still hand back a response after this
      // caller has left. Consume and discard that late body rather than
      // leaking its transport lease.
      unawaited(
        pending.then<void>(
          (response) async {
            try {
              await response.discard(control: control);
            } on Object {
              // The cancellation result remains authoritative.
            }
          },
          onError: (Object _, StackTrace __) {},
        ),
      );
      _throwIfTaskCancelled(control);
    }
    throw Error.throwWithStackTrace(error, stackTrace);
  }
}

Future<bool> _moveNextCancellable(
  StreamIterator<List<int>> iterator,
  TaskControl? control,
) async {
  if (control == null) return iterator.moveNext();
  _throwIfTaskCancelled(control);
  try {
    return await Future.any<bool>(<Future<bool>>[
      iterator.moveNext(),
      control.whenCancelled.then<bool>((_) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message:
              'artifact cache transport was cancelled by its scheduler owner',
        );
      }),
    ]);
  } catch (error, stackTrace) {
    if (control.cancelled) _throwIfTaskCancelled(control);
    throw Error.throwWithStackTrace(error, stackTrace);
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

  return ByteResponse(
    bytes: _cancelAwareBody(
      response.bytes,
      onDone: release,
      onAborted: () {
        _discardUnawaited(response);
        release();
      },
    ),
    statusCode: response.statusCode,
    rangeStart: response.rangeStart,
    totalLength: response.totalLength,
    validators: response.validators,
    rangeSupported: response.rangeSupported,
    disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
    diagnostics: response.diagnostics,
    readDiagnostics: response.readDiagnostics,
    onDiscardControlled: ({TaskControl? control}) async {
      try {
        await response.discard(control: control);
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
  TaskControl? control,
  required void Function(int waitMicros, int priority) onAcquired,
}) {
  final bodyControl = _BodyTaskControl(
    prioritySource: priority,
    parent: control,
  );

  Stream<List<int>> scheduledBytes() async* {
    final iterator = StreamIterator<List<int>>(response.bytes);
    ArtifactCacheReadLease? lease;
    var completed = false;
    try {
      while (true) {
        var activeLease = lease;
        Stopwatch? wait;
        if (activeLease == null) {
          wait = Stopwatch()..start();
          activeLease = control == null && bodyControl.parent == null
              ? await scheduler.acquire(priority: priority)
              : await scheduler.acquire(
                  priority: priority,
                  control: bodyControl,
                );
          lease = activeLease;
        }
        final available = await _moveNextCancellable(
          iterator,
          bodyControl,
        );
        if (!available) {
          completed = true;
          activeLease.release();
          lease = null;
          return;
        }
        if (wait != null) {
          onAcquired(wait.elapsedMicroseconds, activeLease.priority);
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
      try {
        await iterator.cancel();
      } finally {
        if (!completed) {
          _discardUnawaited(response);
        }
      }
    }
  }

  return ByteResponse(
    bytes: _cancelAwareBody(
      scheduledBytes(),
      onDone: () {},
      onAborted: () {
        bodyControl.cancel();
        _discardUnawaited(response);
      },
    ),
    statusCode: response.statusCode,
    rangeStart: response.rangeStart,
    totalLength: response.totalLength,
    validators: response.validators,
    rangeSupported: response.rangeSupported,
    disposition: response.disposition,
      bodyAuthority: response.bodyAuthority,
      flowControl: response.flowControl,
    diagnostics: response.diagnostics,
    readDiagnostics: response.readDiagnostics,
    onDiscardControlled: ({TaskControl? control}) async {
      bodyControl.cancel();
      await response.discard(control: control);
    },
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
  final start = canServeRange ? range.start : 0;
  final requestedEnd = canServeRange ? range.end : null;
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
  final start = canServeRange ? range.start : 0;
  final requestedEnd = canServeRange ? range.end : null;
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
