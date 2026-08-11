import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'coordinator.dart';
import 'decode_refill_policy.dart';
import 'decode_registry.dart';
import 'decode_session.dart';
import 'download_ingress_projection.dart';
import 'download_ingress_registry.dart';
import 'download_registry.dart';
import 'download_session.dart';
import 'download_transfer_owner.dart';
import 'frame_budget.dart';
import 'net_lane.dart';
import 'playback_gate.dart';
import 'retry_policy.dart';
import 'source_progress.dart';
import 'upload_registry.dart';
import 'upload_session.dart';

typedef TransportPick = Transport Function(Uri uri);
typedef DecodeWork = Future<void> Function(
  DecodeId id,
  DecodeDemand demand,
  CancelToken token,
);
typedef UploadWork = Future<void> Function(
  DecodeId id,
  UploadDemand demand,
  CancelToken token,
);
typedef Sleep = Future<void> Function(Duration delay);
typedef DownloadPrepare = Future<void> Function(DownloadSession session);
typedef DownloadObserve = void Function(DownloadSession session);

Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);

final class LiveCoordinator implements Coordinator, PlaybackCoordinator {
  LiveCoordinator({
    required this.registry,
    required TransportPick transportFor,
    this.ingresses,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    RetryPolicy retry = const RetryPolicy(),
    this.sleep = _defaultSleep,
    this.onDecode,
    this.onUpload,
    this.decodes,
    this.uploads,
    this.budgets,
    this.refillPolicy = const StagedDecodeRefillPolicy(),
    DownloadPrepare? prepareDownload,
    DownloadObserve? onDownloadObserved,
    DownloadTransferConsumer? downloadTransfer,
    NetLane? net,
    DecodeLane? decode,
    UploadLane? upload,
    String Function(DownloadId id)? downloadBucketFor,
    int Function(DownloadId id)? downloadBucketLimitFor,
  })  : decode = decode ?? DecodeLane(maxActive: 2),
        upload = upload ?? UploadLane(maxActive: 1),
        onDownloadObserved = onDownloadObserved {
    retry.validate();
    if (onDecode != null && decodes != null) {
      throw ArgumentError('onDecode and decodes are mutually exclusive');
    }
    if (onUpload != null && uploads != null) {
      throw ArgumentError('onUpload and uploads are mutually exclusive');
    }
    final budgeter = budgets;
    if (budgeter != null &&
        (!identical(budgeter.decodes, decodes) ||
            !identical(budgeter.uploads, uploads))) {
      throw ArgumentError(
        'budgets must use the coordinator decode and upload registries',
      );
    }
    final external = downloadTransfer;
    if (external != null) {
      if (!identical(external.registry, registry)) {
        throw ArgumentError(
          'downloadTransfer must use the coordinator DownloadRegistry',
        );
      }
      if (net != null && !identical(net, external.net)) {
        throw ArgumentError(
          'net must be the physical owner lane when downloadTransfer is set',
        );
      }
      _downloadTransfer = external;
      this.net = external.net;
    } else {
      final localNet = net ?? NetLane(maxActive: 3);
      final owner = DownloadTransferOwner(
        registry: registry,
        clock: clock,
        prepareDownload: prepareDownload,
        net: localNet,
      );
      _ownedDownloadTransferOwner = owner;
      _downloadTransfer = owner.attachConsumer(
        scopeId: 'live-coordinator:${++_fallbackTransferScopeSequence}',
        transportFor: transportFor,
        traceSink: traceSink,
        retry: retry,
        sleep: sleep,
        downloadBucketFor: downloadBucketFor,
        downloadBucketLimitFor: downloadBucketLimitFor,
      );
      this.net = localNet;
    }
  }

  final DownloadRegistry registry;
  final DownloadIngressProjectionRegistry? ingresses;
  final MonoClock clock;
  final TraceSink traceSink;
  final Sleep sleep;
  final DecodeWork? onDecode;
  final UploadWork? onUpload;
  final DecodeRegistry? decodes;
  final UploadRegistry? uploads;
  final FrameBudgeter? budgets;
  final StagedDecodeRefillPolicy refillPolicy;
  final DownloadObserve? onDownloadObserved;
  late final DownloadTransferConsumer _downloadTransfer;
  DownloadTransferOwner? _ownedDownloadTransferOwner;
  late final NetLane net;
  final DecodeLane decode;
  final UploadLane upload;
  static int _fallbackTransferScopeSequence = 0;

