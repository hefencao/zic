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
typedef DownloadPrepareWithControl = TransferPrepareWithControl;
typedef DownloadObserve = void Function(DownloadSession session);
typedef DownloadSessionAcquire = DownloadSession Function(DownloadId id);
typedef DownloadSessionLookup = DownloadSession? Function(DownloadId id);
typedef SourceKindObserve = void Function(DownloadId id, ContentKind kind);
typedef ExternalPresentationRequest = void Function(
  DecodeId id,
  int demandRevision,
);
typedef ExternalPresentationAvailability = bool Function(DecodeId id);

Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);


final class _SourceWatchBinding {
  _SourceWatchBinding({
    required this.session,
    required this.projection,
    required this.listener,
    required this.epoch,
    required this.sourceReady,
  });

  DownloadSession session;
  final DownloadIngressProjection projection;
  final SourceListener listener;
  SourceEpoch epoch;
  bool sourceReady;
}

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
    DownloadPrepareWithControl? prepareDownloadWithControl,
    DownloadObserve? onDownloadObserved,
    DownloadSessionAcquire? downloadSessionFor,
    DownloadSessionLookup? findDownloadSession,
    this.onSourceKindObserved,
    this.onExternalPresentationRequested,
    this.externalPresentationAvailable,
    this.maxSpeculativeExternalPresentationPending = 1,
    DownloadTransferConsumer? downloadTransfer,
    required NetLane net,
    DecodeLane? decode,
    UploadLane? upload,
    String Function(DownloadId id)? downloadBucketFor,
    int Function(DownloadId id)? downloadBucketLimitFor,
  })  : decode = decode ?? DecodeLane(maxActive: 2),
        upload = upload ?? UploadLane(maxActive: 1),
        onDownloadObserved = onDownloadObserved,
        _downloadSessionFor = downloadSessionFor ?? registry.get,
        _findDownloadSession = findDownloadSession ?? registry.find {
    retry.validate();
    if (maxSpeculativeExternalPresentationPending <= 0) {
      throw ArgumentError.value(
        maxSpeculativeExternalPresentationPending,
        'maxSpeculativeExternalPresentationPending',
        'must be positive',
      );
    }
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
      if (!identical(net, external.net)) {
        throw ArgumentError(
          'net must be the physical owner lane when downloadTransfer is set',
        );
      }
      _downloadTransfer = external;
      this.net = external.net;
    } else {
      final owner = DownloadTransferOwner(
        registry: registry,
        clock: clock,
        prepareDownload: prepareDownload,
        prepareDownloadWithControl: prepareDownloadWithControl,
        net: net,
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
      this.net = net;
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
  final DownloadSessionAcquire _downloadSessionFor;
  final DownloadSessionLookup _findDownloadSession;
  final SourceKindObserve? onSourceKindObserved;
  final ExternalPresentationRequest? onExternalPresentationRequested;
  final ExternalPresentationAvailability? externalPresentationAvailable;
  final int maxSpeculativeExternalPresentationPending;
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
  final Set<DecodeId> _externalPresentationPending = <DecodeId>{};
  final Set<DecodeId> _externalPresentationSatisfied = <DecodeId>{};
  final Map<DecodeId, UploadDemand> _uploads = <DecodeId, UploadDemand>{};
  final Map<DecodeId, int> _uploadDemandRevisions = <DecodeId, int>{};
  final Map<DownloadId, DownloadSession> _observedDownloadSessions =
      <DownloadId, DownloadSession>{};
  final Map<DownloadId, _SourceWatchBinding> _sourceWatches =
      <DownloadId, _SourceWatchBinding>{};
  final Set<DownloadId> _sourceRebindWakes = <DownloadId>{};
  final Map<DownloadId, int> _sourceRevisions = <DownloadId, int>{};
  final Map<DownloadId, int> _sourceWakeLengths = <DownloadId, int>{};
  final Map<DownloadId, ContentKind> _sourceKinds = <DownloadId, ContentKind>{};
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

  int _availableSourceRevision(DownloadId id) {
    var available = _sourceRevisions[id] ?? -1;
    final projectionRevision =
        _sourceWatches[id]?.projection.snapshot.revision ?? -1;
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
    final startedAtMicros = clock.nowMicros();
    _revision = update.plan.revision;

    // One accepted DemandPlan is one scheduler transaction. Reader page-boundary
    // revisions routinely change the role/priority of most of the 3/7 download
    // window plus all 2/1 decode and visible upload roles. Pumping a lane after
    // every individual mutation repeatedly scans the same pending/active state
    // on the UI isolate and can consume an entire vsync before rendering starts.
    // Mutate all three lanes first, then let each lane pump once with the final
    // authoritative state. This does not change policy, priorities or windows.
    // Nest in reverse dependency order so commit unwinds network -> decode ->
    // upload, matching the historical admission order while every lane still
    // observes the same fully-mutated authoritative plan.
    var downloadsMicros = 0;
    var decodesMicros = 0;
    var uploadsMicros = 0;
    var livenessMicros = 0;
    var sourceWakeMicros = 0;
    var budgetMicros = 0;
    upload.batch(() {
      decode.batch(() {
        net.batch(() {
          var stageStartedAt = clock.nowMicros();
          _reconcileDownloads(sessionId, update.diff.downloads);
          downloadsMicros = clock.nowMicros() - stageStartedAt;
          stageStartedAt = clock.nowMicros();
          _reconcileDecodes(sessionId, update.diff.decodes);
          decodesMicros = clock.nowMicros() - stageStartedAt;
          stageStartedAt = clock.nowMicros();
          _reconcileUploads(sessionId, update.diff.uploads);
          uploadsMicros = clock.nowMicros() - stageStartedAt;
          stageStartedAt = clock.nowMicros();
          _refreshDemandLiveness(update.plan);
          livenessMicros = clock.nowMicros() - stageStartedAt;
          stageStartedAt = clock.nowMicros();
          _flushSourceRebindWakes(sessionId);
          sourceWakeMicros = clock.nowMicros() - stageStartedAt;
          stageStartedAt = clock.nowMicros();
          _enforceBudget(sessionId);
          budgetMicros = clock.nowMicros() - stageStartedAt;
        });
      });
    });

    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.pipelineReconcileTiming,
        revision: _revision,
        payload: <String, Object?>{
          'reconcileMicros':
              (clock.nowMicros() - startedAtMicros).clamp(0, 1 << 62).toInt(),
          'downloadsMicros': downloadsMicros.clamp(0, 1 << 62).toInt(),
          'decodesMicros': decodesMicros.clamp(0, 1 << 62).toInt(),
          'uploadsMicros': uploadsMicros.clamp(0, 1 << 62).toInt(),
          'livenessMicros': livenessMicros.clamp(0, 1 << 62).toInt(),
          'sourceWakeMicros': sourceWakeMicros.clamp(0, 1 << 62).toInt(),
          'budgetMicros': budgetMicros.clamp(0, 1 << 62).toInt(),
          'downloadAdded': update.diff.downloads.added.length,
          'downloadChanged': update.diff.downloads.changed.length,
          'downloadRemoved': update.diff.downloads.removed.length,
          'decodeAdded': update.diff.decodes.added.length,
          'decodeChanged': update.diff.decodes.changed.length,
          'decodeRemoved': update.diff.decodes.removed.length,
          'uploadAdded': update.diff.uploads.added.length,
          'uploadChanged': update.diff.uploads.changed.length,
          'uploadRemoved': update.diff.uploads.removed.length,
          'downloadCount': update.plan.downloads.length,
          'decodeCount': update.plan.decodes.length,
          'uploadCount': update.plan.uploads.length,
          'atomicLaneBatch': true,
        },
      ),
    );
  }

  /// Plan revision is liveness metadata, not scheduler identity. Semantic
  /// diffs above perform the only cancel/submit/follow work; afterwards every
  /// surviving demand receives the new expiration revision in-place so active
  /// tasks remain live without being re-enqueued merely because time advanced.
  void _refreshDemandLiveness(DemandPlan plan) {
    _downloads
      ..clear()
      ..addAll(plan.downloads);
    _decodes
      ..clear()
      ..addAll(plan.decodes);
    _uploads
      ..clear()
      ..addAll(plan.uploads);
    // Revision-scoped policy feedback must observe the accepted plan revision
    // even when the underlying task was not resubmitted. These maps are
    // metadata clocks, not task-generation identities.
    for (final id in plan.decodes.keys) {
      _decodeDemandRevisions[id] = _revision;
    }
    for (final id in plan.uploads.keys) {
      _uploadDemandRevisions[id] = _revision;
    }
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
        return registry.freezePlayback(id);
      },
      resume: (id) {
        final registry = uploads;
        if (registry == null) {
          return false;
        }
        return registry.resumePlayback(id);
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
    for (final binding in _sourceWatches.values) {
      binding.projection.removeSourceListener(binding.listener);
    }
    _sourceWatches.clear();
    _observedDownloadSessions.clear();
    _sourceRebindWakes.clear();
    _sourceRevisions.clear();
    _sourceWakeLengths.clear();
    _decodeSourceRevisions.clear();
    // This barrier removes only this Reader/command consumer from the
    // composition physical owner. If an active task captured this Reader's
    // transport, dispose waits for that task to physically exit before the
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
    _externalPresentationPending.clear();
    _externalPresentationSatisfied.clear();
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
    if (diff.isEmpty) return;
    for (final id in diff.removed) {
      _downloads.remove(id);
      _observedDownloadSessions.remove(id);
    }
    final scheduled = <MapEntry<DownloadId, DownloadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ];
    for (final entry in scheduled) {
      _downloads[entry.key] = entry.value;
    }
    _downloadTransfer.replaceDemands(
      sessionId,
      _revision,
      <DownloadId, TransferDemand>{
        for (final entry in _downloads.entries)
          entry.key: TransferDemand(
            priority: entry.value.priority,
            reason: entry.value.reason,
            flowTargetFrames: entry.value.flowTargetFrames,
          ),
      },
    );
    // Source/ingress observation is physical-identity lifecycle work, not a
    // scheduling-priority side effect. Newly demanded identities must attach;
    // an existing logical id only re-enters this path if the physical session
    // object actually changed. Routine role/priority migration therefore stays
    // in the transfer scheduler and does not repeatedly attach ingress or walk
    // Reader source-watch ownership on every page boundary.
    for (final entry in diff.added.entries) {
      final session = _downloadSessionFor(entry.key);
      _observeDownloadIdentity(sessionId, entry.key, session);
    }
    for (final entry in diff.changed.entries) {
      final session = _findDownloadSession(entry.key);
      final observed = _observedDownloadSessions[entry.key];
      if (session != null && !identical(observed, session)) {
        _observeDownloadIdentity(sessionId, entry.key, session);
        if (_sourceWatches.containsKey(entry.key)) {
          _watchSource(sessionId, entry.key, session);
        }
      }
    }
  }

  void _observeDownloadIdentity(
    String sessionId,
    DownloadId id,
    DownloadSession session,
  ) {
    _observedDownloadSessions[id] = session;
    try {
      onDownloadObserved?.call(session);
    } on Object {
      // Reader-local observers cannot break physical transfer ownership.
    }
  }

  void _clearSourceKind(DownloadId id) {
    final removed = _sourceKinds.remove(id);
    if (removed == null) return;
    try {
      onSourceKindObserved?.call(id, ContentKind.unknown);
    } on Object {
      // Cost observers cannot break source/decode ownership.
    }
  }

  void _forgetSourceKindWatch(DownloadId id) {
    // Releasing one Reader-local source watch is a consumer-lifetime event,
    // not negative encoded-content evidence. In particular, publishing
    // ContentKind.unknown here makes Pipeline remove an already-observed WebP
    // transport-cost fact; the resulting plan can reacquire this same source,
    // sniff WebP again, release it again, and oscillate forever. Physical
    // session/generation replacement still uses _clearSourceKind so genuinely
    // stale evidence is withdrawn before the replacement source is observed.
    _sourceKinds.remove(id);
  }

  void _clearExternalPresentationForDownload(DownloadId id) {
    _externalPresentationPending.removeWhere(
      (decodeId) => decodeId.download == id,
    );
    _externalPresentationSatisfied.removeWhere(
      (decodeId) => decodeId.download == id,
    );
  }

  void _releaseSourceIfUnused(DownloadId id) {
    if (_decodes.keys.any((candidate) => candidate.download == id) ||
        _uploads.keys.any((candidate) => candidate.download == id) ||
        (uploads?.hasRetainableStaticOutputForDownload(id) ?? false)) {
      return;
    }
    final binding = _sourceWatches.remove(id);
    _sourceRevisions.remove(id);
    _sourceWakeLengths.remove(id);
    _sourceRebindWakes.remove(id);
    _forgetSourceKindWatch(id);
    _clearExternalPresentationForDownload(id);
    if (binding == null) return;
    binding.projection.removeSourceListener(binding.listener);
    for (final decodeId in _decodeSourceRevisions.keys
        .where((candidate) => candidate.download == id)
        .toList(growable: false)) {
      _decodeSourceRevisions.remove(decodeId);
    }
    // Native cursors and UploadSessions hold concrete source/decode generation
    // ownership. Once no demand or retained static output authorizes that
    // media generation, retire the full dependent chain before disposing the
    // Reader-local ingress; otherwise stale cursors can pin encoded bytes or
    // be reused against a later physical generation.
    uploads?.invalidateForDownload(id);
    decodes?.invalidateForDownload(id);
    ingresses?.release(binding.session);
  }

  void _watchSource(
    String sessionId,
    DownloadId id,
    DownloadSession session,
  ) {
    final projection = ingresses?.get(session);
    if (projection == null) {
      return;
    }
    final existing = _sourceWatches[id];
    if (existing != null && identical(existing.projection, projection)) {
      if (!identical(existing.session, session)) {
        final previousSession = existing.session;
        existing.session = session;
        traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.artifactSource,
            identityHash: id.key,
            revision: _revision,
            payload: <String, Object?>{
              'stage': 'reader-source-watch-rebind',
              'action': 'sealed-source-generation-preserved',
              'fromPhysicalSession': previousSession.sessionId,
              'toPhysicalSession': session.sessionId,
              'invalidatedUploads': 0,
              'invalidatedDecodes': 0,
            },
          ),
        );
      }
      return;
    }

    if (existing != null) {
      existing.projection.removeSourceListener(existing.listener);
      _sourceRevisions.remove(id);
      _sourceWakeLengths.remove(id);
      _clearSourceKind(id);
      _clearExternalPresentationForDownload(id);
      for (final decodeId in _decodeSourceRevisions.keys
          .where((decodeId) => decodeId.download == id)
          .toList(growable: false)) {
        _decodeSourceRevisions.remove(decodeId);
      }
      final reboundDecodeIds = <DecodeId>{
        ..._decodes.keys.where((decodeId) => decodeId.download == id),
        ..._uploads.keys.where((decodeId) => decodeId.download == id),
      };
      for (final decodeId in reboundDecodeIds) {
        decode.cancel(decodeId.key);
        upload.cancel(decodeId.key);
      }
      // UploadSession holds a concrete DecodeSession for its lifetime. Retire
      // dependent upload/output sessions before replacing DecodeRegistry's
      // physical-generation-bound DecodeSessions, otherwise an upload revisit
      // can remain attached to the disposed holder indefinitely.
      final invalidatedUploads = uploads?.invalidateForDownload(id) ?? 0;
      final invalidatedDecodes = decodes?.invalidateForDownload(id) ?? 0;
      _sourceRebindWakes.add(id);
      traceSink.record(
        traceEvent(
          clock: clock,
          sessionId: sessionId,
          kind: TraceEventKind.artifactSource,
          identityHash: id.key,
          revision: _revision,
          payload: <String, Object?>{
            'stage': 'reader-source-watch-rebind',
            'action': 'physical-generation-changed',
            'fromPhysicalSession': existing.session.sessionId,
            'toPhysicalSession': session.sessionId,
            'invalidatedUploads': invalidatedUploads,
            'invalidatedDecodes': invalidatedDecodes,
          },
        ),
      );
    }

    late final _SourceWatchBinding binding;
    void listener(IngressSnap snapshot) {
      final epochChanged = binding.epoch != snapshot.epoch;
      if (epochChanged) {
        final previousEpoch = binding.epoch;
        binding.epoch = snapshot.epoch;
        binding.sourceReady = false;
        _sourceWakeLengths.remove(id);
        _sourceRevisions.remove(id);
        _clearSourceKind(id);
        _clearExternalPresentationForDownload(id);
        final reboundDecodeIds = <DecodeId>{
          ..._decodes.keys.where((decodeId) => decodeId.download == id),
          ..._uploads.keys.where((decodeId) => decodeId.download == id),
        };
        for (final decodeId in reboundDecodeIds) {
          _decodeSourceRevisions.remove(decodeId);
          _decodeRecoveryAttempts.remove(decodeId);
          _decodeRecoveryPending.remove(decodeId);
          decode.cancel(decodeId.key);
          upload.cancel(decodeId.key);
        }
        // The physical DownloadSession object may survive a reset, but its
        // SourceEpoch does not. Upload/output and decode/cursor state are bound
        // to encoded-source generations, so retire them before the first byte
        // of the replacement epoch becomes visible. The existing demand map
        // remains authoritative and will recreate this Reader-local media
        // chain when the new source becomes ready.
        final invalidatedUploads = uploads?.invalidateForDownload(id) ?? 0;
        final invalidatedDecodes = decodes?.invalidateForDownload(id) ?? 0;
        traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.artifactSource,
            identityHash: id.key,
            revision: _revision,
            epoch: snapshot.epoch.value,
            payload: <String, Object?>{
              'stage': 'reader-source-watch-rebind',
              'action': 'source-epoch-changed',
              'fromSourceEpoch': previousEpoch.value,
              'toSourceEpoch': snapshot.epoch.value,
              'invalidatedUploads': invalidatedUploads,
              'invalidatedDecodes': invalidatedDecodes,
            },
          ),
        );
      }

      // Encoded content kind is a Reader/runtime transport-cost fact, not
      // animation truth. Publish only actual sniff transitions; opaque plugin
      // URIs otherwise leave the Pipeline unable to activate bounded WebP body
      // flow until a full animation classification arrives.
      final priorKind = _sourceKinds[id];
      final kindChanged = priorKind != snapshot.kind;
      if (kindChanged) {
        _sourceKinds[id] = snapshot.kind;
        try {
          onSourceKindObserved?.call(id, snapshot.kind);
        } on Object {
          // Cost observers cannot break source/decode ownership.
        }
      }
      // Physical retry/terminal state is owned by DownloadTransferOwner. This
      // Reader-local listener projects both source growth and content
      // classification into decode wakeups. Fallback/GIF can become
      // classification-ready without ever exposing a native EncodedSource, so
      // a non-unknown kind transition is sufficient evidence to rerun a decode
      // that is waiting for source classification.
      final becameSourceReady = !binding.sourceReady && snapshot.sourceReady;
      binding.sourceReady = snapshot.sourceReady;
      _sourceRevisions[id] = snapshot.revision;
      final priorLength = _sourceWakeLengths[id];
      final shouldWake = snapshot.failure != null ||
          snapshot.sealed ||
          (kindChanged && snapshot.kind != ContentKind.unknown) ||
          (snapshot.sourceReady &&
              (onDecode != null ||
                  becameSourceReady ||
                  priorLength == null ||
                  snapshot.length - priorLength >= sourceProgressQuantumBytes));
      if (!shouldWake) {
        return;
      }
      _sourceWakeLengths[id] = snapshot.length;
      _wakeDecodesForSource(sessionId, id);
    }

    final initialSnapshot = projection.snapshot;
    binding = _SourceWatchBinding(
      session: session,
      projection: projection,
      listener: listener,
      epoch: initialSnapshot.epoch,
      sourceReady: initialSnapshot.sourceReady,
    );
    _sourceWatches[id] = binding;
    projection.addSourceListener(listener);
  }

  void _flushSourceRebindWakes(String sessionId) {
    if (_sourceRebindWakes.isEmpty) return;
    final downloads = _sourceRebindWakes.toList(growable: false);
    _sourceRebindWakes.clear();
    for (final id in downloads) {
      _wakeDecodesForSource(sessionId, id);
    }
  }

  String _decodeTraceIdentity(DecodeId id) =>
      decodes?.traceIdentityFor(id) ?? traceIdentityToken(id.key);

  void _reconcileDecodes(
    String sessionId,
    MapDiff<DecodeId, DecodeDemand> diff,
  ) {
    final removedDownloads = <DownloadId>{};
    for (final id in diff.removed) {
      removedDownloads.add(id.download);
      _decodes.remove(id);
      _decodeDemandRevisions.remove(id);
      _decodeSourceRevisions.remove(id);
      _decodeRecoveryAttempts.remove(id);
      _decodeRecoveryPending.remove(id);
      _externalPresentationPending.remove(id);
      _externalPresentationSatisfied.remove(id);
      decode.cancel(id.key);
      decodes?.detach(id);
    }
    for (final entry in <MapEntry<DecodeId, DecodeDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      final downloadSession = _observedDownloadSessions[entry.key.download] ??
          _findDownloadSession(entry.key.download);
      if (downloadSession != null) {
        _watchSource(sessionId, entry.key.download, downloadSession);
      }
      _decodes[entry.key] = entry.value;
      final demandRevision = _revision;
      _decodeDemandRevisions[entry.key] = demandRevision;
      if (diff.added.containsKey(entry.key)) {
        _resourceTrace(
          sessionId,
          TraceEventKind.decodeDemand,
          _decodeTraceIdentity(entry.key),
          entry.value.priority,
          revision: demandRevision,
        );
      }
      if (entry.value.role == PageRole.current) {
        _promoteDecodeToCurrent(sessionId, entry.key, demandRevision);
      }
      if (onDecode == null && decodes == null) {
        continue;
      }
      final decodeRegistry = decodes;
      if (_externalPresentationSatisfied.contains(entry.key)) {
        // A Flutter/fallback first frame is the one-frame readiness proof for
        // this exact DecodeId. Role/priority migrations keep that proof just
        // like a resident native static frame; they must not restart the
        // no-native-frame DecodeSession merely because the plan revision moved.
        decode.cancelQueued(entry.key.key);
        continue;
      }
      final pendingSourceWake = _hasPendingSourceRevision(entry.key);
      final before = decodeRegistry?.find(entry.key)?.snapshot;
      final preparedDepth = uploads?.preparedDepth(entry.key) ?? 0;
      if (decodeRegistry != null &&
          !pendingSourceWake &&
          !_decodeNeedsFill(
            before,
            entry.value,
            preparedDepth: preparedDepth,
            sourceWake: false,
            force: true,
          )) {
        // Role/priority migration of an already-satisfied static page is
        // scheduler metadata, not decode work. Remove any stale queued no-op
        // and update a genuinely active task in place instead of following it
        // with another lane task that will rediscover the same fact.
        decode.cancelQueued(entry.key.key);
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
    for (final id in removedDownloads) {
      _releaseSourceIfUnused(id);
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
        identityHash: _decodeTraceIdentity(id),
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
              before?.state != DecodeState.waitingSource &&
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
              reason: '${current.reason}:refill:${refill.stage.wireName}',
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
        if (pendingSourceWake &&
            sourceRevision >= 0 &&
            before?.state != DecodeState.waitingSource) {
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
            identityHash: _decodeTraceIdentity(id),
            revision: demandRevision,
            payload: <String, Object?>{
              'role': refill.role.name,
              'stage': refill.stage.wireName,
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
                    _wakeUploadFromDecode(sessionId, id);
                  }
                : null,
          );
          final sourceBinding = _sourceWatches[id.download];
          if (sourceBinding != null) {
            _downloadTransfer.observeDecodePrefixEvidence(
              sourceBinding.session,
              after,
            );
            if (sourceBinding.session.residentIngressDeferred &&
                after.state == DecodeState.waitingSource &&
                after.requiredSourceLength > after.sourceLength) {
              unawaited(
                ingresses?.ensureResidentPrefix(
                      sourceBinding.session,
                      after.requiredSourceLength,
                    ) ??
                    Future<void>.value(),
              );
            }
          }
        }
        if (after != null &&
            (after.state == DecodeState.failed || after.failure != null)) {
          throw after.failure ??
              const Failure(
                code: ErrorCode.decode,
                message: 'decode fill returned a failed snapshot',
              );
        }
        if (sourceRevision >= 0 &&
            (after == null || after.state != DecodeState.waitingSource)) {
          _decodeSourceRevisions[id] = sourceRevision;
        }
        if (after != null) {
          _decodeRecoveryAttempts.remove(id);
          _decodeRecoveryPending.remove(id);
          if (refill != null &&
              after.externalPresentationRequired &&
              after.state == DecodeState.ended &&
              after.failure == null &&
              after.depth == 0 &&
              _uploads.containsKey(id) &&
              !_externalPresentationSatisfied.contains(id) &&
              onExternalPresentationRequested != null &&
              externalPresentationAvailable?.call(id) != false &&
              _externalPresentationPending.add(id)) {
            try {
              onExternalPresentationRequested?.call(
                id,
                _decodeDemandRevisions[id] ?? demandRevision,
              );
            } on Object {
              // A projection observer may disappear with its Reader host. Do
              // not leave the staged refill permanently blocked if notifying
              // that read-only projection fails.
              _externalPresentationPending.remove(id);
            }
          }
        }
        if (work != null) {
          _wakeUpload(sessionId, id);
        } else if (after?.externalPresentationRequired != true &&
            _decodeChangeNeedsUpload(before, after)) {
          _wakeUploadFromDecode(sessionId, id);
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
                identityHash: _decodeTraceIdentity(id),
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
        identityHash: _decodeTraceIdentity(id),
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
    final pendingExternal = _externalPresentationPending
        .where(_decodes.containsKey)
        .toSet();
    final speculativePendingExternal = pendingExternal.where((id) {
      final uploadDemand = _uploads[id];
      if (uploadDemand?.viewportVisible == true) return false;
      final role = _decodes[id]?.role;
      return role != PageRole.current && role != PageRole.transition;
    }).length;
    bool admittedWhileExternalPresentationPending(DecodeId id) {
      if (pendingExternal.contains(id)) return false;
      // Visible/current/transition first frames may always preempt speculative
      // external work. Offscreen static warming is separately bounded so fast
      // vertical motion can prepare more than one upcoming Flutter image
      // without turning the whole 3/7 window into unbounded UI work.
      final uploadDemand = _uploads[id];
      if (uploadDemand?.viewportVisible == true) return true;
      final role = _decodes[id]?.role;
      if (role == PageRole.current || role == PageRole.transition) return true;
      return speculativePendingExternal <
          maxSpeculativeExternalPresentationPending;
    }
    return refillPolicy.next(
      demands: _decodes,
      depthOf: (id) => registry.find(id)?.snapshot.depth ?? 0,
      terminalOf: (id) {
        final snapshot = registry.find(id)?.snapshot;
        if (snapshot == null ||
            snapshot.state != DecodeState.ended ||
            snapshot.failure != null) {
          return false;
        }
        if (snapshot.externalPresentationRequired &&
            (onExternalPresentationRequested == null ||
                !_uploads.containsKey(id))) {
          // There is no active presentation consumer for this decode. Treat
          // the native decode branch as terminal for now; promotion into an
          // UploadDemand will make it eligible for the external first-frame
          // handshake without manufacturing background UI work.
          return true;
        }
        return snapshot.animation.complete &&
            snapshot.animation.frameCount > 1;
      },
      satisfiedOf: (id) {
        if (_externalPresentationSatisfied.contains(id)) {
          return true;
        }
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
        if (!admittedWhileExternalPresentationPending(id)) {
          return false;
        }
        if (only != null && id != only) {
          return false;
        }
        final snapshot = registry.find(id)?.snapshot;
        if (snapshot == null ||
            snapshot.failure != null ||
            snapshot.state == DecodeState.failed) {
          return true;
        }
        if (snapshot.externalPresentationRequired &&
            externalPresentationAvailable?.call(id) == false) {
          // External first-frame work can only be granted to a concrete
          // presentation consumer. A retained/offscreen static page may still
          // keep its decode/upload intent, but it must not occupy the bounded
          // speculative grant set while no adapter can ever report a frame.
          return false;
        }
        return snapshot.state != DecodeState.waitingSource ||
            _hasPendingSourceRevision(id) ||
            snapshot.partialPrefixLoopEligible;
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

  bool get hasPendingExternalPresentation =>
      _externalPresentationPending.any(_decodes.containsKey);

  bool externalPresentationPendingFor(DecodeId id) =>
      _externalPresentationPending.contains(id) && _decodes.containsKey(id);

  bool externalPresentationSatisfiedFor(DecodeId id) =>
      _externalPresentationSatisfied.contains(id) && _decodes.containsKey(id);

  /// Invalidates presentation-cache readiness without changing media/source
  /// identity. Presentation geometry (for example contain vs fit-width) is not
  /// part of [DecodeId], so a layout change must retire only the external
  /// first-frame proof and let the existing staged policy re-grant it.
  void invalidateExternalPresentation(String sessionId, DecodeId id) {
    if (!_decodes.containsKey(id)) return;
    final releasedPending = _externalPresentationPending.remove(id);
    final releasedSatisfied = _externalPresentationSatisfied.remove(id);
    if (releasedPending || releasedSatisfied) {
      _wakeNextDecodeRefill(sessionId, except: id);
    }
    refreshDecodeScheduling(sessionId, only: id);
  }

  /// Updates the presentation-side ability to fulfill one external first
  /// frame without transferring scheduling ownership out of the coordinator.
  ///
  /// Losing the last consumer invalidates both an outstanding grant and its
  /// satisfied marker: a later host is a new presentation lifetime and must
  /// receive a fresh exact grant. Becoming available only wakes this exact
  /// decode identity; normal refill policy still decides whether it runs.
  void updateExternalPresentationAvailability(
    String sessionId,
    DecodeId id, {
    required bool available,
  }) {
    if (!_decodes.containsKey(id)) return;
    if (available) {
      refreshDecodeScheduling(sessionId, only: id);
      return;
    }
    final releasedPending = _externalPresentationPending.remove(id);
    // A satisfied external static DecodeId is presentation-cache readiness, not
    // a widget-listener lifetime. Dropping the last page host must not erase a
    // first-frame proof produced by a detached presentation prewarmer. Decode
    // removal/source-generation reset still clears the proof at their existing
    // ownership boundaries.
    if (releasedPending) {
      _wakeNextDecodeRefill(sessionId, except: id);
    }
  }

  /// Completes the staged one-frame watermark for a source whose frame is
  /// produced by the presentation adapter rather than DecodeRegistry.
  ///
  /// The caller reports an observed first frame only; it cannot choose which
  /// page is eligible. Eligibility remains owned by [StagedDecodeRefillPolicy].
  bool completeExternalPresentation(String sessionId, DecodeId id) {
    if (!_externalPresentationPending.remove(id)) {
      return false;
    }
    if (!_decodes.containsKey(id)) {
      _externalPresentationSatisfied.remove(id);
      return false;
    }
    _externalPresentationSatisfied.add(id);
    _wakeNextDecodeRefill(sessionId);
    return true;
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
    if (snapshot.partialPrefixLoopEligible) {
      return true;
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
    final removedDownloads = <DownloadId>{};
    var releasedExternalPresentation = false;
    for (final id in diff.removed) {
      removedDownloads.add(id.download);
      _uploads.remove(id);
      releasedExternalPresentation =
          _externalPresentationPending.remove(id) ||
              releasedExternalPresentation;
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
      final priorUploadDemand = _uploads[entry.key];
      final downloadSession = _observedDownloadSessions[entry.key.download] ??
          _findDownloadSession(entry.key.download);
      if (downloadSession != null) {
        _watchSource(sessionId, entry.key.download, downloadSession);
      }
      _uploads[entry.key] = entry.value;
      if (priorUploadDemand?.viewportVisible == true &&
          !entry.value.viewportVisible) {
        releasedExternalPresentation =
            _externalPresentationPending.remove(entry.key) ||
                releasedExternalPresentation;
      }
      final demandRevision = _revision;
      _uploadDemandRevisions[entry.key] = demandRevision;
      if (diff.added.containsKey(entry.key)) {
        _resourceTrace(
          sessionId,
          TraceEventKind.uploadDemand,
          _decodeTraceIdentity(entry.key),
          entry.value.priority,
          revision: demandRevision,
        );
      }
      final uploadRegistry = uploads;
      if (uploadRegistry != null) {
        if (entry.value.role == PageRole.current ||
            entry.value.role == PageRole.transition) {
          uploadRegistry.resumePlayback(entry.key);
        } else if (entry.value.role == PageRole.next) {
          // Paged next may own one speculative first-frame output so a swipe
          // does not pay RGBA->SurfaceProducer work after the host mounts.
          // Freeze before prepare/presentation: the detached prewarm may
          // present frame zero, but it must never start hidden animation
          // playback. Promotion to transition/current resumes the same output.
          uploadRegistry.get(entry.key).freezePlayback();
        }
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
                identityHash: _decodeTraceIdentity(entry.key),
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
      if (uploadRegistry != null &&
          uploadRegistry.rebindResidentAnimatedForDemand(
            entry.key,
            entry.value,
            revision: demandRevision,
          )) {
        // Role/priority-only migrations do not invalidate a resident animated
        // output. Playback owns when its successor becomes eligible; submitting
        // UploadLane here would only run prepare() into its resident-frame
        // no-op branch and can repeat as the viewport oscillates around 50%.
        upload.cancelQueued(entry.key.key);
        continue;
      }
      if (uploadRegistry != null &&
          uploadRegistry.reusePreparedStaticForDemand(
            entry.key,
            entry.value,
            revision: demandRevision,
          )) {
        // A retained/ready authoritative static output only changed policy
        // role. Do not enqueue an UploadLane task merely to run prepare() into
        // its already-ready no-op branch.
        upload.cancelQueued(entry.key.key);
        continue;
      }
      if (uploadRegistry != null && entry.value.role == PageRole.next) {
        final decodeHolder = decodes?.find(entry.key)?.holder;
        final residentOutput =
            uploadRegistry.find(entry.key)?.snapshot.frameIndex;
        if (residentOutput == null &&
            (decodeHolder == null || decodeHolder.isEmpty)) {
          // Hidden paged-next preupload is producer-driven. Its UploadDemand
          // owns the right to prepare one output, but an empty decode holder is
          // not upload work yet. The first decoded-frame callback wakes this
          // lane once real input exists instead of burning an initial no-op
          // task before decode and then another task for the same frame.
          upload.cancelQueued(entry.key.key);
          continue;
        }
      }
      _submitUpload(
        sessionId,
        entry.key,
        entry.value,
        follow: diff.changed.containsKey(entry.key),
        demandRevision: demandRevision,
      );
    }
    for (final id in removedDownloads) {
      _releaseSourceIfUnused(id);
    }
    if (releasedExternalPresentation) {
      _wakeNextDecodeRefill(sessionId);
    }
  }

  void _wakeUploadFromDecode(String sessionId, DecodeId id) {
    final uploadRegistry = uploads;
    if (uploadRegistry != null) {
      final snapshot = uploadRegistry.find(id)?.snapshot;
      if (snapshot != null) {
        // Decode refill may run ahead while a resident output is intentionally
        // frozen (paged next) or waiting for its playback deadline (current).
        // That new decoded depth is producer inventory, not immediate upload
        // work. Only the first output, an explicitly awaited successor, or a
        // session without a resident frame may re-enter UploadLane.
        if (snapshot.state == UploadState.uploading) {
          return;
        }
        if (snapshot.frameIndex != null &&
            snapshot.state != UploadState.waitingFrame) {
          return;
        }
      }
    }
    _wakeUpload(sessionId, id);
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
                      _decodes.containsKey(id) &&
                      decodes?.find(id)?.state != DecodeState.waitingSource)) {
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
    if (report.decodedFreed > 0 || report.outputFreed > 0) {
      for (final id in _sourceWatches.keys.toList(growable: false)) {
        _releaseSourceIfUnused(id);
      }
    }
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
