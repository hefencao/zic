import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

enum DownloadState { idle, queued, receiving, sealed, promoted, failed, disposed }

typedef SourceListener = void Function(IngressSnap snapshot);
typedef DownloadSnapshotListener = void Function(DownloadSnapshot snapshot);

final class RunLease {
  const RunLease._(this.id);

  final int id;
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
    required this.hasWriter,
    required this.activeRun,
    required this.artifact,
    this.validators = const Validators(),
    this.totalLength,
    this.failure,
    this.ingress,
  });

  final DownloadId id;
  final DownloadState state;
  final SourceEpoch epoch;
  final int committedLength;
  final int networkStartLength;
  final ContentKind contentKind;
  final bool demanded;
  final bool hasWriter;
  final bool activeRun;
  final ArtifactSnapshot artifact;
  final Validators validators;
  final int? totalLength;
  final Failure? failure;
  final IngressSnap? ingress;
}

final class DownloadSession {
  DownloadSession({
    required this.id,
    required this.artifact,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'download',
    this.index,
    this.ingress,
  });

  final DownloadId id;
  final Artifact artifact;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final CacheIndex? index;
  final Ingress? ingress;

  DownloadState _state = DownloadState.idle;
  SourceEpoch _epoch = const SourceEpoch(0);
  WriterLease? _writer;
  RunLease? _run;
  int _writerSeq = 0;
  int _runSeq = 0;
  bool _demanded = true;
  ContentKind _contentKind = ContentKind.unknown;
  Validators _validators = const Validators();
  int? _totalLength;
  int _networkStartLength = 0;
  Failure? _failure;
  List<int> _prefix = <int>[];
  final Set<SourceListener> _sourceListeners = <SourceListener>{};
  final Set<DownloadSnapshotListener> _snapshotListeners =
      <DownloadSnapshotListener>{};

