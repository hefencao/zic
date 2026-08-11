import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'download_ingress_projection.dart';
import 'source_progress.dart';

enum DownloadState { idle, queued, receiving, sealed, promoted, failed, disposed }

typedef DownloadSnapshotListener = void Function(DownloadSnapshot snapshot);

final class RunLease {
  const RunLease._(this.id);

  final int id;
}

final class DownloadDemandLease {
  DownloadDemandLease._(this._session, this.scopeId);

  DownloadSession? _session;
  final String scopeId;

  bool get attached => _session != null;

  void updatePriority(int priority) {
    final session = _session;
    if (session == null) return;
    session._setDemandPriority(scopeId, priority);
  }

  void detach() {
    final session = _session;
    if (session == null) return;
    _session = null;
    session._detachDemand(scopeId);
  }
}

final class WriterLease {
  const WriterLease._({required this.id, required this.epoch});

  final int id;
  final SourceEpoch epoch;

  @override
  String toString() => 'WriterLease($id, $epoch)';
}

final class DownloadSnapshot {
  const DownloadSnapshot({
    required this.id,
    required this.state,
    required this.epoch,
    required this.committedLength,
    required this.networkStartLength,
    required this.contentKind,
    required this.demanded,
    this.demandCount = 0,
    this.effectivePriority = 0,
    required this.hasWriter,
    required this.activeRun,
    required this.artifact,
    this.validators = const Validators(),
    this.totalLength,
    this.failure,
    this.ingressProjectionCount = 0,
  });

  final DownloadId id;
  final DownloadState state;
  final SourceEpoch epoch;
  final int committedLength;
  final int networkStartLength;
  final ContentKind contentKind;
  final bool demanded;
  final int demandCount;
  final int effectivePriority;
  final bool hasWriter;
  final bool activeRun;
  final ArtifactSnapshot artifact;
  final Validators validators;
  final int? totalLength;
  final Failure? failure;
  final int ingressProjectionCount;
}

final class DownloadSession {
  DownloadSession({
    required this.id,
    required this.artifact,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'download',
    this.index,
    bool initiallyDemanded = true,
  }) : _legacyDemanded = initiallyDemanded;

  final DownloadId id;
  final Artifact artifact;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final CacheIndex? index;

  DownloadState _state = DownloadState.idle;
  SourceEpoch _epoch = const SourceEpoch(0);
  WriterLease? _writer;
  RunLease? _run;
  int _writerSeq = 0;
  int _runSeq = 0;
  bool _legacyDemanded;
  final Map<String, int> _demandPriorities = <String, int>{};
  ContentKind _contentKind = ContentKind.unknown;
  Validators _validators = const Validators();
  int? _totalLength;
  int _networkStartLength = 0;
  int? _residentLength;
  bool _residentCacheBacked = false;
  String? _residentSource;
  Failure? _failure;
  List<int> _prefix = <int>[];
  int _pendingCommitTraceBytes = 0;
  int _pendingCommitTraceChunks = 0;
  int _pendingNativeIngressMicros = 0;
  int _pendingArtifactWriteMicros = 0;
  int _pendingMaxNativeIngressMicros = 0;
  int _pendingMaxArtifactWriteMicros = 0;
  final Map<String, DownloadIngressProjection> _ingressProjections =
      <String, DownloadIngressProjection>{};
  int _ingressProjectionRevision = 0;
  final Set<DownloadSnapshotListener> _snapshotListeners =
      <DownloadSnapshotListener>{};

