import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';
import 'package:transport/transport.dart';

import 'coordinator.dart';
import 'decode_registry.dart';
import 'decode_session.dart';
import 'download_job.dart';
import 'download_registry.dart';
import 'download_session.dart';
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

Future<void> _defaultSleep(Duration delay) => Future<void>.delayed(delay);

final class LiveCoordinator implements Coordinator, PlaybackCoordinator {
  LiveCoordinator({
    required this.registry,
    required this.transportFor,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.retry = const RetryPolicy(),
    this.sleep = _defaultSleep,
    this.onDecode,
    this.onUpload,
    this.decodes,
    this.uploads,
    this.budgets,
    NetLane? net,
    DecodeLane? decode,
    UploadLane? upload,
  })  : net = net ?? NetLane(maxActive: 3),
        decode = decode ?? DecodeLane(maxActive: 2),
        upload = upload ?? UploadLane(maxActive: 1) {
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
  }

  final DownloadRegistry registry;
  final TransportPick transportFor;
  final MonoClock clock;
  final TraceSink traceSink;
  final RetryPolicy retry;
  final Sleep sleep;
  final DecodeWork? onDecode;
  final UploadWork? onUpload;
  final DecodeRegistry? decodes;
  final UploadRegistry? uploads;
  final FrameBudgeter? budgets;
  final NetLane net;
  final DecodeLane decode;
  final UploadLane upload;

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
  final PlaybackGate _playbackGate = PlaybackGate();
  int _revision = 0;