  DownloadState get state => _state;
  SourceEpoch get epoch => _epoch;
  int get committedLength => artifact.committedLength;
  Validators get validators => _validators;
  int? get totalLength => _totalLength;
  int get networkStartLength => _networkStartLength;
  ContentKind get contentKind => _contentKind;
  bool get hasWriter => _writer != null;
  bool get demanded => _demanded;
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
        demanded: _demanded,
        hasWriter: hasWriter,
        activeRun: activeRun,
        artifact: artifact.snapshot,
        validators: _validators,
        totalLength: _totalLength,
        failure: _failure,
        ingress: ingress?.snapshot,
      );

  void addSourceListener(
    SourceListener listener, {
    bool fireImmediately = true,
  }) {
    _requireNotDisposed();
    _sourceListeners.add(listener);
    final current = ingress?.snapshot;
    if (fireImmediately &&
        current != null &&
        (current.sourceReady || current.failure != null)) {
      try {
        listener(current);
      } on Object catch (error) {
        _emit(
          TraceEventKind.taskFailed,
          <String, Object?>{
            'lane': 'source-listener',
            'error': '$error',
          },
        );
      }
    }
  }

  void removeSourceListener(SourceListener listener) {
    _sourceListeners.remove(listener);
  }

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

  Future<DownloadSnapshot> restore() async {
    _requireNotDisposed();
    if (_writer != null) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot restore while a writer is active',
      );
    }
    final restored = await artifact.restore();
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
      await _rebuildIngress(sealed: true);
      _state = DownloadState.promoted;
      await _syncCache(CacheState.ready);
      _notifySnapshot();
      return snapshot;
    }

    if (restored.committedLength > 0) {
      var validMeta = false;
      try {
        final meta = await artifact.readMeta();
        if (meta != null && _metaMatches(meta)) {
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
        }
      } on Failure catch (error) {
        if (error.code != ErrorCode.artifactCorruption) {
          rethrow;
        }
      } on FormatException {
        // Invalid validators make the partial unsafe to resume.
      }
      if (!validMeta) {
        await _restartArtifact();
        _prefix = <int>[];
        _contentKind = ContentKind.unknown;
        _validators = const Validators();
        _totalLength = null;
      }
    }

    await _rebuildIngress(sealed: false);
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
    _validators = validators;
    _totalLength = totalLength;
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
    final chunk = List<int>.of(bytes, growable: false);
    await artifact.append(offset, chunk);
    _appendIngress(lease.epoch, offset, chunk);
    if (_prefix.length < sniffPrefixLength && chunk.isNotEmpty) {
      final remaining = sniffPrefixLength - _prefix.length;
      _prefix.addAll(chunk.take(remaining));
      _contentKind = sniffContent(_prefix);
    }
    _emit(
      TraceEventKind.bytesCommitted,
      <String, Object?>{
        'bytes': chunk.length,
        'committedLength': committedLength,
        'kind': _contentKind.name,
      },
    );
  }

  Future<DownloadSnapshot> seal(
    WriterLease lease, {
    int? expectedLength,
    String? expectedChecksum,
  }) async {
    _requireWriter(lease);
    final sealed = await artifact.seal(
      expectedLength: expectedLength,
      expectedChecksum: expectedChecksum,
    );
    final targetIngress = ingress;
    if (targetIngress != null) {
      final before = targetIngress.snapshot;
      targetIngress.seal(lease.epoch);
      _traceIngress(before, targetIngress.snapshot);
    }
    _writer = null;
    _state = DownloadState.sealed;
    _contentKind = sniffContent(_prefix, finalChunk: true);
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
    _emit(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'error': '$_failure'},
    );
    await _syncCache(CacheState.partial);
  }

  void attach() {
    if (_demanded) {
      return;
    }
    _demanded = true;
    _notifySnapshot();
  }

  void recordResume({required bool restarted}) {
    _emit(
      restarted
          ? TraceEventKind.resumeRestarted
          : TraceEventKind.resumeAccepted,
      <String, Object?>{'committedLength': committedLength},
    );
  }

  void detach() {
    _demanded = false;
    _emit(
      TraceEventKind.demandDetached,
      <String, Object?>{
        'lane': 'download',
        'receivingRetained': _state == DownloadState.receiving,
      },
    );
  }

  Future<void> reset() async {
    _requireNotDisposed();
    _writer = null;
    _epoch = _epoch.next();
    ingress?.reset(_epoch);
    _validators = const Validators();
    _totalLength = null;
    _networkStartLength = 0;
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
    if (!canEvict) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot evict while a writer is active',
      );
    }
    final released = artifact.committedLength;
    _epoch = _epoch.next();
    ingress?.reset(_epoch);
    await artifact.deleteAll();
    _state = DownloadState.idle;
    _validators = const Validators();
    _totalLength = null;
    _networkStartLength = 0;
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
    if (_writer != null || _run != null) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'cannot dispose while work is active',
      );
    }
    _sourceListeners.clear();
    ingress?.dispose();
    await artifact.dispose();
    _state = DownloadState.disposed;
    _notifySnapshot();
    _snapshotListeners.clear();
  }

  Future<void> _rebuildIngress({required bool sealed}) async {
    final target = ingress;
    if (target == null) {
      return;
    }
    final before = target.snapshot;
    await target.rebuild(
      epoch: _epoch,
      chunks: artifact.readChunks(),
      sealed: sealed,
    );
    _traceIngress(before, target.snapshot);
  }

  void _appendIngress(SourceEpoch epoch, int offset, List<int> bytes) {
    final target = ingress;
    if (target == null) {
      return;
    }
    final before = target.snapshot;
    target.append(epoch: epoch, offset: offset, bytes: bytes);
    _traceIngress(before, target.snapshot);
  }

  void _traceIngress(IngressSnap before, IngressSnap after) {
    final sourceBecameReady = !before.sourceReady && after.sourceReady;
    if (sourceBecameReady) {
      _emit(
        TraceEventKind.sourceReady,
        <String, Object?>{
          'kind': after.kind.name,
          'length': after.length,
        },
      );
    }
    final sourceChanged =
        (after.sourceReady || after.failure != null) &&
        (sourceBecameReady ||
            before.revision != after.revision ||
            before.length != after.length ||
            before.sealed != after.sealed ||
            before.kind != after.kind ||
            before.failure != after.failure);
    if (sourceChanged) {
      for (final listener in List<SourceListener>.of(_sourceListeners)) {
        try {
          listener(after);
        } on Object catch (error) {
          _emit(
            TraceEventKind.taskFailed,
            <String, Object?>{
              'lane': 'source-listener',
              'error': '$error',
            },
          );
        }
      }
    }
    if (before.failure == null && after.failure != null) {
      _emit(
        TraceEventKind.sourceDisabled,
        <String, Object?>{
          'kind': after.kind.name,
          'length': after.length,
          'error': '${after.failure}',
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
