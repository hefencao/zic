import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:storage/storage.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'download_ingress_projection.dart';
import 'source_progress.dart';
import 'webp_decode_prefix_hints.dart';

enum DownloadState { idle, queued, receiving, sealed, promoted, failed, disposed }

bool _isStaleSessionLifecycleFailure(Object error) =>
    error is Failure &&
    (error.code == ErrorCode.staleEpoch ||
        error.code == ErrorCode.staleWriter ||
        error.code == ErrorCode.staleRun);

const int _sourceMetadataPrefixLength = 64;

typedef DownloadSnapshotListener = void Function(DownloadSnapshot snapshot);
typedef DownloadCommittedProgressListener = void Function(int committedLength);

/// Resident-body replay capability already bound to one physical generation.
///
/// Physical DownloadSession owns transfer state, but promoted resident-cache
/// sessions intentionally do not duplicate immutable cache bytes into the
/// session artifact. Prefix reads and late Reader joins therefore receive this
/// bound capability instead of inferring resident bytes from [Artifact].
typedef DownloadResidentReplayChunks = Future<Stream<List<int>>> Function(
  int endExclusive,
);

/// Composition/runtime resident-body replay service before it is bound to one
/// concrete physical DownloadSession generation.
///
/// Cross-owner services may receive the session explicitly. Once the call
/// enters a concrete DownloadSession, callers must bind this service into a
/// [DownloadResidentReplayChunks] capability so session methods never accept
/// themselves again as a callback argument.
typedef DownloadResidentReplaySource = Future<Stream<List<int>>> Function(
  DownloadSession session,
  int endExclusive,
);

typedef DownloadResidentReplayChunksWithControl =
    Future<Stream<List<int>>> Function(
  int endExclusive, {
  required TaskControl control,
});
typedef DownloadResidentReplaySourceWithControl =
    Future<Stream<List<int>>> Function(
  DownloadSession session,
  int endExclusive, {
  required TaskControl control,
});

/// Resident replay over one exact encoded byte range. This is used by
/// Reader-local on-demand hydration so a durable immutable body does not need
/// to be recopied from byte zero whenever decode asks for a larger prefix.
typedef DownloadResidentReplayRangeSource = Future<Stream<List<int>>> Function(
  DownloadSession session,
  int start,
  int endExclusive,
);
typedef DownloadResidentReplayRangeSourceWithControl =
    Future<Stream<List<int>>> Function(
  DownloadSession session,
  int start,
  int endExclusive, {
  required TaskControl control,
});

/// Exact-range replay capability already bound to one immutable physical body
/// generation. The capability is invalidated together with resident authority
/// on reset/rebind; callers still own scheduling/cancellation around the stream.
typedef DownloadResidentReplayRangeChunks = Future<Stream<List<int>>> Function(
  int start,
  int endExclusive,
);
typedef DownloadResidentReplayRangeClose = Future<void> Function();

/// Reader-local replay of the mutable encoded body currently owned by this
/// physical DownloadSession. Production composition binds this capability to
/// its shared local-read scheduler so hot partial replay and durable READY
/// replay compete in one I/O priority domain.
typedef DownloadArtifactReplayRangeChunksWithControl =
    Future<Stream<List<int>>> Function(
  int start,
  int endExclusive, {
  required int chunkSize,
  required TaskControl control,
});
typedef DownloadArtifactReplayRangeSourceWithControl =
    Future<Stream<List<int>>> Function(
  DownloadSession session,
  int start,
  int endExclusive, {
  required int chunkSize,
  required TaskControl control,
});

Stream<List<int>> _replayChunks(
  Stream<List<int>> chunks, {
  TaskControl? control,
}) async* {
  if (control == null) {
    yield* chunks;
    return;
  }
  final iterator = StreamIterator<List<int>>(chunks);
  try {
    while (await _moveNextReplayChunk(iterator, control)) {
      control.throwIfCancelled();
      yield iterator.current;
    }
  } finally {
    // Cancellation is a best-effort transport/ingress cleanup boundary. Do
    // not let a stream subscription's late close error mask the authoritative
    // stale-epoch or cancellation result from the replay itself.
    try {
      await iterator.cancel();
    } on Object {
      // The projection/owner will surface the original replay failure.
    }
  }
}

Future<bool> _moveNextReplayChunk(
  StreamIterator<List<int>> iterator,
  TaskControl control,
) async {
  control.throwIfCancelled();
  try {
    return await Future.any<bool>(<Future<bool>>[
      iterator.moveNext(),
      control.whenCancelled.then<bool>((_) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'Reader ingress replay was cancelled',
        );
      }),
    ]);
  } catch (error, stackTrace) {
    if (control.cancelled) control.throwIfCancelled();
    throw Error.throwWithStackTrace(error, stackTrace);
  }
}

final class RunLease {
  const RunLease._(this.id, this.epoch);

  final int id;
  final SourceEpoch epoch;
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
    this.physicalId,
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
    this.networkAttemptSequence = 0,
    this.networkAttemptActive = false,
    this.networkAttemptTotalLength,
    this.networkCursorLength = 0,
    this.localEncodedTotalLengthHint,
    this.sourceCanvasWidth,
    this.sourceCanvasHeight,
  });

  final DownloadId id;
  final PhysicalMediaId? physicalId;
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

  /// Monotonic identifier for the currently observed physical network attempt.
  ///
  /// This is transient telemetry/projection state only. It must never
  /// participate in resume, durable identity, aliasing or scheduler rank.
  final int networkAttemptSequence;
  final bool networkAttemptActive;

  /// Full object length reported by the current transport attempt, when known.
  ///
  /// This is transient projection metadata only. It may differ from [totalLength]
  /// until a restarted full-body response has verified the preserved partial; it
  /// must never authorize resume, sealing, promotion or durable cache mutation.
  final int? networkAttemptTotalLength;

  /// Absolute byte position consumed by the current transport attempt.
  ///
  /// Unlike [committedLength], this may restart behind an existing playable
  /// partial when a server ignores Range and the task must re-read the prefix.
  final int networkCursorLength;

  /// Encoded full-body length declared by bytes already available locally.
  ///
  /// Currently this is populated from a valid RIFF/WebP header when durable
  /// response metadata does not already carry a total. It is projection-only
  /// metadata: it must never authorize resume, sealing, promotion or cache
  /// mutation.
  final int? localEncodedTotalLengthHint;

  /// Source-container canvas dimensions derived from the authoritative ingress
  /// prefix for this physical generation. These are source metadata, not
  /// decoder target/output raster dimensions.
  final int? sourceCanvasWidth;
  final int? sourceCanvasHeight;

  bool get hasSourceCanvas =>
      sourceCanvasWidth != null && sourceCanvasHeight != null;
}

/// Durable cache-mutation owner for a DownloadSession whose mutable backing
/// has been borrowed from another package-level owner.
///
/// Ordinary standalone sessions may continue to mutate their injected
/// [CacheIndex] directly. Once a persistent store lends one of its partial
/// bodies to a composition transfer session, however, writes to that store's
/// index must re-enter the store's serialization domain instead of creating a
/// second independent mutation tail inside the session.
abstract interface class DownloadCacheMutationOwner {
  Future<void> syncDownloadCache(
    DownloadSession session,
    CacheState state, {
    required SourceEpoch expectedEpoch,
    int? committedLength,
  });

  Future<bool> beginDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  });

  Future<void> commitDownloadCachePromotion(
    DownloadSession session, {
    required SourceEpoch expectedEpoch,
  });

  Future<void> abortDownloadCachePromotion(DownloadSession session);

  Future<void> clearDownloadCache(
    DownloadSession session, {
    required bool removeCacheRecord,
    required bool deleteFinalArtifact,
  });
}

final class DownloadSession {
  DownloadSession({
    required this.id,
    PhysicalMediaId? physicalId,
    required Artifact artifact,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'download',
    String? traceIdentityHash,
    CacheIndex? index,
    DownloadCacheMutationOwner? cacheMutationOwner,
    String storageRootId = 'default',
    bool initiallyDemanded = true,
  })  : physicalId = physicalId ?? PhysicalMediaId.exact(id),
        _artifact = artifact,
        _index = index,
        _cacheMutationOwner = cacheMutationOwner,
        _physicalPartialIndex = index is PhysicalPartialIndex
            ? index as PhysicalPartialIndex
            : null,
        _storageRootId = storageRootId,
        _traceIdentityHash = traceIdentityHash ?? id.key,
        _legacyDemanded = initiallyDemanded;

  /// Compatibility/exact provider anchor for this physical generation.
  /// Physical ownership is [physicalId]; transport opens use the active claim's
  /// exact DownloadId rather than assuming this anchor is the provider.
  final DownloadId id;
  final PhysicalMediaId physicalId;
  Artifact _artifact;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;
  final String _traceIdentityHash;
  CacheIndex? _index;
  PhysicalPartialIndex? _physicalPartialIndex;
  DownloadCacheMutationOwner? _cacheMutationOwner;
  String _storageRootId;
  void Function()? _borrowedBackingRelease;
  bool _borrowedBackingCanBecomeDurableFinal = false;

  Artifact get artifact => _artifact;
  CacheIndex? get index => _index;
  String get storageRootId => _storageRootId;
  bool get hasBorrowedPartialBacking => _borrowedBackingRelease != null;
  bool get hasBorrowedDurableSpool =>
      _borrowedBackingRelease != null && _borrowedBackingCanBecomeDurableFinal;

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
  Uri? _validatorRequestUri;
  int? _totalLength;
  int _networkStartLength = 0;
  int _networkAttemptSequence = 0;
  bool _networkAttemptActive = false;
  int? _networkAttemptTotalLength;
  int _networkCursorLength = 0;
  int _networkCursorPublishedLength = 0;
  int? _residentLength;
  bool _residentBodyBacked = false;
  bool _residentIngressDeferred = false;
  ByteResponseBodyAuthority? _residentBodyAuthority;
  DownloadResidentReplayRangeChunks? _residentReplayRangeChunks;
  DownloadResidentReplayRangeClose? _residentReplayRangeClose;
  Object? _residentReplayGenerationToken;
  Object? _residentReplayCacheKey;
  String _residentReplayAccessMode = 'unknown';
  Future<void> _residentReplayCloseTail = Future<void>.value();
  Failure? _failure;

  // Decoder-owned playable-prefix evidence projected onto this physical
  // generation solely for speculative transport flow control. Transport ANMF
  // framing is only structural progress and must not independently authorize
  // suspension before this floor. Reader-local replay must derive availability
  // from its own source/decoder lifecycle instead of consuming this evidence.
  int _firstPlayablePrefixBytes = 0;
  int _firstFrameRequiredPrefixBytes = 0;
  int _decodedPrefixFrames = 0;
  int _networkFlowSatisfiedFrames = 0;
  int _networkFlowProofLength = 0;

  List<int> _prefix = <int>[];
  int? _sourceCanvasWidth;
  int? _sourceCanvasHeight;
  int _pendingCommitTraceBytes = 0;
  int _pendingCommitTraceChunks = 0;
  int _pendingNativeIngressMicros = 0;
  int _pendingArtifactWriteMicros = 0;
  int _pendingMaxNativeIngressMicros = 0;
  int _pendingMaxArtifactWriteMicros = 0;
  final Map<String, DownloadIngressProjection> _ingressProjections =
      <String, DownloadIngressProjection>{};
  final Map<String, Object> _pendingIngressAttachments = <String, Object>{};
  int _ingressProjectionRevision = 0;
  Future<void> _cacheMutationTail = Future<void>.value();
  bool _resetting = false;
  bool _disposing = false;
  bool _restoring = false;
  final Set<DownloadSnapshotListener> _snapshotListeners =
      <DownloadSnapshotListener>{};
  final Set<DownloadCommittedProgressListener> _committedProgressListeners =
      <DownloadCommittedProgressListener>{};

  DownloadState get state => _state;
  SourceEpoch get epoch => _epoch;
  int get committedLength => _residentLength ?? artifact.committedLength;
  bool get residentBodyBacked => _residentBodyBacked;
  bool get residentIngressDeferred =>
      _residentBodyBacked && _residentIngressDeferred;

  ByteResponseBodyAuthority? get residentBodyAuthority =>
      _residentBodyBacked ? _residentBodyAuthority : null;

  DownloadResidentReplayRangeChunks? get residentReplayRangeChunks =>
      residentIngressDeferred ? _residentReplayRangeChunks : null;

  /// Opaque identity for the currently bound immutable resident-body
  /// generation. Composition-owned accelerators may key derived replay bytes
  /// by this token, but the token carries no body authority of its own. A
  /// sealed durable generation may supply a stable opaque acceleration key so
  /// re-created sessions for the same immutable bytes can reuse that prefix;
  /// otherwise each resident bind receives a fresh session-local token.
  Object? get residentReplayGenerationToken => residentIngressDeferred
      ? (_residentReplayCacheKey ?? _residentReplayGenerationToken)
      : null;

  String get residentReplayAccessMode =>
      residentIngressDeferred ? _residentReplayAccessMode : 'unknown';

  /// Compatibility/diagnostic label; behavior must use [residentBodyAuthority].
  String? get residentSource => switch (residentBodyAuthority) {
        ByteResponseBodyAuthority.artifactCache => 'durable-artifact-cache',
        ByteResponseBodyAuthority.source => 'reopenable-immutable-source',
        null => null,
      };
  /// Last validators observed from a transport response. Network resume logic
  /// MUST use [resumeValidatorsFor] so validators cannot cross provider URIs
  /// when a physical session is shared by verified-equivalent exact requests.
  Validators get validators => _validators;
  Uri? get validatorRequestUri =>
      _validators.isEmpty ? null : _validatorRequestUri;