  Map<DownloadId, DownloadDemand> get demands =>
      Map<DownloadId, DownloadDemand>.unmodifiable(_downloads);
  Map<DecodeId, DecodeDemand> get decodeDemands =>
      Map<DecodeId, DecodeDemand>.unmodifiable(_decodes);
  Map<DecodeId, UploadDemand> get uploadDemands =>
      Map<DecodeId, UploadDemand>.unmodifiable(_uploads);

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
      await net.idle();
      await decode.idle();
      await upload.idle();
      await Future<void>.delayed(Duration.zero);
      if (net.isIdle && decode.isIdle && upload.isIdle) {
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
      registry.find(entry.key)?.removeSourceListener(entry.value);
    }
    _sourceListeners.clear();
    _sourceRevisions.clear();
    _sourceWakeLengths.clear();
    _decodeSourceRevisions.clear();
    for (final session in registry.sessions) {
      net.cancel(session.id.key);
    }
    final decodeRegistry = decodes;
    if (decodeRegistry != null) {
      for (final session in decodeRegistry.sessions) {
        decode.cancel(session.id.key);
      }
    } else {
      for (final id in _decodes.keys) {
        decode.cancel(id.key);
      }
    }
    final uploadRegistry = uploads;
    if (uploadRegistry != null) {
      for (final session in uploadRegistry.sessions) {
        upload.cancel(session.id.key);
      }
    } else {
      for (final id in _uploads.keys) {
        upload.cancel(id.key);
      }
    }
    _downloads.clear();
    _decodes.clear();
    _decodeDemandRevisions.clear();
    _uploads.clear();
    _uploadDemandRevisions.clear();
    await idle();
  }

  void _reconcileDownloads(
    String sessionId,
    MapDiff<DownloadId, DownloadDemand> diff,
  ) {
    for (final id in diff.removed) {
      _downloads.remove(id);
      net.cancelQueued(id.key);
      final session = registry.find(id);
      final listener = _sourceListeners.remove(id);
      if (listener != null) {
        session?.removeSourceListener(listener);
      }
      _sourceRevisions.remove(id);
      _sourceWakeLengths.remove(id);
      session?.detach();
    }
    for (final entry in <MapEntry<DownloadId, DownloadDemand>>[
      ...diff.added.entries,
      ...diff.changed.entries,
    ]) {
      _downloads[entry.key] = entry.value;
      final session = registry.get(entry.key)..attach();
      _watchSource(sessionId, entry.key, session);
      net.submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) => _runDownload(sessionId, entry.key, session, token),
      );
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
      // Source revision remains authoritative, but tiny network chunks are not
      // independent decode work. The first ready source, each 64 KiB growth
      // quantum, seal and failure wake the same decode demand.
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
    _sourceListeners[id] = listener;
    session.addSourceListener(listener);
  }

  Future<void> _runDownload(
    String sessionId,
    DownloadId id,
    DownloadSession session,
    CancelToken token,
  ) async {
    for (var attempt = 1; ; attempt++) {
      token.throwIfCancelled();
      final demand = _downloads[id];
      if (demand == null ||
          demand.expirationRevision < _revision ||
          !session.demanded) {
        return;
      }
      try {
        await DownloadJob(
          transport: transportFor(id.canonicalUri),
          session: session,
        ).run(cancel: token);
        _wakeDecodesForSource(sessionId, id);
        return;
      } on Object catch (error) {
        if (!retry.allows(error, attempt)) {
          if (error is Failure && error.code == ErrorCode.cancelled) {
            return;
          }
          _error(sessionId, id.key, 'network', error);
          return;
        }
        final delay = retry.delayAfter(attempt);
        traceSink.record(
          traceEvent(
            clock: clock,
            sessionId: sessionId,
            kind: TraceEventKind.retryScheduled,
            identityHash: id.key,
            revision: _revision,
            payload: <String, Object?>{
              'attempt': attempt + 1,
              'delayUs': delay.inMicroseconds,
              'error': '$error',
            },
          ),
        );
        await _sleepOrCancel(delay, token);
      }
    }
  }

  Future<void> _sleepOrCancel(Duration delay, CancelToken token) async {
    if (delay == Duration.zero) {
      token.throwIfCancelled();
      return;
    }
    await Future.any<void>(<Future<void>>[
      sleep(delay),
      token.whenCancelled,
    ]);
    token.throwIfCancelled();
  }

  void _reconcileDecodes(
    String sessionId,
    MapDiff<DecodeId, DecodeDemand> diff,
  ) {
    for (final id in diff.removed) {
      _decodes.remove(id);
      _decodeDemandRevisions.remove(id);
      _decodeSourceRevisions.remove(id);
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
      if (onDecode == null && decodes == null) {
        continue;
      }
      final submit = diff.changed.containsKey(entry.key)
          ? decode.replace
          : decode.submit;
      submit(
        key: entry.key.key,
        priority: entry.value.priority,
        task: (token) => _runDecode(
          sessionId,
          entry.key,
          token,
          demandRevision: demandRevision,
          sourceWake: false,
          force: true,
        ),
      );
    }
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
    decode.follow(
      key: id.key,
      priority: demand.priority,
      task: (token) => _runDecode(
        sessionId,
        id,
        token,
        demandRevision: _decodeDemandRevisions[id] ?? _revision,
        sourceWake: sourceWake,
        force: force,
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
  }) async {
    while (true) {
      final current = _decodes[id];
      if (current == null || current.expirationRevision < _revision) {
        return;
      }
      final sourceRevision = _sourceRevisions[id.download] ?? -1;
      final observedSourceRevision = _decodeSourceRevisions[id] ?? -1;
      if (sourceWake && observedSourceRevision >= sourceRevision) {
        return;
      }

      final registry = decodes;
      final before = registry?.find(id)?.snapshot;
      final preparedDepth = uploads?.preparedDepth(id) ?? 0;
      if (registry != null &&
          !_decodeNeedsFill(
            before,
            current,
            preparedDepth: preparedDepth,
            sourceWake: sourceWake,
            force: force,
          )) {
        if (sourceWake && sourceRevision >= 0) {
          _decodeSourceRevisions[id] = sourceRevision;
        }
        return;
      }
      if (sourceRevision >= 0) {
        _decodeSourceRevisions[id] = sourceRevision;
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
          await work(id, current, token);
        } else if (registry != null) {
          after = await registry.fill(
            id,
            current,
            token,
            revision: demandRevision,
            preparedDepth: preparedDepth,
          );
        }
        if (work != null || _decodeChangeNeedsUpload(before, after)) {
          _wakeUpload(sessionId, id);
        }
        _enforceBudget(sessionId);
      } on Object catch (error) {
        if (error is! Failure || error.code != ErrorCode.cancelled) {
          _error(sessionId, id.key, 'decode', error);
          _wakeUpload(sessionId, id);
        }
        return;
      }

      if (!sourceWake) {
        return;
      }
      final latestSourceRevision = _sourceRevisions[id.download] ?? -1;
      final consumedSourceRevision = _decodeSourceRevisions[id] ?? -1;
      if (consumedSourceRevision >= latestSourceRevision) {
        return;
      }
    }
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
      final decodeRestarted = uploads?.detach(id) ?? false;
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
      if (onUpload == null && uploads == null) {
        continue;
      }
      _submitUpload(
        sessionId,
        entry.key,
        entry.value,
        replace: diff.changed.containsKey(entry.key),
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
    bool replace = false,
    bool follow = false,
    required int demandRevision,
  }) {
    final submit = replace
        ? upload.replace
        : follow
            ? upload.follow
            : upload.submit;
    submit(
      key: id.key,
      priority: demand.priority,
      task: (token) async {
        final current = _uploads[id];
        if (current == null || current.expirationRevision < _revision) {
          return;
        }
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
            _error(sessionId, id.key, 'upload', error);
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
    Object error,
  ) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: TraceEventKind.taskFailed,
        identityHash: identity,
        revision: _revision,
        payload: <String, Object?>{'lane': lane, 'error': '$error'},
      ),
    );
  }
}