  final Map<DownloadId, DownloadDemand> _downloads =
      <DownloadId, DownloadDemand>{};
  final Map<DecodeId, DecodeDemand> _decodes = <DecodeId, DecodeDemand>{};
  final Map<DecodeId, int> _decodeDemandRevisions = <DecodeId, int>{};
  final Map<DecodeId, UploadDemand> _uploads = <DecodeId, UploadDemand>{};
  final Map<DecodeId, int> _uploadDemandRevisions = <DecodeId, int>{};
  final Map<DownloadId, SourceListener> _sourceListeners =
      <DownloadId, SourceListener>{};
  final Map<DownloadId, int> _sourceRevisions = <DownloadId, int>{};
  final Map<DownloadId, int> _sourceWakeLengths = <DownloadId, int>{};
  final Map<DecodeId, int> _decodeSourceRevisions = <DecodeId, int>{};
  final Map<DecodeId, int> _decodeRecoveryAttempts = <DecodeId, int>{};
  final Set<DecodeId> _decodeRecoveryPending = <DecodeId>{};
  final PlaybackGate _playbackGate = PlaybackGate();
  int _revision = 0;
  bool _disposed = false;

  Map<DownloadId, DownloadDemand> get demands =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_downloads);

  /// Current physical task key for diagnostics/tests. Task identity belongs to
  /// the composition transfer owner rather than to a Reader scope.
  String? downloadTaskKeyFor(DownloadId id) =>
      _downloadTransfer.owner.taskKeyFor(id);

  /// Re-applies dynamic physical-transfer scheduling without changing this
  /// Reader's demand claims.
  void refreshDownloadScheduling(String sessionId) {
    if (_disposed) return;
    _downloadTransfer.refreshScheduling();
  }

  Map<DecodeId, DecodeDemand> get decodeDemands =>
      Map<DecodeId, DecodeDemand>.unmodifiable(_decodes);
  Map<DecodeId, UploadDemand> get uploadDemands =>
      Map<DecodeId, UploadDemand>.unmodifiable(_uploads);

  /// Lets the composition physical owner reopen an incomplete exact transfer
  /// after a verified immutable local artifact becomes available.
  void refreshDownloadForLocalArtifact(String sessionId, DownloadId id) {
    if (_disposed || !_downloads.containsKey(id)) return;
    _downloadTransfer.refreshForLocalArtifact(id);
  }

  int _availableSourceRevision(DownloadId id) {
    var available = _sourceRevisions[id] ?? -1;
    final projectionRevision = ingresses?.find(id)?.snapshot.revision ?? -1;
    if (projectionRevision > available) {
      available = projectionRevision;
      _sourceRevisions[id] = projectionRevision;
    }
    return available;
  }

  bool _hasPendingSourceRevision(DecodeId id) {
    final available = _availableSourceRevision(id.download);
    final consumed = _decodeSourceRevisions[id] ?? -1;
    return available > consumed;
  }

  @override
  void reconcile(String sessionId, PipelineDelta update) {
    _revision = update.plan.revision;
    _reconcileDownloads(sessionId, update.diff.downloads);
    _reconcileDecodes(sessionId, update.diff.decodes);
    _reconcileUploads(sessionId, update.diff.uploads);
    _enforceBudget(sessionId);
  }

  Future<void> idle() async {
    while (true) {
      await _downloadTransfer.idle();
      await decode.idle();
      await upload.idle();
      await Future<void>.delayed(Duration.zero);
      if (decode.isIdle && upload.isIdle) {
        await _downloadTransfer.idle();
        return;
      }
    }
  }

  bool freezePlayback(DecodeId id) => uploads?.freezePlayback(id) ?? false;

  bool resumePlayback(DecodeId id) => uploads?.resumePlayback(id) ?? false;

  void syncPlayback(
    ViewportState viewport,
    Map<int, DecodeId> ids,
  ) {
    _playbackGate.apply(
      viewport: viewport,
      ids: ids,
      freeze: (id) {
        final registry = uploads;
        if (registry == null) {
          return false;
        }
        return registry.get(id).freezePlayback();
      },
      resume: (id) {
        final registry = uploads;
        if (registry == null) {
          return false;
        }
        return registry.get(id).resumePlayback();
      },
    );
  }

  bool advanceDueFrame(String sessionId, DecodeId id) {
    final frameIndex = uploads?.takeDueFrame(id);
    if (frameIndex == null) {
      return false;
    }
    return advanceFrame(sessionId, id, frameIndex);
  }

  bool advanceFrame(
    String sessionId,
    DecodeId id,
    int frameIndex,
  ) {
    final registry = uploads;
    if (registry == null) {
      return false;
    }
    upload.cancel(id.key);
    if (!registry.advance(id, frameIndex)) {
      return false;
    }
    // A predecoded successor can be uploaded immediately. If none is ready,
    // the retained output remains visible while decode fills and wakes upload.
    _wakeUpload(sessionId, id);
    _wakeDecode(sessionId, id, force: true);
    return true;
  }

  Future<void> dispose() async {
    _disposed = true;
    _playbackGate.clear(
      freeze: (id) {
        if (uploads?.find(id) == null) {
          return false;
        }
        freezePlayback(id);
        return true;
      },
    );
    for (final entry in _sourceListeners.entries) {
      ingresses?.find(entry.key)?.removeSourceListener(entry.value);
    }
    _sourceListeners.clear();
    _sourceRevisions.clear();
    _sourceWakeLengths.clear();
    _decodeSourceRevisions.clear();
    // This barrier removes only this Reader/command consumer from the
    // composition physical owner. If an active task captured this Reader's
    // transport, dispose waits for that task to physically exit before the
    // Reader may close the transport. Other consumers are not cancelled.
    await _downloadTransfer.dispose();
    final ownedOwner = _ownedDownloadTransferOwner;
    _ownedDownloadTransferOwner = null;
    if (ownedOwner != null) {
      await ownedOwner.dispose();
    }
    decode.cancelAll();
    upload.cancelAll();
    _downloads.clear();
    _decodes.clear();
    _decodeDemandRevisions.clear();
    _uploads.clear();
    _uploadDemandRevisions.clear();
    await Future.wait<void>(<Future<void>>[
      decode.idle(),
      upload.idle(),
    ]);
  }

  void _reconcileDownloads(
    String sessionId,
    MapDiff<DownloadId, DownloadDemand> diff,
  ) {
    for (final id in diff.removed) {
      _downloads.remove(id);
    }
    final observed = <MapEntry<DownloadId, DownloadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ];
    for (final entry in observed) {
      _downloads[entry.key] = entry.value;
    }
    _downloadTransfer.reconcile(sessionId, _revision, diff);
    for (final entry in observed) {
      final session = registry.get(entry.key);
      try {
        onDownloadObserved?.call(session);
      } on Object {
        // Reader-local observers cannot break physical transfer ownership.
      }
      _watchSource(sessionId, entry.key, session);
    }
  }

  void _watchSource(
    String sessionId,
    DownloadId id,
    DownloadSession session,
  ) {
    if (_sourceListeners.containsKey(id)) {
      return;
    }
    void listener(IngressSnap snapshot) {
      // Physical retry/terminal state is owned by DownloadTransferOwner. This
      // Reader-local listener only projects source growth into decode wakeups.
      _sourceRevisions[id] = snapshot.revision;
      final priorLength = _sourceWakeLengths[id];
      final shouldWake = onDecode != null ||
          priorLength == null ||
          snapshot.failure != null ||
          snapshot.sealed ||
          snapshot.length - priorLength >= sourceProgressQuantumBytes;
      if (!shouldWake) {
        return;
      }
      _sourceWakeLengths[id] = snapshot.length;
      _wakeDecodesForSource(sessionId, id);
    }
    final projection = ingresses?.get(session);
    if (projection == null) {
      return;
    }
    _sourceListeners[id] = listener;
    projection.addSourceListener(listener);
  }

  void _reconcileDecodes(
    String sessionId,
    MapDiff<DecodeId, DecodeDemand> diff,
  ) {
    for (final id in diff.removed) {
      _decodes.remove(id);
      _decodeDemandRevisions.remove(id);
      _decodeSourceRevisions.remove(id);
      _decodeRecoveryAttempts.remove(id);
      _decodeRecoveryPending.remove(id);
      decode.cancel(id.key);
      decodes?.detach(id);
    }
    for (final entry in <MapEntry<DecodeId, DecodeDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _decodes[entry.key] = entry.value;
      final demandRevision = _revision;
      _decodeDemandRevisions[entry.key] = demandRevision;
      _resourceTrace(
        sessionId,
        TraceEventKind.decodeDemand,
        entry.key.key,
        entry.value.priority,
        revision: demandRevision,
      );
      if (entry.value.role == PageRole.current) {
        _promoteDecodeToCurrent(sessionId, entry.key, demandRevision);
      }
      if (onDecode == null && decodes == null) {
        continue;
      }
      final submit = diff.changed.containsKey(entry.key)
          ? decode.follow
          : decode.submit;
      final submittedAtMicros = clock.nowMicros();
      submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) => _runDecode(
          sessionId,
          entry.key,
          token,
          demandRevision: demandRevision,
          sourceWake: _hasPendingSourceRevision(entry.key),
          force: true,
          submittedAtMicros: submittedAtMicros,
        ),
      );
    }
  }

  void _promoteDecodeToCurrent(
    String sessionId,
    DecodeId id,
    int revision,
  ) {
    final promotion = decodes?.promotePendingDecodeToCurrent(id) ??
        DecodePriorityPromotion.none;
    if (promotion == DecodePriorityPromotion.none) {
      return;
    }
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.decodePriorityPromoted,
        identityHash: id.key,
        revision: revision,
        payload: <String, Object?>{
          'promotion': promotion.name,
          'role': PageRole.current.name,
        },
      ),
    );
  }

  void _wakeDecodesForSource(String sessionId, DownloadId downloadId) {
    for (final id in _decodes.keys) {
      if (id.download == downloadId) {
        _wakeDecode(sessionId, id, sourceWake: true);
      }
    }
  }

  void _wakeDecode(
    String sessionId,
    DecodeId id, {
    bool sourceWake = false,
    bool force = false,
  }) {
    final demand = _decodes[id];
    if (demand == null || (onDecode == null && decodes == null)) {
      return;
    }
    if (demand.role == PageRole.current) {
      _promoteDecodeToCurrent(
        sessionId,
        id,
        _decodeDemandRevisions[id] ?? _revision,
      );
    }
    final submittedAtMicros = clock.nowMicros();
    final effectiveSourceWake =
        sourceWake || _hasPendingSourceRevision(id);
    decode.follow(
      key: id.key,
      priority: demand.priority,
      task: (token) => _runDecode(
        sessionId,
        id,
        token,
        demandRevision: _decodeDemandRevisions[id] ?? _revision,
        sourceWake: effectiveSourceWake,
        force: force,
        submittedAtMicros: submittedAtMicros,
      ),
    );
  }

  Future<void> _runDecode(
    String sessionId,
    DecodeId id,
    CancelToken token, {
    required int demandRevision,
    required bool sourceWake,
    required bool force,
    required int submittedAtMicros,
  }) async {
    while (true) {
      final current = _decodes[id];
      if (current == null || current.expirationRevision < _revision) {
        return;
      }
      final sourceRevision = _availableSourceRevision(id.download);
      final observedSourceRevision = _decodeSourceRevisions[id] ?? -1;
      final pendingSourceWake = sourceRevision > observedSourceRevision;
      if (sourceWake && !pendingSourceWake) {
        return;
      }

      final registry = decodes;
      final before = registry?.find(id)?.snapshot;
      final preparedDepth = uploads?.preparedDepth(id) ?? 0;
      final refill = registry == null
          ? null
          : _nextDecodeRefill(only: pendingSourceWake ? id : null);
      if (registry != null) {
        if (refill == null) {
          // A null staged-refill decision is not proof that this decode has
          // consumed the latest source revision. During current bootstrap the
          // policy intentionally gates neighbor work and can return null even
          // while this exact DecodeSession is waitingSource. Keep that revision
          // pending unless the session itself proves that no fill is needed.
          if (pendingSourceWake &&
              sourceRevision >= 0 &&
              !_decodeNeedsFill(
                before,
                current,
                preparedDepth: preparedDepth,
                sourceWake: true,
                force: true,
              )) {
            _decodeSourceRevisions[id] = sourceRevision;
          }
          return;
        }
        if (refill.id != id) {
          _wakeDecode(
            sessionId,
            refill.id,
            sourceWake: _hasPendingSourceRevision(refill.id),
            force: true,
          );
          return;
        }
      }
      final effectiveDemand = refill == null
          ? current
          : DecodeDemand(
              role: current.role,
              priority: current.priority,
              targetWatermark: refill.targetWatermark,
              reason: '${current.reason}:refill:${refill.stage}',
              expirationRevision: current.expirationRevision,
              decisionId: current.decisionId,
            );
      if (registry != null &&
          !_decodeNeedsFill(
            before,
            effectiveDemand,
            preparedDepth: preparedDepth,
            sourceWake: pendingSourceWake,
            force: force,
          )) {
        if (pendingSourceWake && sourceRevision >= 0) {
          _decodeSourceRevisions[id] = sourceRevision;
        }
        return;
      }
      final decodeLaneQueueMicros =
          (clock.nowMicros() - submittedAtMicros).clamp(0, 1 << 62).toInt();
      if (refill != null) {
        traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.decodeRefill,
            identityHash: id.key,
            revision: demandRevision,
            payload: <String, Object?>{
              'role': refill.role.name,
              'stage': refill.stage,
              'depth': refill.depth,
              'threshold': refill.threshold,
              'target': refill.targetWatermark,
              'sourceWake': pendingSourceWake,
              'sourceRevision': sourceRevision,
              'consumedSourceRevision': observedSourceRevision,
            },
          ),
        );
      }
      _resourceTrace(
        sessionId,
        TraceEventKind.decodeStarted,
        id.key,
        current.priority,
        revision: demandRevision,
      );
      try {
        DecodeSnapshot? after;
        final work = onDecode;
        if (work != null) {
          await work(id, effectiveDemand, token);
        } else if (registry != null) {
          after = await registry.fill(
            id,
            effectiveDemand,
            token,
            revision: demandRevision,
            preparedDepth: preparedDepth,
            laneQueueMicros: decodeLaneQueueMicros,
            onFrameReady: _uploads.containsKey(id)
                ? (_) {
                    _decodeRecoveryAttempts.remove(id);
                    _decodeRecoveryPending.remove(id);
                    _wakeUpload(sessionId, id);
                  }
                : null,
          );
        }
        if (sourceRevision >= 0) {
          _decodeSourceRevisions[id] = sourceRevision;
        }
        if (after != null &&
            after.state != DecodeState.failed &&
            after.failure == null) {
          _decodeRecoveryAttempts.remove(id);
          _decodeRecoveryPending.remove(id);
        }
        if (work != null || _decodeChangeNeedsUpload(before, after)) {
          _wakeUpload(sessionId, id);
        }
        _enforceBudget(sessionId);
            if (registry != null) {
          _wakeNextDecodeRefill(sessionId, except: id);
        }
      } on Object catch (error) {
        if (error is! Failure || error.code != ErrorCode.cancelled) {
          final failedAtMicros = clock.nowMicros();
          final failedSnapshot = decodes?.find(id)?.snapshot;
          _error(
            sessionId,
            id.key,
            'decode',
            error,
            details: <String, Object?>{
              'role': current.role.name,
              'sourceLength': failedSnapshot?.sourceLength ?? 0,
              'sourceSealed': failedSnapshot?.sourceSealed ?? false,
              'requiredSourceLength':
                  failedSnapshot?.requiredSourceLength ?? 0,
              'failureClass': failedSnapshot?.sourceSealed == true
                  ? 'sealed-source'
                  : 'partial-source',
              'laneQueueMicros': decodeLaneQueueMicros,
              'executionMicros':
                  (failedAtMicros - submittedAtMicros -
                          decodeLaneQueueMicros)
                      .clamp(0, 1 << 62)
                      .toInt(),
              'taskElapsedMicros':
                  (failedAtMicros - submittedAtMicros)
                      .clamp(0, 1 << 62)
                      .toInt(),
            },
          );
          _wakeUpload(sessionId, id);
          final sourceSealed = failedSnapshot?.sourceSealed;
          if (sourceSealed == false) {
            traceSink.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.retryScheduled,
                identityHash: id.key,
                revision: demandRevision,
                payload: <String, Object?>{
                  'stage': 'decode-source-growth',
                  'role': current.role.name,
                  'waitForSourceRevision': true,
                  'sourceLength': failedSnapshot?.sourceLength ?? 0,
                  'requiredSourceLength':
                      failedSnapshot?.requiredSourceLength ?? 0,
                },
              ),
            );
          } else if (current.role == PageRole.current ||
              current.role == PageRole.transition) {
            _scheduleDecodeRecovery(sessionId, id, current);
          }
        }
        return;
      }

      if (!pendingSourceWake) {
        return;
      }
      final latestSourceRevision = _availableSourceRevision(id.download);
      final consumedSourceRevision = _decodeSourceRevisions[id] ?? -1;
      if (consumedSourceRevision >= latestSourceRevision) {
        return;
      }
    }
  }

  void _scheduleDecodeRecovery(
    String sessionId,
    DecodeId id,
    DecodeDemand demand,
  ) {
    final existing = decodes?.find(id)?.snapshot;
    if (existing?.sourceSealed == false) {
      return;
    }
    if (_decodeRecoveryPending.contains(id) || !_decodes.containsKey(id)) {
      return;
    }
    final attempt = (_decodeRecoveryAttempts[id] ?? 0) + 1;
    if (attempt > 4) {
      return;
    }
    _decodeRecoveryAttempts[id] = attempt;
    _decodeRecoveryPending.add(id);
    final demandRevision = _decodeDemandRevisions[id] ?? _revision;
    final delay = Duration(milliseconds: 16 * attempt);
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.retryScheduled,
        identityHash: id.key,
        revision: demandRevision,
        payload: <String, Object?>{
          'stage': 'decode-recovery',
          'attempt': attempt,
          'delayUs': delay.inMicroseconds,
          'role': demand.role.name,
          'bufferedDepth': decodes?.find(id)?.snapshot.depth ?? 0,
        },
      ),
    );
    unawaited(() async {
      try {
        await sleep(delay);
      } finally {
        _decodeRecoveryPending.remove(id);
      }
      final current = _decodes[id];
      if (current == null ||
          (_decodeDemandRevisions[id] ?? _revision) != demandRevision) {
        return;
      }
      final snapshot = decodes?.find(id)?.snapshot;
      if (snapshot == null ||
          (snapshot.state != DecodeState.failed && snapshot.failure == null)) {
        _decodeRecoveryAttempts.remove(id);
        return;
      }
      _wakeDecode(sessionId, id, force: true);
    }());
  }

  DecodeRefillDecision? _nextDecodeRefill({DecodeId? only}) {
    final registry = decodes;
    if (registry == null) {
      return null;
    }
    return refillPolicy.next(
      demands: _decodes,
      depthOf: (id) => registry.find(id)?.snapshot.depth ?? 0,
      terminalOf: (id) {
        final snapshot = registry.find(id)?.snapshot;
        return snapshot != null &&
            snapshot.state == DecodeState.ended &&
            snapshot.failure == null &&
            snapshot.animation.complete &&
            snapshot.animation.frameCount > 1;
      },
      satisfiedOf: (id) {
        final snapshot = registry.find(id)?.snapshot;
        if (snapshot == null || snapshot.failure != null) {
          return false;
        }
        final animation = snapshot.animation;
        if (!animation.complete || animation.frameCount > 1) {
          return false;
        }
        final preparedDepth = uploads?.preparedDepth(id) ?? 0;
        return snapshot.depth + preparedDepth >= 1;
      },
      eligibleOf: (id) {
        if (only != null && id != only) {
          return false;
        }
        final snapshot = registry.find(id)?.snapshot;
        if (snapshot == null ||
            snapshot.failure != null ||
            snapshot.state == DecodeState.failed) {
          return true;
        }
        return snapshot.state != DecodeState.waitingSource ||
            _hasPendingSourceRevision(id);
      },
    );
  }

  void refreshDecodeScheduling(String sessionId, {DecodeId? only}) {
    final decision = _nextDecodeRefill(only: only);
    if (decision == null) return;
    _wakeDecode(
      sessionId,
      decision.id,
      sourceWake: _hasPendingSourceRevision(decision.id),
      force: true,
    );
  }

  void _wakeNextDecodeRefill(String sessionId, {DecodeId? except}) {
    final decision = _nextDecodeRefill();
    if (decision == null) return;
    if (decision.id == except) {
      return;
    }
    _wakeDecode(
      sessionId,
      decision.id,
      sourceWake: _hasPendingSourceRevision(decision.id),
      force: true,
    );
  }

  bool _decodeNeedsFill(
    DecodeSnapshot? snapshot,
    DecodeDemand demand, {
    required int preparedDepth,
    required bool sourceWake,
    required bool force,
  }) {
    if (snapshot == null) {
      return true;
    }
    final targetDepth = demand.targetWatermark > preparedDepth
        ? demand.targetWatermark - preparedDepth
        : 0;
    if (snapshot.failure != null || snapshot.state == DecodeState.failed) {
      return true;
    }
    final animation = snapshot.animation;
    if (animation.complete &&
        animation.frameCount <= 1 &&
        snapshot.depth + preparedDepth >= 1) {
      return false;
    }
    if (snapshot.state == DecodeState.waitingSource && !sourceWake) {
      return false;
    }
    if (sourceWake) {
      return snapshot.state == DecodeState.waitingSource ||
          snapshot.depth < targetDepth;
    }
    if (force) {
      return snapshot.depth < targetDepth;
    }
    return true;
  }

  bool _decodeChangeNeedsUpload(
    DecodeSnapshot? before,
    DecodeSnapshot? after,
  ) {
    if (after == null) {
      return false;
    }
    if (after.depth > (before?.depth ?? 0)) {
      return true;
    }
    if (after.failure != before?.failure) {
      return true;
    }
    return after.state == DecodeState.ended &&
        before?.state != DecodeState.ended;
  }

  void _reconcileUploads(
    String sessionId,
    MapDiff<DecodeId, UploadDemand> diff,
  ) {
    for (final id in diff.removed) {
      _uploads.remove(id);
      _uploadDemandRevisions.remove(id);
      upload.cancel(id.key);
      final decodeDemanded = _decodes.containsKey(id);
      final uploadRegistry = uploads;
      final retainStaticOutput =
          uploadRegistry?.find(id)?.hasRetainableStaticOutput ?? false;
      final decodeRestarted = uploadRegistry?.detach(
            id,
            retainStaticOutput: retainStaticOutput,
          ) ??
          false;
      if (decodeDemanded && decodeRestarted) {
        _wakeDecode(sessionId, id, force: true);
      }
    }
    for (final entry in <MapEntry<DecodeId, UploadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _uploads[entry.key] = entry.value;
      final demandRevision = _revision;
      _uploadDemandRevisions[entry.key] = demandRevision;
      _resourceTrace(
        sessionId,
        TraceEventKind.uploadDemand,
        entry.key.key,
        entry.value.priority,
        revision: demandRevision,
      );
      final uploadRegistry = uploads;
      if (uploadRegistry != null &&
          (entry.value.role == PageRole.current ||
              entry.value.role == PageRole.transition)) {
        uploadRegistry.resumePlayback(entry.key);
      }
      if (entry.value.role == PageRole.last && uploadRegistry != null) {
        upload.cancel(entry.key.key);
        final existing = uploadRegistry.find(entry.key);
        if (existing != null) {
          existing.freezePlayback();
          if (existing.snapshot.frameIndex != null) {
            traceSink.record(
              traceEvent(
                clock: clock,
                sessionId: sessionId,
                kind: TraceEventKind.lastFrameKept,
                identityHash: entry.key.key,
                revision: demandRevision,
                payload: <String, Object?>{
                  'frame': existing.snapshot.frameIndex,
                  'outputBytes': existing.snapshot.outputBytes,
                },
              ),
            );
            continue;
          }
        }
      }
      if (onUpload == null && uploadRegistry == null) {
        continue;
      }
      _submitUpload(
        sessionId,
        entry.key,
        entry.value,
        follow: diff.changed.containsKey(entry.key),
        demandRevision: demandRevision,
      );
    }
  }

  void _wakeUpload(String sessionId, DecodeId id) {
    final demand = _uploads[id];
    if (demand == null || (onUpload == null && uploads == null)) {
      return;
    }
    _submitUpload(
      sessionId,
      id,
      demand,
      follow: true,
      demandRevision: _uploadDemandRevisions[id] ?? _revision,
    );
  }

  void _submitUpload(
    String sessionId,
    DecodeId id,
    UploadDemand demand, {
    bool follow = false,
    required int demandRevision,
  }) {
    final submit = follow ? upload.follow : upload.submit;
    final submittedAtMicros = clock.nowMicros();
    submit(
      key: id.key,
      priority: demand.priority,
      task: (token) async {
        final current = _uploads[id];
        if (current == null || current.expirationRevision < _revision) {
          return;
        }
        final uploadLaneQueueMicros =
            (clock.nowMicros() - submittedAtMicros)
                .clamp(0, 1 << 62)
                .toInt();
        _resourceTrace(
          sessionId,
          TraceEventKind.uploadStarted,
          id.key,
          current.priority,
          revision: demandRevision,
        );
        try {
          final work = onUpload;
          if (work != null) {
            await work(id, current, token);
          } else {
            final registry = uploads;
            if (registry != null) {
              final before = registry.find(id)?.snapshot;
              final after = await registry.prepare(
                id,
                current,
                token,
                revision: demandRevision,
                laneQueueMicros: uploadLaneQueueMicros,
              );
              final producedFrame = after.state == UploadState.ready &&
                  (before?.state != UploadState.ready ||
                      before?.epoch != after.epoch ||
                      before?.frameIndex != after.frameIndex);
              if (producedFrame ||
                  (after.state == UploadState.waitingFrame &&
                      _decodes.containsKey(id))) {
                _wakeDecode(sessionId, id, force: true);
              }
            }
          }
          _enforceBudget(sessionId);
        } on Object catch (error) {
          if (error is! Failure || error.code != ErrorCode.cancelled) {
            final failedAtMicros = clock.nowMicros();
            final taskElapsedMicros =
                (failedAtMicros - submittedAtMicros)
                    .clamp(0, 1 << 62)
                    .toInt();
            _error(
              sessionId,
              id.key,
              'upload',
              error,
              details: <String, Object?>{
                'role': current.role.name,
                'laneQueueMicros': uploadLaneQueueMicros,
                'executionMicros':
                    (taskElapsedMicros - uploadLaneQueueMicros)
                        .clamp(0, 1 << 62)
                        .toInt(),
                'taskElapsedMicros': taskElapsedMicros,
              },
            );
          }
        }
      },
    );
  }

  void _enforceBudget(String sessionId) {
    final budgeter = budgets;
    if (budgeter == null) {
      return;
    }
    final report = budgeter.enforce(
      decodeDemands: _decodes,
      uploadDemands: _uploads,
    );
    if (report.decodedFreed == 0 && report.outputFreed == 0) {
      return;
    }
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.frameBudget,
        revision: _revision,
        payload: <String, Object?>{
          'decodedBefore': report.decodedBefore,
          'decodedAfter': report.decodedAfter,
          'decodedLimit': budgeter.limits.decodedBytes,
          'outputBefore': report.outputBefore,
          'outputAfter': report.outputAfter,
          'outputLimit': budgeter.limits.outputBytes,
          'currentDecoded': report.currentDecoded,
          'currentOutput': report.currentOutput,
        },
      ),
    );
  }

  void _resourceTrace(
    String sessionId,
    TraceEventKind kind,
    String key,
    int priority, {
    int? revision,
  }) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: key,
        revision: revision ?? _revision,
        payload: <String, Object?>{'priority': priority},
      ),
    );
  }

  void _error(
    String sessionId,
    String identity,
    String lane,
    Object error, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: identity,
        revision: _revision,
        payload: <String, Object?>{
          'lane': lane,
          'error': '$error',
          ...details,
        },
      ),
    );
  }
}
