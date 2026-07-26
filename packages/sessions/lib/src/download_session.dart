import 'package:domain/domain.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

enum DownloadState { idle, queued, receiving, sealed, promoted, failed, disposed }

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
    required this.contentKind,
    required this.demanded,
    required this.hasWriter,
    required this.activeRun,
    required this.artifact,
    this.validators = const Validators(),
    this.totalLength,
    this.failure,
  });

  final DownloadId id;
  final DownloadState state;
  final SourceEpoch epoch;
  final int committedLength;
  final ContentKind contentKind;
  final bool demanded;
  final bool hasWriter;
  final bool activeRun;
  final ArtifactSnapshot artifact;
  final Validators validators;
  final int? totalLength;
  final Failure? failure;
}

final class DownloadSession {
  DownloadSession({
    required this.id,
    required this.artifact,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'download',
  });

  final DownloadId id;
  final Artifact artifact;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;

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
  Failure? _failure;
  List<int> _prefix = <int>[];

  DownloadState get state => _state;
  SourceEpoch get epoch => _epoch;
  int get committedLength => artifact.committedLength;
  Validators get validators => _validators;
  int? get totalLength => _totalLength;
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
        contentKind: _contentKind,
        demanded: _demanded,
        hasWriter: hasWriter,
        activeRun: activeRun,
        artifact: artifact.snapshot,
        validators: _validators,
        totalLength: _totalLength,
        failure: _failure,
      );

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
    _prefix = await artifact.readPrefix(sniffPrefixLength);
    _contentKind = sniffContent(
      _prefix,
      finalChunk: restored.state == ArtifactState.promoted,
    );

    if (restored.state == ArtifactState.promoted) {
      _state = DownloadState.promoted;
      return snapshot;
    }

    if (restored.committedLength > 0) {
      var validMeta = false;
      try {
        final meta = await artifact.readMeta();
        if (meta != null && meta['downloadKey'] == id.key) {
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

    _state = DownloadState.idle;
    _failure = null;
    return snapshot;
  }

  void queue() {
    _requireState(<DownloadState>{DownloadState.idle, DownloadState.failed});
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
      'version': 1,
      'downloadKey': id.key,
      'uri': id.canonicalUri.toString(),
      'sourceRevision': id.sourceRevision,
      'validators': validators.toJson(),
      if (totalLength != null) 'totalLength': totalLength,
    });
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
    if (artifact.state != ArtifactState.partial || !artifact.hasOpenWriter) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'artifact is not open for partial writes',
      );
    }
    final lease = WriterLease._(id: ++_writerSeq, epoch: _epoch);
    _writer = lease;
    _state = DownloadState.receiving;
    _failure = null;
    _emit(TraceEventKind.downloadState, <String, Object?>{'state': _state.name});
    return lease;
  }

  Future<void> append(WriterLease lease, int offset, List<int> bytes) async {
    _requireWriter(lease);
    await artifact.append(offset, bytes);
    if (_prefix.length < sniffPrefixLength && bytes.isNotEmpty) {
      final remaining = sniffPrefixLength - _prefix.length;
      _prefix.addAll(bytes.take(remaining));
      _contentKind = sniffContent(_prefix);
    }
    _emit(
      TraceEventKind.bytesCommitted,
      <String, Object?>{
        'bytes': bytes.length,
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
  }

  void attach() => _demanded = true;

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
    _validators = const Validators();
    _totalLength = null;
    _contentKind = ContentKind.unknown;
    _prefix = <int>[];
    _failure = null;
    await _restartArtifact();
    _state = DownloadState.idle;
  }

  Future<void> evict() async {
    _requireNotDisposed();
    if (!canEvict) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot evict while a writer is active',
      );
    }
    await artifact.deleteAll();
    _state = DownloadState.idle;
    _validators = const Validators();
    _totalLength = null;
    _contentKind = ContentKind.unknown;
    _prefix = <int>[];
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
    await artifact.dispose();
    _state = DownloadState.disposed;
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
  }
}