  Validators resumeValidatorsFor(Uri requestUri) {
    if (_validators.isEmpty || _validatorRequestUri != requestUri) {
      return const Validators();
    }
    return _validators;
  }

  bool hasValidatorsForOtherRequest(Uri requestUri) =>
      _validators.canResume && _validatorRequestUri != requestUri;

  int? get totalLength => _totalLength;
  int get networkStartLength => _networkStartLength;
  int get networkAttemptSequence => _networkAttemptSequence;
  bool get networkAttemptActive => _networkAttemptActive;
  int? get networkAttemptTotalLength => _networkAttemptTotalLength;
  int get networkCursorLength => _networkCursorLength;
  int? get localEncodedTotalLengthHint {
    if (_prefix.length < 12 ||
        _prefix[0] != 0x52 ||
        _prefix[1] != 0x49 ||
        _prefix[2] != 0x46 ||
        _prefix[3] != 0x46 ||
        _prefix[8] != 0x57 ||
        _prefix[9] != 0x45 ||
        _prefix[10] != 0x42 ||
        _prefix[11] != 0x50) {
      return null;
    }
    final riffPayloadLength = _prefix[4] |
        (_prefix[5] << 8) |
        (_prefix[6] << 16) |
        (_prefix[7] << 24);
    final declaredTotal = riffPayloadLength + 8;
    if (declaredTotal < 20 || declaredTotal < committedLength) {
      return null;
    }
    return declaredTotal;
  }
  ContentKind get contentKind => _contentKind;
  int get firstPlayablePrefixBytes => _firstPlayablePrefixBytes;
  int get firstFrameRequiredPrefixBytes => _firstFrameRequiredPrefixBytes;
  int get decodedPrefixFrames => _decodedPrefixFrames;
  int get networkFlowSatisfiedFrames => _networkFlowSatisfiedFrames;
  int get networkFlowProofLength => _networkFlowProofLength;

  /// Minimum authoritative prefix that may satisfy speculative transport flow.
  /// Decoder success is strongest; before success, a decoder need-more-data
  /// lower bound raises the unresolved fallback. This is transport-only state:
  /// Reader-local ingress startup must not use it as a replay watermark.
  int transportFlowPlayableFloorBytes({required int unresolvedFloorBytes}) {
    if (_firstPlayablePrefixBytes > 0) {
      return _firstPlayablePrefixBytes;
    }
    var floor = unresolvedFloorBytes;
    if (_prefix.isNotEmpty) {
      final estimated = estimateWebpPlayablePrefixBytes(
        Uint8List.fromList(_prefix),
        totalLength: _totalLength ?? committedLength,
        minQuantum: unresolvedFloorBytes,
      );
      if (estimated > floor) {
        floor = estimated;
      }
    }
    if (_firstFrameRequiredPrefixBytes > floor) {
      return _firstFrameRequiredPrefixBytes;
    }
    return floor;
  }

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
      _writer == null &&
      _run == null &&
      !_resetting &&
      !_disposing &&
      !_restoring &&
      _pendingIngressAttachments.isEmpty &&
      _state != DownloadState.disposed;

  DownloadSnapshot get snapshot => DownloadSnapshot(
        id: id,
        physicalId: physicalId,
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
        networkAttemptSequence: _networkAttemptSequence,
        networkAttemptActive: _networkAttemptActive,
        networkAttemptTotalLength: _networkAttemptTotalLength,
        networkCursorLength: _networkCursorLength,
        localEncodedTotalLengthHint: localEncodedTotalLengthHint,
        sourceCanvasWidth: _sourceCanvasWidth,
        sourceCanvasHeight: _sourceCanvasHeight,
      );

  void addSnapshotListener(
    DownloadSnapshotListener listener, {
    bool fireImmediately = true,
  }) {
    // Observation is independent of restore/reset/disposing. In particular,
    // the composition owner may attach a terminal-state waiter while local
    // preparation is restoring the session. Only a disposed session can no
    // longer publish a meaningful snapshot.
    if (_state == DownloadState.disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'download session is disposed',
      );
    }
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

  /// Observes only successful physical byte commits. Unlike snapshot
  /// listeners this signal does not publish scheduler/UI state and therefore
  /// can be used by the physical durability owner without turning every
  /// transport chunk into a broad DownloadSnapshot invalidation.
  void addCommittedProgressListener(DownloadCommittedProgressListener listener) {
    _requireNotDisposed();
    _committedProgressListeners.add(listener);
  }

  void removeCommittedProgressListener(
    DownloadCommittedProgressListener listener,
  ) {
    _committedProgressListeners.remove(listener);
  }