  DownloadState get state => _state;
  SourceEpoch get epoch => _epoch;
  int get committedLength => _residentLength ?? artifact.committedLength;
  bool get residentCacheBacked => _residentCacheBacked;
  Validators get validators => _validators;
  int? get totalLength => _totalLength;
  int get networkStartLength => _networkStartLength;
  ContentKind get contentKind => _contentKind;
  bool get hasWriter => _writer != null;
  bool get demanded => _legacyDemanded || _demandPriorities.isNotEmpty;
  int get demandCount => _demandPriorities.length + (_legacyDemanded ? 1 : 0);
  int get effectivePriority {
    if (_demandPriorities.isEmpty) return 0;
    return _demandPriorities.values.reduce((left, right) =>
        left >= right ? left : right);
  }
  bool get activeRun => _run != null;
  bool get canEvict =>
      _writer == null && _run == null && _state != DownloadState.disposed;

  DownloadSnapshot get snapshot => DownloadSnapshot(
        id: id,
        state: _state,
        epoch: _epoch,
        committedLength: committedLength,
        networkStartLength: _networkStartLength,
        contentKind: _contentKind,
        demanded: demanded,
        demandCount: demandCount,
        effectivePriority: effectivePriority,
        hasWriter: hasWriter,
        activeRun: activeRun,
        artifact: artifact.snapshot,
        validators: _validators,
        totalLength: _totalLength,
        failure: _failure,
        ingressProjectionCount: _ingressProjections.length,
      );

  void addSnapshotListener(
    DownloadSnapshotListener listener, {
    bool fireImmediately = true,
  }) {
    _requireNotDisposed();
    _snapshotListeners.add(listener);
    if (fireImmediately) {
      try {
        listener(snapshot);
      } on Object {
        // Application observers must not break the authoritative session.
      }
    }
  }

  void removeSnapshotListener(DownloadSnapshotListener listener) {
    _snapshotListeners.remove(listener);
  }