  RunLease beginRun() {
    _requireNotDisposed();
    if (_run != null ||
        _resetting ||
        _disposing ||
        _restoring) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download already has an active transport run',
      );
    }
    final lease = RunLease._(++_runSeq, _epoch);
    _run = lease;
    _notifySnapshot();
    return lease;
  }

  /// Returns whether [lease] still owns the current physical generation.
  ///
  /// A reset may intentionally leave the old run registered until its
  /// transport finally exits, so checking only [activeRun] is insufficient:
  /// an old open could otherwise acquire a writer in the freshly reset
  /// generation and repopulate a session that the caller explicitly cleared.
  bool isCurrentRun(RunLease lease) =>
      identical(_run, lease) && _epoch == lease.epoch;

  void requireRun(RunLease lease) {
    if (isCurrentRun(lease)) return;
    throw const Failure(
      code: ErrorCode.staleRun,
      message: 'run lease is no longer authoritative for this generation',
    );
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

  /// Rebinds this still-empty physical session to one verified direct partial
  /// while preserving session identity, demand leases and Reader ingress.
  ///
  /// The backing is exclusive until [dispose] invokes the release callback.
  /// Ordinary durable adoption also transfers exact-cache index ownership so a
  /// later promotion may become the durable final in place. [transferStaging]
  /// keeps exact-cache ownership with the persistent store instead: only the
  /// physical-partial index follows the mutable backing while network Range
  /// append continues. Promotion of such staging must therefore be handed off
  /// through the normal promoted-artifact owner before it becomes durable.
  Future<DownloadSnapshot> adoptDurablePartialBacking({
    required Artifact artifact,
    required CacheIndex index,
    DownloadCacheMutationOwner? cacheMutationOwner,
    required String storageRootId,
    required int expectedLength,
    required Validators validators,
    required int? totalLength,
    required void Function() releaseBacking,
    bool transferStaging = false,
    TaskControl? control,
  }) async {
    _requireNotDisposed();
    control?.throwIfCancelled();
    if (_borrowedBackingRelease != null ||
        committedLength != 0 ||
        _writer != null ||
        _run != null ||
        _resetting ||
        _disposing ||
        _restoring ||
        _pendingIngressAttachments.isNotEmpty ||
        (_state != DownloadState.idle && _state != DownloadState.failed)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'durable partial adoption requires an idle empty session',
      );
    }
    final epoch = _epoch;
    _restoring = true;
    var backingCommitted = false;
    try {
      final adopted = await artifact.adoptExistingPartial(
        expectedLength: expectedLength,
      );
      _requireEpoch(epoch);
      control?.throwIfCancelled();
      final restoredPrefix =
          await artifact.readPrefix(_sourceMetadataPrefixLength);
      _requireEpoch(epoch);
      control?.throwIfCancelled();

      final previousArtifact = _artifact;
      _artifact = artifact;
      if (!transferStaging) {
        _index = index;
      }
      _physicalPartialIndex = index is PhysicalPartialIndex
          ? index as PhysicalPartialIndex
          : _physicalPartialIndex;
      _storageRootId = storageRootId;
      _borrowedBackingRelease = releaseBacking;
      _borrowedBackingCanBecomeDurableFinal = !transferStaging;
      backingCommitted = true;
      await previousArtifact.dispose();

      _ingressProjectionRevision++;
      _residentLength = null;
      _residentBodyBacked = false;
      _residentIngressDeferred = false;
      _residentBodyAuthority = null;
      _dropResidentReplayRangeCapability();
      await _residentReplayCloseTail;
      _validators = validators;
      _validatorRequestUri =
          validators.isEmpty ? null : id.canonicalUri;
      _totalLength = totalLength;
      _networkStartLength = adopted.committedLength;
      _networkAttemptActive = false;
      _networkAttemptTotalLength = null;
      // A durable local prefix is committed transfer state, not evidence that
      // the next transport attempt already consumed those bytes. Keep the
      // transient transport cursor at its reset value until DownloadJob starts
      // a real provider attempt and publishes that attempt's cursor.
      _networkCursorLength = 0;
      _networkCursorPublishedLength = 0;
      _prefix = List<int>.of(restoredPrefix, growable: true);
      _contentKind = sniffContent(_prefix, finalChunk: false);
      _refreshSourceCanvasFromPrefix();
      _failure = null;
      _resetPlayablePrefixEvidence();
      _state = DownloadState.idle;
      _expectIngressLength(totalLength);
      await _restoreIngressIfNeeded(sealed: false);
      _requireEpoch(epoch);
      control?.throwIfCancelled();
      await _syncCache(CacheState.partial, expectedEpoch: epoch);
      _requireEpoch(epoch);
      // The initial adoption sync above still runs while the lending store's
      // adoption serializer is held. Hand subsequent persistent mutations
      // back to that owner only after this boundary is committed; otherwise a
      // nested sync could wait on the very store operation that is adopting
      // this backing.
      _cacheMutationOwner = cacheMutationOwner;
      _recordTrace(
        TraceEventKind.artifactSource,
        <String, Object?>{
          'stage': 'durable-partial-adoption',
          'action': 'adopted-posix-spool',
          'committedLength': adopted.committedLength,
          'storageRootId': storageRootId,
        },
      );
      _notifySnapshot();
      return snapshot;
    } catch (error) {
      if (!backingCommitted) {
        try {
          await artifact.dispose();
        } on Object {
          // Preserve the adoption failure; no session state references this
          // candidate backing yet.
        }
      }
      rethrow;
    } finally {
      _restoring = false;
    }
  }

  Future<DownloadSnapshot> restore({
    bool verifyPromotedChecksum = true,
    bool preferOwnedPartialCheckpoint = false,
    bool ownedCheckpointProbeOnly = false,
    RunLease? expectedRun,
    TaskControl? control,
  }) async {
    _requireNotDisposed();
    if (_restoring) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download restore is already active',
      );
    }
    if (expectedRun != null) {
      requireRun(expectedRun);
    }
    if (_writer != null ||
        (_run != null && !identical(_run, expectedRun)) ||
        _resetting ||
        _disposing) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'cannot restore while download work is active',
      );
    }
    final epoch = _epoch;
    _restoring = true;
    try {
      return await _restore(
        verifyPromotedChecksum: verifyPromotedChecksum,
        preferOwnedPartialCheckpoint: preferOwnedPartialCheckpoint,
        ownedCheckpointProbeOnly: ownedCheckpointProbeOnly,
        expectedEpoch: epoch,
        control: control,
      );
    } catch (error) {
      // Restore participates in scheduler-owned local preparation. A cancelled
      // control only withdraws that attempt; it is not evidence that the
      // physical artifact is invalid. Re-enter through restore on the next
      // demand instead of publishing a transient terminal failure. Any
      // partially reconciled artifact state remains durable and authoritative.
      // Genuine restore failures still become explicit terminal lifecycle
      // failures so a stale promoted/partial projection cannot survive them.
      if (_epoch == epoch &&
          _state != DownloadState.disposed &&
          !_resetting &&
          !_disposing) {
        if (error is Failure && error.code == ErrorCode.cancelled) {
          _state = DownloadState.idle;
          _failure = null;
          _flushCommittedTrace();
          _recordTrace(
            TraceEventKind.downloadState,
            <String, Object?>{
              'state': _state.name,
              'deferred': true,
              'reason': 'restore-cancelled',
              'committedLength': committedLength,
            },
          );
          _notifySnapshot();
        } else {
          _markLifecycleFailure(error, operation: 'restore');
        }
      }
      rethrow;
    } finally {
      _restoring = false;
    }
  }

  Future<DownloadSnapshot> _restore({
    required bool verifyPromotedChecksum,
    required bool preferOwnedPartialCheckpoint,
    required bool ownedCheckpointProbeOnly,
    required SourceEpoch expectedEpoch,
    TaskControl? control,
  }) async {
    control?.throwIfCancelled();
    if (_writer != null) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot restore while a writer is active',
      );
    }
    final epoch = expectedEpoch;
    _ingressProjectionRevision++;
    _residentLength = null;
    _residentBodyBacked = false;
    _residentIngressDeferred = false;
    _residentBodyAuthority = null;
    _dropResidentReplayRangeCapability();
    await _residentReplayCloseTail;
    // The owned App-private partial path can prove itself without first
    // probing unrelated final/ready paths. It rejects any existing final and
    // validates the partial sidecar + body path before adoption. If that fast
    // path does not apply, retain the generic promoted ownership preflight.
    final ownedRecovery = preferOwnedPartialCheckpoint
        ? await _restoreOwnedPartialCheckpoint(control: control)
        : null;
    final ownedCheckpoint = ownedRecovery?.snapshot == null
        ? null
        : (snapshot: ownedRecovery!.snapshot!, meta: ownedRecovery.meta!);
    if (ownedCheckpoint == null &&
        ownedCheckpointProbeOnly &&
        ownedRecovery != null &&
        !ownedRecovery.requiresGenericRestore) {
      _prefix.clear();
      _contentKind = ContentKind.unknown;
      _validators = const Validators();
      _validatorRequestUri = null;
      _totalLength = null;
      _networkStartLength = 0;
      _failure = null;
      _state = DownloadState.idle;
      return snapshot;
    }
    if (ownedCheckpoint == null) {
      // Artifact.restore must not first bind a final file that explicitly
      // belongs to another DownloadId. Preflight the ready sidecar while the
      // Artifact is still empty so a collision cannot leave its in-memory state
      // promoted after this restore fails. The post-restore check below remains
      // a defense for a sidecar that changes during the preflight/restore gap.
      final promotedMeta = await _readPromotedMetaForOwnership();
      _requireEpoch(epoch);
      control?.throwIfCancelled();
      if (promotedMeta != null &&
          _metaExplicitlyClaimsDifferentOwner(promotedMeta)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact metadata belongs to another download',
        );
      }
    }
    final restored = ownedCheckpoint?.snapshot ??
        await artifact.restore(
          verifyPromotedChecksum: verifyPromotedChecksum,
        );
    _requireEpoch(epoch);
    control?.throwIfCancelled();
    final restoredPrefix = await artifact.readPrefix(_sourceMetadataPrefixLength);
    _requireEpoch(epoch);
    control?.throwIfCancelled();
    _prefix = List<int>.of(
      restoredPrefix,
      growable: true,
    );
    _contentKind = sniffContent(
      _prefix,
      finalChunk: restored.state == ArtifactState.promoted,
    );
    _refreshSourceCanvasFromPrefix();

    _networkStartLength = restored.committedLength;

    if (restored.state == ArtifactState.promoted) {
      // The deterministic artifact path is not an ownership proof: a stale
      // file (or a hash collision) can leave a valid, same-length promoted
      // body at this path. When a ready sidecar explicitly identifies another
      // DownloadId, never expose that body through this session. Leave the
      // physical files untouched so the owner of the other artifact can still
      // recover them; the caller can report the collision/corruption and
      // choose a new placement.
      final promotedMeta = await artifact.readMeta();
      _requireEpoch(epoch);
      control?.throwIfCancelled();
      if (promotedMeta != null &&
          _metaExplicitlyClaimsDifferentOwner(promotedMeta)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'promoted artifact metadata belongs to another download',
        );
      }
      await _restoreIngressIfNeeded(sealed: true);
      _requireEpoch(epoch);
      control?.throwIfCancelled();
      _state = DownloadState.promoted;
      await _syncCache(CacheState.ready, expectedEpoch: epoch);
      _requireEpoch(epoch);
      _notifySnapshot();
      return snapshot;
    }

    if (restored.committedLength > 0) {
      var validMeta = false;
      var wrongOwner = false;
      try {
        final meta = ownedCheckpoint?.meta ?? await artifact.readMeta();
        _requireEpoch(epoch);
        control?.throwIfCancelled();
        if (meta != null) {
          if (_metaMatches(meta)) {
            final rawValidators = meta['validators'];
            final rawLength = meta['totalLength'];
            if (rawValidators is Map &&
                (rawLength == null || rawLength is int)) {
              final restoredValidators = Validators.fromJson(
                Map<String, Object?>.from(rawValidators),
              );
              final rawValidatorRequestUri = meta['validatorRequestUri'];
              final restoredValidatorRequestUri = rawValidatorRequestUri is String
                  ? Uri.tryParse(rawValidatorRequestUri)
                  : null;
              _validators = restoredValidators.isEmpty ||
                      restoredValidatorRequestUri == null
                  ? const Validators()
                  : restoredValidators;
              _validatorRequestUri = _validators.isEmpty
                  ? null
                  : restoredValidatorRequestUri;
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
        _validatorRequestUri = null;
        _totalLength = null;
        if (wrongOwner) {
          // The deterministic partial path is not an ownership proof. Do not
          // reset it here: an explicit foreign sidecar may be the valid owner
          // of a hash-colliding artifact, and reset would truncate its bytes.
          throw const Failure(
            code: ErrorCode.artifactCorruption,
            message: 'partial artifact metadata belongs to another download',
          );
        }
      }
    }

    await _restoreIngressIfNeeded(sealed: false);
    _requireEpoch(epoch);
    control?.throwIfCancelled();
    _state = DownloadState.idle;
    _failure = null;
    await _syncCache(CacheState.partial, expectedEpoch: epoch);
    _requireEpoch(epoch);
    _notifySnapshot();
    return snapshot;
  }

  /// Restores one exclusively-owned mutable transfer spool from its atomic
  /// owner sidecar and current file length without eagerly hashing the body.
  ///
  /// This fast path is only for composition-owned App-private/rebound transfer
  /// staging. The generic restore path still re-hashes unknown partial files.
  /// The adopted checksum stays dirty, so a later seal performs the same
  /// authoritative whole-body CRC before promotion.
  Future<({
    ArtifactSnapshot? snapshot,
    Map<String, Object?>? meta,
    bool requiresGenericRestore,
  })> _restoreOwnedPartialCheckpoint({
    TaskControl? control,
  }) async {
    final finalType = await FileSystemEntity.type(
      artifact.finalPath,
      followLinks: false,
    );
    control?.throwIfCancelled();
    if (finalType != FileSystemEntityType.notFound) {
      return (snapshot: null, meta: null, requiresGenericRestore: true);
    }
    final meta = await artifact.readPartialMetaForAdoption();
    control?.throwIfCancelled();
    if (meta == null ||
        meta['artifactState'] != 'partial' ||
        meta['path'] != artifact.partialPath ||
        !_metaMatches(meta)) {
      final partialType = await FileSystemEntity.type(
        artifact.partialPath,
        followLinks: false,
      );
      control?.throwIfCancelled();
      return (
        snapshot: null,
        meta: null,
        requiresGenericRestore:
            partialType != FileSystemEntityType.notFound,
      );
    }
    final rawBytes = meta['bytes'];
    final expectedLength = rawBytes is int && rawBytes > 0
        ? rawBytes
        : await artifact.readPartialLengthForAdoption() ?? 0;
    control?.throwIfCancelled();
    if (expectedLength <= 0) {
      final partialType = await FileSystemEntity.type(
        artifact.partialPath,
        followLinks: false,
      );
      return (
        snapshot: null,
        meta: null,
        requiresGenericRestore:
            partialType != FileSystemEntityType.notFound,
      );
    }
    final restored = await artifact.adoptExistingPartial(
      expectedLength: expectedLength,
    );
    _recordTrace(
      TraceEventKind.artifactSource,
      <String, Object?>{
        'stage': 'recoverable-partial',
        'action': 'adopt-owned-checkpoint',
        'bytes': restored.committedLength,
      },
    );
    return (
      snapshot: restored,
      meta: meta,
      requiresGenericRestore: false,
    );
  }

  /// Publishes the transport cursor for one physical network attempt.
  ///
  /// The cursor is deliberately separate from [committedLength]: a resumed
  /// request may have to re-read an old prefix before it can append new
  /// authoritative bytes. Reader progress can therefore expose re-downloads
  /// without inventing a second partial owner.
  void beginNetworkAttemptProgress(
    int startOffset, {
    int? totalLength,
    RunLease? expectedRun,
  }) {
    _requireNotDisposed();
    if (expectedRun != null) {
      requireRun(expectedRun);
    }
    if (startOffset < 0) {
      throw ArgumentError.value(
        startOffset,
        'startOffset',
        'must not be negative',
      );
    }
    if (totalLength != null && totalLength <= 0) {
      throw ArgumentError.value(
        totalLength,
        'totalLength',
        'must be positive when known',
      );
    }
    _networkAttemptSequence++;
    _networkAttemptActive = true;
    _networkAttemptTotalLength = totalLength;
    _networkCursorLength = startOffset;
    _networkCursorPublishedLength = startOffset;
    _notifySnapshot();
  }

  void advanceNetworkAttemptProgress(
    int absoluteOffset, {
    bool force = false,
    RunLease? expectedRun,
  }) {
    _requireNotDisposed();
    if (expectedRun != null) {
      requireRun(expectedRun);
    }
    if (!_networkAttemptActive) {
      return;
    }
    if (absoluteOffset < _networkCursorLength) {
      throw Failure(
        code: ErrorCode.invalidOffset,
        message: 'network cursor moved backwards: '
            '$_networkCursorLength -> $absoluteOffset',
      );
    }
    if (absoluteOffset == _networkCursorLength && !force) {
      return;
    }
    _networkCursorLength = absoluteOffset;
    if (force ||
        absoluteOffset - _networkCursorPublishedLength >=
            sourceProgressQuantumBytes) {
      _networkCursorPublishedLength = absoluteOffset;
      _notifySnapshot();
    }
  }

  void endNetworkAttemptProgress({RunLease? expectedRun}) {
    if (expectedRun != null && !isCurrentRun(expectedRun)) {
      return;
    }
    if (!_networkAttemptActive) {
      return;
    }
    _networkAttemptActive = false;
    _networkAttemptTotalLength = null;
    _networkCursorPublishedLength = _networkCursorLength;
    _notifySnapshot();
  }

  void queue() {
    _requireState(<DownloadState>{DownloadState.idle, DownloadState.failed});
    _networkStartLength = committedLength;
    _state = DownloadState.queued;
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name},
    );
    _notifySnapshot();
  }

  Future<void> bindResponse({
    required Validators validators,
    int? totalLength,
    Uri? validatorRequestUri,
  }) async {
    _requireNotDisposed();
    final epoch = _epoch;
    if (artifact.state == ArtifactState.empty) {
      await artifact.restore();
      _requireEpoch(epoch);
    }
    _ingressProjectionRevision++;
    _validators = validators;
    _validatorRequestUri = validators.isEmpty
        ? null
        : (validatorRequestUri ?? id.canonicalUri);
    _totalLength = totalLength;
    _expectIngressLength(totalLength);
    await artifact.writeMeta(<String, Object?>{
      'version': 3,
      'physicalMedia': physicalId.toJson(),
      'downloadKey': id.key,
      'download': id.toJson(),
      'uri': (validatorRequestUri ?? id.canonicalUri).toString(),
      'sourceRevision': id.sourceRevision,
      'validators': validators.toJson(),
      if (_validatorRequestUri != null)
        'validatorRequestUri': _validatorRequestUri.toString(),
      if (totalLength != null) 'totalLength': totalLength,
    });
    _requireEpoch(epoch);
    await _syncCache(CacheState.partial, expectedEpoch: epoch);
    _requireEpoch(epoch);
    _notifySnapshot();
  }

  /// Binds a complete immutable body authority without hydrating Reader ingress.
  ///
  /// [committedLength] becomes the physical body-authority boundary immediately,
  /// while each Reader-local ingress remains independently empty until its
  /// media demand asks the projection registry to replay a prefix. This is the
  /// durable READY fast path: the session owns transfer/completion state, not a
  /// duplicate encoded-body copy.
  void bindResidentImmutableAuthority({
    required Validators validators,
    required int totalLength,
    required ByteResponseBodyAuthority bodyAuthority,
    required List<int> metadataPrefix,
    Uri? validatorRequestUri,
    DownloadResidentReplayRangeChunks? residentReplayRangeChunks,
    DownloadResidentReplayRangeClose? residentReplayRangeClose,
    String residentReplayAccessMode = 'unknown',
    Object? residentReplayCacheKey,
  }) {
    _requireNotDisposed();
    _requireState(<DownloadState>{
      DownloadState.idle,
      DownloadState.queued,
      DownloadState.failed,
    });
    if (totalLength <= 0) {
      throw ArgumentError.value(
        totalLength,
        'totalLength',
        'resident immutable authorities must contain image bytes',
      );
    }
    if (metadataPrefix.isEmpty) {
      throw ArgumentError.value(
        metadataPrefix,
        'metadataPrefix',
        'resident immutable authorities must preserve encoded metadata',
      );
    }
    if (metadataPrefix.length > _sourceMetadataPrefixLength) {
      throw ArgumentError.value(
        metadataPrefix.length,
        'metadataPrefix.length',
        'must not exceed $_sourceMetadataPrefixLength bytes',
      );
    }
    _ingressProjectionRevision++;
    _residentBodyBacked = true;
    _residentIngressDeferred = true;
    _residentBodyAuthority = bodyAuthority;
    _dropResidentReplayRangeCapability();
    _residentReplayRangeChunks = residentReplayRangeChunks;
    _residentReplayRangeClose = residentReplayRangeClose;
    _residentReplayGenerationToken = Object();
    _residentReplayCacheKey = residentReplayCacheKey;
    _residentReplayAccessMode = residentReplayAccessMode;
    _residentLength = totalLength;
    _validators = validators;
    _validatorRequestUri = validators.isEmpty
        ? null
        : (validatorRequestUri ?? id.canonicalUri);
    _totalLength = totalLength;
    _networkStartLength = 0;
    _networkAttemptActive = false;
    _networkAttemptTotalLength = null;
    _networkCursorLength = 0;
    _networkCursorPublishedLength = 0;
    _prefix = <int>[];
    _sourceCanvasWidth = null;
    _sourceCanvasHeight = null;
    _appendSourceMetadataPrefix(
      0,
      metadataPrefix is Uint8List
          ? metadataPrefix
          : Uint8List.fromList(metadataPrefix),
    );
    _failure = null;
    _resetPlayablePrefixEvidence();
    final epoch = _epoch;
    for (final projection in _ingressProjections.values) {
      projection.expectLength(totalLength);
    }
    _state = DownloadState.promoted;
    _recordTrace(
      TraceEventKind.artifactPromoted,
      <String, Object?>{
        'length': totalLength,
        'cacheResident': true,
        'residentBodyBacked': true,
        'residentIngressDeferred': true,
        'residentIngressHydratedLength': 0,
        'residentBodyAuthority': bodyAuthority.name,
        'residentReplayAccessMode': _residentReplayAccessMode,
        if (residentSource != null) 'residentSource': residentSource,
      },
    );
    _notifySnapshot();
    _requireEpoch(epoch);
  }

  /// Attaches an empty Reader-local projection to a complete resident body.
  /// The projection remains part of this physical generation for reset/dispose
  /// lifecycle propagation, but immutable bytes are appended only by the
  /// Reader-local replay registry as decode requests them.
  void attachDeferredResidentIngressProjection(
    DownloadIngressProjection projection,
  ) {
    _requireNotDisposed();
    if (!residentIngressDeferred || _state != DownloadState.promoted) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'deferred resident ingress requires a promoted resident authority',
      );
    }
    final existing = _ingressProjections[projection.scopeId];
    if (existing != null && !identical(existing, projection)) {
      throw ArgumentError.value(
        projection.scopeId,
        'projection.scopeId',
        'already attached to another ingress projection',
      );
    }
    if (identical(existing, projection)) return;
    _ingressProjections[projection.scopeId] = projection;
    projection.expectLength(_totalLength);
    _notifySnapshot();
  }

  void beginResidentImmutableIngress({
    required Validators validators,
    required int totalLength,
    Uri? validatorRequestUri,
    ByteResponseBodyAuthority bodyAuthority = ByteResponseBodyAuthority.source,
    DownloadResidentReplayRangeChunks? residentReplayRangeChunks,
    String residentReplayAccessMode = 'unknown',
  }) {
    _requireNotDisposed();
    _requireState(<DownloadState>{
      DownloadState.idle,
      DownloadState.queued,
      DownloadState.failed,
    });
    if (totalLength <= 0) {
      throw ArgumentError.value(
        totalLength,
        'totalLength',
        'resident immutable sources must contain image bytes',
      );
    }
    _ingressProjectionRevision++;
    _residentBodyBacked = true;
    _residentIngressDeferred = false;
    _residentBodyAuthority = bodyAuthority;
    _dropResidentReplayRangeCapability();
    _residentReplayRangeChunks = residentReplayRangeChunks;
    _residentReplayGenerationToken =
        residentReplayRangeChunks == null ? null : Object();
    _residentReplayAccessMode = residentReplayRangeChunks == null
        ? 'unknown'
        : residentReplayAccessMode;
    _residentLength = 0;
    _validators = validators;
    _validatorRequestUri = validators.isEmpty
        ? null
        : (validatorRequestUri ?? id.canonicalUri);
    _totalLength = totalLength;
    _networkStartLength = 0;
    _prefix = <int>[];
    _sourceCanvasWidth = null;
    _sourceCanvasHeight = null;
    _contentKind = ContentKind.unknown;
    _failure = null;
    _resetPlayablePrefixEvidence();
    final epoch = _epoch;
    _resetIngressProjections(epoch);
    _requireEpoch(epoch);
    _expectIngressLength(totalLength);
    _state = DownloadState.receiving;
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{
        'state': _state.name,
        'cacheResident': true,
        'residentBodyBacked': true,
        if (residentBodyAuthority != null)
          'residentBodyAuthority': residentBodyAuthority!.name,
        if (residentSource != null) 'residentSource': residentSource,
      },
    );
    _notifySnapshot();
    _requireEpoch(epoch);
  }

  void appendResidentImmutableIngress(int offset, List<int> bytes) {
    _requireNotDisposed();
    if (!_residentBodyBacked || _state != DownloadState.receiving) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'session is not receiving a resident immutable source',
      );
    }
    if (offset != (_residentLength ?? 0)) {
      throw Failure(
        code: ErrorCode.invalidOffset,
        message: 'expected resident offset ${_residentLength ?? 0}, got $offset',
      );
    }
    _ingressProjectionRevision++;
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final ingressStarted = clock.nowMicros();
    final epoch = _epoch;
    _appendIngress(epoch, offset, chunk);
    _requireEpoch(epoch);
    final nativeIngressMicros =
        (clock.nowMicros() - ingressStarted).clamp(0, 1 << 62).toInt();
    _residentLength = offset + chunk.length;
    _recordIngressTiming(
      nativeIngressMicros: nativeIngressMicros,
      artifactWriteMicros: 0,
    );
    _appendSourceMetadataPrefix(offset, chunk);
    _recordCommittedChunk(chunk.length);
    _requireEpoch(epoch);
  }

  DownloadSnapshot sealResidentImmutableIngress({
    bool deferFutureReaderIngress = false,
  }) {
    _requireNotDisposed();
    if (!_residentBodyBacked || _state != DownloadState.receiving) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'session is not receiving a resident immutable source',
      );
    }
    final expected = _totalLength;
    if (expected != null && expected != committedLength) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident immutable length $committedLength does not match $expected',
      );
    }
    final contentKind = sniffContent(_prefix, finalChunk: true);
    if (committedLength <= 0 || contentKind == ContentKind.unknown) {
      throw const Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident immutable source has no recognizable image body',
      );
    }
    _ingressProjectionRevision++;
    final epoch = _epoch;
    _sealIngressProjections(epoch);
    _requireEpoch(epoch);
    _contentKind = contentKind;
    // The response has now been consumed to one complete immutable authority.
    // Existing Reader projections already own their live source and remain
    // untouched. Future Reader attachments may instead hydrate this immutable
    // body by exact ranges, avoiding a whole-body replay before frame 0. The
    // caller opts in only when its composition guarantees resident range replay.
    if (deferFutureReaderIngress) {
      _residentIngressDeferred = true;
    }
    _state = DownloadState.promoted;
    _flushCommittedTrace();
    _recordTrace(TraceEventKind.artifactPromoted, <String, Object?>{
      'length': committedLength,
      'cacheResident': true,
      'residentBodyBacked': true,
      'residentIngressDeferred': _residentIngressDeferred,
      if (residentBodyAuthority != null)
        'residentBodyAuthority': residentBodyAuthority!.name,
      if (residentSource != null) 'residentSource': residentSource,
    });
    _notifySnapshot();
    _requireEpoch(epoch);
    return snapshot;
  }

  WriterLease acquireWriter({RunLease? expectedRun}) {
    _requireNotLifecycleBusy();
    _requireMutationRun(expectedRun);
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
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name},
    );
    _notifySnapshot();
    _requireWriter(lease);
    return lease;
  }

  Future<void> append(WriterLease lease, int offset, List<int> bytes) async {
    _requireWriter(lease);
    final epoch = lease.epoch;
    _ingressProjectionRevision++;
    final chunk = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      final artifactStarted = clock.nowMicros();
      final artifactWrite = artifact.appendOwned(offset, chunk);
      await artifactWrite;
      // Reset/eviction may have advanced the physical epoch while the artifact
      // write was awaiting disk I/O. Do not publish a stale completion into
      // Reader projections or session metadata after that boundary.
      _requireWriter(lease);
      final artifactWriteMicros =
          (clock.nowMicros() - artifactStarted).clamp(0, 1 << 62).toInt();
      final ingressStarted = clock.nowMicros();
      _appendIngress(epoch, offset, chunk);
      _requireWriter(lease);
      final nativeIngressMicros =
          (clock.nowMicros() - ingressStarted).clamp(0, 1 << 62).toInt();
      _recordIngressTiming(
        nativeIngressMicros: nativeIngressMicros,
        artifactWriteMicros: artifactWriteMicros,
      );
      _appendSourceMetadataPrefix(offset, chunk);
      _recordCommittedChunk(chunk.length);
      _notifyCommittedProgress();
      _requireWriter(lease);
    } on Object catch (error, stackTrace) {
      // A direct session consumer may observe an artifact or ingress failure
      // without going through DownloadJob's attempt cleanup. Retire this
      // writer here as well; otherwise a failed sink/open leaves the logical
      // session writer-busy forever even though the artifact has no open sink.
      if (identical(_writer, lease) && _epoch == epoch) {
        try {
          if (_isStaleSessionLifecycleFailure(error)) {
            // The physical append is already committed at this point. A
            // Reader-local projection from an older lifecycle is not evidence
            // that those bytes are corrupt; retire only this attempt and keep
            // the partial resumable for the current physical owner.
            await pause(lease);
          } else {
            await fail(lease, error);
          }
        } on Object {
          // Preserve the append failure. Writer retirement is best-effort;
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<DownloadSnapshot> seal(
    WriterLease lease, {
    int? expectedLength,
    String? expectedChecksum,
  }) async {
    _requireWriter(lease);
    final epoch = lease.epoch;
    _ingressProjectionRevision++;
    final ArtifactSnapshot sealed;
    try {
      sealed = await artifact.seal(
        expectedLength: expectedLength,
        expectedChecksum: expectedChecksum,
      );
    } on Object catch (error) {
      // Artifact.seal closes the IOSink before validating length/checksum and
      // can therefore fail with no usable writer left behind. Retire the
      // session writer lifecycle here as well; otherwise a direct caller that
      // does not route the error through DownloadJob remains permanently
      // blocked by writerBusy even though the partial is resumable.
      await _retireWriterAfterSealError(lease, error);
      rethrow;
    }
    // The artifact operation is asynchronous; reject a seal that completed
    // after reset/eviction advanced the writer epoch.
    _requireWriter(lease);
    try {
      _sealIngressProjections(lease.epoch);
      _requireWriter(lease);
    } on Object catch (error) {
      // Artifact.seal has already closed the IOSink and moved the artifact to
      // its sealed state. If a Reader-local projection fails while receiving
      // that terminal edge, leaving [_writer] installed makes the physical
      // session look like it still owns a partial writer and strands every
      // later retry behind writerBusy. Retire the writer lifecycle here while
      // preserving the original projection failure; the next owner attempt
      // can restore the sealed partial and rebuild its projections.
      if (identical(_writer, lease) &&
          _epoch == epoch &&
          artifact.state == ArtifactState.sealed) {
        _writer = null;
        final staleLifecycle = _isStaleSessionLifecycleFailure(error);
        _state = staleLifecycle ? DownloadState.idle : DownloadState.failed;
        _failure = staleLifecycle
            ? null
            : error is Failure
                ? error
                : Failure(
                    code: ErrorCode.source,
                    message: '$error',
                    cause: error,
                  );
        _flushCommittedTrace();
        _recordTrace(
          TraceEventKind.downloadState,
          <String, Object?>{
            'state': _state.name,
            'operation': 'seal-projection',
            if (staleLifecycle) ...<String, Object?>{
              'deferred': true,
              'reason': 'stale-consumer-projection',
            } else
              'error': '$_failure',
          },
        );
        _notifySnapshot();
      }
      rethrow;
    }
    _writer = null;
    _state = DownloadState.sealed;
    _contentKind = sniffContent(_prefix, finalChunk: true);
    _flushCommittedTrace();
    _recordTrace(
      TraceEventKind.artifactSealed,
      <String, Object?>{
        'length': sealed.committedLength,
        'checksum': sealed.checksum,
        'kind': _contentKind.name,
      },
    );
    _notifySnapshot();
    await _syncCache(CacheState.partial, expectedEpoch: epoch);
    _requireEpoch(epoch);
    return snapshot;
  }

  Future<void> _retireWriterAfterSealError(
    WriterLease lease,
    Object error,
  ) async {
    if (!identical(_writer, lease) || _epoch != lease.epoch) {
      return;
    }
    _writer = null;
    _state = DownloadState.failed;
    _failure = error is Failure
        ? error
        : Failure(code: ErrorCode.network, message: '$error', cause: error);
    _flushCommittedTrace();
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{
        'state': _state.name,
        'operation': 'seal',
        'error': '$_failure',
      },
    );
    _notifySnapshot();
    try {
      await _syncCache(CacheState.partial, expectedEpoch: lease.epoch);
    } on Object {
      // Preserve the original seal failure. A later owner attempt can restore
      // the durable partial and reconcile its cache record.
    }
  }

  Future<DownloadSnapshot> promote({RunLease? expectedRun}) async {
    _requireMutationRun(expectedRun);
    _requireState(<DownloadState>{DownloadState.sealed});
    final epoch = _epoch;
    _ingressProjectionRevision++;
    final ArtifactSnapshot promoted;
    try {
      // A deterministic final path is not an ownership proof. Before an
      // existing same-content target is adopted by Artifact.promote, reject
      // an explicit ready/partial sidecar belonging to another DownloadId;
      // otherwise a hash/path collision could overwrite the other owner's
      // metadata while leaving its bytes apparently intact.
      final existingMeta = await _readPromotedMetaForOwnership();
      _requireEpoch(epoch);
      if (existingMeta != null &&
          _metaExplicitlyClaimsDifferentOwner(existingMeta)) {
        throw const Failure(
          code: ErrorCode.artifactCorruption,
          message: 'final artifact metadata belongs to another download',
        );
      }
      final journaled = await _beginDurablePromotion(expectedEpoch: epoch);
      _requireEpoch(epoch);
      promoted = await artifact.promote();
      _requireEpoch(epoch);
      _state = DownloadState.promoted;
      _recordTrace(
        TraceEventKind.artifactPromoted,
        <String, Object?>{
          'path': promoted.finalPath,
          'length': promoted.committedLength,
        },
      );
      _notifySnapshot();
      if (journaled) {
        await _commitDurablePromotion(expectedEpoch: epoch);
      } else {
        await _syncCache(CacheState.ready, expectedEpoch: epoch);
      }
      _requireEpoch(epoch);
      return snapshot;
    } on Object catch (error) {
      if (_epoch != epoch || _state == DownloadState.disposed) rethrow;
      _state = DownloadState.failed;
      _failure = error is Failure
          ? error
          : Failure(code: ErrorCode.network, message: '$error', cause: error);
      _flushCommittedTrace();
      _recordTrace(
        TraceEventKind.downloadState,
        <String, Object?>{'state': _state.name, 'error': '$_failure'},
      );
      _notifySnapshot();
      rethrow;
    }
  }

  /// Pauses an authoritative partial writer without converting the partial
  /// into a failure or a promoted artifact.
  ///
  /// Durable Reader-session handoff uses this after importing an existing
  /// partial into the long-lived artifact owner. Network scheduling remains
  /// outside this primitive.
  Future<DownloadSnapshot> pause(WriterLease lease) async {
    _requireWriter(lease);
    final epoch = lease.epoch;
    try {
      await artifact.pause();
      _requireWriter(lease);
    } finally {
      if (identical(_writer, lease)) {
        _writer = null;
        _state = DownloadState.idle;
        _failure = null;
      }
    }
    _requireEpoch(epoch);
    _flushCommittedTrace();
    await _syncCache(CacheState.partial, expectedEpoch: epoch);
    _requireEpoch(epoch);
    _notifySnapshot();
    return snapshot;
  }

  Future<void> fail(WriterLease lease, Object error) async {
    _requireWriter(lease);
    if (error is Failure && error.code == ErrorCode.cancelled) {
      // Cancellation is an attempt-lifecycle outcome, not evidence that the
      // encoded partial is invalid. Preserve the authoritative bytes as an
      // idle resumable partial even if a higher-level caller routes the
      // cancellation through the generic failure closure.
      await pause(lease);
      return;
    }
    final epoch = lease.epoch;
    try {
      await artifact.pause();
      _requireWriter(lease);
    } finally {
      if (identical(_writer, lease)) {
        _writer = null;
        _state = DownloadState.failed;
        _failure = error is Failure
            ? error
            : Failure(code: ErrorCode.network, message: '$error', cause: error);
      }
    }
    _requireEpoch(epoch);
    _flushCommittedTrace();
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'error': '$_failure'},
    );
    _notifySnapshot();
    await _syncCache(CacheState.partial, expectedEpoch: epoch);
    _requireEpoch(epoch);
  }

  /// Terminal failure for a task that exited without a writer (open /
  /// request-plan rejection). MUST publish `failed`: demand holders wait for
  /// a terminal state — a session left `queued` stalls them until the
  /// inactivity timeout instead of surfacing the real error.
  Future<void> failWithoutWriter(Object error) async {
    _requireNotDisposed();
    if (_state == DownloadState.promoted ||
        _state == DownloadState.disposed) {
      // Promoted/disposed are authoritative terminal facts that must not be
      // overwritten.
      return;
    }
    final writer = _writer;
    if (writer != null) {
      // Setup failures can happen after a writer was acquired but before the
      // transport owns the attempt. Route them through the same pause/fail
      // lifecycle so no sink or partial writer is stranded.
      await fail(writer, error);
      return;
    }
    if (_state == DownloadState.failed && _failure != null) {
      return;
    }
    _state = DownloadState.failed;
    _failure = error is Failure
        ? error
        : Failure(code: ErrorCode.network, message: '$error', cause: error);
    _flushCommittedTrace();
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'error': '$_failure'},
    );
    _notifySnapshot();
  }

  /// Legacy single-consumer demand used by direct DownloadJob callers.
  /// Reader/prefetch/download composition should use [attachDemand] instead.
  void attach() {
    _requireNotDisposed();
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
    // Priority belongs to transfer scheduling, not encoded-media/session
    // lifecycle. A newly attached demand scope is a lifecycle edge and remains visible in
    // both the demand trace and DownloadSnapshot. Existing-scope priority
    // migration is scheduling metadata only: DownloadTransferOwner/NetLane own
    // the actual priority change, while Pipeline reconcile timing already
    // records plan-level changed cardinality. Emitting one demandApplied event
    // per hot-window priority migration serializes routine control telemetry on
    // the UI isolate without adding lifecycle information.
    if (previous == null) {
      _recordTrace(
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
  }

  void _detachDemand(String scopeId) {
    if (_demandPriorities.remove(scopeId) == null) return;
    _flushCommittedTrace();
    _recordTrace(
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

  void deferNetwork({required String reason, RunLease? expectedRun}) {
    _requireNotDisposed();
    if (expectedRun != null) {
      requireRun(expectedRun);
    } else if (!_runActivityIsCurrent()) {
      return;
    }
    _requireState(<DownloadState>{DownloadState.queued});
    _flushCommittedTrace();
    _state = DownloadState.idle;
    _failure = null;
    _recordTrace(
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

  /// Projects decoder evidence onto the current physical encoded prefix.
  ///
  /// Returns true only when the physical playable-prefix fact strengthened.
  /// Policy targets, Reader roles and transport framing never write this fact.
  bool observePlayablePrefixEvidence({
    required int decodedPrefixFrames,
    required int sourceLength,
    required int firstPlayablePrefixBytes,
    required int firstFrameRequiredSourceLength,
  }) {
    _requireNotDisposed();
    var changed = false;
    if (decodedPrefixFrames > _decodedPrefixFrames) {
      _decodedPrefixFrames = decodedPrefixFrames;
      changed = true;
    }
    if (firstPlayablePrefixBytes > 0 &&
        (_firstPlayablePrefixBytes == 0 ||
            firstPlayablePrefixBytes < _firstPlayablePrefixBytes)) {
      _firstPlayablePrefixBytes = firstPlayablePrefixBytes;
      changed = true;
    }
    if (_firstPlayablePrefixBytes == 0 &&
        firstFrameRequiredSourceLength > _firstFrameRequiredPrefixBytes) {
      _firstFrameRequiredPrefixBytes = firstFrameRequiredSourceLength;
      changed = true;
    }
    if (!changed) return false;
    _recordTrace(
      TraceEventKind.artifactSource,
      <String, Object?>{
        'stage': 'decode-playable-prefix',
        'action': 'evidence-updated',
        'decodedPrefixFrames': _decodedPrefixFrames,
        'sourceLength': sourceLength,
        'firstPlayablePrefixBytes': _firstPlayablePrefixBytes,
        'firstFrameRequiredPrefixBytes': _firstFrameRequiredPrefixBytes,
        'committedLength': committedLength,
      },
    );
    return true;
  }

  /// Records the strongest structural frame proof reached by the live
  /// physical response for this generation. The proof is a physical-prefix
  /// fact, not a Reader policy target, and remains valid while the append-only
  /// partial keeps at least [committedLengthAtProof] bytes.
  void observeNetworkFlowFrameProof({
    required int completedFrames,
    required int committedLengthAtProof,
    RunLease? expectedRun,
  }) {
    if (expectedRun != null) {
      requireRun(expectedRun);
    } else if (!_runActivityIsCurrent()) {
      return;
    }
    if (completedFrames <= 0 || committedLengthAtProof <= 0) return;
    if (completedFrames < _networkFlowSatisfiedFrames) return;
    if (completedFrames == _networkFlowSatisfiedFrames &&
        committedLengthAtProof >= _networkFlowProofLength &&
        _networkFlowProofLength > 0) {
      return;
    }
    _networkFlowSatisfiedFrames = completedFrames;
    _networkFlowProofLength = committedLengthAtProof;
  }

  void recordFlowControl({
    required String action,
    String? mode,
    required int targetFrames,
    required int completedFrames,
    required int networkCursor,
    int? playablePrefixFloorBytes,
    bool? responseRangeSupported,
    String? retentionReason,
    bool? responseRetained,
    bool? responseReadPermitHeld,
    bool? demanded,
    RunLease? expectedRun,
  }) {
    if (expectedRun != null) {
      requireRun(expectedRun);
    } else if (!_runActivityIsCurrent()) {
      return;
    }
    _recordTrace(
      TraceEventKind.artifactSource,
      <String, Object?>{
        'stage': 'transport-flow-control',
        'action': action,
        if (mode != null) 'mode': mode,
        'targetFrames': targetFrames,
        'completedFrames': completedFrames,
        'networkCursor': networkCursor,
        'committedLength': committedLength,
        'decodedPrefixFrames': _decodedPrefixFrames,
        'firstPlayablePrefixBytes': _firstPlayablePrefixBytes,
        'firstFrameRequiredPrefixBytes': _firstFrameRequiredPrefixBytes,
        if (playablePrefixFloorBytes != null)
          'playablePrefixFloorBytes': playablePrefixFloorBytes,
        if (playablePrefixFloorBytes != null)
          'playablePrefixProven': _firstPlayablePrefixBytes > 0,
        if (responseRangeSupported != null)
          'responseRangeSupported': responseRangeSupported,
        if (retentionReason != null) 'retentionReason': retentionReason,
        if (responseRetained != null) 'responseRetained': responseRetained,
        if (responseReadPermitHeld != null)
          'responseReadPermitHeld': responseReadPermitHeld,
        if (demanded != null) 'demanded': demanded,
      },
    );
  }

  void recordTransportReadPermit({
    required String action,
    required String reason,
    bool? responseReadPermitHeld,
    bool? demanded,
    String? bodyAuthority,
    RunLease? expectedRun,
  }) {
    if (expectedRun != null) {
      requireRun(expectedRun);
    } else if (!_runActivityIsCurrent()) {
      return;
    }
    _recordTrace(
      TraceEventKind.artifactSource,
      <String, Object?>{
        'stage': 'transport-read-permit',
        'action': action,
        'reason': reason,
        if (responseReadPermitHeld != null)
          'responseReadPermitHeld': responseReadPermitHeld,
        if (demanded != null) 'demanded': demanded,
        if (bodyAuthority != null) 'bodyAuthority': bodyAuthority,
        'committedLength': committedLength,
      },
    );
  }

  void recordResume({
    required bool restarted,
    String? strategy,
    bool playablePrefixPreserved = false,
    Map<String, Object?> diagnostics = const <String, Object?>{},
    RunLease? expectedRun,
  }) {
    if (expectedRun != null) {
      requireRun(expectedRun);
    } else if (!_runActivityIsCurrent()) {
      return;
    }
    _recordTrace(
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
    _recordTrace(
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

  /// Starts a fresh physical generation. Ordinary resets preserve an immutable
  /// promoted final so cache/shared-binding owners can re-adopt it. A caller
  /// with semantic evidence that those exact physical bytes are invalid must
  /// set [deleteFinalArtifact] to destroy that final before restore.
  Future<void> reset({
    bool removeCacheRecord = true,
    bool deleteFinalArtifact = false,
  }) async {
    _requireNotDisposed();
    if (_resetting ||
        _disposing ||
        _restoring ||
        _pendingIngressAttachments.isNotEmpty) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download session lifecycle operation is already active',
      );
    }
    _resetting = true;
    try {
      await _resetClaimed(
        removeCacheRecord: removeCacheRecord,
        deleteFinalArtifact: deleteFinalArtifact,
      );
    } finally {
      _resetting = false;
    }
  }

  /// Resets an idle session without deleting a promoted final file.
  ///
  /// Cache owners use this after removing one logical index binding whose
  /// physical file may still be referenced by another binding. The check and
  /// transition to [_resetting] happen synchronously, so a new run cannot
  /// start between the idle check and the reset operation.
  Future<bool> resetIfIdle({bool removeCacheRecord = true}) async {
    return await resetIfIdleAndRun<bool>(
          removeCacheRecord: removeCacheRecord,
          operation: () async => true,
        ) ??
        false;
  }

  /// Resets an idle session while holding the lifecycle boundary through
  /// [operation]. Cache owners use this for check/remove/delete sequences: a
  /// plain [resetIfIdle] releases [_resetting] before the caller's next
  /// asynchronous index/byte mutation, allowing a new demand to acquire the
  /// session in that gap.
  Future<T?> resetIfIdleAndRun<T>({
    required Future<T> Function() operation,
    bool removeCacheRecord = true,
  }) async {
    if (_state == DownloadState.disposed ||
        _resetting ||
        _disposing ||
        _restoring ||
        _pendingIngressAttachments.isNotEmpty ||
        _writer != null ||
        _run != null) {
      return null;
    }
    // Claim the lifecycle boundary before the first await. beginRun() does
    // not wait on an asynchronous reset, so checking first and delegating to
    // reset() would leave a check-to-reset window in which a new run could
    // acquire this physical session.
    _resetting = true;
    try {
      await _resetClaimed(removeCacheRecord: removeCacheRecord);
      return await operation();
    } finally {
      _resetting = false;
    }
  }

  Future<void> _resetClaimed({
    required bool removeCacheRecord,
    bool deleteFinalArtifact = false,
  }) async {
    _ingressProjectionRevision++;
    _flushCommittedTrace();
    _writer = null;
    _epoch = _epoch.next();
    _resetIngressProjections(_epoch);
    _validators = const Validators();
    _validatorRequestUri = null;
    _totalLength = null;
    _networkStartLength = 0;
    _networkAttemptActive = false;
    _networkAttemptTotalLength = null;
    _networkCursorLength = 0;
    _networkCursorPublishedLength = 0;
    _residentLength = null;
    _residentBodyBacked = false;
    _residentIngressDeferred = false;
    _residentBodyAuthority = null;
    _dropResidentReplayRangeCapability();
    await _residentReplayCloseTail;
    _contentKind = ContentKind.unknown;
    _prefix = <int>[];
    _sourceCanvasWidth = null;
    _sourceCanvasHeight = null;
    _failure = null;
    _resetPlayablePrefixEvidence();
    try {
      await _restartArtifact(deleteFinal: deleteFinalArtifact);
      _state = DownloadState.idle;
      // Establish a cache synchronization boundary even when the caller has
      // already removed the index binding. In particular, a stale _syncCache
      // operation may have passed its epoch check immediately before this
      // reset and can otherwise repopulate a logically deleted row during
      // resetIfIdle(removeCacheRecord: false).
      await _enqueueCacheMutation<void>(() async {
        final mutationOwner = _cacheMutationOwner;
        if (mutationOwner != null) {
          await mutationOwner.clearDownloadCache(
            this,
            removeCacheRecord: removeCacheRecord,
            deleteFinalArtifact: deleteFinalArtifact,
          );
          return;
        }
        final cache = index;
        final physicalCache = _physicalPartialIndex;
        if (!physicalId.isExactFallback && physicalCache != null) {
          await physicalCache.removePhysicalPartial(physicalId);
        }
        if (deleteFinalArtifact &&
            !physicalId.isExactFallback &&
            cache is PhysicalMediaArtifactIndex) {
          await (cache as PhysicalMediaArtifactIndex)
              .removePhysicalMediaArtifactBinding(physicalId);
        }
        if (removeCacheRecord) {
          await cache?.remove(id.key);
        }
      });
    } on Object catch (error) {
      _markLifecycleFailure(error, operation: 'reset');
      rethrow;
    }
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{'state': _state.name, 'reset': true},
    );
    _notifySnapshot();
  }

  Future<int> evict() async {
    _requireNotDisposed();
    if (_resetting || _disposing) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download session lifecycle operation is already active',
      );
    }
    _flushCommittedTrace();
    if (!canEvict) {
      throw const Failure(
        code: ErrorCode.writerBusy,
        message: 'cannot evict while a writer is active',
      );
    }
    _ingressProjectionRevision++;
    _resetting = true;
    try {
      final released = artifact.committedLength;
      _epoch = _epoch.next();
      _resetIngressProjections(_epoch);
      await artifact.deleteAll();
      _state = DownloadState.idle;
      _validators = const Validators();
      _validatorRequestUri = null;
      _totalLength = null;
      _networkStartLength = 0;
      _networkAttemptActive = false;
      _networkAttemptTotalLength = null;
      _networkCursorLength = 0;
      _networkCursorPublishedLength = 0;
      _residentLength = null;
      _residentBodyBacked = false;
      _residentIngressDeferred = false;
      _residentBodyAuthority = null;
      _dropResidentReplayRangeCapability();
      await _residentReplayCloseTail;
      _contentKind = ContentKind.unknown;
      _prefix = <int>[];
      _sourceCanvasWidth = null;
      _sourceCanvasHeight = null;
      _resetPlayablePrefixEvidence();
      await _enqueueCacheMutation<void>(() async {
        final mutationOwner = _cacheMutationOwner;
        if (mutationOwner != null) {
          await mutationOwner.clearDownloadCache(
            this,
            removeCacheRecord: true,
            deleteFinalArtifact: true,
          );
          return;
        }
        final cache = index;
        final physicalCache = _physicalPartialIndex;
        if (!physicalId.isExactFallback && physicalCache != null) {
          await physicalCache.removePhysicalPartial(physicalId);
        }
        if (!physicalId.isExactFallback &&
            cache is PhysicalMediaArtifactIndex) {
          await (cache as PhysicalMediaArtifactIndex)
              .removePhysicalMediaArtifactBinding(physicalId);
        }
        await cache?.remove(id.key);
      });
      _recordTrace(
        TraceEventKind.downloadState,
        <String, Object?>{'state': _state.name, 'evictedBytes': released},
      );
      _notifySnapshot();
      return released;
    } on Object catch (error) {
      _markLifecycleFailure(error, operation: 'evict');
      rethrow;
    } finally {
      _resetting = false;
    }
  }

  void _dropResidentReplayRangeCapability() {
    final close = _residentReplayRangeClose;
    _residentReplayRangeChunks = null;
    _residentReplayRangeClose = null;
    _residentReplayGenerationToken = null;
    _residentReplayCacheKey = null;
    _residentReplayAccessMode = 'unknown';
    if (close == null) return;
    _residentReplayCloseTail = _residentReplayCloseTail.then((_) async {
      try {
        await close();
      } on Object {
        // Generation retirement must not be reversed by descriptor cleanup.
      }
    });
  }

  void _resetPlayablePrefixEvidence() {
    _firstPlayablePrefixBytes = 0;
    _firstFrameRequiredPrefixBytes = 0;
    _decodedPrefixFrames = 0;
    _networkFlowSatisfiedFrames = 0;
    _networkFlowProofLength = 0;
  }

  /// Flushes the currently committed partial prefix and publishes exactly that
  /// flushed length to the durable cache owner without pausing the active
  /// writer. Bytes appended after the flush remain an uncheckpointed crash tail
  /// until a later checkpoint advances the durable length.
  Future<int> checkpointPartialCache() async {
    _requireNotDisposed();
    if (artifact.state != ArtifactState.partial || artifact.committedLength <= 0) {
      return 0;
    }
    final epoch = _epoch;
    final checkpointLength = await artifact.flushCommittedLength();
    _requireEpoch(epoch);
    await _syncCache(
      CacheState.partial,
      expectedEpoch: epoch,
      committedLength: checkpointLength,
    );
    _requireEpoch(epoch);
    return checkpointLength;
  }

  /// Waits until cache/index synchronization already queued by this session
  /// has settled. Composition owners use this before removing an idle physical
  /// session from the registry, so a newly-created same-id generation cannot
  /// race a stale index write from the retired generation.
  Future<void> settleCacheMutations() => _cacheMutationTail;

  Future<void> dispose() async {
    if (_state == DownloadState.disposed) {
      return;
    }
    if (_resetting ||
        _disposing ||
        _restoring ||
        _pendingIngressAttachments.isNotEmpty) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download session lifecycle operation is already active',
      );
    }
    _flushCommittedTrace();
    if (_writer != null || _run != null) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'cannot dispose while work is active',
      );
    }
    _disposing = true;
    try {
      // Disposal is a lifecycle boundary just like reset/eviction. Advance
      // the epoch before any awaited artifact/index work so late restore,
      // append, seal, promote, or replay completions cannot publish after the
      // session has begun closing.
      _ingressProjectionRevision++;
      _epoch = _epoch.next();
      // Session disposal owns the final physical lifecycle boundary. Detach
      // projection listeners before resetting the native ingresses so a late
      // observer cannot retain Reader callbacks or re-enter a session that is
      // already closing.
      for (final projection in _ingressProjections.values) {
        projection.detach();
      }
      // The Reader/source-pool owner disposes the native ingress separately.
      // Resetting it here is both unnecessary and unsafe when that owner has
      // already retired the ingress during a replacement race; disposal must
      // remain idempotent at this boundary.
      _ingressProjections.clear();
      _demandPriorities.clear();
      _legacyDemanded = false;
      _dropResidentReplayRangeCapability();
      await _residentReplayCloseTail;
      // Cache synchronization is a separate serialized persistence tail. Do
      // not close the artifact/session while a prior index operation can still
      // touch the cache backend; the epoch guard above turns that operation
      // into a no-op, and awaiting the tail establishes the shutdown boundary.
      await _cacheMutationTail;
      await artifact.dispose();
      final releaseBacking = _borrowedBackingRelease;
      if (releaseBacking != null) {
        releaseBacking();
        _borrowedBackingRelease = null;
        _borrowedBackingCanBecomeDurableFinal = false;
      }
      _cacheMutationOwner = null;
      _state = DownloadState.disposed;
      _notifySnapshot();
      _snapshotListeners.clear();
      _committedProgressListeners.clear();
    } finally {
      _disposing = false;
    }
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

  /// Returns the generation-local encoded prefix retained by the physical
  /// ingress owner. Resident artifact-cache sessions intentionally may have an
  /// empty [Artifact], so callers must not infer source metadata from that file.
  Uint8List readIngressPrefix(int maxBytes) {
    if (maxBytes <= 0 || _prefix.isEmpty) return Uint8List(0);
    final end = maxBytes < _prefix.length ? maxBytes : _prefix.length;
    return Uint8List.fromList(_prefix.sublist(0, end));
  }

  /// Returns only the generation-local encoded metadata authority.
  ///
  /// Presentation/content sniffing must use this instead of [readSourcePrefix]:
  /// expanding a metadata probe into the Artifact body would force an active
  /// receiving IOSink to flush before the file can be read back. Decoder source
  /// growth remains the owner of larger encoded prefixes.
  int get sourceMetadataPrefixLength => _prefix.length;

  Uint8List readSourceMetadataPrefix() =>
      readIngressPrefix(_sourceMetadataPrefixLength);

  /// Reads an encoded prefix through this physical generation's body owner.
  /// Small metadata reads hit the generation-local ingress prefix. Larger
  /// reads use the external replay authority for resident bodies and the
  /// session Artifact only for ordinary artifact-backed generations.
  Future<Uint8List> readSourcePrefix(
    int maxBytes, {
    DownloadResidentReplayChunks? residentReplayChunks,
  }) async {
    _requireNotDisposed();
    final epoch = _epoch;
    if (maxBytes <= 0 || committedLength <= 0) return Uint8List(0);
    final end = maxBytes < committedLength ? maxBytes : committedLength;
    if (end <= _prefix.length) {
      _requireEpoch(epoch);
      return Uint8List.fromList(_prefix.sublist(0, end));
    }
    if (!_residentBodyBacked) {
      final result = await artifact.readPrefix(end);
      _requireEpoch(epoch);
      return Uint8List.fromList(result);
    }
    final replay = residentReplayChunks;
    if (replay == null) {
      _requireEpoch(epoch);
      return readIngressPrefix(end);
    }
    final chunks = await replay(end);
    _requireEpoch(epoch);
    final builder = BytesBuilder(copy: false);
    var remaining = end;
    await for (final rawChunk in chunks) {
      _requireEpoch(epoch);
      if (remaining <= 0) break;
      final chunk = rawChunk is Uint8List
          ? rawChunk
          : Uint8List.fromList(rawChunk);
      if (chunk.length <= remaining) {
        builder.add(chunk);
        remaining -= chunk.length;
      } else {
        builder.add(chunk.sublist(0, remaining));
        remaining = 0;
      }
    }
    _requireEpoch(epoch);
    final result = builder.takeBytes();
    if (result.length != end) {
      throw Failure(
        code: ErrorCode.artifactCorruption,
        message: 'resident source prefix replay was short: '
            '${result.length}/$end',
      );
    }
    return result;
  }

  void _appendSourceMetadataPrefix(int offset, Uint8List chunk) {
    if (chunk.isEmpty || _prefix.length >= _sourceMetadataPrefixLength) {
      return;
    }
    // Prefix facts are only valid when bytes are contiguous from offset zero.
    // Restored partials pre-populate [_prefix]; resumed suffix writes therefore
    // do not need to reconstruct source metadata from a non-zero offset.
    if (offset > _prefix.length) return;
    final skip = _prefix.length - offset;
    if (skip >= chunk.length) return;
    final remaining = _sourceMetadataPrefixLength - _prefix.length;
    final available = chunk.length - skip;
    final take = remaining < available ? remaining : available;
    _prefix.addAll(chunk.sublist(skip, skip + take));
    _contentKind = sniffContent(_prefix);
    _refreshSourceCanvasFromPrefix();
  }

  Future<Map<String, Object?>?> _readPromotedMetaForOwnership() async {
    final finalFile = File(artifact.finalPath);
    if (!await finalFile.exists()) return null;
    for (final path in <String>[
      artifact.finalMetaPath,
      '${artifact.finalMetaPath}.tmp',
      // A crash after the partial-to-final rename but before the ready-sidecar
      // rename can leave the old partial sidecar as the only ownership proof.
      // Inspect it before Artifact.restore can promote that metadata.
      artifact.metaPath,
    ]) {
      try {
        final raw = jsonDecode(await File(path).readAsString());
        if (raw is Map) {
          return Map<String, Object?>.from(raw);
        }
      } on FileSystemException {
        // A sidecar may disappear during promotion; Artifact.restore owns the
        // authoritative retry/recovery behavior for that race.
      } on FormatException {
        // Malformed metadata is not an ownership proof. Artifact.restore will
        // rehash the body and apply its normal metadata recovery policy.
      } on TypeError {
        // A JSON value with non-string keys is malformed metadata, not a
        // foreign ownership claim.
      }
    }
    return null;
  }

  void _refreshSourceCanvasFromPrefix() {
    if (_sourceCanvasWidth != null || _sourceCanvasHeight != null) return;
    if (_prefix.length < 8) return;
    try {
      final encodedKind = sniffEncodedImageKind(_prefix);
      if (encodedKind == EncodedImageKind.webp) {
        final info = parseWebpPrefixInfo(Uint8List.fromList(_prefix));
        if (info == null) return;
        _sourceCanvasWidth = info.width;
        _sourceCanvasHeight = info.height;
        return;
      }
      final dimensions = parseEncodedImageDimensions(
        _prefix,
        kind: encodedKind,
      );
      if (dimensions == null) return;
      _sourceCanvasWidth = dimensions.width;
      _sourceCanvasHeight = dimensions.height;
    } on FormatException {
      // Content sniffing remains the authority for type classification. A bad
      // or incomplete metadata header must not fail the transfer generation.
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
    _notifySnapshot();
  }

  void _flushCommittedTrace() {
    if (_pendingCommitTraceBytes == 0) {
      return;
    }
    _recordTrace(
      TraceEventKind.bytesCommitted,
      <String, Object?>{
        'bytes': _pendingCommitTraceBytes,
        'chunks': _pendingCommitTraceChunks,
        'committedLength': committedLength,
        'kind': _contentKind.name,
        'cacheResident': _residentBodyBacked,
        'residentBodyBacked': _residentBodyBacked,
        if (residentBodyAuthority != null)
          'residentBodyAuthority': residentBodyAuthority!.name,
        if (residentSource != null) 'residentSource': residentSource,
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
    final projectionSnapshot = projection.snapshot;
    if (projectionSnapshot.epoch != _epoch) {
      // A physical reset may advance this session beyond epoch zero while its
      // artifact is still empty. Fresh Reader projections are constructed at
      // epoch zero, so an actually empty projection may be aligned to the
      // current physical generation before publication.
      //
      // committedLength == 0 does NOT prove the Reader projection is empty:
      // callers may already have a decoder-usable local prefix. Never erase
      // that consumer-owned source to make epochs line up. A non-empty/stated
      // projection must instead use the synchronized attachment path.
      final projectionIsEmpty = projectionSnapshot.length == 0 &&
          projection.source == null &&
          projectionSnapshot.failure == null;
      if (!projectionIsEmpty) {
        throw const Failure(
          code: ErrorCode.invalidState,
          message:
              'non-empty ingress projection requires synchronized attachment',
        );
      }
      projection.reset(_epoch);
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
    DownloadIngressProjection projection, {
    DownloadResidentReplayChunks? residentReplayChunks,
    DownloadResidentReplayChunksWithControl? controlledResidentReplayChunks,
    DownloadArtifactReplayRangeChunksWithControl?
        controlledArtifactReplayRangeChunks,
    TaskControl? control,
    int preferredInitialProbeLength = 0,
  }) async {
    _requireNotDisposed();
    control?.throwIfCancelled();
    final existing = _ingressProjections[projection.scopeId];
    if (existing != null && !identical(existing, projection)) {
      throw ArgumentError.value(
        projection.scopeId,
        'projection.scopeId',
        'already attached to another ingress projection',
      );
    }
    if (identical(existing, projection)) return;
    if (_pendingIngressAttachments.containsKey(projection.scopeId)) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'Reader ingress projection attachment is already active',
      );
    }

    final attachmentToken = Object();
    _pendingIngressAttachments[projection.scopeId] = attachmentToken;
    projection.beginSynchronizedReplay();

    Future<Stream<List<int>>> openArtifactReplay(
      int start,
      int endExclusive, {
      required int chunkSize,
    }) {
      final scheduled = controlledArtifactReplayRangeChunks;
      final attachmentControl = control;
      if (scheduled != null && attachmentControl != null) {
        return scheduled(
          start,
          endExclusive,
          chunkSize: chunkSize,
          control: attachmentControl,
        );
      }
      return Future<Stream<List<int>>>.value(
        artifact.readChunks(
          chunkSize: chunkSize,
          start: start,
          endExclusive: endExclusive,
        ),
      );
    }

    try {
      // A new Reader must not wait for a multi-megabyte physical WebP partial
      // to be copied in full before it can decode frame 0. Replay only the
      // decoder-owned first-playable/required prefix (or the shared unresolved
      // quantum), publish that Reader-local source, then keep catching up the
      // remaining authoritative suffix in this same synchronized join.
      //
      // The projection is still excluded from physical live fan-out until the
      // full committed boundary is stable. Physical growth during catch-up is
      // detected by the existing revision loop, so early source publication
      // does not invent a second byte owner or lose appended suffixes.
      if (!_residentBodyBacked &&
          _contentKind == ContentKind.webp &&
          committedLength > 0) {
        while (true) {
          _requireNotDisposed();
          control?.throwIfCancelled();
          if (!identical(
            _pendingIngressAttachments[projection.scopeId],
            attachmentToken,
          )) {
            throw const Failure(
              code: ErrorCode.cancelled,
              message: 'Reader ingress projection attachment was withdrawn',
            );
          }
          final epoch = _epoch;
          final targetLength = committedLength;
          final initialQuantum = webpDecodePrefixQuantumBytesFor(id);
          // A Reader-local decoder retry floor is learned only from an explicit
          // needMoreData result. Replaying directly to that already-proven
          // insufficient boundary skips redundant decode wakeups without
          // treating the floor as playability evidence or inheriting physical
          // transport state from another Reader.
          final requestedInitialProbeLength =
              preferredInitialProbeLength > initialQuantum
                  ? preferredInitialProbeLength
                  : initialQuantum;
          final initialProbeLength = requestedInitialProbeLength < targetLength
              ? requestedInitialProbeLength
              : targetLength;
          final initialReadChunkBytes =
              initialProbeLength > localWebpDecodePrefixQuantumBytes
                  ? localWebpDecodePrefixQuantumBytes
                  : initialProbeLength;
          final totalLength = _totalLength;
          projection.expectLength(totalLength);
          final before = projection.snapshot;
          final initialChunks = await openArtifactReplay(
            0,
            initialProbeLength,
            chunkSize: initialReadChunkBytes > 0
                ? initialReadChunkBytes
                : 256 * 1024,
          );
          await projection.rebuild(
            epoch: epoch,
            chunks: _replayEpochChunks(
              epoch,
              initialChunks,
              control: control,
            ),
            sealed: (_state == DownloadState.sealed ||
                    _state == DownloadState.promoted) &&
                initialProbeLength == targetLength,
          );
          control?.throwIfCancelled();
          if (!identical(
            _pendingIngressAttachments[projection.scopeId],
            attachmentToken,
          )) {
            throw const Failure(
              code: ErrorCode.cancelled,
              message: 'Reader ingress projection attachment was withdrawn',
            );
          }
          // Growth preserves the prefix. Reset/replacement does not. If the
          // physical epoch changed or truncated below the replayed prefix, retry
          // against the new generation before exposing any source.
          if (_epoch != epoch || committedLength < initialProbeLength) {
            continue;
          }
          projection.publishSynchronizedReplayPrefix();
          _traceIngressProjection(
            projection.scopeId,
            before,
            projection.snapshot,
          );
          _recordTrace(
            TraceEventKind.artifactSource,
            <String, Object?>{
              'stage': 'reader-ingress-late-join',
              'action': 'decoder-probe-published',
              'publishLength': initialProbeLength,
              'physicalCommittedLength': committedLength,
              'preferredInitialProbeLength': preferredInitialProbeLength,
              'initialReadChunkBytes': initialReadChunkBytes,
              'replayBasis': preferredInitialProbeLength > initialQuantum
                  ? 'reader-local-decoder-retry-floor'
                  : 'reader-local-probe',
            },
          );
          break;
        }
      }
      while (true) {
        _requireNotDisposed();
        control?.throwIfCancelled();
        if (!identical(
          _pendingIngressAttachments[projection.scopeId],
          attachmentToken,
        )) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'Reader ingress projection attachment was withdrawn',
          );
        }
        final revision = _ingressProjectionRevision;
        final epoch = _epoch;
        final targetLength = committedLength;
        final totalLength = _totalLength;
        final sealed = _state == DownloadState.sealed ||
            _state == DownloadState.promoted;
        projection.expectLength(totalLength);
        final before = projection.snapshot;
        final current = projection.snapshot;

        // Build once, then catch up same-epoch growth by appending only the
        // newly committed artifact suffix. WebP late joins may already have
        // published a decoder-usable prefix above; the suffix must stay on that
        // same native source. Rebuilding from byte zero on every moving boundary
        // would dispose a source decode may already have observed and also turns
        // streaming catch-up into quadratic local I/O.
        final canAppendSuffix = !_residentBodyBacked &&
            current.epoch == epoch &&
            current.length > 0 &&
            current.length <= targetLength &&
            !current.sealed &&
            current.failure == null;
        if (canAppendSuffix) {
          var offset = current.length;
          final remainingSuffix = targetLength - offset;
          if (remainingSuffix > 0) {
            final suffixChunks = await openArtifactReplay(
              offset,
              targetLength,
              chunkSize: 256 * 1024,
            );
            await for (final chunk in _replayEpochChunks(
              epoch,
              suffixChunks,
              control: control,
            )) {
              control?.throwIfCancelled();
              projection.append(epoch: epoch, offset: offset, bytes: chunk);
              offset += chunk.length;
            }
          }
          if (sealed) {
            projection.seal(epoch);
          }
        } else {
          final Stream<List<int>> chunks;
          if (_residentBodyBacked) {
            final replay = residentReplayChunks;
            if (replay == null) {
              throw const Failure(
                code: ErrorCode.invalidState,
                message: 'resident-cache projection replay requires durable byte authority',
              );
            }
            final controlledReplay = controlledResidentReplayChunks;
            final residentChunks = controlledReplay != null && control != null
                ? await controlledReplay(
                    targetLength,
                    control: control,
                  )
                : await replay(targetLength);
            chunks = _replayEpochChunks(
              epoch,
              residentChunks,
              control: control,
            );
          } else {
            final artifactChunks = await openArtifactReplay(
              0,
              targetLength,
              chunkSize: 256 * 1024,
            );
            chunks = _replayEpochChunks(
              epoch,
              artifactChunks,
              control: control,
            );
          }
          await projection.rebuild(
            epoch: epoch,
            chunks: chunks,
            sealed: sealed,
          );
          projection.expectLength(totalLength);
        }
        control?.throwIfCancelled();
        _traceIngressProjection(projection.scopeId, before, projection.snapshot);

        final stillSealed = _state == DownloadState.sealed ||
            _state == DownloadState.promoted;
        final physicalBoundaryChanged =
            _ingressProjectionRevision != revision ||
                _epoch != epoch ||
                committedLength != targetLength ||
                _totalLength != totalLength ||
                stillSealed != sealed;
        if (physicalBoundaryChanged) {
          continue;
        }

        final replayed = projection.snapshot;
        final projectionCaughtUp = replayed.epoch == epoch &&
            replayed.length == targetLength &&
            replayed.sealed == sealed &&
            replayed.failure == null;
        if (!projectionCaughtUp) {
          throw Failure(
            code: ErrorCode.source,
            message:
                'Reader ingress projection did not reach the authoritative physical boundary',
          );
        }

        control?.throwIfCancelled();
        // No await after the state check: later physical mutations see this
        // projection in the live fan-out before they can append/reset/seal it.
        // A WebP source may already be published at a decoder-usable prefix;
        // joining fan-out here closes the catch-up phase without changing byte
        // ownership or replacing that source.
        if (!identical(
          _pendingIngressAttachments[projection.scopeId],
          attachmentToken,
        )) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'Reader ingress projection attachment was withdrawn',
          );
        }
        _ingressProjections[projection.scopeId] = projection;
        projection.finishSynchronizedReplay();
        _notifySnapshot();
        return;
      }
    } catch (error) {
      // A failed late replay is surfaced by the Reader-local registry. A WebP
      // prefix may already have been published; the registry projects failure
      // onto that same Reader-local source rather than silently replacing it.
      rethrow;
    } finally {
      if (identical(
        _pendingIngressAttachments[projection.scopeId],
        attachmentToken,
      )) {
        _pendingIngressAttachments.remove(projection.scopeId);
      }
    }
  }

  bool detachIngressProjection(String scopeId) {
    final removed = _ingressProjections.remove(scopeId);
    final pending = _pendingIngressAttachments.remove(scopeId);
    if (removed == null && pending == null) return false;
    // A synchronized attachment may be between its replay awaits. Advance
    // the same revision used by append/reset/seal so a detach cannot be
    // followed by a stale replay inserting the projection again.
    _ingressProjectionRevision++;
    _notifySnapshot();
    return true;
  }

  Future<void> _restoreIngressIfNeeded({required bool sealed}) async {
    for (final projection in List<DownloadIngressProjection>.of(
      _ingressProjections.values,
    )) {
      final current = projection.snapshot;
      final expectedLength = artifact.committedLength;
      final alreadyAuthoritative =
          current.epoch == _epoch &&
          current.length == expectedLength &&
          current.kind == _contentKind &&
          current.sealed == sealed &&
          current.failure == null;
      if (alreadyAuthoritative) continue;
      await _rebuildIngressProjection(
        projection,
        sealed: sealed,
      );
    }
  }

  Future<void> _rebuildIngressProjection(
    DownloadIngressProjection projection, {
    required bool sealed,
    TaskControl? control,
  }) async {
    final before = projection.snapshot;
    final epoch = _epoch;
    final targetLength = artifact.committedLength;
    if (!_residentBodyBacked &&
        _contentKind == ContentKind.webp &&
        targetLength > 0) {
      final initialQuantum = webpDecodePrefixQuantumBytesFor(id);
      final initialProbeLength = initialQuantum < targetLength
          ? initialQuantum
          : targetLength;
      await projection.rebuild(
        epoch: epoch,
        chunks: _replayEpochChunks(
          epoch,
          artifact.readChunks(
            chunkSize: initialProbeLength > 0
                ? initialProbeLength
                : 256 * 1024,
            endExclusive: initialProbeLength,
          ),
          control: control,
        ),
        sealed: sealed && initialProbeLength == targetLength,
      );
      _requireEpoch(epoch);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
      if (initialProbeLength < targetLength) {
        var offset = initialProbeLength;
        final remainingToTarget = targetLength - offset;
        if (remainingToTarget > 0) {
          await for (final chunk in _replayEpochChunks(
            epoch,
            artifact.readChunks(
              chunkSize: 256 * 1024,
              start: offset,
              endExclusive: targetLength,
            ),
            control: control,
          )) {
            control?.throwIfCancelled();
            projection.append(epoch: epoch, offset: offset, bytes: chunk);
            offset += chunk.length;
          }
        }
        if (sealed) {
          projection.seal(epoch);
        }
        _requireEpoch(epoch);
        _traceIngressProjection(
          projection.scopeId,
          before,
          projection.snapshot,
        );
      }
      return;
    }
    await projection.rebuild(
      epoch: epoch,
      chunks: _replayEpochChunks(
        epoch,
        artifact.readChunks(
          chunkSize: 256 * 1024,
          endExclusive: targetLength,
        ),
        control: control,
      ),
      sealed: sealed,
    );
    _requireEpoch(epoch);
    _traceIngressProjection(projection.scopeId, before, projection.snapshot);
  }

  Stream<List<int>> _replayEpochChunks(
    SourceEpoch epoch,
    Stream<List<int>> chunks, {
    TaskControl? control,
  }) async* {
    await for (final chunk in _replayChunks(chunks, control: control)) {
      _requireEpoch(epoch);
      yield chunk;
    }
  }

  void _expectIngressLength(int? length) {
    for (final projection in List<DownloadIngressProjection>.of(
      _ingressProjections.values,
    )) {
      projection.expectLength(length);
    }
  }

  void _resetIngressProjections(SourceEpoch epoch) {
    for (final projection in List<DownloadIngressProjection>.of(
      _ingressProjections.values,
    )) {
      final before = projection.snapshot;
      projection.reset(epoch);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
    }
  }

  void _sealIngressProjections(SourceEpoch epoch) {
    for (final projection in List<DownloadIngressProjection>.of(
      _ingressProjections.values,
    )) {
      final before = projection.snapshot;
      projection.seal(epoch);
      _traceIngressProjection(projection.scopeId, before, projection.snapshot);
    }
  }

  void _appendIngress(SourceEpoch epoch, int offset, List<int> bytes) {
    for (final projection in List<DownloadIngressProjection>.of(
      _ingressProjections.values,
    )) {
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
      _recordTrace(
        TraceEventKind.sourceReady,
        <String, Object?>{
          'kind': after.kind.name,
          'length': after.length,
          'readerLocalLength': after.length,
          'physicalCommittedLength': committedLength,
          'physicalState': _state.name,
          'projectionScope': scopeId,
        },
      );
    }
    if (before.failure == null && after.failure != null) {
      _recordTrace(
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
    final rawPhysical = meta['physicalMedia'];
    if (rawPhysical is Map) {
      try {
        return PhysicalMediaId.fromJson(
              Map<String, Object?>.from(rawPhysical),
            ) ==
            physicalId;
      } on Object {
        return false;
      }
    }
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
    final rawPhysical = meta['physicalMedia'];
    if (rawPhysical is Map) {
      try {
        return PhysicalMediaId.fromJson(
              Map<String, Object?>.from(rawPhysical),
            ) !=
            physicalId;
      } on Object {
        // Malformed metadata is not enough evidence to delete media bytes.
        return false;
      }
    }
    final key = meta['downloadKey'];
    if (key == id.key) return false;
    final raw = meta['download'];
    if (raw is Map) {
      try {
        // The structured identity is authoritative across the v1 delimiter
        // key and the framed v2 key. This keeps older metadata for the same
        // DownloadId from being mistaken for a foreign artifact after a key
        // format migration.
        return DownloadId.fromJson(Map<String, Object?>.from(raw)) != id;
      } on Object {
        // Malformed network metadata is not proof that the media bytes belong
        // to another DownloadId. Preserve the authoritative partial.
        return false;
      }
    }
    if (key is String) return true;
    return false;
  }

  Future<bool> _beginDurablePromotion({
    required SourceEpoch expectedEpoch,
  }) async {
    final mutationOwner = _cacheMutationOwner;
    if (mutationOwner != null) {
      final journaled = await mutationOwner.beginDownloadCachePromotion(
        this,
        expectedEpoch: expectedEpoch,
      );
      if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
        if (journaled) {
          await mutationOwner.abortDownloadCachePromotion(this);
        }
        _requireEpoch(expectedEpoch);
      }
      return journaled;
    }
    final cache = index;
    if (cache is! ArtifactPromotionIndex) return false;
    final promotionIndex = cache as ArtifactPromotionIndex;
    await promotionIndex.beginArtifactPromotion(
      id: id,
      physicalId: physicalId,
      sourceAccessLocator: artifact.partialPath,
      destinationAccessLocator: artifact.finalPath,
      bytes: artifact.committedLength,
      checksum: artifact.checksum,
      storageRootId: storageRootId,
    );
    if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
      await promotionIndex.removeArtifactPromotion(physicalId.key);
      _requireEpoch(expectedEpoch);
    }
    return true;
  }

  Future<void> _commitDurablePromotion({
    required SourceEpoch expectedEpoch,
  }) async {
    if (_epoch != expectedEpoch || _state == DownloadState.disposed) return;
    final mutationOwner = _cacheMutationOwner;
    if (mutationOwner != null) {
      await mutationOwner.commitDownloadCachePromotion(
        this,
        expectedEpoch: expectedEpoch,
      );
      return;
    }
    final cache = index;
    if (cache is ArtifactPromotionIndex) {
      final promotionIndex = cache as ArtifactPromotionIndex;
      await promotionIndex.commitArtifactPromotion(physicalId.key);
    }
  }

  Future<void> _syncCache(
    CacheState state, {
    required SourceEpoch expectedEpoch,
    int? committedLength,
  }) => _enqueueCacheMutation<void>(() async {
        if (committedLength != null && state != CacheState.partial) {
          throw StateError('explicit committed length is only valid for partial cache sync');
        }
        final mutationOwner = _cacheMutationOwner;
        if (mutationOwner != null) {
          await mutationOwner.syncDownloadCache(
            this,
            state,
            expectedEpoch: expectedEpoch,
            committedLength: committedLength,
          );
          return;
        }
        if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
          return;
        }
        final persistedLength = committedLength ?? artifact.committedLength;
        if (persistedLength < 0 || persistedLength > artifact.committedLength) {
          throw StateError('cache sync length exceeds committed artifact prefix');
        }
        final cache = index;
        final physicalCache = _physicalPartialIndex;
        if (artifact.state == ArtifactState.empty ||
            (state == CacheState.partial && persistedLength == 0)) {
          return;
        }
        final now = DateTime.now().toUtc().microsecondsSinceEpoch;
        if (state == CacheState.partial &&
            !physicalId.isExactFallback &&
            physicalCache != null) {
          final existingPhysical =
              await physicalCache.getPhysicalPartial(physicalId);
          if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
            return;
          }
          final writtenPhysical = PhysicalPartialRecord(
            id: physicalId,
            path: artifact.partialPath,
            bytes: persistedLength,
            checksum: artifact.checksum,
            createdUs: existingPhysical?.createdUs ?? now,
            touchedUs: now,
            checksumAlgorithm: existingPhysical?.checksumAlgorithm ?? 'crc32',
            storageRootId: storageRootId,
          );
          await physicalCache.putPhysicalPartial(writtenPhysical);
          if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
            final current = await physicalCache.getPhysicalPartial(physicalId);
            if (current == writtenPhysical) {
              await physicalCache.removePhysicalPartial(physicalId);
            }
          }
          return;
        }
        if (cache == null) return;
        final existing = await cache.get(id.key);
        if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
          return;
        }
        final writtenPath = state == CacheState.ready
            ? artifact.finalPath
            : artifact.partialPath;
        final written = CacheRec(
          id: id,
          state: state,
          path: writtenPath,
          bytes: persistedLength,
          checksum: artifact.checksum,
          createdUs: existing?.createdUs ?? now,
          touchedUs: now,
          pinned: existing?.pinned ?? false,
          checksumAlgorithm: existing?.checksumAlgorithm ?? 'crc32',
          artifactId: existing?.path == writtenPath ? existing!.artifactId : '',
          storageRootId: storageRootId,
        );
        await cache.put(written);
        if (state == CacheState.ready &&
            !physicalId.isExactFallback &&
            cache is PhysicalMediaArtifactIndex) {
          await (cache as PhysicalMediaArtifactIndex)
              .putPhysicalMediaArtifactBinding(
            id: physicalId,
            artifactId: written.effectiveArtifactId,
            createdUs: written.createdUs,
            touchedUs: written.touchedUs,
          );
          if (_epoch == expectedEpoch &&
              _state != DownloadState.disposed &&
              cache is PhysicalPartialIndex) {
            await (cache as PhysicalPartialIndex).removePhysicalPartial(physicalId);
          }
        }
        if (_epoch != expectedEpoch || _state == DownloadState.disposed) {
          // The lifecycle boundary can advance while the backend put is in
          // flight. A pre-put epoch check cannot prevent that stale write;
          // remove only the exact row this operation wrote so a newer
          // binding for the same logical key is not blindly deleted.
          final current = await cache.get(id.key);
          if (current != null && _sameCacheRecord(current, written)) {
            await cache.remove(id.key);
          }
          if (!physicalId.isExactFallback &&
              cache is PhysicalMediaArtifactIndex) {
            final currentPhysical =
                await (cache as PhysicalMediaArtifactIndex)
                    .getPhysicalMediaArtifact(physicalId);
            if (currentPhysical?.artifactId == written.effectiveArtifactId) {
              await (cache as PhysicalMediaArtifactIndex)
              .removePhysicalMediaArtifactBinding(physicalId);
            }
          }
        }
      });

  bool _sameCacheRecord(CacheRec first, CacheRec second) =>
      first.id == second.id &&
      first.state == second.state &&
      first.path == second.path &&
      first.bytes == second.bytes &&
      first.checksum.trim().toLowerCase() ==
          second.checksum.trim().toLowerCase() &&
      first.createdUs == second.createdUs &&
      first.touchedUs == second.touchedUs &&
      first.pinned == second.pinned &&
      first.checksumAlgorithm.trim().toLowerCase() ==
          second.checksumAlgorithm.trim().toLowerCase() &&
      first.effectiveArtifactId == second.effectiveArtifactId &&
      first.storageRootId == second.storageRootId;

  Future<T> _enqueueCacheMutation<T>(Future<T> Function() operation) {
    final previous = _cacheMutationTail;
    final current = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    _cacheMutationTail = current.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _recordTrace(
          TraceEventKind.taskFailed,
          <String, Object?>{
            'stage': 'cache-mutation-tail',
            'error': '$error',
            'stackTrace': '$stackTrace',
          },
        );
      },
    );
    return current;
  }

  Future<void> _restartArtifact({bool deleteFinal = false}) async {
    await artifact.reset(deleteFinal: deleteFinal);
    await artifact.restore();
  }

  void _markLifecycleFailure(Object error, {required String operation}) {
    _state = DownloadState.failed;
    _failure = error is Failure
        ? error
        : Failure(code: ErrorCode.network, message: '$error', cause: error);
    _flushCommittedTrace();
    _recordTrace(
      TraceEventKind.downloadState,
      <String, Object?>{
        'state': _state.name,
        'operation': operation,
        'error': '$_failure',
      },
    );
    _notifySnapshot();
  }

  bool _runActivityIsCurrent() {
    final run = _run;
    return run == null || run.epoch == _epoch;
  }

  void _requireEpoch(SourceEpoch expected) {
    if (_state == DownloadState.disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'download session is disposed',
      );
    }
    if (_epoch != expected) {
      _recordTrace(
        TraceEventKind.staleWorkRejected,
        <String, Object?>{'epoch': expected.value},
      );
      throw const Failure(
        code: ErrorCode.staleEpoch,
        message: 'download operation completed for a stale epoch',
      );
    }
  }

  void _requireMutationRun(RunLease? expectedRun) {
    if (expectedRun != null) {
      requireRun(expectedRun);
      return;
    }
    if (_run != null) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download has an active transport run',
      );
    }
  }

  void _requireWriter(WriterLease lease) {
    if (_state == DownloadState.disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'download session is disposed',
      );
    }
    try {
      _epoch.requireMatch(lease.epoch);
    } on Failure {
      _recordTrace(
        TraceEventKind.staleWorkRejected,
        <String, Object?>{'writerId': lease.id},
      );
      rethrow;
    }
    if (!identical(_writer, lease)) {
      _recordTrace(
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
    if (_state == DownloadState.disposed || _disposing) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'download session is disposed',
      );
    }
  }

  void _requireNotLifecycleBusy() {
    _requireNotDisposed();
    if (_resetting || _disposing || _restoring) {
      throw const Failure(
        code: ErrorCode.sessionBusy,
        message: 'download session lifecycle operation is already active',
      );
    }
  }

  /// Diagnostics only. Snapshot publication is an independent lifecycle edge
  /// and must be explicit at the state mutation that owns it.
  void _recordTrace(TraceEventKind kind, Map<String, Object?> payload) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: _traceIdentityHash,
        epoch: _epoch.value,
        payload: payload,
      ),
    );
  }

  void _notifyCommittedProgress() {
    if (_committedProgressListeners.isEmpty) return;
    final length = committedLength;
    for (final listener in List<DownloadCommittedProgressListener>.of(
      _committedProgressListeners,
    )) {
      try {
        listener(length);
      } on Object {
        // Durability/diagnostic observers must never change writer success.
      }
    }
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