  RunLease beginRun() {
    _requireNotDisposed();
    if (_run != null) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download already has an active transport run',
      );
    }
    final lease = RunLease._(++_runSeq);
    _run = lease;
    _notifySnapshot();
    return lease;
  }

  void endRun(RunLease lease) {
    if (!identical(_run, lease)) {
      throw const Failure(
        code: ErrorCode.staleRun,
        message: 'run lease is no longer authoritative',
      );
    }
    _run = null;
    _notifySnapshot();
  }

  Future<DownloadSnapshot> restore({
    bool verifyPromotedChecksum = true,
  }) async {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    _residentLength = null;
    _residentCacheBacked = false;
    _residentSource = null;
    if (_writer != null) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot restore while a writer is active',
      );
    }
    final restored = await artifact.restore(
      verifyPromotedChecksum: verifyPromotedChecksum,
    );
    _prefix = List<int>.of(
      await artifact.readPrefix(sniffPrefixLength),
      growable: true,
    );
    _contentKind = sniffContent(
      _prefix,
      finalChunk: restored.state == ArtifactState.promoted,
    );

    _networkStartLength = restored.committedLength;

    if (restored.state == ArtifactState.promoted) {
      await _restoreIngressIfNeeded(sealed: true);
      _state = DownloadState.promoted;
      await _syncCache(CacheState.ready);
      _notifySnapshot();
      return snapshot;
    }

    if (restored.committedLength > 0) {
      var validMeta = false;
      var wrongOwner = false;
      try {
        final meta = await artifact.readMeta();
        if (meta != null) {
          if (_metaMatches(meta)) {
            final rawValidators = meta['validators'];
            final rawLength = meta['totalLength'];
            if (rawValidators is Map &&
                (rawLength == null || rawLength is int)) {
              _validators = Validators.fromJson(
                Map<String, Object?>.from(rawValidators),
              );
              _totalLength = rawLength as int?;
              validMeta = true;
            }
          } else {
            wrongOwner = _metaExplicitlyClaimsDifferentOwner(meta);
          }
        }
      } on Failure catch (error) {
        if (error.code != ErrorCode.artifactCorruption) {
          rethrow;
        }
      } on FormatException {
        // Broken resume metadata does not prove that committed media bytes are
        // corrupt. Preserve the playable prefix and rebuild network knowledge.
      }
      if (!validMeta) {
        _validators = const Validators();
        _totalLength = null;
        if (wrongOwner) {
          await _restartArtifact();
          _prefix = <int>[];
          _contentKind = ContentKind.unknown;
        }
      }
    }

    await _restoreIngressIfNeeded(sealed: false);
    _state = DownloadState.idle;
    _failure = null;
    await _syncCache(CacheState.partial);
    _notifySnapshot();
    return snapshot;
  }

  void queue() {
    _requireState(<DownloadState>{DownloadState.idle, DownloadState.failed});
    _networkStartLength = committedLength;
    _state = DownloadState.queued;
    _emit(TraceEventKind.downloadState, <String, Object?>{'state': _state.name});
  }

  Future<void> bindResponse({
    required Validators validators,
    int? totalLength,
  }) async {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    _validators = validators;
    _totalLength = totalLength;
    _expectIngressLength(totalLength);
    await artifact.writeMeta(<String, Object?>{
      'version': 2,
      'downloadKey': id.key,
      'download': id.toJson(),
      'uri': id.canonicalUri.toString(),
      'sourceRevision': id.sourceRevision,
      'validators': validators.toJson(),
      if (totalLength != null) 'totalLength': totalLength,
    });
    await _syncCache(CacheState.partial);
    _notifySnapshot();
  }

  void beginDurableCachedIngress({
    required Validators validators,
    required int totalLength,
    String residentSource = 'durable-cache',
  }) {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    _requireState(<DownloadState>{
      DownloadState.idle,
      DownloadState.queued,
      DownloadState.failed,
    });
    if (totalLength <= 0) {
      throw ArgumentError.value(
        totalLength,
        'totalLength',
        'durable cache sources must contain image bytes',
      );
    }
    _residentCacheBacked = true;
    _residentSource = residentSource;
    _residentLength = 0;
    _validators = validators;
    _totalLength = totalLength;
    _networkStartLength = 0;
    _prefix = <int>[];
    _contentKind = ContentKind.unknown;
    _failure = null;
    _resetIngressProjections(_epoch);
    _expectIngressLength(totalLength);
    _state = DownloadState.receiving;
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{
        'state': _state.name,
        'cacheResident': true,
        'residentSource': _residentSource,
      },
    );
  }

  void appendDurableCachedIngress(int offset, List<int> bytes) {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    if (!_residentCacheBacked || _state != DownloadState.receiving) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'session is not receiving a durable cache source',
      );
    }
    if (offset != (_residentLength ?? 0)) {
      throw Failure(
        code: ErrorCode.invalidOffset,
        message: 'expected resident offset ${_residentLength ?? 0}, got $offset',
      );
    }
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final ingressStarted = clock.nowMicros();
    _appendIngress(_epoch, offset, chunk);
    final nativeIngressMicros =
        (clock.nowMicros() - ingressStarted).clamp(0, 1 << 62).toInt();
    _residentLength = offset + chunk.length;
    _recordIngressTiming(
      nativeIngressMicros: nativeIngressMicros,
      artifactWriteMicros: 0,
    );
    if (_prefix.length < sniffPrefixLength && chunk.isNotEmpty) {
      final remaining = sniffPrefixLength - _prefix.length;
      _prefix.addAll(chunk.take(remaining));
      _contentKind = sniffContent(_prefix);
    }
    _recordCommittedChunk(chunk.length);
  }

  DownloadSnapshot sealDurableCachedIngress() {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    if (!_residentCacheBacked || _state != DownloadState.receiving) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'session is not receiving a durable cache source',
      );
    }
    final expected = _totalLength;
    if (expected != null && expected != committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'durable cache length $committedLength does not match $expected',
      );
    }
    _sealIngressProjections(_epoch);
    _contentKind = sniffContent(_prefix, finalChunk: true);
    if (committedLength <= 0 || _contentKind == ContentKind.unknown) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'durable cache source has no recognizable image body',
      );
    }
    _state = DownloadState.promoted;
    _flushCommittedTrace();
    _emit(TraceEventKind.artifactPromoted, <String, Object?>{
      'length': committedLength,
      'cacheResident': true,
      'residentSource': _residentSource,
    });
    return snapshot;
  }

  WriterLease acquireWriter() {
    _requireNotDisposed();
    if (_writer != null) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'download already has an active writer',
      );
    }
    _requireState(<DownloadState>{
      DownloadState.idle,
      DownloadState.queued,
      DownloadState.failed,
    });
    if (artifact.state != ArtifactState.partial) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'artifact is not ready for partial writes',
      );
    }
    final lease = WriterLease._(id: ++_writerSeq, epoch: _epoch);
    _networkStartLength = committedLength;
    _writer = lease;
    _state = DownloadState.receiving;
    _failure = null;
    _emit(TraceEventKind.downloadState, <String, Object?>{'state': _state.name});
    return lease;
  }

  Future<void> append(WriterLease lease, int offset, List<int> bytes) async {
    _requireWriter(lease);
    _ingressProjectionRevision++;
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final artifactStarted = clock.nowMicros();
    final artifactWrite = artifact.appendOwned(offset, chunk);
    final ingressStarted = clock.nowMicros();
    _appendIngress(lease.epoch, offset, chunk);
    final nativeIngressMicros =
        (clock.nowMicros() - ingressStarted).clamp(0, 1 << 62).toInt();
    await artifactWrite;
    final artifactWriteMicros =
        (clock.nowMicros() - artifactStarted).clamp(0, 1 << 62).toInt();
    _recordIngressTiming(
      nativeIngressMicros: nativeIngressMicros,
      artifactWriteMicros: artifactWriteMicros,
    );
    if (_prefix.length < sniffPrefixLength && chunk.isNotEmpty) {
      final remaining = sniffPrefixLength - _prefix.length;
      _prefix.addAll(chunk.take(remaining));
      _contentKind = sniffContent(_prefix);
    }
    _recordCommittedChunk(chunk.length);
  }

  Future<DownloadSnapshot> seal(
    WriterLease lease, {
    int? expectedLength,
    String? expectedChecksum,
  }) async {
    _requireWriter(lease);
    _ingressProjectionRevision++;
    final sealed = await artifact.seal(
      expectedLength: expectedLength,
      expectedChecksum: expectedChecksum,
    );
    _sealIngressProjections(lease.epoch);
    _writer = null;
    _state = DownloadState.sealed;
    _contentKind = sniffContent(_prefix, finalChunk: true);
    _flushCommittedTrace();
    _emit(
      TraceEventKind.artifactSealed,
      <String, Object?>{
        'length': sealed.committedLength,
        'checksum': sealed.checksum,
        'kind': _contentKind.name,
      },
    );
    await _syncCache(CacheState.partial);
    return snapshot;
  }

  Future<DownloadSnapshot> promote() async {
    _requireState(<DownloadState>{DownloadState.sealed});
    _ingressProjectionRevision++;
    final promoted = await artifact.promote();
    _state = DownloadState.promoted;
    _emit(
      TraceEventKind.artifactPromoted,
      <String, Object?>{
        'path': promoted.finalPath,
        'length': promoted.committedLength,
      },
    );
    await _syncCache(CacheState.ready);
    return snapshot;
  }

  /// Pauses an authoritative partial writer without converting the partial
  /// into a failure or a promoted artifact.
  ///
  /// Durable Reader-session handoff uses this after importing an existing
  /// partial into the long-lived artifact owner. Network scheduling remains
  /// outside this primitive.
  Future<DownloadSnapshot> pause(WriterLease lease) async {
    _requireWriter(lease);
    try {
      await artifact.pause();
    } finally {
      _writer = null;
      _state = DownloadState.idle;
      _failure = null;
    }
    _flushCommittedTrace();
    await _syncCache(CacheState.partial);
    _notifySnapshot();
    return snapshot;
  }

  Future<void> fail(WriterLease lease, Object error) async {
    _requireWriter(lease);
    try {
      await artifact.pause();
    } finally {
      _writer = null;
      _state = DownloadState.failed;
      _failure = error is Failure
          ? error
          : Failure(code: ErrorCode.network, message: '$error', cause: error);
    }
    _flushCommittedTrace();
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'error': '$_failure'},
    );
    await _syncCache(CacheState.partial);
  }

  /// Legacy single-consumer demand used by direct DownloadJob callers.
  /// Reader/prefetch/download composition should use [attachDemand] instead.
  void attach() {
    if (_legacyDemanded) {
      return;
    }
    _legacyDemanded = true;
    _notifySnapshot();
  }

  DownloadDemandLease attachDemand({
    required String scopeId,
    required int priority,
  }) {
    _requireNotDisposed();
    if (scopeId.isEmpty) {
      throw ArgumentError.value(scopeId, 'scopeId', 'must not be empty');
    }
    _setDemandPriority(scopeId, priority);
    return DownloadDemandLease._(this, scopeId);
  }

  void _setDemandPriority(String scopeId, int priority) {
    _requireNotDisposed();
    if (priority < 0) {
      throw ArgumentError.value(priority, 'priority', 'must not be negative');
    }
    final previous = _demandPriorities[scopeId];
    if (previous == priority) return;
    _demandPriorities[scopeId] = priority;
    _emit(
      TraceEventKind.demandApplied,
      <String, Object?>{
        'lane': 'download',
        'scopeId': scopeId,
        'priority': priority,
        'effectivePriority': effectivePriority,
        'demandCount': demandCount,
      },
    );
    _notifySnapshot();
  }

  void _detachDemand(String scopeId) {
    if (_demandPriorities.remove(scopeId) == null) return;
    _flushCommittedTrace();
    _emit(
      TraceEventKind.demandDetached,
      <String, Object?>{
        'lane': 'download',
        'scopeId': scopeId,
        'effectivePriority': effectivePriority,
        'demandCount': demandCount,
        'receivingRetained': _state == DownloadState.receiving,
      },
    );
    _notifySnapshot();
  }

  void deferNetwork({required String reason}) {
    _requireNotDisposed();
    _requireState(<DownloadState>{DownloadState.queued});
    _flushCommittedTrace();
    _state = DownloadState.idle;
    _failure = null;
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{
        'state': _state.name,
        'deferred': true,
        'reason': reason,
        'committedLength': committedLength,
      },
    );
    _notifySnapshot();
  }

  void recordResume({
    required bool restarted,
    String? strategy,
    bool playablePrefixPreserved = false,
    Map<String, Object?> diagnostics = const <String, Object?>{},
  }) {
    _emit(
      restarted
          ? TraceEventKind.resumeRestarted
          : TraceEventKind.resumeAccepted,
      <String, Object?>{
        'committedLength': committedLength,
        if (strategy != null) 'strategy': strategy,
        if (playablePrefixPreserved)
          'playablePrefixPreserved': true,
        ...diagnostics,
      },
    );
  }

  void detach() {
    if (!_legacyDemanded) return;
    _flushCommittedTrace();
    _legacyDemanded = false;
    _emit(
      TraceEventKind.demandDetached,
      <String, Object?>{
        'lane': 'download',
        'scopeId': 'legacy',
        'effectivePriority': effectivePriority,
        'demandCount': demandCount,
        'receivingRetained': _state == DownloadState.receiving,
      },
    );
    _notifySnapshot();
  }

  Future<void> reset() async {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    _flushCommittedTrace();
    _writer = null;
    _epoch = _epoch.next();
    _resetIngressProjections(_epoch);
    _validators = const Validators();
    _totalLength = null;
    _networkStartLength = 0;
    _residentLength = null;
    _residentCacheBacked = false;
    _residentSource = null;
    _contentKind = ContentKind.unknown;
    _prefix = <int>[];
    _failure = null;
    await _restartArtifact();
    _state = DownloadState.idle;
    await index?.remove(id.key);
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'reset': true},
    );
  }

  Future<int> evict() async {
    _requireNotDisposed();
    _ingressProjectionRevision++;
    _flushCommittedTrace();
    if (!canEvict) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot evict while a writer is active',
      );
    }
    final released = artifact.committedLength;
    _epoch = _epoch.next();
    _resetIngressProjections(_epoch);
    await artifact.deleteAll();
    _state = DownloadState.idle;
    _validators = const Validators();
    _totalLength = null;
    _networkStartLength = 0;
    _residentLength = null;
    _residentCacheBacked = false;
    _residentSource = null;
    _contentKind = ContentKind.unknown;
    _prefix = <int>[];
    await index?.remove(id.key);
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'evictedBytes': released},
    );
    return released;
  }

  Future<void> dispose() async {
    if (_state == DownloadState.disposed) {
      return;
    }
    _flushCommittedTrace();
    if (_writer != null || _run != null) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'cannot dispose while work is active',
      );
    }
    _ingressProjections.clear();
    _demandPriorities.clear();
    _legacyDemanded = false;
    await artifact.dispose();
    _state = DownloadState.disposed;
    _notifySnapshot();
    _snapshotListeners.clear();
  }

  void _recordIngressTiming({
    required int nativeIngressMicros,
    required int artifactWriteMicros,
  }) {
    _pendingNativeIngressMicros += nativeIngressMicros;
    _pendingArtifactWriteMicros += artifactWriteMicros;
    if (nativeIngressMicros > _pendingMaxNativeIngressMicros) {
      _pendingMaxNativeIngressMicros = nativeIngressMicros;
    }
    if (artifactWriteMicros > _pendingMaxArtifactWriteMicros) {
      _pendingMaxArtifactWriteMicros = artifactWriteMicros;
    }
  }

  void _recordCommittedChunk(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _pendingCommitTraceBytes += bytes;
    _pendingCommitTraceChunks++;
    if (_pendingCommitTraceBytes >= sourceProgressQuantumBytes) {
      _flushCommittedTrace();
    }
  }

  void _flushCommittedTrace() {
    if (_pendingCommitTraceBytes == 0) {
      return;
    }
    _emit(
      TraceEventKind.bytesCommitted,
      <String, Object?>{
        'bytes': _pendingCommitTraceBytes,
        'chunks': _pendingCommitTraceChunks,
        'committedLength': committedLength,
        'kind': _contentKind.name,
        'cacheResident': _residentCacheBacked,
        if (_residentSource != null) 'residentSource': _residentSource,
        'nativeIngressMicros': _pendingNativeIngressMicros,
        'artifactWriteMicros': _pendingArtifactWriteMicros,
        'maxNativeIngressMicros': _pendingMaxNativeIngressMicros,
        'maxArtifactWriteMicros': _pendingMaxArtifactWriteMicros,
      },
    );
    _pendingCommitTraceBytes = 0;
    _pendingCommitTraceChunks = 0;
    _pendingNativeIngressMicros = 0;
    _pendingArtifactWriteMicros = 0;
    _pendingMaxNativeIngressMicros = 0;
    _pendingMaxArtifactWriteMicros = 0;
  }

  void attachIngressProjection(DownloadIngressProjection projection) {
    _requireNotDisposed();
    final existing = _ingressProjections[projection.scopeId];
    if (existing != null && !identical(existing, projection)) {
      throw ArgumentError.value(
        projection.scopeId,
        'projection.scopeId',
        'already attached to another ingress projection',
      );
    }
    if (identical(existing, projection)) return;
    if (committedLength != 0) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'late ingress projection requires synchronized attachment',
      );
    }
    _ingressProjections[projection.scopeId] = projection;
    projection.expectLength(_totalLength);
    _notifySnapshot();
  }

  /// Atomically joins a late Reader-local ingress projection to this physical
  /// transfer at an authoritative committed boundary.
  ///
  /// The projection stays outside the live fan-out while replay is in flight.
  /// Any append/reset/seal/bind that starts during replay advances
  /// [_ingressProjectionRevision], forcing another bounded replay. The final
  /// state check and map insertion contain no await, so a writer cannot slip a
  /// chunk between the verified boundary and attachment on the Dart isolate.
  Future<void> attachSynchronizedIngressProjection(
    DownloadIngressProjection projection,
  ) async {
    _requireNotDisposed();
    final existing = _ingressProjections[projection.scopeId];
    if (existing != null && !identical(existing, projection)) {
      throw ArgumentError.value(
        projection.scopeId,
        'projection.scopeId',
        'already attached to another ingress projection',
      );
    }
    if (identical(existing, projection)) return;

    while (true) {
      _requireNotDisposed();
      final revision = _ingressProjectionRevision;
      final epoch = _epoch;
      final targetLength = committedLength;
      final totalLength = _totalLength;
      final sealed = _state == DownloadState.sealed ||
          _state == DownloadState.promoted;
      projection.expectLength(totalLength);
      final before = projection.snapshot;
      await projection.rebuild(
        epoch: epoch,
        chunks: artifact.readChunks(endExclusive: targetLength),
        sealed: sealed,
      );
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);

      final stillSealed = _state == DownloadState.sealed ||
          _state == DownloadState.promoted;
      if (_ingressProjectionRevision != revision ||
          _epoch != epoch ||
          committedLength != targetLength ||
          _totalLength != totalLength ||
          stillSealed != sealed) {
        continue;
      }

      // No await after the state check: later physical mutations see this
      // projection in the live fan-out before they can append/reset/seal it.
      _ingressProjections[projection.scopeId] = projection;
      _notifySnapshot();
      return;
    }
  }

  bool detachIngressProjection(String scopeId) {
    final removed = _ingressProjections.remove(scopeId);
    if (removed == null) return false;
    _notifySnapshot();
    return true;
  }

  Future<void> _restoreIngressIfNeeded({required bool sealed}) async {
    for (final projection in _ingressProjections.values) {
      final current = projection.snapshot;
      final expectedLength = artifact.committedLength;
      final alreadyAuthoritative =
          current.epoch == _epoch &&
          current.length == expectedLength &&
          current.kind == _contentKind &&
          current.sealed == sealed &&
          current.failure == null;
      if (alreadyAuthoritative) continue;
      await _rebuildIngressProjection(projection, sealed: sealed);
    }
  }

  Future<void> _rebuildIngressProjection(
    DownloadIngressProjection projection, {
    required bool sealed,
  }) async {
    final before = projection.snapshot;
    await projection.rebuild(
      epoch: _epoch,
      chunks: artifact.readChunks(),
      sealed: sealed,
    );
    _traceIngressProjection(projection.scopeId, before, projection.snapshot);
  }

  void _expectIngressLength(int? length) {
    for (final projection in _ingressProjections.values) {
      projection.expectLength(length);
    }
  }

  void _resetIngressProjections(SourceEpoch epoch) {
    for (final projection in _ingressProjections.values) {
      final before = projection.snapshot;
      projection.reset(epoch);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
    }
  }

  void _sealIngressProjections(SourceEpoch epoch) {
    for (final projection in _ingressProjections.values) {
      final before = projection.snapshot;
      projection.seal(epoch);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
    }
  }

  void _appendIngress(SourceEpoch epoch, int offset, List<int> bytes) {
    for (final projection in _ingressProjections.values) {
      final before = projection.snapshot;
      projection.append(epoch: epoch, offset: offset, bytes: bytes);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
    }
  }

  void _traceIngressProjection(
    String scopeId,
    IngressSnap before,
    IngressSnap after,
  ) {
    final sourceBecameReady = !before.sourceReady && after.sourceReady;
    if (sourceBecameReady) {
      _emit(
        TraceEventKind.sourceReady,
        <String, Object?>{
          'kind': after.kind.name,
          'length': after.length,
          'projectionScope': scopeId,
        },
      );
    }
    if (before.failure == null && after.failure != null) {
      _emit(
        TraceEventKind.sourceDisabled,
        <String, Object?>{
          'kind': after.kind.name,
          'length': after.length,
          'error': '${after.failure}',
          'projectionScope': scopeId,
        },
      );
    }
  }

  bool _metaMatches(Map<String, Object?> meta) {
    if (meta['downloadKey'] == id.key) {
      return true;
    }
    final raw = meta['download'];
    if (raw is! Map) {
      return false;
    }
    try {
      return DownloadId.fromJson(Map<String, Object?>.from(raw)) == id;
    } on Object {
      return false;
    }
  }

  bool _metaExplicitlyClaimsDifferentOwner(Map<String, Object?> meta) {
    final key = meta['downloadKey'];
    if (key is String) {
      return key != id.key;
    }
    final raw = meta['download'];
    if (raw is! Map) {
      return false;
    }
    try {
      return DownloadId.fromJson(Map<String, Object?>.from(raw)) != id;
    } on Object {
      // Malformed network metadata is not proof that the media bytes belong to
      // another DownloadId. Preserve the authoritative partial.
      return false;
    }
  }

  Future<void> _syncCache(CacheState state) async {
    final cache = index;
    if (cache == null ||
        artifact.state == ArtifactState.empty ||
        (state == CacheState.partial && artifact.committedLength == 0)) {
      return;
    }
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final existing = await cache.get(id.key);
    await cache.put(
      CacheRec(
        id: id,
        state: state,
        path: state == CacheState.ready
            ? artifact.finalPath
            : artifact.partialPath,
        bytes: artifact.committedLength,
        checksum: artifact.checksum,
        createdUs: existing?.createdUs ?? now,
        touchedUs: now,
      ),
    );
  }

  Future<void> _restartArtifact() async {
    await artifact.reset();
    await artifact.restore();
  }

  void _requireWriter(WriterLease lease) {
    _requireNotDisposed();
    try {
      _epoch.requireMatch(lease.epoch);
    } on Failure {
      _emit(
        TraceEventKind.staleWorkRejected,
        <String, Object?>{'writerId': lease.id},
      );
      rethrow;
    }
    if (!identical(_writer, lease)) {
      _emit(
        TraceEventKind.writerRejected,
        <String, Object?>{'writerId': lease.id},
      );
      throw const Failure(
        code: ErrorCode.staleWriter,
        message: 'writer lease is no longer authoritative',
      );
    }
  }

  void _requireState(Set<DownloadState> expected) {
    _requireNotDisposed();
    if (!expected.contains(_state)) {
      throw Failure(
        code: ErrorCode.invalidState,
        message: 'download state ${_state.name} is not allowed here',
      );
    }
  }

  void _requireNotDisposed() {
    if (_state == DownloadState.disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'download session is disposed',
      );
    }
  }

  void _emit(TraceEventKind kind, Map<String, Object?> payload) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: id.key,
        epoch: _epoch.value,
        payload: payload,
      ),
    );
    _notifySnapshot();
  }

  void _notifySnapshot() {
    if (_snapshotListeners.isEmpty) {
      return;
    }
    final current = snapshot;
    for (final listener in List<DownloadSnapshotListener>.of(
      _snapshotListeners,
    )) {
      try {
        listener(current);
      } on Object {
        // Application observers must not break the authoritative session.
      }
    }
  }
}
